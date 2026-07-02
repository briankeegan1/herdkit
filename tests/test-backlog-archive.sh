#!/usr/bin/env bash
# test-backlog-archive.sh — hermetic test of the shipped-item ARCHIVE rotation the file backend
# runs at scribe-commit time (_backend_archive_shipped in scripts/herd/backends/file.sh). Shipped
# (✅) entries beyond the most recent ~10 must MOVE (not delete) to BACKLOG.archive.md — a file the
# coordinator and builders never read — so the per-turn BACKLOG.md the coordinator pays for stays
# bounded. Asserts: the RIGHT (oldest) entries move, the newest stay, BACKLOG.md format is
# preserved (other sections + heading intact), the archive gets its one-line header, and the step
# is a no-op at/under the cap. NETWORK-FREE, no git. Run:  bash tests/test-backlog-archive.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BACKEND="$HERE/../scripts/herd/backends/file.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail(){ echo "FAIL: $1" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || fail "python3 required to run this test"

# Source the backend to get _backend_archive_shipped. It only DEFINES functions (no side effects).
# shellcheck source=/dev/null
. "$BACKEND"

# Build a fixture BACKLOG.md with an unrelated section + N shipped entries (newest-first, as the
# reap flow prepends them under the heading).
make_backlog() {
  local n="$1" i
  {
    printf '# herdkit — backlog\n\n'
    printf '## Reliability / safety\n'
    printf -- '- 🔜 **Open item that must survive** — a queued thing\n\n'
    printf '## Recently shipped\n\n'
    for i in $(seq 1 "$n"); do
      printf -- '- ✅ **Ship %02d** *(PR #%d)*\n' "$i" "$((100 + i))"
    done
  } > "$T/BACKLOG.md"
}

run_archive() {
  # Invoke the rotation exactly as _backend_add_item does, from the repo cwd.
  ( cd "$T" && BACKLOG_FILE="BACKLOG.md" SHIPPED_KEEP="${1:-10}" _backend_archive_shipped )
}

ARCHIVE="$T/BACKLOG.archive.md"

# ── (1) 12 shipped, keep 10 → 2 oldest rotate out ─────────────────────────────
make_backlog 12
run_archive 10 || fail "archive step returned non-zero"

n_kept="$(grep -c '✅' "$T/BACKLOG.md")"
[ "$n_kept" -eq 10 ] || fail "expected 10 shipped entries kept in BACKLOG.md, got $n_kept"
# Newest ten (Ship 01..10) stay; the two oldest (Ship 11, Ship 12) leave.
grep -q 'Ship 10' "$T/BACKLOG.md" || fail "BACKLOG.md dropped a kept entry (Ship 10)"
grep -q 'Ship 11' "$T/BACKLOG.md" && fail "BACKLOG.md still holds overflow entry Ship 11"
grep -q 'Ship 12' "$T/BACKLOG.md" && fail "BACKLOG.md still holds overflow entry Ship 12"
[ -f "$ARCHIVE" ] || fail "archive file was not created"
grep -q 'Ship 11' "$ARCHIVE" || fail "archive missing rotated entry Ship 11"
grep -q 'Ship 12' "$ARCHIVE" || fail "archive missing rotated entry Ship 12"
# One-line header explaining the file.
head -1 "$ARCHIVE" | grep -q 'backlog archive' || fail "archive missing its explanatory header line"

# ── (2) format preservation: unrelated section + heading + open item survive ──
grep -q '^# herdkit — backlog$'        "$T/BACKLOG.md" || fail "top title lost"
grep -q '^## Reliability / safety$'    "$T/BACKLOG.md" || fail "unrelated section heading lost"
grep -q 'Open item that must survive'  "$T/BACKLOG.md" || fail "open (🔜) item was disturbed"
grep -q '^## Recently shipped$'        "$T/BACKLOG.md" || fail "Recently shipped heading lost"
# The blank line between the heading and the first entry is preserved (format byte-for-byte).
awk '/^## Recently shipped$/{getline nx; if(nx=="") ok=1} END{exit ok?0:1}' "$T/BACKLOG.md" \
  || fail "blank line after Recently shipped heading not preserved"

# ── (3) no-op at/under the cap: exactly 10 shipped → no rotation, no archive ───
rm -f "$ARCHIVE"
make_backlog 10
before="$(cat "$T/BACKLOG.md")"
run_archive 10 || fail "archive step returned non-zero on the no-op case"
[ "$before" = "$(cat "$T/BACKLOG.md")" ] || fail "BACKLOG.md changed when at the cap (should be a no-op)"
[ -f "$ARCHIVE" ] && fail "archive file created when nothing needed rotating"

# ── (4) idempotent: re-running after a rotation moves nothing more ────────────
make_backlog 11
run_archive 10 || fail "archive step returned non-zero (round 1)"
snap_backlog="$(cat "$T/BACKLOG.md")"; snap_archive="$(cat "$ARCHIVE")"
run_archive 10 || fail "archive step returned non-zero (round 2)"
[ "$snap_backlog" = "$(cat "$T/BACKLOG.md")" ] || fail "second run mutated BACKLOG.md (not idempotent)"
[ "$snap_archive"  = "$(cat "$ARCHIVE")" ]     || fail "second run mutated the archive (not idempotent)"

# ── (5) absent section → clean no-op (no crash, no archive) ───────────────────
rm -f "$ARCHIVE"
printf '# herdkit — backlog\n\n## Reliability\n- 🔜 thing\n' > "$T/BACKLOG.md"
run_archive 10 || fail "archive step crashed when there is no Recently shipped section"
[ -f "$ARCHIVE" ] && fail "archive created when there was no shipped section"

echo "ALL PASS"
