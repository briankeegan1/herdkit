#!/usr/bin/env bash
# test-bash-syntax-lint.sh — hermetic tests for the shared SYSTEM-BASH SYNTAX guard (HERD-608):
# scripts/herd/bash-syntax-lint.sh bash -n's every scripts/herd/*.sh under the SYSTEM /bin/bash (a
# hardcoded path, never a PATH-resolved bash), so a script that only parses cleanly under a
# developer's homebrew bash — but hits a false syntax error under the watcher pane's system
# /bin/bash 3.2 — is caught pre-PR instead of in production (the journal-audit.sh heredoc-parser
# line-count cliff this lint exists to guard against).
#
# Proves:
#   (1) The REAL tree is clean: every scripts/herd/*.sh parses under /bin/bash.
#   (2) A genuine syntax error in a fixture script reds (exit 1) and prints a BASH-SYNTAX line.
#   (3) A clean fixture is clean (exit 0), with only the ADVISORY summary.
#   (4) Non-recursive: a syntax error nested one directory deeper (scripts/herd/sub/x.sh) is NOT
#       scanned — mirrors caps-sync-lint.sh's own "new lane script" surface (scripts/herd/*.sh only).
#   (5) FAIL-SOFT: a tree with no scripts/herd/*.sh → skip (exit 2), reason set, never a red.
#   (6) The pure-function form (herd_bash_syntax_check) takes explicit file args regardless of
#       directory and is what herd_bash_syntax_lint's entrypoint drives.
#
# This test proves the MECHANISM (a real parse error under /bin/bash reds; a clean file doesn't; the
# scan surface and fail-soft behavior are as documented) — it does not attempt to reproduce the
# specific historical bash-3.2 heredoc-parser line-count cliff itself (that reproduction was
# attempted directly against journal-audit.sh during development and did not trigger on this
# machine's bash 3.2.57 build via naive padding; the guard is valuable regardless, since it makes the
# actual probe — bash -n under the actual watcher interpreter — a standing pre-PR check rather than a
# one-time manual bisection).
#
# Network-free: temp dirs + fixtures only. Run:  bash tests/test-bash-syntax-lint.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LINT="$ROOT/scripts/herd/bash-syntax-lint.sh"

[ -f "$LINT" ] || { echo "FAIL: missing lint: $LINT" >&2; exit 1; }
# shellcheck source=/dev/null
. "$LINT"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { PASS=$((PASS+1)); }

# ── 1. Real tree is clean ─────────────────────────────────────────────────────────────────────────
real_out="$(herd_bash_syntax_lint "$ROOT")"; real_rc=$?
if [ "$real_rc" -ne 0 ]; then
  printf '%s\n' "$real_out" | grep '^BASH-SYNTAX' >&2
  fail "(1) real tree has a scripts/herd/*.sh syntax error under /bin/bash"
fi
grep -q '^BASH-SYNTAX' <<< "$real_out" && fail "(1) BASH-SYNTAX lines present despite clean exit"
grep -q '^ADVISORY:' <<< "$real_out" || fail "(1) advisory summary line missing"
pass
echo "PASS (1) real tree: every scripts/herd/*.sh parses under the system /bin/bash"

# ── helper: a fixture tree with one script under scripts/herd/ ───────────────────────────────────
make_script() {
  # make_script <dir> <body...> — write scripts/herd/probe.sh with the given trailing lines.
  local d="$1"; shift
  mkdir -p "$d/scripts/herd"
  { printf '#!/usr/bin/env bash\n'; printf '%s\n' "$@"; } > "$d/scripts/herd/probe.sh"
}

# ── 2. A genuine syntax error reds ────────────────────────────────────────────────────────────────
TB="$T/broken"; make_script "$TB" 'if true; then' 'echo unterminated'
out="$(herd_bash_syntax_lint "$TB")"; rc=$?
[ "$rc" -eq 1 ] || fail "(2) an unterminated 'if' must red (exit 1, got $rc): $out"
grep -q 'BASH-SYNTAX .*probe.sh' <<< "$out" \
  || fail "(2) should print a BASH-SYNTAX line for probe.sh (got: $out)"
pass
echo "PASS (2) a genuine parse error under /bin/bash → guard reds and emits a BASH-SYNTAX line"

# ── 3. A clean fixture stays clean ────────────────────────────────────────────────────────────────
TC="$T/clean"; make_script "$TC" 'echo ok'
out="$(herd_bash_syntax_lint "$TC")"; rc=$?
[ "$rc" -eq 0 ] || fail "(3) a clean fixture must exit 0 (got $rc): $out"
grep -q '^BASH-SYNTAX' <<< "$out" && fail "(3) clean fixture must emit zero BASH-SYNTAX lines (got: $out)"
grep -qE '^ADVISORY: 1 file' <<< "$out" || fail "(3) advisory should count 1 file checked (got: $out)"
pass
echo "PASS (3) a clean fixture → only the ADVISORY summary, zero BASH-SYNTAX lines"

# ── 4. Non-recursive: a nested syntax error is not scanned ───────────────────────────────────────
TN="$T/nested"; mkdir -p "$TN/scripts/herd/sub"
printf '#!/usr/bin/env bash\necho fine\n' > "$TN/scripts/herd/probe.sh"
printf '#!/usr/bin/env bash\nif true; then\necho unterminated\n' > "$TN/scripts/herd/sub/nested.sh"
out="$(herd_bash_syntax_lint "$TN")"; rc=$?
[ "$rc" -eq 0 ] || fail "(4) a nested-only syntax error must NOT be scanned (exit 0 expected, got $rc): $out"
grep -q 'nested.sh' <<< "$out" && fail "(4) nested.sh must not appear in the output (got: $out)"
pass
echo "PASS (4) scan surface is non-recursive scripts/herd/*.sh, mirroring caps-sync-lint.sh"

# ── 5. Fail-soft: no scripts/herd/*.sh → skip ─────────────────────────────────────────────────────
TS="$T/nosurface"; mkdir -p "$TS/somewhere"
printf 'echo hi\n' > "$TS/somewhere/thing.sh"
HERD_BASH_SYNTAX_SKIP_REASON=""
herd_bash_syntax_lint "$TS" >/dev/null 2>&1; skip_rc=$?
[ "$skip_rc" -eq 2 ] || fail "(5) no scripts/herd/*.sh → skip (exit 2, got $skip_rc)"
[ -n "${HERD_BASH_SYNTAX_SKIP_REASON:-}" ] || fail "(5) HERD_BASH_SYNTAX_SKIP_REASON must be set on skip"
pass
echo "PASS (5) no scripts/herd/*.sh surface → skip (exit 2), never a red, reason set"

# ── 6. Pure-function form takes explicit file args ────────────────────────────────────────────────
TF="$T/purefn"; mkdir -p "$TF/anywhere"
printf '#!/usr/bin/env bash\nif true; then\necho unterminated\n' > "$TF/anywhere/x.sh"
printf '#!/usr/bin/env bash\necho ok\n' > "$TF/anywhere/y.sh"
out="$(herd_bash_syntax_check "$TF/anywhere/x.sh" "$TF/anywhere/y.sh")"; rc=$?
[ "$rc" -eq 1 ] || fail "(6) pure-function form must red on x.sh regardless of directory (exit 1, got $rc): $out"
grep -q 'BASH-SYNTAX .*x.sh' <<< "$out" || fail "(6) should name x.sh (got: $out)"
grep -q 'BASH-SYNTAX .*y.sh' <<< "$out" && fail "(6) y.sh is clean and must not be flagged (got: $out)"
grep -qE '^ADVISORY: 2 file' <<< "$out" || fail "(6) advisory should count both files checked (got: $out)"
pass
echo "PASS (6) herd_bash_syntax_check <file>... — pure form, explicit args, independent of directory"

echo
echo "ALL PASS ($PASS checks) — bash-syntax guard is live, fail-soft, and non-recursive by design."
