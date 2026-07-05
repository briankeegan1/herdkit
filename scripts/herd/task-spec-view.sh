#!/usr/bin/env bash
# task-spec-view.sh <spec-file> — live, styled viewer for a BUILDER tab's otherwise-idle root pane.
#
# The builder lanes (herd-quick.sh / herd-feature.sh) create a tab, run the Claude sub-agent in its
# own pane, and leave the tab's ROOT pane sitting at an idle shell (fastfetch). This viewer fills that
# unused pane with the builder's live task spec — $WORKTREES_DIR/<slug>.task.md — so a human glancing
# at the tab sees WHAT the agent was told to build, not a blank shell. Strictly additive UX: gated on
# TASK_PANE_VIEW (default on), and the lanes only launch it when the root pane is otherwise unused
# (never over the app-preview pane) and never under the headless driver (which has no panes).
#
# Modeled DIRECTLY on backlog-view.sh's file loop:
#   • renders with glow + the bundled tokyonight style when available (DIRECTLY to the pane TTY so
#     colors apply — glow strips color when its output is captured/piped), else glow -s dark, else cat;
#   • repaints ONLY when the file's mtime changes, so an idle pane never scroll-yanks while read;
#   • NEVER crashes on a missing/deleted spec: when the task file is reaped (worktree removed / tab
#     torn down), it shows one quiet DIM 'task spec removed' line — no red, per the no-false-red rule —
#     and keeps polling silently, repainting if the file ever returns.
#
# It is a VIEWER, not a console: it takes no config-binding guard (it renders whatever file it is
# handed) and mutes the pane's keyboard the same way backlog-view.sh does so stray keystrokes never
# corrupt the render. Dies gracefully when the tab closes (the pane's processes are signalled → the
# trap restores the TTY and exits 0).
#
# Run:  bash task-spec-view.sh /path/to/<slug>.task.md
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SPEC="${1:?usage: task-spec-view.sh <task-spec-file>}"
# Glamour style — themed via HERD_THEME (default tokyonight, byte-identical to the bundled
# tokyonight.json). This viewer takes no config-binding guard (it renders whatever file it is handed),
# so it resolves the theme from the environment: HERD_THEME (exported by herd-config.sh, default
# tokyonight) and PROJECT_ROOT if present. theme.sh fails soft to the tokyonight built-in, and glow
# already drops color for a non-TTY, so an unset/unknown theme still renders cleanly.
# shellcheck source=/dev/null
. "$HERE/theme.sh"
STYLE="$(herd_theme_glow_style)"
BASENAME="$(basename "$SPEC")"
last_frame=""

# Quiet the pane's keyboard (mirrors backlog-view.sh). The TTY line discipline echoes keystrokes
# (e.g. arrow keys -> ^[[A) onto the rendered view, corrupting it; disabling stdin reads is not enough
# (echo happens in the kernel), so mute the tty with stty, then restore it (and the cursor) on ANY
# exit so the terminal is never left in a broken state.
saved_tty=""
if [ -r /dev/tty ]; then
  saved_tty=$(stty -g </dev/tty 2>/dev/null) || saved_tty=""
fi
restore_tty() {
  [ -n "$saved_tty" ] && stty "$saved_tty" </dev/tty 2>/dev/null
  printf '\033[?25h'  # show cursor
}
trap 'restore_tty; exit 0' INT TERM
trap restore_tty EXIT
if [ -n "$saved_tty" ]; then
  stty -echo -icanon </dev/tty 2>/dev/null
  printf '\033[?25l'  # hide cursor
fi

# glow_pane <glow-args...> — paint the pane TTY with glow under a PINNED color profile so every
# repaint renders identically without re-detecting the terminal, and with stdin detached from the
# keyboard-muted pane tty (mirrors backlog-view.sh). COLORTERM=truecolor + CLICOLOR_FORCE=1 lock
# glamour to the tokyonight TRUECOLOR palette — a pane that doesn't propagate COLORTERM would
# otherwise leave termenv to downsample the theme to flat 256-color — and </dev/null keeps glow
# from blocking on or misreading the muted tty during its terminal-capability probe (color still
# applies: glamour keys color off stdOUT and CLICOLOR_FORCE forces it on regardless of stdin).
glow_pane() { CLICOLOR_FORCE=1 COLORTERM=truecolor glow "$@" </dev/null; }

# file_mtime — portable helper; detect BSD vs GNU once at startup (mirrors backlog-view.sh).
if stat --version 2>/dev/null | grep -q GNU; then
  file_mtime() { stat -c %Y "$1" 2>/dev/null || echo 0; }
else
  file_mtime() { stat -f %m "$1" 2>/dev/null || echo 0; }
fi

# Tick cadence (default 2s, override for hermetic tests). Sanitize to a non-negative int.
tick="${TASK_PANE_VIEW_TICK_SECS:-2}"; case "$tick" in ''|*[!0-9]*) tick=2 ;; esac
ticks=0

while true; do
  # Snapshot existence + mtime ONCE per tick so the frame key and the render agree.
  if [ -f "$SPEC" ]; then present=1; frame="present|$(file_mtime "$SPEC")"; else present=0; frame="removed"; fi

  if [ "$frame" != "$last_frame" ]; then
    clear
    printf '\033[1;36m📋 task spec\033[0m \033[2m· %s · live\033[0m\n\n' "$BASENAME"
    if [ "$present" -eq 1 ]; then
      w=$(( $(tput cols 2>/dev/null || echo 100) - 2 ))
      render_rc=0
      if   command -v glow >/dev/null 2>&1 && [ -f "$STYLE" ]; then glow_pane -s "$STYLE" -w "$w" "$SPEC" || render_rc=$?
      elif command -v glow >/dev/null 2>&1;                    then glow_pane -s dark     -w "$w" "$SPEC" || render_rc=$?
      else cat "$SPEC" || render_rc=$?
      fi
      # Latch this frame ONLY on a successful render; a transient glow/cat failure leaves last_frame
      # unlatched so the next tick retries instead of sticking on stale/blank content.
      [ "$render_rc" -eq 0 ] && last_frame="$frame"
    else
      # No-false-red: the spec was reaped with the worktree/tab. One quiet DIM line, never red.
      printf '\033[2mtask spec removed\033[0m\n'
      last_frame="$frame"
    fi
  fi

  ticks=$((ticks + 1))
  # Test hook only: TASK_PANE_VIEW_MAX_TICKS caps the loop for hermetic tests. Unset in real use →
  # the viewer polls forever.
  if [ -n "${TASK_PANE_VIEW_MAX_TICKS:-}" ] && [ "$ticks" -ge "$TASK_PANE_VIEW_MAX_TICKS" ]; then
    break
  fi
  sleep "$tick"
done
