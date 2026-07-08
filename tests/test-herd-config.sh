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
  ( cd "$T" && HERD_CONFIG_FILE="$cfg" bash -c ". '$LOADER'
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
echo "$out" | grep -qx "SCRIBE_BACKEND=file"            || fail "default SCRIBE_BACKEND wrong ($out)"
echo "$out" | grep -qx "BACKLOG_FILE=BACKLOG.md"        || fail "default BACKLOG_FILE wrong"
# Eco-leaning starter fallbacks (HERD-161): Opus is an escalation tier, not a bare default.
echo "$out" | grep -qx "MODEL_FEATURE=claude-sonnet-4-6" || fail "default MODEL_FEATURE wrong"
echo "$out" | grep -qx "MODEL_QUICK=claude-haiku-4-5"    || fail "default MODEL_QUICK wrong"
echo "$out" | grep -qx "MODEL_REVIEW=claude-sonnet-4-6"  || fail "default MODEL_REVIEW wrong"
echo "$out" | grep -qx "WATCHER_AUTOMERGE=true"         || fail "default WATCHER_AUTOMERGE wrong"
echo "$out" | grep -qx "HERD_VERSION=1"                 || fail "default HERD_VERSION wrong"
echo "$out" | grep -qx "COORDINATOR_CMD=/coordinator"   || fail "default COORDINATOR_CMD wrong"
echo "$out" | grep -qx "DEFAULT_BRANCH=origin/main"     || fail "default DEFAULT_BRANCH wrong"
echo "$out" | grep -qx "HERD_REMOTE=origin"             || fail "default HERD_REMOTE not derived"
echo "$out" | grep -qx "HERD_BRANCH_NAME=main"          || fail "default HERD_BRANCH_NAME not derived"
echo "$out" | grep -q  "WORKSPACE_NAME="                || fail "WORKSPACE_NAME not set"
# Defaults must NOT leak any single-consumer literal.
echo "$out" | grep -qi "northstar" && fail "default config leaked a 'northstar' literal" || true

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
echo "$out2" | grep -qx "DEFAULT_BRANCH=upstream/develop"  || fail "config DEFAULT_BRANCH not loaded ($out2)"
echo "$out2" | grep -qx "WORKSPACE_NAME=myapp"             || fail "config WORKSPACE_NAME not loaded"
echo "$out2" | grep -qx "MODEL_FEATURE=claude-sonnet-4-6"  || fail "config MODEL_FEATURE not loaded"
echo "$out2" | grep -qx "BACKLOG_FILE=TODO.md"             || fail "config BACKLOG_FILE not loaded"
echo "$out2" | grep -qx "SCRIBE_BACKEND=changelog"         || fail "config SCRIBE_BACKEND not loaded"
echo "$out2" | grep -qx "WATCHER_AUTOMERGE=false"          || fail "config WATCHER_AUTOMERGE not loaded"
echo "$out2" | grep -qx "COORDINATOR_CMD=/run-the-herd"    || fail "config COORDINATOR_CMD not loaded"
echo "$out2" | grep -qx "HERD_REMOTE=upstream"             || fail "HERD_REMOTE not derived from config ($out2)"
echo "$out2" | grep -qx "HERD_BRANCH_NAME=develop"         || fail "HERD_BRANCH_NAME not derived from config"

echo "ALL PASS"
