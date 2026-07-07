#!/usr/bin/env bash
# test-codemap-autorefresh.sh — hermetic tests for the POST-MERGE codemap freshness hook
# (refresh_codemap in agent-watch.sh, HERD-46).
#
#   (1) OFF (CODEMAP_AUTOREFRESH=false) is BYTE-INERT: the scan never runs, the tree is untouched,
#       and the event journals result=skipped reason=disabled
#   (2) CHANGED CONTENT: the deterministic regen differs from the committed map → commit STRAIGHT to
#       the default branch (message "chore: refresh codemap after PR #N"), scoped to docs/codemap.md,
#       pushed ff-safe (origin advances); journals result=committed pushed=yes
#   (3) FRESH: the regen matches the committed map → NO commit, tree clean; journals result=fresh
#   (4) DIRTY PATH: docs/codemap.md already carries an uncommitted change → skip untouched (never
#       clobber or bundle a concurrent writer's edit); journals result=skipped reason=dirty-path
#   (5) NOT ADOPTED: no committed docs/codemap.md → skip, never materialize one; result=skipped no-codemap
#
# Sources agent-watch.sh in lib mode (AGENT_WATCH_LIB=1) and drives refresh_codemap directly against
# a REAL local git repo wired to a bare "origin" (so push is exercised with no network). codemap.sh
# is stubbed via an overridden $HERE so the test controls exactly what a "regen" produces, and
# journal_append is overridden to a log so each outcome is asserted.
# Run:  bash tests/test-codemap-autorefresh.sh
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
type refresh_codemap >/dev/null 2>&1 || fail "refresh_codemap not defined"

# Override journal_append to a log so every outcome is inspectable.
JLOG="$T/journal.log"; : > "$JLOG"
journal_append() { printf '%s\n' "$*" >> "$JLOG"; }

# Redirect $HERE at a stub dir whose codemap.sh writes deterministic content controlled by $STUB_MAP
# to the requested HERD_CODEMAP_OUT — the exact seam refresh_codemap drives.
STUBHERD="$T/herd-stub"; mkdir -p "$STUBHERD"
cat > "$STUBHERD/codemap.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "${STUB_MAP:-MAP v1}" > "$HERD_CODEMAP_OUT"
STUB
chmod +x "$STUBHERD/codemap.sh"
HERE="$STUBHERD"
export STUB_MAP

# ── Real git repo wired to a bare origin ──────────────────────────────────────────────────────────
ORIGIN="$T/origin.git"; git init -q --bare "$ORIGIN"
MAIN="$T/main"; git clone -q "$ORIGIN" "$MAIN" 2>/dev/null
git -C "$MAIN" checkout -q -B main
git -C "$MAIN" config user.email t@t.test; git -C "$MAIN" config user.name tester
mkdir -p "$MAIN/docs"; printf 'MAP v1\n' > "$MAIN/docs/codemap.md"
git -C "$MAIN" add docs/codemap.md; git -C "$MAIN" commit -q -m init
git -C "$MAIN" push -q origin main
# refresh_codemap reads these (normally derived by herd-config from DEFAULT_BRANCH).
HERD_REMOTE=origin; HERD_BRANCH_NAME=main; DEFAULT_BRANCH=origin/main

commits() { git -C "$MAIN" rev-list --count HEAD; }
mapfile_content() { cat "$MAIN/docs/codemap.md"; }
jhas() { grep -q "$1" "$JLOG"; }

# ── (1) OFF = byte-inert ──────────────────────────────────────────────────────────────────────────
: > "$JLOG"; STUB_MAP="MAP v2"; c0="$(commits)"
CODEMAP_AUTOREFRESH=false refresh_codemap 5
[ "$(commits)" = "$c0" ]              || fail "(1) OFF created a commit — must be inert"
[ "$(mapfile_content)" = "MAP v1" ]   || fail "(1) OFF touched docs/codemap.md — must be inert (got: $(mapfile_content))"
jhas 'result skipped reason disabled' || fail "(1) OFF did not journal skipped/disabled: $(cat "$JLOG")"
ok

# ── (2) CHANGED CONTENT → commit direct + push ff-safe ────────────────────────────────────────────
: > "$JLOG"; STUB_MAP="MAP v2"; c0="$(commits)"
CODEMAP_AUTOREFRESH=true refresh_codemap 7
[ "$(commits)" = "$((c0 + 1))" ]                             || fail "(2) expected exactly one new commit"
[ "$(mapfile_content)" = "MAP v2" ]                          || fail "(2) committed map content not refreshed"
[ "$(git -C "$MAIN" log -1 --format=%s)" = "chore: refresh codemap after PR #7" ] \
                                                             || fail "(2) commit message wrong: $(git -C "$MAIN" log -1 --format=%s)"
# Only docs/codemap.md was in the commit (scoped) — exactly one path changed.
[ "$(git -C "$MAIN" show --stat --format= HEAD | grep -c '|')" = "1" ] || fail "(2) commit not scoped to a single path"
grep -q 'docs/codemap.md' < <(git -C "$MAIN" show --stat --format= HEAD) || fail "(2) commit did not touch docs/codemap.md"
# Pushed ff-safe: origin advanced to HEAD.
[ "$(git -C "$MAIN" rev-parse HEAD)" = "$(git -C "$MAIN" rev-parse origin/main)" ] || fail "(2) commit was not pushed to origin"
jhas 'result committed pushed yes' || fail "(2) did not journal committed/pushed: $(cat "$JLOG")"
ok

# ── (3) FRESH (regen == committed) → no commit ────────────────────────────────────────────────────
: > "$JLOG"; STUB_MAP="MAP v2"; c0="$(commits)"
CODEMAP_AUTOREFRESH=true refresh_codemap 8
[ "$(commits)" = "$c0" ]                    || fail "(3) FRESH created a commit — nothing changed"
[ -z "$(git -C "$MAIN" status --porcelain)" ] || fail "(3) FRESH left the tree dirty"
jhas 'result fresh'                          || fail "(3) did not journal fresh: $(cat "$JLOG")"
ok

# ── (4) DIRTY PATH → skip, never touch a concurrent writer's edit ─────────────────────────────────
: > "$JLOG"; printf 'HAND-EDIT IN FLIGHT\n' > "$MAIN/docs/codemap.md"; STUB_MAP="MAP v3"; c0="$(commits)"
CODEMAP_AUTOREFRESH=true refresh_codemap 9
[ "$(commits)" = "$c0" ]                       || fail "(4) DIRTY created a commit — must skip"
[ "$(mapfile_content)" = "HAND-EDIT IN FLIGHT" ] || fail "(4) DIRTY was overwritten by the regen — must skip untouched"
jhas 'result skipped reason dirty-path'        || fail "(4) did not journal skipped/dirty-path: $(cat "$JLOG")"
git -C "$MAIN" checkout -- docs/codemap.md      # restore clean state for (5)
ok

# ── (5) NOT ADOPTED (no committed map) → skip, never materialize one ──────────────────────────────
: > "$JLOG"; git -C "$MAIN" rm -q docs/codemap.md; git -C "$MAIN" commit -q -m "drop map"
STUB_MAP="MAP v9"; c0="$(commits)"
CODEMAP_AUTOREFRESH=true refresh_codemap 10
[ "$(commits)" = "$c0" ]                 || fail "(5) NOT-ADOPTED created a commit"
[ -f "$MAIN/docs/codemap.md" ]           && fail "(5) NOT-ADOPTED materialized a new codemap"
jhas 'result skipped reason no-codemap'  || fail "(5) did not journal skipped/no-codemap: $(cat "$JLOG")"
ok

echo "PASS: test-codemap-autorefresh.sh ($pass checks)"
