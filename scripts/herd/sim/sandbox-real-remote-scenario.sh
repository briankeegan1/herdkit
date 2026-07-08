#!/usr/bin/env bash
# scripts/herd/sim/sandbox-real-remote-scenario.sh — P2c OPT-IN EPHEMERAL REAL-REMOTE (GitHub) tier.
#
# Every other sim tier PATH-stubs `gh` (sandbox-concurrency-scenario.sh installs a hermetic gh/reviewer/
# healthcheck stub; the P0/P2a/P2b scenarios never touch a hosted repo). This P2c scenario adds the ONE
# tier that runs `gh` for REAL: an ENV-GATED opt-in (SANDBOX_REAL_REMOTE=1) that provisions a DISPOSABLE
# private GitHub repo under the authenticated `gh` account (a clearly-sandboxed name — herd-sim-<ts>-<pid>),
# pushes the local fixture to it, and drives the herd PR flow — `gh pr create`, the watcher's PR polling
# (`gh pr view --json mergeable,mergeStateStatus`), and `gh pr merge` — against that LIVE remote.
#
# DEFAULT (env unset) IS BYTE-IDENTICAL HERMETIC STUB behavior: a self-contained `gh` PATH stub records
# create/merge, answers view/list, and NO network/repo is ever touched. The real tier fires ONLY when
# SANDBOX_REAL_REMOTE=1 AND a real, AUTHENTICATED `gh` is present; otherwise it degrades to a clean SKIP
# (result "skip", exit 0 — an expected absence is never a red alarm). This dual guard is also what keeps
# the hermetic CI suite off the real tier: the test wrapper never sets SANDBOX_REAL_REMOTE, and even if
# it did, an unauthenticated/absent gh makes the real path SKIP instead of reaching out (proven by
# tests/test-sandbox-real-remote.sh's guard case).
#
# DELETE-SCOPE PREFLIGHT. gh's default token grant (gist/read:org/repo) does NOT include `delete_repo`,
# so a naive run would CREATE the disposable repo and only discover at teardown that it cannot delete it
# — a guaranteed leftover + red run on an env limitation. Before `gh repo create`, we probe the token
# scopes and, when `delete_repo` is definitively absent, FAIL up front creating NOTHING, naming the exact
# remedy: `gh auth refresh -h github.com -s delete_repo`. (The loud-leftover backstop below still guards
# against scope loss mid-run.)
#
# GUARANTEED CLEANUP (incl. failure paths). A disposable repo on a live account MUST NEVER be stranded:
#   • an EXIT/INT/TERM trap runs `gh repo delete` on the provisioned repo no matter how we exit;
#   • if deletion FAILS, we emit a LOUD warning naming the repo and append it to a stable leftover log
#     ($TMPDIR/herd-sim-leftover-repos.log) — never a silent strand;
#   • a `--sweep` helper lists+deletes any lingering herd-sim-* repos on the account (run it to mop up
#     a repo a crashed run could not delete).
#
# Usage:
#   bash scripts/herd/sim/sandbox-real-remote-scenario.sh [--artifacts DIR] [--keep]
#   bash scripts/herd/sim/sandbox-real-remote-scenario.sh --sweep [--yes]   # delete stray herd-sim-* repos
#     --artifacts DIR   put the repo + scorecard + artifacts here (default: a fresh mktemp dir)
#     --keep            do not delete the artifacts dir on exit (implied when --artifacts is given)
#     --sweep           leftover-repo sweep: list (and, with --yes, delete) herd-sim-* repos on the account
#     --yes             with --sweep, actually delete (default: dry-run list only)
#   Env:
#     SANDBOX_REAL_REMOTE=1   opt IN to the real GitHub tier (default unset → hermetic stub)
#     SANDBOX_REPO_PREFIX     disposable repo-name prefix (default: herd-sim)
#
# Exit: 0 = every checkpoint passed OR cleanly skipped · 1 = at least one checkpoint failed.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/herd/sim/sandbox-fixture.sh
. "$HERE/sandbox-fixture.sh"

# ── output helpers (mirror the sandbox-sim family's style) ──────────────────────────────────────
c_bold=$'\033[1m'; c_dim=$'\033[2m'
c_grn=$'\033[32m'; c_red=$'\033[31m'; c_yel=$'\033[33m'; c_rst=$'\033[0m'
step() { printf '\n%s[%s]%s %s\n' "$c_bold" "$1" "$c_rst" "$2"; }
ok()   { printf '  %s✓%s %s\n' "$c_grn" "$c_rst" "$*"; }
bad()  { printf '  %s✗%s %s\n' "$c_red" "$c_rst" "$*"; }
skip() { printf '  %s–%s %s\n' "$c_yel" "$c_rst" "$*"; }
info() { printf '  %s→%s %s\n' "$c_dim" "$c_rst" "$*"; }
warn() { printf '%s⚠️  %s%s\n' "$c_yel" "$*" "$c_rst" >&2; }

REPO_PREFIX="${SANDBOX_REPO_PREFIX:-herd-sim}"
LEFTOVER_LOG="${TMPDIR:-/tmp}/herd-sim-leftover-repos.log"

# ── leftover-repo sweep helper (own subcommand; also usable to mop up a crashed run) ─────────────
# Lists every repo owned by the authenticated account whose name starts with $REPO_PREFIX-, and with
# --yes deletes each (naming it). Requires a real, authenticated gh; a clean no-op otherwise.
run_sweep() {
  local do_delete="$1"
  if ! command -v gh >/dev/null 2>&1; then echo "sweep: gh not installed — nothing to do"; return 0; fi
  if ! gh auth status >/dev/null 2>&1;   then echo "sweep: gh not authenticated — nothing to do"; return 0; fi
  local owner; owner="$(gh api user --jq .login 2>/dev/null || true)"
  [ -n "$owner" ] || { echo "sweep: could not resolve gh account"; return 1; }
  local repos
  repos="$(gh repo list "$owner" --limit 200 --json name --jq '.[].name' 2>/dev/null \
    | grep -E "^${REPO_PREFIX}-" || true)"
  if [ -z "$repos" ]; then echo "sweep: no ${REPO_PREFIX}-* repos on $owner (clean)"; return 0; fi
  local n=0
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    if [ "$do_delete" = 1 ]; then
      if gh repo delete "$owner/$r" --yes >/dev/null 2>&1; then
        echo "sweep: deleted $owner/$r"; n=$((n+1))
      else
        warn "sweep: FAILED to delete $owner/$r — delete it by hand: gh repo delete $owner/$r --yes"
      fi
    else
      echo "sweep: would delete $owner/$r (dry-run; pass --yes to delete)"
    fi
  done <<< "$repos"
  [ "$do_delete" = 1 ] && echo "sweep: deleted $n repo(s)"
  return 0
}

# ── args ────────────────────────────────────────────────────────────────────────
ART=""; KEEP=""; SWEEP=""; SWEEP_YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --artifacts) ART="${2:-}"; KEEP=1; shift 2 ;;
    --keep)      KEEP=1; shift ;;
    --sweep)     SWEEP=1; shift ;;
    --yes)       SWEEP_YES=1; shift ;;
    -h|--help)   grep -E '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "sandbox-real-remote-scenario: unknown arg: $1" >&2; exit 1 ;;
  esac
done
if [ -n "$SWEEP" ]; then run_sweep "$SWEEP_YES"; exit $?; fi

if [ -z "$ART" ]; then ART="$(mktemp -d)"; fi
mkdir -p "$ART"

SCENARIO="stub-real-remote-e2e"
REPO="$ART/repo"
BUILDER_BRANCH="sim/stub-builder"

# The selected tier: real when the opt-in is set, else the hermetic stub. `remote` in the scorecard.
REMOTE="stub"; [ "${SANDBOX_REAL_REMOTE:-}" = "1" ] && REMOTE="real"

# ── checkpoint recording (bash 3.2: parallel indexed arrays, no assoc arrays) ────────────────────
CP_NAMES=(); CP_STATUS=(); CP_DETAIL=()
_pass=0; _fail=0; _skip=0
checkpoint() {
  local name="$1" status="$2"; shift 2
  local detail="$*"
  detail="$(printf '%s' "$detail" | tr -d '"\\' | tr '\n' ' ')"
  CP_NAMES+=("$name"); CP_STATUS+=("$status"); CP_DETAIL+=("$detail")
  case "$status" in
    pass) _pass=$((_pass+1)); ok "$name — $detail" ;;
    fail) _fail=$((_fail+1)); bad "$name — $detail" ;;
    skip) _skip=$((_skip+1)); skip "$name — $detail" ;;
  esac
}

# ── scorecard state ──────────────────────────────────────────────────────────────
REAL_RAN=false          # did the real GitHub tier actually execute?
REPO_SLUG=""            # owner/name of the provisioned disposable repo (real tier only)
REPO_CREATED=false
REPO_DELETED=false
PR_NUMBER=""
PR_MERGED=false

# ── GUARANTEED CLEANUP: delete the disposable repo no matter how we exit ──────────────────────────
# Never strand a repo on the account: the trap runs on EXIT and on INT/TERM. If the delete fails we
# warn LOUDLY (naming the repo) and record it to a stable leftover log so it is never silently lost.
_cleanup() {
  if [ "$REPO_CREATED" = true ] && [ "$REPO_DELETED" != true ] && [ -n "$REPO_SLUG" ]; then
    if gh repo delete "$REPO_SLUG" --yes >/dev/null 2>&1; then
      REPO_DELETED=true
      info "cleanup: deleted disposable repo $REPO_SLUG"
    else
      warn "COULD NOT DELETE disposable sandbox repo: $REPO_SLUG"
      warn "  delete it by hand:  gh repo delete $REPO_SLUG --yes"
      warn "  (or run: bash $0 --sweep --yes)"
      printf '%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)" "$REPO_SLUG" >> "$LEFTOVER_LOG" 2>/dev/null || true
      warn "  recorded to leftover log: $LEFTOVER_LOG"
    fi
  fi
  if [ -z "$KEEP" ]; then rm -rf "$ART"; fi
}
trap _cleanup EXIT INT TERM

# real_remote_available — the DUAL guard. The real tier fires ONLY when opted in AND a real,
# authenticated gh is reachable; anything else → a clean skip (never a red). This is exactly what
# keeps the hermetic CI suite off the real tier.
real_remote_available() {
  [ "${SANDBOX_REAL_REMOTE:-}" = "1" ] || return 1
  command -v gh >/dev/null 2>&1        || return 1
  gh auth status >/dev/null 2>&1       || return 1
}

# delete_repo_scope_probe — PREFLIGHT the ability to DELETE a repo BEFORE we create one. gh's default
# grant is gist/read:org/repo — it does NOT include `delete_repo`. Without this probe we'd create the
# disposable repo and only discover at teardown that we cannot delete it: a guaranteed leftover + a red
# run on an env limitation. We read the token scopes off `gh auth status` (which prints a
# "Token scopes: '…', '…'" line) and classify:
#   return 0 → delete_repo is present (safe to provision)
#   return 1 → a scopes line exists but delete_repo is ABSENT (definitively unsafe — fail up front)
#   return 2 → no scopes line found (e.g. a fine-grained token exposes no classic scopes) → indeterminate;
#              proceed and let the loud-leftover teardown backstop guard against a strand.
delete_repo_scope_probe() {
  local out line
  out="$(gh auth status 2>&1 || true)"
  line="$(printf '%s\n' "$out" | grep -iE 'Token scopes:' | head -n1)"
  [ -n "$line" ] || return 2
  case "$line" in
    *delete_repo*) return 0 ;;
    *)             return 1 ;;
  esac
}

# ═══════════════════════════════════════════════════════════════════════════════
printf '%s══ Sandbox REAL-REMOTE scenario: %s (remote=%s) ══%s\n' "$c_bold" "$SCENARIO" "$REMOTE" "$c_rst"
printf '  artifacts: %s\n' "$ART"

# ── init: build the deterministic fixture ────────────────────────────────────────────────────────
step init "build deterministic local fixture"
FIXTURE_SHA="$(sandbox_fixture_build "$REPO")" || { bad "fixture build failed"; exit 1; }
info "fixture HEAD: $FIXTURE_SHA"
[ -f "$REPO/app/greet.sh" ] && checkpoint fixture_built pass "fixture at $REPO (HEAD ${FIXTURE_SHA:0:12})" \
  || checkpoint fixture_built fail "fixture missing app/greet.sh"

# ── build (STUB builder): a deterministic tiny change on a builder branch. NO model call. ────────
step build "STUB builder — deterministic tiny change (no model call)"
_sf_git_env
git -C "$REPO" checkout -q -b "$BUILDER_BRANCH"
cat > "$REPO/app/farewell.sh" <<'FAREWELL'
#!/usr/bin/env bash
# farewell.sh — added by the stub builder (implements backlog item 1).
farewell() { printf 'goodbye, %s!\n' "${1:-world}"; }
if [ "${BASH_SOURCE[0]}" = "$0" ]; then farewell "$@"; fi
FAREWELL
chmod +x "$REPO/app/farewell.sh"
git -C "$REPO" add -A
git -C "$REPO" commit -q -m "stub-builder: add farewell command"
BUILDER_SHA="$(git -C "$REPO" rev-parse "$BUILDER_BRANCH")"
git -C "$REPO" checkout -q main
_ahead="$(git -C "$REPO" rev-list --count main.."$BUILDER_BRANCH" 2>/dev/null || echo 0)"
if [ "$_ahead" = "1" ]; then
  checkpoint builder_committed pass "branch $BUILDER_BRANCH is 1 commit ahead of main (${BUILDER_SHA:0:12})"
else
  checkpoint builder_committed fail "builder branch not 1 commit ahead (ahead=$_ahead)"
fi

# ── availability guard: when the real tier is requested but unreachable, skip cleanly (never red) ─
if [ "$REMOTE" = real ] && ! real_remote_available; then
  step probe "real tier requested (SANDBOX_REAL_REMOTE=1) but gh is unavailable/unauthenticated"
  reason="gh unavailable"
  command -v gh >/dev/null 2>&1 || reason="gh not installed"
  command -v gh >/dev/null 2>&1 && ! gh auth status >/dev/null 2>&1 && reason="gh not authenticated (gh auth login)"
  checkpoint real_remote_available skip "$reason — skipping the real-remote path (an expected absence is not a red)"
  for cp in remote_provisioned pr_created pr_polled gate_passed pr_merged teardown_clean; do
    checkpoint "$cp" skip "no authenticated gh — real-remote checkpoint not exercised"
  done
  REMOTE_RUNNABLE=false
else
  REMOTE_RUNNABLE=true
fi

if [ "$REMOTE_RUNNABLE" = true ]; then
if [ "$REMOTE" = stub ]; then
  # ══ HERMETIC STUB TIER (default) ═══════════════════════════════════════════════════════════════
  # A self-contained `gh` PATH stub: records create/merge, answers view/list. NO network, NO repo.
  step stub "install hermetic gh stub (records create/merge; answers view/list; no network)"
  BIN="$ART/bin"; mkdir -p "$BIN"
  GH_LOG="$ART/gh-calls.log"; : > "$GH_LOG"
  cat > "$BIN/gh" <<GH
#!/usr/bin/env bash
# Hermetic gh stub for the sandbox real-remote sim (stub tier). Records every call; NEVER networks.
printf '%s\n' "\$*" >> "$GH_LOG"
case "\${1:-} \${2:-}" in
  "repo create")
    # A stub must NEVER pretend to hit the network: creating a real repo is a REAL-tier-only action.
    echo "gh-stub: repo create is a no-op in the hermetic stub tier" >&2; exit 0 ;;
  "pr create")
    printf 'https://github.com/herd-sim/sandbox/pull/1\n'; exit 0 ;;
  "pr view")
    printf '{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","state":"OPEN"}\n'; exit 0 ;;
  "pr merge")
    exit 0 ;;
  "pr list") printf '[]\n'; exit 0 ;;
  "repo delete") exit 0 ;;
  *) exit 0 ;;
esac
GH
  chmod +x "$BIN/gh"
  export PATH="$BIN:$PATH"
  checkpoint remote_provisioned pass "hermetic gh stub installed (no hosted repo; byte-identical default)"
else
  # ══ REAL EPHEMERAL GITHUB TIER (opt-in) ════════════════════════════════════════════════════════
  REAL_RAN=true

  # ── PREFLIGHT: the token must be able to DELETE the repo BEFORE we create it ──────────────────
  # gh's default grant (gist/read:org/repo) lacks `delete_repo`, so a naive run creates the disposable
  # repo and only fails at teardown — a guaranteed leftover on a live account. Probe up front and, when
  # the scope is definitively absent, fail here CREATING NOTHING and name the exact remedy.
  step preflight "preflight the delete_repo scope BEFORE creating anything (gh's default grant lacks it)"
  delete_repo_scope_probe; _scope_rc=$?
  if [ "$_scope_rc" -eq 1 ]; then
    checkpoint delete_repo_scope fail "gh token lacks the 'delete_repo' scope — refusing to provision (creating it now would strand a repo we cannot delete). Grant it and retry: gh auth refresh -h github.com -s delete_repo"
    checkpoint remote_provisioned skip "no delete_repo scope — nothing was provisioned (see delete_repo_scope)"
  else
    if [ "$_scope_rc" -eq 2 ]; then
      checkpoint delete_repo_scope pass "delete_repo scope not determinable from gh auth status (e.g. a fine-grained token) — proceeding; the loud-leftover teardown backstop still guards against a strand"
    else
      checkpoint delete_repo_scope pass "gh token carries the delete_repo scope — safe to provision a disposable repo"
    fi
    ts="$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || echo run)"
    REPO_NAME="${REPO_PREFIX}-${ts}-$$"
    owner="$(gh api user --jq .login 2>/dev/null || true)"
    step provision "provision a DISPOSABLE private repo ($REPO_NAME) and push the fixture"
    if [ -z "$owner" ]; then
      checkpoint remote_provisioned fail "could not resolve gh account (gh api user)"
    elif gh repo create "$owner/$REPO_NAME" --private --disable-issues --disable-wiki >/dev/null 2>&1; then
      REPO_SLUG="$owner/$REPO_NAME"; REPO_CREATED=true
      info "created disposable repo: $REPO_SLUG (private)"
      # Push main + the builder branch to the live remote using gh's git credentials.
      push_url="$(gh repo view "$REPO_SLUG" --json url --jq .url 2>/dev/null).git"
      git -C "$REPO" remote add origin "$push_url" 2>/dev/null || git -C "$REPO" remote set-url origin "$push_url"
      if git -C "$REPO" push -q -u origin main 2>/dev/null \
         && git -C "$REPO" push -q origin "$BUILDER_BRANCH" 2>/dev/null; then
        checkpoint remote_provisioned pass "created $REPO_SLUG and pushed main + $BUILDER_BRANCH to the live remote"
      else
        checkpoint remote_provisioned fail "repo created ($REPO_SLUG) but push failed (repo will still be cleaned up)"
      fi
    else
      checkpoint remote_provisioned fail "gh repo create failed for $owner/$REPO_NAME"
    fi
  fi
fi

# ── PR: gh pr create against the (real or stubbed) remote ─────────────────────────────────────────
step pr "open the PR via gh pr create ($REMOTE remote)"
if [ "$REMOTE" = real ] && [ "$REPO_CREATED" != true ]; then
  checkpoint pr_created skip "no repo provisioned — cannot open a PR"
else
  if [ "$REMOTE" = real ]; then
    PR_URL="$(gh pr create --repo "$REPO_SLUG" --base main --head "$BUILDER_BRANCH" \
      --title "stub-builder: add farewell command" \
      --body "Sandbox real-remote sim PR (disposable). Refs: HERD-69" 2>/dev/null || true)"
  else
    PR_URL="$(gh pr create --base main --head "$BUILDER_BRANCH" \
      --title "stub-builder: add farewell command" --body "sandbox real-remote sim (stub)" 2>/dev/null || true)"
  fi
  PR_NUMBER="$(printf '%s' "$PR_URL" | grep -oE '[0-9]+$' || true)"
  if [ -n "$PR_NUMBER" ]; then
    checkpoint pr_created pass "gh pr create → PR #$PR_NUMBER ($PR_URL)"
  else
    checkpoint pr_created fail "gh pr create returned no PR number (out: $PR_URL)"
  fi
fi

# ── poll: the watcher's PR-polling read — gh pr view --json mergeable,mergeStateStatus ───────────
step poll "poll PR mergeability the way the watcher does (gh pr view --json mergeable,mergeStateStatus)"
if [ -z "$PR_NUMBER" ]; then
  checkpoint pr_polled skip "no PR to poll"
else
  view_args=(pr view "$PR_NUMBER" --json mergeable,mergeStateStatus,state)
  [ "$REMOTE" = real ] && view_args+=(--repo "$REPO_SLUG")
  merge_ready=false; poll_out=""
  # Bounded poll: GitHub computes mergeability asynchronously, so allow a few tries in real mode.
  tries=1; max=8; [ "$REMOTE" = stub ] && max=1
  while [ "$tries" -le "$max" ]; do
    poll_out="$(gh "${view_args[@]}" 2>/dev/null || true)"
    case "$poll_out" in
      *'"mergeable":"MERGEABLE"'*|*'"mergeStateStatus":"CLEAN"'*) merge_ready=true; break ;;
    esac
    tries=$((tries+1)); sleep 2
  done
  if [ "$merge_ready" = true ]; then
    checkpoint pr_polled pass "watcher poll saw the PR MERGEABLE/CLEAN after $tries poll(s)"
  else
    checkpoint pr_polled fail "PR never reported MERGEABLE/CLEAN within $max polls (last: $poll_out)"
  fi
fi

# ── gate: run the fixture's real health gate on the builder branch (mirrors the pre-merge gate) ──
step gate "run fixture health gate (app/greet.test.sh) on the builder branch"
git -C "$REPO" checkout -q "$BUILDER_BRANCH"
gate_rc=0
gate_out="$( (cd "$REPO" && bash app/greet.test.sh) 2>&1 )" || gate_rc=$?
git -C "$REPO" checkout -q main
if [ "$gate_rc" -eq 0 ]; then
  checkpoint gate_passed pass "gate clean: $gate_out"
else
  checkpoint gate_passed fail "gate FAILED (rc=$gate_rc): $gate_out"
fi

# ── merge: gh pr merge against the remote — only if the gate passed ──────────────────────────────
step merge "merge the PR via gh pr merge ($REMOTE remote; gate-gated)"
if [ "$gate_rc" -ne 0 ]; then
  checkpoint pr_merged skip "merge correctly SKIPPED because the gate failed"
elif [ -z "$PR_NUMBER" ]; then
  checkpoint pr_merged skip "no PR to merge"
else
  merge_args=(pr merge "$PR_NUMBER" --merge)
  [ "$REMOTE" = real ] && merge_args+=(--repo "$REPO_SLUG")
  if gh "${merge_args[@]}" >/dev/null 2>&1; then
    if [ "$REMOTE" = real ]; then
      # Confirm the merge actually landed on the live remote (state MERGED).
      state="$(gh pr view "$PR_NUMBER" --repo "$REPO_SLUG" --json state --jq .state 2>/dev/null || true)"
      if [ "$state" = MERGED ]; then PR_MERGED=true; checkpoint pr_merged pass "gh pr merge landed; remote reports PR #$PR_NUMBER MERGED"
      else checkpoint pr_merged fail "gh pr merge returned 0 but remote state is '$state' (expected MERGED)"; fi
    else
      PR_MERGED=true; checkpoint pr_merged pass "gh pr merge recorded (stub) for PR #$PR_NUMBER"
    fi
  else
    checkpoint pr_merged fail "gh pr merge failed for PR #$PR_NUMBER"
  fi
fi

# ── teardown: delete the disposable repo (real) and assert it is gone; stub has nothing hosted ───
step teardown "delete the disposable repo (real) / assert no hosted residue (stub)"
if [ "$REMOTE" = real ]; then
  if [ "$REPO_CREATED" = true ]; then
    if gh repo delete "$REPO_SLUG" --yes >/dev/null 2>&1; then
      REPO_DELETED=true
      # Assert it is actually gone (best-effort: a view must now fail).
      if gh repo view "$REPO_SLUG" >/dev/null 2>&1; then
        checkpoint teardown_clean fail "gh repo delete returned 0 but $REPO_SLUG still resolves"
      else
        checkpoint teardown_clean pass "disposable repo $REPO_SLUG deleted and no longer resolves"
      fi
    else
      # The EXIT trap will retry + warn loudly; record the failure here too.
      checkpoint teardown_clean fail "gh repo delete FAILED for $REPO_SLUG — see loud warning + leftover log"
    fi
  else
    checkpoint teardown_clean pass "no repo was created (nothing to delete)"
  fi
else
  # Stub tier: prove no real `gh repo create` was ever issued (byte-identical hermetic behavior).
  if [ -f "$ART/gh-calls.log" ] && grep -qE '^repo create' "$ART/gh-calls.log"; then
    checkpoint teardown_clean fail "stub tier issued a 'repo create' — hermeticity broken"
  else
    checkpoint teardown_clean pass "stub tier touched no hosted repo (no gh repo create issued)"
  fi
fi
fi   # REMOTE_RUNNABLE

# ── SCORECARD emitter (machine-readable JSON; mirrors the sandbox-sim family + real-remote fields) ─
write_scorecard() {
  local out="$ART/scorecard.json" result="$1"
  local i n; n=${#CP_NAMES[@]}
  {
    printf '{\n'
    printf '  "scenario": "%s",\n' "$SCENARIO"
    printf '  "artifacts_dir": "%s",\n' "$ART"
    printf '  "repo_dir": "%s",\n' "$REPO"
    printf '  "fixture_sha": "%s",\n' "$FIXTURE_SHA"
    printf '  "result": "%s",\n' "$result"
    printf '  "passed": %d,\n' "$_pass"
    printf '  "failed": %d,\n' "$_fail"
    printf '  "skipped": %d,\n' "$_skip"
    printf '  "remote": "%s",\n' "$REMOTE"
    printf '  "real_remote_ran": %s,\n' "$REAL_RAN"
    printf '  "repo_slug": "%s",\n' "$REPO_SLUG"
    printf '  "repo_created": %s,\n' "$REPO_CREATED"
    printf '  "repo_deleted": %s,\n' "$REPO_DELETED"
    printf '  "pr_number": "%s",\n' "$PR_NUMBER"
    printf '  "pr_merged": %s,\n' "$PR_MERGED"
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

# RESULT: fail if any checkpoint failed; else skip when the requested real tier was not exercised; else pass.
if [ "$_fail" -gt 0 ]; then RESULT="fail"
elif [ "$REMOTE" = real ] && [ "$REAL_RAN" != true ]; then RESULT="skip"
else RESULT="pass"; fi
SCARD="$(write_scorecard "$RESULT")"

printf '\n%s══ scorecard ══%s\n' "$c_bold" "$c_rst"
printf '  scenario:      %s\n' "$SCENARIO"
printf '  remote:        %s (real_ran=%s)\n' "$REMOTE" "$REAL_RAN"
printf '  result:        %s\n' "$RESULT"
printf '  passed/failed/skipped: %d / %d / %d\n' "$_pass" "$_fail" "$_skip"
[ -n "$REPO_SLUG" ] && printf '  repo:          %s (created=%s deleted=%s)\n' "$REPO_SLUG" "$REPO_CREATED" "$REPO_DELETED"
printf '  scorecard:     %s\n' "$SCARD"
printf '  artifacts:     %s\n' "$ART"

# A skip is a clean, deliberate no-op (no authenticated gh): exit 0. Only a real failure is exit 1.
[ "$RESULT" = "fail" ] && exit 1 || exit 0
