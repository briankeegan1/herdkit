#!/usr/bin/env bash
# test-preflight.sh — hermetic test of the herdr preflight guard (scripts/herd/herd-preflight.sh).
# Injects a FAKE `herdr` stub on PATH in a temp dir and asserts the three branches:
#   (a) herdr missing          → non-zero + remediation text
#   (b) healthy/expected shape → silent pass (exit 0)
#   (c) skewed/bad shape       → non-zero + skew message
# Plus: the HERD_SKIP_PREFLIGHT escape hatch, and the opt-in HERDR_MIN_VERSION floor.
# No network, no real herdr. Run:  bash tests/test-preflight.sh
# No `set -e`: several checks deliberately run the guard expecting a non-zero exit; we assert on the
# captured RC explicitly via fail() instead.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PREFLIGHT="$HERE/../scripts/herd/herd-preflight.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ pass=$((pass+1)); }

[ -f "$PREFLIGHT" ] || fail "preflight helper not found at $PREFLIGHT"

# Standard system bin dirs: provide bash/env/python3/grep to the stubbed runs WITHOUT pulling in a
# (typically brew-installed) real herdr, so the "missing herdr" branch is genuinely herdr-free.
SYS="/usr/bin:/bin:/usr/sbin:/sbin"
command -v python3 >/dev/null 2>&1 || fail "python3 required to run this test"
case ":$SYS:" in *":$(dirname "$(command -v python3)"):"*) ;; *) SYS="$(dirname "$(command -v python3)"):$SYS";; esac

# write_stub <name> <body> — drop an executable fake `herdr` into a fresh bindir; echo the bindir.
write_stub() {
  local bindir="$T/$1"; mkdir -p "$bindir"
  printf '%s\n' "$2" > "$bindir/herdr"
  chmod +x "$bindir/herdr"
  printf '%s' "$bindir"
}

# run_preflight <PATH-to-use> [env assignments...] — run the guard under the given PATH (with the
# fake herdr stub) and optional env, printing its combined output and RETURNING its exit code. Each
# caller captures that with `RC=$?`. The modified PATH governs `command -v herdr` + python3/bash
# resolution inside the spawned shell.
run_preflight() {
  local usepath="$1"; shift
  PATH="$usepath" env "$@" bash -c '. "$0"; herd_preflight 2>&1' "$PREFLIGHT"
}

# ── (a) herdr MISSING → non-zero + remediation ───────────────────────────────
# A bindir with python3 reachable but NO herdr. Crucially the real herdr (if any) is shadowed by
# using ONLY this controlled PATH.
emptybin="$T/nopath"; mkdir -p "$emptybin"
out="$(run_preflight "$emptybin:$SYS")"; RC=$?
[ "$RC" -ne 0 ] || fail "(a) missing herdr should return non-zero (got 0)"
echo "$out" | grep -qi "herdr" || fail "(a) missing: message does not mention herdr"
echo "$out" | grep -qiE "required|install|PATH|dependency" || fail "(a) missing: no remediation text"
ok

# ── (b) HEALTHY shape → silent pass ──────────────────────────────────────────
healthy="$(write_stub healthy '#!/usr/bin/env bash
case "$1 $2" in
  "tab list") echo "{\"id\":1,\"result\":{\"tabs\":[],\"type\":\"x\"}}" ;;
  *) echo "{}" ;;
esac')"
out="$(run_preflight "$healthy:$SYS")"; RC=$?
[ "$RC" -eq 0 ] || fail "(b) healthy shape should pass (got $RC: $out)"
[ -z "$out" ] || fail "(b) healthy shape should be silent (got: $out)"
ok

# ── (c1) SKEW: valid JSON but missing result.tabs → non-zero + skew message ──
skew="$(write_stub skew '#!/usr/bin/env bash
case "$1 $2" in
  "tab list") echo "{\"id\":1,\"result\":{\"panes\":[]}}" ;;
  *) echo "{}" ;;
esac')"
out="$(run_preflight "$skew:$SYS")"; RC=$?
[ "$RC" -ne 0 ] || fail "(c1) skewed shape should return non-zero (got 0)"
echo "$out" | grep -qiE "skew|contract|expected" || fail "(c1) skew: no skew/contract message ($out)"
echo "$out" | grep -q "result.tabs" || fail "(c1) skew: message should name result.tabs"
ok

# ── (c2) SKEW: not JSON at all → non-zero ────────────────────────────────────
notjson="$(write_stub notjson '#!/usr/bin/env bash
echo "herdr: unknown subcommand" >&2; echo "garbage not json"')"
out="$(run_preflight "$notjson:$SYS")"; RC=$?
[ "$RC" -ne 0 ] || fail "(c2) non-JSON output should return non-zero (got 0)"
echo "$out" | grep -qiE "skew|contract|JSON" || fail "(c2) non-JSON: no contract message ($out)"
ok

# ── (c3) SKEW: herdr exits non-zero on the probe → non-zero ──────────────────
exiterr="$(write_stub exiterr '#!/usr/bin/env bash
exit 3')"
out="$(run_preflight "$exiterr:$SYS")"; RC=$?
[ "$RC" -ne 0 ] || fail "(c3) herdr exiting non-zero should fail preflight (got 0)"
echo "$out" | grep -qiE "contract|non-zero|skew" || fail "(c3) exit-nonzero: no contract message ($out)"
ok

# ── escape hatch: HERD_SKIP_PREFLIGHT=1 bypasses even with NO herdr ───────────
out="$(run_preflight "$emptybin:$SYS" HERD_SKIP_PREFLIGHT=1)"; RC=$?
[ "$RC" -eq 0 ] || fail "escape hatch HERD_SKIP_PREFLIGHT=1 should pass with no herdr (got $RC: $out)"
ok

# ── HERDR_MIN_VERSION floor (opt-in) over a healthy-shape stub that reports a version ─
verstub="$(write_stub verstub '#!/usr/bin/env bash
case "$1" in
  "--version") echo "herdr 0.7.1" ;;
  *) case "$1 $2" in "tab list") echo "{\"id\":1,\"result\":{\"tabs\":[],\"type\":\"x\"}}";; *) echo "{}";; esac ;;
esac')"
# Floor satisfied (0.7.1 >= 0.5.0) → pass.
out="$(run_preflight "$verstub:$SYS" HERDR_MIN_VERSION=0.5.0)"; RC=$?
[ "$RC" -eq 0 ] || fail "min-version satisfied should pass (got $RC: $out)"
ok
# Floor too high (0.7.1 < 9.9.9) → fail with version message.
out="$(run_preflight "$verstub:$SYS" HERDR_MIN_VERSION=9.9.9)"; RC=$?
[ "$RC" -ne 0 ] || fail "min-version unmet should fail (got 0)"
echo "$out" | grep -qiE "version" || fail "min-version: no version message ($out)"
ok

echo "ALL PASS ($pass checks)"
