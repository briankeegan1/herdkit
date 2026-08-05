#!/usr/bin/env python3
# capacity_flock_run.py — HERD-557 P1: the ATOMIC ACQUIRE-AND-RUN backbone for the suite-capacity
# ledger (scripts/herd/capacity-ledger.sh). Tries an EXCLUSIVE, NON-BLOCKING flock (fcntl.flock,
# portable to both Linux and macOS/BSD) on every given lock file — ALL-OR-NOTHING, so a single-lock
# call is an ordinary "claim one unit" attempt and a multi-lock call (the RETRY-SOLO drain-barrier
# tenant, which passes every unit's lock file) is "claim the whole ledger or nothing".
#
# A flock is tied to this PROCESS's open file descriptor, not to a marker file we have to police —
# the kernel releases it the instant this process exits, crashes, or is killed, with zero reconciler
# / TTL / liveness-scan machinery required for CORRECTNESS. The marker file (--marker) this script
# also writes/removes is OBSERVABILITY ONLY: it lets the shell side render "N live" / "class=watcher"
# without re-deriving it from lock state, and a courtesy best-effort sweep can drop a marker whose pid
# died before its own cleanup ran — but nothing ever GATES on the marker. That split (locks decide,
# markers narrate) is the whole point of this design: see docs/spikes/capacity-admission.md.
#
# Usage:
#   capacity_flock_run.py [--marker FILE] [--class LABEL] LOCKFILE... -- CMD...
#
# Exit codes:
#   75         EX_TEMPFAIL — at least one lock was busy; NOTHING was acquired and CMD never ran. The
#              caller (capacity-ledger.sh) treats this as "try a different slot, or wait and retry".
#   2          usage error (no lock files, or no command after `--`).
#   otherwise  CMD's own exit status (128+signal if CMD died to a signal, the usual shell convention).
import fcntl
import os
import sys
import time

EX_BUSY = 75
EX_USAGE = 2


def main(argv):
    marker = None
    cls = ""
    locks = []
    i = 0
    n = len(argv)
    while i < n:
        a = argv[i]
        if a == "--marker" and i + 1 < n:
            marker = argv[i + 1]
            i += 2
        elif a == "--class" and i + 1 < n:
            cls = argv[i + 1]
            i += 2
        elif a == "--":
            i += 1
            break
        else:
            locks.append(a)
            i += 1
    cmd = argv[i:]
    if not locks or not cmd:
        sys.stderr.write(
            "capacity_flock_run: usage: [--marker FILE] [--class LABEL] LOCKFILE... -- CMD...\n"
        )
        return EX_USAGE

    fds = []
    for lk in locks:
        try:
            fd = os.open(lk, os.O_CREAT | os.O_RDWR, 0o644)
        except OSError:
            for f in fds:
                os.close(f)
            return EX_BUSY
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            os.close(fd)
            for f in fds:
                os.close(f)
            return EX_BUSY
        fds.append(fd)

    if marker:
        try:
            with open(marker, "w") as m:
                m.write("%d\n%s\n%d\n" % (os.getpid(), cls, int(time.time())))
        except OSError:
            pass

    rc = 1
    try:
        import subprocess

        proc = subprocess.Popen(cmd)
        try:
            rc = proc.wait()
        except KeyboardInterrupt:
            proc.wait()
            rc = 130
        if rc < 0:
            rc = 128 - rc  # child died to a signal (negative rc) -> 128+signum, the shell convention
    finally:
        if marker:
            try:
                os.remove(marker)
            except OSError:
                pass
        for f in fds:
            try:
                os.close(f)
            except OSError:
                pass
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
