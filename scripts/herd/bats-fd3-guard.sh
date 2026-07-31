#!/usr/bin/env bash
# bats-fd3-guard.sh — HERD-462: the shared-chokepoint half of the bats-FD3 wedge fix.
#
# ROOT CAUSE (grounded live, HERD-462): bats-core dup's a live pipe onto an internal fd (fd 3;
# a higher dup, fd 12, was also observed on bats 1.14.0) before running each test, so it can stream
# the "ok N …" TAP line back to its own aggregator. A test that backgrounds a child WITHOUT closing
# that fd inherits it by default and, once the test itself has already reported "ok", keeps the WRITE
# end open indefinitely — bats' aggregator then blocks on a read() that will never see EOF, wedging
# the entire `bats` run behind that ONE leaked child, well after every test's own result is already
# known (reproduced live: an unguarded background `sleep` hangs `bats` even though every test prints
# "ok"; see tests/test-cli-reload.sh's own `_bg_close_fds` for the test-authoring half of this fix —
# THE fix for a KNOWN leaky test). This file is the OTHER half: even with every known test disciplined,
# "a future leaky test is inevitable" (a contributor forgets the fd-close convention), and ONE such
# test must never wedge the WHOLE local gate behind the existing ${HEALTHCHECK_SUITE_TIMEOUT:-1800}s
# backstop alone — that bound is sized for a legitimately slow full suite, not for noticing a wedge
# that, from the test suite's own perspective, already finished.
#
# scripts/ci/run-suite.sh sidesteps the whole failure class by never invoking bats at all (each test
# runs directly, `timeout N bash test.sh > logfile`, so nothing ever blocks on a live pipe — a leaked
# child just writes to a plain file nobody blockingly reads). healthcheck.project.sh's LOCAL gate still
# wants bats when it is present (dynamic ~350-test discovery, TAP aggregation), so this applies run-
# suite.sh's SAME principle — trust an observable plain FILE, never block on a pipe a leaked child can
# hold open — as an ACTIVE watchdog instead of a passive redirect: passive redirection of bats' own
# stdout/stderr to a file (already done by the caller) does NOT help here, because the leak lives one
# layer deeper, inside bats' own internal fd, unrelated to what the caller's redirect can see.
#
# herd_bats_early_reap OUTFILE WRAPPER_PID [GRACE_SECS]
#   Call AFTER backgrounding the caller's OWN `timeout … bats … >OUTFILE 2>&1 &` invocation, passing
#   OUTFILE (the growing combined stdout/stderr bats is writing to) and WRAPPER_PID (`$!` of that
#   background job — MUST be the `timeout` wrapper's pid, never a raw `bats` pid: `timeout` relays a
#   signal sent to itself on to its whole child process group, which is what safely tears down a
#   leaked descendant too — a plain `kill` of a bare `bats` pid would not reach one).
#
#   Polls OUTFILE for bats' own TAP plan line (`1..N`) plus N "ok"/"not ok" result lines. Once every
#   planned test has reported, gives WRAPPER_PID GRACE_SECS (default 15) to exit on its own — the
#   overwhelmingly common, non-wedged case, where bats' aggregator simply hasn't flushed yet — before
#   concluding it is wedged and killing it (SIGTERM, then SIGKILL after a further 5s grace). No plan
#   line ever appearing is NOT treated as a wedge (bats crashing before printing one is a different
#   failure shape entirely) — this function just returns once WRAPPER_PID exits by any means; the
#   caller's own outer `timeout` stays the backstop for that shape, unchanged.
#
#   Prints `reaped-wedged` (nothing otherwise) and always returns 0 — the caller reads WRAPPER_PID's
#   real exit status via its own subsequent `wait`, and additionally checks this function's stdout for
#   the `reaped-wedged` marker to distinguish "bats finished (whatever its exit code)" from "we killed
#   it before it would ever have finished on its own".
herd_bats_early_reap() {
  local _hbr_out="$1" _hbr_pid="$2" _hbr_grace="${3:-15}"
  local _hbr_want="" _hbr_have _hbr_waited

  while kill -0 "$_hbr_pid" 2>/dev/null; do
    sleep 1
    if [ -z "$_hbr_want" ]; then
      _hbr_want="$(grep -m1 -E '^1\.\.[0-9]+[[:space:]]*$' "$_hbr_out" 2>/dev/null \
        | sed -E 's/^1\.\.([0-9]+).*/\1/')"
      [ -n "$_hbr_want" ] || continue
    fi
    _hbr_have="$(grep -cE '^(ok|not ok) ' "$_hbr_out" 2>/dev/null || true)"
    [ -n "$_hbr_have" ] || _hbr_have=0
    [ "$_hbr_have" -ge "$_hbr_want" ] 2>/dev/null || continue

    # Every planned test has already reported — give the wrapper a short window to exit on its own
    # before treating it as wedged.
    _hbr_waited=0
    while kill -0 "$_hbr_pid" 2>/dev/null && [ "$_hbr_waited" -lt "$_hbr_grace" ]; do
      sleep 1; _hbr_waited=$((_hbr_waited + 1))
    done
    if kill -0 "$_hbr_pid" 2>/dev/null; then
      kill -TERM "$_hbr_pid" 2>/dev/null || true
      sleep 5
      kill -KILL "$_hbr_pid" 2>/dev/null || true
      echo "reaped-wedged"
    fi
    return 0
  done
  return 0
}
