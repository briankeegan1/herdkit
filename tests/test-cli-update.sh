#!/usr/bin/env bash
# test-cli-update.sh — hermetic tests for `herd update`.
#
# Design principles (mirrors test-cli-reload.sh):
#   • herdr is STUBBED on PATH — exits 1 by default (no herdr instance needed) so the
#     working-builder check sees no agents and proceeds harmlessly. Tests 8–9 swap in a
#     richer herdr stub that returns a "working" agent to exercise the mid-flight guard.
#   • HERD_UPDATE_ENGINE_DIR points at a temp fake HERDKIT_HOME git repo (never touches
#     the real engine checkout). Four variants are built once at the top:
#       CLEAN_ENGINE    — clone at v3, already up to date (nothing to pull)
#       NEW_ENGINE      — clone at v1, behind upstream by two commits (pull brings them in)
#       DIVERGED_ENGINE — clone at v3, reset to v1 + local commit → ff-only fails
#       DIRTY_ENGINE    — clone at v3 with an uncommitted file in the working tree
#   • HERD_RELOAD_SKIP_LAUNCH=1 suppresses every watcher/pane launch so no persistent
#     processes are spawned.
#   • pgrep is STUBBED to return nothing — cmd_reload's stray-guard never sees real PIDs.
#
# Engine setup order (preserves the invariants above):
#   1. Create upstream at v1.
#   2. Clone NEW_ENGINE at v1 (will be behind after v2/v3 land).
#   3. Add v2, v3 to upstream.
#   4. Clone CLEAN_ENGINE at v3 (already up to date).
#   5. Clone DIRTY_ENGINE at v3, add an uncommitted file.
#   6. Clone DIVERGED_ENGINE at v3, reset to v1, add a local commit (diverges from upstream).
#
# Run:  bash tests/test-cli-update.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
HERD="$HERE/../bin/herd"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass=0
ok(){ pass=$((pass+1)); }

# ── Stub pgrep and herdr on PATH ─────────────────────────────────────────────
BIN="$T/bin"; mkdir -p "$BIN"

# pgrep stub: returns nothing — cmd_reload's stray-guard is a no-op.
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/pgrep"; chmod +x "$BIN/pgrep"

# herdr stub: exits 1 by default — builder check finds no agents, falls through.
printf '#!/usr/bin/env bash\nexit 1\n' > "$BIN/herdr"; chmod +x "$BIN/herdr"

export PATH="$BIN:$PATH"

# ── Fake engine repos ─────────────────────────────────────────────────────────
# Step 1: upstream at v1.
UPSTREAM="$T/upstream"
mkdir "$UPSTREAM"
git -C "$UPSTREAM" init -q
git -C "$UPSTREAM" config user.email t@t.t
git -C "$UPSTREAM" config user.name t
printf 'version=1\n' > "$UPSTREAM/version.txt"
git -C "$UPSTREAM" add -A
git -C "$UPSTREAM" commit -q -m "engine v1"

# Step 2: NEW_ENGINE cloned at v1 (will be behind after v2/v3 land on upstream).
NEW_ENGINE="$T/new_engine"
git clone "$UPSTREAM" "$NEW_ENGINE" -q 2>/dev/null

# Step 3: Add v2 and v3 to upstream.
printf 'version=2\n' > "$UPSTREAM/version.txt"
git -C "$UPSTREAM" add -A
git -C "$UPSTREAM" commit -q -m "engine v2: fix the foo bug"
printf 'version=3\n' > "$UPSTREAM/version.txt"
git -C "$UPSTREAM" add -A
git -C "$UPSTREAM" commit -q -m "engine v3: add bar feature"

# Step 4: CLEAN_ENGINE cloned at v3 (same as upstream — already up to date).
CLEAN_ENGINE="$T/clean_engine"
git clone "$UPSTREAM" "$CLEAN_ENGINE" -q 2>/dev/null

# Step 5: DIRTY_ENGINE: clone at v3, add an uncommitted file.
DIRTY_ENGINE="$T/dirty_engine"
git clone "$UPSTREAM" "$DIRTY_ENGINE" -q 2>/dev/null
printf 'uncommitted\n' >> "$DIRTY_ENGINE/version.txt"

# Step 6: DIVERGED_ENGINE: clone at v3, reset to v1, add a local commit.
#   local HEAD: v1 → local-commit (not an ancestor of upstream v3)
#   origin/main: v3
#   → git pull --ff-only fails (histories diverged).
DIVERGED_ENGINE="$T/diverged_engine"
git clone "$UPSTREAM" "$DIVERGED_ENGINE" -q 2>/dev/null
git -C "$DIVERGED_ENGINE" config user.email t@t.t
git -C "$DIVERGED_ENGINE" config user.name t
git -C "$DIVERGED_ENGINE" reset --hard HEAD~2 -q 2>/dev/null
printf 'local only\n' >> "$DIVERGED_ENGINE/version.txt"
git -C "$DIVERGED_ENGINE" add -A
git -C "$DIVERGED_ENGINE" commit -q -m "local diverging commit" 2>/dev/null

# ── Helper: make a minimal project under ROOT with WORKSPACE ─────────────────
_make_project() {
  local r="$1" ws="$2"; shift 2
  local r_real; r_real="$(cd "$r" && pwd -P)"
  git -C "$r" init -q
  git -C "$r" config user.email t@t.t
  git -C "$r" config user.name t
  ( cd "$r" && git commit -q --allow-empty -m init )
  mkdir -p "$r/.herd" "$r/trees"
  cat > "$r/.herd/config" <<CFG
HERD_VERSION=1
PROJECT_ROOT="$r_real"
WORKTREES_DIR="$r_real/trees"
DEFAULT_BRANCH="origin/main"
WORKSPACE_NAME="$ws"
BACKLOG_FILE="BACKLOG.md"
SCRIBE_BACKEND="file"
WATCHER_AUTOMERGE="true"
CFG
  for line in "$@"; do printf '%s\n' "$line" >> "$r/.herd/config"; done
}

# _run_update PROJECT ENGINE [extra env...] — run herd update with standard test knobs.
# "extra env..." entries are VAR=val STRINGS (e.g. from a variable, not a parse-time literal), so
# they are handed to `env` rather than used as a bash prefix-assignment — "$@" VAR=val cmd only
# works when VAR=val is an unquoted literal token at parse time, never when it comes from parameter
# expansion (bash never re-parses an already-expanded string for '=' assignment syntax).
_run_update() {
  local proj="$1" eng="$2"; shift 2
  ( cd "$proj" && env HERD_UPDATE_ENGINE_DIR="$eng" HERD_RELOAD_SKIP_LAUNCH=1 "$@" bash "$HERD" update 2>&1 )
}

# ── 1. No .herd/config → die with clear message ───────────────────────────────
P="$T/p1"; mkdir "$P"
git -C "$P" init -q; git -C "$P" config user.email t@t.t; git -C "$P" config user.name t
( cd "$P" && git commit -q --allow-empty -m init )
out="$(_run_update "$P" "$CLEAN_ENGINE" || true)"
grep -qi "herd init\|no .herd/config" <<< "$out" \
  || fail "missing .herd/config should produce a clear error"
ok

# ── 2. Dirty engine (no --force) → refuse with clear message ─────────────────
P="$T/p2"; mkdir "$P"
_make_project "$P" "updatetest"
out="$(_run_update "$P" "$DIRTY_ENGINE" || true)"
grep -qi "uncommitted\|dirty" <<< "$out" \
  || fail "dirty engine should be reported in the error"
grep -qi "refus\|abort\|dirty" <<< "$out" \
  || fail "should refuse to pull over dirty engine without --force"
ok

# ── 3. Dirty engine (--force) → proceeds with warning ────────────────────────
P="$T/p3"; mkdir "$P"
_make_project "$P" "updatetest"
out="$( cd "$P" && HERD_UPDATE_ENGINE_DIR="$DIRTY_ENGINE" HERD_RELOAD_SKIP_LAUNCH=1 \
  bash "$HERD" update --force 2>&1 )"
grep -qi "force\|proceed" <<< "$out" \
  || fail "dirty engine with --force should warn and proceed"
grep -qi "reload complete\|upgrade" <<< "$out" \
  || fail "update --force on dirty engine should still run upgrade+reload"
ok

# ── 4. git pull --ff-only fails → die with clear message ─────────────────────
P="$T/p4"; mkdir "$P"
_make_project "$P" "updatetest"
out="$(_run_update "$P" "$DIVERGED_ENGINE" || true)"
grep -qi "ff-only\|diverged\|failed" <<< "$out" \
  || fail "ff-only failure should produce a clear error message"
ok

# ── 5. Already up to date → reports no new commits ───────────────────────────
P="$T/p5"; mkdir "$P"
_make_project "$P" "updatetest"
out="$(_run_update "$P" "$CLEAN_ENGINE")"
grep -qi "already up to date\|no new commits" <<< "$out" \
  || fail "already-up-to-date pull should report no new commits"
ok

# ── 6. New commits pulled → shows delta (git log --oneline) ──────────────────
P="$T/p6"; mkdir "$P"
_make_project "$P" "updatetest"
out="$(_run_update "$P" "$NEW_ENGINE")"
grep -q "engine v2" <<< "$out" || fail "delta missing 'engine v2' commit"
grep -q "engine v3" <<< "$out" || fail "delta missing 'engine v3' commit"
ok

# ── 7. Full happy path: upgrade runs (skill rendered) + reload runs ───────────
P="$T/p7"; mkdir "$P"
_make_project "$P" "updatetest"
out="$(_run_update "$P" "$CLEAN_ENGINE")"
[ -f "$P/.claude/commands/coordinator.md" ] \
  || fail "update did not render the coordinator skill"
grep -q "GENERATED BY herdkit" "$P/.claude/commands/coordinator.md" \
  || fail "rendered skill missing generated banner"
grep -q '{{' "$P/.claude/commands/coordinator.md" \
  && fail "rendered skill has unrendered {{tokens}}" || true
grep -qi "reload complete\|MERGE_POLICY" <<< "$out" \
  || fail "update should run reload and show reload summary"
ok

# ── 8. Mid-flight builders (non-interactive, no --force) → die ───────────────
P="$T/p8"; mkdir "$P"
_make_project "$P" "updatetest"
# Add a real git worktree so 'git worktree list' shows slug 'my-feature'.
git -C "$P" worktree add "$P/trees/my-feature" -b feat/my-feature 2>/dev/null

cat > "$BIN/herdr" <<'STUB'
#!/usr/bin/env bash
printf '{"result":{"agents":[{"name":"my-feature","agent_status":"working"}]}}\n'
STUB
chmod +x "$BIN/herdr"

out="$( cd "$P" && HERD_UPDATE_ENGINE_DIR="$CLEAN_ENGINE" HERD_RELOAD_SKIP_LAUNCH=1 \
  HERD_NONINTERACTIVE=1 bash "$HERD" update 2>&1 || true )"
grep -qi "mid.flight\|builder" <<< "$out" \
  || fail "mid-flight builders should be reported"
grep -qi "abort\|refus" <<< "$out" \
  || fail "should abort with mid-flight builders (non-interactive, no --force)"

printf '#!/usr/bin/env bash\nexit 1\n' > "$BIN/herdr"; chmod +x "$BIN/herdr"
ok

# ── 9. Mid-flight builders (--force) → proceeds with warning ─────────────────
P="$T/p9"; mkdir "$P"
_make_project "$P" "updatetest"
git -C "$P" worktree add "$P/trees/my-feature" -b feat/my-feature 2>/dev/null

cat > "$BIN/herdr" <<'STUB'
#!/usr/bin/env bash
printf '{"result":{"agents":[{"name":"my-feature","agent_status":"working"}]}}\n'
STUB
chmod +x "$BIN/herdr"

out="$( cd "$P" && HERD_UPDATE_ENGINE_DIR="$CLEAN_ENGINE" HERD_RELOAD_SKIP_LAUNCH=1 \
  bash "$HERD" update --force 2>&1 )"
grep -qi "force\|proceed" <<< "$out" \
  || fail "--force with mid-flight builders should warn and proceed"
grep -qi "reload complete\|MERGE_POLICY" <<< "$out" \
  || fail "update --force with mid-flight builders should run to completion"

printf '#!/usr/bin/env bash\nexit 1\n' > "$BIN/herdr"; chmod +x "$BIN/herdr"
ok

# ── 10. No herdr on PATH → builder check skipped, update proceeds ─────────────
# HERD-189/441: moving OUR OWN $BIN/herdr aside only removes it from PATH's FIRST match — under the
# whole-suite daemon-hermeticity sandbox (.herd/healthcheck.project.sh), a SECOND herdr tripwire
# stub is ALSO on PATH (further down, shadowing the real binary for every test in the run), so
# `command -v herdr` still finds THAT one and cmd_update's builder check still runs against it —
# which both defeats this case's actual intent (it no longer exercises the "herdr genuinely
# absent" branch) and trips the outer suite's leak detector (a false hermeticity violation, since
# it is that OUTER stub's own tripwire firing, not a real reach past it). Build a PATH with EVERY
# directory that provides an executable named 'herdr' filtered out — $BIN, the outer sandbox's
# shim dir, and any real system herdr alike — so this case is a genuine, environment-independent
# proof of "herdr unresolvable", immune to how many stub layers happen to be stacked around it.
P="$T/p10"; mkdir "$P"
_make_project "$P" "updatetest"
mv "$BIN/herdr" "$BIN/herdr.bak"
NO_HERDR_PATH=""
IFS=':' read -ra _p10_dirs <<< "$PATH"
for _p10_d in "${_p10_dirs[@]}"; do
  [ -x "$_p10_d/herdr" ] && continue
  NO_HERDR_PATH="${NO_HERDR_PATH:+$NO_HERDR_PATH:}$_p10_d"
done
out="$(_run_update "$P" "$CLEAN_ENGINE" "PATH=$NO_HERDR_PATH")"
# HERD-441 class, hit live on the macos CI leg of PR #563: `printf | grep -q` is EPIPE-unsafe under
# pipefail — grep -q exits on the first match while printf is still writing, and once $out crosses the
# platform pipe buffer (16KB on macOS, 64KB on linux) printf takes SIGPIPE and the pipeline goes
# non-zero on a MATCH. Here-string is the shared lint's prescribed safe form: no producer process, so
# nothing can EPIPE. Pre-existing, not this PR's change — fixed only because it reds this PR's leg.
grep -qi "reload complete\|MERGE_POLICY" <<< "$out" \
  || fail "update should succeed even when herdr is absent"
mv "$BIN/herdr.bak" "$BIN/herdr"
ok

# ── 11. Rendered skill contains 'Update the engine' section ──────────────────
P="$T/p11"; mkdir "$P"
_make_project "$P" "updatetest"
_run_update "$P" "$CLEAN_ENGINE" >/dev/null 2>&1
grep -q "Update the engine" "$P/.claude/commands/coordinator.md" \
  || fail "rendered coordinator skill missing 'Update the engine' section"
grep -q "herd update" "$P/.claude/commands/coordinator.md" \
  || fail "rendered coordinator skill missing 'herd update' command reference"
ok

# ── 12. Rendered skill's capabilities block mentions herd update ──────────────
P="$T/p12"; mkdir "$P"
_make_project "$P" "updatetest"
_run_update "$P" "$CLEAN_ENGINE" >/dev/null 2>&1
grep -q "herd update" "$P/.claude/commands/coordinator.md" \
  || fail "capabilities block missing herd update entry"
ok

echo "ALL PASS ($pass checks)"
