#!/usr/bin/env bash
# git-pr.sh — the git-pr work-unit ADAPTER BODY (Phase 3, HERD-398/HERD-395). Full design:
# docs/spikes/work-unit-abstraction.md (interface at ~2.2, git-pr adapter table at ~2.3, Phase 3 at
# ~414-419).
#
# WHY: Phase 1 (scripts/herd/work-unit.sh, HERD-396) named the work-unit spine as wunit_* wrappers but
# left every git-pr implementation living inline inside agent-watch.sh — the facade borrowed them via
# the AGENT_WATCH_LIB=1 seam. Phase 3 moves the PR-specific implementations OUT from behind
# agent-watch.sh's 14k lines and INTO this file — selected by WORK_UNIT_KIND (default git-pr; see the
# resolver in work-unit.sh, wunit_resolve_adapter). This is a MOVE, not a rewrite: every function below
# is byte-identical to its prior body in agent-watch.sh — same name, same argv, same globals it reads
# (STATE, MAIN, TREES, journal_append, …) — so behavior is unchanged and every existing call site in
# agent-watch.sh (and every test that sources agent-watch.sh in lib mode) keeps working with ZERO edits:
# bash resolves a function by name at CALL time, not at source time, so relocating the DEFINITION to a
# sibling file sourced earlier in agent-watch.sh's own load sequence changes nothing observable.
#
# WHAT MOVED HERE (the spike's §1 seam table, mapped to this PR's extraction):
#   already_merged                      state-file key READ  (idempotency guard on $STATE)
#   _classify_review_tier                review dispatch argv (`gh pr diff --name-only`)
#   _merge_method_flag, _delete_branch_flag   merge actuation flags (composed into `gh pr merge`)
#   do_merge                             merge actuation/verify + state-file key WRITE (`gh pr merge`,
#                                         --match-head-commit, the $STATE append, post-merge hooks)
#   _reconcile_pr_ref                    reconcile: PR-specific 'Refs:' fetch (`gh pr view`)
#   reconcile_backlog                    reconcile: the PR-keyed post-merge hook orchestrator
#   _watcher_tick_fields, _prs_fetch_tick  discovery: the tick's `gh pr list --json` call + field set
#     (candidate schema)
#
# WHAT DELIBERATELY DID NOT MOVE (partial honest extraction — a seam left in agent-watch.sh because
# moving it was cross-cutting or already kind-agnostic, per the spike's explicit escape hatch "if a
# seam cannot be extracted without semantic risk, leave it for a follow-up"; each is journaled — herd
# note — at extraction time rather than silently skipped):
#   _reap_slug            teardown — the spike (§3.2 step 6) says a FUTURE kind reuses this AS-IS
#                          ("Same _reap_slug mechanics"); it is already kind-agnostic, not PR-shaped.
#   _reconcile_via_ref     the spike (§3.2 step 5) calls this OUT BY NAME as "already PR-agnostic once
#                          given a ref!" — reused verbatim by a future manifest-based kind.
#   herd_pr_ref_from_body  pure text parsing of a 'Refs:' line from body TEXT on stdin — no gh, no PR
#                          coupling at all; a future doc-apply manifest body reuses it unchanged.
#   _cand_gates_ready      generic health+review readiness composition; already the wunit_gate body.
#   stale-dup-gate.sh      already an independently-sourced, independently-tested module (own contract,
#                          own test file) — relocating it into this adapter is pure file-shuffling with
#                          no behavior benefit and a real risk of breaking its test's path assumptions;
#                          left in place.
#   the task-spec "…then gh pr create." pointer strings (herd_write_task_spec in herd-config.sh,
#     _respawn_builder_in_worktree in agent-watch.sh) — hot, duplicated-but-working call sites that
#     compose EVERY builder's spawn prompt; touching either for cosmetic dedup risks the byte-identical
#     guarantee across every spawn for a purely cosmetic win. Left in place.
#   _discover_feature_worktrees — the worktree↔PR↔agent join (candidate schema's OTHER half). Genuinely
#     entangled with agent/worktree discovery, not purely PR-shaped; too risky to extract in this pass.
#
# CONTRACT: sourced by agent-watch.sh only (never executed standalone — it has no shebang-run guard
# because, like human-verify.sh / stale-dup-gate.sh / merge-policy.sh, it defines functions that read
# globals (STATE, MAIN, TREES, APPROVALS, CI_CHECKS_STATE, RECONCILE_STATE, FLAIR_CELEBRATE_STATE, …)
# and call sibling functions (journal_append, _gh_timeout, purge_pr_*, _reap_slug, _reconcile_via_ref,
# herd_pr_ref_from_body, refresh_codemap, refresh_symbol_index, main_health_tick, steps_run_at,
# cost_emit_merge, _flair_enabled, _slug_ref, _watcher_view_fields, _watcher_team_mode,
# _adopt_remote_prs_enabled, _watcher_view_filter) that agent-watch.sh itself defines or sources. None
# of that needs to exist yet AT SOURCE TIME — only at CALL time, long after agent-watch.sh has finished
# loading — so sourcing this file early in agent-watch.sh's own load sequence is safe.

# ── borrow journal.sh's journal_append if not already in scope ─────────────────────────────────────
# agent-watch.sh sources journal.sh (scripts/herd/journal.sh) near the top of its own load sequence,
# well before it reaches the point where this file is sourced — in the real pipeline this is always a
# no-op. Explicit, not conventional, so every journal_append call below (reconcile/do_merge) has the
# machinery loaded even for a caller that sources this file standalone (a test, or a future caller
# that hasn't sourced agent-watch.sh at all). Mirrors work-unit.sh's own borrow-if-not-in-scope pattern
# for journal_unit_ref.
if ! command -v journal_append >/dev/null 2>&1; then
  _GITPR_HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
  # shellcheck source=/dev/null
  . "$_GITPR_HERE/journal.sh"
fi

# already_merged <pr#> <slug> — idempotency guard against the persistent state file. Matches the
# "<epoch> <pr#> <slug>" prefix followed by end-of-line OR a space (a HERD-92 4th tracker-ref field),
# so appending the ref never regresses this guard.
already_merged() {
  [ -s "$STATE" ] || return 1
  grep -qE "^[0-9]+ $1 $2( |\$)" "$STATE" 2>/dev/null
}

# _classify_review_tier <pr#> — echo the review tier for a PR's diff: STRONG | CHEAP | DOCS | SKIP.
# Only ever called when REVIEW_ESCALATE_GLOB or DOCS_ONLY_GLOB is set (the opt-in); with BOTH empty the
# caller keeps today's always-$MODEL_REVIEW path and this never runs. Classification is DETERMINISTIC and
# fails SAFE — any uncertainty (unreadable/empty diff) → STRONG, never a downgrade:
#   • only *.md / tests/ paths changed                  → SKIP  (no reviewer; PASS recorded low-risk)
#   • any path matches REVIEW_ESCALATE_GLOB             → STRONG (engine surface; escalation wins)
#   • more than REVIEW_ESCALATE_MAXFILES files changed  → STRONG (large diff; escalation wins)
#   • every path matches DOCS_ONLY_GLOB (opt-in)        → DOCS   ($REVIEW_MODEL_DOCS, cheapest tier)
#   • otherwise (small, low-risk)                        → CHEAP  ($REVIEW_MODEL_CHEAP)
# ESCALATION WINS: the REVIEW_ESCALATE_GLOB / MAXFILES checks run BEFORE the DOCS_ONLY_GLOB check, so a
# docs-only diff that ALSO touches an engine-critical path (or is large) still gets the STRONG tier.
_classify_review_tier() {
  local pr="$1" paths n max
  # Changed-file paths for THIS PR's diff. Any failure/empty list → STRONG (never downgrade blind).
  paths="$(_gh_timeout review_scope_diff pr diff "$pr" --name-only 2>/dev/null | awk 'NF')"
  [ -n "$paths" ] || { printf STRONG; return 0; }
  # DOCS/TEST-ONLY: every changed path is a *.md doc or under tests/ — i.e. NO line fails to match
  # the docs/test pattern → skip the adversarial review entirely.
  if ! printf '%s\n' "$paths" | grep -qvE '(\.md$)|(^tests/)'; then printf SKIP; return 0; fi  # pipe-ok: bounded membership list, under a pipe buffer
  # Engine-surface glob match → full strong review (escalation wins over the docs tier). The -n guard
  # keeps this classifier safe when only DOCS_ONLY_GLOB opted in: an empty REVIEW_ESCALATE_GLOB would
  # make `grep -qE ""` match every path and wrongly force STRONG.
  if [ -n "${REVIEW_ESCALATE_GLOB:-}" ] && printf '%s\n' "$paths" | grep -qE "$REVIEW_ESCALATE_GLOB"; then printf STRONG; return 0; fi  # pipe-ok: bounded membership list, under a pipe buffer
  # Large diff (many files) → strong even without a glob match (escalation wins over the docs tier).
  n="$(printf '%s\n' "$paths" | grep -c .)"
  max="${REVIEW_ESCALATE_MAXFILES:-10}"; case "$max" in ''|*[!0-9]*) max=10 ;; esac
  if [ "$n" -gt "$max" ] 2>/dev/null; then printf STRONG; return 0; fi
  # DOCS-ONLY (opt-in via DOCS_ONLY_GLOB): every changed path matches the operator's docs pattern → the
  # cheapest reviewer tier ($REVIEW_MODEL_DOCS). Distinct from SKIP: a real (cheap) adversarial review
  # still runs — for doc formats the hardcoded *.md/tests SKIP above doesn't cover (e.g. *.txt).
  if [ -n "${DOCS_ONLY_GLOB:-}" ] && ! printf '%s\n' "$paths" | grep -qvE "$DOCS_ONLY_GLOB"; then  # pipe-ok: bounded membership list, under a pipe buffer
    printf DOCS; return 0
  fi
  # Small + low-risk → cheap reviewer tier.
  printf CHEAP
}

# _merge_method_flag — return the gh pr merge flag for the configured MERGE_METHOD.
_merge_method_flag() {
  case "${MERGE_METHOD:-merge}" in
    squash) printf '%s' '--squash' ;;
    rebase) printf '%s' '--rebase' ;;
    *)      printf '%s' '--merge' ;;
  esac
}

# _delete_branch_flag — '--delete-branch' when DELETE_BRANCH_ON_MERGE is true, else empty. Composed
# UNQUOTED into the `gh pr merge` line (alongside the always-present _merge_method_flag) so on the
# default false it contributes NO argument and the merge is byte-identical to before; on true, gh
# deletes the merged head branch instead of letting merged feature branches accumulate on the remote.
_delete_branch_flag() {
  case "${DELETE_BRANCH_ON_MERGE:-false}" in
    1|true|yes|on) printf '%s' '--delete-branch' ;;
    *)             : ;;
  esac
}

# _reconcile_pr_ref <pr#> — deterministic tracker linkage (HERD-39): read the merged PR body and
# print the explicit 'Refs: <ID>' tracker reference the builder carried (lanes REQUIRE it when the
# coordinator spawned with HERD_ITEM_REF). Empty when the PR carries no ref, the body is unreadable,
# or the value is still the template placeholder ('<...>' / none / n/a). Best-effort + fail-soft: a
# missing 'gh', an offline run, or a body-less PR all yield an empty ref, so the caller cleanly falls
# back to the fuzzy path — never a hard error on the merge tail.
_reconcile_pr_ref() {
  local body ref
  body="$(_gh_timeout reconcile_pr_ref pr view "$1" --json body -q .body 2>/dev/null || true)"
  [ -n "$body" ] || return 0
  ref="$(printf '%s' "$body" | herd_pr_ref_from_body)"
  [ -n "$ref" ] || return 0
  printf '%s' "$ref"
}

# reconcile_backlog <pr#> <slug> <headSha> — the POST-MERGE auto-reconcile HOOK. Fires on EVERY
# successful merge (the normal auto-merge path, an autofix bounce that finally lands, and direct
# hand-off merges — all converge here in do_merge), enqueuing ONE scribe reconcile request keyed by
# the merged PR number + its branch slug. The scribe matches the 🔜/🚧 backlog item by 'worktree
# <slug>' OR the PR title (so items the coordinator never slug-tagged still reconcile — the drift the
# old slug-only reap missed) and marks it ✅ shipped; if none matches it no-ops. IDEMPOTENT: record
# FIRST against $RECONCILE_STATE (keyed by pr+sha, mirroring the review/health ledgers) so a re-run
# tick for the same merged PR reads the ledger and never re-enqueues, even if scribe.sh later dies.
# Best-effort — a failed enqueue never blocks the merge (the advisory sweep is the backstop).
reconcile_backlog() {
  local rb_pr="$1" rb_slug="$2" rb_sha="${3:-}" rb_ref
  reconcile_enqueued "$rb_pr" "$rb_sha" && return 0
  record_reconcile "$rb_pr" "$rb_sha" "$rb_slug"
  # EXPLICIT-REF path FIRST (HERD-39): if the merged PR carries a 'Refs: <ID>' line, resolve the
  # backlog item by that exact ref via the active backend's update-state — deterministic, no fuzzy
  # slug/title guessing and no scribe LLM. Only when there is no ref line OR it fails to resolve
  # (backend has no update-state op, e.g. the default file backend, or reports no match) do we fall
  # back to today's fuzzy scribe enqueue — so ref-less PRs behave EXACTLY as before. Journal which
  # path resolved so a drift audit can tell explicit-ref links from fuzzy ones.
  rb_ref="$(_reconcile_pr_ref "$rb_pr")"
  if [ -n "$rb_ref" ] && _reconcile_via_ref "$rb_ref" "$rb_pr"; then
    journal_append reconcile pr "$rb_pr" slug "$rb_slug" sha "$rb_sha" ref "$rb_ref" resolution explicit-ref
    return 0
  fi
  if [ -n "$rb_ref" ]; then
    journal_append reconcile pr "$rb_pr" slug "$rb_slug" sha "$rb_sha" ref "$rb_ref" resolution fuzzy
  else
    journal_append reconcile pr "$rb_pr" slug "$rb_slug" sha "$rb_sha" resolution fuzzy
  fi
  bash "$HERE/scribe.sh" "Reconcile: PR #${rb_pr} (worktree ${rb_slug}) merged — find the 🔜/🚧 backlog item matching worktree ${rb_slug} or the PR title and mark it ✅ shipped (PR #${rb_pr}); if none matches, no-op." >/dev/null 2>&1 || true
  return 0
}

# do_merge <slug> <pr#> <worktree> — the safety-railed merge + post-merge sequence.
do_merge() {
  ds="$1"; dp="$2"; dd="$3"; dsha="${4:-}"
  if [ -n "$DRYRUN" ]; then
    return 0
  fi
  # CROSS-SEAT DUAL-ENGINE HALT (HERD-308): a merge is the pool's most consequential mutable write. If
  # this tick's reconcile found this seat STALE (a newer engine is writing the same pool), HOLD the
  # merge — return WITHOUT writing the $STATE merge row, so the PR re-gates next tick once the engine is
  # updated. Gated on the lever, so byte-identical when ENGINE_SEAT_RECONCILE=off (the global is unset).
  if [ "${ENGINE_SEAT_RECONCILE:-off}" = on ] && [ -n "${_ENGINE_SEAT_HALT:-}" ]; then
    journal_append engine_seat_write_held surface do_merge pr "$dp" slug "$ds" sha "$dsha"
    return 1
  fi
  # Pipeline steps (HERD-132) — PRE-MERGE seam. Operator-defined pre-merge steps run HERE, AFTER the
  # built-in review + health gates have already passed (this PR only reaches do_merge on green gates),
  # so they ADD a gate, never bypass the floor. A block-step failure (rc 1) or an approve-HOLD (rc 20)
  # leaves the PR UNMERGED — we return WITHOUT writing the $STATE merge row, so the watcher retries next
  # tick (a block re-runs; an approve-hold re-surfaces until 'herd-approve.sh approve <slug>' releases
  # it). Byte-inert when .herd/steps.tsv is absent (steps_run_at returns 0 immediately).
  if command -v steps_run_at >/dev/null 2>&1; then
    local _st_rc=0
    steps_run_at pre-merge --slug "$ds" --dir "$dd" --sha "$dsha" || _st_rc=$?
    if [ "$_st_rc" -ne 0 ]; then
      case "$_st_rc" in
        20) journal_append step_gate pr "$dp" slug "$ds" sha "$dsha" seam pre-merge action held ;;
        *)  journal_append step_gate pr "$dp" slug "$ds" sha "$dsha" seam pre-merge action blocked ;;
      esac
      return 1
    fi
  fi
  # HERD-156: PIN the merge to the gate-verified sha. Everything upstream — the re-verify tick, the
  # PR-body fetch, the pre-merge steps seam above — opens a window in which a NEW commit could be
  # pushed to the head branch AFTER the review + health gates passed on $dsha. --match-head-commit makes
  # gh REFUSE the merge unless the remote head is still exactly $dsha, so a commit that landed during
  # that window can NEVER merge unreviewed. On a moved head gh exits non-zero; we journal it and return
  # WITHOUT writing the $STATE merge row, so the next tick re-gates (re-review + re-health) the NEW sha
  # through the existing machinery — no new state, and the merge stays at-most-once. $dsha is empty only
  # for a legacy caller that threaded no sha; there we fall back to the unpinned merge (byte-identical to
  # before this change) rather than refuse a merge we cannot pin.
  #
  # HERD-221: gh pr merge can exit non-zero AFTER a successful merge — most commonly when
  # DELETE_BRANCH_ON_MERGE=true and the local branch delete fails (branch still checked out in its
  # worktree). Treating ANY non-zero as "sha moved" skipped every post-merge hook while the PR was
  # already MERGED. On non-zero, re-check the PR's actual state: MERGED → treat as success and run
  # ALL post-merge hooks; only a NOT-merged PR is a real refusal that returns 1 and skips hooks.
  #
  # HERD-232 (audit G6, honest labels): the re-check itself can fail. `gh pr view` returning nothing —
  # a network blip, rate limit, auth expiry — is NOT evidence the head moved, and journaling
  # `merge_refused_sha_moved` for it sends a post-mortem hunting a phantom force-push. Distinguish the
  # two: an EMPTY state is a gh outage (`merge_gh_unreadable`), a readable non-MERGED state is a real
  # refusal. Both still return 1 and skip the hooks — the PR is re-gated next tick either way, and the
  # post-merge reconcile sweep is the backstop if it turns out the merge did land.
  #
  # HERD-237: the merge call is timeout-wrapped like every other gh call. A merge killed at the
  # deadline is INDISTINGUISHABLE from any other non-zero merge exit — including one where GitHub
  # already applied the merge — which is precisely the case the HERD-221 state re-check below was
  # written for: it re-reads the PR's actual state instead of inferring it from the exit code. A
  # timed-out merge whose PR reads MERGED runs its hooks; one that reads unmerged/unreadable returns 1
  # and is re-gated next tick. No new failure mode, and the tick no longer wedges on a hung merge.
  if [ -n "$dsha" ]; then
    if ! _gh_timeout merge_pinned pr merge "$dp" "$(_merge_method_flag)" $(_delete_branch_flag) --match-head-commit "$dsha" >/dev/null 2>&1; then
      _dm_state="$(_gh_timeout merge_state_recheck pr view "$dp" --json state,mergedAt -q '.state' 2>/dev/null || true)"
      if [ "$_dm_state" != "MERGED" ]; then
        if [ -n "$_dm_state" ]; then
          journal_append merge_refused_sha_moved pr "$dp" slug "$ds" sha "$dsha" state "$_dm_state"
        else
          journal_append merge_gh_unreadable pr "$dp" slug "$ds" sha "$dsha"
        fi
        return 1
      fi
    fi
  else
    if ! _gh_timeout merge_unpinned pr merge "$dp" "$(_merge_method_flag)" $(_delete_branch_flag) >/dev/null 2>&1; then
      [ "$(_gh_timeout merge_state_recheck pr view "$dp" --json state,mergedAt -q '.state' 2>/dev/null)" = "MERGED" ] || return 1
    fi
  fi
  # HERD-92: capture the tracker ref so "recently landed" can render "<ref> <slug>" like the healed
  # section. Prefer the cheap per-worktree marker (no network); fall back to the merged PR's 'Refs:'
  # body line. Empty for an untracked PR → the row renders the plain slug, exactly as before.
  _dm_ref="$(_slug_ref "$ds")"
  [ -n "$_dm_ref" ] || _dm_ref="$(_reconcile_pr_ref "$dp" 2>/dev/null || true)"
  # Record FIRST: even if a later cleanup step dies, we never re-merge this PR. Omit the 4th field
  # entirely when there is no ref so a ref-less row stays byte-identical to the pre-HERD-92 format.
  if [ -n "$_dm_ref" ]; then
    printf '%s %s %s %s\n' "$(date +%s)" "$dp" "$ds" "$_dm_ref" >> "$STATE"
  else
    printf '%s %s %s\n' "$(date +%s)" "$dp" "$ds" >> "$STATE"
  fi
  journal_append merge pr "$dp" slug "$ds" sha "$dsha" method "$(_merge_method_flag)" reason gates_passed
  # HERD-147 flair: queue a merge CELEBRATION for the NEXT status tick (build_celebrate renders + clears
  # it). Gated on WATCHER_FLAIR so the marker is never written when flair is off → do_merge stays
  # byte-identical to before this feature. Additive + fail-soft: a marker write that fails is ignored.
  _flair_enabled && printf '%s\n' "$dp" >> "$FLAIR_CELEBRATE_STATE" 2>/dev/null || true
  # HERD-90: purge every approval-ledger row for this PR (all shas) now that it is merged. Without
  # this, an OLD-sha 'awaiting' row from a re-applied HUMAN-VERIFY hold lingers as a phantom pending
  # approval in `herd-approve.sh list`. Done right after the merge record so a later cleanup crash
  # can never leave the phantom behind.
  purge_pr_approvals "$dp"
  # HERD-197: drop this PR's CI-check gate-event ledger rows too — the PR is merged, so its check
  # results are terminal and never re-evaluated; keeps $CI_CHECKS_STATE from growing unbounded.
  purge_pr_ci_checks "$dp"
  # HERD-334: drop this PR's aging-alarm markers (first-seen + noted, all shas) — the PR merged, so it
  # can never age again; keeps the marker set from growing unbounded (mirrors purge_pr_ci_checks).
  purge_pr_aging "$dp"
  # 0) COST ACCOUNTING (best-effort, read-only): sum this builder's worktree transcript and journal
  #    a `cost` event (builder — and the in-worktree review, if captured) BEFORE the worktree is
  #    reaped. Never affects the merge; a missing transcript / python3 just drops the event.
  type cost_emit_merge >/dev/null 2>&1 && cost_emit_merge "$dp" "$ds" "$dd"
  # 1) POST-MERGE auto-reconcile hook: enqueue exactly ONE idempotent scribe reconcile request keyed
  #    by PR# + slug (matches by 'worktree <slug>' OR PR title, so autofix / hand-off items that were
  #    never slug-tagged still reconcile — the drift the old slug-only reap missed).
  reconcile_backlog "$dp" "$ds" "$dsha"
  # 2) fast-forward the MAIN checkout so coordinator + backlog viewer reflect it. Never force.
  git -C "$MAIN" pull --ff-only >/dev/null 2>&1 || git -C "$MAIN" fetch --all >/dev/null 2>&1 || true
  # 2b) POST-MERGE codemap refresh: regenerate the committed docs/codemap.md against the freshly ff'd
  #     $MAIN and, only when it actually changed, commit it direct to the default branch (no PR,
  #     BACKLOG.md-style) and push ff-safe. Gated by CODEMAP_AUTOREFRESH; fully fail-soft — a codemap
  #     problem never blocks or fails the merge (mirrors the reconcile hook's best-effort posture).
  refresh_codemap "$dp"
  # 2c) POST-MERGE symbol-index refresh: same posture as 2b but for the function-level def→caller
  #     index (docs/symbol-index.md). Shares the CODEMAP_AUTOREFRESH lever; fully fail-soft.
  refresh_symbol_index "$dp"
  # 2d) POST-MERGE main-health tick (HERD-129): run the healthcheck suite against the freshly ff'd
  #     default-branch HEAD to catch a RED main AT MERGE TIME (two independently-green PRs merging into
  #     a broken combination). Gated by MAIN_HEALTH_TICK (default off → byte-inert). An ALARM only:
  #     fully fail-soft, never blocks/reverts/re-merges — like 2b/2c it can never fail the merge.
  main_health_tick "$dp"
  # 2e) POST-MERGE pipeline steps (HERD-132): operator-defined post-merge steps run here, BEFORE the
  #     worktree is reaped (so a step can still inspect it). ALARM-class like 2b–2d: the merge has
  #     already landed, so this can NEVER revert or re-merge — a failing block-step / an approve-hold
  #     journals loudly but the merge stands. Byte-inert when no steps.tsv. Never fails the merge.
  if command -v steps_run_at >/dev/null 2>&1; then
    steps_run_at post-merge --slug "$ds" --dir "$dd" --sha "$dsha" \
      || journal_append step_gate pr "$dp" slug "$ds" sha "$dsha" seam post-merge action nonzero
  fi
  # 3+4) IDEMPOTENT teardown (the WATCHER's job — sub-agents NEVER self-close): force-remove the
  #      worktree, reap the HERD-92 tracker-ref marker (the ref lives on in the $STATE row), journal
  #      the reap, and close the builder / review·slug / resolver·slug tabs. Shared with the startup
  #      reap-sweep so a merge that crashed BEFORE this point (PR #208) is resumed on restart.
  _reap_slug "$ds" "$dd" "$dp" "$dsha" merged
  return 0
}

# The --json fields for the tick's `gh pr list`. In team mode we additionally need each PR's `author`
# to enforce the ownership gate even when NO view lens is active; fold it in (deduped). HERD-369 needs
# `isDraft` (never adopt a draft) ONLY when ADOPT_REMOTE_PRS is on. In the default solo scope with
# adopt off this is exactly _watcher_view_fields — the base set — so the default gh call is unchanged.
_watcher_tick_fields() {
  _wtf="$(_watcher_view_fields)"
  if _watcher_team_mode; then
    case ",$_wtf," in *,author,*) ;; *) _wtf="${_wtf},author" ;; esac
  fi
  if _adopt_remote_prs_enabled; then
    case ",$_wtf," in *,isDraft,*) ;; *) _wtf="${_wtf},isDraft" ;; esac
  fi
  printf '%s' "$_wtf"
}

# _prs_fetch_tick — set PRS_JSON + PRS_LOOKUP_OK for this watch tick (HERD-224).
# Captures the EXIT STATUS of `gh pr list` so a transient fetch failure is NEVER collapsed into an
# empty roster. The pre-fix form (`|| echo '[]'`) made a failed fetch look identical to "zero open
# PRs", which then rendered builders that HAD an open PR as "awaiting task · assign or retire".
#   • PRS_LOOKUP_OK=1 — the list call succeeded; an empty `[]` means positively no open PRs.
#   • PRS_LOOKUP_OK=0 — the list call failed/errored; PRS_JSON is `[]` only as a safe placeholder
#     for discovery, and the console must paint the degraded "PR match pending" row, never the
#     definitive awaiting-task / died-(no PR) claims. The view filter still applies on success.
_prs_fetch_tick() {
  local _raw _rc=0
  _raw="$(_gh_timeout tick_pr_list pr list --json "$(_watcher_tick_fields)" 2>/dev/null)" || _rc=$?
  if [ "$_rc" -ne 0 ]; then
    PRS_LOOKUP_OK=0
    PRS_JSON='[]'
    return 0
  fi
  PRS_LOOKUP_OK=1
  PRS_JSON="${_raw}"
  [ -n "$PRS_JSON" ] || PRS_JSON='[]'
  PRS_JSON="$(printf '%s' "$PRS_JSON" | _watcher_view_filter)"
  return 0
}
