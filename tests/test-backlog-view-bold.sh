#!/usr/bin/env bash
# test-backlog-view-bold.sh — hermetic, network-free test of backlog-view.sh's BACKEND-mode
# emphasis-marker handling (the backend-mode render bug; follow-on to #152/#153, which fixed the
# file-backend rich-description render). Linear descriptions are markdown and carry literal
# **bold** markers; when a **…** span is split — by an upstream desc cap (linear.sh truncates the
# rich desc at 280), backlog-view.sh's own BODY_MAX cut, or the overlong-title spill join — one
# marker is orphaned. glow then renders that lone ** as a literal '**' (often stranded on its own
# wrapped line: ~15 stray '**' lines when listing the live Linear HERD backlog). rich_to_md must
# now neutralize every orphaned/unbalanced ** BEFORE glow while leaving legitimate, balanced bold
# intact — and must not touch the file-backend path or the id-chip + bold-title styling.
#
# Both `herd` AND `glow` are FAKED on PATH: the fake glow cats the markdown file it is given, so the
# assertions run against the exact rich_to_md shaping (the markdown handed to glow) rather than
# glamour's ANSI — deterministic, and no glow install required. The core invariant asserted is the
# one that makes the orphan impossible downstream: NO shaped line is a lone '**', and every shaped
# line carries an EVEN number of '**' (balanced) so glow can never strand a marker on a wrap.
#
# Run:  bash tests/test-backlog-view-bold.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../scripts/herd/backlog-view.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass(){ PASS=$((PASS+1)); }

BIN="$T/bin"; mkdir -p "$BIN"
LOG="$T/herd.log"

# FAKE `herd` — `backlog --rich` prints $HERD_FAKE_RICH_OUT; plain `backlog` prints $HERD_FAKE_OUT.
cat > "$BIN/herd" <<'FAKE'
#!/usr/bin/env bash
echo "herd $*" >> "$HERD_FAKE_LOG"
[ "${1:-}" = "backlog" ] || exit 0
if [ "${2:-}" = "--rich" ]; then
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

# no_lone_bold <output> — succeeds when NO line is a lone '**' AND every line has an even count of
# '**' (balanced). This is the property that makes a glow-orphaned '**' impossible.
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

TAB="$(printf '\t')"

# ── Case 1: orphaned ** from an upstream/BODY_MAX cut is neutralized; balanced bold survives ──────
# Three orphan mechanisms in one batch:
#   HERD-1 desc arrives already truncated with a dangling opening ** (linear.sh's 280-cap split a
#          **…** span upstream) AND carries a legitimate, balanced **complete** span earlier.
#   HERD-2 desc is > BODY_MAX (300) with a **…** span straddling the cut, so rich_to_md's own
#          truncation orphans the closing marker.
#   HERD-3 an overlong TITLE contains a **…** span at the word-boundary split point, so the head is
#          bolded by the template and the spill carries the other marker into the body.
P1="$T/proj"; make_project "$P1"
# HERD-2 body: ~285 chars of filler, THEN an opening ** whose closing ** lands past the 300-char
# BODY_MAX cut — so rich_to_md's own truncation severs the span and orphans the opener. (Field
# content has no real tabs — flat() upstream guarantees that.)
PAD="$(printf 'x%.0s' {1..285})"
LONGTITLE="This is a deliberately long tracker title that names the **externalized work queue** subsystem and keeps going well past the word-boundary split threshold so the spill lands in the body"
RICH="#HERD-1${TAB}started${TAB}In Progress${TAB}Alpha work${TAB}Uses a **complete** balanced span, then a **dangling opener that an upstream cap left unmatched…
#HERD-2${TAB}unstarted${TAB}Todo${TAB}Beta work${TAB}Intro ${PAD} **span opens here yet only closes well beyond the three-hundred character body cap so the cut severs it**
#HERD-3${TAB}backlog${TAB}Icebox${TAB}${LONGTITLE}${TAB}"
: > "$LOG"
out="$(run_view "$P1" HERD_FAKE_RICH_OUT="$RICH")"

grep -q "herd backlog --rich" "$LOG" || fail "viewer did not ask for the rich list"
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
pass

# ── Case 2: an item with NO bold markers is byte-for-byte unaffected (no spurious edits) ─────────
P2="$T/proj-plainbold"; make_project "$P2"
: > "$LOG"
out2="$(run_view "$P2" HERD_FAKE_RICH_OUT="#HERD-9${TAB}started${TAB}In Progress${TAB}Gamma${TAB}A plain description with no emphasis at all.")"
no_lone_bold "$out2" || fail "plain (no-bold) item somehow produced an unbalanced marker ($out2)"
grep -q '^A plain description with no emphasis at all\.$' <<<"$out2" \
  || fail "plain description body was altered ($out2)"
pass

echo "ALL PASS ($PASS checks)"
