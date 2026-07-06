#!/usr/bin/env bash
# test-backlog-view-refresh-key.sh — hermetic, network-free test of the manual-refresh key (HERD-48).
#
# backlog-view.sh's poll loop now waits via poll_wait, which lets the coordinator's backlog pane force
# an immediate refetch+repaint when the user presses r/R instead of waiting out the poll interval. Two
# behaviours need proving, and both are driven from a small python harness (deterministic on every
# runner — no backgrounding, no watchdog, no timing races):
#
#   A. no-tty fallback — with NO controlling tty (the child is spawned in its own session), poll_wait
#      must degrade to a plain sleep: the loop still renders and TERMINATES at MAX_POLLS, never blocks
#      on a tty read, and the 'r = refresh' footer hint is OMITTED (byte-identical to pre-HERD-48).
#   B. keypress refresh — under a REAL pty (so /dev/tty resolves to the pty), pressing 'r' forces a
#      SECOND repaint of BYTE-FOR-BYTE UNCHANGED backlog content. That can ONLY happen if the key
#      cleared last_hash (unchanged content is otherwise latched by the content hash → no repaint), so
#      a second rendered header is unambiguous proof the key fired. The footer hint IS shown here.
#
# Fails SOFT: if python3, os.forkpty, or new-session spawning is unavailable, the affected scenario
# SKIPS (never a false red).
#
# Run:  bash tests/test-backlog-view-refresh-key.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../scripts/herd/backlog-view.sh"
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 unavailable"; exit 0; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
BIN="$T/bin"; mkdir -p "$BIN"; LOG="$T/herd.log"

# FAKE `herd` — emits a FIXED backlog list, so content never changes between polls (the whole point of
# scenario B: a repaint of unchanged content can only come from the key clearing last_hash).
cat > "$BIN/herd" <<'FAKE'
#!/usr/bin/env bash
echo "herd $*" >> "$HERD_FAKE_LOG"
[ "${1:-}" = "backlog" ] || exit 0
printf '%s\n' "${HERD_FAKE_OUT:-}"
FAKE
chmod +x "$BIN/herd"

mkdir -p "$T/p/.herd"
cat > "$T/p/.herd/config" <<EOF
PROJECT_ROOT="$T/p"
WORKSPACE_NAME="testws"
BACKLOG_FILE="BACKLOG.md"
SCRIBE_BACKEND="linear"
EOF
: > "$LOG"

# The python harness — written to a temp file (avoids heredoc-inside-\$() quoting hazards) and run.
cat > "$T/drive.py" <<'PY'
import os, sys, time, select, subprocess

SCRIPT = os.environ["SCRIPT"]
MARK   = b"live \xc2\xb7"   # the header printf's 'live \xc2\xb7' marker — exactly one per repaint

def base_env(poll, maxp):
    return {
        "HOME": os.environ["HOME"],
        "PATH": os.environ["BIN"] + ":/usr/bin:/bin:/usr/sbin:/sbin",
        "TERM": "xterm",
        "HERD_CONFIG_FILE": os.environ["CFG"],
        "HERD_ALLOW_FOREIGN_CWD": "1",
        "HERD_FAKE_LOG": os.environ["LOG"],
        "HERD_FAKE_OUT": "#R-1 refresh-item",
        "BACKLOG_VIEW_MAX_POLLS": maxp,
        "BACKLOG_VIEW_POLL_SECS": poll,
    }

def scenario_no_tty():
    # No controlling tty (start_new_session=os.setsid) → poll_wait must take the plain-sleep fallback.
    env = base_env(poll="1", maxp="2")
    try:
        p = subprocess.Popen(["bash", SCRIPT], env=env, stdin=subprocess.DEVNULL,
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                             start_new_session=True)
    except OSError as e:
        return ("no-tty", None, "spawn unavailable: %s" % e)
    try:
        out, _ = p.communicate(timeout=25)
    except subprocess.TimeoutExpired:
        p.kill(); p.communicate()
        return ("no-tty", False, "loop did not terminate — poll_wait blocked with no tty")
    if p.returncode != 0:
        return ("no-tty", False, "non-zero exit %d in the no-tty fallback" % p.returncode)
    if b"refresh-item" not in out:
        return ("no-tty", False, "list never rendered in the no-tty fallback")
    if b"r = refresh" in out:
        return ("no-tty", False, "footer hint shown though there is no interactive tty")
    return ("no-tty", True, "clean exit, rendered, no footer")

def scenario_keypress():
    try:
        pid, fd = os.forkpty()
    except (OSError, AttributeError) as e:
        return ("keypress", None, "forkpty unavailable: %s" % e)
    if pid == 0:
        env = base_env(poll="5", maxp="2")   # long poll: unchanged content would NOT repaint on its own
        try:
            os.execve("/bin/bash", ["bash", SCRIPT], env)
        finally:
            os._exit(127)

    buf = b""; deadline = time.time() + 20; sent = False
    while time.time() < deadline:
        try:
            r, _, _ = select.select([fd], [], [], 0.3)
        except (OSError, ValueError):
            break
        if not r:
            continue
        try:
            chunk = os.read(fd, 4096)
        except OSError:
            break            # EIO on the master == slave closed (child exited)
        if not chunk:
            break            # EOF
        buf += chunk
        if not sent and buf.count(MARK) >= 1:
            time.sleep(0.2)
            try:
                os.write(fd, b"r")
            except OSError:
                pass
            sent = True
    try:
        os.waitpid(pid, 0)
    except OSError:
        pass

    heads = buf.count(MARK)
    if not sent:
        return ("keypress", False, "harness never saw the first render to press 'r' on")
    if b"refresh-item" not in buf:
        return ("keypress", False, "list never rendered under the pty")
    if b"r = refresh" not in buf:
        return ("keypress", False, "footer hint missing on the interactive tty")
    if heads < 2:
        return ("keypress", False, "'r' did not repaint unchanged content (rendered headers=%d)" % heads)
    return ("keypress", True, "'r' forced a repaint of unchanged content (headers=%d)" % heads)

ok = True
for name, passed, msg in (scenario_no_tty(), scenario_keypress()):
    if passed is None:
        sys.stdout.write("SKIP[%s]: %s\n" % (name, msg))
    elif passed:
        sys.stdout.write("PASS[%s]: %s\n" % (name, msg))
    else:
        sys.stdout.write("FAIL[%s]: %s\n" % (name, msg)); ok = False
sys.exit(0 if ok else 1)
PY

out="$(SCRIPT="$SCRIPT" BIN="$BIN" CFG="$T/p/.herd/config" LOG="$LOG" HOME="$HOME" python3 "$T/drive.py")"; rc=$?
printf '%s\n' "$out"
[ "$rc" -eq 0 ] || { echo "FAIL: refresh-key harness reported a failure (see above)"; exit 1; }
echo "ALL PASS (refresh-key: no-tty fallback + live keypress refresh)"
