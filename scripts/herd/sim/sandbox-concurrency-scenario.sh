#!/usr/bin/env bash
# scripts/herd/sim/sandbox-concurrency-scenario.sh — P1 CONCURRENCY scenario for the sandbox consumer.
#
# Extends the P0 rig (sandbox-fixture.sh / sandbox-scenario.sh) from a single happy-path PR to a
# CONCURRENCY drain: it opens N>=3 STUB-builder PRs SIMULTANEOUSLY (deterministic tiny changes, NO
# model call) and drives the REAL watcher gate loop against them — not a re-implementation. It sources
# scripts/herd/agent-watch.sh in lib mode (AGENT_WATCH_LIB=1) and calls the SHIPPED gate functions
# (_healthcheck_gate, _review_gate_step, _count_live_reviews, do_merge, already_merged, …) in the
# exact order the watcher's action pass does (agent-watch.sh:2941–3123), tick by tick, until the queue
# drains. So the concurrency accounting under test is the production code's, and this scenario breaks
# if that code regresses.
#
# It asserts the four concurrency invariants as scorecard checkpoints:
#   (a) REVIEW_CONCURRENCY respected — never more than the configured reviews are in flight at once
#       (peak observed live reviewers <= REVIEW_CONCURRENCY), and the cap ACTIVELY gates (>=1 PR is
#       QUEUED while the slots are full — a non-vacuous test).
#   (b) HEALTH_CONCURRENCY=1 serializes healthchecks, NO interleaving — the stub healthcheck records
#       the live .health-inflight-* marker count on every invocation and it is ALWAYS exactly 1; plus
#       a planted-holder probe proves a second healthcheck QUEUEs (never runs) while a slot is busy.
#   (c) no double-merge, no skipped PR — each PR's `gh pr merge` fires exactly once (do_merge's STATE
#       record makes already_merged idempotent), and every opened PR ends merged.
#   (d) the queue drains fully — after the tick loop every PR is merged and its worktree reaped.
#
# VERIFICATION ARTIFACTS (into the artifacts dir):
#   • pane-<checkpoint>.txt — the watcher console frame captured back THROUGH the real driver
#     read-pane surface (herd_driver_read_pane, headless → tails the agent log). Not a re-render:
#     the frame is written to the headless agent log and read out via the shipped driver, exercising
#     that seam end-to-end.
#   • screenshots/watcher-<checkpoint>.png — macOS `screencapture` of the console at key checkpoints.
#     DEGRADES GRACEFULLY (no-false-red rule): skips with a note — never fails — when headless, not
#     macOS, `screencapture` is absent, Screen Recording permission is missing (empty/failed capture),
#     or SANDBOX_NO_SCREENSHOT=1 is set (the hermetic test sets this).
#
# HERMETIC: fixture-repo only. Stubs `gh` (PATH), HERD_REVIEW_BIN + HERD_HEALTHCHECK_BIN (documented
# test seams), HERD_DRIVER=headless (no herdr panes/tabs), and an ISOLATED WORKSPACE_NAME +
# temp WORKTREES_DIR — so it never touches the real herdkit repo's PRs, panes, or journal, and the
# tab-leak-guard cannot miscount it (no real tabs are ever created). `git` is NOT stubbed: the fixture
# is a real local repo and its worktrees/merges are real git.
#
# Usage:
#   bash scripts/herd/sim/sandbox-concurrency-scenario.sh [--artifacts DIR] [--keep] [-n N]
#     --artifacts DIR   put the repo + scorecard + artifacts here (default: a fresh mktemp dir)
#     --keep            do not delete the artifacts dir on exit (implied when --artifacts is given)
#     -n, --prs N       number of simultaneous stub PRs (default 3; minimum 3)
#   Env:
#     REVIEW_CONCURRENCY (default 2)   the review cap under test
#     SANDBOX_REVIEW_DELAY (default 1) seconds each stub review stays "in flight" (keeps reviewers
#                                      overlapping so the cap is observable); the inter-tick wait is
#                                      derived from it
#     SANDBOX_NO_SCREENSHOT=1          force-skip the screenshot step (set by the hermetic test)
#
# Exit: 0 = every checkpoint passed · 1 = at least one checkpoint failed (or a hard error).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/herd/sim/sandbox-fixture.sh
. "$HERE/sandbox-fixture.sh"
# shellcheck source=scripts/herd/sim/posture-lib.sh
. "$HERE/posture-lib.sh"   # canonical config postures (HERD-153) — see templates/postures.tsv

# ── output helpers (mirror sandbox-scenario.sh's style) ─────────────────────────────────────────
c_bold=$'\033[1m'; c_dim=$'\033[2m'
c_grn=$'\033[32m'; c_red=$'\033[31m'; c_yel=$'\033[33m'; c_rst=$'\033[0m'
step() { printf '\n%s[%s]%s %s\n' "$c_bold" "$1" "$c_rst" "$2"; }
ok()   { printf '  %s✓%s %s\n' "$c_grn" "$c_rst" "$*"; }
bad()  { printf '  %s✗%s %s\n' "$c_red" "$c_rst" "$*"; }
skip() { printf '  %s–%s %s\n' "$c_yel" "$c_rst" "$*"; }
info() { printf '  %s→%s %s\n' "$c_dim" "$c_rst" "$*"; }

# ── args ────────────────────────────────────────────────────────────────────────
# --posture <name> selects a canonical config posture (HERD-153, templates/postures.tsv). This
# scenario owns the MERGE-POLICY postures (solo-auto | team-approve | observe-only): each sets its
# .herd/config keys, drives the SHIPPED watcher gate loop at zero quota, and asserts the posture's
# merge invariant. An ABSENT --posture is byte-identical to today's single-posture run (POSTURE="" →
# every gate function and the whole assert path below is unchanged). --posture solo-auto runs the SAME
# drain, only tagging the scorecard with the posture field.
ART=""; KEEP=""; NPRS=3; POSTURE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --artifacts) ART="${2:-}"; KEEP=1; shift 2 ;;
    --keep)      KEEP=1; shift ;;
    -n|--prs)    NPRS="${2:-3}"; shift 2 ;;
    --posture)   POSTURE="${2:-}"; shift 2 ;;
    -h|--help)   grep -E '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "sandbox-concurrency-scenario: unknown arg: $1" >&2; exit 1 ;;
  esac
done
if [ -n "$POSTURE" ]; then
  posture_exists "$POSTURE" || { echo "sandbox-concurrency-scenario: unknown posture: $POSTURE" >&2; exit 1; }
  # This scenario only proves the MERGE-POLICY postures; push/steps postures are proven by the sibling
  # sandbox-scenario.sh. Refuse the others LOUDLY so the matrix wrapper's routing can never silently
  # run a posture through the wrong scenario.
  case "$POSTURE" in
    solo-auto|full-auto|team-approve|observe-only) : ;;
    *) echo "sandbox-concurrency-scenario: posture '$POSTURE' is not a merge-policy posture (use sandbox-scenario.sh)" >&2; exit 1 ;;
  esac
  # Apply the posture's real config keys BEFORE agent-watch.sh is sourced, so its module-level
  # _effective_merge_policy (which reads MERGE_POLICY once at source time) resolves under the posture.
  posture_apply "$POSTURE"
fi
case "$NPRS" in ''|*[!0-9]*) echo "sandbox-concurrency-scenario: -n must be an integer" >&2; exit 1 ;; esac
[ "$NPRS" -ge 3 ] || NPRS=3   # the scenario is only meaningful with >= 3 simultaneous PRs
if [ -z "$ART" ]; then ART="$(mktemp -d)"; fi
mkdir -p "$ART"
if [ -z "$KEEP" ]; then trap 'rm -rf "$ART"' EXIT; fi

SCENARIO="stub-concurrency-drain"
REPO="$ART/repo"
TREES="$ART/trees"
SHOTS="$ART/screenshots"
mkdir -p "$TREES" "$SHOTS"

REVIEW_DELAY="${SANDBOX_REVIEW_DELAY:-1}"
: "${REVIEW_CONCURRENCY:=2}"
HEALTH_CONCURRENCY=1

# ── checkpoint recording (bash 3.2: parallel indexed arrays, no assoc arrays) ───────────────────
CP_NAMES=(); CP_STATUS=(); CP_DETAIL=()
_pass=0; _fail=0
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

# ═══════════════════════════════════════════════════════════════════════════════
printf '%s══ Sandbox CONCURRENCY scenario: %s (N=%d PRs, REVIEW_CONCURRENCY=%d) ══%s\n' \
  "$c_bold" "$SCENARIO" "$NPRS" "$REVIEW_CONCURRENCY" "$c_rst"
printf '  artifacts: %s\n' "$ART"

# ── init: build the deterministic fixture (this is $PROJECT_ROOT / $MAIN for the watcher) ────────
step init "build deterministic local fixture"
FIXTURE_SHA="$(sandbox_fixture_build "$REPO")" || { bad "fixture build failed"; exit 1; }
info "fixture HEAD: $FIXTURE_SHA"
[ -f "$REPO/app/greet.sh" ] && checkpoint fixture_built pass "fixture at $REPO (HEAD ${FIXTURE_SHA:0:12})" \
  || checkpoint fixture_built fail "fixture missing app/greet.sh"

# ── open N stub-builder PRs SIMULTANEOUSLY: one real worktree/branch per PR, each a deterministic
#    tiny change (no model call). Every PR is constructed CLEAN + MERGEABLE. ─────────────────────
step open "open $NPRS stub-builder PRs simultaneously (deterministic; no model call)"
_sf_git_env
PR_NUM=(); PR_SLUG=(); PR_DIR=(); PR_BRANCH=(); PR_SHA=()
i=1
while [ "$i" -le "$NPRS" ]; do
  slug="feat-$i"; branch="sim/$slug"; dir="$TREES/$slug"; num=$((100 + i))
  git -C "$REPO" worktree add -q -b "$branch" "$dir" main 2>/dev/null \
    || { bad "worktree add failed for $slug"; exit 1; }
  # Deterministic, unique, tiny change — a per-PR command file. No model, byte-stable.
  cat > "$dir/app/$slug.sh" <<FEAT
#!/usr/bin/env bash
# $slug.sh — added by the stub builder for PR #$num (deterministic; no model call).
$(printf '%s' "$slug" | tr '-' '_')() { printf 'feature %s ready\n' "$slug"; }
if [ "\${BASH_SOURCE[0]}" = "\$0" ]; then $(printf '%s' "$slug" | tr '-' '_') "\$@"; fi
FEAT
  chmod +x "$dir/app/$slug.sh"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m "stub-builder: implement $slug (PR #$num)"
  sha="$(git -C "$dir" rev-parse HEAD)"
  PR_NUM+=("$num"); PR_SLUG+=("$slug"); PR_DIR+=("$dir"); PR_BRANCH+=("$branch"); PR_SHA+=("$sha")
  i=$((i+1))
done
_ntrees="$(git -C "$REPO" worktree list --porcelain | grep -c '^worktree ')"
# N feature worktrees + the main checkout.
if [ "$_ntrees" -eq $((NPRS + 1)) ]; then
  checkpoint prs_opened pass "$NPRS builder worktrees/branches opened simultaneously off main"
else
  checkpoint prs_opened fail "expected $((NPRS + 1)) worktrees (N+main), found $_ntrees"
fi

# ── hermetic stubs: gh (PATH), stub reviewer + healthcheck (seams), headless driver ─────────────
step stubs "install hermetic stubs (gh · reviewer · healthcheck · headless driver)"
BIN="$ART/bin"; mkdir -p "$BIN"
MERGE_LOG="$ART/gh-merges.log"; : > "$MERGE_LOG"
# Stub `gh`: record merges (proves each PR merges exactly once), answer list/view/comment safely.
cat > "$BIN/gh" <<GH
#!/usr/bin/env bash
if [ "\${1:-}" = "pr" ] && [ "\${2:-}" = "merge" ]; then
  printf '%s\n' "\${3:-?}" >> "$MERGE_LOG"; exit 0
fi
if [ "\${1:-}" = "pr" ] && [ "\${2:-}" = "list" ]; then printf '[]\n'; exit 0; fi
if [ "\${1:-}" = "pr" ] && [ "\${2:-}" = "view" ]; then
  printf '{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefName":"","headRefOid":"","author":{"login":"herd-sim"}}\n'; exit 0
fi
exit 0
GH
chmod +x "$BIN/gh"
export PATH="$BIN:$PATH"

# Stub reviewer (HERD_REVIEW_BIN seam): stays "in flight" for $REVIEW_DELAY s, then writes REVIEW: PASS
# (atomic temp+mv, mirroring herd-review.sh's result-file contract). No model, no network.
STUB_REVIEW="$ART/stub-review.sh"
cat > "$STUB_REVIEW" <<'STUB'
#!/usr/bin/env bash
[ -n "${STUB_SPAWN_LOG:-}" ] && printf '%s %s\n' "$1" "$2" >> "$STUB_SPAWN_LOG"
sleep "${SANDBOX_REVIEW_DELAY:-1}"
if [ -n "${HERD_REVIEW_RESULT_FILE:-}" ]; then
  printf 'REVIEW: PASS\n' > "$HERD_REVIEW_RESULT_FILE.tmp.$$"
  mv "$HERD_REVIEW_RESULT_FILE.tmp.$$" "$HERD_REVIEW_RESULT_FILE"
fi
printf 'REVIEW: PASS\n'
STUB
chmod +x "$STUB_REVIEW"

# Stub healthcheck (HERD_HEALTHCHECK_BIN seam): always clean; on every invocation records how many
# .health-inflight-* markers are LIVE — the interleaving probe. Serialization (HEALTH_CONCURRENCY=1)
# means this count must ALWAYS be exactly 1.
STUB_HC="$ART/stub-healthcheck.sh"
cat > "$STUB_HC" <<'STUB'
#!/usr/bin/env bash
if [ -n "${STUB_HC_MARKERCOUNT_LOG:-}" ] && [ -n "${STUB_HC_TREES:-}" ]; then
  c=0
  for f in "$STUB_HC_TREES"/.health-inflight-*; do
    [ -e "$f" ] || continue
    pid="$(head -1 "$f" 2>/dev/null)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then c=$((c+1)); fi
  done
  printf '%s\n' "$c" >> "$STUB_HC_MARKERCOUNT_LOG"
fi
printf '✅ clean — sandbox concurrency stub\n'
exit 0
STUB
chmod +x "$STUB_HC"
checkpoint stubs_installed pass "gh + stub reviewer + stub healthcheck + headless driver ready"

# ── source the REAL watcher in lib mode (AGENT_WATCH_LIB=1 → functions only, no loop / re-exec) ──
step source "source the REAL agent-watch.sh (lib mode) with the concurrency knobs"
export AGENT_WATCH_LIB=1
export HERD_CONFIG_FILE="$ART/no-such-config"    # ignore any ambient .herd/config
export HERD_DRIVER=headless                       # panes-as-a-view: no herdr tabs/panes ever created
export WORKSPACE_NAME="sandbox-conc-sim"          # isolated name (tab-leak-guard cannot miscount us)
export PROJECT_ROOT="$REPO"                        # → MAIN for do_merge's git ops
export WORKTREES_DIR="$TREES"                      # → TREES: all ledgers/markers/journal land here
export DEFAULT_BRANCH="main"
# MERGE_POLICY defaults to auto (today's behavior) but a --posture may already have set it
# (team-approve→approve, observe-only→observe) via posture_apply above; never clobber that.
export MERGE_POLICY="${MERGE_POLICY:-auto}"
export REVIEW_CONCURRENCY HEALTH_CONCURRENCY
export HERD_REVIEW_BIN="$STUB_REVIEW"
export HERD_HEALTHCHECK_BIN="$STUB_HC"
export STUB_SPAWN_LOG="$ART/review-spawns.log"; : > "$STUB_SPAWN_LOG"
export STUB_HC_MARKERCOUNT_LOG="$ART/health-markercount.log"; : > "$STUB_HC_MARKERCOUNT_LOG"
export STUB_HC_TREES="$TREES"
export SANDBOX_REVIEW_DELAY="$REVIEW_DELAY"
# Capture the engine dir (scripts/herd) BEFORE sourcing agent-watch.sh — sourcing it OVERWRITES this
# script's $HERE with agent-watch's own (scripts/herd), so any post-source path must not rely on $HERE.
ENGINE_DIR="$(cd "$HERE/.." && pwd)"
WATCH="$HERE/../agent-watch.sh"
[ -f "$WATCH" ] || { bad "agent-watch.sh not found at $WATCH"; exit 1; }
# shellcheck source=/dev/null
. "$WATCH" || { bad "sourcing agent-watch.sh (lib mode) failed"; exit 1; }

# The gate functions we drive must exist (proves we bound to the real watcher, not a stand-in).
_missing=""
for fn in _healthcheck_gate _review_gate_step _count_live_reviews _count_live_healthchecks \
          _health_slot_free _health_inflight_file _review_inflight_file do_merge already_merged \
          review_verdict _predispatch_review_if_parallel _gate_dispatch_mode \
          _breaker_gate _breaker_record_infra _breaker_record_ok _breaker_read; do
  type "$fn" >/dev/null 2>&1 || _missing="$_missing $fn"
done
if [ -z "$_missing" ]; then
  checkpoint watcher_bound pass "real agent-watch.sh gate functions sourced (lib mode)"
else
  checkpoint watcher_bound fail "missing gate functions:$_missing"
fi

# Neutralize the post-merge SIDE-QUESTS that are orthogonal to concurrency and would touch external
# surfaces (scribe enqueue, herdr tab teardown, codemap push, cost transcript scan). The
# concurrency- and merge-critical core of do_merge — the `gh pr merge` call, the STATE record that
# makes already_merged idempotent, the merge journal event, and the real `git worktree remove` reap
# — all remain the shipped code. render() is silenced like the unit tests do.
render() { :; }
reconcile_backlog() { :; }
refresh_codemap() { :; }
herd_teardown_slug() { :; }
cost_emit_merge() { :; }

# ── artifact helpers ────────────────────────────────────────────────────────────
# Pane capture THROUGH the real driver read-pane surface: write the console frame to the headless
# agent log, then read it back via herd_driver_read_pane (headless → tail the log).
PANE_SLUG="watch-console"
PANE_DIR="$TREES/.herd/agents/$PANE_SLUG"
mkdir -p "$PANE_DIR"
PANE_CAPTURES=0
capture_pane() {
  local label="$1"; shift
  local frame="$*"
  printf '%s\n' "$frame" > "$PANE_DIR/log"
  local out="$ART/pane-$label.txt" got
  got="$(herd_driver_read_pane "$PANE_SLUG" 2>/dev/null || true)"
  printf '%s\n' "$got" > "$out"
  if [ -s "$out" ]; then PANE_CAPTURES=$((PANE_CAPTURES+1)); info "pane captured via driver read-pane → $out"; fi
}

# macOS screenshot with graceful degradation (no-false-red): pass on capture, SKIP (never fail) on
# headless / non-macOS / missing tool / missing Screen Recording permission / opt-out.
SHOTS_TAKEN=0
take_screenshot() {
  local label="$1"; local out="$SHOTS/watcher-$label.png"
  if [ "${SANDBOX_NO_SCREENSHOT:-}" = "1" ]; then
    checkpoint "screenshot_$label" skip "opt-out (SANDBOX_NO_SCREENSHOT=1)"; return 0
  fi
  case "$(uname -s 2>/dev/null)" in
    Darwin) ;;
    *) checkpoint "screenshot_$label" skip "not macOS (screencapture unavailable)"; return 0 ;;
  esac
  command -v screencapture >/dev/null 2>&1 || { checkpoint "screenshot_$label" skip "screencapture not found"; return 0; }
  # A headless session or a missing Screen Recording permission makes screencapture fail or emit an
  # empty file — treat either as a graceful SKIP, never a failure.
  if screencapture -x "$out" >/dev/null 2>&1 && [ -s "$out" ]; then
    SHOTS_TAKEN=$((SHOTS_TAKEN+1))
    checkpoint "screenshot_$label" pass "captured $out"
  else
    rm -f "$out" 2>/dev/null || true
    checkpoint "screenshot_$label" skip "screencapture unavailable (headless or Screen Recording permission missing)"
  fi
}

# Build a watcher-console frame from the REAL DISPLAY[] rows the gate functions populate. Flair-aware
# exactly as the shipped render() is (HERD-147): it prepends the merge CELEBRATION + the PASTURE HEADER
# assembled by the REAL build_celebrate/build_pasture helpers. Byte-inert when WATCHER_FLAIR is off
# (the default the whole drive loop runs under), so the pane captures above are unchanged.
DISPLAY=()
FLAIR_STATE=()
console_frame() {
  local title="$1"
  local _grazing=0 _fs
  for _fs in ${FLAIR_STATE[@]+"${FLAIR_STATE[@]}"}; do [ "$_fs" = grazing ] && _grazing=$((_grazing+1)); done
  build_celebrate "$_grazing"   # sets CELEBRATE (empty when off/none); consumes the pending marker
  build_pasture                 # sets PASTURE   (empty when off/idle)
  printf '🐑 herd watch · %s · %s\n' "$WORKSPACE_NAME" "$title"
  [ -n "${CELEBRATE:-}" ] && printf '%s' "$CELEBRATE"
  [ -n "${PASTURE:-}" ] && printf '%s' "$PASTURE"
  printf '   in flight\n'
  local r
  for r in ${DISPLAY[@]+"${DISPLAY[@]}"}; do [ -n "$r" ] && printf '%s\n' "$r"; done
}

# ── DRIVE the real gate loop, tick by tick, until the queue drains ──────────────────────────────
step drive "drive the REAL watcher gate loop (health → review → merge) until drained"
PEAK_REVIEWS=0
MAX_HEALTH_INFLIGHT=0
QUEUED_PRS=""            # space-list of PRs that were QUEUED behind the review cap at least once
NIDX=$((NPRS - 1))

record_peak_reviews() {
  local c; c="$(_count_live_reviews)"
  [ "$c" -gt "$PEAK_REVIEWS" ] && PEAK_REVIEWS="$c"
}
all_merged() {
  local k
  for k in $(seq 0 "$NIDX"); do already_merged "${PR_NUM[$k]}" "${PR_SLUG[$k]}" || return 1; done
  return 0
}

# One tick == one pass of the watcher's action loop over every candidate, in the SHIPPED order:
#   already_merged → _healthcheck_gate → review gate (_review_gate_step) → do_merge on PASS.
run_tick() {
  local k pr slug dir sha prior stepv
  for k in $(seq 0 "$NIDX"); do
    pr="${PR_NUM[$k]}"; slug="${PR_SLUG[$k]}"; dir="${PR_DIR[$k]}"; sha="${PR_SHA[$k]}"
    already_merged "$pr" "$slug" && continue

    # INFRA CIRCUIT BREAKER (HERD-110) — mirror the watcher's action pass: a BLOCKED candidate skips
    # ALL dispatch this tick. Byte-inert (always PASS) under the default INFRA_BREAKER_MAX=0, so the
    # happy-path drain below proves the gate is transparent when the breaker is off.
    case "$(_breaker_gate "$pr")" in
      BLOCKED) continue ;;
      *) : ;;
    esac

    # PARALLEL GATE DISPATCH (GATE_DISPATCH=parallel) — mirror the watcher's action pass: kick the
    # review off CONCURRENTLY with the healthcheck via the SHIPPED helper. A strict no-op under serial
    # (default), so the same tick loop verifies BOTH modes. record_peak_reviews after it so a review
    # dispatched early still counts toward the observed peak (checkpoint a).
    _predispatch_review_if_parallel "$pr" "$slug" "$sha"
    record_peak_reviews

    # (b) SERIALIZED healthcheck gate — real function; sha-keyed cache means one run per PR.
    _HC_RESULT=""
    _healthcheck_gate "$pr" "$slug" "$dir" "$k" "$sha"
    case "$_HC_RESULT" in
      CLEAN|FLAKY) : ;;      # passed → gate on
      *) continue ;;         # QUEUED / CODEERROR → re-evaluate next tick, never merge
    esac

    # (a) BACKGROUND review gate — real function, bounded by REVIEW_CONCURRENCY.
    prior="$(review_verdict "$pr" "$sha" 2>/dev/null || true)"
    if [ "$prior" != "PASS" ]; then
      stepv="$(_review_gate_step "$pr" "$slug" "$sha")"
      record_peak_reviews
      case "$stepv" in
        PASS) : ;;                                   # verdict collected → fall through to merge
        QUEUED) case " $QUEUED_PRS " in *" $pr "*) : ;; *) QUEUED_PRS="$QUEUED_PRS $pr" ;; esac
                continue ;;
        *) continue ;;                               # RUNNING / RETRY / ESCALATED → next tick
      esac
    fi

    # (c) MERGE — real do_merge (gh pr merge stub + STATE record + real worktree reap). Under a
    # --posture the merge is gated by the SHIPPED policy decision (the exact action-pass logic:
    # _hold_decision over the effective mode + sha-keyed approval), so team-approve HOLDs and
    # observe-only OBSERVEs instead of merging. When POSTURE is empty the decision is skipped entirely
    # and this is byte-identical to today (always MERGE → do_merge → merged row).
    _pdec=MERGE
    [ -n "$POSTURE" ] && _pdec="$(_posture_merge_decision "$pr" "$sha")"
    case "$_pdec" in
      MERGE)
        do_merge "$slug" "$pr" "$dir" "$sha"
        DISPLAY[$k]="    ${c_grn}✅${c_rst} $(printf '%-14s' "$slug") ${c_dim}#${pr}${c_rst} · ${c_grn}merged${c_rst}"
        ;;
      HOLD)
        approval_awaiting_noted "$pr" "$sha" || record_approval_awaiting "$pr" "$sha"
        DISPLAY[$k]="    ${c_yel}⏸${c_rst} $(printf '%-14s' "$slug") ${c_dim}#${pr}${c_rst} · ${c_yel}held · awaiting approval${c_rst}"
        ;;
      OBSERVE)
        observe_noted "$pr" "$sha" || record_observe_noted "$pr" "$sha"
        DISPLAY[$k]="    ${c_grn}✅${c_rst} $(printf '%-14s' "$slug") ${c_dim}#${pr}${c_rst} · ${c_dim}ready · observe mode${c_rst}"
        ;;
    esac
  done
}

# _posture_merge_decision <pr#> <sha> — echo MERGE | HOLD | OBSERVE for a PASS-gated PR under the
# effective merge policy, mirroring agent-watch.sh's action pass EXACTLY: derive the mode from the
# module vars agent-watch.sh set at source time (AUTOMERGE / MERGE_OBSERVE), read the sha-keyed
# approval, and defer to the SHIPPED _hold_decision. hv_hold is "" (the concurrency stubs open no
# HUMAN-VERIFY PRs), so auto → MERGE and the empty-POSTURE path never calls this.
_posture_merge_decision() {
  local pr="$1" sha="$2" mode approved=""
  mode=auto; [ -z "$AUTOMERGE" ] && mode=approve; [ -n "$MERGE_OBSERVE" ] && mode=observe
  approval_is_approved "$pr" "$sha" && approved=1
  _hold_decision "$mode" "" "$approved" "$HV_POLICY"
}

# Inter-tick wait must outlast a review's in-flight window so dispatched reviewers finish and their
# results are collectable on the next tick. Whole seconds keep it robust across `sleep` variants.
INTER_TICK=$((REVIEW_DELAY + 1))
MAX_TICKS=$((NPRS + 5))
TICKS=0

# ── POSTURE BRANCH: merge-policy postures that do NOT auto-drain (team-approve, observe-only) ─────────
# solo-auto (and the empty-POSTURE default) fall THROUGH to the standard drain loop below unchanged.
# team-approve and observe-only never merge on their own, so the drain-oriented asserts do not apply;
# each runs its own bounded gate-loop drive, asserts its merge invariant against the SHIPPED gate, emits
# a posture-tagged scorecard, and exits here (isolating posture logic from the pristine drain path).
if [ -n "$POSTURE" ] && { [ "$POSTURE" = team-approve ] || [ "$POSTURE" = observe-only ]; }; then
  # write_posture_scorecard <result> — machine-readable scorecard for a merge-policy posture. Carries
  # the posture + the merge-gating fields the wrapper asserts on (posture-specific), NOT the drain
  # fields. Reuses the CP_* arrays that checkpoint() populates.
  write_posture_scorecard() {
    local out="$ART/scorecard.json" result="$1" skipped=0 i n; n=${#CP_NAMES[@]}
    for ((i=0; i<n; i++)); do [ "${CP_STATUS[$i]}" = "skip" ] && skipped=$((skipped+1)); done
    {
      printf '{\n'
      printf '  "scenario": "%s",\n' "$SCENARIO"
      printf '  "posture": "%s",\n' "$POSTURE"
      printf '  "artifacts_dir": "%s",\n' "$ART"
      printf '  "repo_dir": "%s",\n' "$REPO"
      printf '  "fixture_sha": "%s",\n' "$FIXTURE_SHA"
      printf '  "result": "%s",\n' "$result"
      printf '  "passed": %d,\n' "$_pass"
      printf '  "failed": %d,\n' "$_fail"
      printf '  "skipped": %d,\n' "$skipped"
      printf '  "prs": %d,\n' "$NPRS"
      printf '  "merge_policy": "%s",\n' "${MERGE_POLICY:-}"
      printf '  "merges": %d,\n' "$_PM_MERGES"
      printf '  "merges_before_approval": %d,\n' "$_PM_MERGES_PREAPPROVAL"
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
  _merge_count() { [ -s "$MERGE_LOG" ] && wc -l < "$MERGE_LOG" | tr -d ' ' || printf 0; }
  # Bounded drive: tick until every PR has SETTLED (held or observed) or the tick budget is spent. Each
  # tick runs the real health→review→policy gate; nothing merges under either posture.
  _all_settled() {
    local k pr sha
    for k in $(seq 0 "$NIDX"); do
      pr="${PR_NUM[$k]}"; sha="${PR_SHA[$k]}"
      if [ "$POSTURE" = observe-only ]; then observe_noted "$pr" "$sha" || return 1
      else approval_awaiting_noted "$pr" "$sha" || return 1; fi
    done
    return 0
  }
  step drive "posture=$POSTURE — drive the SHIPPED gate loop (no auto-merge); assert the merge invariant"
  t=1
  while [ "$t" -le "$MAX_TICKS" ]; do
    TICKS="$t"; run_tick
    [ "$t" -eq 1 ] && capture_pane "posture-tick1" "$(console_frame "posture $POSTURE · tick 1 · gates running, no merge")"
    _all_settled && break
    sleep "$INTER_TICK"; t=$((t+1))
  done
  _PM_MERGES_PREAPPROVAL="$(_merge_count)"

  step assert "posture=$POSTURE — assert the merge invariant from the observed run"
  # Common leg: every PR reached a PASS-gated settle (held/observed) — the gate actually ran (so the
  # zero-merge result is a real GATE decision, not a stalled queue that never reached the merge seam).
  if _all_settled; then
    checkpoint posture_gates_settled pass "all $NPRS PRs reached the merge seam (gated PASS) under posture=$POSTURE"
  else
    checkpoint posture_gates_settled fail "not all PRs reached the merge seam within $TICKS ticks (gate did not run for every PR)"
  fi

  if [ "$POSTURE" = observe-only ]; then
    # observe-only invariant: NOTHING merges, ever — not even after an approval attempt.
    _obs_noted=0; for k in $(seq 0 "$NIDX"); do observe_noted "${PR_NUM[$k]}" "${PR_SHA[$k]}" && _obs_noted=$((_obs_noted+1)); done
    # Adversarial probe: record an explicit approval for one PR, then re-tick. observe must IGNORE it
    # (observe mode never merges, approval or not) — a real safety property, not a vacuous "no approval".
    printf '%s approved %s %s\n' "0" "${PR_NUM[0]}" "${PR_SHA[0]}" >> "$APPROVALS"
    run_tick
    _PM_MERGES="$(_merge_count)"
    if [ "$_PM_MERGES" -eq 0 ] && [ "$_obs_noted" -eq "$NPRS" ]; then
      checkpoint posture_observe_never_merges pass "observe: 0 merges across the whole run ($NPRS PRs observe-noted); an injected approval did NOT cause a merge"
    else
      checkpoint posture_observe_never_merges fail "observe merged something (merges=$_PM_MERGES) or not all observed (observed=$_obs_noted/$NPRS)"
    fi
  else
    # team-approve invariant: NOTHING merges without a sha-keyed approval. Pre-approval merges must be 0.
    if [ "$_PM_MERGES_PREAPPROVAL" -eq 0 ]; then
      checkpoint posture_approve_no_merge_preapproval pass "team-approve: 0 merges before any approval ($NPRS PRs held awaiting)"
    else
      checkpoint posture_approve_no_merge_preapproval fail "team-approve merged $_PM_MERGES_PREAPPROVAL PR(s) with NO approval on record"
    fi
    # Approve exactly ONE PR via the SHIPPED herd-approve.sh, re-tick: EXACTLY that PR merges, others hold.
    env HERD_CONFIG_FILE="$HERD_CONFIG_FILE" WORKTREES_DIR="$TREES" PROJECT_ROOT="$REPO" \
        DEFAULT_BRANCH=main NO_COLOR=1 HERD_DRIVER=headless \
        bash "$ENGINE_DIR/herd-approve.sh" approve "${PR_NUM[0]}" >/dev/null 2>&1 || true
    run_tick
    _after_one="$(_merge_count)"
    _first_merged=0; already_merged "${PR_NUM[0]}" "${PR_SLUG[0]}" && _first_merged=1
    if [ "$_after_one" -eq 1 ] && [ "$_first_merged" -eq 1 ]; then
      checkpoint posture_approve_merges_only_approved pass "team-approve: after approving #${PR_NUM[0]} only IT merged (merges=1); the other $((NPRS-1)) still held"
    else
      checkpoint posture_approve_merges_only_approved fail "approving one PR did not merge exactly it (merges=$_after_one, first_merged=$_first_merged)"
    fi
    # Approve the rest and drain, proving the hold is releasable and no double-merge slips through.
    for k in $(seq 1 "$NIDX"); do
      env HERD_CONFIG_FILE="$HERD_CONFIG_FILE" WORKTREES_DIR="$TREES" PROJECT_ROOT="$REPO" \
          DEFAULT_BRANCH=main NO_COLOR=1 HERD_DRIVER=headless \
          bash "$ENGINE_DIR/herd-approve.sh" approve "${PR_NUM[$k]}" >/dev/null 2>&1 || true
    done
    t=1; while [ "$t" -le "$MAX_TICKS" ]; do run_tick; all_merged && break; sleep "$INTER_TICK"; t=$((t+1)); done
    _PM_MERGES="$(_merge_count)"
    _dupes="$(sort "$MERGE_LOG" 2>/dev/null | uniq -d | grep -c . || true)"
    if all_merged && [ "$_PM_MERGES" -eq "$NPRS" ] && [ "$_dupes" -eq 0 ]; then
      checkpoint posture_approve_drains_after_approval pass "team-approve: all $NPRS merged only after approval; no double-merge"
    else
      checkpoint posture_approve_drains_after_approval fail "post-approval drain wrong (merges=$_PM_MERGES/$NPRS, dupes=$_dupes)"
    fi
  fi
  capture_pane "posture-drained" "$(console_frame "posture $POSTURE · settled in $TICKS ticks")"

  RESULT="pass"; [ "$_fail" -gt 0 ] && RESULT="fail"
  SCARD="$(write_posture_scorecard "$RESULT")"
  printf '\n%s══ posture scorecard (%s) ══%s\n' "$c_bold" "$POSTURE" "$c_rst"
  printf '  result:        %s\n' "$RESULT"
  printf '  passed/failed: %d / %d\n' "$_pass" "$_fail"
  printf '  merges:        %d (pre-approval %d)\n' "${_PM_MERGES:-0}" "$_PM_MERGES_PREAPPROVAL"
  printf '  scorecard:     %s\n' "$SCARD"
  [ "$RESULT" = "pass" ] && exit 0 || exit 1
fi

t=1
while [ "$t" -le "$MAX_TICKS" ]; do
  TICKS="$t"
  run_tick
  # Capture pane text + a screenshot right after the FIRST tick — the moment the review cap bites
  # (slots full, the rest QUEUED) — and again once drained.
  if [ "$t" -eq 1 ]; then
    capture_pane "tick1-cap-bites" "$(console_frame "tick 1 · review slots full, overflow queued")"
    take_screenshot "tick1-cap-bites"
  fi
  all_merged && break
  sleep "$INTER_TICK"
  t=$((t+1))
done

# Fold the observed max live-healthcheck count from the stub's interleaving log.
if [ -s "$STUB_HC_MARKERCOUNT_LOG" ]; then
  MAX_HEALTH_INFLIGHT="$(sort -nr "$STUB_HC_MARKERCOUNT_LOG" | head -1)"
fi
HEALTH_RUNS="$(wc -l < "$STUB_HC_MARKERCOUNT_LOG" | tr -d ' ')"

capture_pane "drained" "$(console_frame "drained · all $NPRS PRs merged in $TICKS ticks")"
take_screenshot "drained"

# ── ASSERT the four concurrency invariants ──────────────────────────────────────────────────────
step assert "assert concurrency invariants from the observed run"

# (a) REVIEW_CONCURRENCY — peak never exceeded the cap, AND the cap actively gated (>=1 PR queued).
_q_count=0; for _q in $QUEUED_PRS; do _q_count=$((_q_count+1)); done
if [ "$PEAK_REVIEWS" -le "$REVIEW_CONCURRENCY" ] && [ "$PEAK_REVIEWS" -ge 1 ]; then
  checkpoint review_concurrency_respected pass "peak live reviews=$PEAK_REVIEWS <= REVIEW_CONCURRENCY=$REVIEW_CONCURRENCY"
else
  checkpoint review_concurrency_respected fail "peak live reviews=$PEAK_REVIEWS exceeded REVIEW_CONCURRENCY=$REVIEW_CONCURRENCY"
fi
if [ "$_q_count" -ge 1 ]; then
  checkpoint review_cap_gated pass "$_q_count PR(s) QUEUED behind the cap (non-vacuous):$QUEUED_PRS"
else
  checkpoint review_cap_gated fail "no PR ever queued — the cap never actually gated (vacuous test)"
fi

# (b) HEALTH_CONCURRENCY=1 — no interleaving: every recorded live-marker count is exactly 1.
if [ "$HEALTH_RUNS" -ge 1 ] && [ "$MAX_HEALTH_INFLIGHT" = "1" ] && ! grep -qvx '1' "$STUB_HC_MARKERCOUNT_LOG"; then
  checkpoint health_serialized pass "$HEALTH_RUNS healthchecks ran, max concurrent=1 (no interleaving)"
else
  checkpoint health_serialized fail "healthchecks interleaved: max concurrent=$MAX_HEALTH_INFLIGHT (log: $(paste -sd' ' - < "$STUB_HC_MARKERCOUNT_LOG"))"
fi

# (b′) Active proof of the mutex: with a slot occupied by a live holder, a new healthcheck QUEUEs
#      (never runs) — the exact mechanism that prevents interleaving under contention.
_probe_before="$(wc -l < "$STUB_HC_MARKERCOUNT_LOG" | tr -d ' ')"
printf '%s\n' "$$" > "$(_health_inflight_file 99999)"     # plant a live holder (this pid is alive)
_HC_RESULT=""
_healthcheck_gate 88888 probe-slug "$REPO" 0 ""
_probe_after="$(wc -l < "$STUB_HC_MARKERCOUNT_LOG" | tr -d ' ')"
_health_release 99999
if [ "$_HC_RESULT" = "QUEUED" ] && [ "$_probe_before" = "$_probe_after" ]; then
  checkpoint health_mutex_queues pass "a healthcheck QUEUED (stub not invoked) while the single slot was busy"
else
  checkpoint health_mutex_queues fail "expected QUEUED with stub not invoked (got '$_HC_RESULT', runs ${_probe_before}→${_probe_after})"
fi

# (c) no double-merge, no skipped PR — each PR merged exactly once.
_merge_total="$(wc -l < "$MERGE_LOG" | tr -d ' ')"
_merge_uniq="$(sort -u "$MERGE_LOG" | grep -c . || true)"
_dupes="$(sort "$MERGE_LOG" | uniq -d | grep -c . || true)"
if [ "$_dupes" -eq 0 ] && [ "$_merge_total" = "$_merge_uniq" ]; then
  checkpoint no_double_merge pass "$_merge_total merges, all unique (0 double-merges)"
else
  checkpoint no_double_merge fail "double-merge detected: $_merge_total merges, $_merge_uniq unique, $_dupes repeated"
fi
_skipped=0; _merged_ct=0
for k in $(seq 0 "$NIDX"); do
  if already_merged "${PR_NUM[$k]}" "${PR_SLUG[$k]}"; then _merged_ct=$((_merged_ct+1)); else _skipped=$((_skipped+1)); fi
done
if [ "$_skipped" -eq 0 ] && [ "$_merged_ct" -eq "$NPRS" ]; then
  checkpoint no_skipped_pr pass "all $NPRS PRs merged (0 skipped)"
else
  checkpoint no_skipped_pr fail "$_skipped PR(s) never merged ($_merged_ct/$NPRS merged)"
fi

# (d) queue drains fully — every PR merged within the tick budget, and its worktree was reaped.
_live_trees=0
for k in $(seq 0 "$NIDX"); do [ -d "${PR_DIR[$k]}" ] && _live_trees=$((_live_trees+1)); done
if all_merged && [ "$_merged_ct" -eq "$NPRS" ]; then
  checkpoint queue_drained pass "queue fully drained in $TICKS ticks ($_merged_ct/$NPRS); $_live_trees builder worktrees remain (reaped)"
else
  checkpoint queue_drained fail "queue did not drain: $_merged_ct/$NPRS merged after $TICKS ticks"
fi

# Artifact-presence checkpoints (the captures themselves; screenshots asserted inline, may skip).
if [ "$PANE_CAPTURES" -ge 1 ]; then
  checkpoint pane_text_captured pass "$PANE_CAPTURES console frame(s) captured via driver read-pane"
else
  checkpoint pane_text_captured fail "driver read-pane surface produced no pane text"
fi

# ── FAULT-INJECTED DEAD-ENV PATH: INFRA circuit breaker (HERD-110) ──────────────────────────────
# The happy path above ran with the breaker OFF (INFRA_BREAKER_MAX unset → 0), proving it is byte-inert.
# Now inject a DEAD ENVIRONMENT: reviewers that die WITHOUT writing a verdict (INFRA-FAIL / non-verdict
# death), across multiple PRs, and drive the SHIPPED functions (_review_gate_step → _breaker_record_infra
# → _breaker_gate) to assert the breaker: (1) OPENs after INFRA_BREAKER_MAX consecutive non-verdict
# deaths and SUPPRESSes further dispatch; (2) NEVER trips on a real BLOCK verdict (the INFRA-vs-verdict
# distinction the whole feature hinges on); (3) HALF-OPENs after the cooldown for a single probe that a
# real verdict CLOSEs; (4) is byte-inert when disabled. Uses the real watcher functions in lib mode.
step deadenv "fault-inject a dead reviewer environment and assert the INFRA circuit breaker (HERD-110)"

BRK_MAX=3
export INFRA_BREAKER_MAX="$BRK_MAX"
export INFRA_BREAKER_COOLDOWN=2
: > "$REVIEW_RETRIES" 2>/dev/null || true
rm -f "$INFRA_BREAKER_STATE" 2>/dev/null || true

# _plant_and_step <pr> <sha> <verdict-line> — write a reviewer result file exactly as herd-review.sh
# would (atomic-ish), then run the SHIPPED review gate step which collects it. <verdict-line> of
# 'REVIEW: INFRA-FAIL' models a reviewer that died with no real verdict; 'REVIEW: BLOCK …' / 'REVIEW:
# PASS' model real verdicts. Echoes the gate token.
_plant_and_step() {
  local pr="$1" sha="$2" line="$3" rf
  rf="$(_review_result_file "$pr" "$sha")"
  printf '%s\n' "$line" > "$rf.tmp.$$"; mv "$rf.tmp.$$" "$rf"
  _review_gate_step "$pr" "dead-$pr" "$sha"
}

# (1) N consecutive non-verdict deaths across DISTINCT PRs → breaker OPENs, dispatch suppressed.
_brk_opened=""; _brk_gate_before=""; _brk_gate_after=""
_brk_gate_before="$(_breaker_gate 901)"          # closed → PASS
d=1
while [ "$d" -le "$BRK_MAX" ]; do
  pr=$((900 + d)); _tok="$(_plant_and_step "$pr" "deadsha$pr" 'REVIEW: INFRA-FAIL')"
  info "dead-env death $d/$BRK_MAX: PR #$pr review gate → $_tok · breaker=[$(_breaker_read)]"
  d=$((d + 1))
done
_brk_gate_after="$(_breaker_gate 999)"           # open (cooling down) → BLOCKED
read -r _bs _bf _bo _bp <<EOF
$(_breaker_read)
EOF
if [ "$_bs" = "open" ] && [ "$_brk_gate_before" = "PASS" ] && [ "$_brk_gate_after" = "BLOCKED" ]; then
  _brk_opened=1
  checkpoint infra_breaker_opens pass "breaker OPEN after $BRK_MAX consecutive non-verdict deaths; dispatch suppressed (gate PASS→BLOCKED)"
else
  checkpoint infra_breaker_opens fail "expected OPEN+BLOCKED (state=$_bs, gate before=$_brk_gate_before after=$_brk_gate_after)"
fi

# (2) CRITICAL: a real BLOCK verdict must NEVER trip the breaker. Reset and feed BRK_MAX+2 real BLOCK
# verdicts — the breaker must stay CLOSED the whole time (a BLOCK proves the env is alive).
: > "$REVIEW_RETRIES" 2>/dev/null || true
rm -f "$INFRA_BREAKER_STATE" 2>/dev/null || true
_blk_tripped=""
b=1; _blk_lim=$((BRK_MAX + 2))
while [ "$b" -le "$_blk_lim" ]; do
  pr=$((920 + b)); _tok="$(_plant_and_step "$pr" "blksha$pr" 'REVIEW: BLOCK — rule: r | why: w | location: l')"
  read -r _bs _ _ _ <<EOF
$(_breaker_read)
EOF
  [ "$_bs" != "closed" ] && _blk_tripped=1
  b=$((b + 1))
done
if [ -z "$_blk_tripped" ] && [ "$(_breaker_gate 999)" = "PASS" ]; then
  checkpoint infra_breaker_ignores_block pass "$_blk_lim real BLOCK verdicts never tripped the breaker (stayed CLOSED — INFRA≠verdict)"
else
  checkpoint infra_breaker_ignores_block fail "a real BLOCK verdict tripped the breaker (state=$(_breaker_read)) — MUST NOT happen"
fi

# (3) HALF-OPEN single probe + recovery: re-open on deaths, wait the cooldown, then exactly ONE
# candidate is admitted as the probe (PROBE) while siblings are BLOCKED; a real verdict CLOSEs it.
: > "$REVIEW_RETRIES" 2>/dev/null || true
rm -f "$INFRA_BREAKER_STATE" 2>/dev/null || true
d=1
while [ "$d" -le "$BRK_MAX" ]; do
  pr=$((940 + d)); _plant_and_step "$pr" "resha$pr" 'REVIEW: INFRA-FAIL' >/dev/null; d=$((d + 1))
done
sleep 3   # outlast INFRA_BREAKER_COOLDOWN=2
_probe="$(_breaker_gate 941)"     # first candidate claims the single probe
_sib1="$(_breaker_gate 942)"      # sibling blocked (one probe only)
_sib2="$(_breaker_gate 943)"
_probe_again="$(_breaker_gate 941)"   # same probe PR keeps PROBE across ticks (dispatch then collect)
# Probe yields a real PASS verdict → breaker CLOSEs, normal dispatch resumes.
_plant_and_step 941 "resha941ok" 'REVIEW: PASS' >/dev/null
_closed="$(_breaker_read)"; _gate_recovered="$(_breaker_gate 942)"
if [ "$_probe" = "PROBE" ] && [ "$_sib1" = "BLOCKED" ] && [ "$_sib2" = "BLOCKED" ] \
   && [ "$_probe_again" = "PROBE" ] && [ "${_closed%% *}" = "closed" ] && [ "$_gate_recovered" = "PASS" ]; then
  checkpoint infra_breaker_halfopen_recovers pass "half-open admitted exactly ONE probe (siblings BLOCKED); a real verdict CLOSEd the breaker and dispatch resumed"
else
  checkpoint infra_breaker_halfopen_recovers fail "half-open/recovery wrong (probe=$_probe sib1=$_sib1 sib2=$_sib2 again=$_probe_again closed=[$_closed] recovered=$_gate_recovered)"
fi

# (4) BYTE-INERT when disabled: the SAME dead-env sequence with INFRA_BREAKER_MAX=0 must write NO
# breaker ledger and the gate must always PASS.
export INFRA_BREAKER_MAX=0
: > "$REVIEW_RETRIES" 2>/dev/null || true
rm -f "$INFRA_BREAKER_STATE" 2>/dev/null || true
d=1
while [ "$d" -le "$((BRK_MAX + 1))" ]; do
  pr=$((960 + d)); _plant_and_step "$pr" "offsha$pr" 'REVIEW: INFRA-FAIL' >/dev/null; d=$((d + 1))
done
if [ ! -f "$INFRA_BREAKER_STATE" ] && [ "$(_breaker_gate 999)" = "PASS" ]; then
  checkpoint infra_breaker_byte_inert pass "disabled (INFRA_BREAKER_MAX=0): no breaker ledger written, gate always PASS (byte-inert)"
else
  checkpoint infra_breaker_byte_inert fail "disabled breaker was not byte-inert (ledger exists=$([ -f "$INFRA_BREAKER_STATE" ] && echo yes || echo no), gate=$(_breaker_gate 999))"
fi
unset INFRA_BREAKER_MAX INFRA_BREAKER_COOLDOWN

# ── (e) REVIEWER-PANE LIFECYCLE (HERD-113): exactly ONE reviewer per (pr,sha) survives a mid-review
#        watcher restart — the reviewer is NEVER duplicated. Reproduces the 2026-07-08 double-Opus
#        incident's shape against the SHIPPED gate: dispatch a review that stays in flight, then model a
#        watcher restart by re-running the startup registry sweep AND re-entering the review gate for the
#        SAME (pr,sha) while the reviewer is still live. The dispatch-registry adopt guard + the inflight
#        pid guard must make that a NO-OP — the stub reviewer is spawned exactly ONCE across the restart.
step restart "mid-review watcher restart: exactly one reviewer per (pr,sha) survives (never duplicated)"
RS_PR=900; RS_SLUG="feat-restart"; RS_SHA="restartsha900"
_rs_spawns() { grep -c "^$RS_PR $RS_SLUG\$" "$STUB_SPAWN_LOG" 2>/dev/null || printf 0; }
# Keep this reviewer in flight long enough to straddle the simulated restart (captured at spawn).
export SANDBOX_REVIEW_DELAY=30
_rs_step="$(_review_gate_step "$RS_PR" "$RS_SLUG" "$RS_SHA")"
# The reviewer spawns and its registry row + inflight marker land on disk (survives a restart). Poll
# briefly for the async spawn to register (the stub logs its spawn as its first act, then sleeps).
_rs_ok=1; _rs_deadline=$(( $(date +%s) + 6 ))
while [ "$(_rs_spawns)" -lt 1 ]; do
  [ "$(date +%s)" -ge "$_rs_deadline" ] && { _rs_ok=0; break; }
  sleep 0.2
done
[ -f "$(_review_registry_file "$RS_PR" "$RS_SHA")" ] || _rs_ok=0
[ -f "$(_review_inflight_file "$RS_PR" "$RS_SHA")" ] || _rs_ok=0
_rs_after_dispatch="$(_rs_spawns)"

# ── SIMULATE THE WATCHER RESTART ──
# The watcher is stateless between restarts except for these on-disk markers, so a restart is faithfully
# modeled by re-running the one-shot startup registry sweep and then re-entering the review gate for the
# same candidate — exactly what a restarted watcher's action pass does on its first tick.
_sweep_reviewer_registry                                   # startup sweep: a LIVE poller is adopted, left alone
_review_gate_step "$RS_PR" "$RS_SLUG" "$RS_SHA" >/dev/null  # restarted action pass re-scans this PR…
_review_gate_step "$RS_PR" "$RS_SLUG" "$RS_SHA" >/dev/null  # …and again a tick later
_rs_after_restart="$(_rs_spawns)"

# Tear the lingering reviewer down so the 30 s sleeper never outlives the scenario (kill the poller and
# drop its markers directly — no re-dispatch).
_rs_pid="$(head -1 "$(_review_inflight_file "$RS_PR" "$RS_SHA")" 2>/dev/null || true)"
[ -n "${_rs_pid:-}" ] && kill "$_rs_pid" 2>/dev/null || true
rm -f "$(_review_inflight_file "$RS_PR" "$RS_SHA")" "$(_review_registry_file "$RS_PR" "$RS_SHA")" \
      "$(_review_result_file "$RS_PR" "$RS_SHA")" 2>/dev/null || true

if [ "$_rs_ok" = 1 ] && [ "$_rs_after_dispatch" = "1" ] && [ "$_rs_after_restart" = "1" ]; then
  checkpoint one_reviewer_survives_restart pass \
    "reviewer for (#$RS_PR,$RS_SHA) spawned exactly once and was ADOPTED (not duplicated) across the restart"
else
  checkpoint one_reviewer_survives_restart fail \
    "reviewer duplicated across restart (dispatch=$_rs_after_dispatch, after-restart=$_rs_after_restart, setup_ok=$_rs_ok, first_step=$_rs_step)"
fi


# ── WATCHER FLAIR PACK (HERD-147): OFF byte-identical · ON adds the pasture header · dead rows LOUD ──
# Drives the REAL flair helpers (build_celebrate/build_pasture, sourced above in lib mode) through the
# flair-aware console_frame — the same surface the drive loop's pane captures use. Proves the two
# invariants the feature ships on: (1) WATCHER_FLAIR=off is byte-identical to a no-flag run (no pasture
# header, no celebration); (2) WATCHER_FLAIR=on adds a pasture header AND keeps the 💀 dead row
# byte-identical (never softened), and a pending merge renders one 'joins the flock' celebration line.
step flair "flair pack (HERD-147): OFF byte-identical · ON adds a pasture header, dead rows unchanged"
DISPLAY=(); FLAIR_STATE=()
DISPLAY+=("    ${c_red:-}💀${c_rst:-} dead-builder · builder died (no agent, no PR) · re-spawn"); FLAIR_STATE+=("dead")
DISPLAY+=("    🔨 graze-a · building");                                                          FLAIR_STATE+=("grazing")
DISPLAY+=("$(_row_awaiting_task 'nap-b' "$REPO")");                                             FLAIR_STATE+=("idle")
DISPLAY+=("    ✅ pen-c · ready · awaiting push approval");                                       FLAIR_STATE+=("pen")
_DEAD_ROW="${DISPLAY[0]}"

# (1) OFF byte-identical: a no-flag run (WATCHER_FLAIR unset → default off) and an explicit off run must
#     produce the SAME frame, and neither may leak a pasture header.
unset WATCHER_FLAIR;      _f_noflag="$(console_frame 'flair check')"
export WATCHER_FLAIR=off; _f_off="$(console_frame 'flair check')"
if [ "$_f_noflag" = "$_f_off" ] && ! printf '%s' "$_f_off" | grep -q 'pasture'; then
  checkpoint flair_off_byte_identical pass "off frame byte-identical to a no-flag run; no pasture header, no celebration"
else
  checkpoint flair_off_byte_identical fail "off-mode frame diverged from the no-flag run or leaked flair"
fi

# (2a) ON adds the pasture header (one glyph per builder by state).
export WATCHER_FLAIR=on; _f_on="$(console_frame 'flair check')"
if printf '%s' "$_f_on" | grep -q 'pasture' && printf '%s' "$_f_on" | grep -q '🐑'; then
  checkpoint flair_on_header_present pass "on renders the pasture header (🐑 grazing / 💤 idle / ✅ in the pen)"
else
  checkpoint flair_on_header_present fail "on-mode frame is missing the pasture header"
fi

# (2b) HARD RULE — the 💀 dead builder's row is byte-IDENTICAL in both modes (flair never touches DISPLAY).
if printf '%s\n' "$_f_off" | grep -qxF "$_DEAD_ROW" && printf '%s\n' "$_f_on" | grep -qxF "$_DEAD_ROW"; then
  checkpoint flair_dead_row_unchanged pass "💀 dead-builder row byte-identical in both modes (never softened)"
else
  checkpoint flair_dead_row_unchanged fail "dead-builder row changed between off/on — flair softened a loud state"
fi

# (2d) CLOSED VOCABULARY (HERD-172) — the spare-builder row (built above from the SHIPPED
#      _row_awaiting_task) must name whose move it is (awaiting task · assign or retire) and carry an
#      age, and the banned ownerless 'idle' state word must never reach an operator-facing frame.
if printf '%s' "$_f_on" | grep -q 'awaiting task · assign or retire' \
   && printf '%s' "$_f_on" | grep -qE 'assign or retire · [0-9]+[smhd]' \
   && ! printf '%s' "$_f_on" | grep -qw 'idle'; then
  checkpoint console_vocab_closed pass "spare-builder row uses the closed vocabulary (awaiting task · owner · age); no banned 'idle' word"
else
  checkpoint console_vocab_closed fail "console frame leaked the banned 'idle' word or is missing the awaiting-task vocabulary/age"
fi

# (2c) Merge CELEBRATION — a pending marker turns into exactly one 'joins the flock' line next frame.
printf '4242\n' > "$FLAIR_CELEBRATE_STATE"
_f_cel="$(console_frame 'flair check')"
if printf '%s' "$_f_cel" | grep -q '#4242 joins the flock'; then
  checkpoint flair_merge_celebration pass "post-merge celebration rendered ('🐑 #4242 joins the flock · N grazing')"
else
  checkpoint flair_merge_celebration fail "merge celebration line missing under WATCHER_FLAIR=on"
fi
unset WATCHER_FLAIR
DISPLAY=(); FLAIR_STATE=()

# ── WATCHER SINGLETON spawn-lock (HERD-209) — reproduce the duplicate-watcher race ──────────────
# The incident: control-room recovery spawned a SECOND agent-watch main while the first was still
# alive; both polled the same PRs and raced the shared .git object store, so healthchecks restarted
# endlessly. Drive the SHIPPED acquisition function _acquire_watcher_singleton (already sourced in lib
# mode above) against the two states that decide REFUSE-vs-ADOPT:
#   • LIVE lock  → a second launch REFUSES (spawns no duplicate), recorded pid untouched.
#   • STALE lock → a launch under a dead recorded pid PROCEEDS and adopts the lock.
# Each acquisition runs in a SUBSHELL so any flock fd / EXIT trap it installs never leaks into the
# scenario shell (a subshell models a separate launch process).
step singleton "watcher singleton spawn-lock (HERD-209): a second launch under a live lock refuses; a stale lock is adopted"

_SNGL_OK=1
if type _acquire_watcher_singleton >/dev/null 2>&1; then
  _sngl_lock="$ART/.singleton-watcher.pid"
  _sngl_saved="${HERD_WATCHER_LOCK:-}"
  export HERD_WATCHER_LOCK="$_sngl_lock"
  # A guaranteed-live pid we own; a guaranteed-dead pid (spawned then reaped).
  sleep 300 & _sngl_live=$!
  sleep 0   & _sngl_dead=$!; wait "$_sngl_dead" 2>/dev/null || true

  # (a) LIVE lock → REFUSE, recorded pid untouched.
  printf '%s\n' "$_sngl_live" > "$_sngl_lock"
  if ( _acquire_watcher_singleton >/dev/null 2>&1 ); then _sngl_a=ACQUIRE; else _sngl_a=REFUSE; fi
  _sngl_after_live="$(cat "$_sngl_lock" 2>/dev/null || true)"
  if [ "$_sngl_a" = "REFUSE" ] && [ "$_sngl_after_live" = "$_sngl_live" ]; then
    checkpoint watcher_singleton_refuses_live pass "a second launch under a LIVE lock (pid $_sngl_live) refused; no duplicate, recorded pid untouched"
  else
    checkpoint watcher_singleton_refuses_live fail "live-lock launch should REFUSE + preserve pid (got $_sngl_a, lock now '$_sngl_after_live')"
    _SNGL_OK=0
  fi

  # (b) STALE lock (dead pid) → PROCEED and adopt (dead pid overwritten).
  printf '%s\n' "$_sngl_dead" > "$_sngl_lock"
  if ( _acquire_watcher_singleton >/dev/null 2>&1 ); then _sngl_b=ACQUIRE; else _sngl_b=REFUSE; fi
  _sngl_after_stale="$(cat "$_sngl_lock" 2>/dev/null || true)"
  if [ "$_sngl_b" = "ACQUIRE" ] && [ "$_sngl_after_stale" != "$_sngl_dead" ]; then
    checkpoint watcher_singleton_adopts_stale pass "a launch under a STALE lock (dead pid $_sngl_dead) proceeded and adopted the lock"
  else
    checkpoint watcher_singleton_adopts_stale fail "stale-lock launch should PROCEED + adopt (got $_sngl_b, lock now '$_sngl_after_stale')"
    _SNGL_OK=0
  fi

  kill "$_sngl_live" 2>/dev/null || true
  rm -f "$_sngl_lock" 2>/dev/null || true
  # Restore the scenario's HERD_WATCHER_LOCK so nothing downstream sees our probe path.
  if [ -n "$_sngl_saved" ]; then export HERD_WATCHER_LOCK="$_sngl_saved"; else unset HERD_WATCHER_LOCK; fi
else
  checkpoint watcher_singleton_refuses_live fail "_acquire_watcher_singleton not defined (lib-mode source did not expose the singleton gate)"
  checkpoint watcher_singleton_adopts_stale fail "_acquire_watcher_singleton not defined"
  _SNGL_OK=0
fi

# ── MAIN-checkout freshness reconcile (HERD-233) — the cross-seat drift the drain above cannot show ──
# The incident: another seat merged, so THIS watcher's do_merge never ran, and its $MAIN checkout — the
# very tree it loads engine code from — silently fell 22 commits behind; a rejected generated-map push
# then left it DIVERGED until a human rebased by hand. Reproduce BOTH against the SHIPPED tick function
# reconcile_main_freshness (sourced in lib mode above), on a fixture where origin advances with no local
# do_merge, and assert (a) the ff + the real `main_ff` journal event, (b) that a local commit nobody
# generated is HELD, never rebased. $MAIN / remote vars are swapped onto the fixture and restored after.
step mainfresh "MAIN-checkout freshness (HERD-233): origin advances without a local do_merge → ff + main_ff; a hand commit is held"

_MF_OK=1
if type reconcile_main_freshness >/dev/null 2>&1; then
  _mf_root="$ART/mainfresh"; rm -rf "$_mf_root"; mkdir -p "$_mf_root"
  _mf_origin="$_mf_root/origin.git"; git init -q --bare "$_mf_origin"
  _mf_main="$_mf_root/main";  git clone -q "$_mf_origin" "$_mf_main" 2>/dev/null
  _mf_seat="$_mf_root/seat2"
  git -C "$_mf_main" checkout -q -B main
  git -C "$_mf_main" config user.email sim@herdkit.test; git -C "$_mf_main" config user.name sim
  printf 'base\n' > "$_mf_main/README.md"
  git -C "$_mf_main" add -A; git -C "$_mf_main" commit -q -m init; git -C "$_mf_main" push -q origin main
  git clone -q "$_mf_origin" "$_mf_seat" 2>/dev/null
  git -C "$_mf_seat" config user.email sim2@herdkit.test; git -C "$_mf_seat" config user.name sim2

  # Swap the watcher's $MAIN + remote coordinates onto the fixture (restored below).
  _mf_saved_main="$MAIN"; _mf_saved_remote="$HERD_REMOTE"; _mf_saved_branch="$HERD_BRANCH_NAME"
  MAIN="$_mf_main"; HERD_REMOTE=origin; HERD_BRANCH_NAME=main
  _mf_journal="$TREES/.herd/journal.jsonl"
  # grep -c prints 0 AND exits 1 when nothing matches — capture the count, never a second "0".
  _mf_ff_count() { local c; c="$(grep -c '"event":"main_ff"' "$_mf_journal" 2>/dev/null || true)"; printf '%s' "${c:-0}"; }
  _mf_ff_before="$(_mf_ff_count)"

  # (a) The OTHER seat merges straight to origin — this watcher's do_merge never runs.
  printf 'another seat merged this\n' > "$_mf_seat/README.md"
  git -C "$_mf_seat" commit -q -am "feat: out-of-band merge (other seat)"; git -C "$_mf_seat" push -q origin main
  reconcile_main_freshness
  _mf_head="$(git -C "$_mf_main" rev-parse HEAD 2>/dev/null || true)"
  _mf_want="$(git -C "$_mf_main" rev-parse origin/main 2>/dev/null || true)"
  _mf_ff_after="$(_mf_ff_count)"
  if [ -n "$_mf_head" ] && [ "$_mf_head" = "$_mf_want" ] && [ "$_mf_ff_after" -gt "$_mf_ff_before" ]; then
    checkpoint main_freshness_ff pass "out-of-band merge fast-forwarded \$MAIN on the tick and journaled main_ff"
  else
    checkpoint main_freshness_ff fail "expected ff to origin/main + a main_ff event (head=$_mf_head want=$_mf_want main_ff ${_mf_ff_before}→${_mf_ff_after})"
    _MF_OK=0
  fi

  # (b) NEVER GUESS: a local commit that is not one of our regenerable maps is held, not rebased.
  printf 'a human wrote this\n' > "$_mf_main/NOTES.md"
  git -C "$_mf_main" add NOTES.md; git -C "$_mf_main" commit -q -m "wip: hand edit on main"
  printf 'seat2 again\n' > "$_mf_seat/README.md"
  git -C "$_mf_seat" commit -q -am "feat: another out-of-band merge"; git -C "$_mf_seat" push -q origin main
  _mf_head_before="$(git -C "$_mf_main" rev-parse HEAD)"
  reconcile_main_freshness
  _mf_head_after="$(git -C "$_mf_main" rev-parse HEAD)"
  _mf_held="$(cat "$TREES/.agent-watch-main-freshness" 2>/dev/null || true)"
  if [ "$_mf_head_after" = "$_mf_head_before" ] && [ -n "$_mf_held" ]; then
    checkpoint main_freshness_no_guess pass "a diverged \$MAIN with a hand-written commit was HELD (row: $_mf_held), never rebased"
  else
    checkpoint main_freshness_no_guess fail "expected a HELD row and an untouched HEAD (head ${_mf_head_before}→${_mf_head_after}, row '${_mf_held:-<none>}')"
    _MF_OK=0
  fi

  rm -f "$TREES/.agent-watch-main-freshness" "$TREES/.agent-watch-main-restart" 2>/dev/null || true
  MAIN="$_mf_saved_main"; HERD_REMOTE="$_mf_saved_remote"; HERD_BRANCH_NAME="$_mf_saved_branch"
else
  checkpoint main_freshness_ff       fail "reconcile_main_freshness not defined (lib-mode source did not expose the tick reconcile)"
  checkpoint main_freshness_no_guess fail "reconcile_main_freshness not defined"
  _MF_OK=0
fi

# ── MERGE FAIRNESS: ready-PR priority + starvation surfacing (HERD-231) ─────────────────────────
# The happy-path drain above ran with MERGE_FAIRNESS unset (off), proving the knob is byte-inert: the
# candidate order was discovery order and every PR merged. Now drive the SHIPPED reorder
# (_merge_fairness_reorder) and the SHIPPED re-stale counter (_restale_note / restale_count) through
# the concurrency scenario's own shape — N>=3 PRs racing one base under merge pressure.
#
# The pressure is the incident, replayed: an expensive dispatch for one candidate takes minutes, and a
# merge lands during it. Every PR that had gate work invested in its sha loses that sha — a lap. A PR
# whose gates are ALREADY green has nothing left to spend and should simply MERGE, which is what the
# reorder buys: it is visited before the pass dispatches anything for anyone else.
#
#   ON  → the green PR merges first, so it is NEVER re-staled; the queue drains; no PR reaches the
#         starvation threshold; merge_fairness_priority is journaled.
#   OFF → (fault leg) the identical rounds starve the green PR: each round a sibling's dispatch invites
#         the merge that re-stales it before the pass ever reaches it. Past the threshold the watcher
#         journals pr_starvation and paints `starving · N re-stale laps`. This proves the ON leg above
#         is not vacuous — the invariant it asserts is one the engine can actually violate.
step fairness "drive $NPRS PRs under merge pressure through the SHIPPED reorder + re-stale counter (HERD-231)"

_FAIR_JOURNAL="$(_journal_file)"
_FAIR_ROUNDS=$(( _RESTALE_STARVE_THRESHOLD + 2 ))
_fair_prs=""; _fair_i=0
while [ "$_fair_i" -lt "$NPRS" ]; do _fair_prs="$_fair_prs $((9001 + _fair_i))"; _fair_i=$((_fair_i+1)); done

# Ledger fixtures — the reorder and the counter read NOTHING else: no gh, no git, no worktree.
_fair_green()   { printf 'CLEAN\t\n' > "$(_health_result_file "$1" "$2")"
                  printf '%s %s %s PASS reviewer\n' "$(date +%s)" "$1" "$2" >> "$REVIEW_STATE"; }
_fair_invest()  { printf '%s\n' "$$" > "$(_health_inflight_file "$1-$2")"; }   # a suite in flight
_fair_ungreen() { rm -f "$(_health_result_file "$1" "$2")" 2>/dev/null || true; }
# Every PR this leg invents is 9xxx, so one pattern clears all of them — including the 95xx
# replacements the sustained-pressure run mints. A row left behind would hand the next run a
# pre-greened PR and quietly vacate its assertions.
_fair_reset()   {
  rm -f "$TREES"/.health-result-9* "$TREES"/.health-inflight-9* 2>/dev/null || true
  : > "$RESTALE_STATE"
  grep -v " 9[0-9][0-9][0-9] " "$REVIEW_STATE" > "$REVIEW_STATE.tmp" 2>/dev/null || : > "$REVIEW_STATE.tmp"
  mv "$REVIEW_STATE.tmp" "$REVIEW_STATE"
  _FAIR_MARK="$(wc -l < "$_FAIR_JOURNAL" 2>/dev/null | tr -d ' ')"; _FAIR_MARK="${_FAIR_MARK:-0}"
}

# The three helpers below read the caller's `live` / `sha` / `green` arrays through bash's dynamic
# scoping — they are round-loop internals, not general utilities.
# Events journaled since the last _fair_reset — this leg's own signal, never the drain's.
_fair_events() { tail -n +$(( ${_FAIR_MARK:-0} + 1 )) "$_FAIR_JOURNAL" 2>/dev/null | grep -c "\"event\":\"$1\"" || true; }

# _fair_assemble — build this round's candidate arrays in DISCOVERY order (ascending PR), exactly as
# the watcher's classify pass does, from the live set. Empty slots are reaped PRs.
_fair_assemble() {
  local j
  CAND_IDX=(); CAND_DIR=(); CAND_SLUG=(); CAND_PR=(); CAND_BRANCH=(); CAND_SHA=()
  for ((j=0; j<${#live[@]}; j++)); do
    [ -n "${live[j]}" ] || continue
    CAND_IDX+=("$j"); CAND_DIR+=("$REPO"); CAND_SLUG+=("fair-${live[j]}")
    CAND_PR+=("${live[j]}"); CAND_BRANCH+=("feat/fair-${live[j]}"); CAND_SHA+=("${sha[j]}")
  done
}

# _fair_slot_of <pr#> — the live-array index holding this PR.
_fair_slot_of() { local j=0; while [ "${live[j]:-}" != "$1" ]; do j=$((j+1)); done; printf '%s' "$j"; }

# _fair_merge_pressure <dispatching-slot> <round> — the incident, in one call. Our expensive dispatch
# for the head candidate takes minutes; during it ANOTHER merge lands on the base. Every sibling
# holding an invested sha loses it: one lap, one bounce, a fresh sha, gates re-run from scratch.
_fair_merge_pressure() {
  local dj="$1" rnd="$2" k
  for ((k=0; k<${#live[@]}; k++)); do
    [ -n "${live[k]:-}" ] || continue
    [ "$k" = "$dj" ] && continue
    _gate_work_invested "${live[k]}" "${sha[k]}" || continue
    [ "${green[k]}" = "1" ] && _FAIR_GREEN_RESTALED=$(( _FAIR_GREEN_RESTALED + 1 ))
    _restale_note "${live[k]}" "${sha[k]}" "fair-${live[k]}" stale-base   # ← the SHIPPED counter
    _fair_ungreen "${live[k]}" "${sha[k]}"
    green[k]=0; sha[k]="sha-${live[k]}-${rnd}"
    _fair_invest "${live[k]}" "${sha[k]}"
  done
}

# ── LEG 1 (ON): the queue drains under pressure, and no gates-green PR is ever re-staled ────────
# The LAST PR in discovery order arrives gates-green — PR #328's exact position: green, at the back,
# behind siblings whose dispatches invite the merge that re-stales it.
fair_drain_run() {
  local mode="$1" round=0 merged=0 j alive
  local -a live=() sha=() green=()
  _FAIR_GREEN_RESTALED=0
  _fair_reset
  j=0; for p in $_fair_prs; do live[j]="$p"; sha[j]="sha-${p}-0"; green[j]=0; j=$((j+1)); done
  local last=$((j-1))
  green[last]=1; _fair_green "${live[last]}" "${sha[last]}"
  for ((j=0; j<last; j++)); do _fair_invest "${live[j]}" "${sha[j]}"; done

  while [ "$round" -lt "$(( NPRS * 2 + _RESTALE_STARVE_THRESHOLD ))" ]; do
    round=$((round+1))
    _fair_assemble
    [ "${#CAND_PR[@]}" -gt 0 ] || break
    MERGE_FAIRNESS="$mode" _merge_fairness_reorder            # ← the SHIPPED reorder
    j="$(_fair_slot_of "${CAND_PR[0]}")"
    if _cand_gates_ready "${CAND_PR[0]}" "${sha[j]}"; then
      merged=$((merged+1)); live[j]=""; green[j]=0            # merge + reap
    else
      _fair_invest "${CAND_PR[0]}" "${sha[j]}"
      _fair_merge_pressure "$j" "$round"
      green[j]=1; _fair_green "${CAND_PR[0]}" "${sha[j]}"     # our suite finished on the fresh base
    fi
    alive=0; for ((j=0; j<${#live[@]}; j++)); do [ -n "${live[j]:-}" ] && alive=$((alive+1)); done
    [ "$alive" -eq 0 ] && break
  done
  printf '%s' "$merged"
}

_F_MERGED="$(fair_drain_run on)"
_F_GREENRESTALED="${_FAIR_GREEN_RESTALED:-0}"
_F_PRIO="$(_fair_events merge_fairness_priority)"
_F_STARVE="$(_fair_events pr_starvation)"
_F_MAXLAPS=0
for p in $_fair_prs; do _n="$(restale_count "$p")"; [ "$_n" -gt "$_F_MAXLAPS" ] && _F_MAXLAPS="$_n"; done

if [ "${_F_GREENRESTALED:-1}" -eq 0 ]; then
  checkpoint fairness_green_pr_never_restaled pass "MERGE_FAIRNESS=on: a gates-green PR was never re-staled — it merged before any sibling dispatch"
else
  checkpoint fairness_green_pr_never_restaled fail "a gates-green PR lost $_F_GREENRESTALED lap(s) despite the reorder"
fi
if [ "${_F_MERGED:-0}" -eq "$NPRS" ]; then
  checkpoint fairness_queue_drained pass "all $NPRS PRs merged under sustained merge pressure"
else
  checkpoint fairness_queue_drained fail "only ${_F_MERGED:-0}/$NPRS PRs merged before the round budget ran out"
fi
if [ "${_F_MAXLAPS:-99}" -le "$_RESTALE_STARVE_THRESHOLD" ] && [ "${_F_STARVE:-1}" -eq 0 ]; then
  checkpoint fairness_no_starvation pass "max re-stale laps=${_F_MAXLAPS} <= threshold=$_RESTALE_STARVE_THRESHOLD; no pr_starvation journaled"
else
  checkpoint fairness_no_starvation fail "starvation under the knob (max laps=${_F_MAXLAPS}, threshold=$_RESTALE_STARVE_THRESHOLD, pr_starvation=${_F_STARVE})"
fi
if [ "${_F_PRIO:-0}" -ge 1 ]; then
  checkpoint fairness_priority_journaled pass "$_F_PRIO merge_fairness_priority event(s) — the reorder actually fired (non-vacuous)"
else
  checkpoint fairness_priority_journaled fail "the reorder never changed an order — the ON leg proved nothing"
fi

# ── LEG 2 (fault): SUSTAINED pressure — a control room that keeps merging ───────────────────────
# Real merge pressure does not stop when three PRs drain: the coordinator keeps landing work. Here a
# merged PR is immediately replaced by a fresh sibling, so the base never stops moving. TARGET is the
# gates-green PR sitting at the back of discovery order.
#
#   OFF → the pass reaches a sibling first, dispatches, and the merge that lands during that dispatch
#         re-stales TARGET. Every round. It starves, and the engine must SAY so.
#   ON  → TARGET is promoted, merges on round 1, and never loses a lap.
fair_pressure_run() {
  local mode="$1" round=0 j fresh=9500
  local -a live=() sha=() green=()
  _FAIR_GREEN_RESTALED=0; _FAIR_TARGET_MERGED=0
  _fair_reset
  j=0; for p in $_fair_prs; do live[j]="$p"; sha[j]="sha-${p}-0"; green[j]=0; j=$((j+1)); done
  local last=$((j-1)); _FAIR_TARGET="${live[last]}"
  green[last]=1; _fair_green "${live[last]}" "${sha[last]}"
  for ((j=0; j<last; j++)); do _fair_invest "${live[j]}" "${sha[j]}"; done

  while [ "$round" -lt "$_FAIR_ROUNDS" ]; do
    round=$((round+1))
    _fair_assemble
    MERGE_FAIRNESS="$mode" _merge_fairness_reorder            # ← the SHIPPED reorder
    j="$(_fair_slot_of "${CAND_PR[0]}")"
    if _cand_gates_ready "${CAND_PR[0]}" "${sha[j]}"; then
      [ "${CAND_PR[0]}" = "$_FAIR_TARGET" ] && _FAIR_TARGET_MERGED=1
      # A merged PR is replaced by a fresh sibling: the pressure never lets up.
      fresh=$((fresh+1)); live[j]="$fresh"; sha[j]="sha-${fresh}-0"; green[j]=0
      _fair_invest "${live[j]}" "${sha[j]}"
      [ "$_FAIR_TARGET_MERGED" = "1" ] && break
    else
      _fair_invest "${CAND_PR[0]}" "${sha[j]}"
      _fair_merge_pressure "$j" "$round"
      # TARGET's builder rebases fast and its gates go green again — only to be passed over again.
      local tj; tj="$(_fair_slot_of "$_FAIR_TARGET")"
      green[tj]=1; _fair_green "$_FAIR_TARGET" "${sha[tj]}"
    fi
  done
}

fair_pressure_run off
_FO_TARGET="$_FAIR_TARGET"
_FO_GREENRESTALED="${_FAIR_GREEN_RESTALED:-0}"
_FO_MAXLAPS="$(restale_count "$_FO_TARGET")"
_FO_STARVE="$(_fair_events pr_starvation)"
_FO_PRIO="$(_fair_events merge_fairness_priority)"
_FO_ROW="$(_starvation_row "$_FO_TARGET")"

if [ "${_FO_PRIO:-1}" -eq 0 ]; then
  checkpoint fairness_off_byte_quiet pass "MERGE_FAIRNESS=off: the reorder never fired, never journaled — candidate order byte-identical"
else
  checkpoint fairness_off_byte_quiet fail "the knob is off but merge_fairness_priority fired ${_FO_PRIO}×"
fi
if [ "${_FAIR_TARGET_MERGED:-1}" -eq 0 ] && [ "${_FO_GREENRESTALED:-0}" -ge 1 ] && [ "${_FO_MAXLAPS:-0}" -gt "$_RESTALE_STARVE_THRESHOLD" ]; then
  checkpoint fairness_off_reproduces_starvation pass "knob off: gates-green PR #$_FO_TARGET never merged, re-staled ${_FO_GREENRESTALED}× (laps=${_FO_MAXLAPS} > $_RESTALE_STARVE_THRESHOLD) — the ON leg is non-vacuous"
else
  checkpoint fairness_off_reproduces_starvation fail "the fault leg did not reproduce starvation (target merged=${_FAIR_TARGET_MERGED}, green re-staled=${_FO_GREENRESTALED}, laps=${_FO_MAXLAPS})"
fi
if [ "${_FO_STARVE:-0}" -ge 1 ] && printf '%s' "$_FO_ROW" | grep -q "starving · .* re-stale laps"; then
  checkpoint starvation_surfaced pass "pr_starvation journaled + the loud row rendered: $(printf '%s' "$_FO_ROW" | sed 's/\x1b\[[0-9;]*m//g' | tr -s ' ')"
else
  checkpoint starvation_surfaced fail "starvation was not surfaced (pr_starvation=${_FO_STARVE}, row='${_FO_ROW:-<none>}')"
fi

# Same sustained pressure, knob ON: TARGET is promoted and merges instead of starving.
fair_pressure_run on
_FP_TARGET_MERGED="${_FAIR_TARGET_MERGED:-0}"
_FP_LAPS="$(restale_count "$_FAIR_TARGET")"
if [ "$_FP_TARGET_MERGED" -eq 1 ] && [ "$_FP_LAPS" -eq 0 ]; then
  checkpoint fairness_on_rescues_starved_pr pass "same pressure, MERGE_FAIRNESS=on: the gates-green PR merged with 0 re-stale laps"
else
  checkpoint fairness_on_rescues_starved_pr fail "the reorder did not rescue the starved PR (merged=$_FP_TARGET_MERGED, laps=$_FP_LAPS)"
fi

# Leave no fairness fixtures behind for the scorecard/tail steps.
rm -f "$TREES"/.health-result-9* "$TREES"/.health-inflight-9* 2>/dev/null || true



# ── SCORECARD emitter (machine-readable JSON; mirrors sandbox-scenario.sh + concurrency fields) ──
write_scorecard() {
  local out="$ART/scorecard.json" result="$1"
  local skipped=0 i n; n=${#CP_NAMES[@]}
  for ((i=0; i<n; i++)); do [ "${CP_STATUS[$i]}" = "skip" ] && skipped=$((skipped+1)); done
  {
    printf '{\n'
    printf '  "scenario": "%s",\n' "$SCENARIO"
    # POSTURE is empty on the default (no --posture) run → this line is omitted, keeping the scorecard
    # BYTE-IDENTICAL to today's. --posture solo-auto runs this SAME drain and only adds the tag.
    [ -n "$POSTURE" ] && printf '  "posture": "%s",\n' "$POSTURE"
    printf '  "artifacts_dir": "%s",\n' "$ART"
    printf '  "repo_dir": "%s",\n' "$REPO"
    printf '  "fixture_sha": "%s",\n' "$FIXTURE_SHA"
    printf '  "result": "%s",\n' "$result"
    printf '  "passed": %d,\n' "$_pass"
    printf '  "failed": %d,\n' "$_fail"
    printf '  "skipped": %d,\n' "$skipped"
    printf '  "prs": %d,\n' "$NPRS"
    printf '  "review_concurrency": %d,\n' "$REVIEW_CONCURRENCY"
    printf '  "health_concurrency": %d,\n' "$HEALTH_CONCURRENCY"
    printf '  "peak_reviews_in_flight": %d,\n' "$PEAK_REVIEWS"
    printf '  "reviews_queued": %d,\n' "$_q_count"
    printf '  "health_runs": %d,\n' "$HEALTH_RUNS"
    printf '  "max_health_in_flight": %s,\n' "${MAX_HEALTH_INFLIGHT:-0}"
    printf '  "merges": %d,\n' "$_merge_total"
    printf '  "double_merges": %d,\n' "$_dupes"
    printf '  "skipped_prs": %d,\n' "$_skipped"
    printf '  "queue_drained": %s,\n' "$([ "$_merged_ct" -eq "$NPRS" ] && echo true || echo false)"
    printf '  "ticks": %d,\n' "$TICKS"
    printf '  "flair_tested": true,\n'
    printf '  "watcher_singleton_tested": true,\n'
    printf '  "watcher_singleton_ok": %s,\n' "$([ "${_SNGL_OK:-0}" -eq 1 ] && echo true || echo false)"
    printf '  "main_freshness_tested": true,\n'
    printf '  "main_freshness_ok": %s,\n' "$([ "${_MF_OK:-0}" -eq 1 ] && echo true || echo false)"
    printf '  "infra_breaker_tested": true,\n'
    printf '  "infra_breaker_max": %d,\n' "$BRK_MAX"
    printf '  "infra_breaker_opened": %s,\n' "$([ -n "${_brk_opened:-}" ] && echo true || echo false)"
    printf '  "merge_fairness_tested": true,\n'
    printf '  "restale_threshold": %d,\n' "$_RESTALE_STARVE_THRESHOLD"
    printf '  "fairness_on_max_restale_laps": %d,\n' "${_F_MAXLAPS:-0}"
    printf '  "fairness_on_green_restaled": %d,\n' "${_F_GREENRESTALED:-0}"
    printf '  "fairness_off_max_restale_laps": %d,\n' "${_FO_MAXLAPS:-0}"
    printf '  "fairness_off_starved": %s,\n' "$([ "${_FO_STARVE:-0}" -ge 1 ] && echo true || echo false)"
    printf '  "pane_captures": %d,\n' "$PANE_CAPTURES"
    printf '  "screenshots": %d,\n' "$SHOTS_TAKEN"
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

RESULT="pass"; [ "$_fail" -gt 0 ] && RESULT="fail"
SCARD="$(write_scorecard "$RESULT")"
printf '\n%s══ scorecard ══%s\n' "$c_bold" "$c_rst"
printf '  scenario:      %s\n' "$SCENARIO"
printf '  result:        %s\n' "$RESULT"
printf '  passed/failed: %d / %d\n' "$_pass" "$_fail"
printf '  peak reviews:  %d (cap %d)\n' "$PEAK_REVIEWS" "$REVIEW_CONCURRENCY"
printf '  health runs:   %d (max concurrent %s)\n' "$HEALTH_RUNS" "${MAX_HEALTH_INFLIGHT:-0}"
printf '  merges:        %d (dupes %d)\n' "$_merge_total" "$_dupes"
printf '  ticks:         %d\n' "$TICKS"
printf '  scorecard:     %s\n' "$SCARD"
printf '  artifacts:     %s\n' "$ART"

[ "$RESULT" = "pass" ] && exit 0 || exit 1
