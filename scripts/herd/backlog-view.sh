#!/usr/bin/env bash
# backlog-view.sh — live, styled backlog viewer for the coordinator's left pane.
# Renders ONLY when content changes (no scroll-yank while reading), and renders glow DIRECTLY to
# the pane (a TTY) so colors actually apply — glow strips color when its output is captured/piped.
# Uses the bundled style if present, else glow dark, else cat.
#
# BACKEND-AWARE (SCRIBE_BACKEND):
#   • file (or unset) — the historical path: render $BACKLOG_FILE with glow + git-log freshness.
#     BYTE-IDENTICAL to before; the file branch below is untouched.
#   • non-file (github/linear/…) — $BACKLOG_FILE is a frozen archive, not the live queue. Poll the
#     live open list via `herd backlog` on an interval (BACKLOG_VIEW_POLL_SECS, default 30s), render
#     it under a styled header (workspace · backend · live · HH:MM), and re-render only when the list
#     content actually changes (hashed). Fails SOFT (no-false-red rule): if `herd backlog` errors or
#     comes back empty (API/network trouble), keep the last good list on screen and append one dim
#     '⚠ backend unreachable since HH:MM (showing last good)' line — never blank, never red. The
#     backend's stderr (which could echo an API error body or headers) is discarded, so no secret or
#     raw error body ever reaches the pane; the warning is a fixed one-liner.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
# Launch-binding guard (issue #60): require a real project config (refuse the engine-dogfood
# rule-3 fallback) and refuse a foreign $PWD — set BEFORE sourcing so herd-config.sh enforces it.
HERD_REQUIRE_PROJECT_CONFIG=1
. "$HERE/herd-config.sh"
herd_console_guard "backlog viewer" || exit 1
REPO="$PROJECT_ROOT"
f="$REPO/$BACKLOG_FILE"
STYLE="$HERE/tokyonight.json"
last_frame=""
BACKLOG_VIEW_TMP=""   # backend-mode scratch file for glow; cleaned up on exit

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
  [ -n "$BACKLOG_VIEW_TMP" ] && rm -f "$BACKLOG_VIEW_TMP" 2>/dev/null
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
now_hhmm() { date +%H:%M 2>/dev/null || echo '--:--'; }

# ── incoming (github issues) — optional additive section (BACKLOG_VIEW_EXTRAS) ─
# When BACKLOG_VIEW_EXTRAS=github-issues this prints a SECOND, clearly-labeled section listing THIS
# repo's OPEN GitHub issues (the herd-report incoming inbox) — to be appended BENEATH the primary
# work queue in either render mode. It is STRICTLY additive & view-only: it never merges into the
# primary list and never feeds `herd backlog` or work-selection (SCRIBE_BACKEND stays the single
# source of truth for planned work).
#
# Off / any other value → prints NOTHING (return 0), so today's output is byte-identical.
#
# Fails SOFT per the no-false-red rule: gh missing, unauthenticated, offline, or any non-zero exit
# renders ONE dim 'incoming unavailable' line — never a red/alarming row, and it never breaks the
# primary section. gh's stderr (which can carry an API error body or auth token) is DISCARDED, so no
# secret or raw error body ever reaches the pane; the note is a fixed one-liner.
incoming_block() {
  [ "${BACKLOG_VIEW_EXTRAS:-}" = "github-issues" ] || return 0
  printf '\n\033[1;35m📥 incoming (github issues)\033[0m\n'
  if ! command -v gh >/dev/null 2>&1; then
    printf '\033[2m  incoming unavailable\033[0m\n'
    return 0
  fi
  local issues rc
  # Ask for a clean '#<n> <title>' line shape via gh's built-in --jq; run from $REPO so gh binds to
  # this project's repo. stdout only — stderr discarded (secrets / error bodies never reach the pane).
  issues="$(cd "$REPO" 2>/dev/null && gh issue list --state open --limit 30 \
              --json number,title --jq '.[] | "#\(.number) \(.title)"' 2>/dev/null)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '\033[2m  incoming unavailable\033[0m\n'
  elif [ -n "$issues" ]; then
    printf '%s\n' "$issues" | while IFS= read -r iln; do printf '  %s\n' "$iln"; done
  else
    printf '\033[2m  (no open issues)\033[0m\n'
  fi
}

# ── non-file backend viewer ───────────────────────────────────────────────────
# Everything below is inert for the file backend (the dispatch at the bottom only enters it when
# SCRIBE_BACKEND is a non-file value). Kept as functions so the historical file loop stays verbatim.

# list_to_md — turn `herd backlog` output into a markdown bullet list so glow renders it with REAL
# visual hierarchy (not a flat, monochrome wall the tokyonight theme has nothing to color). Tracker
# backends emit bare "#<id> <title>" lines; a flat "- #HERD-n title" bullet gives glow one
# undifferentiated run of body text. Instead we shape each item so glow+style paints it like the loved
# file-backend
# view: the identifier as an inline CODE chip (a distinct themed color/background — a tag that pops)
# and the title in BOLD (the theme's strong color), with a blank line between entries so they divide
# visually. This is PURE markdown-shaping — glow + the style do ALL the coloring (no ANSI hand-coding),
# and the plain-text `cat` fallback (which prints the raw list, not this) stays readable. An optional
# leading "- " is stripped first so a bullet a backend already added is reshaped uniformly, never
# doubled. A bare "#…" is never emitted (glow would balloon it into an H1). Blank in → blank out.
list_to_md() {
  printf '%s\n' "$1" | while IFS= read -r ln; do
    case "$ln" in '- '*) ln="${ln#- }" ;; esac   # normalize a pre-existing bullet so shaping is uniform
    case "$ln" in
      '')          printf '\n' ;;
      '#'*' '*)    # "#<id> <title>": code-chip id (themed tag) + bold title, then a blank line to divide
                   printf -- '- `%s` **%s**\n\n' "${ln%% *}" "${ln#* }" ;;
      '#'*)        printf -- '- `%s`\n\n' "$ln" ;;               # id-only line → just the chip
      *)           printf -- '- **%s**\n\n' "$ln" ;;             # no id → bold the whole line
    esac
  done
}

# render_backend_frame <list> <degraded 0|1> <since HH:MM> <refreshed HH:MM> <incoming>
# Clears + repaints the pane: styled header, then the list (glow if available, else plain text), then
# — only when degraded — one dim last-good warning line, then the optional additive <incoming> block
# (empty when BACKLOG_VIEW_EXTRAS is off → no change). Returns non-zero if the body render failed so
# the caller can leave last_frame unlatched and retry (mirrors the file loop's success-latch).
render_backend_frame() {
  local list="$1" degraded="$2" since="$3" refreshed="$4" incoming="${5:-}"
  local hhmm="${refreshed:---:--}" rc=0
  clear
  # e.g. '📋 herdkit · linear · live · 15:42'
  printf '\033[1;36m📋 %s\033[0m \033[2m· %s · live · %s\033[0m\n\n' \
    "$WORKSPACE_NAME" "$SCRIBE_BACKEND" "$hhmm"
  local w; w=$(( $(tput cols 2>/dev/null || echo 100) - 2 ))
  if [ -n "$list" ]; then
    if   command -v glow >/dev/null 2>&1 && [ -f "$STYLE" ]; then
      list_to_md "$list" > "$BACKLOG_VIEW_TMP" && glow -s "$STYLE" -w "$w" "$BACKLOG_VIEW_TMP" || rc=$?
    elif command -v glow >/dev/null 2>&1; then
      list_to_md "$list" > "$BACKLOG_VIEW_TMP" && glow -s dark -w "$w" "$BACKLOG_VIEW_TMP" || rc=$?
    else
      printf '%s\n' "$list" || rc=$?
    fi
  else
    printf '\033[2m(no open items yet)\033[0m\n'
  fi
  if [ "$degraded" -eq 1 ]; then
    printf '\033[2m⚠ backend unreachable since %s (showing last good)\033[0m\n' "$since"
  fi
  # Strictly-additive incoming section (empty unless BACKLOG_VIEW_EXTRAS=github-issues).
  [ -n "$incoming" ] && printf '%s\n' "$incoming"
  return "$rc"
}

# run_backend_mode — poll `herd backlog` and render the live open list (see the header comment).
run_backend_mode() {
  # Resolve the CLI from PATH first (so a project install / a test's fake `herd` wins), then fall
  # back to the bundled binary next to this script.
  local herd_bin; herd_bin="$(command -v herd 2>/dev/null || true)"
  [ -n "$herd_bin" ] || herd_bin="$HERE/../bin/herd"

  # Poll interval: default 30s, override via BACKLOG_VIEW_POLL_SECS. Sanitize to a non-negative int.
  local poll="${BACKLOG_VIEW_POLL_SECS:-30}"
  case "$poll" in ''|*[!0-9]*) poll=30 ;; esac

  BACKLOG_VIEW_TMP="$(mktemp 2>/dev/null || echo "${TMPDIR:-/tmp}/herd-backlog-view.$$.md")"

  local last_good="" last_hash="" degraded=0 since="" refreshed="" frame="" polls=0
  while true; do
    # Capture stdout only; DISCARD stderr — it may carry the backend's raw API error body or headers
    # (secrets). Run from $REPO so `herd backlog` finds this project's .herd/config.
    local raw rc trimmed cur_hash
    raw="$(cd "$REPO" 2>/dev/null && "$herd_bin" backlog 2>/dev/null)"; rc=$?
    trimmed="$(printf '%s' "$raw" | tr -d '[:space:]')"

    # Optional additive incoming section (github issues). Empty unless BACKLOG_VIEW_EXTRAS is on; its
    # content is folded into the frame key so a change in the incoming list also triggers a repaint.
    local incoming inc_hash
    incoming="$(incoming_block)"
    inc_hash="$(printf '%s' "$incoming" | cksum)"

    if [ "$rc" -eq 0 ] && [ -n "$trimmed" ]; then
      # Healthy poll. Re-render only when the list content actually changed (hash it).
      degraded=0; since=""
      cur_hash="$(printf '%s' "$raw" | cksum)"
      if [ "$cur_hash" != "$last_hash" ]; then
        last_hash="$cur_hash"; last_good="$raw"; refreshed="$(now_hhmm)"
      fi
      frame="ok|$last_hash|$refreshed|$inc_hash"
    else
      # Degraded poll (error or empty). Keep the last good list; never blank, never red. Stamp the
      # unreachable-since time once, on the transition into degraded.
      if [ "$degraded" -eq 0 ]; then degraded=1; since="$(now_hhmm)"; fi
      frame="down|$last_hash|$since|$inc_hash"
    fi

    if [ "$frame" != "$last_frame" ]; then
      if render_backend_frame "$last_good" "$degraded" "$since" "$refreshed" "$incoming"; then
        last_frame="$frame"
      fi
    fi

    polls=$((polls + 1))
    # Test hook only: BACKLOG_VIEW_MAX_POLLS caps the loop for hermetic tests. Unset in real use →
    # the viewer polls forever.
    if [ -n "${BACKLOG_VIEW_MAX_POLLS:-}" ] && [ "$polls" -ge "$BACKLOG_VIEW_MAX_POLLS" ]; then
      break
    fi
    sleep "$poll"
  done
}

# ── dispatch ──────────────────────────────────────────────────────────────────
# Non-file backend → the live-poll viewer above. file (or unset) → the historical loop below, byte
# for byte as it was.
if [ "${SCRIBE_BACKEND:-file}" != "file" ]; then
  run_backend_mode
  exit 0
fi

# Incoming-section refresh cadence for the file loop. The file loop ticks every 2s (mtime/banner
# watch), but `gh issue list` must NOT run that often — refresh the incoming list on its own interval
# (default 30s, override via BACKLOG_VIEW_POLL_SECS) and reuse the cached block between refreshes. Off
# by default: when BACKLOG_VIEW_EXTRAS is unset the block stays empty and gh is never invoked.
inc_poll="${BACKLOG_VIEW_POLL_SECS:-30}"; case "$inc_poll" in ''|*[!0-9]*) inc_poll=30 ;; esac
incoming=""; inc_next=0

while true; do
  cur_mtime=$(file_mtime "$f")
  ts=$(git -C "$REPO" log -1 --format=%ct -- "$BACKLOG_FILE" 2>/dev/null || echo 0)
  ts=${ts:-0}
  sub=$(git -C "$REPO" log -1 --format=%s -- "$BACKLOG_FILE" 2>/dev/null)
  sub=${sub:-}
  now=$(date +%s); age=$(( now - ts ))
  if [ "$ts" -gt 0 ] && [ "$age" -lt 90 ]; then
    banner=$(printf '\033[1;42;30m ✍️  JUST SCRIBED \033[0m \033[1m%s\033[0m' "$sub")
  elif [ "$ts" -gt 0 ]; then
    banner=$(printf '\033[2mlast scribed %s — %s\033[0m' "$(epoch_to_hhmm "$ts")" "$sub")
  else
    banner=$(printf '\033[2m(uncommitted working-tree changes)\033[0m')
  fi

  # Optional additive incoming section (github issues). Empty unless BACKLOG_VIEW_EXTRAS=github-issues
  # → zero change to today's output; its content is folded into the frame key so a change in the
  # incoming list also triggers a repaint. Refreshed at most every $inc_poll secs (cached in between)
  # so the 2s file-watch tick never hammers `gh`.
  if [ "${BACKLOG_VIEW_EXTRAS:-}" = "github-issues" ] && [ "$now" -ge "$inc_next" ]; then
    incoming="$(incoming_block)"
    inc_next=$(( now + inc_poll ))
  fi

  # render only when the file, banner, or incoming state changes -> idle pane never repaints
  frame="$cur_mtime|$banner|$(printf '%s' "$incoming" | cksum)"
  if [ "$frame" != "$last_frame" ]; then
    clear
    printf '\033[1;36m📋 %s\033[0m  \033[2m(live)\033[0m\n' "$BACKLOG_FILE"
    printf '%b\n\n' "$banner"
    w=$(( $(tput cols 2>/dev/null || echo 100) - 2 ))
    if   command -v glow >/dev/null 2>&1 && [ -f "$STYLE" ]; then glow -s "$STYLE" -w "$w" "$f"
    elif command -v glow >/dev/null 2>&1;                    then glow -s dark     -w "$w" "$f"
    else cat "$f"; fi
    # Capture the render outcome BEFORE printing the additive section so latching still keys off the
    # primary render (a failed glow/cat must not be masked by the incoming block's exit status).
    render_rc=$?
    # Strictly-additive incoming section, beneath the primary queue (empty when the key is off).
    [ -n "$incoming" ] && printf '%s\n' "$incoming"
    # Only latch this frame once the render actually succeeded. If glow (or cat) fails / paints
    # nothing, leave last_frame unchanged so the next 2s tick retries instead of sticking on
    # stale/blank content until mtime or banner changes again.
    if [ "$render_rc" -eq 0 ]; then last_frame="$frame"; fi
  fi
  sleep 2
done
