#!/usr/bin/env bash
# test-watcher-settle-threshold.sh — hermetic proof of HERD-548 leg 3: the DUPLICATE-WATCHER COUNT
# excludes pids younger than a settle threshold and re-verifies liveness at RENDER time
# (watcher_singleton_verdict / watcher_list_mains_settled, scripts/herd/watcher-exempt.sh).
#
# GROUNDED 2026-08-05: post-reload, a single `ps` sample briefly saw FOUR argv0-tagged pids — THREE
# already dead (or dying) by the time anything could act on the sample (the "4-mains-3-dead"
# snapshot). watcher_singleton_verdict had no defense against that: one ps call in, one verdict out,
# no persistence, no re-check — unlike `herd status`'s own (separately implemented, slower)
# _status_dup_verified. This suite drives the REAL watcher_singleton_verdict against a SYNTHETIC
# process table (the same $HERD_SWEEP_PS_CMD seam tests/test-watcher-exempt.sh already uses) plus a
# synthetic per-pid age seam ($HERD_SWEEP_PS_ETIME_CMD), asserting:
#
#   (1) a YOUNG non-canonical tagged pid (age < WATCHER_SETTLE_SECS) is excluded from the count: the
#       canonical + one young extra reads OK / count=1, not DUPLICATE
#   (2) the SAME young pid, once it has aged past the threshold, IS counted — a persisting duplicate
#       still alarms, just one tick later
#   (3) the CANONICAL (lockfile) pid is NEVER settle-filtered — a freshly-acquired legitimate watcher
#       reads OK immediately, not NONE, even with age=0
#   (4) RENDER-TIME RE-VERIFY: a settled-age candidate that is no longer actually alive (kill -0
#       fails) is excluded even though the synthetic ps table still lists it
#   (5) a genuine settled + alive duplicate still alarms (the property none of this may break)
#
# Fully synthetic process table — no real ps sample is ever consulted for the pid rows; only kill -0
# on real backgrounded/reaped test processes exercises the render-time re-verify.
# Run:  bash tests/test-watcher-settle-threshold.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

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

export WORKTREES_DIR="$T/trees"; mkdir -p "$WORKTREES_DIR"
export HERD_WATCH_ARGV0="herd-watch-settlews"
export HERD_WATCHER_LOCK="$T/trees/.watcher-settlews.pid"

# shellcheck source=/dev/null
. "$REPO/scripts/herd/watcher-exempt.sh"

for fn in watcher_singleton_verdict watcher_list_mains_settled; do
  declare -f "$fn" >/dev/null 2>&1 || fail "(0) $fn not defined after sourcing"
done
ok
echo "PASS (0) leg-3 helpers load"

# A genuinely LIVE canonical watcher.
sleep 100 & CANON=$!; track "$CANON"
kill -0 "$CANON" 2>/dev/null || fail "setup: canonical pid unexpectedly dead"
printf '%s\n' "$CANON" > "$HERD_WATCHER_LOCK"

# A genuinely LIVE extra tagged pid standing in for "a fork the exemptions could not attribute" —
# real liveness (kill -0 must succeed) so case (4)'s render-time re-verify has something to falsify.
sleep 100 & EXTRA=$!; track "$EXTRA"
kill -0 "$EXTRA" 2>/dev/null || fail "setup: extra pid unexpectedly dead"

_plant_table() {   # writes "pid ppid pgid command" rows to $HERD_SWEEP_PS_CMD's target
  local dst="$1"
  cat > "$dst" <<EOF
#!/usr/bin/env bash
printf '%s 1 %s herd-watch-settlews bash agent-watch.sh\n' "$CANON" "$CANON"
printf '%s 1 %s herd-watch-settlews bash agent-watch.sh\n' "$EXTRA" "$EXTRA"
EOF
  chmod +x "$dst"
}
PSCMD="$T/ps-table.sh"; _plant_table "$PSCMD"
export HERD_SWEEP_PS_CMD="$PSCMD"

# Age stub: $CANON is old (irrelevant — canonical is never settle-filtered), $EXTRA's age is driven
# by $EXTRA_AGE so each case can move it across the settle threshold without re-planting anything.
EXTRA_AGE=0
ETIMECMD="$T/etime.sh"
cat > "$ETIMECMD" <<EOF
#!/usr/bin/env bash
case "\$1" in
  "$CANON") printf '99:99' ;;
  "$EXTRA")  printf '%s' "\$(cat "$T/extra-age" 2>/dev/null || echo 0)" ;;
  *) : ;;
esac
EOF
chmod +x "$ETIMECMD"
export HERD_SWEEP_PS_ETIME_CMD="$ETIMECMD"
set_extra_age() { printf '%s' "$1" > "$T/extra-age"; }

# watcher-exempt.sh already set WATCHER_SETTLE_SECS to its default (2s, from HERD_WATCHER_SETTLE_SECS
# unset at source time above) — the cases below are written against that default explicitly.
[ "$WATCHER_SETTLE_SECS" = "2" ] || fail "setup: expected the default WATCHER_SETTLE_SECS=2 (got $WATCHER_SETTLE_SECS)"

verdict_state() { watcher_singleton_verdict | cut -f1; }
verdict_count() { watcher_singleton_verdict | cut -f4; }

# ── (1) a YOUNG extra pid (age 0, well under the 2s settle threshold) is excluded ──────────────────
set_extra_age "0:00"
st="$(verdict_state)"; ct="$(verdict_count)"
[ "$st" = "OK" ] || fail "(1) a young extra pid must not trip DUPLICATE (got state=$st count=$ct)"
[ "$ct" = "1" ] || fail "(1) count must settle to 1 while the extra pid is young (got $ct)"
ok
echo "PASS (1) a duplicate candidate younger than the settle threshold is excluded from the count"

# ── (2) the SAME pid, once past the threshold, is counted — a persisting duplicate still alarms ────
set_extra_age "0:05"   # 5s > the 2s default settle threshold
st="$(verdict_state)"; ct="$(verdict_count)"
[ "$st" = "DUPLICATE" ] || fail "(2) a SETTLED, still-alive extra pid must trip DUPLICATE (got state=$st count=$ct)"
[ "$ct" = "2" ] || fail "(2) count must include the settled extra pid (got $ct)"
ok
echo "PASS (2) the same pid, once settled, is counted — a persisting duplicate still alarms"

# ── (3) the canonical (lockfile) pid is NEVER settle-filtered, even at age 0 ────────────────────────
# Remove the extra pid from the table entirely; only the canonical (whose synthetic age is 99:99,
# but this asserts the exemption applies regardless — flip its own age stub to 0 too, to prove it).
cat > "$PSCMD" <<EOF
#!/usr/bin/env bash
printf '%s 1 %s herd-watch-settlews bash agent-watch.sh\n' "$CANON" "$CANON"
EOF
chmod +x "$PSCMD"
cat > "$ETIMECMD" <<EOF
#!/usr/bin/env bash
printf '0:00'
EOF
chmod +x "$ETIMECMD"
st="$(verdict_state)"; ct="$(verdict_count)"
[ "$st" = "OK" ] || fail "(3) a fresh (age=0) CANONICAL watcher must read OK immediately (got state=$st count=$ct)"
[ "$ct" = "1" ] || fail "(3) count must be exactly 1 (got $ct)"
ok
echo "PASS (3) the canonical pid is never settle-filtered — reads OK immediately even at age 0"

# ── (4) RENDER-TIME RE-VERIFY: a settled candidate gone by render time is excluded ──────────────────
# A STATEFUL table script (mirrors tests/test-watcher-exempt.sh case (j)): the candidate's row is
# present on call 1 (the scan watcher_singleton_verdict itself takes) but ABSENT from every call
# after — the render-time re-verify deliberately re-fetches the table (_wx_pid_alive) instead of
# reusing the frozen scan sample, so a candidate that "died" in that gap must drop out silently.
DYING=700001
rm -f "$T/ps-dying-calls"
cat > "$PSCMD" <<EOF
#!/usr/bin/env bash
n=0; [ -f "$T/ps-dying-calls" ] && n="\$(cat "$T/ps-dying-calls")"
n=\$(( n + 1 )); printf '%s\n' "\$n" > "$T/ps-dying-calls"
printf '%s 1 %s herd-watch-settlews bash agent-watch.sh\n' "$CANON" "$CANON"
if [ "\$n" -lt 2 ]; then
  printf '%s 1 %s herd-watch-settlews bash agent-watch.sh\n' "$DYING" "$DYING"
fi
EOF
chmod +x "$PSCMD"
cat > "$ETIMECMD" <<EOF
#!/usr/bin/env bash
printf '0:10'
EOF
chmod +x "$ETIMECMD"
st="$(verdict_state)"; ct="$(verdict_count)"
[ "$st" = "OK" ] || fail "(4) a settled candidate gone by render time must be excluded (got state=$st count=$ct)"
[ "$ct" = "1" ] || fail "(4) count must exclude the vanished candidate (got $ct)"
ok
echo "PASS (4) render-time re-verify excludes a settled candidate gone by render time"

# ── (5) a genuine settled + alive duplicate still alarms (the property this may never break) ────────
cat > "$PSCMD" <<EOF
#!/usr/bin/env bash
printf '%s 1 %s herd-watch-settlews bash agent-watch.sh\n' "$CANON" "$CANON"
printf '%s 1 %s herd-watch-settlews bash agent-watch.sh\n' "$EXTRA" "$EXTRA"
EOF
chmod +x "$PSCMD"
cat > "$ETIMECMD" <<EOF
#!/usr/bin/env bash
printf '0:10'
EOF
chmod +x "$ETIMECMD"
kill -0 "$EXTRA" 2>/dev/null || fail "(5) setup: EXTRA pid must still be alive"
st="$(verdict_state)"
[ "$st" = "DUPLICATE" ] || fail "(5) a genuine settled + alive duplicate must still alarm (got state=$st)"
ok
echo "PASS (5) a genuine settled + alive duplicate still alarms"

echo "ALL PASS ($pass checks)"
