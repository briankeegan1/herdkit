#!/usr/bin/env bash
# test-scribe-backend-flip.sh — hermetic tests for issue #139: the scribe drainer must not apply a
# request via a STALE backend after SCRIBE_BACKEND changes mid-session.
#
# The bug: the drainer prompt was rendered backend-conditional at SPAWN time, and scribe.sh's
# singleton check reuses an idle/done drainer — so requests enqueued after a file→linear flip were
# drained by the old FILE-mode prompt, which filed BACKLOG-summary no-ops as junk backend issues.
#
# The fix has three testable layers:
#   (a) scribe-step.sh 'next' emits the ACTIVE backend (resolved fresh each invocation) on a
#       "BACKEND <name>" line, so a mid-session flip is honored on the very next drained request.
#   (b) scribe-step.sh 'commit' (the file-backend apply) GUARDS against a non-file active backend:
#       a stale file-mode drainer's commit no longer files the short SUMMARY as a backend item — it
#       dispatches the ORIGINAL request text through the active backend instead. The reverse
#       ('add-item' while the active backend is 'file') warns loudly rather than silently dropping.
#   (c) scribe.sh emits a SINGLE backend-agnostic prompt (no spawn-time `if SCRIBE_BACKEND = file`).
#   (d) `herd config set SCRIBE_BACKEND` warns the operator to retire the old-backend drainer.
#
# All hermetic: a temp git repo, no remote (DEFAULT_BRANCH points at a non-existent ref so push is
# skipped), herdr stubbed. Run:  bash tests/test-scribe-backend-flip.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
STEP="$HERE/../scripts/herd/scribe-step.sh"
SCRIBE="$HERE/../scripts/herd/scribe.sh"
HERD="$HERE/../bin/herd"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ pass=$((pass+1)); }

# ── Stub herdr on PATH so no real notification/tab is ever touched ────────────
BIN="$T/bin"; mkdir -p "$BIN"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/herdr"; chmod +x "$BIN/herdr"
# pgrep stub keeps a hypothetical reload path hermetic (see the config-set section).
cat > "$BIN/pgrep" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$BIN/pgrep"
export PATH="$BIN:$PATH"

# ── A temp git repo + a .herd/config the step script sources ──────────────────
REPO="$T/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email t@t.t; git -C "$REPO" config user.name t
git -C "$REPO" commit -q --allow-empty -m init
TREES="$T/trees"; Q="$TREES/backlog-queue"; mkdir -p "$Q"

CFG="$T/config"
write_cfg() {  # write_cfg <backend> <backlog-file>
  cat > "$CFG" <<CFGEOF
HERD_VERSION=1
PROJECT_ROOT="$REPO"
WORKTREES_DIR="$TREES"
DEFAULT_BRANCH="origin/main"
WORKSPACE_NAME="fliptest"
HERD_REMOTE="origin"
HERD_BRANCH_NAME="main"
BACKLOG_FILE="$2"
SCRIBE_BACKEND="$1"
CFGEOF
}

# step <args...> — run scribe-step.sh from inside $REPO with the temp config; capture combined
# output in $OUT and the exit code in $RC (never aborts the harness). SCRIBE_POLL=0 so an empty
# queue returns EMPTY immediately.
step() {
  set +e
  OUT="$( cd "$REPO" && HERD_CONFIG_FILE="$CFG" SCRIBE_POLL=0 bash "$STEP" "$@" 2>&1 )"
  RC=$?
  set -e
}

# ══ 1. `next` reports the ACTIVE backend, resolved FRESH each invocation ═══════
# The whole staleness fix hinges on this: the backend printed must track a config change, because
# the drainer branches on THIS line — not on whatever was set when it was spawned.
write_cfg changelog CHANGELOG.md
printf 'please add feature X\n' > "$Q/100-a.req"
step next
[ "$RC" -eq 0 ]                                   || fail "1: next exited $RC ($OUT)"
printf '%s\n' "$OUT" | grep -qx 'BACKEND changelog' || fail "1: next did not report the changelog backend ($OUT)"
printf '%s\n' "$OUT" | grep -q 'please add feature X' || fail "1: next did not echo the request text ($OUT)"
ok

# Flip the backend mid-session (as `herd config set` would) and enqueue another request. The very
# next `next` must report the NEW backend — proving per-drain resolution, not spawn-time freezing.
write_cfg file BACKLOG.md
printf 'another request\n' > "$Q/200-b.req"
step next
printf '%s\n' "$OUT" | grep -qx 'BACKEND file' || fail "2: next did not pick up the flipped backend ($OUT)"
ok

# ══ 2. `commit` GUARD: a stale file-mode commit under a non-file backend dispatches the ORIGINAL
#       request text (not the summary), so no junk 'no-op:' item is filed ════════
# Simulate the exact #139 scenario: SCRIBE_BACKEND has flipped to changelog, but a file-mode drainer
# (its prompt frozen from before the flip) calls `commit <mine> "<summary>"`. The claimed file still
# holds the ORIGINAL request text. The guard must file THAT via the active backend, never the summary.
write_cfg changelog CHANGELOG.md
rm -f "$Q"/*.req "$Q"/*.mine 2>/dev/null || true
printf 'Add dark mode toggle\n' > "$Q/300-c.req.mine"
step commit "$Q/300-c.req.mine" "no-op: nothing to change"
[ "$RC" -eq 0 ]                                                     || fail "3: guarded commit exited $RC ($OUT)"
grep -q -- '- Add dark mode toggle' "$REPO/CHANGELOG.md"           || fail "3: original request text was NOT dispatched to the backend ($(cat "$REPO/CHANGELOG.md" 2>/dev/null))"
grep -q 'no-op: nothing to change' "$REPO/CHANGELOG.md"           && fail "3: the SUMMARY was filed as an item (the #139 junk bug)"
printf '%s\n' "$OUT" | grep -q 'issue #139'                        || fail "3: stale-drainer commit did not warn about the mismatch ($OUT)"
[ ! -f "$Q/300-c.req.mine" ]                                       || fail "3: claimed file not cleaned up after dispatch"
ok

# The stray file edit a stale file-mode drainer would have made is discarded, not committed as junk.
# (herestrings, not `git … | grep -q`: under `pipefail`, grep -q closes the pipe on match and the
# producer's SIGPIPE would falsely fail the pipeline.)
grep -qi 'no-op' <<<"$(git -C "$REPO" log --oneline)" && fail "3b: a no-op summary leaked into a commit"
ok

# ══ 3. `commit` under the FILE backend still behaves normally (summary → commit message) ═
write_cfg file BACKLOG.md
rm -f "$Q"/*.req "$Q"/*.mine 2>/dev/null || true
printf '# Backlog\n\n## Backlog\n' > "$REPO/BACKLOG.md"
git -C "$REPO" add BACKLOG.md && git -C "$REPO" commit -q -m "seed backlog"
# The agent (simulated) edits BACKLOG.md, then calls commit with a short summary.
printf '🔜 shiny-thing — a queued item\n' >> "$REPO/BACKLOG.md"
printf 'add shiny-thing\n' > "$Q/400-d.req.mine"
step commit "$Q/400-d.req.mine" "add shiny-thing"
[ "$RC" -eq 0 ]                                                     || fail "4: file-backend commit exited $RC ($OUT)"
grep -q 'Backlog: add shiny-thing' <<<"$(git -C "$REPO" log --oneline)" || fail "4: file-backend commit did not commit with the summary ($OUT)"
grep -q 'shiny-thing' <<<"$(git -C "$REPO" show HEAD:BACKLOG.md)"  || fail "4: the agent's BACKLOG.md edit was not committed"
printf '%s\n' "$OUT" | grep -q 'issue #139'                        && fail "4: file-backend commit wrongly warned about a mismatch"
ok

# ══ 4. reverse guard: `add-item` while the active backend is 'file' warns loudly ═
write_cfg file BACKLOG.md
printf 'orphaned dispatch\n' > "$Q/500-e.req.mine"
step add-item "$Q/500-e.req.mine" "orphaned dispatch"
printf '%s\n' "$OUT" | grep -q 'issue #139' || fail "5: add-item under the file backend did not warn ($OUT)"
ok

# ══ 5. scribe.sh emits a SINGLE backend-agnostic prompt (no spawn-time backend branch) ═
grep -q 'if \[ "\$SCRIBE_BACKEND" = "file" \]' "$SCRIBE" && fail "6: scribe.sh still branches its prompt on the spawn-time backend"
grep -q 'BACKEND <name>' "$SCRIBE"                        || fail "6: scribe.sh prompt does not instruct the drainer to read the per-request BACKEND line"
# Exactly one heredoc-opened PROMPT (the single agnostic prompt), not the old two-branch pair.
[ "$(grep -c 'PROMPT=$(cat <<EOF' "$SCRIBE")" -eq 1 ]     || fail "6: scribe.sh does not emit exactly one prompt"
ok

# ══ 6. `herd config set SCRIBE_BACKEND` warns the operator to retire the old-backend drainer ═
# Minimal bin/herd harness (mirrors test-cli-config.sh): a stub capabilities manifest so key
# validation is hermetic and SCRIBE_BACKEND requires nothing (no watcher restart / re-render).
CAPS="$T/capabilities.tsv"
{
  printf 'name\tkind\tdescription\twhen_to_surface\trequires\n'
  printf 'WORKSPACE_NAME\tconfig\tProject label\tAlways\twatcher\n'
  printf 'SCRIBE_BACKEND\tconfig\tWork-tracker backend adapter\tSet for a tracker\t\n'
} > "$CAPS"
CPROJ="$T/cproj"; mkdir -p "$CPROJ/.herd"
git -C "$CPROJ" init -q
git -C "$CPROJ" config user.email t@t.t; git -C "$CPROJ" config user.name t
git -C "$CPROJ" commit -q --allow-empty -m init
cat > "$CPROJ/.herd/config" <<CFGEOF
HERD_VERSION=1
PROJECT_ROOT="$CPROJ"
WORKTREES_DIR="$CPROJ/trees"
DEFAULT_BRANCH="origin/main"
WORKSPACE_NAME="cproj"
SCRIBE_BACKEND="file"
CFGEOF

set +e
COUT="$( cd "$CPROJ" && HERD_CAPABILITIES_FILE="$CAPS" HERD_RELOAD_SKIP_LAUNCH=1 \
          bash "$HERD" config set SCRIBE_BACKEND linear 2>&1 )"
CRC=$?
set -e
[ "$CRC" -eq 0 ]                                       || fail "7: config set SCRIBE_BACKEND exited $CRC ($COUT)"
printf '%s\n' "$COUT" | grep -qi 'SCRIBE_BACKEND changed' || fail "7: config set did not announce the backend change ($COUT)"
printf '%s\n' "$COUT" | grep -qi 'retire'              || fail "7: config set did not warn to retire the old-backend drainer ($COUT)"
# A no-op re-set (value unchanged) must NOT re-warn.
set +e
COUT2="$( cd "$CPROJ" && HERD_CAPABILITIES_FILE="$CAPS" bash "$HERD" config set SCRIBE_BACKEND linear 2>&1 )"
set -e
printf '%s\n' "$COUT2" | grep -qi 'retire' && fail "7: a no-op backend set still warned to retire the drainer"
ok

# ══ 7. the SHIPPED retire-drainer remedy names an ACTIONABLE herdr surface (HERD-287) ═══════════
# Guards against a regression to the old bogus line, which told operators to run
# 'herdr agent stop scribe-<workspace>' — but 'herdr agent' has NO stop subcommand (its surface is
# list/get/read/send/rename/focus/wait/attach/start/explain). The actionable remedy is closing the
# drainer's tab ('herdr tab close <tab-id>'). Grep the shipped bin/herd text directly so a future
# bogus remedy reds the gate even if the runtime warn path is refactored.
grep -q 'herdr agent stop' "$HERD" && fail "7: bin/herd still ships the bogus 'herdr agent stop' remedy ('herdr agent' has no stop subcommand)"
grep -q 'herdr tab close' "$HERD" || fail "7: bin/herd's retire-drainer remedy no longer names the actionable 'herdr tab close' surface"
ok

echo "ALL PASS ($pass checks)"
