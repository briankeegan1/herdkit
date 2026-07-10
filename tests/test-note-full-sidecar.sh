#!/usr/bin/env bash
# test-note-full-sidecar.sh — hermetic proof of HERD-298: `herd note`'s 300-char cap no longer
# destroys a finding's tail. An OVER-cap note spills its FULL flattened text to a sidecar
# ($WORKTREES_DIR/.builder-notes-full/<epoch>-<slug>.txt) and records the path on the builder_note
# event as note_full; `herd notes show <n>` resolves that path and prints the whole finding.
#
#   (a) a >300-char note round-trips LOSSLESSLY via `herd notes show` (the dropped tail is restored).
#   (b) a short (sub-cap) note produces NO sidecar and a BYTE-IDENTICAL journal line (no note_full).
#   (c) a sidecar-write failure still journals the capped note (fail-soft — a note is never blocked).
#
# Fully hermetic: temp dirs only, no network, no live watcher loop (AGENT_WATCH_LIB=1 to build the
# console ledger the same way the watcher does). Run:  bash tests/test-note-full-sidecar.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
HERD_BIN="$REPO/bin/herd"
WATCH="$REPO/scripts/herd/agent-watch.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

[ -f "$HERD_BIN" ] || fail "bin/herd not found"
[ -f "$WATCH" ]    || fail "agent-watch.sh not found"
command -v python3 >/dev/null 2>&1 || fail "python3 required"

# ── Fixture: a fake project with WORKTREES_DIR under $T ──────────────────────────────────────────
MAIN="$T/main"
TREES="$T/trees"
mkdir -p "$MAIN/.herd" "$TREES/.herd" "$TREES/my-slug"
cat > "$MAIN/.herd/config" <<EOF
WORKTREES_DIR="$TREES"
DEFAULT_BRANCH=main
EOF
WT="$TREES/my-slug"                                   # builder runs from the worktree (basename = slug)
export JOURNAL_FILE="$TREES/.herd/journal.jsonl"      # explicit journal so the hermetic guard cannot redirect
export HERMETIC_TEST="test-note-full-sidecar.sh"
export HERD_JOURNAL_HERMETIC=1
SIDECAR_DIR="$TREES/.builder-notes-full"

# jq-free journal field reader (reads the FIRST journal line's <key>).
_field() {
  python3 -c '
import sys, json
with open(sys.argv[1]) as f:
    lines = [l for l in f if l.strip()]
o = json.loads(lines[0])
sys.stdout.write(str(o.get(sys.argv[2], "<MISSING>")))
' "$1" "$2"
}

# Run `herd note` from the builder worktree.
run_note() {
  cd "$WT" && \
  HERD_CONFIG_FILE="$MAIN/.herd/config" \
  JOURNAL_FILE="$JOURNAL_FILE" \
  HERMETIC_TEST=1 \
  HERD_SLUG="my-slug" \
  bash "$HERD_BIN" note "$1" 2>&1
}

# ── (a) an over-cap note spills a sidecar + round-trips losslessly via `herd notes show` ──────────
: > "$JOURNAL_FILE"; rm -rf "$SIDECAR_DIR"
# A single-line (already flattened) >300-char note with a UNIQUE tail the 300-char cap would DROP.
LONG="HEAD-$(python3 -c 'import sys; sys.stdout.write("y"*400)')-UNIQUETAIL298"
out="$(run_note "$LONG")" || fail "herd note (long) exited non-zero: $out"
echo "$out" | grep -q "noted" || fail "herd note should confirm (got: $out)"
ok

# The capped journal line is present and TRUNCATED (tail gone), and carries a note_full path.
[ "$(_field "$JOURNAL_FILE" event)" = "builder_note" ] || fail "event should be builder_note"
cap_len="$(python3 -c 'import json,sys; print(len(json.loads(open(sys.argv[1]).read().strip())["text"]))' "$JOURNAL_FILE")"
[ "$cap_len" -le 300 ] || fail "journal text should be capped ≤300 (got $cap_len)"
python3 -c 'import json,sys; t=json.loads(open(sys.argv[1]).read().strip())["text"]; sys.exit(0 if "UNIQUETAIL298" not in t else 1)' "$JOURNAL_FILE" \
  || fail "capped journal text must NOT contain the dropped tail"
nf="$(_field "$JOURNAL_FILE" note_full)"
[ "$nf" != "<MISSING>" ] && [ -n "$nf" ] || fail "over-cap note must record note_full on the event"
ok

# The sidecar exists, sits under WORKTREES_DIR/.builder-notes-full, and holds the FULL flattened text.
[ -f "$nf" ] || fail "note_full sidecar file should exist ($nf)"
case "$nf" in "$SIDECAR_DIR"/*.txt) : ;; *) fail "sidecar path unexpected: $nf" ;; esac
side_content="$(cat "$nf")"
[ "$side_content" = "$LONG" ] || fail "sidecar must hold the FULL note losslessly"
ok

# Build the console ledger exactly as the watcher does, then `herd notes show 1` restores the tail.
BIN="$T/bin"; mkdir -p "$BIN"
for cmd in gh git herdr; do printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$cmd"; chmod +x "$BIN/$cmd"; done
export PATH="$BIN:$PATH"
export AGENT_WATCH_LIB=1
export HERD_CONFIG_FILE="$MAIN/.herd/config"
export WORKTREES_DIR="$TREES"
export PROJECT_ROOT="$MAIN"
export WORKSPACE_NAME="note-full-test"
export NO_COLOR=1
export HERD_FAKE_NOW=1700000000
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"
BUILDER_NOTES_LEDGER="$TREES/.agent-watch-builder-notes"
BUILDER_NOTES_CURSOR="$TREES/.agent-watch-builder-notes-cursor"
rm -f "$BUILDER_NOTES_LEDGER" "$BUILDER_NOTES_CURSOR"
herd_driver_notify() { :; }                          # swallow notifies
printf '0' > "$BUILDER_NOTES_CURSOR"                 # drain from the start (skip the first-scan EOF pin)
_builder_notes_scan
[ -s "$BUILDER_NOTES_LEDGER" ] || fail "scan should append a ledger row for the note"

show_out="$(
  cd "$WT" && \
  HERD_CONFIG_FILE="$MAIN/.herd/config" \
  JOURNAL_FILE="$JOURNAL_FILE" \
  HERMETIC_TEST=1 \
  HERD_FAKE_NOW=1700000000 \
  NO_COLOR=1 \
  bash "$HERD_BIN" notes show 1 2>&1
)" || fail "herd notes show 1 exited non-zero: $show_out"
printf '%s' "$show_out" | grep -qF "UNIQUETAIL298" || fail "show must restore the dropped tail (got: $show_out)"
printf '%s' "$show_out" | grep -qF "$LONG" || fail "show must print the FULL note losslessly"
ok

# ── (b) a sub-cap note writes NO sidecar and a byte-identical journal line (no note_full) ─────────
: > "$JOURNAL_FILE"; rm -rf "$SIDECAR_DIR"
SHORT="this red is a stale cached row"
out="$(run_note "$SHORT")" || fail "herd note (short) exited non-zero: $out"
[ "$(_field "$JOURNAL_FILE" text)" = "$SHORT" ] || fail "short note text field wrong"
[ "$(_field "$JOURNAL_FILE" note_full)" = "<MISSING>" ] || fail "sub-cap note must NOT carry note_full"
[ -d "$SIDECAR_DIR" ] && fail "sub-cap note must NOT create a sidecar dir"
# Byte-identical: a short note's journal line must exactly equal one produced WITHOUT the HERD-298
# sidecar surface (i.e. the historical field set/order: no note_full key anywhere on the line).
grep -q 'note_full' "$JOURNAL_FILE" && fail "sub-cap journal line must be byte-identical (no note_full key)"
line="$(head -n1 "$JOURNAL_FILE")"
case "$line" in
  *'"component":"builder"'*'"slug":"my-slug"'*'"text":"'"$SHORT"'"'*) : ;;
  *) fail "sub-cap journal line shape unexpected: $line" ;;
esac
ok

# ── (c) a sidecar-write failure still journals the capped note (fail-soft) ────────────────────────
# Make the pool unwritable so mkdir/write fails; the note must still be journaled (capped, no note_full).
: > "$JOURNAL_FILE"; rm -rf "$SIDECAR_DIR"
if [ "$(id -u)" = "0" ]; then
  ok   # root ignores the perm bit; the write would succeed — skip this hostile-FS assertion.
else
  # A regular FILE at the sidecar-dir path makes `mkdir -p .../.builder-notes-full` fail.
  : > "$TREES/.builder-notes-full"
  LONG2="BLOCKED-$(python3 -c 'import sys; sys.stdout.write("z"*400)')-TAIL"
  out="$(run_note "$LONG2")" || fail "herd note must not fail when the sidecar cannot be written: $out"
  echo "$out" | grep -q "noted" || fail "herd note should still confirm when the sidecar fails"
  [ "$(_field "$JOURNAL_FILE" event)" = "builder_note" ] || fail "capped note must still be journaled on sidecar failure"
  [ "$(_field "$JOURNAL_FILE" note_full)" = "<MISSING>" ] || fail "a failed sidecar must NOT leave a note_full field"
  rm -f "$TREES/.builder-notes-full"
  ok
fi

echo "ALL PASS ($pass assertions)"
