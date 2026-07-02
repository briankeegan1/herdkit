#!/usr/bin/env bash
# agent-watch.sh — live "herd watch" status console for the coordinator.
#
# A compact, pretty "rollup card" pane that continuously watches the feature sub-agents and
# AUTO-MERGES their PRs when ready (full-auto, safety-railed), so the coordinator (and the user)
# can walk away and still see what is happening and what recently landed. This is HERD TOOLING (a
# herdr pane) — NOT part of the app. Launch it via herd-watch.sh.
#
# Layout: a header (`🐑 herd watch` · live · HH:MM) over a "recently landed" pin (last 3 merges)
# and an "in flight" list — one row per active feature worktree, slug-padded so the state words
# align:
#   🔨 building       — agent working, no PR yet
#   🩺 health-check    — running healthcheck.sh on its worktree
#   🔬 reviewing      — health passed: a STRONG model is adversarially correctness-reviewing the
#                       diff BEFORE merge (herd-review.sh). Merges only on PASS.
#   ⏳ merging         — health passed AND review PASSed, merging now
#   🔀 resolving …     — PR CONFLICTING for the FIRST time: auto-spawned the isolated, test-gated
#                       conflict resolver (herd-resolve.sh). Hands-off.
#   ⚠️ needs you · …   — PR CONFLICTING OR healthcheck returned a CODE error (❌), OR the review
#                       gate returned BLOCK, OR the auto-resolver already ran and it's STILL
#                       conflicting ("resolver failed"). NEVER auto-merged; one-line reason.
#
# AUTO-MERGE rule (full auto, safety-railed): for a PR that is mergeable==MERGEABLE AND
# mergeStateStatus==CLEAN, run  healthcheck.sh <worktree>.  Only if it passes (a ⚠️ data/env
# warning is OK; a ❌ code error is NOT), then RE-VERIFY the PR is STILL MERGEABLE/CLEAN and still
# maps to the expected branch in the instant before merging — guarding the window between
# classification and merge — THEN pass the PRE-MERGE REVIEW GATE, and only on a PASS do
# gh pr merge <n> --merge.
#
# On a successful merge the WATCHER owns teardown (sub-agents never self-close): (1) enqueue
# scribe.sh to mark the backlog item shipped, (2) git -C <main> pull --ff-only (fetch-and-move-on
# if it can't ff — never force), (3) git worktree remove --force <wt>, (4) close its herdr tab,
# and record the merge in a persistent state file so "recently landed" survives re-renders.
#
# AUTO-RESOLVE rule (full auto, safety-railed): when a PR FIRST goes CONFLICTING, the watcher
# auto-spawns the EXISTING isolated resolver (herd-resolve.sh <slug>). Two hard rails: (1)
# resolve-loop guard — a branch that already has a recorded attempt is NEVER re-spawned; (2)
# escalation preserved — the resolver aborts + escalates semantically-ambiguous conflicts; the
# watcher NEVER blind-merges a conflict.
#
# MERGE_POLICY (.herd/config): three-way human-in-the-loop lever.
#   auto    — current behavior: merge automatically after all gates pass.
#   approve — run gates, then hold: record an awaiting-approval entry keyed by <pr#>+<headSha>
#             in .agent-watch-approvals, post a PR comment + notification, and merge ONLY once
#             an explicit approval record for that exact sha is written by herd-approve.sh.
#             A new commit (new headSha) invalidates prior approval and restarts the gate cycle.
#   observe — run gates and report/notify, but NEVER merge under any circumstances.
# Back-compat: WATCHER_AUTOMERGE is still read when MERGE_POLICY is not set (true→auto, false→approve).
#
# DRY-RUN: AGENT_WATCH_DRYRUN=1 does everything EXCEPT the real merge / worktree remove / scribe /
# ff-pull, and never spawns the reviewer/resolver or writes their state files.
#
# Renders ONLY when the computed frame changes — an idle pane never repaints. Polls every ~4s.
set -u

# BASH_SOURCE (not $0) so HERE resolves correctly whether this file is executed or sourced
# (the hermetic test sources it to exercise the pure merge-decision helper).
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/herd-config.sh"
MAIN="$PROJECT_ROOT"
TREES="$WORKTREES_DIR"
STATE="$TREES/.agent-watch-merged"
# Resolve-attempt ledger, PARALLEL to $STATE: one line per conflict-resolver SPAWN
# ("<epoch> <pr#> <slug> <branch>"). A branch that already has a recorded attempt is NEVER given a
# second resolver (a failed/escalated resolve leaves the PR CONFLICTING; re-spawning would loop).
RESOLVE_STATE="$TREES/.agent-watch-resolve-attempts"
# Review ledger, PARALLEL to $STATE/$RESOLVE_STATE: one line per PRE-MERGE REVIEW
# ("<epoch> <pr#> <headSha> <verdict>"). Keyed by PR *and* head sha so a PR is reviewed at most
# ONCE PER COMMIT — a recorded BLOCK is read back instead of re-spawning the reviewer; a recorded
# PASS lets a retried merge skip straight to merging. A new commit changes the sha → fresh review.
REVIEW_STATE="$TREES/.agent-watch-reviewed"
# Override ledger: one line per human override of a cached BLOCK.
# Format: "<epoch> override <pr#> <headSha>"
# Written by herd-approve.sh override <pr#>; keyed by sha so a new commit invalidates the override.
OVERRIDES="$TREES/.agent-watch-overrides"
# Approval ledger (MERGE_POLICY=approve|observe): one line per record, append-only.
# Format: "<epoch> awaiting <pr#> <headSha>"  — watcher noted gates passed, awaiting human approval
#         "<epoch> approved <pr#> <headSha>"  — herd-approve.sh wrote explicit approval for this sha
#         "<epoch> observed <pr#> <headSha>"  — watcher notified in observe mode (dedup guard)
APPROVALS="$TREES/.agent-watch-approvals"
# Only truthy values enable dry-run. Treat "0"/""/"false"/"no" as live.
case "${AGENT_WATCH_DRYRUN:-}" in 1|true|yes|on) DRYRUN=1 ;; *) DRYRUN="" ;; esac

# _effective_merge_policy — resolve "auto" | "approve" | "observe".
# MERGE_POLICY takes precedence; falls back to legacy WATCHER_AUTOMERGE when unset/empty.
_effective_merge_policy() {
  case "${MERGE_POLICY:-}" in
    auto|approve|observe) printf '%s' "${MERGE_POLICY}" ;;
    *)
      case "${WATCHER_AUTOMERGE:-true}" in
        false|no|off|0) printf 'approve' ;;
        *)              printf 'auto' ;;
      esac ;;
  esac
}
_pol="$(_effective_merge_policy)"
AUTOMERGE=""; MERGE_OBSERVE=""
case "$_pol" in
  auto)    AUTOMERGE=1 ;;
  observe) MERGE_OBSERVE=1 ;;
esac
unset _pol
# This watcher's own worktree root — never auto-merge/remove the dir we run from.
SELF_WT="$(cd "$HERE/../.." && pwd)"

# Tokyo Night palette (truecolor — this is a status console, not markdown).
C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'
C_BLUE=$'\033[38;2;122;162;247m'
C_CYAN=$'\033[38;2;125;207;255m'
C_GREEN=$'\033[38;2;158;206;106m'
C_YELLOW=$'\033[38;2;224;175;104m'
C_RED=$'\033[38;2;247;118;142m'
C_DIM=$'\033[38;2;86;95;137m'

SLUGW=28               # slug column width — pads slugs so the state words align.

last_frame=""
HDR_LINE=""
RULE=""
LANDED=""
DISPLAY=()

# build_header — the title row + a full-width rule.
build_header() {
  hhmm="$(date +%H:%M)"
  rlabel="live"; [ -n "$DRYRUN" ] && rlabel="dry-run"
  cols="$(tput cols 2>/dev/null || echo 56)"
  [ "$cols" -lt 40 ] && cols=40
  [ "$cols" -gt 64 ] && cols=64
  rcells=$(( ${#rlabel} + 3 + 5 ))
  pad=$(( cols - 13 - rcells )); [ "$pad" -lt 1 ] && pad=1
  spaces="$(printf '%*s' "$pad" '')"
  HDR_LINE=" ${C_BOLD}${C_CYAN}🐑 herd watch${C_RESET}${spaces}${C_DIM}${rlabel} · ${hhmm}${C_RESET}"
  RULE=" ${C_DIM}$(python3 -c "print('═'*$cols)")${C_RESET}"
}

# epoch_to_hhmm <epoch> — HH:MM from a Unix timestamp; BSD/macOS (-r) and GNU/Linux (-d @) safe.
epoch_to_hhmm() { date -r "$1" +%H:%M 2>/dev/null || date -d "@$1" +%H:%M 2>/dev/null || echo '--:--'; }
# reverse_file <path> — print lines in reverse order; tac (GNU/Linux) or tail -r (BSD/macOS).
reverse_file() { tac "$1" 2>/dev/null || tail -r "$1" 2>/dev/null; }

# build_landed — the pinned "recently landed" rows: the last 3 lines of the state file
# ("<epoch> <pr#> <slug>"), newest first. Stays visible even when idle.
build_landed() {
  if [ ! -s "$STATE" ]; then
    LANDED="    ${C_DIM}nothing yet${C_RESET}"$'\n'
    return 0
  fi
  LANDED=""
  while read -r epoch prnum slug; do
    [ -z "${epoch:-}" ] && continue
    hhmm="$(epoch_to_hhmm "$epoch")"
    pnum="$(printf '#%-4s' "$prnum")"
    sl="$(printf '%-*s' "$SLUGW" "$slug")"
    LANDED="${LANDED}    ${C_GREEN}✅${C_RESET} ${C_DIM}${pnum}${C_RESET} ${C_GREEN}${sl}${C_RESET} ${C_DIM}${hhmm}${C_RESET}"$'\n'
  done < <(reverse_file "$STATE" | head -3)
}

# render — paint the whole rollup card, but ONLY when the computed frame changed.
render() {
  frame="${HDR_LINE}"$'\n'"${RULE}"$'\n\n'
  frame="${frame}  ${C_DIM}recently landed${C_RESET}"$'\n'"${LANDED}"$'\n'
  frame="${frame}  ${C_DIM}in flight${C_RESET}"$'\n'
  if [ "${#DISPLAY[@]}" -eq 0 ]; then
    frame="${frame}    ${C_DIM}— idle —${C_RESET}"$'\n'
  else
    for line in "${DISPLAY[@]}"; do frame="${frame}${line}"$'\n'; done
  fi
  if [ "$frame" != "$last_frame" ]; then
    clear
    if printf '%b' "$frame"; then last_frame="$frame"; fi
  fi
}

# already_merged <pr#> <slug> — idempotency guard against the persistent state file.
already_merged() {
  [ -s "$STATE" ] || return 1
  grep -q "^[0-9][0-9]* $1 $2\$" "$STATE" 2>/dev/null
}

# _should_automerge <mergeStateStatus> — the pure merge-readiness predicate. GitHub computes
# mergeStateStatus by folding in ALL branch-protection gates, so the watcher auto-merges ONLY when
# it reports CLEAN (every required review/CODEOWNERS approval present, branch up to date, every
# required status check green). Any other state is a HOLD, never a human-action error:
#   BLOCKED  — required reviews / CODEOWNERS not yet satisfied
#   BEHIND   — branch out of date with base
#   UNSTABLE — a required status check is pending or failing
#   plus DIRTY/DRAFT/HAS_HOOKS/UNKNOWN/empty/anything else.
# Returns 0 (merge) ONLY for CLEAN; non-zero (hold, re-evaluate next tick) otherwise.
_should_automerge() {
  [ "${1:-}" = "CLEAN" ]
}

# resolver_attempted <branch> — the resolve-loop guard.
resolver_attempted() {
  [ -s "$RESOLVE_STATE" ] || return 1
  awk -v b="$1" '$4==b{f=1} END{exit !f}' "$RESOLVE_STATE" 2>/dev/null
}

# record_resolve_attempt <pr#> <slug> <branch> — append one spawn record (BEFORE the spawn).
record_resolve_attempt() {
  printf '%s %s %s %s\n' "$(date +%s)" "$1" "$2" "$3" >> "$RESOLVE_STATE"
}

# review_verdict <pr#> <headSha> — the review-once-per-commit guard. Echoes the recorded verdict
# for this exact PR+sha, or nothing if none recorded.
review_verdict() {
  [ -s "$REVIEW_STATE" ] || return 1
  awk -v p="$1" -v s="$2" '$2==p && $3==s{v=$4} END{if(v){print v} else exit 1}' "$REVIEW_STATE" 2>/dev/null
}

# record_review <pr#> <headSha> <verdict> — append one review record (the instant a verdict known).
record_review() {
  printf '%s %s %s %s\n' "$(date +%s)" "$1" "$2" "$3" >> "$REVIEW_STATE"
}

# override_exists <pr#> <headSha> — true if a human override was recorded for this exact pr+sha.
# A new commit changes the sha → override does not carry over.
override_exists() {
  [ -s "$OVERRIDES" ] || return 1
  grep -q "^[0-9]* override $1 $2$" "$OVERRIDES" 2>/dev/null
}

# approval_awaiting_noted <pr#> <headSha> — true if we already recorded an awaiting-approval notice.
approval_awaiting_noted() {
  [ -s "$APPROVALS" ] || return 1
  grep -q "^[0-9]* awaiting $1 $2$" "$APPROVALS" 2>/dev/null
}

# approval_is_approved <pr#> <headSha> — true if herd-approve.sh wrote an explicit approval.
approval_is_approved() {
  [ -s "$APPROVALS" ] || return 1
  grep -q "^[0-9]* approved $1 $2$" "$APPROVALS" 2>/dev/null
}

# record_approval_awaiting <pr#> <headSha> — note gates passed; awaiting human approval.
record_approval_awaiting() {
  printf '%s awaiting %s %s\n' "$(date +%s)" "$1" "$2" >> "$APPROVALS"
}

# observe_noted <pr#> <headSha> — true if we already sent an observe-mode notification.
observe_noted() {
  [ -s "$APPROVALS" ] || return 1
  grep -q "^[0-9]* observed $1 $2$" "$APPROVALS" 2>/dev/null
}

# record_observe_noted <pr#> <headSha> — note that we notified in observe mode.
record_observe_noted() {
  printf '%s observed %s %s\n' "$(date +%s)" "$1" "$2" >> "$APPROVALS"
}

# _merge_method_flag — return the gh pr merge flag for the configured MERGE_METHOD.
_merge_method_flag() {
  case "${MERGE_METHOD:-merge}" in
    squash) printf '%s' '--squash' ;;
    rebase) printf '%s' '--rebase' ;;
    *)      printf '%s' '--merge' ;;
  esac
}

# spawn_resolver <slug> <pr#> <branch> — hand a newly-CONFLICTING PR to the isolated resolver.
# Record-first keeps the loop guard sound; the spawn is best-effort.
spawn_resolver() {
  rs="$1"; rp="$2"; rb="$3"
  record_resolve_attempt "$rp" "$rs" "$rb"
  bash "$HERE/herd-resolve.sh" "$rs" >/dev/null 2>&1 || true
}

# do_merge <slug> <pr#> <worktree> — the safety-railed merge + post-merge sequence.
do_merge() {
  ds="$1"; dp="$2"; dd="$3"
  if [ -n "$DRYRUN" ]; then
    return 0
  fi
  gh pr merge "$dp" "$(_merge_method_flag)" >/dev/null 2>&1 || return 1
  # Record FIRST: even if a later cleanup step dies, we never re-merge this PR.
  printf '%s %s %s\n' "$(date +%s)" "$dp" "$ds" >> "$STATE"
  # 1) enqueue the scribe to reap the backlog item for this slug (slug-match + reap-not-stamp).
  bash "$HERE/scribe.sh" "Reap the backlog item for worktree slug '${ds}' (PR #${dp}): (1) grep ${BACKLOG_FILE} for the line containing '(worktree ${ds})' to locate the exact item; (2) if found, REMOVE that item from its active/thematic section entirely; (3) prepend '- ✅ **<title>** *(PR #${dp})*' (substituting the actual item title) immediately after the '## Recently shipped' heading, then drop any trailing entry beyond the 10th to keep the window capped at ~10; (4) if NO line matches that slug, make NO change and report that there is no backlog item for slug '${ds}'." >/dev/null 2>&1 || true
  # 2) fast-forward the MAIN checkout so coordinator + backlog viewer reflect it. Never force.
  git -C "$MAIN" pull --ff-only >/dev/null 2>&1 || git -C "$MAIN" fetch --all >/dev/null 2>&1 || true
  # 3) remove the worktree (force: the SHARE_LINKS symlinks make a non-force remove fail).
  git -C "$MAIN" worktree remove --force "$dd" >/dev/null 2>&1 || true
  # 4) TEARDOWN is the WATCHER's job — sub-agents NEVER self-close. Close the builder tab,
  #    review tab (review·slug), and resolver tab (resolve·slug) in one shot. Verifies each
  #    close and retries once; warns loudly if a tab cannot be closed.
  herd_teardown_slug "$ds"
  return 0
}

# _sweep_orphan_tabs — close any herd-managed tabs whose slug no longer has a live worktree or
# an open PR. Runs every _ORPHAN_SWEEP_INTERVAL ticks (~60 s). Scoped to this project's
# workspace to avoid touching another project's tabs. Skipped in dry-run mode.
#
# "Herd-managed" means the tab label is one of:
#   review·<slug>   — review-gate visibility tab  (definitely herd-created)
#   resolve·<slug>  — conflict-resolver tab        (definitely herd-created)
#   <slug>          — builder tab (bare slug, no middle dot, not the coordinator label)
#
# A slug is "live" if ANY live worktree has that basename, OR ANY open PR's headRefName ends
# with that slug (last path component). Orphaned = not live → close.
_sweep_orphan_tabs() {
  [ -n "$DRYRUN" ] && return 0
  command -v herdr >/dev/null 2>&1 || return 0
  local _sw_wsid; _sw_wsid="$(herd_resolve_workspace_id 2>/dev/null || true)"
  local _sw_tabs; _sw_tabs="$(herdr tab list 2>/dev/null || true)"
  [ -n "$_sw_tabs" ] || return 0

  # Collect live slugs from worktrees (excluding the main checkout).
  local _sw_wt_json; _sw_wt_json="$(git -C "$MAIN" worktree list --porcelain 2>/dev/null || true)"
  local _sw_wt_slugs
  _sw_wt_slugs="$(WT="$_sw_wt_json" MAIN="$MAIN" python3 -c '
import os
main = os.environ["MAIN"]
for line in os.environ.get("WT","").splitlines():
  if line.startswith("worktree "):
    p = line[9:]
    if p != main:
      print(os.path.basename(p))
' 2>/dev/null || true)"

  # Collect live slugs from open PRs (headRefName last component).
  local _sw_pr_slugs
  _sw_pr_slugs="$(gh pr list --json headRefName 2>/dev/null | python3 -c '
import sys, json
try:
  for p in json.load(sys.stdin):
    b = p.get("headRefName","")
    if b: print(b.split("/")[-1])
except Exception:
  pass
' 2>/dev/null || true)"

  local _sw_live
  _sw_live="$(printf '%s\n%s\n' "$_sw_wt_slugs" "$_sw_pr_slugs" | sort -u | grep -v '^$' || true)"

  # Find orphaned tab IDs and close them. Exclude all per-project singleton tabs
  # (coordinator, scribe, researcher) — they are bare-label tabs with no worktree
  # or PR, so without this exclusion the sweep would kill them every ~60 s.
  local _sw_orphans
  _sw_orphans="$(printf '%s' "$_sw_tabs" \
    | WS="$_sw_wsid" LIVE="$_sw_live" \
      SINGLETONS="${HERD_TAB_COORDINATOR}:${HERD_AGENT_SCRIBE}:${HERD_AGENT_RESEARCHER}" \
      python3 -c '
import sys, json, os
ws         = os.environ.get("WS", "")
live       = set(os.environ.get("LIVE","").split("\n")) - {""}
singletons = set(os.environ.get("SINGLETONS","").split(":")) - {""}
MID        = "·"
try:
  tabs = json.load(sys.stdin).get("result",{}).get("tabs",[])
  for t in tabs:
    label = t.get("label","") or ""
    if not label or label in singletons:
      continue
    if ws and t.get("workspace_id","") != ws:
      continue
    if label.startswith("review" + MID):
      slug = label[len("review" + MID):]
    elif label.startswith("resolve" + MID):
      slug = label[len("resolve" + MID):]
    elif MID not in label:
      slug = label
    else:
      continue
    if slug and slug not in live:
      print(t["tab_id"])
except Exception:
  pass
' 2>/dev/null || true)"

  [ -n "$_sw_orphans" ] || return 0
  local _sw_id
  while IFS= read -r _sw_id; do
    [ -n "$_sw_id" ] || continue
    herdr tab close "$_sw_id" >/dev/null 2>&1 || true
  done <<< "$_sw_orphans"
}

# Sourcing this file (e.g. from the hermetic test) loads the helper functions — including the pure
# merge-decision predicate _should_automerge — WITHOUT entering the live watch loop. Direct
# execution runs the loop normally.
if [ "${AGENT_WATCH_LIB:-}" = "1" ]; then return 0 2>/dev/null || exit 0; fi

# ── Singleton spawn-lock: exactly one watcher per project ──────────────────────────────────────
# Keyed by WORKSPACE_NAME (matching the coordinator/scribe/researcher pattern). Prevents duplicate
# launchers from racing on 'gh pr merge' when the coordinator is relaunched. Stale locks (PID dead
# from a crashed/ended session) are reaped automatically so the next launch can take over.
#
# Two mechanisms, one per environment:
#   • flock(1) available  — non-blocking exclusive lock (fd 9) held for our lifetime; auto-released
#                           on any exit (fd close). A second watcher's flock -n fails immediately.
#   • no flock (macOS)    — atomic-mkdir mutex guards the check+write, then a PID file is held for
#                           our lifetime and removed on EXIT/INT/TERM.
mkdir -p "$(dirname "$HERD_WATCHER_LOCK")" 2>/dev/null || true
if command -v flock >/dev/null 2>&1; then
  exec 9>"$HERD_WATCHER_LOCK"
  if ! flock -n 9; then
    printf '🐑 watcher already running for %s — exiting.\n' "$WORKSPACE_NAME" >&2; exit 0
  fi
  printf '%s\n' "$$" >"$HERD_WATCHER_LOCK"   # informational PID for diagnostics
else
  # Atomic-mkdir mutex (serializes the check+write window; held only for that instant).
  _wl_mtx="${HERD_WATCHER_LOCK}.d"
  _wl_tries=0
  while ! mkdir "$_wl_mtx" 2>/dev/null; do
    [ -z "$(find "$_wl_mtx" -prune -mmin -1 2>/dev/null)" ] && { rmdir "$_wl_mtx" 2>/dev/null || true; continue; }
    _wl_tries=$((_wl_tries + 1)); [ "$_wl_tries" -ge 30 ] && break; sleep 0.1
  done
  _wl_pid="$(cat "$HERD_WATCHER_LOCK" 2>/dev/null || true)"
  if [ -n "$_wl_pid" ] && kill -0 "$_wl_pid" 2>/dev/null; then
    rmdir "$_wl_mtx" 2>/dev/null || true
    printf '🐑 watcher already running for %s (PID %s) — exiting.\n' "$WORKSPACE_NAME" "$_wl_pid" >&2; exit 0
  fi
  # Stale or absent lock: write our PID (temp+mv for atomicity so readers never see a partial write).
  _wl_tmp="${HERD_WATCHER_LOCK}.$$"
  printf '%s\n' "$$" >"$_wl_tmp"; mv "$_wl_tmp" "$HERD_WATCHER_LOCK"
  rmdir "$_wl_mtx" 2>/dev/null || true
  unset _wl_mtx _wl_tries _wl_pid _wl_tmp
  # Clean up the PID file on exit — but ONLY if it still contains our own PID.
  # If cmd_reload confirms us dead, removes our lock, and relaunches a new watcher,
  # the new watcher writes its PID before we exit; our EXIT trap must not clobber it.
  _watcher_lock_cleanup() {
    [ "$(cat "$HERD_WATCHER_LOCK" 2>/dev/null)" = "$$" ] \
      && rm -f "$HERD_WATCHER_LOCK" 2>/dev/null || true
  }
  trap '_watcher_lock_cleanup' EXIT
  trap '_watcher_lock_cleanup; exit 1' INT TERM
fi
# ───────────────────────────────────────────────────────────────────────────────────────────────

_ORPHAN_SWEEP_TICK=0
_ORPHAN_SWEEP_INTERVAL=15   # sweep every ~60 s (15 × 4 s sleep)

while true; do
  build_header
  build_landed

  PRS_JSON="$(gh pr list --json number,title,headRefName,mergeable,mergeStateStatus 2>/dev/null || echo '[]')"
  AGENTS_JSON="$(herdr agent list 2>/dev/null || echo '{}')"
  WT="$(git -C "$MAIN" worktree list --porcelain 2>/dev/null || echo '')"

  # Parse worktrees + match each to its open PR and its agent, emitting one tab-separated record
  # per active feature worktree (the main checkout excluded).
  FEATS=()
  while IFS= read -r rec; do
    [ -n "$rec" ] && FEATS+=("$rec")
  done < <(PRS_JSON="$PRS_JSON" AGENTS_JSON="$AGENTS_JSON" WT="$WT" MAIN="$MAIN" python3 -c '
import os, json
MAIN = os.environ["MAIN"]
try: prs = json.loads(os.environ.get("PRS_JSON") or "[]")
except Exception: prs = []
try: agents = (json.loads(os.environ.get("AGENTS_JSON") or "{}").get("result") or {}).get("agents") or []
except Exception: agents = []
pr_by_branch = {p.get("headRefName"): p for p in prs}
ag_status = {a.get("name"): a.get("agent_status") for a in agents if a.get("name")}
feats = []; wt = None; branch = None
for line in (os.environ.get("WT") or "").splitlines():
    if line.startswith("worktree "): wt = line[9:]; branch = None
    elif line.startswith("branch "): branch = line[7:].replace("refs/heads/", "")
    elif line == "":
        if wt and wt != MAIN: feats.append((wt, branch))
        wt = None; branch = None
if wt and wt != MAIN: feats.append((wt, branch))
for wt, branch in feats:
    slug = os.path.basename(wt)
    pr = pr_by_branch.get(branch or "", {})
    print("\x1f".join(str(x) for x in [
        wt, slug, branch or "", pr.get("number", ""),
        pr.get("mergeable", ""), pr.get("mergeStateStatus", ""),
        ag_status.get(slug, "")]))
')

  # Classify each feature into a display line; collect merge candidates separately.
  DISPLAY=()
  CAND_IDX=(); CAND_DIR=(); CAND_SLUG=(); CAND_PR=(); CAND_BRANCH=()
  CONF_IDX=(); CONF_SLUG=(); CONF_PR=(); CONF_BRANCH=()
  i=0
  for rec in ${FEATS[@]+"${FEATS[@]}"}; do
    IFS=$'\037' read -r dir slug branch prnum mergeable mstate astatus <<EOF
$rec
EOF
    sl="$(printf '%-*s' "$SLUGW" "$slug")"
    pn=""; [ -n "$prnum" ] && pn=" ${C_DIM}#${prnum}${C_RESET} ·"
    if [ -z "$prnum" ]; then
      if [ "$astatus" != "working" ]; then
        DISPLAY[i]="    ${C_BLUE}🔨${C_RESET} ${C_BOLD}${sl}${C_RESET} ${C_BLUE}idle · no PR${C_RESET}"
      else
        # Stall detection: agent is "working" but has made zero commits for >5 min —
        # likely stuck on the folder-trust gate or a permissions prompt. Surface a
        # warning so the user knows to check the pane. The threshold avoids false
        # positives on agents that spend a few minutes reading before their first commit.
        _born="$(stat -f '%B' "$dir" 2>/dev/null || echo 0)"
        _age=$(( $(date +%s) - _born ))
        _commits="$(git -C "$dir" rev-list HEAD --count --not "$DEFAULT_BRANCH" 2>/dev/null || echo 0)"
        if [ "$_age" -gt 300 ] && [ "${_commits:-0}" -eq 0 ]; then
          _mins=$(( _age / 60 ))
          DISPLAY[i]="    ${C_YELLOW}⚠️${C_RESET}  ${C_BOLD}${sl}${C_RESET} ${C_YELLOW}stalled? · 0 commits (${_mins}m) · check pane${C_RESET}"
        else
          DISPLAY[i]="    ${C_BLUE}🔨${C_RESET} ${C_BOLD}${sl}${C_RESET} ${C_BLUE}building${C_RESET}"
        fi
      fi
    elif [ "$dir" = "$SELF_WT" ]; then
      DISPLAY[i]="    ${C_DIM}🐑 ${sl} self · won't auto-merge${C_RESET}"
    elif [ "$mergeable" = "MERGEABLE" ] && _should_automerge "$mstate"; then
      DISPLAY[i]="    ${C_YELLOW}🩺${C_RESET} ${C_BOLD}${sl}${C_RESET}${pn} ${C_YELLOW}health-check${C_RESET}"
      CAND_IDX+=("$i"); CAND_DIR+=("$dir"); CAND_SLUG+=("$slug"); CAND_PR+=("$prnum"); CAND_BRANCH+=("$branch")
    elif [ "$mergeable" = "UNKNOWN" ] || [ "$mstate" = "UNKNOWN" ] || [ -z "$mergeable" ]; then
      DISPLAY[i]="    ${C_DIM}🔍${C_RESET} ${C_DIM}${sl}${C_RESET}${pn} ${C_DIM}verifying mergeability…${C_RESET}"
    elif [ "$mergeable" = "CONFLICTING" ]; then
      if resolver_attempted "$branch"; then
        DISPLAY[i]="    ${C_RED}⚠️${C_RESET} ${C_BOLD}${sl}${C_RESET}${pn} ${C_RED}needs you · resolver failed${C_RESET}"
      else
        DISPLAY[i]="    ${C_RED}⚠️${C_RESET} ${C_BOLD}${sl}${C_RESET}${pn} ${C_RED}needs you · conflict${C_RESET}"
        CONF_IDX+=("$i"); CONF_SLUG+=("$slug"); CONF_PR+=("$prnum"); CONF_BRANCH+=("$branch")
      fi
    elif [ "$mergeable" = "MERGEABLE" ]; then
      # MERGEABLE (no conflict) but mergeStateStatus != CLEAN: branch-protection gates aren't
      # satisfied yet — BLOCKED (required reviews/CODEOWNERS), BEHIND (out of date), or UNSTABLE
      # (pending/failing required checks). Do NOT merge; soft-hold and re-evaluate next tick. This
      # is transient, NOT a human-action error, so no ⚠️ "needs you".
      DISPLAY[i]="    ${C_YELLOW}⏸${C_RESET}  ${C_BOLD}${sl}${C_RESET}${pn} ${C_YELLOW}blocked · awaiting required checks/reviews (${mstate:-?})${C_RESET}"
    else
      reason="not mergeable (${mstate})"
      DISPLAY[i]="    ${C_RED}⚠️${C_RESET} ${C_BOLD}${sl}${C_RESET}${pn} ${C_RED}needs you · ${reason}${C_RESET}"
    fi
    i=$((i + 1))
  done

  render

  # Action pass: gate + auto-merge each CLEAN/MERGEABLE candidate.
  j=0
  for idx in ${CAND_IDX[@]+"${CAND_IDX[@]}"}; do
    dir="${CAND_DIR[j]}"; slug="${CAND_SLUG[j]}"; prnum="${CAND_PR[j]}"; branch="${CAND_BRANCH[j]}"; j=$((j + 1))
    already_merged "$prnum" "$slug" && continue
    sl="$(printf '%-*s' "$SLUGW" "$slug")"
    pn=" ${C_DIM}#${prnum}${C_RESET} ·"

    DISPLAY[idx]="    ${C_YELLOW}🩺${C_RESET} ${C_BOLD}${sl}${C_RESET}${pn} ${C_YELLOW}health-check${C_RESET}"
    render
    hc="$(bash "$HERE/healthcheck.sh" "$dir" --oneline 2>/dev/null)"; rc=$?
    if [ "$rc" -ne 0 ]; then
      DISPLAY[idx]="    ${C_RED}⚠️${C_RESET} ${C_BOLD}${sl}${C_RESET}${pn} ${C_RED}needs you · ${hc}${C_RESET}"
      render
      continue
    fi

    if [ -n "$DRYRUN" ]; then
      DISPLAY[idx]="    ${C_DIM}🔬${C_RESET} ${C_DIM}${sl}${C_RESET}${pn} ${C_DIM}[dry-run] would review PR #${prnum} (then merge on PASS)${C_RESET}"
      render
      continue
    fi

    # Re-verify in the instant before merging — guard the window between classification and merge.
    IFS=$'\t' read -r rmergeable rmstate rbranch rsha < <(
      gh pr view "$prnum" --json mergeable,mergeStateStatus,headRefName,headRefOid 2>/dev/null | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: d = {}
print("\t".join([str(d.get("mergeable","")), str(d.get("mergeStateStatus","")), str(d.get("headRefName","")), str(d.get("headRefOid",""))]))
')
    if [ "$rbranch" != "$branch" ]; then
      DISPLAY[idx]="    ${C_RED}⚠️${C_RESET} ${C_BOLD}${sl}${C_RESET}${pn} ${C_RED}needs you · PR #${prnum} no longer maps to ${branch}${C_RESET}"
      render
      continue
    fi
    if [ "$rmergeable" != "MERGEABLE" ] || ! _should_automerge "$rmstate"; then
      if [ "$rmergeable" = "MERGEABLE" ]; then
        # Still conflict-free but a gate regressed since classification (e.g. a required check went
        # pending, or the branch fell BEHIND): soft-hold, re-evaluate next tick — not a ⚠️.
        DISPLAY[idx]="    ${C_YELLOW}⏸${C_RESET}  ${C_BOLD}${sl}${C_RESET}${pn} ${C_YELLOW}blocked · awaiting required checks/reviews (${rmstate:-?})${C_RESET}"
      else
        if [ "$rmergeable" = "CONFLICTING" ]; then rreason="conflict"; else rreason="${rmstate:-unknown}"; fi
        DISPLAY[idx]="    ${C_RED}⚠️${C_RESET} ${C_BOLD}${sl}${C_RESET}${pn} ${C_RED}needs you · changed under us · ${rreason}${C_RESET}"
      fi
      render
      continue
    fi

    # PRE-MERGE ADVERSARIAL REVIEW GATE. Keyed by PR + head sha so each commit is reviewed once.
    if [ -z "$rsha" ]; then
      DISPLAY[idx]="    ${C_DIM}🔬${C_RESET} ${C_DIM}${sl}${C_RESET}${pn} ${C_DIM}awaiting head sha for review…${C_RESET}"
      render
      continue
    fi
    prior="$(review_verdict "$prnum" "$rsha" || true)"
    if [ "$prior" = "BLOCK" ]; then
      if override_exists "$prnum" "$rsha"; then
        # Human override recorded for this sha — treat as PASS and proceed to merge path.
        prior="PASS"
      else
        DISPLAY[idx]="    ${C_RED}⚠️${C_RESET} ${C_BOLD}${sl}${C_RESET}${pn} ${C_RED}review blocked · see PR #${prnum} comment · herd-approve.sh why ${prnum}${C_RESET}"$'\n'"       ${C_DIM}└─ new commit auto-re-reviews · override: herd-approve.sh override ${prnum}${C_RESET}"
        render
        continue
      fi
    fi
    if [ "$prior" != "PASS" ]; then
      DISPLAY[idx]="    ${C_YELLOW}🔬${C_RESET} ${C_BOLD}${sl}${C_RESET}${pn} ${C_YELLOW}reviewing…${C_RESET}"
      render
      verdict_line="$(bash "$HERE/herd-review.sh" "$prnum" "$slug" 2>/dev/null | grep -E '^REVIEW: (PASS|BLOCK|INFRA-FAIL)' | tail -1)"
      case "$verdict_line" in
        "REVIEW: PASS")        verdict="PASS" ;;
        "REVIEW: BLOCK"*)      verdict="BLOCK" ;;
        "REVIEW: INFRA-FAIL"*) verdict="INFRA-FAIL" ;;
        *)                     verdict="BLOCK" ;;
      esac
      # INFRA-FAIL means the reviewer could not run — transient, not a real finding. Do NOT persist
      # it to the ledger (that would permanently wedge the PR). Surface for retry next cycle.
      if [ "$verdict" = "INFRA-FAIL" ]; then
        DISPLAY[idx]="    ${C_YELLOW}🔬${C_RESET} ${C_BOLD}${sl}${C_RESET}${pn} ${C_YELLOW}review errored · will retry${C_RESET}"
        render
        continue
      fi
      record_review "$prnum" "$rsha" "$verdict"
      if [ "$verdict" != "PASS" ]; then
        DISPLAY[idx]="    ${C_RED}⚠️${C_RESET} ${C_BOLD}${sl}${C_RESET}${pn} ${C_RED}review blocked · see PR #${prnum} comment · herd-approve.sh why ${prnum}${C_RESET}"$'\n'"       ${C_DIM}└─ new commit auto-re-reviews · override: herd-approve.sh override ${prnum}${C_RESET}"
        render
        continue
      fi
    fi
    # PASS (just now, or recorded for this sha) → proceed based on effective merge policy.

    if [ -n "$MERGE_OBSERVE" ]; then
      # observe: run all gates, report + notify once per sha, NEVER merge.
      if ! observe_noted "$prnum" "$rsha"; then
        record_observe_noted "$prnum" "$rsha"
        herdr notification show "🐑 PR #${prnum} ready (observe)" --body "${slug}: review passed — observe mode, not merging" --sound default >/dev/null 2>&1 || true
      fi
      DISPLAY[idx]="    ${C_GREEN}✅${C_RESET} ${C_BOLD}${sl}${C_RESET}${pn} ${C_GREEN}ready · observe mode${C_RESET}"
      render
      continue
    fi

    if [ -z "$AUTOMERGE" ]; then
      # approve: require explicit sha-keyed human approval before merging.
      if approval_is_approved "$prnum" "$rsha"; then
        DISPLAY[idx]="    ${C_YELLOW}⏳${C_RESET} ${C_BOLD}${sl}${C_RESET}${pn} ${C_YELLOW}merging (approved)${C_RESET}"
        render
        do_merge "$slug" "$prnum" "$dir"
        continue
      fi
      # First time gates pass for this sha: record + notify, then hold until approved.
      if ! approval_awaiting_noted "$prnum" "$rsha"; then
        record_approval_awaiting "$prnum" "$rsha"
        gh pr comment "$prnum" --body "🐑 **herd watch** · all gates passed (healthcheck ✅ · review ✅) · awaiting approval before merge.

Run \`herd approve ${prnum}\` (or \`bash scripts/herd/herd-approve.sh approve ${prnum}\`) to approve commit \`${rsha:0:8}\` for merge." >/dev/null 2>&1 || true
        herdr notification show "🐑 PR #${prnum} awaiting approval" --body "${slug}: gates passed — herd approve ${prnum}" --sound default >/dev/null 2>&1 || true
      fi
      DISPLAY[idx]="    ${C_GREEN}✅${C_RESET} ${C_BOLD}${sl}${C_RESET}${pn} ${C_GREEN}ready · awaiting approval${C_RESET}"
      render
      continue
    fi

    DISPLAY[idx]="    ${C_YELLOW}⏳${C_RESET} ${C_BOLD}${sl}${C_RESET}${pn} ${C_YELLOW}merging${C_RESET}"
    render
    do_merge "$slug" "$prnum" "$dir"
  done

  # Resolve pass: auto-spawn the isolated conflict resolver for each NEWLY-conflicting PR.
  k=0
  for idx in ${CONF_IDX[@]+"${CONF_IDX[@]}"}; do
    slug="${CONF_SLUG[k]}"; prnum="${CONF_PR[k]}"; branch="${CONF_BRANCH[k]}"; k=$((k + 1))
    sl="$(printf '%-*s' "$SLUGW" "$slug")"
    pn=" ${C_DIM}#${prnum}${C_RESET} ·"
    if [ -n "$DRYRUN" ]; then
      DISPLAY[idx]="    ${C_DIM}🔀${C_RESET} ${C_DIM}${sl}${C_RESET}${pn} ${C_DIM}[dry-run] would spawn resolver for PR #${prnum}${C_RESET}"
      render
      continue
    fi
    DISPLAY[idx]="    ${C_YELLOW}🔀${C_RESET} ${C_BOLD}${sl}${C_RESET}${pn} ${C_YELLOW}resolving conflict…${C_RESET}"
    render
    spawn_resolver "$slug" "$prnum" "$branch"
  done

  # Orphan sweep: every _ORPHAN_SWEEP_INTERVAL ticks close tabs whose slug is no longer live.
  _ORPHAN_SWEEP_TICK=$((_ORPHAN_SWEEP_TICK + 1))
  if [ "$_ORPHAN_SWEEP_TICK" -ge "$_ORPHAN_SWEEP_INTERVAL" ]; then
    _ORPHAN_SWEEP_TICK=0
    _sweep_orphan_tabs
  fi

  sleep 4
done
