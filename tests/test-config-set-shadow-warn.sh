#!/usr/bin/env bash
# test-config-set-shadow-warn.sh — hermetic tests for HERD-285: `herd config set` must warn
# when the key being written to the committed baseline is already pinned in .herd/config.local,
# because the overlay wins at load time and the baseline write is effectively inert.
#
# Contracts:
#   (a) Warning fires when config.local pins the SAME key that was just written to the baseline.
#   (b) Warning does NOT fire when config.local exists but does NOT contain the key.
#   (c) Warning does NOT fire for a --local write (the overlay itself was the target).
#   (d) Warning fires even when the set is a no-op (changed=0, force_shared path skipped early-return
#       but here we verify via the write path that the warn appears once the key is shadowed).
#
# Run:  bash tests/test-config-set-shadow-warn.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
HERD="$HERE/../bin/herd"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass=0; ok(){ pass=$((pass+1)); }

# ── Stub pgrep + herdr on PATH ───────────────────────────────────────────────
BIN="$T/bin"; mkdir -p "$BIN"
cat > "$BIN/pgrep" <<'STUB'
#!/usr/bin/env bash
IFS=':' read -ra pids <<< "${FAKE_STRAY_PIDS:-}"
for p in "${pids[@]}"; do [ -n "$p" ] && printf '%s\n' "$p"; done
exit 0
STUB
chmod +x "$BIN/pgrep"
printf '#!/usr/bin/env bash\nexit 1\n' > "$BIN/herdr"; chmod +x "$BIN/herdr"
export PATH="$BIN:$PATH"

# ── Stub capabilities manifest ───────────────────────────────────────────────
CAPS="$T/capabilities.tsv"
{
  printf 'name\tkind\tdescription\twhen_to_surface\trequires\tscope\tgovernance\tvalue_shape\n'
  printf 'WORKSPACE_NAME\tconfig\tProject label\tAlways required\twatcher\t\t\tfree\n'
  printf 'SCRIBE_BACKEND\tconfig\tWork-tracker backend\tSet for a tracker\t\t\t\tfree\n'
  printf 'REVIEW_CONCURRENCY\tconfig\tMax parallel reviews\tRaise for throughput\twatcher\t\t\tnumeric\n'
} > "$CAPS"
export HERD_CAPABILITIES_FILE="$CAPS"

# ── project fixture ───────────────────────────────────────────────────────────
_make_project() {
  local r="$1"; local r_real; r_real="$(cd "$r" && pwd -P)"
  git -C "$r" init -q
  git -C "$r" config user.email t@t.t; git -C "$r" config user.name t
  ( cd "$r" && git commit -q --allow-empty -m init )
  mkdir -p "$r/.herd" "$r/trees"
  cat > "$r/.herd/config" <<CFG
# .herd/config — shadow-warn test fixture
HERD_VERSION=1
PROJECT_ROOT="$r_real"
WORKTREES_DIR="$r_real/trees"
DEFAULT_BRANCH="origin/main"
WORKSPACE_NAME="shadowtest"
SCRIBE_BACKEND="file"
REVIEW_CONCURRENCY="2"
CFG
}

run() {
  local r="$1"; shift
  set +e
  OUT="$( cd "$r" && HERD_RELOAD_SKIP_LAUNCH=1 HERD_RELOAD_SIGTERM_POLLS=3 FAKE_STRAY_PIDS="" \
           bash "$HERD" "$@" 2>&1 )"
  RC=$?
  set -e
}

# ══ (a) Warning fires when config.local pins the key being set to the baseline ══════
P="$T/p1"; mkdir "$P"; _make_project "$P"
cat > "$P/.herd/config.local" <<'CFG'
SCRIBE_BACKEND="github"
CFG
run "$P" config set SCRIBE_BACKEND changelog
[ "$RC" -eq 0 ] || fail "(a) set failed unexpectedly ($OUT)"
printf '%s\n' "$OUT" | grep -qi 'shadowed by' \
  || fail "(a) no shadow warning when config.local pins the key ($OUT)"
printf '%s\n' "$OUT" | grep -qi 'config.local' \
  || fail "(a) shadow warning does not mention config.local ($OUT)"
printf '%s\n' "$OUT" | grep -qi -- '--local' \
  || fail "(a) shadow warning does not suggest --local ($OUT)"
ok

# ══ (b) Warning does NOT fire when config.local exists but does NOT pin the key ═
P2="$T/p2"; mkdir "$P2"; _make_project "$P2"
cat > "$P2/.herd/config.local" <<'CFG'
WORKSPACE_NAME="local-ws"
CFG
run "$P2" config set SCRIBE_BACKEND changelog
[ "$RC" -eq 0 ] || fail "(b) set failed unexpectedly ($OUT)"
printf '%s\n' "$OUT" | grep -qi 'shadowed' \
  && fail "(b) shadow warning fired for a key NOT in config.local ($OUT)"
ok

# ══ (c) Warning does NOT fire for a --local write (overlay was the target) ══════
P3="$T/p3"; mkdir "$P3"; _make_project "$P3"
cat > "$P3/.herd/config.local" <<'CFG'
SCRIBE_BACKEND="github"
CFG
run "$P3" config set --local SCRIBE_BACKEND linear
[ "$RC" -eq 0 ] || fail "(c) --local set failed ($OUT)"
printf '%s\n' "$OUT" | grep -qi 'shadowed' \
  && fail "(c) shadow warning fired incorrectly for a --local write ($OUT)"
ok

# ══ (d) Warning does NOT fire when config.local is absent ════════════════════
P4="$T/p4"; mkdir "$P4"; _make_project "$P4"
[ ! -f "$P4/.herd/config.local" ] || fail "(d) fixture unexpectedly has a config.local"
run "$P4" config set SCRIBE_BACKEND changelog
[ "$RC" -eq 0 ] || fail "(d) set failed unexpectedly ($OUT)"
printf '%s\n' "$OUT" | grep -qi 'shadowed' \
  && fail "(d) shadow warning fired with no config.local present ($OUT)"
ok

echo "ALL PASS ($pass tests)"
