#!/usr/bin/env bash
# test-quick-tab-register.sh — the quick lane registers its builder tab in the .herd-tabs sweep
# allowlist, exactly like the feature lane (HERD-160 quick win).
#
# THE BUG: herd-feature.sh appends a `<slug> <tab> builder` row to $WORKTREES_DIR/.herd-tabs so the
# tab-leak-guard's registration whitelist knows the tab is engine-created (HERD-93). herd-quick.sh
# created its tab but NEVER registered it — so a quick-lane builder's own tab was not on the allowlist
# and could false-red the leak-guard the same way the pre-HERD-93 feature tabs did.
#
# THE FIX: herd-quick.sh appends the SAME row after a successful tab create. This test proves (1) the
# registration row the lanes write parses cleanly under the whitelist reader's split, and (2) BOTH
# lanes contain the .herd-tabs registration in their tab-creation block.
#
# Hermetic: drives the registration snippet against a temp file + static source assertions. No herdr.
# Run:  bash tests/test-quick-tab-register.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
QUICK="$ROOT/scripts/herd/herd-quick.sh"
FEATURE="$ROOT/scripts/herd/herd-feature.sh"
GREP=/usr/bin/grep; command -v "$GREP" >/dev/null 2>&1 || GREP=grep

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { PASS=$((PASS+1)); }

[ -f "$QUICK" ]   || fail "herd-quick.sh not found at $QUICK"
[ -f "$FEATURE" ] || fail "herd-feature.sh not found at $FEATURE"

# ── 1. the registration row the lanes write parses under the whitelist reader ─────────────────────
# The tab-leak-guard / teardown read .herd-tabs with `line.split(" ", 2)` → (slug, tab, role). Drive
# the exact printf the lanes use and assert the resulting row parses back to the slug + role.
WORKTREES_DIR="$T"; SLUG="my-slug"; TAB="tab_0007"
printf '%s %s builder\n' "$SLUG" "$TAB" >> "$WORKTREES_DIR/.herd-tabs"
[ -f "$T/.herd-tabs" ] || fail "(1) registration did not create the .herd-tabs file"
row="$(cat "$T/.herd-tabs")"
[ "$row" = "my-slug tab_0007 builder" ] || fail "(1) registration row malformed: '$row'"
parsed="$(SLUG="$SLUG" python3 - "$T/.herd-tabs" <<'PY'
import os, sys
want = os.environ["SLUG"]
with open(sys.argv[1]) as f:
    for line in f:
        parts = line.strip().split(" ", 2)
        if len(parts) == 3 and parts[0] == want and parts[2] == "builder":
            print("ok"); break
PY
)"
[ "$parsed" = "ok" ] || fail "(1) whitelist reader did not recognize the registered builder row"
pass

# ── 2. the FEATURE lane registers (the oracle) ────────────────────────────────────────────────────
"$GREP" -qE 'printf .*builder.*>>[[:space:]]*"?\$\{?WORKTREES_DIR\}?/\.herd-tabs' "$FEATURE" \
  || fail "(2) herd-feature.sh no longer registers its tab in .herd-tabs — the mirror oracle changed"
pass

# ── 3. the QUICK lane registers too (the fix) ─────────────────────────────────────────────────────
"$GREP" -qE 'printf .*builder.*>>[[:space:]]*"?\$\{?WORKTREES_DIR\}?/\.herd-tabs' "$QUICK" \
  || fail "(3) herd-quick.sh does not register its builder tab in .herd-tabs (mirror herd-feature.sh)"
pass

# ── 4. the quick-lane registration sits inside the non-headless tab-creation block ────────────────
# It must be gated by the same `$_HERD_DRIVER_NAME != headless` block that owns the tab create — a
# headless lane has no tab to register. Assert the registration line appears AFTER the tab-create guard.
awk '
  /_HERD_DRIVER_NAME.*!=.*headless/ { in_block=1 }
  in_block && /\.herd-tabs/ { found=1 }
  END { exit found ? 0 : 1 }
' "$QUICK" || fail "(4) the .herd-tabs registration is not inside herd-quick.sh's non-headless tab block"
pass

echo "ALL PASS ($PASS checks)"
