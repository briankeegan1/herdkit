#!/usr/bin/env bash
# watcher-exempt.sh — THE ONE shared WATCHER-IDENTITY check (HERD-266).
#
# WHAT IS A "WATCHER MAIN"
# -----------------------
# The watcher tags itself at startup by re-execing under a distinctive per-workspace argv0
# ($HERD_WATCH_ARGV0 = herd-watch-<slug>) — the only attribution marker visible in `ps` on every
# platform. But argv0 is INHERITED by every fork, and the tick loop forks constantly: async gate
# workers (healthcheck / herd-review), backgrounded lane dispatches (herd-feature / herd-quick /
# herd-resolve), and plain sub-second command substitutions. Each of those carries the identical
# argv0. "Tagged with our argv0" therefore does NOT mean "a second watcher main" — it means "a
# process descended from this workspace's watcher", which is the normal, healthy state.
#
# Two consumers must answer the question "is this tagged pid a watcher MAIN?", and before HERD-266
# they answered it DIFFERENTLY:
#   • bin/herd's _list_project_watchers  — exempted only pids owned by a live inflight marker, so a
#     sub-second tick fork with no marker counted as a duplicate. `herd status` alarmed
#     '⚠ 2 watcher mains alive' against a perfectly healthy control room (~20 such forks observed,
#     every one a child of the canonical watcher, each alive < 1s).
#   • sweep.sh's sweep_stray_watchers   — ALSO exempted a tagged pid whose ppid is the canonical
#     (lockfile) watcher, and one that parents a live gate worker. The correct answer, in one seat.
#
# Two seats, two answers, one of them wrong: exactly the drift the invariance-first doctrine exists
# to prevent. This file is the reconciled invariant — ONE exemption check, sourced by BOTH seats (and
# by status.sh's alarm), so no surface can disagree about what a duplicate watcher is.
#
# A pid carrying our argv0 is EXEMPT from the LISTING (i.e. is not a main) when EITHER of:
#   (1) MARKER-OWNED     — a live .review-inflight-* / .health-inflight-* / .spawn-inflight-* marker
#                          records it. It is mid-flight gate work, possibly reparented to init by a
#                          watcher restart (HERD-185/217/237/245). SIGTERMing it destroys that work.
#   (2) CHILD-OF-CANONICAL — its ppid is the pid recorded in $HERD_WATCHER_LOCK. A child of the
#                          canonical watcher is that watcher's own fork, by construction.
# A GENUINE ORPHAN DUPLICATE — parent dead, not marker-owned — passes both clauses and IS listed. That
# is the real failure this machinery exists to catch (a duplicate races the shared .git object store),
# and nothing here softens it.
#
# WHY PARENT-OF-GATE-WORKER IS **NOT** A LISTING CLAUSE. sweep_stray_watchers carries a third guard —
# spare a tagged pid that PARENTS a live healthcheck.sh / herd-review.sh / herd-feature.sh — and it is
# tempting to hoist it here too. It must not be hoisted, because that guard cannot tell a reparented
# FORK from a watcher MAIN that merely dispatched a gate worker:
#   • macOS has no setsid, so _bg_new_session's python3 os.setsid()+execvp branch leaves
#     `bash …/herd-review.sh` a DIRECT CHILD of the dispatching watcher main;
#   • the inflight marker records the WORKER's pid, not the dispatching watcher's, so clause (1) does
#     not cover that main either.
# So a lock-absent STRAY watcher that has dispatched a review would be exempted — invisible to `herd
# status` (a calm green `alive`, precisely when the duplicate exists and its healthchecks restart
# endlessly) and, worse, skipped by _stop_project_watcher, which would then report "no running watcher
# found", drop the lockfile, and let the caller spawn a fresh watcher ON TOP of the survivor. That is
# the exact emergency this machinery prevents. watcher_list_mains feeds BOTH the status count AND the
# kill list, so it must count a gate-running stray as the main it is. The guard stays where it is safe:
# sweep.sh's DETECTION-only surface, applied there via the shared watcher_has_gate_child predicate.
#
# HANDOFF (root cause 1). WATCHER_SELF_RESTART=on re-execs the watcher in place. exec preserves the
# pid, but the OUTGOING image's still-running forks are momentarily neither marker-owned nor children
# of a settled lock, so a sample taken inside that window can see more than one tagged main. The
# outgoing image records the window in a TTL-bounded handoff marker (watcher_handoff_begin, cleared by
# the incoming image's startup); watcher_handoff_active reports it. The handoff SUPPRESSES THE ALARM
# only — it never removes a pid from watcher_list_mains, because that list also feeds the killer
# (_stop_project_watcher), and a `herd reload` during a handoff must still stop the watcher. A stale
# marker (a crashed exec) ages out after WATCHER_HANDOFF_TTL and stops masking anything.
#
# PROCESS-TABLE SEAM. Every probe here reads the table through watcher_ps_table, which honors
# $HERD_SWEEP_PS_CMD — the seam sweep.sh's unit test already uses to plant a synthetic process table
# with no real processes at all. One seam, one table snapshot per listing: the argv0 match and the
# parent/child exemptions all resolve against the SAME sample, never two racy ones.
#
# Sourced (never executed) by bin/herd, sweep.sh, status.sh and agent-watch.sh. Defines functions +
# one constant; side-effect-free apart from the explicit handoff-marker writers. Requires nothing but
# $HERD_WATCH_ARGV0 / $HERD_WATCHER_LOCK / a worktrees dir in scope, and degrades to "no exemptions"
# when they are absent — it never crashes a caller running under `set -euo pipefail`.

# Idempotent guard: bin/herd, sweep.sh (via agent-watch.sh or directly) and status.sh may each source
# this, in any order. Unexported, so it can never leak into a spawned watcher.
if [ -z "${HERD_WATCHER_EXEMPT_LIB:-}" ]; then
HERD_WATCHER_EXEMPT_LIB=1

# How long a recorded self-restart handoff may suppress the duplicate alarm. Deliberately a constant,
# not a config key: it is an upper bound on an exec, not an operator preference. A crashed exec's
# marker stops masking after this, so a REAL duplicate can hide for at most this long.
WATCHER_HANDOFF_TTL="${HERD_WATCHER_HANDOFF_TTL:-120}"

# _wx_trees — this project's worktrees dir under whichever name the caller has in scope: bin/herd and
# status.sh export WORKTREES_DIR, agent-watch.sh/sweep.sh use TREES. Empty when none is set (a
# standalone source), which every reader below treats as "no markers, no handoff".
_wx_trees() { printf '%s' "${WORKTREES_DIR:-${HERD_WORKTREES_DIR:-${TREES:-}}}"; }

# watcher_ps_table — "pid ppid pgid command" for every process, one per line. THE seam: a test plants
# $HERD_SWEEP_PS_CMD (an executable printing a synthetic table) and no real process is ever consulted.
# `|| true` so a ps hiccup degrades to an empty table rather than aborting a `set -e` caller.
watcher_ps_table() {
  if [ -n "${HERD_SWEEP_PS_CMD:-}" ]; then "$HERD_SWEEP_PS_CMD"; return 0; fi
  ps -eo pid=,ppid=,pgid=,command= 2>/dev/null || true
}

# watcher_lock_pid — the pid RECORDED in the lockfile, alive or not. This is the identity the ppid
# exemption compares against: a fork's ppid names the watcher that spawned it, and that watcher may
# have died since (leaving the fork reparented) without invalidating the parentage record.
watcher_lock_pid() {
  [ -f "${HERD_WATCHER_LOCK:-/nonexistent}" ] || return 0
  local p; p="$(cat "$HERD_WATCHER_LOCK" 2>/dev/null || true)"
  case "$p" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s' "$p"
}

# watcher_canonical_pid — the recorded pid IFF it is a LIVE process. The watcher this project owns.
watcher_canonical_pid() {
  local p; p="$(watcher_lock_pid)"
  [ -n "$p" ] && kill -0 "$p" 2>/dev/null && printf '%s' "$p"
  return 0
}

# watcher_marker_pids — pids owned by a LIVE inflight marker (all three families), one per line.
# Uses agent-watch.sh's _marker_live (pid + start-time recycling guard) when that richer probe is in
# scope; falls back to the marker's first line + `kill -0` for a standalone source (bin/herd), which
# is exactly what _list_project_watchers did before this file existed.
watcher_marker_pids() {
  local trees f mp
  trees="$(_wx_trees)"
  [ -n "$trees" ] || return 0
  for f in "$trees"/.review-inflight-* "$trees"/.health-inflight-* "$trees"/.spawn-inflight-*; do
    [ -e "$f" ] || continue
    if declare -f _marker_live >/dev/null 2>&1; then
      _marker_live "$f" || continue
      printf '%s\n' "$(sed -n '1p' "$f" 2>/dev/null)"
    else
      mp="$(head -1 "$f" 2>/dev/null || true)"
      case "$mp" in ''|*[!0-9]*) continue ;; esac
      kill -0 "$mp" 2>/dev/null || continue
      printf '%s\n' "$mp"
    fi
  done
}

# ── Self-restart generation handoff ──────────────────────────────────────────────────────────────

# watcher_handoff_file — the marker path, or empty when no worktrees dir is in scope.
watcher_handoff_file() {
  local trees; trees="$(_wx_trees)"
  [ -n "$trees" ] || return 0
  printf '%s/.watcher-handoff' "$trees"
}

# watcher_handoff_begin <pid> — record that <pid>'s image is about to be replaced. Two lines: the
# outgoing pid, then the epoch the window opened. Fail-soft: an unwritable trees dir is a silent
# no-op (a missing marker only costs a possible transient alarm, never correctness).
watcher_handoff_begin() {
  local f; f="$(watcher_handoff_file)"
  [ -n "$f" ] || return 0
  printf '%s\n%s\n' "${1:-$$}" "$(date +%s)" > "$f" 2>/dev/null || true
  return 0
}

# watcher_handoff_clear — the incoming image calls this once it owns the singleton lock.
watcher_handoff_clear() {
  local f; f="$(watcher_handoff_file)"
  [ -n "$f" ] && rm -f "$f" 2>/dev/null
  return 0
}

# watcher_handoff_pid — the outgoing pid recorded in a FRESH handoff marker; empty otherwise.
watcher_handoff_pid() {
  watcher_handoff_active || return 0
  local f; f="$(watcher_handoff_file)"
  sed -n '1p' "$f" 2>/dev/null
}

# watcher_handoff_active — success iff a handoff marker exists and its window has not expired. A
# marker with an unreadable/absent epoch is treated as EXPIRED (fail toward telling the truth: we
# would rather show a real duplicate than let a corrupt marker mask one forever).
watcher_handoff_active() {
  local f ts now
  f="$(watcher_handoff_file)"
  [ -n "$f" ] && [ -f "$f" ] || return 1
  ts="$(sed -n '2p' "$f" 2>/dev/null)"
  case "$ts" in ''|*[!0-9]*) return 1 ;; esac
  now="$(date +%s)"
  [ $(( now - ts )) -ge 0 ] || return 1          # clock stepped backwards ⇒ do not trust the window
  [ $(( now - ts )) -lt "$WATCHER_HANDOFF_TTL" ]
}

# ── The exemption check ──────────────────────────────────────────────────────────────────────────

# watcher_has_gate_child <pid> <table> — success iff some row of <table> is a live gate worker or lane
# dispatch whose PARENT is <pid>. The table is passed in so the parent/child edge resolves against the
# SAME snapshot the caller matched argv0 against — no second, racy `ps`.
#
# NOT a listing clause (see the header): this predicate cannot tell a reparented fork from a watcher
# main that dispatched a gate worker, so it is safe ONLY on a surface that never kills. Its one caller
# is sweep.sh's sweep_stray_watchers (detection).
#
# Matched with `case` globs, not a grep: this runs per candidate pid per child row, and forking a grep
# for each would allocate a process to answer a question about a string we already hold.
watcher_has_gate_child() {
  local parent="${1:-}" table="${2:-}" cpid cppid cpgid ccmd
  [ -n "$parent" ] || return 1
  while read -r cpid cppid cpgid ccmd; do
    [ "$cppid" = "$parent" ] || continue
    case " $ccmd " in
      # gate workers (HERD-245) + the backgrounded lane dispatches (HERD-237).
      *healthcheck.sh*|*herd-review.sh*) return 0 ;;
      *herd-feature.sh*|*herd-quick.sh*|*herd-resolve.sh*) return 0 ;;
    esac
  done <<EOF
$table
EOF
  return 1
}

# _wx_exempt <pid> <ppid> <lockpid> <live-pids-padded> — the pure LISTING predicate (clauses 1+2), with
# the two expensive sets (lockfile pid, live marker pids) precomputed by the caller so a whole listing
# pass costs one marker glob, not one per pid. <live-pids-padded> is " p1 p2 … " for substring matching.
# Deliberately does NOT consult watcher_has_gate_child — that guard would exempt a gate-running stray
# from the kill list. See the header.
_wx_exempt() {
  local pid="${1:-}" ppid="${2:-}" lockpid="${3:-}" live="${4:- }"
  case "$live" in *" $pid "*) return 0 ;; esac                       # (1) marker-owned
  [ -n "$lockpid" ] && [ "$ppid" = "$lockpid" ] && return 0          # (2) child of the canonical watcher
  return 1
}

# watcher_pid_exempt <pid> <ppid> — the same LISTING predicate for a ONE-OFF caller, computing the sets
# itself. Success ⇒ <pid> carries our argv0 but is NOT a watcher main.
watcher_pid_exempt() {
  local live
  live=" $(watcher_marker_pids | tr '\n' ' ')"
  _wx_exempt "${1:-}" "${2:-}" "$(watcher_lock_pid)" "$live"
}

# watcher_list_mains [table] — THE canonical enumeration of this project's watcher MAINS, one pid per
# line, de-duplicated: the union of
#   (a) the lockfile pid, when alive — the watcher this project recorded; and
#   (b) every process whose argv0 is EXACTLY $HERD_WATCH_ARGV0 and which is not exempt per _wx_exempt.
# argv0 is matched as the command's FIRST TOKEN, never as a pgrep substring, so workspace "north"
# never captures "northern"'s watcher and "app" never captures "apple"'s (issue #60). Clause (b) finds
# lock-ABSENT strays too — the "no running watcher found while 2 alive" case — INCLUDING a stray that
# has already dispatched a gate worker. UNTAGGED legacy watchers carry no marker and are NOT returned;
# _stop_project_watcher still reaps those via its lsof/cwd fallback. Callers may pass a table they
# already sampled; otherwise one is taken here.
#
# This list feeds BOTH the `herd status` count AND _stop_project_watcher's SIGTERM loop, so a pid
# omitted here is a pid the duplicate safety rail will never stop. Nothing may be exempted from it
# that has not been PROVEN to be a fork (clauses 1+2). sweep.sh's sweep_stray_watchers, which only
# detects, layers its own extra gate-child guard on top of this listing.
watcher_list_mains() {
  local table="${1:-}" marker="${HERD_WATCH_ARGV0:-}" lockpid canon live
  local pid ppid pgid cmd argv0 seen=" "
  [ -n "$table" ] || table="$(watcher_ps_table)"
  lockpid="$(watcher_lock_pid)"
  canon="$(watcher_canonical_pid)"
  live=" $(watcher_marker_pids | tr '\n' ' ')"
  if [ -n "$canon" ]; then
    printf '%s\n' "$canon"; seen=" $canon "
  fi
  [ -n "$marker" ] || return 0
  while read -r pid ppid pgid cmd; do
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    argv0="${cmd%%[[:space:]]*}"
    [ "$argv0" = "$marker" ] || continue
    case "$seen" in *" $pid "*) continue ;; esac
    _wx_exempt "$pid" "$ppid" "$lockpid" "$live" && continue
    printf '%s\n' "$pid"; seen="$seen$pid "
  done <<EOF
$table
EOF
}

fi
