#!/usr/bin/env bash
# test-doctor-dep-tiering.sh — hermetic tests for the DEPENDENCY-TIERING fix in the herd dependency
# doctor (herd_doctor in scripts/herd/herd-preflight.sh). External-consumer audit, Leak A / ranked
# follow-up #1: `herd init` must gate ONLY on git + gh, and treat herdr / claude / python3 as
# RECOMMENDED deps that are checked lazily at point-of-use — a miss WARNS, it does NOT block init.
#
# Asserts:
#   (A) init-tier passes with ONLY git+gh   → herd_doctor exits 0 though herdr/claude/python3 absent
#   (B) missing herdr = WARNING, not a gate → exit 0, "herdr not found" still reported (doctor lists
#                                             it), and the summary says init can proceed
#   (C) claude / python3 absent also only warn (same tier)
#   (D) the full one-pass report survives   → every RECOMMENDED miss carries an install hint, and the
#                                             REQUIRED / RECOMMENDED / OPTIONAL section headers print
#   (E) git missing IS still a hard gate     → exit 1 (proves the tier boundary is real, not "never fail")
#   (F) end-to-end cmd_init                   → with git+gh(+python3) present but herdr/claude ABSENT,
#                                             `herd init` PROCEEDS and writes .herd/config (no bypass)
#
# Never touches the real environment (builds a FAKE PATH of tool stubs). Run: bash tests/test-doctor-dep-tiering.sh
# No `set -e`: one check runs the doctor expecting a non-zero exit; assert RC explicitly.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
PREFLIGHT="$REPO/scripts/herd/herd-preflight.sh"
HERD="$REPO/bin/herd"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

[ -f "$PREFLIGHT" ] || fail "preflight helper not found at $PREFLIGHT"
command -v python3 >/dev/null 2>&1 || fail "python3 required to run this test"
REAL_PY="$(command -v python3)"
REAL_UNAME="$(command -v uname)"
REAL_BASH="$(command -v bash)"

# BASE: the minimal genuine externals the doctor itself needs (uname for platform). It deliberately
# holds NO git/gh/claude/herdr/python3 — a tool is "present" only when a scenario explicitly stubs it.
BASE="$T/base"; mkdir -p "$BASE"
ln -sf "$REAL_UNAME" "$BASE/uname"
ln -sf "$REAL_BASH" "$BASE/bash"   # stub shebangs (/usr/bin/env bash) need bash reachable on PATH

mkbin() { local d="$T/$1"; rm -rf "$d"; mkdir -p "$d"; printf '%s' "$d"; }
add_present() { local d="$1"; shift; local n; for n in "$@"; do printf '#!/usr/bin/env bash\nexit 0\n' > "$d/$n"; chmod +x "$d/$n"; done; }
add_gh_authed() { printf '#!/usr/bin/env bash\ncase "$1 $2" in "auth status") exit 0;; esac\nexit 0\n' > "$1/gh"; chmod +x "$1/gh"; }
add_herdr_healthy() {
  printf '%s\n' '#!/usr/bin/env bash' \
    'case "$1 $2" in "tab list") echo "{\"result\":{\"tabs\":[]}}";; *) echo "{}";; esac' > "$1/herdr"
  chmod +x "$1/herdr"
}
add_real_python() { ln -sf "$REAL_PY" "$1/python3"; }

# run_doctor <bindir> [env...] — run herd_doctor with the DOCTOR's PATH set to <bindir>:BASE, echo
# combined output, RETURN its exit code. Only the doctor's `command -v` sees the restricted PATH.
run_doctor() {
  local d="$1"; shift
  env "$@" PATH="$d:$BASE" "$REAL_BASH" -c '. "$0"; herd_doctor 2>&1' "$PREFLIGHT"
}

# ── (A/B/C/D) ONLY git+gh present (authed); herdr, claude, python3 ALL absent ─────────────────────
b="$(mkbin sA)"; add_present "$b" git; add_gh_authed "$b"   # NO herdr / claude / python3
out="$(run_doctor "$b" HERD_DOCTOR_OS=darwin)"; RC=$?
# (A/B) the whole point: init is NOT gated on the herdkit runtime — this must PASS.
[ "$RC" -eq 0 ] || fail "(A) doctor must pass with only git+gh present (got $RC): $out"
echo "$out" | grep -qi "herd init can proceed" || fail "(B) summary should say init can proceed: $out"
# (B/C) …yet every RECOMMENDED miss is still REPORTED (doctor lists everything in one pass).
echo "$out" | grep -qi "herdr not found"   || fail "(B) missing herdr not reported: $out"
echo "$out" | grep -qi "claude not found"  || fail "(C) missing claude not reported: $out"
echo "$out" | grep -qi "python3 not found" || fail "(C) missing python3 not reported: $out"
# …and each carries a warn marker + an install hint, and is NOT dressed up as a hard ✗-required miss.
echo "$out" | grep -qi "fix:" || fail "(D) recommended miss printed no install hint: $out"
# (D) the tiered section headers all render (full one-pass report preserved).
echo "$out" | grep -qi "Required (herd init needs these)"      || fail "(D) Required header missing: $out"
echo "$out" | grep -qi "Recommended"                           || fail "(D) Recommended header missing: $out"
echo "$out" | grep -qi "Optional (a missing one only degrades" || fail "(D) Optional header missing: $out"
ok

# ── (B2) herdr the ONLY missing dep → still just a warning, init proceeds ──────────────────────────
b="$(mkbin sB2)"; add_present "$b" git claude; add_gh_authed "$b"; add_real_python "$b"   # NO herdr
out="$(run_doctor "$b")"; RC=$?
[ "$RC" -eq 0 ] || fail "(B2) a lone-missing herdr must not block init (got $RC): $out"
echo "$out" | grep -qi "herdr not found"        || fail "(B2) missing herdr not reported: $out"
echo "$out" | grep -qi "recommended dependency check" || fail "(B2) warn summary line missing: $out"
ok

# ── (E) git STILL a hard gate → proves the tier boundary is real (doctor is not "never fail") ─────
b="$(mkbin sE)"; add_gh_authed "$b"; add_present "$b" claude; add_herdr_healthy "$b"; add_real_python "$b"  # git MISSING
out="$(run_doctor "$b")"; RC=$?
[ "$RC" -ne 0 ] || fail "(E) missing REQUIRED git must still hard-fail (got 0): $out"
echo "$out" | grep -qi "git not found"        || fail "(E) git miss not reported: $out"
echo "$out" | grep -qi "herd init cannot proceed" || fail "(E) hard-fail summary missing: $out"
ok

# ── (F) end-to-end cmd_init: git+gh(+python3) present, herdr+claude ABSENT → init PROCEEDS ────────
# SAFE holds the system tools bin/herd needs (sed/awk/git/...) plus python3's dir; a scenario bindir
# supplies an AUTHED gh. herdr/claude live in a package-manager prefix outside these dirs, so they
# are genuinely absent — and init must STILL write config (no HERD_SKIP_DOCTOR bypass).
SAFE="/usr/bin:/bin:/usr/sbin:/sbin"
case ":$SAFE:" in *":$(dirname "$REAL_PY"):"*) ;; *) SAFE="$(dirname "$REAL_PY"):$SAFE" ;; esac
ghbin="$T/ghbin"; mkdir -p "$ghbin"; add_gh_authed "$ghbin"
command -v git >/dev/null 2>&1 || fail "(F) real git required on the test's own PATH"
# Guard: the scenario is only meaningful if herdr/claude are truly absent from the PATH init will see.
if PATH="$ghbin:$SAFE" command -v herdr >/dev/null 2>&1 || PATH="$ghbin:$SAFE" command -v claude >/dev/null 2>&1; then
  echo "SKIP (F): herdr/claude present under the sandbox PATH; cannot prove absence hermetically" >&2
else
  proj="$T/proj"; mkdir -p "$proj"
  git -C "$proj" init -q; git -C "$proj" config user.email t@t.t; git -C "$proj" config user.name t
  ( cd "$proj" && git commit -q --allow-empty -m init )
  out="$(cd "$proj" && PATH="$ghbin:$SAFE" HERD_NONINTERACTIVE=1 bash "$HERD" init 2>&1)"; RC=$?
  [ "$RC" -eq 0 ]           || fail "(F) init must PROCEED with herdr/claude absent but git+gh present (got $RC): $out"
  [ -f "$proj/.herd/config" ] || fail "(F) init did not write .herd/config though the doctor gate passed: $out"
fi
ok

echo "ALL PASS ($pass checks)"
