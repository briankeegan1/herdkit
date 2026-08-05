#!/usr/bin/env bash
# test-red-auto-escalate.sh — hermetic proof of ENGINE-SHAPED RED AUTO-ESCALATION (HERD-547,
# HERD-539 leg 4, scripts/herd/agent-watch.sh + scripts/herd/red-ledger.sh + bin/herd `herd report
# --diagnosis`).
#
# Asserted here, driving the REAL functions (AGENT_WATCH_LIB=1, a stubbed `herd` binary standing in
# for HERDKIT_HOME/bin/herd via the HERD_RED_ESCALATE_HERD_BIN test seam, and the REAL shared-pool
# store against a scratch WORKTREES_DIR — exactly like tests/test-finish-stall-watchdog.sh):
#   (a) herd_red_ledger_engine_shaped (red-ledger.sh): true for why-text naming the engine surface
#       (bin/herd, scripts/herd/**, pysrc/herd/**, …); false for a project's own path, and for empty.
#   (b) RED_AUTOESCALATE=off (default) — _red_escalate_engine_red never shells to the stub, never
#       journals red_escalated, byte-identical to before this feature existed.
#   (c) RED_AUTOESCALATE=on + RED_LEDGER=off — still a no-op (requires the ledger's own lever too).
#   (d) an ENGINE-shaped why with both levers on files EXACTLY ONE escalation: the stub is invoked
#       once with the why-text on --diagnosis, and red_escalated is journaled result=filed.
#   (e) a PROJECT-shaped why (both levers on) files NOTHING — the stub is never invoked, and no
#       red_escalated is journaled at all (never a "declined" event for an out-of-scope red).
#   (f) a SECOND observation of the SAME dedup key no-ops: the stub is still invoked exactly once
#       total, and exactly one red_escalated is journaled, across two separate calls.
#   (g) a DIFFERENT dedup key (fresh sha) escalates independently — the once-guard is keyed, not global.
#   (h) `herd report` itself declining (stub exits non-zero — no gh, dedup, etc.) is fail-soft: no
#       crash, and result=skipped reason=report-failed is journaled instead of result=filed.
#
# Fully hermetic: temp dirs only, no network, no live watcher loop (AGENT_WATCH_LIB=1), no real gh.
# Run:  bash tests/test-red-auto-escalate.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
WATCH="$REPO/scripts/herd/agent-watch.sh"
LIB="$REPO/scripts/herd/red-ledger.sh"
PYSRC="$REPO/pysrc"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); printf 'ok — %s\n' "$1"; }

[ -f "$LIB" ]              || fail "scripts/herd/red-ledger.sh not found"
[ -f "$WATCH" ]            || fail "agent-watch.sh not found"
[ -f "$PYSRC/herd/store.py" ] || fail "pysrc/herd/store.py not found"
command -v python3 >/dev/null 2>&1 || fail "python3 required to run this test"

MAIN="$T/main"; POOL="$T/trees"
mkdir -p "$MAIN/.herd" "$POOL"
git -C "$MAIN" init -q -b main 2>/dev/null || true

BIN="$T/bin"; mkdir -p "$BIN"
for cmd in gh git herdr; do printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$cmd"; chmod +x "$BIN/$cmd"; done
export PATH="$BIN:$PATH"

# The stub standing in for HERDKIT_HOME/bin/herd (HERD_RED_ESCALATE_HERD_BIN test seam): records
# every invocation's argv (one line per call) to CALLS_LOG, and exits per REPORT_STUB_RC (default 0
# — "herd report filed cleanly"; a test flips it to simulate `herd report` declining).
HERD_STUB="$T/herd-stub"
cat > "$HERD_STUB" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CALLS_LOG:?CALLS_LOG unset}"
exit "${REPORT_STUB_RC:-0}"
STUB
chmod +x "$HERD_STUB"
CALLS_LOG="$T/calls.log"; : > "$CALLS_LOG"

export AGENT_WATCH_LIB=1 NO_COLOR=1 HERD_DRIVER=headless
export HERD_CONFIG_FILE="$T/no-such-config"
export PROJECT_ROOT="$MAIN" WORKTREES_DIR="$POOL"
export JOURNAL_FILE="$T/journal.jsonl"
export HERD_RED_ESCALATE_HERD_BIN="$HERD_STUB"
export CALLS_LOG REPORT_STUB_RC=0
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"

for fn in herd_red_ledger_engine_shaped _red_autoescalate_enabled _red_escalate_herd_bin \
          _red_escalate_once _red_escalate_engine_red; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined after sourcing"
done

TREES="$POOL"    # _red_escalate_once/_main_health_fix_pysrc read this bash var, not just the env
jcount() { local n; n="$(grep -c "$1" "$JOURNAL_FILE" 2>/dev/null)" || n=0; printf '%s' "${n:-0}"; }
ncalls() { local n; n="$(grep -c . "$CALLS_LOG" 2>/dev/null)" || n=0; printf '%s' "${n:-0}"; }
reset_all() { : > "$CALLS_LOG"; : > "$JOURNAL_FILE"; }

# ── (a) herd_red_ledger_engine_shaped: the routing-rule classifier ────────────────────────────────
herd_red_ledger_engine_shaped "scripts/herd/agent-watch.sh: line 42: unbound variable" \
  || fail "(a) a scripts/herd/ path did not classify as engine-shaped"
herd_red_ledger_engine_shaped "pysrc/herd/store.py:120: AssertionError" \
  || fail "(a) a pysrc/herd/ path did not classify as engine-shaped"
herd_red_ledger_engine_shaped "bin/herd: line 8: die: command not found" \
  || fail "(a) a bin/herd path did not classify as engine-shaped"
herd_red_ledger_engine_shaped "app/greet.test.sh: FAIL: expected 2 got 3" \
  && fail "(a) a project-shaped path misclassified as engine-shaped"
herd_red_ledger_engine_shaped "" \
  && fail "(a) an empty why misclassified as engine-shaped"
ok "(a) herd_red_ledger_engine_shaped: engine-surface paths true, a project path / empty false"

# ── (b) RED_AUTOESCALATE=off (default) — pure no-op ────────────────────────────────────────────────
reset_all
RED_LEDGER=on RED_AUTOESCALATE=off
_red_escalate_engine_red "main_health:offsha" main_health "scripts/herd/agent-watch.sh: boom"
[ "$(ncalls)" -eq 0 ] || fail "(b) RED_AUTOESCALATE=off still shelled to the report stub"
[ "$(jcount red_escalated)" -eq 0 ] || fail "(b) RED_AUTOESCALATE=off still journaled red_escalated"
ok "(b) RED_AUTOESCALATE=off (default): _red_escalate_engine_red is a pure no-op"

# ── (c) RED_AUTOESCALATE=on but RED_LEDGER=off — still requires BOTH levers ────────────────────────
reset_all
RED_LEDGER=off RED_AUTOESCALATE=on
_red_escalate_engine_red "main_health:noledger" main_health "scripts/herd/agent-watch.sh: boom"
[ "$(ncalls)" -eq 0 ] || fail "(c) RED_LEDGER=off still shelled to the report stub"
[ "$(jcount red_escalated)" -eq 0 ] || fail "(c) RED_LEDGER=off still journaled red_escalated"
ok "(c) RED_AUTOESCALATE=on with RED_LEDGER=off still no-ops (both levers required)"

# ── (d) ENGINE-shaped why, both levers on: files EXACTLY ONE escalation ────────────────────────────
reset_all
RED_LEDGER=on RED_AUTOESCALATE=on
_red_escalate_engine_red "main_health:enginesha1" main_health "scripts/herd/agent-watch.sh: line 42: unbound variable"
[ "$(ncalls)" -eq 1 ] || fail "(d) an engine-shaped red did not file exactly one escalation: $(ncalls)"
grep -q -- '--diagnosis scripts/herd/agent-watch.sh: line 42: unbound variable' "$CALLS_LOG" \
  || fail "(d) the stub call did not carry the why-text on --diagnosis: $(cat "$CALLS_LOG")"
grep -q 'report ' "$CALLS_LOG" || fail "(d) the stub was not invoked with the report subcommand"
[ "$(jcount '"event":"red_escalated".*"key":"main_health:enginesha1".*"result":"filed"')" -eq 1 ] \
  || fail "(d) red_escalated result=filed was not journaled with the right key"
ok "(d) an engine-shaped red files exactly one escalation, carrying the red-ledger diagnosis"

# ── (e) PROJECT-shaped why, both levers on: files NOTHING ──────────────────────────────────────────
reset_all
_red_escalate_engine_red "main_health:projectsha1" main_health "app/greet.test.sh: FAIL: expected 2 got 3"
[ "$(ncalls)" -eq 0 ] || fail "(e) a project-shaped red shelled to the report stub"
[ "$(jcount red_escalated)" -eq 0 ] || fail "(e) a project-shaped red journaled red_escalated"
ok "(e) a project-shaped red never escalates: no stub call, no journal line"

# ── (f) a SECOND observation of the SAME key no-ops ────────────────────────────────────────────────
reset_all
_red_escalate_engine_red "main_health:dupsha" main_health "scripts/herd/agent-watch.sh: dup case"
_red_escalate_engine_red "main_health:dupsha" main_health "scripts/herd/agent-watch.sh: dup case"
[ "$(ncalls)" -eq 1 ] || fail "(f) a repeat observation of the same key filed more than once: $(ncalls)"
[ "$(jcount red_escalated)" -eq 1 ] || fail "(f) a repeat observation journaled more than one red_escalated"
ok "(f) a second observation of the same dedup key no-ops (shared-pool once-guard)"

# ── (g) a DIFFERENT dedup key escalates independently ──────────────────────────────────────────────
_red_escalate_engine_red "main_health:freshsha" main_health "pysrc/herd/store.py: fresh case"
[ "$(ncalls)" -eq 2 ] || fail "(g) a fresh dedup key did not get its own escalation: $(ncalls)"
[ "$(jcount red_escalated)" -eq 2 ] || fail "(g) a fresh dedup key did not journal its own red_escalated"
ok "(g) a different dedup key escalates independently — the once-guard is keyed, not global"

# ── (h) `herd report` declining is fail-soft: no crash, journals skipped/report-failed ─────────────
reset_all
REPORT_STUB_RC=1
_red_escalate_engine_red "main_health:declinesha" main_health "scripts/herd/agent-watch.sh: gh missing"
[ "$(ncalls)" -eq 1 ] || fail "(h) the declining stub was not even invoked: $(ncalls)"
[ "$(jcount '"event":"red_escalated".*"key":"main_health:declinesha".*"result":"skipped".*"reason":"report-failed"')" -eq 1 ] \
  || fail "(h) a declining herd report did not journal result=skipped reason=report-failed"
REPORT_STUB_RC=0
ok "(h) herd report declining (no gh/HERD_REPO/dedup) is fail-soft: journaled, never a crash"

echo "PASS: $pass red-auto-escalate assertions ($0)"
