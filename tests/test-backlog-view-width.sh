#!/usr/bin/env bash
# test-backlog-view-width.sh — width-conformance guard for the backlog pane's rendered frame (HERD-288).
#
# The pane corrupts on zoom/resize because glamour hard-wraps AND right-pads its lines to the exact
# width it was handed: a frame rendered at 118 columns and left on screen in an 80-column pane
# re-wraps every padded line, producing the double-spaced stray-char mess. The viewer's half of that
# contract is "always render at the CURRENT width" (asserted by test-backlog-view-resize.sh). THIS
# test asserts the other half — that the frame the viewer produces at width N genuinely FITS in N
# columns, so a correctly-sized render can never be the thing that overflows the pane.
#
# It drives the real pipeline the pane uses: `backlog-view.sh --emit-md` (the deterministic shaping
# seam) → `glow -s "$(herd_theme_glow_style)" -w N`. Scraping the live pane paint is not portable
# (glow paints straight to the pane tty), which is exactly why the --emit-md seam exists.
#
# Measurement: strip OSC 8 hyperlinks (ESC ]8;;URL ST … ESC ]8;; ST — emitted around id chips for
# linear rich data) and SGR color (ESC [ … m), then compare the VISIBLE character count of every line
# against N. Character count is a deliberate UNDER-estimate of terminal cells for the emoji in the
# group headers (🚧/🔜/❓ occupy 2 cells but 1 char), so the assertion is conservative: it can only
# fire on a genuine overflow, never on an emoji-width rounding artifact.
#
# Widths cover the narrow clamp floor (20), a split pane (60), a default pane (80) and a wide/zoomed
# pane (120). Both list shapes are exercised: the plain "#<id> <title>" contract and the rich TSV
# (tabs → rich_to_md, with a URL so the OSC 8 stripping is genuinely exercised).
#
# SKIP-SOFT: glow is an OPTIONAL dependency (the pane falls back to plain text without it), so its
# absence is a clean skip, never a red row.
#
# Run:  bash tests/test-backlog-view-width.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../scripts/herd/backlog-view.sh"

if ! command -v glow >/dev/null 2>&1; then
  echo "SKIP: glow not installed (optional dep — the pane falls back to plain text, nothing to guard)"
  exit 0
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "SKIP: python3 not installed (needed to measure visible line width)"
  exit 0
fi

PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass(){ PASS=$((PASS+1)); }

# The pane's own style resolution (theme.sh), so this asserts the frame the pane actually paints.
# shellcheck source=/dev/null
PROJECT_ROOT="$(cd "$HERE/.." && pwd)" . "$HERE/../scripts/herd/theme.sh" 2>/dev/null || true
STYLE="$(herd_theme_glow_style 2>/dev/null || true)"

# max_visible_width — read a rendered frame on stdin, print the widest VISIBLE line length.
max_visible_width() {
  python3 -c '
import sys, re
s = sys.stdin.buffer.read().decode("utf-8", "replace")
s = re.sub(r"\x1b\]8;;[^\x07\x1b]*(?:\x1b\\|\x07)", "", s)   # OSC 8 hyperlink open/close
s = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", s)                 # SGR / CSI
print(max((len(l.rstrip("\r")) for l in s.split("\n")), default=0))
'
}

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# render_at <width> <list…on stdin> — the exact pipeline the pane runs. glow picks its renderer from
# the file EXTENSION, so the shaped markdown must land in a .md file or it is syntax-highlighted as
# source instead of glamour-rendered (see test-backlog-view-render.sh).
render_at() {
  local w="$1" tmp="$T/frame.md"
  bash "$SCRIPT" --emit-md > "$tmp" || return 1
  if [ -n "$STYLE" ] && [ -f "$STYLE" ]; then
    CLICOLOR_FORCE=1 COLORTERM=truecolor glow -s "$STYLE" -w "$w" "$tmp" </dev/null
  else
    CLICOLOR_FORCE=1 COLORTERM=truecolor glow -s dark -w "$w" "$tmp" </dev/null
  fi
}

# Plain list: a long title that MUST wrap at every width under test.
PLAIN="$(printf '%s\n' \
  "#HERD-288 the backlog pane corrupts on zoom and resize because both frame-latch keys omit the render width" \
  "#HERD-42 short one")"

# Rich TSV: id, state-type, state-name, title, description, assignee, url. The url makes the id chip an
# OSC 8 hyperlink, so the stripping above is exercised rather than assumed.
RICH="$(printf '#HERD-288\tstarted\tIn Progress\tbacklog pane corrupts on zoom and resize\tglamour pads roughly eighty percent of rendered lines with trailing spaces out to the full render width, so a narrower pane hard-wraps every padded line into a double-spaced stray-char mess\tbrian\thttps://linear.app/herd/issue/HERD-288\n#HERD-42\tbacklog\tBacklog\tshort queued item\t\t\t\n')"

for w in 20 60 80 120; do
  got="$(printf '%s\n' "$PLAIN" | render_at "$w" | max_visible_width)" \
    || fail "plain: render failed at -w $w"
  [ -n "$got" ] || fail "plain: no output at -w $w"
  [ "$got" -le "$w" ] \
    || fail "plain: rendered frame overflows its own width at -w $w (widest visible line: $got cols)"
  pass

  got="$(printf '%s' "$RICH" | render_at "$w" | max_visible_width)" \
    || fail "rich: render failed at -w $w"
  [ -n "$got" ] || fail "rich: no output at -w $w"
  [ "$got" -le "$w" ] \
    || fail "rich: rendered frame overflows its own width at -w $w (widest visible line: $got cols)"
  pass
done

# Sanity: the measurement is not vacuously passing on an empty/blank frame — a wide render must
# actually produce content near its width, or the loop above proves nothing.
wide="$(printf '%s\n' "$PLAIN" | render_at 80 | max_visible_width)"
[ "$wide" -gt 20 ] || fail "measurement is vacuous: an 80-col render measured only $wide visible cols"
pass

echo "ALL PASS ($PASS checks)"
