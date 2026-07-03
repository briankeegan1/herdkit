#!/usr/bin/env bash
# test-upgrade-migrations.sh — hermetic test of `herd upgrade`'s versioned migration runner
# (bin/herd: run_migrations + cmd_upgrade). No network, no claude, no herdr. Verifies:
#   1. the SHIPPED example migration (migrations/v1-to-v2.sh) transforms a pre-MERGE_POLICY v1 config
#      to v2 — adding MERGE_POLICY from legacy WATCHER_AUTOMERGE — while PRESERVING custom keys;
#   2. re-running the upgrade at the current version is a safe no-op (no dup keys, no re-mutation);
#   3. multiple pending migrations run in ASCENDING order, exactly once (v1→v3 = v1-to-v2 then v2-to-v3);
#   4. it is a no-op when the project is already at the target version (no migration runs);
#   5. it is rollback-safe: a failing migration restores the config and leaves HERD_VERSION un-bumped.
# Run:  bash tests/test-upgrade-migrations.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
HERD="$HERE/../bin/herd"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail(){ echo "FAIL: $1" >&2; exit 1; }

# mkproj <dir> <config-body> — stand up a temp project with a .herd/config.
mkproj() {
  local dir="$1" body="$2"
  mkdir -p "$dir/.herd"
  printf '%s\n' "$body" > "$dir/.herd/config"
}

# cfgval <cfg> <KEY> — first value assigned to KEY (one layer of quotes stripped); '' when unset.
cfgval() {
  awk -v k="$2" '
    { line=$0; sub(/^[[:space:]]+/,"",line) }
    index(line, k "=")==1 { v=substr(line,length(k)+2); if (v ~ /^".*"$/) v=substr(v,2,length(v)-2); print v; exit }' "$1"
}
# count_key <cfg> <KEY> — how many assignment lines exist for KEY (must stay 1 across idempotent runs).
count_key() { grep -cE "^[[:space:]]*$2=" "$1" || true; }

# ── 1. Shipped migration: pre-MERGE_POLICY v1 config → v2, custom keys preserved ────────────────
P1="$T/proj-real"
mkproj "$P1" 'PROJECT_ROOT="'"$P1"'"
WORKSPACE_NAME="realproj"
WATCHER_AUTOMERGE="false"
MY_CUSTOM_KEY="keep-me"
HERD_VERSION=1'
( cd "$P1" && HERD_TARGET_VERSION=2 bash "$HERD" upgrade >/dev/null ) || fail "upgrade to v2 failed"
[ "$(cfgval "$P1/.herd/config" HERD_VERSION)"     = "2" ]        || fail "HERD_VERSION not bumped to 2"
[ "$(cfgval "$P1/.herd/config" MERGE_POLICY)"     = "observe" ] || fail "MERGE_POLICY not derived from WATCHER_AUTOMERGE=false (got '$(cfgval "$P1/.herd/config" MERGE_POLICY)')"
[ "$(cfgval "$P1/.herd/config" WATCHER_AUTOMERGE)" = "false" ]  || fail "migration clobbered legacy WATCHER_AUTOMERGE"
[ "$(cfgval "$P1/.herd/config" MY_CUSTOM_KEY)"     = "keep-me" ] || fail "migration clobbered a custom key"

# ── 2. Idempotent re-run at the current version is a safe no-op ──────────────────────────────────
out2="$( cd "$P1" && HERD_TARGET_VERSION=2 bash "$HERD" upgrade 2>&1 )" || fail "idempotent re-run failed"
echo "$out2" | grep -q "no pending migrations" || fail "re-run at current version should report no pending migrations"
[ "$(count_key "$P1/.herd/config" MERGE_POLICY)" -eq 1 ]         || fail "re-run duplicated MERGE_POLICY"
[ "$(cfgval "$P1/.herd/config" MERGE_POLICY)"     = "observe" ] || fail "re-run altered MERGE_POLICY"
[ "$(cfgval "$P1/.herd/config" HERD_VERSION)"     = "2" ]        || fail "re-run altered HERD_VERSION"

# ── 3. Ordering: multiple pending migrations run in ascending order, exactly once ────────────────
# Stub a migrations dir with two steps; each appends its tag to a MIG_TRACE key using the exported
# helpers (proving both ordering AND that the runner provides _config_file_value / _config_put_value).
MIGDIR="$T/migs"; mkdir -p "$MIGDIR"
for step in v1-to-v2 v2-to-v3; do
  cat > "$MIGDIR/$step.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
_config_put_value "\$HERD_CONFIG" MIG_TRACE "\$(_config_file_value "\$HERD_CONFIG" MIG_TRACE)$step;"
EOF
done
P3="$T/proj-order"
mkproj "$P3" 'WORKSPACE_NAME="orderproj"
HERD_VERSION=1'
( cd "$P3" && HERD_MIGRATIONS_DIR="$MIGDIR" HERD_TARGET_VERSION=3 bash "$HERD" upgrade >/dev/null ) || fail "multi-step upgrade failed"
[ "$(cfgval "$P3/.herd/config" MIG_TRACE)"   = "v1-to-v2;v2-to-v3;" ] || fail "migrations ran out of order or repeated (trace='$(cfgval "$P3/.herd/config" MIG_TRACE)')"
[ "$(cfgval "$P3/.herd/config" HERD_VERSION)" = "3" ]                 || fail "HERD_VERSION not bumped to 3 after chain"

# ── 4. No-op when already current: already at target, no migration side effects ──────────────────
P4="$T/proj-current"
mkproj "$P4" 'WORKSPACE_NAME="curproj"
HERD_VERSION=3'
out4="$( cd "$P4" && HERD_MIGRATIONS_DIR="$MIGDIR" HERD_TARGET_VERSION=3 bash "$HERD" upgrade 2>&1 )" || fail "no-op upgrade failed"
echo "$out4" | grep -q "no pending migrations" || fail "already-current upgrade should report no pending migrations"
[ -z "$(cfgval "$P4/.herd/config" MIG_TRACE)" ] || fail "already-current upgrade ran a migration (trace set)"

# ── 5. Rollback-safe: a failing migration restores the config and leaves HERD_VERSION un-bumped ──
BADDIR="$T/bad"; mkdir -p "$BADDIR"
# First step succeeds (writes a key), second step fails — the runner must restore the ORIGINAL config.
cat > "$BADDIR/v1-to-v2.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
_config_put_value "$HERD_CONFIG" STEP1_RAN "yes"
EOF
cat > "$BADDIR/v2-to-v3.sh" <<'EOF'
#!/usr/bin/env bash
echo "v2-to-v3: unresolvable conflict" >&2
exit 1
EOF
P5="$T/proj-rollback"
mkproj "$P5" 'WORKSPACE_NAME="rbproj"
KEEP="original"
HERD_VERSION=1'
before="$(cat "$P5/.herd/config")"
if ( cd "$P5" && HERD_MIGRATIONS_DIR="$BADDIR" HERD_TARGET_VERSION=3 bash "$HERD" upgrade >/dev/null 2>&1 ); then
  fail "upgrade with a failing migration should exit non-zero"
fi
[ "$(cat "$P5/.herd/config")" = "$before" ] || fail "failed migration did not restore the original config"
[ "$(cfgval "$P5/.herd/config" HERD_VERSION)" = "1" ] || fail "failed migration bumped HERD_VERSION anyway"
[ -z "$(cfgval "$P5/.herd/config" STEP1_RAN)" ]       || fail "failed migration left step-1's partial edit behind"

echo "ALL PASS"
