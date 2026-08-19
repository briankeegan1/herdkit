#!/usr/bin/env bash
# agents-pane-view.sh — HERD-668 (epic HERD-666, child 2 of the agent-roster CLI HERD-667/PR #784):
# the compact READ-ONLY specialist-AGENT-ROSTER control-room pane. A narrow sibling of the watch/
# backlog panes (herd-watch.sh / backlog-view.sh) — launched ONLY when AGENTS_PANE=on, by coordinator.sh
# (fresh control room) or bin/herd's `herd reload` / `herd pane agents` (in-place). This file carries
# no lever of its own (matching herd-watch.sh's convention): the AGENTS_PANE gate lives entirely in
# its callers, so a stray direct invocation still renders — the ship-dormant guarantee is "nothing
# ever LAUNCHES this pane while off", not "this script refuses to run".
#
# STRICTLY READ-ONLY. It renders two things, both from OBSERVED/CACHED state — never a live probe or
# spawn on the render path:
#   • the roster (scripts/herd/agents.sh's .herd/agents/*.md definitions) with each definition's
#     CACHED resolve verdict (herd_roster_cache_get — the exact cache `herd agents verify` writes;
#     this pane never re-probes);
#   • which specialist agent (if any) each IN-FLIGHT builder was spawned under — read from the
#     per-worktree `$WORKTREES_DIR/.herd-agent-<slug>` marker herd-feature.sh / herd-quick.sh write
#     only when HERD_AGENT was set (mirrors the HERD_ITEM_REF/.herd-ref-<slug> marker convention,
#     agent-watch.sh:_slug_ref_file); no marker → rendered "general".
# It never spawns, mutates, gates, or merges anything — a crash here can only blank this one pane.
#
# RENDER DISCIPLINE: reconciled from observed state on a SLOW tick (default 10s, override
# AGENTS_PANE_VIEW_POLL_SECS), re-painting only when the observed state OR the pane's width changed
# (mirrors backlog-view.sh's frame-latch + HERD-288 resize-repaint discipline, at a fraction of the
# cost — a roster listing + two file reads, no glow, no backend poll).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"

# Launch-binding guard (issue #60): require a real project config and refuse a foreign $PWD, exactly
# like backlog-view.sh / herd-watch.sh.
HERD_REQUIRE_PROJECT_CONFIG=1
# shellcheck source=/dev/null
. "$HERE/herd-config.sh"
herd_console_guard "agents pane" || exit 1
REPO="$PROJECT_ROOT"
# shellcheck source=/dev/null
. "$HERE/agents.sh"    # herd_roster_* — functions only, no side effects
# shellcheck source=/dev/null
. "$HERE/driver.sh"    # herd_driver_name — functions only, no side effects
# shellcheck source=/dev/null
. "$HERE/theme.sh"     # herd_theme_load_console — the C_* palette (seam-conformance B3: every
                       # themed color routes through here, never a raw ANSI literal)
herd_theme_load_console

last_frame=""

# file_mtime — portable helper (BSD vs GNU stat), mirrors backlog-view.sh.
if stat --version 2>/dev/null | grep -qE "GNU|uutils"; then  # pipe-ok: fixed short version banner, far under a pipe buffer
  file_mtime() { stat -c %Y "$1" 2>/dev/null || echo 0; }
else
  file_mtime() { stat -f %m "$1" 2>/dev/null || echo 0; }
fi

# ── render width (mirrors backlog-view.sh's HERD-288 discipline, no glow dependency here) ─────────
_MIN_RENDER_W=14
AGENTS_PANE_VIEW_TTY="${AGENTS_PANE_VIEW_TTY:-/dev/tty}"
_term_cols() {
  local c="" size=""
  if [ -n "${AGENTS_PANE_VIEW_COLS_CMD:-}" ]; then
    c="$($AGENTS_PANE_VIEW_COLS_CMD 2>/dev/null)" || c=""
  else
    size="$(stty size <"$AGENTS_PANE_VIEW_TTY" 2>/dev/null)" || size=""
    case "$size" in *' '*) c="${size#* }" ;; esac
    [ -n "$c" ] || { c="$(tput cols 2>/dev/null)" || c=""; }
  fi
  case "$c" in ''|*[!0-9]*) c=40 ;; esac
  printf '%s' "$c"
}
render_width() {
  local w; w=$(( $(_term_cols) - 2 ))
  [ "$w" -lt "$_MIN_RENDER_W" ] && w="$_MIN_RENDER_W"
  printf '%s' "$w"
}

# Quiet the pane's keyboard + hide the cursor, restoring both on any exit — mirrors backlog-view.sh.
# A resize busts the frame latch so the next tick repaints at the new width unconditionally.
_winch=0
trap '_winch=1; last_frame=""' WINCH
saved_tty=""
if [ -r "$AGENTS_PANE_VIEW_TTY" ]; then
  saved_tty=$(stty -g <"$AGENTS_PANE_VIEW_TTY" 2>/dev/null) || saved_tty=""
fi
restore_tty() {
  [ -n "$saved_tty" ] && stty "$saved_tty" <"$AGENTS_PANE_VIEW_TTY" 2>/dev/null
  printf '\033[?25h'  # seam-lint-ok: cursor visibility, not a themed color (mirrors backlog-view.sh/task-spec-view.sh)
}
trap 'restore_tty; exit 0' INT TERM
trap restore_tty EXIT
if [ -n "$saved_tty" ]; then
  stty -echo -icanon <"$AGENTS_PANE_VIEW_TTY" 2>/dev/null
  printf '\033[?25l'  # seam-lint-ok: cursor visibility, not a themed color (mirrors backlog-view.sh/task-spec-view.sh)
fi

# _truncate <text> <width> — hard-truncate with a trailing ellipsis; this pane is narrow by design
# (~quarter of the watch pane's width) so long roster/slug names must never wrap the layout.
_truncate() {
  local s="$1" w="$2"
  [ "$w" -gt 0 ] || { printf ''; return 0; }
  [ "${#s}" -le "$w" ] && { printf '%s' "$s"; return 0; }
  [ "$w" -le 1 ] && { printf '%s' "${s:0:$w}"; return 0; }
  printf '%s…' "${s:0:$((w-1))}"
}

# _verdict_glyph <verdict> — one-character summary of a roster entry's CACHED herd_roster_verify
# verdict (see agents.sh's verdict vocabulary: ok · unresolved · indeterminate · no-sentinel ·
# unverified · missing, or empty when never verified).
_verdict_glyph() {
  case "$1" in
    ok)                  printf '%s✓%s' "$C_GREEN" "$C_RESET" ;;
    unresolved|missing)  printf '%s✗%s' "$C_RED" "$C_RESET" ;;
    *)                   printf '%s?%s' "$C_DIM" "$C_RESET" ;;
  esac
}

# _in_flight_builders — one "<slug>\t<agent-or-empty>" line per registered builder worktree (kind
# `builder` rows in $WORKTREES_DIR/.herd-tabs — the same allowlist the sweep/tab-leak-guard read),
# paired with the specialist agent it was spawned under (the HERD-668 `.herd-agent-<slug>` marker;
# absent/empty → rendered "general" by the caller). Empty when nothing is in flight or the registry
# is absent (a brand-new control room with no builders yet).
_in_flight_builders() {
  local tabs="$WORKTREES_DIR/.herd-tabs" slug rest agent rows=""
  [ -f "$tabs" ] || return 0
  while read -r slug rest; do
    [ -n "$slug" ] || continue
    case "$rest" in *builder*) : ;; *) continue ;; esac
    agent=""
    [ -f "$WORKTREES_DIR/.herd-agent-$slug" ] && agent="$(cat "$WORKTREES_DIR/.herd-agent-$slug" 2>/dev/null || true)"
    rows="${rows}${slug}"$'\t'"${agent}"$'\n'
  done < "$tabs"
  # The registry is best-effort and may contain stale historical rows after an interrupted
  # respawn.  One canonical builder identity gets one visual row; retain the first observed row
  # so normal, byte-identical registries are unchanged.
  printf '%s' "$rows" | awk -F '\t' 'NF && !seen[$1]++'
}

# _state_hash — a cheap fingerprint of everything render_frame reads, so the frame-latch below only
# repaints on a REAL observed change (a new/edited definition, a fresh verify verdict, a builder
# spawned/retired) — never on an idle tick.
_state_hash() {
  {
    herd_roster_names 2>/dev/null
    local cf; cf="$(herd_roster_cache_file 2>/dev/null)"
    [ -n "$cf" ] && [ -f "$cf" ] && file_mtime "$cf"
    _in_flight_builders
    herd_driver_name 2>/dev/null
  } | cksum
}

# render_frame <width> — clear + repaint the pane: header, roster (glyph + name, cache-only), then
# the in-flight builders section (slug + the specialist agent it was spawned under, or "general").
render_frame() {
  local w="$1" drv names n=0 name f sha desc cached verdict tab
  tab="$(printf '\t')"
  clear
  printf '%s%s\xf0\x9f\x91\xa4 agents%s %s· %s%s\n\n' \
    "$C_BOLD" "$C_CYAN" "$C_RESET" "$C_DIM" "$(_truncate "$WORKSPACE_NAME" $((w-10)))" "$C_RESET"
  drv="$(herd_driver_name 2>/dev/null || printf 'herdr-claude')"
  names="$(herd_roster_names 2>/dev/null || true)"
  if [ -z "$names" ]; then
    printf '%s(no roster —%s\n%s herd agents new)%s\n' "$C_DIM" "$C_RESET" "$C_DIM" "$C_RESET"
  else
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      n=$((n+1))
      f="$(herd_roster_path "$name" 2>/dev/null)" || continue
      sha="$(herd_roster_sha "$f" 2>/dev/null)"
      cached="$(herd_roster_cache_get "$drv" "$name" "$sha" 2>/dev/null)"
      verdict="${cached%%$tab*}"
      printf ' %s %s\n' "$(_verdict_glyph "$verdict")" "$(_truncate "$name" $((w-2)))"
    done <<EOF
$names
EOF
  fi
  printf '\n%s%sbuilders%s\n' "$C_BOLD" "$C_BLUE" "$C_RESET"
  local ib bn=0
  ib="$(_in_flight_builders)"
  if [ -n "$ib" ]; then
    while IFS="$tab" read -r slug agent; do
      [ -n "$slug" ] || continue
      bn=$((bn+1))
      printf ' %s\n %s%s%s\n' "$(_truncate "$slug" "$w")" "$C_DIM" "$(_truncate "${agent:-general}" "$w")" "$C_RESET"
    done <<EOF
$ib
EOF
  fi
  [ "$bn" -eq 0 ] && printf '%s(none in flight)%s\n' "$C_DIM" "$C_RESET"
}

# ── the render loop ─────────────────────────────────────────────────────────
poll="${AGENTS_PANE_VIEW_POLL_SECS:-10}"
case "$poll" in ''|*[!0-9]*) poll=10 ;; esac

polls=0
while true; do
  w="$(render_width)"
  frame="$(_state_hash)|$w"
  if [ "$frame" != "$last_frame" ]; then
    render_frame "$w"
    last_frame="$frame"
  fi
  polls=$((polls + 1))
  # Test hook only (mirrors BACKLOG_VIEW_MAX_POLLS): caps the loop for hermetic tests. Unset in real
  # use → the viewer polls forever.
  if [ -n "${AGENTS_PANE_VIEW_MAX_POLLS:-}" ] && [ "$polls" -ge "$AGENTS_PANE_VIEW_MAX_POLLS" ]; then
    break
  fi
  sleep "$poll" 2>/dev/null || sleep 1
  if [ "$_winch" -eq 1 ]; then _winch=0; last_frame=""; fi
done
