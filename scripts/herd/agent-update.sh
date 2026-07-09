#!/usr/bin/env bash
# agent-update.sh — the AGENT_UPDATE mechanism (HERD-149): keep the AGENT RUNTIME up to date SAFELY,
# INSIDE the engine's visibility instead of by hand. Operators today update claude — and, via the
# driver seam, codex/grok — with a personal OS job (brew/npm/native), outside herdkit, with a KNOWN
# macOS footgun: a `brew upgrade --cask` leaves the new binary com.apple.quarantine'd, so EVERY new
# exec hangs in _dyld_start (issue #137) and spawned agents sit idle with blank panes. This mechanism
# DETECTS the installer (brew/npm/native), runs the update, and DE-QUARANTINES the binary afterward.
#
# CONTRACT (mirrors driver.sh):
#   • SOURCED, not executed, by bin/herd (cmd_agent_update) AFTER herd-config.sh (AGENT_UPDATE,
#     HERD_DRIVER) and driver.sh (herd_driver_agent_value). Defines functions ONLY; sourcing has NO
#     side effects — safe in lib mode / hermetic tests.
#   • Also RUNNABLE as a CLI (`bash agent-update.sh [--dry-run] [run|installer|binary|dequarantine]`)
#     — the CLI entrypoint (and only it) sources herd-config.sh + driver.sh to resolve the knob/driver.
#   • OPT-IN + BYTE-IDENTICAL OFF: AGENT_UPDATE unset/≠on ⇒ agent_update_run is a no-op that touches
#     NOTHING (no installer probe, no exec, no xattr) — behavior identical to before this existed.
#   • FAIL-SOFT: a missing runtime, an unknown installer, or a failed installer command WARNS and
#     returns 0 — updating the runtime must never abort an operator's session or a wrapping script.
#   • DRIVER-AWARE: every runtime-specific value (binary, npm/brew package, native update command)
#     comes from the ACTIVE driver's DRIVER_AGENT_* bindings, so codex/grok update their OWN binary.

# _agent_update_os — the platform, lowercased. HERD_AGENT_UPDATE_OS overrides it (the test seam +
# the same knob the doctor's quarantine probe uses, HERD_DOCTOR_OS, in spirit) so a linux CI run can
# exercise the darwin-only de-quarantine path hermetically.
_agent_update_os() {
  if [ -n "${HERD_AGENT_UPDATE_OS:-}" ]; then printf '%s' "$HERD_AGENT_UPDATE_OS"; return 0; fi
  uname -s 2>/dev/null | tr '[:upper:]' '[:lower:]' || true
}
_agent_update_is_darwin() { [ "$(_agent_update_os)" = darwin ]; }

# _agent_update_realpath <path> — resolve a symlink chain to its final target WITHOUT `readlink -f`
# (GNU-only; stock macOS lacks it), so the brew shim/symlink chain (/opt/homebrew/bin/claude →
# ../Caskroom/claude-code/<ver>/bin/claude) resolves to the REAL on-disk binary the installer probe
# classifies and the quarantine fix targets. Mirrors herd-preflight.sh's _herd_doctor_realpath; bounded
# to 40 hops to defuse a symlink loop. Echoes the resolved path (or the input if it is not a symlink).
_agent_update_realpath() {
  local p="${1:-}" n=0 target
  while [ -L "$p" ] && [ "$n" -lt 40 ]; do
    target="$(readlink "$p" 2>/dev/null)" || break
    [ -n "$target" ] || break
    case "$target" in
      /*) p="$target" ;;
      *)  p="$(dirname "$p")/$target" ;;
    esac
    n=$((n+1))
  done
  printf '%s' "$p"
}

# agent_update_binary — the active driver's runtime CLI binary (DRIVER_AGENT_BINARY; default 'claude'
# so a driver predating this block still resolves). This is WHICH runtime `herd agent-update` updates.
agent_update_binary() { herd_driver_agent_value DRIVER_AGENT_BINARY claude; }

# agent_update_installer <binary> — classify HOW the runtime binary was installed, so the right update
# command runs. Echoes exactly one word:
#   missing — not on PATH (nothing to update)
#   brew    — a Homebrew formula/cask (resolved under a Cellar/Caskroom tree, or the brew prefix)
#   npm     — an npm GLOBAL package (resolved under `npm prefix -g`)
#   native  — a self-contained install (the native installer / a plain binary elsewhere)
# Ordering is load-bearing: the DEFINITIVE Homebrew markers (Cellar/Caskroom) win first; then npm
# (a brew-provided node puts npm globals UNDER the brew prefix too, so the npm-prefix check must beat
# the generic brew-prefix check); then the generic brew prefix; else native. PURE (no mutation).
agent_update_installer() {
  local bin="${1:-}" p real pfx
  [ -n "$bin" ] || { printf 'missing'; return 0; }
  command -v "$bin" >/dev/null 2>&1 || { printf 'missing'; return 0; }
  p="$(command -v "$bin" 2>/dev/null || true)"
  real="$(_agent_update_realpath "$p")"
  # 1) Homebrew formula/cask — the definitive markers. The Caskroom case carries the quarantine footgun.
  case "$real" in
    */Cellar/*|*/Caskroom/*) printf 'brew'; return 0 ;;
  esac
  # 2) npm global — resolved under the npm global prefix (…/bin/<bin> → …/lib/node_modules/<pkg>).
  if command -v npm >/dev/null 2>&1; then
    pfx="$(npm prefix -g 2>/dev/null || true)"
    if [ -n "$pfx" ]; then case "$real" in "$pfx"/*) printf 'npm'; return 0 ;; esac; fi
  fi
  # 3) Homebrew, generically — resolved under the active brew prefix (a formula symlinked into …/bin).
  if command -v brew >/dev/null 2>&1; then
    pfx="$(brew --prefix 2>/dev/null || true)"
    if [ -n "$pfx" ]; then case "$real" in "$pfx"/*) printf 'brew'; return 0 ;; esac; fi
  fi
  # 4) native — the runtime's own installer / a plain binary (e.g. ~/.local/bin, the curl install).
  printf 'native'
}

# agent_update_dequarantine <resolved-binary> [dry] — the macOS FOOTGUN FIX. After a `brew upgrade
# --cask` (and, occasionally, a native download) macOS stamps the new binary with com.apple.quarantine,
# which makes EVERY new exec hang in _dyld_start (issue #137). This strips that xattr from the resolved
# binary — the exact remedy `herd doctor` only PRINTS; here the update APPLIES it. Guarded: darwin only,
# `xattr` present, and the flag actually set (never touches a clean binary). FAIL-SOFT (never aborts);
# with dry=1 it PRINTS the command instead of running it. Returns 0 always.
agent_update_dequarantine() {
  local path="${1:-}" dry="${2:-}"
  [ -n "$path" ] || return 0
  _agent_update_is_darwin || return 0                     # quarantine is a macOS-only concern
  command -v xattr >/dev/null 2>&1 || return 0
  if xattr "$path" 2>/dev/null | grep -q '^com\.apple\.quarantine$'; then
    if [ -n "$dry" ]; then
      printf 'agent-update: [dry-run] xattr -d com.apple.quarantine %s\n' "$path"
    else
      if xattr -d com.apple.quarantine "$path" 2>/dev/null; then
        printf '\xe2\x9c\x93 agent-update: de-quarantined %s (com.apple.quarantine removed; issue #137)\n' "$path"
      else
        printf '\xe2\x9a\xa0 agent-update: could not remove com.apple.quarantine from %s \xe2\x80\x94 run: xattr -d com.apple.quarantine %s\n' "$path" "$path" >&2
      fi
    fi
  else
    printf 'agent-update: %s not quarantined \xe2\x80\x94 no de-quarantine needed\n' "$path"
  fi
  return 0
}

# agent_update_run [--dry-run] — the orchestrator. OFF (default) is a hard no-op (opt-in, byte-identical
# off). ON: resolve the driver's runtime + installer, run the update, then de-quarantine on macOS.
# FAIL-SOFT throughout. --dry-run prints every command it WOULD run (installer + xattr) without
# executing them — a safe preview + the sim proof's entry point. Returns 0 (fail-soft).
agent_update_run() {
  local dry=""
  [ "${1:-}" = "--dry-run" ] && dry=1

  # OFF (default) → no-op. The whole feature is opt-in; nothing is probed, run, or de-quarantined.
  if [ "${AGENT_UPDATE:-off}" != "on" ]; then
    printf 'agent-update: AGENT_UPDATE is off (opt-in) \xe2\x80\x94 nothing to do. Enable with: herd config set AGENT_UPDATE on\n'
    return 0
  fi

  local driver bin pkg brewpkg native_cmd
  driver="$(herd_driver_name 2>/dev/null || printf 'herdr-claude')"
  bin="$(agent_update_binary)"
  pkg="$(herd_driver_agent_value DRIVER_AGENT_NPM_PKG '@anthropic-ai/claude-code')"
  brewpkg="$(herd_driver_agent_value DRIVER_AGENT_BREW_PKG "$bin")"
  native_cmd="$(herd_driver_agent_value DRIVER_AGENT_NATIVE_UPDATE "$bin update")"
  printf 'agent-update: driver=%s runtime=%s%s\n' "$driver" "$bin" "${dry:+ (dry-run)}"

  local installer; installer="$(agent_update_installer "$bin")"
  if [ "$installer" = missing ]; then
    printf '\xe2\x9a\xa0 agent-update: runtime %s not found on PATH \xe2\x80\x94 nothing to update (install it first)\n' "$bin" >&2
    return 0                                              # fail-soft: no runtime, no update
  fi
  printf 'agent-update: installer=%s\n' "$installer"

  # Compose the installer-specific update command (indexed array — bash-3.2 safe, no assoc arrays).
  local -a cmd
  case "$installer" in
    brew)   cmd=(brew upgrade "$brewpkg") ;;
    npm)    cmd=(npm install -g "$pkg@latest") ;;
    native) # shellcheck disable=SC2206  # $native_cmd intentionally word-splits into argv.
            cmd=($native_cmd) ;;
    *)      printf '\xe2\x9a\xa0 agent-update: unknown installer %s \xe2\x80\x94 skipping update\n' "$installer" >&2; return 0 ;;
  esac
  printf 'agent-update: update command: %s\n' "${cmd[*]}"

  if [ -n "$dry" ]; then
    printf 'agent-update: [dry-run] would run: %s\n' "${cmd[*]}"
  elif "${cmd[@]}"; then
    printf '\xe2\x9c\x93 agent-update: %s updated via %s\n' "$bin" "$installer"
  else
    # Fail-soft: report and continue to the de-quarantine step — a partial cask upgrade can still have
    # left a quarantined binary that needs clearing, and the operator can retry the installer by hand.
    printf '\xe2\x9a\xa0 agent-update: update command failed (%s) \xe2\x80\x94 leaving runtime as-is\n' "${cmd[*]}" >&2
  fi

  # The macOS footgun: after the update, strip com.apple.quarantine from the RESOLVED binary so the
  # new runtime does not hang in _dyld_start (issue #137). No-op off darwin / when not quarantined.
  local p real
  p="$(command -v "$bin" 2>/dev/null || true)"
  if [ -n "$p" ]; then
    real="$(_agent_update_realpath "$p")"
    agent_update_dequarantine "$real" "$dry"
  fi
  return 0
}

# ── CLI entrypoint ───────────────────────────────────────────────────────────────────────────────
# Only runs when EXECUTED (not sourced). Sources herd-config.sh (AGENT_UPDATE + HERD_DRIVER) and
# driver.sh (herd_driver_agent_value), then dispatches. `run` is the default.
_agent_update_cli() {
  local dry=""
  [ "${1:-}" = "--dry-run" ] && { dry="--dry-run"; shift || true; }
  local cmd="${1:-run}"; shift || true
  case "$cmd" in
    run)          agent_update_run $dry ;;
    installer)    agent_update_installer "${1:-$(agent_update_binary)}"; echo ;;
    binary)       agent_update_binary; echo ;;
    dequarantine) agent_update_dequarantine "${1:-$(_agent_update_realpath "$(command -v "$(agent_update_binary)" 2>/dev/null || true)")}" "$dry" ;;
    *) printf 'usage: agent-update.sh [--dry-run] {run|installer [binary]|binary|dequarantine [path]}\n' >&2; return 2 ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  _HERD_AGENT_UPDATE_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=/dev/null
  . "$_HERD_AGENT_UPDATE_HERE/herd-config.sh"
  # shellcheck source=/dev/null
  . "$_HERD_AGENT_UPDATE_HERE/driver.sh"
  _agent_update_cli "$@"
fi
