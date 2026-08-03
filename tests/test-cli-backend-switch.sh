#!/usr/bin/env bash
# test-cli-backend-switch.sh — hermetic test of `herd backend switch`: the guided work-tracker
# flip (preflight → config-set flip → optional migration → frozen-archive banner → pane restart
# best-effort → journal). No network, no real gh, no herdr: gh is FAKED on PATH, herdr is absent
# (pane restart soft-fails by design), and stdin is /dev/null so every prompt takes its
# non-interactive path.
#
# Coverage:
#   1. file → github with --migrate: preflight passes (fake gh auth), SCRIBE_BACKEND flips, each
#      open 🔜/🚧 line is replayed via `gh issue create` with a '(migrated from file)' provenance
#      suffix (✅ lines are NOT migrated), BACKLOG.md gains the FROZEN ARCHIVE banner exactly once.
#   2. idempotence: re-running the same switch is a no-op ("already on").
#   3. failed preflight changes NOTHING: linear without a key (non-tty) dies loudly and the
#      config still says github; unauthenticated gh dies the same way from file; jira without creds
#      dies too. curl is FAKED for the jira /myself round-trip.
#   4. unknown backend name dies before any change.
#   5. file → jira with creds: the /myself round-trip passes (fake curl), the config flips and the
#      frozen-archive banner is stamped; a jira round-trip that FAILS leaves the config on file.
#
# Run:  bash tests/test-cli-backend-switch.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
HERD="$HERE/../bin/herd"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass(){ PASS=$((PASS+1)); }

BIN="$T/bin"; mkdir -p "$BIN"
GHLOG="$T/gh.log"

# FAKE gh: `auth status` honors $GH_FAKE_AUTH_FAIL; `issue create` logs its args; `issue list`
# returns an empty set (so migration dedup sees no pre-existing items).
cat > "$BIN/gh" <<'FAKE'
#!/usr/bin/env bash
echo "gh $*" >> "$GH_FAKE_LOG"
case "$1 ${2:-}" in
  "auth status")  [ "${GH_FAKE_AUTH_FAIL:-0}" = "1" ] && exit 1 || exit 0 ;;
  "issue list")   printf '%s' "${GH_FAKE_LIST:-[]}" ;;
  "issue create") exit 0 ;;
esac
exit 0
FAKE
chmod +x "$BIN/gh"

# FAKE curl: the jira preflight round-trip (_jira_api GET /myself) posts through curl. Log args and
# return a myself payload (honoring $CURL_FAKE_FAIL to simulate a bad-cred/network round-trip). The
# linear preflight (viewer{} query) is matched by "viewer" appearing in the POSTed --data and honors
# $CURL_LINEAR_FAIL to simulate a REAL API-level refusal (HERD-504: a body curl actually received,
# distinct from a LOCAL payload-build failure that never reaches curl at all — see the python3 fake
# below).
CURLLOG="$T/curl.log"
cat > "$BIN/curl" <<'FAKE'
#!/usr/bin/env bash
echo "curl $*" >> "$CURL_FAKE_LOG"
case "$*" in
  *viewer*)
    [ "${CURL_LINEAR_FAIL:-0}" = "1" ] && { echo '{"errors":[{"message":"Internal Server Error"}]}'; exit 0; }
    echo '{"data":{"viewer":{"id":"user_1"}}}'
    exit 0
    ;;
esac
[ "${CURL_FAKE_FAIL:-0}" = "1" ] && { echo '{"errorMessages":["Unauthorized"]}'; exit 0; }
echo '{"accountId":"acc_1","displayName":"Herd Bot"}'
FAKE
chmod +x "$BIN/curl"

# FAKE python3: a passthrough to the REAL python3 (captured before $BIN joins PATH) UNLESS
# LINEAR_PY_FAIL=1 AND this invocation IS _linear_gql's payload-build call (matched on the
# QUERY-env-var read that only that call site does), in which case it exits 1 without running —
# simulating that specific fork failing to exec under load (HERD-504's false-unreachable root
# cause). Scoped this tightly so LINEAR_PY_FAIL=1 does not also break the many OTHER python3 calls
# `herd backend switch` makes along the way (config parsing, engine guard, etc.) — only the one
# fork this test targets. Harmless to every other case in this file: LINEAR_PY_FAIL is unset by
# default, so it always delegates to the real python3.
REAL_PYTHON3="$(command -v python3)"
cat > "$BIN/python3" <<FAKE
#!/usr/bin/env bash
if [ "\${LINEAR_PY_FAIL:-0}" = "1" ]; then
  case "\$*" in *'os.environ["QUERY"]'*) exit 1 ;; esac
fi
exec "$REAL_PYTHON3" "\$@"
FAKE
chmod +x "$BIN/python3"

# HERMETIC STUB: step 5 of `backend switch` restarts the backlog pane via `herd pane backlog`, which
# calls the LIVE herdr (agent/tab/workspace list) whenever herdr is on PATH. The header assumes herdr
# is ABSENT, but on a dev box it is present — so shadow it with a no-op returning empty JSON. The pane
# restart is best-effort (no assertion depends on it), so outcomes are unchanged and nothing touches
# the real control room.
cat > "$BIN/herdr" <<'FAKE'
#!/usr/bin/env bash
echo '{}'
exit 0
FAKE
chmod +x "$BIN/herdr"

# HERMETIC GUARD: the backend flip runs `herd pane backlog`, whose reload path can fall back to
# spawning a REAL `nohup bash agent-watch.sh` watcher against this temp repo (which then hangs the
# switch and leaks a live daemon). Suppress the background relaunch, and make any watcher that IS
# launched inert (AGENT_WATCH_LIB returns before the loop). Neither is asserted, so outcomes hold.
export HERD_RELOAD_SKIP_LAUNCH=fallback
export AGENT_WATCH_LIB=1

# Temp project on the file backend with a mixed backlog.
P="$T/proj"; mkdir -p "$P/.herd"
cat > "$P/.herd/config" <<EOF
PROJECT_ROOT="$P"
WORKSPACE_NAME="testws"
SCRIBE_BACKEND="file"
BACKLOG_FILE="BACKLOG.md"
WORKTREES_DIR="$T/trees"
EOF
mkdir -p "$T/trees"
cat > "$P/BACKLOG.md" <<'EOF'
# proj — backlog
## Now
- 🚧 wiring the feedback loop
## Next
- 🔜 add a dark-mode toggle
## Recently shipped
- ✅ already done (must NOT migrate)
EOF

run_switch(){ ( cd "$P" && PATH="$BIN:$PATH" GH_FAKE_LOG="$GHLOG" CURL_FAKE_LOG="$CURLLOG" "$@" bash "$HERD" backend switch "${ARGS[@]}" </dev/null 2>&1 ); }

# ── Case 1: file → github --migrate ─────────────────────────────────────────────────────────────
# The target repo ALREADY has: issue #7 whose title merely CONTAINS an old item's title (the
# review-gate substring false-skip repro — it must NOT suppress migration) and issue #8 whose
# title EXACTLY equals an old item's normalized title (a true duplicate — it MUST be skipped).
export GH_FAKE_LIST='[{"number":7,"title":"Fix the wiring the feedback loop crash"},{"number":8,"title":"add a dark-mode toggle"}]'
: > "$GHLOG"
ARGS=(github --migrate)
out="$(run_switch)" || fail "file→github switch exited non-zero: $out"
grep -q 'SCRIBE_BACKEND="github"' "$P/.herd/config" || fail "config was not flipped to github"
grep -q "issue create" "$GHLOG" || fail "migration did not create issues via gh"
grep -q "wiring the feedback loop (migrated from file)" "$GHLOG" \
  || fail "substring false-skip regression: an unrelated issue containing the title suppressed migration ($(cat "$GHLOG"))"
grep -q "add a dark-mode toggle (migrated from file)" "$GHLOG" && fail "exact-duplicate item must be SKIPPED, not re-created"
grep -q "1 already present" <<<"$out" || fail "skip count for the exact duplicate missing from output ($out)"
grep -q "already done" "$GHLOG" && fail "✅ shipped item must NOT be migrated"
unset GH_FAKE_LIST
grep -q "FROZEN ARCHIVE" "$P/BACKLOG.md" || fail "BACKLOG.md missing the frozen-archive banner"
[ "$(grep -c 'FROZEN ARCHIVE' "$P/BACKLOG.md")" = "1" ] || fail "banner must be stamped exactly once"
pass

# ── Case 2: same-backend re-run is a no-op ──────────────────────────────────────────────────────
: > "$GHLOG"
ARGS=(github)
out2="$(run_switch)" || fail "same-backend switch should exit 0"
grep -q "already on" <<<"$out2" || fail "same-backend switch should say 'already on' ($out2)"
grep -q "issue create" "$GHLOG" && fail "no-op switch must not create issues"
pass

# ── Case 3a: linear without a key (non-tty) → loud death, config unchanged ─────────────────────
ARGS=(linear)
if run_switch >/dev/null; then fail "linear switch without a key must die"; fi
out3="$(run_switch)" || true
grep -q "LINEAR_API_KEY missing" <<<"$out3" || fail "missing-key death lacks the exact instruction ($out3)"
grep -q 'SCRIBE_BACKEND="github"' "$P/.herd/config" || fail "failed preflight must leave the config UNCHANGED"
pass

# ── Case 3b: unauthenticated gh → loud death, no flip ──────────────────────────────────────────
P2="$T/proj2"; mkdir -p "$P2/.herd" "$T/trees2"
cat > "$P2/.herd/config" <<EOF
PROJECT_ROOT="$P2"
WORKSPACE_NAME="testws2"
SCRIBE_BACKEND="file"
BACKLOG_FILE="BACKLOG.md"
WORKTREES_DIR="$T/trees2"
EOF
: > "$P2/BACKLOG.md"
if ( cd "$P2" && PATH="$BIN:$PATH" GH_FAKE_LOG="$GHLOG" GH_FAKE_AUTH_FAIL=1 bash "$HERD" backend switch github </dev/null ) >/dev/null 2>&1; then
  fail "switch with unauthenticated gh must die"
fi
grep -q 'SCRIBE_BACKEND="file"' "$P2/.herd/config" || fail "failed gh preflight must leave the config on file"
pass

# ── Case 3c: jira without creds (non-tty) → loud death, config unchanged ────────────────────────
ARGS=(jira)
out3c="$(run_switch)" && fail "jira switch without creds must die"
grep -q 'JIRA_' <<<"$out3c" || fail "jira no-creds death must name the missing JIRA_* keys ($out3c)"
grep -q 'SCRIBE_BACKEND="github"' "$P/.herd/config" || fail "failed jira preflight must leave the config UNCHANGED"
pass

# ── Case 4: unknown backend dies before any change ──────────────────────────────────────────────
ARGS=(zzz-nope)
if run_switch >/dev/null; then fail "unknown backend must die"; fi
grep -q 'SCRIBE_BACKEND="github"' "$P/.herd/config" || fail "unknown-backend attempt must not touch the config"
pass

# ── Case 5: file → jira with creds present → preflight round-trip passes, config flips, frozen banner
#    stamped. Creds live in .herd/secrets (sourced by the switch); the fake curl proves the /myself
#    round-trip without a real network.
P3="$T/proj3"; mkdir -p "$P3/.herd" "$T/trees3"
cat > "$P3/.herd/config" <<EOF
PROJECT_ROOT="$P3"
WORKSPACE_NAME="testws3"
SCRIBE_BACKEND="file"
BACKLOG_FILE="BACKLOG.md"
WORKTREES_DIR="$T/trees3"
EOF
cat > "$P3/.herd/secrets" <<'EOF'
JIRA_BASE_URL="https://acme.atlassian.net"
JIRA_EMAIL="bot@acme.io"
JIRA_API_TOKEN="jira_test_token"
JIRA_PROJECT_KEY="ENG"
EOF
: > "$P3/BACKLOG.md"
: > "$CURLLOG"
out5="$( cd "$P3" && PATH="$BIN:$PATH" GH_FAKE_LOG="$GHLOG" CURL_FAKE_LOG="$CURLLOG" bash "$HERD" backend switch jira --no-migrate </dev/null 2>&1 )" \
  || fail "file→jira switch exited non-zero: $out5"
grep -q 'SCRIBE_BACKEND="jira"' "$P3/.herd/config" || fail "config was not flipped to jira ($out5)"
grep -q "myself" "$CURLLOG" || fail "jira preflight did not perform the live /myself round-trip"
grep -q "FROZEN ARCHIVE" "$P3/BACKLOG.md" || fail "leaving the file backend must stamp the frozen-archive banner"
pass

# ── Case 5b: file → jira whose round-trip FAILS (bad creds) → loud death, config stays on file ───
P4="$T/proj4"; mkdir -p "$P4/.herd" "$T/trees4"
cat > "$P4/.herd/config" <<EOF
PROJECT_ROOT="$P4"
WORKSPACE_NAME="testws4"
SCRIBE_BACKEND="file"
BACKLOG_FILE="BACKLOG.md"
WORKTREES_DIR="$T/trees4"
EOF
cp "$P3/.herd/secrets" "$P4/.herd/secrets"
: > "$P4/BACKLOG.md"
if ( cd "$P4" && PATH="$BIN:$PATH" GH_FAKE_LOG="$GHLOG" CURL_FAKE_LOG="$CURLLOG" CURL_FAKE_FAIL=1 bash "$HERD" backend switch jira </dev/null ) >/dev/null 2>&1; then
  fail "jira switch whose /myself round-trip fails must die"
fi
grep -q 'SCRIBE_BACKEND="file"' "$P4/.herd/config" || fail "failed jira round-trip must leave the config on file"
pass

# ── Case 6: file → linear with a key present → preflight round-trip (viewer{}) passes via fake curl,
#    config flips, frozen banner stamped. HERD-504 happy path: behavior must be exactly as before.
P5="$T/proj5"; mkdir -p "$P5/.herd" "$T/trees5"
cat > "$P5/.herd/config" <<EOF
PROJECT_ROOT="$P5"
WORKSPACE_NAME="testws5"
SCRIBE_BACKEND="file"
BACKLOG_FILE="BACKLOG.md"
WORKTREES_DIR="$T/trees5"
EOF
cat > "$P5/.herd/secrets" <<'EOF'
LINEAR_API_KEY="lin_test_key"
EOF
: > "$P5/BACKLOG.md"
: > "$CURLLOG"
out6="$( cd "$P5" && PATH="$BIN:$PATH" GH_FAKE_LOG="$GHLOG" CURL_FAKE_LOG="$CURLLOG" bash "$HERD" backend switch linear --no-migrate </dev/null 2>&1 )" \
  || fail "file→linear switch exited non-zero: $out6"
grep -q 'SCRIBE_BACKEND="linear"' "$P5/.herd/config" || fail "config was not flipped to linear ($out6)"
grep -q "viewer" "$CURLLOG" || fail "linear preflight did not perform the live viewer{} round-trip"
grep -q "Linear API reachable" <<<"$out6" || fail "linear success message missing ($out6)"
pass

# ── Case 6b: HERD-504 mutation-prove — the round-trip DOES reach curl but Linear answers with an
#    error body (no id). This is a REAL API-level failure, so the death message must say "API
#    unreachable" and must NEVER say "local exec" (that phrase is reserved for a payload build that
#    never got as far as asking Linear anything).
P6="$T/proj6"; mkdir -p "$P6/.herd" "$T/trees6"
cat > "$P6/.herd/config" <<EOF
PROJECT_ROOT="$P6"
WORKSPACE_NAME="testws6"
SCRIBE_BACKEND="file"
BACKLOG_FILE="BACKLOG.md"
WORKTREES_DIR="$T/trees6"
EOF
cp "$P5/.herd/secrets" "$P6/.herd/secrets"
: > "$P6/BACKLOG.md"
: > "$CURLLOG"
out6b="$( cd "$P6" && PATH="$BIN:$PATH" GH_FAKE_LOG="$GHLOG" CURL_FAKE_LOG="$CURLLOG" CURL_LINEAR_FAIL=1 bash "$HERD" backend switch linear </dev/null 2>&1 )" \
  && fail "linear switch whose viewer round-trip errors must die ($out6b)"
grep -q 'SCRIBE_BACKEND="file"' "$P6/.herd/config" || fail "failed linear round-trip must leave the config on file"
grep -q "API unreachable" <<<"$out6b" || fail "a real API-level failure must say 'API unreachable' ($out6b)"
grep -q "local exec failed" <<<"$out6b" && fail "an API-level failure must NOT be misreported as a local exec failure ($out6b)"
pass

# ── Case 6c: HERD-504 mutation-prove — python3 (the payload-build fork) fails EVERY TIME under this
#    fake, so _linear_gql retries once and then gives up WITHOUT ever invoking curl. This is OUR local
#    exec failing under load, not Linear being down, so the death message must be distinct from case
#    6b's real API failure and curl must never be reached.
P7="$T/proj7"; mkdir -p "$P7/.herd" "$T/trees7"
cat > "$P7/.herd/config" <<EOF
PROJECT_ROOT="$P7"
WORKSPACE_NAME="testws7"
SCRIBE_BACKEND="file"
BACKLOG_FILE="BACKLOG.md"
WORKTREES_DIR="$T/trees7"
EOF
cp "$P5/.herd/secrets" "$P7/.herd/secrets"
: > "$P7/BACKLOG.md"
: > "$CURLLOG"
out6c="$( cd "$P7" && PATH="$BIN:$PATH" GH_FAKE_LOG="$GHLOG" CURL_FAKE_LOG="$CURLLOG" LINEAR_PY_FAIL=1 bash "$HERD" backend switch linear </dev/null 2>&1 )" \
  && fail "linear switch whose payload build fails locally must die ($out6c)"
grep -q 'SCRIBE_BACKEND="file"' "$P7/.herd/config" || fail "failed local-exec preflight must leave the config on file"
grep -q "local exec failed under load" <<<"$out6c" || fail "a local payload-build failure must say so distinctly ($out6c)"
grep -q "API unreachable" <<<"$out6c" && fail "a local exec failure must NOT be misreported as an API failure ($out6c)"
[ -s "$CURLLOG" ] && fail "a local payload-build failure must never reach curl ($out6c)"
pass

echo "ALL PASS ($PASS checks)"
