#!/usr/bin/env bash
# test-git-scope-lint.sh — hermetic tests for the shared engine/project ISOLATION guard (HERD-435,
# GitHub issue #547): scripts/herd/git-scope-lint.sh reds repo-wide staging (`git add -A|.|-u`,
# `git commit -a`) or an unscoped `git commit` in a PRODUCTION engine path, while leaving the sim /
# test fixture paths — which legitimately `git add -A` throwaway temp repos — clean.
#
# Proves:
#   (1)  The REAL tree is clean: every production git staging/commit site is named, pathspec-scoped,
#        or carries an explicit '# herd-scope-ok' rationale.
#   (2)  REPO-WIDE staging REDS in a production path: `git add -A`, `git add .`, `git add -u`.
#   (3)  `git commit -a` / `-am` REDS (a short-option cluster is caught; `--amend` is NOT).
#   (4)  An UNSCOPED `git commit` (no `-- <pathspec>`) REDS; the same commit WITH `-- path` is clean.
#   (5)  SIM/FIXTURE PATHS STAY CLEAN: the identical `git add -A` under scripts/herd/sim/,
#        scripts/herd/experiment/ or tests/ is classified, counted, and never flagged.
#   (6)  '# herd-scope-ok' opts out — on the offending line, anywhere in a '\'-continued command, or
#        on the contiguous comment run directly above the command.
#   (7)  NAMED staging is never flagged: `git add -- "$f"`, `git add "$f"`, `git commit … -- "$f"`.
#   (8)  Sibling git subcommands that merely contain the word `add` (`git worktree add`,
#        `git remote add`, `git submodule add`) are not mistaken for staging.
#   (9)  PROSE is not mistaken for a call: `die "git commit failed at $path"` is clean.
#  (10)  The PYTHON engine core is covered: the argv-list form `["git", …, "add", "-A"]` reds, and
#        `["git", …, "commit", …, "--"] + paths` is clean — including when the `"--"` wraps onto the
#        next physical line.
#  (11)  FAIL-SOFT: a tree with no engine surface → skip (exit 2), never a red.
#  (12)  BYTE-IDENTICAL when clean: a clean fixture emits zero GIT-SCOPE lines, only the ADVISORY.
#
# Network-free: temp dirs + fixtures only. Run:  bash tests/test-git-scope-lint.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LINT="$ROOT/scripts/herd/git-scope-lint.sh"

[ -f "$LINT" ] || { echo "FAIL: missing lint: $LINT" >&2; exit 1; }
# shellcheck source=/dev/null
. "$LINT"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { PASS=$((PASS+1)); }

# make_file <dir> <relpath> <body...> — write an engine-surface file with the given trailing lines.
make_file() {
  local d="$1" rel="$2"; shift 2
  mkdir -p "$d/$(dirname "$rel")"
  { printf '#!/usr/bin/env bash\n'; printf '%s\n' "$@"; } > "$d/$rel"
}

# ── 1. Real tree is clean ─────────────────────────────────────────────────────────────────────────
real_out="$(herd_git_scope_lint "$ROOT")"; real_rc=$?
if [ "$real_rc" -ne 0 ]; then
  grep '^GIT-SCOPE' <<< "$real_out" >&2
  fail "(1) real tree has unscoped engine git ops — name the paths, or annotate '# herd-scope-ok: <why>'"
fi
grep -q '^GIT-SCOPE' <<< "$real_out" && fail "(1) GIT-SCOPE lines present despite a clean exit"
grep -q '^ADVISORY:' <<< "$real_out" || fail "(1) advisory summary line missing"
grep -qE 'ADVISORY:.*[1-9][0-9]* fixture file' <<< "$real_out" \
  || fail "(1) the real tree's sim/test fixtures must be scanned and counted, not silently unscanned"
pass
echo "PASS (1) real tree: every production git staging/commit site is scoped or annotated"

# ── 2. Repo-wide staging reds ─────────────────────────────────────────────────────────────────────
for sel in '-A' '.' '-u' '--all'; do
  TW="$T/wide$$-${sel//[^a-z-]/x}"; rm -rf "$TW"
  make_file "$TW" scripts/herd/probe.sh "git -C \"\$d\" add $sel"
  out="$(herd_git_scope_lint "$TW")"; rc=$?
  [ "$rc" -eq 1 ] || fail "(2) 'git add $sel' in a production path must red (exit 1, got $rc): $out"
  grep -q 'GIT-SCOPE .*probe.sh:2: REPO-WIDE staging' <<< "$out" \
    || fail "(2) 'git add $sel' should be classed REPO-WIDE staging (got: $out)"
done

# …and the selector must still be caught when a command TERMINATOR follows it rather than
# whitespace/EOL. `{ git add -A; }` on one line is the commonest real shape and slipped through an
# earlier draft of the grammar (caught in HERD-435's own gate verification, before landing).
TT="$T/terminator"; make_file "$TT" scripts/herd/probe.sh \
  '_probe() { git -C "$PROJECT_ROOT" add -A; }' \
  '_probe2() { git -C "$d" commit -am x; }' \
  '( git add . )'
out="$(herd_git_scope_lint "$TT")"; rc=$?
[ "$rc" -eq 1 ] || fail "(2) a selector followed by ';' or ')' must still red (exit 1, got $rc): $out"
for ln in 2 3 4; do
  grep -q "probe.sh:$ln:" <<< "$out" || fail "(2) line $ln (terminator-followed selector) must be flagged (got: $out)"
done
pass
echo "PASS (2) 'git add -A/./-u/--all' → red as REPO-WIDE staging, including when a ';' or ')' follows"

# ── 3. commit -a reds; --amend does not ───────────────────────────────────────────────────────────
TCA="$T/commitall"; make_file "$TCA" scripts/herd/probe.sh 'git commit -am "sweep"'
out="$(herd_git_scope_lint "$TCA")"; rc=$?
[ "$rc" -eq 1 ] || fail "(3) 'git commit -am' must red (exit 1, got $rc): $out"
grep -q 'REPO-WIDE commit' <<< "$out" || fail "(3) 'git commit -am' should be classed REPO-WIDE commit (got: $out)"
TAM="$T/amend"; make_file "$TAM" scripts/herd/probe.sh 'git commit --amend --no-edit -- path/to/f'
out="$(herd_git_scope_lint "$TAM")"; rc=$?
[ "$rc" -eq 0 ] || fail "(3) 'git commit --amend … -- path' must be clean (exit 0, got $rc): $out"
pass
echo "PASS (3) 'git commit -am' → red (REPO-WIDE commit); a scoped '--amend' is not"

# ── 4. Unscoped commit reds; the same commit with a pathspec is clean ─────────────────────────────
TU="$T/unscoped"; make_file "$TU" scripts/herd/probe.sh 'git -C "$MAIN" commit -q -m "$msg"'
out="$(herd_git_scope_lint "$TU")"; rc=$?
[ "$rc" -eq 1 ] || fail "(4) a commit with no pathspec must red (exit 1, got $rc): $out"
grep -q 'UNSCOPED commit' <<< "$out" || fail "(4) should be classed UNSCOPED commit (got: $out)"
TS="$T/scoped"; make_file "$TS" scripts/herd/probe.sh 'git -C "$MAIN" commit -q -m "$msg" -- "$out"'
out="$(herd_git_scope_lint "$TS")"; rc=$?
[ "$rc" -eq 0 ] || fail "(4) the same commit WITH '-- <path>' must be clean (exit 0, got $rc): $out"
pass
echo "PASS (4) unscoped 'git commit' → red; the pathspec-scoped form (the watcher's reconcile shape) → clean"

# ── 5. Sim / experiment / tests fixtures stay clean ──────────────────────────────────────────────
for rel in scripts/herd/sim/fixture.sh scripts/herd/experiment/fixture.sh tests/test-fixture.sh; do
  TFX="$T/fixture$$"; rm -rf "$TFX"
  make_file "$TFX" scripts/herd/real.sh 'git add -- "$f"'          # a production file, so the scan runs
  make_file "$TFX" "$rel" 'git -C "$tmp" add -A' 'git -C "$tmp" commit -qm seed'
  out="$(herd_git_scope_lint "$TFX")"; rc=$?
  [ "$rc" -eq 0 ] || fail "(5) '$rel' is a throwaway-repo fixture and must stay clean (exit 0, got $rc): $out"
  grep -q 'GIT-SCOPE' <<< "$out" && fail "(5) '$rel' must not be flagged (got: $out)"
  grep -qE 'ADVISORY:.*1 fixture file\(s\) skipped' <<< "$out" \
    || fail "(5) '$rel' must be COUNTED as a classified fixture, not silently unscanned (got: $out)"
done
pass
echo "PASS (5) sim/ · experiment/ · tests/ fixtures: same 'git add -A' classified FIXTURE, never flagged"

# ── 6. '# herd-scope-ok' opts out (inline · continued block · comment above) ──────────────────────
TA1="$T/annot-inline"; make_file "$TA1" scripts/herd/probe.sh 'git add -A  # herd-scope-ok: throwaway repo'
out="$(herd_git_scope_lint "$TA1")"; rc=$?
[ "$rc" -eq 0 ] || fail "(6) an inline-annotated line must be clean (exit 0, got $rc): $out"
grep -qE 'ADVISORY:.*1 opted-out' <<< "$out" || fail "(6) advisory should count 1 opted-out (got: $out)"

TA2="$T/annot-block"; mkdir -p "$TA2/scripts/herd"
{
  printf '#!/usr/bin/env bash\n'
  printf '( cd "$p" && git commit -q -m "seed" ) \\\n'
  printf '  || die "failed"  # herd-scope-ok: index-scoped, the named add above is all that is staged\n'
} > "$TA2/scripts/herd/probe.sh"
out="$(herd_git_scope_lint "$TA2")"; rc=$?
[ "$rc" -eq 0 ] || fail "(6) an annotation on any line of a '\\'-continued command must opt it out (exit 0, got $rc): $out"

TA3="$T/annot-above"; make_file "$TA3" scripts/herd/probe.sh \
  '# herd-scope-ok: index-scoped — the named add above stages only the backlog file' \
  'git commit -q -m "Backlog: $sum"'
out="$(herd_git_scope_lint "$TA3")"; rc=$?
[ "$rc" -eq 0 ] || fail "(6) an annotation on the comment line ABOVE must opt the command out (exit 0, got $rc): $out"

# …and WITHOUT the annotation the very same code reds — prove the opt-out, not a matching miss.
TA4="$T/annot-bare"; make_file "$TA4" scripts/herd/probe.sh 'git commit -q -m "Backlog: $sum"'
out="$(herd_git_scope_lint "$TA4")"; rc=$?
[ "$rc" -eq 1 ] || fail "(6) the same command WITHOUT '# herd-scope-ok' must red (exit 1, got $rc): $out"
pass
echo "PASS (6) '# herd-scope-ok' opts out inline · across a continued command · from the comment above"

# ── 7. Named staging is never flagged ─────────────────────────────────────────────────────────────
TN="$T/named"; make_file "$TN" scripts/herd/probe.sh \
  'git add -- "${commit_paths[@]}"' \
  'git add "$BACKLOG_FILE"' \
  'git add .herd/config' \
  'git -C "$MAIN" commit -q -m "$msg" -- "$rc_out"'
out="$(herd_git_scope_lint "$TN")"; rc=$?
[ "$rc" -eq 0 ] || fail "(7) named staging + pathspec commit must be clean (exit 0, got $rc): $out"
pass
echo "PASS (7) named staging ('git add -- \"\$f\"', 'git add .herd/config') → not flagged"

# ── 8. Sibling subcommands containing the word 'add' are not staging ─────────────────────────────
TSUB="$T/subcmds"; make_file "$TSUB" scripts/herd/probe.sh \
  'git -C "$MAIN" worktree add "$dir" "$branch"' \
  'git -C "$path" remote add origin "$url"' \
  'git submodule add "$url" vendor/x'
out="$(herd_git_scope_lint "$TSUB")"; rc=$?
[ "$rc" -eq 0 ] || fail "(8) 'git worktree/remote/submodule add' must not be read as staging (exit 0, got $rc): $out"
pass
echo "PASS (8) 'git worktree add' / 'git remote add' / 'git submodule add' → not staging, not flagged"

# ── 9. Prose naming the command is not a call ────────────────────────────────────────────────────
TP="$T/prose"; make_file "$TP" scripts/herd/probe.sh \
  '|| die "git commit failed at $path"' \
  'warn "run git add yourself"'
out="$(herd_git_scope_lint "$TP")"; rc=$?
[ "$rc" -eq 0 ] || fail "(9) prose naming git commit/add must not red (exit 0, got $rc): $out"
pass
echo "PASS (9) 'die \"git commit failed at \$path\"' → prose, not a call, not flagged"

# ── 10. The python engine core (argv-list form) is covered ───────────────────────────────────────
TPY="$T/py"; mkdir -p "$TPY/pysrc/herd"
{
  printf 'import subprocess\n'
  printf 'subprocess.run(["git", "-C", main, "add", "-A"])\n'
} > "$TPY/pysrc/herd/probe.py"
out="$(herd_git_scope_lint "$TPY")"; rc=$?
[ "$rc" -eq 1 ] || fail "(10) the python argv form of 'git add -A' must red (exit 1, got $rc): $out"
grep -q 'probe.py:2: REPO-WIDE staging' <<< "$out" || fail "(10) python 'add','-A' should be REPO-WIDE (got: $out)"

TPY2="$T/py-ok"; mkdir -p "$TPY2/pysrc/herd"
{
  printf 'import subprocess\n'
  printf 'subprocess.run(["git", "-C", main, "add", "--"] + paths)\n'
  printf 'subprocess.run(["git", "-C", main, "commit", "-q", "-m", msg,\n'
  printf '                "--"] + paths)\n'
} > "$TPY2/pysrc/herd/probe.py"
out="$(herd_git_scope_lint "$TPY2")"; rc=$?
[ "$rc" -eq 0 ] || fail "(10) the scoped python argv form (incl. a wrapped '--') must be clean (exit 0, got $rc): $out"
pass
echo "PASS (10) python argv form: 'add','-A' reds; 'commit',…,'--' (even wrapped) is clean"

# ── 11. Fail-soft: a CONSUMING project skips, never reds ─────────────────────────────────────────
TNS="$T/nosurface"; mkdir -p "$TNS/somewhere"
printf 'git add -A\n' > "$TNS/somewhere/thing.sh"
HERD_GIT_SCOPE_SKIP_REASON=""
herd_git_scope_lint "$TNS" >/dev/null 2>&1; skip_rc=$?
[ "$skip_rc" -eq 2 ] || fail "(11) a tree with no engine surface → skip (exit 2, got $skip_rc)"
[ -n "${HERD_GIT_SCOPE_SKIP_REASON:-}" ] || fail "(11) HERD_GIT_SCOPE_SKIP_REASON must be set on skip"

# A consuming project may own an install.sh / scripts/ci that stages however it likes — those are ITS
# files, not the engine's. Without a scripts/herd, pysrc/herd or bin/herd marker the scan must not run
# at all, so this guard can never red someone else's repo.
TCONS="$T/consumer"; mkdir -p "$TCONS/scripts/ci" "$TCONS/app"
printf 'git add -A && git commit -am "release"\n' > "$TCONS/install.sh"
printf 'git add .\n' > "$TCONS/scripts/ci/publish.sh"
out="$(herd_git_scope_lint "$TCONS" 2>&1)"; cons_rc=$?
[ "$cons_rc" -eq 2 ] || fail "(11) a CONSUMING project (no engine marker) must skip, not red (exit 2, got $cons_rc): $out"
grep -q 'GIT-SCOPE' <<< "$out" && fail "(11) a consumer's own install.sh/scripts/ci must never be flagged (got: $out)"
# Re-run OUTSIDE a command substitution: the skip reason is set in the caller's shell, and a $( )
# subshell would discard it.
HERD_GIT_SCOPE_SKIP_REASON=""
herd_git_scope_lint "$TCONS" >/dev/null 2>&1
[ -n "${HERD_GIT_SCOPE_SKIP_REASON:-}" ] || fail "(11) the consumer skip must carry a reason"
pass
echo "PASS (11) a consuming project (its own install.sh / scripts/ci) → skip (exit 2), never a red"

# ── 12. Byte-identical-clean: a clean fixture emits only the ADVISORY ────────────────────────────
TC="$T/clean"; make_file "$TC" scripts/herd/probe.sh 'git add -- "$f" && git commit -q -m x -- "$f"'
out="$(herd_git_scope_check "$TC/scripts/herd/probe.sh")"; rc=$?
[ "$rc" -eq 0 ] || fail "(12) a clean fixture must exit 0 (got $rc): $out"
[ "$(grep -c '^GIT-SCOPE' <<< "$out")" -eq 0 ] || fail "(12) clean fixture must emit zero GIT-SCOPE lines (got: $out)"
grep -qE '^ADVISORY: 0 unscoped git op' <<< "$out" || fail "(12) clean advisory must report 0 (got: $out)"
pass
echo "PASS (12) clean fixture → only the ADVISORY summary, zero GIT-SCOPE lines"

echo
echo "ALL PASS ($PASS checks) — engine/project isolation is ENFORCED: repo-wide staging reds in production paths, sim fixtures stay clean."
