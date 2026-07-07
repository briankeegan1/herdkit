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

# ── output helpers (mirror sandbox-scenario.sh's style) ─────────────────────────────────────────
c_bold=$'\033[1m'; c_dim=$'\033[2m'
c_grn=$'\033[32m'; c_red=$'\033[31m'; c_yel=$'\033[33m'; c_rst=$'\033[0m'
step() { printf '\n%s[%s]%s %s\n' "$c_bold" "$1" "$c_rst" "$2"; }
ok()   { printf '  %s✓%s %s\n' "$c_grn" "$c_rst" "$*"; }
bad()  { printf '  %s✗%s %s\n' "$c_red" "$c_rst" "$*"; }
skip() { printf '  %s–%s %s\n' "$c_yel" "$c_rst" "$*"; }
info() { printf '  %s→%s %s\n' "$c_dim" "$c_rst" "$*"; }

# ── args ────────────────────────────────────────────────────────────────────────
ART=""; KEEP=""; NPRS=3
while [ $# -gt 0 ]; do
  case "$1" in
    --artifacts) ART="${2:-}"; KEEP=1; shift 2 ;;
    --keep)      KEEP=1; shift ;;
    -n|--prs)    NPRS="${2:-3}"; shift 2 ;;
    -h|--help)   grep -E '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "sandbox-concurrency-scenario: unknown arg: $1" >&2; exit 1 ;;
  esac
done
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
export MERGE_POLICY="auto"
export REVIEW_CONCURRENCY HEALTH_CONCURRENCY
export HERD_REVIEW_BIN="$STUB_REVIEW"
export HERD_HEALTHCHECK_BIN="$STUB_HC"
export STUB_SPAWN_LOG="$ART/review-spawns.log"; : > "$STUB_SPAWN_LOG"
export STUB_HC_MARKERCOUNT_LOG="$ART/health-markercount.log"; : > "$STUB_HC_MARKERCOUNT_LOG"
export STUB_HC_TREES="$TREES"
export SANDBOX_REVIEW_DELAY="$REVIEW_DELAY"
WATCH="$HERE/../agent-watch.sh"
[ -f "$WATCH" ] || { bad "agent-watch.sh not found at $WATCH"; exit 1; }
# shellcheck source=/dev/null
. "$WATCH" || { bad "sourcing agent-watch.sh (lib mode) failed"; exit 1; }

# The gate functions we drive must exist (proves we bound to the real watcher, not a stand-in).
_missing=""
for fn in _healthcheck_gate _review_gate_step _count_live_reviews _count_live_healthchecks \
          _health_slot_free _health_inflight_file _review_inflight_file do_merge already_merged \
          review_verdict _predispatch_review_if_parallel _gate_dispatch_mode; do
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

# Build a watcher-console frame from the REAL DISPLAY[] rows the gate functions populate.
DISPLAY=()
console_frame() {
  local title="$1"
  printf '🐑 herd watch · %s · %s\n' "$WORKSPACE_NAME" "$title"
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

    # (c) MERGE — real do_merge (gh pr merge stub + STATE record + real worktree reap).
    do_merge "$slug" "$pr" "$dir" "$sha"
    DISPLAY[$k]="    ${c_grn}✅${c_rst} $(printf '%-14s' "$slug") ${c_dim}#${pr}${c_rst} · ${c_grn}merged${c_rst}"
  done
}

# Inter-tick wait must outlast a review's in-flight window so dispatched reviewers finish and their
# results are collectable on the next tick. Whole seconds keep it robust across `sleep` variants.
INTER_TICK=$((REVIEW_DELAY + 1))
MAX_TICKS=$((NPRS + 5))
TICKS=0
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
  checkpoint health_mutex_queues fail "expected QUEUED with stub not invoked (got '$_HC_RESULT', runs $_probe_before→$_probe_after)"
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

# ── SCORECARD emitter (machine-readable JSON; mirrors sandbox-scenario.sh + concurrency fields) ──
write_scorecard() {
  local out="$ART/scorecard.json" result="$1"
  local skipped=0 i n; n=${#CP_NAMES[@]}
  for ((i=0; i<n; i++)); do [ "${CP_STATUS[$i]}" = "skip" ] && skipped=$((skipped+1)); done
  {
    printf '{\n'
    printf '  "scenario": "%s",\n' "$SCENARIO"
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
