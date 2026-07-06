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
  env -i HOME="$HOME" PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin" TERM=xterm \
    HERD_CONFIG_FILE="$dir/.herd/config" HERD_ALLOW_FOREIGN_CWD=1 \
    HERD_FAKE_LOG="$LOG" BACKLOG_VIEW_MAX_POLLS=1 BACKLOG_VIEW_POLL_SECS=0 "$@" \
    bash "$SCRIPT" 2>/dev/null </dev/null
}

TAB="$(printf '\t')"

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
out1="$(run_view "$P1" HERD_FAKE_RICH_OUT="$RICH")"
grep -q "herd backlog --rich" "$LOG" || fail "viewer did not ask for the rich list"
grep -q '## 🚧 in progress (1)' <<<"$out1" || fail "missing in-progress group header ($out1)"
grep -q '## 🔜 queued (2)' <<<"$out1"      || fail "missing queued group header (unstarted+backlog merged)"
# started renders first
first_group="$(grep -n '##' <<<"$out1" | head -n1)"
grep -q 'in progress' <<<"$first_group" || fail "in-progress group must render before queued ($first_group)"
# chip + bold TITLE ONLY + italic state name; description is a plain top-level paragraph line, never bold
grep -q -- '- `#HERD-8` \*\*Externalized work queue\*\* _(In Progress)_' <<<"$out1" \
  || fail "in-progress item shape wrong (chip/bold-title/state) ($out1)"
grep -q '^Coordinator writes spawn intents, watcher drains them\.$' <<<"$out1" \
  || fail "description must be a plain top-level paragraph (unindented: glamour glues an indented continuation onto the item)"
# title-repeating description is de-duplicated out of the body
grep -q '^Show live status in the pane\.$' <<<"$out1" \
  || fail "body must strip the description's leading title repetition"
# paragraph-length title: bold head caps at a word boundary, spill continues as plain body
grep -q -- '- `#HERD-36` \*\*Code map for agent context: graphify the codebase so coordinators and builders start grounded instead of\*\*' <<<"$out1" \
  || fail "long title was not split at a word boundary into a bold head ($out1)"
grep -q '^re-exploring the repository every session which is expensive$' <<<"$out1" \
  || fail "long-title spill must continue as plain body text"
pass

# ── Case 2: tab-free answer under --rich → legacy flat-bullet shape (backward compat) ────────────
P2="$T/proj-plain"; make_project "$P2"
: > "$LOG"
out2="$(run_view "$P2" HERD_FAKE_RICH_OUT='#ABC-1 alpha ticket')"
grep -q -- '- `#ABC-1` \*\*alpha ticket\*\*' <<<"$out2" || fail "plain shape must keep the legacy bullet form ($out2)"
grep -q '##' <<<"$out2" && fail "plain shape must not invent group headers"
pass

# ── Case 3: older CLI rejects --rich → retried as plain `herd backlog`, still renders ────────────
P3="$T/proj-old"; make_project "$P3"
: > "$LOG"
out3="$(run_view "$P3" HERD_FAKE_RICH_REJECT=1 HERD_FAKE_OUT='#OLD-1 legacy item')"
grep -q "herd backlog --rich" "$LOG" || fail "old-CLI case: rich attempt missing from the call log"
grep -q "^herd backlog$" "$LOG"      || fail "old-CLI case: plain retry missing from the call log"
grep -q -- '- `#OLD-1` \*\*legacy item\*\*' <<<"$out3" || fail "old-CLI case did not render the plain list ($out3)"
pass

echo "ALL PASS ($PASS checks)"
