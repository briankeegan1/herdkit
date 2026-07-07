#!/usr/bin/env bash
# test-builder-secrets-isolation.sh — hermetic proof that a builder worktree cannot reach the work
# tracker's credentials (HERD-87).
#
# Builders run --dangerously-skip-permissions and can read anything the lane provisions into their
# worktree. The tracker's API key lives in $MAIN/.herd/secrets (gitignored, never checked out). The
# ONE lane-provisioned filesystem seam that could expose it is SHARE_LINKS — the space-separated dirs
# new-feature.sh symlinks from the main checkout into each worktree. If SHARE_LINKS named .herd (or
# .herd/secrets itself), the builder would resolve the secrets path through the symlink and could
# mutate tracker state, violating "the coordinator owns all backlog/tracker updates".
#
# Asserts:
#   (a) SHARE_LINKS=".herd/secrets" → the lane REFUSES the link; the worktree cannot resolve
#       $DIR/.herd/secrets.
#   (b) SHARE_LINKS=".herd"         → the lane REFUSES the link; neither $DIR/.herd (as a symlink) nor
#       $DIR/.herd/.herd/secrets resolves to the real secret.
#   (c) The secret's content is NOT reachable anywhere under the worktree via a provisioned link
#       (control: it IS readable in the main checkout, proving the fixture is real).
#   (d) A BENIGN SHARE_LINK ("data") is unaffected — still symlinked, worktree still built (fail-soft:
#       refusing the dangerous link never blocks worktree creation).
#   (e) Both builder lanes' task-spec preambles carry the standing rule: never read .herd/secrets and
#       never write the work tracker (grep-test of the generated spec, both lanes).
#
# Fully hermetic: a throwaway git repo + stubbed herdr/claude (NETWORK-FREE). Mirrors the setup in
# tests/test-context-provision.sh.
# Run:  bash tests/test-builder-secrets-isolation.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
NEWFEAT="$HERE/../scripts/herd/new-feature.sh"
QUICK="$HERE/../scripts/herd/herd-quick.sh"
FEATURE="$HERE/../scripts/herd/herd-feature.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass(){ PASS=$((PASS+1)); }
command -v git >/dev/null 2>&1 || fail "git required to run this test"

SECRET_MARKER="SENTINEL_LINEAR_API_KEY_do_not_leak"

# ── Stubs (mirror tests/test-context-provision.sh) ─────────────────────────────────────────────
BIN="$T/bin"; mkdir -p "$BIN"
cat > "$BIN/herdr" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${HERDR_CALL_LOG:-/dev/null}" 2>/dev/null || true
case "$1 $2" in
  "workspace list") printf '{"result":{"workspaces":[{"workspace_id":"wTest","label":"%s"}]}}\n' "${WORKSPACE_NAME:-herdkit}" ;;
  "tab list")       printf '{"result":{"tabs":[]}}\n' ;;
  "tab create")     printf '{"result":{"tab":{"tab_id":"tTest"},"root_pane":{"pane_id":"rTest"}}}\n' ;;
  "agent start")    printf '{"result":{"agent":{"pane_id":"aTest"}}}\n' ;;
  "pane split")     printf '{"result":{"pane":{"pane_id":"pTest"}}}\n' ;;
  *) : ;;
esac
exit 0
STUB
chmod +x "$BIN/herdr"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/claude"; chmod +x "$BIN/claude"
export PATH="$BIN:$PATH"

# ── Throwaway git repo with a committed .herd/ (so the worktree has a real .herd dir — the
#    precondition that makes a .herd/secrets symlink *creatable*, i.e. the guard is what stops it)
#    plus a gitignored, secret-bearing .herd/secrets living ONLY in the main checkout. ───────────
REPO="$T/repo"
git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$REPO" 2>/dev/null
git -C "$REPO" checkout -q -b main
mkdir -p "$REPO/.herd"
printf 'SCRIBE_BACKEND=file\n'                  > "$REPO/.herd/config"
printf '.herd/secrets\ndata/\n'                 > "$REPO/.gitignore"
git -C "$REPO" -c user.email=t@t -c user.name=t add .herd/config .gitignore
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m seed
git -C "$REPO" push -q -u origin main 2>/dev/null
# These land AFTER commit (both gitignored) — main-checkout only, never in the tree a worktree checks
# out. 'data' models a legitimate gitignored SHARE_LINK (e.g. node_modules); .herd/secrets is the vector.
printf 'LINEAR_API_KEY=%s\n' "$SECRET_MARKER" > "$REPO/.herd/secrets"
mkdir -p "$REPO/data"; : > "$REPO/data/keep.txt"

# Control: the secret IS real and readable in the main checkout.
grep -q "$SECRET_MARKER" "$REPO/.herd/secrets" || fail "fixture: secret marker not present in main .herd/secrets"

# ── Hermetic env ───────────────────────────────────────────────────────────────
export HOME="$T"                  # herd_pretrust_worktree writes $HOME/.claude.json — keep it sandboxed
export WORKSPACE_NAME="herdkit"
export HERD_SKIP_PREFLIGHT=1
TREES="$T/trees"
CFG="$T/config"
export HERD_CONFIG_FILE="$CFG"

write_cfg() {  # write_cfg <SHARE_LINKS value>
  {
    printf 'PROJECT_ROOT="%s"\n'  "$REPO"
    printf 'WORKTREES_DIR="%s"\n' "$TREES"
    printf 'DEFAULT_BRANCH="origin/main"\n'
    printf 'WORKSPACE_NAME="herdkit"\n'
    printf 'APP_PREVIEW_CMD=""\n'
    printf 'MODEL_QUICK="test-quick-model"\n'
    printf 'MODEL_FEATURE="test-feature-model"\n'
    printf 'SHARE_LINKS="%s"\n' "$1"
  } > "$CFG"
}

# make_worktree <slug> — run new-feature.sh with the current $CFG; returns the worktree dir path.
make_worktree() {
  local slug="$1"
  bash "$NEWFEAT" "$slug" > "$T/$slug.nf.out" 2>&1 \
    || fail "new-feature.sh exited non-zero for '$slug' (worktree creation must be fail-soft):"$'\n'"$(cat "$T/$slug.nf.out")"
  echo "$TREES/$slug"
}

# assert_no_secret <dir> — no path under <dir> may resolve to the real secret via a provisioned link.
assert_no_secret() {
  local dir="$1"
  # Direct + one-hop-through-a-.herd-symlink secrets paths must not resolve to an existing file.
  [ ! -e "$dir/.herd/secrets" ]        || fail "$dir/.herd/secrets resolves — the secrets link was NOT refused"
  [ ! -e "$dir/.herd/.herd/secrets" ]  || fail "$dir/.herd/.herd/secrets resolves — a .herd symlink leaked the dir"
  # And the secret's content must not be reachable anywhere under the worktree (follow symlinks).
  if grep -rIl "$SECRET_MARKER" "$dir" 2>/dev/null | grep -q .; then
    fail "$SECRET_MARKER is reachable from within the worktree $dir — secrets isolation breached"
  fi
}

# ── (a) SHARE_LINKS=".herd/secrets" → link refused, secrets unreachable ──────────────────────────
write_cfg ".herd/secrets"
d="$(make_worktree iso-file)"
grep -q "refusing SHARE_LINK" "$T/iso-file.nf.out" || fail "(a) lane did not announce it refused the .herd/secrets link"
assert_no_secret "$d"
pass; echo "PASS (a) SHARE_LINKS=.herd/secrets refused → worktree cannot resolve the secrets path"

# ── (b) SHARE_LINKS=".herd" (whole dir) → link refused, secrets unreachable ──────────────────────
write_cfg ".herd"
d="$(make_worktree iso-dir)"
grep -q "refusing SHARE_LINK" "$T/iso-dir.nf.out" || fail "(b) lane did not announce it refused the .herd link"
assert_no_secret "$d"
pass; echo "PASS (b) SHARE_LINKS=.herd refused → no symlink exposes the secrets-bearing dir"

# ── (c) control: the secret stays readable in the MAIN checkout (fixture is genuinely secret-bearing)
grep -q "$SECRET_MARKER" "$REPO/.herd/secrets" || fail "(c) control failed: main-checkout secret vanished"
pass; echo "PASS (c) secret remains readable in the main checkout (isolation is worktree-scoped, as intended)"

# ── (d) fail-soft: a benign SHARE_LINK alongside a dangerous one is still provisioned ─────────────
write_cfg ".herd/secrets data"
d="$(make_worktree iso-mixed)"
[ -L "$d/data" ] || fail "(d) benign SHARE_LINK 'data' was not symlinked — refusing the dangerous link must not block the safe ones"
[ -e "$d/data/keep.txt" ] || fail "(d) 'data' symlink is broken — worktree not usable"
assert_no_secret "$d"
pass; echo "PASS (d) fail-soft: dangerous link refused, benign link still provisioned, worktree usable"

# ── (e) both lanes' task-spec preambles carry the never-read-secrets / never-write-tracker rule ──
write_cfg ""   # no shares; we only need the generated spec
RULE_MARK="never write the work tracker"
SECRETS_MARK="Never read .herd/secrets"
for pair in "quick $QUICK iso-rule-quick" "feat $FEATURE iso-rule-feat"; do
  set -- $pair; script="$2"; slug="$3"
  export HERDR_CALL_LOG="$T/$slug.herdr.log"; : > "$HERDR_CALL_LOG"
  HERD_NO_APP=1 bash "$script" "$slug" "SENTINEL body build the thing" > "$T/$slug.out" 2>&1 \
    || fail "(e) $(basename "$script") exited non-zero for '$slug':"$'\n'"$(cat "$T/$slug.out")"
  spec="$TREES/$slug.task.md"
  [ -f "$spec" ] || fail "(e) $slug: spec file not written at $spec"
  grep -q "$SECRETS_MARK" "$spec" || fail "(e) $slug: preamble missing the '.herd/secrets' rule"
  grep -q "$RULE_MARK"    "$spec" || fail "(e) $slug: preamble missing the 'never write the work tracker' rule"
done
pass; echo "PASS (e) both lanes' task-spec preambles forbid reading secrets / writing the tracker"

echo "ALL PASS ($PASS groups)"
