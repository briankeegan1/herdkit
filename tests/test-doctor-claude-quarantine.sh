#!/usr/bin/env bash
# test-doctor-claude-quarantine.sh — hermetic tests for the herd dependency doctor's CLAUDE PROBE
# hardening (herd_doctor in scripts/herd/herd-preflight.sh), issue #137. On macOS, after a homebrew
# cask upgrade the com.apple.quarantine xattr makes EVERY new claude exec hang in _dyld_start — even
# `claude --version` never returns — so an un-timed probe would hang the doctor itself and every
# spawned builder/scribe sits idle with a blank pane. The fix: (a) run the claude probe under a HARD
# TIMEOUT (portable, no GNU-only `timeout` assumption) so a hung binary is REPORTED, not hung on;
# (b) on darwin, resolve the actual claude binary (following the brew shim/symlink chain to the
# Caskroom target) and xattr-check it for com.apple.quarantine, warning with the exact one-line fix.
#
# Builds a FAKE PATH of tool stubs so no real dependency/xattr state leaks in, and asserts:
#   (1) hung claude              → probe TIMES OUT and is REPORTED (doctor returns; does NOT hang),
#                                  a hang is still a RECOMMENDED-tier warn (git+gh present → exit 0)
#   (2) darwin + quarantined bin → ⚠ QUARANTINED + the EXACT `xattr -d com.apple.quarantine <path>` fix
#   (3) darwin + clean binary    → ✓ "not quarantined"; no false QUARANTINED alarm
#   (4) symlink/shim resolution  → the fix names the RESOLVED Caskroom target, not the /bin shim
#   (5) healthy claude           → ✓ "claude responds"; no hang/quarantine noise
#   (6) non-darwin               → the xattr check is skipped entirely (quarantine is macOS-only)
#
# The FALLBACK timeout path (pure-shell watchdog) is exercised on purpose: BASE carries no
# timeout/gtimeout, matching stock macOS. Never touches the real environment. Run:
#   bash tests/test-doctor-claude-quarantine.sh
# No `set -e`: nothing here should abort on an expected non-zero; assert RC explicitly.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
PREFLIGHT="$REPO/scripts/herd/herd-preflight.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

[ -f "$PREFLIGHT" ] || fail "preflight helper not found at $PREFLIGHT"

# real_of <tool> — absolute path to a genuine system tool, or fail if absent (the doctor shells out
# to these under the restricted PATH, so they must be reachable there).
real_of() { command -v "$1" 2>/dev/null || fail "this test needs a real '$1' on PATH"; }

# BASE: the minimal genuine externals the doctor itself needs under the restricted PATH — uname
# (platform), readlink/dirname/grep (symlink resolution + xattr-name match), sleep (the pure-shell
# timeout watchdog), and bash (the stub shebangs). It deliberately carries NO git/gh/claude/xattr and
# NO timeout/gtimeout: a tool is "present" only when a scenario stubs it, and the absence of
# timeout/gtimeout forces the portable pure-shell fallback (the stock-macOS path).
BASE="$T/base"; mkdir -p "$BASE"
for t in uname bash readlink dirname grep sleep; do ln -sf "$(real_of "$t")" "$BASE/$t"; done

mkbin() { local d="$T/$1"; rm -rf "$d"; mkdir -p "$d"; printf '%s' "$d"; }
# add_present <bindir> <name...> — trivial present-and-healthy stubs (exit 0 for any args, so a
# `claude --version` probe responds instantly).
add_present() { local d="$1"; shift; local n; for n in "$@"; do printf '#!/usr/bin/env bash\nexit 0\n' > "$d/$n"; chmod +x "$d/$n"; done; }
add_gh_authed() { printf '#!/usr/bin/env bash\ncase "$1 $2" in "auth status") exit 0;; esac\nexit 0\n' > "$1/gh"; chmod +x "$1/gh"; }
# add_claude_hung <bindir> — a claude that NEVER returns (models the _dyld_start hang). `exec sleep`
# so the pid the watchdog kills IS the sleep, leaving nothing lingering after the timeout fires.
add_claude_hung() { printf '#!/usr/bin/env bash\nexec sleep 30\n' > "$1/claude"; chmod +x "$1/claude"; }
# add_xattr_quarantined <bindir> — xattr stub reporting com.apple.quarantine for ANY file (models a
# freshly cask-upgraded, gatekeeper-flagged binary). Lists names one-per-line like the real tool.
add_xattr_quarantined() {
  printf '%s\n' '#!/usr/bin/env bash' \
    'printf "com.apple.provenance\ncom.apple.quarantine\n"' > "$1/xattr"
  chmod +x "$1/xattr"
}
# add_xattr_clean <bindir> — xattr stub for an un-quarantined file (no attributes).
add_xattr_clean() { printf '#!/usr/bin/env bash\nexit 0\n' > "$1/xattr"; chmod +x "$1/xattr"; }

# run_doctor <bindir> [env...] — run herd_doctor with the DOCTOR's PATH set to <bindir>:BASE (a tool
# is present only when the scenario stubs it), echo combined output, RETURN its exit code.
run_doctor() {
  local d="$1"; shift
  env "$@" PATH="$d:$BASE" "$BASE/bash" -c '. "$0"; herd_doctor 2>&1' "$PREFLIGHT"
}

# ── (1) HUNG claude → probe times out and is REPORTED (the doctor does NOT hang) ──────────────────
# A short probe timeout keeps the test fast; the pure-shell watchdog (no timeout/gtimeout on BASE)
# must fire and surface the hang. claude is RECOMMENDED-tier, so with git+gh present the run passes.
b="$(mkbin s1)"; add_present "$b" git; add_gh_authed "$b"; add_claude_hung "$b"
out="$(run_doctor "$b" HERD_DOCTOR_OS=darwin HERD_DOCTOR_CLAUDE_TIMEOUT=2)"; RC=$?
[ "$RC" -eq 0 ] || fail "(1) a hung claude is a RECOMMENDED-tier warn, not a gate (got $RC): $out"
echo "$out" | grep -qi "claude HUNG"        || fail "(1) hung claude not reported as HUNG: $out"
echo "$out" | grep -qi "did not return within 2s" || fail "(1) timeout not surfaced with the probe window: $out"
echo "$out" | grep -qi "_dyld_start"        || fail "(1) hang not tied to the _dyld_start symptom: $out"
echo "$out" | grep -qi "issue #137"         || fail "(1) hung-claude report should point at the quarantine fix (#137): $out"
ok

# ── (2) darwin + QUARANTINED binary → ⚠ + the EXACT one-line un-quarantine fix, naming the binary ──
b="$(mkbin s2)"; add_present "$b" git claude; add_gh_authed "$b"; add_xattr_quarantined "$b"
out="$(run_doctor "$b" HERD_DOCTOR_OS=darwin)"; RC=$?
[ "$RC" -eq 0 ] || fail "(2) quarantine is a RECOMMENDED-tier warn, not a gate (got $RC): $out"
echo "$out" | grep -qi "QUARANTINED"                              || fail "(2) quarantine not flagged: $out"
echo "$out" | grep -qi "com.apple.quarantine"                    || fail "(2) xattr name not named: $out"
echo "$out" | grep -qE "fix: xattr -d com\.apple\.quarantine .*/claude" || fail "(2) exact one-line fix (with the binary path) missing: $out"
ok

# ── (3) darwin + CLEAN binary → ✓ not quarantined; no false alarm ─────────────────────────────────
b="$(mkbin s3)"; add_present "$b" git claude; add_gh_authed "$b"; add_xattr_clean "$b"
out="$(run_doctor "$b" HERD_DOCTOR_OS=darwin)"; RC=$?
[ "$RC" -eq 0 ] || fail "(3) clean binary should pass (got $RC): $out"
echo "$out" | grep -qi "claude binary not quarantined" || fail "(3) clean binary not reported as ✓: $out"
echo "$out" | grep -qi "is QUARANTINED"                && fail "(3) false quarantine alarm on a clean binary: $out"
ok

# ── (4) symlink/shim resolution → the fix names the RESOLVED Caskroom target, not the /bin shim ────
# claude on PATH is a shim symlink into a fake Caskroom; the xattr flag lives on the real target.
# Proves _herd_doctor_realpath follows the chain: the reported path must be the Caskroom binary.
CASK="$T/Caskroom/claude-code/2.1.201/bin"; mkdir -p "$CASK"
add_present "$CASK" claude   # the REAL (resolved) binary
b="$(mkbin s4)"; add_present "$b" git; add_gh_authed "$b"; add_xattr_quarantined "$b"
ln -sf "$CASK/claude" "$b/claude"   # /bin shim → Caskroom target
out="$(run_doctor "$b" HERD_DOCTOR_OS=darwin)"; RC=$?
echo "$out" | grep -qF "$CASK/claude"     || fail "(4) fix did not resolve the shim to the Caskroom binary: $out"
echo "$out" | grep -qF "fix: xattr -d com.apple.quarantine $CASK/claude" || fail "(4) fix should target the resolved Caskroom path: $out"
ok

# ── (5) HEALTHY claude → ✓ responds; no hang/quarantine noise ─────────────────────────────────────
b="$(mkbin s5)"; add_present "$b" git claude; add_gh_authed "$b"; add_xattr_clean "$b"
out="$(run_doctor "$b" HERD_DOCTOR_OS=darwin)"; RC=$?
[ "$RC" -eq 0 ] || fail "(5) healthy claude should pass (got $RC): $out"
echo "$out" | grep -qi "claude responds"  || fail "(5) healthy claude not reported as responsive: $out"
echo "$out" | grep -qi "claude HUNG"      && fail "(5) healthy claude wrongly flagged as hung: $out"
ok

# ── (6) non-darwin → the xattr/quarantine check is SKIPPED (macOS-only concern) ───────────────────
# Even with an xattr stub that would report quarantine, a linux platform must not run the check.
b="$(mkbin s6)"; add_present "$b" git claude; add_gh_authed "$b"; add_xattr_quarantined "$b"
out="$(run_doctor "$b" HERD_DOCTOR_OS=linux)"; RC=$?
[ "$RC" -eq 0 ] || fail "(6) linux run should pass (got $RC): $out"
echo "$out" | grep -qi "is QUARANTINED"         && fail "(6) quarantine check must not run off darwin: $out"
echo "$out" | grep -qi "claude binary not quarantined" && fail "(6) quarantine ✓ line must not print off darwin: $out"
echo "$out" | grep -qi "claude responds"        || fail "(6) probe should still run + pass on linux: $out"
ok

echo "ALL PASS ($pass checks)"
