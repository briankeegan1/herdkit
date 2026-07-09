#!/usr/bin/env bash
# test-ci-autorepair.sh — hermetic proof of CI_AUTOREPAIR (HERD-250).
#
# A MERGEABLE+UNSTABLE PR whose required CI is FAILING can be either:
#   • INHERITED red — herd/gates PASSED + branch BEHIND main → base-refresh (merge main)
#   • REAL new-code failure — not behind, or gates not green → needs-you (never auto-heal)
#
# This suite proves:
#   (1) OFF (default) → needs-you path (handler returns 1), no bounce, no ledger, no journal
#   (2) ON + gates green + behind + live builder → one pane-run bounce, kind=ci, ci_repair journal
#   (3) ON + gates green + NOT behind → real failure, no heal (handler returns 1)
#   (4) ON + behind + gates NOT green → real failure, no heal
#   (5) once-guard: same sha re-enters → no second bounce
#   (6) no live builder → conflict resolver, not silent merge
#   (7) dry-run never bounces
#   (8) pure predicates (ci_autorepair_enabled / ci_repair_eligible / branch_behind / gates_passed)
#   (9) git-real behind probe on a tiny sandbox repo
#
# Sources agent-watch.sh in lib mode (pulls in ci-repair.sh). Stubs herdr/gh/git (NETWORK-FREE)
# except (9) which uses a real git sandbox. Run: bash tests/test-ci-autorepair.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../scripts/herd/agent-watch.sh"
CI_REPAIR="$HERE/../scripts/herd/ci-repair.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); echo "PASS: $1"; }

[ -f "$WATCH" ] || fail "agent-watch.sh not found at $WATCH"
[ -f "$CI_REPAIR" ] || fail "ci-repair.sh not found at $CI_REPAIR"
command -v python3 >/dev/null 2>&1 || fail "python3 required"

# ── Stub binaries on PATH ─────────────────────────────────────────────────────
BIN="$T/bin"; mkdir -p "$BIN"
for cmd in gh git; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$cmd"; chmod +x "$BIN/$cmd"
done

cat > "$BIN/herdr" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "agent list")
    if [ "${STUB_AGENT_EMPTY:-}" = "1" ]; then
      printf '{"result":{"agents":[]}}\n'
    else
      printf '{"result":{"agents":[{"name":"%s","agent_status":"%s","pane_id":"%s"}]}}\n' \
        "${STUB_AGENT_NAME:-}" \
        "${STUB_AGENT_STATUS:-idle}" \
        "${STUB_PANE_ID:-pane-test-000}"
    fi
    ;;
  "pane run")
    [ -n "${STUB_PANE_RUN_LOG:-}" ] && printf '%s\t%s\n' "$3" "$(printf '%s' "${4:-}" | tr '\n' ' ')" >> "$STUB_PANE_RUN_LOG"
    ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$BIN/herdr"
export PATH="$BIN:$PATH"

. "$(dirname "$0")/../scripts/herd/sim/sim-notify-stub.sh" || { echo "cannot source notify stub"; exit 1; }
sim_notify_install "$T" || { echo "sim_notify_install failed"; exit 1; }

# ── Source agent-watch.sh in lib mode ────────────────────────────────────────
export AGENT_WATCH_LIB=1 HERD_DRIVER=headless
export WORKTREES_DIR="$T/trees"; mkdir -p "$T/trees"
export HERD_CONFIG_FILE="$T/no-such-config"
export JOURNAL_FILE="$T/journal.jsonl"; : > "$JOURNAL_FILE"
export DEFAULT_BRANCH="origin/main"
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"
TREES="$WORKTREES_DIR"

for fn in ci_autorepair_enabled ci_repair_eligible ci_repair_branch_behind ci_repair_gates_passed \
          _handle_ci_repair refix_attempted refix_rail_count record_refix spawn_resolver; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined after sourcing"
done
ok "helpers defined"

render() { :; }
STUB_WAIT_FILE="$T/wait-codes.txt"; : > "$STUB_WAIT_FILE"
_wait_agent_working() {
  local _c; _c="$(head -1 "$STUB_WAIT_FILE" 2>/dev/null || true)"
  { tail -n +2 "$STUB_WAIT_FILE" 2>/dev/null || true; } > "${STUB_WAIT_FILE}.tmp"
  mv "${STUB_WAIT_FILE}.tmp" "$STUB_WAIT_FILE" 2>/dev/null || true
  return "${_c:-0}"
}
_agent_liveness() { printf '%s' "${STUB_LIVENESS:-alive}"; }
_resolver_agent_alive() { [ "${STUB_RESOLVER_ALIVE:-0}" = "1" ]; }
_resolver_in_flight() { local _s="$1" _p="$2"; [ "${STUB_RESOLVER_ALIVE:-0}" = "1" ]; }
_detect_limit_hit() { return 1; }
_self_restart_hold_dispatch() { return 1; }
_defer_for_suite() { return 1; }

RESOLVE_LOG="$T/resolve.log"; : > "$RESOLVE_LOG"
spawn_resolver() {
  printf '%s %s %s %s\n' "${1:-}" "${2:-}" "${3:-}" "${4:-}" >> "$RESOLVE_LOG"
}

export STUB_PANE_RUN_LOG="$T/pane-runs.txt"; : > "$STUB_PANE_RUN_LOG"
runs() { awk 'END{print NR+0}' "$STUB_PANE_RUN_LOG" 2>/dev/null || printf '0'; }
rslv() { awk 'END{print NR+0}' "$RESOLVE_LOG" 2>/dev/null || printf '0'; }
row()  { printf '%s\n' "${DISPLAY[0]:-}"; }
reset_state() {
  : > "$STUB_PANE_RUN_LOG"; : > "$RESOLVE_LOG"; : > "$REFIX_STATE"; : > "$JOURNAL_FILE"
  DISPLAY=(); DRYRUN=""; STUB_AGENT_EMPTY=""; STUB_LIVENESS=alive
  export STUB_AGENT_NAME="slug-a" STUB_AGENT_STATUS="idle" STUB_PANE_ID="pane-a"
  unset HERD_CI_REPAIR_GATES_PASSED HERD_CI_REPAIR_BEHIND CI_AUTOREPAIR
}
CI_SUM='CI failed: suite(macos)'
WT="$T/trees/slug-a"; mkdir -p "$WT"

# ── (1) OFF-mode: byte-identical needs-you (handler returns 1, no side effects) ───────────────
reset_state
# Even with seams that WOULD make it eligible, off mode must refuse.
export HERD_CI_REPAIR_GATES_PASSED=1 HERD_CI_REPAIR_BEHIND=1
unset CI_AUTOREPAIR
if _handle_ci_repair 10 slug-a shaA 0 "$WT" feat/a "$CI_SUM"; then
  fail "(1) off-mode must return 1 so the caller paints needs-you"
fi
[ "$(runs)" = "0" ] || fail "(1) off-mode must never pane-run"
[ "$(rslv)" = "0" ] || fail "(1) off-mode must never spawn a resolver"
[ "$(refix_rail_count 10 ci)" = "0" ] || fail "(1) off-mode must not consume a ci refix round"
grep -q '"event":"ci_repair"' "$JOURNAL_FILE" 2>/dev/null && fail "(1) off-mode must not journal ci_repair"
ok "(1) off-mode is byte-identical (return 1, no bounce, no ledger)"

export CI_AUTOREPAIR=false
_handle_ci_repair 11 slug-a shaB 0 "$WT" feat/a "$CI_SUM" && fail "(1b) false must return 1"
[ "$(runs)" = "0" ] || fail "(1b) false must not bounce"
ok "(1b) CI_AUTOREPAIR=false is inert"

# ── (2) ON + gates green + behind + live builder → bounce once ───────────────────────────────
reset_state
export CI_AUTOREPAIR=on HERD_CI_REPAIR_GATES_PASSED=1 HERD_CI_REPAIR_BEHIND=1
printf '0\n' > "$STUB_WAIT_FILE"
_handle_ci_repair 20 slug-a shaC 0 "$WT" feat/a "$CI_SUM" || fail "(2) eligible heal must return 0"
[ "$(runs)" = "1" ] || fail "(2) autofix on must pane-run exactly once (got $(runs))"
grep -q '^pane-a' "$STUB_PANE_RUN_LOG" || fail "(2) bounce must target the AGENT pane"
grep -q 'git merge origin/main' "$STUB_PANE_RUN_LOG" || fail "(2) prompt must ask for git merge origin/main"
grep -q 'INHERITED' "$STUB_PANE_RUN_LOG" || fail "(2) prompt must name INHERITED red"
refix_attempted 20 shaC ci || fail "(2) bounce must be recorded kind=ci"
[ "$(refix_rail_count 20 ci)" = "1" ] || fail "(2) must consume exactly one ci refix round"
row | grep -q 'ci-repair' || fail "(2) row must name ci-repair (got: $(row))"
row | grep -q 'awaiting push' || fail "(2) row must read awaiting push (got: $(row))"
row | grep -q 'needs you' && fail "(2) 'needs you' is BANNED after a successful bounce (got: $(row))"
grep -q '"event":"ci_repair"' "$JOURNAL_FILE" || fail "(2) bounce must journal ci_repair"
grep -q '"result":"bounce"' "$JOURNAL_FILE" || fail "(2) journal must record result=bounce"
ok "(2) inherited red (gates+behind) bounces with merge prompt"

# ── (3) ON + gates green + NOT behind → REAL failure, no heal ────────────────────────────────
reset_state
export CI_AUTOREPAIR=on HERD_CI_REPAIR_GATES_PASSED=1 HERD_CI_REPAIR_BEHIND=0
_handle_ci_repair 30 slug-a shaD 0 "$WT" feat/a "$CI_SUM" && fail "(3) not-behind must return 1 (real failure)"
[ "$(runs)" = "0" ] || fail "(3) real failure must never pane-run"
[ "$(rslv)" = "0" ] || fail "(3) real failure must never spawn a resolver"
[ "$(refix_rail_count 30 ci)" = "0" ] || fail "(3) real failure must not consume a refix round"
grep -q '"event":"ci_repair"' "$JOURNAL_FILE" 2>/dev/null && fail "(3) real failure must not journal ci_repair"
ok "(3) up-to-date branch with red CI is NOT auto-healed (real new-code failure)"

# ── (4) ON + behind + gates NOT green → no heal ──────────────────────────────────────────────
reset_state
export CI_AUTOREPAIR=on HERD_CI_REPAIR_GATES_PASSED=0 HERD_CI_REPAIR_BEHIND=1
_handle_ci_repair 40 slug-a shaE 0 "$WT" feat/a "$CI_SUM" && fail "(4) gates-not-green must return 1"
[ "$(runs)" = "0" ] || fail "(4) no gates blessing must never bounce"
ok "(4) behind + no gates blessing is NOT auto-healed"

# ── (5) once-guard: same sha re-enters → no second bounce ────────────────────────────────────
reset_state
export CI_AUTOREPAIR=on HERD_CI_REPAIR_GATES_PASSED=1 HERD_CI_REPAIR_BEHIND=1
printf '0\n' > "$STUB_WAIT_FILE"
_handle_ci_repair 50 slug-a shaF 0 "$WT" feat/a "$CI_SUM" || fail "(5) first call should heal"
_handle_ci_repair 50 slug-a shaF 0 "$WT" feat/a "$CI_SUM" || fail "(5) second call still handles the row"
[ "$(runs)" = "1" ] || fail "(5) second call for same sha must not re-bounce (got $(runs))"
row | grep -q 'ci-repair' || fail "(5) once-guard row must still say ci-repair"
ok "(5) sha-keyed once-guard holds"

# New sha is eligible.
printf '0\n' > "$STUB_WAIT_FILE"
_handle_ci_repair 50 slug-a shaG 0 "$WT" feat/a "$CI_SUM" || fail "(5b) new sha should heal"
[ "$(runs)" = "2" ] || fail "(5b) a new sha must be eligible for a fresh bounce (got $(runs))"
ok "(5b) new sha is eligible"

# ── (6) no live builder (foreign/reaped) → conflict resolver, not silent merge ───────────────
reset_state
export CI_AUTOREPAIR=on HERD_CI_REPAIR_GATES_PASSED=1 HERD_CI_REPAIR_BEHIND=1
export STUB_AGENT_EMPTY=1
STUB_LIVENESS=missing
_handle_ci_repair 60 slug-a shaH 0 "$WT" feat/a "$CI_SUM" || fail "(6) no-builder path must return 0"
[ "$(runs)" = "0" ] || fail "(6) no-builder path must never pane-run"
[ "$(rslv)" = "1" ] || fail "(6) no-builder path must dispatch the resolver exactly once (got $(rslv))"
grep -q '^slug-a 60 feat/a shaH$' "$RESOLVE_LOG" || fail "(6) resolver args must be slug/pr/branch/sha (got: $(cat "$RESOLVE_LOG"))"
refix_attempted 60 shaH ci || fail "(6) resolver dispatch must burn the ci once-guard"
row | grep -q 'awaiting push' || fail "(6) resolver path must read awaiting push (got: $(row))"
grep -q '"result":"resolver"' "$JOURNAL_FILE" || fail "(6) resolver dispatch must journal result=resolver"
ok "(6) foreign/reaped PR dispatches the conflict resolver (never silent-merges)"

# ── (7) dry-run never bounces ────────────────────────────────────────────────────────────────
reset_state
export CI_AUTOREPAIR=on HERD_CI_REPAIR_GATES_PASSED=1 HERD_CI_REPAIR_BEHIND=1
DRYRUN=1 _handle_ci_repair 70 slug-a shaI 0 "$WT" feat/a "$CI_SUM" && fail "(7) dry-run must return 1"
[ "$(runs)" = "0" ] || fail "(7) dry-run must never bounce"
[ "$(rslv)" = "0" ] || fail "(7) dry-run must never spawn a resolver"
ok "(7) dry-run is inert"

# ── (8) pure predicates ──────────────────────────────────────────────────────────────────────
( unset CI_AUTOREPAIR; ci_autorepair_enabled ) && fail "(8) default (unset) must be OFF"
( CI_AUTOREPAIR=off  ci_autorepair_enabled ) && fail "(8) off must be OFF"
( CI_AUTOREPAIR=on   ci_autorepair_enabled ) || fail "(8) on must be ON"
( CI_AUTOREPAIR=true ci_autorepair_enabled ) || fail "(8) true must be ON"

# eligible: needs on + gates + behind
unset CI_AUTOREPAIR HERD_CI_REPAIR_GATES_PASSED HERD_CI_REPAIR_BEHIND
export CI_AUTOREPAIR=on HERD_CI_REPAIR_GATES_PASSED=1 HERD_CI_REPAIR_BEHIND=1
ci_repair_eligible "$WT" origin/main shaX || fail "(8) eligible when on+gates+behind"
[ -n "${_CI_REPAIR_REASON:-}" ] || fail "(8) eligible must set _CI_REPAIR_REASON"

export HERD_CI_REPAIR_BEHIND=0
ci_repair_eligible "$WT" origin/main shaX && fail "(8) not eligible when not behind"

export HERD_CI_REPAIR_BEHIND=1 HERD_CI_REPAIR_GATES_PASSED=0
ci_repair_eligible "$WT" origin/main shaX && fail "(8) not eligible when gates not green"

unset CI_AUTOREPAIR
export HERD_CI_REPAIR_GATES_PASSED=1 HERD_CI_REPAIR_BEHIND=1
ci_repair_eligible "$WT" origin/main shaX && fail "(8) not eligible when lever off"
ok "(8) pure predicates (enabled / eligible axes)"

# ── (9) git-real behind probe on a tiny sandbox repo ─────────────────────────────────────────
# Restore a real git on PATH for this case only (the stub returns 0 with empty output).
REAL_GIT="$(command -v -p git 2>/dev/null || type -P git || true)"
# Prefer the system git outside our stub bin.
for _g in /usr/bin/git /bin/git; do
  [ -x "$_g" ] && REAL_GIT="$_g" && break
done
[ -n "$REAL_GIT" ] && [ -x "$REAL_GIT" ] || fail "(9) real git binary required for sandbox probe"

SAND="$T/sandbox"
mkdir -p "$SAND"
(
  cd "$SAND" || exit 1
  "$REAL_GIT" init -q -b main
  "$REAL_GIT" config user.email "t@t"
  "$REAL_GIT" config user.name "t"
  echo base > f.txt
  "$REAL_GIT" add f.txt
  "$REAL_GIT" commit -q -m base
  "$REAL_GIT" branch -M main
  # Feature branch cut here.
  "$REAL_GIT" checkout -q -b feat
  echo feat > g.txt
  "$REAL_GIT" add g.txt
  "$REAL_GIT" commit -q -m feat
  # Advance main past the feature branch (feature is now behind).
  "$REAL_GIT" checkout -q main
  echo main2 >> f.txt
  "$REAL_GIT" add f.txt
  "$REAL_GIT" commit -q -m main2
  "$REAL_GIT" checkout -q feat
) || fail "(9) sandbox repo setup failed"

# Temporarily put real git first so ci_repair_branch_behind uses it.
export PATH="$(dirname "$REAL_GIT"):$BIN:$PATH"
unset HERD_CI_REPAIR_BEHIND
ci_repair_branch_behind "$SAND" main HEAD || fail "(9) feat is behind main — must report behind"
# Merge main into feat → no longer behind.
(
  cd "$SAND" || exit 1
  "$REAL_GIT" merge -q main -m "refresh"
) || fail "(9) merge main into feat failed"
ci_repair_branch_behind "$SAND" main HEAD && fail "(9) after merge, feat must NOT be behind"
ok "(9) git-real behind probe (before merge = behind; after = not)"

# ── (10) kind isolation: ci bounce does not satisfy the stale once-guard ─────────────────────
reset_state
export CI_AUTOREPAIR=on HERD_CI_REPAIR_GATES_PASSED=1 HERD_CI_REPAIR_BEHIND=1
printf '0\n' > "$STUB_WAIT_FILE"
_handle_ci_repair 80 slug-a shaJ 0 "$WT" feat/a "$CI_SUM" || fail "(10) heal should fire"
refix_attempted 80 shaJ ci || fail "(10) kind=ci must match"
refix_attempted 80 shaJ stale && fail "(10) a ci bounce must NOT satisfy the stale once-guard"
refix_attempted 80 shaJ review && fail "(10) a ci bounce must NOT satisfy the review once-guard"
ok "(10) kind isolation (ci vs stale vs review)"

echo
echo "ALL PASS ($pass checks) — CI_AUTOREPAIR (HERD-250)"
