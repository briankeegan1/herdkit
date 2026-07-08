#!/usr/bin/env bash
# test-doctor.sh — hermetic tests for the herd dependency doctor (herd_doctor in
# scripts/herd/herd-preflight.sh) and its two integration points (cmd_init gate + install.sh
# advisory). Builds a FAKE PATH of tool stubs so no real dependency state leaks in, and asserts:
#   (1) all deps present/healthy        → exit 0, "all required dependencies present"
#   (2) required git missing (+ others) → exit 1, ALL reported in ONE pass (not fail-on-first)
#   (3) gh present but not authed       → HARD fail (gh auth is a REQUIRED-tier check)
#   (4) soft vs hard classification     → a missing SOFT dep warns but never fails the run
#   (5) python3 UTF-8 FIXED / BROKEN    → PYTHONUTF8 rescue is ✓; broken python3 UTF-8 only WARNS
#                                         (python3 is a RECOMMENDED dep, checked lazily — not a gate)
#   (6) per-platform install hints      → HERD_DOCTOR_OS selects the right hint
#   (7) HERD_SKIP_DOCTOR=1 escape hatch → silent pass even with everything missing
#   (8) cmd_init gate                   → blocks + writes NO config when a hard dep is missing
#   (9) install.sh advisory            → still symlinks (never blocks) but WARNS on missing deps
#
# Never touches the real environment. Run:  bash tests/test-doctor.sh
# No `set -e`: several checks run the doctor expecting a non-zero exit; assert RC explicitly.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
PREFLIGHT="$REPO/scripts/herd/herd-preflight.sh"
HERD="$REPO/bin/herd"
INSTALL="$REPO/install.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

[ -f "$PREFLIGHT" ] || fail "preflight helper not found at $PREFLIGHT"
command -v python3 >/dev/null 2>&1 || fail "python3 required to run this test"
REAL_PY="$(command -v python3)"
REAL_UNAME="$(command -v uname)"
REAL_BASH="$(command -v bash)"

# BASE: the minimal genuine externals the doctor itself needs (uname for platform, nothing else).
# It deliberately contains NO git/gh/claude/herdr/python3 so a tool is "present" ONLY when a
# scenario explicitly stubs it — that is what makes the missing-dep branches hermetic.
BASE="$T/base"; mkdir -p "$BASE"
ln -sf "$REAL_UNAME" "$BASE/uname"
ln -sf "$REAL_BASH" "$BASE/bash"   # the stub shebangs (/usr/bin/env bash) need bash reachable on PATH

# mkbin <name> — fresh empty scenario bindir; echoes its path.
mkbin() { local d="$T/$1"; rm -rf "$d"; mkdir -p "$d"; printf '%s' "$d"; }
# add_present <bindir> <name...> — drop trivial presence-only stubs (doctor only `command -v`s them).
add_present() { local d="$1"; shift; local n; for n in "$@"; do printf '#!/usr/bin/env bash\nexit 0\n' > "$d/$n"; chmod +x "$d/$n"; done; }
# add_gh_authed <bindir> — gh whose `auth status` succeeds.
add_gh_authed() { printf '#!/usr/bin/env bash\ncase "$1 $2" in "auth status") exit 0;; esac\nexit 0\n' > "$1/gh"; chmod +x "$1/gh"; }
# add_gh_unauthed <bindir> — gh present but `auth status` fails (logged out).
add_gh_unauthed() { printf '#!/usr/bin/env bash\ncase "$1 $2" in "auth status") echo "not logged in" >&2; exit 1;; esac\nexit 0\n' > "$1/gh"; chmod +x "$1/gh"; }
# add_herdr_healthy <bindir> — herdr whose `tab list` emits the expected result.tabs envelope.
add_herdr_healthy() {
  printf '%s\n' '#!/usr/bin/env bash' \
    'case "$1 $2" in "tab list") echo "{\"result\":{\"tabs\":[]}}";; *) echo "{}";; esac' > "$1/herdr"
  chmod +x "$1/herdr"
}
# add_real_python <bindir> — a working python3 (symlink to the real one) for the contract/UTF-8 probes.
add_real_python() { ln -sf "$REAL_PY" "$1/python3"; }
# add_python_fixed <bindir> — fake python3: default cp1252 (can't emit UTF-8) but PYTHONUTF8=1 rescues it.
add_python_fixed() {
  printf '%s\n' '#!/usr/bin/env bash' \
    'case "$*" in *stdout.encoding*) echo cp1252; exit 0;; esac' \
    'if [ "${PYTHONUTF8:-}" = "1" ]; then exit 0; else echo "UnicodeEncodeError" >&2; exit 1; fi' > "$1/python3"
  chmod +x "$1/python3"
}
# add_python_broken <bindir> — fake python3: cannot emit UTF-8 even with PYTHONUTF8=1 (ancient python).
add_python_broken() {
  printf '%s\n' '#!/usr/bin/env bash' \
    'case "$*" in *stdout.encoding*) echo cp1252; exit 0;; esac' \
    'echo "UnicodeEncodeError" >&2; exit 1' > "$1/python3"
  chmod +x "$1/python3"
}

# run_doctor <bindir> [env...] — run herd_doctor with the DOCTOR's PATH set to <bindir>:BASE (so a
# tool is present only when the scenario stubs it), echo combined output, RETURN its exit code.
# `env` + the absolute REAL_BASH are resolved by the test's own PATH; only the doctor's `command -v`
# sees the restricted PATH we hand it via env.
run_doctor() {
  local d="$1"; shift
  env "$@" PATH="$d:$BASE" "$REAL_BASH" -c '. "$0"; herd_doctor 2>&1' "$PREFLIGHT"
}

# ── (1) ALL healthy → exit 0 + success line; soft deps absent must NOT fail the run ──────────────
b="$(mkbin s1)"; add_present "$b" git claude; add_gh_authed "$b"; add_herdr_healthy "$b"; add_real_python "$b"
out="$(run_doctor "$b")"; RC=$?
[ "$RC" -eq 0 ] || fail "(1) all-healthy should pass (got $RC): $out"
grep -qi "all required dependencies present" <<<"$out" || fail "(1) missing success line: $out"
grep -qiE "(git|gh|claude|python3|herdr) not found" <<<"$out" && fail "(1) a hard dep wrongly reported missing: $out"
# soft deps (glow/shellcheck/bats) are NOT stubbed → they warn, but the run still passes. (4)
grep -qiE "shellcheck.*not found|bats.*not found" <<<"$out" || fail "(1/4) soft dep should be reported when absent: $out"
ok

# ── (2) required git missing (+ recommended claude/herdr) → exit 1 + ALL reported in ONE pass ─────
# git is REQUIRED (its miss is the exit-1 condition); claude/herdr are RECOMMENDED (reported +
# warned, but they alone would NOT fail the run — see the dedicated dep-tiering test). All three
# must still surface in the single pass, each with an install hint.
b="$(mkbin s2)"; add_gh_authed "$b"; add_real_python "$b"   # present: gh(authed), python3; MISSING: git, claude, herdr
out="$(run_doctor "$b" HERD_DOCTOR_OS=darwin)"; RC=$?
[ "$RC" -ne 0 ] || fail "(2) missing REQUIRED git should fail (got 0): $out"
grep -qi "git not found" <<<"$out"    || fail "(2) git not reported: $out"
grep -qi "claude not found" <<<"$out" || fail "(2) claude not reported: $out"
grep -qi "herdr not found" <<<"$out"  || fail "(2) herdr not reported: $out"
grep -qi "fix:" <<<"$out"             || fail "(2) no install hint printed: $out"
ok

# ── (3) gh present but NOT authenticated → hard fail naming gh auth ───────────────────────────────
b="$(mkbin s3)"; add_present "$b" git claude; add_gh_unauthed "$b"; add_herdr_healthy "$b"; add_real_python "$b"
out="$(run_doctor "$b")"; RC=$?
[ "$RC" -ne 0 ] || fail "(3) unauthenticated gh should fail (got 0): $out"
grep -qi "gh auth" <<<"$out"          || fail "(3) gh auth not named: $out"
grep -qiE "not authenticated|gh auth login" <<<"$out" || fail "(3) no auth remediation: $out"
ok

# ── (5a) python3 UTF-8 FIXED: cp1252 default but PYTHONUTF8=1 rescues → reported as OK (a ✓) ──────
# herdr absent here (so no contract probe hits the fake python3); assert on the python3-UTF8 line.
b="$(mkbin s5a)"; add_present "$b" git claude; add_gh_authed "$b"; add_python_fixed "$b"
out="$(run_doctor "$b" PYTHONUTF8=)"; RC=$?
grep -qi "PYTHONUTF8=1 to fix it" <<<"$out" || fail "(5a) FIXED python3 not reported as rescued: $out"
grep -qi "cannot emit UTF-8" <<<"$out"      && fail "(5a) FIXED python3 wrongly flagged broken: $out"
ok

# ── (5b) python3 UTF-8 BROKEN: fails even with PYTHONUTF8=1 → WARNS, does NOT gate init ────────────
# python3 (and its UTF-8 capability) is a RECOMMENDED dep now, not a REQUIRED one: herdkit's own
# emoji pane labels are not a generic consumer's concern at init time. With git+gh present the run
# must still PASS (exit 0), while the broken-UTF-8 message is still reported for `herd doctor`.
b="$(mkbin s5b)"; add_present "$b" git claude herdr; add_gh_authed "$b"; add_python_broken "$b"
out="$(run_doctor "$b" PYTHONUTF8=)"; RC=$?
[ "$RC" -eq 0 ] || fail "(5b) broken python3 UTF-8 must WARN, not fail, when git+gh present (got $RC): $out"
grep -qi "cannot emit UTF-8 even with PYTHONUTF8=1" <<<"$out" || fail "(5b) broken UTF-8 message missing: $out"
ok

# ── (6) per-platform install hints: same missing git, different HERD_DOCTOR_OS → different hint ───
b="$(mkbin s6)"; add_gh_authed "$b"; add_real_python "$b"; add_present "$b" claude herdr   # git MISSING
out="$(run_doctor "$b" HERD_DOCTOR_OS=windows)"; RC=$?
grep -qi "winget install Git.Git" <<<"$out" || fail "(6) windows git hint missing: $out"
out="$(run_doctor "$b" HERD_DOCTOR_OS=linux)"; RC=$?
grep -qi "apt install git" <<<"$out"        || fail "(6) linux git hint missing: $out"
ok

# ── (6b) herdr missing + windows → WSL2-first hint (not a bare "install herdr") ───────────────────
b="$(mkbin s6b)"; add_present "$b" git claude; add_gh_authed "$b"; add_real_python "$b"  # herdr MISSING
out="$(run_doctor "$b" HERD_DOCTOR_OS=windows)"; RC=$?
grep -qi "WSL2" <<<"$out"      || fail "(6b) windows herdr hint should point to WSL2: $out"
out="$(run_doctor "$b" HERD_DOCTOR_OS=linux)"; RC=$?
grep -qi "on PATH" <<<"$out"   || fail "(6b) linux herdr hint should keep the generic on-PATH text: $out"
ok

# ── (7) escape hatch: HERD_SKIP_DOCTOR=1 passes silently even with everything missing ────────────
b="$(mkbin s7)"   # empty bindir: no deps at all
out="$(run_doctor "$b" HERD_SKIP_DOCTOR=1)"; RC=$?
[ "$RC" -eq 0 ] || fail "(7) HERD_SKIP_DOCTOR=1 should pass with nothing installed (got $RC): $out"
[ -z "$out" ]   || fail "(7) HERD_SKIP_DOCTOR=1 should be silent (got: $out)"
ok

# ── (8) cmd_init gate: a missing hard dep blocks init and writes NO config ────────────────────────
# SAFE has the system tools bin/herd itself needs (git, sed, awk, mktemp, ...) but NOT gh/claude/herdr
# (those live in a package-manager prefix outside these dirs), so the doctor sees them missing.
SAFE="/usr/bin:/bin:/usr/sbin:/sbin"
case ":$SAFE:" in *":$(dirname "$REAL_PY"):"*) ;; *) SAFE="$(dirname "$REAL_PY"):$SAFE" ;; esac
proj="$T/proj"; mkdir -p "$proj"
git -C "$proj" init -q; git -C "$proj" config user.email t@t.t; git -C "$proj" config user.name t
( cd "$proj" && git commit -q --allow-empty -m init )
out="$(cd "$proj" && PATH="$SAFE" HERD_NONINTERACTIVE=1 bash "$HERD" init 2>&1)"; RC=$?
[ "$RC" -ne 0 ] || fail "(8) init should fail when a hard dep is missing (got 0): $out"
[ ! -f "$proj/.herd/config" ] || fail "(8) init wrote .herd/config despite the doctor gate — config must not be written on a broken env"
grep -qi "herd doctor found" <<<"$out" || fail "(8) init did not surface the doctor gate: $out"
# ...and HERD_SKIP_DOCTOR=1 bypasses the gate so init proceeds to write config.
out="$(cd "$proj" && PATH="$SAFE" HERD_NONINTERACTIVE=1 HERD_SKIP_DOCTOR=1 bash "$HERD" init 2>&1)"; RC=$?
[ "$RC" -eq 0 ] || fail "(8) init with HERD_SKIP_DOCTOR=1 should proceed (got $RC): $out"
[ -f "$proj/.herd/config" ] || fail "(8) init with doctor bypassed did not write .herd/config: $out"
ok

# ── (9) install.sh advisory: still symlinks (never blocks) but WARNS about missing deps ──────────
prefix="$T/optbin"; mkdir -p "$prefix"
out="$(PATH="$SAFE" bash "$INSTALL" --dir "$prefix" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] || fail "(9) install.sh must not be blocked by missing deps (got $RC): $out"
[ -L "$prefix/herd" ] || fail "(9) install.sh did not create the herd symlink: $out"
grep -qiE "missing|broken" <<<"$out" || fail "(9) install.sh did not warn about missing deps: $out"
ok

echo "ALL PASS ($pass checks)"
