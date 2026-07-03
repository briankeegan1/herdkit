#!/usr/bin/env bash
# test-team-mode.sh — HEAVY hermetic tests for multi-user / team mode (WATCHER_SCOPE) — SAFETY-CRITICAL.
#
# Sources agent-watch.sh in lib mode (AGENT_WATCH_LIB=1) with a stubbed gh binary (no network) and
# exercises the pure ownership/scope gate that decides whether a MERGEABLE+CLEAN PR may AUTO-MERGE:
#   • _watcher_scope / _watcher_team_mode  — mine (default) | all, with unknown → safe 'mine' + warn
#   • _watcher_owner_login                 — WATCHER_OWNER → WATCHER_VIEW_AUTHOR → gh, memoized once
#   • _scope_permits_automerge <author>    — the SAFETY-CRITICAL gate (fail-CLOSED in team mode)
#   • _watcher_tick_fields                 — folds `author` into the gh fields in team mode only
#
# The four NON-NEGOTIABLE invariants from the backlog item, asserted below:
#   (1) DEFAULT (solo) == today's exact behavior — scope gate DORMANT, every candidate auto-merges.
#   (2) WATCHER_SCOPE=all DISPLAYS teammates' PRs but auto-merges ONLY the operator's OWNED PRs.
#   (3) a teammate-authored MERGEABLE+CLEAN+APPROVED PR is NOT auto-merged.
#   (4) an OWNED PR still auto-merges under team mode.
#
# Run:  bash tests/test-team-mode.sh
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

# ── Stub binaries on PATH — no network. The gh stub returns whatever login GH_USER_LOGIN holds for
# `gh api user`, so tests can simulate a resolvable OR an unresolvable operator identity. Any test
# that supplies WATCHER_OWNER/WATCHER_VIEW_AUTHOR must NOT reach gh at all (asserted via the sentinel).
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
export HERD_CONFIG_FILE="$T/no-such-config"   # falls back to generic defaults
# TREES is where _watcher_view_warn_once writes its dedup marker; keep warnings deterministic per key.
export TREES="$T/trees"
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"

for fn in _watcher_scope _watcher_team_mode _watcher_owner_login _resolve_watcher_owner _scope_permits_automerge _watcher_tick_fields _should_automerge; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined"
done

# Reset the memoized owner resolution + the dedup warn marker so each case starts pristine.
reset_owner() { _WATCHER_OWNER_RESOLVED=""; _WATCHER_OWNER_CACHE=""; rm -f "$TREES/.agent-watch-view-warned"; }
clear_scope() { unset WATCHER_SCOPE WATCHER_OWNER WATCHER_VIEW_AUTHOR WATCHER_VIEW WATCHER_VIEW_ASSIGNEE WATCHER_VIEW_LABEL WATCHER_VIEW_STATUS; reset_owner; }

# is_candidate <mergeable> <mstate> <author> — MODELS the watcher's classification candidate test
# EXACTLY as agent-watch.sh's tick loop does: MERGEABLE + _should_automerge(mstate) + scope permits.
# Returns 0 when this PR would be added to the auto-merge candidate set, non-zero otherwise.
is_candidate() { [ "$1" = "MERGEABLE" ] && _should_automerge "$2" && _scope_permits_automerge "$3"; }

# Fixture mirroring test-watcher-views.sh: two authors. PR1 owned+CLEAN, PR2 teammate+CLEAN+APPROVED,
# PR3 owned+CONFLICTING. The operator is `alice`.
FIXTURE='[
 {"number":1,"title":"a","headRefName":"f1","headRefOid":"s1","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","author":{"login":"alice"},"reviewDecision":"APPROVED"},
 {"number":2,"title":"b","headRefName":"f2","headRefOid":"s2","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","author":{"login":"bob"},"reviewDecision":"APPROVED"},
 {"number":3,"title":"c","headRefName":"f3","headRefOid":"s3","mergeable":"CONFLICTING","mergeStateStatus":"DIRTY","author":{"login":"alice"},"reviewDecision":"APPROVED"}
]'
nums() { python3 -c 'import sys,json; d=json.load(sys.stdin); print(",".join(str(p["number"]) for p in d))'; }

# ── 1. DEFAULT (unset) == today's exact solo behavior ─────────────────────────────────────────────
# INVARIANT (1): scope resolves to 'mine', team mode is OFF, the ownership probe stays DORMANT, and
# the tick fields are the UNCHANGED base set (no `author`) — byte-identical to before this change.
clear_scope
[ "$(_watcher_scope)" = "mine" ] || fail "unset WATCHER_SCOPE must resolve to 'mine'"
ok
_watcher_team_mode && fail "default scope must NOT be team mode"
ok
[ "$(_watcher_tick_fields)" = "$(_watcher_view_fields)" ] \
  || fail "solo tick fields must equal the base view fields (got: $(_watcher_tick_fields))"
ok
case ",$(_watcher_tick_fields)," in *,author,*) fail "solo tick fields must NOT request author" ;; esac
ok
# In solo mode _scope_permits_automerge ALWAYS permits — regardless of author, even an empty one.
_scope_permits_automerge alice   || fail "solo: owned author must be permitted"
_scope_permits_automerge bob     || fail "solo: ANY author must be permitted (today's behavior)"
_scope_permits_automerge ""      || fail "solo: empty author must be permitted (today's behavior)"
ok
# Solo classification: every MERGEABLE+CLEAN PR is a candidate irrespective of author (PR1 & PR2).
is_candidate MERGEABLE CLEAN alice || fail "solo: owned CLEAN PR must be a merge candidate"
is_candidate MERGEABLE CLEAN bob   || fail "solo: teammate CLEAN PR is STILL a candidate in solo mode (unchanged)"
is_candidate CONFLICTING DIRTY alice && fail "solo: a CONFLICTING PR must never be a candidate"
ok
# Solo mode must NEVER consult gh for an operator identity (no ownership probe at all).
GH_USER_LOGIN="sentinel-gh-user" _scope_permits_automerge bob >/dev/null
[ -z "$_WATCHER_OWNER_RESOLVED" ] || fail "solo mode must not resolve/consult the gh operator identity"
ok

# ── 2. Team mode DISPLAYS teammates' PRs but auto-merges ONLY owned ones ──────────────────────────
# INVARIANTS (2),(3),(4). Operator = alice, configured via WATCHER_OWNER (no gh call needed).
clear_scope
export WATCHER_SCOPE=all WATCHER_OWNER=alice
_watcher_team_mode || fail "WATCHER_SCOPE=all must be team mode"
ok
# tick fields must now include `author` so the ownership gate has its input.
case ",$(_watcher_tick_fields)," in *,author,*) : ;; *) fail "team mode must fold author into tick fields (got: $(_watcher_tick_fields))" ;; esac
ok
# DISPLAY: scope is NOT a lens — with the default (all) view lens, EVERY PR (incl. the teammate's)
# still flows through to be displayed. Scope narrows only the MERGE set, never what is shown.
got="$(printf '%s' "$FIXTURE" | _watcher_view_filter | nums)"
[ "$got" = "1,2,3" ] || fail "team mode must still DISPLAY all PRs incl. teammates' (got: $got)"
ok
# INVARIANT (4): the OWNED, MERGEABLE+CLEAN PR (alice/#1) still auto-merges.
is_candidate MERGEABLE CLEAN alice || fail "team mode: owned CLEAN PR must still auto-merge"
_scope_permits_automerge alice     || fail "team mode: owned author must be permitted"
ok
# INVARIANT (3): the TEAMMATE-authored MERGEABLE+CLEAN+APPROVED PR (bob/#2) is NOT auto-merged.
is_candidate MERGEABLE CLEAN bob   && fail "team mode: teammate CLEAN+approved PR must NOT be a candidate"
_scope_permits_automerge bob       && fail "team mode: teammate author must be FORBIDDEN from auto-merge"
ok

# ── 3. FAIL-CLOSED: unknown/unconfirmable ownership never blind-merges ────────────────────────────
# An empty/unknown PR author in team mode is FORBIDDEN — we cannot confirm it is ours.
clear_scope
export WATCHER_SCOPE=all WATCHER_OWNER=alice
_scope_permits_automerge "" && fail "team mode: an empty PR author must be forbidden (fail-closed)"
is_candidate MERGEABLE CLEAN "" && fail "team mode: an unknown-author CLEAN PR must NOT be a candidate"
ok
# An UNRESOLVABLE operator identity (no WATCHER_OWNER, no WATCHER_VIEW_AUTHOR, gh returns nothing)
# forbids EVERY auto-merge and warns loudly — refuse to merge rather than risk a teammate's PR.
clear_scope
export WATCHER_SCOPE=all GH_USER_LOGIN=""
if _scope_permits_automerge alice 2>"$T/noowner.err"; then fail "team mode + unresolvable owner must forbid auto-merge"; fi
ok
grep -qi "unresolved" "$T/noowner.err" || fail "unresolvable owner must emit a loud warning"
ok

# ── 4. Owner identity resolution + memoization ───────────────────────────────────────────────────
# WATCHER_OWNER wins over WATCHER_VIEW_AUTHOR; neither → gh api user; result memoized (one probe max).
clear_scope
export WATCHER_OWNER=alice WATCHER_VIEW_AUTHOR=carol
[ "$(_watcher_owner_login)" = "alice" ] || fail "WATCHER_OWNER must take precedence over WATCHER_VIEW_AUTHOR"
ok
clear_scope
export WATCHER_VIEW_AUTHOR=carol
[ "$(_watcher_owner_login)" = "carol" ] || fail "WATCHER_VIEW_AUTHOR must be the fallback identity"
ok
clear_scope
export GH_USER_LOGIN=dave
[ "$(_watcher_owner_login)" = "dave" ] || fail "gh api user must be the last-resort identity"
ok
# Memoized: resolve once (DIRECT call so the global memo survives), then a later gh identity change
# is NOT re-read this process. The subshell accessor above must not have persisted a memo.
reset_owner
export GH_USER_LOGIN=dave
_resolve_watcher_owner
[ "$_WATCHER_OWNER_CACHE" = "dave" ] || fail "direct resolve must read the gh identity (got: $_WATCHER_OWNER_CACHE)"
export GH_USER_LOGIN=someone-else
_resolve_watcher_owner
[ "$_WATCHER_OWNER_CACHE" = "dave" ] || fail "owner identity must be memoized (resolved once, got: $_WATCHER_OWNER_CACHE)"
ok

# ── 5. Unknown WATCHER_SCOPE degrades to the SAFE default 'mine' + a loud warning ─────────────────
clear_scope
export WATCHER_SCOPE=bogus
scope="$(_watcher_scope 2>"$T/scope.err")"
[ "$scope" = "mine" ] || fail "unknown WATCHER_SCOPE must fall back to safe 'mine' (got: $scope)"
ok
grep -qi "unknown value" "$T/scope.err" || fail "unknown WATCHER_SCOPE must warn loudly"
grep -q "bogus" "$T/scope.err" || fail "warning must name the offending scope value"
ok
# A bogus scope must behave EXACTLY like solo — it must never accidentally arm the ownership gate.
_watcher_team_mode && fail "unknown scope must NOT enable team mode"
_scope_permits_automerge bob || fail "unknown scope (→mine) must permit any author like solo"
ok

# ── 6. Explicit WATCHER_SCOPE=mine == unset (no regression from naming it) ─────────────────────────
clear_scope
export WATCHER_SCOPE=mine
[ "$(_watcher_scope)" = "mine" ] || fail "explicit mine must resolve to mine"
_watcher_team_mode && fail "explicit mine must not be team mode"
[ "$(_watcher_tick_fields)" = "$(_watcher_view_fields)" ] || fail "explicit mine tick fields must equal base"
_scope_permits_automerge bob || fail "explicit mine must permit any author"
ok

clear_scope
echo "ALL PASS ($pass checks)"
