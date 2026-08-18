#!/usr/bin/env bash
# codex-durable-coordinator.sh — a herd-owned DURABLE, STEERABLE, CANCELLABLE Codex session (HERD-766,
# step 7 of the HERD-754 Codex/Grok portability epic). The Codex counterpart of what herd-feature.sh
# gives a Claude builder (spawn, steer mid-session, observe progress, cancel), built on top of
# codex-exec-adapter.sh's (HERD-760) bounded one-shot call rather than replacing it.
#
# GROUND TRUTH, NOT GUESSED (2026-08-18, codex-cli 0.147.0 @ /opt/homebrew/bin/codex). `codex --help`
# was read exhaustively before writing a line of code here. Two experimental daemon/socket surfaces
# exist (`codex app-server`, `codex exec-server`) but are undocumented protocol servers meant for a
# GUI/IDE host, not a scriptable CLI contract, and ship no npm/pip SDK alongside the CLI — building
# against them tonight would be exactly the "guessed API shape" the task spec forbids. What IS a real,
# documented, and — critically — EMPIRICALLY VERIFIED durable surface is `codex exec resume`, proven
# live in a scratch worktree (not assumed) before this file was written:
#   1. `codex exec --json --sandbox workspace-write -C <workdir> -- <prompt>` starts a session and
#      emits `{"type":"thread.started","thread_id":"<uuid>"}` — a REAL, stable session identifier.
#   2. `codex exec -C <workdir> --sandbox workspace-write resume --json <thread_id> -- <prompt>`
#      (isolation flags stay at the `exec` level — `resume`'s OWN flag set has no -C/--sandbox despite
#      --help listing --sandbox as valid; passing it there fails with "unexpected argument '--sandbox'
#      found", a real CLI parsing quirk between --help text and clap's actual arg placement) continues
#      the SAME thread — re-emits the SAME thread_id, and the model correctly recalls prior-turn
#      content (verified: asked it to reply with one word, then in a SEPARATE process a turn later
#      asked what that word was — it answered correctly). This is genuine steering: send a new
#      instruction to a persistent session between turns, the same interaction shape a human steers a
#      herdr builder pane with (wait for idle, send the next instruction).
#   3. Cancellation: SIGTERM to the *actual* `codex exec` process kills codex itself cleanly, but does
#      NOT reliably kill an in-flight shell-command child it already spawned — this was WRONG in an
#      earlier pass of this file and corrected after a harder re-test (see codex_durable_cancel's own
#      header for the full live repro: cancelling 3s into a `sleep 20` left the sleep process AND its
#      parent shell orphaned and running to completion). Root cause: codex puts each shell command it
#      runs in its OWN process group (verified via `ps -o pid,pgid,ppid`), so signalling codex alone
#      cannot rely on group-signal delivery reaching it. This file's cancel path compensates by
#      capturing and sweeping codex's full descendant process tree explicitly — see
#      _codex_durable_descendants / codex_durable_cancel. The session itself survives being killed
#      mid-turn either way — a subsequent `resume` on the same thread_id continues normally (verified
#      repeatedly, including after the corrected orphan-sweeping cancel — see LAUNCH MECHANISM below).
#   4. `-C` MUST be re-supplied on every resume call, at the `codex exec` (parent) level, never
#      `resume`'s own flags — verified live: a resume issued from a DIFFERENT cwd with no `-C` silently
#      ran shell commands in that cwd instead of the original workdir (asked codex to `pwd`; it printed
#      the invoking shell's cwd, not the session's original one). `codex exec resume` does NOT persist
#      the workdir from the start call — this file re-passes -C/--sandbox on every resume, closing that
#      isolation gap. `--skip-git-repo-check` is unneeded when -C points at a real git worktree
#      (verified: resume succeeded without it once -C pointed at a git worktree).
# `codex exec resume --last` exists but scope (does it filter by cwd?) was not fully characterized, so
# this file never relies on it — every resume call passes the EXPLICIT thread_id captured from the
# start call's own stdout, per the task spec's explicit design requirement.
#
# LAUNCH MECHANISM (why a bare `cmd &` is not enough for durability): a background job's exit code can
# only be reaped by `wait` from the SAME shell that forked it — useless once this file's caller (a
# coordinator loop, a test, a Bash-tool invocation) is a different process than whatever later calls
# codex_durable_wait/status/cancel. So every turn is launched inside a small SIGTERM-trapping subshell
# that is itself backgrounded and disowned (`( trap ...; codex ... & child=$!; wait "$child"; echo
# $? >turns/NNN.exit ) & disown`), and the WRAPPER's pid is what codex_durable_cancel signals first.
# This was verified two ways BEFORE settling on it: a naive `(codex ... ; echo $? >exit) &` wrapper
# with NO trap leaks the codex process itself on SIGTERM (confirmed live — killing the wrapper left a
# still-running codex process behind); adding `trap 'kill -TERM "$child"; wait "$child"; exit 143'
# TERM` fixes THAT leak (confirmed live) — SIGTERM to the wrapper now cleanly kills codex itself, and
# normal (non-cancelled) completion still writes the real exit code to turns/NNN.exit. A cancelled turn
# deliberately does NOT get an exit file (the trap short-circuits before reaching that line) —
# cancellation is tracked as its own session_state, never confused with a real turn outcome. This
# wrapper trap is necessary but NOT sufficient for a fully orphan-free cancel — codex's own
# shell-command children are a SEPARATE leak the wrapper trap does not reach (see finding 3 above and
# codex_durable_cancel's header), which is why cancel also sweeps codex's descendant tree explicitly.
#
# A SECOND launch-mechanism bug was found and fixed the same way, by testing the ACTUAL failure mode
# rather than trusting a design that looked right: codex_durable_steer/start were reliably returning
# immediately when their stdout went straight to a terminal or `>/dev/null`, but reliably BLOCKED for
# the turn's full duration (tens of seconds) when a caller captured their output via `out="$(...)"` —
# exactly the shape every caller in this file's own CLI and test suite actually needs. Root cause:
# `out="$(...)"` makes bash read from a PIPE until every process holding its write end closes it. The
# launch wrapper subshell above is forked (via `&`) from INSIDE that command substitution, so it
# inherits a copy of that pipe's write end — and even though it never WRITES to stdout, disowning it
# does not close that inherited fd, so the pipe stays open (and bash's read blocks) for the wrapper's
# entire lifetime, i.e. until the turn itself finishes. FIX: the wrapper's OWN stdio must be
# redirected away from whatever it inherited BEFORE backgrounding — `( ... ) </dev/null >/dev/null
# 2>&1 &` — the standard daemonizing idiom, which this file was missing on the OUTER group (codex's
# own stdio was already correctly redirected to turns/NNN.{jsonl,err}; the wrapper's was not).
# Verified fixed live: with the redirection in place, `out="$(codex_durable_steer ...)"` returns in
# under a second even while the launched turn is still running.
#
# WHY NOT AN SDK: no npm/pip package ships alongside codex-cli 0.147.0 exposing a programmatic API —
# `codex exec resume` (a documented CLI subcommand) is the only genuinely verified durable surface, so
# that is what this file builds against, exactly as the task spec's decision tree calls for.
#
# CONTRACT (mirrors codex-exec-adapter.sh's shape):
#   • SOURCED, not executed, by callers: `. "$HERE/codex-durable-coordinator.sh"` (which itself sources
#     codex-exec-adapter.sh for codex_exec_adapter_bin/available/parse_events — REUSED, not
#     reimplemented, per the task spec). Also RUNNABLE as a CLI: `bash codex-durable-coordinator.sh
#     {start|steer|status|wait|cancel} ...`.
#   • ISOLATION: every launched turn (start AND every steer) runs `codex exec -C <workdir> --sandbox
#     workspace-write [--model M] --json [resume <thread_id>] -- <prompt>` — never
#     `--dangerously-bypass-approvals-and-sandbox`, and -C/--sandbox are re-supplied on every resume
#     per finding 4 above.
#   • ONE session per <session_dir> (a caller-owned bookkeeping directory, separate from <workdir> so a
#     builder's actual worktree never gets coordinator-control files mixed into its git status):
#       <session_dir>/workdir     — the isolated worktree this session is scoped to
#       <session_dir>/thread_id   — codex's real thread id, written once known
#       <session_dir>/turn        — the current/last turn number
#       <session_dir>/status      — "cancelled" once codex_durable_cancel has run; otherwise absent
#       <session_dir>/pid         — wrapper pid while a turn is in flight; removed once it exits
#       <session_dir>/turns/NNN.{jsonl,err,exit} — per-turn raw output, exactly like the bounded
#         adapter's raw stream, parsed by the SAME codex_exec_adapter_parse_events function
#   • OUTPUT SCHEMA (every public function prints one line of JSON): {session_dir, workdir, thread_id,
#     turn_number, pid, session_state, turn}. session_state is this file's OWN small vocabulary —
#     working | idle | cancelled — deliberately distinct from codex_exec_adapter_parse_events' turn-level
#     state (starting/working/completed/failed/unknown), which is nested unchanged under "turn" (null
#     while a turn is still in flight and no prior turn exists yet).
#   • FAIL SOFT on missing tools (no codex/jq on PATH), same as the bounded adapter.

# ── sourcing (adapter reuse) ────────────────────────────────────────────────────────────────────────
_CODEX_DURABLE_HERE="${_CODEX_DURABLE_HERE:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
# shellcheck source=/dev/null
. "$_CODEX_DURABLE_HERE/codex-exec-adapter.sh"

# codex_durable_bin / codex_durable_available — thin pass-throughs to the adapter's own (CODEX_BIN
# is the same test/override seam for both files).
codex_durable_bin() { codex_exec_adapter_bin; }
codex_durable_available() { codex_exec_adapter_available; }

_codex_durable_pid_alive() {
  local pid="${1:-}"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

# _codex_durable_descendants <pid> — print every descendant pid of <pid> (children, grandchildren,
# ...), one per line, via a BFS walk of `pgrep -P`. Needed because codex spawns each shell command it
# runs in its OWN process group (verified live: `ps -o pid,pgid,ppid` on a running `sleep 20` command
# showed pgid == the shell's own pid, ppid == codex's pid — NOT codex's process group), so a single
# `kill -TERM <codex-pid>` cannot rely on group-signal delivery to reach it; this walk is what lets
# codex_durable_cancel find and sweep that whole tree explicitly. Fail-soft: prints nothing if pgrep
# is unavailable (same convention as agent-watch.sh/status.sh/fleet.sh's existing pgrep call sites).
_codex_durable_descendants() {
  local root="${1:-}"
  command -v pgrep >/dev/null 2>&1 || return 0
  [ -n "$root" ] || return 0
  local -a queue=("$root") out=()
  local pid kid
  while [ "${#queue[@]}" -gt 0 ]; do
    pid="${queue[0]}"; queue=("${queue[@]:1}")
    while IFS= read -r kid; do
      [ -n "$kid" ] || continue
      out+=("$kid")
      queue+=("$kid")
    done < <(pgrep -P "$pid" 2>/dev/null || true)
  done
  [ "${#out[@]}" -gt 0 ] && printf '%s\n' "${out[@]}"
  return 0
}

_codex_durable_turn_number() {
  local session_dir="${1:-}"
  if [ -f "$session_dir/turn" ]; then cat "$session_dir/turn" 2>/dev/null || printf '0'; else printf '0'; fi
}

_codex_durable_turn_stem() {
  local session_dir="${1:-}" turn="${2:-0}"
  printf '%s/turns/%03d' "$session_dir" "$turn"
}

# codex_durable_init <session_dir> <workdir> — create/refresh the bookkeeping directory. Idempotent;
# safe to call before every start/steer. Returns 2 on bad args (usage error), 0 otherwise.
codex_durable_init() {
  local session_dir="${1:-}" workdir="${2:-}"
  if [ -z "$session_dir" ] || [ -z "$workdir" ]; then
    echo "codex_durable_init: usage: codex_durable_init <session_dir> <workdir>" >&2
    return 2
  fi
  if [ ! -d "$workdir" ]; then
    echo "codex_durable_init: workdir does not exist: $workdir" >&2
    return 2
  fi
  mkdir -p "$session_dir/turns" 2>/dev/null || { echo "codex_durable_init: cannot create $session_dir/turns" >&2; return 2; }
  printf '%s' "$workdir" > "$session_dir/workdir"
  [ -f "$session_dir/turn" ] || printf '0' > "$session_dir/turn"
  return 0
}

# _codex_durable_launch <session_dir> <workdir> <thread_id-or-empty> <prompt> [model] — internal:
# launch ONE turn (start when thread_id is empty, steer/resume otherwise) in the trap-wrapped
# background subshell described in the file header. Writes pid/turn bookkeeping. Prints the new turn
# number. Never blocks on the turn finishing.
_codex_durable_launch() {
  local session_dir="$1" workdir="$2" thread_id="$3" prompt="$4" model="${5:-}"
  local turn stem out err exitf bin
  turn=$(( $(_codex_durable_turn_number "$session_dir") + 1 ))
  printf '%s' "$turn" > "$session_dir/turn"
  rm -f "$session_dir/status"
  stem="$(_codex_durable_turn_stem "$session_dir" "$turn")"
  out="$stem.jsonl"; err="$stem.err"; exitf="$stem.exit"
  bin="$(codex_durable_bin)"

  local -a args
  args=(exec -C "$workdir" --sandbox workspace-write)
  [ -n "$model" ] && args+=(--model "$model")
  args+=(--json)
  if [ -n "$thread_id" ]; then
    args+=(resume "$thread_id")
  fi
  args+=(-- "$prompt")

  (
    trap 'kill -TERM "$child" 2>/dev/null; wait "$child" 2>/dev/null; exit 143' TERM
    "$bin" "${args[@]}" </dev/null >"$out" 2>"$err" &
    child=$!
    wait "$child"
    echo $? > "$exitf"
  ) </dev/null >/dev/null 2>&1 &
  local wrapper_pid=$!
  disown "$wrapper_pid" 2>/dev/null || true
  printf '%s' "$wrapper_pid" > "$session_dir/pid"
  printf '%s' "$turn"
}

# _codex_durable_wait_for_thread_id <session_dir> <turn> — best-effort poll (bounded by
# CODEX_DURABLE_START_TIMEOUT seconds, default 10) of a just-launched turn's raw output for the
# thread.started event. Prints the thread id (empty if not seen in time / codex missing / jq missing).
# Never blocks past the turn's own process exit or the timeout, whichever is first.
_codex_durable_wait_for_thread_id() {
  local session_dir="$1" turn="$2" out pid tid tries max_tries
  out="$(_codex_durable_turn_stem "$session_dir" "$turn").jsonl"
  pid="$(cat "$session_dir/pid" 2>/dev/null || true)"
  max_tries=$(( ${CODEX_DURABLE_START_TIMEOUT:-10} * 2 ))
  tries=0
  command -v jq >/dev/null 2>&1 || { printf ''; return 0; }
  while [ "$tries" -lt "$max_tries" ]; do
    if [ -s "$out" ]; then
      tid="$(jq -rs '[.[] | select(.type=="thread.started") | .thread_id] | first // empty' "$out" 2>/dev/null)"
      if [ -n "$tid" ] && [ "$tid" != "null" ]; then printf '%s' "$tid"; return 0; fi
    fi
    _codex_durable_pid_alive "$pid" || break
    sleep 0.5
    tries=$((tries+1))
  done
  printf ''
}

# codex_durable_start <session_dir> <workdir> <prompt> [model] — spawn a NEW durable session: launches
# the first turn in the background, captures the real thread_id from its own stdout (never guessed),
# and returns immediately (does not wait for the turn to finish). Returns 2 on usage error, 1 if a
# session is already in flight in this session_dir, 0 otherwise (thread_id may still be null in the
# printed JSON if it was not observed within CODEX_DURABLE_START_TIMEOUT — call codex_durable_status
# to keep watching).
codex_durable_start() {
  local session_dir="${1:-}" workdir="${2:-}" prompt="${3:-}" model="${4:-}"
  if [ -z "$session_dir" ] || [ -z "$workdir" ] || [ -z "$prompt" ]; then
    echo "codex_durable_start: usage: codex_durable_start <session_dir> <workdir> <prompt> [model]" >&2
    return 2
  fi
  if ! codex_durable_available; then
    printf '{"session_dir":null,"workdir":null,"thread_id":null,"turn_number":0,"pid":null,"session_state":"idle","turn":{"exit_code":127,"raw_event_count":0,"thread_id":null,"usage":null,"turn_error":null,"top_level_errors":[],"items":[],"final_agent_message":null,"state":"failed","state_reason":"codex-binary-not-found"}}\n'
    return 1
  fi
  codex_durable_init "$session_dir" "$workdir" || return 2
  local pid
  pid="$(cat "$session_dir/pid" 2>/dev/null || true)"
  if _codex_durable_pid_alive "$pid"; then
    echo "codex_durable_start: a turn is already in flight in $session_dir (pid $pid)" >&2
    return 1
  fi
  rm -f "$session_dir/thread_id"
  local turn tid
  turn="$(_codex_durable_launch "$session_dir" "$workdir" "" "$prompt" "$model")"
  tid="$(_codex_durable_wait_for_thread_id "$session_dir" "$turn")"
  [ -n "$tid" ] && printf '%s' "$tid" > "$session_dir/thread_id"
  codex_durable_status "$session_dir"
}

# codex_durable_steer <session_dir> <prompt> [model] — send a NEW instruction to an EXISTING durable
# session's thread (a resumed turn). Requires codex_durable_start to have already captured a
# thread_id, and requires no turn currently in flight (this file never attempts concurrent resumes on
# one thread — that combination was not tested and codex's own concurrency behavior there is unknown).
# Returns 2 on usage error / no thread_id yet, 1 if a turn is already in flight, 0 otherwise.
codex_durable_steer() {
  local session_dir="${1:-}" prompt="${2:-}" model="${3:-}"
  if [ -z "$session_dir" ] || [ -z "$prompt" ]; then
    echo "codex_durable_steer: usage: codex_durable_steer <session_dir> <prompt> [model]" >&2
    return 2
  fi
  local workdir thread_id pid
  workdir="$(cat "$session_dir/workdir" 2>/dev/null || true)"
  thread_id="$(cat "$session_dir/thread_id" 2>/dev/null || true)"
  if [ -z "$workdir" ] || [ -z "$thread_id" ]; then
    echo "codex_durable_steer: no durable session (thread_id) found in $session_dir — call codex_durable_start first" >&2
    return 2
  fi
  pid="$(cat "$session_dir/pid" 2>/dev/null || true)"
  if _codex_durable_pid_alive "$pid"; then
    echo "codex_durable_steer: a turn is already in flight in $session_dir (pid $pid) — wait or cancel first" >&2
    return 1
  fi
  # A THIRD launch-mechanism finding (see _codex_durable_launch's header for the first two): discarding
  # this call's stdout via a `>` REDIRECT (`_codex_durable_launch ... >/dev/null`) reintroduces the
  # exact same pipe-hang bug even with the wrapper's own stdio already detached — verified live, and
  # bisected down to the `>` operator specifically (a `$(...)` command-substitution discard, used here,
  # does NOT trigger it; only a `>` redirect on the function CALL does). Root cause, as far as this was
  # bisectable without reading bash's C source: `fn >/dev/null` temporarily dup2's the CALLER's fd 1 for
  # the duration of the call, and whatever bash uses internally to save/restore the previous fd 1 is
  # itself inherited by any background job forked during that window — my explicit `</dev/null
  # >/dev/null 2>&1` on the wrapper's own `(...)` group only covers fds 0/1/2, not that internal
  # save-slot. A `$(...)` discard forks a plain subshell instead (no save/restore step), which is why it
  # doesn't have this problem.
  local _codex_durable_discard
  _codex_durable_discard="$(_codex_durable_launch "$session_dir" "$workdir" "$thread_id" "$prompt" "$model")"
  codex_durable_status "$session_dir"
}

# _codex_durable_compose <session_dir> — build the shared output-schema JSON object (see file header)
# from whatever is on disk right now. Pure read; no side effects. Used by status/wait/cancel/start.
_codex_durable_compose() {
  local session_dir="${1:-}"
  local workdir thread_id turn pid state stem turn_json session_state
  workdir="$(cat "$session_dir/workdir" 2>/dev/null || true)"
  thread_id="$(cat "$session_dir/thread_id" 2>/dev/null || true)"
  turn="$(_codex_durable_turn_number "$session_dir")"
  pid="$(cat "$session_dir/pid" 2>/dev/null || true)"

  if _codex_durable_pid_alive "$pid"; then
    session_state="working"
    turn_json="null"
  else
    [ -f "$session_dir/pid" ] && rm -f "$session_dir/pid"
    pid=""
    if [ -f "$session_dir/status" ] && [ "$(cat "$session_dir/status" 2>/dev/null)" = "cancelled" ]; then
      session_state="cancelled"
    else
      session_state="idle"
    fi
    stem="$(_codex_durable_turn_stem "$session_dir" "$turn")"
    if [ "$turn" -gt 0 ] && [ -f "$stem.exit" ]; then
      turn_json="$(codex_exec_adapter_parse_events "$stem.jsonl" "$(cat "$stem.exit" 2>/dev/null || echo 1)" 2>/dev/null || true)"
      [ -z "$turn_json" ] && turn_json="null"
    else
      turn_json="null"
    fi
  fi

  if command -v jq >/dev/null 2>&1; then
    jq -n -c \
      --arg session_dir "$session_dir" \
      --arg workdir "$workdir" \
      --arg thread_id "$thread_id" \
      --argjson turn_number "${turn:-0}" \
      --arg pid "$pid" \
      --arg session_state "$session_state" \
      --argjson turn "$turn_json" \
      '{session_dir: $session_dir, workdir: $workdir,
        thread_id: (if $thread_id == "" then null else $thread_id end),
        turn_number: $turn_number,
        pid: (if $pid == "" then null else ($pid | tonumber) end),
        session_state: $session_state, turn: $turn}'
  else
    printf '{"session_dir":"%s","workdir":"%s","thread_id":null,"turn_number":%s,"pid":null,"session_state":"%s","turn":null}\n' \
      "$session_dir" "$workdir" "${turn:-0}" "$session_state"
  fi
}

# codex_durable_status <session_dir> — NON-BLOCKING observe: prints the current session snapshot
# (see output schema above) and returns immediately. Returns 0 if session_state is idle/cancelled and
# the last turn completed cleanly, 1 otherwise (working, cancelled, or a failed last turn) — mirrors
# codex_exec_adapter_run's boolean-function contract.
codex_durable_status() {
  local session_dir="${1:-}"
  [ -n "$session_dir" ] || { echo "codex_durable_status: usage: codex_durable_status <session_dir>" >&2; return 2; }
  local out
  out="$(_codex_durable_compose "$session_dir")"
  printf '%s\n' "$out"
  command -v jq >/dev/null 2>&1 || return 1
  [ "$(printf '%s' "$out" | jq -r '.session_state')" = "idle" ] && \
    [ "$(printf '%s' "$out" | jq -r '.turn.state // "failed"')" = "completed" ]
}

# codex_durable_wait <session_dir> [timeout_seconds] — BLOCKING observe: poll until the in-flight turn
# exits or <timeout_seconds> (default 300) elapses, then behave exactly like codex_durable_status.
# Returns 1 (without cancelling anything) if the timeout is hit while still working — the caller
# decides whether to keep waiting or call codex_durable_cancel.
codex_durable_wait() {
  local session_dir="${1:-}" timeout="${2:-300}"
  [ -n "$session_dir" ] || { echo "codex_durable_wait: usage: codex_durable_wait <session_dir> [timeout_seconds]" >&2; return 2; }
  local pid waited=0
  pid="$(cat "$session_dir/pid" 2>/dev/null || true)"
  while _codex_durable_pid_alive "$pid" && [ "$waited" -lt "$timeout" ]; do
    sleep 1
    waited=$((waited+1))
  done
  codex_durable_status "$session_dir"
}

# codex_durable_cancel <session_dir> [grace_seconds] — interrupt an in-flight turn. GROUND TRUTH
# (verified live, and corrected mid-build after the FIRST design was proven wrong): SIGTERM to the
# launch wrapper reliably forwards to the real codex process and kills IT cleanly, but codex does NOT
# reliably kill its own in-flight shell-command child on SIGTERM — reproduced live: cancelling a turn
# 3s into `sleep 20 && touch <marker>` (well before the command finished) left `sleep 20` and its
# parent `zsh -c ...` running as orphans, and the marker file existed minutes later, meaning the
# command ran to completion UNSUPERVISED after codex itself was gone. A second live run with an
# earlier cancel (before the shell child had even been spawned) looked "clean" purely because nothing
# was running yet to leak — that false negative is why this went through a second, harder validation
# pass before shipping. Root cause: codex spawns each shell command in ITS OWN process group (verified
# via `ps -o pid,pgid,ppid`: the child's pgid equals its own pid, not codex's), so a plain
# `kill -TERM <codex-pid>` cannot rely on group-signal delivery reaching it either.
# FIX: capture the codex process's full descendant tree (_codex_durable_descendants) BEFORE signalling
# anything, then — after the primary SIGTERM/grace/SIGKILL sequence on the wrapper — sweep every
# pid in that captured list that is still alive with SIGTERM then SIGKILL. No-op (fail-soft, still
# returns 0) if nothing is in flight. The session's thread_id/workdir stay on disk — a subsequent
# codex_durable_steer resumes the SAME thread (verified: resume works cleanly after a mid-turn cancel,
# including this corrected orphan-sweeping version).
codex_durable_cancel() {
  local session_dir="${1:-}" grace="${2:-5}"
  [ -n "$session_dir" ] || { echo "codex_durable_cancel: usage: codex_durable_cancel <session_dir> [grace_seconds]" >&2; return 2; }
  local pid waited=0
  pid="$(cat "$session_dir/pid" 2>/dev/null || true)"
  if _codex_durable_pid_alive "$pid"; then
    printf 'cancelled' > "$session_dir/status"
    local -a tree=()
    while IFS= read -r d; do [ -n "$d" ] && tree+=("$d"); done < <(_codex_durable_descendants "$pid")
    kill -TERM "$pid" 2>/dev/null || true
    while _codex_durable_pid_alive "$pid" && [ "$waited" -lt "$grace" ]; do
      sleep 1
      waited=$((waited+1))
    done
    _codex_durable_pid_alive "$pid" && kill -KILL "$pid" 2>/dev/null || true
    local d
    for d in "${tree[@]:-}"; do
      [ -n "$d" ] || continue
      _codex_durable_pid_alive "$d" || continue
      kill -TERM "$d" 2>/dev/null || true
    done
    if [ "${#tree[@]}" -gt 0 ]; then
      sleep 1
      for d in "${tree[@]}"; do
        [ -n "$d" ] || continue
        _codex_durable_pid_alive "$d" && kill -KILL "$d" 2>/dev/null || true
      done
    fi
  fi
  codex_durable_status "$session_dir"
}

# ── CLI entrypoint ───────────────────────────────────────────────────────────────────────────────
# Only runs when EXECUTED (not sourced), mirroring codex-exec-adapter.sh's dual shape.
_codex_durable_cli() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    init)      codex_durable_init "$@" ;;
    start)     codex_durable_start "$@" ;;
    steer)     codex_durable_steer "$@" ;;
    status)    codex_durable_status "$@" ;;
    wait)      codex_durable_wait "$@" ;;
    cancel)    codex_durable_cancel "$@" ;;
    available) if codex_durable_available; then echo yes; else echo no; return 1; fi ;;
    *) printf 'usage: codex-durable-coordinator.sh {init <session_dir> <workdir>|start <session_dir> <workdir> <prompt> [model]|steer <session_dir> <prompt> [model]|status <session_dir>|wait <session_dir> [timeout_seconds]|cancel <session_dir> [grace_seconds]|available}\n' >&2; return 2 ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  _codex_durable_cli "$@"
fi
