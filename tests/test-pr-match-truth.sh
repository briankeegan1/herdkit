#!/usr/bin/env bash
# test-pr-match-truth.sh — hermetic tests for HERD-224 row truth on PR-match failures.
#
# GROUNDED: a failed `gh pr list` used to collapse into `[]` via `|| echo '[]'`, so a builder that
# HAD an open PR rendered "💤 <slug> awaiting task · assign or retire" — a definitive "no work ·
# assign or retire" claim from a lookup FAILURE. The fix distinguishes:
#   • PR-lookup FAILED/errored  → neutral "PR match pending · retrying" (never "awaiting task")
#   • SUCCESSFUL list with no matching PR → the closed-vocabulary awaiting-task row (positive empty)
#
# Sources agent-watch.sh in lib mode (AGENT_WATCH_LIB=1). NETWORK-FREE (stubbed gh on PATH).
# Run:  bash tests/test-pr-match-truth.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../scripts/herd/agent-watch.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

[ -f "$WATCH" ] || fail "missing $WATCH"
command -v python3 >/dev/null 2>&1 || fail "python3 required"

# ── stub gh on PATH: exit status + body controlled by GH_PR_LIST_RC / GH_PR_LIST_JSON ─────────────
BIN="$T/bin"; mkdir -p "$BIN"
cat > "$BIN/gh" << 'STUB'
#!/usr/bin/env bash
# Only `pr list` is exercised by _prs_fetch_tick; anything else is a no-op success.
case "$*" in
  *"pr list"*)
    cat "${GH_PR_LIST_JSON:-/dev/null}" 2>/dev/null || true
    exit "${GH_PR_LIST_RC:-0}"
    ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$BIN/gh"
for cmd in git herdr; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$cmd"; chmod +x "$BIN/$cmd"
done
export PATH="$BIN:$PATH"

export AGENT_WATCH_LIB=1
export WORKTREES_DIR="$T/trees"; mkdir -p "$T/trees"
export HERD_CONFIG_FILE="$T/no-such-config"
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"

type _prs_fetch_tick >/dev/null 2>&1 || fail "_prs_fetch_tick not defined"
type _row_pr_match_pending >/dev/null 2>&1 || fail "_row_pr_match_pending not defined"
type _row_awaiting_task >/dev/null 2>&1 || fail "_row_awaiting_task not defined"

# ── (1) failed gh pr list → PRS_LOOKUP_OK=0, never a positive empty roster ────────────────────────
export GH_PR_LIST_RC=1
export GH_PR_LIST_JSON="$T/empty.json"
printf '[]' > "$GH_PR_LIST_JSON"   # body may be empty-or-junk on failure; rc is what matters
unset PRS_JSON PRS_LOOKUP_OK
_prs_fetch_tick
[ "${PRS_LOOKUP_OK:-}" = "0" ] || fail "(1) failed gh must set PRS_LOOKUP_OK=0, got: ${PRS_LOOKUP_OK:-unset}"
[ "$PRS_JSON" = "[]" ] || fail "(1) failed gh must leave PRS_JSON as safe [], got: $PRS_JSON"
ok

# ── (2) successful empty list → PRS_LOOKUP_OK=1 (positive: genuinely no open PRs) ─────────────────
export GH_PR_LIST_RC=0
printf '[]' > "$GH_PR_LIST_JSON"
unset PRS_JSON PRS_LOOKUP_OK
_prs_fetch_tick
[ "${PRS_LOOKUP_OK:-}" = "1" ] || fail "(2) successful empty list must set PRS_LOOKUP_OK=1, got: ${PRS_LOOKUP_OK:-unset}"
[ "$PRS_JSON" = "[]" ] || fail "(2) successful empty list must yield [], got: $PRS_JSON"
ok

# ── (3) successful list with a PR → PRS_LOOKUP_OK=1 and the PR is preserved ───────────────────────
export GH_PR_LIST_RC=0
printf '[{"number":328,"title":"x","headRefName":"feat/retirement-invariant","headRefOid":"abc","mergeable":"CONFLICTING","mergeStateStatus":"DIRTY"}]' \
  > "$GH_PR_LIST_JSON"
unset PRS_JSON PRS_LOOKUP_OK
_prs_fetch_tick
[ "${PRS_LOOKUP_OK:-}" = "1" ] || fail "(3) successful list must set PRS_LOOKUP_OK=1, got: ${PRS_LOOKUP_OK:-unset}"
printf '%s' "$PRS_JSON" | python3 -c 'import sys,json; d=json.load(sys.stdin); assert any(p.get("number")==328 for p in d)' \
  || fail "(3) successful list must retain the open PR, got: $PRS_JSON"
ok

# ── (4) degraded row never says "awaiting task"; genuine spare does ───────────────────────────────
WT="$T/wt-spare"; mkdir -p "$WT"
pending="$(_row_pr_match_pending "retirement-invariant")"
printf '%s' "$pending" | grep -q 'PR match pending · retrying' \
  || fail "(4) degraded row missing 'PR match pending · retrying', got: $pending"
printf '%s' "$pending" | grep -q 'awaiting task' \
  && fail "(4) degraded row must NEVER say 'awaiting task', got: $pending"
printf '%s' "$pending" | grep -q 'assign or retire' \
  && fail "(4) degraded row must NEVER say 'assign or retire', got: $pending"
printf '%s' "$pending" | grep -q 'retirement-invariant' \
  || fail "(4) degraded row dropped the slug, got: $pending"

awaiting="$(_row_awaiting_task "spare-a" "$WT")"
printf '%s' "$awaiting" | grep -q 'awaiting task · assign or retire' \
  || fail "(4) successful-no-PR spare must still render awaiting task, got: $awaiting"
ok

# ── (5) classification contract: failed lookup → pending; successful empty → awaiting ────────────
# Mirrors the main-loop branch: empty prnum + PRS_LOOKUP_OK decides the row. This is the load-bearing
# operator-facing contract — a gh blip must not paint the definitive spare-builder claim.
_classify_no_pr_row() {
  # $1=slug-cell $2=worktree — uses ambient PRS_LOOKUP_OK
  local _sl="$1" _wt="$2"
  if [ "${PRS_LOOKUP_OK:-1}" != "1" ]; then
    _row_pr_match_pending "$_sl"
  else
    _row_awaiting_task "$_sl" "$_wt"
  fi
}

PRS_LOOKUP_OK=0
row_fail="$(_classify_no_pr_row "multi-seat-doctrine" "$WT")"
printf '%s' "$row_fail" | grep -q 'awaiting task' \
  && fail "(5) failed PR lookup must NOT render 'awaiting task', got: $row_fail"
printf '%s' "$row_fail" | grep -q 'PR match pending · retrying' \
  || fail "(5) failed PR lookup must render 'PR match pending · retrying', got: $row_fail"

PRS_LOOKUP_OK=1
row_ok="$(_classify_no_pr_row "spare-a" "$WT")"
printf '%s' "$row_ok" | grep -q 'awaiting task · assign or retire' \
  || fail "(5) successful list with no PR must render awaiting task, got: $row_ok"
printf '%s' "$row_ok" | grep -q 'PR match pending' \
  && fail "(5) successful empty list must NOT render PR match pending, got: $row_ok"
ok

# ── (6) ratchet: the old `|| echo '[]'` collapse is gone from the tick's pr-list fetch ────────────
# The pre-fix one-liner is the exact bug. _prs_fetch_tick (or any successor) must capture rc; the
# bare `|| echo '[]'` form on the tick path must not return.
if grep -nE 'gh pr list.*\|\| *echo' "$WATCH" | grep -q '_watcher_tick_fields\|PRS_JSON'; then
  # Only fail if the collapse is still wired to the tick fields / PRS_JSON assignment path.
  leaked="$(grep -nE 'PRS_JSON=.*gh pr list.*\|\| *echo|gh pr list --json "\$\(_watcher_tick_fields\)".*\|\| *echo' "$WATCH" || true)"
  [ -z "$leaked" ] || fail "(6) tick still collapses failed gh pr list via || echo:
$leaked"
fi
# Positive: _prs_fetch_tick is what the main loop must call (not the inlined collapse).
grep -q '_prs_fetch_tick' "$WATCH" || fail "(6) _prs_fetch_tick must exist in agent-watch.sh"
# The live loop (below the LIB return) must call it — not reintroduce the collapse inline.
loop_fetch="$(awk '/^if \[ "\$\{AGENT_WATCH_LIB:-\}" = "1" \]; then return/,0' "$WATCH" | grep -n 'gh pr list\| _prs_fetch_tick' || true)"
printf '%s' "$loop_fetch" | grep -q '_prs_fetch_tick' \
  || fail "(6) main loop must call _prs_fetch_tick, loop refs:
$loop_fetch"
printf '%s' "$loop_fetch" | grep -E 'gh pr list.*\|\| *echo' \
  && fail "(6) main loop still has gh pr list || echo collapse:
$loop_fetch"
ok

echo "ALL PASS ($pass checks)"
