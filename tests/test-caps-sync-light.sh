#!/usr/bin/env bash
# test-caps-sync-light.sh — hermetic tests for the SHARED caps-sync guard (HERD-220):
# scripts/herd/caps-sync-lint.sh, called from BOTH the heavy project gate and the LIGHT profile of
# scripts/herd/healthcheck.sh.
#
# The guard used to live only in .herd/healthcheck.project.sh, so a builder whose light pre-PR gate
# passed still bounced off the authoritative merge gate for a missing templates/capabilities.tsv row
# (incident: PR #328). These assert the light profile now carries the same red:
#   (1) VIOLATION — a committed new scripts/herd/x.sh with NO manifest touch → exit 1 + CAPS-SYNC
#       (full mode and --oneline, which must stay exactly one line).
#   (2) SATISFIED — the same diff WITH templates/capabilities.tsv touched → clean, exit 0.
#   (3) BYTE-IDENTICAL — a diff touching no engine surface emits the exact pre-HERD-220 light verdict.
#   (4) cmd_* / config-key surfaces — bin/herd growing a cmd_*, and herd-config.sh growing a key,
#       are each red without a manifest touch (the other two arms of the shared lint).
#   (5) FAIL-SOFT — a tree with no templates/capabilities.tsv (i.e. every consuming project) SKIPS:
#       clean, never red, and the verdict is unchanged.
#   (6) FAIL-SOFT (infra) — an engine tree missing the lint SKIPS the guard, never breaks the run.
#   (7) ONE IMPLEMENTATION — the light profile owns no grep of its own; both gates source the lib.
#
# Network-free: a temp git repo + temp config via HERD_CONFIG_FILE. No $HEALTHCHECK_CMD is set, so
# the profile resolves to light on its own; --light is passed to be explicit.
# Run:  bash tests/test-caps-sync-light.sh
# No `set -e`: several checks assert non-zero returns explicitly.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
HC="$ROOT/scripts/herd/healthcheck.sh"
LIB="$ROOT/scripts/herd/caps-sync-lint.sh"
[ -f "$HC" ]  || { echo "healthcheck.sh not found at $HC" >&2; exit 1; }
[ -f "$LIB" ] || { echo "caps-sync-lint.sh not found at $LIB" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "git required to run this test" >&2; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }
nlines() { printf '%s\n' "$1" | grep -c .; }

WT="$T/wt"
CFG="$T/config"
export HERD_CONFIG_FILE="$CFG"
cat > "$CFG" <<CFGEOF
PROJECT_ROOT="$WT"
WORKTREES_DIR="$T/trees"
DEFAULT_BRANCH="main"
WORKSPACE_NAME="ctest"
CFGEOF

git_wt() { git -C "$WT" "$@"; }
run_hc() { bash "$HC" "$WT" --light "$@"; }

# ── a repo shaped like herdkit's engine tree: bin/herd, herd-config.sh, the manifest ──────────
# `reset_repo <with-manifest|no-manifest>` rebuilds it from scratch on 'main', then checks out a
# feature branch so every case starts from an identical, committed base.
reset_repo() {
  rm -rf "$WT"; mkdir -p "$WT/bin" "$WT/scripts/herd" "$WT/templates" "$WT/docs"
  git_wt init -q
  git_wt checkout -q -b main 2>/dev/null || git_wt checkout -q main
  git_wt config user.email t@t.test
  git_wt config user.name  herd-test
  printf '#!/usr/bin/env bash\ncmd_status() { echo hi; }\n'      > "$WT/bin/herd"
  printf '#!/usr/bin/env bash\n: "${EXISTING_KEY:=on}"\n'        > "$WT/scripts/herd/herd-config.sh"
  printf '# a doc\n'                                             > "$WT/docs/notes.md"
  [ "$1" = "with-manifest" ] && printf 'name\tkind\n' > "$WT/templates/capabilities.tsv"
  git_wt add -A; git_wt commit -qm seed
  git_wt checkout -q -b feat/x
}

touch_manifest() { printf 'newthing\tlane\n' >> "$WT/templates/capabilities.tsv"; }
commit_all()     { git_wt add -A; git_wt commit -qm change; }

# ── (1) VIOLATION — a new lane script, no manifest touch → red ────────────────────────────────
reset_repo with-manifest
printf '#!/usr/bin/env bash\necho lane\n' > "$WT/scripts/herd/x.sh"
commit_all
out="$(run_hc)"; rc=$?
[ "$rc" -eq 1 ] || fail "(1) new scripts/herd/x.sh with no manifest touch must be red (exit 1, got $rc): $out"
printf '%s' "$out" | grep -q 'CAPS-SYNC' || fail "(1) should emit the CAPS-SYNC headline (got: $out)"
printf '%s' "$out" | grep -q 'new lane script added' || fail "(1) should name the offending surface (got: $out)"
printf '%s' "$out" | grep -q 'LIGHT CHECK CLEAN' && fail "(1) must not also claim a clean light verdict"
ok
oneout="$(run_hc --oneline)"; orc=$?
[ "$orc" -eq 1 ] || fail "(1) oneline violation must exit 1 (got $orc)"
[ "$(nlines "$oneout")" -eq 1 ] || fail "(1) oneline must be exactly one line (got: $oneout)"
printf '%s' "$oneout" | grep -q 'caps-sync' || fail "(1) oneline should name caps-sync (got: $oneout)"
printf '%s' "$oneout" | grep -q '❌' || fail "(1) oneline should carry a ❌ (got: $oneout)"
ok

# ── (2) SATISFIED — the same diff, manifest touched → clean ───────────────────────────────────
reset_repo with-manifest
printf '#!/usr/bin/env bash\necho lane\n' > "$WT/scripts/herd/x.sh"
touch_manifest
commit_all
out="$(run_hc)"; rc=$?
[ "$rc" -eq 0 ] || fail "(2) new lane script WITH a manifest touch must be clean (exit 0, got $rc): $out"
printf '%s' "$out" | grep -q 'CAPS-SYNC' && fail "(2) a satisfied guard must print nothing (got: $out)"
printf '%s' "$out" | grep -q 'LIGHT CHECK CLEAN' || fail "(2) should be a confident light clean (got: $out)"
ok

# ── (3) BYTE-IDENTICAL — a diff touching no engine surface reads exactly as it did pre-HERD-220 ─
reset_repo with-manifest
printf 'more docs\n' >> "$WT/docs/notes.md"
printf 'echo hi\n'    > "$WT/docs/tool.sh"     # a *.sh outside the engine surface: syntax-checked only
commit_all
out="$(run_hc)"; rc=$?
[ "$rc" -eq 0 ] || fail "(3) a non-engine diff must stay clean (exit 0, got $rc): $out"
exp="$(printf '✅ LIGHT CHECK CLEAN (non-heavy change)\n   shell:  1 changed *.sh — bash -n ok\n   python: 0 changed *.py — py_compile ok')"
[ "$out" = "$exp" ] || fail "(3) full light output not byte-identical to the pre-HERD-220 verdict; got:
$out"
ok
oneout="$(run_hc --oneline)"; orc=$?
[ "$orc" -eq 0 ] || fail "(3) oneline non-engine diff should exit 0 (got $orc)"
[ "$oneout" = "✅ light clean — 1 sh, 0 py ok" ] || fail "(3) oneline not byte-identical (got: $oneout)"
ok

# ── (4) the other two arms: a new cmd_* in bin/herd, a new key in herd-config.sh ───────────────
reset_repo with-manifest
printf 'cmd_brandnew() { echo new; }\n' >> "$WT/bin/herd"
commit_all
out="$(run_hc)"; rc=$?
[ "$rc" -eq 1 ] || fail "(4) bin/herd adding a cmd_* with no manifest touch must be red (got $rc): $out"
printf '%s' "$out" | grep -q 'bin/herd adds cmd_\*' || fail "(4) should name the cmd_* surface (got: $out)"
ok
touch_manifest; commit_all
out="$(run_hc)"; rc=$?
[ "$rc" -eq 0 ] || fail "(4) bin/herd cmd_* WITH a manifest touch must be clean (got $rc): $out"
ok

reset_repo with-manifest
printf ': "${BRAND_NEW_KEY:=off}"\n' >> "$WT/scripts/herd/herd-config.sh"
commit_all
out="$(run_hc)"; rc=$?
[ "$rc" -eq 1 ] || fail "(4) herd-config.sh adding a key with no manifest touch must be red (got $rc): $out"
printf '%s' "$out" | grep -q 'herd-config.sh adds config keys' || fail "(4) should name the config-key surface (got: $out)"
ok
touch_manifest; commit_all
out="$(run_hc)"; rc=$?
[ "$rc" -eq 0 ] || fail "(4) herd-config.sh key WITH a manifest touch must be clean (got $rc): $out"
ok

# ── (5) FAIL-SOFT — no capabilities manifest in the tree (every consuming project) → skip ──────
reset_repo no-manifest
printf '#!/usr/bin/env bash\necho lane\n' > "$WT/scripts/herd/x.sh"
commit_all
out="$(run_hc)"; rc=$?
[ "$rc" -eq 0 ] || fail "(5) a tree with no capabilities manifest must SKIP, never red (exit 0, got $rc): $out"
printf '%s' "$out" | grep -q 'CAPS-SYNC' && fail "(5) the skip must be silent (got: $out)"
printf '%s' "$out" | grep -q 'LIGHT CHECK CLEAN' || fail "(5) verdict should be the plain light clean (got: $out)"
ok
# The lib says WHY it skipped, so the heavy caller can render an honest note.
skip_reason="$(cd "$WT" && . "$LIB" && herd_caps_sync_lint main >/dev/null; printf '%s' "$HERD_CAPS_SYNC_SKIP_REASON")"
printf '%s' "$skip_reason" | grep -q 'capabilities.tsv' || fail "(5) skip reason should cite the missing manifest (got: $skip_reason)"
ok
# An unresolvable base ref is infra, not a code error: skip with a reason, exit 2.
reset_repo with-manifest
printf '#!/usr/bin/env bash\necho lane\n' > "$WT/scripts/herd/x.sh"
commit_all
( cd "$WT" && . "$LIB" && herd_caps_sync_lint no/such/ref >/dev/null 2>&1 )
[ "$?" -eq 2 ] || fail "(5) an unresolvable base ref must return 2 (skip), never 1"
ok

# ── (6) FAIL-SOFT ON OUR OWN INFRA — an engine tree missing the lint SKIPS, never breaks ──────
# A partially-upgraded engine (healthcheck.sh present, caps-sync-lint.sh not) must still run: the
# guard skips. Caught live — the first cut of this change sourced the lib by a path that does not
# exist in the fixture worktrees the project-gate tests drive, reddening tests/herd.bats.
reset_repo with-manifest
printf '#!/usr/bin/env bash\necho lane\n' > "$WT/scripts/herd/x.sh"
commit_all
NOLIB="$T/nolib"; mkdir -p "$NOLIB"
cp "$ROOT/scripts/herd/healthcheck.sh" "$ROOT/scripts/herd/herd-config.sh" \
   "$ROOT/scripts/herd/commit-lint.sh" "$NOLIB/"      # caps-sync-lint.sh deliberately not copied
out="$(bash "$NOLIB/healthcheck.sh" "$WT" --light 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || fail "(6) healthcheck.sh without caps-sync-lint.sh must skip the guard, not break (exit 0, got $rc): $out"
printf '%s' "$out" | grep -qi 'not found\|No such file' && fail "(6) missing lint must not leak a shell error (got: $out)"
printf '%s' "$out" | grep -q 'LIGHT CHECK CLEAN' || fail "(6) verdict should be the plain light clean (got: $out)"
ok

# ── (7) ONE IMPLEMENTATION — both gates source the lib; neither re-greps the rule ──────────────
grep -q 'caps-sync-lint.sh' "$ROOT/scripts/herd/healthcheck.sh" \
  || fail "(7) healthcheck.sh must source scripts/herd/caps-sync-lint.sh"
grep -q 'caps-sync-lint.sh' "$ROOT/.herd/healthcheck.project.sh" \
  || fail "(7) .herd/healthcheck.project.sh must source scripts/herd/caps-sync-lint.sh"
for f in "$ROOT/scripts/herd/healthcheck.sh" "$ROOT/.herd/healthcheck.project.sh"; do
  grep -q 'diff-filter=A' "$f" && fail "(7) $f still carries its own caps-sync grep (duplicated logic)"
done
ok

echo "ALL PASS ($pass checks) — the caps-sync guard is one shared lint, enforced by the light gate too."
