#!/usr/bin/env bash
# test-healthcheck-light-probes.sh — hermetic tests for the LIGHT-profile per-language probes in
# scripts/herd/healthcheck.sh (Leak B / external-consumer audit follow-up #2 [P0]).
#
# The light profile is the gate a consumer with NO $HEALTHCHECK_CMD gets. Before this fix it only
# syntax-checked *.sh / *.py and reported a confident "✅ light clean — 0 sh, 0 py ok (exit 0)" for a
# diff whose ONLY changed files were a language it cannot check (.go/.rs/.java/…) — a silent-green
# correctness hazard for non-Python/Node consumers. This asserts the fix:
#   (1) BYTE-IDENTICAL — a purely *.sh + *.py diff still emits the exact old verdict (full + oneline).
#   (2) CONTROL — a real *.sh syntax error is still caught red (exit 1), unchanged.
#   (3) FLAG-THE-ABSENCE — a diff touching only unprobed languages (.rs/.java) is NOT green-lit: a
#       loud ⚠️ "unchecked … (no light probe)", exit 0 (a warning, never red), NEVER a confident ✅.
#   (4) GO PROBE — with gofmt present (stubbed), a clean *.go passes ("go ok") and a broken *.go is
#       caught red (exit 1) — a REAL parse error, not flag-the-absence.
#   (5) MISSING TOOLCHAIN — *.go with gofmt absent → a data/env ⚠️ (exit 0), never red and never a
#       confident ✅ (we still flag that we could not check it).
#
# Network-free: a temp git repo, temp config via HERD_CONFIG_FILE, and a stubbed/curated PATH so the
# gofmt-present and gofmt-absent branches are both deterministic regardless of the host toolchain.
# Run:  bash tests/test-healthcheck-light-probes.sh
# No `set -e`: several checks assert non-zero returns explicitly.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
HC="$HERE/../scripts/herd/healthcheck.sh"
[ -f "$HC" ] || { echo "healthcheck.sh not found at $HC" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "git required to run this test" >&2; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }
nlines() { printf '%s\n' "$1" | grep -c .; }   # count non-empty lines in a captured string

# ── A worktree that looks like a real repo (committed seed on 'main') ─────────
WT="$T/wt"; mkdir -p "$WT"
git -C "$WT" init -q
git -C "$WT" checkout -q -b main 2>/dev/null || git -C "$WT" checkout -q main
git -C "$WT" config user.email t@t.test
git -C "$WT" config user.name  herd-test
echo seed > "$WT/seed.txt"; git -C "$WT" add seed.txt; git -C "$WT" commit -qm seed

# Light profile: no HEALTHCHECK_CMD → auto resolves to light; we also pass --light to be explicit.
CFG="$T/config"
export HERD_CONFIG_FILE="$CFG"
cat > "$CFG" <<CFGEOF
PROJECT_ROOT="$WT"
WORKTREES_DIR="$T/trees"
DEFAULT_BRANCH="main"
WORKSPACE_NAME="ltest"
CFGEOF

# The "diff" is represented by untracked files (a freshly added source file wouldn't show in
# `git diff` yet — exactly what _changed_files unions in via `git ls-files --others`).
clear_diff() { rm -rf "$WT/src" 2>/dev/null || true; mkdir -p "$WT/src"; }
run_hc() { bash "$HC" "$WT" --light "$@"; }

# ── (1) BYTE-IDENTICAL — a *.sh + *.py-only diff emits the exact pre-fix verdict ──────────────
clear_diff
printf 'echo hi\n'      > "$WT/src/tool.sh"
printf 'x = 1\n'        > "$WT/src/mod.py"
out="$(run_hc)"; rc=$?
[ "$rc" -eq 0 ] || fail "(1) sh+py clean should exit 0 (got $rc)"
exp="$(printf '✅ LIGHT CHECK CLEAN (non-heavy change)\n   shell:  1 changed *.sh — bash -n ok\n   python: 1 changed *.py — py_compile ok')"
[ "$out" = "$exp" ] || fail "(1) full output not byte-identical to the pre-fix verdict; got:
$out"
ok
oneout="$(run_hc --oneline)"; orc=$?
[ "$orc" -eq 0 ] || fail "(1) oneline sh+py clean should exit 0 (got $orc)"
[ "$oneout" = "✅ light clean — 1 sh, 1 py ok" ] || fail "(1) oneline not byte-identical (got: $oneout)"
ok

# ── (2) CONTROL — a real *.sh syntax error is still caught red (unchanged) ────────────────────
clear_diff
printf 'if then fi\n' > "$WT/src/broken.sh"
out="$(run_hc)"; rc=$?
[ "$rc" -eq 1 ] || fail "(2) broken .sh must be caught red (exit 1, got $rc): $out"
printf '%s' "$out" | grep -q 'SYNTAX ERROR' || fail "(2) broken .sh should report a SYNTAX ERROR"
ok

# ── (3) FLAG-THE-ABSENCE — an unprobed-language-only diff is flagged ⚠️, never a confident ✅ ──
clear_diff
printf 'fn main() {}\n'                 > "$WT/src/lib.rs"
printf 'pub fn also() {}\n'             > "$WT/src/more.rs"
printf 'class A {}\n'                   > "$WT/src/A.java"
out="$(run_hc)"; rc=$?
[ "$rc" -eq 0 ] || fail "(3) unprobed-only diff is a warning, not a code error (exit 0, got $rc): $out"
printf '%s' "$out" | grep -q 'UNCHECKED FILE TYPES' || fail "(3) should flag UNCHECKED FILE TYPES (got: $out)"
printf '%s' "$out" | grep -q 'no light probe'       || fail "(3) should say 'no light probe' (got: $out)"
printf '%s' "$out" | grep -q '2 rs'                 || fail "(3) should count 2 rs files (got: $out)"
printf '%s' "$out" | grep -q '1 java'               || fail "(3) should count 1 java file (got: $out)"
printf '%s' "$out" | grep -q 'LIGHT CHECK CLEAN'    && fail "(3) MUST NOT emit a confident '✅ LIGHT CHECK CLEAN' for unchecked types"
ok
oneout="$(run_hc --oneline)"; orc=$?
[ "$orc" -eq 0 ] || fail "(3) oneline unchecked should exit 0 (got $orc)"
[ "$(nlines "$oneout")" -eq 1 ] || fail "(3) oneline must be exactly one line (got: $oneout)"
printf '%s' "$oneout" | grep -q '⚠️'          || fail "(3) oneline should carry a ⚠️ (got: $oneout)"
printf '%s' "$oneout" | grep -q 'no light probe' || fail "(3) oneline should say 'no light probe' (got: $oneout)"
printf '%s' "$oneout" | grep -q '✅'          && fail "(3) oneline must not claim ✅ for unchecked types (got: $oneout)"
ok

# ── (4) GO PROBE — with a (stubbed) gofmt present: clean *.go passes, broken *.go is caught red ──
# Stub gofmt: a pure parser that exits non-zero (like real `gofmt -e`) on files containing the
# sentinel GO_SYNTAX_ERR, and 0 otherwise. Prepended to PATH so `command -v gofmt` finds it.
STUBBIN="$T/stubbin"; mkdir -p "$STUBBIN"
cat > "$STUBBIN/gofmt" <<'GOFMT'
#!/usr/bin/env bash
# fake `gofmt -e <file>`: parse-only. Non-zero + stderr on a deliberate syntax error, else clean.
f="${!#}"
if grep -q 'GO_SYNTAX_ERR' "$f" 2>/dev/null; then
  printf '%s:2:1: expected declaration, found broken\n' "$f" >&2
  exit 2
fi
exit 0
GOFMT
chmod +x "$STUBBIN/gofmt"

clear_diff
printf 'package greet\n\nfunc Hello() string { return "hi" }\n' > "$WT/src/ok.go"
out="$(PATH="$STUBBIN:$PATH" run_hc)"; rc=$?
[ "$rc" -eq 0 ] || fail "(4) clean .go with gofmt present should exit 0 (got $rc): $out"
printf '%s' "$out" | grep -q 'go:.*gofmt -e ok' || fail "(4) clean .go should report 'go … gofmt -e ok' (got: $out)"
printf '%s' "$out" | grep -q 'LIGHT CHECK CLEAN' || fail "(4) clean sh/py/go should stay a confident clean (got: $out)"
ok
oneout="$(PATH="$STUBBIN:$PATH" run_hc --oneline)"; orc=$?
[ "$orc" -eq 0 ] || fail "(4) oneline clean .go should exit 0 (got $orc)"
printf '%s' "$oneout" | grep -q '1 go ok' || fail "(4) oneline should note '1 go ok' (got: $oneout)"
ok
clear_diff
printf 'package greet\n\nfunc broken( {  // GO_SYNTAX_ERR\n' > "$WT/src/bad.go"
out="$(PATH="$STUBBIN:$PATH" run_hc)"; rc=$?
[ "$rc" -eq 1 ] || fail "(4) a REAL .go parse error (gofmt present) must be caught red (exit 1, got $rc): $out"
printf '%s' "$out" | grep -q 'SYNTAX ERROR' || fail "(4) broken .go should report a SYNTAX ERROR (got: $out)"
printf '%s' "$out" | grep -qi 'gofmt' || fail "(4) broken .go error should cite gofmt (got: $out)"
ok

# ── (5) MISSING TOOLCHAIN — *.go with gofmt absent → data/env ⚠️, never red, never confident ✅ ──
# Curated PATH with a broad tool set but NO gofmt, so the "toolchain missing" branch is exercised
# deterministically even on hosts that ship gofmt.
CBIN="$T/cbin"; mkdir -p "$CBIN"
for c in bash sh git python3 python sed awk gawk sort uniq grep egrep fgrep tail head cat tr \
         basename dirname mktemp rm rmdir mkdir chmod chown env printf echo ls wc paste find \
         cut expr id date test true false touch cp mv ln readlink stat od dash which; do
  p="$(command -v "$c" 2>/dev/null)" && ln -sf "$p" "$CBIN/$c"   # gofmt is deliberately never linked
done
clear_diff
printf 'package greet\n\nfunc Hello() {}\n' > "$WT/src/nogofmt.go"
out="$(PATH="$CBIN" bash "$HC" "$WT" --light)"; rc=$?
[ "$rc" -eq 0 ] || fail "(5) missing gofmt is data/env, not a code error (exit 0, got $rc): $out"
printf '%s' "$out" | grep -q 'gofmt not found' || fail "(5) should surface 'gofmt not found' (got: $out)"
printf '%s' "$out" | grep -qi 'data/env'       || fail "(5) missing toolchain should read as data/env (got: $out)"
printf '%s' "$out" | grep -q 'LIGHT CHECK CLEAN' && fail "(5) MUST NOT claim a confident clean when it could not check the .go"
ok
oneout="$(PATH="$CBIN" bash "$HC" "$WT" --light --oneline)"; orc=$?
[ "$orc" -eq 0 ] || fail "(5) oneline missing-gofmt should exit 0 (got $orc)"
[ "$(nlines "$oneout")" -eq 1 ] || fail "(5) oneline must be exactly one line (got: $oneout)"
printf '%s' "$oneout" | grep -q '⚠️' || fail "(5) oneline missing-gofmt should carry a ⚠️ (got: $oneout)"
printf '%s' "$oneout" | grep -q '✅' && fail "(5) oneline must not claim ✅ when the .go went unchecked (got: $oneout)"
ok

echo "ALL PASS ($pass checks) — light-profile per-language probes flag the absence, never false-green."
