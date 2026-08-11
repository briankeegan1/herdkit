#!/usr/bin/env bash
# test-write-fence-tripwire.sh — HERD-637: proves the CHECKOUT UNCLEAN incident mechanism is real, and
# that the fix (scripts/herd/git-scope-lint.sh's new CWD-RELIANT class, see git-scope-lint.sh's header)
# catches the shape statically before it can land.
#
# GROUNDED incident (2026-08-11, evidence at .checkout-contamination-2026-08-11.patch): six files were
# found STAGED in the shared $MAIN checkout with pre-PR-743 content, staged between PR #742's merge
# (23:43Z) and PR #743's (00:10Z) on exactly those PRs' file surfaces — the fingerprint of a gate-side
# or test-side actor running an un-scoped mutating git verb (no `-C`, no enclosing `cd`) whose cwd
# resolved to $MAIN instead of its own worktree/sandbox.
#
# AUDIT LEG (HERD-637 leg 1): the engine surface was swept for every `add`/`stash`/`restore`/
# `checkout --`/`reset` lacking `-C` (scripts/herd/*.sh, backends/, work-units/, pysrc/herd/*.py,
# tests/*.sh). Two PRIOR incidents of this exact failure mode — HERD-361's baseline suite and HERD-452's
# main-health worker — were already fixed by sandboxing the CALLER into a disposable detached worktree;
# both remain sandboxed (re-verified: tests/test-checkout-cleanliness.sh's PART B, and the ROOT-CAUSE
# FIX comment on `_main_health_worker` in agent-watch.sh). No THIRD currently-live unscoped writer was
# found: scripts/herd/backends/file.sh's `git reset --hard` / `git checkout -- <path>` calls are the one
# remaining ambient-cwd-reliant shape, and they were ALREADY sanctioned-by-convention (every caller
# `cd`s to $PROJECT_ROOT before sourcing the backend) — that invariant is now made EXPLICIT via
# `# herd-scope-ok` annotations in the same PR, rather than left implicit and un-auditable.
#
# So this test proves the MECHANISM (PART A: an unscoped mutating verb really does stage stale content
# into whatever cwd it is handed — the tripwire, reproduced directly against a real git repo standing
# in for $MAIN) and the DEFENSE (PART B: the new lint class catches the exact vulnerable shape statically
# — red before an explicit `-C`/`cd` fix, green after — which is what would have caught this incident's
# actual writer, whatever it was, before it could land).
#
# Fully hermetic: real local git repos under a mktemp dir, no herdr/gh/network/model.
# Run:  bash tests/test-write-fence-tripwire.sh
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
command -v git >/dev/null 2>&1 || fail "git required to run this test"
export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_SYSTEM=/dev/null
git config --file "$T/gitconfig" user.email t@t.test
git config --file "$T/gitconfig" user.name  tester
git config --file "$T/gitconfig" init.defaultBranch main
git config --file "$T/gitconfig" commit.gpgsign false

# ════════════════════════════════════════════════════════════════════════════════════════════════
# PART A — THE TRIPWIRE: an unscoped mutating verb, run with cwd = the shared checkout, really does
# stage stale content there — the exact observable fingerprint the incident's evidence patch shows.
# ════════════════════════════════════════════════════════════════════════════════════════════════

# SHARED stands in for $MAIN: one committed file at "v1", then a second commit advancing it to "v2"
# (the PR-743-equivalent change). SHARED's HEAD is the v2 commit — clean, exactly as $MAIN sits between
# merges.
SHARED="$T/shared"; mkdir -p "$SHARED"
git -C "$SHARED" init -q
git -C "$SHARED" checkout -q -B main
printf 'v1 (pre-743)\n' > "$SHARED/docs-symbol-index.md.txt"
git -C "$SHARED" add -A; git -C "$SHARED" commit -q -m "v1"
OLD_SHA="$(git -C "$SHARED" rev-parse HEAD)"
printf 'v2 (post-743)\n' > "$SHARED/docs-symbol-index.md.txt"
git -C "$SHARED" add -A; git -C "$SHARED" commit -q -m "v2"
STATUS_BEFORE="$(git -C "$SHARED" status --porcelain)"
HEAD_BEFORE="$(git -C "$SHARED" rev-parse HEAD)"
[ -z "$STATUS_BEFORE" ] || fail "(A) fixture: SHARED must start clean"

# ── (A1) THE ROGUE WRITER, UNSCOPED — the exact CWD-RELIANT shape: no `-C`, no `cd`. A real gate/test
# actor whose OWN sandbox setup silently failed/was skipped falls through to running this in whatever
# directory the calling process happens to be in. Invoked here with cwd = $SHARED (standing in for the
# incident's writer landing in $MAIN instead of its own worktree).
_rogue_writer_unscoped() {
  # herd-scope-ok: DELIBERATELY unscoped — this IS the tripwire under test (HERD-637 PART A), not a
  # real production call site.
  git checkout "$OLD_SHA" -- docs-symbol-index.md.txt 2>/dev/null || true
}
( cd "$SHARED" && _rogue_writer_unscoped )

STATUS_AFTER="$(git -C "$SHARED" status --porcelain)"
[ -n "$STATUS_AFTER" ] \
  || fail "(A1) tripwire did not reproduce — the unscoped writer left SHARED clean (mechanism not real?)"
grep -q 'docs-symbol-index.md.txt' <<< "$STATUS_AFTER" \
  || fail "(A1) expected docs-symbol-index.md.txt staged, got: [$STATUS_AFTER]"
[ "$(cat "$SHARED/docs-symbol-index.md.txt")" = "v1 (pre-743)" ] \
  || fail "(A1) expected the STALE (pre-743) content staged, got: [$(cat "$SHARED/docs-symbol-index.md.txt")]"
pass
echo "PASS (A1) TRIPWIRE REPRODUCED: an unscoped 'git checkout -- <path>' run with cwd=SHARED stages stale content there — the incident's exact fingerprint"

# ── (A2) RECOVERY: undo the tripwire so PART B's byte-identical assertion below starts clean ───────
git -C "$SHARED" checkout -q HEAD -- docs-symbol-index.md.txt
[ -z "$(git -C "$SHARED" status --porcelain)" ] || fail "(A2) fixture: SHARED must be clean again before PART B"
pass

# ════════════════════════════════════════════════════════════════════════════════════════════════
# PART B — THE FIX: the SAME writer, now explicitly `-C`-scoped to its OWN sandbox (never SHARED),
# leaves SHARED byte-identical regardless of the calling process's cwd — before/after the tripwire.
# ════════════════════════════════════════════════════════════════════════════════════════════════
SANDBOX="$T/sandbox"; git -C "$SHARED" worktree add -q --detach "$SANDBOX" HEAD >/dev/null 2>&1 \
  || fail "(B) could not create the writer's own sandbox worktree"

_rogue_writer_scoped() {
  git -C "$SANDBOX" checkout "$OLD_SHA" -- docs-symbol-index.md.txt 2>/dev/null || true
}
( cd "$SHARED" && _rogue_writer_scoped )   # cwd is STILL $SHARED — the fix must not depend on it

STATUS_SHARED_AFTER="$(git -C "$SHARED" status --porcelain)"
HEAD_SHARED_AFTER="$(git -C "$SHARED" rev-parse HEAD)"
[ -z "$STATUS_SHARED_AFTER" ] \
  || fail "(B1) the FIXED (-C-scoped) writer still contaminated SHARED — git status: [$STATUS_SHARED_AFTER]"
[ "$HEAD_BEFORE" = "$HEAD_SHARED_AFTER" ] || fail "(B1) the fixed writer moved SHARED's HEAD"
[ "$(cat "$SANDBOX/docs-symbol-index.md.txt")" = "v1 (pre-743)" ] \
  || fail "(B1) the fixed writer's OWN sandbox should still have received the stale content (it applies the same op — just scoped)"
git -C "$SHARED" worktree remove --force "$SANDBOX" >/dev/null 2>&1 || true
pass
echo "PASS (B1) FIXED: the same op, explicitly '-C'-scoped to its own sandbox, leaves SHARED byte-identical regardless of cwd"

# ════════════════════════════════════════════════════════════════════════════════════════════════
# PART C — the LINT (scripts/herd/git-scope-lint.sh's CWD-RELIANT class) catches the vulnerable shape
# statically: red before the -C/cd fix, green after — in BOTH a production gate path and a test file.
# ════════════════════════════════════════════════════════════════════════════════════════════════
make_file() {   # <dir> <relpath> <body...> — an engine-surface file with the given trailing lines
  local d="$1" rel="$2"; shift 2
  mkdir -p "$d/$(dirname "$rel")"
  { printf '#!/usr/bin/env bash\n'; printf '%s\n' "$@"; } > "$d/$rel"
}

for rel in scripts/herd/rogue-writer.sh tests/test-rogue-writer.sh; do
  TB="$T/lint$$-${rel//\//x}"; rm -rf "$TB"
  make_file "$TB" scripts/herd/marker.sh 'true'   # engine-tree marker (harmless when rel IS this file)
  # herd-scope-ok: this whole call's ARGUMENTS are DATA written verbatim into a throwaway fixture file
  # (the vulnerable shape under lint test, not a live call in THIS file).
  make_file "$TB" "$rel" \
    '_rogue_writer_unscoped() {' \
    '  git checkout "$OLD_SHA" -- docs-symbol-index.md.txt 2>/dev/null || true' \
    '}'
  out="$(herd_git_scope_lint "$TB")"; rc=$?
  [ "$rc" -eq 1 ] || fail "(C1) '$rel': the UNSCOPED writer shape must red BEFORE the fix (exit 1, got $rc): $out"
  grep -qF 'CWD-RELIANT checkout --' <<< "$out" \
    || fail "(C1) '$rel': expected a CWD-RELIANT checkout -- finding (got: $out)"

  TB2="$T/lintfixed$$-${rel//\//x}"; rm -rf "$TB2"
  make_file "$TB2" scripts/herd/marker.sh 'true'
  make_file "$TB2" "$rel" \
    '_rogue_writer_scoped() {' \
    '  git -C "$SANDBOX" checkout "$OLD_SHA" -- docs-symbol-index.md.txt 2>/dev/null || true' \
    '}'
  out2="$(herd_git_scope_lint "$TB2")"; rc2=$?
  [ "$rc2" -eq 0 ] || fail "(C2) '$rel': the '-C'-scoped fix must be clean AFTER the fix (exit 0, got $rc2): $out2"
done
pass
echo "PASS (C) the lint reds the unscoped shape and passes the -C-scoped fix, in a gate path AND a test file alike"

echo
echo "ALL PASS: test-write-fence-tripwire.sh ($PASS checks) — HERD-637 mechanism reproduced + fixed + statically caught"
