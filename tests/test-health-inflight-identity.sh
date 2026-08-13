#!/usr/bin/env bash
# test-health-inflight-identity.sh — hermetic proof of the four HERD-736 in-flight-identity legs over
# agent-watch.sh's health-inflight substrate:
#
#   (1) HEARTBEAT CORROBORATION — a marker whose tracked pid is dead (or unprovable) is NOT declared
#       dead when its progress-log heartbeat is still fresh (`_inflight_verified_live` / `_health_pid_live`).
#   (2) ADOPT-OR-REAP — the corpse sweep leaves a heartbeat-adopted marker exactly as-is (never reaped,
#       never re-dispatched over), journals `health_inflight_adopted` ONCE, while a marker with NO
#       corroborating heartbeat is still reaped as a genuine corpse (`health_died`), unchanged from
#       before.
#   (3) REDISPATCH VISIBILITY — the 2nd+ dispatch for one exact (pr,sha)/main-<sha> key journals a
#       distinct, undeduped `health_redispatch_loop` event.
#   (4) BOOT RECONCILE — `_health_inflight_boot_reconcile` adopts (journals, leaves alone) a live/
#       heartbeat-corroborated marker and verified-kills + reaps a genuinely dead one, on sight.
#
# Fully hermetic: temp dir only, stubbed gh/git/herdr, headless driver, NO network/model/panes. Mirrors
# tests/test-restart-safe-dispatch.sh's planted-marker style (the established pattern for exercising
# _sweep_gate_corpses without a real suite) and test-watcher-health-cache.sh's drive_gate/stub-binary
# style for the one true end-to-end dispatch.
# Run:  bash tests/test-health-inflight-identity.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../scripts/herd/agent-watch.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ pass=$((pass+1)); }
[ -f "$WATCH" ] || fail "agent-watch.sh not found at $WATCH"

BIN="$T/bin"; mkdir -p "$BIN"
for cmd in gh git herdr; do printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$cmd"; chmod +x "$BIN/$cmd"; done
export PATH="$BIN:$PATH"

export AGENT_WATCH_LIB=1
export HERD_DRIVER=headless
export WORKTREES_DIR="$T/trees"; mkdir -p "$T/trees"
export HERD_CONFIG_FILE="$T/no-such-config"
export JOURNAL_FILE="$T/journal.jsonl"; : > "$JOURNAL_FILE"
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"
render() { :; }

case "$(_journal_file)" in "$T"/*) : ;; *) fail "journal path escapes the sandbox: '$(_journal_file)' (issue #144)" ;; esac

for fn in _sweep_gate_corpses _marker_write _marker_live _inflight_verified_live _health_pid_live \
          _health_heartbeat_file _heartbeat_fresh _health_key_from_inflight _health_dispatch_count_file \
          _health_bump_dispatch_count _health_redispatch_loop_note _health_inflight_boot_reconcile \
          _health_inflight_file _health_dispatch_file _health_log_file _health_terminate_worker \
          _health_adopted_file; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined after sourcing"
done
ok

TREES="$WORKTREES_DIR"
mk_marker(){ printf '%s\n%s\n%s\n' "$2" "$3" "$4" > "$1"; }
dead_pid(){ bash -c 'exit 0' & local p=$!; wait "$p" 2>/dev/null; printf '%s' "$p"; }
jgrep(){ local n; n="$(grep -c "$1" "$JOURNAL_FILE" 2>/dev/null || true)"; printf '%s' "${n:-0}"; }
NOW="$(date +%s)"

# ── (1)+(2) ADOPTED: dead pid, FRESH heartbeat → never reaped, adopted once ────────────────────────
: > "$JOURNAL_FILE"
DP="$(dead_pid)"
KEY1="401-shaAdopt"
INF1="$(_health_inflight_file "$KEY1")"
mk_marker "$INF1" "$DP" "irrelevant start" "$NOW"
HB1="$(_health_heartbeat_file "$KEY1")"
mkdir -p "$(dirname "$HB1")"
printf 'progress line\n' > "$HB1"          # fresh mtime (just written)

_health_pid_live "$INF1" || fail "leg1: dead pid + fresh heartbeat must read as live (adopted)"
ok

ADOPTED1="$(_health_adopted_file "$KEY1")"
_sweep_gate_corpses
[ -f "$INF1" ] || fail "leg2: adopted marker must NOT be reaped by the corpse sweep"
[ -f "$ADOPTED1" ] || fail "leg2: adopted marker must gain a .health-adopted-<key> sidecar"
[ "$(jgrep 'health_inflight_adopted')" -ge 1 ] || fail "leg2: health_inflight_adopted must be journaled"
[ "$(jgrep 'health_died')" -eq 0 ] || fail "leg2: adopted key must never journal health_died"
ok

# PR #808 round-1 review regression: the adopted sidecar must NOT share the .health-inflight- prefix —
# every OTHER companion file lives under its own distinct prefix precisely so this glob only ever
# matches real markers. A sidecar that collided here was itself mis-walked as a marker (empty pid ->
# treated as a corpse -> rm'd + a phantom health_died, and the once-only guard defeated every sweep).
case "$ADOPTED1" in
  "$TREES"/.health-inflight-*) fail "leg2: the adopted sidecar must NOT match the .health-inflight-* glob (was: $ADOPTED1)" ;;
esac
ok

# a second sweep tick must not re-journal the adoption (once-only guard) — this is the DIRECT proof the
# sidecar naming fix restores: before it, the sidecar itself was reaped as a phantom corpse every sweep,
# which recreated it and re-journaled the adoption note every ~2 ticks.
_N_ADOPT_BEFORE="$(jgrep 'health_inflight_adopted')"
_sweep_gate_corpses
[ -f "$INF1" ] || fail "leg2: the real marker must still be standing after a second sweep tick"
[ "$(jgrep 'health_inflight_adopted')" -eq "$_N_ADOPT_BEFORE" ] || fail "leg2: adoption note must be once-only, not re-journaled every sweep"
[ "$(jgrep 'health_died')" -eq 0 ] || fail "leg2: a second sweep must never phantom-reap the sidecar itself as a dead marker"
ok

# ── (1)+(2) GENUINE CORPSE: dead pid, STALE/absent heartbeat → reaped, health_died journaled ───────
: > "$JOURNAL_FILE"
DP2="$(dead_pid)"
KEY2="402-shaCorpse"
INF2="$(_health_inflight_file "$KEY2")"
mk_marker "$INF2" "$DP2" "irrelevant start" "$NOW"
# no heartbeat file at all for this key.
_health_pid_live "$INF2" && fail "leg1: dead pid + no heartbeat must NOT read as live"
ok

_sweep_gate_corpses
[ -f "$INF2" ] && fail "leg2: a genuine corpse (no heartbeat) must still be reaped"
[ "$(jgrep 'health_died')" -ge 1 ] || fail "leg2: health_died must still be journaled for a genuine corpse"
ok

# a heartbeat that exists but is STALE (older than the grace window) must not adopt either. Rather than
# backdate the file (touch -t's format differs across platforms), pin HERD_FAKE_NOW far enough into the
# FUTURE that the heartbeat's real (unmodified) mtime reads as stale — file_mtime always reads the real
# filesystem clock, so this is a portable way to simulate age.
: > "$JOURNAL_FILE"
DP3="$(dead_pid)"
KEY3="403-shaStaleHb"
INF3="$(_health_inflight_file "$KEY3")"
mk_marker "$INF3" "$DP3" "irrelevant start" "$NOW"
HB3="$(_health_heartbeat_file "$KEY3")"
printf 'old\n' > "$HB3"
HERD_FAKE_NOW=$(( NOW + _HEALTH_HEARTBEAT_GRACE + 60 )) _health_pid_live "$INF3" \
  && fail "leg1: a STALE heartbeat must not corroborate liveness"
ok

# ── (3) REDISPATCH VISIBILITY — 2nd+ dispatch for one key journals health_redispatch_loop ──────────
: > "$JOURNAL_FILE"
KEY4="404-shaRedispatch"
N1="$(_health_bump_dispatch_count "$KEY4")"
[ "$N1" = "1" ] || fail "leg3: first bump must read 1, got '$N1'"
_health_redispatch_loop_note "$KEY4" "$N1" 404 shaRedispatch some-slug
[ "$(jgrep 'health_redispatch_loop')" -eq 0 ] || fail "leg3: the FIRST dispatch must never journal health_redispatch_loop"
ok

N2="$(_health_bump_dispatch_count "$KEY4")"
[ "$N2" = "2" ] || fail "leg3: second bump must read 2, got '$N2'"
_health_redispatch_loop_note "$KEY4" "$N2" 404 shaRedispatch some-slug
[ "$(jgrep 'health_redispatch_loop')" -eq 1 ] || fail "leg3: the SECOND dispatch must journal exactly one health_redispatch_loop"
ok

N3="$(_health_bump_dispatch_count "$KEY4")"
_health_redispatch_loop_note "$KEY4" "$N3" 404 shaRedispatch some-slug
[ "$(jgrep 'health_redispatch_loop')" -eq 2 ] || fail "leg3: the loop note is UNDEDUPED — every re-dispatch past the first journals again"
ok

# ── (4) BOOT RECONCILE — adopt a live marker, verified-kill + reap a genuinely dead one ────────────
: > "$JOURNAL_FILE"
# a genuinely LIVE marker (this test process itself, so kill -0 succeeds and starttime matches).
LIVE_KEY="405-shaBootLive"
LIVE_INF="$(_health_inflight_file "$LIVE_KEY")"
_marker_write "$LIVE_INF" "$$"
# a genuinely dead one, no heartbeat.
DEAD_KEY="406-shaBootDead"
DP4="$(dead_pid)"
DEAD_INF="$(_health_inflight_file "$DEAD_KEY")"
mk_marker "$DEAD_INF" "$DP4" "irrelevant start" "$NOW"

_health_inflight_boot_reconcile

[ -f "$LIVE_INF" ] || fail "leg4: a genuinely live marker must be ADOPTED (left in place) at boot"
[ "$(jgrep 'health_inflight_boot_adopted')" -ge 1 ] || fail "leg4: health_inflight_boot_adopted must be journaled for the live marker"
[ -f "$DEAD_INF" ] && fail "leg4: a genuinely dead marker must be reaped at boot"
[ "$(jgrep 'health_inflight_boot_orphan_reaped')" -ge 1 ] || fail "leg4: health_inflight_boot_orphan_reaped must be journaled for the dead marker"
ok

echo "ok - test-health-inflight-identity.sh ($pass assertions)"
