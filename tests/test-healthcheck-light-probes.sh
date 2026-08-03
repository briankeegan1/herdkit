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
#   (6) SHEBANG DISPATCH (HERD-505) — an EXTENSIONLESS file (bin/herd, a git hook) declares its
#       language in its first line, so the extension-keyed bucketing skipped it entirely and the
#       engine's own CLI went unprobed. Now: a broken extensionless bash script is caught RED, a
#       broken extensionless python script is caught RED, clean ones are counted in the sh/py
#       summary, and an interpreter with no dependency-free probe (perl/node/…), a file with no
#       shebang at all, and a dotted-but-unrecognized name all skip SILENTLY — byte-identical to the
#       pre-fix verdict, never red, never "unchecked". Removing the dispatch reds (6a)/(6b)/(6c).
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
grep -q 'SYNTAX ERROR' <<< "$out" || fail "(2) broken .sh should report a SYNTAX ERROR"
ok

# ── (3) FLAG-THE-ABSENCE — an unprobed-language-only diff is flagged ⚠️, never a confident ✅ ──
clear_diff
printf 'fn main() {}\n'                 > "$WT/src/lib.rs"
printf 'pub fn also() {}\n'             > "$WT/src/more.rs"
printf 'class A {}\n'                   > "$WT/src/A.java"
out="$(run_hc)"; rc=$?
[ "$rc" -eq 0 ] || fail "(3) unprobed-only diff is a warning, not a code error (exit 0, got $rc): $out"
grep -q 'UNCHECKED FILE TYPES' <<< "$out" || fail "(3) should flag UNCHECKED FILE TYPES (got: $out)"
grep -q 'no light probe' <<< "$out" || fail "(3) should say 'no light probe' (got: $out)"
grep -q '2 rs' <<< "$out" || fail "(3) should count 2 rs files (got: $out)"
grep -q '1 java' <<< "$out" || fail "(3) should count 1 java file (got: $out)"
grep -q 'LIGHT CHECK CLEAN' <<< "$out" && fail "(3) MUST NOT emit a confident '✅ LIGHT CHECK CLEAN' for unchecked types"
ok
oneout="$(run_hc --oneline)"; orc=$?
[ "$orc" -eq 0 ] || fail "(3) oneline unchecked should exit 0 (got $orc)"
[ "$(nlines "$oneout")" -eq 1 ] || fail "(3) oneline must be exactly one line (got: $oneout)"
grep -q '⚠️' <<< "$oneout" || fail "(3) oneline should carry a ⚠️ (got: $oneout)"
grep -q 'no light probe' <<< "$oneout" || fail "(3) oneline should say 'no light probe' (got: $oneout)"
grep -q '✅' <<< "$oneout" && fail "(3) oneline must not claim ✅ for unchecked types (got: $oneout)"
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
grep -q 'go:.*gofmt -e ok' <<< "$out" || fail "(4) clean .go should report 'go … gofmt -e ok' (got: $out)"
grep -q 'LIGHT CHECK CLEAN' <<< "$out" || fail "(4) clean sh/py/go should stay a confident clean (got: $out)"
ok
oneout="$(PATH="$STUBBIN:$PATH" run_hc --oneline)"; orc=$?
[ "$orc" -eq 0 ] || fail "(4) oneline clean .go should exit 0 (got $orc)"
grep -q '1 go ok' <<< "$oneout" || fail "(4) oneline should note '1 go ok' (got: $oneout)"
ok
clear_diff
printf 'package greet\n\nfunc broken( {  // GO_SYNTAX_ERR\n' > "$WT/src/bad.go"
out="$(PATH="$STUBBIN:$PATH" run_hc)"; rc=$?
[ "$rc" -eq 1 ] || fail "(4) a REAL .go parse error (gofmt present) must be caught red (exit 1, got $rc): $out"
grep -q 'SYNTAX ERROR' <<< "$out" || fail "(4) broken .go should report a SYNTAX ERROR (got: $out)"
grep -qi 'gofmt' <<< "$out" || fail "(4) broken .go error should cite gofmt (got: $out)"
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
grep -q 'gofmt not found' <<< "$out" || fail "(5) should surface 'gofmt not found' (got: $out)"
grep -qi 'data/env' <<< "$out" || fail "(5) missing toolchain should read as data/env (got: $out)"
grep -q 'LIGHT CHECK CLEAN' <<< "$out" && fail "(5) MUST NOT claim a confident clean when it could not check the .go"
ok
oneout="$(PATH="$CBIN" bash "$HC" "$WT" --light --oneline)"; orc=$?
[ "$orc" -eq 0 ] || fail "(5) oneline missing-gofmt should exit 0 (got $orc)"
[ "$(nlines "$oneout")" -eq 1 ] || fail "(5) oneline must be exactly one line (got: $oneout)"
grep -q '⚠️' <<< "$oneout" || fail "(5) oneline missing-gofmt should carry a ⚠️ (got: $oneout)"
grep -q '✅' <<< "$oneout" && fail "(5) oneline must not claim ✅ when the .go went unchecked (got: $oneout)"
ok

# ── (6) SHEBANG DISPATCH — extensionless files are classified by their first line (HERD-505) ─────
# (6a) a broken extensionless BASH script is caught red, exactly like a broken *.sh.
clear_diff
printf '#!/usr/bin/env bash\nif then fi\n' > "$WT/src/herdlike"; chmod +x "$WT/src/herdlike"
out="$(run_hc)"; rc=$?
[ "$rc" -eq 1 ] || fail "(6a) broken extensionless bash script must be caught red (exit 1, got $rc): $out"
grep -q 'SYNTAX ERROR' <<< "$out" || fail "(6a) broken extensionless bash should report a SYNTAX ERROR (got: $out)"
grep -q 'bash -n .*herdlike' <<< "$out" || fail "(6a) the error should cite 'bash -n <file>' (got: $out)"
ok

# (6b) a CLEAN extensionless bash script passes and is counted in the shell bucket (not ignored).
clear_diff
printf '#!/bin/sh\nexec echo hi "$@"\n' > "$WT/src/hook"; chmod +x "$WT/src/hook"
out="$(run_hc)"; rc=$?
[ "$rc" -eq 0 ] || fail "(6b) clean extensionless sh script should exit 0 (got $rc): $out"
grep -q 'LIGHT CHECK CLEAN' <<< "$out" || fail "(6b) clean extensionless sh should be a confident clean (got: $out)"
grep -q 'shell:  1 changed' <<< "$out" || fail "(6b) extensionless sh must be COUNTED in the shell bucket, not ignored (got: $out)"
ok

# (6c) a broken extensionless PYTHON script is caught red by the py_compile probe.
if [ -n "$(command -v python3 || true)" ]; then
  clear_diff
  printf '#!/usr/bin/env -S python3 -u\ndef broken(:\n' > "$WT/src/pytool"; chmod +x "$WT/src/pytool"
  out="$(run_hc)"; rc=$?
  [ "$rc" -eq 1 ] || fail "(6c) broken extensionless python script must be caught red (exit 1, got $rc): $out"
  grep -q 'SYNTAX ERROR' <<< "$out" || fail "(6c) broken extensionless python should report a SYNTAX ERROR (got: $out)"
  grep -q 'py_compile .*pytool' <<< "$out" || fail "(6c) the error should cite 'py_compile <file>' (got: $out)"
  ok
fi

# (6d) FAIL-SOFT — an interpreter with no dependency-free probe, and a file with no shebang at all,
# skip SILENTLY: no red, no "unchecked" flag, and the verdict is byte-identical to the pre-fix one.
clear_diff
printf '#!/usr/bin/perl\nthis is (not perl at all\n'   > "$WT/src/perltool"; chmod +x "$WT/src/perltool"
printf '#!/usr/bin/env node\nfunction ( broken {\n'    > "$WT/src/nodetool"; chmod +x "$WT/src/nodetool"
printf 'plain data, no shebang, if then fi\n'          > "$WT/src/NOTICE"
out="$(run_hc)"; rc=$?
[ "$rc" -eq 0 ] || fail "(6d) unknown-interpreter/no-shebang files must never red (exit 0, got $rc): $out"
exp="$(printf '✅ LIGHT CHECK CLEAN (non-heavy change)\n   shell:  0 changed *.sh — bash -n ok\n   python: 0 changed *.py — py_compile ok')"
[ "$out" = "$exp" ] || fail "(6d) verdict must be byte-identical to the pre-fix skip; got:
$out"
ok

# (6e) BYTE-IDENTICAL — an extensioned but unrecognized file (docs/JSON/config) is still ignored,
# and is never sent through the shebang path even when it carries a shebang-looking first line.
clear_diff
printf '#!/usr/bin/env bash\nif then fi\n' > "$WT/src/notes.md"
printf '{ "a": 1 }\n'                     > "$WT/src/data.json"
out="$(run_hc)"; rc=$?
[ "$rc" -eq 0 ] || fail "(6e) unrecognized extensions must stay ignored (exit 0, got $rc): $out"
[ "$out" = "$exp" ] || fail "(6e) verdict must be byte-identical to the pre-fix skip; got:
$out"
ok
oneout="$(run_hc --oneline)"; orc=$?
[ "$orc" -eq 0 ] || fail "(6e) oneline should exit 0 (got $orc)"
[ "$oneout" = "✅ light clean — 0 sh, 0 py ok" ] || fail "(6e) oneline not byte-identical (got: $oneout)"
ok

echo "ALL PASS ($pass checks) — light-profile per-language probes flag the absence, never false-green."
