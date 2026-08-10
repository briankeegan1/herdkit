#!/usr/bin/env bash
# test-main-health-scribe-sync.sh — HERD-613 LEG 1: MAIN_HEALTH_AUTOFIX=spawn must never thread the
# raw failing-test identity as HERD_ITEM_REF.
#
# THE INCIDENT (grounded 2026-08-10, PRs 712/719): with no OPEN item already matching a reproduced
# main red, the pre-HERD-613 spawn leg fell back to the raw failing-test identity STRING as the
# spawned builder's tracker ref. The builder faithfully wrote that string into its own PR's `Refs:`
# line (herd-quick.sh's REFS_RULE, exactly as designed for a REAL ref) — a non-empty token that parsed
# clean under pr-ref.sh's pre-HERD-613 "no shape test" rule and then sat forever as an unresolvable
# ESCALATED tracker-heal row with no operator clear path.
#
# This proves _main_health_scribe_sync (the new synchronous-create helper) end to end:
#   (1) the default `file` backend never attempts a synchronous create — _backend_add_item is not
#       reachable synchronously (it needs a scribe AGENT to stage the BACKLOG.md edit first) — and
#       _main_health_scribe_sync returns empty without ever touching the stub.
#   (2) a backend with a real synchronous create (stubbed as `linear`) that SUCCEEDS: the created
#       item's real tracker id is extracted from the backend's own output (a URL) via the SAME
#       per-backend shape guard LEG 2 uses, and threaded end to end as HERD_ITEM_REF into the spawned
#       intent's ref sidecar — the async scribe queue (_main_health_scribe) is NEVER also called
#       (no double-filing).
#   (3) the same backend's create call FAILING (_BACKEND_RESULT=NOCHANGE) falls back to the ordinary
#       ASYNC scribe enqueue, and the spawn carries NO ref sidecar — never a fabricated one.
#   (4) the same backend's create SUCCEEDING but returning output with no shape-conforming id at all
#       (a defensive/malformed case) also yields NO ref sidecar — never a fabricated one — even though
#       the create itself reports DONE.
# Fully hermetic: a throwaway git fixture stands in for $MAIN, a stub `linear.sh` backend under a
# private SCRIBE_BACKEND_DIR stands in for the real API, no network, no drainer, no model.
# Run:  bash tests/test-main-health-scribe-sync.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../scripts/herd/agent-watch.sh"

if [ -f "$HERE/../scripts/herd/hermetic-env-scrub.sh" ]; then
  # shellcheck source=/dev/null
  . "$HERE/../scripts/herd/hermetic-env-scrub.sh"
  herd_hermetic_env_scrub "$HERE/../scripts/herd/herd-config.sh"
fi

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ pass=$((pass+1)); printf 'ok — %s\n' "$1"; }

[ -f "$WATCH" ] || fail "agent-watch.sh not found at $WATCH"
command -v git >/dev/null 2>&1 || fail "git required"
command -v python3 >/dev/null 2>&1 || fail "python3 required"

REPO="$T/main"; TREES_DIR="$T/trees"; mkdir -p "$REPO" "$TREES_DIR"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name  tester
git -C "$REPO" config commit.gpgsign false
printf 'seed\n' > "$REPO/seed.txt"
printf '## Backlog\n\n' > "$REPO/BACKLOG.md"
git -C "$REPO" add -A && git -C "$REPO" commit -q -m "seed"

HC="$T/hc.sh"
cat > "$HC" <<'HCSTUB'
#!/usr/bin/env bash
case "$(cat "$HC_MODE" 2>/dev/null)" in
  green) echo "✅ clean — all tests pass"; exit 0 ;;
  red-file) echo "❌ code error — app/greet.test.sh → greet.test FAIL"; exit 1 ;;
  *) echo "✅ clean"; exit 0 ;;
esac
HCSTUB
chmod +x "$HC"
export HC_MODE="$T/hc-mode"; printf 'green\n' > "$HC_MODE"

# ── stub `linear` backend: a synchronous create whose behavior is driven by $ADD_MODE ─────────────
BACKENDS="$T/backends"; mkdir -p "$BACKENDS"
export ADD_ITEM_LOG="$T/add-item.log"; : > "$ADD_ITEM_LOG"
export ADD_MODE="$T/add-mode"; printf 'ok\n' > "$ADD_MODE"
cat > "$BACKENDS/linear.sh" <<'STUB'
#!/usr/bin/env bash
_backend_add_item() {
  local text="$2"
  printf '%s\n' "$text" >> "$ADD_ITEM_LOG"
  case "$(cat "$ADD_MODE" 2>/dev/null)" in
    fail)    _BACKEND_RESULT="NOCHANGE" ;;
    garbage) _BACKEND_RESULT="DONE"; printf '%s\n' "https://linear.app/herdkit/issue/no-id-here/x" ;;
    *)       _BACKEND_RESULT="DONE"; printf '%s\n' "https://linear.app/herdkit/issue/HERD-901/main-red-fix" ;;
  esac
}
STUB

export AGENT_WATCH_LIB=1 NO_COLOR=1 HERD_DRIVER=headless
export HERD_CONFIG_FILE="$T/no-such-config"
export PROJECT_ROOT="$REPO" WORKTREES_DIR="$TREES_DIR"
export JOURNAL_FILE="$T/journal.jsonl"
export HERD_HEALTHCHECK_BIN="$HC"
export DEFAULT_BRANCH=origin/main
export BACKLOG_FILE=BACKLOG.md
export HERD_REMOTE=origin
export WATCHER_OWNER=test-operator
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"
for fn in _main_health_scribe_sync _main_health_autofix _main_health_autofix_spawn; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined after sourcing"
done

NOTIFY_LOG="$T/notify.log"; : > "$NOTIFY_LOG"
SCRIBE_LOG="$T/scribe.log"; : > "$SCRIBE_LOG"
herd_driver_notify() { printf '%s\n' "$1" >> "$NOTIFY_LOG"; }
_main_health_scribe() { printf '%s\n' "$1" >> "$SCRIBE_LOG"; }

# ── (1) the default file backend never attempts a synchronous create ───────────────────────────────
export SCRIBE_BACKEND=file SCRIBE_BACKEND_DIR="$BACKENDS"
got="$(_main_health_scribe_sync 'MAIN RED: fix app/greet.test.sh')"
[ -z "$got" ] || fail "(1) the file backend produced a synchronous ref: '$got'"
[ ! -s "$ADD_ITEM_LOG" ] || fail "(1) the file backend reached the stub's _backend_add_item: $(cat "$ADD_ITEM_LOG")"
ok "(1) the file backend never attempts a synchronous create — _main_health_scribe_sync is a clean no-op"

# ── (2) a real synchronous create SUCCEEDS: the real id is extracted and returned ──────────────────
export SCRIBE_BACKEND=linear
printf 'ok\n' > "$ADD_MODE"; : > "$ADD_ITEM_LOG"
got="$(_main_health_scribe_sync 'MAIN RED: fix app/greet.test.sh')"
[ "$got" = "HERD-901" ] || fail "(2) expected the real created id HERD-901, got: '$got'"
[ -s "$ADD_ITEM_LOG" ] || fail "(2) the stub's _backend_add_item was never called"
ok "(2) a synchronous create success yields the REAL tracker id, shape-extracted from the backend's own output"

# ── (3) a synchronous create FAILURE yields nothing ─────────────────────────────────────────────────
printf 'fail\n' > "$ADD_MODE"
got="$(_main_health_scribe_sync 'MAIN RED: fix app/greet.test.sh')"
[ -z "$got" ] || fail "(3) a failed create still produced a ref: '$got'"
ok "(3) a synchronous create failure (_BACKEND_RESULT=NOCHANGE) yields NO ref — never fabricated"

# ── (4) a synchronous create that SUCCEEDS but names no shape-conforming id yields nothing ──────────
printf 'garbage\n' > "$ADD_MODE"
got="$(_main_health_scribe_sync 'MAIN RED: fix app/greet.test.sh')"
[ -z "$got" ] || fail "(4) a create with no shape-conforming id in its output still produced a ref: '$got'"
ok "(4) a create whose own output carries no shape-conforming id yields NO ref — never fabricated"

# ── (5)/(6) end-to-end through _main_health_autofix + spawn: real id threaded, never double-filed ──
SPAWN_Q="$TREES_DIR/spawn-queue"
spawn_reqs() { ls "$SPAWN_Q"/*.req 2>/dev/null | wc -l | tr -d ' '; }
latest_req() { ls -t "$SPAWN_Q"/*.req 2>/dev/null | sed -n '1p'; }
head_sha() { git -C "$REPO" rev-parse HEAD; }
new_sha() {
  printf '%s\n' "$RANDOM$RANDOM" >> "$REPO/seed.txt"
  git -C "$REPO" add -A && git -C "$REPO" commit -q -m "$1"
}
reset_state() {
  rm -rf "$TREES_DIR"; mkdir -p "$TREES_DIR"
  : > "$JOURNAL_FILE"; : > "$NOTIFY_LOG"; : > "$SCRIBE_LOG"; : > "$ADD_ITEM_LOG"
}
settle() {
  local n=0
  while [ "$n" -lt 400 ]; do
    ls "$TREES_DIR"/.health-dispatch-main-* >/dev/null 2>&1 && break
    ls "$TREES_DIR"/.health-inflight-main-* >/dev/null 2>&1 || break
    sleep 0.05; n=$((n + 1))
  done
  _collect_main_health
}
jcount() { local n; n="$(grep -c "$1" "$JOURNAL_FILE" 2>/dev/null)" || n=0; printf '%s' "${n:-0}"; }

MAIN_HEALTH_TICK=on
MAIN_HEALTH_RECHECK_MINS=0
MAIN_HEALTH_CI_GATE=off
MAIN_HEALTH_AUTOFIX=spawn
export CLAIM_REQUIRED=off   # isolate this test from the HERD-543 open-item lookup — covered elsewhere

# (5) synchronous create SUCCEEDS — the real id threads all the way to the spawn's .ref sidecar, and
# the async scribe path is never ALSO invoked (no double-filing of the same item).
reset_state
printf 'ok\n' > "$ADD_MODE"
printf 'red-file\n' > "$HC_MODE"
new_sha "feat: reds main (sync create succeeds)"
reconcile_main_health; settle
[ "$(jcount '"event":"main_health_autofix".*"result":"enqueued"')" -ge 1 ] \
  || fail "(5) autofix did not journal enqueued: $(cat "$JOURNAL_FILE")"
[ "$(spawn_reqs)" -eq 1 ] || fail "(5) exactly one intent should have been enqueued: $(ls "$SPAWN_Q" 2>/dev/null)"
REQ5="$(latest_req)"
[ "$(cat "${REQ5%.req}.ref" 2>/dev/null)" = "HERD-901" ] \
  || fail "(5) the spawn's ref sidecar is not the synchronously-created real id: $(cat "${REQ5%.req}.ref" 2>/dev/null)"
[ ! -s "$SCRIBE_LOG" ] || fail "(5) the async scribe path ALSO fired despite a successful synchronous create (double-filing): $(cat "$SCRIBE_LOG")"
grep -q '"ref":"HERD-901"' "$JOURNAL_FILE" || fail "(5) the journal does not record ref=HERD-901: $(cat "$JOURNAL_FILE")"
ok "(5) a successful synchronous create threads the REAL tracker id end to end, with no redundant async filing"

# (6) synchronous create FAILS — falls back to the async scribe path, and the spawn is untracked
# (no ref sidecar at all) rather than carrying a fabricated one.
reset_state
printf 'fail\n' > "$ADD_MODE"
printf 'red-file\n' > "$HC_MODE"
new_sha "feat: reds main (sync create fails)"
reconcile_main_health; settle
[ "$(spawn_reqs)" -eq 1 ] || fail "(6) exactly one intent should have been enqueued: $(ls "$SPAWN_Q" 2>/dev/null)"
[ -s "$SCRIBE_LOG" ] || fail "(6) a failed synchronous create did not fall back to the async scribe path"
REQ6="$(latest_req)"
[ ! -e "${REQ6%.req}.ref" ] \
  || fail "(6) the spawn carries a ref sidecar despite the synchronous create failing: $(cat "${REQ6%.req}.ref" 2>/dev/null)"
ok "(6) a failed synchronous create falls back to the async path and spawns untracked — never a fabricated ref"

echo "ALL PASS ($pass checks)"
