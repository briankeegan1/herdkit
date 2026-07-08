#!/usr/bin/env bash
# test-init-merge-policy-ask.sh — hermetic tests for HERD-140: `herd init` must NEVER silently seed
# MERGE_POLICY=auto. The merge-policy choice is a consequence-loud interview step in cmd_init.
#
# Asserts:
#   (1) NON-INTERACTIVE init on the detection-skip path (no gh) → the consequence block is printed
#       (what auto/approve/observe DO), a LOUD notice announces the auto default (not a single dim
#       line), and MERGE_POLICY=auto is seeded — the script never hangs.
#   (2) NON-INTERACTIVE init where GitHub detection derives approve (protected + required review) →
#       the seeded value is announced as approve and the "auto merges with NO human sign-off" loud
#       warning is NOT emitted (the warning is specific to an auto default, not boilerplate).
#   (3) INTERACTIVE (pty) → the MERGE_POLICY prompt renders live with its auto|approve|observe text
#       and the operator's answer is what lands; skipped cleanly if a pty can't be allocated.
#
# A FAKE `gh` returns scripted JSON — NO network, NO real gh/GitHub is ever contacted.
# No `set -e`: several checks assert degradation explicitly.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
HERD="$REPO/bin/herd"
export HERD

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }
plain() { printf '%s' "$1" | sed $'s/\x1b\\[[0-9;]*m//g'; }   # strip ANSI so greps match plain text

command -v python3 >/dev/null 2>&1 || fail "python3 required to run this test"
command -v git     >/dev/null 2>&1 || fail "git required to run this test"
REAL_PY="$(command -v python3)"

mkproj() { # <dir> [origin-url]
  local d="$1" origin="${2:-}"
  rm -rf "$d"; mkdir -p "$d"
  git -C "$d" init -q
  git -C "$d" config user.email t@t.t; git -C "$d" config user.name t
  git -C "$d" commit -q --allow-empty -m init
  git -C "$d" branch -M main
  [ -n "$origin" ] && git -C "$d" remote add origin "$origin"
  return 0
}

# ── (1) NON-INTERACTIVE, detection skipped (no gh) → consequence block + LOUD auto notice + seed ──
# SAFE PATH excludes gh (so detection skips → auto default), but keeps python3's dir for bin/herd.
SAFE="/usr/bin:/bin:/usr/sbin:/sbin"
case ":$SAFE:" in *":$(dirname "$REAL_PY"):"*) ;; *) SAFE="$(dirname "$REAL_PY"):$SAFE" ;; esac
proj="$T/skip"; mkproj "$proj" "git@github.com:acme/widgets.git"
if PATH="$SAFE" command -v gh >/dev/null 2>&1; then
  echo "SKIP (1): a real gh is on the SAFE PATH; cannot assert the no-gh auto-default branch" >&2
  ok
else
  out="$(cd "$proj" && PATH="$SAFE" HERD_NONINTERACTIVE=1 HERD_SKIP_DOCTOR=1 bash "$HERD" init 2>&1)"; RC=$?
  [ "$RC" -eq 0 ] || fail "(1) init must not hang/hard-fail non-interactively (rc=$RC): $out"
  pout="$(plain "$out")"
  # consequence block — the operator SEES what each value does, verbatim in the flow.
  echo "$pout" | grep -qi "watcher MERGES every gate-passed PR"    || fail "(1) auto consequence not shown: $out"
  echo "$pout" | grep -qi "HOLDS each PR for an explicit human"    || fail "(1) approve consequence not shown: $out"
  echo "$pout" | grep -qi "NEVER merges"                          || fail "(1) observe consequence not shown: $out"
  # LOUD notice (not a single dim line) that we defaulted to auto without a human choosing it.
  echo "$pout" | grep -qi "MERGE_POLICY defaulted to 'auto'"      || fail "(1) loud auto-default notice missing: $out"
  echo "$pout" | grep -qi "NO human sign-off"                     || fail "(1) auto notice must spell out the consequence: $out"
  grep -qE '^MERGE_POLICY="auto"$' "$proj/.herd/config"           || fail "(1) config should seed MERGE_POLICY=auto: $(cat "$proj/.herd/config")"
  ok
fi

# ── (2) NON-INTERACTIVE, detection derives approve → announced approve, NO false auto warning ─────
STUB="$T/stub"; mkdir -p "$STUB"
cat > "$STUB/gh" <<'STUB_EOF'
#!/usr/bin/env bash
case "$1" in
  auth) exit 0 ;;
  api)
    case "$2" in
      repos/acme/widgets)
        printf '{"default_branch":"main","allow_merge_commit":true,"allow_squash_merge":true,"allow_rebase_merge":true}\n' ;;
      repos/acme/widgets/branches/main/protection)
        printf '{"required_pull_request_reviews":{"required_approving_review_count":2},"required_status_checks":{"contexts":["ci"]}}\n' ;;
      *) echo '{"message":"Not Found"}' >&2; exit 1 ;;
    esac ;;
  *) exit 1 ;;
esac
STUB_EOF
chmod +x "$STUB/gh"
proj="$T/approve"; mkproj "$proj" "git@github.com:acme/widgets.git"
out="$(cd "$proj" && PATH="$STUB:$PATH" HERD_NONINTERACTIVE=1 HERD_SKIP_DOCTOR=1 bash "$HERD" init 2>&1)"; RC=$?
[ "$RC" -eq 0 ] || fail "(2) init should succeed with approve detection (rc=$RC): $out"
pout="$(plain "$out")"
echo "$pout" | grep -qi "MERGE_POLICY=approve"                        || fail "(2) approve seeded value not announced: $out"
echo "$pout" | grep -qi "MERGE_POLICY defaulted to 'auto'"           && fail "(2) must NOT warn about auto when default is approve: $out"
grep -qE '^MERGE_POLICY="approve"$' "$proj/.herd/config"             || fail "(2) config should seed MERGE_POLICY=approve: $(cat "$proj/.herd/config")"
ok

# ── (3) INTERACTIVE (pty): the MERGE_POLICY prompt renders live and the answer lands ──────────────
# Driven through a real pty (python's pty.fork), so ask()'s `[ -t 0 ]` branch runs. The prompt goes
# to the pty (captured); ask's return is redirected to a file so we can read the chosen value back.
# Guarded: if a pty can't be allocated (locked-down CI), SKIP rather than fail.
ANSF="$T/ans"; : > "$ANSF"
ptyout="$(PTY_FEED='approve
' PTY_ANSFILE="$ANSF" HERD="$HERD" "$REAL_PY" - <<'PY' 2>/dev/null || true
import os, pty, select, sys
herd, ansf, feed = os.environ["HERD"], os.environ["PTY_ANSFILE"], os.environ["PTY_FEED"]
# child: source bin/herd (no-op dispatch), render the exact cmd_init prompt via ask(), value → file
script = '. %r help >/dev/null 2>&1; ask "MERGE_POLICY (auto | approve | observe)" auto > %r' % (herd, ansf)
try:
    pid, fd = pty.fork()
except OSError:
    sys.exit(7)                      # no pty available → signal SKIP
if pid == 0:
    os.execvp("bash", ["bash", "-c", script])
os.write(fd, feed.encode())
buf = b""
while True:
    try: r, _, _ = select.select([fd], [], [], 5)
    except OSError: break
    if not r: break
    try: chunk = os.read(fd, 4096)
    except OSError: break
    if not chunk: break
    buf += chunk
os.waitpid(pid, 0)
sys.stdout.write(buf.decode(errors="replace"))
PY
)"
PTY_RC=$?
if [ "$PTY_RC" = "7" ] || [ -z "$ptyout" ]; then
  echo "SKIP (3): no pty available in this environment" >&2
  ok
else
  pptyout="$(plain "$ptyout" | tr -d '\r')"
  echo "$pptyout" | grep -qi "MERGE_POLICY (auto | approve | observe)" || fail "(3) interactive prompt did not render: $ptyout"
  [ "$(plain "$(cat "$ANSF")" | tr -d '\r\n ')" = "approve" ]          || fail "(3) operator answer not honored: got [$(cat "$ANSF")]"
  ok
fi

echo "ALL PASS ($pass checks)"
