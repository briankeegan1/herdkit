#!/usr/bin/env bash
# test-reconcile-push-divergence.sh — regression for HERD-338: codemap/symbol-index reconcile
# commits must never strand in local main when the remote rejects the push (protected branch).
#
#   (1) refresh_codemap with a push-blocking origin: the commit is rolled back immediately,
#       'git rev-list origin/main..HEAD' stays 0, journal says result=error reason=push-rejected.
#   (2) refresh_symbol_index with a push-blocking origin: same guarantee.
#   (3) reconcile_main_freshness with generated-only local commits and a push-blocking origin:
#       resets to origin (0 ahead after the tick), journals main_freshness result=error
#       reason=push-rejected-reset, and clears the held state (no push-failed hold forever).
#   (4) herd update self-heal: when the engine dir has only docs/codemap.md + docs/symbol-index.md
#       as local-only commits (the HERD-338 corpse), auto-resets to origin and proceeds; the update
#       completes successfully instead of dying on ff-only.
#
# Sources agent-watch.sh in lib mode (AGENT_WATCH_LIB=1) for tests 1–3; exercises bin/herd update
# directly for test 4. All git operations use a local bare origin — no network required.
# Run:  bash tests/test-reconcile-push-divergence.sh
set -uo pipefail
HERE_T="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE_T/../scripts/herd/agent-watch.sh"
HERD="$HERE_T/../bin/herd"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

[ -f "$WATCH" ] || fail "agent-watch.sh not found at $WATCH"
[ -f "$HERD"  ] || fail "bin/herd not found at $HERD"
command -v git >/dev/null 2>&1 || fail "git required"

# ── Stub gh / herdr / pgrep on PATH (network-free) ───────────────────────────────────────────────
BIN="$T/bin"; mkdir -p "$BIN"
for cmd in gh herdr pgrep; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$cmd"; chmod +x "$BIN/$cmd"
done
export PATH="$BIN:$PATH"

# ── Source agent-watch.sh in lib mode ─────────────────────────────────────────────────────────────
export AGENT_WATCH_LIB=1
export WORKTREES_DIR="$T/trees"; mkdir -p "$T/trees"
export HERD_CONFIG_FILE="$T/no-such-config"
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"
for fn in refresh_codemap refresh_symbol_index reconcile_main_freshness \
          _main_fresh_generated_only _main_fresh_hold _main_fresh_clear \
          _watch_gate_inflight; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined after sourcing agent-watch.sh"
done

JLOG="$T/journal.log"; : > "$JLOG"
journal_append() { printf '%s\n' "$*" >> "$JLOG"; }

jhas() { grep -q "$1" "$JLOG"; }
reset_jlog() { : > "$JLOG"; }

# ── Stub dir: codemap.sh writes STUB_MAP to HERD_CODEMAP_OUT, symbol-index.sh writes STUB_INDEX ──
STUBHERD="$T/herd-stub"; mkdir -p "$STUBHERD"
STUB_MAP="MAP v2"; STUB_INDEX="INDEX v2"
cat > "$STUBHERD/codemap.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "${STUB_MAP:-MAP v2}" > "$HERD_CODEMAP_OUT"
STUB
cat > "$STUBHERD/symbol-index.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "${STUB_INDEX:-INDEX v2}" > "$HERD_SYMBOL_INDEX_OUT"
STUB
chmod +x "$STUBHERD/codemap.sh" "$STUBHERD/symbol-index.sh"
HERE="$STUBHERD"

# ── Real git repo wired to a PROTECTED bare origin (pre-receive hook rejects every push) ─────────
ORIGIN="$T/origin.git"; git init -q --bare "$ORIGIN"
cat > "$ORIGIN/hooks/pre-receive" <<'HOOK'
#!/usr/bin/env bash
echo "error: protected branch — direct pushes to main are not allowed" >&2
exit 1
HOOK
chmod +x "$ORIGIN/hooks/pre-receive"

gitcfg() { git -C "$1" config user.email t@t.test; git -C "$1" config user.name tester; }

MAIN="$T/main"; git clone -q "$ORIGIN" "$MAIN" 2>/dev/null || true
git -C "$MAIN" checkout -q -B main 2>/dev/null || true; gitcfg "$MAIN"
mkdir -p "$MAIN/docs"
printf 'MAP v1\n'   > "$MAIN/docs/codemap.md"
printf 'INDEX v1\n' > "$MAIN/docs/symbol-index.md"
# Seed origin via a temporary permissive hook so we have a baseline commit there.
chmod -x "$ORIGIN/hooks/pre-receive"
git -C "$MAIN" add docs/; git -C "$MAIN" commit -q -m init
git -C "$MAIN" push -q origin main
chmod +x "$ORIGIN/hooks/pre-receive"   # re-enable protection

HERD_REMOTE=origin; HERD_BRANCH_NAME=main; DEFAULT_BRANCH=origin/main
MAIN_FRESH_STATE="$TREES/.agent-watch-main-freshness"
MAIN_FRESH_RESTART="$TREES/.agent-watch-main-restart"

ahead() { git -C "$MAIN" rev-list --count "origin/main..HEAD" 2>/dev/null; }
head_sha()   { git -C "$MAIN" rev-parse HEAD 2>/dev/null; }
origin_sha() { git -C "$MAIN" rev-parse origin/main 2>/dev/null; }

export STUB_MAP STUB_INDEX

# ── (1) refresh_codemap with blocked push: 0 stranded commits, loud journal ──────────────────────
reset_jlog
STUB_MAP="MAP v2"; c_before="$(ahead)"
CODEMAP_AUTOREFRESH=true refresh_codemap 1
[ "$(ahead)" = "0" ] \
  || fail "(1) refresh_codemap left a stranded commit — 'ahead' should be 0, got $(ahead)"
[ "$(git -C "$MAIN" status --porcelain)" = "" ] \
  || fail "(1) refresh_codemap left the tree dirty: $(git -C "$MAIN" status --porcelain)"
jhas 'result error reason push-rejected' \
  || fail "(1) did not journal push-rejected: $(cat "$JLOG")"
# Must NOT still say committed pushed no (the old silent pattern)
grep -q 'result committed pushed no' "$JLOG" \
  && fail "(1) still emitting the old silent 'committed pushed no' pattern"
ok

# ── (2) refresh_symbol_index with blocked push: 0 stranded commits, loud journal ─────────────────
reset_jlog
STUB_INDEX="INDEX v2"
CODEMAP_AUTOREFRESH=true refresh_symbol_index 2
[ "$(ahead)" = "0" ] \
  || fail "(2) refresh_symbol_index left a stranded commit — 'ahead' should be 0, got $(ahead)"
[ "$(git -C "$MAIN" status --porcelain)" = "" ] \
  || fail "(2) refresh_symbol_index left the tree dirty: $(git -C "$MAIN" status --porcelain)"
jhas 'result error reason push-rejected' \
  || fail "(2) did not journal push-rejected: $(cat "$JLOG")"
grep -q 'result committed pushed no' "$JLOG" \
  && fail "(2) still emitting the old silent 'committed pushed no' pattern"
ok

# ── (3) reconcile_main_freshness: generated-only ahead + blocked push → reset, no hold forever ───
# Simulate the HERD-338 state: a seat previously committed a map refresh but the push was rejected.
# We create the stranded commit directly (bypassing refresh_codemap, which now rolls it back itself)
# to reproduce the pre-fix state that the tick-level reconcile must heal.
printf 'MAP v3 (stranded)\n' > "$MAIN/docs/codemap.md"
git -C "$MAIN" commit -q -m "chore: refresh codemap (reconcile)" -- docs/codemap.md

[ "$(ahead)" = "1" ] || fail "(3) fixture: expected 1 stranded commit, got $(ahead)"
reset_jlog; rm -f "$MAIN_FRESH_STATE" "$MAIN_FRESH_RESTART"

reconcile_main_freshness

# After the tick the seat must be at origin (no stranded commits).
[ "$(ahead)" = "0" ] \
  || fail "(3) reconcile_main_freshness left stranded commits — 'ahead' should be 0, got $(ahead)"
[ "$(head_sha)" = "$(origin_sha)" ] \
  || fail "(3) HEAD != origin/main after the reconcile tick"
# Journal must record the push-rejected-reset event.
jhas 'main_freshness result error reason push-rejected-reset' \
  || fail "(3) did not journal push-rejected-reset: $(cat "$JLOG")"
# The held state file must be gone (no push-failed hold looping forever).
[ ! -e "$MAIN_FRESH_STATE" ] \
  || fail "(3) reconcile_main_freshness left a held state file: $(cat "$MAIN_FRESH_STATE")"
ok

# ── (4) herd update self-heal: engine with only regenerable artifact commits succeeds ─────────────
# Build a fake engine upstream + a clone that has ONLY codemap/symbol-index divergence.
# The upstream must ALSO have a new commit so the clone is truly DIVERGED (ahead AND behind),
# which is what kills 'git pull --ff-only'. A clone that is only AHEAD sees 'Already up to date.'
UPSTREAM="$T/engine-upstream"
mkdir -p "$UPSTREAM"
git -C "$UPSTREAM" init -q; gitcfg "$UPSTREAM"
printf 'v1\n' > "$UPSTREAM/version.txt"
mkdir -p "$UPSTREAM/docs"
printf 'CODEMAP v1\n' > "$UPSTREAM/docs/codemap.md"
printf 'INDEX v1\n'   > "$UPSTREAM/docs/symbol-index.md"
git -C "$UPSTREAM" add -A; git -C "$UPSTREAM" commit -q -m "engine v1"

ENG="$T/engine-clone"
git clone -q "$UPSTREAM" "$ENG" 2>/dev/null; gitcfg "$ENG"

# Simulate HERD-338 divergence: add codemap + symbol-index commits that could NOT be pushed.
printf 'CODEMAP v2 (reconcile)\n' > "$ENG/docs/codemap.md"
git -C "$ENG" add docs/codemap.md; git -C "$ENG" commit -q -m "chore: refresh codemap (reconcile)"
printf 'INDEX v2 (reconcile)\n' > "$ENG/docs/symbol-index.md"
git -C "$ENG" add docs/symbol-index.md; git -C "$ENG" commit -q -m "chore: refresh symbol-index (reconcile)"

# Advance the upstream AFTER the clone so ENG is DIVERGED (ahead AND behind) — this is what kills
# 'git pull --ff-only'. A clone that is only ahead sees 'Already up to date.' and succeeds trivially.
printf 'v2\n' > "$UPSTREAM/version.txt"
git -C "$UPSTREAM" add -A; git -C "$UPSTREAM" commit -q -m "engine v2: new real commit"

# Verify the fixture: 2 ahead AND 1 behind origin.
ahead_eng()  { git -C "$ENG" rev-list --count "origin/main..HEAD" 2>/dev/null; }
behind_eng() { git -C "$ENG" rev-list --count "HEAD..origin/main" 2>/dev/null; }
git -C "$ENG" fetch -q 2>/dev/null || true
[ "$(ahead_eng)" = "2" ]  || fail "(4) fixture: expected 2 ahead, got $(ahead_eng)"
[ "$(behind_eng)" = "1" ] || fail "(4) fixture: expected 1 behind, got $(behind_eng)"

# Make a minimal project and run herd update.
PROJ="$T/proj4"; mkdir -p "$PROJ"
git -C "$PROJ" init -q; gitcfg "$PROJ"
( cd "$PROJ" && git commit -q --allow-empty -m init )
mkdir -p "$PROJ/.herd" "$PROJ/trees"
cat > "$PROJ/.herd/config" <<CFG
HERD_VERSION=1
PROJECT_ROOT="$PROJ"
WORKTREES_DIR="$PROJ/trees"
DEFAULT_BRANCH="origin/main"
WORKSPACE_NAME="testws"
BACKLOG_FILE="BACKLOG.md"
SCRIBE_BACKEND="file"
WATCHER_AUTOMERGE="true"
CFG

out="$( cd "$PROJ" && HERD_UPDATE_ENGINE_DIR="$ENG" HERD_RELOAD_SKIP_LAUNCH=1 \
  bash "$HERD" update 2>&1 )"
# The update must succeed (not die on ff-only).
[ $? -eq 0 ] || fail "(4) herd update failed after self-heal: $out"
# It must warn about the auto-heal.
printf '%s' "$out" | grep -qi "auto-heal\|regenerable\|HERD-338" \
  || fail "(4) herd update did not mention auto-heal: $out"
# After the self-heal, the engine clone must be at origin (no stranded commits).
[ "$(ahead_eng)" = "0" ] \
  || fail "(4) engine still has stranded commits after self-heal: $(ahead_eng) ahead"
ok

echo "PASS: test-reconcile-push-divergence.sh ($pass checks)"
