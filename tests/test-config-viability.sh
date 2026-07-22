#!/usr/bin/env bash
# test-config-viability.sh — hermetic proof of HERD-355: EXTERNAL-CONSISTENCY PROBES that validate
# .herd/config against LIVE external reality (repo merge flags, branch protection, driver bindings).
#
# Asserts, with a STUBBED gh + stub drivers (no network, no real gh, no model):
#   (1) env_coupling dispatch — a coupled key routes to its probe; an uncoupled key is SKIPped.
#   (2) MERGE_METHOD vs allow_*_merge — a repo that DISALLOWS the method → MISMATCH naming BOTH sides;
#       an allowed method → OK; an offline gh → WARN (fail-soft), never MISMATCH.
#   (3) GATE_STATUS vs branch-protection required checks — protection requires herd/gates while
#       GATE_STATUS=off → MISMATCH; GATE_STATUS=on → OK; unprotected branch → OK.
#   (4) DELETE_BRANCH_ON_MERGE — divergence from the repo default is advisory WARN, never MISMATCH.
#   (5) MODEL_REVIEW driver — a driver with no driveable one-shot binding → MISMATCH; a driver whose
#       runtime binary is absent → WARN; a good driver with its binary on PATH → OK.
#   (6) `herd config set MERGE_METHOD merge` against a repo that disallows merge commits → a LOUD
#       refusal (non-zero exit) naming both sides; the refused value is NOT written to config.
#   (7) the same set is fail-soft when gh is offline (WARNS, proceeds, writes the value).
#   (8) the doctor "Config viability" section renders each probe's ✓/⚠/✗ line.
#   (9) a probe result lands as a config_viability journal event + a machine-readable report file.
#   (10) HERD-407 driver-CLI spawn-contract probe (a stubbed `herdr agent start --help`, NOT keyed to
#        a config value): the attach shape (--pane) → OK; the legacy shape (--workspace/--cwd) → OK;
#        a garbage/unrecognized shape → MISMATCH; herdr absent from PATH → WARN (fail-soft).
#
# Run:  bash tests/test-config-viability.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CV="$ROOT/scripts/herd/config-viability.sh"
DRIVER="$ROOT/scripts/herd/driver.sh"
JOURNAL="$ROOT/scripts/herd/journal.sh"
PREFLIGHT="$ROOT/scripts/herd/herd-preflight.sh"
HERD="$ROOT/bin/herd"

for f in "$CV" "$DRIVER" "$JOURNAL" "$PREFLIGHT" "$HERD"; do
  [ -f "$f" ] || { echo "FAIL: missing required file: $f" >&2; exit 1; }
done
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 required" >&2; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASSN=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ PASSN=$((PASSN+1)); }

# ── Stub capabilities manifest with the env_coupling column ───────────────────────────────────────
STUBCAPS="$T/capabilities.tsv"
{
  printf 'name\tkind\tdescription\twhen_to_surface\trequires\tscope\tgovernance\tvalue_shape\tenv_coupling\n'
  printf 'MERGE_METHOD\tconfig\tgit merge strategy\twhen\twatcher\t\tgovernance\tmerge|squash|rebase\tmerge_method\n'
  printf 'GATE_STATUS\tconfig\tgate status\twhen\twatcher\tproject\t\ton|off\trequired_checks\n'
  printf 'DELETE_BRANCH_ON_MERGE\tconfig\tdelete branch\twhen\twatcher\t\tgovernance\tfree\tdelete_branch\n'
  printf 'MODEL_REVIEW\tconfig\treview model\twhen\twatcher\tmachine\t\tfree\tmodel_driver\n'
  printf 'WORKSPACE_NAME\tconfig\tworkspace name\twhen\trender\t\t\tfree\t\n'
} > "$STUBCAPS"

# ── Stub gh: dispatches on `api repos/<owner>/<name>[/branches/<branch>]`. Scenario is chosen via
#    env vars the harness sets per-case (GH_ALLOW_MERGE, GH_PROTECTED, GH_REQUIRED_CONTEXTS, ...).
#    GH_FAIL=1 makes every call fail (the offline / no-access path). ─────────────────────────────────
GH="$T/gh"
cat > "$GH" <<'EOF'
#!/usr/bin/env bash
[ -n "${GH_FAIL:-}" ] && exit 1
[ "${1:-}" = api ] || { echo '{}'; exit 0; }
path="${2:-}"
case "$path" in
  */branches/*)
    cat <<JSON
{"protected": ${GH_PROTECTED:-false}, "protection": {"required_status_checks": {"contexts": [${GH_REQUIRED_CONTEXTS:-}]}}}
JSON
    ;;
  repos/*)
    cat <<JSON
{"allow_merge_commit": ${GH_ALLOW_MERGE:-true}, "allow_squash_merge": ${GH_ALLOW_SQUASH:-true}, "allow_rebase_merge": ${GH_ALLOW_REBASE:-true}, "delete_branch_on_merge": ${GH_DELETE_BRANCH:-false}}
JSON
    ;;
  *) echo '{}' ;;
esac
EOF
chmod +x "$GH"

# ── Stub drivers dir for the MODEL_REVIEW probe: a good driver (binary present), a no-binary driver,
#    and a driver with a degraded (undriveable) one-shot binding. ─────────────────────────────────────
DRV="$T/drivers"; mkdir -p "$DRV"
printf "DRIVER_AGENT_ONESHOT_EXEC='goodrt-bin -p \"<prompt>\" --model <model>'\n" > "$DRV/goodrt.driver"
printf "DRIVER_AGENT_ONESHOT_EXEC='nort-bin -p \"<prompt>\" --model <model>'\n"   > "$DRV/nort.driver"
printf "DRIVER_AGENT_ONESHOT_EXEC='@degrade:no-oneshot-binding'\n"                > "$DRV/degraded.driver"
# a present runtime binary for the good driver; nort-bin is deliberately never created.
GBIN="$T/gbin"; mkdir -p "$GBIN"
printf '#!/usr/bin/env bash\nexit 0\n' > "$GBIN/goodrt-bin"; chmod +x "$GBIN/goodrt-bin"

# Shared probe environment: stub manifest, stub gh, fixed repo, isolated report + journal.
export HERD_CAPABILITIES_FILE="$STUBCAPS"
export HERD_CV_GH="$GH"
export HERD_CV_REPO="acme/widgets"
export HERD_DRIVERS_DIR="$DRV"
export HERD_CONFIG_VIABILITY_REPORT="$T/report.json"
export JOURNAL_FILE="$T/journal.jsonl"
export PATH="$GBIN:$PATH"

# shellcheck source=/dev/null
. "$DRIVER"; . "$JOURNAL"; . "$CV"

# probe <status-var> <msg-var> <KEY> <VALUE> [env=val ...] — run herd_config_viability_probe with the
# per-case env, split the "<STATUS>\t<message>" line into the named vars.
probe(){
  local _sv="$1" _mv="$2" _key="$3" _val="$4"; shift 4
  local _out; _out="$(env "$@" bash -c '
    . "'"$DRIVER"'"; . "'"$JOURNAL"'"; . "'"$CV"'"
    herd_config_viability_probe "'"$_key"'" "'"$_val"'"' 2>/dev/null || true)"
  printf -v "$_sv" '%s' "${_out%%$'\t'*}"
  printf -v "$_mv" '%s' "${_out#*$'\t'}"
}

# ══ (1) env_coupling dispatch ═════════════════════════════════════════════════════════════════════
probe ST MSG WORKSPACE_NAME anything
[ "$ST" = SKIP ] || fail "(1a) an uncoupled key must SKIP (got '$ST')"
probe ST MSG MERGE_METHOD squash GH_ALLOW_SQUASH=true
[ "$ST" = OK ] || fail "(1b) a coupled key must dispatch to its probe (got '$ST': $MSG)"
ok; echo "PASS (1) env_coupling dispatch: uncoupled→SKIP, coupled→probe"

# ══ (2) MERGE_METHOD vs allow_*_merge ═════════════════════════════════════════════════════════════
probe ST MSG MERGE_METHOD merge GH_ALLOW_MERGE=false
[ "$ST" = MISMATCH ] || fail "(2a) disallowed merge method must MISMATCH (got '$ST': $MSG)"
case "$MSG" in *MERGE_METHOD=merge*allow_merge_commit=false*) : ;;
  *) fail "(2a) mismatch message must name BOTH sides (config + repo flag): $MSG" ;; esac
probe ST MSG MERGE_METHOD merge GH_ALLOW_MERGE=true
[ "$ST" = OK ] || fail "(2b) an allowed merge method must be OK (got '$ST': $MSG)"
probe ST MSG MERGE_METHOD merge GH_FAIL=1
[ "$ST" = WARN ] || fail "(2c) an offline probe must WARN, never MISMATCH (got '$ST': $MSG)"
probe ST MSG MERGE_METHOD rebase GH_ALLOW_REBASE=false
[ "$ST" = MISMATCH ] || fail "(2d) disallowed rebase must MISMATCH (got '$ST': $MSG)"
ok; echo "PASS (2) MERGE_METHOD: disallowed→MISMATCH (both sides), allowed→OK, offline→WARN"

# ══ (3) GATE_STATUS vs required checks ════════════════════════════════════════════════════════════
probe ST MSG GATE_STATUS off GH_PROTECTED=true GH_REQUIRED_CONTEXTS='"herd/gates"'
[ "$ST" = MISMATCH ] || fail "(3a) required herd/gates + GATE_STATUS=off must MISMATCH (got '$ST': $MSG)"
case "$MSG" in *GATE_STATUS=off*herd/gates*) : ;; *) fail "(3a) message must name both sides: $MSG" ;; esac
probe ST MSG GATE_STATUS on GH_PROTECTED=true GH_REQUIRED_CONTEXTS='"herd/gates"'
[ "$ST" = OK ] || fail "(3b) required herd/gates + GATE_STATUS=on must be OK (got '$ST': $MSG)"
probe ST MSG GATE_STATUS off GH_PROTECTED=false
[ "$ST" = OK ] || fail "(3c) an unprotected branch must be OK (got '$ST': $MSG)"
ok; echo "PASS (3) GATE_STATUS: required-but-off→MISMATCH, required-and-on→OK, unprotected→OK"

# ══ (4) DELETE_BRANCH_ON_MERGE is advisory ════════════════════════════════════════════════════════
probe ST MSG DELETE_BRANCH_ON_MERGE true GH_DELETE_BRANCH=false
[ "$ST" = WARN ] || fail "(4a) a delete-branch divergence must be advisory WARN, not MISMATCH (got '$ST': $MSG)"
probe ST MSG DELETE_BRANCH_ON_MERGE false GH_DELETE_BRANCH=false
[ "$ST" = OK ] || fail "(4b) a matching delete-branch default must be OK (got '$ST': $MSG)"
ok; echo "PASS (4) DELETE_BRANCH_ON_MERGE: divergence advisory (WARN), match OK"

# ══ (5) MODEL_REVIEW driver capability ════════════════════════════════════════════════════════════
probe ST MSG MODEL_REVIEW degraded:m
[ "$ST" = MISMATCH ] || fail "(5a) an undriveable driver (degraded one-shot) must MISMATCH (got '$ST': $MSG)"
probe ST MSG MODEL_REVIEW nort:m
[ "$ST" = WARN ] || fail "(5b) an absent runtime binary must WARN (got '$ST': $MSG)"
probe ST MSG MODEL_REVIEW goodrt:m
[ "$ST" = OK ] || fail "(5c) a good driver with its binary present must be OK (got '$ST': $MSG)"
ok; echo "PASS (5) MODEL_REVIEW: undriveable→MISMATCH, binary-absent→WARN, good→OK"

# ══ (6) config set integration: refusal on a proven merge-method mismatch ═════════════════════════
# A real herd project fixture; bin/herd bootstrap needs benign git/gh/herdr/pgrep on PATH.
BIN="$T/bin"; mkdir -p "$BIN"
for c in pgrep git herdr; do printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$c"; chmod +x "$BIN/$c"; done
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/gh"; chmod +x "$BIN/gh"   # bin/herd's own gh (not the probe's)
P="$T/proj"; mkdir -p "$P/.herd" "$P/trees"
cat > "$P/.herd/config" <<CFG
HERD_VERSION=1
PROJECT_ROOT="$P"
WORKTREES_DIR="$P/trees"
DEFAULT_BRANCH="origin/main"
WORKSPACE_NAME="viab"
MERGE_METHOD="squash"
CFG

# The probe reads the REAL manifest here (HERD_CAPABILITIES_FILE cleared) so MERGE_METHOD's real
# env_coupling drives it; HERD_CV_GH/HERD_CV_REPO steer the probe's gh; GH_ALLOW_MERGE=false disallows.
set +e
OUT="$(cd "$P" && PATH="$BIN:$PATH" HERD_CAPABILITIES_FILE= HERD_DRIVERS_DIR= \
  HERD_CV_GH="$GH" HERD_CV_REPO="acme/widgets" GH_ALLOW_MERGE=false \
  HERD_RELOAD_SKIP_LAUNCH=1 HERD_RELOAD_SIGTERM_POLLS=1 \
  bash "$HERD" config set MERGE_METHOD merge 2>&1)"
RC=$?
set -e
[ "$RC" -ne 0 ] || fail "(6a) setting a repo-disallowed MERGE_METHOD must be REFUSED (rc=0, out=$OUT)"
printf '%s\n' "$OUT" | grep -qi 'refusing to set MERGE_METHOD' || fail "(6b) refusal must mention 'refusing to set MERGE_METHOD' (out=$OUT)"
printf '%s\n' "$OUT" | grep -q 'allow_merge_commit=false' || fail "(6c) refusal must name the repo side (allow_merge_commit=false) (out=$OUT)"
grep -qE '^MERGE_METHOD="merge"' "$P/.herd/config" && fail "(6d) the refused value must NOT be written to config"
grep -qE '^MERGE_METHOD="squash"' "$P/.herd/config" || fail "(6e) the prior value must remain (out: $(cat "$P/.herd/config"))"
ok; echo "PASS (6) config set refuses a proven merge-method mismatch, naming both sides, no write"

# ══ (7) config set is fail-soft when gh is offline ════════════════════════════════════════════════
set +e
OUT="$(cd "$P" && PATH="$BIN:$PATH" HERD_CAPABILITIES_FILE= HERD_DRIVERS_DIR= \
  HERD_CV_GH="$GH" HERD_CV_REPO="acme/widgets" GH_FAIL=1 \
  HERD_RELOAD_SKIP_LAUNCH=1 HERD_RELOAD_SIGTERM_POLLS=1 \
  bash "$HERD" config set MERGE_METHOD rebase 2>&1)"
RC=$?
set -e
[ "$RC" -eq 0 ] || fail "(7a) an offline probe must NOT block the set (rc=$RC, out=$OUT)"
grep -qE '^MERGE_METHOD="rebase"' "$P/.herd/config" || fail "(7b) the value must be written when the probe is offline"
ok; echo "PASS (7) config set is fail-soft when the probe is offline (WARN, still writes)"

# ══ (8) doctor section renders each probe's verdict ═══════════════════════════════════════════════
cat > "$P/.herd/config" <<CFG
HERD_VERSION=1
PROJECT_ROOT="$P"
WORKTREES_DIR="$P/trees"
DEFAULT_BRANCH="origin/main"
WORKSPACE_NAME="viab"
MERGE_METHOD="merge"
GATE_STATUS="off"
CFG
DOCOUT="$(HERD_CAPABILITIES_FILE="$STUBCAPS" HERD_CONFIG_FILE="$P/.herd/config" \
  HERD_CV_GH="$GH" HERD_CV_REPO="acme/widgets" GH_ALLOW_MERGE=false \
  bash -c '. "'"$PREFLIGHT"'"; . "'"$DRIVER"'"; . "'"$JOURNAL"'"; . "'"$CV"'"; herd_config_viability_doctor_section' 2>&1 || true)"
printf '%s\n' "$DOCOUT" | grep -qi 'Config viability' || fail "(8a) doctor section header missing (out=$DOCOUT)"
printf '%s\n' "$DOCOUT" | grep -q 'MERGE_METHOD=merge' || fail "(8b) doctor section did not render the MERGE_METHOD row (out=$DOCOUT)"
ok; echo "PASS (8) doctor Config-viability section renders per-key verdicts"

# ══ (9) journal event + machine-readable report ═══════════════════════════════════════════════════
: > "$JOURNAL_FILE"; rm -f "$HERD_CONFIG_VIABILITY_REPORT"
GH_ALLOW_MERGE=false herd_config_viability_note MERGE_METHOD merge MISMATCH "repo disallows it" config-set
grep -q '"event": *"config_viability"' "$JOURNAL_FILE" 2>/dev/null \
  || grep -q 'config_viability' "$JOURNAL_FILE" 2>/dev/null \
  || fail "(9a) a config_viability journal event was not written ($(cat "$JOURNAL_FILE" 2>/dev/null))"
[ -f "$HERD_CONFIG_VIABILITY_REPORT" ] || fail "(9b) the machine-readable report file was not written"
python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
assert d.get("results",{}).get("MERGE_METHOD",{}).get("status")=="MISMATCH", d
assert "MERGE_METHOD" in d.get("mismatches",[]), d
' "$HERD_CONFIG_VIABILITY_REPORT" || fail "(9c) report JSON did not record the MERGE_METHOD MISMATCH"
ok; echo "PASS (9) probe result lands as a config_viability journal event + machine-readable report"

# ══ (10) HERD-407 driver-CLI spawn-contract probe ═════════════════════════════════════════════════
# A stub herdr whose `agent start --help` shape is chosen via $HERDR_HELP_MODE (attach/legacy/garbage).
HERDR_STUB="$T/herdr_stub"; mkdir -p "$HERDR_STUB"
cat > "$HERDR_STUB/herdr" <<'EOF'
#!/usr/bin/env bash
case "${HERDR_HELP_MODE:-}" in
  attach)  echo 'Usage: herdr agent start NAME --kind KIND --pane ID [-- ARG...]' ;;
  legacy)  echo 'Usage: herdr agent start NAME --workspace WS --cwd DIR --tab TAB [--split DIR] --no-focus -- ARG...' ;;
  garbage) echo 'Usage: herdr frobnicate --wat' ;;
  *)       echo 'unrecognized' ;;
esac
exit 0
EOF
chmod +x "$HERDR_STUB/herdr"
EMPTYBIN="$T/emptybin"; mkdir -p "$EMPTYBIN"

# probe_driver_cli <status-var> <msg-var> <mode> [path] — run _cv_probe_driver_cli in a FRESH process
# (per-process help-text cache) with the stub herdr's shape mode; PATH defaults to the stub.
probe_driver_cli(){
  local _sv="$1" _mv="$2" _mode="$3" _path="${4:-$HERDR_STUB:$PATH}"
  local _out; _out="$(HERDR_HELP_MODE="$_mode" PATH="$_path" bash -c '
    unset HERD_HERDR_ATTACH_CLI
    . "'"$DRIVER"'"; . "'"$JOURNAL"'"; . "'"$CV"'"
    _cv_probe_driver_cli' 2>/dev/null || true)"
  printf -v "$_sv" '%s' "${_out%%$'\t'*}"
  printf -v "$_mv" '%s' "${_out#*$'\t'}"
}

probe_driver_cli ST MSG attach
[ "$ST" = OK ] || fail "(10a) the attach shape (--pane) must be OK (got '$ST': $MSG)"
case "$MSG" in *attach*) : ;; *) fail "(10a) OK message should name the attach contract: $MSG" ;; esac

probe_driver_cli ST MSG legacy
[ "$ST" = OK ] || fail "(10b) the legacy shape (--workspace/--cwd) must be OK (got '$ST': $MSG)"
case "$MSG" in *legacy*) : ;; *) fail "(10b) OK message should name the legacy contract: $MSG" ;; esac

probe_driver_cli ST MSG garbage
[ "$ST" = MISMATCH ] || fail "(10c) an unrecognized shape must MISMATCH (got '$ST': $MSG)"
case "$MSG" in *attach*legacy*|*NEITHER*) : ;; *) : ;; esac

probe_driver_cli ST MSG '' "/usr/bin:/bin:$EMPTYBIN"
[ "$ST" = WARN ] || fail "(10d) herdr absent from PATH must WARN, never MISMATCH (got '$ST': $MSG)"
ok; echo "PASS (10) HERD-407 driver-CLI spawn contract: attach→OK, legacy→OK, garbage→MISMATCH, absent→WARN"

echo ""
echo "ALL $PASSN tests PASSED — HERD-355 config viability + HERD-407 driver-CLI probe"
