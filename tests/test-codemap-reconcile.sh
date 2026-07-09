#!/usr/bin/env bash
# test-codemap-reconcile.sh — hermetic tests for the TICK-LEVEL codemap/symbol-index freshness
# reconcile (reconcile_map_freshness in agent-watch.sh, HERD-218).
#
# Multi-seat doctrine: map freshness is a RECONCILED INVARIANT, not a do_merge side-effect. When an
# out-of-band merge leaves the committed maps stale (do_merge never ran on THIS seat), the next
# watcher tick must repair them exactly once. When maps are already fresh, the tick commits nothing.
#
#   (1) OFF (CODEMAP_AUTOREFRESH=false) is BYTE-INERT: no pull probe, no commit, no journal line
#   (2) OUT-OF-BAND STALE (maps drifted, do_merge NOT invoked) → exactly ONE reconcile refresh
#       commits both maps, journals codemap_refresh / symbol_index_refresh with provenance=reconcile
#   (3) FRESH tree (already matching) → zero commits, zero reconcile journal lines
#   (4) SECOND TICK after a reconcile repair → still zero commits (memo / fresh; no double-commit)
#   (5) MID-OP (live review inflight marker) → defer: no commit, no journal
#
# Sources agent-watch.sh in lib mode and drives reconcile_map_freshness directly against a REAL local
# git repo wired to a bare "origin". codemap.sh / symbol-index.sh are stubbed via $HERE so the test
# controls exactly what --check and regen produce. journal_append is overridden to a log.
# Run:  bash tests/test-codemap-reconcile.sh
set -uo pipefail
HERE_T="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE_T/../scripts/herd/agent-watch.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

[ -f "$WATCH" ] || fail "agent-watch.sh not found at $WATCH"
command -v git >/dev/null 2>&1 || fail "git required to run this test"

# ── Stub gh / herdr on PATH (network-free); git stays REAL ────────────────────────────────────────
BIN="$T/bin"; mkdir -p "$BIN"
for cmd in gh herdr; do printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$cmd"; chmod +x "$BIN/$cmd"; done
export PATH="$BIN:$PATH"

# ── Source agent-watch.sh in lib mode ─────────────────────────────────────────────────────────────
export AGENT_WATCH_LIB=1
export WORKTREES_DIR="$T/trees"; mkdir -p "$T/trees"
export HERD_CONFIG_FILE="$T/no-such-config"
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"
type reconcile_map_freshness >/dev/null 2>&1 || fail "reconcile_map_freshness not defined"
type refresh_codemap         >/dev/null 2>&1 || fail "refresh_codemap not defined"
type refresh_symbol_index    >/dev/null 2>&1 || fail "refresh_symbol_index not defined"
type _map_reconcile_mid_op   >/dev/null 2>&1 || fail "_map_reconcile_mid_op not defined"

# Override journal_append to a log so every outcome is inspectable.
JLOG="$T/journal.log"; : > "$JLOG"
journal_append() { printf '%s\n' "$*" >> "$JLOG"; }

# Stub dir: codemap.sh + symbol-index.sh honour --check (cmp STUB_* vs the committed file) and
# refresh (write STUB_* to the out path). This is the exact seam reconcile_map_freshness drives.
STUBHERD="$T/herd-stub"; mkdir -p "$STUBHERD"
cat > "$STUBHERD/codemap.sh" <<'STUB'
#!/usr/bin/env bash
set -u
want="${STUB_MAP:-MAP v1}"
out="${HERD_CODEMAP_OUT:?}"
case "${1:-}" in
  --check)
    if [ -f "$out" ] && [ "$(cat "$out")" = "$want" ]; then
      printf 'docs/codemap.md — fresh\n'; exit 0
    fi
    printf 'docs/codemap.md — STALE\n' >&2; exit 1
    ;;
  "")
    printf '%s\n' "$want" > "$out"; exit 0
    ;;
  *) printf 'codemap.sh stub: unknown arg %s\n' "${1:-}" >&2; exit 2 ;;
esac
STUB
cat > "$STUBHERD/symbol-index.sh" <<'STUB'
#!/usr/bin/env bash
set -u
want="${STUB_INDEX:-INDEX v1}"
out="${HERD_SYMBOL_INDEX_OUT:?}"
case "${1:-}" in
  --check)
    if [ -f "$out" ] && [ "$(cat "$out")" = "$want" ]; then
      printf 'docs/symbol-index.md — fresh\n'; exit 0
    fi
    printf 'docs/symbol-index.md — STALE\n' >&2; exit 1
    ;;
  "")
    printf '%s\n' "$want" > "$out"; exit 0
    ;;
  *) printf 'symbol-index.sh stub: unknown arg %s\n' "${1:-}" >&2; exit 2 ;;
esac
STUB
chmod +x "$STUBHERD/codemap.sh" "$STUBHERD/symbol-index.sh"
HERE="$STUBHERD"
export STUB_MAP STUB_INDEX

# ── Real git repo wired to a bare origin ──────────────────────────────────────────────────────────
ORIGIN="$T/origin.git"; git init -q --bare "$ORIGIN"
MAIN="$T/main"; git clone -q "$ORIGIN" "$MAIN" 2>/dev/null
git -C "$MAIN" checkout -q -B main
git -C "$MAIN" config user.email t@t.test; git -C "$MAIN" config user.name tester
mkdir -p "$MAIN/docs"
printf 'MAP v1\n'   > "$MAIN/docs/codemap.md"
printf 'INDEX v1\n' > "$MAIN/docs/symbol-index.md"
git -C "$MAIN" add docs/codemap.md docs/symbol-index.md
git -C "$MAIN" commit -q -m init
git -C "$MAIN" push -q origin main
HERD_REMOTE=origin; HERD_BRANCH_NAME=main; DEFAULT_BRANCH=origin/main
# TREES is already set from WORKTREES_DIR by agent-watch.sh; ensure it exists for the memo file.
mkdir -p "$TREES"

commits() { git -C "$MAIN" rev-list --count HEAD; }
jhas()    { grep -q "$1" "$JLOG"; }
jcount()  { grep -c "$1" "$JLOG" 2>/dev/null || printf '0'; }
clear_memo() { rm -f "$TREES/.codemap-reconcile-sha"; }

# ── (1) OFF = byte-inert ──────────────────────────────────────────────────────────────────────────
: > "$JLOG"; clear_memo
STUB_MAP="MAP v2"; STUB_INDEX="INDEX v2"   # would be stale if probed
c0="$(commits)"
CODEMAP_AUTOREFRESH=false reconcile_map_freshness
[ "$(commits)" = "$c0" ]            || fail "(1) OFF created a commit — must be inert"
[ "$(cat "$MAIN/docs/codemap.md")" = "MAP v1" ] \
                                    || fail "(1) OFF touched codemap — must be inert"
[ ! -s "$JLOG" ]                    || fail "(1) OFF journaled something — must be silent: $(cat "$JLOG")"
[ ! -f "$TREES/.codemap-reconcile-sha" ] \
                                    || fail "(1) OFF wrote a reconcile memo — must be inert"
ok

# ── (2) OUT-OF-BAND STALE → exactly ONE reconcile refresh (do_merge NOT run) ──────────────────────
# Simulate another seat's merge: source tree "changed" (stub regen produces v2) but the committed
# maps still say v1. do_merge is never called; only reconcile_map_freshness runs.
: > "$JLOG"; clear_memo
STUB_MAP="MAP v2"; STUB_INDEX="INDEX v2"
c0="$(commits)"
CODEMAP_AUTOREFRESH=true reconcile_map_freshness
[ "$(commits)" = "$((c0 + 2))" ]    || fail "(2) expected exactly two new commits (codemap + symbol-index); got $(commits) from $c0"
[ "$(cat "$MAIN/docs/codemap.md")" = "MAP v2" ] \
                                    || fail "(2) codemap not refreshed to MAP v2"
[ "$(cat "$MAIN/docs/symbol-index.md")" = "INDEX v2" ] \
                                    || fail "(2) symbol-index not refreshed to INDEX v2"
# Commit messages use the reconcile shape (no PR #).
git -C "$MAIN" log -2 --format=%s | grep -q 'chore: refresh codemap (reconcile)' \
                                    || fail "(2) codemap commit message wrong: $(git -C "$MAIN" log -2 --format=%s)"
git -C "$MAIN" log -2 --format=%s | grep -q 'chore: refresh symbol-index (reconcile)' \
                                    || fail "(2) symbol-index commit message wrong: $(git -C "$MAIN" log -2 --format=%s)"
# Journaled with provenance=reconcile (the multi-seat audit trail).
jhas 'codemap_refresh pr  result committed pushed yes provenance reconcile' \
                                    || fail "(2) codemap journal missing provenance=reconcile: $(cat "$JLOG")"
jhas 'symbol_index_refresh pr  result committed pushed yes provenance reconcile' \
                                    || fail "(2) symbol-index journal missing provenance=reconcile: $(cat "$JLOG")"
# Exactly one codemap_refresh + one symbol_index_refresh committed line (no double-fire).
[ "$(jcount 'codemap_refresh')" = "1" ] \
                                    || fail "(2) expected exactly 1 codemap_refresh journal line, got $(jcount 'codemap_refresh')"
[ "$(jcount 'symbol_index_refresh')" = "1" ] \
                                    || fail "(2) expected exactly 1 symbol_index_refresh journal line, got $(jcount 'symbol_index_refresh')"
# Pushed ff-safe.
[ "$(git -C "$MAIN" rev-parse HEAD)" = "$(git -C "$MAIN" rev-parse origin/main)" ] \
                                    || fail "(2) reconcile commits were not pushed to origin"
ok

# ── (3) FRESH tree → zero commits ─────────────────────────────────────────────────────────────────
# Maps already match the stub regen; a new main-sha advance (empty commit simulating an out-of-band
# merge that did not drift the maps) must NOT produce a refresh commit.
: > "$JLOG"; clear_memo
STUB_MAP="MAP v2"; STUB_INDEX="INDEX v2"   # matches the committed maps from (2)
# Advance HEAD so the sha-memo does not short-circuit before the --check probe.
printf 'oob\n' > "$MAIN/docs/note.txt"
git -C "$MAIN" add docs/note.txt; git -C "$MAIN" commit -q -m "oob merge (maps still fresh)"
git -C "$MAIN" push -q origin main
c0="$(commits)"
CODEMAP_AUTOREFRESH=true reconcile_map_freshness
[ "$(commits)" = "$c0" ]            || fail "(3) FRESH created a commit — must not"
# No committed/pushed journal lines (fresh probe may journal nothing at the reconcile layer).
jhas 'result committed'             && fail "(3) FRESH journaled a commit: $(cat "$JLOG")"
jhas 'provenance reconcile'         && fail "(3) FRESH journaled provenance=reconcile: $(cat "$JLOG")"
ok

# ── (4) SECOND TICK after repair → still zero (no double-commit) ──────────────────────────────────
: > "$JLOG"
c0="$(commits)"
CODEMAP_AUTOREFRESH=true reconcile_map_freshness
[ "$(commits)" = "$c0" ]            || fail "(4) second tick created a commit — double-commit"
[ ! -s "$JLOG" ]                    || fail "(4) second tick journaled something (memo should short-circuit): $(cat "$JLOG")"
ok

# ── (5) MID-OP (live review inflight) → defer, no commit ──────────────────────────────────────────
: > "$JLOG"; clear_memo
# Make maps stale again so a non-deferred tick WOULD commit.
STUB_MAP="MAP v3"; STUB_INDEX="INDEX v3"
# Advance HEAD so the memo does not short-circuit.
printf 'mid\n' >> "$MAIN/docs/note.txt"
git -C "$MAIN" add docs/note.txt; git -C "$MAIN" commit -q -m "advance for mid-op"
git -C "$MAIN" push -q origin main
# Plant a LIVE inflight marker for the current shell pid (kill -0 succeeds; starttime matches).
INF="$TREES/.review-inflight-99-shaMID"
_marker_write "$INF" "$$"
c0="$(commits)"
CODEMAP_AUTOREFRESH=true reconcile_map_freshness
[ "$(commits)" = "$c0" ]            || fail "(5) MID-OP created a commit — must defer"
[ ! -s "$JLOG" ]                    || fail "(5) MID-OP journaled something — must defer silently: $(cat "$JLOG")"
[ "$(cat "$MAIN/docs/codemap.md")" = "MAP v2" ] \
                                    || fail "(5) MID-OP mutated codemap — must leave untouched"
rm -f "$INF"
ok

# ── Bonus: after mid-op clears, the deferred stale maps DO heal on the next tick ──────────────────
: > "$JLOG"; clear_memo
c0="$(commits)"
CODEMAP_AUTOREFRESH=true reconcile_map_freshness
[ "$(commits)" = "$((c0 + 2))" ]    || fail "(5b) post-mid-op expected 2 commits; got $(commits) from $c0"
[ "$(cat "$MAIN/docs/codemap.md")" = "MAP v3" ] \
                                    || fail "(5b) post-mid-op codemap not healed"
jhas 'provenance reconcile'         || fail "(5b) post-mid-op missing provenance=reconcile: $(cat "$JLOG")"
ok

echo "PASS: test-codemap-reconcile.sh ($pass checks)"
