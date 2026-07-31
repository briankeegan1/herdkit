#!/usr/bin/env bash
# env-export-lint.sh — THE shared shell→python EXPORT guard (HERD-449): a config knob the Python
# engine core reads from os.environ (pysrc/herd/live_runtime.py's _CORE_ENV_KEYS) must be `export`ed
# by scripts/herd/herd-config.sh, or `python3 -m herd.live_runtime --tick` — spawned as a CHILD
# process of the watcher (engine-version.sh:herd_engine_live_tick) — never sees it and silently falls
# back to its own built-in default no matter what a project's .herd/config says.
#
# GROUNDED 2026-07-31: exactly this bug, live. HEALTH_CONCURRENCY=3 was configured but the engine
# core read 1 (its built-in default), zeroing the HERD-359 main-health slot reservation
# (_health_max - 1 == 0) whenever main-health was pending — no PR healthcheck could dispatch at all,
# and two PRs sat un-gated for over an hour. Three prior items (HERD-353/345/359) each fixed this
# same bug for ONE key by hand; this lint is the guard that makes a fourth one-off fix unnecessary —
# same shape as the caps-sync / doc-drift / gate-coverage lints below: a consumer reading a signal no
# producer supplies, caught pre-PR instead of discovered live.
#
# WHAT COUNTS AS A VIOLATION
# A key is checked ONLY if it is actually SET (has a value) after herd-config.sh finishes sourcing —
# either from its own `: "${KEY:=default}"` line, or from a project's .herd/config. A key that stays
# completely UNSET (e.g. WATCHER_SCOPE with no default anywhere) is NOT a violation: os.environ.get()
# returns the identical None whether or not an unset shell var carries the export attribute, so there
# is nothing for the python core to miss. The violation is narrowly: SET in this shell, but not
# exported — the exact shape that stranded HEALTH_CONCURRENCY.
#
# herd_env_export_lint <worktree-root>
#   Sources <worktree-root>/scripts/herd/herd-config.sh in an ISOLATED child bash (so a project's real
#   .herd/config — which may run arbitrary shell — can never mutate the CALLER's environment; only the
#   child's final variable table is inspected via `declare -p`), asks the Python core for its
#   authoritative _CORE_ENV_KEYS list (imported directly — never a text scrape, so the lint cannot
#   drift from the actual consumer list), then reports every key that is SET but NOT exported.
#   Prints one offending KEY per line; the caller owns the ❌ headline/note/exit.
#   Exit: 0 = clean · 1 = violation (lines on stdout) · 2 = skipped (infra; NEVER a red).
#   On a skip, $HERD_ENV_EXPORT_SKIP_REASON carries the one-line why.

HERD_ENV_EXPORT_SKIP_REASON=""

herd_env_export_lint() {
  local _eel_root="${1:-.}"
  HERD_ENV_EXPORT_SKIP_REASON=""

  local _eel_cfg="$_eel_root/scripts/herd/herd-config.sh"
  local _eel_py="$_eel_root/pysrc"
  if [ ! -f "$_eel_cfg" ] || [ ! -d "$_eel_py" ]; then
    HERD_ENV_EXPORT_SKIP_REASON="no scripts/herd/herd-config.sh + pysrc in this tree"
    return 2
  fi
  command -v python3 >/dev/null 2>&1 || { HERD_ENV_EXPORT_SKIP_REASON="python3 not on PATH"; return 2; }

  local _eel_keys
  _eel_keys="$(PYTHONPATH="$_eel_py" python3 -c '
import sys
try:
    from herd.live_runtime import _CORE_ENV_KEYS
except Exception as exc:
    print("IMPORT_ERROR:" + str(exc)[:200])
    sys.exit(0)
print("\n".join(_CORE_ENV_KEYS))
' 2>/dev/null)"
  case "$_eel_keys" in
    IMPORT_ERROR:*|"")
      HERD_ENV_EXPORT_SKIP_REASON="could not resolve _CORE_ENV_KEYS from pysrc/herd/live_runtime.py (${_eel_keys#IMPORT_ERROR:})"
      return 2
      ;;
  esac

  # Source herd-config.sh in a CHILD bash — an isolated environment so a project's real .herd/config
  # (arbitrary shell) can never leak into or mutate THIS process; only the child's post-source
  # variable table is inspected. HERD_CONFIG_FILE is unset first so the child's own discovery walk
  # (from $_eel_root as cwd) finds that tree's config, matching what the real watcher sources.
  local _eel_out _eel_rc
  _eel_out="$(cd "$_eel_root" && env -u HERD_CONFIG_FILE bash -c '
    cfg="$1"; shift
    . "$cfg" >/dev/null 2>&1 || exit 0
    for k in "$@"; do
      if decl="$(declare -p "$k" 2>/dev/null)"; then
        case "$decl" in
          "declare -x"*) : ;;                 # exported — fine
          *) printf "%s\n" "$k" ;;            # SET but NOT exported — the HERD-449 bug class
        esac
      fi
      # else: genuinely unset — os.environ.get() reads identically exported or not, not a bug
    done
  ' _ "$_eel_cfg" $_eel_keys)"; _eel_rc=$?

  if [ "$_eel_rc" -ne 0 ]; then
    HERD_ENV_EXPORT_SKIP_REASON="herd-config.sh failed to source cleanly in $_eel_root"
    return 2
  fi
  [ -n "$_eel_out" ] && { printf '%s\n' "$_eel_out"; return 1; }
  return 0
}
