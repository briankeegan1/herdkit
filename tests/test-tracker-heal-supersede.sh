#!/usr/bin/env bash
# test-tracker-heal-supersede.sh — hermetic proof of HERD-284: healed tracker rows supersede
# prior failed rows for the same key in the watch console.
#
# Verifies herd_console_visible_lines_tracker / herd_console_section_tracker in
# scripts/herd/console-section.sh, exercised via build_tracker_drift from agent-watch.sh:
#   (1) basic supersession — a failed row for HERD-x is hidden once a healed row exists for HERD-x
#   (2) multi-failed — multiple failed rows for the same ref are all superseded by one healed row
#   (3) cross-key isolation — healed HERD-x does NOT hide failed rows for a different HERD-y
#   (4) byte-identical — with no healed row for a ref, the tracker variant renders identically to
#       the plain herd_console_section (no supersession ⇒ no output change)
#   (5) fail-soft — a malformed line with no tracker ref does not crash and is never spuriously
#       suppressed by a same-ref healed row (there is none)
#   (6) new functions defined — herd_console_visible_lines_tracker / herd_console_section_tracker
# Fully hermetic: temp dirs only, no network, AGENT_WATCH_LIB=1, fake clock.
# Run:  bash tests/test-tracker-heal-supersede.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
WATCH="$REPO/scripts/herd/agent-watch.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

[ -f "$WATCH" ] || fail "agent-watch.sh not found at $WATCH"

MAIN="$T/main"; TREES="$T/trees"
mkdir -p "$MAIN/.herd" "$TREES"
cat > "$MAIN/.herd/config" <<EOF
WORKTREES_DIR="$TREES"
DEFAULT_BRANCH=main
EOF

BIN="$T/bin"; mkdir -p "$BIN"
for cmd in gh git herdr; do printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$cmd"; chmod +x "$BIN/$cmd"; done
export PATH="$BIN:$PATH"

NOW=1700000000
H1=$(( NOW - 3600 ))   # 1h ago — within retention window

export AGENT_WATCH_LIB=1
export HERD_CONFIG_FILE="$MAIN/.herd/config"
export WORKTREES_DIR="$TREES"
export PROJECT_ROOT="$MAIN"
export WORKSPACE_NAME="supersede-test"
export NO_COLOR=1
export HERD_FAKE_NOW="$NOW"
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"

TRACKER_HEAL_FILE="$TREES/.agent-watch-tracker-heals"

# ── (6) new functions must be defined after sourcing ────────────────────────────────────────────
for fn in herd_console_visible_lines_tracker herd_console_section_tracker; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined after sourcing"
done
ok

# ── (1) basic supersession ───────────────────────────────────────────────────────────────────────
# Ledger: older failed row, then a newer healed row — same ref.  Failed must be hidden.
cat > "$TRACKER_HEAL_FILE" <<EOF
$H1 failed HERD-377 377 in-progress
$NOW healed HERD-377 377 merged
EOF

build_tracker_drift
[ -n "${TRACKER_DRIFT:-}" ] || fail "(1) section must render when a healed row exists"
printf '%s' "$TRACKER_DRIFT" | grep -q "HERD-377" || fail "(1) the healed row for HERD-377 must render"
ok
printf '%s' "$TRACKER_DRIFT" | grep -q "failed" && fail "(1) the superseded failed row for HERD-377 must NOT render"
ok
[ "$(printf '%s' "$TRACKER_DRIFT" | grep -c .)" -eq 1 ] \
  || fail "(1) expected exactly 1 rendered row (got $(printf '%s' "$TRACKER_DRIFT" | grep -c .))"
ok
# Display-only: the ledger is never modified
grep -q "failed" "$TRACKER_HEAL_FILE" || fail "(1) supersession must not modify the ledger"
ok

# ── (2) multiple failed rows for the same ref, all superseded ────────────────────────────────────
cat > "$TRACKER_HEAL_FILE" <<EOF
$((H1 - 3600)) failed HERD-400 400 in-progress
$H1 failed HERD-400 400 in-progress
$NOW healed HERD-400 400 merged
EOF

build_tracker_drift
printf '%s' "$TRACKER_DRIFT" | grep -q "healed" || fail "(2) the healed row for HERD-400 must render"
ok
printf '%s' "$TRACKER_DRIFT" | grep -q "failed" && fail "(2) all failed rows for HERD-400 must be superseded"
ok
[ "$(printf '%s' "$TRACKER_DRIFT" | grep -c .)" -eq 1 ] \
  || fail "(2) expected exactly 1 rendered row (got $(printf '%s' "$TRACKER_DRIFT" | grep -c .))"
ok

# ── (3) cross-key isolation — healed HERD-x must NOT hide failed HERD-y ─────────────────────────
cat > "$TRACKER_HEAL_FILE" <<EOF
$H1 failed HERD-500 500 in-progress
$NOW healed HERD-600 600 merged
EOF

build_tracker_drift
printf '%s' "$TRACKER_DRIFT" | grep -q "HERD-600" || fail "(3) healed HERD-600 must render"
ok
printf '%s' "$TRACKER_DRIFT" | grep -q "HERD-500" || fail "(3) failed HERD-500 must still render (different ref)"
ok
[ "$(printf '%s' "$TRACKER_DRIFT" | grep -c .)" -eq 2 ] \
  || fail "(3) expected exactly 2 rendered rows (got $(printf '%s' "$TRACKER_DRIFT" | grep -c .))"
ok

# ── (4) byte-identical when no supersession applies ──────────────────────────────────────────────
# Only failed rows, no healed rows — the two variants must produce identical output.
cat > "$TRACKER_HEAL_FILE" <<EOF
$H1 failed HERD-700 700 in-progress
$NOW failed HERD-800 800 in-progress
EOF

plain_out="$(herd_console_section "$TRACKER_HEAL_FILE" 3 \
  herd_console_classify_tracker_heal _tracker_heal_row)"
tracker_out="$(herd_console_section_tracker "$TRACKER_HEAL_FILE" 3 _tracker_heal_row)"
[ "$plain_out" = "$tracker_out" ] || {
  printf 'plain:   %q\ntracker: %q\n' "$plain_out" "$tracker_out" >&2
  fail "(4) with no healed rows, output must be byte-identical to the plain variant"
}
ok

# ── (5) fail-soft: malformed line with no tracker ref does not crash ─────────────────────────────
cat > "$TRACKER_HEAL_FILE" <<EOF
$NOW failed
EOF
# The render fn returns 1 for a missing ref, so the section is empty — but must not abort.
build_tracker_drift
ok

# ── conformance row present ───────────────────────────────────────────────────────────────────────
grep -q $'console-section.sh\tunit\ttests/test-tracker-heal-supersede.sh' "$REPO/templates/conformance.tsv" \
  || fail "conformance.tsv missing console-section.sh proof row for this test"
ok

echo "ALL PASS ($pass assertions)"
