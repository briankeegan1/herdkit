#!/usr/bin/env bash
# test-watcher-checks.sh — hermetic test that the watcher honors branch-protection gates before
# auto-merging (required reviews / CODEOWNERS / required status checks). It stubs `gh` on PATH
# (NETWORK-FREE) to return canned `pr view --json mergeable,mergeStateStatus` payloads, sources
# agent-watch.sh's pure merge-decision helper (_should_automerge) via the AGENT_WATCH_LIB guard
# (which loads the helpers WITHOUT entering the live watch loop), and asserts the decision logic:
#   • MERGES (calls `gh pr merge`) only when mergeStateStatus == CLEAN
#   • HOLDS  (never calls `gh pr merge`) on BLOCKED / BEHIND / UNSTABLE / DIRTY / unknown / empty
# Run:  bash tests/test-watcher-checks.sh
# No `set -e`: some checks deliberately expect a non-zero predicate return; we assert explicitly.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../scripts/herd/agent-watch.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ pass=$((pass+1)); }

[ -f "$WATCH" ] || fail "agent-watch.sh not found at $WATCH"
command -v python3 >/dev/null 2>&1 || fail "python3 required to run this test"

# ── stub `gh` on PATH (no network) ───────────────────────────────────────────
# `gh pr view ... --json mergeable,mergeStateStatus` echoes a payload built from $GH_MERGEABLE /
# $GH_MSTATE. `gh pr merge ...` records the call to $GH_MERGE_LOG so we can prove no merge happens
# on a gated PR. The stub shadows any real gh because $BIN is prepended to PATH.
BIN="$T/bin"; mkdir -p "$BIN"
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "pr view")
    printf '{"mergeable":"%s","mergeStateStatus":"%s"}\n' "${GH_MERGEABLE-MERGEABLE}" "${GH_MSTATE-CLEAN}"
    ;;
  "pr merge")
    printf 'merge %s\n' "${GH_MSTATE:-?}" >> "${GH_MERGE_LOG:?GH_MERGE_LOG unset}"
    ;;
  *) : ;;
esac
exit 0
STUB
chmod +x "$BIN/gh"
export PATH="$BIN:$PATH"

# Source the watcher's helpers WITHOUT its live loop. Point config discovery at a nonexistent file
# so herd-config.sh falls back to its generic defaults — fully hermetic, no repo/.herd walk-up.
export AGENT_WATCH_LIB=1
export HERD_CONFIG_FILE="$T/no-such-config"
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"
type _should_automerge >/dev/null 2>&1 || fail "_should_automerge not defined after sourcing"

# decide <mergeStateStatus> [mergeable] — mirror the watcher's gate end-to-end: fetch the PR's real
# state through the stubbed gh, then merge ONLY when _should_automerge approves. Echoes MERGE/HOLD.
decide() {
  local m
  export GH_MSTATE="$1" GH_MERGEABLE="${2:-MERGEABLE}"
  m="$(gh pr view 1 --json mergeable,mergeStateStatus \
        | python3 -c 'import sys,json;print(json.load(sys.stdin)["mergeStateStatus"])')"
  if _should_automerge "$m"; then gh pr merge 1 --merge; echo MERGE; else echo HOLD; fi
}

GH_MERGE_LOG="$T/merge.log"; export GH_MERGE_LOG

# ── CLEAN → merges, and `gh pr merge` IS called ──────────────────────────────
: > "$GH_MERGE_LOG"
[ "$(decide CLEAN)" = "MERGE" ] || fail "CLEAN should MERGE"
grep -q "merge CLEAN" "$GH_MERGE_LOG" || fail "CLEAN should have invoked gh pr merge"
ok

# ── gated / not-ready states → HOLD, and `gh pr merge` is NOT called ──────────
for st in BLOCKED BEHIND UNSTABLE DIRTY DRAFT HAS_HOOKS UNKNOWN WEIRD ""; do
  : > "$GH_MERGE_LOG"
  d="$(decide "$st")"
  [ "$d" = "HOLD" ] || fail "state '${st:-<empty>}' should HOLD (got $d)"
  [ -s "$GH_MERGE_LOG" ] && fail "state '${st:-<empty>}' must NOT invoke gh pr merge"
  ok
done

# ── the pure predicate directly: ONLY CLEAN returns success ──────────────────
_should_automerge CLEAN   || fail "_should_automerge CLEAN should return 0"
! _should_automerge BLOCKED || fail "_should_automerge BLOCKED should return non-zero"
! _should_automerge ""      || fail "_should_automerge '' should return non-zero"
ok

echo "ALL PASS ($pass checks)"
