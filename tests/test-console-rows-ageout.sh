#!/usr/bin/env bash
# test-console-rows-ageout.sh — hermetic proof of HERD-243: console rows AGE OUT.
#
# The tracker-heal and builder-note sections both render append-only ledgers. This proves the ONE
# shared bounded-section helper (scripts/herd/console-section.sh) that both now go through:
#
#   (1) age-out — a CALM row (a `healed` heal, a builder note) older than CONSOLE_ROW_RETENTION (2h)
#       leaves the DISPLAY; a fresh row (now / now-1h) stays.
#   (2) loud rows never age out — a 3h-old FAILED heal is still on screen (a stuck drift is not history).
#   (3) ack — a builder note whose exact ledger line sits in the ack sidecar is hidden immediately,
#       and `herd notes ack <n|all>` is what puts it there. The journal/ledger are untouched.
#   (4) file trim — both ledger FILES are tail-kept at 20 rows on write (CONSOLE_LEDGER_MAX).
#   (5) byte-identical — with only fresh, unacked rows BOTH sections render exactly what the
#       pre-HERD-243 renderers produced (no cosmetic drift).
#
# Fully hermetic: temp dirs only, no network, no live watcher loop (AGENT_WATCH_LIB=1), fake clock.
# Run:  bash tests/test-console-rows-ageout.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
HERD_BIN="$REPO/bin/herd"
WATCH="$REPO/scripts/herd/agent-watch.sh"
LIB="$REPO/scripts/herd/console-section.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

[ -f "$LIB" ]      || fail "scripts/herd/console-section.sh not found"
[ -f "$WATCH" ]    || fail "agent-watch.sh not found"
[ -f "$HERD_BIN" ] || fail "bin/herd not found"

# ── Fixture project ──────────────────────────────────────────────────────────────────────────────
MAIN="$T/main"; TREES="$T/trees"
mkdir -p "$MAIN/.herd" "$TREES/.herd"
cat > "$MAIN/.herd/config" <<EOF
WORKTREES_DIR="$TREES"
DEFAULT_BRANCH=main
EOF

BIN="$T/bin"; mkdir -p "$BIN"
for cmd in gh git herdr; do printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$cmd"; chmod +x "$BIN/$cmd"; done
export PATH="$BIN:$PATH"

NOW=1700000000
H1=$(( NOW - 3600 ))    # 1h ago — fresh
H3=$(( NOW - 10800 ))   # 3h ago — past the 2h retention window

export AGENT_WATCH_LIB=1
export HERD_CONFIG_FILE="$MAIN/.herd/config"
export WORKTREES_DIR="$TREES"
export PROJECT_ROOT="$MAIN"
export WORKSPACE_NAME="ageout-test"
export NO_COLOR=1
export HERD_FAKE_NOW="$NOW"
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"

for fn in herd_console_row_visible herd_console_visible_lines herd_console_section herd_console_trim \
          herd_console_classify_tracker_heal herd_console_classify_builder_note \
          build_tracker_drift build_builder_notes; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined after sourcing"
done
ok

[ "$CONSOLE_ROW_RETENTION" = "7200" ] || fail "retention should be 2h (got $CONSOLE_ROW_RETENTION)"
[ "$CONSOLE_LEDGER_MAX" = "20" ]      || fail "ledger bound should be 20 (got $CONSOLE_LEDGER_MAX)"
ok

# Re-pin the ledger paths (they were computed from WORKTREES_DIR at source time; be explicit).
TRACKER_HEAL_FILE="$TREES/.agent-watch-tracker-heals"
BUILDER_NOTES_LEDGER="$TREES/.agent-watch-builder-notes"
BUILDER_NOTES_ACK="$TREES/.agent-watch-builder-notes-acked"

# ── (1)+(2) tracker heals: calm ages out, LOUD failed row never does ─────────────────────────────
cat > "$TRACKER_HEAL_FILE" <<EOF
$H3 healed HERD-old 100 open
$H3 failed HERD-stuck 101 open
$H1 healed HERD-fresh 102 in-progress
$NOW healed HERD-now 103 open
EOF

build_tracker_drift
[ -n "${TRACKER_DRIFT:-}" ] || fail "tracker drift section should render"
printf '%s' "$TRACKER_DRIFT" | grep -q "HERD-now"   || fail "a now row must render"
printf '%s' "$TRACKER_DRIFT" | grep -q "HERD-fresh" || fail "a 1h-old calm row must still render"
ok
printf '%s' "$TRACKER_DRIFT" | grep -q "HERD-old" && fail "a 3h-old HEALED (calm) row must age out of display"
ok
printf '%s' "$TRACKER_DRIFT" | grep -q "HERD-stuck" || fail "a 3h-old FAILED (loud) row must NEVER age out"
ok
# The aged-out row is display-only: the LEDGER still holds it (history is never rewritten).
grep -q "HERD-old" "$TRACKER_HEAL_FILE" || fail "age-out must not delete the ledger row"
ok
# Hidden rows do not consume one of the 3 slots: 3 visible rows survive here.
[ "$(printf '%s' "$TRACKER_DRIFT" | grep -c .)" -eq 3 ] || fail "expected exactly 3 rendered heal rows"
ok

# Every row aged out (and none loud) ⇒ the section vanishes entirely.
printf '%s healed HERD-ancient 99 open\n' "$H3" > "$TRACKER_HEAL_FILE"
build_tracker_drift
[ -z "${TRACKER_DRIFT:-}" ] || fail "all-aged-out calm ledger should render NO section"
ok

# Fail-soft: a garbage epoch is SHOWN, never silently swallowed.
printf 'not-an-epoch healed HERD-weird 98 open\n' > "$TRACKER_HEAL_FILE"
build_tracker_drift
printf '%s' "$TRACKER_DRIFT" | grep -q "HERD-weird" || fail "unparseable epoch must fail-soft to VISIBLE"
ok

# ── (1)+(3) builder notes: age-out + ack ────────────────────────────────────────────────────────
: > "$BUILDER_NOTES_ACK"
{
  printf '%s\tslug-old\told finding\t2026-01-01T00:00:00Z\n' "$H3"
  printf '%s\tslug-fresh\tfresh finding\t2026-01-01T02:00:00Z\n' "$H1"
  printf '%s\tslug-now\tnow finding\t2026-01-01T03:00:00Z\n' "$NOW"
} > "$BUILDER_NOTES_LEDGER"

build_builder_notes
printf '%s' "$BUILDER_NOTES_ROWS" | grep -q "now finding"   || fail "a now note must render"
printf '%s' "$BUILDER_NOTES_ROWS" | grep -q "fresh finding" || fail "a 1h-old note must render"
ok
printf '%s' "$BUILDER_NOTES_ROWS" | grep -q "old finding" && fail "a 3h-old note must age out of display"
ok
grep -q "old finding" "$BUILDER_NOTES_LEDGER" || fail "note age-out must not delete the ledger row"
ok

# Ack the newest note by its verbatim ledger line → hidden immediately, ledger untouched.
printf '%s\tslug-now\tnow finding\t2026-01-01T03:00:00Z\n' "$NOW" > "$BUILDER_NOTES_ACK"
build_builder_notes
printf '%s' "$BUILDER_NOTES_ROWS" | grep -q "now finding" && fail "an acked note must be hidden"
ok
printf '%s' "$BUILDER_NOTES_ROWS" | grep -q "fresh finding" || fail "acking one note must not hide the others"
ok
grep -q "now finding" "$BUILDER_NOTES_LEDGER" || fail "ack must not delete the ledger row"
ok

# Everything acked or aged out ⇒ no section at all (byte-identical console when there is nothing to say).
{
  printf '%s\tslug-fresh\tfresh finding\t2026-01-01T02:00:00Z\n' "$H1"
  printf '%s\tslug-now\tnow finding\t2026-01-01T03:00:00Z\n' "$NOW"
} > "$BUILDER_NOTES_ACK"
build_builder_notes
[ -z "${BUILDER_NOTES_ROWS:-}" ] || fail "all-acked/aged ledger should render NO section"
ok

# ── (4) file trim at CONSOLE_LEDGER_MAX ─────────────────────────────────────────────────────────
: > "$T/big"
for i in $(seq 1 35); do printf '%s healed HERD-%s %s open\n' "$NOW" "$i" "$i" >> "$T/big"; done
herd_console_trim "$T/big"
[ "$(grep -c . "$T/big")" -eq 20 ] || fail "herd_console_trim should tail-keep 20 rows (got $(grep -c . "$T/big"))"
ok
grep -q "HERD-35 " "$T/big" || fail "trim must keep the NEWEST rows"
grep -q "HERD-15 " "$T/big" && fail "trim must drop the oldest rows"
ok
# Under the bound: untouched.
printf 'a\nb\n' > "$T/small"; herd_console_trim "$T/small"
[ "$(grep -c . "$T/small")" -eq 2 ] || fail "trim must not touch a ledger under the bound"
ok
# Missing file: silent success (fail-soft).
herd_console_trim "$T/nope" || fail "trim of a missing file must be a no-op success"
ok

# The tracker sweep trims its heal ledger through the SAME helper (no second bound to drift).
grep -q 'herd_console_trim "$NOTE_FILE"' "$REPO/scripts/herd/tracker-state-sweep.sh" \
  || fail "tracker-state-sweep.sh must trim the heal ledger via herd_console_trim"
ok

# ── (5) byte-identical render for fresh, unacked rows ───────────────────────────────────────────
# Reference = the pre-HERD-243 renderers, verbatim.
: > "$BUILDER_NOTES_ACK"
cat > "$TRACKER_HEAL_FILE" <<EOF
$H1 healed HERD-a 1 open
$NOW failed HERD-b 2 in-progress
EOF
{
  printf '%s\tslug-a\tfinding a\t2026-01-01T02:00:00Z\n' "$H1"
  printf '%s\tslug-b\tfinding b\t2026-01-01T03:00:00Z\n' "$NOW"
} > "$BUILDER_NOTES_LEDGER"

legacy_tracker_drift() {
  local epoch status ref pr state hhmm glyph color rows=""
  while read -r epoch status ref pr state; do
    [ -n "${ref:-}" ] || continue
    hhmm="$(epoch_to_hhmm "$epoch")"
    case "$status" in
      healed) glyph='🩹'; color="$C_GREEN" ;;
      *)      glyph='⚠️'; color="$C_RED"   ;;
    esac
    rows="${rows}    ${color}${glyph}${C_RESET} ${C_BOLD}${ref}${C_RESET} ${color}${status}${C_RESET} ${C_DIM}#${pr} was ${state} · ${hhmm}${C_RESET}"$'\n'
  done < <(reverse_file "$TRACKER_HEAL_FILE" | head -3)
  printf '%s' "$rows"
}
legacy_builder_notes() {
  local epoch slug text ts hhmm rows=""
  # shellcheck disable=SC2034  # ts consumes the 4th TSV field, exactly as the pre-HERD-243 renderer did
  while IFS=$'\t' read -r epoch slug text ts; do
    [ -n "${slug:-}" ] || continue
    hhmm="$(epoch_to_hhmm "$epoch")"
    rows="${rows}    ${C_CYAN}📝${C_RESET} ${C_BOLD}${slug}${C_RESET} ${text} ${C_DIM}${hhmm}${C_RESET}"$'\n'
  done < <(reverse_file "$BUILDER_NOTES_LEDGER" | head -5)
  printf '%s' "$rows"
}

build_tracker_drift
[ "${TRACKER_DRIFT}" = "$(legacy_tracker_drift)"$'\n' ] || {
  printf 'new: %q\nold: %q\n' "$TRACKER_DRIFT" "$(legacy_tracker_drift)" >&2
  fail "tracker section must be byte-identical for fresh rows"
}
ok
build_builder_notes
[ "${BUILDER_NOTES_ROWS}" = "$(legacy_builder_notes)"$'\n' ] || {
  printf 'new: %q\nold: %q\n' "$BUILDER_NOTES_ROWS" "$(legacy_builder_notes)" >&2
  fail "builder-notes section must be byte-identical for fresh, unacked rows"
}
ok

# ── (3) `herd notes` CLI: list + ack <n> + ack all ──────────────────────────────────────────────
: > "$BUILDER_NOTES_ACK"
run_herd() { HERD_CONFIG_FILE="$MAIN/.herd/config" HERD_FAKE_NOW="$NOW" HERMETIC_TEST=1 NO_COLOR=1 \
  bash "$HERD_BIN" "$@" 2>&1; }

out="$(cd "$MAIN" && run_herd notes)" || fail "herd notes failed: $out"
printf '%s' "$out" | grep -q "finding b" || fail "herd notes should list the newest note (got: $out)"
printf '%s' "$out" | grep -q "finding a" || fail "herd notes should list the older fresh note"
ok

# ack #1 = the newest = "finding b".
out="$(cd "$MAIN" && run_herd notes ack 1)" || fail "herd notes ack 1 failed: $out"
printf '%s' "$out" | grep -qi "acked" || fail "ack should confirm (got: $out)"
grep -q "finding b" "$BUILDER_NOTES_ACK" || fail "ack 1 should record the newest ledger line"
grep -q "finding a" "$BUILDER_NOTES_ACK" && fail "ack 1 must not ack the other note"
ok
build_builder_notes
printf '%s' "$BUILDER_NOTES_ROWS" | grep -q "finding b" && fail "acked note must leave the console"
printf '%s' "$BUILDER_NOTES_ROWS" | grep -q "finding a" || fail "unacked note must stay on the console"
ok
# The journal-facing ledger is untouched by an ack.
grep -q "finding b" "$BUILDER_NOTES_LEDGER" || fail "ack must never rewrite the ledger"
ok
# The acked note is gone from the CLI listing too (one shared visibility rule).
out="$(cd "$MAIN" && run_herd notes)" || fail "herd notes failed after ack: $out"
printf '%s' "$out" | grep -q "finding b" && fail "herd notes must not list an acked note"
ok

# Bad index / bad subcommand are hard usage errors (one note is still on the console here).
if (cd "$MAIN" && run_herd notes ack 99 >/dev/null 2>&1); then fail "ack of a nonexistent index should fail"; fi
ok
if (cd "$MAIN" && run_herd notes bogus >/dev/null 2>&1); then fail "unknown subcommand should fail"; fi
ok

out="$(cd "$MAIN" && run_herd notes ack all)" || fail "herd notes ack all failed: $out"
build_builder_notes
[ -z "${BUILDER_NOTES_ROWS:-}" ] || fail "ack all should clear the whole section"
ok
out="$(cd "$MAIN" && run_herd notes)" || fail "herd notes on an empty console should exit 0: $out"
printf '%s' "$out" | grep -qi "no builder notes" || fail "empty console should say so (got: $out)"
ok

# The ack sidecar is bounded, and never keeps an ack for an evicted ledger row.
[ "$(grep -c . "$BUILDER_NOTES_ACK")" -le 20 ] || fail "ack sidecar must stay bounded at 20"
ok

# ── manifest rows ───────────────────────────────────────────────────────────────────────────────
grep -q $'herd notes \[list|ack <n|all>\]\tcommand' "$REPO/templates/capabilities.tsv" \
  || fail "capabilities.tsv missing herd notes row"
grep -q $'console-section.sh\tlane' "$REPO/templates/capabilities.tsv" \
  || fail "capabilities.tsv missing console-section.sh row"
ok
grep -q $'herd notes \[list|ack <n|all>\]\tunit\ttests/test-console-rows-ageout.sh' "$REPO/templates/conformance.tsv" \
  || fail "conformance.tsv missing herd notes proof row"
grep -q $'console-section.sh\tunit\ttests/test-console-rows-ageout.sh' "$REPO/templates/conformance.tsv" \
  || fail "conformance.tsv missing console-section.sh proof row"
ok

echo "ALL PASS ($pass assertions)"
