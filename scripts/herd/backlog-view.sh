#!/usr/bin/env bash
# backlog-view.sh — live, styled $BACKLOG_FILE viewer for the coordinator's left pane.
# Renders ONLY when content changes (no scroll-yank while reading), and renders glow DIRECTLY to
# the pane (a TTY) so colors actually apply — glow strips color when its output is captured/piped.
# Uses the bundled style if present, else glow dark, else cat.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/herd-config.sh"
REPO="$PROJECT_ROOT"
f="$REPO/$BACKLOG_FILE"
STYLE="$HERE/tokyonight.json"
last_frame=""

# Quiet the pane's keyboard. The TTY line discipline echoes keystrokes (e.g. arrow keys -> ^[[A)
# onto the rendered view, corrupting it. Disabling stdin reads is NOT enough — echo happens in the
# kernel regardless — so we mute the tty itself with stty, then restore it (and the cursor) on any
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

# file_mtime / epoch_to_hhmm — portable helpers; detect BSD vs GNU once at startup.
# GNU/Linux: stat -c %Y, date -d "@<epoch>". BSD/macOS: stat -f %m, date -r <epoch>.
if stat --version 2>/dev/null | grep -q GNU; then
  file_mtime()    { stat -c %Y "$1" 2>/dev/null || echo 0; }
  epoch_to_hhmm() { date -d "@$1" +%H:%M 2>/dev/null || echo '--:--'; }
else
  file_mtime()    { stat -f %m "$1" 2>/dev/null || echo 0; }
  epoch_to_hhmm() { date -r "$1" +%H:%M 2>/dev/null || echo '--:--'; }
fi

while true; do
  cur_mtime=$(file_mtime "$f")
  ts=$(git -C "$REPO" log -1 --format=%ct -- "$BACKLOG_FILE" 2>/dev/null || echo 0)
  sub=$(git -C "$REPO" log -1 --format=%s -- "$BACKLOG_FILE" 2>/dev/null)
  now=$(date +%s); age=$(( now - ts ))
  if [ "$ts" -gt 0 ] && [ "$age" -lt 90 ]; then
    banner=$(printf '\033[1;42;30m ✍️  JUST SCRIBED \033[0m \033[1m%s\033[0m' "$sub")
  elif [ "$ts" -gt 0 ]; then
    banner=$(printf '\033[2mlast scribed %s — %s\033[0m' "$(epoch_to_hhmm "$ts")" "$sub")
  else
    banner=$(printf '\033[2m(uncommitted working-tree changes)\033[0m')
  fi

  # render only when the file or banner state changes -> idle pane never repaints
  frame="$cur_mtime|$banner"
  if [ "$frame" != "$last_frame" ]; then
    clear
    printf '\033[1;36m📋 %s\033[0m  \033[2m(live)\033[0m\n' "$BACKLOG_FILE"
    printf '%b\n\n' "$banner"
    w=$(( $(tput cols 2>/dev/null || echo 100) - 2 ))
    if   command -v glow >/dev/null 2>&1 && [ -f "$STYLE" ]; then glow -s "$STYLE" -w "$w" "$f"
    elif command -v glow >/dev/null 2>&1;                    then glow -s dark     -w "$w" "$f"
    else cat "$f"; fi
    # Only latch this frame once the render actually succeeded. If glow (or cat) fails / paints
    # nothing, leave last_frame unchanged so the next 2s tick retries instead of sticking on
    # stale/blank content until mtime or banner changes again.
    if [ $? -eq 0 ]; then last_frame="$frame"; fi
  fi
  sleep 2
done
