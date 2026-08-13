#!/usr/bin/env bash
# test-status-corroborate.sh — hermetic tests for HERD-647: the shared agent_status corroboration
# resolver (herd_driver_agent_status_resolved, scripts/herd/driver.sh) and its wiring into every
# agent_status consumer in agent-watch.sh.
#
# Regression target: after the #632 Enter-nudge recovery, `herdr agent list` can keep reporting
# agent_status=idle for a builder that is demonstrably still working (task-specific pane chrome +
# active spinner glyph + fresh pane-content repaint) — fooling the watcher's "awaiting task"
# classification. GROUNDED on herdkit itself 2026-08-11 (hv-policy-aware-audit ~20:35Z,
# merged-worktree-truth ~20:51Z). tests/test-spawn-wake-verify.sh already proves the driver-level
# wake-verify integration end to end (cases e/f/g/h); THIS file proves:
#   (1) herd_driver_agent_status_resolved directly — non-idle passthrough (zero pane reads), the
#       AND-gated corroboration (active chrome + content delta), the dead-builder guardrail (active
#       chrome alone, frozen pane, is never enough), and the HERD_STATUS_CORROBORATE=off kill switch.
#   (2) agent-watch.sh's _agent_status() — the ~30-call-site oracle every bounce/refix/wedge/
#       finish-stall/dead-builder rail reads — is wired through the SAME resolver, so a single edit
#       covers every one of those callers.
#
# Sources driver.sh directly (part 1) and agent-watch.sh in lib mode (part 2). Stubs herdr/gh/git.
# NETWORK-FREE, launches no real claude.
# Run:  bash tests/test-status-corroborate.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DRIVER="$HERE/../scripts/herd/driver.sh"
WATCH="$HERE/../scripts/herd/agent-watch.sh"
JOURNAL_SRC="$HERE/../scripts/herd/journal.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

[ -f "$DRIVER" ] || fail "driver.sh not found at $DRIVER"
[ -f "$WATCH" ] || fail "agent-watch.sh not found at $WATCH"
command -v python3 >/dev/null 2>&1 || fail "python3 required to run this test"

# ── Stub binaries on PATH ─────────────────────────────────────────────────────
BIN="$T/bin"; mkdir -p "$BIN"
for cmd in gh git; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$cmd"; chmod +x "$BIN/$cmd"
done
# herdr stub: `agent list` reports STUB_AGENT_NAME/STUB_AGENT_STATUS; `pane read` serves
# STUB_PANE_TEXT verbatim (this test drives the resolver directly — no poll loop, so no
# per-call frame-counter variance is needed; each call passes a caller-controlled text instead).
cat > "$BIN/herdr" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "agent list")
    printf '{"result":{"agents":[{"name":"%s","agent_status":"%s","pane_id":"%s"}]}}\n' \
      "${STUB_AGENT_NAME:-}" "${STUB_AGENT_STATUS:-idle}" "${STUB_AGENT_PANE_ID:-pane-x}"
    ;;
  "pane read") printf '%s\n' "${STUB_PANE_TEXT:-}" ;;
  "notification") : ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$BIN/herdr"
export PATH="$BIN:$PATH"

export WORKTREES_DIR="$T/trees"; mkdir -p "$T/trees"
export HERD_TRANSCRIPT_ROOT="$T/claude-projects"; mkdir -p "$HERD_TRANSCRIPT_ROOT"
export JOURNAL_FILE="$T/journal.jsonl"

# write_transcript <slug> <bytes> — create/replace a single-file transcript for <slug>'s worktree
# ($WORKTREES_DIR/<slug>, the standard builder-worktree layout) with exactly <bytes> of content, at a
# FRESH mtime (touch after write, since some filesystems have 1s mtime resolution and two writes in
# the same wall-clock second would otherwise look byte-grown but not mtime-grown, or vice versa —
# either signal alone is enough for _herd_wake_transcript_growing, but keeping both moving avoids a
# flaky assertion on a fast filesystem).
write_transcript() {
  local slug="$1" n="$2" wt dir
  wt="$WORKTREES_DIR/$slug"; mkdir -p "$wt"
  dir="$HERD_TRANSCRIPT_ROOT/$(printf '%s' "$wt" | tr '/.' '-')"; mkdir -p "$dir"
  python3 -c "import sys; sys.stdout.write('x' * int(sys.argv[1]))" "$n" > "$dir/session.jsonl"
  touch "$dir/session.jsonl"
}
# shellcheck source=/dev/null
. "$JOURNAL_SRC" || fail "sourcing journal.sh failed"
# shellcheck source=/dev/null
. "$DRIVER" || fail "sourcing driver.sh (lib mode) failed"

ACTIVE="✳ Cogitating… (esc to interrupt)"
IDLE_PROMPT="> "

# ══════════════════════════════════════════════════════════════════════════════════════════════════
# PART 1 — herd_driver_agent_status_resolved, direct
# ══════════════════════════════════════════════════════════════════════════════════════════════════

# (1) non-idle raw status is returned UNCHANGED, with NO pane read at all (zero cost on the majority
#     path). Prove no pane read happened by pointing STUB_AGENT_PANE_ID at a pane whose read would
#     blow up the test if consulted (it can't — herdr's stub just echoes STUB_PANE_TEXT — so instead
#     assert no delta-snapshot file was written, which only happens on an actual corroboration attempt).
: > "$JOURNAL_FILE"
rm -rf "$T/trees/.herd/status-resolve"
for raw in working done "" parked; do
  got="$(herd_driver_agent_status_resolved "some-slug" "$raw" "pane-1")"
  [ "$got" = "$raw" ] || fail "1: raw '$raw' must pass through unchanged (got '$got')"
done
ok
[ ! -d "$T/trees/.herd/status-resolve" ] \
  || fail "1: a non-idle raw status must never touch the corroboration store (dir exists)"
ok
[ ! -s "$JOURNAL_FILE" ] || fail "1: a non-idle raw status must never journal (got: $(cat "$JOURNAL_FILE"))"
ok

# (2) idle + active chrome + a content delta ⇒ corroborated 'working', journaled once.
: > "$JOURNAL_FILE"
export STUB_PANE_TEXT="$ACTIVE (frame 1)"
got="$(herd_driver_agent_status_resolved "corrob-a" "idle" "pane-2")"
export STUB_PANE_TEXT="$ACTIVE (frame 2)"
got="$(herd_driver_agent_status_resolved "corrob-a" "idle" "pane-2")"
[ "$got" = "working" ] || fail "2: idle+active+delta must resolve to working (got '$got')"
ok
dl="$(grep 'status_disagreement' "$JOURNAL_FILE" | tail -1)"
[ -n "$dl" ] || fail "2: status_disagreement must be journaled"
ok
grep -q '"slug":"corrob-a"' <<< "$dl" || fail "2: journal must carry the slug (got: $dl)"
ok
grep -q '"pane":"pane-2"' <<< "$dl" || fail "2: journal must carry the pane (got: $dl)"
ok

# (3) idle + active chrome, FROZEN (identical text call to call) ⇒ NEVER corroborated — the
#     dead-builder guardrail (a crashed process leaves the spinner frame sitting forever).
: > "$JOURNAL_FILE"
export STUB_PANE_TEXT="$ACTIVE (frozen)"
got="$(herd_driver_agent_status_resolved "corrob-b" "idle" "pane-3")"
got="$(herd_driver_agent_status_resolved "corrob-b" "idle" "pane-3")"
got="$(herd_driver_agent_status_resolved "corrob-b" "idle" "pane-3")"
[ "$got" = "idle" ] || fail "3: idle+active+NO delta must stay idle (got '$got')"
ok
[ ! -s "$JOURNAL_FILE" ] || fail "3: a frozen pane must never journal status_disagreement (got: $(cat "$JOURNAL_FILE"))"
ok

# (4) idle + a genuinely static idle prompt, even with changing content ⇒ never corroborated (the
#     active-chrome gate matters independently of delta).
: > "$JOURNAL_FILE"
export STUB_PANE_TEXT="$IDLE_PROMPT frame-1"
got="$(herd_driver_agent_status_resolved "corrob-c" "idle" "pane-4")"
export STUB_PANE_TEXT="$IDLE_PROMPT frame-2"
got="$(herd_driver_agent_status_resolved "corrob-c" "idle" "pane-4")"
[ "$got" = "idle" ] || fail "4: idle+static-prompt+delta (no spinner chrome) must stay idle (got '$got')"
ok
[ ! -s "$JOURNAL_FILE" ] || fail "4: a genuinely idle pane must never journal (got: $(cat "$JOURNAL_FILE"))"
ok

# (5) idle + no pane resolvable at all ⇒ raw returned unchanged, fail-soft (absent signal = today's
#     behavior). Point at an agent name the stub roster does not carry (STUB_AGENT_NAME stays "corrob-a"
#     from case 2), so herd_driver_agent_pane_id's internal roster lookup finds no match.
: > "$JOURNAL_FILE"
got="$(herd_driver_agent_status_resolved "no-such-agent" "idle" "")"
[ "$got" = "idle" ] || fail "5: an unresolvable pane must fail-soft to the raw status (got '$got')"
ok

# (6) HERD_STATUS_CORROBORATE=off is a total kill switch, same fixture as (2).
: > "$JOURNAL_FILE"
export STUB_PANE_TEXT="$ACTIVE (frame 1)"
got="$(HERD_STATUS_CORROBORATE=off herd_driver_agent_status_resolved "corrob-d" "idle" "pane-6")"
export STUB_PANE_TEXT="$ACTIVE (frame 2)"
got="$(HERD_STATUS_CORROBORATE=off herd_driver_agent_status_resolved "corrob-d" "idle" "pane-6")"
[ "$got" = "idle" ] || fail "6: HERD_STATUS_CORROBORATE=off must disable corroboration (got '$got')"
ok
[ ! -s "$JOURNAL_FILE" ] || fail "6: kill switch must never journal (got: $(cat "$JOURNAL_FILE"))"
ok
unset STUB_PANE_TEXT

# ══════════════════════════════════════════════════════════════════════════════════════════════════
# PART 2 — agent-watch.sh's _agent_status() is wired through the SAME resolver
# ══════════════════════════════════════════════════════════════════════════════════════════════════
export AGENT_WATCH_LIB=1
export HERD_CONFIG_FILE="$T/no-such-config"
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"
type _agent_status >/dev/null 2>&1 || fail "_agent_status not defined after sourcing agent-watch.sh"

# (7) a non-idle status is returned unchanged (byte-identical to pre-HERD-647 behavior).
export STUB_AGENT_NAME="aw-working" STUB_AGENT_STATUS="working" STUB_AGENT_PANE_ID="pane-7"
[ "$(_agent_status "aw-working")" = "working" ] || fail "7: _agent_status must pass a non-idle status through unchanged"
ok

# (8) idle + active, repainting pane ⇒ _agent_status resolves to working and journals
#     status_disagreement — proving the watcher's ~30 callers inherit the fix from this one function.
: > "$JOURNAL_FILE"
export STUB_AGENT_NAME="aw-idle" STUB_AGENT_STATUS="idle" STUB_AGENT_PANE_ID="pane-8"
export STUB_PANE_TEXT="$ACTIVE (frame 1)"
got="$(_agent_status "aw-idle")"
export STUB_PANE_TEXT="$ACTIVE (frame 2)"
got="$(_agent_status "aw-idle")"
[ "$got" = "working" ] || fail "8: _agent_status must corroborate idle+active+delta into working (got '$got')"
ok
grep -q 'status_disagreement' "$JOURNAL_FILE" || fail "8: _agent_status's corroboration must journal status_disagreement"
ok

# (9) genuinely idle (no PR, spare builder) is unchanged — _agent_status still reads idle.
export STUB_AGENT_NAME="aw-spare" STUB_AGENT_STATUS="idle" STUB_AGENT_PANE_ID="pane-9"
export STUB_PANE_TEXT="$IDLE_PROMPT"
[ "$(_agent_status "aw-spare")" = "idle" ] || fail "9: a genuinely idle spare builder must stay idle"
ok
unset STUB_PANE_TEXT

unset STUB_AGENT_NAME STUB_AGENT_STATUS STUB_AGENT_PANE_ID

# ══════════════════════════════════════════════════════════════════════════════════════════════════
# PART 3 (HERD-660) — transcript-growth corroboration: the SECOND, pane-independent rescue path
# ══════════════════════════════════════════════════════════════════════════════════════════════════
# Regression target: HERD-647's pane path alone left a real gap — herdkit's own journal
# (2026-08-11/12) shows raw agent_status=idle persisting CONTINUOUSLY for up to ~30 minutes
# (actuator-status-port, 15 straight corroborated ticks) while the pane path happened to catch every
# poll; a caller with a SHORT observation window (wake-verify's ~20s / 1-4 polls) has no such
# guarantee — a poll that lands between repaints, or whose visible pane text is scrolled past the
# "esc to interrupt" hint, sees neither pane signal and misreads idle. These cases prove
# _herd_wake_transcript_growing closes that gap independently of the pane.

# (10) idle + a pane that shows NO active chrome at all (pane signal fails outright) + a GROWING
#      transcript for the slug's worktree ⇒ still corroborated to working via the transcript path
#      alone. This is the exact gap: the pane path contributes nothing here.
: > "$JOURNAL_FILE"
write_transcript "tgrow-a" 100
export STUB_PANE_TEXT="$IDLE_PROMPT"
got="$(herd_driver_agent_status_resolved "tgrow-a" "idle" "pane-10")"
write_transcript "tgrow-a" 250
got="$(herd_driver_agent_status_resolved "tgrow-a" "idle" "pane-10")"
[ "$got" = "working" ] || fail "10: idle + static pane + growing transcript must resolve to working (got '$got')"
ok
grep -q 'status_disagreement' "$JOURNAL_FILE" || fail "10: transcript-path rescue must journal status_disagreement"
ok
grep -q '"slug":"tgrow-a"' "$JOURNAL_FILE" || fail "10: journal must carry the slug"
ok

# (11) idle + NO pane resolvable AT ALL (headless-shaped: empty pane, no roster match) + a growing
#      transcript ⇒ still corroborated. Proves the transcript path needs no pane whatsoever.
: > "$JOURNAL_FILE"
write_transcript "tgrow-b" 100
got="$(herd_driver_agent_status_resolved "tgrow-b" "idle" "")"
write_transcript "tgrow-b" 400
got="$(herd_driver_agent_status_resolved "tgrow-b" "idle" "")"
[ "$got" = "working" ] || fail "11: idle + no pane + growing transcript must resolve to working (got '$got')"
ok

# (12) idle + a transcript that EXISTS but has stopped growing (repeated identical size/mtime) ⇒
#      never corroborated — the guardrail: a genuinely stuck/crashed agent must stay idle even though
#      it once had a transcript.
: > "$JOURNAL_FILE"
write_transcript "tgrow-c" 200
got="$(herd_driver_agent_status_resolved "tgrow-c" "idle" "pane-12")"
got="$(herd_driver_agent_status_resolved "tgrow-c" "idle" "pane-12")"
got="$(herd_driver_agent_status_resolved "tgrow-c" "idle" "pane-12")"
[ "$got" = "idle" ] || fail "12: idle + flat transcript (no growth) must stay idle (got '$got')"
ok
[ ! -s "$JOURNAL_FILE" ] || fail "12: a flat transcript must never journal (got: $(cat "$JOURNAL_FILE"))"
ok

# (13) idle + no pane + no transcript at all for this slug's worktree ⇒ fail-soft to raw idle
#      (absent signal = today's behavior, unchanged by HERD-660).
: > "$JOURNAL_FILE"
got="$(herd_driver_agent_status_resolved "tgrow-d-no-transcript" "idle" "")"
[ "$got" = "idle" ] || fail "13: idle + no pane + no transcript must fail-soft to idle (got '$got')"
ok

# (14) HERD_STATUS_CORROBORATE=off also disables the transcript path (one kill switch for both).
: > "$JOURNAL_FILE"
write_transcript "tgrow-e" 100
got="$(HERD_STATUS_CORROBORATE=off herd_driver_agent_status_resolved "tgrow-e" "idle" "")"
write_transcript "tgrow-e" 500
got="$(HERD_STATUS_CORROBORATE=off herd_driver_agent_status_resolved "tgrow-e" "idle" "")"
[ "$got" = "idle" ] || fail "14: kill switch must also disable the transcript path (got '$got')"
ok
[ ! -s "$JOURNAL_FILE" ] || fail "14: kill switch must never journal (got: $(cat "$JOURNAL_FILE"))"
ok
unset STUB_PANE_TEXT

echo "ALL PASS ($pass checks)"
