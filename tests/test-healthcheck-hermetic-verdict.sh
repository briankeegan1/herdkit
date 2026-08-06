#!/usr/bin/env bash
# test-healthcheck-hermetic-verdict.sh — hermetic proof of HERD-571: .herd/healthcheck.project.sh's
# _hk_dh_verdict only reds on a GENUINE leak line, never on a line agent-watch.sh's hermetic-guard
# choke point tagged "refusal" (HERD_HERMETIC_GUARD_REFUSAL=1 — a test deliberately driving that choke
# point as its own subject, e.g. tests/test-watcher-boot-journal.sh case (a)). Before this fix, ANY
# non-empty leak log reded the whole suite regardless of why the line was written — a test that shared
# the outer harness's HERD_HERMETIC_GUARD without pinning its own private log (a test-isolation bug,
# not a real leak) poisoned every unrelated test in the same run.
#
# Drives the REAL .herd/healthcheck.project.sh end-to-end with a stub `bats` that, instead of actually
# running the suite, writes directly into $HERD_HERMETIC_GUARD (the exact env var the real script
# exports for its bats invocation) — simulating what a test running INSIDE that suite would leave
# behind — then reports a clean passing TAP run. No real bats, no real tests, no network, never touches
# the real workspace. Kept in lockstep with tests/test-daemon-hermeticity.sh (which proves the choke
# point itself writes the "refusal"/"leak" tag) and tests/test-healthcheck-env-classify.sh (same
# stub-fixture pattern for this same script). Run:  bash tests/test-healthcheck-hermetic-verdict.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT_REPO="$(cd "$HERE/.." && pwd)"
PROJ="$ROOT_REPO/.herd/healthcheck.project.sh"
[ -f "$PROJ" ] || { echo "FAIL: healthcheck.project.sh not found at $PROJ" >&2; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ pass=$((pass + 1)); }

TAP_PASS='1..1
ok 1 hermetic something test passes'

# build_fixture <name> <guard-body> — a throwaway worktree with a stub `bats` whose body is inlined
# verbatim: it writes whatever the caller wants into $HERD_HERMETIC_GUARD (the real healthcheck script
# exports this for its bats invocation), then prints a clean passing TAP and exits 0. Also stubs the
# lint/workspace tools so the pre-bats sections pass fast and offline — same shape as
# tests/test-healthcheck-env-classify.sh's build_fixture.
build_fixture() {
  local name="$1" guard_body="$2"
  local F="$T/$name" B="$T/$name.bin"
  mkdir -p "$F/tests" "$B"
  : > "$F/tests/dummy.bats"                                # so `ls tests/*.bats` succeeds
  { printf '#!/usr/bin/env bash\n'
    printf '%s\n' "$guard_body"
    printf 'cat <<'"'"'TAP'"'"'\n%s\nTAP\n' "$TAP_PASS"
    printf 'exit 0\n'
  } > "$B/bats"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$B/shellcheck"  # pre-bats lint: no-op clean
  printf '#!/usr/bin/env bash\nexit 1\n' > "$B/herdr"       # absent-ish: no live workspace
  chmod +x "$B/bats" "$B/shellcheck" "$B/herdr"
  echo "$F"
}

# run_proj <fixture> [--oneline] — run the real project healthcheck with the fixture's paired stub
# bindir ("<fixture>.bin") first on PATH. Sets globals OUT (combined output) and RC (exit code).
run_proj() {
  local dir="$1"; shift
  OUT="$(PATH="${dir}.bin:$PATH" bash "$PROJ" "$dir" "$@" 2>&1)"; RC=$?
}

# ── (a) refusal-only taint: an agent-watch.sh line tagged "refusal" must NOT red ────────────────────
F="$(build_fixture refusal_only 'printf "agent-watch.sh\tsome-ws\t/some/fixture/cwd\trefusal\n" >> "$HERD_HERMETIC_GUARD"')"
run_proj "$F" --oneline
[ "$RC" -eq 0 ] || fail "(a) a refusal-only guard line must not red the suite, got RC=$RC — out: $OUT"
case "$OUT" in *"a test touched a LIVE production surface"*) fail "(a) must not report daemon-hermeticity — out: $OUT" ;; esac
ok
echo "PASS (a) a refusal-tagged agent-watch.sh line does not red the suite"

# ── (b) a fixture GENUINE leak (leak-tagged agent-watch.sh reach) still reds ─────────────────────────
F="$(build_fixture genuine_leak 'printf "agent-watch.sh\tsome-ws\t/some/fixture/cwd\tleak\n" >> "$HERD_HERMETIC_GUARD"')"
run_proj "$F" --oneline
[ "$RC" -eq 1 ] || fail "(b) a genuine leak-tagged line must still red, got RC=$RC — out: $OUT"
case "$OUT" in *"a test touched a LIVE production surface"*) : ;; *) fail "(b) must report daemon-hermeticity — out: $OUT" ;; esac
ok
echo "PASS (b) a fixture GENUINE leak (leak-tagged agent-watch.sh reach) still reds"

# ── (c) a genuine stub-tripwire hit (herdr/claude/codex reached for real) still reds — unaffected ────
F="$(build_fixture tripwire_leak 'printf "some-test\therdr\targs\n" >> "$HERD_HERMETIC_GUARD"')"
run_proj "$F" --oneline
[ "$RC" -eq 1 ] || fail "(c) an unstubbed herdr/claude/codex reach must still red, got RC=$RC — out: $OUT"
ok
echo "PASS (c) a genuine stub-tripwire hit still reds (unaffected by the refusal tag)"

# ── (d) mixed: a refusal line PLUS a genuine leak line → still reds (never masks a real leak) ────────
F="$(build_fixture mixed 'printf "agent-watch.sh\tws\t/cwd\trefusal\n" >> "$HERD_HERMETIC_GUARD"; printf "agent-watch.sh\tws2\t/cwd2\tleak\n" >> "$HERD_HERMETIC_GUARD"')"
run_proj "$F" --oneline
[ "$RC" -eq 1 ] || fail "(d) a genuine leak alongside a harmless refusal line must still red, got RC=$RC — out: $OUT"
ok
echo "PASS (d) a genuine leak alongside a harmless refusal line still reds"

echo "ALL PASS ($pass checks)"
