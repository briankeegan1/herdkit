#!/usr/bin/env bash
# test-backlog-view-bold.sh — deterministic, TTY-independent test of backlog-view.sh's BACKEND-mode
# emphasis-marker handling (the backend-mode render bug; follow-on to #152/#153, which fixed the
# file-backend rich-description render).
#
# WHY THE --emit-md SEAM: the live viewer paints via glow DIRECTLY to the pane TTY, so scraping the
# viewer's stdout is not portable — on a non-TTY capture (CI, Windows/Git-bash) the shaped item
# markdown never reaches stdout and only the pane header survives. Instead we drive
# `backlog-view.sh --emit-md`, the one-shot seam that reads a `herd backlog --rich` list on STDIN and
# writes the EXACT markdown the pane hands to glow (shape_md) to STDOUT — no glow, no TTY, no live
# backend, no project config. PYTHONUTF8=1 pins python's stdout to UTF-8 so the emoji group headers
# render identically regardless of the box's default encoding (Windows Python defaults to cp1252).
#
# Linear descriptions are markdown carrying literal **bold** markers; a **…** span gets split by an
# upstream desc cap (linear.sh truncates the rich desc at 280), backlog-view.sh's own BODY_MAX cut,
# or the overlong-title spill join — orphaning one marker. glow then renders that lone ** as a
# literal '**' (often stranded on its own wrapped line: ~15 stray '**' lines when listing the live
# Linear HERD backlog). rich_to_md must neutralize every orphaned/unbalanced ** while leaving
# legitimate, balanced bold intact. The invariant asserted: NO shaped line is a lone '**' and every
# line carries an EVEN number of '**' (balanced), so glow can never strand a marker on a wrap.
#
# Run:  bash tests/test-backlog-view-bold.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../scripts/herd/backlog-view.sh"

PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass(){ PASS=$((PASS+1)); }

TAB="$(printf '\t')"

# shape <rich-or-plain-list> — the shaped markdown handed to glow, straight to stdout (see header).
shape(){ printf '%s\n' "$1" | PYTHONUTF8=1 bash "$SCRIPT" --emit-md; }

# no_lone_bold <output> — succeeds when NO line is a lone '**' AND every line has an even count of
# '**' (balanced). This is exactly the property that makes a glow-orphaned '**' impossible.
no_lone_bold() {
  printf '%s\n' "$1" | awk '
    { line=$0
      # a line that is nothing but ** (optionally indented) is the classic orphan
      if (line ~ /^[[:space:]]*\*\*[[:space:]]*$/) { print "lone ** line: [" $0 "]"; bad=1 }
      n=gsub(/\*\*/, "**", line)
      if (n % 2 != 0) { print "unbalanced ** ("n") on: [" $0 "]"; bad=1 }
    }
    END { exit bad ? 1 : 0 }'
}

# ── Case 1: orphaned ** (three ways) is neutralized; balanced bold survives ───────────────────────
#   HERD-1 desc arrives already truncated with a dangling opening ** (linear.sh's 280-cap split a
#          **…** span upstream) AND carries a legitimate, balanced **complete** span earlier.
#   HERD-2 desc is > BODY_MAX (300) with a **…** span straddling the cut, so rich_to_md's own
#          truncation orphans the opener.
#   HERD-3 an overlong TITLE contains a **…** span; the head is bolded by the template (so its **
#          markers must be stripped) and the spill carries the rest into the body.
PAD="$(printf 'x%.0s' {1..285})"
LONGTITLE="This is a deliberately long tracker title that names the **externalized work queue** subsystem and keeps going well past the word-boundary split threshold so the spill lands in the body"
RICH="#HERD-1${TAB}started${TAB}In Progress${TAB}Alpha work${TAB}Uses a **complete** balanced span, then a **dangling opener that an upstream cap left unmatched…
#HERD-2${TAB}unstarted${TAB}Todo${TAB}Beta work${TAB}Intro ${PAD} **span opens here yet only closes well beyond the three-hundred character body cap so the cut severs it**
#HERD-3${TAB}backlog${TAB}Icebox${TAB}${LONGTITLE}${TAB}"
out="$(shape "$RICH")"

[ -n "$out" ] || fail "--emit-md produced no shaped markdown"
# THE core assertion: no orphaned / lone / unbalanced ** anywhere in the shaped markdown.
no_lone_bold "$out" || fail "shaped output orphaned an emphasis marker:
$(no_lone_bold "$out" 2>&1)
--- full output ---
$out"
# Legitimate, balanced bold must STILL render (we only strip the orphan, never all bold).
grep -q -- '\*\*complete\*\*' <<<"$out" || fail "balanced legitimate bold was lost ($out)"
# The loved id-chip + bold-title styling is preserved for every item.
grep -q -- '- `#HERD-1` \*\*Alpha work\*\* _(In Progress)_' <<<"$out" \
  || fail "chip + bold-title + state styling regressed ($out)"
grep -q -- '- `#HERD-3` \*\*This is a deliberately long tracker title' <<<"$out" \
  || fail "overlong-title head lost its chip/bold styling ($out)"
# Grouped headers still shape correctly (the shaping seam mirrors the live pane exactly). Match the
# ASCII portion only — a literal-emoji grep is not portable (Git-bash grep won't match the multibyte
# 🚧 against UTF-8 output); the emoji itself is covered by test-backlog-view-rich.sh.
grep -q '## .* in progress (1)$' <<<"$out" || fail "missing in-progress group header ($out)"
pass

# ── Case 2: an item with NO bold markers is left unaltered (no spurious edits) ────────────────────
out2="$(shape "#HERD-9${TAB}started${TAB}In Progress${TAB}Gamma${TAB}A plain description with no emphasis at all.")"
no_lone_bold "$out2" || fail "plain (no-bold) item somehow produced an unbalanced marker ($out2)"
grep -q '^A plain description with no emphasis at all\.$' <<<"$out2" \
  || fail "plain description body was altered ($out2)"
pass

# ── Case 3: a plain (tab-free) list still shapes to the legacy flat-bullet form ───────────────────
out3="$(shape '#ABC-1 alpha ticket')"
grep -q -- '- `#ABC-1` \*\*alpha ticket\*\*' <<<"$out3" || fail "plain list lost the legacy bullet shape ($out3)"
no_lone_bold "$out3" || fail "plain list produced an unbalanced marker ($out3)"
pass

echo "ALL PASS ($PASS checks)"
