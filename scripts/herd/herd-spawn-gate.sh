#!/usr/bin/env bash
# herd-spawn-gate.sh — ADVISORY pre-spawn review-gate saturation check, SOURCED by the lane
# scripts (herd-quick.sh / herd-feature.sh) AFTER herd-config.sh so REVIEW_CONCURRENCY,
# SPAWN_AHEAD, WORKTREES_DIR and PROJECT_ROOT are already resolved.
#
# THE PROBLEM (BACKLOG "Match builder spawn rate to REVIEW_CONCURRENCY"): the watcher reviews at
# most $REVIEW_CONCURRENCY PRs in parallel (default 2), but the coordinator can queue and spawn
# UNLIMITED builders. Surplus builds finish, push PRs, then sit in REVIEW_QUEUED state — burning
# full builder-session tokens with ZERO throughput gain, because no review slot is free to advance
# them. This gate lets a lane HOLD a spawn when the review pipeline is already saturated AND enough
# builds are already in flight to keep the gate fed.
#
# DERIVES REVIEW STATE WITHOUT TOUCHING agent-watch.sh (another builder owns the watcher surface):
# it re-reads the SAME on-disk artifacts the watcher writes — the sha-keyed review ledger
# (.agent-watch-reviewed) and the in-flight review markers (.review-inflight-<pr>-<sha>) — plus
# `gh pr list` for the set of open PRs. It never calls into, nor edits, agent-watch.sh /
# herd-review.sh.
#
# THE RULE (both conditions must hold to defer):
#   live_reviews + queued_reviews >= REVIEW_CONCURRENCY   # the gate has no review headroom, AND
#   in-flight builders            >  REVIEW_CONCURRENCY + SPAWN_AHEAD   # already building ahead
# SPAWN_AHEAD (default 1) is the permitted lead: it keeps ONE build ahead of the gate so the
# pipeline never starves while a review runs. SPAWN_AHEAD=0 → strict no-surplus (never build past
# REVIEW_CONCURRENCY in-flight while the gate is full).
#
# ADVISORY + FAIL-OPEN: this NEVER hard-fails a lane. On any uncertainty (gh unavailable, not a git
# repo, unreadable ledger) it reports NOT saturated so work is never wrongly blocked by an infra
# hiccup. A force-spawn override (HERD_FORCE_SPAWN=1, or the lane's --force flag) bypasses it for
# urgent items.
#
# Definitions:
#   live_reviews   — .review-inflight-<pr>-<sha> markers whose recorded reviewer pid is still alive
#                    (mirrors agent-watch.sh's _count_live_reviews; reimplemented here, not called).
#   queued_reviews — OPEN PRs whose CURRENT head sha has no verdict in the ledger and is not live —
#                    i.e. waiting for a review slot (the REVIEW_QUEUED display state).
#   builders       — git worktrees under $WORKTREES_DIR (each lane spawns exactly one per slug; the
#                    watcher removes it on merge), i.e. builds not yet landed.

# _sg_trees — the worktrees dir that holds the watcher's ledger + inflight markers.
_sg_trees() { printf '%s' "${WORKTREES_DIR:-}"; }

# _sg_review_pid_live <inflight-file> — true if the marker's first line is a still-running pid.
# Mirrors agent-watch.sh:_review_pid_live (the marker's line 1 is the reviewer pid).
_sg_review_pid_live() {
  local pid; pid="$(head -1 "$1" 2>/dev/null || true)"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

# _sg_count_live_reviews — number of .review-inflight-* markers with an alive reviewer pid.
_sg_count_live_reviews() {
  local trees n=0 f
  trees="$(_sg_trees)"
  [ -n "$trees" ] || { printf '0'; return 0; }
  for f in "$trees"/.review-inflight-*; do
    [ -e "$f" ] || continue
    _sg_review_pid_live "$f" && n=$((n+1))
  done
  printf '%s' "$n"
}

# _sg_verdict_recorded <pr#> <headSha> — true if the ledger holds ANY verdict (PASS/BLOCK/…) for
# this exact pr+sha. Ledger row format (agent-watch.sh:record_review): "<epoch> <pr> <sha> <verdict> <source>".
# A new commit changes <sha>, so a superseded verdict never masks a PR that must be re-reviewed.
_sg_verdict_recorded() {
  local trees ledger; trees="$(_sg_trees)"; ledger="$trees/.agent-watch-reviewed"
  [ -s "$ledger" ] || return 1
  awk -v p="$1" -v s="$2" '$2==p && $3==s{f=1} END{exit f?0:1}' "$ledger" 2>/dev/null
}

# _sg_live_for <pr#> <headSha> — true if a live in-flight review marker exists for this exact pr+sha.
_sg_live_for() {
  local trees f; trees="$(_sg_trees)"
  f="$trees/.review-inflight-$1-$2"
  [ -e "$f" ] && _sg_review_pid_live "$f"
}

# _sg_open_prs — emit "<number> <headSha>" lines for every OPEN PR, via `gh pr list`. A missing gh,
# a failed call, or an unparseable payload emits NOTHING — the caller then reads zero queued reviews
# and the gate fails OPEN (advisory: never block a spawn on an infra hiccup).
_sg_open_prs() {
  command -v gh >/dev/null 2>&1 || return 0
  local json
  json="$(gh pr list --state open --json number,headRefOid --limit 200 2>/dev/null)" || return 0
  [ -n "$json" ] || return 0
  printf '%s' "$json" | python3 -c '
import sys, json
try:
  for p in json.load(sys.stdin):
    n = p.get("number"); sha = p.get("headRefOid") or ""
    if n is not None:
      print(n, sha)
except Exception:
  pass
' 2>/dev/null || true
}

# _sg_count_queued_reviews — OPEN PRs waiting for a review slot: current head sha has NO ledger
# verdict AND is not currently being reviewed (no live marker). This is the REVIEW_QUEUED depth.
_sg_count_queued_reviews() {
  local n=0 num sha
  while read -r num sha; do
    [ -n "$num" ] || continue
    _sg_verdict_recorded "$num" "$sha" && continue   # already decided (PASS/BLOCK at this sha)
    _sg_live_for "$num" "$sha" && continue           # currently live — counted as a live review
    n=$((n+1))
  done < <(_sg_open_prs)
  printf '%s' "$n"
}

# _sg_count_inflight_builders — git worktrees rooted under $WORKTREES_DIR (excludes the main
# checkout). Each lane creates exactly one per slug and the watcher removes it on merge, so this is
# the count of builds not yet landed. Not a git repo / no git → 0 (fail-open on the builder axis).
_sg_count_inflight_builders() {
  local root trees; root="${PROJECT_ROOT:-}"; trees="$(_sg_trees)"
  { [ -n "$root" ] && [ -n "$trees" ]; } || { printf '0'; return 0; }
  git -C "$root" worktree list --porcelain 2>/dev/null | ROOT_TREES="$trees" python3 -c '
import sys, os
# Resolve symlinks on BOTH sides: `git worktree list` reports PHYSICAL paths (on macOS /var is a
# symlink to /private/var), while WORKTREES_DIR may be the logical path from .herd/config — a raw
# string compare would then miss every worktree.
trees = os.path.realpath(os.environ["ROOT_TREES"])
n = 0
for line in sys.stdin:
  if line.startswith("worktree "):
    path = os.path.realpath(line[len("worktree "):].strip())
    if path.startswith(trees + os.sep):
      n += 1
print(n)
' 2>/dev/null || printf '0'
}

# herd_spawn_gate_saturated — compute the gate state ONCE and stash the counts in globals
# (_SG_LIVE / _SG_QUEUED / _SG_BUILDERS / _SG_CONC / _SG_AHEAD) for the caller's message. Returns 0
# (SATURATED → the caller should defer unless forced) or 1 (headroom → proceed). Advisory only.
herd_spawn_gate_saturated() {
  local conc ahead cap
  conc="${REVIEW_CONCURRENCY:-2}"; case "$conc" in ''|*[!0-9]*) conc=2 ;; esac
  ahead="${SPAWN_AHEAD:-1}";       case "$ahead" in ''|*[!0-9]*) ahead=1 ;; esac
  _SG_LIVE="$(_sg_count_live_reviews)"
  _SG_QUEUED="$(_sg_count_queued_reviews)"
  _SG_BUILDERS="$(_sg_count_inflight_builders)"
  _SG_CONC="$conc"; _SG_AHEAD="$ahead"
  cap=$((conc + ahead))
  # Both axes must hold: the review gate has no headroom AND builders already lead past the cap.
  if [ "$((_SG_LIVE + _SG_QUEUED))" -ge "$conc" ] && [ "$_SG_BUILDERS" -gt "$cap" ]; then
    return 0
  fi
  return 1
}

# herd_spawn_gate_emit_defer <slug> — print the standing "review-gate saturated" hold message using
# the counts stashed by the most recent herd_spawn_gate_saturated call.
herd_spawn_gate_emit_defer() {
  local slug="${1:-}"
  printf '⏸️  review-gate saturated — holding spawn until a slot opens%s\n' "${slug:+ (slug: $slug)}"
  printf '   reviews in flight: %s live + %s queued ≥ REVIEW_CONCURRENCY=%s\n' \
    "${_SG_LIVE:-?}" "${_SG_QUEUED:-?}" "${_SG_CONC:-?}"
  printf '   builders in flight: %s > REVIEW_CONCURRENCY + SPAWN_AHEAD (%s + %s = %s)\n' \
    "${_SG_BUILDERS:-?}" "${_SG_CONC:-?}" "${_SG_AHEAD:-?}" "$(( ${_SG_CONC:-0} + ${_SG_AHEAD:-0} ))"
  printf '   this build would just queue behind the gate, burning builder-session tokens with no throughput gain.\n'
  printf '   force past the gate for an urgent item:  HERD_FORCE_SPAWN=1  (or pass --force before the slug)\n'
}
