#!/usr/bin/env bash
# scripts/herd/sim/postmerge-reconcile-sim.sh — the adversary for HERD-232.
#
# The claim _sweep_merged_prs makes is the same shape retirement.sh makes about teardown: a post-merge
# hook is an INVARIANT of a merged PR, not a side effect of the merge EVENT. If that is true then it
# must not matter WHO merged the PR, or whether the merging process survived long enough to run its own
# hooks. This sim is the adversary for exactly that claim.
#
# Two ways a merged PR ends up with unrun hooks, both reproduced here against a REAL git repo:
#
#   CRASHED MERGE — this seat's do_merge lands the merge (`gh pr merge` succeeds, the $STATE row goes
#     down record-first) and is then killed at each subsequent hook in turn. The 17-PR incident that
#     grounded HERD-232 is the `before-hooks` case: the merge ledgered, so no later tick ever retried,
#     and approval rows, CI rows, the backlog link, and the worktree were stranded forever.
#
#   FOREIGN MERGE — another seat's watcher, or a human clicking Merge in the GitHub UI, merges the PR.
#     Our do_merge never runs at all, so NONE of our seat's obligations are discharged. `gh` reports the
#     PR MERGED; nothing else in our world knows.
#
# For each, the sim runs the crashed/foreign merge in one process, then runs the post-merge sweep in a
# BRAND-NEW process (a restarted watcher, zero inherited memory) and asserts it converges: the $STATE
# merge row exists exactly once, the backlog reconcile is enqueued exactly once, the merged PR's
# approval + CI ledger rows are purged, the worktree is gone, and the tab is closed. Then a THIRD pass
# must be a fixed point — byte-inert.
#
# The SAFETY half: (a) a merged worktree carrying uncommitted work is HELD, never force-removed, and is
# NOT marked swept, so the reap retries; (b) a merged PR whose tracker ref another seat already marked
# Done gets our LOCAL obligations only — the shared hook (the scribe enqueue) is DEFERRED, never
# double-written; (c) a live re-spawned slug sharing the merged PR's name is never reaped, because the
# anchor is the commit sha, not the slug.
#
# Hermetic: a real local git repo, stub `gh` + stub `herdr` on PATH. NO network, NO model, NO real tab.
# Run:  bash scripts/herd/sim/postmerge-reconcile-sim.sh [--artifacts DIR] [--keep]
# Exit: 0 = every checkpoint passed · 1 = at least one failed.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../agent-watch.sh"

c_bold=$'\033[1m'; c_dim=$'\033[2m'; c_grn=$'\033[32m'; c_red=$'\033[31m'; c_rst=$'\033[0m'
step() { printf '\n%s[%s]%s %s\n' "$c_bold" "$1" "$c_rst" "$2"; }
ok()   { printf '  %s✓%s %s\n' "$c_grn" "$c_rst" "$*"; PASS=$((PASS+1)); }
bad()  { printf '  %s✗%s %s\n' "$c_red" "$c_rst" "$*"; FAIL=$((FAIL+1)); }
info() { printf '  %s→%s %s\n' "$c_dim" "$c_rst" "$*"; }
PASS=0; FAIL=0

ART=""; KEEP=""
while [ $# -gt 0 ]; do
  case "$1" in
    --artifacts) ART="${2:-}"; KEEP=1; shift 2 ;;
    --keep)      KEEP=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -n "$ART" ] || ART="$(mktemp -d)"
mkdir -p "$ART"
[ -n "$KEEP" ] || trap 'rm -rf "$ART"' EXIT

[ -f "$WATCH" ] || { bad "agent-watch.sh not found at $WATCH"; exit 1; }
for b in git python3; do command -v "$b" >/dev/null 2>&1 || { bad "$b required"; exit 1; }; done

PR=232

# ── stub binaries (NETWORK-FREE) ─────────────────────────────────────────────────────────────────
BIN="$ART/bin"; mkdir -p "$BIN"

# gh: the whole GitHub surface this sim needs, backed by files in $GH_DIR.
#   pr merge <n> …            → perform the REAL git merge into main, then mark the PR merged.
#   pr list --state merged …  → the merged-PR list the sweep reads (empty until the merge marker exists).
#   pr view <n> --json body   → the PR body, carrying the `Refs:` line the reconcile hook parses.
#   pr view <n> -q .state     → MERGED once the marker exists, else OPEN.
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
merged() { [ -f "$GH_DIR/merged" ]; }
case "${1:-} ${2:-}" in
  "pr merge")
    git -C "$SIM_MAIN" merge -q --no-ff -m "merge #$SIM_PR" "feat/$SIM_SLUG" >/dev/null 2>&1 || exit 1
    : > "$GH_DIR/merged"; exit 0 ;;
  "pr list")
    case "$*" in
      *"--state merged"*)
        if merged; then cat "$GH_DIR/merged.json"; else printf '[]\n'; fi ;;
      *) printf '[]\n' ;;
    esac
    exit 0 ;;
  "pr view")
    case "$*" in
      *"--json body"*)   merged && cat "$GH_DIR/body.txt"; exit 0 ;;
      *.state*|*state*)  merged && printf 'MERGED\n' || printf 'OPEN\n'; exit 0 ;;
    esac
    exit 0 ;;
esac
exit 0
STUB

# herdr: a tab registry in one JSON file; `tab close` removes a tab (so a leaked tab is observable).
cat > "$BIN/herdr" <<'STUB'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "workspace list") printf '{"result":{"workspaces":[{"name":"simws","workspace_id":"ws1"}]}}\n' ;;
  "tab list")       cat "$HERDR_TABS" ;;
  "tab close")      TAB="${3:-}" python3 -c '
import json, os
p = os.environ["HERDR_TABS"]; tid = os.environ["TAB"]
d = json.load(open(p))
d["result"]["tabs"] = [t for t in d["result"]["tabs"] if t["tab_id"] != tid]
json.dump(d, open(p, "w"))
' ;;
  "agent list")     printf '{"result":{"agents":[]}}\n' ;;
esac
exit 0
STUB
chmod +x "$BIN/gh" "$BIN/herdr"

# ── the TICK child: one whole watcher lifetime, from `source` to death ───────────────────────────
# MODE=merge  → run the shipped do_merge, optionally dying after a named post-merge hook.
# MODE=sweep  → run the shipped _sweep_merged_prs (the next watcher's cadence pass).
# Each runs in a FRESH process: a crashed merge and the sweep that follows share nothing but the disk.
cat > "$ART/tick.sh" <<'CHILD'
#!/usr/bin/env bash
set -uo pipefail
export AGENT_WATCH_LIB=1
# shellcheck source=/dev/null
. "$WATCH_SH" || { echo "SOURCE-FAIL"; exit 2; }

MAIN="$SIM_MAIN"; TREES="$SIM_TREES"; SELF_WT="$SIM_MAIN/.self"
STATE="$TREES/.agent-watch-merged"
RECONCILE_STATE="$TREES/.agent-watch-reconciled"
APPROVALS="$TREES/.agent-watch-approvals"
CI_CHECKS_STATE="$TREES/.agent-watch-ci-checks"
TRACKER_SWEEP_LEDGER="$TREES/.agent-watch-tracker-swept"
POSTMERGE_SWEPT_LEDGER="$TREES/.agent-watch-postmerge-swept"
DEFAULT_BRANCH="main"; DRYRUN=""; WORKSPACE_NAME="simws"; export WORKSPACE_NAME
export HERD_DISPOSABLE_WORKSPACE=1  # sim creates/tears down its own stub tabs (HERD-310 guard)

# The scribe drainer is out of scope: log the enqueue instead of spawning it. ($HERE is read at call
# time by reconcile_backlog, so redirecting it after sourcing captures every enqueue.)
HERE="$SIM_STUB_HERD"
# The map refreshes are a different invariant (HERD-218) and would need a remote; silence them.
refresh_codemap() { :; }
refresh_symbol_index() { :; }
main_health_tick() { :; }

# crash_after <fn> — run the shipped <fn>, then die. Simulates `kill -9` landing between two post-merge
# hooks: the hook's effect is durable on disk, everything after it never happened. The engine carries
# no crash seam; the wrapper is installed HERE, in the sim, by copying the shipped function.
crash_after() {
  eval "$(declare -f "$1" | sed "1s/^$1/__orig_$1/")"
  eval "$1() { __orig_$1 \"\$@\"; exit 9; }"
}

if [ "${MODE:-sweep}" = merge ]; then
  case "${CRASH_AFTER:-none}" in
    # The merge lands and the $STATE row goes down record-first; the very first hook then dies. This is
    # the 17-PR incident: ledgered as merged, so no later tick ever retried it.
    before-hooks)    purge_pr_approvals() { exit 9; } ;;
    after-purges)    crash_after purge_pr_ci_checks ;;
    after-reconcile) crash_after reconcile_backlog ;;
    none) : ;;
  esac
  do_merge "$SIM_SLUG" "$SIM_PR" "$TREES/$SIM_SLUG" "$SIM_SHA"
  exit $?
fi

_sweep_merged_prs
printf 'SWEPT %s\n' "$(awk -v p="$SIM_PR" '$2==p{print $3}' "$POSTMERGE_SWEPT_LEDGER" 2>/dev/null | tr '\n' ',' | sed 's/,$//')"
CHILD

# tick <scenario-dir> <slug> <sha> <mode> [crash-point] — one watcher lifetime.
tick() {
  local scn="$1" slug="$2" sha="$3" mode="$4" crash="${5:-none}"
  PATH="$BIN:$PATH" \
  WATCH_SH="$WATCH" SIM_MAIN="$scn/main" SIM_TREES="$scn/trees" SIM_SLUG="$slug" \
  SIM_SHA="$sha" SIM_PR="$PR" SIM_STUB_HERD="$scn/herd-stub" \
  GH_DIR="$scn/gh" HERDR_TABS="$scn/tabs.json" HERD_CONFIG_FILE="$scn/no-config" \
  JOURNAL_FILE="$scn/journal.jsonl" HERD_TRANSCRIPT_ROOT="$scn/transcripts" \
  MODE="$mode" CRASH_AFTER="$crash" HERD_DISPOSABLE_WORKSPACE=1 \
    bash "$ART/tick.sh" 2>/dev/null
}

# fixture <scenario-dir> <slug> [dirty] — a real repo + worktree + tab + the PR-keyed gate residue a
# merged PR leaves behind. Echoes the worktree's HEAD sha (the merged PR's headRefOid).
fixture() {
  local scn="$1" slug="$2" mode="${3:-}"
  local main="$scn/main" trees="$scn/trees"
  mkdir -p "$main" "$trees" "$scn/gh" "$scn/herd-stub"
  git -C "$main" init -q -b main
  git -C "$main" config user.email sim@sim; git -C "$main" config user.name sim
  echo base > "$main/file.txt"
  git -C "$main" add -A; git -C "$main" -c commit.gpgsign=false commit -qm base

  git -C "$main" worktree add -q -b "feat/$slug" "$trees/$slug" main
  echo "the feature" > "$trees/$slug/file.txt"
  git -C "$trees/$slug" -c user.email=sim@sim -c user.name=sim -c commit.gpgsign=false commit -qam "$slug"
  local sha; sha="$(git -C "$trees/$slug" rev-parse HEAD)"

  # What `gh pr list --state merged` will report once the PR is merged.
  printf '[{"number":%s,"headRefOid":"%s","headRefName":"feat/%s"}]\n' "$PR" "$sha" "$slug" > "$scn/gh/merged.json"
  printf 'Implements the thing.\n\nRefs: HERD-232\n' > "$scn/gh/body.txt"

  # The scribe stub: one line per reconcile enqueue.
  cat > "$scn/herd-stub/scribe.sh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$1" >> "$scn/scribe.log"
STUB
  chmod +x "$scn/herd-stub/scribe.sh"
  : > "$scn/scribe.log"

  # A builder tab, and the registry that allowlists it for teardown.
  printf '{"result":{"tabs":[{"tab_id":"t-build","label":"%s","workspace_id":"ws1"}]}}\n' "$slug" > "$scn/tabs.json"
  printf '%s t-build 0\n' "$slug" > "$trees/.herd-tabs"

  # PR-keyed ledger residue the merge is supposed to purge: a phantom "awaiting approval" row and a
  # terminal CI check event. Plus a DIFFERENT, still-open PR's rows, which must survive untouched.
  printf '%s awaiting %s %s\n' "$(date +%s)" "$PR" "$sha" >  "$trees/.agent-watch-approvals"
  printf '%s awaiting 999 cafe\n' "$(date +%s)"           >> "$trees/.agent-watch-approvals"
  printf '%s %s failure macos\n' "$PR" "$sha"             >  "$trees/.agent-watch-ci-checks"
  printf '999 cafe success linux\n'                       >> "$trees/.agent-watch-ci-checks"

  [ "$mode" = dirty ] && echo "work a human has not committed" >> "$trees/$slug/file.txt"
  printf '%s' "$sha"
}

# residue <scenario-dir> <slug> — every obligation still outstanding, named. Empty ⇒ converged.
residue() {
  local scn="$1" slug="$2" out="" t="$scn/trees"
  awk -v p="$PR" '$2==p{f=1} END{exit !f}' "$t/.agent-watch-merged" 2>/dev/null || out="${out}state_row "
  awk -v p="$PR" '$2==p{f=1} END{exit !f}' "$t/.agent-watch-reconciled" 2>/dev/null || out="${out}reconcile "
  awk -v p="$PR" '$3==p{f=1} END{exit !f}' "$t/.agent-watch-approvals" 2>/dev/null && out="${out}approvals "
  awk -v p="$PR" '$1==p{f=1} END{exit !f}' "$t/.agent-watch-ci-checks" 2>/dev/null && out="${out}ci_checks "
  [ -d "$t/$slug" ] && out="${out}worktree "
  grep -q "\"label\":\"$slug\"" "$scn/tabs.json" 2>/dev/null && out="${out}tab "
  printf '%s' "$out"
}

# live_pr_intact <scenario-dir> — the OTHER, still-open PR's gate ledgers must never be touched.
live_pr_intact() {
  local t="$1/trees"
  grep -q ' awaiting 999 cafe' "$t/.agent-watch-approvals" 2>/dev/null && \
  grep -q '^999 cafe success linux' "$t/.agent-watch-ci-checks" 2>/dev/null
}

scribe_calls() { [ -s "$1/scribe.log" ] && grep -c . "$1/scribe.log" || echo 0; }
state_rows()   { awk -v p="$PR" '$2==p{n++} END{print n+0}' "$1/trees/.agent-watch-merged" 2>/dev/null; }

# ── PART 1: kill the merge at every post-merge hook; the next sweep must converge ────────────────
step crash "kill the watcher at every post-merge hook — the next sweep pass must converge"
SLUG=postmerge
for crash in none before-hooks after-purges after-reconcile; do
  scn="$ART/scn-$crash"; rm -rf "$scn"; mkdir -p "$scn"
  sha="$(fixture "$scn" "$SLUG")"

  # Tick 1 — the doomed merge. (Its exit status is irrelevant: it was killed.)
  tick "$scn" "$SLUG" "$sha" merge "$crash" >/dev/null 2>&1

  # The merge really landed in every case — that is what makes the stranded hooks unrecoverable today.
  # (No `git log | grep -q`: grep exits on the first hit, git dies of SIGPIPE, and under `pipefail` the
  # pipeline reports 141 — an assertion that fails on the SUCCESS path. Substitute + case instead.)
  case "$(git -C "$scn/main" log --oneline 2>/dev/null)" in
    *"merge #$PR"*) : ;;
    *) bad "crash=$crash → the fixture merge did not land; the scenario is invalid"; continue ;;
  esac

  # Tick 2 — a brand-new watcher process running only the cadence sweep. This is the whole claim.
  tick "$scn" "$SLUG" "$sha" sweep >/dev/null

  res="$(residue "$scn" "$SLUG")"
  if [ -n "$res" ]; then
    bad "crash=$crash → the sweep did NOT converge; still outstanding: $res"
  elif [ "$(state_rows "$scn")" -ne 1 ]; then
    bad "crash=$crash → \$STATE carries $(state_rows "$scn") merge rows for PR #$PR (want exactly 1)"
  elif [ "$(scribe_calls "$scn")" -ne 1 ]; then
    bad "crash=$crash → $(scribe_calls "$scn") reconcile enqueues (want exactly 1 — the hook is at-most-once)"
  else
    ok "crash=$crash → the next sweep discharged every obligation (row, reconcile, purges, reap, tab)"
  fi

  live_pr_intact "$scn" \
    && ok "crash=$crash → the live open PR's gate ledgers survive untouched" \
    || bad "crash=$crash → the sweep ate a live PR's approval/CI rows"

  # Tick 3 — a converged world is a FIXED POINT: nothing re-runs, nothing is re-enqueued.
  jbefore="$(grep -c . "$scn/journal.jsonl" 2>/dev/null || echo 0)"
  tick "$scn" "$SLUG" "$sha" sweep >/dev/null
  jafter="$(grep -c . "$scn/journal.jsonl" 2>/dev/null || echo 0)"
  if [ "$jbefore" = "$jafter" ] && [ "$(state_rows "$scn")" -eq 1 ] && [ "$(scribe_calls "$scn")" -eq 1 ]; then
    ok "crash=$crash → re-running the sweep over a converged world is byte-inert"
  else
    # BRACE the names (HERD-260): macOS bash 3.2 under a UTF-8 locale folds the bytes of a following
    # multibyte char into the identifier, so an UNBRACED name butted straight against the arrow below
    # would read as an unset variable and `set -u` would kill the script with "unbound variable" —
    # replacing this diagnostic exactly when it is needed. tests/test-bash32-brace-multibyte.sh lints
    # for it repo-wide (and greps source text, so do not spell the hazard out literally here).
    bad "crash=$crash → the sweep is not a fixed point (journal ${jbefore}→${jafter}, rows $(state_rows "$scn"), enqueues $(scribe_calls "$scn"))"
  fi
done

# ── PART 2: a FOREIGN merge — our do_merge never ran at all ──────────────────────────────────────
step foreign "another seat (or the gh UI) merged the PR; our seat ran no hooks whatsoever"
scn="$ART/scn-foreign"; rm -rf "$scn"; mkdir -p "$scn"
sha="$(fixture "$scn" "$SLUG")"
# The foreign merge: raw git, no do_merge, no ledger row. `gh` now reports the PR MERGED.
git -C "$scn/main" merge -q --no-ff -m "merge #$PR" "feat/$SLUG"
: > "$scn/gh/merged"

[ -z "$(awk -v p="$PR" '$2==p{print}' "$scn/trees/.agent-watch-merged" 2>/dev/null)" ] \
  && ok "precondition: our seat has NO merge row for the foreign merge" \
  || bad "precondition failed: a merge row exists before the sweep"

tick "$scn" "$SLUG" "$sha" sweep >/dev/null
res="$(residue "$scn" "$SLUG")"
[ -z "$res" ] && ok "the sweep discharged every one of OUR obligations for a merge we never performed" \
              || bad "the foreign merge left obligations outstanding: $res"
[ "$(scribe_calls "$scn")" -eq 1 ] && ok "the backlog reconcile ran exactly once" \
                                   || bad "expected 1 reconcile enqueue, got $(scribe_calls "$scn")"
grep -q '"event":"postmerge_reconciled"' "$scn/journal.jsonl" 2>/dev/null \
  && ok "the reconcile is journaled (postmerge_reconciled) — never a silent correction" \
  || bad "the sweep did not journal postmerge_reconciled"
grep -q '"event":"merge_observed".*"reason":"reconcile"' "$scn/journal.jsonl" 2>/dev/null \
  && ok "the observed merge carries an honest provenance (merge_observed, reason=reconcile)" \
  || bad "the reconciled merge is not journaled as merge_observed/reason=reconcile"
# THE MERGE⇒REAP INVARIANT (review BLOCK). journal-audit.sh rule (a) treats every `merge` event as a
# claim that this seat owes a later `reap`. Here the sweep DID reap, so a bare `merge` would happen to
# be satisfiable — but the event must still not be emitted, because the identical code path serves the
# worktree-less foreign merge where no reap can ever exist. Assert the absence directly.
grep -q '"event":"merge"[,}]' "$scn/journal.jsonl" 2>/dev/null \
  && bad "the sweep journaled a bare 'merge' event — it would assert a reap obligation it may not own" \
  || ok "the sweep never emits a bare 'merge' event (the merge⇒reap invariant stays honest)"
live_pr_intact "$scn" && ok "the live open PR's gate ledgers survive untouched" \
                      || bad "the sweep ate a live PR's approval/CI rows"

# ── PART 2b: the REAL journal auditor must not flag the reconciled foreign merge ─────────────────
# HERD-238's journal-audit.sh check (a) is literally "a `merge` event with no LATER `reap` for the same
# pr/slug, past the grace window". A foreign merge has no worktree here, so the sweep can never emit a
# reap for it. If the sweep journaled `merge`, this seat's own auditor would raise a permanent,
# self-healing-proof `merge_without_reap` finding for exactly the PRs the sweep exists to serve — the
# two halves of the engine contradicting each other. Drive the SHIPPED auditor, not a re-implementation.
step audit "the shipped journal auditor agrees with the sweep (no phantom merge_without_reap)"
# _audit <scenario-dir> → how many merge_without_reap findings the SHIPPED auditor raises.
# The auditor reports through the operator inbox + journal (its stdout is only a one-line tally), so
# read the inbox. Fresh inbox + seen-ledger each call: the dedup ledger would suppress a repeat finding.
_audit() {
  local s="$1" now
  now="$(python3 -c 'import time; print(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time()+3600)))')"
  rm -f "$s/inbox" "$s/audit-seen"
  JOURNAL_AUDIT=on JOURNAL_FILE="$s/journal.jsonl" \
  HERD_JOURNAL_AUDIT_NOW="$now" \
  HERD_JOURNAL_AUDIT_INBOX="$s/inbox" HERD_JOURNAL_AUDIT_SEEN="$s/audit-seen" \
  WORKTREES_DIR="$s/trees" \
    bash "$HERE/../journal-audit.sh" >/dev/null 2>&1 || true
  grep -c 'audit:merge_without_reap' "$s/inbox" 2>/dev/null || printf '0'
}
[ "$(_audit "$scn")" -eq 0 ] \
  && ok "the auditor raises NO merge_without_reap for the reconciled foreign merge" \
  || bad "the auditor flagged the foreign merge as a stranded merge — the sweep mislabels engine state"

# CONTROL: the check is not vacuous. Inject a bare `merge` with no reap and the auditor must catch it —
# proving the clean result above comes from an honest event, not from a dead audit rule.
cp "$scn/journal.jsonl" "$scn/journal.jsonl.bak"
printf '{"ts":"%s","event":"merge","pr":9999,"slug":"phantom","sha":"deadbeef","reason":"gates_passed"}\n' \
  "$(python3 -c 'import time; print(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time()-1800)))')" \
  >> "$scn/journal.jsonl"
[ "$(_audit "$scn")" -ge 1 ] \
  && ok "control: a genuine merge-without-reap IS still caught (the rule is live, not vacuous)" \
  || bad "control failed: the auditor no longer catches a real stranded merge"
mv -f "$scn/journal.jsonl.bak" "$scn/journal.jsonl"; rm -f "$scn/audit-seen" "$scn/inbox"

# ── PART 3: the shared hook DEFERS when another seat already handled the tracker item ────────────
step defer "a foreign merge whose tracker ref is already Done — the shared hook must not double-write"
scn="$ART/scn-defer"; rm -rf "$scn"; mkdir -p "$scn"
sha="$(fixture "$scn" "$SLUG")"
git -C "$scn/main" merge -q --no-ff -m "merge #$PR" "feat/$SLUG"
: > "$scn/gh/merged"
# Evidence the other seat's work is already reflected: the tracker sweep confirmed HERD-232 Done.
printf '%s HERD-232 %s\n' "$(date +%s)" "$PR" > "$scn/trees/.agent-watch-tracker-swept"

tick "$scn" "$SLUG" "$sha" sweep >/dev/null
[ "$(scribe_calls "$scn")" -eq 0 ] && ok "the shared hook DEFERRED — no scribe enqueue, no tracker double-write" \
                                   || bad "a handled tracker ref was reconciled again ($(scribe_calls "$scn") enqueues)"
grep -q '"event":"postmerge_deferred".*"evidence":"tracker-swept"' "$scn/journal.jsonl" 2>/dev/null \
  && ok "the deferral is journaled with its evidence — a defer is never silent" \
  || bad "the deferral was not journaled with evidence"
[ "$(state_rows "$scn")" -eq 1 ] && ok "our seat's OWN local obligations still ran (the \$STATE row)" \
                                 || bad "the deferral suppressed this seat's own obligations"
[ ! -d "$scn/trees/$SLUG" ] && ok "…and the worktree was still reaped" \
                            || bad "the deferral suppressed the reap"

# ── PART 4: real dirt is HELD — never reaped, never marked swept ─────────────────────────────────
step hold "a merged worktree carrying uncommitted work is held, and the reap is retried"
scn="$ART/scn-dirty"; rm -rf "$scn"; mkdir -p "$scn"
sha="$(fixture "$scn" "$SLUG" dirty)"
git -C "$scn/main" merge -q --no-ff -m "merge #$PR" "feat/$SLUG"
: > "$scn/gh/merged"

rep="$(tick "$scn" "$SLUG" "$sha" sweep)"
[ -d "$scn/trees/$SLUG" ] && ok "the dirty worktree survives" || bad "a dirty merged worktree was reaped — WORK LOST"
grep -q 'has not committed' "$scn/trees/$SLUG/file.txt" 2>/dev/null \
  && ok "the uncommitted work survives verbatim" || bad "the uncommitted work did not survive"
grep -q '"event":"postmerge_reap_skip".*"reason":"dirty-worktree"' "$scn/journal.jsonl" 2>/dev/null \
  && ok "the hold is journaled with its reason — never a silent skip" \
  || bad "the held reap was not journaled"
case "$rep" in
  *"SWEPT $sha"*) bad "a held worktree was marked run-once — the reap would never be retried" ;;
  *)              ok "the PR is NOT marked swept, so a later pass retries the reap" ;;
esac
# The non-worktree obligations still ran this pass — a held reap does not block the rest.
[ "$(state_rows "$scn")" -eq 1 ] && ok "the other obligations ran despite the held reap" \
                                 || bad "a held reap blocked the \$STATE row"

# ── PART 5: the reap anchor is the COMMIT, never the slug ────────────────────────────────────────
step anchor "a re-spawned worktree on the merged PR's slug is never reaped (sha anchor, not name)"
scn="$ART/scn-respawn"; rm -rf "$scn"; mkdir -p "$scn"
sha="$(fixture "$scn" "$SLUG")"
git -C "$scn/main" merge -q --no-ff -m "merge #$PR" "feat/$SLUG"
: > "$scn/gh/merged"
# The coordinator re-spawned the SAME slug for a follow-up: a new commit, not yet in any PR. The merged
# PR's headRefOid no longer matches this worktree's HEAD — and a slug-keyed reap would destroy it.
echo "the follow-up nobody has pushed yet" >> "$scn/trees/$SLUG/file.txt"
git -C "$scn/trees/$SLUG" -c user.email=sim@sim -c user.name=sim -c commit.gpgsign=false commit -qam followup
newsha="$(git -C "$scn/trees/$SLUG" rev-parse HEAD)"

tick "$scn" "$SLUG" "$sha" sweep >/dev/null
[ -d "$scn/trees/$SLUG" ] && ok "the re-spawned worktree survives (its HEAD is not the merged sha)" \
                          || bad "a live re-spawned worktree was reaped — WORK LOST"
[ "$(git -C "$scn/trees/$SLUG" rev-parse HEAD 2>/dev/null)" = "$newsha" ] \
  && ok "its follow-up commit is untouched" || bad "the follow-up commit was lost"
[ "$(state_rows "$scn")" -eq 1 ] && ok "the merged PR's other obligations still ran" \
                                 || bad "the live worktree blocked the merge row"

step done "scorecard"
info "artifacts: $ART"
printf '  %s%s passed%s · %s%s failed%s\n' "$c_grn" "$PASS" "$c_rst" \
  "$([ "$FAIL" -gt 0 ] && printf '%s' "$c_red" || printf '%s' "$c_dim")" "$FAIL" "$c_rst"
[ "$FAIL" -eq 0 ] && { echo "ALL PASS ($PASS checkpoints)"; exit 0; }
exit 1
