#!/usr/bin/env bash
# test-cli-note-context.sh — hermetic tests for the HERD-412 project-config resolution shared by
# `herd note` (and the sibling worktree-run subcommands `herd advise` / `herd ledger`, plus `herd
# pane`'s HERD-405/#523 walk-up they now share the exact resolver with).
#
# THE BUG: `herd note` run from a worktree that carries no committed .herd/config fell through to
# herd-config.sh's own plain-directory PWD walk-up + $_HERD_REPO_DEFAULT engine-dogfood fallback,
# silently binding a FOREIGN project's (or the engine's OWN) config and writing the finding onto the
# wrong project's journal/pool. Live incident (2026-07-22): a money-bets builder worktree's `herd
# note` landed on herdkit-trees/.agent-watch-builder-notes instead of money-bets' own ledger.
#
# THE FIX: _herd_resolve_project_config / _herd_require_project_config (bin/herd) — ONE shared,
# non-actuator seam. Resolution order: (1) cwd's own .herd/config, (2) the git toplevel's
# .herd/config (HERD-405, subdirectory case), (3) — only when cwd is itself a git-linked worktree —
# the OWNING main checkout's .herd/config (`git worktree list`'s first entry). A total miss REFUSES
# loudly with the exact dogfood-refusal message `herd pane` uses, rather than silently dogfooding.
#
# Covers:
#   (1) a worktree with NO .herd/config anywhere (own tree nor parent) → herd note refuses loudly
#   (1b) a plain (non-worktree) repo with no .herd/config anywhere → herd note refuses loudly too
#   (2) a worktree whose PARENT main checkout HAS .herd/config → the note lands in THAT project's
#       pool journal, with the worktree's own basename as the slug
#   (3) a plain project directory (cwd itself carries .herd/config, no git worktree involved) →
#       unchanged direct resolution (mirrors "from this repo's own tree" — dogfood project layout)
#   (4) the shared seam: `herd advise` and `herd ledger`, run from the SAME parentless worktree,
#       inherit the identical parent-checkout resolution (and the identical refusal) — proving the
#       fix landed at one shared seam rather than being hand-patched per command
#
# Fully hermetic: temp dirs + a real (throwaway) git repo/worktree only, no network, no herdr.
# CAUTION: this test deliberately drives the REAL bin/herd with resolution allowed to run to
# completion — every fixture sets WORKTREES_DIR under $T so a miscoded fix could only ever write
# inside the mktemp sandbox, never a real project (the total-miss cases assert a hard `die` before
# herd-config.sh is ever sourced, so they touch no filesystem at all beyond exit status/stderr).
# Run:  bash tests/test-cli-note-context.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
HERD_BIN="$REPO/bin/herd"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

[ -f "$HERD_BIN" ] || fail "bin/herd not found"
command -v git >/dev/null 2>&1 || fail "git required"
command -v python3 >/dev/null 2>&1 || fail "python3 required"

_git_init() {
  local r="$1"
  git -C "$r" init -q
  git -C "$r" config user.email t@t.t
  git -C "$r" config user.name t
}

_field() {
  python3 -c '
import sys, json
with open(sys.argv[1]) as f:
    lines = [l for l in f if l.strip()]
o = json.loads(lines[int(sys.argv[2])])
sys.stdout.write(str(o.get(sys.argv[3], "<MISSING>")))
' "$1" "$2" "$3"
}

# _run ENVVAR=VAL... -- cmd args...  — invoke bin/herd with an explicitly EMPTY environment for the
# resolution-sensitive vars (HERD_CONFIG_FILE/WORKTREES_DIR/PROJECT_ROOT), so nothing leaks from this
# test process's own real .herd/config into the child. Also strips the bats/hermetic-test SIGNALS
# (BATS_TEST_FILENAME/BATS_TEST_NAME/HERMETIC_TEST/HERD_HERMETIC_GUARD/HERD_JOURNAL_HERMETIC) this
# script inherits when run UNDER bats (tests/herd.bats shells out to every tests/test-*.sh) — left
# alone, journal.sh's _journal_in_test_context (HERD-223) sees them and redirects the write to a
# throwaway TMPDIR file instead of the resolved WORKTREES_DIR/.herd/journal.jsonl, which is exactly
# the resolution this test asserts. Stripping them makes the child behave like a REAL invocation.
_run() {
  local -a envs=() args=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ "${1:-}" = "--" ] && shift
  args=("$@")
  env -u HERD_CONFIG_FILE -u WORKTREES_DIR -u PROJECT_ROOT -u HERD_SLUG \
    -u BATS_TEST_FILENAME -u BATS_TEST_NAME -u HERMETIC_TEST -u HERD_HERMETIC_GUARD -u HERD_JOURNAL_HERMETIC \
    ${envs[@]+"${envs[@]}"} HERD_NONINTERACTIVE=1 bash "$HERD_BIN" ${args[@]+"${args[@]}"} 2>&1
}

# ═══ (1) worktree with NO .herd/config anywhere (own tree nor parent) → loud refusal ═══════════════
MAIN1="$T/main1"; mkdir -p "$MAIN1"; _git_init "$MAIN1"
( cd "$MAIN1" && git commit -q --allow-empty -m init )   # MAIN1 itself never gets a .herd/config
WT1="$T/wt1"
( cd "$MAIN1" && git worktree add -q "$WT1" -b feat/wt1 ) || fail "(1) could not create worktree WT1"

set +e
out="$(cd "$WT1" && _run -- note "should never land anywhere")"
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "(1) herd note should refuse with no .herd/config anywhere (rc=$rc, out: $out)"
printf '%s' "$out" | grep -qi "no .herd/config" || fail "(1) refusal message missing 'no .herd/config' (got: $out)"
printf '%s' "$out" | grep -qi "dogfood" || fail "(1) refusal message should mention refusing the dogfood config (got: $out)"
ok

# ═══ (1b) plain (non-worktree) repo, no .herd/config anywhere → refuses the same way ════════════════
PLAIN="$T/plain"; mkdir -p "$PLAIN"; _git_init "$PLAIN"
( cd "$PLAIN" && git commit -q --allow-empty -m init )
set +e
out="$(cd "$PLAIN" && _run -- note "should never land anywhere either")"
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "(1b) herd note should refuse in a plain repo with no .herd/config (rc=$rc)"
printf '%s' "$out" | grep -qi "no .herd/config" || fail "(1b) refusal message missing 'no .herd/config'"
printf '%s' "$out" | grep -qi "dogfood" || fail "(1b) refusal message should mention the dogfood fallback"
ok

# ═══ (2) worktree whose PARENT main checkout HAS .herd/config → note lands in ITS pool ══════════════
MAIN2="$T/main2"; TREES2="$T/trees2"; mkdir -p "$MAIN2/.herd" "$TREES2/.herd"
_git_init "$MAIN2"
cat > "$MAIN2/.herd/config" <<CFG
PROJECT_ROOT="$MAIN2"
WORKTREES_DIR="$TREES2"
WORKSPACE_NAME="note-ctx-test"
MODEL_FEATURE="sentinel-feature-model"
CFG
( cd "$MAIN2" && git add -A && git commit -q -m init )
# The linked worktree lives exactly where a real builder tree does: WORKTREES_DIR/<slug>. Its own
# checkout carries NO .herd/config — simulating a project (like money-bets) that doesn't commit one.
WT2="$TREES2/my-slug"
( cd "$MAIN2" && git worktree add -q "$WT2" -b feat/my-slug ) || fail "(2) could not create worktree WT2"
rm -rf "$WT2/.herd"
[ ! -f "$WT2/.herd/config" ] || fail "(2) fixture bug: WT2 still carries .herd/config"

out="$(cd "$WT2" && _run -- note "this red is a stale cached row")"
rc=$?
[ "$rc" -eq 0 ] || fail "(2) herd note should succeed via the parent checkout's config (rc=$rc, out: $out)"
printf '%s' "$out" | grep -q "noted" || fail "(2) missing confirmation output (got: $out)"
ok

JNL2="$TREES2/.herd/journal.jsonl"
[ -f "$JNL2" ] || fail "(2) note should land in the PARENT project's journal ($JNL2)"
[ "$(_field "$JNL2" 0 event)" = "builder_note" ] || fail "(2) journal event should be builder_note"
ok
[ "$(_field "$JNL2" 0 slug)" = "my-slug" ] || fail "(2) slug should derive from the worktree basename (got $(_field "$JNL2" 0 slug))"
ok
[ "$(_field "$JNL2" 0 text)" = "this red is a stale cached row" ] || fail "(2) text field wrong"
ok

# ═══ (3) plain project dir (cwd itself carries .herd/config; no worktree involved) — unchanged ══════
P3="$T/p3"; TREES3="$T/trees3"; mkdir -p "$P3/.herd" "$TREES3/.herd"
cat > "$P3/.herd/config" <<CFG
PROJECT_ROOT="$P3"
WORKTREES_DIR="$TREES3"
WORKSPACE_NAME="note-ctx-p3"
CFG
out="$(cd "$P3" && _run -- note "own-tree behavior unchanged")"
rc=$?
[ "$rc" -eq 0 ] || fail "(3) herd note should succeed from cwd's own .herd/config (rc=$rc, out: $out)"
JNL3="$TREES3/.herd/journal.jsonl"
[ -f "$JNL3" ] || fail "(3) note should land at cwd's own project pool"
[ "$(_field "$JNL3" 0 text)" = "own-tree behavior unchanged" ] || fail "(3) text field wrong for the direct-cwd case"
ok

# ═══ (4) shared seam: herd advise / herd ledger inherit the SAME resolution ═════════════════════════
# Reuse WT2 (parentless worktree, MAIN2 owns the config) for both the success and refusal paths.

# (4a) herd ledger — writes to the PARENT's ledger, not a foreign one.
out="$(cd "$WT2" && _run -- ledger set HERD-412 slug ctx-test status spawned)"
rc=$?
[ "$rc" -eq 0 ] || fail "(4a) herd ledger set should resolve via the parent checkout (rc=$rc, out: $out)"
LEDGER2="$TREES2/.herd/ledger.jsonl"
[ -f "$LEDGER2" ] || fail "(4a) ledger should land in the PARENT project's pool ($LEDGER2)"
ok
cli_get="$(cd "$WT2" && _run -- ledger get HERD-412)"
printf '%s' "$cli_get" | grep -q "slug=ctx-test" || fail "(4a) ledger get should fold the item written from the worktree"
ok

# (4b) herd advise — resolves MODEL_FEATURE from the PARENT's config (proves the SAME config bound).
BIN="$T/bin"; mkdir -p "$BIN"
CLOG="$T/claude.args"
cat > "$BIN/claude" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$CLOG"
printf 'ok\n'
EOF
chmod +x "$BIN/claude"
: > "$CLOG"
out="$(cd "$WT2" && PATH="$BIN:$PATH" _run -- advise "which lock strategy is safer?")"
rc=$?
[ "$rc" -eq 0 ] || fail "(4b) herd advise should resolve via the parent checkout (rc=$rc, out: $out)"
grep -q -- '--model sentinel-feature-model' "$CLOG" \
  || fail "(4b) advise did not read the PARENT project's MODEL_FEATURE (got: $(cat "$CLOG"))"
ok

# (4c) both refuse the same way from a worktree with NO parent match either (WT1 fixture from (1)).
set +e
out_l="$(cd "$WT1" && _run -- ledger set HERD-999 slug x)"; rc_l=$?
out_a="$(cd "$WT1" && _run -- advise "q?")"; rc_a=$?
set -e
[ "$rc_l" -ne 0 ] || fail "(4c) herd ledger should refuse with no .herd/config anywhere (rc=$rc_l)"
printf '%s' "$out_l" | grep -qi "dogfood" || fail "(4c) ledger refusal should mention the dogfood fallback"
[ "$rc_a" -ne 0 ] || fail "(4c) herd advise should refuse with no .herd/config anywhere (rc=$rc_a)"
printf '%s' "$out_a" | grep -qi "dogfood" || fail "(4c) advise refusal should mention the dogfood fallback"
ok

echo "ALL PASS ($pass checks)"
