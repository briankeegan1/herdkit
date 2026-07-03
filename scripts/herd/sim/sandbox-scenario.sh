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
