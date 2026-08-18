#!/usr/bin/env bash
# codex-exec-adapter.sh — a herd-owned adapter around `codex exec --json` for BOUNDED, ONE-SHOT
# Codex work (HERD-760, step 4 of the HERD-754 Codex/Grok portability epic). The Codex counterpart
# of what herd-feature.sh does for a Claude builder — EXCEPT herd-feature.sh spawns a DURABLE,
# resumable herdr pane session, and this adapter does not: it wraps a single, synchronous
# `codex exec --json <prompt>` call and returns once that one call finishes. Durable Codex
# coordination (a long-lived, resumable session the coordinator can poll/steer over time) is step 7
# of the same epic and is explicitly OUT of scope here — see the task spec this shipped from.
#
# ADDITIVE ONLY: this does not touch, wrap, or replace herd-feature.sh / herd-quick.sh's existing
# Claude spawn path, nor templates/drivers/codex.driver's DRIVER_AGENT_ONESHOT_EXEC binding (that
# binding is researched-but-unexercised scaffolding for a FUTURE full-autonomy builder lane, and
# deliberately uses `--dangerously-bypass-approvals-and-sandbox`; this adapter is a narrower,
# STRICTER tool built for a different job — see ISOLATION below).
#
# GROUND TRUTH, NOT GUESSED (2026-08-18, codex-cli 0.147.0 @ /opt/homebrew/bin/codex): every event
# shape this file parses was observed from REAL `codex exec --json` invocations in a scratch
# worktree before writing a line of parsing code — a success run, an invalid-model failure, a failed
# shell command, and a dash-prefixed prompt (see tests/test-codex-exec-adapter.sh for the captured
# fixtures). Observed event stream, in order:
#   {"type":"thread.started","thread_id":"<uuid>"}
#   {"type":"turn.started"}
#   {"type":"item.started","item":{"id":"item_N","type":"command_execution","command":"...",
#                                   "aggregated_output":"","exit_code":null,"status":"in_progress"}}
#   {"type":"item.completed","item":{...}}          # terminal record of an item — agent_message
#                                                     # {id,type,text}; command_execution adds
#                                                     # exit_code/status/aggregated_output; error
#                                                     # adds message. item.completed is authoritative;
#                                                     # item.started is a progress echo only.
#   {"type":"turn.completed","usage":{"input_tokens":N,"cached_input_tokens":N,
#                                      "cache_write_input_tokens":N,"output_tokens":N,
#                                      "reasoning_output_tokens":N}}
#   {"type":"turn.failed","error":{"message":"..."}}          # instead of turn.completed, on failure
#   {"type":"error","message":"..."}                          # a top-level protocol/API error
# `codex exec` is genuinely STATELESS per call in the sense this adapter cares about: thread_id
# identifies the ONE turn just run (real, not invented — null if codex crashed before even emitting
# thread.started), but nothing here resumes it. `codex exec resume <id>` exists and could continue
# that thread, but wiring that up is durable-session territory (step 7), not this adapter's job.
# Process exit code observed: 0 on turn.completed, 1 on turn.failed. A killed/timed-out process may
# exit some other nonzero code with a truncated/absent JSONL tail — see state_reason below.
#
# STATE VOCABULARY (design req 2) — this adapter owns a small, stable vocabulary, derived ONLY from
# the event types codex actually emits (never guessed): starting / working / completed / failed /
# unknown. codex_exec_adapter_event_state maps one raw `.type` to it; codex_exec_adapter_parse_events
# folds a whole run down to ONE terminal state the same way — completed iff the LAST mapped event
# was "completed" AND the process exit code was 0, failed otherwise. This is the ONLY place either
# judgment is made (design req 3): callers get a typed JSON object back and never grep raw text.
#
# NEVER INFERRED FROM (design req 4): pane text, process names/argv, or codex's stderr chatter (e.g.
# the harmless "Reading additional input from stdin..." line codex always prints — observed on every
# run here, success or failure, so it is deliberately NEVER inspected for control flow). Only codex's
# own structured stdout events and its real process exit code decide state.
#
# ISOLATION (design req 5): codex_exec_adapter_run takes a REQUIRED <workdir> and always runs
# `codex exec --sandbox workspace-write -C <workdir>` — scoped read/write to that one directory,
# NEVER `--dangerously-bypass-approvals-and-sandbox`. The caller is responsible for <workdir> being
# an isolated git worktree (new-feature.sh's job, not this adapter's); a non-worktree <workdir> gets
# a loud stderr warning, not a hard abort, since a caller may legitimately point this at a plain
# scratch directory for a read-only/no-repo probe.
#
# CONTRACT:
#   • SOURCED, not executed, by callers: `. "$HERE/codex-exec-adapter.sh"`. Defines functions only —
#     no side effects at source time (safe in hermetic tests). Also RUNNABLE as a CLI, mirroring
#     driver.sh's dual sourced/executable shape: `bash codex-exec-adapter.sh run <workdir> <prompt>
#     [model]`.
#   • FAIL SOFT on missing tools: no `codex` binary or no `jq` on PATH degrades to a typed
#     state=failed JSON object (never a crash under a caller's `set -euo pipefail`).
#   • codex_exec_adapter_run returns 0 iff state=="completed", 1 otherwise (turn failure, nonzero
#     exit, unparseable/truncated output, or a missing tool) — a normal bash boolean-function
#     contract so callers can `if codex_exec_adapter_run …; then`.

# The state-map is the SINGLE source of truth for the raw-event → adapter-vocabulary mapping, shared
# by codex_exec_adapter_event_state and codex_exec_adapter_parse_events so the two can never drift.
_CODEX_EXEC_ADAPTER_STATE_MAP='{"thread.started":"starting","turn.started":"working","item.started":"working","item.completed":"working","turn.completed":"completed","turn.failed":"failed","error":"failed"}'

# codex_exec_adapter_bin — the codex executable to invoke. CODEX_BIN overrides (test seam); default
# 'codex' (resolved via PATH, exactly like every other runtime binary this repo shells out to).
codex_exec_adapter_bin() { printf '%s' "${CODEX_BIN:-codex}"; }

# codex_exec_adapter_available — success iff the codex binary is on PATH. Fail-soft: callers use
# this to degrade gracefully (skip a test, report an adapter-level failure) rather than crashing.
codex_exec_adapter_available() { command -v "$(codex_exec_adapter_bin)" >/dev/null 2>&1; }

# codex_exec_adapter_event_state <raw-event-type> — map ONE codex event `.type` string to this
# adapter's owned vocabulary (starting|working|completed|failed|unknown). Pure; no side effects.
# Requires jq (part of this repo's existing jq usage — governance-hook.sh, resolver-claim.sh,
# team-presence-live.sh all shell to it the same fail-soft way); prints "unknown" if jq is absent.
codex_exec_adapter_event_state() {
  local t="${1:-}"
  command -v jq >/dev/null 2>&1 || { printf 'unknown'; return 0; }
  jq -n -r --arg t "$t" --argjson m "$_CODEX_EXEC_ADAPTER_STATE_MAP" '$m[$t] // "unknown"' 2>/dev/null \
    || printf 'unknown'
}

# codex_exec_adapter_parse_events <raw-jsonl-file> <exit-code> — THE one place codex's real JSONL
# stream is parsed (design req 3: never leave raw text parsing scattered at call sites). Prints ONE
# line of JSON to stdout: {exit_code, raw_event_count, thread_id, usage, turn_error,
# top_level_errors, items, final_agent_message, state, state_reason}. Returns 0 iff state=="completed",
# 1 otherwise. Never touches stderr/pane/process-name signals (design req 4) — only the parsed event
# types in <raw-jsonl-file> and the passed-in real process exit code.
codex_exec_adapter_parse_events() {
  local raw="${1:-}" xc="${2:-1}" out
  if [ ! -f "$raw" ] || ! command -v jq >/dev/null 2>&1; then
    printf '{"exit_code":%s,"raw_event_count":0,"thread_id":null,"usage":null,"turn_error":null,"top_level_errors":[],"items":[],"final_agent_message":null,"state":"failed","state_reason":"jq-or-input-unavailable"}\n' "${xc:-1}"
    return 1
  fi
  out="$(jq -c -s --argjson exit_code "$xc" --argjson state_map "$_CODEX_EXEC_ADAPTER_STATE_MAP" '
    . as $events
    | ($events | length) as $raw_event_count
    | ($events | map(select(.type=="thread.started")) | (.[0].thread_id // null)) as $thread_id
    | ($events | map(select(.type=="turn.completed")) | (.[0].usage // null)) as $usage
    | ($events | map(select(.type=="turn.failed")) | (.[0].error.message // null)) as $turn_error
    | ([$events[] | select(.type=="error") | .message]) as $top_level_errors
    | ([$events[] | select(.type=="item.completed") | .item]) as $items
    | (([$events[] | select(.type=="item.completed" and .item.type=="agent_message") | .item.text]) | last // null) as $final_agent_message
    | ([$events[] | ($state_map[.type] // "unknown")] | last // "unknown") as $last_event_state
    | {
        exit_code: $exit_code,
        raw_event_count: $raw_event_count,
        thread_id: $thread_id,
        usage: $usage,
        turn_error: $turn_error,
        top_level_errors: $top_level_errors,
        items: $items,
        final_agent_message: $final_agent_message,
        state: (if $exit_code != 0 then "failed" elif $last_event_state == "completed" then "completed" else "failed" end),
        state_reason: (
          if   ($exit_code != 0) and ($last_event_state == "failed")    then "turn-failed-nonzero-exit"
          elif ($exit_code != 0) and ($last_event_state == "completed") then "turn-completed-nonzero-exit"
          elif ($exit_code != 0)                                        then "process-exit-nonzero"
          elif $last_event_state == "completed"                         then "turn-completed"
          elif $last_event_state == "failed"                            then "turn-failed"
          elif $raw_event_count == 0                                    then "no-events"
          else "incomplete-stream"
          end)
      }
  ' "$raw" 2>/dev/null)"
  if [ -z "$out" ]; then
    printf '{"exit_code":%s,"raw_event_count":0,"thread_id":null,"usage":null,"turn_error":null,"top_level_errors":[],"items":[],"final_agent_message":null,"state":"failed","state_reason":"unparseable-output"}\n' "${xc:-1}"
    return 1
  fi
  printf '%s\n' "$out"
  [ "$(printf '%s' "$out" | jq -r '.state' 2>/dev/null)" = "completed" ]
}

# codex_exec_adapter_run <workdir> <prompt> [model] — run ONE bounded `codex exec --json` turn
# scoped to <workdir> and print the normalized result (see codex_exec_adapter_parse_events). Returns
# 0 iff the turn completed cleanly, 1 otherwise, 2 on a usage error (bad args / missing workdir).
codex_exec_adapter_run() {
  local workdir="${1:-}" prompt="${2:-}" model="${3:-}"
  if [ -z "$workdir" ] || [ -z "$prompt" ]; then
    echo "codex_exec_adapter_run: usage: codex_exec_adapter_run <workdir> <prompt> [model]" >&2
    return 2
  fi
  if [ ! -d "$workdir" ]; then
    echo "codex_exec_adapter_run: workdir does not exist: $workdir" >&2
    return 2
  fi
  if ! codex_exec_adapter_available; then
    printf '{"exit_code":127,"raw_event_count":0,"thread_id":null,"usage":null,"turn_error":null,"top_level_errors":[],"items":[],"final_agent_message":null,"state":"failed","state_reason":"codex-binary-not-found"}\n'
    return 1
  fi
  # Isolation contract (design req 5): warn, don't abort, if <workdir> isn't a git worktree — a
  # caller may legitimately point this at a plain scratch dir for a no-repo probe.
  if ! git -C "$workdir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "codex_exec_adapter_run: WARNING — $workdir is not a git worktree; this adapter's isolation contract expects one (see file header)" >&2
  fi

  local bin raw err rc
  bin="$(codex_exec_adapter_bin)"
  raw="$(mktemp)"; err="$(mktemp)"
  local -a args
  args=(exec --json --sandbox workspace-write -C "$workdir")
  [ -n "$model" ] && args+=(--model "$model")
  args+=(-- "$prompt")

  # stdin closed (</dev/null): `codex exec` appends piped stdin to the prompt as a <stdin> block
  # when present (observed live) — closing it keeps this call self-contained on <prompt> alone.
  "$bin" "${args[@]}" </dev/null >"$raw" 2>"$err"
  rc=$?

  codex_exec_adapter_parse_events "$raw" "$rc"
  local parse_rc=$?

  if [ -n "${CODEX_EXEC_ADAPTER_KEEP_RAW:-}" ]; then
    echo "codex_exec_adapter_run: raw stdout=$raw stderr=$err" >&2
  else
    rm -f "$raw" "$err"
  fi
  return "$parse_rc"
}

# ── CLI entrypoint ───────────────────────────────────────────────────────────────────────────────
# Only runs when EXECUTED (not sourced): `bash codex-exec-adapter.sh <cmd> …`.
_codex_exec_adapter_cli() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    run)        codex_exec_adapter_run "$@" ;;
    parse)      codex_exec_adapter_parse_events "$@" ;;
    event-state) codex_exec_adapter_event_state "$@"; echo ;;
    available)  if codex_exec_adapter_available; then echo yes; else echo no; return 1; fi ;;
    *) printf 'usage: codex-exec-adapter.sh {run <workdir> <prompt> [model]|parse <raw-jsonl-file> <exit-code>|event-state <raw-event-type>|available}\n' >&2; return 2 ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  _codex_exec_adapter_cli "$@"
fi
