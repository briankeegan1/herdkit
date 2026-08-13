#!/usr/bin/env bash
# test-autofix-scope.sh — hermetic proof of AUTOFIX_SCOPE (HERD-655, GitHub issue #771) — the
# multi-operator ownership gate shared by every autofix WRITE rail.
#
# GROUNDED (emberglen, two operators): a seat's RESOLVE_AUTOFIX rail adopted the OTHER operator's
# conflicting PR and dispatched a resolver against his branch — no author/operator filter existed on
# any autofix write rail. This suite proves the ONE shared check (_autofix_scope / _autofix_scope_permits)
# that closes the gap, mirroring test-team-mode.sh's proof of the analogous WATCHER_SCOPE gate:
#   (1) own (default): only the resolved operator's OWN PRs are permitted.
#   (2) all: every PR is permitted (today's behavior, explicit opt-in).
#   (3) FAIL-CLOSED: an empty/unknown author, or an unresolvable operator identity, is WITHHELD —
#       never fires blind — and journals `autofix_scope_withheld` (pr, author, rail).
#   (4) unknown AUTOFIX_SCOPE value degrades to the safe default 'own', loudly.
#   (5) identity resolution reuses _resolve_watcher_owner/_WATCHER_OWNER_CACHE (WATCHER_OWNER →
#       WATCHER_VIEW_AUTHOR → gh api user, memoized once — never one gh probe per candidate).
#
# Per-rail wiring (RESOLVE_AUTOFIX/_dispatch_conflict_autofix, STALE_BASE_AUTOFIX/_handle_stale_dup,
# REVIEW_AUTOFIX/_handle_block_verdict, HEALTHCHECK_AUTOFIX/_handle_health_codeerror) is proved by the
# scope-specific cases appended to each rail's own suite (tests/test-resolve-autofix.bats,
# tests/test-stale-base-autofix.sh, tests/test-auto-refix.sh, tests/test-health-autofix.sh) — this
# file covers the ONE shared implementation those call sites all consult.
#
# Run:  bash tests/test-autofix-scope.sh
# No `set -e`: several checks assert non-zero returns explicitly.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../scripts/herd/agent-watch.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

[ -f "$WATCH" ] || fail "agent-watch.sh not found at $WATCH"
command -v python3 >/dev/null 2>&1 || fail "python3 required"

# ── Stub gh: `gh api user -q .login` returns whatever login GH_USER_LOGIN holds — lets a test
# simulate a resolvable OR an unresolvable operator identity, exactly like test-team-mode.sh.
BIN="$T/bin"; mkdir -p "$BIN"
cat > "$BIN/gh" << 'STUB'
#!/usr/bin/env bash
case "$*" in
  "api user -q .login") printf '%s\n' "${GH_USER_LOGIN:-}"; exit 0 ;;
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
export TREES="$T/trees"
export JOURNAL_FILE="$T/journal.jsonl"; : > "$JOURNAL_FILE"
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"

for fn in _autofix_scope _autofix_scope_permits _resolve_watcher_owner _watcher_owner_login; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined"
done

reset_owner() { _WATCHER_OWNER_RESOLVED=""; _WATCHER_OWNER_CACHE=""; rm -f "$TREES/.agent-watch-view-warned"; }
clear_scope() {
  unset AUTOFIX_SCOPE WATCHER_OWNER WATCHER_VIEW_AUTHOR GH_USER_LOGIN
  reset_owner
  : > "$JOURNAL_FILE"
}
withheld_events() { grep -c '"event":"autofix_scope_withheld"' "$JOURNAL_FILE" 2>/dev/null; }

# ── 1. DEFAULT (unset) resolves to 'own' ──────────────────────────────────────────────────────────
clear_scope
[ "$(_autofix_scope)" = "own" ] || fail "unset AUTOFIX_SCOPE must resolve to 'own'"
ok

# ── 2. own + matching author: PERMITTED, no gh call needed when WATCHER_OWNER is explicit ──────────
clear_scope
export WATCHER_OWNER=alice
_autofix_scope_permits alice resolve 100 || fail "own: the operator's own PR must be permitted"
[ "$(withheld_events)" -eq 0 ] || fail "a permitted call must not journal a withhold"
ok

# ── 3. own + teammate author: WITHHELD (FAIL for real, not just display) + journaled ───────────────
clear_scope
export WATCHER_OWNER=alice
_autofix_scope_permits bob resolve 101 && fail "own: a teammate's PR must be WITHHELD"
[ "$(withheld_events)" -eq 1 ] || fail "a withhold must journal exactly one autofix_scope_withheld event"
grep -q '"pr":101' "$JOURNAL_FILE" || fail "withhold journal must carry the pr"
grep -q '"author":"bob"' "$JOURNAL_FILE" || fail "withhold journal must carry the author"
grep -q '"rail":"resolve"' "$JOURNAL_FILE" || fail "withhold journal must carry the rail"
ok

# ── 4. own + empty/unknown author: FAIL-CLOSED even with a resolvable owner ─────────────────────────
clear_scope
export WATCHER_OWNER=alice
_autofix_scope_permits "" resolve 102 && fail "own: an empty/unknown PR author must be forbidden (fail-closed)"
ok

# ── 5. own + UNRESOLVABLE operator identity: every rail WITHHELD, loud warning ──────────────────────
clear_scope
export GH_USER_LOGIN=""
if _autofix_scope_permits alice stale 103 2>"$T/noowner.err"; then
  fail "own + unresolvable owner must withhold (fail-closed)"
fi
grep -qi "unresolved" "$T/noowner.err" || fail "unresolvable owner must warn loudly"
grep -q '"reason":"noowner"' "$JOURNAL_FILE" || fail "unresolvable-owner withhold must journal reason=noowner"
ok

# ── 6. all: every rail permits regardless of author, EVEN an empty one (today's behavior) ──────────
clear_scope
export AUTOFIX_SCOPE=all WATCHER_OWNER=alice
_autofix_scope_permits bob review 200 || fail "all: a teammate's PR must be permitted"
_autofix_scope_permits ""  health 201 || fail "all: an empty author must be permitted"
[ "$(withheld_events)" -eq 0 ] || fail "all must never journal a withhold"
ok
# all must never even resolve/consult the operator identity (no ownership probe at all).
clear_scope
export AUTOFIX_SCOPE=all
GH_USER_LOGIN="sentinel-gh-user" _autofix_scope_permits bob resolve 202 >/dev/null
[ -z "$_WATCHER_OWNER_RESOLVED" ] || fail "all must not resolve/consult the gh operator identity"
ok

# ── 7. Unknown AUTOFIX_SCOPE degrades to the safe default 'own' + a loud warning ────────────────────
clear_scope
export AUTOFIX_SCOPE=bogus
scope="$(_autofix_scope 2>"$T/scope.err")"
[ "$scope" = "own" ] || fail "unknown AUTOFIX_SCOPE must fall back to safe 'own' (got: $scope)"
ok
grep -qi "unknown value" "$T/scope.err" || fail "unknown AUTOFIX_SCOPE must warn loudly"
grep -q "bogus" "$T/scope.err" || fail "warning must name the offending value"
ok

# ── 8. Identity resolution order + memoization mirrors WATCHER_OWNER exactly ────────────────────────
clear_scope
export WATCHER_OWNER=alice WATCHER_VIEW_AUTHOR=carol
_autofix_scope_permits alice resolve 300 || fail "WATCHER_OWNER must take precedence over WATCHER_VIEW_AUTHOR"
ok
clear_scope
export WATCHER_VIEW_AUTHOR=carol
_autofix_scope_permits carol resolve 301 || fail "WATCHER_VIEW_AUTHOR must be the fallback identity"
ok
clear_scope
export GH_USER_LOGIN=dave
_autofix_scope_permits dave resolve 302 || fail "gh api user must be the last-resort identity"
ok
# Memoized: resolve once, then a later gh identity change is NOT re-read this process.
reset_owner
export GH_USER_LOGIN=dave
_autofix_scope_permits dave resolve 303 || fail "first resolve must read the live gh identity"
export GH_USER_LOGIN=someone-else
_autofix_scope_permits dave resolve 304 || fail "owner identity must stay memoized (resolved once)"
ok

# ── 9. Every write rail's dispatch function shares THIS ONE implementation (multi-seat doctrine) ────
# Static proof: each rail's write-site calls _autofix_scope_permits by name (grep, not behavior — the
# per-rail suites already prove the runtime wiring). A rail re-implementing its own check would drift.
for site in _dispatch_conflict_autofix _handle_stale_dup _handle_block_verdict _handle_health_codeerror; do
  body="$(declare -f "$site" 2>/dev/null)"
  [ -n "$body" ] || fail "$site not defined"
  case "$body" in
    *_autofix_scope_permits*) : ;;
    *) fail "$site must consult the shared _autofix_scope_permits check" ;;
  esac
done
ok

clear_scope
echo "ALL PASS ($pass checks)"
