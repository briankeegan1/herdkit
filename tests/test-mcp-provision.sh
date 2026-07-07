#!/usr/bin/env bash
# test-mcp-provision.sh — hermetic proof for the builder MCP tool-provisioning surface (HERD-41).
#
# MCP_PROVISION is a space-separated list of MCP server names wired into every spawned builder
# worktree's project-level .claude/settings.json (its `mcpServers` block) by herd_write_mcp_servers
# (herd-config.sh, called from new-feature.sh). It is the TOOLS sibling of the context-provisioning
# surface (HERD-40). This test drives the function directly and inspects the resulting settings.json.
#
# Asserts:
#   (a) OFF (unset, the default)         → NOTHING is written: a pre-existing settings.json is left
#       BYTE-IDENTICAL, and no file is created when none existed.
#   (b) ON  (MCP_PROVISION=context7)     → an mcpServers.context7 entry lands with the built-in
#       command/args and a "${VAR}" env passthrough reference — and the merge preserves an existing
#       rate-limit hook in the same file (additive, never clobbers unrelated keys).
#   (c) PRIVACY                          → the secret VALUE never appears in the file; only the
#       "${CONTEXT7_API_KEY}" reference string is written.
#   (d) NON-CLOBBER                      → a user/hand-authored server of the SAME name is left exactly
#       as-is (never overwritten), while a not-yet-present built-in is still added alongside it.
#   (e) IDEMPOTENT                       → a second run once wired changes nothing (byte-identical).
#   (f) PER-SERVER OVERRIDE + custom     → MCP_<NAME>_COMMAND/_ARGS/_ENV replace the built-in, and a
#       server with NO built-in is wired purely from a _COMMAND override.
#   (g) UNKNOWN server (no built-in, no override) → ignored, no entry, no error (forward-compatible).
#
# Fully hermetic: a temp dir, a sandboxed $HOME, and a stub config so sourcing herd-config.sh never
# touches the real project. NETWORK-FREE — the function only writes a local JSON file.
# Run:  bash tests/test-mcp-provision.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CONFIG_SH="$HERE/../scripts/herd/herd-config.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass(){ PASS=$((PASS+1)); }
command -v python3 >/dev/null 2>&1 || fail "python3 required to run this test"

# ── Hermetic env: a stub config so sourcing herd-config.sh binds to the sandbox, not the real repo ──
export HOME="$T"
CFG="$T/config"; : > "$CFG"
export HERD_CONFIG_FILE="$CFG"
# shellcheck source=/dev/null
. "$CONFIG_SH"    # defines herd_write_mcp_servers (+ herd_write_ratelimit_hook)

# jval <file> <python-expr over `d` (the parsed dict)> — print a value from the settings JSON.
jval(){ python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"; }
# fresh <name> — a clean worktree dir; returns its settings.json path on stdout.
fresh(){ local d="$T/$1"; rm -rf "$d"; mkdir -p "$d"; printf '%s' "$d/.claude/settings.json"; }

# Reset all MCP_* knobs between cases so a stray value never leaks across tests.
clear_mcp(){ unset MCP_PROVISION MCP_CONTEXT7_COMMAND MCP_CONTEXT7_ARGS MCP_CONTEXT7_ENV \
                   MCP_MYSERVER_COMMAND MCP_MYSERVER_ARGS MCP_MYSERVER_ENV 2>/dev/null || true; }

# ── (a) OFF (unset, the default) → nothing written; pre-existing file byte-identical ────────────────
clear_mcp
d="$T/off"; mkdir -p "$d/.claude"
sfile="$d/.claude/settings.json"
printf '{\n  "hooks": {"StopFailure": []},\n  "permissions": {"allow": ["x"]}\n}\n' > "$sfile"
before="$(cat "$sfile")"
herd_write_mcp_servers "$d" || fail "(a) function returned non-zero"
[ "$(cat "$sfile")" = "$before" ] || fail "(a) OFF but settings.json was modified"
# And with no file at all, none is created.
d2="$T/off-nofile"; mkdir -p "$d2"
herd_write_mcp_servers "$d2" || fail "(a) function returned non-zero (no-file case)"
[ ! -f "$d2/.claude/settings.json" ] || fail "(a) OFF created a settings.json where none existed"
pass; echo "PASS (a) MCP_PROVISION unset → nothing written (byte-identical / no file created)"

# ── (b) ON (context7) → built-in entry + "${VAR}" env, merged alongside an existing rate-limit hook ──
clear_mcp
d="$T/on"; mkdir -p "$d"
sfile="$(fresh on)"
herd_write_ratelimit_hook "$d" >/dev/null 2>&1 || true   # seed a real hook to prove the merge is additive
[ -f "$sfile" ] || fail "(b) precondition: rate-limit hook did not create settings.json"
export MCP_PROVISION="context7"
herd_write_mcp_servers "$d" || fail "(b) function returned non-zero"
[ "$(jval "$sfile" "d['mcpServers']['context7']['command']")" = "npx" ] \
  || fail "(b) context7 command is not the built-in npx"
[ "$(jval "$sfile" "d['mcpServers']['context7']['args']")" = "['-y', '@upstash/context7-mcp']" ] \
  || fail "(b) context7 args are not the built-in list"
[ "$(jval "$sfile" "d['mcpServers']['context7']['env']['CONTEXT7_API_KEY']")" = '${CONTEXT7_API_KEY}' ] \
  || fail "(b) context7 env is not a \${VAR} passthrough reference"
# The additive merge preserved the rate-limit hook written first.
[ "$(jval "$sfile" "d['hooks']['StopFailure'][0]['matcher']")" = "rate_limit" ] \
  || fail "(b) the merge clobbered the existing rate-limit hook"
pass; echo "PASS (b) context7 wired from built-in, alongside the preserved rate-limit hook"

# ── (c) PRIVACY → the secret VALUE never lands in the file ───────────────────────────────────────────
export CONTEXT7_API_KEY="SUPER_SECRET_VALUE_DO_NOT_WRITE"
d="$T/priv"; mkdir -p "$d"; sfile="$(fresh priv)"
herd_write_mcp_servers "$d" || fail "(c) function returned non-zero"
grep -q "SUPER_SECRET_VALUE_DO_NOT_WRITE" "$sfile" && fail "(c) the secret VALUE leaked into settings.json"
grep -q '${CONTEXT7_API_KEY}' "$sfile" || fail "(c) the \${VAR} reference is missing"
unset CONTEXT7_API_KEY
pass; echo "PASS (c) secret value never written — only the \${VAR} passthrough reference"

# ── (d) NON-CLOBBER → an existing same-name server is left as-is; a new built-in is added alongside ──
clear_mcp
d="$T/noclobber"; mkdir -p "$d/.claude"; sfile="$d/.claude/settings.json"
cat > "$sfile" <<'JSON'
{
  "mcpServers": {
    "context7": {"command": "USER_OWNED_BINARY", "args": ["--mine"]},
    "keepme": {"command": "unrelated"}
  }
}
JSON
export MCP_PROVISION="context7 graphify-mcp"
herd_write_mcp_servers "$d" || fail "(d) function returned non-zero"
[ "$(jval "$sfile" "d['mcpServers']['context7']['command']")" = "USER_OWNED_BINARY" ] \
  || fail "(d) an existing same-name server was overwritten"
[ "$(jval "$sfile" "d['mcpServers']['keepme']['command']")" = "unrelated" ] \
  || fail "(d) an unrelated existing server was dropped"
[ "$(jval "$sfile" "d['mcpServers']['graphify-mcp']['command']")" = "graphify-mcp" ] \
  || fail "(d) the not-yet-present built-in was not added alongside the user's server"
pass; echo "PASS (d) non-clobber: existing server preserved, new built-in added alongside"

# ── (e) IDEMPOTENT → a second run changes nothing ────────────────────────────────────────────────────
clear_mcp
export MCP_PROVISION="context7"
d="$T/idem"; mkdir -p "$d"; sfile="$(fresh idem)"
herd_write_mcp_servers "$d" || fail "(e) first run returned non-zero"
first="$(cat "$sfile")"
herd_write_mcp_servers "$d" || fail "(e) second run returned non-zero"
[ "$(cat "$sfile")" = "$first" ] || fail "(e) a second run changed the file (not idempotent)"
pass; echo "PASS (e) idempotent — re-running once wired is a no-op"

# ── (f) PER-SERVER OVERRIDE + a custom server with no built-in ───────────────────────────────────────
clear_mcp
export MCP_PROVISION="context7 myserver"
export MCP_CONTEXT7_COMMAND="my-context7"          # override the built-in command
export MCP_CONTEXT7_ARGS="--flag one two"          # override the built-in args
export MCP_CONTEXT7_ENV="FOO_TOKEN BAR_TOKEN"      # override the built-in env passthrough list
export MCP_MYSERVER_COMMAND="run-myserver"         # a server with NO built-in — wired purely by override
d="$T/override"; mkdir -p "$d"; sfile="$(fresh override)"
herd_write_mcp_servers "$d" || fail "(f) function returned non-zero"
[ "$(jval "$sfile" "d['mcpServers']['context7']['command']")" = "my-context7" ] \
  || fail "(f) _COMMAND override did not take effect"
[ "$(jval "$sfile" "d['mcpServers']['context7']['args']")" = "['--flag', 'one', 'two']" ] \
  || fail "(f) _ARGS override did not take effect"
[ "$(jval "$sfile" "sorted(d['mcpServers']['context7']['env'].keys())")" = "['BAR_TOKEN', 'FOO_TOKEN']" ] \
  || fail "(f) _ENV override did not take effect"
[ "$(jval "$sfile" "d['mcpServers']['context7']['env']['FOO_TOKEN']")" = '${FOO_TOKEN}' ] \
  || fail "(f) overridden env is not a \${VAR} reference"
[ "$(jval "$sfile" "d['mcpServers']['myserver']['command']")" = "run-myserver" ] \
  || fail "(f) a custom no-built-in server was not wired from its _COMMAND override"
pass; echo "PASS (f) per-server COMMAND/ARGS/ENV overrides + custom no-built-in server"

# ── (g) UNKNOWN server (no built-in, no override) → ignored, no entry, no error ──────────────────────
clear_mcp
export MCP_PROVISION="totally-unknown-server"
d="$T/unknown"; mkdir -p "$d"; sfile="$(fresh unknown)"
herd_write_mcp_servers "$d" || fail "(g) function returned non-zero for an unknown server"
[ ! -f "$sfile" ] || fail "(g) an unknown server produced a settings.json (should write nothing)"
pass; echo "PASS (g) unknown server ignored (forward-compatible, no write, no error)"

clear_mcp
echo "ALL PASS ($PASS groups)"
