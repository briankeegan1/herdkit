#!/usr/bin/env bash
# scripts/herd/sim/sandbox-scenario.sh — P0 scenario runner SKELETON for the sandbox consumer.
#
# Walks the herd workflow end-to-end against the LOCAL fixture from sandbox-fixture.sh:
#
#     init → (stubbed) build → PR → gate → merge → teardown
#
# using a STUB builder — a deterministic tiny file change, NO model call — so runs are fast and
# free. Every step asserts a CHECKPOINT via git/file state (real herdr-pane + screenshot assertions
# are explicitly DEFERRED to P1 — see scripts/herd/sim/README-sandbox-sim.md). At the end it writes
# a machine-readable SCORECARD (scenario, checkpoints passed/failed, artifacts dir) as JSON.
#
# P0 SCOPE (local-only):
#   • No hosted GitHub repo. The "PR" is a local branch + a local pr.json record.  [TODO(P1)]
#   • No herdr panes/tabs/workspaces are spun; no screenshots are captured.        [TODO(P1)]
#   • The "builder" is a fixed diff, not an agent.                                 [TODO(P1): real-model smoke]
#
# Usage:
#   bash scripts/herd/sim/sandbox-scenario.sh [--artifacts DIR] [--keep]
#     --artifacts DIR   put the repo + scorecard here (default: a fresh mktemp dir)
#     --keep            do not delete the artifacts dir on exit (implied when --artifacts is given)
#
# Fault injection (a P0 seed of the P1 fault-injection scenarios):
#   SANDBOX_FORCE_GATE_FAIL=1   the stub builder breaks the app so the gate FAILS LOUDLY; the runner
#                               must record gate=fail, SKIP the merge, and end with result=fail
#                               (proving a broken change is never silently merged).
#
# Exit: 0 = every checkpoint passed · 1 = at least one checkpoint failed (or a hard error).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/herd/sim/sandbox-fixture.sh
. "$HERE/sandbox-fixture.sh"

# ── output helpers (mirror cross-repo-loop-sim.sh's style) ──────────────────────────────────────
c_bold=$'\033[1m'; c_dim=$'\033[2m'
c_grn=$'\033[32m'; c_red=$'\033[31m'; c_yel=$'\033[33m'; c_rst=$'\033[0m'
step() { printf '\n%s[%s]%s %s\n' "$c_bold" "$1" "$c_rst" "$2"; }
ok()   { printf '  %s✓%s %s\n' "$c_grn" "$c_rst" "$*"; }
bad()  { printf '  %s✗%s %s\n' "$c_red" "$c_rst" "$*"; }
skip() { printf '  %s–%s %s\n' "$c_yel" "$c_rst" "$*"; }
info() { printf '  %s→%s %s\n' "$c_dim" "$c_rst" "$*"; }

# ── args ────────────────────────────────────────────────────────────────────────
ART=""; KEEP=""
while [ $# -gt 0 ]; do
  case "$1" in
    --artifacts) ART="${2:-}"; KEEP=1; shift 2 ;;
    --keep)      KEEP=1; shift ;;
    -h|--help)   grep -E '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "sandbox-scenario: unknown arg: $1" >&2; exit 1 ;;
  esac
done
if [ -z "$ART" ]; then ART="$(mktemp -d)"; fi
mkdir -p "$ART"
if [ -z "$KEEP" ]; then trap 'rm -rf "$ART"' EXIT; fi

SCENARIO="stub-happy-path"
[ "${SANDBOX_FORCE_GATE_FAIL:-}" = "1" ] && SCENARIO="stub-gate-fault"
REPO="$ART/repo"
BUILDER_BRANCH="sim/stub-builder"

# ── checkpoint recording (bash 3.2: parallel indexed arrays, no assoc arrays) ───────────────────
CP_NAMES=(); CP_STATUS=(); CP_DETAIL=()
_pass=0; _fail=0

# checkpoint <name> <status: pass|fail|skip> <detail...>
checkpoint() {
  local name="$1" status="$2"; shift 2
  local detail="$*"
  # Sanitize detail for embedding in JSON: strip the two chars that would break a bare string.
  detail="$(printf '%s' "$detail" | tr -d '"\\' | tr '\n' ' ')"
  CP_NAMES+=("$name"); CP_STATUS+=("$status"); CP_DETAIL+=("$detail")
  case "$status" in
    pass) _pass=$((_pass+1)); ok "$name — $detail" ;;
    fail) _fail=$((_fail+1)); bad "$name — $detail" ;;
    skip) skip "$name — $detail" ;;
  esac
}

# assert <name> <predicate-cmd...> — run predicate; pass if exit 0, fail otherwise.
assert() {
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then checkpoint "$name" pass "$*"; return 0
  else checkpoint "$name" fail "predicate failed: $*"; return 1; fi
}

# ── SCORECARD emitter (machine-readable JSON, no jq/python dependency) ───────────────────────────
# Fields: scenario, artifacts_dir, repo_dir, fixture_sha, result, passed, failed, skipped,
#         checkpoints[]{name,status,detail}. All string values are controlled/sanitized above.
write_scorecard() {
  local out="$ART/scorecard.json" result="$1" fixture_sha="$2"
  local skipped=0 i n
  n=${#CP_NAMES[@]}
  for ((i=0; i<n; i++)); do [ "${CP_STATUS[$i]}" = "skip" ] && skipped=$((skipped+1)); done
  {
    printf '{\n'
    printf '  "scenario": "%s",\n' "$SCENARIO"
    printf '  "artifacts_dir": "%s",\n' "$ART"
    printf '  "repo_dir": "%s",\n' "$REPO"
    printf '  "fixture_sha": "%s",\n' "$fixture_sha"
    printf '  "result": "%s",\n' "$result"
    printf '  "passed": %d,\n' "$_pass"
    printf '  "failed": %d,\n' "$_fail"
    printf '  "skipped": %d,\n' "$skipped"
    printf '  "checkpoints": [\n'
    for ((i=0; i<n; i++)); do
      printf '    {"name": "%s", "status": "%s", "detail": "%s"}' \
        "${CP_NAMES[$i]}" "${CP_STATUS[$i]}" "${CP_DETAIL[$i]}"
      [ "$i" -lt "$((n-1))" ] && printf ',\n' || printf '\n'
    done
    printf '  ]\n'
    printf '}\n'
  } > "$out"
  printf '%s' "$out"
}

# ── predicates used by checkpoints ──────────────────────────────────────────────
_file_exists()   { [ -f "$1" ]; }
_tree_clean()    { [ -z "$(git -C "$1" status --porcelain 2>/dev/null)" ]; }
_branch_exists() { git -C "$1" show-ref --verify --quiet "refs/heads/$2"; }
_branch_absent() { ! git -C "$1" show-ref --verify --quiet "refs/heads/$2"; }
_path_on_ref()   { git -C "$1" cat-file -e "$2:$3" 2>/dev/null; }   # <repo> <ref> <path>

# ═══════════════════════════════════════════════════════════════════════════════
printf '%s══ Sandbox consumer scenario: %s ══%s\n' "$c_bold" "$SCENARIO" "$c_rst"
printf '  artifacts: %s\n' "$ART"

# ── init: build the deterministic fixture ───────────────────────────────────────
step init "build deterministic local fixture"
FIXTURE_SHA="$(sandbox_fixture_build "$REPO")" || { bad "fixture build failed"; write_scorecard fail "" >/dev/null; exit 1; }
info "fixture HEAD: $FIXTURE_SHA"
assert fixture_built _file_exists "$REPO/app/greet.sh"
assert fixture_clean _tree_clean "$REPO"

# ── build (STUB): a deterministic tiny change on a builder branch. NO model call. ───────────────
step build "STUB builder — deterministic tiny change (no model call)"
git -C "$REPO" checkout -q -b "$BUILDER_BRANCH"
_sf_git_env
if [ "${SANDBOX_FORCE_GATE_FAIL:-}" = "1" ]; then
  # Fault injection: break the app so the gate must catch it.
  cat > "$REPO/app/greet.sh" <<'BROKEN'
#!/usr/bin/env bash
# greet.sh — intentionally broken by the fault-injection stub (wrong output).
greet() { printf 'HOWDY, %s.\n' "${1:-world}"; }
if [ "${BASH_SOURCE[0]}" = "$0" ]; then greet "$@"; fi
BROKEN
  info "fault injected: greet.sh output broken (gate should fail)"
else
  # Happy path: implement backlog item 1 (farewell) as a fixed, tiny addition.
  cat > "$REPO/app/farewell.sh" <<'FAREWELL'
#!/usr/bin/env bash
# farewell.sh — added by the stub builder (implements backlog item 1).
farewell() { printf 'goodbye, %s!\n' "${1:-world}"; }
if [ "${BASH_SOURCE[0]}" = "$0" ]; then farewell "$@"; fi
FAREWELL
  chmod +x "$REPO/app/farewell.sh"
fi
git -C "$REPO" add -A
git -C "$REPO" commit -q -m "stub-builder: deterministic change ($SCENARIO)"
assert builder_committed _branch_exists "$REPO" "$BUILDER_BRANCH"

# ── PR: local-only PR record (no hosted repo). [TODO(P1): gh pr create on herdkit-sandbox] ──────
step pr "open local PR record (no hosted GitHub repo in P0)"
BUILDER_SHA="$(git -C "$REPO" rev-parse "$BUILDER_BRANCH")"
BASE_SHA="$(git -C "$REPO" rev-parse main)"
cat > "$ART/pr.json" <<PR
{
  "branch": "$BUILDER_BRANCH",
  "base": "main",
  "head_sha": "$BUILDER_SHA",
  "base_sha": "$BASE_SHA",
  "title": "stub-builder: $SCENARIO",
  "hosted": false
}
PR
# The branch must be exactly one commit ahead of main (a real, reviewable delta).
_ahead="$(git -C "$REPO" rev-list --count main.."$BUILDER_BRANCH" 2>/dev/null || echo 0)"
if [ -f "$ART/pr.json" ] && [ "$_ahead" = "1" ]; then
  checkpoint pr_opened pass "branch $BUILDER_BRANCH is 1 commit ahead of main; pr.json written"
else
  checkpoint pr_opened fail "pr.json missing or branch not 1 ahead (ahead=$_ahead)"
fi

# ── gate: run the fixture's real health gate on the builder branch ──────────────────────────────
step gate "run fixture health gate (app/greet.test.sh)"
git -C "$REPO" checkout -q "$BUILDER_BRANCH"
gate_rc=0
gate_out="$( (cd "$REPO" && bash app/greet.test.sh) 2>&1 )" || gate_rc=$?
git -C "$REPO" checkout -q main
if [ "$gate_rc" -eq 0 ]; then
  checkpoint gate_passed pass "gate clean: $gate_out"
else
  checkpoint gate_passed fail "gate FAILED LOUDLY (rc=$gate_rc): $gate_out"
fi

# ── merge: only if the gate passed. A failed gate must SKIP the merge (never silently merge). ───
step merge "merge builder branch into main (gate-gated)"
if [ "$gate_rc" -eq 0 ]; then
  _sf_git_env
  git -C "$REPO" merge -q --no-ff -m "merge: $BUILDER_BRANCH ($SCENARIO)" "$BUILDER_BRANCH"
  if [ "${SANDBOX_FORCE_GATE_FAIL:-}" = "1" ]; then
    assert merged _path_on_ref "$REPO" main "app/greet.sh"
  else
    assert merged _path_on_ref "$REPO" main "app/farewell.sh"
  fi
else
  checkpoint merged skip "merge correctly SKIPPED because the gate failed"
  # And prove the broken change never reached main.
  if git -C "$REPO" merge-base --is-ancestor "$BUILDER_BRANCH" main 2>/dev/null; then
    checkpoint change_isolated fail "broken builder commit leaked onto main"
  else
    checkpoint change_isolated pass "broken change is NOT on main (isolation held)"
  fi
fi

# ── teardown: delete the builder branch; assert it is gone and main is clean ────────────────────
step teardown "delete builder branch; assert clean teardown"
git -C "$REPO" branch -q -D "$BUILDER_BRANCH" >/dev/null 2>&1 || true
assert torn_down _branch_absent "$REPO" "$BUILDER_BRANCH"
assert final_clean _tree_clean "$REPO"

# ── main-health tick (HERD-129): post-merge default-branch tripwire ─────────────────────────────
# The stub merge above proves the PRE-merge gate blocks a broken PR in isolation. This phase proves
# the POST-merge main_health_tick — the tripwire for the OTHER failure class: two independently-green
# PRs merging into a broken COMBINATION, which no per-PR gate can see. We drive the REAL function from
# scripts/herd/agent-watch.sh (sourced in AGENT_WATCH_LIB mode) against a throwaway fixture 'main',
# with a stub HERD_HEALTHCHECK_BIN that runs the fixture's own gate — so a genuinely broken fixture
# test is what turns main red. Four assertions: dormant-when-unset, green silence, red alarm, recovery.
step main-health "post-merge main_health_tick — dormant/off, green silence, red alarm, recovery"
WATCH_SH="$HERE/../agent-watch.sh"
if [ ! -f "$WATCH_SH" ]; then
  checkpoint main_health_lib skip "agent-watch.sh not found at $WATCH_SH — main-health phase skipped"
else
  # Stub healthcheck bin: run the fixture's REAL gate against <dir>, emit healthcheck.sh --oneline
  # shape (0 clean / 1 code error). A broken greet.sh fails greet.test.sh → rc 1 → main red.
  MH_HC="$ART/mh-healthcheck.sh"
  cat > "$MH_HC" <<'HCSTUB'
#!/usr/bin/env bash
dir="$1"
if ( cd "$dir" && bash app/greet.test.sh ) >/dev/null 2>&1; then
  echo "✅ clean — greet.test PASS"; exit 0
else
  echo "❌ code error — app/greet.test.sh → greet.test FAIL"; exit 1
fi
HCSTUB
  # Driver: source agent-watch.sh in lib mode, run main_health_tick + build_main_health, print the
  # rendered row on stdout. HERD_DRIVER=headless routes any notification to a log (never the live
  # herdr workspace); NO_COLOR keeps the row plain-text so the assertions can grep it.
  MH_DRIVER="$ART/mh-driver.sh"
  cat > "$MH_DRIVER" <<'DRV'
#!/usr/bin/env bash
set -u
export AGENT_WATCH_LIB=1 HERD_DRIVER=headless NO_COLOR=1
export PROJECT_ROOT="$1" WORKTREES_DIR="$2" JOURNAL_FILE="$3"
export MAIN_HEALTH_TICK="$5" HERD_HEALTHCHECK_BIN="$6"
export HEALTHCHECK_CMD="app/greet.test.sh" HEALTHCHECK_HEAVY_GLOB='^app/' DEFAULT_BRANCH="main"
export HERD_CONFIG_FILE="$2/.no-such-config"
# shellcheck source=/dev/null
. "$7" >/dev/null 2>&1 || { echo "SRC_FAIL" >&2; exit 3; }
main_health_tick "$4" >/dev/null 2>&1
build_main_health >/dev/null 2>&1
printf '%s' "${MAIN_HEALTH:-}"
DRV
  # mh_drive <main-repo> <trees> <journal> <pr#> <on|off> — run the driver; echo the rendered row.
  mh_drive() { bash "$MH_DRIVER" "$1" "$2" "$3" "$4" "$5" "$MH_HC" "$WATCH_SH" 2>/dev/null; }
  # mh_break <repo> — commit a broken greet.sh (fails greet.test.sh); advances HEAD to a new sha.
  mh_break() {
    _sf_git_env
    cat > "$1/app/greet.sh" <<'BROKEN'
#!/usr/bin/env bash
# greet.sh — broken by the main-health fixture (wrong output → greet.test.sh fails).
greet() { printf 'HOWDY, %s.\n' "${1:-world}"; }
if [ "${BASH_SOURCE[0]}" = "$0" ]; then greet "$@"; fi
BROKEN
    git -C "$1" add -A && git -C "$1" commit -q -m "break greet (main-health fixture)"
  }
  # mh_fix <repo> — restore greet.sh to a passing state; advances HEAD to a NEW green sha.
  mh_fix() {
    _sf_git_env
    sandbox_fixture_files "$1"                       # rewrite the pristine (passing) greet.sh
    git -C "$1" add -A && git -C "$1" commit -q -m "fix greet (main-health fixture)"
  }
  _mh_state() { printf '%s' "$1/.agent-watch-main-health"; }
  _mh_no_event()  { ! grep -q '"event":"main_health"' "$1" 2>/dev/null; }
  _mh_has_result(){ grep -q "\"event\":\"main_health\".*\"result\":\"$2\"" "$1" 2>/dev/null; }

  # (A) DORMANT: feature OFF against a BROKEN main → byte-inert. No journal event, no state file, no row.
  MH_A="$ART/mh-a"; TR_A="$ART/tr-a"; JN_A="$ART/jn-a.jsonl"; mkdir -p "$TR_A"; : > "$JN_A"
  sandbox_fixture_build "$MH_A" >/dev/null 2>&1 && mh_break "$MH_A" >/dev/null 2>&1
  ROW_A="$(mh_drive "$MH_A" "$TR_A" "$JN_A" 900 off)"
  if _mh_no_event "$JN_A" && [ ! -f "$(_mh_state "$TR_A")" ] && [ -z "$ROW_A" ]; then
    checkpoint main_health_dormant pass "MAIN_HEALTH_TICK=off on a broken main is byte-inert (no event, no state, no row)"
  else
    checkpoint main_health_dormant fail "disabled tick was NOT inert (event/state/row leaked: row='$ROW_A')"
  fi

  # (B) GREEN SILENCE: feature ON against a GREEN main → green journal, NO red, no state file, empty row.
  MH_B="$ART/mh-b"; TR_B="$ART/tr-b"; JN_B="$ART/jn-b.jsonl"; mkdir -p "$TR_B"; : > "$JN_B"
  sandbox_fixture_build "$MH_B" >/dev/null 2>&1
  ROW_B="$(mh_drive "$MH_B" "$TR_B" "$JN_B" 901 on)"
  if _mh_has_result "$JN_B" green && ! _mh_has_result "$JN_B" red && [ ! -f "$(_mh_state "$TR_B")" ] && [ -z "$ROW_B" ]; then
    checkpoint main_health_green pass "green merge journals green and stays SILENT (no red, no state, no row)"
  else
    checkpoint main_health_green fail "green merge was not silent (row='$ROW_B')"
  fi

  # (C) RED ALARM: feature ON against a BROKEN main → red journal (failed=app/greet.test.sh, since #N),
  #     a state file, and a LOUD 'MAIN RED — <test> (since #N)' row. Shares its trees with (D).
  MH_CD="$ART/mh-cd"; TR_CD="$ART/tr-cd"; JN_C="$ART/jn-c.jsonl"; mkdir -p "$TR_CD"; : > "$JN_C"
  sandbox_fixture_build "$MH_CD" >/dev/null 2>&1 && mh_break "$MH_CD" >/dev/null 2>&1
  ROW_C="$(mh_drive "$MH_CD" "$TR_CD" "$JN_C" 226 on)"
  if _mh_has_result "$JN_C" red \
     && grep -q '"failed":"app/greet.test.sh"' "$JN_C" 2>/dev/null \
     && grep -Eq '"since":"?226"?' "$JN_C" 2>/dev/null \
     && [ -s "$(_mh_state "$TR_CD")" ] \
     && printf '%s' "$ROW_C" | grep -q 'MAIN RED' \
     && printf '%s' "$ROW_C" | grep -q 'app/greet.test.sh' \
     && printf '%s' "$ROW_C" | grep -q 'since #226'; then
    checkpoint main_health_red pass "broken main → red journal + state + row: ${ROW_C}"
  else
    checkpoint main_health_red fail "broken main did NOT raise the alarm (row='$ROW_C')"
  fi

  # (D) RECOVERY: a LATER green sha (same trees, HEAD advanced) clears the state file → empty row + green.
  : > "$JN_C"                                        # reuse the journal for the recovery assertion
  mh_fix "$MH_CD" >/dev/null 2>&1
  ROW_D="$(mh_drive "$MH_CD" "$TR_CD" "$JN_C" 227 on)"
  if _mh_has_result "$JN_C" green && [ ! -f "$(_mh_state "$TR_CD")" ] && [ -z "$ROW_D" ]; then
    checkpoint main_health_recovery pass "a later green sha clears the MAIN RED row (state removed, row empty)"
  else
    checkpoint main_health_recovery fail "green sha did NOT clear the alarm (row='$ROW_D', state=$( [ -f "$(_mh_state "$TR_CD")" ] && echo present || echo absent ))"
  fi
fi

# ── scorecard ───────────────────────────────────────────────────────────────────
RESULT="pass"; [ "$_fail" -gt 0 ] && RESULT="fail"
SCARD="$(write_scorecard "$RESULT" "$FIXTURE_SHA")"
printf '\n%s══ scorecard ══%s\n' "$c_bold" "$c_rst"
printf '  scenario:   %s\n' "$SCENARIO"
printf '  result:     %s\n' "$RESULT"
printf '  passed:     %d\n' "$_pass"
printf '  failed:     %d\n' "$_fail"
printf '  scorecard:  %s\n' "$SCARD"
printf '  artifacts:  %s\n' "$ART"

[ "$RESULT" = "pass" ] && exit 0 || exit 1
