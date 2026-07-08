#!/usr/bin/env bash
# scripts/herd/sim/sandbox-governance-scenario.sh — end-to-end GOVERNANCE scenario (HERD-127).
#
# Proves the WHOLE import→enforcement chain at ZERO quota: a fixture consumer's CLAUDE.md carries an
# operator ruleset, the HERD-119 adoption pass maps each sentence to the expected herd surface, and —
# with those keys applied — the shipped enforcement gates actually bind. Every consumed feature is
# real code driven against a throwaway fixture; the only thing stubbed is the LLM (never called — the
# deterministic table alone classifies) and `gh pr create` on the push-gate resume (a local seam,
# mirroring sandbox-scenario.sh's push-gate phase). NO model call, NO network, NO herdr panes.
#
# The five consumed features, each a checkpoint leg:
#   (1) HERD-119 adoption — templates/governance-map.tsv maps each CLAUDE.md sentence to KEY=VALUE:
#         'I review every change before it is uploaded' → PUSH_GATE=human
#         'Never co-author Claude …'                    → ATTRIBUTION_POLICY=no-ai-coauthor
#         'Name every feature branch feat/<slug>'       → BRANCH_TEMPLATE=feat/{slug}
#         'Use Conventional Commits …'                  → COMMIT_CONVENTION=^(feat|fix|…)
#   (2) HERD-123 PUSH_GATE=human — a finished stub builder is HELD pre-push; NOTHING reaches origin
#       until a human approves, and approve resumes the push + PR.
#   (3) HERD-121 ATTRIBUTION_POLICY — a commit carrying a `Co-Authored-By: Claude` trailer REDS the
#       gate, naming the offending sha (a clean commit stays green — no false red).
#   (4) HERD-120 BRANCH_TEMPLATE / HERD-124 COMMIT_CONVENTION — a non-conforming branch name and a
#       non-conforming commit subject are both REFUSED (a conforming one is accepted).
#   (5) RESET CONTRACT — the fixture rebuilds byte-identical (same HEAD sha) every run; teardown
#       leaves no residue.
#
# Usage:
#   bash scripts/herd/sim/sandbox-governance-scenario.sh [--artifacts DIR] [--keep]
#     --artifacts DIR   put the repo(s) + scorecard here (default: a fresh mktemp dir)
#     --keep            do not delete the artifacts dir on exit (implied when --artifacts is given)
#
# Fault injection (the negative leg — proves the harness FAILS LOUDLY when the chain is broken):
#   SANDBOX_FORCE_GOVERNANCE_FAIL=1  the attribution commit is written WITHOUT the AI-coauthor trailer,
#                                    so the gate stays green when the scenario asserts it must red —
#                                    flipping exactly one checkpoint, forcing result=fail + exit 1.
#
# Exit: 0 = every checkpoint passed · 1 = at least one checkpoint failed (or a hard error).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ENGINE="$(cd "$HERE/.." && pwd)"       # scripts/herd — where the shipped engine scripts live
# shellcheck source=scripts/herd/sim/sandbox-fixture.sh
. "$HERE/sandbox-fixture.sh"
# shellcheck source=scripts/herd/governance.sh
. "$ENGINE/governance.sh"              # real HERD-119 extraction + mapping (_gov_statements/_gov_match)

# ── output helpers (mirror sandbox-scenario.sh's style) ─────────────────────────────────────────
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
    *) echo "sandbox-governance-scenario: unknown arg: $1" >&2; exit 1 ;;
  esac
done
if [ -z "$ART" ]; then ART="$(mktemp -d)"; fi
mkdir -p "$ART"
if [ -z "$KEEP" ]; then trap 'rm -rf "$ART"' EXIT; fi

SCENARIO="stub-governance-e2e"
FORCE_FAIL=""
[ "${SANDBOX_FORCE_GOVERNANCE_FAIL:-}" = "1" ] && { SCENARIO="stub-governance-fault"; FORCE_FAIL=1; }
REPO="$ART/repo"

# ── zero-model-call guard: a `claude` shim on PATH that records any invocation. The deterministic
# table is the ONLY classifier; if any leg reached for the LLM fallback this log would be non-empty,
# and the zero_model_calls checkpoint would red. This is what "LLM fallback stubbed" means, provably.
MODEL_LOG="$ART/model-calls.log"; : > "$MODEL_LOG"
SHIM="$ART/shim"; mkdir -p "$SHIM"
cat > "$SHIM/claude" <<SHIMEOF
#!/usr/bin/env bash
# sandbox-governance stub: record any model call so the scenario can prove there were none.
printf '%s\n' "claude $*" >> "$MODEL_LOG"
exit 1
SHIMEOF
chmod +x "$SHIM/claude"
export PATH="$SHIM:$PATH"
unset HERD_GOVERNANCE_MAP 2>/dev/null || true   # use the REAL shipped table, never a seam override

# ── checkpoint recording (bash 3.2: parallel indexed arrays, no assoc arrays) ───────────────────
CP_NAMES=(); CP_STATUS=(); CP_DETAIL=()
_pass=0; _fail=0

# checkpoint <name> <status: pass|fail|skip> <detail...>
checkpoint() {
  local name="$1" status="$2"; shift 2
  local detail="$*"
  detail="$(printf '%s' "$detail" | tr -d '"\\' | tr '\n' ' ')"
  CP_NAMES+=("$name"); CP_STATUS+=("$status"); CP_DETAIL+=("$detail")
  case "$status" in
    pass) _pass=$((_pass+1)); ok "$name — $detail" ;;
    fail) _fail=$((_fail+1)); bad "$name — $detail" ;;
    skip) skip "$name — $detail" ;;
  esac
}

# ── governance scorecard fields (populated as legs run) ─────────────────────────────────────────
GOV_SOURCE="CLAUDE.md"; N_STMTS=0; MAPPED=0
PUSH_HELD=false; PUSH_RESUMED=false
ATTR_RED=false; OFFENDING_SHA=""
BRANCH_REFUSED=false; COMMIT_REFUSED=false
RESET_IDENTICAL=false; MODEL_CALLS=0

# ── SCORECARD emitter (mirrors sandbox-scenario.sh, + governance fields) ─────────────────────────
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
    printf '  "governance_source": "%s",\n' "$GOV_SOURCE"
    printf '  "statements": %d,\n' "$N_STMTS"
    printf '  "mapped_keys": %d,\n' "$MAPPED"
    printf '  "push_held": %s,\n' "$PUSH_HELD"
    printf '  "push_resumed": %s,\n' "$PUSH_RESUMED"
    printf '  "attribution_red": %s,\n' "$ATTR_RED"
    printf '  "offending_sha": "%s",\n' "$OFFENDING_SHA"
    printf '  "branch_refused": %s,\n' "$BRANCH_REFUSED"
    printf '  "commit_refused": %s,\n' "$COMMIT_REFUSED"
    printf '  "reset_identical": %s,\n' "$RESET_IDENTICAL"
    printf '  "model_calls": %d,\n' "$MODEL_CALLS"
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

# ── predicates ──────────────────────────────────────────────────────────────────
_branch_exists() { git -C "$1" show-ref --verify --quiet "refs/heads/$2"; }
_branch_absent() { ! git -C "$1" show-ref --verify --quiet "refs/heads/$2"; }
_tree_clean()    { [ -z "$(git -C "$1" status --porcelain 2>/dev/null)" ]; }

# ── the canonical operator ruleset the fixture project's CLAUDE.md carries ───────────────────────
CLAUDE_MD='# Operator governance

These are the house rules for this project. Deterministic — do not hand-edit.

- I review every change before it is uploaded.
- Never co-author Claude on any commit.
- Name every feature branch feat/<slug>.
- Use Conventional Commits for every commit subject.
'
# Parallel arrays: the expected surface + KEY=VALUE each sentence must adopt, in file order.
EXP_CP=(adopt_push_gate adopt_attribution adopt_branch_template adopt_commit_convention)
EXP_KV=("PUSH_GATE=human" \
        "ATTRIBUTION_POLICY=no-ai-coauthor" \
        "BRANCH_TEMPLATE=feat/{slug}" \
        "COMMIT_CONVENTION=^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)")

# gov_fixture_build <dir> — the base sandbox fixture + a committed CLAUDE.md carrying the ruleset.
# Deterministic (pinned identity/date) so its HEAD sha is stable — the reset contract applies to the
# governance-augmented tree too, not just the bare fixture. Prints the HEAD sha.
gov_fixture_build() {
  local dir="$1"
  sandbox_fixture_build "$dir" >/dev/null 2>&1 || return 1
  printf '%s' "$CLAUDE_MD" > "$dir/CLAUDE.md"
  _sf_git_env
  git -C "$dir" add -A
  git -C "$dir" commit -q -m "seed: operator governance (CLAUDE.md)" || return 1
  git -C "$dir" rev-parse HEAD
}

# ═══════════════════════════════════════════════════════════════════════════════
printf '%s══ Sandbox governance scenario: %s ══%s\n' "$c_bold" "$SCENARIO" "$c_rst"
printf '  artifacts: %s\n' "$ART"

# ── init: build the deterministic fixture + its CLAUDE.md ────────────────────────────────────────
step init "build deterministic fixture carrying the operator CLAUDE.md"
FIXTURE_SHA="$(gov_fixture_build "$REPO")" || { bad "fixture build failed"; write_scorecard fail "" >/dev/null; exit 1; }
info "fixture HEAD: $FIXTURE_SHA"
if [ -f "$REPO/CLAUDE.md" ] && grep -q 'Operator governance' "$REPO/CLAUDE.md"; then
  checkpoint fixture_built pass "fixture + CLAUDE.md at $FIXTURE_SHA"
else
  checkpoint fixture_built fail "CLAUDE.md missing from the fixture"
fi

# ── (1) ADOPTION: the HERD-119 deterministic table maps each sentence to the expected KEY=VALUE ───
step adopt "HERD-119 adoption — map each CLAUDE.md sentence to its enforcement key (deterministic table)"
STMTS=()
while IFS= read -r _s; do [ -n "$_s" ] && STMTS+=("$_s"); done < <(_gov_statements "$REPO/CLAUDE.md")
N_STMTS=${#STMTS[@]}
if [ "$N_STMTS" -ge "${#EXP_CP[@]}" ]; then
  checkpoint adopt_statements_extracted pass "extracted $N_STMTS statement(s) from CLAUDE.md (≥ the ${#EXP_CP[@]} rules)"
else
  checkpoint adopt_statements_extracted fail "expected ≥ ${#EXP_CP[@]} statements, extracted $N_STMTS"
fi
# For each expected rule, prove SOME extracted statement maps to it via the deterministic table.
# Search-based (not positional), so surrounding prose in the CLAUDE.md never perturbs the assertion.
_i=0
while [ "$_i" -lt "${#EXP_CP[@]}" ]; do
  _cp="${EXP_CP[$_i]}"; _want="${EXP_KV[$_i]}"
  _found=""; _matchstmt=""; _j=0
  while [ "$_j" -lt "$N_STMTS" ]; do
    _stmt="${STMTS[$_j]}"
    _m="$(_gov_match "$_stmt" 2>/dev/null || true)"
    if [ "$(printf '%s' "$_m" | cut -f1)" = "config-key" ] && [ "$(printf '%s' "$_m" | cut -f2)" = "$_want" ]; then
      _found=1; _matchstmt="$_stmt"; break
    fi
    _j=$((_j+1))
  done
  if [ -n "$_found" ]; then
    checkpoint "$_cp" pass "\"$_matchstmt\" → $_want"
    MAPPED=$((MAPPED+1))
  else
    checkpoint "$_cp" fail "no CLAUDE.md statement mapped to config-key $_want"
  fi
  _i=$((_i+1))
done

# ── (2) PUSH_GATE=human (HERD-123): hold pre-push, approve resumes push + PR ──────────────────────
# Drives the REAL push-gate.sh + herd-approve.sh against a throwaway fixture with a LOCAL bare origin
# (a real `git push` with no network); `gh pr create` is the one stubbed seam (HERD_PUSH_GATE_PR_CMD),
# mirroring sandbox-scenario.sh's push-gate phase.
step push-gate "PUSH_GATE=human — no push before approval, approve resumes push+PR"
if [ ! -f "$ENGINE/push-gate.sh" ] || [ ! -f "$ENGINE/herd-approve.sh" ]; then
  checkpoint push_gate_lib skip "push-gate.sh / herd-approve.sh not found — push-gate leg skipped"
else
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
  pg_env() {
    local _pg_root="$1"; shift
    env HERD_CONFIG_FILE="$ART/.pg-no-config" WORKTREES_DIR="$PG_TREES" PROJECT_ROOT="$_pg_root" \
        DEFAULT_BRANCH="origin/main" NO_COLOR=1 HERD_DRIVER=headless PUSH_GATE=human \
        HERD_PUSH_GATE_PR_CMD="$PG_PR_CMD" "$@"
  }

  gov_fixture_build "$PG_REPO" >/dev/null 2>&1
  git init -q --bare "$PG_BARE"
  git -C "$PG_REPO" remote add origin "$PG_BARE"
  _sf_git_env
  git -C "$PG_REPO" push -q origin main 2>/dev/null || true
  PG_BRANCH="feat/pg-demo"
  git -C "$PG_REPO" checkout -q -b "$PG_BRANCH"
  printf '\nfarewell() { printf "goodbye, %%s!\\n" "${1:-world}"; }\n' >> "$PG_REPO/app/greet.sh"
  git -C "$PG_REPO" add -A && git -C "$PG_REPO" commit -q -m "feat: add farewell (finished work)"
  PG_SHA="$(git -C "$PG_REPO" rev-parse HEAD)"
  PG_BODY="$ART/pg-body.md"; printf 'Add farewell.\n\nRefs: HERD-123\n' > "$PG_BODY"

  # (A) HOLD instead of push — awaiting record written AND the branch is NOT on origin.
  pg_env "$PG_REPO" bash "$ENGINE/push-gate.sh" hold pg-demo --dir "$PG_REPO" --branch "$PG_BRANCH" \
      --base main --title "feat: add farewell" --body-file "$PG_BODY" >/dev/null 2>&1
  if grep -q "awaiting pg-demo $PG_SHA" "$PG_LEDGER" 2>/dev/null && _branch_absent "$PG_BARE" "$PG_BRANCH"; then
    PUSH_HELD=true
    checkpoint push_gate_held_no_push pass "hold recorded (awaiting ${PG_SHA}); NOTHING pushed to origin"
  else
    checkpoint push_gate_held_no_push fail "hold not recorded or branch leaked to origin before approval"
  fi

  # (B) APPROVE resumes: push + PR proceed; the branch is now on origin and pr.json is written.
  pg_env "$PG_REPO" bash "$ENGINE/herd-approve.sh" approve pg-demo >/dev/null 2>&1
  if _branch_exists "$PG_BARE" "$PG_BRANCH" && [ -f "$PG_PR_JSON" ] \
     && grep -q "pushed pg-demo $PG_SHA" "$PG_LEDGER" 2>/dev/null; then
    PUSH_RESUMED=true
    checkpoint push_gate_resumed pass "approve resumed: branch pushed to origin, PR created"
  else
    checkpoint push_gate_resumed fail "approve did not resume push+PR (branch/pr.json/pushed missing)"
  fi
fi

# ── (3) ATTRIBUTION_POLICY (HERD-121): a Co-Authored-By: Claude trailer reds the gate naming the sha ─
# Drives the REAL scripts/herd/healthcheck.sh with ATTRIBUTION_POLICY=no-ai-coauthor. The lint scans
# DEFAULT_BRANCH..HEAD, so the trailer commit lives on a branch ahead of main. HEALTHCHECK_CMD is
# empty → the light profile is a clean syntax gate, so the ONLY thing that can red is the attribution
# lint. First a CLEAN commit proves the gate is green when there is no trailer (no false red).
step attribution "ATTRIBUTION_POLICY=no-ai-coauthor — Co-Authored-By: Claude reds the gate, names the sha"
AT_REPO="$ART/attr-repo"; gov_fixture_build "$AT_REPO" >/dev/null 2>&1
hc_run() { # <repo> <attr> <commitconv> — run the real healthcheck (light); echoes output, returns rc
  env HERD_CONFIG_FILE="$ART/.hc-no-config" DEFAULT_BRANCH="main" HEALTHCHECK_CMD="" \
      ATTRIBUTION_POLICY="$2" COMMIT_CONVENTION="$3" APP_SURFACE_GLOB="" NO_COLOR=1 \
      bash "$ENGINE/healthcheck.sh" "$1" --light 2>&1
}

# Baseline: a clean (trailer-free) commit → the attribution gate is GREEN.
git -C "$AT_REPO" checkout -q -b feat/attr-clean
printf '\n- 🔜 Clean note.\n' >> "$AT_REPO/BACKLOG.md"
_sf_git_env
git -C "$AT_REPO" add -A && git -C "$AT_REPO" commit -q -m "docs: add a clean note"
_ac_rc=0; hc_run "$AT_REPO" no-ai-coauthor "" >/dev/null 2>&1 || _ac_rc=$?
if [ "$_ac_rc" -eq 0 ]; then
  checkpoint attribution_clean_baseline pass "a trailer-free commit passes the attribution gate (no false red)"
else
  checkpoint attribution_clean_baseline fail "a clean commit was reddened (rc=$_ac_rc) — false red"
fi

# The offending commit: a Co-Authored-By: Claude trailer. Under the FORCE flag the trailer is OMITTED
# (the negative leg), so the gate stays green when we assert it must red — flipping this one checkpoint.
git -C "$AT_REPO" checkout -q main
git -C "$AT_REPO" checkout -q -b feat/attr-dirty
printf '\n- 🔜 Trailer note.\n' >> "$AT_REPO/BACKLOG.md"
_sf_git_env
if [ -n "$FORCE_FAIL" ]; then
  git -C "$AT_REPO" add -A && git -C "$AT_REPO" commit -q -m "docs: add a note"
  info "FORCE flag: committed WITHOUT the trailer — the gate should (wrongly) stay green"
else
  git -C "$AT_REPO" add -A && git -C "$AT_REPO" commit -q -m "docs: add a note

Co-Authored-By: Claude <noreply@anthropic.com>"
fi
OFFENDING_SHA="$(git -C "$AT_REPO" rev-parse --short=12 HEAD)"
_ad_out="$(hc_run "$AT_REPO" no-ai-coauthor "")"; _ad_rc=$?
if [ "$_ad_rc" -eq 1 ] \
   && printf '%s' "$_ad_out" | grep -q 'ATTRIBUTION LINT' \
   && printf '%s' "$_ad_out" | grep -q "$OFFENDING_SHA"; then
  ATTR_RED=true
  checkpoint attribution_red_names_sha pass "trailer commit reds the gate naming sha $OFFENDING_SHA"
else
  checkpoint attribution_red_names_sha fail "trailer commit did NOT red naming its sha (rc=$_ad_rc, sha=$OFFENDING_SHA)"
fi

# ── (4) BRANCH_TEMPLATE (HERD-120) / COMMIT_CONVENTION (HERD-124): non-conforming names refused ────
step convention "BRANCH_TEMPLATE / COMMIT_CONVENTION — refuse a non-conforming branch name + commit subject"
# Branch: with the adopted BRANCH_TEMPLATE=feat/{slug}, a name conforms iff it round-trips through the
# REAL herd_branch_parse → herd_branch_render (HERD-120). A conforming name is accepted; a
# non-conforming one is refused.
branch_conforms() { # <branch> — rc 0 iff <branch> round-trips under BRANCH_TEMPLATE=feat/{slug}
  env HERD_CONFIG_FILE="$ART/.bt-no-config" BRANCH_TEMPLATE="feat/{slug}" \
      PROJECT_ROOT="$ART" WORKTREES_DIR="$ART" bash -c '
    . "$1/herd-config.sh" >/dev/null 2>&1 || exit 3
    slug="$(herd_branch_parse "$2")"
    [ "$(herd_branch_render "$slug")" = "$2" ]
  ' _ "$ENGINE" "$1"
}
if branch_conforms "feat/add-farewell" && ! branch_conforms "wip/add-farewell"; then
  BRANCH_REFUSED=true
  checkpoint branch_template_refuses_nonconforming pass "feat/add-farewell accepted; wip/add-farewell refused"
else
  checkpoint branch_template_refuses_nonconforming fail "branch conformance check did not accept-conforming/refuse-nonconforming"
fi

# Commit subject: the REAL healthcheck commit-convention lint (HERD-124) reds a non-conforming subject
# and passes a conforming one. Fresh fixture so main..HEAD holds exactly the one commit under test.
CC_PAT="^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)"
CC_REPO="$ART/cc-repo"; gov_fixture_build "$CC_REPO" >/dev/null 2>&1
git -C "$CC_REPO" checkout -q -b feat/cc-bad
printf '\n- 🔜 CC note.\n' >> "$CC_REPO/BACKLOG.md"
_sf_git_env
git -C "$CC_REPO" add -A && git -C "$CC_REPO" commit -q -m "add farewell command"   # non-conforming subject
_cb_rc=0; _cb_out="$(hc_run "$CC_REPO" "" "$CC_PAT")" || _cb_rc=$?
# And a conforming subject on a sibling branch stays green.
git -C "$CC_REPO" checkout -q main
git -C "$CC_REPO" checkout -q -b feat/cc-good
printf '\n- 🔜 CC ok.\n' >> "$CC_REPO/BACKLOG.md"
_sf_git_env
git -C "$CC_REPO" add -A && git -C "$CC_REPO" commit -q -m "feat: add farewell command"
_cg_rc=0; hc_run "$CC_REPO" "" "$CC_PAT" >/dev/null 2>&1 || _cg_rc=$?
if [ "$_cb_rc" -eq 1 ] && printf '%s' "$_cb_out" | grep -q 'COMMIT CONVENTION' && [ "$_cg_rc" -eq 0 ]; then
  COMMIT_REFUSED=true
  checkpoint commit_convention_refuses_nonconforming pass "non-conforming subject refused; 'feat: …' accepted"
else
  checkpoint commit_convention_refuses_nonconforming fail "commit-convention gate wrong (bad rc=$_cb_rc, good rc=$_cg_rc)"
fi

# ── (5) RESET CONTRACT: the governance fixture rebuilds byte-identical (same HEAD sha) ────────────
step reset "reset contract — the fixture rebuilds to a byte-identical HEAD sha"
RS_A="$ART/reset-a"; RS_B="$ART/reset-b"
SHA_A="$(gov_fixture_build "$RS_A")"
SHA_B="$(gov_fixture_build "$RS_B")"
if [ -n "$SHA_A" ] && [ "$SHA_A" = "$SHA_B" ] && [ "$SHA_A" = "$FIXTURE_SHA" ]; then
  RESET_IDENTICAL=true
  checkpoint reset_byte_identical pass "three independent builds all yield HEAD $SHA_A"
else
  checkpoint reset_byte_identical fail "non-deterministic fixture (a=$SHA_A b=$SHA_B seed=$FIXTURE_SHA)"
fi
# Teardown residue: the throwaway repos are wholly under $ART (removed on exit unless --keep).
rm -rf "$RS_A" "$RS_B"

# ── zero model calls: the deterministic table classified everything; the LLM was never invoked ────
step model-calls "assert ZERO model calls (LLM fallback stubbed; the table alone classified)"
MODEL_CALLS="$(wc -l < "$MODEL_LOG" 2>/dev/null | tr -d ' ')"; MODEL_CALLS="${MODEL_CALLS:-0}"
if [ "$MODEL_CALLS" -eq 0 ]; then
  checkpoint zero_model_calls pass "no claude invocation recorded (deterministic-only)"
else
  checkpoint zero_model_calls fail "the LLM fallback fired $MODEL_CALLS time(s): $(head -1 "$MODEL_LOG")"
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
