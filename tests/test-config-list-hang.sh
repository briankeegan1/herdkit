#!/usr/bin/env bash
# test-config-list-hang.sh — regression test for the Windows `herd config list` HANG (HERD-47
# provenance regression). The pre-fix cmd_config_list ran a per-key loop that forked ~5 short-lived
# subprocesses per key (printf|grep, sed, an overlay grep, an awk value-read, and _config_secret_key);
# on Git-bash for Windows that fork storm deadlocks/stalls so `herd config list` printed only the first
# handful of keys and never finished. The fix resolves value + provenance in a SINGLE awk pass.
#
# This test pins the three things the fix must keep true, hermetically (no herdr/gh/network/model,
# no capabilities manifest — `config list` reads only .herd/config and .herd/config.local):
#   1. COMPLETION: `herd config list` exits 0 and prints EVERY key (the buggy version printed ~10
#      then hung). A large fixture makes "prints all of them" a meaningful completion assertion.
#   2. PROVENANCE + values: baseline, override->local, local-only, all exact.
#   3. MASKED secrets: secret-shaped keys are masked ******** in BOTH baseline and overlay context.
#   4. DETERMINISTIC / no-TTY: output is captured (no tty ⇒ no color) and byte-identical across runs.
# Run:  bash tests/test-config-list-hang.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
HERD="$HERE/../bin/herd"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass=0; okp(){ pass=$((pass+1)); }

# run <ROOT> <args...> → `herd <args>` in ROOT; combined output → $OUT, exit → $RC. Output is
# captured (stdout is NOT a tty here), so this also exercises the deterministic/no-color path.
run() {
  local r="$1"; shift
  set +e
  OUT="$( cd "$r" && bash "$HERD" "$@" 2>&1 )"
  RC=$?
  set -e
}

# ── Fixture: a baseline with MANY keys (so "printed all of them" is a real completion check),
#    including two secret-shaped keys (masked in [baseline] context). ──────────────────────────────
P="$T/proj"; mkdir -p "$P/.herd"
{
  echo '# baseline fixture'
  echo 'HERD_VERSION=1'
  echo 'WORKSPACE_NAME="baselinews"'
  echo 'SCRIBE_BACKEND="file"'
  echo 'MODEL_QUICK="claude-baseline"'
  echo 'MY_API_TOKEN="raw-token-value"'   # secret-shaped (*TOKEN*) → masked
  echo 'DEPLOY_KEY="raw-key-value"'       # secret-shaped (*_KEY)   → masked
  # Bulk keys K00..K59 to make the loop long enough that a per-key fork storm would stall.
  for i in $(seq 0 59); do printf 'K%02d="v%02d"\n' "$i" "$i"; done
} > "$P/.herd/config"
TOTAL_KEYS="$(grep -cE '^[A-Za-z_][A-Za-z0-9_]*=' "$P/.herd/config")"

# ══════════════════════════════════════════════════════════════════════════════
# 1. COMPLETION — no overlay: exits 0 and prints EVERY key (buggy version hung after ~10).
# ══════════════════════════════════════════════════════════════════════════════
run "$P" config list
[ "$RC" -eq 0 ] || fail "(1) config list did not exit 0 (rc=$RC) — hang/regression? OUT:
$OUT"
# One printed row per key (rows are the indented '  KEY  value  [src]' lines; header has no leading space).
rows="$(printf '%s\n' "$OUT" | grep -cE '^\s+[A-Za-z_][A-Za-z0-9_]*\s')"
[ "$rows" -eq "$TOTAL_KEYS" ] || fail "(1) printed $rows rows, expected all $TOTAL_KEYS keys — truncated/hung? OUT:
$OUT"
# Spot-check first and LAST key both present (a truncating hang would drop the tail).
printf '%s\n' "$OUT" | grep -qE 'HERD_VERSION[[:space:]]+1[[:space:]]+\[baseline\]' || fail "(1) first key missing"
printf '%s\n' "$OUT" | grep -qE 'K59[[:space:]]+v59[[:space:]]+\[baseline\]'        || fail "(1) LAST key missing — output was truncated"
okp

# ── 2. Masked secrets in baseline context ─────────────────────────────────────
printf '%s\n' "$OUT" | grep -qE 'MY_API_TOKEN[[:space:]]+\*{8}[[:space:]]+\[baseline\]' \
  || fail "(2) secret-shaped MY_API_TOKEN not masked in baseline ($OUT)"
printf '%s\n' "$OUT" | grep -qE 'DEPLOY_KEY[[:space:]]+\*{8}[[:space:]]+\[baseline\]' \
  || fail "(2) secret-shaped DEPLOY_KEY not masked in baseline ($OUT)"
printf '%s\n' "$OUT" | grep -q 'raw-token-value' && fail "(2) raw secret value leaked into output"
okp

# ══════════════════════════════════════════════════════════════════════════════
# 3. PROVENANCE with an overlay — baseline / override->local / local-only / masked local secret.
# ══════════════════════════════════════════════════════════════════════════════
cat > "$P/.herd/config.local" <<'CFG'
# overlay
SCRIBE_BACKEND="github"
MY_LOCAL_ONLY="hello"
OVERLAY_PASSWORD="s3kret"
CFG
run "$P" config list
[ "$RC" -eq 0 ] || fail "(3) config list with overlay did not exit 0 (rc=$RC): $OUT"
# Header notes the overlay.
printf '%s\n' "$OUT" | grep -q 'config.local overlay' || fail "(3) header did not note the overlay ($OUT)"
# A baseline-only key stays [baseline].
printf '%s\n' "$OUT" | grep -qE 'WORKSPACE_NAME[[:space:]]+baselinews[[:space:]]+\[baseline\]' \
  || fail "(3) baseline key lost [baseline] provenance ($OUT)"
# An overridden key shows the LOCAL value tagged [local].
printf '%s\n' "$OUT" | grep -qE 'SCRIBE_BACKEND[[:space:]]+github[[:space:]]+\[local\]' \
  || fail "(3) override did not show [local]/local value ($OUT)"
# A key present ONLY in the overlay is [local-only].
printf '%s\n' "$OUT" | grep -qE 'MY_LOCAL_ONLY[[:space:]]+hello[[:space:]]+\[local-only\]' \
  || fail "(3) local-only key missing [local-only] provenance ($OUT)"
# A secret-shaped local-only key is masked.
printf '%s\n' "$OUT" | grep -qE 'OVERLAY_PASSWORD[[:space:]]+\*{8}[[:space:]]+\[local-only\]' \
  || fail "(3) secret-shaped local-only key not masked ($OUT)"
printf '%s\n' "$OUT" | grep -q 's3kret' && fail "(3) raw overlay secret leaked into output"
# Baseline order is still respected AND all baseline keys plus the one local-only key are present.
printf '%s\n' "$OUT" | grep -qE 'K59[[:space:]]+v59[[:space:]]+\[baseline\]' || fail "(3) tail key missing with overlay"
okp

# ══════════════════════════════════════════════════════════════════════════════
# 4. DETERMINISTIC — two identical invocations produce byte-identical output.
# ══════════════════════════════════════════════════════════════════════════════
run "$P" config list; a="$OUT"
run "$P" config list; b="$OUT"
[ "$a" = "$b" ] || fail "(4) config list output not deterministic across runs"
okp

echo "ALL PASS ($pass tests)"
