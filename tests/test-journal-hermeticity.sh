#!/usr/bin/env bash
# test-journal-hermeticity.sh — hermetic proof of HERD-223 JOURNAL HERMETICITY:
#
#   Test fixtures must NEVER append to the REAL project journal
#   ($WORKTREES_DIR/.herd/journal.jsonl from the committed .herd/config).
#
# Two shared layers (kept in lockstep with .herd/healthcheck.project.sh +
# scripts/herd/journal-test-env.sh + scripts/herd/journal.sh):
#   (A) shared TEST layer — journal-test-env.sh always exports JOURNAL_FILE to a temp path
#   (B) GUARD in journal.sh — a journal_append from a test context (HERMETIC_TEST /
#       HERD_HERMETIC_GUARD / HERD_JOURNAL_HERMETIC / BATS_*) that forgot JOURNAL_FILE is
#       fail-safe-redirected to TMPDIR, never to $WORKTREES_DIR/.herd/journal.jsonl
#
# Fully hermetic: temp dirs only, no network, never touches the live control room. When a
# real project journal happens to be readable we ALSO assert its byte-count is unchanged by
# a fixture run (the production-surface proof); that assertion is skip-soft if the path is
# absent (CI / clean machines).
#
# Run:  bash tests/test-journal-hermeticity.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
JOURNAL_SH="$ROOT/scripts/herd/journal.sh"
JTE_SH="$ROOT/scripts/herd/journal-test-env.sh"
TRIG="$ROOT/scripts/herd/triggers.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ pass=$((pass+1)); }

[ -f "$JOURNAL_SH" ] || fail "journal.sh not found at $JOURNAL_SH"
[ -f "$JTE_SH" ]     || fail "journal-test-env.sh not found at $JTE_SH"
[ -f "$TRIG" ]       || fail "triggers.sh not found at $TRIG"
command -v python3 >/dev/null 2>&1 || fail "python3 required"

# ── A synthetic "real" project journal the fixture must NOT touch ───────────────────────────────
FAKE_ROOT="$T/real-project"
FAKE_TREES="$T/real-trees"
FAKE_JOURNAL="$FAKE_TREES/.herd/journal.jsonl"
mkdir -p "$FAKE_ROOT/.herd" "$FAKE_TREES/.herd"
# Seed a known production-looking event so we can detect any append.
printf '%s\n' '{"ts":"2026-01-01T00:00:00Z","event":"seed","pr":1}' > "$FAKE_JOURNAL"
SEED_BYTES="$(wc -c < "$FAKE_JOURNAL" | tr -cd '0-9')"
SEED_SHA="$(cksum < "$FAKE_JOURNAL" | awk '{print $1" "$2}')"

# ── (A) shared TEST layer: sourcing journal-test-env.sh pins JOURNAL_FILE ───────────────────────
(
  unset JOURNAL_FILE HERD_JOURNAL_HERMETIC 2>/dev/null || true
  # shellcheck source=scripts/herd/journal-test-env.sh
  . "$JTE_SH" "$T/layer-a"
  [ -n "${JOURNAL_FILE:-}" ] || exit 1
  case "$JOURNAL_FILE" in
    "$T/layer-a"/*) ;;
    *) exit 2 ;;
  esac
  [ "${HERD_JOURNAL_HERMETIC:-}" = "1" ] || exit 3
  # Idempotent: a second source does not clobber an explicit JOURNAL_FILE.
  keep="$JOURNAL_FILE"
  # shellcheck source=scripts/herd/journal-test-env.sh
  . "$JTE_SH" "$T/layer-a-other"
  [ "$JOURNAL_FILE" = "$keep" ] || exit 4
) || fail "(A) journal-test-env.sh must pin JOURNAL_FILE under the supplied dir and set HERD_JOURNAL_HERMETIC (rc=$?)"
ok
echo "PASS (A) shared TEST layer (journal-test-env.sh) pins JOURNAL_FILE + HERD_JOURNAL_HERMETIC"

# ── (B) GUARD: test-context journal_append never touches WORKTREES_DIR journal ──────────────────
# Simulate the bug: WORKTREES_DIR points at the "real" trees, JOURNAL_FILE is UNset, but a test
# signal is present. journal_append must NOT grow FAKE_JOURNAL.
before_b="$SEED_BYTES"
(
  unset JOURNAL_FILE 2>/dev/null || true
  export WORKTREES_DIR="$FAKE_TREES"
  export HERMETIC_TEST="test-journal-hermeticity.sh"
  # shellcheck source=scripts/herd/journal.sh
  . "$JOURNAL_SH"
  # Resolve path must NOT be the fake real journal.
  jf="$(_journal_file)"
  case "$jf" in
    "$FAKE_JOURNAL") exit 1 ;;
    "") exit 2 ;;
  esac
  journal_append trigger_tick name watch-a schedule '@hourly' outcome first-run spawns 2
  journal_append trigger_spawn name watch-a slug watch-a-x lane quick item x
  # The redirect target must have received the events.
  [ -f "$jf" ] || exit 3
  grep -q '"event":"trigger_tick"' "$jf" || exit 4
  grep -q '"event":"trigger_spawn"' "$jf" || exit 5
) || fail "(B) guard: test-context journal_append must redirect away from WORKTREES_DIR journal (rc=$?)"
after_b="$(wc -c < "$FAKE_JOURNAL" | tr -cd '0-9')"
[ "$after_b" = "$before_b" ] || fail "(B) FAKE real journal grew under HERMETIC_TEST ($before_b → $after_b)"
# Also under HERD_JOURNAL_HERMETIC alone (no HERMETIC_TEST).
(
  unset JOURNAL_FILE HERMETIC_TEST 2>/dev/null || true
  export WORKTREES_DIR="$FAKE_TREES"
  export HERD_JOURNAL_HERMETIC=1
  # shellcheck source=scripts/herd/journal.sh
  . "$JOURNAL_SH"
  jf="$(_journal_file)"
  [ "$jf" != "$FAKE_JOURNAL" ] || exit 1
  journal_append fixture_event k v
) || fail "(B2) HERD_JOURNAL_HERMETIC alone must trigger the fail-safe redirect"
after_b2="$(wc -c < "$FAKE_JOURNAL" | tr -cd '0-9')"
[ "$after_b2" = "$before_b" ] || fail "(B2) FAKE real journal grew under HERD_JOURNAL_HERMETIC"
ok
echo "PASS (B) journal.sh fail-safe redirects test-context appends away from WORKTREES_DIR journal"

# ── (B3) production path is UNCHANGED when no test signal is set ────────────────────────────────
(
  unset JOURNAL_FILE HERMETIC_TEST HERD_HERMETIC_GUARD HERD_JOURNAL_HERMETIC \
        BATS_TEST_FILENAME BATS_TEST_NAME 2>/dev/null || true
  export WORKTREES_DIR="$FAKE_TREES"
  # shellcheck source=scripts/herd/journal.sh
  . "$JOURNAL_SH"
  jf="$(_journal_file)"
  [ "$jf" = "$FAKE_JOURNAL" ] || exit 1
  journal_append prod_event pr 42
) || fail "(B3) without test signals, journal_append must use WORKTREES_DIR/.herd/journal.jsonl"
grep -q '"event":"prod_event"' "$FAKE_JOURNAL" || fail "(B3) production path did not receive the event"
# Restore the seed-only journal for later size checks (drop the prod event).
printf '%s\n' '{"ts":"2026-01-01T00:00:00Z","event":"seed","pr":1}' > "$FAKE_JOURNAL"
SEED_BYTES="$(wc -c < "$FAKE_JOURNAL" | tr -cd '0-9')"
ok
echo "PASS (B3) production path is byte-identical when no test signal is set"

# ── (C) end-to-end: a triggers fixture that journals does NOT grow a "real" journal ─────────────
# Mirrors the historical pollution path: triggers.sh CLI re-sources herd-config (which would load
# a real WORKTREES_DIR) and journals trigger_tick/trigger_spawn. With the shared layer + guard,
# a simulated real journal's byte-count must stay unchanged.
REALISH_CFG="$T/cfg-realish"
mkdir -p "$REALISH_CFG"
cat > "$REALISH_CFG/config" <<EOF
PROJECT_ROOT="$FAKE_ROOT"
WORKTREES_DIR="$FAKE_TREES"
WORKSPACE_NAME="jherm-fake"
EOF
# Build a minimal triggers fixture and run tick under HERMETIC_TEST (as the suite runner does),
# WITHOUT exporting JOURNAL_FILE — so only the GUARD stands between us and the real journal.
FIX="$T/triggers.tsv"
INPUT="$T/input-a"; printf 'x\ny\n' > "$INPUT"
printf 'watch-a\t@hourly\tquick\tFix {item}.\tcat %s\n' "$INPUT" > "$FIX"
SPAWNLOG="$T/spawn.log"; : > "$SPAWNLOG"
STUB="$T/spawn-stub.sh"
cat > "$STUB" <<'STUB'
#!/usr/bin/env bash
printf '%s|%s|%s\n' "$1" "$2" "$3" >> "${SPAWNLOG:?}"
exit 0
STUB
chmod +x "$STUB"

before_c="$(wc -c < "$FAKE_JOURNAL" | tr -cd '0-9')"
before_sha="$(cksum < "$FAKE_JOURNAL" | awk '{print $1" "$2}')"
(
  # Deliberately do NOT set JOURNAL_FILE — exercise the fail-safe alone.
  unset JOURNAL_FILE 2>/dev/null || true
  export HERMETIC_TEST="test-journal-hermeticity.sh"
  export HERD_CONFIG_FILE="$REALISH_CFG/config"
  export HERD_TRIGGERS_FILE="$FIX"
  export HERD_TRIGGERS_STATE_DIR="$T/tstate"
  export HERD_TRIGGERS_SPAWN_CMD="$STUB"
  export HERD_TRIGGERS_INPUT_DIR="$T"
  export SPAWNLOG
  bash "$TRIG" tick --now 1000000000 >/dev/null 2>&1
) || fail "(C) triggers fixture tick failed under HERMETIC_TEST"
after_c="$(wc -c < "$FAKE_JOURNAL" | tr -cd '0-9')"
after_sha="$(cksum < "$FAKE_JOURNAL" | awk '{print $1" "$2}')"
[ "$after_c" = "$before_c" ] || fail "(C) realish journal byte-count changed by triggers fixture ($before_c → $after_c)"
[ "$after_sha" = "$before_sha" ] || fail "(C) realish journal content changed by triggers fixture"
# And the fixture did actually journal somewhere (the redirect), and spawn.
[ -s "$SPAWNLOG" ] || fail "(C) triggers fixture must still spawn (got empty spawn log)"
ok
echo "PASS (C) triggers fixture under HERMETIC_TEST leaves realish journal byte-count unchanged"

# ── (D) with the shared layer (JOURNAL_FILE set), same guarantee + events land in the temp file ─
TMPJ="$T/layer-d/journal.jsonl"
mkdir -p "$T/layer-d"; : > "$TMPJ"
before_d="$(wc -c < "$FAKE_JOURNAL" | tr -cd '0-9')"
(
  export JOURNAL_FILE="$TMPJ"
  export HERD_JOURNAL_HERMETIC=1
  export HERMETIC_TEST="test-journal-hermeticity.sh"
  export HERD_CONFIG_FILE="$REALISH_CFG/config"
  export HERD_TRIGGERS_FILE="$FIX"
  export HERD_TRIGGERS_STATE_DIR="$T/tstate2"
  export HERD_TRIGGERS_SPAWN_CMD="$STUB"
  export HERD_TRIGGERS_INPUT_DIR="$T"
  export SPAWNLOG
  : > "$SPAWNLOG"
  bash "$TRIG" tick --now 1000000000 >/dev/null 2>&1
) || fail "(D) triggers fixture with JOURNAL_FILE set failed"
after_d="$(wc -c < "$FAKE_JOURNAL" | tr -cd '0-9')"
[ "$after_d" = "$before_d" ] || fail "(D) realish journal grew even with JOURNAL_FILE set"
grep -q '"event":"trigger_tick"' "$TMPJ"  || fail "(D) events must land in the pinned JOURNAL_FILE"
grep -q '"event":"trigger_spawn"' "$TMPJ" || fail "(D) spawn events must land in the pinned JOURNAL_FILE"
grep -q 'watch-a' "$TMPJ"                 || fail "(D) fixture slug must appear in the temp journal"
ok
echo "PASS (D) shared layer: JOURNAL_FILE receives fixture events; realish journal untouched"

# ── (E) optional: live project journal (if present) is unchanged by a mini fixture ──────────────
# Resolve the dogfood WORKTREES_DIR the same way a leaky test would (source the committed config
# from the engine tree). Skip-soft when the path is absent (CI, fresh machines).
LIVE_JOURNAL=""
if [ -f "$ROOT/.herd/config" ]; then
  LIVE_JOURNAL="$(
    set +eu 2>/dev/null || true
    # shellcheck source=/dev/null
    . "$ROOT/.herd/config" 2>/dev/null || true
    if [ -n "${WORKTREES_DIR:-}" ] && [ -f "${WORKTREES_DIR}/.herd/journal.jsonl" ]; then
      printf '%s' "${WORKTREES_DIR}/.herd/journal.jsonl"
    fi
  )"
fi
if [ -n "$LIVE_JOURNAL" ] && [ -f "$LIVE_JOURNAL" ]; then
  live_before="$(wc -c < "$LIVE_JOURNAL" | tr -cd '0-9')"
  live_sha="$(cksum < "$LIVE_JOURNAL" | awk '{print $1" "$2}')"
  (
    # shellcheck source=scripts/herd/journal-test-env.sh
    . "$JTE_SH" "$T/live-probe"
    # shellcheck source=scripts/herd/journal.sh
    . "$JOURNAL_SH"
    journal_append hermeticity_probe source test-journal-hermeticity
  ) || fail "(E) live-probe journal_append failed"
  live_after="$(wc -c < "$LIVE_JOURNAL" | tr -cd '0-9')"
  live_sha2="$(cksum < "$LIVE_JOURNAL" | awk '{print $1" "$2}')"
  [ "$live_after" = "$live_before" ] || fail "(E) LIVE project journal byte-count changed ($live_before → $live_after) at $LIVE_JOURNAL"
  [ "$live_sha2" = "$live_sha" ] || fail "(E) LIVE project journal content changed at $LIVE_JOURNAL"
  ok
  echo "PASS (E) live project journal byte-count unchanged by a fixture that journals ($LIVE_JOURNAL)"
else
  ok
  echo "PASS (E) live project journal absent — skip-soft (CI / clean machine)"
fi

echo
echo "ALL PASS ($pass checks) — journal hermeticity: shared TEST layer + journal.sh fail-safe guard (HERD-223)."
