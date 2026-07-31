#!/usr/bin/env bash
# test-config-env-precedence.sh — hermetic tests for HERD-465: the FILE is authoritative for
# engine-core config keys, never an inherited/stale exported value from a parent shell or a
# WATCHER_SELF_RESTART re-exec.
#
# GROUNDED 2026-07-31: HERD-449/PR #565 correctly `export`s the engine-core keys (MERGE_POLICY,
# HEALTH_CONCURRENCY, HUMAN_VERIFY_POLICY, …) so the Python engine core sees them — but
# herd-config.sh resolved every one of them with the set-if-unset idiom `: "${KEY:=default}"`. An
# INHERITED exported value already counts as "set", so it won an re-exec chain (WATCHER_SELF_RESTART,
# HERD-251, `exec`s in place and keeps the whole environment) over what the project's config file
# said the moment that file changed after first launch: an operator flipped HUMAN_VERIFY_POLICY=auto
# at 14:45; a re-exec-chain watcher still resolved coordinator at 15:12 and applied a hold that
# policy made impossible.
#
# THE FIX (scripts/herd/herd-config.sh): before sourcing baseline + config.local, unset every key in
# _HERD_ENGINE_CORE_KEYS — the SAME list the export block below uses, so the two halves can never
# drift apart — whenever there is a real project config (the resolved HERD_CONFIG_FILE, or its
# config.local sibling) to be authoritative over. When NEITHER exists there is nothing to be
# authoritative over, so the reset is skipped: this preserves the hermetic test/sim seam
# (scripts/herd/sim/sandbox-*-scenario.sh, many tests/test-*.sh) that points HERD_CONFIG_FILE at a
# deliberately absent path and pre-exports these very keys to drive a scenario with no config file on
# disk at all. HERD_CONFIG_ENV_OK=1 is an explicit escape hatch for a caller that needs its
# pre-exported value to win even against a real file.
#
# Proves:
#   (1) A real file's explicit assignment wins over a stale inherited exported value (the headline
#       fix — MERGE_POLICY).
#   (2) A real file that stays SILENT on a key falls to herd-config.sh's own engine default, never an
#       inherited stale value (the actual live-incident shape — HUMAN_VERIFY_POLICY).
#   (3) config.local alone (no baseline) is also "a real project config" — the reset still applies.
#   (4) THE SIM/TEST SEAM: HERD_CONFIG_FILE pointing at a path that exists nowhere on disk is
#       byte-identical to before this fix — pre-exported env always wins, no reset.
#   (5) HERD_CONFIG_ENV_OK=1 skips the reset even against a real file.
#   (6) MUTATION-PROVE: a temp copy of herd-config.sh with the reset block stripped out reproduces
#       the ORIGINAL bug (stale env beats the file's silence) — proving the reset is what fixes it,
#       not something incidental.
#   (7) THE EXACT LIVE SCENARIO: a real `exec` re-launch (the literal WATCHER_SELF_RESTART shape —
#       same process image, full inherited env) picks up a config-file edit made between the two
#       launches.
#   (8) DRIFT GUARD: every _HERD_ENGINE_CORE_KEYS member is one of the literal names
#       scripts/herd/hermetic-env-scrub.sh's text scanner finds exported in herd-config.sh — the
#       reset list and the export list can never silently diverge.
#
# Fully hermetic: temp dirs only, no network/model/herdr/gh. Run:  bash tests/test-config-env-precedence.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LOADER="$ROOT/scripts/herd/herd-config.sh"

[ -f "$LOADER" ] || { echo "FAIL: missing loader: $LOADER" >&2; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { PASS=$((PASS+1)); }

# make_project <dir> [extra-config-lines...] — a minimal real .herd/config
make_project() {
  local d="$1"; shift
  mkdir -p "$d/.herd"
  {
    printf 'PROJECT_ROOT="%s"\n' "$d"
    printf 'WORKSPACE_NAME="precedence-fixture"\n'
    local line; for line in "$@"; do printf '%s\n' "$line"; done
  } > "$d/.herd/config"
}

# ── (1) real file's explicit assignment beats a stale inherited exported value ──────────────────────
P1="$T/p1"; make_project "$P1" 'MERGE_POLICY="auto"'
out="$(
  HERD_CONFIG_FILE="$P1/.herd/config" MERGE_POLICY="observe" \
    bash -c '. "$1" >/dev/null 2>&1; echo "$MERGE_POLICY"' _ "$LOADER"
)"
[ "$out" = "auto" ] || fail "(1) file's MERGE_POLICY=auto did not beat stale env MERGE_POLICY=observe (got: $out)"
pass
echo "PASS (1) a real file's explicit assignment overrides a stale inherited exported value"

# ── (2) a real file SILENT on a key falls to the engine default, not the stale inherited value ──────
# This is the exact live-incident shape: the project never mentions HUMAN_VERIFY_POLICY at all.
P2="$T/p2"; make_project "$P2"
out="$(
  HERD_CONFIG_FILE="$P2/.herd/config" HUMAN_VERIFY_POLICY="coordinator" \
    bash -c '. "$1" >/dev/null 2>&1; echo "$HUMAN_VERIFY_POLICY"' _ "$LOADER"
)"
[ "$out" = "hold" ] || fail "(2) a file silent on HUMAN_VERIFY_POLICY did not fall to the engine default 'hold' (got: $out, stale env was 'coordinator')"
pass
echo "PASS (2) a file silent on a key falls to herd-config.sh's own default, never a stale inherited value"

# ── (3) config.local ALONE (no baseline) also counts as a real project config ───────────────────────
P3="$T/p3"; mkdir -p "$P3/.herd"
printf 'HEALTH_CONCURRENCY="4"\n' > "$P3/.herd/config.local"
out="$(
  HERD_CONFIG_FILE="$P3/.herd/config" HEALTH_CONCURRENCY="99" HUMAN_VERIFY_POLICY="coordinator" \
    bash -c '. "$1" >/dev/null 2>&1; echo "$HEALTH_CONCURRENCY $HUMAN_VERIFY_POLICY"' _ "$LOADER"
)"
[ "$out" = "4 hold" ] || fail "(3) a config.local-only project did not reset engine-core keys (got: $out)"
pass
echo "PASS (3) config.local alone (no committed baseline) is a real project config — reset still applies"

# ── (4) THE SIM/TEST SEAM: no config file anywhere → pre-exported env is untouched ──────────────────
out="$(
  HERD_CONFIG_FILE="$T/no-such-config" MERGE_POLICY="auto" HEALTH_CONCURRENCY="1" INFRA_BREAKER_MAX="3" \
    bash -c '. "$1" >/dev/null 2>&1; echo "$MERGE_POLICY $HEALTH_CONCURRENCY $INFRA_BREAKER_MAX"' _ "$LOADER"
)"
[ "$out" = "auto 1 3" ] || fail "(4) a nonexistent config file must leave pre-exported engine-core env untouched — the sim/test seam (got: $out)"
pass
echo "PASS (4) the hermetic sim/test seam (HERD_CONFIG_FILE pointing nowhere) is byte-identical: env always wins"

# ── (5) HERD_CONFIG_ENV_OK=1 skips the reset even against a real file ───────────────────────────────
P5="$T/p5"; make_project "$P5"
out="$(
  HERD_CONFIG_FILE="$P5/.herd/config" HERD_CONFIG_ENV_OK=1 HUMAN_VERIFY_POLICY="coordinator" \
    bash -c '. "$1" >/dev/null 2>&1; echo "$HUMAN_VERIFY_POLICY"' _ "$LOADER"
)"
[ "$out" = "coordinator" ] || fail "(5) HERD_CONFIG_ENV_OK=1 did not preserve the pre-exported value against a real file (got: $out)"
pass
echo "PASS (5) HERD_CONFIG_ENV_OK=1 is an explicit escape hatch that skips the reset"

# ── (6) MUTATION-PROVE: stripping the reset block reproduces the ORIGINAL bug ───────────────────────
MUT="$T/mutated-herd-config.sh"
python3 - "$LOADER" "$MUT" <<'PYEOF'
import re, sys
src_path, dst_path = sys.argv[1], sys.argv[2]
src = open(src_path, encoding="utf-8").read()
start_marker = "# ── Engine-core key RESET (HERD-465)"
end_marker = "esac\n\nif [ -f \"$_HERD_CONFIG_FILE\" ]; then"
start = src.index(start_marker)
end = src.index(end_marker, start)
# Keep the `if [ -f ... ]; then` that follows — drop only the reset block above it.
mutated = src[:start] + src[end + len("esac\n\n"):]
if mutated == src:
    sys.exit("mutation anchor not found — herd-config.sh's reset block changed shape")
open(dst_path, "w", encoding="utf-8").write(mutated)
PYEOF
[ $? -eq 0 ] || fail "(6) mutation setup failed — see stderr above"
bash -n "$MUT" || fail "(6) mutated herd-config.sh has a syntax error"
out="$(
  HERD_CONFIG_FILE="$P2/.herd/config" HUMAN_VERIFY_POLICY="coordinator" \
    bash -c '. "$1" >/dev/null 2>&1; echo "$HUMAN_VERIFY_POLICY"' _ "$MUT"
)"
[ "$out" = "coordinator" ] || fail "(6) mutation-prove: removing the reset block should REPRODUCE the original bug (stale env beats the file's silence), but got: $out"
pass
echo "PASS (6) mutation-prove: without the reset block, a stale inherited value silently beats the file again — proving the reset is what fixes it"

# ── (7) THE EXACT LIVE SCENARIO: a real re-exec picks up a config-file edit made in between ─────────
# Models WATCHER_SELF_RESTART (HERD-251) precisely: `exec` replaces the process image but keeps the
# FULL inherited environment, including every engine-core key the FIRST launch already exported. A
# config-file edit landing between the two launches must be visible to the re-exec'd process.
P7="$T/p7"; make_project "$P7" 'HUMAN_VERIFY_POLICY="coordinator"'
REEXEC_SCRIPT="$T/reexec.sh"
cat > "$REEXEC_SCRIPT" <<SCRIPT
#!/usr/bin/env bash
set -uo pipefail
if [ -z "\${_REEXEC_STAGE2:-}" ]; then
  # Stage 1: the "first launch" — resolves HUMAN_VERIFY_POLICY=coordinator from the file and (per
  # herd-config.sh's export list) exports it, exactly like the live watcher does at startup.
  . "$LOADER" >/dev/null 2>&1
  export HUMAN_VERIFY_POLICY
  [ "\$HUMAN_VERIFY_POLICY" = "coordinator" ] || { echo "STAGE1_WRONG:\$HUMAN_VERIFY_POLICY"; exit 1; }
  # The operator edits the config file HERE, after stage 1 already resolved+exported the old value —
  # exactly the 14:45-edit-vs-15:12-re-exec timeline from the incident.
  printf 'HUMAN_VERIFY_POLICY="auto"\n' >> "$P7/.herd/config"
  export _REEXEC_STAGE2=1
  exec bash "$REEXEC_SCRIPT"
fi
# Stage 2: the re-exec'd process — same pid, full inherited env (including the stale
# HUMAN_VERIFY_POLICY=coordinator export from stage 1), sourcing herd-config.sh again exactly as a
# self-restarted watcher does.
. "$LOADER" >/dev/null 2>&1
echo "\$HUMAN_VERIFY_POLICY"
SCRIPT
chmod +x "$REEXEC_SCRIPT"
out="$(HERD_CONFIG_FILE="$P7/.herd/config" bash "$REEXEC_SCRIPT")"
[ "$out" = "auto" ] || fail "(7) the exact WATCHER_SELF_RESTART re-exec shape did not pick up the config-file edit (got: $out, want auto)"
pass
echo "PASS (7) the exact live scenario: a real re-exec (same env, full inheritance) resolves the edited file, not the stale exported value"

# ── (8) DRIFT GUARD: every reset-list key is a literal export the hermetic-env-scrub scanner finds ──
SCRUB="$ROOT/scripts/herd/hermetic-env-scrub.sh"
[ -f "$SCRUB" ] || fail "(8) missing $SCRUB"
# shellcheck source=/dev/null
. "$SCRUB"
scanned="$(herd_hermetic_scrub_keys "$LOADER")"
reset_keys="$(
  bash -c '. "$1" >/dev/null 2>&1; echo "$_HERD_ENGINE_CORE_KEYS"' _ "$LOADER" 2>/dev/null
)"
[ -n "$reset_keys" ] || fail "(8) _HERD_ENGINE_CORE_KEYS resolved empty — reset list missing from herd-config.sh"
missing=""
for k in $reset_keys; do
  grep -qxF "$k" <<< "$scanned" || missing="$missing $k"
done
[ -z "$missing" ] || fail "(8) reset-list key(s) not found among herd-config.sh's literal exports (would silently un-set without ever re-exporting):$missing"
pass
echo "PASS (8) every _HERD_ENGINE_CORE_KEYS member is a literal export herd-config.sh actually makes — reset and export can't drift apart"

echo
echo "ALL PASS ($PASS checks) — HERD-465: the config file is authoritative over inherited/stale env for every engine-core key, mutation-proven, sim seam preserved."
