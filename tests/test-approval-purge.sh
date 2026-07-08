#!/usr/bin/env bash
# test-approval-purge.sh — hermetic tests for HERD-90: purge superseded awaiting-approval rows
# when a PR merges, plus the herd-approve.sh `list` display-level backstop.
#
# Scenario the fix addresses: a HUMAN-VERIFY hold re-applies at a NEW sha and the PR is
# approved+merged at that sha. The OLD sha's 'awaiting' row in .agent-watch-approvals was never
# cleaned, so `herd-approve.sh list` kept surfacing a phantom hold for a long-merged PR (and
# `approve` no-op'd with "already approved"), causing false coordinator wakes.
#
# Covers:
#   • purge_pr_approvals (agent-watch.sh, lib mode): drops EVERY row for a PR regardless of sha,
#     is substring-safe (9 vs 90 vs 900), leaves other PRs intact, fail-soft on an empty ledger.
#   • herd-approve.sh `list`: a merged PR's stale awaiting rows are skipped — via the offline
#     merge/reap ledger (.agent-watch-merged) AND via a `gh` MERGED probe (out-of-band merge).
#   • Regression guard: a genuinely-awaiting, unmerged PR still shows.
# Run:  bash tests/test-approval-purge.sh
# No `set -e`: some checks assert non-zero returns explicitly.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../scripts/herd/agent-watch.sh"
APPROVE="$HERE/../scripts/herd/herd-approve.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

[ -f "$WATCH" ]   || fail "agent-watch.sh not found at $WATCH"
[ -f "$APPROVE" ] || fail "herd-approve.sh not found at $APPROVE"
command -v python3 >/dev/null 2>&1 || fail "python3 required"

# ── Stub binaries on PATH — no network, no side-effects beyond $T ─────────────────────────────────
# gh: `pr view <n> --json state` reports MERGED iff <n> is in $MERGED_PRS (space-separated), else
# OPEN; `--json title` a synthetic title; `--json body` empty (no HUMAN-VERIFY block). Everything
# else is a harmless no-op.
BIN="$T/bin"; mkdir -p "$BIN"
cat > "$BIN/gh" << 'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "pr view")
    num="$3"; allargs="$*"
    case "$allargs" in
      *"--json state"*)
        for m in ${MERGED_PRS:-}; do [ "$m" = "$num" ] && { echo MERGED; exit 0; }; done
        echo OPEN ;;
      *"--json title"*) printf 'title for PR %s' "$num" ;;
      *) : ;;
    esac
    exit 0 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$BIN/gh"
for cmd in git herdr; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$cmd"; chmod +x "$BIN/$cmd"
done
export PATH="$BIN:$PATH"
export NO_COLOR=1

export WORKTREES_DIR="$T/trees"; mkdir -p "$WORKTREES_DIR"
export HERD_CONFIG_FILE="$T/no-such-config"
APPROVALS="$WORKTREES_DIR/.agent-watch-approvals"
MERGED_STATE="$WORKTREES_DIR/.agent-watch-merged"

# ── 1. purge_pr_approvals (agent-watch.sh lib mode) ──────────────────────────────────────────────
export AGENT_WATCH_LIB=1
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"
type purge_pr_approvals >/dev/null 2>&1 || fail "purge_pr_approvals not defined"

# Fail-soft: empty/absent ledger must not error.
rm -f "$APPROVALS"
purge_pr_approvals 90 || fail "purge on absent ledger should be a no-op success"
ok

# Two awaiting rows for PR 90 at DIFFERENT shas (the re-applied-hold case), plus an approved row for
# 90, plus rows for substring PRs 9 and 900, plus an unrelated PR 91.
cat > "$APPROVALS" << 'ROWS'
1000 awaiting 90 aaaaaaaa
1001 approved 90 bbbbbbbb
1002 awaiting 90 bbbbbbbb
1003 awaiting 9 cccccccc
1004 awaiting 900 dddddddd
1005 awaiting 91 eeeeeeee
ROWS
purge_pr_approvals 90 || fail "purge_pr_approvals returned non-zero"
# Every PR-90 row (awaiting AND approved, both shas) is gone.
grep -q ' 90 ' "$APPROVALS" && fail "PR 90 rows should be fully purged (all shas, all states)"
ok
# Substring PRs and the unrelated PR are untouched — exact field-3 match, not substring.
grep -q '^1003 awaiting 9 cccccccc$'   "$APPROVALS" || fail "PR 9 row (substring) must survive"
ok
grep -q '^1004 awaiting 900 dddddddd$' "$APPROVALS" || fail "PR 900 row (substring) must survive"
ok
grep -q '^1005 awaiting 91 eeeeeeee$'  "$APPROVALS" || fail "unrelated PR 91 row must survive"
ok
[ "$(grep -c . "$APPROVALS")" = "3" ] || fail "exactly 3 rows should remain after purge"
ok

# ── 2. herd-approve.sh list — offline merged-ledger backstop ─────────────────────────────────────
# PR 90 has two stale awaiting rows (two shas), neither approved. The merge/reap ledger shows 90
# merged. gh reports nothing merged (MERGED_PRS empty) — so ONLY the offline ledger drives the skip.
cat > "$APPROVALS" << 'ROWS'
1000 awaiting 90 aaaaaaaa
1002 awaiting 90 bbbbbbbb
1005 awaiting 91 eeeeeeee
ROWS
printf '1500 90 some-slug\n' > "$MERGED_STATE"
out="$(MERGED_PRS='' bash "$APPROVE" list 2>/dev/null)"
printf '%s' "$out" | grep -q 'PR #90' && fail "list must not show merged PR 90 (offline ledger backstop)"
ok
printf '%s' "$out" | grep -q 'PR #91' || fail "list must still show genuinely-awaiting PR 91"
ok

# ── 3. herd-approve.sh list — out-of-band gh MERGED backstop ─────────────────────────────────────
# No merge/reap ledger entry for 90 (merged directly on GitHub by a human); gh reports it MERGED.
rm -f "$MERGED_STATE"
out="$(MERGED_PRS='90' bash "$APPROVE" list 2>/dev/null)"
printf '%s' "$out" | grep -q 'PR #90' && fail "list must not show PR 90 merged out-of-band (gh backstop)"
ok
printf '%s' "$out" | grep -q 'PR #91' || fail "list must still show PR 91 (gh reports it OPEN)"
ok

# ── 4. Regression guard — unmerged PRs still surface ─────────────────────────────────────────────
# No ledger, nothing merged in gh: both awaiting PRs must show (the backstop must not over-skip).
out="$(MERGED_PRS='' bash "$APPROVE" list 2>/dev/null)"
printf '%s' "$out" | grep -q 'PR #90' || fail "unmerged PR 90 must still show"
ok
printf '%s' "$out" | grep -q 'PR #91' || fail "unmerged PR 91 must still show"
ok

echo "ALL PASS ($pass checks)"
