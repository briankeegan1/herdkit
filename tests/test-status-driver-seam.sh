#!/usr/bin/env bash
# test-status-driver-seam.sh — `herd status` reads the builder roster through the driver seam
# (herd_driver_agent_list_json), not raw `herdr agent list` (HERD-160 quick win).
#
# BEHAVIOURAL: stand up a real project with a linked builder worktree and run _status_run twice —
# once with herd_driver_agent_list_json DEFINED (the seam reports the builder alive+working, as it is
# under `herd status`, where bin/herd has sourced driver.sh) and once UNDEFINED (a standalone source
# where the seam degrades to an empty roster). The builder's classification MUST differ between the
# two: a seam that reports the agent working keeps the builder out of the DEAD signature that an
# empty roster (worktree present + no agent + no PR + no commits) produces. That difference is proof
# _status_run consumes the seam's output.
#
# Hermetic: real local git + stubbed gh; no herdr, no network.
# Run:  bash tests/test-status-driver-seam.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
STATUS="$ROOT/scripts/herd/status.sh"
GREP=/usr/bin/grep; command -v "$GREP" >/dev/null 2>&1 || GREP=grep

command -v git     >/dev/null 2>&1 || { echo "FAIL: git required" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 required" >&2; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { PASS=$((PASS+1)); }

# ── Static wiring: status.sh routes through the seam (guarded), no raw `herdr agent list` ──────────
_code() { awk '{ s=$0; sub(/^[ \t]+/,"",s); if (s !~ /^#/) print }' "$STATUS"; }
_code | "$GREP" -qE 'herd_driver_agent_list_json' \
  || fail "status.sh does not read the roster via herd_driver_agent_list_json"
_code | "$GREP" -qE 'declare -f herd_driver_agent_list_json' \
  || fail "status.sh does not GUARD the seam call (declare -f) for standalone-source safety"
_code | "$GREP" -qE 'herdr agent list' \
  && fail "status.sh still contains a raw 'herdr agent list' call"
pass

# ── Stub gh on PATH (no network): `gh pr list` → empty array ───────────────────────────────────────
BIN="$T/bin"; mkdir -p "$BIN"
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = "pr" ] && { echo '[]'; exit 0; }
exit 0
EOF
chmod +x "$BIN/gh"
export PATH="$BIN:$PATH"

# ── A real project + a linked builder worktree (no PR, no commits ahead → the DEAD signature) ──────
export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_SYSTEM=/dev/null
git config --file "$T/gitconfig" user.email t@herd.local
git config --file "$T/gitconfig" user.name  "herd test"
git config --file "$T/gitconfig" init.defaultBranch main
git config --file "$T/gitconfig" commit.gpgsign false

PROJ="$T/proj"; TREES="$T/proj-trees"; mkdir -p "$PROJ"
( cd "$PROJ" && git init -q && printf 'base\n' > f.txt && git add f.txt && git commit -q -m init )
git -C "$PROJ" worktree add -q -b feat/myslug "$TREES/myslug" >/dev/null 2>&1 \
  || fail "could not create the builder worktree"

# _run <want-seam> — source status.sh fresh, optionally define the seam stub (roster: myslug working),
# and run _status_run against the project. Runs in a subshell so the two invocations don't cross-talk.
_run() {
  local want="$1"
  (
    export PROJECT_ROOT="$PROJ" WORKTREES_DIR="$TREES" WORKSPACE_NAME=proj DEFAULT_BRANCH=main
    # shellcheck source=/dev/null
    . "$STATUS"
    if [ "$want" = "seam" ]; then
      herd_driver_agent_list_json() { printf '%s' '{"result":{"agents":[{"name":"myslug","agent_status":"working"}]}}'; }
    fi
    _status_run 2>/dev/null
  )
}

with_seam="$(_run seam)"
no_seam="$(_run none)"

# Both must show the builder row for myslug at all.
printf '%s' "$with_seam" | "$GREP" -q 'myslug' || fail "status row for the builder is missing (with seam)"
printf '%s' "$no_seam"   | "$GREP" -q 'myslug' || fail "status row for the builder is missing (no seam)"
pass

# The classification MUST differ: the seam-fed roster (agent working) is NOT the empty-roster DEAD
# signature. Compare only the myslug line so unrelated output (watcher pid, timing) can't mask it.
line_seam="$(printf '%s\n' "$with_seam" | "$GREP" 'myslug' | head -1)"
line_none="$(printf '%s\n' "$no_seam"   | "$GREP" 'myslug' | head -1)"
[ "$line_seam" != "$line_none" ] \
  || fail "builder classification identical with/without the seam — status.sh is not consuming herd_driver_agent_list_json
  seam: $line_seam
  none: $line_none"
pass

# And concretely: the seam-fed row must NOT read DEAD, while the empty-roster row DOES.
printf '%s' "$line_none" | "$GREP" -qi 'dead' \
  || fail "empty roster did not yield the DEAD signature (test premise broken): $line_none"
printf '%s' "$line_seam" | "$GREP" -qi 'dead' \
  && fail "seam reported the agent working yet status still marked it DEAD: $line_seam"
pass

git -C "$PROJ" worktree remove --force "$TREES/myslug" >/dev/null 2>&1 || true
echo "ALL PASS ($PASS checks)"
