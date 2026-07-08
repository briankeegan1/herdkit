#!/usr/bin/env bash
# install.sh — one-command herdkit installer.
#
# Curl-able bootstrap (no pre-clone needed):
#   curl -fsSL https://raw.githubusercontent.com/briankeegan1/herdkit/main/install.sh | bash
#
# It: (1) clones herdkit to a standard location (~/.herdkit) — or fast-forward-updates an existing
# checkout there; (2) makes the `herd` entrypoint reachable (symlink into a writable PATH dir it
# verifies, else prints the exact PATH line to add); (3) runs the dependency doctor to surface any
# missing deps with the per-platform hints it already prints; (4) finishes with the two-step
# quickstart. IDEMPOTENT: re-running updates (git pull --ff-only) + re-verifies, never clobbering
# local state, and refuses politely on a dirty engine checkout — mirroring `herd update`'s guard.
# Dependency-light: bash + git (+ curl to fetch this file). No package manager assumed.
#
# Two modes, auto-detected:
#   • managed  — the default. Manage a checkout at HERDKIT_HOME (clone if absent, ff-update if
#                present). Used by the curl | bash bootstrap and by an explicit HERDKIT_HOME.
#   • local    — when run as ./install.sh from INSIDE an existing herdkit checkout (and no
#                HERDKIT_HOME override): wire THIS checkout onto PATH + run the doctor, but leave
#                the checkout itself alone (you manage it with git / `herd update`).
#
# Usage:
#   bash install.sh                 # bootstrap/update ~/.herdkit (or wire the local checkout)
#   bash install.sh --dir <dir>     # symlink `herd` into a specific PATH directory
#   bash install.sh --home <dir>    # install/update the engine checkout at <dir>
#   bash install.sh --force         # proceed even if the engine checkout is dirty
#
# Knobs (env):
#   HERDKIT_HOME       install/update the engine checkout here (default: ~/.herdkit).
#   HERDKIT_REPO_URL   git URL to clone from (default: https://github.com/briankeegan1/herdkit.git).
set -euo pipefail

DEFAULT_HOME="$HOME/.herdkit"
REPO_URL="${HERDKIT_REPO_URL:-https://github.com/briankeegan1/herdkit.git}"

# ── Output helpers (color only on a tty, so piped/captured output stays clean) ──────────────────
if [ -t 1 ]; then
  c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_red=$'\033[31m'; c_bold=$'\033[1m'; c_rst=$'\033[0m'
else
  c_grn=''; c_yel=''; c_red=''; c_bold=''; c_rst=''
fi
say()  { printf '%s\n' "$*"; }
ok()   { printf '%s✅ %s%s\n' "$c_grn" "$*" "$c_rst"; }
warn() { printf '%s⚠️  %s%s\n' "$c_yel" "$*" "$c_rst" >&2; }
die()  { printf '%s❌ %s%s\n' "$c_red" "$*" "$c_rst" >&2; exit 1; }

# ── Args ────────────────────────────────────────────────────────────────────────────────────────
TARGET_DIR=""   # explicit symlink destination (--dir)
HOME_OVERRIDE=""
FORCE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dir)   TARGET_DIR="${2:?--dir requires a directory argument}"; shift 2 ;;
    --home)  HOME_OVERRIDE="${2:?--home requires a directory argument}"; shift 2 ;;
    --force|-f) FORCE=1; shift ;;
    -h|--help)
      sed -n '2,30p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

command -v git >/dev/null 2>&1 || die "git not found — herdkit needs git. Install it, then re-run this installer."

# ── Resolve this script to a real path (follow symlinks; macOS has no \`readlink -f\`) so we can
#    tell a from-checkout run (./install.sh in a clone) from a piped \`curl | bash\` run, where
#    BASH_SOURCE is not a readable file and SELF_DIR stays empty. ─────────────────────────────────
SELF="${BASH_SOURCE[0]:-}"
SELF_DIR=""
if [ -n "$SELF" ] && [ -f "$SELF" ]; then
  while [ -L "$SELF" ]; do
    _t="$(readlink "$SELF" 2>/dev/null)" || break
    [ -n "$_t" ] || break
    case "$_t" in
      /*) SELF="$_t" ;;
      *)  SELF="$(cd "$(dirname "$SELF")" && cd "$(dirname "$_t")" && pwd)/${_t##*/}" ;;
    esac
  done
  SELF_DIR="$(cd "$(dirname "$SELF")" && pwd)"
fi

# ── Decide mode + engine home ───────────────────────────────────────────────────────────────────
# Priority: explicit --home / HERDKIT_HOME (managed) > from-checkout run (local) > default (managed).
HH=""
MODE=""
if [ -n "$HOME_OVERRIDE" ]; then
  HH="$HOME_OVERRIDE"; MODE=managed
elif [ -n "${HERDKIT_HOME:-}" ]; then
  HH="$HERDKIT_HOME"; MODE=managed
elif [ -n "$SELF_DIR" ] && [ -x "$SELF_DIR/bin/herd" ] && [ -e "$SELF_DIR/.git" ]; then
  HH="$SELF_DIR"; MODE=local
else
  HH="$DEFAULT_HOME"; MODE=managed
fi

say "${c_bold}herdkit installer${c_rst}"
say ""

# ── Managed mode: clone-if-absent, else ff-update (idempotent, dirty-guarded) ────────────────────
if [ "$MODE" = managed ]; then
  if [ ! -e "$HH" ]; then
    say "  cloning ${REPO_URL} → ${HH} …"
    if ! git clone "$REPO_URL" "$HH"; then
      die "git clone failed — check the URL/network and retry: git clone $REPO_URL $HH"
    fi
    ok "cloned herdkit to $HH"
  elif [ -e "$HH/.git" ] && git -C "$HH" rev-parse --git-dir >/dev/null 2>&1; then
    # Existing checkout → update. Refuse over uncommitted changes (mirrors \`herd update\`'s guard).
    _dirty="$(git -C "$HH" status --porcelain 2>/dev/null || true)"
    if [ -n "$_dirty" ]; then
      warn "engine checkout at $HH has uncommitted changes:"
      printf '%s\n' "$_dirty" >&2
      if [ -n "$FORCE" ]; then
        warn "proceeding anyway (--force)"
      else
        die "refusing to update over a dirty engine checkout — commit or stash your changes first, or re-run with --force"
      fi
    fi
    # Fast-forward only — divergence is always a human decision. Skip cleanly when there is no
    # upstream tracking branch (e.g. a detached / never-pushed checkout) rather than erroring.
    if git -C "$HH" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
      _old="$(git -C "$HH" rev-parse HEAD 2>/dev/null || true)"
      say "  updating $HH (git pull --ff-only) …"
      if ! _pull="$(git -C "$HH" pull --ff-only 2>&1)"; then
        printf '%s\n' "$_pull" >&2
        die "git pull --ff-only failed — the engine branch may have diverged. Diagnose with: git -C $HH fetch && git -C $HH merge --ff-only"
      fi
      _new="$(git -C "$HH" rev-parse HEAD 2>/dev/null || true)"
      if [ -n "$_old" ] && [ "$_old" != "$_new" ]; then
        ok "updated $HH (${_old:0:7}..${_new:0:7})"
      else
        ok "already up to date ($HH)"
      fi
    else
      ok "engine checkout at $HH is up to date (no upstream tracking branch — skipping pull)"
    fi
  else
    die "$HH exists but is not a git checkout — move it aside or pass --home <dir> to install elsewhere."
  fi
else
  ok "using this herdkit checkout: $HH"
fi

HERD_BIN="$HH/bin/herd"
[ -x "$HERD_BIN" ] || die "installed engine at $HH is missing an executable bin/herd — the checkout looks incomplete."

# ── Make \`herd\` reachable on PATH: symlink into a writable PATH dir, verified; else print the
#    exact export line to add. ln -sf is idempotent, so a re-run never clobbers a good symlink. ──
say ""
if [ -z "$TARGET_DIR" ]; then
  IFS=: read -ra _path_dirs <<< "$PATH"
  for d in "${_path_dirs[@]}"; do
    [ -n "$d" ] || continue
    if [ -d "$d" ] && [ -w "$d" ]; then
      TARGET_DIR="$d"; break
    fi
  done
fi

PATH_HINT=""
if [ -z "$TARGET_DIR" ]; then
  warn "no writable directory found in PATH — could not symlink automatically."
  PATH_HINT="$HH/bin"
  say "Add herdkit's bin/ to your PATH — append this to your shell profile (~/.bashrc, ~/.zshrc):"
  say "  ${c_bold}export PATH=\"$HH/bin:\$PATH\"${c_rst}"
else
  if ln -sf "$HERD_BIN" "$TARGET_DIR/herd"; then
    ok "linked $TARGET_DIR/herd → $HERD_BIN"
    # Verify the entrypoint actually resolves on PATH now.
    hash -r 2>/dev/null || true
    _resolved="$(command -v herd 2>/dev/null || true)"
    if [ -z "$_resolved" ]; then
      warn "$TARGET_DIR is not on your PATH — add it so \`herd\` is reachable:"
      say "  ${c_bold}export PATH=\"$TARGET_DIR:\$PATH\"${c_rst}"
      PATH_HINT="$TARGET_DIR"
    fi
  else
    warn "could not create the symlink in $TARGET_DIR."
    PATH_HINT="$HH/bin"
    say "Add herdkit's bin/ to your PATH instead — append to your shell profile:"
    say "  ${c_bold}export PATH=\"$HH/bin:\$PATH\"${c_rst}"
  fi
fi

# ── Dependency doctor (advisory at install time) ────────────────────────────────────────────────
# The engine is installed regardless — a missing dep never blocks the install; it just surfaces the
# full picture NOW (with per-platform install hints) rather than as a cryptic failure later. The
# same herd_doctor that \`herd doctor\` and \`herd init\`'s hard gate run.
if [ -f "$HH/scripts/herd/herd-preflight.sh" ]; then
  say ""
  # shellcheck source=/dev/null
  . "$HH/scripts/herd/herd-preflight.sh"
  if ! herd_doctor; then
    warn "some required dependencies are missing/broken (above) — fix them before running 'herd init'"
  fi
fi

# ── Two-step quickstart ─────────────────────────────────────────────────────────────────────────
say ""
say "${c_bold}herdkit installed.${c_rst} Quickstart — stand it up in a project:"
if [ -n "$PATH_HINT" ]; then
  say "  ${c_bold}export PATH=\"$PATH_HINT:\$PATH\"${c_rst}   # add this to your shell profile first"
fi
say "  ${c_bold}cd your-project${c_rst}"
say "  ${c_bold}herd init${c_rst}"
