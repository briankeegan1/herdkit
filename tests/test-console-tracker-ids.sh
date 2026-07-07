#!/usr/bin/env bash
# test-console-tracker-ids.sh — hermetic tests for the console tracker-id labelling (HERD-92): the
# watcher renders every row as "<ref> <slug>" wherever a tracker ref is known, and the plain slug
# (BYTE-IDENTICAL to before) when it is not.
#
# Sources agent-watch.sh in lib mode (AGENT_WATCH_LIB=1 — helpers only, no polling loop, no console,
# no network), pointing config discovery at a nonexistent file so herd-config.sh falls back to its
# generic defaults. Exercises the pure labelling helpers (_slug_ref / _slug_cell), the "recently
# landed" render (build_landed) over ref-carrying and ref-less state rows, and the already_merged
# idempotency guard against both the 3-field (pre-HERD-92) and 4-field (ref) state formats.
# Run:  bash tests/test-console-tracker-ids.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../scripts/herd/agent-watch.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass(){ PASS=$((PASS+1)); }

[ -f "$WATCH" ] || fail "agent-watch.sh not found at $WATCH"
command -v python3 >/dev/null 2>&1 || fail "python3 required to run this test"

# ── Source the watcher's helpers WITHOUT its live loop (lib mode) ─────────────────────────────────
export AGENT_WATCH_LIB=1
export HERD_CONFIG_FILE="$T/no-such-config"
export WORKTREES_DIR="$T"          # $TREES / $STATE / the ref markers all live under here
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"
for fn in _slug_ref _slug_ref_file _slug_cell build_landed already_merged; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined after sourcing"
done

# ── 1. _slug_ref: reads the per-worktree marker; fail-soft when absent/blank ──────────────────────
[ -z "$(_slug_ref no-marker)" ] || fail "_slug_ref should be empty with no marker"; pass
printf '%s\n' "HERD-92" > "$T/.herd-ref-tracked"
[ "$(_slug_ref tracked)" = "HERD-92" ] || fail "_slug_ref did not read the marker"; pass
# Only the FIRST token — a malformed multi-token marker can never inject spaces/newlines into a row.
printf '%s\n' "HERD-7 junk here" > "$T/.herd-ref-messy"
[ "$(_slug_ref messy)" = "HERD-7" ] || fail "_slug_ref should read only the first token"; pass
: > "$T/.herd-ref-blank"
[ -z "$(_slug_ref blank)" ] || fail "_slug_ref should be empty for a blank marker"; pass

# ── 2. _slug_cell: '<ref> <slug>' when a ref is known; BYTE-IDENTICAL plain slug when not ──────────
# Ref-less rendering MUST equal the pre-HERD-92 column exactly (the fail-soft invariant).
want_plain="$(printf '%-*s' "$SLUGW" "untracked-slug")"
[ "$(_slug_cell untracked-slug)" = "$want_plain" ] || fail "ref-less _slug_cell must be byte-identical to the plain padded slug"; pass
# Marker-driven ref (in-flight rows look it up).
[ "$(_slug_cell tracked)" = "$(printf '%-*s' "$SLUGW" "HERD-92 tracked")" ] || fail "_slug_cell should prefix the marker ref"; pass
# Explicit ref (landed rows pass it in) wins without a marker present.
[ "$(_slug_cell any-slug HERD-42)" = "$(printf '%-*s' "$SLUGW" "HERD-42 any-slug")" ] || fail "_slug_cell should use an explicit ref"; pass
case "$(_slug_cell tracked)" in *"HERD-92 tracked"*) pass ;; *) fail "cell should contain 'HERD-92 tracked'";; esac

# ── 3. build_landed: renders the ref for a 4-field state row, plain slug for a 3-field row ─────────
# STATE format: "<epoch> <pr#> <slug> [ref]". The 4th field is the merge-captured tracker ref.
{
  echo "1700000000 101 legacy-landed"          # 3-field, pre-HERD-92 → plain slug
  echo "1700000100 102 tracked-landed HERD-88" # 4-field → '<ref> <slug>'
} > "$STATE"
build_landed
case "$LANDED" in *"HERD-88 tracked-landed"*) pass ;; *) fail "build_landed must render 'HERD-88 tracked-landed'";; esac
# The legacy row shows the bare slug and never invents a ref. Inspect that row in ISOLATION (LANDED
# holds both rows, so a whole-string match would see the other row's ref).
legacy_row="$(printf '%s\n' "$LANDED" | grep -F 'legacy-landed')"
[ -n "$legacy_row" ] || fail "build_landed must still render the legacy slug"; pass
case "$legacy_row" in *HERD*) fail "legacy row must not gain a phantom ref";; *) pass ;; esac

# ── 4. already_merged: idempotency guard matches BOTH the 3-field and 4-field state formats ───────
already_merged 101 legacy-landed  || fail "already_merged must match a 3-field row"; pass
already_merged 102 tracked-landed || fail "already_merged must match a 4-field (ref) row"; pass
already_merged 999 nope           && fail "already_merged must not match an absent PR"; pass
# A slug that is a prefix of a landed slug must NOT match (word-boundary guard).
already_merged 101 legacy         && fail "already_merged must not match a slug prefix"; pass

echo "PASS: $PASS checks (console tracker-id labelling — HERD-92)"
