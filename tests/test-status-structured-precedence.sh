#!/usr/bin/env bash
# test-status-structured-precedence.sh — hermetic tests for HERD-768: the structured-signal-first
# entry point (herd_driver_agent_status_resolved_ex, scripts/herd/driver.sh) that sits ABOVE the
# existing pane/transcript-scrape resolver (herd_driver_agent_status_resolved, HERD-647/HERD-660,
# covered by tests/test-status-corroborate.sh — untouched by this change).
#
# HERD-754's acceptance criterion: "no auto-kill or lifecycle decision relies solely on argv, cwd, pane
# text, or process-name attribution." This proves the demote-precedence pass for codex specifically,
# where a REAL structured alternative now exists (codex-durable-coordinator.sh, HERD-766, itself built
# on codex-exec-adapter.sh's real JSON event parser, HERD-760):
#   (a) when a codex-durable session exists for a slug, its OWN tracked state answers the lifecycle
#       read and pane/argv inference is NEVER consulted (a poisoned pane stub proves this — reading it
#       would flip the answer, and it never does; the pane-corroboration snapshot store is never
#       created either, the same technique test-status-corroborate.sh's case (1) uses).
#   (b) when genuinely unavailable — no durable session for this slug, or the coordinator was never
#       even sourced (today's real-world condition: nothing wires it into agent-watch.sh yet) — the
#       fallback behaves EXACTLY like herd_driver_agent_status_resolved always has: no regression to
#       any existing runtime.
#   (c) the answer names which kind of evidence backed it ("... structured" vs "... fallback") so a
#       caller can tell the two apart, instead of them being indistinguishable.
#
# Sources journal.sh + driver.sh always; sources codex-durable-coordinator.sh (which pulls in
# codex-exec-adapter.sh) only for the back half of this file, so the front half exercises the REAL
# "capability not even sourced" fallback shape. Stubs herdr/gh/git. NETWORK-FREE, launches no real
# codex/claude binary — every fixture is written directly to disk (never inferred from pane text or
# argv, matching the adapter's own "never inferred from" design requirement).
# Run:  bash tests/test-status-structured-precedence.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DRIVER="$HERE/../scripts/herd/driver.sh"
DURABLE="$HERE/../scripts/herd/codex-durable-coordinator.sh"
JOURNAL_SRC="$HERE/../scripts/herd/journal.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

[ -f "$DRIVER" ] || fail "driver.sh not found at $DRIVER"
[ -f "$DURABLE" ] || fail "codex-durable-coordinator.sh not found at $DURABLE"
command -v jq >/dev/null 2>&1 || fail "jq required to run this test"
command -v python3 >/dev/null 2>&1 || fail "python3 required to run this test"

# ── Stub binaries on PATH (same shape as test-status-corroborate.sh) ─────────────────────────────
BIN="$T/bin"; mkdir -p "$BIN"
for cmd in gh git; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$cmd"; chmod +x "$BIN/$cmd"
done
# A POISONED herdr stub: `pane read` prints text that WOULD corroborate a raw 'idle' into 'working'
# via the pane-scrape path if it were ever consulted (active spinner chrome). Any test whose expected
# answer is NOT "working structured"/"working fallback"-by-real-corroboration must therefore prove the
# structured path short-circuited before this stub was ever read.
cat > "$BIN/herdr" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "agent list")
    printf '{"result":{"agents":[{"name":"%s","agent_status":"%s","pane_id":"%s"}]}}\n' \
      "${STUB_AGENT_NAME:-}" "${STUB_AGENT_STATUS:-idle}" "${STUB_AGENT_PANE_ID:-pane-x}"
    ;;
  "pane read") printf '%s\n' "${STUB_PANE_TEXT:-✳ Cogitating… (esc to interrupt) POISON}" ;;
  "notification") : ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$BIN/herdr"
export PATH="$BIN:$PATH"

export WORKTREES_DIR="$T/trees"; mkdir -p "$T/trees"
export JOURNAL_FILE="$T/journal.jsonl"

# shellcheck source=/dev/null
. "$JOURNAL_SRC" || fail "sourcing journal.sh failed"
# shellcheck source=/dev/null
. "$DRIVER" || fail "sourcing driver.sh (lib mode) failed"

# ══════════════════════════════════════════════════════════════════════════════════════════════════
# PART 1 — codex-durable-coordinator.sh NOT sourced at all: today's real-world condition. Every
# read must fall straight through to herd_driver_agent_status_resolved, unchanged, labeled fallback.
# ══════════════════════════════════════════════════════════════════════════════════════════════════
type codex_durable_status >/dev/null 2>&1 && fail "setup: codex_durable_status must not be defined yet in part 1"

for raw in working done "" parked; do
  plain="$(herd_driver_agent_status_resolved "part1-$raw" "$raw" "pane-1")"
  ex="$(herd_driver_agent_status_resolved_ex "part1-$raw" "$raw" "pane-1")"
  [ "$ex" = "$plain fallback" ] \
    || fail "1: _ex must equal plain resolver + ' fallback' when the coordinator isn't sourced (raw='$raw' got '$ex' plain='$plain')"
done
ok

# (2) an idle+active+delta corroboration still fires through the _ex wrapper exactly as it does
#     through the plain resolver (proves the wrapper doesn't dampen or duplicate the existing rescue).
: > "$JOURNAL_FILE"
export STUB_PANE_TEXT="✳ Cogitating… (esc to interrupt) (frame 1)"
_="$(herd_driver_agent_status_resolved_ex "part1-corrob" "idle" "pane-2")"
export STUB_PANE_TEXT="✳ Cogitating… (esc to interrupt) (frame 2)"
got="$(herd_driver_agent_status_resolved_ex "part1-corrob" "idle" "pane-2")"
[ "$got" = "working fallback" ] || fail "2: idle+active+delta via _ex must resolve to 'working fallback' (got '$got')"
ok
grep -q 'status_disagreement' "$JOURNAL_FILE" || fail "2: the underlying pane-rescue must still journal status_disagreement"
ok
unset STUB_PANE_TEXT

# ══════════════════════════════════════════════════════════════════════════════════════════════════
# PART 2 — codex-durable-coordinator.sh sourced (a caller that HAS the structured signal available),
# but THIS slug has no durable session ⇒ still falls straight through, byte-identical to part 1.
# ══════════════════════════════════════════════════════════════════════════════════════════════════
# shellcheck source=/dev/null
. "$DURABLE" || fail "sourcing codex-durable-coordinator.sh failed"
type codex_durable_status >/dev/null 2>&1 || fail "setup: codex_durable_status must be defined after sourcing"

for raw in working done "" parked; do
  plain="$(herd_driver_agent_status_resolved "part2-$raw" "$raw" "pane-1")"
  ex="$(herd_driver_agent_status_resolved_ex "part2-$raw" "$raw" "pane-1")"
  [ "$ex" = "$plain fallback" ] \
    || fail "3: _ex with no durable session for this slug must equal plain + ' fallback' (raw='$raw' got '$ex')"
done
ok

# ══════════════════════════════════════════════════════════════════════════════════════════════════
# PART 3 — a REAL codex-durable session on disk (built directly via codex_durable_init + hand-written
# turn artifacts — never a real codex/claude process, never a pane, never argv). Proves criterion (a):
# structured wins, pane is never consulted (the poisoned herdr stub would flip 'idle' to 'working' if
# it were ever read — every one of these fixtures passes raw='idle' and none of the non-working
# expectations come out 'working', so the poison never fired).
# ══════════════════════════════════════════════════════════════════════════════════════════════════
mk_session() {
  local slug="$1"
  codex_durable_init "$(_herd_codex_durable_session_dir "$slug")" "$T/some-workdir" >/dev/null
  printf '%s' "$(_herd_codex_durable_session_dir "$slug")"
}
mkdir -p "$T/some-workdir"

# (4) a turn currently in flight (a live tracked pid) ⇒ "working structured".
: > "$JOURNAL_FILE"
sdir="$(mk_session codex-working)"
printf '1' > "$sdir/turn"
printf '%s' "$$" > "$sdir/pid"   # this test's own shell pid — genuinely alive for the test's duration
got="$(herd_driver_agent_status_resolved_ex "codex-working" "idle" "pane-3")"
[ "$got" = "working structured" ] || fail "4: a live durable session must resolve to 'working structured' (got '$got')"
ok
[ ! -e "$T/trees/.herd/status-resolve/codex-working" ] \
  || fail "4: a structured resolve must NEVER create this slug's pane-corroboration snapshot (pane was consulted)"
ok
[ ! -s "$JOURNAL_FILE" ] || fail "4: a structured resolve must never journal status_disagreement (that's the scrape path's own marker)"
ok

# (5) no turn in flight + the last turn's parsed state is 'completed' ⇒ "done structured".
sdir="$(mk_session codex-done)"
printf '1' > "$sdir/turn"
cat > "$sdir/turns/001.jsonl" <<'JSONL'
{"type":"thread.started","thread_id":"t-done"}
{"type":"turn.started"}
{"type":"turn.completed","usage":{"input_tokens":1,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":1,"reasoning_output_tokens":0}}
JSONL
printf '0' > "$sdir/turns/001.exit"
got="$(herd_driver_agent_status_resolved_ex "codex-done" "idle" "pane-4")"
[ "$got" = "done structured" ] || fail "5: a completed durable turn must resolve to 'done structured' (got '$got')"
ok
[ ! -e "$T/trees/.herd/status-resolve/codex-done" ] \
  || fail "5: 'done structured' must never have touched this slug's pane-corroboration snapshot"
ok

# (6) no turn in flight + the last turn FAILED ⇒ "idle structured" (not silently mapped to done, not a
#     guess — codex's own parsed turn state says failed).
sdir="$(mk_session codex-failed)"
printf '1' > "$sdir/turn"
cat > "$sdir/turns/001.jsonl" <<'JSONL'
{"type":"thread.started","thread_id":"t-failed"}
{"type":"turn.started"}
{"type":"turn.failed","error":{"message":"boom"}}
JSONL
printf '1' > "$sdir/turns/001.exit"
got="$(herd_driver_agent_status_resolved_ex "codex-failed" "idle" "pane-5")"
[ "$got" = "idle structured" ] || fail "6: a failed durable turn must resolve to 'idle structured', not done (got '$got')"
ok

# (7) a cancelled session (no pid alive, status=cancelled) ⇒ "idle structured" — resumable, not dead.
sdir="$(mk_session codex-cancelled)"
printf '1' > "$sdir/turn"
printf 'cancelled' > "$sdir/status"
got="$(herd_driver_agent_status_resolved_ex "codex-cancelled" "working" "pane-6")"
[ "$got" = "idle structured" ] || fail "7: a cancelled durable session must resolve to 'idle structured' regardless of the raw arg (got '$got')"
ok

echo "ALL PASS ($pass checks)"
