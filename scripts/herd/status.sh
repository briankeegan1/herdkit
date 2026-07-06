#!/usr/bin/env bash
# status.sh — pure helpers + the orchestrator behind `herd status`, a ONE-SHOT, READ-ONLY,
# human-and-cron-friendly control-room health snapshot for THIS project. Sourced by bin/herd
# (cmd_status) AFTER .herd/config is loaded; also standalone-sourceable for the hermetic test
# (tests/test-status.sh), which drives ONLY the pure classifiers/ledger-readers below.
#
# It NEVER mutates anything — no tree, ledger, tab, PR, or dead-builder record. It only READS:
#   • the watcher liveness (bin/herd's _list_project_watchers — lockfile ∪ herd-watch-<slug> argv0
#     marker — with a self-contained argv0 pgrep fallback when sourced standalone);
#   • `git worktree list` + `herdr agent list` + `gh pr list` to enumerate in-flight builders;
#   • the watcher's OWN append-only ledgers ($WORKTREES_DIR/.agent-watch-reviewed and
#     .agent-watch-healthchecks) for the last review/health verdict — never writing them;
#   • the backlog file (file backend) for open/in-progress counts.
#
# The DEAD-builder check here is a SMALL, INDEPENDENT, read-only replica of the watcher's DEAD
# signature (worktree present + NO live agent + NO open PR + NO commits) — it does NOT call into or
# edit agent-watch.sh (which owns the grace-window ledger + the 💀 notification). A one-shot snapshot
# has no cross-tick memory, so it flags the plain signature deterministically.
#
# Uses say / the colour vars from bin/herd at CALL time (bash late-binds), and every colour is
# referenced with a ${x:-} default so a standalone `set -u` source (the test) never trips on an
# unset colour name.

# ── Pure classifiers (unit-tested by tests/test-status.sh) ───────────────────────────────────────

# _status_classify_builder <has_agent 0|1> <agent_status> <has_pr 0|1> <commits> — the deterministic
# bucket for one feature worktree. Echoes exactly one token:
#   dead     — no live agent record + no open PR + zero commits: the watcher's DEAD signature,
#              replicated READ-ONLY (a silently-exited pre-PR builder that produced nothing).
#   building — a live agent is WORKING on it (no PR yet).
#   done     — an open PR exists, the agent reports done, OR commits were produced (work landed;
#              the agent may have legitimately exited).
#   idle     — a live agent is present but not working and has produced no PR/commits yet.
_status_classify_builder() {
  local has_agent="${1:-0}" astatus="${2:-}" has_pr="${3:-0}" commits="${4:-0}"
  case "$commits" in ''|*[!0-9]*) commits=0 ;; esac
  # An open PR is an unambiguous liveness signal — the builder reached its finish line.
  [ "$has_pr" = "1" ] && { printf 'done'; return 0; }
  if [ "$has_agent" = "1" ]; then
    case "$astatus" in
      working) printf 'building'; return 0 ;;
      done)    printf 'done';     return 0 ;;
    esac
    # Present but idle/other: done if it already produced commits, else genuinely idle.
    [ "$commits" -gt 0 ] && { printf 'done'; return 0; }
    printf 'idle'; return 0
  fi
  # No agent record at all — the dead signature UNLESS commits were already produced.
  [ "$commits" -gt 0 ] && { printf 'done'; return 0; }
  printf 'dead'
}

# _status_latest_review <ledger-file> <pr> <sha> — echo the MOST-RECENT recorded review verdict
# (PASS|BLOCK) for this exact PR+sha from the watcher's append-only review ledger
# ($WORKTREES_DIR/.agent-watch-reviewed, "<epoch> <pr> <sha> <verdict> <source>"). Empty when none.
# The ledger is append-only in chronological order, so the last matching row is the latest verdict.
_status_latest_review() {
  local f="$1" pr="$2" sha="$3"
  [ -s "$f" ] || return 0
  awk -v p="$pr" -v s="$sha" '$2==p && $3==s{v=$4} END{if(v!="")print v}' "$f" 2>/dev/null || true
}

# _status_latest_health <ledger-file> <pr> — echo the MOST-RECENT healthcheck outcome
# (clean|dataenv|code-error|flaky-pass) for this PR from the watcher's append-only health ledger
# ($WORKTREES_DIR/.agent-watch-healthchecks, "<epoch> <pr> <slug> <attempt> <outcome>"). Empty when
# none. Last matching row = latest attempt.
_status_latest_health() {
  local f="$1" pr="$2"
  [ -s "$f" ] || return 0
  awk -v p="$pr" '$2==p{o=$5} END{if(o!="")print o}' "$f" 2>/dev/null || true
}

# _status_pr_attention <mergeable> <review_verdict> <reviewDecision> — echo 1 when this PR needs a
# HUMAN (CONFLICTING branch, a recorded review BLOCK, or GitHub reviewDecision CHANGES_REQUESTED),
# else 0. Pure; the caller ORs it into the snapshot's exit code.
_status_pr_attention() {
  local mergeable="${1:-}" review="${2:-}" decision="${3:-}"
  [ "$mergeable" = "CONFLICTING" ]        && { printf 1; return 0; }
  [ "$review" = "BLOCK" ]                 && { printf 1; return 0; }
  [ "$decision" = "CHANGES_REQUESTED" ]   && { printf 1; return 0; }
  printf 0
}

# _status_backlog_counts <backlog-file> — echo "<open> <in-progress>" for the FILE backend: open =
# 🔜 queued items, in-progress = 🚧 items (the same emoji state markers backends/file.sh reads).
# "0 0" when the file is absent/empty. Pure over the file; hermetic-testable.
_status_backlog_counts() {
  local f="$1" open=0 inprog=0
  if [ -f "$f" ]; then
    # grep -c prints the count AND exits 1 on zero matches; `|| true` keeps that "0" (never a second
    # one) and keeps the command substitution exit 0 under the caller's set -e.
    open="$(grep -c '🔜' "$f" 2>/dev/null || true)";  open="${open:-0}"
    inprog="$(grep -c '🚧' "$f" 2>/dev/null || true)"; inprog="${inprog:-0}"
  fi
  printf '%s %s' "$open" "$inprog"
}

# ── Watcher liveness ─────────────────────────────────────────────────────────────────────────────

# _status_watcher_pids — one PID per line for THIS project's live watcher(s). Prefers bin/herd's
# _list_project_watchers (lockfile ∪ exact herd-watch-<slug> argv0 marker) when it is in scope;
# falls back to a self-contained argv0-EXACT pgrep so status.sh still works sourced standalone.
# READ-ONLY: it only reads the lockfile + ps/pgrep, never signals anything.
_status_watcher_pids() {
  if declare -f _list_project_watchers >/dev/null 2>&1; then
    _list_project_watchers 2>/dev/null || true
    return 0
  fi
  command -v pgrep >/dev/null 2>&1 || return 0
  local marker="${HERD_WATCH_ARGV0:-herd-watch-${WORKSPACE_NAME:-project}}" pid a0
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    a0="$(ps -o command= -p "$pid" 2>/dev/null | awk 'NR==1{print $1}' || true)"
    [ "$a0" = "$marker" ] && printf '%s\n' "$pid"
  done < <(pgrep -f "$marker" 2>/dev/null || true)
}

# ── Orchestrator ─────────────────────────────────────────────────────────────────────────────────

# _status_run — gather + print the four-section snapshot for THIS project (config already loaded).
# Returns 1 when something needs attention (a DEAD builder, a CONFLICTING PR, or a review-blocked
# PR), 0 when healthy. Every external command is best-effort (missing git/gh/herdr degrades to a
# graceful "unknown"/empty, never a crash).
_status_run() {
  local root="${PROJECT_ROOT:-$(pwd)}"
  local trees="${WORKTREES_DIR:-${root}-trees}"
  local base="${DEFAULT_BRANCH:-origin/main}"
  local review_ledger="$trees/.agent-watch-reviewed"
  local health_ledger="$trees/.agent-watch-healthchecks"
  local b="${c_bold:-}" d="${c_dim:-}" g="${c_grn:-}" y="${c_yel:-}" r="${c_red:-}" x="${c_rst:-}"
  local attention=0 reasons=""

  printf '%s🐑 herd status%s · %s%s%s · %s%s%s\n\n' \
    "$b" "$x" "$b" "${WORKSPACE_NAME:-?}" "$x" "$d" "$root" "$x"

  # (a) WATCHER — alive via the argv0 marker / pid lock. A down watcher is INFORMATIONAL only (its
  #     counts may be stale); it is NOT an attention condition on its own — we never false-red it.
  local wpids wpid1
  wpids="$(_status_watcher_pids)"
  if [ -n "$wpids" ]; then
    wpid1="${wpids%%$'\n'*}"   # first pid line (no pipe → no pipefail/SIGPIPE surprise under set -e)
    printf '  %sWATCHER%s   %salive%s (pid %s)\n' "$b" "$x" "$g" "$x" "$wpid1"
  else
    printf '  %sWATCHER%s   %sdown%s %s(no herd-watch-<workspace> process / pid lock)%s\n' \
      "$b" "$x" "$y" "$x" "$d" "$x"
  fi

  # (b) BUILDERS — one row per active feature worktree, joined to its agent + PR. DEAD is the
  #     read-only replica of the watcher's signature. gh/herdr absence degrades gracefully.
  local wt_porcelain agents_json prs_json
  wt_porcelain="$(git -C "$root" worktree list --porcelain 2>/dev/null || true)"
  agents_json="$(herdr agent list 2>/dev/null || printf '{}')"
  prs_json="$( (cd "$root" 2>/dev/null && gh pr list --json number,title,headRefName,headRefOid,mergeable,mergeStateStatus,reviewDecision 2>/dev/null) || printf '[]')"

  # Emit one record per feature worktree: wt \x1f slug \x1f branch \x1f prnum \x1f mergeable \x1f
  # mstate \x1f reviewDecision \x1f headsha \x1f agent_status  (main checkout excluded).
  local feats
  feats="$(MAIN="$root" WT="$wt_porcelain" AGENTS_JSON="$agents_json" PRS_JSON="$prs_json" python3 -c '
import os, json
MAIN = os.environ["MAIN"]
def _rp(p):
    try: return os.path.realpath(p)
    except Exception: return p
MAIN_RP = _rp(MAIN)
try: prs = json.loads(os.environ.get("PRS_JSON") or "[]")
except Exception: prs = []
try: agents = (json.loads(os.environ.get("AGENTS_JSON") or "{}").get("result") or {}).get("agents") or []
except Exception: agents = []
pr_by_branch = {p.get("headRefName"): p for p in prs}
ag_status = {a.get("name"): a.get("agent_status") for a in agents if a.get("name")}
# Parse porcelain into (wt, branch, is_first). The FIRST worktree entry is ALWAYS the main checkout;
# exclude it both by position and by realpath match to MAIN (symlink-safe, e.g. /var → /private/var),
# so the main checkout is never misclassified as a DEAD builder (a false-red we must avoid).
rows = []; wt = None; branch = None
for line in (os.environ.get("WT") or "").splitlines():
    if line.startswith("worktree "): wt = line[9:]; branch = None
    elif line.startswith("branch "): branch = line[7:].replace("refs/heads/", "")
    elif line == "":
        if wt: rows.append((wt, branch))
        wt = None; branch = None
if wt: rows.append((wt, branch))
feats = [(wt, branch) for i, (wt, branch) in enumerate(rows)
         if i > 0 and _rp(wt) != MAIN_RP]
for wt, branch in feats:
    slug = os.path.basename(wt)
    pr = pr_by_branch.get(branch or "", {})
    print("\x1f".join(str(v) for v in [
        wt, slug, branch or "", pr.get("number", ""),
        pr.get("mergeable", ""), pr.get("mergeStateStatus", ""),
        pr.get("reviewDecision", ""), pr.get("headRefOid", ""),
        ag_status.get(slug, "")]))
' 2>/dev/null || true)"

  local n_build=0 n_done=0 n_idle=0 n_dead=0 rows=""
  local rec wt slug branch prnum mergeable mstate decision headsha astatus has_agent has_pr commits verdict
  while IFS= read -r rec; do
    [ -n "$rec" ] || continue
    IFS=$'\037' read -r wt slug branch prnum mergeable mstate decision headsha astatus <<EOF
$rec
EOF
    [ -n "$astatus" ] && has_agent=1 || has_agent=0
    [ -n "$prnum" ] && has_pr=1 || has_pr=0
    commits="$(git -C "$wt" rev-list --count HEAD --not "$base" 2>/dev/null || printf 0)"
    case "$commits" in ''|*[!0-9]*) commits=0 ;; esac
    verdict="$(_status_classify_builder "$has_agent" "$astatus" "$has_pr" "$commits")"
    local sl; sl="$(printf '%-24s' "$slug")"
    case "$verdict" in
      building) n_build=$((n_build+1)); rows="${rows}    ${g}🔨${x} ${b}${sl}${x} building"$'\n' ;;
      done)     n_done=$((n_done+1));   rows="${rows}    ${g}✅${x} ${b}${sl}${x} done${prnum:+ · PR #$prnum}"$'\n' ;;
      idle)     n_idle=$((n_idle+1));   rows="${rows}    ${d}💤 ${sl} idle · no PR${x}"$'\n' ;;
      dead)     n_dead=$((n_dead+1));   attention=1; reasons="${reasons} dead-builder:${slug}"
                rows="${rows}    ${r}💀 ${b}${sl}${x} ${r}DEAD (no agent, no PR, no commits)${x}"$'\n' ;;
    esac
  done <<EOF
$feats
EOF

  local dcol=""; [ "$n_dead" -gt 0 ] && dcol="$r"
  printf '  %sBUILDERS%s  %d building · %d done · %d idle · %s%d dead%s\n' \
    "$b" "$x" "$n_build" "$n_done" "$n_idle" "$dcol" "$n_dead" "$x"
  [ -n "$rows" ] && printf '%s' "$rows"

  # (c) PRS — open PRs + gate state (mergeable/mstate + last review/health verdict + reviewDecision).
  local pr_summary
  pr_summary="$(PRS_JSON="$prs_json" python3 -c '
import os, json
try: prs = json.loads(os.environ.get("PRS_JSON") or "[]")
except Exception: prs = []
print(len(prs))
for p in prs:
    print("\x1f".join(str(v) for v in [
        p.get("number",""), (p.get("title","") or "")[:48], p.get("headRefName",""),
        p.get("mergeable",""), p.get("mergeStateStatus",""),
        p.get("reviewDecision",""), p.get("headRefOid","")]))
' 2>/dev/null || printf '0')"
  local n_prs; n_prs="${pr_summary%%$'\n'*}"   # first line = the count (no pipe under set -e)
  case "$n_prs" in ''|*[!0-9]*) n_prs=0 ;; esac
  printf '  %sPRS%s       %d open\n' "$b" "$x" "$n_prs"
  local first=1 num title brnch review health attn mcol
  while IFS= read -r rec; do
    if [ "$first" = 1 ]; then first=0; continue; fi   # skip the count line
    [ -n "$rec" ] || continue
    IFS=$'\037' read -r num title brnch mergeable mstate decision headsha <<EOF
$rec
EOF
    review="$(_status_latest_review "$review_ledger" "$num" "$headsha")"
    health="$(_status_latest_health "$health_ledger" "$num")"
    attn="$(_status_pr_attention "$mergeable" "$review" "$decision")"
    if [ "$attn" = "1" ]; then
      attention=1; mcol="$r"
      case "$mergeable" in CONFLICTING) reasons="${reasons} conflicting-pr:#${num}" ;; esac
      [ "$review" = "BLOCK" ] && reasons="${reasons} review-blocked:#${num}"
      [ "$decision" = "CHANGES_REQUESTED" ] && reasons="${reasons} changes-requested:#${num}"
    else
      mcol="$g"
    fi
    printf '    %s#%s%s %s%-24s%s %s%s%s%s%s%s%s\n' \
      "$d" "$num" "$x" "$b" "${brnch:0:24}" "$x" \
      "$mcol" "${mergeable:-UNKNOWN}" "$x" \
      "${mstate:+ · $mstate}" \
      "${review:+ · review $review}" \
      "${health:+ · health $health}" \
      "${decision:+ · $decision}"
  done <<EOF
$pr_summary
EOF

  # (d) BACKLOG — open (🔜) / in-progress (🚧) counts. File backend reads $BACKLOG_FILE directly;
  #     a tracker backend (github/linear) has no local emoji state, so we say so rather than guess.
  if [ "${SCRIBE_BACKEND:-file}" = "file" ]; then
    local blf counts bopen binprog
    blf="${BACKLOG_FILE:-BACKLOG.md}"
    case "$blf" in /*) : ;; *) blf="$root/$blf" ;; esac
    counts="$(_status_backlog_counts "$blf")"
    bopen="${counts%% *}"; binprog="${counts##* }"
    printf '  %sBACKLOG%s   %s open · %s in-progress\n' "$b" "$x" "$bopen" "$binprog"
  else
    printf '  %sBACKLOG%s   %s(backend: %s — no local counts)%s\n' \
      "$b" "$x" "$d" "${SCRIBE_BACKEND}" "$x"
  fi

  # (e) CODEMAP — freshness of the committed docs/codemap.md. INFORMATIONAL ONLY: always dim, never
  #     red, and NEVER an attention condition (per the no-false-red rule — a stale doc is not a broken
  #     build). Shown only when the project has adopted the codemap (the committed file exists). Uses
  #     the read-only `codemap.sh --check` probe (exit 0 fresh / non-zero stale) which never writes
  #     the committed file. Independent of CODEMAP_AUTOREFRESH.
  local cm_dir cm_script cm_out
  cm_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
  cm_script="$cm_dir/codemap.sh"; cm_out="$root/docs/codemap.md"
  if [ -f "$cm_out" ] && [ -f "$cm_script" ]; then
    if HERD_CODEMAP_ROOT="$root" HERD_CODEMAP_OUT="$cm_out" bash "$cm_script" --check >/dev/null 2>&1; then
      printf '  %sCODEMAP%s   %sfresh%s\n' "$b" "$x" "$d" "$x"
    else
      printf '  %sCODEMAP%s   %sstale · run `herd codemap` to refresh%s\n' "$b" "$x" "$d" "$x"
    fi
  fi

  # Verdict line + exit code.
  printf '\n'
  if [ "$attention" = 1 ]; then
    printf '%s⚠️  attention:%s%s\n' "$y" "$reasons" "$x"
    return 1
  fi
  printf '%s✅ healthy%s\n' "$g" "$x"
  return 0
}
