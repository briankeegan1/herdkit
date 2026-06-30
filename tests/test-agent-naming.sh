#!/usr/bin/env bash
# test-agent-naming.sh — hermetic test of the PROJECT-SCOPED singleton agent/tab names derived in
# herd-config.sh. Each project running in one herdr must own its OWN coordinator/scribe/researcher
# singleton; sharing a global name makes two projects collide. This verifies (a) the names resolve
# to the WORKSPACE_NAME-suffixed forms, and (b) two different WORKSPACE_NAMEs yield DISTINCT names
# (proving no collision). No $HOME mutation.
# Run:  bash tests/test-agent-naming.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LOADER="$HERE/../scripts/herd/herd-config.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail(){ echo "FAIL: $1" >&2; exit 1; }

# Source loader in a subshell with a given WORKSPACE_NAME (via a config file), from a cwd with no
# .herd/config above it, and echo the derived scoped identifiers.
load_names() {
  local ws="$1"
  local cfg="$T/cfg.config"
  printf 'WORKSPACE_NAME="%s"\n' "$ws" > "$cfg"
  ( cd "$T" && HERD_CONFIG_FILE="$cfg" bash -c ". '$LOADER'
echo HERD_AGENT_COORDINATOR=\$HERD_AGENT_COORDINATOR
echo HERD_AGENT_SCRIBE=\$HERD_AGENT_SCRIBE
echo HERD_AGENT_RESEARCHER=\$HERD_AGENT_RESEARCHER
echo HERD_TAB_COORDINATOR=\$HERD_TAB_COORDINATOR" )
}

# 1. WORKSPACE_NAME=alpha → every singleton carries the -alpha suffix.
outA="$(load_names alpha)"
echo "$outA" | grep -qx "HERD_AGENT_COORDINATOR=coordinator-alpha" || fail "coordinator name not scoped to -alpha ($outA)"
echo "$outA" | grep -qx "HERD_AGENT_SCRIBE=scribe-alpha"           || fail "scribe name not scoped to -alpha"
echo "$outA" | grep -qx "HERD_AGENT_RESEARCHER=researcher-alpha"   || fail "researcher name not scoped to -alpha"
echo "$outA" | grep -qx "HERD_TAB_COORDINATOR=coordinator-alpha"   || fail "coordinator tab label not scoped to -alpha"

# 2. A DIFFERENT WORKSPACE_NAME yields DISTINCT names — the whole point: two projects in one herdr
#    never share a singleton name, so neither closes the other's tab nor blocks the other's drainer.
outB="$(load_names beta)"
echo "$outB" | grep -qx "HERD_AGENT_COORDINATOR=coordinator-beta" || fail "coordinator name not scoped to -beta ($outB)"
echo "$outB" | grep -qx "HERD_AGENT_SCRIBE=scribe-beta"           || fail "scribe name not scoped to -beta"
echo "$outB" | grep -qx "HERD_AGENT_RESEARCHER=researcher-beta"   || fail "researcher name not scoped to -beta"

get(){ printf '%s\n' "$1" | grep "^$2=" | cut -d= -f2-; }
for key in HERD_AGENT_COORDINATOR HERD_AGENT_SCRIBE HERD_AGENT_RESEARCHER HERD_TAB_COORDINATOR; do
  a="$(get "$outA" "$key")"; b="$(get "$outB" "$key")"
  [ "$a" != "$b" ] || fail "$key collides across projects: '$a' == '$b'"
done

# 3. A WORKSPACE_NAME with shell/JSON-unsafe characters is sanitized to a safe agent/tab slug
#    ([A-Za-z0-9_-] only) so `herdr agent start <name>` / tab labels never choke.
outC="$(load_names 'we/ird name')"
coord="$(get "$outC" HERD_AGENT_COORDINATOR)"
case "$coord" in
  coordinator-*) : ;;
  *) fail "sanitized coordinator name lost its prefix ($coord)" ;;
esac
printf '%s' "$coord" | grep -Eq '^[A-Za-z0-9_-]+$' || fail "sanitized coordinator name has unsafe chars ($coord)"

echo "ALL PASS"
