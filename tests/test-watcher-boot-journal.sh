#!/usr/bin/env bash
# test-watcher-boot-journal.sh — hermetic proof of HERD-548 leg 1: watcher startup is JOURNAL-VISIBLE.
#
# GROUNDED 2026-08-05: post-reload the watcher crash-looped silently for ~2 minutes (child pid churn,
# zero journal entry, zero console beyond the header) then self-resolved — an outage nobody could
# reconstruct afterward because nothing recorded that a boot was even ATTEMPTED. This suite drives the
# REAL agent-watch.sh end-to-end (never lib-mode helpers) through every pre-tick exit path and asserts:
#
#   (a) a run that reaches the hermetic-test choke point journals `watcher_boot` FIRST, then
#       `watcher_boot_failed` (phase=hermetic_guard) — exit 0 (a refusal/redirect, not a crash).
#   (b) a run from a FOREIGN cwd journals `watcher_boot` then `watcher_boot_failed`
#       (phase=console_guard) — exit 1.
#   (c) a run against a LIVE singleton lock journals `watcher_boot` then `watcher_boot_failed`
#       (phase=singleton_lock) — exit 1, and never spawns a duplicate (the pre-existing holder pid is
#       left untouched).
#   (d) `watcher_boot` itself carries pid / argv0 / engine_sha / workspace fields.
#
# No herdr, no gh, no network, no real daemon ever left running (every case exits before the tick
# loop). Run:  bash tests/test-watcher-boot-journal.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
LOADER="$REPO/scripts/herd/herd-config.sh"
WATCH="$REPO/scripts/herd/agent-watch.sh"

T="$(mktemp -d)"
LIVE_PROCS=""
cleanup() {
  local p
  for p in $LIVE_PROCS; do kill -KILL "$p" 2>/dev/null || true; done
  rm -rf "$T"
}
trap cleanup EXIT
track() { LIVE_PROCS="$LIVE_PROCS $1"; }

pass=0
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
ok()   { pass=$((pass + 1)); }

[ -f "$WATCH" ] || fail "agent-watch.sh not found at $WATCH"
command -v python3 >/dev/null 2>&1 || fail "python3 required"

PROJ="$T/proj"; mkdir -p "$PROJ/.herd" "$T/trees"
cat > "$PROJ/.herd/config" <<EOF
PROJECT_ROOT="$PROJ"
WORKTREES_DIR="$T/trees"
WORKSPACE_NAME="boot-journal-test"
EOF
FOREIGN="$T/foreign"; mkdir -p "$FOREIGN"

# Resolve the REAL derived lock path + argv0 the same way agent-watch.sh will, so case (c) can
# pre-seed the exact lockfile a live run would consult.
LOCK="$(cd "$PROJ" && HERD_CONFIG_FILE="$PROJ/.herd/config" bash -c ". '$LOADER'; printf '%s' \"\$HERD_WATCHER_LOCK\"")"
ARGV0="$(cd "$PROJ" && HERD_CONFIG_FILE="$PROJ/.herd/config" bash -c ". '$LOADER'; printf '%s' \"\$HERD_WATCH_ARGV0\"")"
[ -n "$LOCK" ] || fail "setup: could not resolve HERD_WATCHER_LOCK"
[ -n "$ARGV0" ] || fail "setup: could not resolve HERD_WATCH_ARGV0"

journal_events() { grep -o '"event"[[:space:]]*:[[:space:]]*"[^"]*"' "$1" 2>/dev/null | sed -E 's/.*"([^"]+)"$/\1/'; }

# ── (a) hermetic-guard choke point: boot, then boot_failed(phase=hermetic_guard), exit 0 ───────────
J="$T/a-journal.jsonl"; : > "$J"
LOG="$T/a-hermetic.log"; : > "$LOG"
out="$(cd "$PROJ" && HERD_CONFIG_FILE="$PROJ/.herd/config" JOURNAL_FILE="$J" HERD_HERMETIC_GUARD="$LOG" bash "$WATCH" 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "(a) hermetic-guard redirect must exit 0 (got $rc): $out"
ok
[ -s "$J" ] || fail "(a) journal must be non-empty"
events_a="$(journal_events "$J")"
[ "$(printf '%s\n' "$events_a" | grep -c '^watcher_boot$')" -ge 1 ] \
  || fail "(a) journal must contain watcher_boot (got: $events_a)"
ok
grep -q '"phase"[[:space:]]*:[[:space:]]*"hermetic_guard"' "$J" \
  || fail "(a) journal must contain watcher_boot_failed phase=hermetic_guard (got: $(cat "$J"))"
ok
# watcher_boot must appear BEFORE watcher_boot_failed (line order == append order).
first_boot_line="$(grep -n '"watcher_boot"' "$J" | grep -v watcher_boot_failed | head -1 | cut -d: -f1)"  # pipe-ok: a handful of lines in a per-test journal fixture, never large
first_failed_line="$(grep -n '"watcher_boot_failed"' "$J" | head -1 | cut -d: -f1)"  # pipe-ok: a handful of lines in a per-test journal fixture, never large
[ -n "$first_boot_line" ] && [ -n "$first_failed_line" ] && [ "$first_boot_line" -lt "$first_failed_line" ] \
  || fail "(a) watcher_boot must be journaled BEFORE watcher_boot_failed (boot@$first_boot_line failed@$first_failed_line)"
ok
echo "PASS (a) hermetic-guard exit journals watcher_boot then watcher_boot_failed(hermetic_guard), exit 0"

# ── (d) watcher_boot required fields (checked against case (a)'s journal) ──────────────────────────
grep -q '"pid"' "$J" || fail "(d) watcher_boot must carry pid"
grep -Fq "\"argv0\":\"$ARGV0\"" "$J" || grep -Fq "\"argv0\": \"$ARGV0\"" "$J" \
  || fail "(d) watcher_boot must carry argv0=$ARGV0 (got: $(cat "$J"))"
grep -q '"engine_sha"' "$J" || fail "(d) watcher_boot must carry engine_sha"
grep -Fq '"workspace":"boot-journal-test"' "$J" || grep -Fq '"workspace": "boot-journal-test"' "$J" \
  || fail "(d) watcher_boot must carry workspace=boot-journal-test"
ok
echo "PASS (d) watcher_boot carries pid/argv0/engine_sha/workspace"

# ── (b) foreign cwd: boot, then boot_failed(phase=console_guard), exit 1 ────────────────────────────
J="$T/b-journal.jsonl"; : > "$J"
out="$(cd "$FOREIGN" && HERD_CONFIG_FILE="$PROJ/.herd/config" JOURNAL_FILE="$J" bash "$WATCH" 2>&1)"
rc=$?
[ "$rc" -ne 0 ] || fail "(b) foreign-cwd run must exit non-zero (got $rc): $out"
ok
grep -q '"watcher_boot"' "$J" || fail "(b) journal must contain watcher_boot (got: $(cat "$J"))"
ok
grep -q '"phase"[[:space:]]*:[[:space:]]*"console_guard"' "$J" \
  || fail "(b) journal must contain watcher_boot_failed phase=console_guard (got: $(cat "$J"))"
ok
echo "PASS (b) foreign-cwd exit journals watcher_boot then watcher_boot_failed(console_guard), exit 1"

# ── (c) live singleton lock: boot, then boot_failed(phase=singleton_lock), exit 1, no duplicate ────
sleep 300 & HOLDER=$!; track "$HOLDER"
kill -0 "$HOLDER" 2>/dev/null || fail "(c) setup: fake holder unexpectedly dead"
mkdir -p "$(dirname "$LOCK")"
printf '%s\n' "$HOLDER" > "$LOCK"

J="$T/c-journal.jsonl"; : > "$J"
out="$(cd "$PROJ" && HERD_CONFIG_FILE="$PROJ/.herd/config" JOURNAL_FILE="$J" bash "$WATCH" 2>&1)"
rc=$?
[ "$rc" -ne 0 ] || fail "(c) live-lock run must exit non-zero (got $rc): $out"
ok
grep -q '"watcher_boot"' "$J" || fail "(c) journal must contain watcher_boot (got: $(cat "$J"))"
ok
grep -q '"phase"[[:space:]]*:[[:space:]]*"singleton_lock"' "$J" \
  || fail "(c) journal must contain watcher_boot_failed phase=singleton_lock (got: $(cat "$J"))"
ok
[ "$(cat "$LOCK" 2>/dev/null)" = "$HOLDER" ] \
  || fail "(c) the live holder pid must be left untouched (lock now: $(cat "$LOCK" 2>/dev/null))"
ok
echo "PASS (c) live-singleton-lock exit journals watcher_boot then watcher_boot_failed(singleton_lock), exit 1, no duplicate"

echo "ALL PASS ($pass checks)"
