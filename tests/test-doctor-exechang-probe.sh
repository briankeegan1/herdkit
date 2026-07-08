#!/usr/bin/env bash
# test-doctor-exechang-probe.sh — hermetic proof for the herd doctor's CLAUDE EXEC-HANG probe (HERD-108).
#
# On some environments `claude` WEDGES on invocation: every exec hangs before the process finishes
# starting, so even `claude --version` never returns and spawned builders/reviewers sit idle. `herd
# doctor` (herd_doctor in scripts/herd/herd-preflight.sh) runs its `claude responds` check under a HARD,
# CONFIG-GATED timeout so a wedge is DETECTED and REPORTED — with a fix hint — instead of hanging the
# doctor itself. The darwin com.apple.quarantine specifics (xattr resolution + un-quarantine fix) are
# covered by test-doctor-claude-quarantine.sh; THIS test locks the GENERIC, cross-platform exec-hang
# behavior on a linux platform (the class the watcher's sibling probe also guards):
#   (1) healthy claude          → ✓ "claude responds" within the window; RC 0
#   (2) HUNG claude             → ⚠ "claude HUNG", the doctor RETURNS (does NOT hang), names the timeout
#                                  window; still a RECOMMENDED-tier warn (git+gh present → exit 0)
#   (3) broken claude (rc!=0)   → ⚠ "exited non-zero" (a DIFFERENT fault than a wedge), RC 0
#   (4) HERD_DOCTOR_CLAUDE_TIMEOUT → the probe honors the configured window (surfaced verbatim)
#   (5) linux platform          → no darwin quarantine noise leaks into the exec-hang report
#
# Fully hermetic: a FAKE PATH of tool stubs so no real dependency state leaks in; the doctor is sourced
# in a fresh subshell per scenario. NO network, NO model, NO herdr, NO gh. Run:
#   bash tests/test-doctor-exechang-probe.sh
# No `set -e`: an expected non-zero probe must not abort the harness; assert RC explicitly.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
PREFLIGHT="$REPO/scripts/herd/herd-preflight.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

[ -f "$PREFLIGHT" ] || fail "preflight helper not found at $PREFLIGHT"

# real_of <tool> — absolute path to a genuine system tool, or fail if absent.
real_of() { command -v "$1" 2>/dev/null || fail "this test needs a real '$1' on PATH"; }

# BASE: the minimal genuine externals the doctor needs under the restricted PATH — uname (platform),
# readlink/dirname/grep (helpers), sleep (the pure-shell watchdog), bash (stub shebangs), and a real
# `timeout` (exercise the coreutils path — the common linux case). No git/gh/claude here: a tool is
# "present" only when a scenario stubs it.
BASE="$T/base"; mkdir -p "$BASE"
for t in uname bash readlink dirname grep sleep timeout; do ln -sf "$(real_of "$t")" "$BASE/$t"; done

mkbin() { local d="$T/$1"; rm -rf "$d"; mkdir -p "$d"; printf '%s' "$d"; }
add_present() { local d="$1"; shift; local n; for n in "$@"; do printf '#!/usr/bin/env bash\nexit 0\n' > "$d/$n"; chmod +x "$d/$n"; done; }
add_gh_authed() { printf '#!/usr/bin/env bash\ncase "$1 $2" in "auth status") exit 0;; esac\nexit 0\n' > "$1/gh"; chmod +x "$1/gh"; }
# add_claude_hung — a claude that NEVER returns (models the exec-wedge). `exec sleep` so the pid the
# watchdog/timeout kills IS the sleep, leaving nothing lingering.
add_claude_hung() { printf '#!/usr/bin/env bash\nexec sleep 30\n' > "$1/claude"; chmod +x "$1/claude"; }
# add_claude_broken — present but `--version` exits non-zero (a broken binary, NOT a wedge).
add_claude_broken() { printf '#!/usr/bin/env bash\nexit 3\n' > "$1/claude"; chmod +x "$1/claude"; }

# run_doctor <bindir> [env...] — run herd_doctor with the DOCTOR's PATH = <bindir>:BASE, echo combined
# output, RETURN its exit code.
run_doctor() {
  local d="$1"; shift
  env "$@" PATH="$d:$BASE" "$BASE/bash" -c '. "$0"; herd_doctor 2>&1' "$PREFLIGHT"
}

# ── (1) HEALTHY claude → ✓ responds; no hang noise ────────────────────────────────────────────────
b="$(mkbin s1)"; add_present "$b" git claude; add_gh_authed "$b"
out="$(run_doctor "$b" HERD_DOCTOR_OS=linux)"; RC=$?
[ "$RC" -eq 0 ] || fail "(1) healthy claude should pass (got $RC): $out"
grep -qi "claude responds" <<<"$out" || fail "(1) healthy claude not reported as responsive: $out"
grep -qi "claude HUNG"     <<<"$out" && fail "(1) healthy claude wrongly flagged as hung: $out"
ok

# ── (2) HUNG claude → probe times out, is REPORTED, doctor RETURNS (a warn, not a gate) ────────────
b="$(mkbin s2)"; add_present "$b" git; add_gh_authed "$b"; add_claude_hung "$b"
out="$(run_doctor "$b" HERD_DOCTOR_OS=linux HERD_DOCTOR_CLAUDE_TIMEOUT=2)"; RC=$?
[ "$RC" -eq 0 ] || fail "(2) a hung claude is a RECOMMENDED-tier warn, not a gate (got $RC): $out"
grep -qi "claude HUNG"            <<<"$out" || fail "(2) hung claude not reported as HUNG: $out"
grep -qi "did not return within 2s" <<<"$out" || fail "(2) timeout window not surfaced: $out"
grep -qi "claude responds"        <<<"$out" && fail "(2) hung claude must not also read as responsive: $out"
ok

# ── (3) BROKEN claude (rc!=0) → a DIFFERENT fault than a wedge; reported, not gated ────────────────
b="$(mkbin s3)"; add_present "$b" git; add_gh_authed "$b"; add_claude_broken "$b"
out="$(run_doctor "$b" HERD_DOCTOR_OS=linux)"; RC=$?
[ "$RC" -eq 0 ] || fail "(3) a broken claude is a warn, not a gate (got $RC): $out"
grep -qi "exited non-zero" <<<"$out" || fail "(3) broken claude not reported as a non-zero exit: $out"
grep -qi "claude HUNG"     <<<"$out" && fail "(3) a broken (non-zero) claude must not read as HUNG: $out"
ok

# ── (4) configured timeout window is honored (surfaced verbatim) ───────────────────────────────────
b="$(mkbin s4)"; add_present "$b" git; add_gh_authed "$b"; add_claude_hung "$b"
out="$(run_doctor "$b" HERD_DOCTOR_OS=linux HERD_DOCTOR_CLAUDE_TIMEOUT=1)"; RC=$?
[ "$RC" -eq 0 ] || fail "(4) hung claude with a 1s window should still pass (got $RC): $out"
grep -qi "did not return within 1s" <<<"$out" || fail "(4) configured 1s probe window not honored: $out"
ok

# ── (5) linux platform → no darwin quarantine lines in the exec-hang report ────────────────────────
b="$(mkbin s5)"; add_present "$b" git; add_gh_authed "$b"; add_claude_hung "$b"
out="$(run_doctor "$b" HERD_DOCTOR_OS=linux HERD_DOCTOR_CLAUDE_TIMEOUT=2)"; RC=$?
grep -qi "com.apple.quarantine" <<<"$out" && fail "(5) darwin quarantine text leaked into a linux report: $out"
grep -qi "claude HUNG"          <<<"$out" || fail "(5) linux hang still reported: $out"
ok

echo "ALL PASS ($pass checks) — test-doctor-exechang-probe.sh"
