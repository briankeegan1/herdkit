#!/usr/bin/env bash
# status.sh — pure helpers + the orchestrator behind `herd status`, a ONE-SHOT, READ-ONLY,
# human-and-cron-friendly control-room health snapshot for THIS project. Sourced by bin/herd
# (cmd_status) AFTER .herd/config is loaded; also standalone-sourceable for the hermetic test
# (tests/test-status.sh), which drives ONLY the pure classifiers/ledger-readers below.
#
# It NEVER mutates anything — no tree, ledger, tab, PR, or dead-builder record. It only READS:
#   • the watcher liveness (the shared check in scripts/herd/watcher-exempt.sh — lockfile ∪
#     herd-watch-<slug> argv0 marker, minus the canonical watcher's own forks — reached via bin/herd's
#     _list_project_watchers, with a self-contained argv0 pgrep fallback when sourced standalone);
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

# _status_classify_builder <has_agent 0|1> <agent_status> <has_pr 0|1> <commits> [liveness] — the
# deterministic bucket for one feature worktree. Echoes exactly one token:
#   agentdead    — the agent SESSION is confirmed DEAD (its process is gone though herdr may still list
#                  it, and even when an open PR exists): the HERD-114 signature. Surfaced distinctly
#                  instead of a misleading done/idle so a review bounce is never sent into a dead pane.
#                  Only a POSITIVE liveness='dead' triggers it, and never over a WORKING agent (a live
#                  process can't be dead — the probe raced); empty/unknown/alive preserves prior bucket.
#   agentmissing — the tab has NO agent in the roster AT ALL, yet work was already produced (an open PR
#                  or commits): the agent VANISHED after finishing (HERD-135). 'done' REQUIRES a live
#                  session, so a vanished agent over real work is NOT 'done' — it is 'agent missing'
#                  (distinct from 'agent dead' = pane present but unresponsive), so a refix bounce is
#                  never attempted against nobody and the operator sees the truth (the #249 incident).
#   dead     — no live agent record + no open PR + zero commits: the watcher's DEAD signature,
#              replicated READ-ONLY (a silently-exited pre-PR builder that produced nothing).
#   building — a live agent is WORKING on it (no PR yet).
#   done     — a LIVE agent is present and it reached its finish line (an open PR, agent-reported done,
#              or commits produced). REQUIRES a live session in the roster (has_agent=1) — HERD-135.
#   idle     — a live agent is present but not working and has produced no PR/commits yet.
_status_classify_builder() {
  local has_agent="${1:-0}" astatus="${2:-}" has_pr="${3:-0}" commits="${4:-0}" liveness="${5:-}"
  case "$commits" in ''|*[!0-9]*) commits=0 ;; esac
  # A confirmed-dead agent session (process gone though herdr may still list it / a PR may be open) is
  # the HERD-114 signature — surface it distinctly. Never override a WORKING agent (a probe race).
  if [ "$liveness" = "dead" ] && [ "$astatus" != "working" ]; then
    printf 'agentdead'; return 0
  fi
  # HERD-135: NO agent in the roster at all. 'done' requires a LIVE session, so a vanished agent is
  # never 'done'. If it produced work (open PR or commits) the tab lost its agent pane AFTER finishing:
  # 'agent missing' — a refix would hit nobody. Nothing produced → the classic pre-PR 'dead' signature.
  if [ "$has_agent" != "1" ]; then
    { [ "$has_pr" = "1" ] || [ "$commits" -gt 0 ]; } && { printf 'agentmissing'; return 0; }
    printf 'dead'; return 0
  fi
  # From here a LIVE agent is present (has_agent=1). An open PR is an unambiguous finish-line signal.
  [ "$has_pr" = "1" ] && { printf 'done'; return 0; }
  case "$astatus" in
    working) printf 'building'; return 0 ;;
    done)    printf 'done';     return 0 ;;
  esac
  # Present but idle/other: done if it already produced commits, else genuinely idle.
  [ "$commits" -gt 0 ] && { printf 'done'; return 0; }
  printf 'idle'
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

# _status_watcher_pids — one PID per line for THIS project's live watcher MAIN(s). Prefers bin/herd's
# _list_project_watchers, then watcher-exempt.sh's watcher_list_mains directly (both are the SAME
# shared check: lockfile ∪ exact herd-watch-<slug> argv0, minus the canonical watcher's own forks);
# falls back to a self-contained argv0-EXACT pgrep so status.sh still works sourced standalone with
# neither in scope. READ-ONLY: it only reads the lockfile + ps/pgrep, never signals anything.
_status_watcher_pids() {
  if declare -f _list_project_watchers >/dev/null 2>&1; then
    _list_project_watchers 2>/dev/null || true
    return 0
  fi
  if declare -f watcher_list_mains >/dev/null 2>&1; then
    watcher_list_mains 2>/dev/null || true
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

# _status_watcher_count — how many watcher mains the CURRENT sample sees. `grep -c .` exits 1 on an
# empty input, so `|| printf 0` keeps that zero under the caller's set -e.
_status_watcher_count() {
  local pids="${1:-}"
  [ -n "$pids" ] || { printf 0; return 0; }
  printf '%s\n' "$pids" | grep -c . 2>/dev/null || printf 0
}

# _status_dup_sleep — pause one inter-sample gap. $HERD_STATUS_DUP_SLEEP is a test seam; a value that
# is not a plain (possibly fractional) number is ignored. A `sleep` without fractional-second support
# would reject "0.3" and, with a bare `|| true`, silently run the samples back-to-back — degrading the
# PERSISTENCE check to a single sample. So a rejected fractional gap falls back to a whole second: a
# slower `herd status` on that platform, never a weaker check. A gap of exactly 0 means "no pause"
# (the unit tests' seam) and must not fall back.
_status_dup_sleep() {
  local gap="${HERD_STATUS_DUP_SLEEP:-0.3}"
  case "$gap" in
    ''|*[!0-9.]*|*.*.*) gap="0.3" ;;
  esac
  case "$gap" in 0|0.0|0.00) return 0 ;; esac
  sleep "$gap" 2>/dev/null && return 0
  sleep 1 2>/dev/null || true
}

# _status_dup_verified <first-sample-pids> — is the duplicate-watcher condition REAL? (HERD-266)
#
# A duplicate watcher is a genuine emergency (two mains race the shared .git object store), so the row
# is red and loud. That makes a FALSE red expensive: the operator hunts a ghost, and a console that
# cries wolf stops being read. One `ps` sample cannot tell a duplicate from a sub-second fork of the
# canonical watcher that happened to be alive when we looked — the tick loop forks constantly.
# watcher_list_mains's exemptions remove the forks we can PROVE are ours (marker-owned, child of the
# canonical watcher, parent of a live gate worker); this adds the two checks that need TIME, not a
# process table:
#   • HANDOFF — a WATCHER_SELF_RESTART exec is in flight. Both generations are legitimate; the window
#     is TTL-bounded and closes itself. Never alarm inside it.
#   • PERSISTENCE — re-sample. A real duplicate is a long-lived process and survives every sample; a
#     fork the exemptions could not attribute (its parent already reaped, its gate child not yet
#     exec'd) is gone within a sample or two. We alarm only when EVERY sample still sees >1 main.
# On success it PRINTS the pids of the LAST sample — the mains that actually survived every check, and
# so the only ones the operator should be told to stop. The caller must render those, never the first
# sample's: re-reading the list after verification (as an earlier revision did) can catch a shrunk
# sample and print a nonsensical '⚠ 1 watcher mains alive (pids 12345)'.
# Returns 0 (alarm — verified real, surviving pids on stdout), 1 (do not alarm). Read-only.
# HERD_STATUS_DUP_SAMPLES / HERD_STATUS_DUP_SLEEP are test seams; the defaults cost ~0.6s and only on
# the already-suspect path.
_status_dup_verified() {
  local pids="${1:-}" samples="${HERD_STATUS_DUP_SAMPLES:-3}" i=1
  if declare -f watcher_handoff_active >/dev/null 2>&1 && watcher_handoff_active; then
    return 1
  fi
  case "$samples" in ''|*[!0-9]*|0) samples=3 ;; esac
  # The caller's sample is sample 1; it already showed > 1 main. Re-sample until we have `samples` of
  # them, and let the LAST one carry the pids we print.
  while [ "$i" -lt "$samples" ]; do
    _status_dup_sleep
    pids="$(_status_watcher_pids)"
    # The extra main is already gone ⇒ it was a transient fork, not a duplicate.
    [ "$(_status_watcher_count "$pids")" -gt 1 ] || return 1
    i=$(( i + 1 ))
  done
  printf '%s\n' "$pids"
}

# ── GATHER → FORMAT split (HERD-307, P1b, EPIC HERD-300) ───────────────────────────────────────────
# `herd status` is a LIVE-ENVIRONMENT snapshot (ps / gh / driver-seam / colours / timing dup-detect),
# not a journal reader — so it cannot be ported wholesale like P1's readers. Instead it is split at a
# stable serialization seam:
#   • _status_gather      — runs EVERY live probe (watcher liveness, git worktrees, driver roster, gh
#                           PRs, ledgers, backlog, codemap), does all classification, and emits ONE
#                           colour-resolved, <US>-delimited snapshot. This is the ONLY stage that
#                           touches the live environment, so it deliberately gets NO golden.
#   • _status_format_bash — the historical bash formatter, now reading that snapshot instead of local
#                           vars. Stays in place as the FAIL-SOFT fallback.
#   • pysrc/herd/status.py — the python formatter, byte-identical to _status_format_bash over the same
#                           snapshot. Preferred when the `herd` package imports (HERD_ENGINE_PY!=0).
# _status_run wires them: gather once, then format via python (fail-soft to bash on HERD_ENGINE_PY=0 or
# any import/exec failure). Because BOTH formatters consume the SAME snapshot, output cannot fork; the
# golden parity test (tests/test-py-readers.sh) drives the format both ways on committed snapshot
# fixtures and cmp's byte-identical incl. exit codes. Colours flow through the snapshot's COLORS record
# (resolved from HERD_THEME by cmd_status, exactly as today) so the seam carries the palette too.
#
# Snapshot record grammar — one record per line, fields joined by US (\037); section order is fixed by
# the formatter (it parses all records first, then renders), so record order is not load-bearing:
#   COLORS    <b> <d> <g> <y> <r> <x>          resolved palette (empty under NO_COLOR / standalone)
#   WORKSPACE <name>
#   ROOT      <root>
#   WATCHER   <state> <pid1> <count> <pids>    state ∈ down|alive|handoff|dup ; <pids> space-joined
#   BCOUNTS   <building> <done> <idle> <dead>
#   BUILDER   <verdict> <slug> <prnum>         repeated, in display order
#   PRCOUNT   <n>
#   PR        <num> <branch> <mergeable> <mstate> <review> <health> <decision> <attn>   repeated
#   BACKLOG   file <open> <inprog>   |   BACKLOG other <backend>
#   CODEMAP   <present 0|1> <fresh 0|1>        no CODEMAP section rendered when present=0
#   ATTENTION <0|1>
#   REASONS   <reasons string>                 leading-space-joined tokens, printed verbatim

# _status_gather — LIVE-PROBE stage: gather + classify, emit the snapshot on stdout. Always returns 0
# (the attention verdict rides in the snapshot's ATTENTION field, not the exit code). Every external
# command is best-effort (missing git/gh/herdr degrades to a graceful "unknown"/empty, never a crash).
_status_gather() {
  local US=$'\037'
  local root="${PROJECT_ROOT:-$(pwd)}"
  local trees="${WORKTREES_DIR:-${root}-trees}"
  local base="${DEFAULT_BRANCH:-origin/main}"
  local review_ledger="$trees/.agent-watch-reviewed"
  local health_ledger="$trees/.agent-watch-healthchecks"
  local attention=0 reasons=""

  # Resolved palette, baked into the snapshot so BOTH formatters apply byte-identical colours from the
  # same seam (HERD_THEME via bin/herd's herd_theme_load_cli, already loaded by cmd_status). Empty under
  # NO_COLOR / a standalone source, exactly as the historical inline `${x:-}` defaults.
  printf 'COLORS%s%s%s%s%s%s%s%s%s%s%s%s\n' \
    "$US" "${c_bold:-}" "$US" "${c_dim:-}" "$US" "${c_grn:-}" \
    "$US" "${c_yel:-}" "$US" "${c_red:-}" "$US" "${c_rst:-}"
  printf 'WORKSPACE%s%s\n' "$US" "${WORKSPACE_NAME:-?}"
  printf 'ROOT%s%s\n' "$US" "$root"

  # (a) WATCHER — alive via the argv0 marker / pid lock. A down watcher is INFORMATIONAL only (its
  #     counts may be stale); it is NOT an attention condition on its own — we never false-red it.
  local wpids wpid1="" wcount="0" wstate="down" wpids_out=""
  wpids="$(_status_watcher_pids)"
  if [ -n "$wpids" ]; then
    wpid1="${wpids%%$'\n'*}"   # first pid line (no pipe → no pipefail/SIGPIPE surprise under set -e)
    # Exactly one watcher main is the invariant (HERD-209): a duplicate races the shared .git object
    # store and is a REAL attention condition — but only once VERIFIED REAL (HERD-266): a single sample
    # cannot tell a duplicate from a transient fork or a self-restart handoff, and a false red is worse
    # than a late one. _status_dup_verified adds the checks that need TIME (handoff window + resample)
    # and prints the SURVIVING pids — the only ones the operator should act on.
    wcount="$(_status_watcher_count "$wpids")"
    local wsurv=""
    if [ "${wcount:-1}" -gt 1 ] && wsurv="$(_status_dup_verified "$wpids")"; then
      wcount="$(_status_watcher_count "$wsurv")"
      wpids_out="$(printf '%s' "$wsurv" | tr '\n' ' ')"; wpids_out="${wpids_out% }"
      wstate="dup"
      attention=1; reasons="${reasons} duplicate-watchers:${wcount}"
    elif [ "${wcount:-1}" -gt 1 ] && declare -f watcher_handoff_active >/dev/null 2>&1 \
         && watcher_handoff_active; then
      wstate="handoff"
    else
      wstate="alive"
    fi
    printf 'WATCHER%s%s%s%s%s%s%s%s\n' "$US" "$wstate" "$US" "$wpid1" "$US" "$wcount" "$US" "$wpids_out"
  else
    printf 'WATCHER%s%s%s%s%s%s%s%s\n' "$US" "down" "$US" "" "$US" "0" "$US" ""
  fi

  # (b) BUILDERS — one record per active feature worktree, joined to its agent + PR. DEAD is the
  #     read-only replica of the watcher's signature. gh/herdr absence degrades gracefully.
  local wt_porcelain agents_json prs_json
  wt_porcelain="$(git -C "$root" worktree list --porcelain 2>/dev/null || true)"
  # Builder roster via the driver seam (herdr-claude → `herdr agent list`; headless → the detached-agent
  # registry), the same seam agent-watch.sh reads. Guarded so a standalone source (the hermetic tests) —
  # where driver.sh is not loaded — degrades to an empty roster instead of a raw herdr call.
  if declare -f herd_driver_agent_list_json >/dev/null 2>&1; then
    agents_json="$(herd_driver_agent_list_json 2>/dev/null || printf '{}')"
  else
    agents_json='{}'
  fi
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

  local n_build=0 n_done=0 n_idle=0 n_dead=0 builder_recs=""
  local rec wt slug branch prnum mergeable mstate decision headsha astatus has_agent has_pr commits verdict liveness
  while IFS= read -r rec; do
    [ -n "$rec" ] || continue
    IFS=$'\037' read -r wt slug branch prnum mergeable mstate decision headsha astatus <<EOF
$rec
EOF
    [ -n "$astatus" ] && has_agent=1 || has_agent=0
    [ -n "$prnum" ] && has_pr=1 || has_pr=0
    commits="$(git -C "$wt" rev-list --count HEAD --not "$base" 2>/dev/null || printf 0)"
    case "$commits" in ''|*[!0-9]*) commits=0 ;; esac
    # HERD-114: read-only, fail-soft liveness of the agent SESSION (its process), distinct from the
    # stale agent_status word herdr keeps reporting after a crash. Probe only a listed agent that would
    # otherwise read done/idle; only a POSITIVE 'dead' changes the bucket, so this is byte-identical when
    # live or when the probe can't tell / the driver seam is unavailable (standalone tests).
    liveness=""
    if [ "$has_agent" = "1" ] && [ "$astatus" != "working" ] && declare -f herd_driver_agent_liveness >/dev/null 2>&1; then
      liveness="$(herd_driver_agent_liveness "$slug" 2>/dev/null || printf 'unknown')"
    fi
    verdict="$(_status_classify_builder "$has_agent" "$astatus" "$has_pr" "$commits" "$liveness")"
    case "$verdict" in
      building)     n_build=$((n_build+1)) ;;
      done)         n_done=$((n_done+1)) ;;
      idle)         n_idle=$((n_idle+1)) ;;
      agentdead)    n_dead=$((n_dead+1)); attention=1; reasons="${reasons} agent-dead:${slug}" ;;
      agentmissing) n_dead=$((n_dead+1)); attention=1; reasons="${reasons} agent-missing:${slug}" ;;
      dead)         n_dead=$((n_dead+1)); attention=1; reasons="${reasons} dead-builder:${slug}" ;;
    esac
    builder_recs="${builder_recs}BUILDER${US}${verdict}${US}${slug}${US}${prnum}"$'\n'
  done <<EOF
$feats
EOF

  printf 'BCOUNTS%s%s%s%s%s%s%s%s\n' "$US" "$n_build" "$US" "$n_done" "$US" "$n_idle" "$US" "$n_dead"
  [ -n "$builder_recs" ] && printf '%s' "$builder_recs"

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
  printf 'PRCOUNT%s%s\n' "$US" "$n_prs"
  local first=1 num title brnch review health attn
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
      attention=1
      case "$mergeable" in CONFLICTING) reasons="${reasons} conflicting-pr:#${num}" ;; esac
      [ "$review" = "BLOCK" ] && reasons="${reasons} review-blocked:#${num}"
      [ "$decision" = "CHANGES_REQUESTED" ] && reasons="${reasons} changes-requested:#${num}"
    fi
    printf 'PR%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s\n' \
      "$US" "$num" "$US" "$brnch" "$US" "$mergeable" "$US" "$mstate" \
      "$US" "$review" "$US" "$health" "$US" "$decision" "$US" "$attn"
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
    printf 'BACKLOG%sfile%s%s%s%s\n' "$US" "$US" "$bopen" "$US" "$binprog"
  else
    printf 'BACKLOG%sother%s%s\n' "$US" "$US" "${SCRIBE_BACKEND}"
  fi

  # (e) CODEMAP — freshness of the committed docs/codemap.md. INFORMATIONAL ONLY (always dim, never an
  #     attention condition — a stale doc is not a broken build). Shown only when the project has adopted
  #     the codemap. Uses the read-only `codemap.sh --check` probe (exit 0 fresh / non-zero stale), which
  #     never writes the committed file. Independent of CODEMAP_AUTOREFRESH.
  local cm_dir cm_script cm_out cm_present=0 cm_fresh=0
  cm_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
  cm_script="$cm_dir/codemap.sh"; cm_out="$root/docs/codemap.md"
  if [ -f "$cm_out" ] && [ -f "$cm_script" ]; then
    cm_present=1
    if HERD_CODEMAP_ROOT="$root" HERD_CODEMAP_OUT="$cm_out" bash "$cm_script" --check >/dev/null 2>&1; then
      cm_fresh=1
    fi
  fi
  printf 'CODEMAP%s%s%s%s\n' "$US" "$cm_present" "$US" "$cm_fresh"

  printf 'ATTENTION%s%s\n' "$US" "$attention"
  printf 'REASONS%s%s\n' "$US" "$reasons"
  return 0
}

# _status_format_bash — FORMAT stage (fallback): render the snapshot on stdin to the four-section
# report, byte-identical to the historical inline formatter. Returns 1 on attention, 0 when healthy —
# the exit contract rides the snapshot's ATTENTION field, so both formatters agree.
_status_format_bash() {
  local US=$'\037'
  local b="" d="" g="" y="" r="" x=""
  local workspace="" root=""
  local w_state="down" w_pid1="" w_count="0" w_pids=""
  local n_build=0 n_done=0 n_idle=0 n_dead=0 builder_rows=""
  local n_prs=0 pr_rows=""
  local bl_kind="" bl_open="" bl_inprog="" bl_backend=""
  local cm_present=0 cm_fresh=0 attention=0 reasons=""
  local line key rest
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    key="${line%%"$US"*}"; rest="${line#*"$US"}"
    case "$key" in
      COLORS)    IFS=$US read -r b d g y r x <<EOF
$rest
EOF
        ;;
      WORKSPACE) workspace="$rest" ;;
      ROOT)      root="$rest" ;;
      WATCHER)   IFS=$US read -r w_state w_pid1 w_count w_pids <<EOF
$rest
EOF
        ;;
      BCOUNTS)   IFS=$US read -r n_build n_done n_idle n_dead <<EOF
$rest
EOF
        ;;
      BUILDER)
        local bv bslug bpr sl
        IFS=$US read -r bv bslug bpr <<EOF
$rest
EOF
        sl="$(printf '%-24s' "$bslug")"
        case "$bv" in
          building)     builder_rows="${builder_rows}    ${g}🔨${x} ${b}${sl}${x} building"$'\n' ;;
          done)         builder_rows="${builder_rows}    ${g}✅${x} ${b}${sl}${x} done${bpr:+ · PR #$bpr}"$'\n' ;;
          idle)         builder_rows="${builder_rows}    ${d}💤 ${sl} idle · no PR${x}"$'\n' ;;
          agentdead)    builder_rows="${builder_rows}    ${r}💀 ${b}${sl}${x} ${r}AGENT DEAD (session unwakeable${bpr:+ · PR #$bpr}) — re-task by hand${x}"$'\n' ;;
          agentmissing) builder_rows="${builder_rows}    ${r}🫥 ${b}${sl}${x} ${r}AGENT MISSING (no agent pane${bpr:+ · PR #$bpr}) — re-task by hand${x}"$'\n' ;;
          dead)         builder_rows="${builder_rows}    ${r}💀 ${b}${sl}${x} ${r}DEAD (no agent, no PR, no commits)${x}"$'\n' ;;
        esac
        ;;
      PRCOUNT)   n_prs="$rest" ;;
      PR)
        local pnum pbr pmerge pmstate preview phealth pdec pattn mcol
        IFS=$US read -r pnum pbr pmerge pmstate preview phealth pdec pattn <<EOF
$rest
EOF
        [ "$pattn" = "1" ] && mcol="$r" || mcol="$g"
        pr_rows="${pr_rows}$(printf '    %s#%s%s %s%-24s%s %s%s%s%s%s%s%s' \
          "$d" "$pnum" "$x" "$b" "${pbr:0:24}" "$x" \
          "$mcol" "${pmerge:-UNKNOWN}" "$x" \
          "${pmstate:+ · $pmstate}" \
          "${preview:+ · review $preview}" \
          "${phealth:+ · health $phealth}" \
          "${pdec:+ · $pdec}")"$'\n'
        ;;
      BACKLOG)   IFS=$US read -r bl_kind bl_open bl_inprog <<EOF
$rest
EOF
        [ "$bl_kind" = "other" ] && bl_backend="$bl_open"
        ;;
      CODEMAP)   IFS=$US read -r cm_present cm_fresh <<EOF
$rest
EOF
        ;;
      ATTENTION) attention="$rest" ;;
      REASONS)   reasons="$rest" ;;
    esac
  done

  printf '%s🐑 herd status%s · %s%s%s · %s%s%s\n\n' \
    "$b" "$x" "$b" "$workspace" "$x" "$d" "$root" "$x"

  case "$w_state" in
    dup)     printf '  %sWATCHER%s   %s⚠ %s watcher mains alive%s (pids %s) %s— duplicates race the gate; stop the extras: '"'"'herd pane watch'"'"' (or kill all but one)%s\n' \
               "$b" "$x" "$r" "$w_count" "$x" "$w_pids" "$d" "$x" ;;
    handoff) printf '  %sWATCHER%s   %salive%s (pid %s) %s· engine-update restart handoff in progress%s\n' \
               "$b" "$x" "$g" "$x" "$w_pid1" "$d" "$x" ;;
    alive)   printf '  %sWATCHER%s   %salive%s (pid %s)\n' "$b" "$x" "$g" "$x" "$w_pid1" ;;
    *)       printf '  %sWATCHER%s   %sdown%s %s(no herd-watch-<workspace> process / pid lock)%s\n' \
               "$b" "$x" "$y" "$x" "$d" "$x" ;;
  esac

  local dcol=""; [ "$n_dead" -gt 0 ] && dcol="$r"
  printf '  %sBUILDERS%s  %d building · %d done · %d idle · %s%d dead%s\n' \
    "$b" "$x" "$n_build" "$n_done" "$n_idle" "$dcol" "$n_dead" "$x"
  [ -n "$builder_rows" ] && printf '%s' "$builder_rows"

  printf '  %sPRS%s       %d open\n' "$b" "$x" "$n_prs"
  [ -n "$pr_rows" ] && printf '%s' "$pr_rows"

  if [ "$bl_kind" = "file" ]; then
    printf '  %sBACKLOG%s   %s open · %s in-progress\n' "$b" "$x" "$bl_open" "$bl_inprog"
  else
    printf '  %sBACKLOG%s   %s(backend: %s — no local counts)%s\n' \
      "$b" "$x" "$d" "$bl_backend" "$x"
  fi

  if [ "$cm_present" = "1" ]; then
    if [ "$cm_fresh" = "1" ]; then
      printf '  %sCODEMAP%s   %sfresh%s\n' "$b" "$x" "$d" "$x"
    else
      printf '  %sCODEMAP%s   %sstale · run `herd codemap` to refresh%s\n' "$b" "$x" "$d" "$x"
    fi
  fi

  printf '\n'
  if [ "$attention" = "1" ]; then
    printf '%s⚠️  attention:%s%s\n' "$y" "$reasons" "$x"
    return 1
  fi
  printf '%s✅ healthy%s\n' "$g" "$x"
  return 0
}

# _status_run — gather ONCE, then FORMAT via python (fail-soft to the bash formatter). The snapshot is
# buffered to a rewindable temp file so both paths read the same bytes and a mid-render python failure
# (empty output) falls back cleanly. HERD_STATUS_SNAPSHOT_FILE is a TEST SEAM: when it names a readable
# file, gather is skipped and that committed snapshot fixture is formatted directly — the hook the
# golden parity test uses to drive the FORMAT stage both ways without any live probe. Returns 1 on
# attention, 0 when healthy (the snapshot's verdict, preserved across both format paths).
_status_run() {
  local snap="" snap_is_temp=0 rc
  if [ -n "${HERD_STATUS_SNAPSHOT_FILE:-}" ] && [ -f "$HERD_STATUS_SNAPSHOT_FILE" ]; then
    snap="$HERD_STATUS_SNAPSHOT_FILE"
  else
    snap="$(mktemp 2>/dev/null)" || { _status_gather | _status_format_bash; return $?; }
    snap_is_temp=1
    _status_gather > "$snap" || true
  fi
  # Python FORMAT path — mirrors the P1 reader dispatch: preflight the package once (memoised), buffer
  # its output, and use it ONLY if it rendered something. Empty output = HERD_ENGINE_PY=0 or an
  # import/exec failure → silently fall back to the bash formatter (never a red row).
  if declare -f _herd_py_ok >/dev/null 2>&1 && _herd_py_ok; then
    local out; out="$(mktemp 2>/dev/null)"
    if [ -n "$out" ]; then
      PYTHONPATH="${HERD_PYSRC:-}${PYTHONPATH:+:$PYTHONPATH}" python3 -m herd.status <"$snap" >"$out" 2>/dev/null
      rc=$?
      if [ -s "$out" ]; then
        cat "$out"; rm -f "$out"
        [ "$snap_is_temp" = 1 ] && rm -f "$snap"
        return "$rc"
      fi
      rm -f "$out"
      declare -f warn >/dev/null 2>&1 && warn "herd status: python formatter unavailable — using builtin fallback"
    fi
  fi
  _status_format_bash <"$snap"; rc=$?
  [ "$snap_is_temp" = 1 ] && rm -f "$snap"
  return "$rc"
}
