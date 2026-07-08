#!/usr/bin/env bash
# test-backlog-view-rich.sh — hermetic, network-free test of backlog-view.sh's RICH backend
# rendering (state-grouped view). The viewer polls `herd backlog --rich`; when the backend answers
# the TSV shape ("#<id>\t<state-type>\t<state-name>\t<title>\t<desc>") the pane must render items
# GROUPED by workflow state (🚧 in progress first), with ONLY the title bold (the wall-of-orange
# fix), the id as a code chip, and the description as plain continuation text. A tab-free answer
# (backend with no rich op, or an older engine) must keep the legacy flat-bullet shape, and a CLI
# that rejects --rich outright must be retried plain.
#
# Both `herd` AND `glow` are FAKED on PATH: the fake glow cats the markdown file it is given, so
# the assertions run against the exact markdown shaping (list_to_md/rich_to_md output) rather than
# glamour's ANSI — deterministic, and no glow install required.
#
# Coverage:
#   1. rich TSV   — grouped headers with counts, started-first, chip + bold-title-only, plain
#                   top-level description paragraph (de-duplicated from a title-repeating
#                   description), long titles split at a word boundary with the spill joining
#                   the body.
#   2. plain list — tab-free `--rich` answer renders the legacy `- \`#id\` **title**` shape.
#   3. old CLI    — `backlog --rich` exiting non-zero falls back to a plain `backlog` call.
#
# Run:  bash tests/test-backlog-view-rich.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../scripts/herd/backlog-view.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass(){ PASS=$((PASS+1)); }

BIN="$T/bin"; mkdir -p "$BIN"
LOG="$T/herd.log"

# ── Portability shims (HERD-53) ───────────────────────────────────────────────────────────────────
# env -i below is deliberately hermetic, but on Git Bash that bites twice: python3 lives under AppData
# (off the fixed PATH) so backlog-view.sh's bare `python3` (rich_to_md) can't resolve, and env -i
# strips LANG/LC_* so the emoji grep assertions run byte-blind. Resolve the real python3 once (pre
# env -i, like scripts/herd/healthcheck.sh) and shim it into $BIN, and pin a UTF-8 locale (fallback C)
# in every env -i. Both are no-ops on Linux — python3 already sits on the fixed PATH and the shimmed
# output is byte-identical.
PY="$(command -v python3 || true)"
[ -n "$PY" ] && { printf '#!/usr/bin/env bash\nexec "%s" "$@"\n' "$PY" > "$BIN/python3"; chmod +x "$BIN/python3"; }
UTF8_LOCALE=C; [ "$(LC_ALL=C.UTF-8 locale charmap 2>/dev/null)" = "UTF-8" ] && UTF8_LOCALE=C.UTF-8

# FAKE `herd` — logs every call. `backlog --rich` prints $HERD_FAKE_RICH_OUT (exit 1 when
# HERD_FAKE_RICH_REJECT=1, emulating an older CLI that doesn't know the flag); plain `backlog`
# prints $HERD_FAKE_OUT.
cat > "$BIN/herd" <<'FAKE'
#!/usr/bin/env bash
echo "herd $*" >> "$HERD_FAKE_LOG"
[ "${1:-}" = "backlog" ] || exit 0
if [ "${2:-}" = "--rich" ]; then
  [ "${HERD_FAKE_RICH_REJECT:-0}" = "1" ] && { echo "unknown flag" >&2; exit 1; }
  printf '%b\n' "${HERD_FAKE_RICH_OUT:-}"
else
  printf '%s\n' "${HERD_FAKE_OUT:-}"
fi
FAKE
chmod +x "$BIN/herd"

# FAKE `glow` — cat the markdown file (the last argument), ignoring style/width flags, so the test
# asserts on the shaped markdown itself.
cat > "$BIN/glow" <<'FAKE'
#!/usr/bin/env bash
for a in "$@"; do f="$a"; done
cat "$f"
FAKE
chmod +x "$BIN/glow"

make_project() {
  local dir="$1"
  mkdir -p "$dir/.herd"
  cat > "$dir/.herd/config" <<EOF
PROJECT_ROOT="$dir"
WORKSPACE_NAME="testws"
BACKLOG_FILE="BACKLOG.md"
SCRIBE_BACKEND="linear"
EOF
}

run_view() {
  local dir="$1"; shift
  env -i LC_ALL="$UTF8_LOCALE" HOME="$HOME" PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin" TERM=xterm \
    HERD_CONFIG_FILE="$dir/.herd/config" HERD_ALLOW_FOREIGN_CWD=1 \
    HERD_FAKE_LOG="$LOG" BACKLOG_VIEW_MAX_POLLS=1 BACKLOG_VIEW_POLL_SECS=0 BACKLOG_VIEW_TTY=/dev/null "$@" \
    bash "$SCRIPT" 2>/dev/null </dev/null
}

TAB="$(printf '\t')"

# strip8 — remove OSC 8 hyperlink wrappers (HERD-49) from a captured frame so the shaping assertions
# below test the markdown chip/title shape itself, independent of the id→Linear link the linear
# backend now wraps each chip in. The link presence is asserted separately (see case 1).
strip8() { sed $'s/\033]8;;[^\033]*\033\\\\//g'; }

# ── Case 1: rich TSV → state-grouped markdown ────────────────────────────────────────────────────
# Three items: a started one (must render FIRST under 🚧 with its state name), an unstarted one
# whose description repeats its title (the repeat must be stripped from the body), and a backlog
# one with a paragraph-length title (must split: bold head + plain spill).
P1="$T/proj-rich"; make_project "$P1"
LONGTITLE="Code map for agent context: graphify the codebase so coordinators and builders start grounded instead of re-exploring the repository every session which is expensive"
RICH="#HERD-8${TAB}started${TAB}In Progress${TAB}Externalized work queue${TAB}Coordinator writes spawn intents, watcher drains them.
#HERD-12${TAB}unstarted${TAB}Todo${TAB}Backlog polish${TAB}Backlog polish. Show live status in the pane.
#HERD-36${TAB}backlog${TAB}Icebox${TAB}${LONGTITLE}${TAB}"
: > "$LOG"
out1="$(run_view "$P1" HERD_FAKE_RICH_OUT="$RICH")"; out1s="$(strip8 <<<"$out1")"
grep -q "herd backlog --rich" "$LOG" || fail "viewer did not ask for the rich list"
grep -q '## 🚧 in progress (1)' <<<"$out1s" || fail "missing in-progress group header ($out1s)"
grep -q '## 🔜 queued (2)' <<<"$out1s"      || fail "missing queued group header (unstarted+backlog merged)"
# started renders first
first_group="$(grep -n '##' <<<"$out1s" | head -n1)"
grep -q 'in progress' <<<"$first_group" || fail "in-progress group must render before queued ($first_group)"
# chip + bold TITLE ONLY + italic state name; description is a plain top-level paragraph line, never bold
grep -q -- '- `#HERD-8` \*\*Externalized work queue\*\* _(In Progress)_' <<<"$out1s" \
  || fail "in-progress item shape wrong (chip/bold-title/state) ($out1s)"
grep -q '^Coordinator writes spawn intents, watcher drains them\.$' <<<"$out1s" \
  || fail "description must be a plain top-level paragraph (unindented: glamour glues an indented continuation onto the item)"
# title-repeating description is de-duplicated out of the body
grep -q '^Show live status in the pane\.$' <<<"$out1s" \
  || fail "body must strip the description's leading title repetition"
# paragraph-length title: bold head caps at a word boundary, spill continues as plain body
grep -q -- '- `#HERD-36` \*\*Code map for agent context: graphify the codebase so coordinators and builders start grounded instead of\*\*' <<<"$out1s" \
  || fail "long title was not split at a word boundary into a bold head ($out1s)"
grep -q '^re-exploring the repository every session which is expensive$' <<<"$out1s" \
  || fail "long-title spill must continue as plain body text"
# HERD-49: each chip is wrapped in an OSC 8 hyperlink to the issue in Linear (raw frame, pre-strip).
grep -q $'\033]8;;https://linear.app/testws/issue/HERD-8\033\\\\#HERD-8\033]8;;\033\\\\' <<<"$out1" \
  || fail "chip #HERD-8 is not wrapped in an OSC 8 hyperlink to Linear ($out1)"
grep -q 'https://linear.app/testws/issue/HERD-36' <<<"$out1" \
  || fail "long-title chip #HERD-36 missing its OSC 8 Linear hyperlink"
pass

# ── Case 2: tab-free answer under --rich → legacy flat-bullet shape (backward compat) ────────────
P2="$T/proj-plain"; make_project "$P2"
: > "$LOG"
out2="$(run_view "$P2" HERD_FAKE_RICH_OUT='#ABC-1 alpha ticket')"; out2s="$(strip8 <<<"$out2")"
grep -q -- '- `#ABC-1` \*\*alpha ticket\*\*' <<<"$out2s" || fail "plain shape must keep the legacy bullet form ($out2s)"
grep -q '##' <<<"$out2s" && fail "plain shape must not invent group headers"
grep -q 'https://linear.app/testws/issue/ABC-1' <<<"$out2" || fail "plain-shape chip #ABC-1 missing its OSC 8 Linear hyperlink"
pass

# ── Case 3: older CLI rejects --rich → retried as plain `herd backlog`, still renders ────────────
P3="$T/proj-old"; make_project "$P3"
: > "$LOG"
out3="$(run_view "$P3" HERD_FAKE_RICH_REJECT=1 HERD_FAKE_OUT='#OLD-1 legacy item')"; out3s="$(strip8 <<<"$out3")"
grep -q "herd backlog --rich" "$LOG" || fail "old-CLI case: rich attempt missing from the call log"
grep -q "^herd backlog$" "$LOG"      || fail "old-CLI case: plain retry missing from the call log"
grep -q -- '- `#OLD-1` \*\*legacy item\*\*' <<<"$out3s" || fail "old-CLI case did not render the plain list ($out3s)"
pass

# ── Case 4: assignee rendering ─────────────────────────────────────────────────────────────────────
# started item with assignee  → '_(In Progress · Chase)_' state suffix
# unstarted item with assignee → '@Name' between the chip and the bold title
# unassigned item             → no @-name anywhere on that item's line
P4="$T/proj-assignee"; make_project "$P4"
RICH4="#HERD-1${TAB}started${TAB}In Progress${TAB}Do the thing${TAB}Body text${TAB}Chase
#HERD-2${TAB}unstarted${TAB}Todo${TAB}Other task${TAB}${TAB}Jordan
#HERD-3${TAB}unstarted${TAB}Todo${TAB}Free task${TAB}${TAB}"
: > "$LOG"
out4="$(run_view "$P4" HERD_FAKE_RICH_OUT="$RICH4")"; out4s="$(strip8 <<<"$out4")"
grep -q -- '- `#HERD-1` \*\*Do the thing\*\* _(In Progress · Chase)_' <<<"$out4s" \
  || fail "started item with assignee must render '_(In Progress · Chase)_' ($out4s)"
grep -q -- '- `#HERD-2` @Jordan \*\*Other task\*\*' <<<"$out4s" \
  || fail "unstarted item with assignee must render '@Name' between chip and bold title ($out4s)"
grep -q -- '- `#HERD-3` \*\*Free task\*\*' <<<"$out4s" \
  || fail "unassigned unstarted item must have no @-name ($out4s)"
! grep -q '@' <<<"$(grep '#HERD-3' <<<"$out4s")" \
  || fail "unassigned item must not emit any @-name on its line"
pass

# ── Case 5: OSC 8 chip hyperlink from the rich TSV's 7th <url> field (HERD-49) ───────────────────
# A rich line carrying a url makes the id chip a clickable OSC 8 hyperlink (ESC ]8;;URL ST … ST)
# WRAPPED INSIDE the code-chip backticks, so glow's chip styling is untouched and the sequence is
# ignored by terminals without OSC 8 support. A line with NO url field stays a plain unlinked chip
# (fail-soft). The fake glow cats the shaped markdown, so we assert on the injected escape directly.
P5="$T/proj-link"; make_project "$P5"
ESC="$(printf '\033')"
RICH5="#HERD-49${TAB}started${TAB}In Progress${TAB}Clickable ids${TAB}${TAB}${TAB}https://linear.app/acme/issue/HERD-49
#HERD-50${TAB}unstarted${TAB}Todo${TAB}No url item${TAB}${TAB}${TAB}"
: > "$LOG"
out5="$(run_view "$P5" HERD_FAKE_RICH_OUT="$RICH5")"
# The chip identifier is wrapped in an OSC 8 open (…]8;;<url>ST) + close (…]8;;ST), still inside `…`.
grep -q -- "\`${ESC}]8;;https://linear.app/acme/issue/HERD-49${ESC}\\\\#HERD-49${ESC}]8;;${ESC}\\\\\`" <<<"$out5" \
  || fail "rich item with a url did not wrap the chip in an OSC 8 hyperlink ($(cat -v <<<"$out5"))"
# Styling untouched: the bold title still renders as its own markdown next to the linked chip.
grep -q -- '\*\*Clickable ids\*\*' <<<"$out5" || fail "OSC 8 wrapping disturbed the bold title ($out5)"
# The url-less item keeps a plain, un-escaped chip.
grep -q -- '- `#HERD-50` \*\*No url item\*\*' <<<"$out5" \
  || fail "url-less rich item must keep a plain unlinked chip ($(cat -v <<<"$out5"))"
pass

echo "ALL PASS ($PASS checks)"
