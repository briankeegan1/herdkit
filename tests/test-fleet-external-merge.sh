#!/usr/bin/env bash
# test-fleet-external-merge.sh — hermetic tests for HERD-290: an externally-merged PR must not be
# classified 'blocked' forever by `herd fleet digest` or `herd fleet inbox`.
#
# Grounded scenario (PR #343): another seat merged the PR on GitHub. THIS seat's journal therefore
# has NO local `merge` event (only the LOCAL watcher's do_merge writes one) — it has BLOCK verdicts
# on the superseded shas AND a `retire_converged` row (HERD-164), the retirement invariant's proof
# that the branch's work reached main. The terminal signal for such a PR is retire_converged, and
# both reducers must rank it as shipped/done so the stale BLOCK never lingers.
#
# Design mirrors test-fleet-digest.sh / test-fleet-inbox.sh: fully hermetic (temp registry, temp
# fake projects with hand-written fixture journals, temp $HOME, pinned HERD_FLEET_NOW, stub gh),
# never touches the live journal or the network.
#
# Run:  bash tests/test-fleet-external-merge.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
HERD="$HERE/../bin/herd"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass=0
ok(){ pass=$((pass+1)); }

export HOME="$T/home"; mkdir -p "$HOME"
export HERD_FLEET_FILE="$T/registry/fleet"
# Pin "now" so the 24h digest window has cutoff 2026-07-08T16:00:00Z (fixture events are all after).
export HERD_FLEET_NOW="2026-07-09T16:00:00Z"

# stub gh — inbox shells out to `gh pr list`. FAKE_GH_FAIL=1 makes it exit non-zero to simulate an
# offline/unauthed gh, which puts the inbox on its fail-OPEN path (journal items kept). That is the
# exact condition under which the inbox's reducer gap manifests: gh cannot prove the PR is closed,
# so only a terminal journal signal (retire_converged) can clear the stale BLOCK.
export FAKE_GH_DIR="$T/gh"; mkdir -p "$FAKE_GH_DIR"
mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'GH'
#!/usr/bin/env bash
[ "${FAKE_GH_FAIL:-}" = "1" ] && { echo "gh: not authenticated" >&2; exit 1; }
case "$*" in
  *"pr list"*)
    f="$FAKE_GH_DIR/$(basename "$PWD").json"
    if [ -f "$f" ]; then cat "$f"; else echo "[]"; fi ;;
  *) echo "[]" ;;
esac
GH
chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH"

_mkproj() {
  local name="$1" root="$T/proj/$1"
  mkdir -p "$root/.herd" "$T/proj/$1-trees/.herd"
  local rr; rr="$(cd "$root" && pwd -P)"
  cat > "$root/.herd/config" <<CFG
PROJECT_ROOT="$rr"
WORKTREES_DIR="$rr-trees"
DEFAULT_BRANCH="origin/main"
WORKSPACE_NAME="$name"
HERD_REPO="me/$name"
CFG
  printf '%s' "$rr"
}

ALPHA="$(_mkproj alpha)"

# alpha's journal — the HERD-290 fixture window: PR #343 got BLOCK verdicts on two superseded shas,
# then the other seat merged it on GitHub. There is NO `merge` event (only the local watcher writes
# one); the terminal proof is `retire_converged`. A control PR #12 is genuinely blocked (BLOCK, no
# retire_converged) and MUST stay blocked so the fix does not over-clear.
cat > "$T/proj/alpha-trees/.herd/journal.jsonl" <<'JL'
{"ts":"2026-07-09T09:00:00Z","event":"verdict_recorded","pr":343,"value":"BLOCK","sha":"old1","source":"reviewer"}
{"ts":"2026-07-09T10:00:00Z","event":"verdict_recorded","pr":343,"value":"BLOCK","sha":"old2","source":"reviewer"}
{"ts":"2026-07-09T10:34:11Z","event":"retire_converged","slug":"external-merge","pr":343,"reason":"terminal"}
{"ts":"2026-07-09T11:00:00Z","event":"verdict_recorded","pr":12,"value":"BLOCK","sha":"cc","source":"reviewer"}
JL

bash "$HERD" fleet register "$ALPHA" >/dev/null

# ── 1. DIGEST: #343 (BLOCK rows + retire_converged, no merge) classifies SHIPPED, not blocked ──
out="$(bash "$HERD" fleet digest)"
alpha_block="$(printf '%s' "$out" | awk '/^alpha$/{f=1;next} /^[a-zA-Z]/{f=0} f')"
ship_line="$(printf '%s' "$alpha_block" | grep -E 'shipped:')"
printf '%s' "$ship_line" | grep -q '#343' || fail "digest: externally-merged #343 must be shipped, got: $alpha_block"
block_line="$(printf '%s' "$alpha_block" | grep -E 'blocked:')"
printf '%s' "$block_line" | grep -q '#343' && fail "digest: #343 must NOT be listed blocked (retire_converged is terminal)"
ok

# ── 2. DIGEST: a genuinely-blocked control PR (#12, no retire_converged) stays blocked ─────────
printf '%s' "$block_line" | grep -q '#12'  || fail "digest: #12 (BLOCK, never converged) must remain blocked"
printf '%s' "$ship_line"  | grep -q '#12'  && fail "digest: #12 must NOT be shipped (no retire_converged)"
ok

# ── 3. INBOX with gh DOWN (fail-open): #343's stale BLOCK is cleared by retire_converged ───────
# gh-down keeps journal-derived items (cannot prove the PR closed), so only the terminal signal
# clears #343. Without the reducer fix the stale BLOCK would surface here.
out_i="$(FAKE_GH_FAIL=1 bash "$HERD" fleet inbox)"
alpha_i="$(printf '%s' "$out_i" | awk '/^alpha$/{f=1;next} /^[a-zA-Z]/{f=0} f')"
printf '%s' "$alpha_i" | grep -q '#343' && fail "inbox (gh down): externally-merged #343 must not surface as blocked"
ok

# ── 4. INBOX with gh DOWN: the genuinely-blocked control #12 STILL surfaces ────────────────────
printf '%s' "$alpha_i" | grep -q '#12' || fail "inbox (gh down): genuinely-blocked #12 must still surface, got: $alpha_i"
printf '%s' "$alpha_i" | grep '#12' | grep -qi 'BLOCK' || fail "inbox: #12 should be labelled a review BLOCK"
ok

echo "ALL PASS ($pass checks)"
