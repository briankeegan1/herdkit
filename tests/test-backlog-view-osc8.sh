#!/usr/bin/env bash
# test-backlog-view-osc8.sh — hermetic, network-free test of backlog-view.sh's OSC 8 hyperlink
# injection (HERD-49): each #KEY-NN id chip in the LINEAR-backend backlog pane is wrapped in an
# OSC 8 terminal hyperlink (ESC ]8;;URL ST  #KEY-NN  ESC ]8;; ST) pointing at the issue in Linear,
# WITHOUT changing the chip's themed styling (SGR color and OSC 8 are orthogonal). glow does not emit
# OSC 8 but passes raw escapes through, so the wrap is injected into the SHAPED markdown before glow.
#
# Both `herd` and `glow` are FAKED on PATH: the fake glow cats the markdown file it is handed, so the
# assertions run against the exact bytes handed to glow (post-osc8_linkify) — deterministic, no glow
# install and no terminal required.
#
# Coverage:
#   1. linear backend, slug derived from WORKSPACE_NAME → chip wrapped, styling markdown intact.
#   2. LINEAR_WORKSPACE_SLUG override → the override wins over the derived slug.
#   3. a numeric id (#42) is NEVER linkified (only the tracker id shape #KEY-NN matches).
#   4. non-linear backend (github) → NO link base → pure passthrough (no OSC 8 anywhere).
#
# Run:  bash tests/test-backlog-view-osc8.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../scripts/herd/backlog-view.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass(){ PASS=$((PASS+1)); }

BIN="$T/bin"; mkdir -p "$BIN"
LOG="$T/herd.log"

# Portability shims (mirror test-backlog-view-rich.sh): shim the real python3 onto the hermetic PATH
# and pin a UTF-8 locale so emoji/byte assertions are stable under `env -i`.
PY="$(command -v python3 || true)"
[ -n "$PY" ] && { printf '#!/usr/bin/env bash\nexec "%s" "$@"\n' "$PY" > "$BIN/python3"; chmod +x "$BIN/python3"; }
UTF8_LOCALE=C; [ "$(LC_ALL=C.UTF-8 locale charmap 2>/dev/null)" = "UTF-8" ] && UTF8_LOCALE=C.UTF-8

# FAKE `herd` — `backlog --rich` prints $HERD_FAKE_RICH_OUT; plain `backlog` prints $HERD_FAKE_OUT.
cat > "$BIN/herd" <<'FAKE'
#!/usr/bin/env bash
echo "herd $*" >> "$HERD_FAKE_LOG"
[ "${1:-}" = "backlog" ] || exit 0
if [ "${2:-}" = "--rich" ]; then printf '%b\n' "${HERD_FAKE_RICH_OUT:-}"; else printf '%s\n' "${HERD_FAKE_OUT:-}"; fi
FAKE
chmod +x "$BIN/herd"

# FAKE `glow` — cat the markdown file (last arg) so the test asserts on the exact bytes glow receives.
cat > "$BIN/glow" <<'FAKE'
#!/usr/bin/env bash
for a in "$@"; do f="$a"; done
cat "$f"
FAKE
chmod +x "$BIN/glow"

make_project() {
  local dir="$1" backend="$2"
  mkdir -p "$dir/.herd"
  cat > "$dir/.herd/config" <<EOF
PROJECT_ROOT="$dir"
WORKSPACE_NAME="testws"
BACKLOG_FILE="BACKLOG.md"
SCRIBE_BACKEND="$backend"
EOF
}

run_view() {
  local dir="$1"; shift
  env -i LC_ALL="$UTF8_LOCALE" HOME="$HOME" PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin" TERM=xterm \
    HERD_CONFIG_FILE="$dir/.herd/config" HERD_ALLOW_FOREIGN_CWD=1 \
    HERD_FAKE_LOG="$LOG" BACKLOG_VIEW_MAX_POLLS=1 BACKLOG_VIEW_POLL_SECS=0 BACKLOG_VIEW_TTY=/dev/null "$@" \
    bash "$SCRIPT" 2>/dev/null </dev/null
}

# OSC 8 wrapper bytes for a given slug + identifier: ESC ]8;;URL ST  #IDENT  ESC ]8;; ST
osc8() { printf '\033]8;;https://linear.app/%s/issue/%s\033\\#%s\033]8;;\033\\' "$1" "$2" "$2"; }

# ── Case 1: linear backend, slug derived from WORKSPACE_NAME ──────────────────────────────────────
P1="$T/p1"; make_project "$P1" linear
: > "$LOG"
out1="$(run_view "$P1" HERD_FAKE_RICH_OUT='#HERD-49 make chips clickable')"
grep -qF "$(osc8 testws HERD-49)" <<<"$out1" \
  || fail "chip #HERD-49 not wrapped in an OSC 8 Linear hyperlink (slug from WORKSPACE_NAME) ($out1)"
# themed shaping is preserved exactly: the chip code span + bold title are still there once the OSC 8
# wrapper is stripped away (SGR/markdown untouched — orthogonal to the hyperlink).
strip8() { sed $'s/\033]8;;[^\033]*\033\\\\//g'; }
grep -q -- '- `#HERD-49` \*\*make chips clickable\*\*' <<<"$(strip8 <<<"$out1")" \
  || fail "chip/title markdown was altered by the OSC 8 wrap (should be orthogonal) ($out1)"
pass

# ── Case 2: LINEAR_WORKSPACE_SLUG override wins over the derived slug ──────────────────────────────
P2="$T/p2"; make_project "$P2" linear
: > "$LOG"
out2="$(run_view "$P2" LINEAR_WORKSPACE_SLUG=acme-corp HERD_FAKE_RICH_OUT='#ENG-7 override slug')"
grep -qF "$(osc8 acme-corp ENG-7)" <<<"$out2" \
  || fail "LINEAR_WORKSPACE_SLUG override did not set the hyperlink workspace slug ($out2)"
grep -q 'linear.app/testws' <<<"$out2" && fail "override case still used the derived 'testws' slug"
pass

# ── Case 3: a numeric id (#42) is NEVER linkified (only #KEY-NN matches) ──────────────────────────
P3="$T/p3"; make_project "$P3" linear
: > "$LOG"
out3="$(run_view "$P3" HERD_FAKE_RICH_OUT='#42 numeric id item')"
grep -q ']8;;' <<<"$(printf '%s' "$out3" | cat -v)" \
  && fail "a numeric '#42' id must not be wrapped in an OSC 8 hyperlink"
grep -q 'numeric id item' <<<"$out3" || fail "numeric-id item did not render"
pass

# ── Case 4: non-linear backend (github) → no link base → pure passthrough (no OSC 8) ──────────────
P4="$T/p4"; make_project "$P4" github
: > "$LOG"
out4="$(run_view "$P4" HERD_FAKE_RICH_OUT='#HERD-9 no link on non-linear backend')"
grep -q ']8;;' <<<"$(printf '%s' "$out4" | cat -v)" \
  && fail "non-linear backend must not emit any OSC 8 hyperlink (passthrough only)"
grep -q 'no link on non-linear backend' <<<"$out4" || fail "github-backend item did not render"
pass

echo "ALL PASS ($PASS checks)"
