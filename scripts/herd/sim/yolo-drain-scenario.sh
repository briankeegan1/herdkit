#!/usr/bin/env bash
# scripts/herd/sim/yolo-drain-scenario.sh — the COORDINATOR DRAIN-MODE scenario (HERD-466).
#
# Proves the claim the `yolo` posture + the coordinator skill's DRAIN MODE section make together:
#
#     under the yolo posture a backlog drains to ZERO with ZERO coordinator prompts,
#     and the ONLY things that stop the loop are the three declared stop conditions.
#
# It runs the drain-mode loop from templates/coordinator.md.tmpl (§ Drain mode) against a real local
# git fixture, one cycle at a time, and for every point in the pipeline where SOMEBODY has to decide
# it asks the EFFECTIVE config who owns that decision. An owner of `engine` is a rail doing its job;
# an owner of `coordinator` is a PAUSE — a prompt — and every one of them is counted and named in the
# scorecard. That is the whole measurement: prompts are not modelled as an opinion about the loop,
# they are derived from the very levers the posture flips.
#
# WHAT IS REAL HERE (this is a sim, not a mock):
#   • real git — a sandbox_fixture_build repo, real worktrees, real branches, a real merge conflict
#     for the DIRTY-PR leg, and a real conflict resolution.
#   • the real gate — each builder's change is gated by the fixture's own app/greet.test.sh.
#   • the real posture table — the bundle comes from templates/postures.tsv via posture-lib.sh, so a
#     lever added to (or dropped from) the posture changes this sim's answer immediately.
#   • the real budget rail — spend is journaled as `cost` events and the ceiling is enforced through
#     cost.sh's own `budget_daily_exceeded`, the SAME predicate the watcher drain and both builder
#     lanes consult. The ceiling is ENFORCED (the loop stops spawning), never merely measured.
# WHAT IS STUBBED: the builders (deterministic tiny commits, no model call) and the review verdicts
# (injected per item). No herdr, no network, no model, no GitHub.
#
# THE LOOP (steps numbered as in the skill's § Drain mode):
#   1. drain + route + ack builder notes
#   2. collision-map every pending item's file surface against the in-flight worktrees
#   3. spawn to capacity on disjoint surfaces, BUNDLING same-surface items into one builder
#   4. dispatch the resolver for any DIRTY PR whose builder is done
#   5. let the gates merge (never self-merge)
#   6. reconcile — mark the item shipped
#   7. repeat
#
# STOP CONDITIONS (exactly three, asserted):
#   backlog-empty    — nothing pending; a completion DIGEST is emitted (artifacts/digest.txt)
#   budget-ceiling   — budget_daily_exceeded() true at a pre-spawn gate; the loop stops SPAWNING
#   escalation       — the resolver punts a conflict (--escalate-at), or an unowned red
#
# Usage:
#   bash scripts/herd/sim/yolo-drain-scenario.sh [--artifacts DIR] [--keep] [--posture NAME]
#        [-n N] [--capacity K] [--budget USD] [--cost-per-item USD] [--escalate-at TOK]
#        [--dirty-item TOK] [--no-bundle]
#     --posture NAME     posture to drain under (default: yolo). Any templates/postures.tsv row.
#     -n N               backlog size (default 3 — the tracker item's "3 stub items").
#     --capacity K       builders spawned per cycle (default 2).
#     --budget USD       BUDGET_DAILY ceiling for this run (default: unset ⇒ dormant, no ceiling).
#     --cost-per-item    USD journaled per drained item (default 1).
#     --escalate-at TOK  the resolver PUNTS on item TOK instead of resolving ⇒ escalation stop.
#     --dirty-item TOK   the item whose PR is made genuinely DIRTY by an out-of-band merge to its
#                        file surface on the default branch (default: 02; empty disables the leg).
#     --no-bundle        do NOT bundle same-surface items (one builder per item) — the control arm
#                        that shows what the collision map buys.
#
# Exit: 0 = the run matched its expected stop condition with no failed checkpoint · 1 = otherwise.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
# shellcheck source=scripts/herd/sim/sandbox-fixture.sh
. "$HERE/sandbox-fixture.sh"
# shellcheck source=scripts/herd/sim/posture-lib.sh
. "$HERE/posture-lib.sh"

c_bold=$'\033[1m'; c_dim=$'\033[2m'
c_grn=$'\033[32m'; c_red=$'\033[31m'; c_yel=$'\033[33m'; c_rst=$'\033[0m'
step() { printf '\n%s[%s]%s %s\n' "$c_bold" "$1" "$c_rst" "$2"; }
ok()   { printf '  %s✓%s %s\n' "$c_grn" "$c_rst" "$*"; }
bad()  { printf '  %s✗%s %s\n' "$c_red" "$c_rst" "$*"; }
skip() { printf '  %s–%s %s\n' "$c_yel" "$c_rst" "$*"; }
info() { printf '  %s→%s %s\n' "$c_dim" "$c_rst" "$*"; }

# ── args ────────────────────────────────────────────────────────────────────────────────────────
ART=""; KEEP=""; POSTURE="yolo"; N=3; CAPACITY=2; BUDGET=""; COST_PER_ITEM=1
ESCALATE_AT=""; DIRTY_ITEM="02"; BUNDLE=1
while [ $# -gt 0 ]; do
  case "$1" in
    --artifacts|--state) [ $# -ge 2 ] || { echo "yolo-drain: $1 requires a value" >&2; exit 1; }; ART="$2"; KEEP=1; shift 2 ;;
    --keep)          KEEP=1; shift ;;
    --posture)       [ $# -ge 2 ] || { echo "yolo-drain: --posture requires a value" >&2; exit 1; }; POSTURE="$2"; shift 2 ;;
    -n|--items)      [ $# -ge 2 ] || { echo "yolo-drain: --items requires a value" >&2; exit 1; }; N="$2"; shift 2 ;;
    --capacity)      [ $# -ge 2 ] || { echo "yolo-drain: --capacity requires a value" >&2; exit 1; }; CAPACITY="$2"; shift 2 ;;
    --budget)        [ $# -ge 2 ] || { echo "yolo-drain: --budget requires a value" >&2; exit 1; }; BUDGET="$2"; shift 2 ;;
    --cost-per-item) [ $# -ge 2 ] || { echo "yolo-drain: --cost-per-item requires a value" >&2; exit 1; }; COST_PER_ITEM="$2"; shift 2 ;;
    --escalate-at)   [ $# -ge 2 ] || { echo "yolo-drain: --escalate-at requires a value" >&2; exit 1; }; ESCALATE_AT="$2"; shift 2 ;;
    --dirty-item)    [ $# -ge 2 ] || { echo "yolo-drain: --dirty-item requires a value" >&2; exit 1; }; DIRTY_ITEM="$2"; shift 2 ;;
    --no-bundle)     BUNDLE=0; shift ;;
    -h|--help)       grep -E '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "yolo-drain: unknown arg: $1" >&2; exit 1 ;;
  esac
done
case "$N" in ''|*[!0-9]*) echo "yolo-drain: --items must be a positive integer" >&2; exit 1 ;; esac
[ "$N" -ge 1 ] || { echo "yolo-drain: --items must be >= 1" >&2; exit 1; }
case "$CAPACITY" in ''|*[!0-9]*) echo "yolo-drain: --capacity must be a positive integer" >&2; exit 1 ;; esac
[ "$CAPACITY" -ge 1 ] || { echo "yolo-drain: --capacity must be >= 1" >&2; exit 1; }
posture_exists "$POSTURE" || { echo "yolo-drain: unknown posture: $POSTURE" >&2; exit 1; }

[ -n "$ART" ] || ART="$(mktemp -d)"
mkdir -p "$ART"
[ -n "$KEEP" ] || trap 'rm -rf "$ART"' EXIT

REPO="$ART/repo"
PRDIR="$ART/pr"; mkdir -p "$PRDIR"

# ── the effective config: the posture's OWN bundle, nothing hand-set ────────────────────────────
# posture_apply exports every real KEY=VALUE from templates/postures.tsv. Everything the posture does
# NOT set falls back to the engine default below, so an UNSET lever answers exactly as a real project
# with that lever unset would. This is why adding a lever to the posture row moves this sim.
posture_apply "$POSTURE"
: "${MERGE_POLICY:=auto}"
: "${HUMAN_VERIFY_POLICY:=hold}"
: "${REVIEW_AUTOFIX:=false}"
: "${HEALTHCHECK_AUTOFIX:=false}"
: "${STALE_BASE_AUTOFIX:=off}"
: "${DRAFT_AUTO_PROMOTE:=off}"
: "${DEAD_BUILDER_AUTORESPAWN:=off}"
: "${COORDINATOR_AUTONOMY:=human}"
[ -n "$BUDGET" ] && export BUDGET_DAILY="$BUDGET"
: "${BUDGET_DAILY:=}"
export BUDGET_DAILY

# ── the real budget rail: journal + cost.sh, pinned to this run's throwaway journal ─────────────
export JOURNAL_FILE="$ART/journal.jsonl"
export HERD_JOURNAL_PIN_PID="$$"
# shellcheck source=scripts/herd/journal.sh
. "$ROOT/scripts/herd/journal.sh"
# shellcheck source=scripts/herd/cost.sh
. "$ROOT/scripts/herd/cost.sh"

# ── checkpoints (bash 3.2: parallel indexed arrays, no assoc arrays) ────────────────────────────
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

# ── DECISION OWNERSHIP — the prompt model ───────────────────────────────────────────────────────
# _owner <situation> — who owns this decision under the EFFECTIVE config: `engine` (a rail handles
# it, the drain keeps going) or `coordinator` (the loop must stop and ask/act — a PROMPT). Every
# answer reads a real .herd/config lever with its real documented default. Nothing else decides.
_lc() { printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]'; }
_owner() {
  case "$1" in
    block_review)  [ "$(_lc "$REVIEW_AUTOFIX")" = true ]           && echo engine || echo coordinator ;;
    red_health)    [ "$(_lc "$HEALTHCHECK_AUTOFIX")" = true ]      && echo engine || echo coordinator ;;
    stale_base)    [ "$(_lc "$STALE_BASE_AUTOFIX")" = on ]         && echo engine || echo coordinator ;;
    draft_pr)      [ "$(_lc "$DRAFT_AUTO_PROMOTE")" = on ]         && echo engine || echo coordinator ;;
    dead_builder)  [ "$(_lc "$DEAD_BUILDER_AUTORESPAWN")" = on ]   && echo engine || echo coordinator ;;
    spawn)         [ "$(_lc "$COORDINATOR_AUTONOMY")" = full ]     && echo engine || echo coordinator ;;
    human_verify)  case "$(_lc "$HUMAN_VERIFY_POLICY")" in auto) echo engine ;; *) echo coordinator ;; esac ;;
    merge)         case "$(_lc "$MERGE_POLICY")" in ''|auto) echo engine ;; *) echo coordinator ;; esac ;;
    *)             echo coordinator ;;
  esac
}
PROMPTS=0; PROMPT_REASONS=""
# _decide <situation> <context> — resolve the owner and, when it is the coordinator, count a PROMPT.
# The work still gets done either way: a prompt is a PAUSE, not a stop. That is exactly the axis
# drain mode moves — under `yolo` every situation below is owned by a rail and the loop never waits;
# under a weaker posture the identical work happens with N human/coordinator pauses in the middle.
# Always returns 0; only the three declared stop conditions ever end the loop.
_decide() {
  local sit="$1" ctx="${2:-}" who
  who="$(_owner "$sit")"
  if [ "$who" = engine ]; then
    info "$sit ($ctx) → engine rail"
    return 0
  fi
  PROMPTS=$((PROMPTS+1))
  PROMPT_REASONS="${PROMPT_REASONS:+$PROMPT_REASONS, }$sit:$ctx"
  printf '  %s⏸%s coordinator PROMPT — %s (%s)\n' "$c_yel" "$c_rst" "$sit" "$ctx"
  return 0
}

# ── backlog helpers (the durable work queue — read from disk, never memory) ─────────────────────
_seed_backlog() {
  local n="$1" out="$2" i tok
  {
    printf '# Drain-mode BACKLOG\n\n'
    printf 'Seeded %d-item backlog for the coordinator DRAIN MODE scenario (HERD-466).\n' "$n"
    printf 'Deterministic — do not hand-edit. The drain flips 🔜 → ✅ exactly as the scribe would.\n\n'
    for ((i=1; i<=n; i++)); do
      tok="$(printf '%02d' "$i")"
      printf -- '- 🔜 **Item %s: drain item %s** — deterministic drain-mode work item %s.\n' "$tok" "$tok" "$tok"
    done
  } > "$out"
}
_pending_tokens() { awk -F'Item ' '/^- 🔜 \*\*Item [0-9]+:/ { n=$2; sub(/[^0-9].*/,"",n); print n }' "$REPO/BACKLOG.md"; }
_count_pending() { local c; c="$(grep -cE '^- 🔜 \*\*Item [0-9]+:' "$REPO/BACKLOG.md" 2>/dev/null)"; echo "${c:-0}"; }
_count_shipped() { local c; c="$(grep -cE '^- ✅ \*\*Item [0-9]+:' "$REPO/BACKLOG.md" 2>/dev/null)"; echo "${c:-0}"; }
_mark_shipped() {
  local tok="$1"
  awk -v tok="$tok" '
    index($0, "**Item " tok ":") && index($0, "🔜") { gsub(/🔜/, "✅"); print; next }
    { print }
  ' "$REPO/BACKLOG.md" > "$REPO/BACKLOG.md.tmp" && mv "$REPO/BACKLOG.md.tmp" "$REPO/BACKLOG.md"
}

# ── the collision map (step 2) ──────────────────────────────────────────────────────────────────
# _surface <tok> — the file surface item <tok> touches. Item 01 owns its own file; every later item
# lands in the SHARED registry, so the map has a real collision to find rather than a synthetic flag.
_surface() {
  case "$1" in
    01) printf 'app/item-01.sh' ;;
    *)  printf 'app/registry.sh' ;;
  esac
}

# ── engine-event injection: which situations each item raises, deterministically by token ───────
# Cycles with period 3 so any -n N exercises every situation. These are the events a real drain hits.
_events_for() {
  local tok="$1" mod=$(( (10#$tok - 1) % 3 ))
  case "$mod" in
    0) printf 'block_review draft_pr' ;;
    1) printf 'red_health human_verify' ;;
    2) printf 'dead_builder' ;;
  esac
}

# ── counters ────────────────────────────────────────────────────────────────────────────────────
CYCLES=0; BUNDLES=0; BUILDERS=0; NOTES_ROUTED=0; RESOLVER_DISPATCHES=0; ESCALATIONS=0
GATE_FAILURES=0; DRAINED=0; SPEND_ITEMS=0; STOP_REASON=""; DIGEST_EMITTED=false
SECONDS=0

# ── scorecard ───────────────────────────────────────────────────────────────────────────────────
write_scorecard() {
  local out="$ART/scorecard.json" result="$1"
  local skipped=0 i n r
  n=${#CP_NAMES[@]}
  for ((i=0; i<n; i++)); do [ "${CP_STATUS[$i]}" = "skip" ] && skipped=$((skipped+1)); done
  {
    printf '{\n'
    printf '  "scenario": "yolo-drain",\n'
    printf '  "posture": "%s",\n' "$POSTURE"
    printf '  "artifacts_dir": "%s",\n' "$ART"
    printf '  "repo_dir": "%s",\n' "$REPO"
    printf '  "items_total": %d,\n' "$N"
    printf '  "items_drained": %d,\n' "$DRAINED"
    printf '  "items_remaining": %d,\n' "$REMAINING"
    printf '  "cycles": %d,\n' "$CYCLES"
    printf '  "builders_spawned": %d,\n' "$BUILDERS"
    printf '  "bundles": %d,\n' "$BUNDLES"
    printf '  "notes_routed": %d,\n' "$NOTES_ROUTED"
    printf '  "resolver_dispatches": %d,\n' "$RESOLVER_DISPATCHES"
    printf '  "escalations": %d,\n' "$ESCALATIONS"
    printf '  "gate_failures": %d,\n' "$GATE_FAILURES"
    printf '  "coordinator_prompts": %d,\n' "$PROMPTS"
    r="$(printf '%s' "$PROMPT_REASONS" | tr -d '"\\' | tr '\n' ' ')"
    printf '  "prompt_reasons": "%s",\n' "$r"
    printf '  "budget_daily": "%s",\n' "$BUDGET_DAILY"
    printf '  "spend": "%s",\n' "$(cost_day_total)"
    printf '  "stop_reason": "%s",\n' "$STOP_REASON"
    printf '  "digest_emitted": %s,\n' "$DIGEST_EMITTED"
    printf '  "wall_clock_s": %d,\n' "$SECONDS"
    printf '  "result": "%s",\n' "$result"
    printf '  "passed": %d,\n' "$_pass"
    printf '  "failed": %d,\n' "$_fail"
    printf '  "skipped": %d,\n' "$skipped"
    printf '  "checkpoints": [\n'
    n=${#CP_NAMES[@]}
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

# ═══════════════════════════════════════════════════════════════════════════════════════════════
printf '%s══ coordinator DRAIN MODE — posture=%s ══%s\n' "$c_bold" "$POSTURE" "$c_rst"
printf '  intent:    %s\n' "$(posture_intent "$POSTURE")"
printf '  artifacts: %s\n' "$ART"
printf '  levers:    MERGE_POLICY=%s HUMAN_VERIFY_POLICY=%s REVIEW_AUTOFIX=%s HEALTHCHECK_AUTOFIX=%s\n' \
  "$MERGE_POLICY" "$HUMAN_VERIFY_POLICY" "$REVIEW_AUTOFIX" "$HEALTHCHECK_AUTOFIX"
printf '             STALE_BASE_AUTOFIX=%s DRAFT_AUTO_PROMOTE=%s DEAD_BUILDER_AUTORESPAWN=%s COORDINATOR_AUTONOMY=%s\n' \
  "$STALE_BASE_AUTOFIX" "$DRAFT_AUTO_PROMOTE" "$DEAD_BUILDER_AUTORESPAWN" "$COORDINATOR_AUTONOMY"
printf '             BUDGET_DAILY=%s\n' "${BUDGET_DAILY:-<unset — dormant>}"

step seed "build the fixture + seed a $N-item backlog"
sandbox_fixture_build "$REPO" >/dev/null || { bad "fixture build failed"; REMAINING="$N"; write_scorecard fail >/dev/null; exit 1; }
_seed_backlog "$N" "$REPO/BACKLOG.md"
printf '#!/usr/bin/env bash\n# registry.sh — the SHARED file surface the collision map has to find.\n' > "$REPO/app/registry.sh"
_sf_git_env
git -C "$REPO" add -A
git -C "$REPO" commit -q -m "seed: $N-item drain backlog + shared registry surface"
checkpoint backlog_seeded pass "seeded $N items (all 🔜) + the shared app/registry.sh surface"

# Seed one builder note per item — step 1 has real work to drain every cycle.
: > "$ART/notes.pending"
for ((i=1; i<=N; i++)); do printf 'item-%02d: stub finding filed mid-build\n' "$i" >> "$ART/notes.pending"; done

# ═══════════════════════════════════════════════════════════════════════════════════════════════
# THE DRAIN LOOP
# ═══════════════════════════════════════════════════════════════════════════════════════════════
while :; do
  CYCLES=$((CYCLES+1))
  step "cycle $CYCLES" "drain-mode loop"

  # ── step 1: drain + route + ack builder notes ────────────────────────────────────────────────
  if [ -s "$ART/notes.pending" ]; then
    local_notes="$(grep -c . "$ART/notes.pending" 2>/dev/null || echo 0)"
    NOTES_ROUTED=$((NOTES_ROUTED + local_notes))
    : > "$ART/notes.pending"
    info "step 1 — routed + acked $local_notes builder note(s)"
  else
    info "step 1 — no builder notes pending"
  fi

  PENDING="$(_pending_tokens)"
  if [ -z "$PENDING" ]; then
    # ── STOP CONDITION 1: backlog empty ────────────────────────────────────────────────────────
    STOP_REASON="backlog-empty"
    info "step 2 — backlog empty; no surfaces left to map"
    break
  fi

  # ── step 2: collision-map each pending item's surface against in-flight worktrees ─────────────
  info "step 2 — collision map:"
  for tok in $PENDING; do info "    item $tok → $(_surface "$tok")"; done

  # ── step 3: spawn to capacity on disjoint surfaces, bundling same-surface items ───────────────
  # Group pending tokens by surface (bash 3.2: parallel arrays keyed by position, no assoc arrays).
  G_SURF=(); G_TOKS=()
  for tok in $PENDING; do
    s="$(_surface "$tok")"; found=-1
    for ((gi=0; gi<${#G_SURF[@]}; gi++)); do [ "${G_SURF[$gi]}" = "$s" ] && found=$gi && break; done
    if [ "$found" -ge 0 ] && [ "$BUNDLE" -eq 1 ]; then
      G_TOKS[$found]="${G_TOKS[$found]} $tok"
    else
      G_SURF+=("$s"); G_TOKS+=("$tok")
    fi
  done

  spawned_this_cycle=0
  DRAINED_THIS_CYCLE=0
  for ((gi=0; gi<${#G_SURF[@]}; gi++)); do
    [ "$spawned_this_cycle" -ge "$CAPACITY" ] && break
    group="${G_TOKS[$gi]}"; surf="${G_SURF[$gi]}"
    ntoks="$(printf '%s\n' $group | grep -c . || true)"

    # ── STOP CONDITION 2: the BUDGET_DAILY ceiling, enforced at the PRE-SPAWN gate ──────────────
    # cost.sh's own predicate — the same one herd-feature.sh / herd-quick.sh / the watcher drain use.
    if budget_over="$(budget_daily_exceeded)"; then
      STOP_REASON="budget-ceiling"
      printf '  %s🛑%s BUDGET_DAILY reached (%s) — refusing to spawn; the drain stops here.\n' \
        "$c_red" "$c_rst" "$budget_over"
      break 2
    fi

    # The spawn decision itself: full autonomy means no "shall I spawn?" ask.
    _decide spawn "surface=$surf items=$group"

    BUILDERS=$((BUILDERS+1)); spawned_this_cycle=$((spawned_this_cycle+1))
    if [ "$ntoks" -gt 1 ]; then
      BUNDLES=$((BUNDLES+1))
      info "step 3 — BUNDLED items [$group ] into ONE builder (shared surface $surf)"
    else
      info "step 3 — spawned a solo builder for item$group (surface $surf)"
    fi

    lead="${group%% *}"; lead="${lead# }"
    BRANCH="drain/builder-$lead"
    WT="$ART/worktrees/builder-$lead"
    git -C "$REPO" worktree remove --force "$WT" 2>/dev/null || true
    git -C "$REPO" branch -D "$BRANCH" >/dev/null 2>&1 || true
    rm -rf "$WT"
    _sf_git_env
    if ! git -C "$REPO" worktree add -q "$WT" -b "$BRANCH" main 2>/dev/null; then
      checkpoint "builder_${lead}_worktree" fail "could not create the worktree/branch"
      continue
    fi

    # STUB builder — one deterministic commit carrying every bundled item's change.
    for tok in $group; do
      if [ "$(_surface "$tok")" = "app/item-01.sh" ]; then
        printf '#!/usr/bin/env bash\nitem_%s() { printf "item %s done\\n"; }\n' "$tok" "$tok" > "$WT/app/item-$tok.sh"
      else
        printf 'register_%s() { printf "item %s registered\\n"; }\n' "$tok" "$tok" >> "$WT/app/registry.sh"
      fi
    done
    git -C "$WT" add -A
    git -C "$WT" commit -q -m "stub-builder: implement item(s)$group"
    HEAD_SHA="$(git -C "$WT" rev-parse HEAD)"
    cat > "$PRDIR/builder-$lead.json" <<PR
{"items": "$(printf '%s' "$group" | sed 's/^ *//')", "branch": "$BRANCH", "surface": "$surf", "head_sha": "$HEAD_SHA", "hosted": false}
PR

    # ── the injected engine events for each item this builder carries ────────────────────────────
    for tok in $group; do
      for ev in $(_events_for "$tok"); do
        case "$ev" in
          block_review) _decide block_review "item $tok · review round 1 BLOCK" ;;
          red_health)   _decide red_health   "item $tok · healthcheck attempt 1 RED" ;;
          draft_pr)     _decide draft_pr     "item $tok · builder finished with the PR still DRAFT" ;;
          dead_builder) _decide dead_builder "item $tok · builder process died before pushing" ;;
          human_verify) _decide human_verify "item $tok · PR carries a HUMAN-VERIFY block" ;;
        esac
      done
    done

    # ── step 4: dispatch the resolver for a DIRTY PR whose builder is done ───────────────────────
    # Make it genuinely dirty: land an out-of-band change on this builder's OWN surface on main
    # (what ADOPT_REMOTE_PRS=on makes routine — another seat's PR landing under you), so the merge
    # below really conflicts and really has to be resolved.
    case " $group " in
      *" $DIRTY_ITEM "*)
        if [ -n "$DIRTY_ITEM" ] && [ "$surf" = "app/registry.sh" ]; then
          printf 'register_out_of_band() { printf "landed by another seat\\n"; }\n' >> "$REPO/app/registry.sh"
          _sf_git_env
          git -C "$REPO" add app/registry.sh
          git -C "$REPO" commit -q -m "out-of-band: another seat lands on app/registry.sh"
          info "step 4 — an out-of-band merge landed on $surf; builder $lead's PR is now DIRTY"
          if [ "$ESCALATE_AT" = "$DIRTY_ITEM" ]; then
            # ── STOP CONDITION 3: the resolver PUNTS — a genuine escalation ──────────────────────
            RESOLVER_DISPATCHES=$((RESOLVER_DISPATCHES+1))
            ESCALATIONS=$((ESCALATIONS+1))
            STOP_REASON="escalation"
            printf '  %s🛑%s resolver ESCALATE on item %s — semantically ambiguous conflict; the drain stops.\n' \
              "$c_red" "$c_rst" "$DIRTY_ITEM"
            break 2
          fi
          _decide stale_base "builder $lead · base moved under it on $surf"
          RESOLVER_DISPATCHES=$((RESOLVER_DISPATCHES+1))
          # The resolver: a real merge-up, resolving the real conflict by taking BOTH sides.
          if ! git -C "$WT" merge -q --no-edit main >/dev/null 2>&1; then
            if [ -f "$WT/app/registry.sh" ]; then
              grep -vE '^(<<<<<<<|=======|>>>>>>>)' "$WT/app/registry.sh" > "$WT/app/registry.sh.res" \
                && mv "$WT/app/registry.sh.res" "$WT/app/registry.sh"
              git -C "$WT" add app/registry.sh
              git -C "$WT" commit -q --no-edit -m "resolver: union-resolve app/registry.sh" 2>/dev/null || true
            fi
          fi
          if [ -n "$(git -C "$WT" status --porcelain 2>/dev/null)" ]; then
            checkpoint "resolver_${lead}" fail "the resolver left the worktree dirty"
          else
            checkpoint "resolver_${lead}" pass "dispatched the resolver on a genuinely DIRTY PR and it resolved cleanly"
          fi
        fi ;;
    esac

    # ── step 5: the GATES merge (never self-merge) ────────────────────────────────────────────────
    gate_rc=0
    ( cd "$WT" && bash app/greet.test.sh ) >/dev/null 2>&1 || gate_rc=$?
    if [ "$gate_rc" -ne 0 ]; then
      GATE_FAILURES=$((GATE_FAILURES+1))
      checkpoint "gate_${lead}" fail "healthcheck RED (rc=$gate_rc) — NOT merged (the gate still gates under YOLO)"
      git -C "$REPO" worktree remove --force "$WT" 2>/dev/null || true
      git -C "$REPO" branch -D "$BRANCH" >/dev/null 2>&1 || true
      continue
    fi
    _decide merge "builder $lead · gates green"
    _sf_git_env
    if ! git -C "$REPO" merge -q --no-ff -m "merge: $BRANCH" "$BRANCH" 2>/dev/null; then
      checkpoint "merge_${lead}" fail "merge of $BRANCH into main failed"
      git -C "$REPO" merge --abort 2>/dev/null || true
      git -C "$REPO" worktree remove --force "$WT" 2>/dev/null || true
      git -C "$REPO" branch -D "$BRANCH" >/dev/null 2>&1 || true
      continue
    fi
    git -C "$REPO" worktree remove --force "$WT" 2>/dev/null || true
    git -C "$REPO" branch -D "$BRANCH" >/dev/null 2>&1 || true

    # ── step 6: reconcile — mark each item shipped, and record the spend on the REAL rail ────────
    for tok in $group; do
      _mark_shipped "$tok"
      DRAINED=$((DRAINED+1)); DRAINED_THIS_CYCLE=$((DRAINED_THIS_CYCLE+1))
      SPEND_ITEMS=$((SPEND_ITEMS+1))
      journal_append cost component builder item "$tok" usd "$COST_PER_ITEM" >/dev/null 2>&1 || true
    done
    _sf_git_env
    git -C "$REPO" add BACKLOG.md
    git -C "$REPO" commit -q -m "scribe: mark item(s)$group shipped"
    ok "merged + reconciled item(s)$group — $(_count_shipped)/$N shipped, spend \$$(cost_day_total)"
  done

  # ── step 7: repeat — unless a cycle moved NOTHING, which is a livelock, not a drain ───────────
  if [ -n "$STOP_REASON" ]; then break; fi
  if [ "$DRAINED_THIS_CYCLE" -eq 0 ]; then
    STOP_REASON="livelock"
    printf '  %s🛑%s cycle %d drained nothing and hit no stop condition — LIVELOCK.\n' \
      "$c_red" "$c_rst" "$CYCLES"
    break
  fi
done

REMAINING="$(_count_pending)"
DRAINED="$(_count_shipped)"

# ── the completion digest (stop condition 1's required output) ──────────────────────────────────
if [ "$STOP_REASON" = "backlog-empty" ]; then
  {
    printf 'DRAIN COMPLETE — posture %s\n' "$POSTURE"
    printf '  items drained:        %d/%d\n' "$DRAINED" "$N"
    printf '  cycles:               %d\n' "$CYCLES"
    printf '  builders spawned:     %d (bundled groups: %d)\n' "$BUILDERS" "$BUNDLES"
    printf '  builder notes routed: %d\n' "$NOTES_ROUTED"
    printf '  resolver dispatches:  %d (escalations: %d)\n' "$RESOLVER_DISPATCHES" "$ESCALATIONS"
    printf '  gate failures:        %d\n' "$GATE_FAILURES"
    printf '  coordinator prompts:  %d\n' "$PROMPTS"
    printf '  recorded spend:       $%s (BUDGET_DAILY=%s)\n' "$(cost_day_total)" "${BUDGET_DAILY:-unset}"
  } > "$ART/digest.txt"
  DIGEST_EMITTED=true
  step digest "completion digest"
  while IFS= read -r l; do printf '  %s\n' "$l"; done < "$ART/digest.txt"
  checkpoint completion_digest pass "backlog empty → digest emitted at $ART/digest.txt"
fi

# ── assertions ──────────────────────────────────────────────────────────────────────────────────
step assert "the drain-mode invariants"

case "$STOP_REASON" in
  backlog-empty|budget-ceiling|escalation)
    checkpoint stop_condition_declared pass "stopped on a DECLARED stop condition: $STOP_REASON" ;;
  *)
    checkpoint stop_condition_declared fail "stopped for an UNDECLARED reason: '${STOP_REASON:-<none>}' — drain mode declares exactly three (backlog-empty, budget-ceiling, escalation)" ;;
esac

if [ "$STOP_REASON" = "backlog-empty" ]; then
  if [ "$REMAINING" -eq 0 ]; then
    checkpoint drained_to_zero pass "all $N items shipped (0 remaining)"
  else
    checkpoint drained_to_zero fail "$REMAINING item(s) still 🔜 at a backlog-empty stop"
  fi
fi

if [ "$STOP_REASON" = "budget-ceiling" ]; then
  if [ "$REMAINING" -gt 0 ]; then
    checkpoint budget_halted_the_loop pass "the BUDGET_DAILY ceiling HALTED the drain with $REMAINING item(s) still open — enforced, not merely measured"
  else
    checkpoint budget_halted_the_loop fail "budget stop reported but the backlog drained anyway — the ceiling was not enforced"
  fi
fi

if [ "$STOP_REASON" = "escalation" ] && [ "$ESCALATIONS" -gt 0 ]; then
  checkpoint escalation_halted_the_loop pass "the resolver's ESCALATE halted the drain with $REMAINING item(s) still open"
fi

# The headline: zero coordinator prompts. Only asserted for a posture that claims to own every rail;
# for any other posture the prompt count is REPORTED (that is the control arm's whole point).
_yolo_full=1
for lever in "$(_owner block_review)" "$(_owner red_health)" "$(_owner stale_base)" "$(_owner draft_pr)" \
             "$(_owner dead_builder)" "$(_owner spawn)" "$(_owner human_verify)" "$(_owner merge)"; do
  [ "$lever" = engine ] || _yolo_full=0
done
if [ "$_yolo_full" -eq 1 ]; then
  if [ "$PROMPTS" -eq 0 ]; then
    checkpoint zero_coordinator_prompts pass "every decision this drain hit was owned by an engine rail — 0 coordinator prompts"
  else
    checkpoint zero_coordinator_prompts fail "$PROMPTS coordinator prompt(s) under an all-rails posture: $PROMPT_REASONS"
  fi
else
  checkpoint zero_coordinator_prompts skip "posture '$POSTURE' does not own every rail — $PROMPTS coordinator prompt(s): ${PROMPT_REASONS:-none}"
fi

if [ "$GATE_FAILURES" -eq 0 ]; then
  checkpoint gates_still_gate pass "every merged PR passed the fixture healthcheck — YOLO removed the pauses, not the gates"
else
  checkpoint gates_still_gate fail "$GATE_FAILURES gate failure(s) merged or mishandled"
fi

RESULT="pass"; [ "$_fail" -gt 0 ] && RESULT="fail"
SCARD="$(write_scorecard "$RESULT")"
printf '\n%s══ scorecard ══%s\n' "$c_bold" "$c_rst"
printf '  posture:              %s\n' "$POSTURE"
printf '  items_drained:        %d/%d (remaining: %d)\n' "$DRAINED" "$N" "$REMAINING"
printf '  cycles:               %d · builders: %d · bundles: %d\n' "$CYCLES" "$BUILDERS" "$BUNDLES"
printf '  notes_routed:         %d · resolver_dispatches: %d · escalations: %d\n' "$NOTES_ROUTED" "$RESOLVER_DISPATCHES" "$ESCALATIONS"
printf '  coordinator_prompts:  %d\n' "$PROMPTS"
printf '  stop_reason:          %s (digest: %s)\n' "$STOP_REASON" "$DIGEST_EMITTED"
printf '  spend / budget:       $%s / %s\n' "$(cost_day_total)" "${BUDGET_DAILY:-<unset>}"
printf '  result:               %s\n' "$RESULT"
printf '  scorecard:            %s\n' "$SCARD"

[ "$RESULT" = "pass" ] && exit 0 || exit 1
