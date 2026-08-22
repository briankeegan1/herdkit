#!/usr/bin/env bash
# test-grok-wake-proof.sh — hermetic proof for GROK_WAKE_PROOF (HERD-803).
#
# Asserts the three invariants the task requires:
#   1. Default-off / byte-identical: when GROK_WAKE_PROOF is off (or unset) the grok lifecycle
#      functions all return rc 1 (no evidence) so the cksum-delta fallback path is taken — no new
#      side-effects for claude/codex/default-off grok.
#   2. Terminal detection: a grok session absent from active_sessions.json yields "idle" from
#      _herd_grok_session_lifecycle (builder is reapable without double-driving).
#   3. Wake-proof / bounce consumption: a session present in active_sessions.json with an
#      updated_at that advanced past the baseline yields "working" (bounce consumed); one where
#      updated_at did NOT advance yields "idle" (not yet consumed).
#
# Fully hermetic: temp dirs only, NO herdr, NO grok, NO gh, NO network, NO model.
# Run:  bash tests/test-grok-wake-proof.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail(){ echo "FAIL: $1" >&2; exit 1; }; ok(){ pass=$((pass+1)); }

# ── bootstrap: seed a minimal herd git repo so driver.sh sources cleanly ───────────────────────
REPO="$T/repo"
mkdir -p "$REPO/.herd" "$REPO/scripts/herd"
cp "$ROOT/scripts/herd/driver.sh"      "$REPO/scripts/herd/"
cp "$ROOT/scripts/herd/herd-config.sh" "$REPO/scripts/herd/"
git -C "$REPO" init -q
git -C "$REPO" config user.email t@t.t; git -C "$REPO" config user.name t
( cd "$REPO" && git commit -q --allow-empty -m init )
cat > "$REPO/.herd/config" <<EOF
HERD_VERSION=1
WORKSPACE_NAME="test"
PROJECT_ROOT="$REPO"
DEFAULT_BRANCH="origin/main"
BACKLOG_FILE="BACKLOG.md"
SCRIBE_BACKEND="file"
HERD_REPO="owner/repo"
COORDINATOR_CMD="/coordinator"
EOF

# Fake worktrees dir for agent-dir state
WTREES="$T/trees"; mkdir -p "$WTREES"

# source the functions under test (hermetically)
source_driver() {
  PROJECT_ROOT="$REPO" WORKTREES_DIR="$WTREES" WORKSPACE_NAME="test" \
  DEFAULT_BRANCH="origin/main" HERD_SKIP_PREFLIGHT=1 HERD_CONFIG_FILE="$REPO/.herd/config" \
  bash -c ". '$REPO/scripts/herd/herd-config.sh' >/dev/null 2>&1 || true; . '$REPO/scripts/herd/driver.sh'; $1"
}
run_lifecycle() {  # run_lifecycle <slug> <extra-env-assignments>
  local slug="$1"; shift
  eval "PROJECT_ROOT=\"$REPO\" WORKTREES_DIR=\"$WTREES\" WORKSPACE_NAME=\"test\" \
  DEFAULT_BRANCH=\"origin/main\" HERD_SKIP_PREFLIGHT=1 HERD_CONFIG_FILE=\"$REPO/.herd/config\" \
  $@ bash -s <<'EOSH'
. '$REPO/scripts/herd/herd-config.sh' >/dev/null 2>&1 || true
. '$REPO/scripts/herd/driver.sh'
SLUG='$slug'
result=\"\$(_herd_grok_session_lifecycle \"\$SLUG\" 2>/dev/null || true)\"
printf '%s' \"\$result\"
EOSH"
}

# Helper: write a minimal driver file for the slug
write_driver_file() {
  local slug="$1" drv="${2:-grok}"
  local adir="$WTREES/.herd/agents/$slug"
  mkdir -p "$adir"
  printf '%s' "$drv" > "$adir/driver"
}

# Helper: write a minimal active_sessions.json
write_sessions() {  # write_sessions <file> <json-content>
  printf '%s' "$2" > "$1"
}

# Helper: write a grok session id for a slug
write_session_id() {
  local slug="$1" sid="$2"
  local adir="$WTREES/.herd/agents/$slug"
  mkdir -p "$adir"
  printf '%s' "$sid" > "$adir/grok-session-id"
}

# Helper: write a baseline file for a slug
write_baseline() {
  local slug="$1" ts="$2"
  local adir="$WTREES/.herd/agents/$slug"
  mkdir -p "$adir"
  printf '%s' "$ts" > "$adir/grok-updated-at-baseline"
}

# ── 1. Default-off: GROK_WAKE_PROOF unset → _herd_grok_session_lifecycle returns rc 1 ──────────
SLUG="grok-slug-1"; write_driver_file "$SLUG" "grok"
result="$(PROJECT_ROOT="$REPO" WORKTREES_DIR="$WTREES" WORKSPACE_NAME="test" \
  DEFAULT_BRANCH="origin/main" HERD_SKIP_PREFLIGHT=1 HERD_CONFIG_FILE="$REPO/.herd/config" \
  bash -c "
    . '$REPO/scripts/herd/herd-config.sh' >/dev/null 2>&1 || true
    . '$REPO/scripts/herd/driver.sh'
    _herd_grok_session_lifecycle '$SLUG' 2>/dev/null && printf hit || printf miss
  " 2>/dev/null)"
[ "$result" = "miss" ] || fail "default-off: lifecycle should return rc 1 when GROK_WAKE_PROOF unset, got: $result"
ok; echo "PASS (1) default-off: GROK_WAKE_PROOF unset → lifecycle returns rc 1 (no evidence)"

# ── 2. Default-off: GROK_WAKE_PROOF=off → same rc 1 ─────────────────────────────────────────────
result="$(GROK_WAKE_PROOF=off PROJECT_ROOT="$REPO" WORKTREES_DIR="$WTREES" WORKSPACE_NAME="test" \
  DEFAULT_BRANCH="origin/main" HERD_SKIP_PREFLIGHT=1 HERD_CONFIG_FILE="$REPO/.herd/config" \
  bash -c "
    . '$REPO/scripts/herd/herd-config.sh' >/dev/null 2>&1 || true
    . '$REPO/scripts/herd/driver.sh'
    _herd_grok_session_lifecycle '$SLUG' 2>/dev/null && printf hit || printf miss
  " 2>/dev/null)"
[ "$result" = "miss" ] || fail "default-off: lifecycle should return rc 1 when GROK_WAKE_PROOF=off, got: $result"
ok; echo "PASS (2) GROK_WAKE_PROOF=off → lifecycle returns rc 1"

# ── 3. Non-grok driver guard: GROK_WAKE_PROOF=on but driver file says "herdr-claude" → rc 1 ─────
SLUG3="claude-slug-3"; write_driver_file "$SLUG3" "herdr-claude"
write_session_id "$SLUG3" "aaaaaaaa-0000-0000-0000-000000000003"
result="$(GROK_WAKE_PROOF=on PROJECT_ROOT="$REPO" WORKTREES_DIR="$WTREES" WORKSPACE_NAME="test" \
  DEFAULT_BRANCH="origin/main" HERD_SKIP_PREFLIGHT=1 HERD_CONFIG_FILE="$REPO/.herd/config" \
  bash -c "
    . '$REPO/scripts/herd/herd-config.sh' >/dev/null 2>&1 || true
    . '$REPO/scripts/herd/driver.sh'
    _herd_grok_session_lifecycle '$SLUG3' 2>/dev/null && printf hit || printf miss
  " 2>/dev/null)"
[ "$result" = "miss" ] || fail "non-grok driver: lifecycle should return rc 1 for herdr-claude spawn, got: $result"
ok; echo "PASS (3) non-grok spawn driver → lifecycle returns rc 1 (byte-identical for claude/codex)"

# ── 4. Fail-soft: GROK_WAKE_PROOF=on, grok driver, but sessions file missing → rc 1 ─────────────
SLUG4="grok-slug-4"; write_driver_file "$SLUG4" "grok"
write_session_id "$SLUG4" "aaaaaaaa-0000-0000-0000-000000000004"
MISSING_FILE="$T/does-not-exist.json"
result="$(GROK_WAKE_PROOF=on GROK_SESSIONS_FILE="$MISSING_FILE" \
  PROJECT_ROOT="$REPO" WORKTREES_DIR="$WTREES" WORKSPACE_NAME="test" \
  DEFAULT_BRANCH="origin/main" HERD_SKIP_PREFLIGHT=1 HERD_CONFIG_FILE="$REPO/.herd/config" \
  bash -c "
    . '$REPO/scripts/herd/herd-config.sh' >/dev/null 2>&1 || true
    . '$REPO/scripts/herd/driver.sh'
    _herd_grok_session_lifecycle '$SLUG4' 2>/dev/null && printf hit || printf miss
  " 2>/dev/null)"
[ "$result" = "miss" ] || fail "fail-soft: missing sessions file should return rc 1, got: $result"
ok; echo "PASS (4) fail-soft: missing sessions file → rc 1, never abort"

# ── 5. Terminal detection: session absent from active_sessions.json → "idle" ────────────────────
SLUG5="grok-slug-5"
SID5="bbbbbbbb-0000-0000-0000-000000000005"
write_driver_file "$SLUG5" "grok"
write_session_id "$SLUG5" "$SID5"
SESSIONS5="$T/sessions5.json"
# Sessions file exists but contains a DIFFERENT session id (ours is absent → terminal)
write_sessions "$SESSIONS5" '[{"id":"cccccccc-0000-0000-0000-000000000099","status":"running"}]'
result="$(GROK_WAKE_PROOF=on GROK_SESSIONS_FILE="$SESSIONS5" \
  PROJECT_ROOT="$REPO" WORKTREES_DIR="$WTREES" WORKSPACE_NAME="test" \
  DEFAULT_BRANCH="origin/main" HERD_SKIP_PREFLIGHT=1 HERD_CONFIG_FILE="$REPO/.herd/config" \
  bash -c "
    . '$REPO/scripts/herd/herd-config.sh' >/dev/null 2>&1 || true
    . '$REPO/scripts/herd/driver.sh'
    _herd_grok_session_lifecycle '$SLUG5' 2>/dev/null || true
  " 2>/dev/null)"
[ "$result" = "idle" ] || fail "terminal detection: absent session should yield 'idle', got: '$result'"
ok; echo "PASS (5) terminal detection: session absent from active_sessions.json → 'idle' (reapable)"

# ── 6. Terminal detection: empty active_sessions.json → "idle" ───────────────────────────────────
SLUG6="grok-slug-6"
SID6="bbbbbbbb-0000-0000-0000-000000000006"
write_driver_file "$SLUG6" "grok"
write_session_id "$SLUG6" "$SID6"
SESSIONS6="$T/sessions6.json"
write_sessions "$SESSIONS6" '[]'
result="$(GROK_WAKE_PROOF=on GROK_SESSIONS_FILE="$SESSIONS6" \
  PROJECT_ROOT="$REPO" WORKTREES_DIR="$WTREES" WORKSPACE_NAME="test" \
  DEFAULT_BRANCH="origin/main" HERD_SKIP_PREFLIGHT=1 HERD_CONFIG_FILE="$REPO/.herd/config" \
  bash -c "
    . '$REPO/scripts/herd/herd-config.sh' >/dev/null 2>&1 || true
    . '$REPO/scripts/herd/driver.sh'
    _herd_grok_session_lifecycle '$SLUG6' 2>/dev/null || true
  " 2>/dev/null)"
[ "$result" = "idle" ] || fail "terminal: empty sessions array should yield 'idle', got: '$result'"
ok; echo "PASS (6) terminal: empty active_sessions.json → 'idle'"

# ── 7. Wake-proof: session present, no baseline → "idle" (waiting) ───────────────────────────────
SLUG7="grok-slug-7"
SID7="dddddddd-0000-0000-0000-000000000007"
write_driver_file "$SLUG7" "grok"
write_session_id "$SLUG7" "$SID7"
SESSIONS7="$T/sessions7.json"
write_sessions "$SESSIONS7" "[{\"id\":\"$SID7\",\"status\":\"running\"}]"
# No baseline file written → should yield "idle" (blocks cksum path; waiting for bounce)
result="$(GROK_WAKE_PROOF=on GROK_SESSIONS_FILE="$SESSIONS7" \
  PROJECT_ROOT="$REPO" WORKTREES_DIR="$WTREES" WORKSPACE_NAME="test" \
  DEFAULT_BRANCH="origin/main" HERD_SKIP_PREFLIGHT=1 HERD_CONFIG_FILE="$REPO/.herd/config" \
  bash -c "
    . '$REPO/scripts/herd/herd-config.sh' >/dev/null 2>&1 || true
    . '$REPO/scripts/herd/driver.sh'
    _herd_grok_session_lifecycle '$SLUG7' 2>/dev/null || true
  " 2>/dev/null)"
[ "$result" = "idle" ] || fail "no-baseline: session present but no baseline should yield 'idle', got: '$result'"
ok; echo "PASS (7) wake-proof: session present, no baseline → 'idle' (not yet consumed)"

# ── 8-9. Wake-proof: session present + SQLite baseline via seam ──────────────────────────────────
command -v sqlite3 >/dev/null 2>&1 || { echo "SKIP (8-9) sqlite3 not available"; ok; ok
  echo "ALL PASS ($pass checks)"; exit 0; }

SLUG8="grok-slug-8"
SID8="eeeeeeee-0000-0000-0000-000000000008"
write_driver_file "$SLUG8" "grok"
write_session_id "$SLUG8" "$SID8"
SESSIONS8="$T/sessions8.json"
write_sessions "$SESSIONS8" "[{\"id\":\"$SID8\",\"status\":\"running\"}]"

# Seed a fake SQLite DB
DB8="$T/session_search8.sqlite"
sqlite3 "$DB8" "CREATE TABLE session_docs (session_id TEXT PRIMARY KEY, cwd TEXT, updated_at INTEGER, title TEXT, content TEXT, content_hash TEXT);"
sqlite3 "$DB8" "INSERT INTO session_docs VALUES ('$SID8', '/tmp', 1000, 't', 'c', 'h');"
write_baseline "$SLUG8" "1000"

# 8. updated_at NOT advanced past baseline → "idle"
result="$(GROK_WAKE_PROOF=on GROK_SESSIONS_FILE="$SESSIONS8" GROK_SESSION_DB="$DB8" \
  PROJECT_ROOT="$REPO" WORKTREES_DIR="$WTREES" WORKSPACE_NAME="test" \
  DEFAULT_BRANCH="origin/main" HERD_SKIP_PREFLIGHT=1 HERD_CONFIG_FILE="$REPO/.herd/config" \
  bash -c "
    . '$REPO/scripts/herd/herd-config.sh' >/dev/null 2>&1 || true
    . '$REPO/scripts/herd/driver.sh'
    _herd_grok_session_lifecycle '$SLUG8' 2>/dev/null || true
  " 2>/dev/null)"
[ "$result" = "idle" ] || fail "updated_at not advanced: should yield 'idle', got: '$result'"
ok; echo "PASS (8) wake-proof: updated_at == baseline → 'idle' (bounce not yet consumed)"

# 9. updated_at advanced past baseline → "working" (bounce consumed)
sqlite3 "$DB8" "UPDATE session_docs SET updated_at=2000 WHERE session_id='$SID8';"
result="$(GROK_WAKE_PROOF=on GROK_SESSIONS_FILE="$SESSIONS8" GROK_SESSION_DB="$DB8" \
  PROJECT_ROOT="$REPO" WORKTREES_DIR="$WTREES" WORKSPACE_NAME="test" \
  DEFAULT_BRANCH="origin/main" HERD_SKIP_PREFLIGHT=1 HERD_CONFIG_FILE="$REPO/.herd/config" \
  bash -c "
    . '$REPO/scripts/herd/herd-config.sh' >/dev/null 2>&1 || true
    . '$REPO/scripts/herd/driver.sh'
    _herd_grok_session_lifecycle '$SLUG8' 2>/dev/null || true
  " 2>/dev/null)"
[ "$result" = "working" ] || fail "updated_at advanced: should yield 'working', got: '$result'"
ok; echo "PASS (9) wake-proof: updated_at > baseline → 'working' (bounce consumed)"

# ── 10. session_id_write/read roundtrip + baseline_write guards ──────────────────────────────────
# (a) write/read roundtrip: a UUID written by _herd_grok_session_id_write is read back by
#     _herd_grok_session_id with byte-identical content.
SLUG10="grok-slug-10"
TEST_SID="f47ac10b-58cc-4372-a567-0e02b2c3d479"
write_driver_file "$SLUG10" "grok"
rt_val="$(GROK_WAKE_PROOF=on PROJECT_ROOT="$REPO" WORKTREES_DIR="$WTREES" WORKSPACE_NAME="test" \
  DEFAULT_BRANCH="origin/main" HERD_SKIP_PREFLIGHT=1 HERD_CONFIG_FILE="$REPO/.herd/config" \
  bash -c "
    . '$REPO/scripts/herd/herd-config.sh' >/dev/null 2>&1 || true
    . '$REPO/scripts/herd/driver.sh'
    _herd_grok_session_id_write '$SLUG10' '$TEST_SID' 2>/dev/null
    _herd_grok_session_id '$SLUG10' 2>/dev/null || true
  " 2>/dev/null)"
[ "$rt_val" = "$TEST_SID" ] || fail "session_id roundtrip: expected '$TEST_SID', got: '$rt_val'"

# (b) baseline_write guard: GROK_WAKE_PROOF=off → no baseline file written (byte-identical).
command -v sqlite3 >/dev/null 2>&1 && {
  SLUG10b="grok-slug-10b"
  SID10b="f47ac10b-58cc-0000-0000-000000000010"
  write_driver_file "$SLUG10b" "grok"
  write_session_id  "$SLUG10b" "$SID10b"
  DB10="$T/session10.sqlite"
  sqlite3 "$DB10" "CREATE TABLE session_docs (session_id TEXT PRIMARY KEY, cwd TEXT, updated_at INTEGER, title TEXT, content TEXT, content_hash TEXT);"
  sqlite3 "$DB10" "INSERT INTO session_docs VALUES ('$SID10b', '/tmp', 5000, 't', 'c', 'h');"
  ADIR10="$WTREES/.herd/agents/$SLUG10b"
  # GROK_WAKE_PROOF=off → no file written
  GROK_WAKE_PROOF=off GROK_SESSION_DB="$DB10" PROJECT_ROOT="$REPO" WORKTREES_DIR="$WTREES" \
    WORKSPACE_NAME="test" DEFAULT_BRANCH="origin/main" HERD_SKIP_PREFLIGHT=1 \
    HERD_CONFIG_FILE="$REPO/.herd/config" bash -c "
      . '$REPO/scripts/herd/herd-config.sh' >/dev/null 2>&1 || true
      . '$REPO/scripts/herd/driver.sh'
      _herd_grok_updated_at_baseline_write '$SLUG10b' 2>/dev/null
    " 2>/dev/null
  [ ! -f "$ADIR10/grok-updated-at-baseline" ] || fail "baseline_write off: file written when GROK_WAKE_PROOF=off"
  # GROK_WAKE_PROOF=on, wrong driver → no file written
  SLUG10c="grok-slug-10c"; write_driver_file "$SLUG10c" "herdr-claude"
  write_session_id "$SLUG10c" "$SID10b"
  ADIR10c="$WTREES/.herd/agents/$SLUG10c"
  GROK_WAKE_PROOF=on GROK_SESSION_DB="$DB10" PROJECT_ROOT="$REPO" WORKTREES_DIR="$WTREES" \
    WORKSPACE_NAME="test" DEFAULT_BRANCH="origin/main" HERD_SKIP_PREFLIGHT=1 \
    HERD_CONFIG_FILE="$REPO/.herd/config" bash -c "
      . '$REPO/scripts/herd/herd-config.sh' >/dev/null 2>&1 || true
      . '$REPO/scripts/herd/driver.sh'
      _herd_grok_updated_at_baseline_write '$SLUG10c' 2>/dev/null
    " 2>/dev/null
  [ ! -f "$ADIR10c/grok-updated-at-baseline" ] || fail "baseline_write guard: file written for non-grok spawn driver"
  # GROK_WAKE_PROOF=on, grok driver, sqlite present → baseline file written
  GROK_WAKE_PROOF=on GROK_SESSION_DB="$DB10" PROJECT_ROOT="$REPO" WORKTREES_DIR="$WTREES" \
    WORKSPACE_NAME="test" DEFAULT_BRANCH="origin/main" HERD_SKIP_PREFLIGHT=1 \
    HERD_CONFIG_FILE="$REPO/.herd/config" bash -c "
      . '$REPO/scripts/herd/herd-config.sh' >/dev/null 2>&1 || true
      . '$REPO/scripts/herd/driver.sh'
      _herd_grok_updated_at_baseline_write '$SLUG10b' 2>/dev/null
    " 2>/dev/null
  [ -f "$ADIR10/grok-updated-at-baseline" ] || fail "baseline_write on/grok: file not written when conditions met"
  baseline_val="$(cat "$ADIR10/grok-updated-at-baseline" 2>/dev/null || true)"
  [ "$baseline_val" = "5000" ] || fail "baseline_write: expected updated_at=5000, got: '$baseline_val'"
}
ok; echo "PASS (10) session_id roundtrip; baseline_write: off→no-op; wrong-driver→no-op; on+grok→writes baseline"

echo "ALL PASS ($pass checks)"
