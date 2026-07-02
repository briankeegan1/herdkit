#!/usr/bin/env bash
# test-workspace-pin.sh — hermetic tests for the workspace-pinning mechanism.
#
# Part A: herd_resolve_workspace_id (herd-config.sh helper):
#   (a) correct id when label found in herdr workspace list
#   (b) empty + warning when herdr is missing
#   (c) empty + warning when workspace list exits non-zero
#   (d) empty + warning when the label is absent
#   (e) empty (no crash) when herdr returns unparseable JSON
#   (f) two distinct names yield two distinct ids
#
# Part B: workspace-aware singleton check (scribe.sh / research.sh):
#   (g) agent in OUR workspace → "already running" (guard fires)
#   (h) agent in DIFFERENT workspace → guard does NOT fire (name+ws mismatch)
#   (i) herdr agent list unknown flag rejected → stub exits non-zero, guard does not crash
#   (j) no _WS_ID (empty) → falls back to name-only match (original behaviour)
#
# Run:  bash tests/test-workspace-pin.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LOADER="$HERE/../scripts/herd/herd-config.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ pass=$((pass+1)); }

SYS="/usr/bin:/bin:/usr/sbin:/sbin"
command -v python3 >/dev/null 2>&1 || fail "python3 required"
case ":$SYS:" in *":$(dirname "$(command -v python3)"):"*) ;; *) SYS="$(dirname "$(command -v python3)"):$SYS";; esac

# write_stub <dir-name> <body> — drop fake herdr into fresh bindir; print path.
write_stub() {
  local bindir="$T/$1"; mkdir -p "$bindir"
  printf '#!/usr/bin/env bash\n%s\n' "$2" > "$bindir/herdr"
  chmod +x "$bindir/herdr"
  printf '%s' "$bindir"
}

# Source loader with controlled WORKSPACE_NAME and PATH; call herd_resolve_workspace_id.
resolve_stdout() {
  local ws="$1" usepath="$2" cfg="$T/cfg-$RANDOM"
  printf 'WORKSPACE_NAME="%s"\n' "$ws" > "$cfg"
  ( cd "$T" && HERD_CONFIG_FILE="$cfg" PATH="$usepath" bash -c ". '$LOADER'; herd_resolve_workspace_id" 2>/dev/null )
}
resolve_stderr() {
  local ws="$1" usepath="$2" cfg="$T/cfg-$RANDOM"
  printf 'WORKSPACE_NAME="%s"\n' "$ws" > "$cfg"
  ( cd "$T" && HERD_CONFIG_FILE="$cfg" PATH="$usepath" bash -c ". '$LOADER'; herd_resolve_workspace_id" 2>&1 1>/dev/null )
}

# Stub: workspace list with two workspaces (alpha→wA, beta→wB); real-herdr-style: unknown
# subcommands/flags exit non-zero with a usage message (herdr agent list has no --workspace flag).
goodstub="$(write_stub good '
case "$1 $2" in
  "workspace list") printf '"'"'{"result":{"workspaces":[{"workspace_id":"wA","label":"alpha"},{"workspace_id":"wB","label":"beta"}]}}\n'"'"' ;;
  "agent list")
    for a in "$@"; do case "$a" in --*) printf "usage: herdr agent list\n" >&2; exit 2;; esac; done
    printf '"'"'{"result":{"agents":[{"name":"scribe-alpha","workspace_id":"wA"},{"name":"scribe-beta","workspace_id":"wB"},{"name":"researcher-alpha","workspace_id":"wA"}]}}\n'"'"' ;;
  *) printf "{}\\n" ;;
esac')"

# ── Part A: herd_resolve_workspace_id ────────────────────────────────────────

# (a) Label found → correct workspace_id.
out="$(resolve_stdout alpha "$goodstub:$SYS")"
[ "$out" = "wA" ] || fail "(a) workspace alpha should resolve to wA (got: '$out')"
ok
out="$(resolve_stdout beta "$goodstub:$SYS")"
[ "$out" = "wB" ] || fail "(a) workspace beta should resolve to wB (got: '$out')"
ok

# (b) herdr missing → empty stdout + warning.
emptybin="$T/noherdr"; mkdir -p "$emptybin"
out="$(resolve_stdout alpha "$emptybin:$SYS")"
[ -z "$out" ] || fail "(b) missing herdr: expected empty id (got: '$out')"
warn="$(resolve_stderr alpha "$emptybin:$SYS")"
printf '%s' "$warn" | grep -qiE "without --workspace|not on PATH" \
  || fail "(b) missing herdr: no warning on stderr (got: $warn)"
ok

# (c) herdr workspace list exits non-zero → empty stdout + warning.
failstub="$(write_stub fail 'exit 1')"
out="$(resolve_stdout alpha "$failstub:$SYS")"
[ -z "$out" ] || fail "(c) failed list: expected empty id (got: '$out')"
warn="$(resolve_stderr alpha "$failstub:$SYS")"
printf '%s' "$warn" | grep -qiE "failed|without --workspace" \
  || fail "(c) failed list: no warning on stderr (got: $warn)"
ok

# (d) Label absent from list → empty stdout + warning.
out="$(resolve_stdout "unknown-project" "$goodstub:$SYS")"
[ -z "$out" ] || fail "(d) unknown label: expected empty id (got: '$out')"
warn="$(resolve_stderr "unknown-project" "$goodstub:$SYS")"
printf '%s' "$warn" | grep -qiE "not found|without --workspace" \
  || fail "(d) unknown label: no warning on stderr (got: $warn)"
ok

# (e) Malformed JSON → empty stdout, no crash.
badjsonstub="$(write_stub badjson '
case "$1 $2" in
  "workspace list") printf "not-valid-json\\n" ;;
  *) printf "{}\\n" ;;
esac')"
out="$(resolve_stdout alpha "$badjsonstub:$SYS")"
[ -z "$out" ] || fail "(e) bad JSON: expected empty id (got: '$out')"
ok

# (f) Two distinct names → two distinct ids.
idA="$(resolve_stdout alpha "$goodstub:$SYS")"
idB="$(resolve_stdout beta "$goodstub:$SYS")"
[ -n "$idA" ] && [ -n "$idB" ] || fail "(f) expected non-empty ids for alpha and beta"
[ "$idA" != "$idB" ] || fail "(f) two distinct workspace names yielded the same id ('$idA')"
ok

# ── Part B: workspace-aware singleton check (python filter) ──────────────────
# The singleton check in scribe.sh and research.sh pipes herdr agent list JSON
# through a python snippet that matches on name AND workspace_id. Test that
# directly by running the same python snippet with controlled JSON input.

# python snippet used in both scribe.sh and research.sh:
PY_CHECK='import sys,json,os
ws=os.environ.get("WS","")
sys.exit(0 if any(
  x.get("name")==os.environ["NAME"] and (not ws or x.get("workspace_id","")==ws)
  for x in json.load(sys.stdin)["result"]["agents"]
) else 1)'

# Agent list with agents in two workspaces.
AGENT_JSON='{"result":{"agents":[
  {"name":"scribe-alpha","workspace_id":"wA"},
  {"name":"scribe-beta","workspace_id":"wB"},
  {"name":"researcher-alpha","workspace_id":"wA"}
]}}'

# (g) Agent in OUR workspace → guard fires (exit 0).
printf '%s' "$AGENT_JSON" | NAME="scribe-alpha" WS="wA" python3 -c "$PY_CHECK" \
  || fail "(g) scribe-alpha in wA should match (guard should fire)"
ok

# (h) Agent with same name but different workspace_id → guard does NOT fire.
printf '%s' "$AGENT_JSON" | NAME="scribe-alpha" WS="wB" python3 -c "$PY_CHECK" \
  && fail "(h) scribe-alpha in wB should NOT match from wA perspective" || true
ok

# (i) herdr agent list stub rejects --workspace (mimics real herdr) → guard sees no-output
#     path; the script must NOT pass --workspace to agent list.
#     Verify the stub's --workspace rejection works as expected.
badflag_out="$(printf '' | PATH="$goodstub:$SYS" herdr agent list --workspace wA 2>/dev/null || true)"
[ -z "$badflag_out" ] || fail "(i) stub should emit no JSON when --workspace is passed (got: '$badflag_out')"
ok

# (j) Empty WS → falls back to name-only match (original behaviour preserved).
printf '%s' "$AGENT_JSON" | NAME="scribe-alpha" WS="" python3 -c "$PY_CHECK" \
  || fail "(j) empty WS should match by name alone"
ok
# Name that does not exist → no match even with empty WS.
printf '%s' "$AGENT_JSON" | NAME="scribe-gamma" WS="" python3 -c "$PY_CHECK" \
  && fail "(j) nonexistent name should not match" || true
ok

echo "ALL PASS ($pass checks)"
