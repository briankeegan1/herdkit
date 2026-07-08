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
# Exit: 0 = nothing failed (result pass, or pass-with-skips when a non-optional phase could not run) ·
#       1 = at least one checkpoint failed (or a hard error).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/herd/sim/sandbox-fixture.sh
. "$HERE/sandbox-fixture.sh"
# shellcheck source=scripts/herd/sim/sim-notify-stub.sh
. "$HERE/sim-notify-stub.sh"   # notify hermeticity (HERD-139) — installed after $ART is known

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

# ── notify hermeticity (HERD-139) ───────────────────────────────────────────────────────────────
# The engine paths this scenario drives (notably the main-health forced-red leg below) call
# herd_driver_notify, which pops a REAL desktop notification. Install the shared notify stub NOW so
# every notification lands only in a durable sink (headless notifications.log / the captured herdr
# stub), never the operator's screen — and so the run can ASSERT the sink and prove zero native leaks.
sim_notify_install "$ART"

SCENARIO="stub-happy-path"
[ "${SANDBOX_FORCE_GATE_FAIL:-}" = "1" ] && SCENARIO="stub-gate-fault"
REPO="$ART/repo"
BUILDER_BRANCH="sim/stub-builder"

# ── checkpoint recording (bash 3.2: parallel indexed arrays, no assoc arrays) ───────────────────
CP_NAMES=(); CP_STATUS=(); CP_DETAIL=()
_pass=0; _fail=0; _skip_req=0

# checkpoint <name> <status> <detail...>
#   status:
#     pass          — the checkpoint held.
#     fail          — the checkpoint did not hold (drives result=fail, exit 1).
#     skip          — a NON-OPTIONAL skip: a phase that was EXPECTED to run but could NOT (e.g. a
#                     required lib was absent). It is a real COVERAGE GAP, so it degrades the scorecard
#                     result to "pass-with-skips" — a silently-skipped phase must never read as a clean
#                     pass (S1: sim scorecards were green even when whole phases skipped).
#     skip-optional — an EXPECTED, designed skip: a conditional branch that is SUPPOSED to skip (e.g.
#                     "merge correctly SKIPPED because the gate failed"). Recorded as a skip in the
#                     scorecard, but does NOT degrade the result — it is the scenario working as designed.
#   Any UNKNOWN/typo'd status is counted as a FAIL (default arm) so a broken checkpoint call can never
#   silently vanish from the tally.
checkpoint() {
  local name="$1" status="$2"; shift 2
  local detail="$*" stored
  # Sanitize detail for embedding in JSON: strip the two chars that would break a bare string.
  detail="$(printf '%s' "$detail" | tr -d '"\\' | tr '\n' ' ')"
  case "$status" in
    pass)          _pass=$((_pass+1));         stored=pass; ok   "$name — $detail" ;;
    fail)          _fail=$((_fail+1));         stored=fail; bad  "$name — $detail" ;;
    skip)          _skip_req=$((_skip_req+1)); stored=skip; skip "$name — $detail (non-optional → pass-with-skips)" ;;
    skip-optional) stored=skip;                             skip "$name — $detail" ;;
    *)             _fail=$((_fail+1));         stored=fail; bad  "$name — UNKNOWN status '$status' (counted as fail): $detail" ;;
  esac
  CP_NAMES+=("$name"); CP_STATUS+=("$stored"); CP_DETAIL+=("$detail")
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
  checkpoint merged skip-optional "merge correctly SKIPPED because the gate failed"
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
  # Stub healthcheck bin — EMULATES healthcheck.sh's profile semantics against $MAIN, so the review's
  # correctness trap is reproducible end-to-end: --light derives its file set from an EMPTY
  # $MAIN-vs-default-branch diff → a zero-file vacuous green (rc 0 regardless of real state); --heavy
  # (the profile the tick must always use) runs the fixture's REAL gate, so a broken greet.sh → rc 1.
  # If main_health_tick ever regressed to passing --light, sub-check (E) would falsely go green.
  MH_HC="$ART/mh-healthcheck.sh"
  cat > "$MH_HC" <<'HCSTUB'
#!/usr/bin/env bash
dir="$1"; shift
mode="heavy"
for a in "$@"; do case "$a" in --light) mode="light" ;; --heavy) mode="heavy" ;; esac; done
if [ "$mode" = "light" ]; then echo "✅ light clean — 0 sh, 0 py ok"; exit 0; fi
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
  # mh_docs_commit <repo> — a docs-only commit (touches BACKLOG.md, NOT app/) so HEAD's merged diff
  # does NOT match HEALTHCHECK_HEAVY_GLOB='^app/' — the routine merge the review showed would be
  # mis-classified '--light' and vacuously cleared. Advances HEAD to a new (docs-only) sha.
  mh_docs_commit() {
    _sf_git_env
    printf '\n- 🔜 **Doc note** — non-app change (main-health regression fixture).\n' >> "$1/BACKLOG.md"
    git -C "$1" add -A && git -C "$1" commit -q -m "docs: touch BACKLOG (non-heavy diff)"
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

  # (C/D) NOTIFY SINK (HERD-139): the forced-red + recovery legs above are exactly the 2026-07-08
  # cry-wolf incident — main_health_tick fires herd_driver_notify. With the notify stub installed the
  # notification is CAPTURED in the durable headless sink instead of the operator's desktop, so we can
  # ASSERT it: the shared TR_CD sink must hold EXACTLY ONE '🚨 MAIN RED' line (green→red transition,
  # leg C) and the '✅ main green' recovery line (red→green transition, leg D). Turns the leak into
  # covered signal — notification behaviour is now tested, not leaked.
  MH_SINK="$(sim_notify_sink "$TR_CD")"
  _mh_red_n="$(sim_notify_count "$MH_SINK" 'MAIN RED')"
  _mh_grn_n="$(sim_notify_count "$MH_SINK" 'main green')"
  if [ "$_mh_red_n" = 1 ] && [ "$_mh_grn_n" -ge 1 ]; then
    checkpoint main_health_notify_sink pass "forced-red leg surfaced exactly one MAIN RED + a recovery line to the durable sink (red=$_mh_red_n green=$_mh_grn_n), never the desktop"
  else
    checkpoint main_health_notify_sink fail "notify sink mismatch (want 1 MAIN RED + >=1 main green; got red=$_mh_red_n green=$_mh_grn_n; sink=$MH_SINK)"
  fi

  # (E) NON-HEAVY MERGE ON A BROKEN MAIN (review regression guard): break main, then land a docs-only
  #     merge whose diff does NOT match HEALTHCHECK_HEAVY_GLOB. The tick must run the FULL (heavy) suite
  #     and STILL see red — never mis-classify it as a zero-file '--light' vacuous green that would
  #     falsely clear the alarm. With the bug present the stub returns '✅ light clean' → this fails.
  MH_E="$ART/mh-e"; TR_E="$ART/tr-e"; JN_E="$ART/jn-e.jsonl"; mkdir -p "$TR_E"; : > "$JN_E"
  sandbox_fixture_build "$MH_E" >/dev/null 2>&1 && mh_break "$MH_E" >/dev/null 2>&1 && mh_docs_commit "$MH_E" >/dev/null 2>&1
  ROW_E="$(mh_drive "$MH_E" "$TR_E" "$JN_E" 300 on)"
  if _mh_has_result "$JN_E" red && [ -s "$(_mh_state "$TR_E")" ] && printf '%s' "$ROW_E" | grep -q 'MAIN RED'; then
    checkpoint main_health_nonheavy_red pass "a docs-only (non-heavy-glob) merge on a broken main still runs the full suite and reds — not a vacuous light green"
  else
    checkpoint main_health_nonheavy_red fail "non-heavy merge on a broken main did NOT red (would falsely clear a real MAIN RED); row='$ROW_E'"
  fi
fi

# ── push-gate (HERD-123): PUSH_GATE=human — hold BEFORE push, approve to resume push + PR ────────
# Proves the seam the item exists for, driving the REAL push-gate.sh + herd-approve.sh entry points
# against a throwaway fixture with a LOCAL bare 'origin' remote (so a real `git push` works with no
# network; the PR-create step is stubbed via HERD_PUSH_GATE_PR_CMD, mirroring how the main-health phase
# stubs HERD_HEALTHCHECK_BIN). Four assertions: (A) a finished builder records a sha-keyed hold and
# NOTHING is pushed; (B) the hold surfaces in herd-approve.sh list with the worktree path; (C) approve
# resumes push + PR + the health gate; (D) a new commit after the hold invalidates a prior approval.
step push-gate "PUSH_GATE=human — no push before approval, approve resumes push+PR, stale-sha refused"
PG_ENGINE="$HERE/.."
if [ ! -f "$PG_ENGINE/push-gate.sh" ] || [ ! -f "$PG_ENGINE/herd-approve.sh" ]; then
  checkpoint push_gate_lib skip "push-gate.sh / herd-approve.sh not found — push-gate phase skipped"
else
  # Stub `gh pr create`: the resume's PR step is overridable via HERD_PUSH_GATE_PR_CMD. It writes a
  # local pr.json from the HERD_PG_* env push-gate.sh exports, so the PR step needs no gh/network.
  PG_PR_JSON="$ART/pg-pr.json"
  PG_PR_CMD="$ART/pg-pr-create.sh"
  cat > "$PG_PR_CMD" <<PRCMD
#!/usr/bin/env bash
# Stub gh pr create — record the PR locally from the HERD_PG_* env push-gate.sh passes.
cat > "$PG_PR_JSON" <<JSON
{ "branch": "\${HERD_PG_BRANCH:-}", "base": "\${HERD_PG_BASE:-}", "title": "\${HERD_PG_TITLE:-}", "hosted": true }
JSON
PRCMD

  PG_REPO="$ART/pg-repo"; PG_BARE="$ART/pg-origin.git"; PG_TREES="$ART/pg-trees"; mkdir -p "$PG_TREES"
  PG_LEDGER="$PG_TREES/.agent-watch-push-holds"
  # pg_env <repo> <cmd…> — run a push-gate/herd-approve CLI hermetically: the ledger lives in a
  # throwaway trees dir, HERD_CONFIG_FILE points at a NON-existent path so herd-config.sh never walks
  # up into herdkit's OWN .herd/config, DEFAULT_BRANCH gives HERD_REMOTE=origin, PR step stubbed.
  pg_env() {
    local _pg_root="$1"; shift
    env HERD_CONFIG_FILE="$ART/.pg-no-config" WORKTREES_DIR="$PG_TREES" PROJECT_ROOT="$_pg_root" \
        DEFAULT_BRANCH="origin/main" NO_COLOR=1 HERD_DRIVER=headless \
        HERD_PUSH_GATE_PR_CMD="$PG_PR_CMD" "$@"
  }

  # Build the builder worktree + a bare 'origin' it can push to; seed main on origin, then a committed
  # change on a feature branch (the "finished" work the builder would push).
  sandbox_fixture_build "$PG_REPO" >/dev/null 2>&1
  git init -q --bare "$PG_BARE"
  git -C "$PG_REPO" remote add origin "$PG_BARE"
  _sf_git_env
  git -C "$PG_REPO" push -q origin main 2>/dev/null || true
  PG_BRANCH="feat/pg-demo"
  git -C "$PG_REPO" checkout -q -b "$PG_BRANCH"
  printf '\nfarewell() { printf "goodbye, %%s!\\n" "${1:-world}"; }\n' >> "$PG_REPO/app/greet.sh"
  git -C "$PG_REPO" add -A && git -C "$PG_REPO" commit -q -m "pg: add farewell (finished work)"
  PG_SHA="$(git -C "$PG_REPO" rev-parse HEAD)"
  PG_BODY="$ART/pg-body.md"; printf 'Add farewell.\n\nRefs: HERD-123\n' > "$PG_BODY"

  # (A) HOLD instead of push. Assert: awaiting record written AND the branch is NOT on origin.
  pg_env "$PG_REPO" bash "$PG_ENGINE/push-gate.sh" hold pg-demo --dir "$PG_REPO" --branch "$PG_BRANCH" \
      --base main --title "pg: add farewell" --body-file "$PG_BODY" >/dev/null 2>&1
  if grep -q "awaiting pg-demo $PG_SHA" "$PG_LEDGER" 2>/dev/null && _branch_absent "$PG_BARE" "$PG_BRANCH"; then
    checkpoint push_gate_held_no_push pass "hold recorded (awaiting ${PG_SHA}); NOTHING pushed to origin"
  else
    checkpoint push_gate_held_no_push fail "hold not recorded or branch leaked to origin before approval"
  fi

  # (B) LIST surfaces the pre-PR hold with the worktree path (what the human reviews).
  PG_LIST="$(pg_env "$PG_REPO" bash "$PG_ENGINE/herd-approve.sh" list 2>/dev/null || true)"
  if printf '%s' "$PG_LIST" | grep -q 'pg-demo' && printf '%s' "$PG_LIST" | grep -q "$PG_REPO"; then
    checkpoint push_gate_listed pass "herd-approve.sh list shows the pre-PR hold + worktree path"
  else
    checkpoint push_gate_listed fail "herd-approve.sh list did not surface the push-hold"
  fi

  # (C) APPROVE resumes: push + PR proceed. Assert: branch NOW on origin, pr.json written, ledger
  #     marked pushed, and the fixture health gate runs green on the resumed branch (gates proceed).
  pg_env "$PG_REPO" bash "$PG_ENGINE/herd-approve.sh" approve pg-demo >/dev/null 2>&1
  _pg_gate_rc=0
  ( cd "$PG_REPO" && bash app/greet.test.sh ) >/dev/null 2>&1 || _pg_gate_rc=$?
  if _branch_exists "$PG_BARE" "$PG_BRANCH" && [ -f "$PG_PR_JSON" ] \
     && grep -q "pushed pg-demo $PG_SHA" "$PG_LEDGER" 2>/dev/null && [ "$_pg_gate_rc" -eq 0 ]; then
    checkpoint push_gate_resumed pass "approve resumed: branch pushed to origin, PR created, gate green"
  else
    checkpoint push_gate_resumed fail "approve did not resume push+PR+gate (branch/pr.json/pushed/gate missing)"
  fi

  # (D) STALE-SHA GUARD: a NEW commit after the hold invalidates a prior approval. A second builder
  #     holds sha1, then commits sha2 WITHOUT re-holding; approve must REFUSE at resume and push NOTHING.
  PG_REPO2="$ART/pg-repo2"; PG_BARE2="$ART/pg-origin2.git"
  sandbox_fixture_build "$PG_REPO2" >/dev/null 2>&1
  git init -q --bare "$PG_BARE2"
  git -C "$PG_REPO2" remote add origin "$PG_BARE2"
  _sf_git_env; git -C "$PG_REPO2" push -q origin main 2>/dev/null || true
  git -C "$PG_REPO2" checkout -q -b feat/pg-stale
  printf '\n# v1\n' >> "$PG_REPO2/app/greet.sh"; git -C "$PG_REPO2" add -A && git -C "$PG_REPO2" commit -q -m "pg-stale v1"
  pg_env "$PG_REPO2" bash "$PG_ENGINE/push-gate.sh" hold pg-stale --dir "$PG_REPO2" --branch feat/pg-stale \
      --base main --title "pg stale" >/dev/null 2>&1
  printf '\n# v2\n' >> "$PG_REPO2/app/greet.sh"; git -C "$PG_REPO2" add -A && git -C "$PG_REPO2" commit -q -m "pg-stale v2"
  _pg_stale_rc=0
  pg_env "$PG_REPO2" bash "$PG_ENGINE/herd-approve.sh" approve pg-stale >/dev/null 2>&1 || _pg_stale_rc=$?
  if [ "$_pg_stale_rc" -ne 0 ] && _branch_absent "$PG_BARE2" "feat/pg-stale"; then
    checkpoint push_gate_stale_refused pass "a new commit after the hold invalidated the approval — resume refused, nothing pushed"
  else
    checkpoint push_gate_stale_refused fail "stale (new-commit) approval was NOT refused (rc=$_pg_stale_rc) or branch leaked to origin"
  fi
fi

# ── pipeline steps (HERD-132): operator-defined stages with hold/approve semantics ───────────────
# Proves the seam the item exists for, driving the REAL steps.sh + herd-approve.sh entry points against
# a throwaway fixture with its OWN step list (HERD_STEPS_FILE), a throwaway trees dir for the hold
# ledger + journal, and HERD_CONFIG_FILE pointed at a non-existent path so herd-config.sh never walks up
# into herdkit's OWN .herd/config. A fixture step list of THREE post-build steps — one blocking (on_fail
# =block), one hold=approve, one skill:<name> — plus a 2-step block fixture. Eight assertions: (A) the
# blocking step runs then the approve step HOLDS (the skill step has NOT run yet); (B) the hold surfaces
# in herd-approve.sh list with the worktree path; (C) approve RELEASES + resumes, running the skill
# step; (D) EXECUTION ORDER holds in the journal (block < approve < skill); (E) a FAILING block step
# blocks its seam (a later step never runs); (F) an ABSENT step list is byte-identical (no journal, rc 0);
# (G) the WATCHER-OWNED pre-merge seam: after approve, a FRESH steps_run_at pre-merge (what do_merge
# re-runs every tick, no --resume-after) SKIPS the consumed hold (rc 0 ⇒ merge proceeds) and never
# re-holds or re-appends an awaiting row (the #249 round-1 liveness/ledger-growth regression);
# (H) TWO hold=approve steps at ONE sha gate INDEPENDENTLY — each holds on its own turn, approving the
# first does NOT release the second, and the merge (rc 0) proceeds only after BOTH are approved (the
# #249 round-2 per-sha-keying safety-rail-bypass regression).
step pipeline-steps "steps.tsv stages — order, approve-hold + release, step_run journal, byte-identical off"
ST_ENGINE="$HERE/.."
if [ ! -f "$ST_ENGINE/steps.sh" ] || [ ! -f "$ST_ENGINE/herd-approve.sh" ]; then
  checkpoint pipeline_steps_lib skip "steps.sh / herd-approve.sh not found — pipeline-steps phase skipped"
else
  ST_REPO="$ART/st-repo"; ST_TREES="$ART/st-trees"; mkdir -p "$ST_TREES"
  ST_STEPS="$ART/st-steps.tsv"; ST_JN="$ART/st-journal.jsonl"; : > "$ST_JN"
  # Build the fixture worktree the steps run against + the skill the skill-step resolves.
  sandbox_fixture_build "$ST_REPO" >/dev/null 2>&1
  mkdir -p "$ST_REPO/.claude/skills/demo-review"
  # st_env <cmd…> — run a steps.sh / herd-approve.sh CLI hermetically: HERD_STEPS_FILE points at the
  # fixture list, the ledger lives in a throwaway trees dir, the journal is redirected via JOURNAL_FILE,
  # and HERD_CONFIG_FILE is a non-existent path so no real project config bleeds in.
  st_env() {
    env HERD_CONFIG_FILE="$ART/.st-no-config" PROJECT_ROOT="$ST_REPO" WORKTREES_DIR="$ST_TREES" \
        HERD_STEPS_FILE="$ST_STEPS" JOURNAL_FILE="$ST_JN" NO_COLOR=1 HERD_DRIVER=headless "$@"
  }
  # The three-step fixture list (all post-build so ORDER is unambiguous): block → approve-HOLD → skill.
  {
    printf 'gate-lint\tpost-build\techo gate-lint ok\tblock\tnone\n'
    printf 'peer-review\tpost-build\techo peer-review ran\tblock\tapprove\n'
    printf 'doc-pass\tpost-build\tskill:demo-review\twarn\tnone\n'
  } > "$ST_STEPS"

  # (A) RUN the post-build seam. Assert: rc 20 (HELD), the block step + approve step journaled a pass,
  #     an awaiting hold exists, and the skill step has NOT run yet (nothing proceeds past the hold).
  _st_rc=0
  st_env bash "$ST_ENGINE/steps.sh" run post-build --slug demo-steps --dir "$ST_REPO" >/dev/null 2>&1 || _st_rc=$?
  _st_hold="$ST_TREES/.agent-watch-step-holds"
  if [ "$_st_rc" -eq 20 ] \
     && grep -q '"name":"gate-lint".*"outcome":"pass"' "$ST_JN" 2>/dev/null \
     && grep -q '"name":"peer-review".*"outcome":"held"' "$ST_JN" 2>/dev/null \
     && grep -q "awaiting demo-steps" "$_st_hold" 2>/dev/null \
     && ! grep -q '"name":"doc-pass"' "$ST_JN" 2>/dev/null; then
    checkpoint pipeline_steps_held pass "block step ran, approve step HELD (rc 20), skill step not yet run, hold recorded"
  else
    checkpoint pipeline_steps_held fail "post-build seam did not hold correctly (rc=$_st_rc)"
  fi

  # (B) LIST surfaces the step-hold with the worktree path (what the human reviews).
  ST_LIST="$(st_env bash "$ST_ENGINE/herd-approve.sh" list 2>/dev/null || true)"
  if printf '%s' "$ST_LIST" | grep -q 'demo-steps' \
     && printf '%s' "$ST_LIST" | grep -q 'peer-review' \
     && printf '%s' "$ST_LIST" | grep -q "$ST_REPO"; then
    checkpoint pipeline_steps_listed pass "herd-approve.sh list shows the step-hold (step + worktree path)"
  else
    checkpoint pipeline_steps_listed fail "herd-approve.sh list did not surface the step-hold"
  fi

  # (C) APPROVE releases + resumes: the skill step now runs. Assert: released record, skill step passed,
  #     and no live hold remains (list no longer shows demo-steps).
  st_env bash "$ST_ENGINE/herd-approve.sh" approve demo-steps >/dev/null 2>&1
  ST_LIST2="$(st_env bash "$ST_ENGINE/herd-approve.sh" list 2>/dev/null || true)"
  if grep -q "released demo-steps" "$_st_hold" 2>/dev/null \
     && grep -q '"name":"doc-pass".*"kind":"skill".*"outcome":"pass"' "$ST_JN" 2>/dev/null \
     && ! printf '%s' "$ST_LIST2" | grep -q 'demo-steps'; then
    checkpoint pipeline_steps_released pass "approve released the hold and resumed: skill step ran, hold cleared"
  else
    checkpoint pipeline_steps_released fail "approve did not release + resume the pipeline (skill step / released record missing)"
  fi

  # (D) EXECUTION ORDER: in the journal, the block step's step_run precedes the approve step's, which
  #     precedes the skill step's — the declared file order, honored across the hold/resume boundary.
  _ln_gate="$(grep -n '"name":"gate-lint".*"outcome":"pass"' "$ST_JN" 2>/dev/null | head -1 | cut -d: -f1)"
  _ln_peer="$(grep -n '"name":"peer-review".*"outcome":"pass"' "$ST_JN" 2>/dev/null | head -1 | cut -d: -f1)"
  _ln_doc="$(grep -n '"name":"doc-pass".*"outcome":"pass"' "$ST_JN" 2>/dev/null | head -1 | cut -d: -f1)"
  if [ -n "$_ln_gate" ] && [ -n "$_ln_peer" ] && [ -n "$_ln_doc" ] \
     && [ "$_ln_gate" -lt "$_ln_peer" ] && [ "$_ln_peer" -lt "$_ln_doc" ]; then
    checkpoint pipeline_steps_order pass "step_run journal order held: gate-lint < peer-review < doc-pass"
  else
    checkpoint pipeline_steps_order fail "execution order not preserved (gate=$_ln_gate peer=$_ln_peer doc=$_ln_doc)"
  fi

  # (E) FAILING block step blocks its seam: a two-step list where the first (on_fail=block) exits
  #     non-zero must RETURN non-zero and NEVER run the second step (block ADDS a gate, never bypasses).
  ST_STEPS_B="$ART/st-steps-block.tsv"; ST_JN_B="$ART/st-journal-block.jsonl"; : > "$ST_JN_B"
  {
    printf 'will-fail\tpost-build\tfalse\tblock\tnone\n'
    printf 'must-not-run\tpost-build\techo LEAKED\tblock\tnone\n'
  } > "$ST_STEPS_B"
  _st_brc=0
  env HERD_CONFIG_FILE="$ART/.st-no-config" PROJECT_ROOT="$ST_REPO" WORKTREES_DIR="$ART/st-trees-b" \
      HERD_STEPS_FILE="$ST_STEPS_B" JOURNAL_FILE="$ST_JN_B" NO_COLOR=1 HERD_DRIVER=headless \
      bash "$ST_ENGINE/steps.sh" run post-build --slug demo-block --dir "$ST_REPO" >/dev/null 2>&1 || _st_brc=$?
  if [ "$_st_brc" -eq 1 ] \
     && grep -q '"name":"will-fail".*"outcome":"fail"' "$ST_JN_B" 2>/dev/null \
     && ! grep -q '"name":"must-not-run"' "$ST_JN_B" 2>/dev/null; then
    checkpoint pipeline_steps_block pass "a failing on_fail=block step blocked the seam (rc 1); the next step never ran"
  else
    checkpoint pipeline_steps_block fail "on_fail=block did not block correctly (rc=$_st_brc)"
  fi

  # (F) BYTE-IDENTICAL OFF: with an ABSENT step list the runner is inert — rc 0, zero journal events.
  ST_JN_OFF="$ART/st-journal-off.jsonl"; : > "$ST_JN_OFF"
  _st_orc=0
  env HERD_CONFIG_FILE="$ART/.st-no-config" PROJECT_ROOT="$ST_REPO" WORKTREES_DIR="$ART/st-trees-off" \
      HERD_STEPS_FILE="$ART/st-absent.tsv" JOURNAL_FILE="$ST_JN_OFF" NO_COLOR=1 HERD_DRIVER=headless \
      bash "$ST_ENGINE/steps.sh" run post-build --slug demo-off --dir "$ST_REPO" >/dev/null 2>&1 || _st_orc=$?
  if [ "$_st_orc" -eq 0 ] && [ ! -s "$ST_JN_OFF" ]; then
    checkpoint pipeline_steps_off pass "absent step list ⇒ byte-identical no-op (rc 0, zero journal events)"
  else
    checkpoint pipeline_steps_off fail "absent step list was NOT inert (rc=$_st_orc, journal bytes=$( wc -c < "$ST_JN_OFF" 2>/dev/null ))"
  fi

  # (G) WATCHER-OWNED pre-merge approve-hold — the do_merge re-tick regression (review BLOCK on PR #249).
  #     The watcher runs `steps_run_at pre-merge` FRESH every tick with NO --resume-after (agent-watch.sh
  #     do_merge). After a human approves a pre-merge hold=approve step, the NEXT such fresh pass MUST
  #     recognise the released hold and SKIP past it (rc 0 ⇒ do_merge proceeds to merge) — NOT re-execute
  #     + re-hold (rc 20) forever. It must also NOT re-append an 'awaiting' row (the ledger stays bounded
  #     across ticks). This drives the exact seam the post-build assertions (A–D) could not: a fresh
  #     seam re-invocation after release, which is what the watcher does — the regression's blind spot.
  ST_STEPS_M="$ART/st-steps-merge.tsv"; ST_JN_M="$ART/st-journal-merge.jsonl"; : > "$ST_JN_M"
  ST_TREES_M="$ART/st-trees-merge"; mkdir -p "$ST_TREES_M"
  {
    printf 'pre-gate\tpre-merge\techo pre-gate ok\tblock\tnone\n'
    printf 'human-check\tpre-merge\techo human-check ran\tblock\tapprove\n'
    printf 'post-gate\tpre-merge\techo post-gate ok\tblock\tnone\n'
  } > "$ST_STEPS_M"
  stm_env() {
    env HERD_CONFIG_FILE="$ART/.st-no-config" PROJECT_ROOT="$ST_REPO" WORKTREES_DIR="$ST_TREES_M" \
        HERD_STEPS_FILE="$ST_STEPS_M" JOURNAL_FILE="$ST_JN_M" NO_COLOR=1 HERD_DRIVER=headless "$@"
  }
  _stm_hold="$ST_TREES_M/.agent-watch-step-holds"
  # G1: the first pre-merge pass HOLDS on human-check (rc 20).
  _stm_rc1=0
  stm_env bash "$ST_ENGINE/steps.sh" run pre-merge --slug demo-merge --dir "$ST_REPO" >/dev/null 2>&1 || _stm_rc1=$?
  # G2: human approves (records approved + released, resumes the remaining steps in-process).
  stm_env bash "$ST_ENGINE/herd-approve.sh" approve demo-merge >/dev/null 2>&1
  _stm_await_before="$(grep -c 'awaiting demo-merge' "$_stm_hold" 2>/dev/null)"; _stm_await_before="${_stm_await_before:-0}"
  # G3: the WATCHER RE-TICK — a fresh pre-merge pass from the top (no --resume-after), exactly what
  #     do_merge runs on the next tick. MUST return 0 (the merge would now proceed).
  _stm_rc2=0
  stm_env bash "$ST_ENGINE/steps.sh" run pre-merge --slug demo-merge --dir "$ST_REPO" >/dev/null 2>&1 || _stm_rc2=$?
  # G4: a THIRD re-tick stays byte-stable (still rc 0, still one awaiting row) — the loop + ledger growth
  #     are both gone (before the fix rc2/rc3 were 20 and the awaiting count grew by one per tick).
  _stm_rc3=0
  stm_env bash "$ST_ENGINE/steps.sh" run pre-merge --slug demo-merge --dir "$ST_REPO" >/dev/null 2>&1 || _stm_rc3=$?
  _stm_await_final="$(grep -c 'awaiting demo-merge' "$_stm_hold" 2>/dev/null)"; _stm_await_final="${_stm_await_final:-0}"
  if [ "$_stm_rc1" -eq 20 ] && [ "$_stm_rc2" -eq 0 ] && [ "$_stm_rc3" -eq 0 ] \
     && [ "$_stm_await_before" = "1" ] && [ "$_stm_await_final" = "1" ]; then
    checkpoint pipeline_steps_merge_resume pass "approved pre-merge hold is CONSUMED: watcher re-tick returns 0 (merge proceeds), ledger stays at 1 awaiting row (bounded)"
  else
    checkpoint pipeline_steps_merge_resume fail "approved pre-merge hold not consumed by the watcher re-tick (rc1=$_stm_rc1 rc2=$_stm_rc2 rc3=$_stm_rc3 awaiting before/final=$_stm_await_before/$_stm_await_final)"
  fi

  # (H) TWO hold=approve steps at ONE sha gate INDEPENDENTLY — the per-sha-keying safety-rail-bypass
  #     regression (review BLOCK on PR #249, round 2). Records keyed by (slug,sha) alone meant approving
  #     step 1 consumed the sha's record so step 2's hold silently never fired — a merge that skips a
  #     configured human gate. With per-(slug,sha,step) keying each approve-step must be approved on its
  #     own. Fixture: two pre-merge hold=approve steps (check-a, check-b) around a final plain step.
  ST_STEPS_2="$ART/st-steps-two.tsv"; ST_JN_2="$ART/st-journal-two.jsonl"; : > "$ST_JN_2"
  ST_TREES_2="$ART/st-trees-two"; mkdir -p "$ST_TREES_2"
  {
    printf 'check-a\tpre-merge\techo check-a ran\tblock\tapprove\n'
    printf 'check-b\tpre-merge\techo check-b ran\tblock\tapprove\n'
    printf 'final-gate\tpre-merge\techo final-gate ok\tblock\tnone\n'
  } > "$ST_STEPS_2"
  st2_env() {
    env HERD_CONFIG_FILE="$ART/.st-no-config" PROJECT_ROOT="$ST_REPO" WORKTREES_DIR="$ST_TREES_2" \
        HERD_STEPS_FILE="$ST_STEPS_2" JOURNAL_FILE="$ST_JN_2" NO_COLOR=1 HERD_DRIVER=headless "$@"
  }
  _st2_hold="$ST_TREES_2/.agent-watch-step-holds"
  _st2_ok=1
  # H1: first pass HOLDS on check-a (rc 20); check-b has NOT held yet (independent, sequential).
  _st2_rc1=0
  st2_env bash "$ST_ENGINE/steps.sh" run pre-merge --slug demo-two --dir "$ST_REPO" >/dev/null 2>&1 || _st2_rc1=$?
  [ "$_st2_rc1" -eq 20 ] || _st2_ok=0
  grep -q 'awaiting demo-two .* check-a$' "$_st2_hold" 2>/dev/null || _st2_ok=0
  grep -q 'awaiting demo-two .* check-b$' "$_st2_hold" 2>/dev/null && _st2_ok=0   # check-b must NOT be holding yet
  # H2: approve check-a. It RELEASES check-a and resumes → check-b now HOLDS. Approving one must NOT
  #     release the other: check-a released, check-b awaiting-but-NOT-released.
  st2_env bash "$ST_ENGINE/herd-approve.sh" approve demo-two >/dev/null 2>&1
  grep -q 'released demo-two .* check-a$' "$_st2_hold" 2>/dev/null || _st2_ok=0
  grep -q 'awaiting demo-two .* check-b$'  "$_st2_hold" 2>/dev/null || _st2_ok=0
  grep -q 'released demo-two .* check-b$'  "$_st2_hold" 2>/dev/null && _st2_ok=0   # check-b NOT released by approving check-a
  # H3: the WATCHER RE-TICK (fresh pre-merge, no --resume-after) MUST still HOLD on check-b (rc 20) —
  #     the merge does NOT proceed while a second gate is unapproved (before the fix this returned 0 and
  #     the merge bypassed check-b).
  _st2_rc2=0
  st2_env bash "$ST_ENGINE/steps.sh" run pre-merge --slug demo-two --dir "$ST_REPO" >/dev/null 2>&1 || _st2_rc2=$?
  [ "$_st2_rc2" -eq 20 ] || _st2_ok=0
  # H4: approve check-b, then a fresh pre-merge pass returns 0 — BOTH gates cleared, merge proceeds, and
  #     final-gate (the plain step after both holds) ran.
  st2_env bash "$ST_ENGINE/herd-approve.sh" approve demo-two >/dev/null 2>&1
  grep -q 'released demo-two .* check-b$' "$_st2_hold" 2>/dev/null || _st2_ok=0
  _st2_rc3=0
  st2_env bash "$ST_ENGINE/steps.sh" run pre-merge --slug demo-two --dir "$ST_REPO" >/dev/null 2>&1 || _st2_rc3=$?
  [ "$_st2_rc3" -eq 0 ] || _st2_ok=0
  grep -q '"name":"final-gate".*"outcome":"pass"' "$ST_JN_2" 2>/dev/null || _st2_ok=0
  # Ledger stays bounded: exactly one awaiting row per step (two total), no per-tick growth.
  _st2_await_ct="$(grep -c 'awaiting demo-two' "$_st2_hold" 2>/dev/null)"; _st2_await_ct="${_st2_await_ct:-0}"
  [ "$_st2_await_ct" = "2" ] || _st2_ok=0
  if [ "$_st2_ok" -eq 1 ]; then
    checkpoint pipeline_steps_two_approve pass "two hold=approve steps gate independently: approving check-a does NOT release check-b; merge proceeds (rc 0) only after BOTH approved; ledger bounded (2 awaiting rows)"
  else
    checkpoint pipeline_steps_two_approve fail "independent double-approve gate failed (rc1=$_st2_rc1 rc2=$_st2_rc2 rc3=$_st2_rc3 awaiting_ct=$_st2_await_ct)"
  fi
fi

# ── notify hermeticity invariant (HERD-139) ─────────────────────────────────────────────────────
# Every notification any phase produced must have landed in the sink, NEVER a real desktop channel.
# The notify stub captures any native osascript/notify-send attempt; with the fix in place that count
# is 0 for the whole run — a non-zero count means a scenario leaked an alarm onto the operator's
# screen (the exact 2026-07-08 cry-wolf regression this guards against).
step notify "harness invariant — zero notifications delivered outside the sink"
_notify_native="$(sim_notify_native_attempts)"
if [ "$_notify_native" = 0 ]; then
  checkpoint notify_hermetic pass "no native desktop notification fired during the run (all notifications captured to the sink)"
else
  checkpoint notify_hermetic fail "$_notify_native native desktop notification(s) LEAKED outside the sink (see $SIM_NOTIFY_CAPTURED)"
fi

# ── scorecard ───────────────────────────────────────────────────────────────────
# A non-optional skip (an expected phase that could NOT run) degrades a clean "pass" to
# "pass-with-skips" so a silently-skipped phase never masquerades as full coverage. A real failure
# still dominates (result=fail). "skip-optional" (designed conditional skips) never degrades.
RESULT="pass"
[ "$_skip_req" -gt 0 ] && RESULT="pass-with-skips"
[ "$_fail" -gt 0 ] && RESULT="fail"
SCARD="$(write_scorecard "$RESULT" "$FIXTURE_SHA")"
printf '\n%s══ scorecard ══%s\n' "$c_bold" "$c_rst"
printf '  scenario:   %s\n' "$SCENARIO"
printf '  result:     %s\n' "$RESULT"
printf '  passed:     %d\n' "$_pass"
printf '  failed:     %d\n' "$_fail"
printf '  scorecard:  %s\n' "$SCARD"
printf '  artifacts:  %s\n' "$ART"

# Exit 1 only on a real FAILURE; pass and pass-with-skips both exit 0 (nothing FAILED — the skip gap
# is flagged in the scorecard RESULT and enforced by the wrapper, which pins every phase checkpoint).
[ "$RESULT" = "fail" ] && exit 1 || exit 0
