#!/usr/bin/env bash
# test-doctor-protocol-advice.sh — hermetic test of the herdr client/server PROTOCOL MISMATCH advice
# (HERD-521, scripts/herd/herd-preflight.sh).
#
# The field failure: a herdr CLI and a running herdr server on different protocol revisions (real
# case: server 0.7.5 / protocol 17 vs CLI 0.8.0 / protocol 19) make the server reject EVERY socket
# command, so every lane and the coordinator die — and the pre-HERD-521 diagnostic only said "your
# herdr looks broken … upgrade/repair herdr", with no mention of the two versions, of restarting the
# server, or of the Homebrew handoff caveat.
#
# Asserted here, against FAKE `herdr` stubs on PATH (no real herdr, no server, no network):
#   (1) modern stub (rejects + `status --json` names both sides) → advice names BOTH versions, both
#       protocols, the server restart, the matching-client download, and the Homebrew caveat
#   (2) same, rendered by `herd_doctor` (its own ⚠ row, not the generic "upgrade/repair" line)
#   (3) legacy stub with NO `status --json` → advice still renders from the rejection text alone,
#       and leads with UPGRADE-THE-CLIENT when the client is the older side
#   (4) error-envelope-on-stdout (exit 0, {"error":{"code":"protocol_mismatch"}}) → advice too
#   (5) FAIL-SOFT: an opaque failure / an ordinary shape skew / a healthy herdr all render
#       BYTE-IDENTICAL to the pre-HERD-521 text (asserted against the literal expected blocks)
#
# Run:  bash tests/test-doctor-protocol-advice.sh
# No `set -e`: several checks deliberately run the guard expecting a non-zero exit; we assert on the
# captured RC explicitly via fail() instead.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PREFLIGHT="$HERE/../scripts/herd/herd-preflight.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ pass=$((pass+1)); }
has(){ grep -qF -- "$2" <<<"$1" || fail "$3 (missing: $2)"; }
hasnt(){ grep -qF -- "$2" <<<"$1" && fail "$3 (unexpectedly present: $2)"; return 0; }

[ -f "$PREFLIGHT" ] || fail "preflight helper not found at $PREFLIGHT"

# Standard system bin dirs: give the stubbed runs bash/env/python3/grep WITHOUT pulling in a
# (typically brew-installed) real herdr.
SYS="/usr/bin:/bin:/usr/sbin:/sbin"
command -v python3 >/dev/null 2>&1 || fail "python3 required to run this test"
case ":$SYS:" in *":$(dirname "$(command -v python3)"):"*) ;; *) SYS="$(dirname "$(command -v python3)"):$SYS";; esac

# mkstub <name> — read a stub body from STDIN into $T/<name>/herdr (executable). The body arrives
# over stdin rather than as an argument so the JSON inside needs no re-quoting; each caller then uses
# "$T/<name>" as the bindir to prepend to PATH.
mkstub() {
  local bindir="$T/$1"; mkdir -p "$bindir"
  cat > "$bindir/herdr"
  chmod +x "$bindir/herdr"
}

# run_fn <fn> <PATH-to-use> [env assignments...] — source the preflight helper in a clean bash and
# run <fn>, printing its COMBINED output and returning its exit code (captured by the caller as $?).
# HERD_BRAND is pinned so the byte-identical assertions below cannot drift with the ambient
# WORKSPACE_NAME of whatever workspace runs the suite.
run_fn() {
  local fn="$1" usepath="$2"; shift 2
  PATH="$usepath" env HERD_BRAND=testbrand "$@" bash -c '. "$0"; '"$fn"' 2>&1' "$PREFLIGHT"
}

# ── the stubs ────────────────────────────────────────────────────────────────
# (A) MODERN mismatch: `tab list` rejected on stderr + a `status --json` that names both sides.
#     This is the real 0.7.5-server / 0.8.0-client case.
mkstub modern <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "tab list")
    echo "error: client protocol 19 is newer than server protocol 17; restart the Herdr server before using this command." >&2
    exit 1 ;;
esac
case "$1" in
  --version) echo "herdr 0.8.0"; exit 0 ;;
  status)    echo '{"client":{"version":"0.8.0","channel":"stable","protocol":19},"server":{"status":"running","running":true,"version":"0.7.5","protocol":17,"compatible":false,"restart_needed":true}}'; exit 0 ;;
esac
echo "{}"
STUB
modern="$T/modern"

# (B) LEGACY mismatch: an older herdr with NO `status` subcommand — the rejection text is the ONLY
#     source, and here the CLIENT is the older side.
mkstub legacy <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "tab list")
    echo "error: client protocol 17 is older than server protocol 19; upgrade the Herdr client before using this command." >&2
    exit 1 ;;
esac
case "$1" in
  --version) echo "herdr 0.7.5"; exit 0 ;;
  status)    echo "error: unrecognized subcommand 'status'" >&2; exit 2 ;;
esac
echo "{}"
STUB
legacy="$T/legacy"

# (C) ENVELOPE mismatch: exits 0 but returns an error envelope instead of result.tabs — lands in the
#     shape-skew branch, not the non-zero branch.
mkstub envelope <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "tab list") echo '{"id":"cli:tab:list","error":{"code":"protocol_mismatch","message":"client protocol 19 is newer than server protocol 17"}}'; exit 0 ;;
esac
case "$1" in
  --version) echo "herdr 0.8.0"; exit 0 ;;
  status)    echo '{"client":{"version":"0.8.0","protocol":19},"server":{"status":"running","running":true,"version":"0.7.5","protocol":17,"compatible":false}}'; exit 0 ;;
esac
echo "{}"
STUB
envelope="$T/envelope"

# (D) OPAQUE failure: broken herdr, nothing to parse, and no server running.
mkstub opaque <<'STUB'
#!/usr/bin/env bash
case "$1" in
  --version) echo "herdr 0.8.0"; exit 0 ;;
  status)    echo '{"client":{"version":"0.8.0","protocol":19},"server":{"status":"not running","running":false}}'; exit 0 ;;
esac
exit 3
STUB
opaque="$T/opaque"

# (E) ORDINARY shape skew: healthy handshake, wrong envelope — must stay the old skew message.
mkstub skew <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "tab list") echo '{"id":1,"result":{"panes":[]}}' ;;
  *) echo "{}" ;;
esac
STUB
skew="$T/skew"

# (F) HEALTHY: the byte-identical-silence baseline.
mkstub healthy <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "tab list") echo '{"id":1,"result":{"tabs":[],"type":"x"}}' ;;
  *) echo "{}" ;;
esac
STUB
healthy="$T/healthy"

# ── (1) modern mismatch → the full remediation block ─────────────────────────
out="$(run_fn herd_preflight "$modern:$SYS")"; RC=$?
[ "$RC" -ne 0 ] || fail "(1) a protocol mismatch must still FAIL the preflight (got 0)"
has "$out" "PROTOCOL MISMATCH"                    "(1) no mismatch header"
has "$out" "0.8.0"                                "(1) client version not named"
has "$out" "0.7.5"                                "(1) server version not named"
has "$out" "protocol 19"                          "(1) client protocol not named"
has "$out" "protocol 17"                          "(1) server protocol not named"
has "$out" "herdr server stop"                    "(1) no restart-the-server remediation"
has "$out" "https://herdr.dev"                    "(1) no matching-client download path"
has "$out" "brew upgrade herdr"                   "(1) no Homebrew upgrade command"
has "$out" "handoff"                              "(1) no Homebrew handoff caveat"
has "$out" "HERD_SKIP_PREFLIGHT=1"                "(1) lost the bypass hint"
hasnt "$out" "Fix: upgrade/repair herdr, then retry."  "(1) still emitting the old generic fix line"
ok

# The client is the NEWER side here, so restarting the server must lead.
grep -qE '^ +1\. Restart the SERVER' <<<"$out" || fail "(1) client-newer should lead with the server restart ($out)"
ok

# ── (2) the doctor renders the same finding in its own style ─────────────────
out="$(run_fn herd_doctor "$modern:$SYS" HERD_DOCTOR_OS=darwin HERD_DOCTOR_CLAUDE_TIMEOUT=1)"
has "$out" "herdr client/server PROTOCOL MISMATCH" "(2) doctor did not render the mismatch row"
has "$out" "0.8.0"                                 "(2) doctor did not name the client version"
has "$out" "0.7.5"                                 "(2) doctor did not name the server version"
has "$out" "herdr server stop"                     "(2) doctor dropped the restart remediation"
has "$out" "https://herdr.dev"                     "(2) doctor dropped the download path"
has "$out" "brew upgrade herdr"                    "(2) doctor dropped the Homebrew caveat"
hasnt "$out" "upgrade/repair herdr to a version"   "(2) doctor still emitting the generic contract line"
ok

# ── (3) legacy herdr (no `status --json`) → advice from the rejection text ────
out="$(run_fn herd_preflight "$legacy:$SYS")"; RC=$?
[ "$RC" -ne 0 ] || fail "(3) legacy mismatch must still FAIL the preflight (got 0)"
has "$out" "PROTOCOL MISMATCH"  "(3) no mismatch header without status --json"
has "$out" "0.7.5"              "(3) client version (from herdr --version) not named"
has "$out" "protocol 17"        "(3) client protocol not named"
has "$out" "protocol 19"        "(3) server protocol not named"
has "$out" "https://herdr.dev"  "(3) no matching-client download path"
has "$out" "herdr server stop"  "(3) no restart-the-server remediation"
ok
# The client is the OLDER side here, so matching the client must lead instead.
grep -qE '^ +1\. Run a herdr CLIENT that matches' <<<"$out" || fail "(3) client-older should lead with the client upgrade ($out)"
ok

# ── (4) error envelope on stdout (exit 0) → advice, not the generic shape skew ─
out="$(run_fn herd_preflight "$envelope:$SYS")"; RC=$?
[ "$RC" -ne 0 ] || fail "(4) an error-envelope response must FAIL the preflight (got 0)"
has "$out" "PROTOCOL MISMATCH" "(4) envelope mismatch not recognized"
has "$out" "0.7.5"             "(4) envelope: server version not named"
hasnt "$out" "JSON shape skew" "(4) envelope reported as a plain shape skew"
ok

# ── (5) FAIL-SOFT: unparseable / unrelated failures keep the pre-HERD-521 text ─
expect_opaque='herdr CLI contract check failed.
  expected: a read-only `herdr tab list` to succeed and emit JSON
  found:    `herdr tab list` exited non-zero
  Your herdr looks broken or incompatible with the shape testbrand'"'"'s lanes parse.
  Fix: upgrade/repair herdr, then retry.   (bypass: HERD_SKIP_PREFLIGHT=1)'
out="$(run_fn herd_preflight "$opaque:$SYS")"; RC=$?
[ "$RC" -ne 0 ] || fail "(5a) an opaque herdr failure must still fail (got 0)"
[ "$out" = "$expect_opaque" ] || fail "(5a) opaque failure is NOT byte-identical to the old message. got:
$out
want:
$expect_opaque"
ok

expect_skew='herdr CLI contract check failed (JSON shape skew).
  expected: `herdr tab list` JSON with a top-level result.tabs array
            (the envelope lanes parse: result.tabs / result.tab.tab_id / result.root_pane.pane_id)
  found:    no "result.tabs" key
  Your herdr'"'"'s output shape has skewed from what testbrand'"'"'s lanes expect.
  Fix: upgrade herdr to a compatible version, then retry.   (bypass: HERD_SKIP_PREFLIGHT=1)'
out="$(run_fn herd_preflight "$skew:$SYS")"; RC=$?
[ "$RC" -ne 0 ] || fail "(5b) an ordinary shape skew must still fail (got 0)"
[ "$out" = "$expect_skew" ] || fail "(5b) ordinary shape skew is NOT byte-identical to the old message. got:
$out
want:
$expect_skew"
ok

out="$(run_fn herd_preflight "$healthy:$SYS")"; RC=$?
[ "$RC" -eq 0 ] || fail "(5c) a healthy herdr must still pass (got $RC: $out)"
[ -z "$out" ] || fail "(5c) a healthy herdr must stay SILENT (got: $out)"
ok

# ...and the doctor's healthy rendering is untouched: the ✓ contract row, no mismatch anywhere.
out="$(run_fn herd_doctor "$healthy:$SYS" HERD_DOCTOR_OS=darwin HERD_DOCTOR_CLAUDE_TIMEOUT=1)"
has "$out" "herdr JSON contract"  "(5d) doctor lost its healthy herdr contract row"
hasnt "$out" "PROTOCOL MISMATCH"  "(5d) doctor invented a mismatch on a healthy herdr"
ok

echo "ALL PASS ($pass checks)"
