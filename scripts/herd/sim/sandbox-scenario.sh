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
# shellcheck source=scripts/herd/sim/posture-lib.sh
. "$HERE/posture-lib.sh"       # canonical config postures (HERD-153) — see templates/postures.tsv

# ── output helpers (mirror cross-repo-loop-sim.sh's style) ──────────────────────────────────────
c_bold=$'\033[1m'; c_dim=$'\033[2m'
c_grn=$'\033[32m'; c_red=$'\033[31m'; c_yel=$'\033[33m'; c_rst=$'\033[0m'
step() { printf '\n%s[%s]%s %s\n' "$c_bold" "$1" "$c_rst" "$2"; }
ok()   { printf '  %s✓%s %s\n' "$c_grn" "$c_rst" "$*"; }
bad()  { printf '  %s✗%s %s\n' "$c_red" "$c_rst" "$*"; }
skip() { printf '  %s–%s %s\n' "$c_yel" "$c_rst" "$*"; }
info() { printf '  %s→%s %s\n' "$c_dim" "$c_rst" "$*"; }

# ── args ────────────────────────────────────────────────────────────────────────
# --posture <name> selects a canonical config posture (HERD-153, templates/postures.tsv). This
# scenario owns the PUSH / STEPS postures (gated-push | custom-steps): it drives the SHIPPED push-gate
# and pipeline-steps seams (below) and, when a posture is given, asserts that posture's invariant as a
# posture_invariant checkpoint + a posture-tagged scorecard field. An ABSENT --posture is byte-identical
# to today's run (POSTURE="" → no posture field, no posture phase).
ART=""; KEEP=""; POSTURE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --artifacts) ART="${2:-}"; KEEP=1; shift 2 ;;
    --keep)      KEEP=1; shift ;;
    --posture)   POSTURE="${2:-}"; shift 2 ;;
    -h|--help)   grep -E '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "sandbox-scenario: unknown arg: $1" >&2; exit 1 ;;
  esac
done
if [ -n "$POSTURE" ]; then
  posture_exists "$POSTURE" || { echo "sandbox-scenario: unknown posture: $POSTURE" >&2; exit 1; }
  case "$POSTURE" in
    gated-push|custom-steps) : ;;
    *) echo "sandbox-scenario: posture '$POSTURE' is not a push/steps posture (merge-policy postures run through sandbox-concurrency-scenario.sh)" >&2; exit 1 ;;
  esac
  posture_apply "$POSTURE"
fi
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
    # POSTURE is empty on the default run → line omitted → scorecard BYTE-IDENTICAL to today's.
    [ -n "$POSTURE" ] && printf '  "posture": "%s",\n' "$POSTURE"
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
  # Driver: source agent-watch.sh in lib mode, DISPATCH main_health_tick (now ASYNC — HERD-185), AWAIT
  # the backgrounded suite, COLLECT it, then build + print the rendered row on stdout. This mirrors the
  # real watcher loop, whose tick top runs _collect_main_health before build_main_health, except we
  # block here (bounded) so the one-shot driver observes the settled outcome. HERD_DRIVER=headless routes
  # any notification to a log (never the live herdr workspace); NO_COLOR keeps the row plain-text to grep.
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
# ASYNC await: wait for the backgrounded suite's dispatch result (bounded). If nothing was dispatched
# (feature OFF, or no slot/bin), there is no inflight marker either → stop immediately (stays inert).
_n=0
while [ "$_n" -lt 200 ]; do
  ls "$2"/.health-dispatch-main-* >/dev/null 2>&1 && break
  ls "$2"/.health-inflight-main-* >/dev/null 2>&1 || break
  sleep 0.05; _n=$((_n + 1))
done
_collect_main_health >/dev/null 2>&1
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

# ── cross-seat BLOCK precedence (HERD-247): one seat's BLOCK outranks another seat's PASS ────────
# The gate phases above prove a BROKEN change never merges. This phase proves the OTHER failure class,
# the one PR #343 hit on 2026-07-09: a change that THIS seat's gates call green, while ANOTHER seat's
# reviewer has a standing correctness BLOCK on the very same sha. Each seat's review ledger is local, so
# only the SHARED artifacts (the herd/gates commit status + the PR's comments) can see the conflict.
# We drive the REAL guard from scripts/herd/agent-watch.sh (AGENT_WATCH_LIB=1) with `gh` stubbed to
# serve a seeded foreign-BLOCK comment fixture, and assert the scenario ends HELD: no blessing posted,
# the merge held behind the loud reconcile row — and that the blocking seat's own later PASS releases it.
step cross-seat-block "herd/gates BLOCK precedence — a foreign BLOCK outranks our PASS until resolved"
WATCH_SH="$HERE/../agent-watch.sh"
if [ ! -f "$WATCH_SH" ]; then
  checkpoint cross_seat_block_lib skip "agent-watch.sh not found at $WATCH_SH — cross-seat phase skipped"
else
  XS="$ART/xseat"; mkdir -p "$XS/bin" "$XS/trees"
  # gh stub: the two shared artifacts the guard reads, plus the statuses WRITE it must not perform.
  # Every invocation is logged, so "was a blessing posted?" is an observable fact, not an inference.
  cat > "$XS/bin/gh" <<'GHSTUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "view" ]; then cat "$GH_COMMENTS_FILE"; exit 0; fi
url=""; prev=""
for a in "$@"; do [ "$prev" = "api" ] && { url="$a"; break; }; prev="$a"; done
case "$url" in
  */commits/*/statuses) printf '' ;;                       # no herd/gates status on the sha yet
  */commits/*)          printf '2026-07-09T16:10:00Z' ;;   # when the head sha landed
  */statuses/*)         exit 0 ;;                          # the blessing WRITE (must never happen held)
  *)                    exit 0 ;;
esac
GHSTUB
  chmod +x "$XS/bin/gh"
  # Driver: source the watcher in lib mode, run the REAL guard, then the REAL setter, and report
  # STANDING/SEAT/BLESSED as three plain lines. $1=comments fixture $2=gh log $3=trees $4=journal.
  cat > "$XS/driver.sh" <<'XSDRV'
#!/usr/bin/env bash
set -u
export PATH="$5/bin:$PATH" GH_COMMENTS_FILE="$1" GH_LOG="$2"
export AGENT_WATCH_LIB=1 HERD_DRIVER=headless NO_COLOR=1
export WORKTREES_DIR="$3" JOURNAL_FILE="$4" HERD_CONFIG_FILE="$3/.no-such-config"
export WATCHER_OWNER="seat-b"     # THIS seat: the one whose gates are green
export _XSEAT_MEMO_TTL=0          # no stale memo across the two legs of this driver
# shellcheck source=/dev/null
. "$6" >/dev/null 2>&1 || { echo "SRC_FAIL"; exit 3; }
if _cross_seat_block_standing 343 simsha; then
  printf 'STANDING=yes\nSEAT=%s\nROW=%s\n' "$_XSEAT_SEAT" "$(_cross_seat_block_row "sim" " #343 ·" "$_XSEAT_SEAT")"
else
  printf 'STANDING=no\nSEAT=\nROW=\n'
fi
post_gate_status 343 simsha success
if grep -q 'statuses/simsha' "$GH_LOG" 2>/dev/null; then printf 'BLESSED=yes\n'; else printf 'BLESSED=no\n'; fi
XSDRV
  # xs_drive <comments-json> — run one leg against a fresh gh log + journal; echo the driver's report.
  xs_drive() {
    : > "$XS/gh.log"; : > "$XS/journal.jsonl"; rm -f "$XS/trees/.agent-watch-gate-status"
    bash "$XS/driver.sh" "$1" "$XS/gh.log" "$XS/trees" "$XS/journal.jsonl" "$XS" "$WATCH_SH" 2>/dev/null
  }
  # Leg 1 — seat-a BLOCKs simsha at 16:19Z; seat-b (us) PASSes it at 16:23Z. Exactly the #343 shape.
  cat > "$XS/held.json" <<'XSJSON'
{"comments": [
  {"author": {"login": "seat-a"}, "createdAt": "2026-07-09T16:19:00Z",
   "body": "REVIEW: **BLOCK** — rule: safety-rail bypass | why: a limit-parked resolver reads idle | location: agent-watch.sh"},
  {"author": {"login": "seat-b"}, "createdAt": "2026-07-09T16:23:00Z",
   "body": "**Pre-merge correctness review — PASS (no blocking findings).**"}
]}
XSJSON
  XS_HELD="$(xs_drive "$XS/held.json")"
  _xs_get() { printf '%s\n' "$1" | grep "^$2=" | head -1 | cut -d= -f2- ; }
  if [ "$(_xs_get "$XS_HELD" STANDING)" = "yes" ] && [ "$(_xs_get "$XS_HELD" SEAT)" = "seat-a" ] \
     && printf '%s' "$XS_HELD" | grep -q 'cross-seat BLOCK · needs reconcile'; then
    checkpoint cross_seat_block_held pass "our PASS did NOT overwrite seat-a's standing BLOCK: scenario ends HELD with the reconcile row"
  else
    checkpoint cross_seat_block_held fail "a standing foreign BLOCK was not honored (report: $(printf '%s' "$XS_HELD" | tr '\n' ' '))"
  fi
  if [ "$(_xs_get "$XS_HELD" BLESSED)" = "no" ] && grep -q cross_seat_block_honored "$XS/journal.jsonl" 2>/dev/null; then
    checkpoint cross_seat_block_no_bless pass "no herd/gates=success posted over the standing BLOCK; cross_seat_block_honored journaled"
  else
    checkpoint cross_seat_block_no_bless fail "a blessing leaked, or the honored event was not journaled (blessed=$(_xs_get "$XS_HELD" BLESSED))"
  fi
  # Leg 2 — RESOLUTION on an existing surface: the BLOCKING seat re-reviews the same sha to PASS.
  cat > "$XS/resolved.json" <<'XSJSON'
{"comments": [
  {"author": {"login": "seat-a"}, "createdAt": "2026-07-09T16:19:00Z",
   "body": "REVIEW: **BLOCK** — rule: safety-rail bypass | why: a limit-parked resolver reads idle | location: agent-watch.sh"},
  {"author": {"login": "seat-b"}, "createdAt": "2026-07-09T16:23:00Z",
   "body": "**Pre-merge correctness review — PASS (no blocking findings).**"},
  {"author": {"login": "seat-a"}, "createdAt": "2026-07-09T17:05:00Z",
   "body": "REVIEW: PASS — the addressed sha now honors the limit-park check."}
]}
XSJSON
  XS_OK="$(xs_drive "$XS/resolved.json")"
  if [ "$(_xs_get "$XS_OK" STANDING)" = "no" ] && [ "$(_xs_get "$XS_OK" BLESSED)" = "yes" ]; then
    checkpoint cross_seat_block_resolved pass "the blocking seat's later PASS on the same sha released the hold — the blessing posts and the merge proceeds"
  else
    checkpoint cross_seat_block_resolved fail "resolution did not release the hold (report: $(printf '%s' "$XS_OK" | tr '\n' ' '))"
  fi
fi

# ── mixed-vendor review panel (HERD-276): per-panelist driver refs + verdict merge policy ────────
# The cross-seat phase above proves a FOREIGN seat's BLOCK is honored. This phase proves the gate's own
# panel now reviews with SEVERAL VENDORS at once, and that the three ways a vendor can fail to vote all
# land as INFRA (a bounded watcher retry) rather than as a BLOCK cached against the sha.
#
# Zero-quota by construction: every panelist runs the STUB PROOF DRIVER (templates/drivers/stub.driver),
# whose runtime is a fictional `stub-agent`. We put a fake `stub-agent` on PATH that prints one
# stream-json verdict line — so the REAL herd-review.sh, the REAL driver seam, and the REAL verdict
# resolver execute end-to-end with NO model call and no network. That the stub driver names a NON-claude
# binary is exactly what makes this a mixed-vendor proof: leg A observes two different binaries launched
# from ONE panel.
step review-panel "mixed-vendor panel — per-panelist runtimes, policy fold, INFRA never a false BLOCK"
REVIEW_SH="$HERE/../herd-review.sh"
if [ ! -f "$REVIEW_SH" ]; then
  checkpoint review_panel_lib skip "herd-review.sh not found at $REVIEW_SH — review-panel phase skipped"
else
  RP="$ART/review-panel"; mkdir -p "$RP/bin" "$RP/trees"
  # gh/git/herdr stubs: this phase asserts the VERDICT contract, not PR plumbing. herd-review.sh must
  # never post a comment or fetch a pin here, and HERD_NO_PANE keeps it off the pane path.
  for _c in gh git; do printf '#!/usr/bin/env bash\nexit 0\n' > "$RP/bin/$_c"; chmod +x "$RP/bin/$_c"; done
  printf '#!/usr/bin/env bash\ncase "$1 $2" in "agent list") printf %s "{\\"result\\":{\\"agents\\":[]}}" ;; *) exit 0 ;; esac\n' > "$RP/bin/herdr"
  chmod +x "$RP/bin/herdr"
  # rp_runtime <binary> <verdict> — a fake agent runtime that RECORDS which binary ran with which
  # --model, then prints one stream-json result line carrying <verdict>. The recording is what turns
  # "the panel is mixed-vendor" from a claim into an observable fact.
  rp_runtime() {
    cat > "$RP/bin/$1" <<RPSTUB
#!/usr/bin/env bash
m=""; prev=""
for a in "\$@"; do [ "\$prev" = "--model" ] && { m="\$a"; break; }; prev="\$a"; done
printf '%s %s\n' "$1" "\$m" >> "\$RP_CALLS"
printf '{"type":"result","subtype":"success","result":"%s"}\n' "$2"
RPSTUB
    chmod +x "$RP/bin/$1"
  }
  # rp_drive <leg> <refs> <policy> — run the REAL herd-review.sh in PR mode against the fixture repo.
  # PATH is prefixed ONLY inside this subshell, so the stub `git` can never leak into a later phase.
  # Echoes "<rc>|<verdict line>"; the per-leg call log lands in $RP/calls-<leg>.
  rp_drive() {
    local leg="$1" refs="$2" policy="$3" out rc
    export RP_CALLS="$RP/calls-$leg"; : > "$RP_CALLS"
    out="$( export PATH="$RP/bin:$PATH"; \
            env RP_CALLS="$RP_CALLS" HERD_NO_PANE=1 NO_COLOR=1 \
                REVIEW_PANEL_MODELS="$refs" REVIEW_PANEL_POLICY="$policy" \
                HERD_REVIEW_MODEL="sim-review-model" \
                WORKTREES_DIR="$RP/trees" HERD_CONFIG_FILE="$RP/.no-such-config" \
                JOURNAL_FILE="$RP/journal-$leg.jsonl" \
                bash "$REVIEW_SH" "77$leg" "sim-panel-$leg" 2>/dev/null )"
    rc=$?
    printf '%s|%s' "$rc" "$out"
  }
  _rp_rc()   { printf '%s' "${1%%|*}"; }
  _rp_line() { printf '%s' "${1#*|}"; }

  # ── Leg A — TWO VENDORS, one panel. A bare ref runs the default runtime (`claude`); a `stub:` ref
  # runs `stub-agent`. Both PASS ⇒ combined PASS. This is the wiring HERD-276 exists for.
  rp_runtime claude     'REVIEW: PASS'
  rp_runtime stub-agent 'REVIEW: PASS'
  RP_A="$(rp_drive a "bare-model stub:stub-model" any-block)"
  _rp_calls_a="$(cat "$RP/calls-a" 2>/dev/null | tr '\n' ';')"
  if [ "$(_rp_rc "$RP_A")" = "0" ] && [ "$(_rp_line "$RP_A")" = "REVIEW: PASS" ] \
     && grep -qx 'claude bare-model' "$RP/calls-a" 2>/dev/null \
     && grep -qx 'stub-agent stub-model' "$RP/calls-a" 2>/dev/null; then
    checkpoint review_panel_mixed_dispatch pass "one panel launched TWO runtimes (claude + stub-agent), each on its own ref; combined PASS"
  else
    checkpoint review_panel_mixed_dispatch fail "mixed dispatch failed (rc=$(_rp_rc "$RP_A") line='$(_rp_line "$RP_A")' calls=$_rp_calls_a)"
  fi

  # ── Leg B — one vendor finds a real bug. A single BLOCK from ANY panelist blocks the merge under the
  # default policy, and the structured HERD-104 line survives the fold intact (the auto-refix bounce
  # reads rule/why/location out of it).
  rp_runtime stub-agent 'REVIEW: BLOCK — rule: off-by-one | why: overshoots the last row | location: app/greet.sh:3'
  RP_B="$(rp_drive b "bare-model stub:stub-model" any-block)"
  if [ "$(_rp_rc "$RP_B")" = "1" ] \
     && printf '%s' "$(_rp_line "$RP_B")" | grep -q '^REVIEW: BLOCK — rule: off-by-one'; then
    checkpoint review_panel_vendor_block pass "a lone dissenting vendor's structured BLOCK gated the merge (exit 1) and survived the fold"
  else
    checkpoint review_panel_vendor_block fail "a vendor BLOCK did not gate the merge (rc=$(_rp_rc "$RP_B") line='$(_rp_line "$RP_B")')"
  fi

  # ── Leg C — the SAFETY invariant: a configured vendor whose binary is NOT installed must report INFRA,
  # never a BLOCK. Under all-pass that coverage gap folds to INFRA-FAIL (exit 2 → the watcher RETRIES and
  # must not cache it), and the clean co-panelist's PASS does not paper over the gap either. A false BLOCK
  # here would be the worst outcome: a sticky, un-actionable refusal cached against the sha.
  rp_runtime claude 'REVIEW: PASS'
  rm -f "$RP/bin/stub-agent"
  RP_C="$(rp_drive c "bare-model stub:stub-model" all-pass)"
  _rp_line_c="$(_rp_line "$RP_C")"
  if [ "$(_rp_rc "$RP_C")" = "2" ] && printf '%s' "$_rp_line_c" | grep -q '^REVIEW: INFRA-FAIL' \
     && ! printf '%s' "$_rp_line_c" | grep -q 'BLOCK'; then
    checkpoint review_panel_missing_binary_infra pass "an absent vendor binary folded to INFRA-FAIL (retry), never a BLOCK — under all-pass a clean co-panelist cannot mask the gap"
  else
    checkpoint review_panel_missing_binary_infra fail "an absent vendor binary did not fold to a BLOCK-free INFRA-FAIL (rc=$(_rp_rc "$RP_C") line='$_rp_line_c')"
  fi

  # ── Leg D — the same absent vendor under the DEFAULT policy is merely a lost vote: the reachable
  # panelist's PASS still carries the merge. all-pass vs any-block must actually differ, or the policy
  # key is decorative. Same inputs as leg C, one key changed.
  RP_D="$(rp_drive d "bare-model stub:stub-model" any-block)"
  if [ "$(_rp_rc "$RP_D")" = "0" ] && [ "$(_rp_line "$RP_D")" = "REVIEW: PASS" ]; then
    checkpoint review_panel_policy_differs pass "policy is load-bearing: the SAME absent vendor is INFRA under all-pass but a lost vote under any-block (PASS)"
  else
    checkpoint review_panel_policy_differs fail "any-block did not tolerate the absent vendor (rc=$(_rp_rc "$RP_D") line='$(_rp_line "$RP_D")')"
  fi

  # ── Provenance — a folded one-line verdict cannot tell an operator WHICH vendor said what. Leg A's
  # journal must carry one review_panelist_verdict row per panelist (with its ref) plus the sha-keyed
  # review_panel_folded row naming the policy the gate applied.
  RP_JA="$RP/journal-a.jsonl"
  if [ -s "$RP_JA" ] && [ "$(grep -c 'review_panelist_verdict' "$RP_JA" 2>/dev/null | tr -cd '0-9')" = "2" ] \
     && grep -q 'stub:stub-model' "$RP_JA" 2>/dev/null && grep -q 'review_panel_folded' "$RP_JA" 2>/dev/null; then
    checkpoint review_panel_provenance pass "the journal attributes each verdict to its panelist ref, and records the policy the fold applied"
  else
    checkpoint review_panel_provenance fail "per-panelist provenance missing from the journal ($RP_JA)"
  fi

  # ── Dormancy — the whole feature is opt-in. With REVIEW_PANEL_MODELS EMPTY the review is the
  # pre-HERD-276 single reviewer on REVIEW_MODEL: exactly one call, and never the stub runtime.
  rp_runtime claude     'REVIEW: PASS'
  rp_runtime stub-agent 'REVIEW: PASS'
  RP_E="$(rp_drive e "" any-block)"
  _rp_n_e="$(grep -c . "$RP/calls-e" 2>/dev/null | tr -cd '0-9')"
  if [ "$(_rp_rc "$RP_E")" = "0" ] && [ "${_rp_n_e:-0}" = "1" ] \
     && grep -qx 'claude sim-review-model' "$RP/calls-e" 2>/dev/null; then
    checkpoint review_panel_dormant pass "REVIEW_PANEL_MODELS unset ⇒ ONE reviewer on REVIEW_MODEL via the default runtime (byte-identical single-model path)"
  else
    checkpoint review_panel_dormant fail "the dormant default did not run a single default-runtime reviewer (rc=$(_rp_rc "$RP_E") calls=$(tr '\n' ';' < "$RP/calls-e" 2>/dev/null))"
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

# ── POSTURE INVARIANT (HERD-153) — asserted only under --posture; byte-inert otherwise ────────────
# gated-push and custom-steps assert the invariant the posture exists for, on top of the phases above.
# The check is a SINGLE posture_invariant checkpoint so the matrix wrapper reads one verdict per posture,
# and — for custom-steps — SANDBOX_FORCE_STEPS_FAULT=1 injects the PR #249 defect class (a steps ledger
# that DOUBLE-releases / releases a STALE sha) so the sim's release-once guard is proven to catch it RED
# (the fault-injection self-check convention from PR #274: the forced fault flips EXACTLY this checkpoint).
if [ -n "$POSTURE" ]; then
  # _cp_status <name> — echo the recorded status of an already-emitted checkpoint (empty if absent).
  _cp_status() {
    local want="$1" i n; n=${#CP_NAMES[@]}
    for ((i=0; i<n; i++)); do [ "${CP_NAMES[$i]}" = "$want" ] && { printf '%s' "${CP_STATUS[$i]}"; return 0; }; done
  }
  if [ "$POSTURE" = gated-push ]; then
    step posture "posture=gated-push — invariant: nothing reaches the remote before a human approves the push"
    # The push-gate phase already drove the SHIPPED PUSH_GATE=human seam. The posture invariant is
    # exactly its two egress-safety checkpoints: a finished builder HELD with NOTHING pushed, and a
    # stale (new-commit) approval REFUSED with nothing pushed. Both green ⇒ the invariant holds.
    if [ "$(_cp_status push_gate_held_no_push)" = pass ] && [ "$(_cp_status push_gate_stale_refused)" = pass ]; then
      checkpoint posture_invariant pass "gated-push: no branch reached origin before approval (held+no-push) and a stale-sha approval was refused"
    else
      checkpoint posture_invariant fail "gated-push egress invariant broke (held_no_push=$(_cp_status push_gate_held_no_push), stale_refused=$(_cp_status push_gate_stale_refused))"
    fi
  elif [ "$POSTURE" = custom-steps ]; then
    step posture "posture=custom-steps — invariant: an approve-stage hold RELEASES exactly once per (sha,step)"
    PS_ENGINE="$HERE/.."
    if [ ! -f "$PS_ENGINE/steps.sh" ] || [ ! -f "$PS_ENGINE/herd-approve.sh" ]; then
      checkpoint posture_invariant skip "steps.sh / herd-approve.sh not found — custom-steps posture invariant skipped"
    else
      PS_REPO="$ART/ps-repo"; PS_TREES="$ART/ps-trees"; mkdir -p "$PS_TREES"
      PS_STEPS="$ART/ps-steps.tsv"; PS_JN="$ART/ps-journal.jsonl"; : > "$PS_JN"
      sandbox_fixture_build "$PS_REPO" >/dev/null 2>&1
      # The STEPS_PROFILE=approve-stage fixture: two pre-merge hold=approve stages around a plain gate.
      {
        printf 'rel-a\tpre-merge\techo rel-a ran\tblock\tapprove\n'
        printf 'rel-b\tpre-merge\techo rel-b ran\tblock\tapprove\n'
        printf 'final\tpre-merge\techo final ok\tblock\tnone\n'
      } > "$PS_STEPS"
      ps_env() {
        env HERD_CONFIG_FILE="$ART/.ps-no-config" PROJECT_ROOT="$PS_REPO" WORKTREES_DIR="$PS_TREES" \
            HERD_STEPS_FILE="$PS_STEPS" JOURNAL_FILE="$PS_JN" NO_COLOR=1 HERD_DRIVER=headless "$@"
      }
      _ps_hold="$PS_TREES/.agent-watch-step-holds"
      # Drive the real approve-stage flow to completion: hold rel-a → approve → hold rel-b → approve →
      # final passes. Each hold releases exactly once; the ledger records one 'released' per (sha,step).
      ps_env bash "$PS_ENGINE/steps.sh" run pre-merge --slug ps-demo --dir "$PS_REPO" >/dev/null 2>&1 || true
      ps_env bash "$PS_ENGINE/herd-approve.sh" approve ps-demo >/dev/null 2>&1 || true
      ps_env bash "$PS_ENGINE/steps.sh" run pre-merge --slug ps-demo --dir "$PS_REPO" >/dev/null 2>&1 || true
      ps_env bash "$PS_ENGINE/herd-approve.sh" approve ps-demo >/dev/null 2>&1 || true
      ps_env bash "$PS_ENGINE/steps.sh" run pre-merge --slug ps-demo --dir "$PS_REPO" >/dev/null 2>&1 || true

      # REGRESSION INJECTION (PR #249 defect class): a buggy steps ledger that DOUBLE-releases a (sha,step)
      # AND records a release keyed to a STALE sha. The release-once guard below must catch either.
      if [ "${SANDBOX_FORCE_STEPS_FAULT:-}" = "1" ]; then
        _ps_cur="$(grep 'awaiting ps-demo ' "$_ps_hold" 2>/dev/null | tail -1 | awk '{print $4}')"
        {
          printf '0 released ps-demo %s rel-a\n' "$_ps_cur"                 # double-release of (cur,rel-a)
          printf '0 released ps-demo deadbeefstalesha0000000000000000000000 rel-a\n'  # stale-sha release
        } >> "$_ps_hold"
        info "fault injected: double-release + stale-sha release appended to the step-holds ledger"
      fi

      # release-once guard: for slug ps-demo, every 'released (sha,step)' must appear EXACTLY once, and
      # every released sha must be the CURRENT (last-awaited) sha — no stale-sha release. Reads the real
      # ledger the shipped steps.sh wrote (plus any injected defect).
      if python3 - "$_ps_hold" ps-demo <<'PY'
import sys
led, slug = sys.argv[1], sys.argv[2]
released, cur = {}, None
try:
    for line in open(led):
        p = line.split()
        if len(p) < 5 or p[2] != slug: continue
        state, sha, step = p[1], p[3], p[4]
        if state == 'awaiting': cur = sha
        elif state == 'released': released[(sha, step)] = released.get((sha, step), 0) + 1
except FileNotFoundError:
    sys.exit(1)
ok = bool(released) and all(v == 1 for v in released.values()) \
     and all(sha == cur for (sha, _s) in released)
sys.exit(0 if ok else 1)
PY
      then
        checkpoint posture_invariant pass "custom-steps: each approve-stage hold released exactly once per (sha,step); no stale-sha release"
      else
        checkpoint posture_invariant fail "custom-steps release-once invariant broke — a (sha,step) double-released or a stale sha was released (PR #249 defect class)"
      fi
    fi
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
