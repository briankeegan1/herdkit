#!/usr/bin/env bash
# scripts/herd/sim/sandbox-shared-config-scenario.sh — HERD-74 SHARED-CONFIG ADOPTION scenario.
#
# Proves the closed gate gap: a `herd config set --shared` PR opens from a `config/<key>` branch that,
# BEFORE this fix, had NO worktree — and agent-watch.sh discovers work via `git worktree list`, NOT
# open PRs, so that PR sat UNGATED forever (observed 2026-07-07: PRs #190/#191 had zero journal entries
# and needed hand-merging). The fix makes `herd config set --shared` leave its throwaway worktree in the
# worktree pool (WORKTREES_DIR) so the STANDARD discovery → healthcheck+review gate → merge → reap
# machinery adopts it exactly like a feature worktree — no bespoke watcher PR-discovery path.
#
# This scenario drives BOTH halves against REAL code (no re-implementation), hermetically:
#   1) It runs the REAL `bin/herd config set --shared <KEY> <VALUE>` against a deterministic fixture
#      that has its own bare "origin". That is the production path that (post-fix) creates the adoptable
#      worktree + opens the PR (gh stubbed on PATH). → checkpoints shared_pr_opened, worktree_persisted.
#   2) It then sources the REAL agent-watch.sh in lib mode (AGENT_WATCH_LIB=1) and drives the SHIPPED
#      gate functions (_healthcheck_gate, _review_gate_step, review_verdict, do_merge, already_merged)
#      over the worktree it DISCOVERS from the REAL `git worktree list` — the exact discovery input the
#      watcher's action pass uses — proving the config/<key> branch with no pre-existing worktree gets
#      adopted, gated (healthcheck ✅ + review ✅), merged, and REAPED. → checkpoints discovered_by_watcher,
#      gated_and_merged, reaped.
#
# HERMETIC: fixture-repo + its own bare origin only. Stubs `gh` (PATH), HERD_REVIEW_BIN +
# HERD_HEALTHCHECK_BIN (documented test seams), HERD_DRIVER=headless, an isolated WORKSPACE_NAME + temp
# WORKTREES_DIR, and a stub capabilities manifest (HERD_CAPABILITIES_FILE) so the key is project-scoped
# with NO requires (no watcher reload). `git` is NOT stubbed — the worktree/merge/reap are real git.
# NO network, NO real GitHub, NO herdr panes/tabs, NO model call. Mirrors sandbox-concurrency-scenario.sh.
#
# Usage:
#   bash scripts/herd/sim/sandbox-shared-config-scenario.sh [--artifacts DIR] [--keep]
#     --artifacts DIR   put the repo + scorecard + artifacts here (default: a fresh mktemp dir)
#     --keep            do not delete the artifacts dir on exit (implied when --artifacts is given)
#   Env:
#     SANDBOX_REVIEW_DELAY (default 1)  seconds the stub reviewer stays "in flight" before PASS
#
# Exit: 0 = every checkpoint passed · 1 = at least one checkpoint failed (or a hard error).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/herd/sim/sandbox-fixture.sh
. "$HERE/sandbox-fixture.sh"
HERD_BIN="$HERE/../../../bin/herd"

# ── output helpers (mirror sandbox-concurrency-scenario.sh's style) ─────────────────────────────
c_bold=$'\033[1m'; c_dim=$'\033[2m'
c_grn=$'\033[32m'; c_red=$'\033[31m'; c_yel=$'\033[33m'; c_rst=$'\033[0m'
step() { printf '\n%s[%s]%s %s\n' "$c_bold" "$1" "$c_rst" "$2"; }
ok()   { printf '  %s✓%s %s\n' "$c_grn" "$c_rst" "$*"; }
bad()  { printf '  %s✗%s %s\n' "$c_red" "$c_rst" "$*"; }
info() { printf '  %s→%s %s\n' "$c_dim" "$c_rst" "$*"; }

# ── args ────────────────────────────────────────────────────────────────────────
ART=""; KEEP=""
while [ $# -gt 0 ]; do
  case "$1" in
    --artifacts) ART="${2:-}"; KEEP=1; shift 2 ;;
    --keep)      KEEP=1; shift ;;
    -h|--help)   grep -E '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "sandbox-shared-config-scenario: unknown arg: $1" >&2; exit 1 ;;
  esac
done
if [ -z "$ART" ]; then ART="$(mktemp -d)"; fi
mkdir -p "$ART"
if [ -z "$KEEP" ]; then trap 'rm -rf "$ART"' EXIT; fi

SCENARIO="stub-shared-config-adoption"
REPO="$ART/repo"
BARE="$ART/repo.origin.git"
TREES="$ART/trees"
KEY="CLAIM_REQUIRED"           # project-scoped, no-requires (stub manifest below) → no watcher reload
VAL="on"
BRANCH="config/$KEY"
CWT="$TREES/config-$KEY"       # where the fix leaves the adoptable worktree
PRNUM=201
REVIEW_DELAY="${SANDBOX_REVIEW_DELAY:-1}"
: "${REVIEW_CONCURRENCY:=2}"

# ── checkpoint recording (bash 3.2: parallel indexed arrays) ────────────────────────────────────
CP_NAMES=(); CP_STATUS=(); CP_DETAIL=()
_pass=0; _fail=0
checkpoint() {
  local name="$1" status="$2"; shift 2
  local detail; detail="$(printf '%s' "$*" | tr -d '"\\' | tr '\n' ' ')"
  CP_NAMES+=("$name"); CP_STATUS+=("$status"); CP_DETAIL+=("$detail")
  case "$status" in
    pass) _pass=$((_pass+1)); ok "$name — $detail" ;;
    fail) _fail=$((_fail+1)); bad "$name — $detail" ;;
  esac
}

printf '%s══ Sandbox SHARED-CONFIG ADOPTION scenario: %s (HERD-74) ══%s\n' "$c_bold" "$SCENARIO" "$c_rst"
printf '  artifacts: %s\n' "$ART"

# ── init: deterministic fixture + its own bare origin (so `set --shared` really pushes + opens a PR) ─
step init "build fixture repo with a bare origin (config/<key> propagation target)"
FIXTURE_SHA="$(sandbox_fixture_build "$REPO")" || { bad "fixture build failed"; exit 1; }
_sf_git_env
# Point DEFAULT_BRANCH at origin/main and pin PROJECT_ROOT/WORKTREES_DIR so the watcher + config set
# agree on paths. Rewrite the fixture's baseline config, then wire + seed the bare origin.
REPO_REAL="$(cd "$REPO" && pwd -P)"; TREES_REAL="$TREES"
mkdir -p "$TREES"
cat > "$REPO/.herd/config" <<CFG
# .herd/config — HERD-74 shared-config-adoption fixture (throwaway; zero-secret).
HERD_VERSION=1
PROJECT_ROOT="$REPO_REAL"
WORKTREES_DIR="$TREES_REAL"
DEFAULT_BRANCH="origin/main"
WORKSPACE_NAME="sandbox-sharedcfg-sim"
BACKLOG_FILE="BACKLOG.md"
SCRIBE_BACKEND="file"
CFG
git -C "$REPO" add -A && git -C "$REPO" commit -q -m "config: point at origin/main for the sim"
git init -q --bare "$BARE"
git -C "$REPO" remote add origin "$BARE"
git -C "$REPO" push -q -u origin main
if [ -f "$REPO/app/greet.sh" ] && git -C "$REPO" rev-parse --verify --quiet origin/main >/dev/null; then
  checkpoint fixture_built pass "fixture at $REPO with bare origin (HEAD ${FIXTURE_SHA:0:12})"
else
  checkpoint fixture_built fail "fixture missing app or origin/main"
fi

# ── stub capabilities manifest: KEY is project-scoped with NO requires (no reload on set) ────────
CAPS="$ART/capabilities.tsv"
{
  printf 'name\tkind\tdescription\twhen_to_surface\trequires\tscope\n'
  printf '%s\tconfig\tRequire a claim before building\tMulti-operator\t\tproject\n' "$KEY"
} > "$CAPS"

# ── hermetic stubs: gh (PATH), stub reviewer + healthcheck (seams) ──────────────────────────────
step stubs "install hermetic stubs (gh · reviewer · healthcheck)"
BIN="$ART/bin"; mkdir -p "$BIN"
GHLOG="$ART/gh.log"; : > "$GHLOG"
MERGE_LOG="$ART/gh-merges.log"; : > "$MERGE_LOG"
PRLIST_JSON="$ART/pr-list.json"
# The config PR the stub advertises once it is "created". headRefOid is filled in after the worktree
# commit lands (its real HEAD sha), so the review gate keys off the true commit.
cat > "$BIN/gh" <<GH
#!/usr/bin/env bash
{ printf 'ARGS:'; for a in "\$@"; do printf ' [%s]' "\$a"; done; printf '\n'; } >> "$GHLOG"
if [ "\${1:-}" = "pr" ] && [ "\${2:-}" = "create" ]; then : > "$ART/pr-open"; exit 0; fi
if [ "\${1:-}" = "pr" ] && [ "\${2:-}" = "merge" ]; then printf '%s\n' "\${3:-?}" >> "$MERGE_LOG"; exit 0; fi
if [ "\${1:-}" = "pr" ] && [ "\${2:-}" = "list" ]; then
  if [ -f "$ART/pr-open" ] && [ -f "$PRLIST_JSON" ]; then cat "$PRLIST_JSON"; else printf '[]\n'; fi
  exit 0
fi
if [ "\${1:-}" = "pr" ] && [ "\${2:-}" = "view" ]; then
  # 'pr view <branch>' (existence probe from config set): 0 iff the PR is open.
  if [ -f "$ART/pr-open" ]; then
    printf '{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefName":"$BRANCH","headRefOid":"","author":{"login":"herd-sim"}}\n'
    exit 0
  fi
  exit 1
fi
exit 0
GH
chmod +x "$BIN/gh"
export PATH="$BIN:$PATH"

# Stub reviewer (HERD_REVIEW_BIN): stays in flight $REVIEW_DELAY s then writes REVIEW: PASS (atomic).
STUB_REVIEW="$ART/stub-review.sh"
cat > "$STUB_REVIEW" <<'STUB'
#!/usr/bin/env bash
sleep "${SANDBOX_REVIEW_DELAY:-1}"
if [ -n "${HERD_REVIEW_RESULT_FILE:-}" ]; then
  printf 'REVIEW: PASS\n' > "$HERD_REVIEW_RESULT_FILE.tmp.$$"
  mv "$HERD_REVIEW_RESULT_FILE.tmp.$$" "$HERD_REVIEW_RESULT_FILE"
fi
printf 'REVIEW: PASS\n'
STUB
chmod +x "$STUB_REVIEW"

# Stub healthcheck (HERD_HEALTHCHECK_BIN): always clean; record each invocation so we can prove the
# adopted config worktree's suite actually ran through the gate.
STUB_HC="$ART/stub-healthcheck.sh"
HC_RUNLOG="$ART/hc-runs.log"; : > "$HC_RUNLOG"
cat > "$STUB_HC" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\${1:-?}" >> "$HC_RUNLOG"
printf '✅ clean — sandbox shared-config stub\n'
exit 0
STUB
chmod +x "$STUB_HC"
checkpoint stubs_installed pass "gh + stub reviewer + stub healthcheck ready"

# ══════════════════════════════════════════════════════════════════════════════════════════════
# HALF 1 — run the REAL `herd config set --shared` (the production adoptable-worktree path)
# ══════════════════════════════════════════════════════════════════════════════════════════════
step shared "run REAL 'herd config set --shared $KEY $VAL' (opens PR + leaves an adoptable worktree)"
set +e
SHARED_OUT="$( cd "$REPO" && \
  PATH="$BIN:$PATH" \
  HERD_CAPABILITIES_FILE="$CAPS" \
  HERD_RELOAD_SKIP_LAUNCH=1 \
  bash "$HERD_BIN" config set --shared --reason "HERD-74 sim" "$KEY" "$VAL" 2>&1 )"
SHARED_RC=$?
set -e
printf '%s\n' "$SHARED_OUT" | sed 's/^/    /'
if [ "$SHARED_RC" -eq 0 ] && grep -q 'ARGS: \[pr\] \[create\]' "$GHLOG" \
   && grep -qE "^$KEY=\"$VAL\"" "$REPO/.herd/config"; then
  checkpoint shared_pr_opened pass "set --shared applied locally + opened the config PR (gh pr create called)"
else
  checkpoint shared_pr_opened fail "rc=$SHARED_RC · gh pr create called=$(grep -c 'ARGS: \[pr\] \[create\]' "$GHLOG") · local baseline=$(grep -E "^$KEY=" "$REPO/.herd/config" 2>/dev/null || echo MISSING)"
fi

# THE FIX: the throwaway worktree now PERSISTS in the pool on the config branch (before the fix it was
# removed at the end of the command, leaving the PR ungated forever).
if [ -d "$CWT" ] && [ "$(git -C "$CWT" symbolic-ref --short HEAD 2>/dev/null)" = "$BRANCH" ]; then
  CWT_SHA="$(git -C "$CWT" rev-parse HEAD)"
  checkpoint worktree_persisted pass "config worktree left in the pool at $CWT on $BRANCH (${CWT_SHA:0:12})"
else
  checkpoint worktree_persisted fail "no adoptable worktree at $CWT (branch=$(git -C "$CWT" symbolic-ref --short HEAD 2>/dev/null || echo none))"
  CWT_SHA=""
fi

# Now that the branch's real HEAD sha is known, publish the PR-list JSON the stub gh advertises.
cat > "$PRLIST_JSON" <<JSON
[{"number":$PRNUM,"headRefName":"$BRANCH","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"$CWT_SHA","author":{"login":"herd-sim"}}]
JSON

# ══════════════════════════════════════════════════════════════════════════════════════════════
# HALF 2 — source the REAL watcher (lib mode) and drive its SHIPPED gate over the DISCOVERED worktree
# ══════════════════════════════════════════════════════════════════════════════════════════════
step source "source REAL agent-watch.sh (lib mode) and bind its gate functions"
export AGENT_WATCH_LIB=1
export HERD_CONFIG_FILE="$ART/no-such-config"       # ignore any ambient .herd/config
export HERD_DRIVER=headless
export WORKSPACE_NAME="sandbox-sharedcfg-sim"
export PROJECT_ROOT="$REPO"                           # → MAIN for discovery + do_merge git ops
export WORKTREES_DIR="$TREES"
export DEFAULT_BRANCH="origin/main"
export MERGE_POLICY="auto"
export REVIEW_CONCURRENCY
export HEALTH_CONCURRENCY=1
export HERD_REVIEW_BIN="$STUB_REVIEW"
export HERD_HEALTHCHECK_BIN="$STUB_HC"
export SANDBOX_REVIEW_DELAY="$REVIEW_DELAY"
WATCH="$HERE/../agent-watch.sh"
[ -f "$WATCH" ] || { bad "agent-watch.sh not found at $WATCH"; exit 1; }
# shellcheck source=/dev/null
. "$WATCH" || { bad "sourcing agent-watch.sh (lib mode) failed"; exit 1; }
_missing=""
for fn in _healthcheck_gate _review_gate_step review_verdict do_merge already_merged; do
  type "$fn" >/dev/null 2>&1 || _missing="$_missing $fn"
done
[ -z "$_missing" ] && checkpoint watcher_bound pass "real gate functions sourced (lib mode)" \
  || checkpoint watcher_bound fail "missing gate functions:$_missing"

# Neutralize post-merge side-quests that touch external surfaces (identical posture to the
# concurrency scenario). The merge/reap CORE — gh pr merge, the STATE record, the merge journal
# event, and the REAL `git worktree remove` reap — all stay the shipped code.
render() { :; }
reconcile_backlog() { :; }
refresh_codemap() { :; }
refresh_symbol_index() { :; }
herd_teardown_slug() { :; }
cost_emit_merge() { :; }

# ── DISCOVERY: the worktree the watcher would adopt comes from the REAL `git worktree list` — the
#    exact input agent-watch.sh's action pass parses — matched to the open PR by branch. No agent
#    exists for it (no herdr tab), yet it is a MERGE CANDIDATE because it carries an open PR. ───────
step discover "prove the REAL git worktree list surfaces the config worktree, mapped to its PR"
WT_PORCELAIN="$(git -C "$PROJECT_ROOT" worktree list --porcelain 2>/dev/null || true)"
DISC_DIR=""; DISC_BRANCH=""
DISC="$(WT="$WT_PORCELAIN" MAIN="$PROJECT_ROOT" BR="$BRANCH" python3 -c '
import os
main=os.environ["MAIN"]; want=os.environ["BR"]
wt=None; br=None
for line in (os.environ.get("WT") or "").splitlines():
    if line.startswith("worktree "): wt=line[9:]; br=None
    elif line.startswith("branch "): br=line[7:].replace("refs/heads/","")
    elif line=="":
        if wt and wt!=main and br==want: print(wt); break
        wt=None; br=None
if wt and wt!=main and br==want: print(wt)
' | head -1)"
if [ -n "$DISC" ]; then DISC_DIR="$DISC"; DISC_BRANCH="$BRANCH"; fi
# The PR list (what the watcher fetches each tick) maps this branch → an open, mergeable PR.
PR_MAPPED=0
if [ -f "$PRLIST_JSON" ] && python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
sys.exit(0 if any(p.get("headRefName")==sys.argv[2] and p.get("mergeable")=="MERGEABLE" for p in d) else 1)' "$PRLIST_JSON" "$BRANCH"; then
  PR_MAPPED=1
fi
# No herdr agent is registered for the config slug (headless roster is empty) — it is adopted purely
# from its worktree + PR, never a builder/agent.
AG_JSON="$(herd_driver_agent_list_json 2>/dev/null || echo '{}')"
AG_COUNT="$(printf '%s' "$AG_JSON" | python3 -c 'import json,sys
try: a=(json.load(sys.stdin).get("result") or {}).get("agents") or []
except Exception: a=[]
print(len(a))' 2>/dev/null || echo 0)"
if [ -n "$DISC_DIR" ] && [ "$PR_MAPPED" = "1" ]; then
  checkpoint discovered_by_watcher pass "git worktree list surfaces $DISC_DIR on $DISC_BRANCH, mapped to PR #$PRNUM (agents in roster: $AG_COUNT)"
else
  checkpoint discovered_by_watcher fail "discovery miss: dir='$DISC_DIR' pr_mapped=$PR_MAPPED"
fi

# ── DRIVE the shipped gate over the discovered worktree, in the watcher's action-pass order:
#    _healthcheck_gate → review gate → do_merge on PASS. Loop a few ticks so the async review lands. ─
step drive "drive the REAL gate (healthcheck → review → merge) over the adopted worktree"
INTER_TICK=$((REVIEW_DELAY + 1))
MERGED=0
t=1
while [ "$t" -le 6 ]; do
  if already_merged "$PRNUM" "config-$KEY"; then MERGED=1; break; fi
  _HC_RESULT=""
  _healthcheck_gate "$PRNUM" "config-$KEY" "$DISC_DIR" 0 "$CWT_SHA"
  case "$_HC_RESULT" in
    CLEAN|FLAKY) : ;;
    *) sleep "$INTER_TICK"; t=$((t+1)); continue ;;
  esac
  prior="$(review_verdict "$PRNUM" "$CWT_SHA" 2>/dev/null || true)"
  if [ "$prior" != "PASS" ]; then
    stepv="$(_review_gate_step "$PRNUM" "config-$KEY" "$CWT_SHA")"
    case "$stepv" in
      PASS) : ;;
      *) sleep "$INTER_TICK"; t=$((t+1)); continue ;;
    esac
  fi
  do_merge "config-$KEY" "$PRNUM" "$DISC_DIR" "$CWT_SHA"
  MERGED=1
  break
done

# ── ASSERT: gated + merged exactly once, and the worktree was reaped ────────────────────────────
step assert "assert the adopted config PR gated, merged once, and reaped"
_merge_total="$(grep -c . "$MERGE_LOG" 2>/dev/null || echo 0)"
_hc_ran="$(grep -c . "$HC_RUNLOG" 2>/dev/null || echo 0)"
if [ "$MERGED" = "1" ] && already_merged "$PRNUM" "config-$KEY" && [ "$_merge_total" -eq 1 ] && [ "$_hc_ran" -ge 1 ]; then
  checkpoint gated_and_merged pass "healthcheck ran ($_hc_ran) + review passed → merged once (gh pr merge x$_merge_total)"
else
  checkpoint gated_and_merged fail "MERGED=$MERGED merges=$_merge_total hc_runs=$_hc_ran already_merged=$(already_merged "$PRNUM" "config-$KEY" && echo y || echo n)"
fi

# do_merge's REAL `git worktree remove` reaped the adopted worktree: the dir is gone AND it is no
# longer registered in the repo's worktree list.
_still_registered=0
git -C "$PROJECT_ROOT" worktree list --porcelain 2>/dev/null | grep -qxF "worktree $DISC_DIR" && _still_registered=1
if [ ! -d "$CWT" ] && [ "$_still_registered" -eq 0 ]; then
  checkpoint reaped pass "config worktree reaped (dir removed + unregistered from git worktree list)"
else
  checkpoint reaped fail "worktree not reaped (dir_exists=$([ -d "$CWT" ] && echo y || echo n) registered=$_still_registered)"
fi

# ── SCORECARD (machine-readable JSON; mirrors the sim family shape) ──────────────────────────────
write_scorecard() {
  local out="$ART/scorecard.json" result="$1"
  local n=${#CP_NAMES[@]} i
  {
    printf '{\n'
    printf '  "scenario": "%s",\n' "$SCENARIO"
    printf '  "artifacts_dir": "%s",\n' "$ART"
    printf '  "repo_dir": "%s",\n' "$REPO"
    printf '  "fixture_sha": "%s",\n' "$FIXTURE_SHA"
    printf '  "result": "%s",\n' "$result"
    printf '  "passed": %d,\n' "$_pass"
    printf '  "failed": %d,\n' "$_fail"
    printf '  "key": "%s",\n' "$KEY"
    printf '  "branch": "%s",\n' "$BRANCH"
    printf '  "pr": %d,\n' "$PRNUM"
    printf '  "merges": %s,\n' "${_merge_total:-0}"
    printf '  "healthcheck_runs": %s,\n' "${_hc_ran:-0}"
    printf '  "merged": %s,\n' "$([ "$MERGED" = "1" ] && echo true || echo false)"
    printf '  "checkpoints": [\n'
    for ((i=0; i<n; i++)); do
      printf '    {"name": "%s", "status": "%s", "detail": "%s"}' "${CP_NAMES[$i]}" "${CP_STATUS[$i]}" "${CP_DETAIL[$i]}"
      [ "$i" -lt "$((n-1))" ] && printf ',\n' || printf '\n'
    done
    printf '  ]\n'
    printf '}\n'
  } > "$out"
  printf '%s' "$out"
}
RESULT="pass"; [ "$_fail" -gt 0 ] && RESULT="fail"
SCARD="$(write_scorecard "$RESULT")"
printf '\n%s══ scorecard ══%s\n' "$c_bold" "$c_rst"
printf '  scenario:      %s\n' "$SCENARIO"
printf '  result:        %s\n' "$RESULT"
printf '  passed/failed: %d / %d\n' "$_pass" "$_fail"
printf '  scorecard:     %s\n' "$SCARD"
printf '  artifacts:     %s\n' "$ART"

[ "$_fail" -eq 0 ] || exit 1
exit 0
