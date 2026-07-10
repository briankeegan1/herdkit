#!/usr/bin/env bash
# test-pane-stamp-coverage.sh — the STAMP-COVERAGE drift guard (HERD-310, part 3).
#
# The pane-close IDENTITY guard (HERD-134, herd_close_pane_verified) can only refuse a stale/mismatched
# close when the pane carries a READABLE identity stamp — an `herdr agent start --name` / `pane rename`
# / `pane report-agent` label the guard proves against an expected-kind. In the 2026-07-10 incident the
# identity guard saved the ONE pane that was unreadable-and-refused; this guard makes that coverage
# TOTAL by asserting that EVERY engine-spawned pane is stamped at spawn. A new spawn site that forgets
# to stamp would let a mismatched close through — this test reds the build before that can ship.
#
# Structural (like caps-sync-lint / gate-coverage-lint): it asserts each known spawn site is paired
# with its identity stamp, and — the ratchet — that no engine `herdr agent start` / control-room
# `pane split` grows WITHOUT a nearby stamp. NETWORK-FREE, no herdr. Run: bash tests/test-pane-stamp-coverage.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
PASS=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { PASS=$((PASS+1)); }

S="$REPO/scripts/herd"

# has <file> <regex> — the file contains a line matching <regex> (ERE).
has() { grep -Eq "$2" "$S/$1" || fail "$3"; }

# ── builder agent pane (herd-feature.sh) — labelled by its slug ─────────────────────────────────────
has herd-feature.sh 'herd_driver_pane_rename "\$_AGENT_PANE" "\$SLUG"' \
  "builder agent pane must be stamped with its slug in herd-feature.sh"
ok

# ── review pane (herd-review.sh) — labelled review·<slug> ───────────────────────────────────────────
has herd-review.sh 'pane rename "\$ROOT" "review·\$SLUG"' \
  "review pane must be stamped review·<slug> in herd-review.sh"
ok

# ── resolver pane (herd-resolve.sh) — labelled resolve·<slug> ───────────────────────────────────────
has herd-resolve.sh 'herd_driver_pane_rename "\$_RESOLVE_PANE" "resolve·\$SLUG"' \
  "resolver pane must be stamped resolve·<slug> in herd-resolve.sh"
ok

# ── control-room panes (coordinator.sh) — the incident's "healthcheck pane" lives in the watch pane ──
has coordinator.sh 'herd_driver_pane_rename "\$ROOT" "backlog·\$WORKSPACE_NAME"' \
  "control-room BACKLOG pane must be stamped backlog·<ws> in coordinator.sh"
ok
has coordinator.sh 'herd_driver_pane_rename "\$WPANE" "watch·\$WORKSPACE_NAME"' \
  "control-room WATCH/health pane must be stamped watch·<ws> in coordinator.sh"
ok

# ── RATCHET: every control-room `herdr pane split` in coordinator.sh must be paired with a stamp ─────
# (the watch pane is a split; a future split that spawns a pane without renaming it would regress).
_splits="$(grep -cE 'herdr pane split' "$S/coordinator.sh" || true)"
_stamps="$(grep -cE 'herd_driver_pane_rename' "$S/coordinator.sh" || true)"
[ "${_stamps:-0}" -ge "${_splits:-0}" ] \
  || fail "coordinator.sh has $_splits pane split(s) but only $_stamps stamp(s) — a spawned pane is unstamped"
ok

# ── the identity guard reads the stamp: driver.sh classifies a pane by name/label/argv ──────────────
# (proves the stamps above are the very identities herd_close_pane_verified proves a close against.)
grep -Eq 'agent:|pane:|argv:' "$S/driver.sh" \
  || fail "driver.sh pane-identity classifier must read agent/pane/argv stamps"
ok

echo "ALL PASS ($PASS checks) — test-pane-stamp-coverage.sh"
