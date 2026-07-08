#!/usr/bin/env bash
# test-reconcile-backend-gate.sh — backlog-reconcile.sh `run` is backend-gated (HERD-160 quick win).
#
# backlog-reconcile enqueues a scribe request to fix DANGLING BACKLOG.md references after a rename PR.
# That is meaningful ONLY for the FILE backend, whose source of truth IS BACKLOG.md. For a tracker
# backend (linear/github/changelog — the source of truth is the external tracker, and _backend_update_state
# is defined) there is no BACKLOG.md prose to reconcile, so `run` must go INERT instead of enqueuing a
# file-edit request the tracker backend would only mis-file or skip. This mirrors tracker-state-sweep.sh's
# backend-scoping, inverted (the sweep runs FOR tracker backends; reconcile runs AGAINST the file backend).
#
# Same fixture as test-backlog-reconcile.sh (a rename that dangles a backlog ref): with the file backend
# `run` enqueues; with a tracker backend `run` is inert. Hermetic: local git + a fake backend + the
# HERD_RECONCILE_SCRIBE capture seam. No herdr/gh/network.
# Run:  bash tests/test-reconcile-backend-gate.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SCRIPT="$ROOT/scripts/herd/backlog-reconcile.sh"

command -v git     >/dev/null 2>&1 || { echo "FAIL: git required" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 required" >&2; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { PASS=$((PASS+1)); }

export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_SYSTEM=/dev/null
git config --file "$T/gitconfig" user.email t@herd.local
git config --file "$T/gitconfig" user.name  "herd test"
git config --file "$T/gitconfig" init.defaultBranch main
git config --file "$T/gitconfig" commit.gpgsign false

# ── fixture: a repo where a rename dangles a backlog reference ─────────────────────────────────────
REPO="$T/repo"; mkdir -p "$REPO/.herd" "$REPO/scripts/herd" "$T/trees"
cat > "$REPO/scripts/herd/agent-watch.sh" <<'S'
#!/usr/bin/env bash
# the watcher — enough shared content that a move stays above git's rename threshold
poll_prs() { echo poll; }
do_old_thing() { echo old; }
c1=1
c2=2
c3=3
S
cat > "$REPO/BACKLOG.md" <<'B'
# project backlog

## Planned
- 🔜 **Harden the watcher** — extend scripts/herd/agent-watch.sh so do_old_thing retries transients
B
git -C "$REPO" init -q
git -C "$REPO" add -A && git -C "$REPO" commit -qm base
git -C "$REPO" mv scripts/herd/agent-watch.sh scripts/herd/watcher.sh
cat > "$REPO/scripts/herd/watcher.sh" <<'S'
#!/usr/bin/env bash
# the watcher — enough shared content that a move stays above git's rename threshold
poll_prs() { echo poll; }
do_new_thing() { echo new; }
c1=1
c2=2
c3=3
S
git -C "$REPO" add -A && git -C "$REPO" commit -qm rename-surface
RANGE="HEAD~1..HEAD"

# ── the capture seam + a base isolated config ─────────────────────────────────────────────────────
REQ="$T/captured-request.txt"
cat > "$T/fake-scribe.sh" <<FS
#!/usr/bin/env bash
printf '%s\n' "\$1" > "$REQ"
FS
chmod +x "$T/fake-scribe.sh"

write_config() {  # <scribe-backend>
  cat > "$REPO/.herd/config" <<EOF
PROJECT_ROOT="$REPO"
WORKTREES_DIR="$T/trees"
DEFAULT_BRANCH="main"
BACKLOG_FILE="BACKLOG.md"
SCRIBE_BACKEND="$1"
EOF
}
export HERD_CONFIG_FILE="$REPO/.herd/config"

# ── 1. FILE backend → `run` enqueues (the reconcile is meaningful) ────────────────────────────────
write_config file
rm -f "$REQ"
out="$(HERD_RECONCILE_SCRIBE="$T/fake-scribe.sh" bash "$SCRIPT" run "$RANGE" 2>&1)" || fail "(1) run exited non-zero: $out"
printf '%s\n' "$out" | grep -q 'enqueued a scribe request' || fail "(1) file backend did not enqueue: $out"
[ -f "$REQ" ] || fail "(1) file backend did not invoke the scribe seam"
pass

# ── 2. TRACKER backend → `run` is INERT (no enqueue, no scribe seam call) ─────────────────────────
# A fake backend dir whose backend defines _backend_update_state (the tracker-dispatch op the file
# backend lacks) — the exact capability tracker-state-sweep probes.
FAKE_DIR="$T/fake-backends"; mkdir -p "$FAKE_DIR"
cat > "$FAKE_DIR/tracker.sh" <<'BK'
#!/usr/bin/env bash
_backend_update_state() { :; }   # marks this as an external-tracker backend
_backend_item_state()   { :; }
BK
write_config tracker
rm -f "$REQ"
out="$(SCRIBE_BACKEND_DIR="$FAKE_DIR" HERD_RECONCILE_SCRIBE="$T/fake-scribe.sh" bash "$SCRIPT" run "$RANGE" 2>&1)" \
  || fail "(2) run exited non-zero under the tracker backend: $out"
printf '%s\n' "$out" | grep -qi 'inert' || fail "(2) tracker backend did not report inert: $out"
printf '%s\n' "$out" | grep -q 'enqueued a scribe request' && fail "(2) tracker backend still enqueued: $out"
[ -f "$REQ" ] && fail "(2) tracker backend still invoked the scribe seam (should be inert)"
pass

# ── 3. surface/scan stay ungated (pure read-only seams the tests drive) ───────────────────────────
write_config tracker
s="$(SCRIBE_BACKEND_DIR="$FAKE_DIR" bash "$SCRIPT" surface "$RANGE" 2>&1)" || fail "(3) surface errored under tracker backend"
printf '%s\n' "$s" | grep -q 'agent-watch.sh' || fail "(3) surface should still work regardless of backend: $s"
pass

echo "ALL PASS ($PASS checks)"
