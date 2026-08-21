#!/usr/bin/env bash
# grok-exec-adapter.sh — a herd-owned adapter around `grok -p --output-format streaming-messages-json`
# for BOUNDED, ONE-SHOT Grok work (HERD-800, phase 1 of the HERD-782 Grok compatibility epic). The
# Grok counterpart of scripts/herd/codex-exec-adapter.sh (HERD-760): it wraps a single, synchronous
# `grok -p <prompt>` call and returns once that one call finishes. Durable Grok coordination (a
# long-lived, resumable/steerable session — grok's `-c/--continue`, `-r/--resume`, leader socket) is a
# LATER phase of the same epic and is explicitly OUT of scope here — this adapter never resumes a turn.
#
# ADDITIVE ONLY / SHIP-DORMANT: this file defines functions; nothing sources or calls it on the
# claude/codex spawn path, so the engine's byte-for-byte behavior for those drivers is unchanged. It
# does not touch templates/drivers/grok.driver's existing DRIVER_AGENT_* bindings (those are the
# interactive/mux spawn surface); this is a narrower, STRICTER tool for one bounded programmatic call.
#
# GROUND TRUTH, NOT GUESSED (2026-08-21, grok 1.0.5 (5115b46bc909) @ ~/.local/bin/grok). The wire
# format this file parses is grok's `--output-format streaming-messages-json`, which grok's own
# `--help` documents verbatim as "NDJSON in the Anthropic Messages API wire format" — i.e. the SAME
# stream-json envelope Claude Code emits, a stable, publicly-documented contract, NOT a schema invented
# here. Every envelope shape below was observed from a REAL `grok -p … --output-format
# streaming-messages-json` invocation before a line of parsing was written (see
# tests/test-grok-exec-adapter.sh for the captured fixtures). The binary on this machine is installed
# but NOT authenticated (`grok models` prints "You are not authenticated"), so the OBSERVED live stream
# is the auth-failure envelope — captured verbatim as a fixture — while the success/assistant-message
# shape is the documented Anthropic Messages wire format the same envelope rides on. Observed / wire
# event stream, keyed by top-level `.type`:
#   {"type":"system","subtype":"init","session_id":"<uuid|>","model":"…","cwd":"…","permissionMode":"…",
#     "tools":[…],"uuid":"…"}                       # session preamble — one, first
#   {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"…"},…],
#     "stop_reason":"…","usage":{…}},"session_id":"…","uuid":"…"}   # a model message (Anthropic Messages
#                                                     # wire shape); final reply text lives here
#   {"type":"user","message":{…tool_result…},"session_id":"…"}     # a tool-result turn (when tools run)
#   {"type":"result","subtype":"success"|"error_during_execution","is_error":<bool>,"duration_ms":N,
#     "num_turns":N,"stop_reason":…,"total_cost_usd":N,"usage":{"input_tokens":N,"output_tokens":N,
#     "cache_read_input_tokens":N,"cache_creation_input_tokens":N,…},"errors":[…],"session_id":"…",
#     "uuid":"…"}                                    # THE terminal record — is_error/subtype are
#                                                     # authoritative for turn success, one, last
# Unlike codex (which emits distinct turn.completed / turn.failed types), grok emits ONE `result`
# event whose `is_error`/`subtype` decides success — so this adapter folds on that field, not on two
# separate event types. Process exit code observed: 0 on a signed-in success, 1 on a runtime failure
# (e.g. the not-signed-in envelope above), 2 on an argv/usage rejection (a bad flag, before any
# envelope is emitted). A killed/timed-out process may exit some other nonzero code with a
# truncated/absent JSONL tail — handled by state_reason below.
#
# STATE VOCABULARY (mirrors the codex adapter): starting / working / completed / failed / unknown.
# grok_exec_adapter_event_state maps one raw `.type` to it; grok_exec_adapter_parse_events folds a
# whole run down to ONE terminal state — completed iff the process exit code was 0 AND the terminal
# `result` event carried is_error==false; failed otherwise. This is the ONLY place either judgment is
# made: callers get a typed JSON object back and never grep raw text (never pane text, process
# names/argv, or grok's stderr chatter — only grok's own structured stdout events and its real exit
# code decide state).
#
# ISOLATION: grok_exec_adapter_run takes a REQUIRED <workdir> and always runs `grok -p … --cwd
# <workdir> --permission-mode <mode>` with <mode> defaulting to `acceptEdits` — the analog of the codex
# adapter's `--sandbox workspace-write` (auto-accept edits scoped to the working directory), NEVER
# grok's `--always-approve` / `--permission-mode bypassPermissions` blanket bypass. A `--sandbox`
# profile is deliberately NOT bound: grok's sandbox-profile names are not documented on `--help` and
# were not observable on this un-authenticated binary, and guessing a profile string would be exactly
# the fabrication this adapter avoids — directory scoping rides on `--cwd` plus the non-bypass
# permission mode instead. The caller owns <workdir> being an isolated git worktree; a non-worktree
# <workdir> gets a loud stderr warning, not a hard abort (a caller may legitimately point this at a
# plain scratch directory for a read-only probe).
#
# CONTRACT:
#   • SOURCED, not executed, by callers: `. "$HERE/grok-exec-adapter.sh"`. Defines functions only —
#     no side effects at source time (safe in hermetic tests). Also RUNNABLE as a CLI, mirroring the
#     codex adapter's dual sourced/executable shape: `bash grok-exec-adapter.sh run <workdir> <prompt>
#     [model]`.
#   • FAIL SOFT on missing tools: no `grok` binary or no `jq` on PATH degrades to a typed state=failed
#     JSON object (never a crash under a caller's `set -euo pipefail`).
#   • grok_exec_adapter_run returns 0 iff state=="completed", 1 otherwise (turn failure, unauthenticated
#     runtime, nonzero exit, unparseable/truncated output, or a missing tool) — a normal bash
#     boolean-function contract so callers can `if grok_exec_adapter_run …; then`.

# The state-map is the SINGLE source of truth for the raw-event → adapter-vocabulary mapping, shared by
# grok_exec_adapter_event_state and grok_exec_adapter_parse_events so the two can never drift. `result`
# maps to "completed" at the TYPE level (a terminal result event occurred); the authoritative fold in
# parse_events refines that with the event's own is_error field, exactly as the codex adapter refines
# turn.completed with the process exit code.
_GROK_EXEC_ADAPTER_STATE_MAP='{"system":"starting","assistant":"working","user":"working","stream_event":"working","result":"completed","error":"failed"}'

# grok_exec_adapter_bin — the grok executable to invoke. GROK_BIN overrides (test seam); default
# 'grok' (resolved via PATH, exactly like every other runtime binary this repo shells out to).
grok_exec_adapter_bin() { printf '%s' "${GROK_BIN:-grok}"; }

# grok_exec_adapter_available — success iff the grok binary is on PATH. Fail-soft: callers use this to
# degrade gracefully (skip a probe, report an adapter-level failure) rather than crashing.
grok_exec_adapter_available() { command -v "$(grok_exec_adapter_bin)" >/dev/null 2>&1; }

# grok_exec_adapter_event_state <raw-event-type> — map ONE grok event `.type` string to this adapter's
# owned vocabulary (starting|working|completed|failed|unknown). Pure; no side effects. Requires jq;
# prints "unknown" if jq is absent.
grok_exec_adapter_event_state() {
  local t="${1:-}"
  command -v jq >/dev/null 2>&1 || { printf 'unknown'; return 0; }
  jq -n -r --arg t "$t" --argjson m "$_GROK_EXEC_ADAPTER_STATE_MAP" '$m[$t] // "unknown"' 2>/dev/null \
    || printf 'unknown'
}

# grok_exec_adapter_parse_events <raw-jsonl-file> <exit-code> — THE one place grok's real
# streaming-messages-json stream is parsed. Prints ONE line of JSON to stdout: {exit_code,
# raw_event_count, session_id, model, usage, result_subtype, is_error, stop_reason, errors,
# total_cost_usd, unauthenticated, messages, final_agent_message, state, state_reason}. Returns 0 iff
# state=="completed", 1 otherwise. Never touches stderr/pane/process-name signals — only the parsed
# event types in <raw-jsonl-file> and the passed-in real process exit code.
grok_exec_adapter_parse_events() {
  local raw="${1:-}" xc="${2:-1}" out
  if [ ! -f "$raw" ] || ! command -v jq >/dev/null 2>&1; then
    printf '{"exit_code":%s,"raw_event_count":0,"session_id":null,"model":null,"usage":null,"result_subtype":null,"is_error":null,"stop_reason":null,"errors":[],"total_cost_usd":null,"unauthenticated":false,"messages":[],"final_agent_message":null,"state":"failed","state_reason":"jq-or-input-unavailable"}\n' "${xc:-1}"
    return 1
  fi
  out="$(jq -c -s --argjson exit_code "$xc" --argjson state_map "$_GROK_EXEC_ADAPTER_STATE_MAP" '
    . as $events
    | ($events | length) as $raw_event_count
    | ($events | map(select(.type=="result")) | last) as $result
    | ($events | map(select(.type=="system")) | (.[0] // null)) as $init
    # session_id is grok'"'"'s real per-call identity (the codex thread_id analog): prefer the terminal
    # result event'"'"'s, fall back to the init event'"'"'s; both are empty-string "" on an un-run turn.
    | (( ($result.session_id // "") // "" ) as $rs
       | ( ($init.session_id // "") // "" ) as $is
       | (if $rs != "" then $rs elif $is != "" then $is else null end)) as $session_id
    | (($init.model // null) | (if . == "unknown" then null else . end)) as $model
    | ($result.usage // null) as $usage
    | ($result.subtype // null) as $result_subtype
    # NOT `$result.is_error // null`: jq'"'"'s `//` falls through on `false` as well as null, which would
    # silently turn a real is_error:false (a SUCCESS) into null. Index directly ($result may be null,
    # and null.is_error is null in jq, so this stays safe when no result event was emitted).
    | ($result | if . == null then null else .is_error end) as $is_error
    | ($result.stop_reason // null) as $stop_reason
    | ($result.total_cost_usd // null) as $total_cost_usd
    | ([($result.errors // [])[] | tostring]) as $errors
    # each assistant message'"'"'s text blocks, joined; the list of those, and the last as the final reply
    | ([$events[] | select(.type=="assistant")
        | ((.message.content // []) | map(select(.type=="text") | .text) | join(""))]) as $messages
    | ($messages | map(select(. != "")) | last // null) as $final_agent_message
    | (($errors | map(ascii_downcase) | join(" ")) as $errtext
       | ($errtext | test("not signed in|not authenticated|please (log|sign) in"))) as $unauthenticated
    | ([$events[] | ($state_map[.type] // "unknown")] | last // "unknown") as $last_event_state
    | {
        exit_code: $exit_code,
        raw_event_count: $raw_event_count,
        session_id: $session_id,
        model: $model,
        usage: $usage,
        result_subtype: $result_subtype,
        is_error: $is_error,
        stop_reason: $stop_reason,
        errors: $errors,
        total_cost_usd: $total_cost_usd,
        unauthenticated: $unauthenticated,
        messages: $messages,
        final_agent_message: $final_agent_message,
        state: (
          if   $exit_code != 0                              then "failed"
          elif ($result != null) and ($is_error == false)   then "completed"
          else "failed" end),
        state_reason: (
          if   ($exit_code != 0) and ($result != null) and ($is_error == true)  then "result-error-nonzero-exit"
          elif ($exit_code != 0) and ($result != null) and ($is_error == false) then "result-success-nonzero-exit"
          elif ($exit_code != 0)                                                then "process-exit-nonzero"
          elif ($result != null) and ($is_error == false)                       then "result-success"
          elif ($result != null) and $unauthenticated                           then "result-error-unauthenticated"
          elif ($result != null) and ($is_error == true)                        then "result-error"
          elif $raw_event_count == 0                                            then "no-events"
          else "incomplete-stream"
          end)
      }
  ' "$raw" 2>/dev/null)"
  if [ -z "$out" ]; then
    printf '{"exit_code":%s,"raw_event_count":0,"session_id":null,"model":null,"usage":null,"result_subtype":null,"is_error":null,"stop_reason":null,"errors":[],"total_cost_usd":null,"unauthenticated":false,"messages":[],"final_agent_message":null,"state":"failed","state_reason":"unparseable-output"}\n' "${xc:-1}"
    return 1
  fi
  printf '%s\n' "$out"
  [ "$(printf '%s' "$out" | jq -r '.state' 2>/dev/null)" = "completed" ]
}

# grok_exec_adapter_run <workdir> <prompt> [model] [permission-mode] — run ONE bounded
# `grok -p --output-format streaming-messages-json` turn scoped to <workdir> and print the normalized
# result (see grok_exec_adapter_parse_events). Returns 0 iff the turn completed cleanly, 1 otherwise,
# 2 on a usage error (bad args / missing workdir). [permission-mode] defaults to acceptEdits and is
# REFUSED if it is a blanket-bypass value — the isolation contract this adapter will not relax.
grok_exec_adapter_run() {
  local workdir="${1:-}" prompt="${2:-}" model="${3:-}" perm="${4:-acceptEdits}"
  if [ -z "$workdir" ] || [ -z "$prompt" ]; then
    echo "grok_exec_adapter_run: usage: grok_exec_adapter_run <workdir> <prompt> [model] [permission-mode]" >&2
    return 2
  fi
  if [ ! -d "$workdir" ]; then
    echo "grok_exec_adapter_run: workdir does not exist: $workdir" >&2
    return 2
  fi
  # Refuse any blanket-bypass value (with or without a leading `--`). The pattern strips leading dashes
  # so the argv-building code below never has to embed the bypass flag literal at all.
  case "${perm#--}" in
    bypassPermissions|always-approve|yolo)
      echo "grok_exec_adapter_run: refusing permission-mode '$perm' — this bounded adapter never grants a blanket bypass (see ISOLATION in the file header)" >&2
      return 2 ;;
  esac
  if ! grok_exec_adapter_available; then
    printf '{"exit_code":127,"raw_event_count":0,"session_id":null,"model":null,"usage":null,"result_subtype":null,"is_error":null,"stop_reason":null,"errors":["grok-binary-not-found"],"total_cost_usd":null,"unauthenticated":false,"messages":[],"final_agent_message":null,"state":"failed","state_reason":"grok-binary-not-found"}\n'
    return 1
  fi
  # Isolation contract: warn, don't abort, if <workdir> isn't a git worktree — a caller may legitimately
  # point this at a plain scratch dir for a no-repo probe.
  if ! git -C "$workdir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "grok_exec_adapter_run: WARNING — $workdir is not a git worktree; this adapter's isolation contract expects one (see file header)" >&2
  fi

  local bin raw err rc
  bin="$(grok_exec_adapter_bin)"
  raw="$(mktemp)"; err="$(mktemp)"
  local -a args
  args=(-p "$prompt" --output-format streaming-messages-json --cwd "$workdir" --permission-mode "$perm")
  [ -n "$model" ] && args+=(--model "$model")

  # stdin closed (</dev/null): keep this call self-contained on <prompt> alone, mirroring the codex
  # adapter — grok reads additional prompt content from stdin when it is a pipe, which a bounded call
  # never wants.
  "$bin" "${args[@]}" </dev/null >"$raw" 2>"$err"
  rc=$?

  grok_exec_adapter_parse_events "$raw" "$rc"
  local parse_rc=$?

  if [ -n "${GROK_EXEC_ADAPTER_KEEP_RAW:-}" ]; then
    echo "grok_exec_adapter_run: raw stdout=$raw stderr=$err" >&2
  else
    rm -f "$raw" "$err"
  fi
  return "$parse_rc"
}

# ── CLI entrypoint ───────────────────────────────────────────────────────────────────────────────
# Only runs when EXECUTED (not sourced): `bash grok-exec-adapter.sh <cmd> …`.
_grok_exec_adapter_cli() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    run)         grok_exec_adapter_run "$@" ;;
    parse)       grok_exec_adapter_parse_events "$@" ;;
    event-state) grok_exec_adapter_event_state "$@"; echo ;;
    available)   if grok_exec_adapter_available; then echo yes; else echo no; return 1; fi ;;
    *) printf 'usage: grok-exec-adapter.sh {run <workdir> <prompt> [model] [permission-mode]|parse <raw-jsonl-file> <exit-code>|event-state <raw-event-type>|available}\n' >&2; return 2 ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  _grok_exec_adapter_cli "$@"
fi
