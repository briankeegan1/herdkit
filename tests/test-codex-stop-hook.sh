#!/usr/bin/env bash
# test-codex-stop-hook.sh — hermetic proof for HERD-788: Codex interactive builder stop-hook lever.
#
# Invokes the REAL herd_driver_launch_agent (the generalized interactive launch seam that
# herd-quick.sh and herd-feature.sh call for every builder spawn) with a stubbed herdr bridge
# that captures the complete runtime argv instead of starting a real pane. The captured argv is
# then parsed to prove hook args precede the prompt, and the generated hook scripts are executed
# to prove the marker semantics.
#
#   (1) herd_driver_launch_agent with codex driver + CODEX_STOP_HOOK=on: the stubbed herdr bridge
#       captures the full runtime argv; the real argv-fragment parser (python3 against the actual
#       hooks.Stop=[...] TOML string) extracts stop.sh and user-prompt-submit.sh command paths.
#       The TOML command value uses \"PATH\" quoting so spaces in WORKTREES_DIR are handled.
#   (2) Hook flags appear BEFORE the positional prompt (last element) in the captured argv.
#   (3) Stop hook script: JSON input with turn_id → last-turn written, current-turn cleared, {} printed.
#   (4) UserPromptSubmit hook: → current-turn written with numeric timestamp, {} printed.
#   (5) BYTE-IDENTICAL when off: CODEX_STOP_HOOK=off → herd_driver_launch_agent emits no hook flags.
#   (6) BYTE-IDENTICAL for non-codex: herdr-claude driver with CODEX_STOP_HOOK=on → no hook flags.
#   (7) Stale-marker lever-off safety: hook markers on disk + CODEX_STOP_HOOK=off →
#       _herd_codex_hook_lifecycle returns nothing (lever guard). _reap_agent_working defers.
#   (8) Stale-marker driver-switch safety: hook markers + spawn driver = herdr-claude (driver switch) →
#       _herd_codex_hook_lifecycle returns nothing (driver guard). _reap_agent_working defers.
#   (9) Retirement integration: CODEX_STOP_HOOK=on + spawn driver = codex + hook idle → _reap_agent_working
#       returns 1 (reap path). On main this fails because _reap_agent_working treated raw working as conclusive.
#  (10) Space-path portability: WORKTREES_DIR containing a space → hook scripts are generated and
#       executable, TOML command value is correctly \"double-quoted\" so the path survives shell splitting.
#
# Fails on main at (1) because _herd_codex_stop_hook_argv_fragment did not exist before HERD-788.
#
# Fully hermetic: temp dir only. No real herdr, no gh, no network, no model, no real codex binary.
# Run:  bash tests/test-codex-stop-hook.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../scripts/herd/agent-watch.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

export JOURNAL_FILE="$T/journal.jsonl"
export HERD_JOURNAL_HERMETIC=1

[ -f "$WATCH" ] || fail "agent-watch.sh not found at $WATCH"
command -v python3 >/dev/null 2>&1 || fail "python3 required"

BIN="$T/bin"; mkdir -p "$BIN"
# gh stub (must be on PATH for agent-watch lib-mode sourcing)
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$BIN/gh"
export PATH="$BIN:$PATH"

# Source agent-watch.sh in lib mode — provides driver.sh functions including
# herd_driver_launch_agent, _herd_codex_stop_hook_argv_fragment, _herd_codex_hook_lifecycle,
# herd_driver_agent_spawn_driver_write/read, _reap_agent_working, herd_driver_agent_status_resolved_ex.
export AGENT_WATCH_LIB=1
export HERD_CONFIG_FILE="$T/no-such-config"
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"

# Verify HERD-788 functions exist (fails on main immediately).
command -v _herd_codex_stop_hook_argv_fragment >/dev/null 2>&1 \
  || fail "_herd_codex_stop_hook_argv_fragment not defined — HERD-788 not applied"
command -v _herd_codex_hook_lifecycle >/dev/null 2>&1 \
  || fail "_herd_codex_hook_lifecycle not defined — HERD-788 not applied"

# Worktree root: WORKTREES_DIR is what _herd_agent_dir uses.
export WORKTREES_DIR="$T/trees"
mkdir -p "$WORKTREES_DIR"

# Fake working tree for herd_driver_launch_agent's cwd parameter.
FAKE_WT="$T/fake-wt"; mkdir -p "$FAKE_WT"

# ── HERDR STUB BRIDGE ────────────────────────────────────────────────────────────────────────────
# Stub herdr to capture its complete argv (NUL-separated) to a capture file, then return 0.
# This exercises the legacy (pre-0.7.5) path of herd_driver_launch_agent, which does:
#   argv=(herdr agent start <name> --cwd <cwd> [--tab <id>] [--no-focus] -- <rt...>)
#   "${argv[@]}"
# Force the legacy path so the argv is built in the shell and we can intercept it.
export HERD_HERDR_ATTACH_CLI=no
ARGV_CAPTURE="$T/herdr-argv"
# Override the herdr shell function with a capturing version.
herdr() {
  # Write each arg NUL-terminated to the capture file so spaces/newlines in args are safe.
  printf '%s\0' "$@" >> "$ARGV_CAPTURE"
  # Also append a record separator so multiple calls are distinguishable.
  printf '\xff' >> "$ARGV_CAPTURE"
  return 0
}
# herd_resolve_workspace_id is called when workspace= is not set; stub it to avoid herdr calls.
herd_resolve_workspace_id() { printf ''; return 0; }

# ── (1) herd_driver_launch_agent with codex + CODEX_STOP_HOOK=on ────────────────────────────────
CODEX_STOP_HOOK=on
SLUG1="test-788-codex"

: > "$ARGV_CAPTURE"
herd_driver_launch_agent \
  "name=$SLUG1" "workspace=" "cwd=$FAKE_WT" "tab=fake-tab-111" \
  "driver=codex" "model=o4-mini" "flags=--dangerously-bypass-approvals-and-sandbox" \
  "pointer=build the thing" 2>/dev/null || true

# Extract the argv after the `--` separator from the first herdr call.
_runtime_args=()
_sep_seen=0
while IFS= read -r -d '' _tok; do
  if [ "$_tok" = "--" ]; then _sep_seen=1; continue; fi
  if [ "$_tok" = "$(printf '\xff')" ]; then break; fi
  [ "$_sep_seen" = "1" ] && _runtime_args+=("$_tok")
done < "$ARGV_CAPTURE"

[ "${#_runtime_args[@]}" -gt 0 ] || fail "(1) no runtime argv captured from herd_driver_launch_agent"

# Parse the captured runtime argv: find hooks.Stop and hooks.UserPromptSubmit elements.
_stop_cmd=""
_ups_cmd=""
for _a in "${_runtime_args[@]}"; do
  case "$_a" in
    *"hooks.Stop="*)
      # Parse command path from the TOML string. The generated format is:
      #   command="\"PATH\"" (TOML-escaped double quotes around the path for space safety)
      # Python regex r'command="\\\"([^"]+)\\\""' matches command=" + \ + " + PATH + \ + " + "
      _stop_cmd="$(python3 -c '
import sys, re
s = sys.argv[1]
m = re.search(r'"'"'command="\\\"([^"]+)\\\""'"'"', s)
if not m:
    m = re.search(r'"'"'command="([^"\\\\]+)"'"'"', s)
if m: print(m.group(1))
' "$_a" 2>/dev/null || true)"
      ;;
    *"hooks.UserPromptSubmit="*)
      _ups_cmd="$(python3 -c '
import sys, re
s = sys.argv[1]
m = re.search(r'"'"'command="\\\"([^"]+)\\\""'"'"', s)
if not m:
    m = re.search(r'"'"'command="([^"\\\\]+)"'"'"', s)
if m: print(m.group(1))
' "$_a" 2>/dev/null || true)"
      ;;
  esac
done
[ -n "$_stop_cmd" ] || fail "(1) stop command path not extractable from hooks.Stop TOML — wrong shape or snake_case"
[ -n "$_ups_cmd" ]  || fail "(1) ups command path not extractable from hooks.UserPromptSubmit TOML — wrong shape"
[ -x "$_stop_cmd" ] || fail "(1) stop.sh not executable: $_stop_cmd"
[ -x "$_ups_cmd" ]  || fail "(1) user-prompt-submit.sh not executable: $_ups_cmd"
# Assert PascalCase, not snake_case.
for _a in "${_runtime_args[@]}"; do
  case "$_a" in
    *"hooks.stop="*|*"hooks.user_prompt_submit="*)
      fail "(1) snake_case event name found — must be PascalCase: $_a" ;;
  esac
done
# Assert --dangerously-bypass-hook-trust is present.
_found_trust=0
for _a in "${_runtime_args[@]}"; do [ "$_a" = "--dangerously-bypass-hook-trust" ] && _found_trust=1; done
[ "$_found_trust" = "1" ] || fail "(1) --dangerously-bypass-hook-trust missing from runtime argv"
ok; echo "PASS (1) herd_driver_launch_agent emits PascalCase hook argv, command paths extractable"

# ── (2) Hook flags precede the prompt (last element in runtime argv) ─────────────────────────────
_last_arg="${_runtime_args[${#_runtime_args[@]}-1]}"
[ "$_last_arg" = "build the thing" ] \
  || fail "(2) last element of runtime argv is not the prompt — post-prompt regression: got '$_last_arg'"
# Find the last hook flag index and confirm it is before the prompt.
_last_hook_idx=-1
for _i in "${!_runtime_args[@]}"; do
  case "${_runtime_args[$_i]}" in
    *"hooks.Stop="*|*"hooks.UserPromptSubmit="*|"--dangerously-bypass-hook-trust")
      _last_hook_idx="$_i" ;;
  esac
done
_prompt_idx="$((${#_runtime_args[@]}-1))"
[ "$_last_hook_idx" -ge 0 ]         || fail "(2) no hook flag found in runtime argv"
[ "$_last_hook_idx" -lt "$_prompt_idx" ] \
  || fail "(2) hook flag at idx $_last_hook_idx comes AFTER prompt at idx $_prompt_idx"
ok; echo "PASS (2) hook flags precede the positional prompt in runtime argv"

# ── (3) Stop hook: JSON input → last-turn written, current-turn cleared, {} printed ─────────────
HOOK_DIR1="$WORKTREES_DIR/.herd/agents/$SLUG1/hook"
[ -d "$HOOK_DIR1" ] || fail "(3) hook dir not created by herd_driver_launch_agent"
# Seed current-turn to verify the stop hook clears it.
printf 'old-ts' > "$HOOK_DIR1/current-turn"
STOP_JSON='{"turn_id":"turn-abc-123","stop_hook_active":false,"last_assistant_message":"done"}'
_stop_out="$(printf '%s' "$STOP_JSON" | bash "$_stop_cmd" 2>/dev/null)"
[ "$_stop_out" = "{}" ] || fail "(3) stop.sh must print {} — got: $_stop_out"
[ -f "$HOOK_DIR1/last-turn" ]       || fail "(3) stop.sh did not write hook/last-turn"
_lt="$(cat "$HOOK_DIR1/last-turn")"
[ "$_lt" = "turn-abc-123" ]         || fail "(3) last-turn must contain turn_id, got: $_lt"
[ ! -f "$HOOK_DIR1/current-turn" ]  || fail "(3) stop.sh must clear hook/current-turn"
ok; echo "PASS (3) stop.sh writes last-turn with turn_id and clears current-turn"

# ── (4) UserPromptSubmit hook: → current-turn timestamp written, {} printed ─────────────────────
rm -f "$HOOK_DIR1/last-turn"
_ups_out="$(bash "$_ups_cmd" 2>/dev/null)"
[ "$_ups_out" = "{}" ] || fail "(4) user-prompt-submit.sh must print {} — got: $_ups_out"
[ -f "$HOOK_DIR1/current-turn" ]    || fail "(4) user-prompt-submit.sh did not write hook/current-turn"
_ct="$(cat "$HOOK_DIR1/current-turn")"
[ -n "$_ct" ] || fail "(4) current-turn must be non-empty"
python3 -c "int('$_ct')" 2>/dev/null || fail "(4) current-turn must be a numeric timestamp, got: $_ct"
ok; echo "PASS (4) user-prompt-submit.sh writes numeric timestamp to current-turn"

# ── (5) BYTE-IDENTICAL when CODEX_STOP_HOOK=off ──────────────────────────────────────────────────
CODEX_STOP_HOOK=off
SLUG5="test-788-off"
: > "$ARGV_CAPTURE"
herd_driver_launch_agent \
  "name=$SLUG5" "workspace=" "cwd=$FAKE_WT" "tab=fake-tab-555" \
  "driver=codex" "model=o4-mini" "flags=--dangerously-bypass-approvals-and-sandbox" \
  "pointer=build the thing" 2>/dev/null || true

_rt_off=()
_sep=0
while IFS= read -r -d '' _tok; do
  if [ "$_tok" = "--" ]; then _sep=1; continue; fi
  if [ "$_tok" = "$(printf '\xff')" ]; then break; fi
  [ "$_sep" = "1" ] && _rt_off+=("$_tok")
done < "$ARGV_CAPTURE"

# Element-for-element comparison against herd_driver_agent_spawn_argv baseline (byte-identical invariant).
_expected5=()
while IFS= read -r -d '' _t; do _expected5+=("$_t"); done \
  < <(herd_driver_agent_spawn_argv "codex" "o4-mini" "--dangerously-bypass-approvals-and-sandbox" "build the thing" 2>/dev/null)
[ "${#_expected5[@]}" -gt 0 ] || fail "(5) herd_driver_agent_spawn_argv returned nothing — function broken"
[ "${#_rt_off[@]}" = "${#_expected5[@]}" ] \
  || fail "(5) off-path argv length ${#_rt_off[@]} != baseline ${#_expected5[@]} from herd_driver_agent_spawn_argv"
for _i in "${!_expected5[@]}"; do
  [ "${_rt_off[$_i]:-}" = "${_expected5[$_i]}" ] \
    || fail "(5) off-path argv[$_i] mismatch: captured='${_rt_off[$_i]:-}' baseline='${_expected5[$_i]}'"
done
ok; echo "PASS (5) CODEX_STOP_HOOK=off → argv is element-for-element identical to herd_driver_agent_spawn_argv baseline"
CODEX_STOP_HOOK=on

# ── (6) BYTE-IDENTICAL for non-codex driver (herdr-claude) ───────────────────────────────────────
SLUG6="test-788-claude"
: > "$ARGV_CAPTURE"
herd_driver_launch_agent \
  "name=$SLUG6" "workspace=" "cwd=$FAKE_WT" "tab=fake-tab-666" \
  "driver=herdr-claude" "model=claude-sonnet-5" "flags=--dangerously-skip-permissions" \
  "pointer=a claude task" 2>/dev/null || true

_rt_claude=()
_sep=0
while IFS= read -r -d '' _tok; do
  if [ "$_tok" = "--" ]; then _sep=1; continue; fi
  if [ "$_tok" = "$(printf '\xff')" ]; then break; fi
  [ "$_sep" = "1" ] && _rt_claude+=("$_tok")
done < "$ARGV_CAPTURE"

# Element-for-element comparison against herd_driver_agent_spawn_argv baseline.
_expected6=()
while IFS= read -r -d '' _t; do _expected6+=("$_t"); done \
  < <(herd_driver_agent_spawn_argv "herdr-claude" "claude-sonnet-5" "--dangerously-skip-permissions" "a claude task" 2>/dev/null)
[ "${#_expected6[@]}" -gt 0 ] || fail "(6) herd_driver_agent_spawn_argv returned nothing for herdr-claude — function broken"
[ "${#_rt_claude[@]}" = "${#_expected6[@]}" ] \
  || fail "(6) herdr-claude argv length ${#_rt_claude[@]} != baseline ${#_expected6[@]}"
for _i in "${!_expected6[@]}"; do
  [ "${_rt_claude[$_i]:-}" = "${_expected6[$_i]}" ] \
    || fail "(6) herdr-claude argv[$_i] mismatch: captured='${_rt_claude[$_i]:-}' baseline='${_expected6[$_i]}'"
done
ok; echo "PASS (6) non-codex (herdr-claude) driver is element-for-element identical to herd_driver_agent_spawn_argv baseline"

# ── (7) Stale-marker lever-off safety ────────────────────────────────────────────────────────────
# Markers on disk + CODEX_STOP_HOOK=off → _herd_codex_hook_lifecycle returns nothing → fallback.
SLUG7="test-788-lever-off"
_HD7="$WORKTREES_DIR/.herd/agents/$SLUG7/hook"
mkdir -p "$_HD7"
printf 'codex' > "$WORKTREES_DIR/.herd/agents/$SLUG7/driver"
printf 'stale-turn' > "$_HD7/last-turn"
CODEX_STOP_HOOK=off
_lc7="$(_herd_codex_hook_lifecycle "$SLUG7" 2>/dev/null || true)"
[ -z "$_lc7" ] || fail "(7) _herd_codex_hook_lifecycle must return nothing when CODEX_STOP_HOOK=off, got: $_lc7"
# _reap_agent_working with raw working + stale markers + lever off → defers (conservative).
WORKING_JSON7='{"result":{"agents":[{"name":"'"$SLUG7"'","agent_status":"working"}]}}'
if AGENTS_JSON="$WORKING_JSON7" CODEX_STOP_HOOK=off _reap_agent_working "$SLUG7" 2>/dev/null; then
  : # returned 0 = still working = defer — correct
else
  fail "(7) _reap_agent_working returned 1 (reap) with stale markers + CODEX_STOP_HOOK=off — lever-off safety broken"
fi
ok; echo "PASS (7) stale hook markers + CODEX_STOP_HOOK=off → lever guard prevents false reap"
CODEX_STOP_HOOK=on

# ── (8) Stale-marker driver-switch safety ────────────────────────────────────────────────────────
# Markers on disk + spawn driver = herdr-claude → _herd_codex_hook_lifecycle returns nothing.
SLUG8="test-788-drv-switch"
_HD8="$WORKTREES_DIR/.herd/agents/$SLUG8/hook"
mkdir -p "$_HD8"
printf 'herdr-claude' > "$WORKTREES_DIR/.herd/agents/$SLUG8/driver"  # re-tasked to Claude
printf 'stale-codex-turn' > "$_HD8/last-turn"
_lc8="$(_herd_codex_hook_lifecycle "$SLUG8" 2>/dev/null || true)"
[ -z "$_lc8" ] || fail "(8) _herd_codex_hook_lifecycle must return nothing for non-codex spawn driver, got: $_lc8"
WORKING_JSON8='{"result":{"agents":[{"name":"'"$SLUG8"'","agent_status":"working"}]}}'
if AGENTS_JSON="$WORKING_JSON8" _reap_agent_working "$SLUG8" 2>/dev/null; then
  : # working = defer — correct
else
  fail "(8) _reap_agent_working returned 1 (reap) with stale markers + herdr-claude driver — driver-switch safety broken"
fi
ok; echo "PASS (8) stale hook markers + non-codex spawn driver → driver guard prevents false reap"

# ── (9) Retirement integration: hook idle + codex driver + CODEX_STOP_HOOK=on → _reap_agent_working 1 ─
# Proves the full pipeline: spawn driver=codex written by herd_driver_launch_agent (test 1 above),
# now simulate an idle Codex builder (last-turn present, no current-turn) and confirm retirement reaps.
# On main this fails because _reap_agent_working did not route through herd_driver_agent_status_resolved_ex.
CODEX_STOP_HOOK=on
# $SLUG1 was spawned by herd_driver_launch_agent above (driver file = codex, hook dir created).
# Set idle state: write last-turn, remove current-turn (simulates stop-hook having fired).
[ -d "$HOOK_DIR1" ] || fail "(9) prereq: hook dir for $SLUG1 not created by test (1)"
printf 'retire-test-turn' > "$HOOK_DIR1/last-turn"
rm -f "$HOOK_DIR1/current-turn"
WORKING_JSON9='{"result":{"agents":[{"name":"'"$SLUG1"'","agent_status":"working"}]}}'
if AGENTS_JSON="$WORKING_JSON9" _reap_agent_working "$SLUG1" 2>/dev/null; then
  fail "(9) _reap_agent_working returned 0 (working) despite hook idle evidence — HERD-788 fix not in effect"
fi
ok; echo "PASS (9) _reap_agent_working returns 1 (reap) when hook idle + codex driver + lever on"

# ── (10) Space-path portability: WORKTREES_DIR with spaces ──────────────────────────────────────
# A WORKTREES_DIR containing a space (common on macOS, e.g. "/Users/foo bar/trees") must produce
# valid, executable hook scripts with properly quoted command paths in the TOML value.
SPACE_WT="$T/trees with spaces"
mkdir -p "$SPACE_WT"
SLUG10="test-788-spaces"
ORIG_WORKTREES_DIR="$WORKTREES_DIR"
export WORKTREES_DIR="$SPACE_WT"
_frag10=()
while IFS= read -r -d '' _t; do _frag10+=("$_t"); done \
  < <(_herd_codex_stop_hook_argv_fragment "$SLUG10" 2>/dev/null)
[ "${#_frag10[@]}" -gt 0 ] || fail "(10) fragment emitted nothing for space-path slug"

# Parse stop command path from the TOML element; it should be executable.
_stop10=""
for _a in "${_frag10[@]}"; do
  case "$_a" in
    *"hooks.Stop="*)
      _stop10="$(python3 -c '
import sys, re
s = sys.argv[1]
m = re.search(r'"'"'command="\\\"([^"]+)\\\""'"'"', s)
if not m:
    m = re.search(r'"'"'command="([^"\\\\]+)"'"'"', s)
if m: print(m.group(1))
' "$_a" 2>/dev/null || true)"
      ;;
  esac
done
[ -n "$_stop10" ] || fail "(10) could not extract stop command from space-path TOML"
[ -x "$_stop10" ] || fail "(10) stop.sh at space path not executable: $_stop10"

# Execute the stop hook: it must write last-turn correctly even with spaces in the path.
_stop10_out="$(printf '{"turn_id":"space-test-turn"}' | bash "$_stop10" 2>/dev/null)"
[ "$_stop10_out" = "{}" ] || fail "(10) stop.sh (space path) must print {} — got: $_stop10_out"
_HD10="$SPACE_WT/.herd/agents/$SLUG10/hook"
[ -f "$_HD10/last-turn" ] || fail "(10) stop.sh (space path) did not write hook/last-turn"
_lt10="$(cat "$_HD10/last-turn")"
[ "$_lt10" = "space-test-turn" ] || fail "(10) last-turn wrong for space path: $_lt10"

# Verify the TOML value contains \"PATH\" quoting (backslash-double-quote before the path), proving
# space-path safety. The actual TOML arg contains: command="\"PATH\"" — look for command="\" pattern.
_found_dq=0
for _a in "${_frag10[@]}"; do
  # Match the literal characters: command=" then backslash then double-quote (TOML \"PATH\" wrapping)
  case "$_a" in
    *'command="\"'*) _found_dq=1 ;;
  esac
done
[ "$_found_dq" = "1" ] || fail "(10) TOML command value not double-quote-wrapped — space-path safety not applied"

export WORKTREES_DIR="$ORIG_WORKTREES_DIR"
ok; echo "PASS (10) space in WORKTREES_DIR: hooks generated and executable, TOML command value double-quoted"

# ── (10b) Codex live parser smoke: verify the space-path TOML -c value is accepted by the binary ────
# Skip softly if codex is absent — this is a belt-and-suspenders check on the generated TOML shape,
# not a functional gate. The sim and retirement-invariant tests own the logic; this is parser-round-trip.
_stop10_arg=""
for _a in "${_frag10[@]}"; do
  case "$_a" in *"hooks.Stop="*) _stop10_arg="$_a"; break ;; esac
done
if command -v codex >/dev/null 2>&1 && [ -n "$_stop10_arg" ]; then
  codex --strict-config -c "$_stop10_arg" --version >/dev/null 2>/dev/null \
    && ok \
    || fail "(10b) codex --strict-config rejected the space-path TOML -c value — syntax error in generated command"
  echo "PASS (10b) codex --strict-config accepts the generated space-path TOML command value"
else
  ok; echo "PASS (10b) codex not on PATH — live parser smoke skipped (soft)"
fi

# ── Done ─────────────────────────────────────────────────────────────────────────────────────────
echo ""; echo "PASS: $pass/11 checks passed — test-codex-stop-hook.sh"
