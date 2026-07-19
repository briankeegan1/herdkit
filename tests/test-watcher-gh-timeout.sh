#!/usr/bin/env bash
# test-watcher-gh-timeout.sh — hermetic proof for the watcher's GH AVAILABILITY GUARD (HERD-237).
#
# Grounding (docs/audits/2026-07-09-gating-hardening.md, G4): the whole control room rides ONE tick
# loop, and every `gh` call on it was unbounded. A single `gh` that never returns — a wedged TLS
# handshake, a black-holed proxy — froze merges, gate-status posts, collections and limit-parks
# indefinitely. `_gh_timeout` bounds every one of them.
#
# This locks the load-bearing properties of the shipped wrapper:
#   (1) HEALTHY PATH IS BYTE-IDENTICAL — stdout, stderr and exit status pass through untouched, gh
#       receives the exact argv it received before (the <site> label never reaches it), and NOTHING is
#       journaled. A healthy seat's event stream is unchanged by this feature.
#   (2) gh's OWN non-zero exits (404, rate limit, auth) pass straight through and are NOT journaled as
#       timeouts — they are not availability faults.
#   (3) A HUNG gh is killed at the deadline: rc 124, one `gh_timeout` journal event carrying the site
#       + budget, and NO stdout (never a fabricated success).
#   (4) FAIL-CLOSED AT THE REAL CALL SITES — a hung gh lands in each site's existing gh-failure branch:
#       `_prs_fetch_tick` → PRS_LOOKUP_OK=0 (never "zero open PRs"), `_pr_body` → non-zero rc (never a
#       fabricated "no HUMAN-VERIFY block", which would auto-merge an unverified PR),
#       `_gate_status_blessed` → false (never a fabricated blessing).
#   (5) The tick PROCEEDS: a hung gh costs the budget, not the loop.
#   (6) BUDGET PARSE is fail-safe (empty / 0 / garbage → the 15 s default) and HERD_GH_TIMEOUT_SECS
#       is a test seam, not a config key.
#   (7) DRIFT GUARD — no raw `gh pr` / `gh api` call survives anywhere in agent-watch.sh. A future
#       call site added bare would re-open G4 silently; this makes that a red build.
#
# Fully hermetic: agent-watch.sh sourced in LIB mode (AGENT_WATCH_LIB=1 → helpers only, no loop/re-exec)
# against a temp WORKTREES_DIR and a non-existent config, each case in its own subshell, with a stubbed
# `gh` on PATH. NO herdr, NO network, NO model. Run:  bash tests/test-watcher-gh-timeout.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WATCH="$ROOT/scripts/herd/agent-watch.sh"
GITPR="$ROOT/scripts/herd/work-units/git-pr.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ PASS=$((PASS+1)); echo "PASS $1"; }

[ -f "$WATCH" ] || fail "missing agent-watch.sh at $WATCH"
command -v python3 >/dev/null 2>&1 || fail "python3 required (journal.sh)"

# stub_gh <bindir> <kind> [argvlog] — install a `gh` stub. When <argvlog> is given every invocation
# appends its full argv, so a case can prove exactly what gh was handed.
#   ok     → prints a JSON payload on stdout, exit 0
#   hung   → never returns (exec sleep — the pid the timeout kills is the sleep)
#   stubborn → never returns AND ignores SIGTERM (only SIGKILL ends it)
#   broken → prints to stderr, exit 1 (gh's own failure: a 404, a rate limit, an expired token)
stub_gh() {
  local d="$1" kind="$2" argvlog="${3:-}"
  mkdir -p "$d"
  { printf '#!/usr/bin/env bash\n'
    [ -n "$argvlog" ] && printf 'printf "%%s\\n" "$*" >> %q\n' "$argvlog"
    case "$kind" in
      ok)     printf 'printf %%s "[{\\"number\\":7}]"\nexit 0\n' ;;
      hung)   printf 'exec sleep 30\n' ;;
      stubborn) printf 'trap "" TERM INT\nsleep 30\n' ;;
      broken) printf 'echo "gh: HTTP 404" >&2\nexit 1\n' ;;
    esac
  } > "$d/gh"
  chmod +x "$d/gh"
}

# source_watcher <trees> [GH_TIMEOUT_SECS] — source the REAL watcher in lib mode in the CURRENT shell.
source_watcher() {
  export AGENT_WATCH_LIB=1
  export HERD_CONFIG_FILE="$T/no-such-config"
  export WORKTREES_DIR="$1"
  export JOURNAL_FILE="$1/journal.jsonl"
  [ -n "${2:-}" ] && export HERD_GH_TIMEOUT_SECS="$2"
  mkdir -p "$1" 2>/dev/null || true
  # shellcheck source=/dev/null
  . "$WATCH" || { echo "__SOURCE_FAILED__"; exit 1; }
}
jcount(){ grep -c "$1" "$2" 2>/dev/null || echo 0; }

# ── (1) HEALTHY path: stdout + rc pass through, argv untouched, nothing journaled ──────────────────
(
  WT="$T/healthy"; STUB="$WT/bin"; ARGV="$WT/argv"
  stub_gh "$STUB" ok "$ARGV"; export PATH="$STUB:$PATH"
  source_watcher "$WT" 3

  out="$(_gh_timeout tick_pr_list pr list --json number)"; rc=$?
  [ "$rc" -eq 0 ]                 || { echo "healthy gh rc=$rc, want 0"; exit 1; }
  [ "$out" = '[{"number":7}]' ]   || { echo "stdout not passed through verbatim: '$out'"; exit 1; }
  # The <site> label is a JOURNAL concern; gh must see the argv it saw before the wrapper existed.
  [ "$(cat "$ARGV")" = "pr list --json number" ] \
    || { echo "argv mutated: '$(cat "$ARGV")'"; exit 1; }
  [ -f "$JOURNAL_FILE" ] && grep -q gh_timeout "$JOURNAL_FILE" && { echo "healthy gh journaled a timeout"; exit 1; }
  exit 0
) || fail "(1) the healthy gh path was not a byte-identical passthrough"
ok "(1) healthy gh → stdout + rc verbatim, argv unchanged, no journal event"

# ── (2) gh's OWN failure passes through and is NOT a timeout ───────────────────────────────────────
(
  WT="$T/broken"; STUB="$WT/bin"; stub_gh "$STUB" broken; export PATH="$STUB:$PATH"
  source_watcher "$WT" 3
  out="$(_gh_timeout pr_body pr view 9 --json body 2>/dev/null)"; rc=$?
  [ "$rc" -eq 1 ]  || { echo "gh's own rc not passed through (got $rc, want 1)"; exit 1; }
  [ -z "$out" ]    || { echo "a failed gh produced stdout: '$out'"; exit 1; }
  grep -q gh_timeout "$JOURNAL_FILE" 2>/dev/null && { echo "a gh 404 was journaled as a timeout"; exit 1; }
  exit 0
) || fail "(2) gh's own non-zero exit was mislabelled or swallowed"
ok "(2) gh's own non-zero exit passes through verbatim and is never journaled as a timeout"

# ── (3) HUNG gh → killed at the deadline: rc 124, ONE gh_timeout event, no stdout ──────────────────
(
  WT="$T/hung"; STUB="$WT/bin"; stub_gh "$STUB" hung; export PATH="$STUB:$PATH"
  source_watcher "$WT" 2
  start=$(date +%s)
  out="$(_gh_timeout gate_status_post api repos/o/r/statuses/abc 2>/dev/null)"; rc=$?
  elapsed=$(( $(date +%s) - start ))
  [ "$rc" -eq 124 ] || { echo "hung gh rc=$rc, want 124"; exit 1; }
  [ -z "$out" ]     || { echo "a timed-out gh fabricated stdout: '$out'"; exit 1; }
  # The wall-clock bound is the whole point: the 30 s stub must not have run to completion. Allow a
  # couple of seconds for the TERM→KILL escalation on the pure-shell/perl fallbacks.
  [ "$elapsed" -lt 10 ] || { echo "tick waited ${elapsed}s on a hung gh (budget was 2s)"; exit 1; }
  grep -q '"event":"gh_timeout"'   "$JOURNAL_FILE" || { echo "no gh_timeout event"; exit 1; }
  grep -q '"site":"gate_status_post"' "$JOURNAL_FILE" || { echo "gh_timeout event carries no site label"; exit 1; }
  grep -q '"timeout_secs":2'       "$JOURNAL_FILE" || { echo "gh_timeout event carries no budget"; exit 1; }
  [ "$(jcount '"event":"gh_timeout"' "$JOURNAL_FILE")" = "1" ] || { echo "one call journaled != once"; exit 1; }
  exit 0
) || fail "(3) a hung gh was not bounded, journaled, or was allowed to fabricate output"
ok "(3) hung gh → SIGTERM at the deadline, rc 124, ONE gh_timeout event (site + budget), no stdout"

# ── (3b) a gh that IGNORES SIGTERM is still killed at the deadline ────────────────────────────────
# The perl and pure-shell runners escalate TERM→KILL. coreutils `timeout` sends TERM only unless given
# -k, and that is the branch Linux always takes — a `gh` that traps TERM would re-open the very hang.
(
  WT="$T/stubborn"; STUB="$WT/bin"; stub_gh "$STUB" stubborn; export PATH="$STUB:$PATH"
  source_watcher "$WT" 2
  start=$(date +%s)
  _gh_timeout tick_pr_list pr list >/dev/null 2>&1; rc=$?
  elapsed=$(( $(date +%s) - start ))
  [ "$rc" -ne 0 ]        || { echo "a TERM-ignoring gh returned success"; exit 1; }
  [ "$elapsed" -lt 20 ]  || { echo "a TERM-ignoring gh held the tick ${elapsed}s (budget 2s)"; exit 1; }
  grep -q '"event":"gh_timeout"' "$JOURNAL_FILE" || { echo "no gh_timeout event"; exit 1; }
  exit 0
) || fail "(3b) a gh that ignores SIGTERM was not killed at the deadline"
ok "(3b) a TERM-ignoring gh is escalated to SIGKILL — the coreutils path carries -k when supported"

# ── (4) FAIL-SOFT at the real call sites: a hang lands in the EXISTING gh-failure branch ───────────
(
  WT="$T/failsoft"; STUB="$WT/bin"; stub_gh "$STUB" hung; export PATH="$STUB:$PATH"
  source_watcher "$WT" 2

  # (4a) the tick's PR fetch: an outage must read as "lookup failed", NEVER as "zero open PRs" — the
  # exact HERD-206 collapse (a blind sweep would then reap every live builder as 'died (no PR)').
  PRS_LOOKUP_OK=1; PRS_JSON='x'
  _prs_fetch_tick
  [ "$PRS_LOOKUP_OK" = "0" ] || { echo "hung gh left PRS_LOOKUP_OK=$PRS_LOOKUP_OK (want 0)"; exit 1; }
  [ "$PRS_JSON" = "[]" ]     || { echo "hung gh left PRS_JSON='$PRS_JSON' (want [])"; exit 1; }

  # (4b) the human-verify body read: no body AND a non-zero rc. The rc is the load-bearing half — an
  # empty body with rc 0 would mean "this PR declares no HUMAN-VERIFY steps" and auto-merge it.
  body="$(_pr_body 12)" && { echo "_pr_body reported SUCCESS on a hang (auto-merge bypass)"; exit 1; }
  [ -z "$body" ] || { echo "_pr_body fabricated a body on a hang"; exit 1; }
  pr_human_verify_held 12; [ "$?" -eq 2 ] || { echo "pr_human_verify_held must report UNKNOWN(2) on a hang"; exit 1; }

  # (4c) the cross-seat blessing: a hang must NOT read as "blessed" (that would skip both gates).
  _gate_status_blessed abc123 && { echo "a hung gh blessed a sha"; exit 1; }

  # (4d) the startup reap sweep: a hang must never yield a reapable "MERGED + sha match" verdict.
  read -r st _ <<<"$(_srs_gh_view feat/x)"
  [ "$st" != "MERGED" ] || { echo "a hung gh produced a MERGED reap verdict"; exit 1; }

  # Every one of those sites journaled its own labelled timeout — the audit trail the incident needed.
  for site in tick_pr_list pr_body gate_status_blessed startup_reap_view; do
    grep -q "\"site\":\"$site\"" "$JOURNAL_FILE" || { echo "no gh_timeout for site=$site"; exit 1; }
  done
  exit 0
) || fail "(4) a hung gh did not land in the existing fail-soft path at some call site"
ok "(4) hung gh → each site FAILS CLOSED (no fabricated PR list / body / blessing / reap)"

# ── (4e) HONEST LABELS: an unreadable merge is never a fabricated success/moved state ──────────────
# The bash merge re-verify that carried this (merge_reverify_unreadable, ordered before the 'no longer
# maps' red row) lived in the action pass (_tick_act), DELETED at the P5 cutover (HERD-306). The Python
# live engine now owns the merge: on an unreadable gh it FAILS CLOSED — journals merge_gh_unreadable and
# returns False (no merge, no fabricated moved/merged row), the same honest-labels invariant.
PYLIVE="$(cd "$(dirname "$WATCH")/../.." && pwd)/pysrc/herd/live_runtime.py"
grep -q 'merge_gh_unreadable' "$PYLIVE" \
  || fail "(4e) the Python merge does not distinguish an unreadable gh (must journal merge_gh_unreadable, fail closed)"
python3 - "$PYLIVE" <<'PY' || fail "(4e) the unreadable-gh merge branch must journal then FAIL CLOSED (return False), never fabricate a merge"
import sys
s = open(sys.argv[1]).read()
i = s.index('merge_gh_unreadable')
# the very next non-trivial thing on that branch is a fail-closed `return False` (no merge)
sys.exit(0 if 'return False' in s[i:i+200] else 1)
PY
ok "(4e) an unreadable gh read journals merge_gh_unreadable and fails closed — no fabricated merge/moved row"

# ── (5) HEALTHY tick fetch is byte-identical: lookup OK, payload verbatim, journal silent ──────────
(
  WT="$T/healthy-tick"; STUB="$WT/bin"; stub_gh "$STUB" ok; export PATH="$STUB:$PATH"
  source_watcher "$WT" 3
  PRS_LOOKUP_OK=0; PRS_JSON=''
  _prs_fetch_tick
  [ "$PRS_LOOKUP_OK" = "1" ]    || { echo "healthy fetch did not set PRS_LOOKUP_OK=1"; exit 1; }
  [ "$PRS_JSON" = '[{"number":7}]' ] || { echo "healthy fetch mangled the payload: '$PRS_JSON'"; exit 1; }
  [ -f "$JOURNAL_FILE" ] && [ -s "$JOURNAL_FILE" ] && { echo "healthy tick journaled: $(cat "$JOURNAL_FILE")"; exit 1; }
  exit 0
) || fail "(5) the healthy tick fetch was not byte-identical"
ok "(5) healthy tick fetch → PRS_LOOKUP_OK=1, payload verbatim, journal untouched"

# ── (6) budget parse is fail-safe; the seam is an env var, not a config key ────────────────────────
(
  WT="$T/budget"; source_watcher "$WT"
  unset HERD_GH_TIMEOUT_SECS
  [ "$(_gh_timeout_secs)" = "15" ] || { echo "unset → $(_gh_timeout_secs), want 15"; exit 1; }
  for bad in "" 0 garbage 3x; do
    [ "$(HERD_GH_TIMEOUT_SECS="$bad" _gh_timeout_secs)" = "15" ] \
      || { echo "'$bad' did not fall back to the 15s default"; exit 1; }
  done
  [ "$(HERD_GH_TIMEOUT_SECS=7 _gh_timeout_secs)" = "7" ] || { echo "a valid override was ignored"; exit 1; }
  exit 0
) || fail "(6) the timeout budget did not parse fail-safe"
ok "(6) budget: unset/0/garbage → 15s default; a positive integer overrides (test seam, no config key)"

# HERD_GH_TIMEOUT_SECS is deliberately NOT a config key — a hung network call is not a policy choice.
grep -q 'HERD_GH_TIMEOUT_SECS' "$ROOT/scripts/herd/herd-config.sh" \
  && fail "(6) HERD_GH_TIMEOUT_SECS leaked into herd-config.sh — the budget must stay inline"
ok "(6b) HERD_GH_TIMEOUT_SECS is not a config key (the budget stays inline in the watcher)"

# ── (7) DRIFT GUARD: every gh call in the watcher (+ the git-pr work-unit adapter, HERD-398 — the
# merge/list/view/diff calls this guard was written to police now live there, not in agent-watch.sh)
# goes through the wrapper. A bare `gh pr …` / `gh api …` added later would silently re-open G4. Scan
# executable lines only (comments and string literals such as the builder's task-spec pointer are not
# call sites).
RAW="$(grep -nHE '(^|[^_[:alnum:]])gh[[:space:]]+(pr|api)[[:space:]]' "$WATCH" "$GITPR" \
        | grep -v '_gh_timeout' \
        | grep -vE '^[^:]*:[0-9]+:[[:space:]]*#' \
        | grep -vE ':[^#]*#.*gh[[:space:]]+(pr|api)' \
        | grep -vE 'Read the full review|herd pr create|gh pr create' || true)"
[ -z "$RAW" ] || fail "(7) unwrapped gh call(s) on the tick path — every one must go through _gh_timeout:
$RAW"
ok "(7) drift guard: no raw 'gh pr' / 'gh api' call survives in agent-watch.sh or work-units/git-pr.sh"

echo "ALL PASS ($PASS checks) — test-watcher-gh-timeout.sh"
