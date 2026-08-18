#!/usr/bin/env bash
# test-codex-exec-adapter.sh — proof for scripts/herd/codex-exec-adapter.sh (HERD-760).
#
# Parts 1-4 are HERMETIC: they replay REAL captured `codex exec --json` event streams (recorded
# fixtures, embedded below) through codex_exec_adapter_parse_events. Every fixture was produced by
# an actual `codex exec --json` invocation (codex-cli 0.147.0) in a scratch worktree before this test
# was written — see the file header of codex-exec-adapter.sh for the same ground-truthing note. The
# EXACT wording of a model's reply/error text is not hermetic (a re-run could phrase it differently),
# so these fixtures freeze one real, observed byte stream rather than re-deriving it live every run —
# exactly the "recorded-fixture" escape hatch the task spec calls for once you've verified live
# behavior first.
#
# Part 5 is the LIVE proof: if `codex` is on PATH, it runs ONE real trivial bounded turn through
# codex_exec_adapter_run in a real isolated detached git worktree and asserts the adapter correctly
# parsed the ACTUAL live output (not a fixture) — protocol-level fields (state, thread_id, exit code)
# are asserted strictly; the model's reply text is asserted loosely (case-insensitive substring) since
# that half IS genuinely model output. Skips (never fails) when codex is not installed, so this suite
# stays green on a machine without the codex CLI.
#
# Run:  bash tests/test-codex-exec-adapter.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ADAPTER="$HERE/../scripts/herd/codex-exec-adapter.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ pass=$((pass+1)); }

[ -f "$ADAPTER" ] || fail "missing adapter file: $ADAPTER"
command -v jq >/dev/null 2>&1 || fail "jq required for this suite (the adapter's own hard dependency)"

. "$ADAPTER"

# ── Recorded fixtures (real `codex exec --json` stdout, byte-for-byte as captured) ────────────────

# A trivial successful turn: `codex exec --json --sandbox workspace-write -C <dir> "Reply with
# exactly the word: pong"`, stdin closed.
cat > "$T/fixture-success.jsonl" <<'EOF'
{"type":"thread.started","thread_id":"01a0134c-8266-7e63-a98c-0405531075cc"}
{"type":"turn.started"}
{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"pong"}}
{"type":"turn.completed","usage":{"input_tokens":15411,"cached_input_tokens":11008,"cache_write_input_tokens":0,"output_tokens":5,"reasoning_output_tokens":0}}
EOF

# An invalid --model: codex exits 1, emits an item.completed(type=error) advisory, then a top-level
# "error" event, then turn.failed (never turn.completed).
cat > "$T/fixture-turn-failed.jsonl" <<'EOF'
{"type":"thread.started","thread_id":"01a0134c-b937-7190-a3df-a0197377372e"}
{"type":"item.completed","item":{"id":"item_0","type":"error","message":"Model metadata for `definitely-not-a-real-model` not found. Defaulting to fallback metadata; this can degrade performance and cause issues."}}
{"type":"turn.started"}
{"type":"error","message":"{\"type\":\"error\",\"status\":400,\"error\":{\"type\":\"invalid_request_error\",\"message\":\"The 'definitely-not-a-real-model' model is not supported when using Codex with a ChatGPT account.\"}}"}
{"type":"turn.failed","error":{"message":"{\"type\":\"error\",\"status\":400,\"error\":{\"type\":\"invalid_request_error\",\"message\":\"The 'definitely-not-a-real-model' model is not supported when using Codex with a ChatGPT account.\"}}"}}
EOF

# Prompted to run `false`: the SHELL COMMAND fails (command_execution item exit_code=1), but the
# TURN itself completes successfully (codex reports the failure back as its answer) — exit 0.
cat > "$T/fixture-cmd-failed-turn-ok.jsonl" <<'EOF'
{"type":"thread.started","thread_id":"01a0134c-d8eb-7b82-941d-36e546ccc9d7"}
{"type":"turn.started"}
{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"I'll run it and report the exit result."}}
{"type":"item.started","item":{"id":"item_1","type":"command_execution","command":"/bin/zsh -lc false","aggregated_output":"","exit_code":null,"status":"in_progress"}}
{"type":"item.completed","item":{"id":"item_1","type":"command_execution","command":"/bin/zsh -lc false","aggregated_output":"","exit_code":1,"status":"failed"}}
{"type":"item.completed","item":{"id":"item_2","type":"agent_message","text":"It failed with exit code 1."}}
{"type":"turn.completed","usage":{"input_tokens":30991,"cached_input_tokens":26112,"cache_write_input_tokens":0,"output_tokens":114,"reasoning_output_tokens":0}}
EOF

jget(){ printf '%s' "$1" | jq -r "$2"; }

# ── 1. Success fixture → state completed, thread_id/final_agent_message/usage captured, rc 0. ─────
out="$(codex_exec_adapter_parse_events "$T/fixture-success.jsonl" 0)"; rc=$?
[ "$rc" -eq 0 ] || fail "success fixture: parse_events should return 0, got $rc"
[ "$(jget "$out" .state)" = "completed" ]                    || fail "success fixture: state != completed"
[ "$(jget "$out" .state_reason)" = "turn-completed" ]         || fail "success fixture: state_reason != turn-completed"
[ "$(jget "$out" .thread_id)" = "01a0134c-8266-7e63-a98c-0405531075cc" ] || fail "success fixture: thread_id not captured"
[ "$(jget "$out" .final_agent_message)" = "pong" ]             || fail "success fixture: final_agent_message != pong"
[ "$(jget "$out" .usage.input_tokens)" = "15411" ]             || fail "success fixture: usage.input_tokens not parsed"
ok; echo "PASS (1) success fixture normalizes to state=completed with thread_id/usage/final_agent_message"

# ── 2. turn.failed fixture → state failed, turn_error captured, exit-code-driven reason. ──────────
out="$(codex_exec_adapter_parse_events "$T/fixture-turn-failed.jsonl" 1)" && rc=0 || rc=$?
[ "$rc" -eq 1 ] || fail "turn-failed fixture: parse_events should return 1, got $rc"
[ "$(jget "$out" .state)" = "failed" ]                          || fail "turn-failed fixture: state != failed"
[ "$(jget "$out" .state_reason)" = "turn-failed-nonzero-exit" ] || fail "turn-failed fixture: wrong state_reason: $(jget "$out" .state_reason)"
[ "$(jget "$out" .thread_id)" = "01a0134c-b937-7190-a3df-a0197377372e" ] || fail "turn-failed fixture: thread_id not captured"
case "$(jget "$out" .turn_error)" in *"not supported when using Codex"*) ok ;; *) fail "turn-failed fixture: turn_error not captured: $(jget "$out" .turn_error)" ;; esac
echo "PASS (2) invalid-model fixture normalizes to state=failed with turn_error captured"

# ── 3. command-fails-but-turn-completes fixture → state completed (never inferred from the failed
#    command_execution item — only the turn-level event + exit code decide overall state). ────────
out="$(codex_exec_adapter_parse_events "$T/fixture-cmd-failed-turn-ok.jsonl" 0)"; rc=$?
[ "$rc" -eq 0 ] || fail "cmd-failed fixture: parse_events should return 0 (turn completed), got $rc"
[ "$(jget "$out" .state)" = "completed" ] || fail "cmd-failed fixture: state != completed (a failed sub-command must not flip the turn state)"
[ "$(jget "$out" '.items | length')" = "3" ] || fail "cmd-failed fixture: expected 3 completed items"
[ "$(jget "$out" '.items[1].exit_code')" = "1" ] || fail "cmd-failed fixture: command_execution item exit_code not preserved"
ok; echo "PASS (3) a failed sub-command does not flip turn state; the failing item's own exit_code is preserved in items[]"

# ── 4. Degrade paths: missing file, and jq-unavailable are typed failures, never a crash. ─────────
out="$(codex_exec_adapter_parse_events "$T/does-not-exist.jsonl" 1)" && rc=0 || rc=$?
[ "$rc" -eq 1 ] || fail "missing-file: parse_events should return 1"
[ "$(jget "$out" .state)" = "failed" ] || fail "missing-file: state != failed"
ok; echo "PASS (4a) a missing raw-events file degrades to a typed state=failed object, not a crash"

# codex_exec_adapter_event_state maps every observed real event type; unknown types degrade safely.
[ "$(codex_exec_adapter_event_state thread.started)" = "starting" ]  || fail "event-state: thread.started"
[ "$(codex_exec_adapter_event_state turn.started)" = "working" ]     || fail "event-state: turn.started"
[ "$(codex_exec_adapter_event_state item.completed)" = "working" ]   || fail "event-state: item.completed"
[ "$(codex_exec_adapter_event_state turn.completed)" = "completed" ] || fail "event-state: turn.completed"
[ "$(codex_exec_adapter_event_state turn.failed)" = "failed" ]       || fail "event-state: turn.failed"
[ "$(codex_exec_adapter_event_state some.unseen.type)" = "unknown" ] || fail "event-state: unknown type should degrade to 'unknown'"
ok; echo "PASS (4b) codex_exec_adapter_event_state maps every observed real event type; unseen types degrade to 'unknown'"

# ── 5. codex_exec_adapter_run argument/availability validation (hermetic — no codex invoked). ─────
if codex_exec_adapter_run 2>/dev/null; then fail "run with no args should refuse (usage error)"; fi
if codex_exec_adapter_run "$T/does-not-exist-dir" "prompt" 2>/dev/null; then fail "run against a nonexistent workdir should refuse"; fi
out="$(CODEX_BIN="$T/no-such-codex-binary" codex_exec_adapter_run "$T" "prompt" 2>/dev/null)" && rc=0 || rc=$?
[ "$rc" -eq 1 ] || fail "run with a missing codex binary should return 1, got $rc"
[ "$(jget "$out" .state_reason)" = "codex-binary-not-found" ] || fail "run with a missing codex binary should report codex-binary-not-found"
ok; echo "PASS (5) codex_exec_adapter_run validates args and degrades on a missing codex binary — no crash, typed result"

# ── 6. Isolation contract (design req 5): the invocation NEVER carries the sandbox-bypass flag, and
#    ALWAYS scopes --sandbox workspace-write to the caller's <workdir> via -C. Static, not a live
#    call — greps the actual argv-building lines so a future edit that reintroduces bypass fails here. ─
# Comments are allowed to NAME the bypass flag (to explain why it's avoided); only CODE lines matter.
# A here-string, not a pipe into grep -q, so an EPIPE on early-exit can never make this pipefail-unsafe.
_adapter_code_lines="$(grep -vE '^[[:space:]]*#' "$ADAPTER")"
if grep -qF -- '--dangerously-bypass-approvals-and-sandbox' <<< "$_adapter_code_lines"; then
  fail "codex-exec-adapter.sh must never carry the sandbox-bypass flag in code (design req 5)"
fi
grep -qF -- '--sandbox workspace-write' "$ADAPTER" || fail "codex-exec-adapter.sh must scope every invocation to --sandbox workspace-write"
grep -qF -- '-C "$workdir"' "$ADAPTER" || fail "codex-exec-adapter.sh must scope the invocation to the caller's <workdir> via -C"
ok; echo "PASS (6) the adapter's real argv never carries the sandbox-bypass flag and always scopes to workspace-write -C <workdir>"

# ── 7. LIVE: one real bounded turn, via a real isolated detached worktree, asserting the ADAPTER
#    parsed codex's ACTUAL live output (not a fixture). Skips (not fail) if codex isn't installed. ─
if ! codex_exec_adapter_available; then
  echo "SKIP (7) codex not on PATH — live proof skipped (fixtures 1-6 above already prove the parser)"
else
  LIVE_WT="$T/scratch-codex-exec-adapter-live"
  if ! git worktree add -q --detach "$LIVE_WT" HEAD >/dev/null 2>&1; then
    echo "SKIP (7) could not create an isolated worktree for the live probe (not inside a git repo?)"
  else
    trap 'rm -rf "$T"; git worktree remove --force "$LIVE_WT" >/dev/null 2>&1 || true' EXIT
    live_out="$(codex_exec_adapter_run "$LIVE_WT" "Reply with exactly and only the single word: herdcodexlive")" && live_rc=0 || live_rc=$?
    [ "$live_rc" -eq 0 ] || fail "live run: expected rc 0, got $live_rc: $live_out"
    [ "$(jget "$live_out" .state)" = "completed" ] || fail "live run: state != completed: $live_out"
    tid="$(jget "$live_out" .thread_id)"
    [ -n "$tid" ] && [ "$tid" != "null" ] || fail "live run: codex's real thread_id was not captured"
    [ "$(jget "$live_out" .exit_code)" = "0" ] || fail "live run: exit_code not 0"
    msg_lc="$(jget "$live_out" .final_agent_message | tr '[:upper:]' '[:lower:]')"
    case "$msg_lc" in *herdcodexlive*) : ;; *) fail "live run: final_agent_message did not contain the requested word (got: $live_out)" ;; esac
    ok; echo "PASS (7) LIVE codex exec --json turn: adapter correctly parsed real thread_id/state/exit_code/reply"
  fi
fi

echo "─────────────────────────────────────────────"
echo "codex-exec-adapter.sh: $pass checks passed"
