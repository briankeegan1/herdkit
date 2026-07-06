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
#      config still says github; unauthenticated gh dies the same way from file.
#   4. unknown backend name dies before any change.
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
  "issue list")   printf '[]' ;;
  "issue create") exit 0 ;;
esac
exit 0
FAKE
chmod +x "$BIN/gh"

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

run_switch(){ ( cd "$P" && PATH="$BIN:$PATH" GH_FAKE_LOG="$GHLOG" "$@" bash "$HERD" backend switch "${ARGS[@]}" </dev/null 2>&1 ); }

# ── Case 1: file → github --migrate ─────────────────────────────────────────────────────────────
: > "$GHLOG"
ARGS=(github --migrate)
out="$(run_switch)" || fail "file→github switch exited non-zero: $out"
grep -q 'SCRIBE_BACKEND="github"' "$P/.herd/config" || fail "config was not flipped to github"
grep -q "issue create" "$GHLOG" || fail "migration did not create issues via gh"
grep -q "wiring the feedback loop (migrated from file)" "$GHLOG" || fail "🚧 item not migrated with provenance suffix ($(cat "$GHLOG"))"
grep -q "add a dark-mode toggle (migrated from file)" "$GHLOG" || fail "🔜 item not migrated with provenance suffix"
grep -q "already done" "$GHLOG" && fail "✅ shipped item must NOT be migrated"
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

# ── Case 4: unknown backend dies before any change ──────────────────────────────────────────────
ARGS=(jira)
if run_switch >/dev/null; then fail "unknown backend must die"; fi
grep -q 'SCRIBE_BACKEND="github"' "$P/.herd/config" || fail "unknown-backend attempt must not touch the config"
pass

echo "ALL PASS ($PASS checks)"
