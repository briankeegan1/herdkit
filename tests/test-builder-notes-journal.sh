#!/usr/bin/env bash
# test-builder-notes-journal.sh — hermetic proof of HERD-202 builder findings flow:
#
#   (1) `herd note "x"` from a builder context appends a builder_note journal event with
#       component=builder, a resolved slug, and free text (truncated ~300 chars).
#   (2) The watcher surfaces that event: _builder_notes_scan drains it into the ledger + fires
#       one notify, and build_builder_notes renders a console row carrying the slug + text.
#   (3) Ship-dormant / first-scan pin: with no new notes past the cursor the ledger stays empty
#       and build_builder_notes leaves BUILDER_NOTES_ROWS empty (byte-identical console when unused).
#   (4) Lane preambles instruct builders to file findings via `herd note`.
#
# Fully hermetic: temp dirs only, no network, no live watcher loop (AGENT_WATCH_LIB=1).
# Run:  bash tests/test-builder-notes-journal.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
HERD_BIN="$REPO/bin/herd"
WATCH="$REPO/scripts/herd/agent-watch.sh"
QUICK="$REPO/scripts/herd/herd-quick.sh"
FEATURE="$REPO/scripts/herd/herd-feature.sh"

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
# Builder runs from the worktree (basename = slug).
WT="$TREES/my-slug"
# Explicit journal path so hermetic journal guard cannot redirect us.
export JOURNAL_FILE="$TREES/.herd/journal.jsonl"
export HERMETIC_TEST="test-builder-notes-journal.sh"
export HERD_JOURNAL_HERMETIC=1
: > "$JOURNAL_FILE"

# jq-free field reader.
_field() {
  python3 -c '
import sys, json
with open(sys.argv[1]) as f:
    lines = [l for l in f if l.strip()]
o = json.loads(lines[int(sys.argv[2])])
v = o.get(sys.argv[3], "<MISSING>")
sys.stdout.write(str(v))
' "$1" "$2" "$3"
}
_nlines() { grep -c . "$1" 2>/dev/null || echo 0; }

# ── (1) herd note appends builder_note with component/slug/text ──────────────────────────────────
out="$(
  cd "$WT" && \
  HERD_CONFIG_FILE="$MAIN/.herd/config" \
  JOURNAL_FILE="$JOURNAL_FILE" \
  HERMETIC_TEST=1 \
  bash "$HERD_BIN" note "this red is a stale cached row" 2>&1
)" || fail "herd note exited non-zero: $out"
echo "$out" | grep -q "noted" || fail "herd note should print a confirmation (got: $out)"
ok

[ -f "$JOURNAL_FILE" ] || fail "journal file not created"
[ "$(_nlines "$JOURNAL_FILE")" -ge 1 ] || fail "expected at least 1 journal line"
[ "$(_field "$JOURNAL_FILE" 0 event)" = "builder_note" ] || fail "event should be builder_note (got $(_field "$JOURNAL_FILE" 0 event))"
ok
[ "$(_field "$JOURNAL_FILE" 0 component)" = "builder" ] || fail "component should be builder"
ok
[ "$(_field "$JOURNAL_FILE" 0 slug)" = "my-slug" ] || fail "slug should be my-slug (got $(_field "$JOURNAL_FILE" 0 slug))"
ok
[ "$(_field "$JOURNAL_FILE" 0 text)" = "this red is a stale cached row" ] || fail "text field wrong"
ok

# HERD_SLUG override wins over cwd basename.
: > "$JOURNAL_FILE"
out="$(
  cd "$WT" && \
  HERD_CONFIG_FILE="$MAIN/.herd/config" \
  JOURNAL_FILE="$JOURNAL_FILE" \
  HERMETIC_TEST=1 \
  HERD_SLUG="explicit-slug" \
  bash "$HERD_BIN" note "override works" 2>&1
)" || fail "herd note with HERD_SLUG failed: $out"
[ "$(_field "$JOURNAL_FILE" 0 slug)" = "explicit-slug" ] || fail "HERD_SLUG should win (got $(_field "$JOURNAL_FILE" 0 slug))"
ok

# Truncation ~300 chars.
long="$(python3 -c 'print("x"*400)')"
: > "$JOURNAL_FILE"
out="$(
  cd "$WT" && \
  HERD_CONFIG_FILE="$MAIN/.herd/config" \
  JOURNAL_FILE="$JOURNAL_FILE" \
  HERMETIC_TEST=1 \
  HERD_SLUG="my-slug" \
  bash "$HERD_BIN" note "$long" 2>&1
)" || fail "herd note with long text failed"
text_len="$(python3 -c 'import json,sys; print(len(json.loads(open(sys.argv[1]).read().strip())["text"]))' "$JOURNAL_FILE")"
[ "$text_len" -le 300 ] || fail "text should be truncated to ~300 chars (got $text_len)"
ok

# Missing args is a hard usage error (exit non-zero).
if HERD_CONFIG_FILE="$MAIN/.herd/config" JOURNAL_FILE="$JOURNAL_FILE" HERMETIC_TEST=1 \
    bash "$HERD_BIN" note 2>/dev/null; then
  fail "herd note with no args should fail"
fi
ok

# ── (2)+(3) watcher surfaces builder_note + first-scan pin is dormant ────────────────────────────
# Stub binaries so a stray call never hits the network; override notify into a file.
BIN="$T/bin"; mkdir -p "$BIN"
for cmd in gh git herdr; do printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$cmd"; chmod +x "$BIN/$cmd"; done
export PATH="$BIN:$PATH"

export AGENT_WATCH_LIB=1
export HERD_CONFIG_FILE="$MAIN/.herd/config"
export WORKTREES_DIR="$TREES"
export PROJECT_ROOT="$MAIN"
export WORKSPACE_NAME="builder-notes-test"
export NO_COLOR=1
export HERD_FAKE_NOW=1700000000
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"
for fn in _builder_notes_scan build_builder_notes _builder_notes_journal; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined after sourcing"
done
ok

# Point ledger/cursor at our TREES (already set via WORKTREES_DIR at source time, but re-pin for clarity).
BUILDER_NOTES_LEDGER="$TREES/.agent-watch-builder-notes"
BUILDER_NOTES_CURSOR="$TREES/.agent-watch-builder-notes-cursor"
rm -f "$BUILDER_NOTES_LEDGER" "$BUILDER_NOTES_CURSOR"
NOTIFY_LOG="$T/notify.log"; : > "$NOTIFY_LOG"
herd_driver_notify() { printf '%s\t%s\n' "$1" "$2" >> "$NOTIFY_LOG"; }

# Seed a journal with a NON-builder_note event, then first-scan: must pin cursor at EOF and surface nothing.
: > "$JOURNAL_FILE"
printf '%s\n' '{"ts":"2026-01-01T00:00:00Z","event":"seed","pr":1}' > "$JOURNAL_FILE"
_builder_notes_scan
[ -f "$BUILDER_NOTES_CURSOR" ] || fail "first scan should create the cursor"
[ -s "$BUILDER_NOTES_LEDGER" ] && fail "first scan must NOT surface historical events"
[ -s "$NOTIFY_LOG" ] && fail "first scan must NOT notify"
BUILDER_NOTES_ROWS=""
build_builder_notes
[ -z "${BUILDER_NOTES_ROWS:-}" ] || fail "empty ledger should leave BUILDER_NOTES_ROWS empty"
ok

# Append a builder_note via the REAL CLI, then second scan should surface it.
out="$(
  cd "$WT" && \
  HERD_CONFIG_FILE="$MAIN/.herd/config" \
  JOURNAL_FILE="$JOURNAL_FILE" \
  HERMETIC_TEST=1 \
  HERD_SLUG="my-slug" \
  bash "$HERD_BIN" note "my test file is not wired into the gate" 2>&1
)" || fail "second herd note failed: $out"

# Confirm the journal has a builder_note after the seed.
has_note="$(python3 -c '
import json,sys
n=0
for line in open(sys.argv[1]):
    line=line.strip()
    if not line: continue
    o=json.loads(line)
    if o.get("event")=="builder_note": n+=1
print(n)
' "$JOURNAL_FILE")"
[ "$has_note" = "1" ] || fail "expected exactly 1 builder_note after seed (got $has_note)"
ok

_builder_notes_scan
[ -s "$BUILDER_NOTES_LEDGER" ] || fail "scan should append a ledger row after a new builder_note"
grep -q "my-slug" "$BUILDER_NOTES_LEDGER" || fail "ledger should carry the slug"
grep -q "not wired into the gate" "$BUILDER_NOTES_LEDGER" || fail "ledger should carry the finding text"
ok
[ -s "$NOTIFY_LOG" ] || fail "scan should fire one notify"
grep -q "builder note" "$NOTIFY_LOG" || fail "notify title should mention builder note"
grep -q "not wired into the gate" "$NOTIFY_LOG" || fail "notify body should carry the finding"
ok

# Idempotent: a second scan with no new events does NOT re-notify.
: > "$NOTIFY_LOG"
_builder_notes_scan
[ -s "$NOTIFY_LOG" ] && fail "second scan with no new events must not re-notify"
ok

# build_builder_notes renders the row.
BUILDER_NOTES_ROWS=""
build_builder_notes
[ -n "${BUILDER_NOTES_ROWS:-}" ] || fail "build_builder_notes should render a row"
printf '%s' "$BUILDER_NOTES_ROWS" | grep -q "my-slug" || fail "render missing slug"
printf '%s' "$BUILDER_NOTES_ROWS" | grep -q "not wired into the gate" || fail "render missing text"
ok

# ── (4) lane preambles instruct builders to use herd note ────────────────────────────────────────
grep -q 'herd note' "$QUICK"   || fail "herd-quick.sh preamble must mention herd note"
grep -q 'BUILDER NOTES' "$QUICK" || fail "herd-quick.sh preamble must label BUILDER NOTES"
ok
grep -q 'herd note' "$FEATURE" || fail "herd-feature.sh preamble must mention herd note"
grep -q 'BUILDER NOTES' "$FEATURE" || fail "herd-feature.sh preamble must label BUILDER NOTES"
ok

# capabilities + conformance rows present.
grep -q $'herd note "<finding>"\tcommand' "$REPO/templates/capabilities.tsv" \
  || fail "capabilities.tsv missing herd note row"
grep -q $'herd note "<finding>"\tunit\ttests/test-builder-notes-journal.sh' "$REPO/templates/conformance.tsv" \
  || fail "conformance.tsv missing herd note proof row"
ok

echo "ALL PASS ($pass assertions)"
