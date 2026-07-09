#!/usr/bin/env bash
# test-driver-lane-spawn.sh — hermetic proof for PHASE 2 of the agent-runtime portability epic
# (HERD-150 / HERD-174): the interactive-spawn LANES (herd-feature.sh / herd-quick.sh / herd-resolve.sh)
# are ROUTED through the P1 DRIVER_AGENT_* bindings instead of hardcoding `claude --model … <prompt>`.
#
# P1 (PR #264) catalogued the exec surface as DATA; P2 makes the INTERACTIVE-SPAWN binding REAL at spawn:
#   • herd_driver_agent_spawn_argv composes the agent-runtime argv from a driver's
#     DRIVER_AGENT_INTERACTIVE_SPAWN template — BYTE-IDENTICAL to the old `claude …` for the shipped
#     drivers, and honoring the DRIVER_AGENT_PERMISSION_FLAG class + empty-model / override-flags edges;
#   • a runtime-qualified MODEL ref (`<driver>:<model>`, HERD-151) now launches THAT driver's runtime —
#     the resolved driver is REAL, no longer resolved-then-DISCARDED (a foreign runtime composes its own
#     argv, proving the driver half selects the spawn binding);
#   • the three lanes route through the ONE seam (herd_driver_launch_agent) — no inline `-- claude`.
#
# Fully hermetic: local temp dirs + a stub herdr on PATH. NO real herdr/claude/gh/network/model.
# Run:  bash tests/test-driver-lane-spawn.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
DRIVER_SH="$ROOT/scripts/herd/driver.sh"
FEATURE="$ROOT/scripts/herd/herd-feature.sh"
QUICK="$ROOT/scripts/herd/herd-quick.sh"
RESOLVE="$ROOT/scripts/herd/herd-resolve.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ pass=$((pass+1)); }
command -v python3 >/dev/null 2>&1 || fail "python3 required"
for f in "$DRIVER_SH" "$FEATURE" "$QUICK" "$RESOLVE"; do [ -f "$f" ] || fail "missing script: $f"; done

# ── 0. Structural: every interactive-spawn lane routes through the ONE seam, not a hardcoded claude. ─
for f in "$FEATURE" "$QUICK" "$RESOLVE"; do
  grep -qE '^\. "\$HERE/driver\.sh"' "$f" || fail "$(basename "$f") does not source driver.sh"
  grep -qF 'herd_driver_launch_agent' "$f" || fail "$(basename "$f") does not route through herd_driver_launch_agent"
  # The builder lanes must NOT still hardcode a `-- claude …` interactive spawn (that IS the P2 bypass).
  # Exclude comment lines (a `#` after the grep -n line-number prefix) — prose may mention the old shape.
  grep -nE 'agent start .*-- claude' "$f" | grep -vE ':[[:space:]]*#' \
    && fail "$(basename "$f") still hardcodes an inline '-- claude' interactive spawn (not routed)"
done
# The builder lanes pass the RESOLVED runtime driver so it is not discarded.
grep -qF 'driver="$_DRIVER_RUNTIME"' "$FEATURE" || fail "herd-feature.sh does not pass the resolved driver= to the seam"
grep -qF 'driver="$_DRIVER_RUNTIME"' "$QUICK"   || fail "herd-quick.sh does not pass the resolved driver= to the seam"
ok; echo "PASS (0) all three lanes route through herd_driver_launch_agent (no inline '-- claude')"

# ── 1. herd_driver_agent_spawn_argv: byte-identical composition for herdr-claude + the class edges. ─
compose(){ # <driver> <model> <flags> <prompt> → space-joined composed argv (one line)
  local -a a=(); local t
  while IFS= read -r -d '' t; do a+=("$t"); done < <(herd_driver_agent_spawn_argv "$@")
  printf '%s' "${a[*]}"
}
( set +e
  # shellcheck source=/dev/null
  . "$DRIVER_SH"
  chk(){ [ "$(compose "$2" "$3" "$4" "$5")" = "$6" ] || { echo "FAIL: $1 → [$(compose "$2" "$3" "$4" "$5")] != [$6]"; exit 1; }; }
  # default binding, yolo flag → today's exact argv.
  chk default herdr-claude opus --dangerously-skip-permissions PTR \
    "claude --model opus --dangerously-skip-permissions PTR"
  # EMPTY model → the --model flag+value pair is dropped (matches the old `[ -n "$model" ] && …`).
  chk empty-model herdr-claude '' --dangerously-skip-permissions PTR \
    "claude --dangerously-skip-permissions PTR"
  # EMPTY flags (human seat) → the permission flag is dropped (matches the old `[ -n "$flags" ] && …`).
  chk empty-flags herdr-claude opus '' PTR \
    "claude --model opus PTR"
  # OVERRIDE flags (HERD_CLAUDE_FLAGS) replace the permission-flag token, word-split.
  chk override-flags herdr-claude opus '--foo --bar' PTR \
    "claude --model opus --foo --bar PTR"
  # headless carries the SAME claude shape (mux differs, runtime is identical) → byte-identical.
  chk headless-native headless sonnet --dangerously-skip-permissions PTR \
    "claude --model sonnet --dangerously-skip-permissions PTR"
  exit 0
) || fail "herd_driver_agent_spawn_argv composition not byte-identical (see FAIL above)"
ok; echo "PASS (1) herd_driver_agent_spawn_argv composes byte-identical argv + honors every class edge"

# ── 2. Resolved driver is REAL: a FOREIGN runtime driver composes ITS OWN argv (not discarded). ────
DD="$T/drivers"; mkdir -p "$DD"
cp "$ROOT/templates/drivers/herdr-claude.driver" "$DD/herdr-claude.driver"
cp "$ROOT/templates/drivers/headless.driver"     "$DD/headless.driver"
cat > "$DD/foreign.driver" <<'DRV'
DRIVER_AGENT_INTERACTIVE_SPAWN='myrt run --model <model> --yolo "<prompt>"'
DRIVER_AGENT_PERMISSION_FLAG='--yolo'
DRV
( set +e
  export HERD_DRIVERS_DIR="$DD"
  # shellcheck source=/dev/null
  . "$DRIVER_SH"
  # The foreign runtime's OWN template shape (a different exec, a renamed permission flag) composes.
  got="$(compose foreign gpt5 --yolo PTR)"
  [ "$got" = "myrt run --model gpt5 --yolo PTR" ] || { echo "FAIL: foreign compose → [$got]"; exit 1; }
  # Native-runtime classification: claude-shaped → native; foreign → NOT native (needs report-agent).
  herd_driver_agent_runtime_native herdr-claude || { echo "FAIL: herdr-claude misread as non-native"; exit 1; }
  herd_driver_agent_runtime_native foreign      && { echo "FAIL: foreign runtime misread as native"; exit 1; }
  exit 0
) || fail "foreign-driver composition / native classification failed (see FAIL above)"
ok; echo "PASS (2) a runtime-qualified ref composes the FOREIGN runtime's argv (driver is REAL, not discarded)"

# ── 3. End-to-end through the seam + a stub herdr: the LANE spawn command is what P2 composed. ─────
BIN="$T/bin"; mkdir -p "$BIN"
cat > "$BIN/herdr" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do printf '[%s]\n' "$a"; done
STUB
chmod +x "$BIN/herdr"
emit(){ for a in "$@"; do printf '[%s]\n' "$a"; done; }
( set +e
  export HERD_DRIVER="herdr-claude" HERD_DRIVERS_DIR="$DD" PATH="$BIN:$PATH"
  # shellcheck source=/dev/null
  . "$DRIVER_SH"
  # (a) bare model → the mux argv is the herdr-claude one AND the runtime tail is the native claude.
  if ! diff <(herd_driver_launch_agent name=b workspace=ws cwd=/d tab=t split=right \
                model=sonnet flags=--dangerously-skip-permissions pointer=PTR) \
            <(emit agent start b --workspace ws --cwd /d --tab t --split right --no-focus \
                -- claude --model sonnet --dangerously-skip-permissions PTR) >/dev/null; then
    echo "FAIL: bare-model lane spawn not byte-identical"
    herd_driver_launch_agent name=b workspace=ws cwd=/d tab=t split=right model=sonnet flags=--dangerously-skip-permissions pointer=PTR
    exit 1
  fi
  # (b) a runtime-qualified ref (no driver= — the shim resolves it) launches the FOREIGN runtime tail,
  #     proving the resolved driver is REAL end-to-end at the spawn seam (mux stays herdr).
  out="$(herd_driver_launch_agent name=b workspace=ws cwd=/d tab=t model=foreign:gpt5 flags=--yolo pointer=PTR)"
  case "$out" in
    *'[--]'*'[myrt]'*'[run]'*'[--model]'*'[gpt5]'*'[--yolo]'*'[PTR]'*) : ;;
    *) echo "FAIL: qualified ref did not compose the foreign runtime tail:"; printf '%s\n' "$out"; exit 1 ;;
  esac
  case "$out" in *'[claude]'*) echo "FAIL: qualified foreign ref STILL spawned claude (driver discarded)"; printf '%s\n' "$out"; exit 1 ;; esac
  exit 0
) || fail "end-to-end lane-seam spawn checks failed (see FAIL above)"
ok; echo "PASS (3) lane seam emits the P2-composed spawn command (bare=byte-identical, qualified=foreign runtime)"

# ── 4. driver= branch does NOT re-resolve a bare model — the colon-bearing regression the review caught. ─
# When the caller supplies driver=<name> the model is BARE BY CONTRACT; re-feeding it to the resolver
# mis-splits any colon-bearing model. Two failure modes the fix must prevent:
#   • ABORT — a bare 'llama3:8b' (from a resolved 'headless:llama3:8b') re-parsed as driver 'llama3'
#     (unknown) → the whole spawn aborts. It must instead spawn with model 'llama3:8b' INTACT.
#   • SILENT CORRUPTION — a bare 'headless:opus' re-parsed as driver 'headless' → model silently
#     rewritten to 'opus'. The model must reach the runtime UNCHANGED.
( set +e
  export HERD_DRIVER="herdr-claude" HERD_DRIVERS_DIR="$DD" PATH="$BIN:$PATH"
  # shellcheck source=/dev/null
  . "$DRIVER_SH"
  # (a) colon-bearing bare model through driver= — must NOT abort and must carry 'llama3:8b' intact.
  out="$(herd_driver_launch_agent name=b workspace=ws cwd=/d tab=t driver=headless \
           model=llama3:8b flags=--dangerously-skip-permissions pointer=PTR)"; rc=$?
  [ "$rc" -eq 0 ] || { echo "FAIL: driver= branch ABORTED on a colon-bearing bare model (re-resolution bug)"; exit 1; }
  case "$out" in *'[--model]'*'[llama3:8b]'*) : ;; *) echo "FAIL: colon-bearing model not carried intact:"; printf '%s\n' "$out"; exit 1 ;; esac
  # (b) a bare model that LOOKS like '<known-driver>:<x>' must NOT be silently rewritten by re-resolution.
  out="$(herd_driver_launch_agent name=b workspace=ws cwd=/d tab=t driver=herdr-claude \
           model=headless:opus flags=--dangerously-skip-permissions pointer=PTR)"; rc=$?
  [ "$rc" -eq 0 ] || { echo "FAIL: driver= branch aborted on a colon-bearing bare model"; exit 1; }
  case "$out" in *'[--model]'*'[headless:opus]'*) : ;; *) echo "FAIL: bare model SILENTLY rewritten (expected headless:opus intact):"; printf '%s\n' "$out"; exit 1 ;; esac
  # The corruption case would emit '[opus]' as the model token instead — assert that did NOT happen.
  case "$out" in *'[--model]'$'\n''[opus]'*) echo "FAIL: model corrupted headless:opus → opus"; printf '%s\n' "$out"; exit 1 ;; esac
  exit 0
) || fail "driver= no-re-resolve checks failed (see FAIL above)"
ok; echo "PASS (4) driver= branch does NOT re-resolve a bare model (no abort / no silent rewrite on colons)"

echo "ALL PASS ($pass checks)"
