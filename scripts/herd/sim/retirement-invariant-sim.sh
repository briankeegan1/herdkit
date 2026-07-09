#!/usr/bin/env bash
# scripts/herd/sim/retirement-invariant-sim.sh — the RESTART-PROOF proof for HERD-164.
#
# The claim retirement.sh makes is strong: teardown is an INVARIANT, not an event, so killing the
# watcher at ANY point in the teardown is harmless — the next tick of the next watcher observes the
# world, sees what still exists, and finishes the job. A claim like that is only worth what its
# adversary proves. This sim IS the adversary.
#
# For each teardown STEP the reconciler performs, it:
#   1. builds a fresh fixture — a real git repo, a real worktree on a real branch, a stub herdr
#      carrying the builder tab + its review tab (and an agent that, as under real herdr, lives and
#      dies with its tab), a tab registry, and a spread of per-slug ledger files;
#   2. MERGES the fixture PR (a real merge into main; the stub `gh` reports MERGED at the worktree's
#      exact HEAD sha, so the sha anchor is genuine);
#   3. runs ONE watcher tick in a child process that is KILLED mid-teardown, immediately after that
#      step — the crash-between-steps window that made HERD-91's startup sweep necessary;
#   4. runs the NEXT tick in a brand-new process (a restarted watcher, zero inherited memory) and
#      asserts it converges to ZERO leftovers: no worktree, no tab, no agent, no branch, no ledger.
#
# Crash points, in teardown order (`none` is the uncrashed control):
#   none · before-teardown · after-reap · after-registry-prune · after-branch-delete · after-ledger-purge
#
# Then the SAFETY half: a fixture whose merged worktree carries REAL dirt (a modified TRACKED file)
# must be HELD — worktree, dirt, branch, and tab all intact after a tick, a loud `retire_hold` in the
# journal, and a needs-you row naming the file. Retirement never destroys work it cannot prove
# disposable, and never silently skips it either.
#
# Hermetic: a local git repo, stub `gh` + stub `herdr` on PATH. NO network, NO model, NO real tab, and
# it never touches the operator's control room. Run:
#   bash scripts/herd/sim/retirement-invariant-sim.sh [--artifacts DIR] [--keep]
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

# ── stub binaries (NETWORK-FREE, and no real herdr can ever be reached) ──────────────────────────
BIN="$ART/bin"; mkdir -p "$BIN"

# gh: `gh pr view <branch> --json … -q …` → the stored "STATE\toid\tnumber" for that branch.
#     `gh pr list …` → an empty array (no OPEN PRs in this world).
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "view" ]; then
  f="$GH_DIR/$(printf '%s' "${3:-}" | tr '/' '%')"
  [ -f "$f" ] && cat "$f"
  exit 0
fi
[ "${1:-}" = "pr" ] && [ "${2:-}" = "list" ] && printf '[]\n'
exit 0
STUB

# herdr: a tab registry in one JSON file. `tab close` removes a tab. `agent list` DERIVES the roster
# from the tabs — a builder agent lives in its tab and dies with it, exactly as under real herdr — so
# the sim never has to hand-wave the agent leftover away.
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
  "agent list")     python3 -c '
import json, os
d = json.load(open(os.environ["HERDR_TABS"]))
ags = [{"name": t["label"], "agent_status": "idle"}
       for t in d["result"]["tabs"] if "·" not in t["label"]]
print(json.dumps({"result": {"agents": ags}}))
' ;;
esac
exit 0
STUB
chmod +x "$BIN/gh" "$BIN/herdr"

# ── the TICK child: a whole watcher lifetime, from `source` to death ─────────────────────────────
# Every scenario runs this in a FRESH process. That is what makes the restart real: a crashed tick and
# the tick that follows it share nothing but the filesystem — which is precisely the invariant's claim.
#
# CRASH_AFTER names the teardown step after which the process dies (SIGKILL-equivalent: `exit 9` from
# inside the reconciler, before it can do anything else). The wrappers are installed HERE, in the sim,
# by copying the shipped function and appending the death — the engine carries no crash seam.
cat > "$ART/tick.sh" <<'CHILD'
#!/usr/bin/env bash
set -uo pipefail
export AGENT_WATCH_LIB=1
# shellcheck source=/dev/null
. "$WATCH_SH" || { echo "SOURCE-FAIL"; exit 2; }
MAIN="$SIM_MAIN"; TREES="$SIM_TREES"; SELF_WT="$SIM_MAIN/.self"; STATE="$TREES/.agent-watch-merged"
DEFAULT_BRANCH="main"; DRYRUN=""; PRS_JSON='[]'; WORKSPACE_NAME="simws"
# The branch is one of the five leftovers this sim asserts converge to zero, and it only converges when
# the operator's policy says a landed branch should go away. (The retain-by-default policy is proven in
# the unit suite instead, where the branch must survive AND not count as a leftover.)
DELETE_BRANCH_ON_MERGE="${SIM_DELETE_BRANCH:-true}"
export WORKSPACE_NAME

# crash_after <fn> — run the shipped <fn>, then die. Simulates `kill -9` landing between two teardown
# steps: the step's effect is durable on disk, the steps after it never happened.
crash_after() {
  eval "$(declare -f "$1" | sed "1s/^$1/__orig_$1/")"
  eval "$1() { __orig_$1 \"\$@\"; exit 9; }"
}
case "${CRASH_AFTER:-none}" in
  before-teardown)     retire_converge() { exit 9; } ;;   # the merge landed; teardown never started
  after-reap)          crash_after _reap_slug ;;          # worktree + tabs gone; registry/branch/ledgers not
  after-registry-prune) crash_after _retire_drop_registry_rows ;;
  after-branch-delete) crash_after _retire_delete_branch ;;
  after-ledger-purge)  crash_after clear_dead ;;          # clear_dead runs right after the ledger rm loop
  none) : ;;
esac

retirement_tick

# Machine-readable report for the parent: one STATE line per row this tick would render, then the
# residual leftovers for the slug under test (empty ⇒ converged).
for _i in "${!RETIRE_SLUG[@]}"; do
  printf 'STATE %s %s %s\n' "${RETIRE_SLUG[_i]}" "${RETIRE_STATE[_i]}" "${RETIRE_DETAIL[_i]}"
done
printf 'LEFT %s\n' "$(retire_leftovers "$SIM_SLUG" "$TREES/$SIM_SLUG" "feat/$SIM_SLUG" | tr '\n' ',' | sed 's/,$//')"
CHILD

# tick <scenario-dir> <slug> [crash-point] — one watcher lifetime. Echoes the child's report.
tick() {
  local scn="$1" slug="$2" crash="${3:-none}"
  PATH="$BIN:$PATH" \
  WATCH_SH="$WATCH" SIM_MAIN="$scn/main" SIM_TREES="$scn/trees" SIM_SLUG="$slug" \
  GH_DIR="$scn/gh" HERDR_TABS="$scn/tabs.json" HERD_CONFIG_FILE="$scn/no-config" \
  CRASH_AFTER="$crash" HERD_RETIRE_STUCK_TICKS=3 \
    bash "$ART/tick.sh" 2>/dev/null
}

# fixture <scenario-dir> <slug> <merged|dirty> — a real repo + worktree + tabs + ledgers, with the
# fixture PR already MERGED into main and `gh` reporting MERGED at the worktree's exact HEAD sha.
fixture() {
  local scn="$1" slug="$2" mode="$3"
  local main="$scn/main" trees="$scn/trees"
  mkdir -p "$main" "$trees" "$scn/gh"
  git -C "$main" init -q -b main
  git -C "$main" config user.email sim@sim; git -C "$main" config user.name sim
  echo base > "$main/file.txt"; git -C "$main" add -A; git -C "$main" commit -qm base

  git -C "$main" worktree add -q -b "feat/$slug" "$trees/$slug" main
  echo "the feature" > "$trees/$slug/file.txt"
  git -C "$trees/$slug" -c user.email=sim@sim -c user.name=sim commit -qam "$slug"
  local sha; sha="$(git -C "$trees/$slug" rev-parse HEAD)"

  # MERGE the fixture PR for real, then let `gh` report it MERGED at that exact sha.
  git -C "$main" merge -q --no-ff -m "merge #77" "feat/$slug"
  printf 'MERGED\t%s\t77\n' "$sha" > "$scn/gh/feat%$slug"

  # A stub herdr world: the builder tab, its review tab, and the registry that allowlists them.
  cat > "$scn/tabs.json" <<EOF
{"result":{"tabs":[
  {"tab_id":"t-build","label":"$slug","workspace_id":"ws1"},
  {"tab_id":"t-review","label":"review·$slug","workspace_id":"ws1"}]}}
EOF
  printf '%s t-build 0\nreview·%s t-review 0\n' "$slug" "$slug" > "$trees/.herd-tabs"

  # Per-slug ledger rows the retired slug must not leave behind.
  printf 'HERD-164\n' > "$trees/.herd-ref-$slug"
  : > "$trees/.health-cachehit-$slug"
  : > "$trees/.health-result-$slug-$sha"

  # A SIBLING slug's ledger file — retiring <slug> must never eat it.
  : > "$trees/.health-result-$slug-sibling-$sha"

  if [ "$mode" = dirty ]; then
    echo "work a human has not committed" >> "$trees/$slug/file.txt"
  fi
}

# residue <scenario-dir> <slug> — every artifact that should be gone, named. Empty ⇒ converged.
residue() {
  local scn="$1" slug="$2" out=""
  [ -d "$scn/trees/$slug" ] && out="${out}worktree "
  git -C "$scn/main" show-ref --verify --quiet "refs/heads/feat/$slug" && out="${out}branch "
  grep -q "\"label\":\"$slug\"" "$scn/tabs.json" 2>/dev/null && out="${out}tab "
  grep -q "review·$slug" "$scn/tabs.json" 2>/dev/null && out="${out}review-tab "
  grep -q "$slug" "$scn/trees/.herd-tabs" 2>/dev/null && out="${out}registry "
  [ -e "$scn/trees/.herd-ref-$slug" ] && out="${out}ref-ledger "
  [ -e "$scn/trees/.health-cachehit-$slug" ] && out="${out}health-ledger "
  ls "$scn/trees/.retire-$slug" >/dev/null 2>&1 && out="${out}retire-state "
  printf '%s' "$out"
}

# ── PART 1: kill the watcher at every teardown step; the next tick must converge ─────────────────
step crash "kill/restart the watcher at every teardown step — the next tick must converge"
SLUG=retiree
for crash in none before-teardown after-reap after-registry-prune after-branch-delete after-ledger-purge; do
  scn="$ART/scn-$crash"; rm -rf "$scn"; mkdir -p "$scn"
  fixture "$scn" "$SLUG" merged

  # Tick 1 — the doomed watcher. (Its exit status is irrelevant: it was killed.)
  tick "$scn" "$SLUG" "$crash" >/dev/null

  # Tick 2 — a brand-new watcher process, zero inherited memory. This is the whole claim.
  rep="$(tick "$scn" "$SLUG" none)"
  left="$(printf '%s' "$rep" | sed -n 's/^LEFT //p')"
  res="$(residue "$scn" "$SLUG")"

  if [ -n "$left" ]; then
    bad "crash=$crash → next tick did NOT converge; leftovers: $left"
  elif [ -n "$res" ]; then
    bad "crash=$crash → residue survived teardown: $res"
  elif printf '%s' "$rep" | grep -q "^STATE $SLUG"; then
    bad "crash=$crash → converged but still renders a row: $(printf '%s' "$rep" | sed -n "s/^STATE //p")"
  else
    ok "crash=$crash → next tick converged to zero leftovers (worktree, tab, agent, branch, ledgers)"
  fi

  # The sibling's ledger must be untouched in every scenario — a slug retires only its own state.
  if ls "$scn/trees/.health-result-$SLUG-sibling-"* >/dev/null 2>&1; then
    ok "crash=$crash → sibling slug's ledger untouched"
  else
    bad "crash=$crash → retiring '$SLUG' ate sibling slug '$SLUG-sibling' ledger files"
  fi
done

# Idempotence: a THIRD tick over a fully-converged world must do nothing and say nothing.
scn="$ART/scn-none"
rep="$(tick "$scn" "$SLUG" none)"
if [ "$(printf '%s' "$rep" | sed -n 's/^LEFT //p')" = "" ] && ! printf '%s' "$rep" | grep -q '^STATE '; then
  ok "a converged world is a fixed point — re-running the tick is a no-op"
else
  bad "re-running the tick over a converged world was not a no-op: $rep"
fi

# ── PART 2: real dirt is HELD, loudly — never deleted, never silently skipped ────────────────────
step hold "a merged worktree carrying REAL dirt is held with evidence, not reaped"
scn="$ART/scn-dirty"; rm -rf "$scn"; mkdir -p "$scn"
fixture "$scn" "$SLUG" dirty
rep="$(tick "$scn" "$SLUG" none)"

state="$(printf '%s' "$rep" | sed -n "s/^STATE $SLUG //p" | cut -d' ' -f1)"
[ "$state" = held ] && ok "the row is HELD (not retiring, not 'awaiting task')" \
                     || bad "expected a held row, got: ${state:-<none>}"
[ -d "$scn/trees/$SLUG" ] && ok "the worktree survives" || bad "a dirty worktree was reaped — WORK LOST"
grep -q 'has not committed' "$scn/trees/$SLUG/file.txt" 2>/dev/null \
  && ok "the uncommitted work survives verbatim" || bad "the uncommitted work did not survive"
git -C "$scn/main" show-ref --verify --quiet "refs/heads/feat/$SLUG" \
  && ok "the branch survives" || bad "a held slug's branch was deleted"
grep -q "\"label\":\"$SLUG\"" "$scn/tabs.json" \
  && ok "the tab survives" || bad "a held slug's tab was closed"
printf '%s' "$rep" | grep -q "^STATE $SLUG held .*file.txt" \
  && ok "the row carries the evidence (names the dirty file)" \
  || bad "the held row does not name the dirty file: $rep"

# A second tick must keep holding — the hold is a property of the world, not a one-shot notice.
rep2="$(tick "$scn" "$SLUG" none)"
printf '%s' "$rep2" | grep -q "^STATE $SLUG held" \
  && ok "the hold persists tick over tick (it is an invariant, not a notification)" \
  || bad "the hold vanished on the second tick: $rep2"

step done "scorecard"
info "artifacts: $ART"
printf '  %s%s passed%s · %s%s failed%s\n' "$c_grn" "$PASS" "$c_rst" \
  "$([ "$FAIL" -gt 0 ] && printf '%s' "$c_red" || printf '%s' "$c_dim")" "$FAIL" "$c_rst"
[ "$FAIL" -eq 0 ] && { echo "ALL PASS ($PASS checkpoints)"; exit 0; }
exit 1
