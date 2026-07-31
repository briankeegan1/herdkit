#!/usr/bin/env bash
# test-herd-config.sh — hermetic test of the herd-config.sh loader. Verifies (a) generic fallback
# defaults apply when no config file is present, and (b) values from a config file override the
# defaults and the derived HERD_REMOTE/HERD_BRANCH_NAME split correctly. No $HOME mutation.
# Run:  bash tests/test-herd-config.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LOADER="$HERE/../scripts/herd/herd-config.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail(){ echo "FAIL: $1" >&2; exit 1; }

# Source loader in a subshell with a given config file, from a cwd with no .herd/config above it.
load_vars() {
  local cfg="$1"
  # Shield the loader from inherited config env (HERD-362): the coordinator/watcher sources
  # herd-config.sh, which EXPORTS MODEL_REVIEW (HERD-353, line ~640). When the gate spawns this
  # suite as a child, that exported MODEL_REVIEW=<machine value> is in the environment and the
  # loader's `: "${MODEL_REVIEW:=default}"` keeps it — reddening a machine-agnostic baseline
  # assertion. Clear the model-resolution inputs so we assert PURE baseline regardless of the
  # host's config or a coordinator-exported override.
  ( cd "$T" && HERD_CONFIG_FILE="$cfg" bash -c "unset MODEL_COORDINATOR MODEL_FEATURE MODEL_QUICK MODEL_SCRIBE MODEL_RESEARCH MODEL_RESOLVER MODEL_REVIEW TOKEN_MODE
. '$LOADER'
echo SCRIBE_BACKEND=\$SCRIBE_BACKEND
echo BACKLOG_FILE=\$BACKLOG_FILE
echo MODEL_FEATURE=\$MODEL_FEATURE
echo MODEL_QUICK=\$MODEL_QUICK
echo MODEL_REVIEW=\$MODEL_REVIEW
echo WATCHER_AUTOMERGE=\$WATCHER_AUTOMERGE
echo HERD_VERSION=\$HERD_VERSION
echo COORDINATOR_CMD=\$COORDINATOR_CMD
echo DEFAULT_BRANCH=\$DEFAULT_BRANCH
echo WORKSPACE_NAME=\$WORKSPACE_NAME
echo HERD_REMOTE=\$HERD_REMOTE
echo HERD_BRANCH_NAME=\$HERD_BRANCH_NAME" )
}

# 1. Fallback defaults — point HERD_CONFIG_FILE at a nonexistent file so the loader uses defaults.
out="$(load_vars "$T/.nonexistent")"
grep -qx "SCRIBE_BACKEND=file" <<< "$out" || fail "default SCRIBE_BACKEND wrong ($out)"
grep -qx "BACKLOG_FILE=BACKLOG.md" <<< "$out" || fail "default BACKLOG_FILE wrong"
# Eco-leaning starter fallbacks (HERD-161): Opus is an escalation tier, not a bare default.
grep -qx "MODEL_FEATURE=claude-sonnet-4-6" <<< "$out" || fail "default MODEL_FEATURE wrong"
grep -qx "MODEL_QUICK=claude-haiku-4-5" <<< "$out" || fail "default MODEL_QUICK wrong"
grep -qx "MODEL_REVIEW=claude-sonnet-4-6" <<< "$out" || fail "default MODEL_REVIEW wrong"
grep -qx "WATCHER_AUTOMERGE=true" <<< "$out" || fail "default WATCHER_AUTOMERGE wrong"
grep -qx "HERD_VERSION=1" <<< "$out" || fail "default HERD_VERSION wrong"
grep -qx "COORDINATOR_CMD=/coordinator" <<< "$out" || fail "default COORDINATOR_CMD wrong"
grep -qx "DEFAULT_BRANCH=origin/main" <<< "$out" || fail "default DEFAULT_BRANCH wrong"
grep -qx "HERD_REMOTE=origin" <<< "$out" || fail "default HERD_REMOTE not derived"
grep -qx "HERD_BRANCH_NAME=main" <<< "$out" || fail "default HERD_BRANCH_NAME not derived"
grep -q  "WORKSPACE_NAME=" <<< "$out" || fail "WORKSPACE_NAME not set"
# Defaults must NOT leak any single-consumer literal.
grep -qi "northstar" <<< "$out" && fail "default config leaked a 'northstar' literal" || true

# 2. Config file override.
mkdir -p "$T/.herd"
cat > "$T/.herd/config" << 'EOF'
PROJECT_ROOT="/tmp/test-proj"
WORKTREES_DIR="/tmp/test-trees"
DEFAULT_BRANCH="upstream/develop"
WORKSPACE_NAME="myapp"
MODEL_FEATURE="claude-sonnet-4-6"
BACKLOG_FILE="TODO.md"
SCRIBE_BACKEND="changelog"
WATCHER_AUTOMERGE="false"
COORDINATOR_CMD="/run-the-herd"
HERD_VERSION=1
EOF
out2="$(load_vars "$T/.herd/config")"
grep -qx "DEFAULT_BRANCH=upstream/develop" <<< "$out2" || fail "config DEFAULT_BRANCH not loaded ($out2)"
grep -qx "WORKSPACE_NAME=myapp" <<< "$out2" || fail "config WORKSPACE_NAME not loaded"
grep -qx "MODEL_FEATURE=claude-sonnet-4-6" <<< "$out2" || fail "config MODEL_FEATURE not loaded"
grep -qx "BACKLOG_FILE=TODO.md" <<< "$out2" || fail "config BACKLOG_FILE not loaded"
grep -qx "SCRIBE_BACKEND=changelog" <<< "$out2" || fail "config SCRIBE_BACKEND not loaded"
grep -qx "WATCHER_AUTOMERGE=false" <<< "$out2" || fail "config WATCHER_AUTOMERGE not loaded"
grep -qx "COORDINATOR_CMD=/run-the-herd" <<< "$out2" || fail "config COORDINATOR_CMD not loaded"
grep -qx "HERD_REMOTE=upstream" <<< "$out2" || fail "HERD_REMOTE not derived from config ($out2)"
grep -qx "HERD_BRANCH_NAME=develop" <<< "$out2" || fail "HERD_BRANCH_NAME not derived from config"

echo "ALL PASS"
