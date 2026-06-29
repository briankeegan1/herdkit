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
# WATCHER_AUTOMERGE (.herd/config, default "true"): when "false"/"no"/"off"/"0" the watcher runs
# the full healthcheck + review pipeline but FLAGS the PR for human merge instead of merging
# automatically — the human-in-the-loop lever.
#
# DRY-RUN: AGENT_WATCH_DRYRUN=1 does everything EXCEPT the real merge / worktree remove / scribe /
# ff-pull, and never spawns the reviewer/resolver or writes their state files.
#
# Renders ONLY when the computed frame changes — an idle pane never repaints. Polls every ~4s.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
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
# Only truthy values enable dry-run. Treat "0"/""/"false"/"no" as live.
case "${AGENT_WATCH_DRYRUN:-}" in 1|true|yes|on) DRYRUN=1 ;; *) DRYRUN="" ;; esac
# WATCHER_AUTOMERGE (from .herd/config, default "true"): when falsey, run the full pipeline but
# flag the PR for human merge instead of merging automatically.
case "${WATCHER_AUTOMERGE:-true}" in false|no|off|0) AUTOMERGE="" ;; *) AUTOMERGE=1 ;; esac
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
    hhmm="$(date -r "$epoch" +%H:%M 2>/dev/null || echo '--:--')"
    pnum="$(printf '#%-4s' "$prnum")"
    sl="$(printf '%-*s' "$SLUGW" "$slug")"
    LANDED="${LANDED}    ${C_GREEN}✅${C_RESET} ${C_DIM}${pnum}${C_RESET} ${C_GREEN}${sl}${C_RESET} ${C_DIM}${hhmm}${C_RESET}"$'\n'
  done < <(tail -r "$STATE" 2>/dev/null | head -3)
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
  gh pr merge "$dp" --merge >/dev/null 2>&1 || return 1
  # Record FIRST: even if a later cleanup step dies, we never re-merge this PR.
  printf '%s %s %s\n' "$(date +%s)" "$dp" "$ds" >> "$STATE"
  # 1) enqueue the scribe to reap the backlog item for this slug (slug-match + reap-not-stamp).
  bash "$HERE/scribe.sh" "Reap the backlog item for worktree slug '${ds}' (PR #${dp}): (1) grep ${BACKLOG_FILE} for the line containing '(worktree ${ds})' to locate the exact item; (2) if found, REMOVE that item from its active/thematic section entirely; (3) prepend '- ✅ **<title>** *(PR #${dp})*' (substituting the actual item title) immediately after the '## Recently shipped' heading, then drop any trailing entry beyond the 10th to keep the window capped at ~10; (4) if NO line matches that slug, make NO change and report that there is no backlog item for slug '${ds}'." >/dev/null 2>&1 || true
  # 2) fast-forward the MAIN checkout so coordinator + backlog viewer reflect it. Never force.
  git -C "$MAIN" pull --ff-only >/dev/null 2>&1 || git -C "$MAIN" fetch --all >/dev/null 2>&1 || true
  # 3) remove the worktree (force: the SHARE_LINKS symlinks make a non-force remove fail).
  git -C "$MAIN" worktree remove --force "$dd" >/dev/null 2>&1 || true
  # 4) TEARDOWN is the WATCHER's job — sub-agents NEVER self-close. Closing the herdr tab
  #    terminates the agent's pane (and process). Best-effort each.
  tabid="$(herdr tab list 2>/dev/null | SLUG="$ds" python3 -c 'import sys,json,os
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
print(next((t["tab_id"] for t in d.get("result",{}).get("tabs",[]) if t.get("label")==os.environ["SLUG"]), ""))' 2>/dev/null)"
  [ -n "$tabid" ] && herdr tab close "$tabid" >/dev/null 2>&1 || true
  return 0
}

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
    if [ -z "$prnum" ]; then
      word="building"; [ "$astatus" != "working" ] && word="idle · no PR"
      DISPLAY[i]="    ${C_BLUE}🔨${C_RESET} ${C_BOLD}${sl}${C_RESET} ${C_BLUE}${word}${C_RESET}"
    elif [ "$dir" = "$SELF_WT" ]; then
      DISPLAY[i]="    ${C_DIM}🐑 ${sl} self · won't auto-merge${C_RESET}"
    elif [ "$mergeable" = "MERGEABLE" ] && [ "$mstate" = "CLEAN" ]; then
      DISPLAY[i]="    ${C_YELLOW}🩺${C_RESET} ${C_BOLD}${sl}${C_RESET} ${C_YELLOW}health-check${C_RESET}"
      CAND_IDX+=("$i"); CAND_DIR+=("$dir"); CAND_SLUG+=("$slug"); CAND_PR+=("$prnum"); CAND_BRANCH+=("$branch")
    elif [ "$mergeable" = "UNKNOWN" ] || [ "$mstate" = "UNKNOWN" ] || [ -z "$mergeable" ]; then
      DISPLAY[i]="    ${C_DIM}🔍 ${sl} verifying mergeability…${C_RESET}"
    elif [ "$mergeable" = "CONFLICTING" ]; then
      if resolver_attempted "$branch"; then
        DISPLAY[i]="    ${C_RED}⚠️${C_RESET} ${C_BOLD}${sl}${C_RESET} ${C_RED}needs you · resolver failed${C_RESET}"
      else
        DISPLAY[i]="    ${C_RED}⚠️${C_RESET} ${C_BOLD}${sl}${C_RESET} ${C_RED}needs you · conflict${C_RESET}"
        CONF_IDX+=("$i"); CONF_SLUG+=("$slug"); CONF_PR+=("$prnum"); CONF_BRANCH+=("$branch")
      fi
    else
      reason="not mergeable (${mstate})"
      DISPLAY[i]="    ${C_RED}⚠️${C_RESET} ${C_BOLD}${sl}${C_RESET} ${C_RED}needs you · ${reason}${C_RESET}"
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

    DISPLAY[idx]="    ${C_YELLOW}🩺${C_RESET} ${C_BOLD}${sl}${C_RESET} ${C_YELLOW}health-check${C_RESET}"
    render
    hc="$(bash "$HERE/healthcheck.sh" "$dir" --oneline 2>/dev/null)"; rc=$?
    if [ "$rc" -ne 0 ]; then
      DISPLAY[idx]="    ${C_RED}⚠️${C_RESET} ${C_BOLD}${sl}${C_RESET} ${C_RED}needs you · ${hc}${C_RESET}"
      render
      continue
    fi

    if [ -n "$DRYRUN" ]; then
      DISPLAY[idx]="    ${C_DIM}🔬 ${sl} [dry-run] would review PR #${prnum} (then merge on PASS)${C_RESET}"
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
      DISPLAY[idx]="    ${C_RED}⚠️${C_RESET} ${C_BOLD}${sl}${C_RESET} ${C_RED}needs you · PR #${prnum} no longer maps to ${branch}${C_RESET}"
      render
      continue
    fi
    if [ "$rmergeable" != "MERGEABLE" ] || [ "$rmstate" != "CLEAN" ]; then
      if [ "$rmergeable" = "CONFLICTING" ]; then rreason="conflict"; else rreason="${rmstate:-unknown}"; fi
      DISPLAY[idx]="    ${C_RED}⚠️${C_RESET} ${C_BOLD}${sl}${C_RESET} ${C_RED}needs you · changed under us · ${rreason}${C_RESET}"
      render
      continue
    fi

    # PRE-MERGE ADVERSARIAL REVIEW GATE. Keyed by PR + head sha so each commit is reviewed once.
    if [ -z "$rsha" ]; then
      DISPLAY[idx]="    ${C_DIM}🔬 ${sl} awaiting head sha for review…${C_RESET}"
      render
      continue
    fi
    prior="$(review_verdict "$prnum" "$rsha" || true)"
    if [ "$prior" = "BLOCK" ]; then
      DISPLAY[idx]="    ${C_RED}⚠️${C_RESET} ${C_BOLD}${sl}${C_RESET} ${C_RED}needs you · review blocked${C_RESET}"
      render
      continue
    elif [ "$prior" != "PASS" ]; then
      DISPLAY[idx]="    ${C_YELLOW}🔬${C_RESET} ${C_BOLD}${sl}${C_RESET} ${C_YELLOW}reviewing…${C_RESET}"
      render
      verdict_line="$(bash "$HERE/herd-review.sh" "$prnum" "$slug" 2>/dev/null | grep -E '^REVIEW: (PASS|BLOCK)' | tail -1)"
      case "$verdict_line" in
        "REVIEW: PASS") verdict="PASS" ;;
        "REVIEW: BLOCK"*) verdict="BLOCK" ;;
        *) verdict="BLOCK" ;;
      esac
      record_review "$prnum" "$rsha" "$verdict"
      if [ "$verdict" != "PASS" ]; then
        DISPLAY[idx]="    ${C_RED}⚠️${C_RESET} ${C_BOLD}${sl}${C_RESET} ${C_RED}needs you · review blocked${C_RESET}"
        render
        continue
      fi
    fi
    # PASS (just now, or recorded for this sha) → merge, or flag for human if AUTOMERGE=false.

    if [ -z "$AUTOMERGE" ]; then
      DISPLAY[idx]="    ${C_GREEN}✅${C_RESET} ${C_BOLD}${sl}${C_RESET} ${C_GREEN}ready · awaiting human merge${C_RESET}"
      render
      herdr notification show "🐑 PR #${prnum} ready to merge" --body "${slug}: review passed — merge when ready" --sound default >/dev/null 2>&1 || true
      continue
    fi

    DISPLAY[idx]="    ${C_YELLOW}⏳${C_RESET} ${C_BOLD}${sl}${C_RESET} ${C_YELLOW}merging${C_RESET}"
    render
    do_merge "$slug" "$prnum" "$dir"
  done

  # Resolve pass: auto-spawn the isolated conflict resolver for each NEWLY-conflicting PR.
  k=0
  for idx in ${CONF_IDX[@]+"${CONF_IDX[@]}"}; do
    slug="${CONF_SLUG[k]}"; prnum="${CONF_PR[k]}"; branch="${CONF_BRANCH[k]}"; k=$((k + 1))
    sl="$(printf '%-*s' "$SLUGW" "$slug")"
    if [ -n "$DRYRUN" ]; then
      DISPLAY[idx]="    ${C_DIM}🔀 ${sl} [dry-run] would spawn resolver for PR #${prnum}${C_RESET}"
      render
      continue
    fi
    DISPLAY[idx]="    ${C_YELLOW}🔀${C_RESET} ${C_BOLD}${sl}${C_RESET} ${C_YELLOW}resolving conflict…${C_RESET}"
    render
    spawn_resolver "$slug" "$prnum" "$branch"
  done

  sleep 4
done
