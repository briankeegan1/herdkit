#!/usr/bin/env bash
# test-health-live-progress-row.sh — hermetic proof for HERD-533 legs 2+3 (the render row).
#
# Both fixes live in agent-watch.sh's render half, the path the console paints under the (sole)
# Python engine — _healthcheck_gate (the old bash DISPATCH gate) is not on this path at all, so its
# pre-existing "queued (n ahead)" wording never protected an operator watching a real, python-driven
# tick. Ungrounded before this change: PR #659 read "health-check" (or, in an ambiguous read, looked
# indistinguishable from "running") for 40 minutes before ever actually starting.
#
# Covers:
#   (1) LEG 2 — QUEUED: another (pr,sha) genuinely holds every HEALTH_CONCURRENCY slot (default 1) and
#       THIS (pr,sha) has no live worker of its own yet → the row must read
#       "health-check · queued (N ahead)", not the bare placeholder.
#   (2) LEG 2 — RUNNING still wins: a live worker for THIS exact (pr,sha) outranks the queued check
#       (unchanged precedence — a suite that HAS started must never regress to "queued").
#   (3) LEG 2 — BYTE-IDENTICAL passthrough: no live worker anywhere (slot genuinely free) → the row is
#       the caller's fallback text VERBATIM, unchanged from before this fix.
#   (4) LEG 3 — the k/N counter (_health_progress) and the liveness note (_health_inflight_note) prefer
#       "<log>.progress" (the new streaming companion, HERD-533 leg 1) over the bare <log>, and fall
#       back to <log> when no companion exists — today's exact behavior.
#   (5) HERD-570 leg 2 — a 'suite: N tests' header + mixed raw/noise lines: the counter reads k/N by
#       counting ONLY '[health-progress] …' completion lines, ignoring every other line in the file.
#   (6) HERD-570 leg 2 — headerless: the exact same mix of '[health-progress]' + noise lines, minus the
#       header, falls back to today's plain byte-line count (never mis-parsed as [health-progress]).
#   (7) HERD-570 leg 3 — RETRY: once "<log>.retry.progress" exists and is newer than "<log>.progress",
#       both the source and the inflight note switch onto it and the note is prefixed "retry 1 · ".
#
# Sources agent-watch.sh in lib mode (AGENT_WATCH_LIB=1); stubs gh/git/herdr so nothing touches the
# network or the live control room. Run:  bash tests/test-health-live-progress-row.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../scripts/herd/agent-watch.sh"
[ -f "$WATCH" ] || { echo "FAIL: agent-watch.sh not found at $WATCH" >&2; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"; _kill_leftovers' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

_LEFTOVERS=""
_track() { _LEFTOVERS="$_LEFTOVERS $1"; }
_kill_leftovers() { local p; for p in $_LEFTOVERS; do kill -KILL "$p" 2>/dev/null || true; done; }

BIN="$T/bin"; mkdir -p "$BIN"
for cmd in gh git herdr; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$cmd"; chmod +x "$BIN/$cmd"
done
export PATH="$BIN:$PATH"

export AGENT_WATCH_LIB=1
export WORKTREES_DIR="$T/trees"; mkdir -p "$T/trees"
export HERD_CONFIG_FILE="$T/no-such-config"
export JOURNAL_FILE="$T/journal.jsonl"; : > "$JOURNAL_FILE"
unset HERD_WATCHER_LOCK 2>/dev/null || true
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"
TREES="$WORKTREES_DIR"

# A long-lived holder process so its inflight marker reads as genuinely LIVE.
sleep 300 & HOLDER=$!; _track "$HOLDER"
for _ in $(seq 1 100); do kill -0 "$HOLDER" 2>/dev/null && break; sleep 0.02; done

FALLBACK="    fallback-placeholder-row"

# ── (1) LEG 2 QUEUED: another (pr,sha) holds the only slot; this (pr,sha) has no worker yet ─────────
_marker_write "$(_health_inflight_file "77-otherSha")" "$HOLDER"
row1="$(_gate_phase_row "slugcell" " #42 ·" 42 "myShaA" "$FALLBACK")"
[[ "$row1" == *"health-check"* && "$row1" == *"queued"* && "$row1" == *"1 ahead"* ]] \
  || fail "(1) expected a 'queued (1 ahead)' row, got: $row1"
[[ "$row1" != *"running"* ]] || fail "(1) a queued PR must never read 'running': $row1"
ok

# ── (2) LEG 2 RUNNING still wins over queued for a PR with its OWN live worker ───────────────────────
_marker_write "$(_health_inflight_file "42-myShaA")" "$HOLDER"
row2="$(_gate_phase_row "slugcell" " #42 ·" 42 "myShaA" "$FALLBACK")"
[[ "$row2" == *"running"* ]] || fail "(2) a PR with its own live worker must render 'running', got: $row2"
[[ "$row2" != *"queued"* ]] || fail "(2) a running PR must not ALSO read 'queued': $row2"
rm -f "$(_health_inflight_file "42-myShaA")"
ok

# ── (3) LEG 2 BYTE-IDENTICAL passthrough when no worker anywhere holds the slot ──────────────────────
rm -f "$(_health_inflight_file "77-otherSha")"
row3="$(_gate_phase_row "slugcell" " #42 ·" 42 "myShaA" "$FALLBACK")"
[ "$row3" = "$FALLBACK" ] || fail "(3) with a genuinely free slot the row must be the fallback VERBATIM, got: $row3"
ok

# ── (4) LEG 3: .progress companion preferred, falls back to <log> when absent ───────────────────────
LOG="$T/some.log"
printf '1..9\nok 1 stale-a\nok 2 stale-b\n' > "$LOG"                 # stale/frozen bare log
PROG="$LOG.progress"
printf '1..9\nok 1 a\nok 2 b\nok 3 c\nnot ok 4 d\n' > "$PROG"        # fresher, growing companion
got_progress="$(_health_progress "$LOG")"
[ "$got_progress" = "test 4/9" ] \
  || fail "(4) _health_progress must read the .progress companion when present, got: '$got_progress'"
rm -f "$PROG"
got_fallback="$(_health_progress "$LOG")"
[ "$got_fallback" = "test 2/9" ] \
  || fail "(4) with no companion, _health_progress must fall back to reading <log> itself, got: '$got_fallback'"
ok

# ── (5) HERD-570 leg 2: header + mixed lines → k/N counts ONLY [health-progress] lines ───────────────
LOG2="$T/hdr.log"
PROG2="$LOG2.progress"
cat > "$PROG2" <<'EOF'
suite: 5 tests
bash -n scripts/herd/foo.sh: clean
shellcheck: clean (retried=no)
[health-progress] test-alpha.sh ok
some interleaved raw suite noise that is not a completion line
[health-progress] test-beta.sh ok
[health-progress] test-gamma.sh FAIL
EOF
got_hdr="$(_health_progress "$LOG2")"
[ "$got_hdr" = "3/5" ] \
  || fail "(5) header+mixed fixture must render '3/5' (3 completion lines / 5 header total), got: '$got_hdr'"
note_hdr="$(_health_inflight_note "$LOG2")"
[ "$note_hdr" = "3/5" ] || fail "(5b) _health_inflight_note must pass the header-based k/N through unprefixed, got: '$note_hdr'"
ok

# ── (6) HERD-570 leg 2: the SAME mix, minus the header, falls back to the plain line count ───────────
LOG3="$T/nohdr.log"
PROG3="$LOG3.progress"
grep -v '^suite: ' "$PROG2" > "$PROG3"
got_nohdr="$(_health_progress "$LOG3")"
[ -z "$got_nohdr" ] \
  || fail "(6) a headerless sidecar must never be parsed via the [health-progress] path, got: '$got_nohdr'"
note_nohdr="$(_health_inflight_note "$LOG3")"
[ "$note_nohdr" = "$(grep -c '' "$PROG3") lines" ] \
  || fail "(6b) a headerless sidecar must fall back to today's plain line count, got: '$note_nohdr'"
ok

# ── (7) HERD-570 leg 3: a live retry companion, once newer, wins the source AND prefixes the note ────
LOG4="$T/retry.log"
PROG4="$LOG4.progress"
RETRY4="$LOG4.retry.progress"
printf 'suite: 5 tests\n[health-progress] test-alpha.sh ok\nnot ok 2 test-alpha.sh\n' > "$PROG4"
sleep 1.1
printf 'suite: 5 tests\n[health-progress] test-alpha.sh ok\n' > "$RETRY4"    # fresher: the solo re-run
got_retry_src="$(_health_progress_source "$LOG4")"
[ "$got_retry_src" = "$RETRY4" ] \
  || fail "(7) a newer .retry.progress must win over .progress, got source: '$got_retry_src'"
got_retry_note="$(_health_inflight_note "$LOG4")"
[ "$got_retry_note" = "retry 1 · 1/5" ] \
  || fail "(7b) the inflight note must read 'retry 1 · 1/5' while the retry companion is live, got: '$got_retry_note'"
rm -f "$RETRY4"
got_after_note="$(_health_inflight_note "$LOG4")"
[ "$got_after_note" = "1/5" ] \
  || fail "(7c) once the retry companion is gone again, the note must revert to the bare (unprefixed) k/N, got: '$got_after_note'"
ok

echo "ALL PASS ($pass checks) — the render row distinguishes queued-vs-running, its k/N counter tracks the new streaming companion (header-scoped and headerless), and a live solo retry visibly switches the source."
