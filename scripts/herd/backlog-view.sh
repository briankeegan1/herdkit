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
#     live open list via `herd backlog --rich` (falling back to plain `herd backlog` on an older
#     CLI) on an interval (BACKLOG_VIEW_POLL_SECS, default 30s), render
#     it under a styled header (workspace · backend · live · HH:MM), and re-render only when the list
#     content actually changes (hashed). Fails SOFT (no-false-red rule): if `herd backlog` errors or
#     comes back empty (API/network trouble), keep the last good list on screen and append one dim
#     '⚠ backend unreachable since HH:MM (showing last good)' line — never blank, never red. The
#     backend's stderr (which could echo an API error body or headers) is discarded, so no secret or
#     raw error body ever reaches the pane; the warning is a fixed one-liner.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"

# ── one-shot shaping seam (--emit-md) ──────────────────────────────────────────
# `backlog-view.sh --emit-md` reads a `herd backlog[ --rich]` list on STDIN and writes the EXACT
# markdown the live pane hands to glow (shape_md) to STDOUT, then exits 0. It is deterministic and
# TTY-/backend-/glow-independent — the seam the render tests assert on, because scraping the live
# pane paint is not portable: glow paints straight to the pane TTY, so on a non-TTY capture the
# shaped item markdown never reaches stdout. The heavy viewer bootstrap below (project config,
# console guard, theme, TTY muting, poll loop) is SKIPPED in this mode — pure shaping needs none of
# it, and its TTY escape codes / cursor-restore would otherwise corrupt the emitted markdown. The
# actual emit happens once shape_md is defined (dispatch just below the shaping helpers).
EMIT_MD=0
case "${1:-}" in --emit-md) EMIT_MD=1 ;; esac

if [ "$EMIT_MD" = 0 ]; then
  # Launch-binding guard (issue #60): require a real project config (refuse the engine-dogfood
  # rule-3 fallback) and refuse a foreign $PWD — set BEFORE sourcing so herd-config.sh enforces it.
  HERD_REQUIRE_PROJECT_CONFIG=1
  . "$HERE/herd-config.sh"
  herd_console_guard "backlog viewer" || exit 1
  REPO="$PROJECT_ROOT"
  f="$REPO/$BACKLOG_FILE"
  # Glamour style — themed via HERD_THEME (default tokyonight, byte-identical to the bundled
  # tokyonight.json). theme.sh resolves .herd/themes/<name>/glow.json → templates/themes/<name>/ →
  # tokyonight, failing soft to the built-in default; glow itself already drops color for a non-TTY.
  # shellcheck source=/dev/null
  . "$HERE/theme.sh"
  STYLE="$(herd_theme_glow_style)"
fi
last_frame=""
BACKLOG_VIEW_TMP=""   # backend-mode scratch file for glow; cleaned up on exit

# Quiet the pane's keyboard. The TTY line discipline echoes keystrokes (e.g. arrow keys -> ^[[A)
# onto the rendered view, corrupting it. Disabling stdin reads is NOT enough — echo happens in the
# kernel regardless — so we mute the tty itself with stty, then restore it (and the cursor) on any
# exit so the terminal is never left in a broken state.
# The pane tty. Overridable via BACKLOG_VIEW_TTY (default /dev/tty) so tests never touch the real
# controlling terminal: the suite runs INSIDE a live pane, where reading its /dev/tty wedges. Tests set
# this to /dev/null (which is not a tty → saved_tty stays empty → the no-tty path) and inject keypresses
# through the BACKLOG_VIEW_KEY_CMD hook below. In real use it is unset → /dev/tty, byte-identical.
HERD_VIEW_TTY="${BACKLOG_VIEW_TTY:-/dev/tty}"
if [ "$EMIT_MD" = 0 ]; then
  saved_tty=""
  if [ -r "$HERD_VIEW_TTY" ]; then
    saved_tty=$(stty -g <"$HERD_VIEW_TTY" 2>/dev/null) || saved_tty=""
  fi
  restore_tty() {
    [ -n "$saved_tty" ] && stty "$saved_tty" <"$HERD_VIEW_TTY" 2>/dev/null
    printf '\033[?25h'  # show cursor
    [ -n "$BACKLOG_VIEW_TMP" ] && rm -f "$BACKLOG_VIEW_TMP" 2>/dev/null
  }
  trap 'restore_tty; exit 0' INT TERM
  trap restore_tty EXIT
  if [ -n "$saved_tty" ]; then
    stty -echo -icanon <"$HERD_VIEW_TTY" 2>/dev/null
    printf '\033[?25l'  # hide cursor
  fi
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

# _poll_read_key <secs> — wait up to <secs> for ONE keypress from the pane tty; sets $_poll_key to the
# key (empty when none) and returns 0 when a key was read, >128 on timeout, other non-zero on EOF/error
# (mirroring `read -t`). This is the ONLY place the tty is read, so tests override it via the
# BACKLOG_VIEW_KEY_CMD hook (invoked as `<cmd> <secs>`, same contract) to drive the refresh logic
# WITHOUT ever touching a real /dev/tty. Unset in real use → the plain single-char tty read.
_poll_key=""
_poll_read_key() {
  _poll_key=""
  if [ -n "${BACKLOG_VIEW_KEY_CMD:-}" ]; then
    _poll_key="$($BACKLOG_VIEW_KEY_CMD "$1")"; return $?
  fi
  IFS= read -r -t "$1" -n 1 _poll_key <"$HERD_VIEW_TTY"
}

# poll_wait <secs> — the poll interval's wait, made interruptible for the manual-refresh key
# (HERD-48). Normally waits <secs> and returns 0; if the pane is interactive and the user presses
# 'r'/'R' during the wait, it returns 10 at once so the caller can force an immediate refetch+repaint.
# Every OTHER key is ignored — we keep waiting out the REMAINING interval, so a stray keystroke never
# shortens the poll cadence nor hammers the backend. The read IS the sleep: its timeout equals the
# poll interval, so with no key pressed the cadence is byte-identical to the old plain `sleep`.
#
# FAIL-SOFT per the no-false-red rule: with no usable pane tty (headless driver, CI, tests — saved_tty
# empty or the tty unreadable, and no key hook) it degrades to a plain `sleep` and never touches the
# tty at all. The read never crashes and never busy-loops: rc >128 = timeout (interval elapsed), rc
# 1..128 = EOF/error; only rc 0 carries a key. On a wedged tty (EOF/error) we sleep the remainder.
poll_wait() {
  local secs="$1" rc deadline now rem
  case "$secs" in ''|*[!0-9]*) secs=0 ;; esac
  if [ -z "${BACKLOG_VIEW_KEY_CMD:-}" ] && { [ -z "$saved_tty" ] || [ ! -r "$HERD_VIEW_TTY" ]; }; then
    [ "$secs" -gt 0 ] && sleep "$secs"
    return 0
  fi
  now=$(date +%s); deadline=$(( now + secs )); rem="$secs"
  while [ "$rem" -gt 0 ]; do
    _poll_read_key "$rem"; rc=$?
    if [ "$rc" -eq 0 ]; then
      case "$_poll_key" in r|R) return 10 ;; esac
      # any other key → keep waiting out the remaining interval
    elif [ "$rc" -gt 128 ]; then
      return 0            # timed out — full interval elapsed
    else
      # EOF/error on the source: don't spin — sleep any time left in the interval, then return.
      now=$(date +%s); rem=$(( deadline - now ))
      [ "$rem" -gt 0 ] && sleep "$rem"
      return 0
    fi
    now=$(date +%s); rem=$(( deadline - now ))
  done
  return 0
}

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

# rich_to_md — turn `herd backlog --rich` TSV (see backends/linear.sh _backend_list_open_rich:
# "#<id>\t<state-type>\t<state-name>\t<title>\t<desc>") into markdown that renders with the loved
# file-backend hierarchy: items GROUPED under H2 state headers (🚧 in progress / 🔜 queued /
# ❓ triage — the theme's H2 purple bar), the id as a code chip, ONLY the title in bold (the
# theme's strong orange), and the description as a plain TOP-LEVEL paragraph between bullets (the
# theme's body color) — so status is visible at a glance and the pane is no longer a wall of bold.
# The paragraph is deliberately NOT indented under the bullet: glamour merges a list item's
# indented continuation paragraph INTO the item's own flow with no separator (title and body glue
# together as '…(In Progress)DESC…'), while a bare paragraph renders on its own line at the item
# margin — the exact visual break of the loved file-backend view. Overlong
# titles are split at a word boundary: the head stays bold, the spill joins the body text (fixes
# paragraph-length tracker titles rendering entirely bold). A description that merely repeats the
# title (the scribe files title = first line of the full text) is de-duplicated. Emphasis markers
# are kept SANE so glow never leaks a literal '**': the bolded head has any internal ** stripped
# (the template already bolds it), and the body's inline **bold** is balanced — an upstream desc cap
# (linear.sh truncates at 280), our BODY_MAX cut, or the title-spill join can split a **…** span and
# orphan one marker, which glow renders as a stray literal '**' (the backend-mode render bug,
# follow-on to #152/#153). PURE markdown
# shaping — glow + the theme style do ALL the coloring, no ANSI hand-coding.
rich_to_md() {
  printf '%s\n' "$1" | python3 -c '
import sys

TITLE_MAX, BODY_MAX = 110, 300
GROUP = {"started": "🚧 in progress", "unstarted": "🔜 queued", "backlog": "🔜 queued", "triage": "❓ triage"}
ORDER = ["🚧 in progress", "🔜 queued", "❓ triage"]

def strip_bold(s):
    # HEAD text is wholly emphasized by the item template (**%s**). Any ** already inside it would
    # nest/break that span (glow then leaks a literal **), so drop internal markers outright — the
    # template supplies the bold.
    return s.replace("**", "")

def balance_bold(s):
    # BODY text keeps its own inline **bold** (rendered as a plain paragraph, not template-bolded),
    # but a **…** span can be split by an upstream desc cap (linear.sh truncates at 280), our own
    # BODY_MAX cut, or the title-spill join — orphaning one marker. glow then renders that lone ** as
    # literal text (often stranded on its own wrapped line: the backend-mode render bug). Drop only
    # the unmatched marker so legitimate, balanced bold still renders while no orphan reaches glow.
    while s.count("**") % 2:
        i = s.rfind("**")
        s = s[:i] + s[i + 2:]
    return s

groups = {}
for ln in sys.stdin.read().splitlines():
    if not ln.strip():
        continue
    p = ln.split("\t")
    ident = p[0]
    stype = p[1] if len(p) > 1 else ""
    sname = p[2] if len(p) > 2 else ""
    title = p[3] if len(p) > 3 else ""
    desc  = p[4] if len(p) > 4 else ""
    groups.setdefault(GROUP.get(stype, "🔜 queued"), []).append((ident, stype, sname, title, desc))

out = []
for g in ORDER:
    items = groups.get(g)
    if not items:
        continue
    out.append("## %s (%d)\n" % (g, len(items)))
    for ident, stype, sname, title, desc in items:
        body = desc
        if title and body.startswith(title):
            body = body[len(title):].lstrip(" .·—-")
        head = title or ident
        if len(head) > TITLE_MAX:
            cut = head.rfind(" ", 60, TITLE_MAX)
            if cut < 0:
                cut = TITLE_MAX
            head, spill = head[:cut].rstrip(), head[cut:].strip()
            body = (spill + " " + body).strip() if body else spill
        if len(body) > BODY_MAX:
            body = body[:BODY_MAX - 1].rstrip() + "…"
        head = strip_bold(head)          # head is bolded by the template — no internal ** allowed
        body = balance_bold(body)        # keep balanced bold, drop any wrap/cut-orphaned marker
        state = " _(%s)_" % sname if (stype == "started" and sname) else ""
        out.append("- `%s` **%s**%s\n" % (ident, head, state))
        if body:
            out.append("%s\n" % body)
out.append("")
sys.stdout.write("\n".join(out))
'
}

# shape_md — pick the renderer from the list content itself: any TAB means the backend answered
# --rich with the TSV shape; a tab-free list is the plain "#<id> <title>" contract (older engine,
# or a backend with no rich op — `herd backlog --rich` falls back to the plain list there).
_TAB="$(printf '\t')"
shape_md() {
  case "$1" in
    *"$_TAB"*) rich_to_md "$1" ;;
    *)         list_to_md "$1" ;;
  esac
}

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

# ── one-shot shaping seam dispatch ─────────────────────────────────────────────
# (See the --emit-md note near the top.) With both shaping helpers now defined, emit the shaped
# markdown for the list on STDIN and exit — before any viewer/config/glow/TTY code runs.
if [ "$EMIT_MD" = 1 ]; then
  shape_md "$(cat)"
  exit 0
fi

# glow_pane <glow-args...> — paint the pane TTY with glow under a PINNED color profile so every
# repaint renders identically without re-detecting the terminal, and with stdin detached from the
# (muted) pane tty. Two robustness fixes for the backend viewer's execution context:
#   • COLORTERM=truecolor + CLICOLOR_FORCE=1 lock glamour to the tokyonight TRUECOLOR palette. A
#     pane that doesn't propagate COLORTERM (e.g. env stripped down the herd-config path) would
#     otherwise leave termenv to guess from TERM alone and downsample the theme to flat 256-color
#     (the '38;5;…' monochrome look) — pinning the profile keeps the truecolor chip/title/bullets.
#   • </dev/null detaches glow's stdin from the keyboard-muted pane tty, so glow never blocks on or
#     misreads that tty during its terminal-capability probe. Color still applies because glamour
#     keys color off stdOUT (the pane) and CLICOLOR_FORCE forces it on regardless of stdin.
glow_pane() { CLICOLOR_FORCE=1 COLORTERM=truecolor glow "$@" </dev/null; }

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
      shape_md "$list" > "$BACKLOG_VIEW_TMP" && glow_pane -s "$STYLE" -w "$w" "$BACKLOG_VIEW_TMP" || rc=$?
    elif command -v glow >/dev/null 2>&1; then
      shape_md "$list" > "$BACKLOG_VIEW_TMP" && glow_pane -s dark -w "$w" "$BACKLOG_VIEW_TMP" || rc=$?
    else
      # No glow: print the raw list, taming rich TSV's tabs into readable spacing.
      printf '%s\n' "$list" | tr '\t' ' ' || rc=$?
      # SELF-DIAGNOSING degraded render (HERD-45): glow is what paints the pretty pane; without it
      # the frame above is raw markdown. Point the user straight at the fix at the exact moment they
      # hit the degradation — one dim informational line, never red (no-false-red rule). Mirrors the
      # fzf self-hint in `herd backlog browse`; does not touch $rc (a bad hint must never fail render).
      printf '\033[2mglow not found — showing raw markdown; run herd doctor for the install command\033[0m\n'
    fi
  else
    printf '\033[2m(no open items yet)\033[0m\n'
  fi
  if [ "$degraded" -eq 1 ]; then
    printf '\033[2m⚠ backend unreachable since %s (showing last good)\033[0m\n' "$since"
  fi
  # Strictly-additive incoming section (empty unless BACKLOG_VIEW_EXTRAS=github-issues).
  [ -n "$incoming" ] && printf '%s\n' "$incoming"
  # HERD-48 hint — only when the pane tty is interactive (a key can actually be pressed); omitted on
  # the headless/CI/test fallback so that path stays byte-identical. Does not affect the frame key.
  [ -n "$saved_tty" ] && printf '\033[2mr = refresh\033[0m\n'
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

  # Scratch file glow renders. It MUST end in .md: glow picks its renderer from the file extension,
  # and a no-suffix temp file is guessed to be SOURCE CODE — so glow runs it through chroma and
  # syntax-highlights the RAW markdown (literal '**'/backticks, flat '38;5;…' 256-color) instead of
  # glamour-rendering it (the exact backend-mode corruption this fixes; the file-loop branch never
  # hit it because it renders the real BACKLOG.md). mktemp can't portably add a suffix (GNU has
  # --suffix, BSD does not), so mktemp for the secure unique name, then rename to add .md. If the
  # rename fails we keep the original name (degraded render, but never a crash).
  BACKLOG_VIEW_TMP="$(mktemp 2>/dev/null || echo "${TMPDIR:-/tmp}/herd-backlog-view.$$.md")"
  case "$BACKLOG_VIEW_TMP" in
    *.md) : ;;  # fallback path already carries .md
    *)    if mv "$BACKLOG_VIEW_TMP" "$BACKLOG_VIEW_TMP.md" 2>/dev/null; then
            BACKLOG_VIEW_TMP="$BACKLOG_VIEW_TMP.md"
          fi ;;
  esac

  local last_good="" last_hash="" degraded=0 since="" refreshed="" frame="" polls=0
  while true; do
    # Capture stdout only; DISCARD stderr — it may carry the backend's raw API error body or headers
    # (secrets). Run from $REPO so `herd backlog` finds this project's .herd/config.
    # Ask for --rich first (state-grouped TSV when the backend supports it; backends without the
    # op serve the plain list under the same flag). A herd that predates --rich rejects the flag
    # non-zero — retry plain so the viewer never degrades just because the CLI is older.
    local raw rc trimmed cur_hash
    raw="$(cd "$REPO" 2>/dev/null && "$herd_bin" backlog --rich 2>/dev/null)"; rc=$?
    if [ "$rc" -ne 0 ]; then
      raw="$(cd "$REPO" 2>/dev/null && "$herd_bin" backlog 2>/dev/null)"; rc=$?
    fi
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
    # Wait out the poll interval — but let the user force an instant refresh with r/R (HERD-48). On
    # refresh clear last_hash (so the NEXT poll treats the re-fetch as new → refreshes last_good and the
    # HH:MM stamp) AND bust last_frame (so the repaint actually happens): the frame key is content-hash
    # + HH:MM + incoming, so unchanged content polled twice inside the same minute is otherwise latched
    # as an identical frame and would NOT repaint. Busting last_frame guarantees the requested repaint.
    poll_wait "$poll" || { last_hash=""; last_frame=""; }
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
    # HERD-48 hint — only when the pane tty is interactive; omitted headless so that path is unchanged.
    [ -n "$saved_tty" ] && printf '\033[2mr = refresh\033[0m\n'
    # Only latch this frame once the render actually succeeded. If glow (or cat) fails / paints
    # nothing, leave last_frame unchanged so the next 2s tick retries instead of sticking on
    # stale/blank content until mtime or banner changes again.
    if [ "$render_rc" -eq 0 ]; then last_frame="$frame"; fi
  fi
  # Wait out the 2s tick — interruptible by the manual-refresh key (HERD-48). On r/R, bust the frame
  # latch so the next iteration force-repaints with a fresh git-log freshness read even when the file
  # (and banner) are unchanged.
  poll_wait 2 || last_frame=""
done
