#!/usr/bin/env bash
# test-workspace-pin.sh — hermetic tests for the workspace-pinning mechanism.
# Verifies herd_resolve_workspace_id in herd-config.sh:
#   (a) correct id when workspace label is found in herdr workspace list
#   (b) empty + stderr warning when herdr is missing
#   (c) empty + stderr warning when workspace list exits non-zero
#   (d) empty + stderr warning when the label is absent from the list
#   (e) empty (no crash) when herdr returns unparseable JSON
#   (f) two distinct workspace names yield two distinct ids
# Run:  bash tests/test-workspace-pin.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LOADER="$HERE/../scripts/herd/herd-config.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ pass=$((pass+1)); }

# Ensure python3 is reachable in the controlled SYS path used by stubs.
SYS="/usr/bin:/bin:/usr/sbin:/sbin"
command -v python3 >/dev/null 2>&1 || fail "python3 required"
case ":$SYS:" in *":$(dirname "$(command -v python3)"):"*) ;; *) SYS="$(dirname "$(command -v python3)"):$SYS";; esac

# write_stub <dir-name> <body> — drop a fake herdr into a fresh bindir; print the bindir path.
write_stub() {
  local bindir="$T/$1"; mkdir -p "$bindir"
  printf '#!/usr/bin/env bash\n%s\n' "$2" > "$bindir/herdr"
  chmod +x "$bindir/herdr"
  printf '%s' "$bindir"
}

# Source the loader with a controlled WORKSPACE_NAME and PATH; call herd_resolve_workspace_id.
# Captures stdout (the id) and stderr (any warnings) separately.
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

# Stub: workspace list with two workspaces, alpha→wA, beta→wB.
goodstub="$(write_stub good '
case "$1 $2" in
  "workspace list") printf '"'"'{"result":{"workspaces":[{"workspace_id":"wA","label":"alpha"},{"workspace_id":"wB","label":"beta"}]}}\n'"'"' ;;
  *) printf "{}\\n" ;;
esac')"

# ── (a) Label found → correct workspace_id printed ───────────────────────────
out="$(resolve_stdout alpha "$goodstub:$SYS")"
[ "$out" = "wA" ] || fail "(a) workspace alpha should resolve to wA (got: '$out')"
ok

out="$(resolve_stdout beta "$goodstub:$SYS")"
[ "$out" = "wB" ] || fail "(a) workspace beta should resolve to wB (got: '$out')"
ok

# ── (b) herdr missing → empty stdout + warning on stderr ─────────────────────
emptybin="$T/noherdr"; mkdir -p "$emptybin"
out="$(resolve_stdout alpha "$emptybin:$SYS")"
[ -z "$out" ] || fail "(b) missing herdr: expected empty id (got: '$out')"
warn="$(resolve_stderr alpha "$emptybin:$SYS")"
printf '%s' "$warn" | grep -qiE "without --workspace|not on PATH" \
  || fail "(b) missing herdr: no warning on stderr (got: $warn)"
ok

# ── (c) herdr workspace list exits non-zero → empty stdout + warning ─────────
failstub="$(write_stub fail 'exit 1')"
out="$(resolve_stdout alpha "$failstub:$SYS")"
[ -z "$out" ] || fail "(c) failed list: expected empty id (got: '$out')"
warn="$(resolve_stderr alpha "$failstub:$SYS")"
printf '%s' "$warn" | grep -qiE "failed|without --workspace" \
  || fail "(c) failed list: no warning on stderr (got: $warn)"
ok

# ── (d) Label absent from list → empty stdout + warning ──────────────────────
out="$(resolve_stdout "unknown-project" "$goodstub:$SYS")"
[ -z "$out" ] || fail "(d) unknown label: expected empty id (got: '$out')"
warn="$(resolve_stderr "unknown-project" "$goodstub:$SYS")"
printf '%s' "$warn" | grep -qiE "not found|without --workspace" \
  || fail "(d) unknown label: no warning on stderr (got: $warn)"
ok

# ── (e) Malformed JSON → empty stdout, no crash ───────────────────────────────
badjsonstub="$(write_stub badjson '
case "$1 $2" in
  "workspace list") printf "not-valid-json\\n" ;;
  *) printf "{}\\n" ;;
esac')"
out="$(resolve_stdout alpha "$badjsonstub:$SYS")"
[ -z "$out" ] || fail "(e) bad JSON: expected empty id (got: '$out')"
ok

# ── (f) Two distinct names → two distinct ids ────────────────────────────────
idA="$(resolve_stdout alpha "$goodstub:$SYS")"
idB="$(resolve_stdout beta "$goodstub:$SYS")"
[ -n "$idA" ] || fail "(f) alpha produced empty id"
[ -n "$idB" ] || fail "(f) beta produced empty id"
[ "$idA" != "$idB" ] || fail "(f) two distinct workspace names yielded the same id ('$idA')"
ok

echo "ALL PASS ($pass checks)"
