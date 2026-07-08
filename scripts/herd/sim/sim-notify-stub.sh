#!/usr/bin/env bash
# scripts/herd/sim/sim-notify-stub.sh — the SHARED sim NOTIFY-STUB preamble (HERD-139).
#
# WHY THIS EXISTS. Sim scenarios drive REAL engine code — main_health_tick, the dead-builder /
# refix escalation, limit-resume — that calls herd_driver_notify (scripts/herd/driver.sh). That seam
# surfaces a DESKTOP notification two ways, BOTH of which escape a sim run onto the operator's screen:
#   • default herdr-claude driver → a REAL `herdr notification show`;
#   • HERD_DRIVER=headless → its durable notifications.log sink PLUS a best-effort NATIVE
#     osascript / notify-send desktop notification (unless HERD_HEADLESS_NATIVE_NOTIFY=off).
# The 2026-07-08 incident: every sim run of an alarm-bearing scenario (the main-health forced-red leg,
# HERD-129) popped a real '🚨 MAIN RED …' macOS notification from the SANDBOX FIXTURE — training the
# operator to ignore the REAL MAIN RED alarm (cry-wolf) and violating the zero-side-effects sim
# contract. The sim stubs `gh` via PATH but never stubbed this notify seam.
#
# WHAT IT DOES. Install a PATH shim + env so EVERY notification a scenario produces lands ONLY in a
# durable sink, NEVER a real desktop channel:
#   • HEADLESS tier — HERD_HEADLESS_NATIVE_NOTIFY=off suppresses the driver's native osascript/
#     notify-send call; its durable sink ($WORKTREES_DIR/.herd/notifications.log) still records the
#     line, so notification behaviour stays OBSERVABLE (scenarios assert against it — leak → signal).
#   • REAL-PANES tier (default herdr-claude driver) — a PATH-stubbed `herdr` that intercepts ONLY the
#     `notification` subcommand (captured to the sink) and FORWARDS every other subcommand to the REAL
#     herdr. Real panes are preserved; only notify is stubbed.
#   • HARNESS INVARIANT — `osascript` and `notify-send` are shimmed to CAPTURE (never deliver) any
#     native attempt, so "zero notifications delivered outside the sink" is PROVABLE, not assumed:
#     sim_notify_native_attempts must be 0 at the end of every run.
#
# CONTRACT: SOURCED, not executed. Defines functions ONLY — sourcing has NO side effects (safe in a
# scenario preamble and in hermetic tests). A scenario opts in by calling sim_notify_install "$ART".
# bash-3.2 safe (no assoc arrays / namerefs), mirroring the rest of scripts/herd/sim/.

# sim_notify_install <artifacts-dir> — install the notify stub for THIS scenario process (and any
# child it spawns via `bash …`, which inherit PATH + the exported env). Idempotent per artifacts dir.
# Builds <artifacts-dir>/.notify-shim/ with herdr/osascript/notify-send stubs, prepends it to PATH,
# and exports HERD_HEADLESS_NATIVE_NOTIFY=off + SIM_NOTIFY_CAPTURED (the captured-attempts log the
# invariant reads). The REAL herdr is resolved ONCE, BEFORE the shim shadows it, so the stub can
# forward non-notify subcommands (and so a herdr-absent headless run keeps the shim inert).
sim_notify_install() {
  local art="${1:-}"
  [ -n "$art" ] || { printf 'sim_notify_install: artifacts dir required\n' >&2; return 1; }
  local shim="$art/.notify-shim"
  mkdir -p "$shim" 2>/dev/null || { printf 'sim_notify_install: cannot create shim dir %s\n' "$shim" >&2; return 1; }

  # Resolve the REAL herdr now, before our stub shadows it on PATH (empty if herdr is not installed —
  # the headless tiers never call it, so the forward path is simply dormant there).
  local _sns_real_herdr; _sns_real_herdr="$(command -v herdr 2>/dev/null || true)"
  export SIM_NOTIFY_CAPTURED="$art/notify-captured.log"
  : > "$SIM_NOTIFY_CAPTURED" 2>/dev/null || true

  # herdr stub — intercept `herdr notification …` (capture, never deliver); forward EVERYTHING else to
  # the real herdr so the real-panes tier keeps real tabs/panes. A tab-separated capture line records
  # the full argv so a scenario can assert exactly what was surfaced.
  cat > "$shim/herdr" <<HERDR
#!/usr/bin/env bash
if [ "\${1:-}" = "notification" ]; then
  printf 'herdr\t%s\n' "\$*" >> "$SIM_NOTIFY_CAPTURED" 2>/dev/null || true
  exit 0
fi
_sns_real="$_sns_real_herdr"
if [ -n "\$_sns_real" ] && [ -x "\$_sns_real" ]; then exec "\$_sns_real" "\$@"; fi
exit 0
HERDR

  # osascript / notify-send stubs — CAPTURE any native desktop attempt instead of delivering it. With
  # the fix in place (HERD_HEADLESS_NATIVE_NOTIFY=off) the code never reaches these; if it ever did,
  # the attempt lands in the sink, never the operator's screen, and the invariant flags it.
  local _sns_n
  for _sns_n in osascript notify-send; do
    cat > "$shim/$_sns_n" <<STUB
#!/usr/bin/env bash
printf '$_sns_n\t%s\n' "\$*" >> "$SIM_NOTIFY_CAPTURED" 2>/dev/null || true
exit 0
STUB
  done
  chmod +x "$shim/herdr" "$shim/osascript" "$shim/notify-send" 2>/dev/null || true

  export HERD_HEADLESS_NATIVE_NOTIFY=off
  case ":$PATH:" in
    *":$shim:"*) : ;;                        # already on PATH — idempotent
    *) export PATH="$shim:$PATH" ;;
  esac
  return 0
}

# sim_notify_sink <trees-dir> — path of the HEADLESS durable notify sink for a given WORKTREES_DIR
# (matches _herd_headless_notify in scripts/herd/driver.sh). Does not create it.
sim_notify_sink() { printf '%s/.herd/notifications.log' "${1:-.}"; }

# sim_notify_count <file> <ere> — count lines in <file> matching the ERE (0 if the file is absent).
# Used by scenarios to turn the notify LEAK into a covered SIGNAL (e.g. exactly one MAIN RED line).
sim_notify_count() {
  local f="${1:-}" pat="${2:-}" n
  [ -f "$f" ] || { printf 0; return 0; }
  # grep -c prints "0" AND exits 1 on no match, so capture it (never let the || double-print).
  n="$(grep -cE "$pat" "$f" 2>/dev/null)" || n="${n:-0}"
  printf '%s' "${n:-0}"
}

# sim_notify_captured_count <ere> — count captured-attempt lines matching the ERE (real-panes tier:
# the `herdr notification …` interceptions land here).
sim_notify_captured_count() { sim_notify_count "${SIM_NOTIFY_CAPTURED:-}" "${1:-}"; }

# sim_notify_native_attempts — echo the count of REAL native desktop-notification attempts captured
# (osascript / notify-send). THE HARNESS INVARIANT: this MUST be 0. With the fix in place the headless
# driver's native seam is suppressed and the real-panes tier routes notify through the captured herdr
# stub, so nothing reaches the operator's desktop — a non-zero count is a hermeticity regression.
sim_notify_native_attempts() { sim_notify_captured_count '^(osascript|notify-send)\b'; }
