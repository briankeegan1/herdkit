#!/usr/bin/env bash
# test-symbol-index-autorefresh.sh — hermetic tests for the POST-MERGE symbol-index freshness hook
# (refresh_symbol_index in agent-watch.sh, HERD-71). The function-level twin of the codemap hook,
# so this mirrors test-codemap-autorefresh.sh case-for-case:
#
#   (1) OFF (CODEMAP_AUTOREFRESH=false) is BYTE-INERT: the scan never runs, the tree is untouched,
#       and the event journals result=skipped reason=disabled
#   (2) CHANGED CONTENT: the deterministic regen differs from the committed index → commit STRAIGHT
#       to the default branch (message "chore: refresh symbol-index after PR #N"), scoped to
#       docs/symbol-index.md, pushed ff-safe; journals result=committed pushed=yes
#   (3) FRESH: the regen matches the committed index → NO commit, tree clean; journals result=fresh
#   (4) DIRTY PATH: docs/symbol-index.md already carries an uncommitted change → skip untouched;
#       journals result=skipped reason=dirty-path
#   (5) NOT ADOPTED: no committed docs/symbol-index.md → skip, never materialize one; result=skipped no-index
#
# Sources agent-watch.sh in lib mode (AGENT_WATCH_LIB=1) and drives refresh_symbol_index directly
# against a REAL local git repo wired to a bare "origin". symbol-index.sh is stubbed via an overridden
# $HERE so the test controls exactly what a "regen" produces, and journal_append is overridden to a log.
# Run:  bash tests/test-symbol-index-autorefresh.sh
# No `set -e`: some checks assert non-zero returns / skip paths explicitly.
set -uo pipefail
HERE_T="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE_T/../scripts/herd/agent-watch.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

[ -f "$WATCH" ] || fail "agent-watch.sh not found at $WATCH"
command -v git >/dev/null 2>&1 || fail "git required to run this test"

# ── Stub gh / herdr on PATH (network-free); git stays REAL for the local repo ops ─────────────────
BIN="$T/bin"; mkdir -p "$BIN"
for cmd in gh herdr; do printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$cmd"; chmod +x "$BIN/$cmd"; done
export PATH="$BIN:$PATH"

# ── Source agent-watch.sh in lib mode (defines functions only) ────────────────────────────────────
export AGENT_WATCH_LIB=1
export WORKTREES_DIR="$T/trees"; mkdir -p "$T/trees"
export HERD_CONFIG_FILE="$T/no-such-config"
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"
type refresh_symbol_index >/dev/null 2>&1 || fail "refresh_symbol_index not defined"

# Override journal_append to a log so every outcome is inspectable.
JLOG="$T/journal.log"; : > "$JLOG"
journal_append() { printf '%s\n' "$*" >> "$JLOG"; }

# Redirect $HERE at a stub dir whose symbol-index.sh writes deterministic content controlled by
# $STUB_INDEX to the requested HERD_SYMBOL_INDEX_OUT — the exact seam refresh_symbol_index drives.
STUBHERD="$T/herd-stub"; mkdir -p "$STUBHERD"
cat > "$STUBHERD/symbol-index.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "${STUB_INDEX:-INDEX v1}" > "$HERD_SYMBOL_INDEX_OUT"
STUB
chmod +x "$STUBHERD/symbol-index.sh"
HERE="$STUBHERD"
export STUB_INDEX

# ── Real git repo wired to a bare origin ──────────────────────────────────────────────────────────
ORIGIN="$T/origin.git"; git init -q --bare "$ORIGIN"
MAIN="$T/main"; git clone -q "$ORIGIN" "$MAIN" 2>/dev/null
git -C "$MAIN" checkout -q -B main
git -C "$MAIN" config user.email t@t.test; git -C "$MAIN" config user.name tester
mkdir -p "$MAIN/docs"; printf 'INDEX v1\n' > "$MAIN/docs/symbol-index.md"
git -C "$MAIN" add docs/symbol-index.md; git -C "$MAIN" commit -q -m init
git -C "$MAIN" push -q origin main
# refresh_symbol_index reads these (normally derived by herd-config from DEFAULT_BRANCH).
HERD_REMOTE=origin; HERD_BRANCH_NAME=main; DEFAULT_BRANCH=origin/main

commits() { git -C "$MAIN" rev-list --count HEAD; }
idxfile_content() { cat "$MAIN/docs/symbol-index.md"; }
jhas() { grep -q "$1" "$JLOG"; }

# ── (1) OFF = byte-inert ──────────────────────────────────────────────────────────────────────────
: > "$JLOG"; STUB_INDEX="INDEX v2"; c0="$(commits)"
CODEMAP_AUTOREFRESH=false refresh_symbol_index 5
[ "$(commits)" = "$c0" ]                || fail "(1) OFF created a commit — must be inert"
[ "$(idxfile_content)" = "INDEX v1" ]   || fail "(1) OFF touched docs/symbol-index.md — must be inert (got: $(idxfile_content))"
jhas 'result skipped reason disabled'   || fail "(1) OFF did not journal skipped/disabled: $(cat "$JLOG")"
ok

# ── (2) CHANGED CONTENT → commit direct + push ff-safe ────────────────────────────────────────────
: > "$JLOG"; STUB_INDEX="INDEX v2"; c0="$(commits)"
CODEMAP_AUTOREFRESH=true refresh_symbol_index 7
[ "$(commits)" = "$((c0 + 1))" ]                             || fail "(2) expected exactly one new commit"
[ "$(idxfile_content)" = "INDEX v2" ]                        || fail "(2) committed index content not refreshed"
[ "$(git -C "$MAIN" log -1 --format=%s)" = "chore: refresh symbol-index after PR #7" ] \
                                                             || fail "(2) commit message wrong: $(git -C "$MAIN" log -1 --format=%s)"
# Only docs/symbol-index.md was in the commit (scoped) — exactly one path changed.
[ "$(git -C "$MAIN" show --stat --format= HEAD | grep -c '|')" = "1" ] || fail "(2) commit not scoped to a single path"
grep -q 'docs/symbol-index.md' < <(git -C "$MAIN" show --stat --format= HEAD) || fail "(2) commit did not touch docs/symbol-index.md"
# Pushed ff-safe: origin advanced to HEAD.
[ "$(git -C "$MAIN" rev-parse HEAD)" = "$(git -C "$MAIN" rev-parse origin/main)" ] || fail "(2) commit was not pushed to origin"
jhas 'result committed pushed yes' || fail "(2) did not journal committed/pushed: $(cat "$JLOG")"
ok

# ── (3) FRESH (regen == committed) → no commit ────────────────────────────────────────────────────
: > "$JLOG"; STUB_INDEX="INDEX v2"; c0="$(commits)"
CODEMAP_AUTOREFRESH=true refresh_symbol_index 8
[ "$(commits)" = "$c0" ]                      || fail "(3) FRESH created a commit — nothing changed"
[ -z "$(git -C "$MAIN" status --porcelain)" ] || fail "(3) FRESH left the tree dirty"
jhas 'result fresh'                           || fail "(3) did not journal fresh: $(cat "$JLOG")"
ok

# ── (4) DIRTY PATH → skip, never touch a concurrent writer's edit ─────────────────────────────────
: > "$JLOG"; printf 'HAND-EDIT IN FLIGHT\n' > "$MAIN/docs/symbol-index.md"; STUB_INDEX="INDEX v3"; c0="$(commits)"
CODEMAP_AUTOREFRESH=true refresh_symbol_index 9
[ "$(commits)" = "$c0" ]                         || fail "(4) DIRTY created a commit — must skip"
[ "$(idxfile_content)" = "HAND-EDIT IN FLIGHT" ] || fail "(4) DIRTY was overwritten by the regen — must skip untouched"
jhas 'result skipped reason dirty-path'          || fail "(4) did not journal skipped/dirty-path: $(cat "$JLOG")"
git -C "$MAIN" checkout -- docs/symbol-index.md   # restore clean state for (5)
ok

# ── (5) NOT ADOPTED (no committed index) → skip, never materialize one ────────────────────────────
: > "$JLOG"; git -C "$MAIN" rm -q docs/symbol-index.md; git -C "$MAIN" commit -q -m "drop index"
STUB_INDEX="INDEX v9"; c0="$(commits)"
CODEMAP_AUTOREFRESH=true refresh_symbol_index 10
[ "$(commits)" = "$c0" ]                    || fail "(5) NOT-ADOPTED created a commit"
[ -f "$MAIN/docs/symbol-index.md" ]         && fail "(5) NOT-ADOPTED materialized a new index"
jhas 'result skipped reason no-index'       || fail "(5) did not journal skipped/no-index: $(cat "$JLOG")"
ok

echo "PASS: test-symbol-index-autorefresh.sh ($pass checks)"
