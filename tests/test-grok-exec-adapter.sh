#!/usr/bin/env bash
# test-grok-exec-adapter.sh — proof for scripts/herd/grok-exec-adapter.sh (HERD-800, epic HERD-782 ph1).
#
# Parts 1-4 are HERMETIC: they replay grok `--output-format streaming-messages-json` event streams
# through grok_exec_adapter_parse_events, and drive grok_exec_adapter_run end-to-end against a STUB
# `grok` binary (no network, no real grok). Two of the fixtures are REAL captured output: the
# not-signed-in envelope was produced by an actual `grok -p … --output-format streaming-messages-json`
# call on grok 1.0.5 (5115b46bc909) in a scratch dir before this test was written (that binary is
# installed but not authenticated on this machine — see the adapter's header). The signed-in SUCCESS
# fixture is constructed from the SAME wire format grok documents — "the Anthropic Messages API wire
# format" — since a real success turn needs authentication this machine does not have; the exact model
# reply text is not hermetic, so the fixture freezes one representative byte stream in that documented
# format rather than re-deriving it live.
#
# Part 5 is the LIVE proof: if `grok` is on PATH, it runs ONE real bounded turn through
# grok_exec_adapter_run in a real isolated detached git worktree and asserts the adapter parsed grok's
# ACTUAL live output. When grok is signed in the turn completes (state=completed with a real
# session_id); when it is installed-but-unauthenticated (this machine's state) the adapter still parses
# the real streaming-messages-json envelope and reports state=failed + unauthenticated=true — the honest
# degrade, asserted as such, never a suite failure. Skips entirely when grok is not installed.
#
# Run:  bash tests/test-grok-exec-adapter.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ADAPTER="$HERE/../scripts/herd/grok-exec-adapter.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ pass=$((pass+1)); }

[ -f "$ADAPTER" ] || fail "missing adapter file: $ADAPTER"
command -v jq >/dev/null 2>&1 || fail "jq required for this suite (the adapter's own hard dependency)"

. "$ADAPTER"

# ── Recorded fixtures (grok streaming-messages-json stdout) ────────────────────────────────────────

# A signed-in successful turn: system.init → one assistant message (Anthropic Messages wire shape) →
# result{subtype:success,is_error:false}. Process exit 0.
cat > "$T/fixture-success.jsonl" <<'EOF'
{"type":"system","subtype":"init","session_id":"7f3a1b02-0c11-4e77-9a2b-1d2e3f4a5b6c","apiKeySource":"user","model":"grok-4.6","cwd":"/w","permissionMode":"acceptEdits","tools":["Bash","Edit"],"slash_commands":[],"mcp_servers":[],"skills":[],"uuid":"aaaa"}
{"type":"assistant","message":{"id":"msg_1","type":"message","role":"assistant","model":"grok-4.6","content":[{"type":"text","text":"pong"}],"stop_reason":"end_turn","usage":{"input_tokens":12,"output_tokens":2}},"session_id":"7f3a1b02-0c11-4e77-9a2b-1d2e3f4a5b6c","uuid":"bbbb"}
{"type":"result","subtype":"success","is_error":false,"duration_ms":840,"duration_api_ms":700,"num_turns":1,"stop_reason":"end_turn","total_cost_usd":0.0012,"usage":{"input_tokens":12,"output_tokens":2,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"server_tool_use":{"web_search_requests":0}},"modelUsage":{},"errors":[],"session_id":"7f3a1b02-0c11-4e77-9a2b-1d2e3f4a5b6c","uuid":"cccc"}
EOF

# REAL captured not-signed-in envelope (grok 1.0.5, byte-for-byte as observed): system.init with empty
# session_id → result{subtype:error_during_execution,is_error:true,errors:[Not signed in …]}. Exit 1.
cat > "$T/fixture-unauth.jsonl" <<'EOF'
{"type":"system","subtype":"init","session_id":"","apiKeySource":"user","model":"unknown","cwd":"","permissionMode":"default","tools":[],"slash_commands":[],"mcp_servers":[],"skills":[],"uuid":"20afe3d9-be47-4362-90ea-14c4a9a056df"}
{"type":"result","subtype":"error_during_execution","is_error":true,"duration_ms":0,"duration_api_ms":0,"num_turns":0,"stop_reason":null,"total_cost_usd":0.0,"usage":{"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"server_tool_use":{"web_search_requests":0}},"modelUsage":{},"errors":["Not signed in. To authenticate without a browser, run:\n  grok login --device-code\n\nAlternatively, set the XAI_API_KEY environment variable or run `grok login` on a machine with a browser."],"session_id":"","uuid":"13d63d36-8bfe-4113-abca-d89ec1b88f12"}
EOF

# A turn that ran a tool then answered: assistant(text) → user(tool_result) → assistant(text) →
# result{success}. Proves a `user` tool-result event does not flip state and the LAST assistant text
# is the final reply. Exit 0.
cat > "$T/fixture-tool-then-answer.jsonl" <<'EOF'
{"type":"system","subtype":"init","session_id":"11111111-2222-3333-4444-555555555555","model":"grok-4.6","cwd":"/w","permissionMode":"acceptEdits","tools":["Bash"],"uuid":"d0"}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Let me check."},{"type":"tool_use","id":"tu1","name":"Bash","input":{"command":"true"}}],"stop_reason":"tool_use","usage":{"input_tokens":40,"output_tokens":10}},"session_id":"11111111-2222-3333-4444-555555555555","uuid":"d1"}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu1","content":"ok"}]},"session_id":"11111111-2222-3333-4444-555555555555","uuid":"d2"}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Done."}],"stop_reason":"end_turn","usage":{"input_tokens":50,"output_tokens":3}},"session_id":"11111111-2222-3333-4444-555555555555","uuid":"d3"}
{"type":"result","subtype":"success","is_error":false,"duration_ms":1200,"num_turns":2,"stop_reason":"end_turn","total_cost_usd":0.0031,"usage":{"input_tokens":50,"output_tokens":13,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"server_tool_use":{"web_search_requests":0}},"errors":[],"session_id":"11111111-2222-3333-4444-555555555555","uuid":"d4"}
EOF

jget(){ printf '%s' "$1" | jq -r "$2"; }

# ── 1. Success fixture → state completed, session_id/final_agent_message/usage captured, rc 0. ─────
out="$(grok_exec_adapter_parse_events "$T/fixture-success.jsonl" 0)"; rc=$?
[ "$rc" -eq 0 ] || fail "success fixture: parse_events should return 0, got $rc"
[ "$(jget "$out" .state)" = "completed" ]                     || fail "success fixture: state != completed"
[ "$(jget "$out" .state_reason)" = "result-success" ]          || fail "success fixture: state_reason != result-success"
[ "$(jget "$out" .is_error)" = "false" ]                       || fail "success fixture: is_error:false must survive (jq // gotcha)"
[ "$(jget "$out" .session_id)" = "7f3a1b02-0c11-4e77-9a2b-1d2e3f4a5b6c" ] || fail "success fixture: session_id not captured"
[ "$(jget "$out" .model)" = "grok-4.6" ]                       || fail "success fixture: model not captured"
[ "$(jget "$out" .final_agent_message)" = "pong" ]             || fail "success fixture: final_agent_message != pong"
[ "$(jget "$out" .usage.input_tokens)" = "12" ]                || fail "success fixture: usage.input_tokens not parsed"
[ "$(jget "$out" .total_cost_usd)" = "0.0012" ]                || fail "success fixture: total_cost_usd not parsed"
ok; echo "PASS (1) signed-in success stream normalizes to state=completed with session_id/model/usage/reply"

# ── 2. Real not-signed-in fixture → state failed, unauthenticated flagged, errors captured, rc 1. ──
out="$(grok_exec_adapter_parse_events "$T/fixture-unauth.jsonl" 1)" && rc=0 || rc=$?
[ "$rc" -eq 1 ] || fail "unauth fixture: parse_events should return 1, got $rc"
[ "$(jget "$out" .state)" = "failed" ]                          || fail "unauth fixture: state != failed"
[ "$(jget "$out" .state_reason)" = "result-error-nonzero-exit" ] || fail "unauth fixture: wrong state_reason: $(jget "$out" .state_reason)"
[ "$(jget "$out" .is_error)" = "true" ]                         || fail "unauth fixture: is_error != true"
[ "$(jget "$out" .unauthenticated)" = "true" ]                  || fail "unauth fixture: unauthenticated flag not set"
[ "$(jget "$out" .result_subtype)" = "error_during_execution" ] || fail "unauth fixture: result_subtype not captured"
case "$(jget "$out" '.errors[0]')" in *"Not signed in"*) ok ;; *) fail "unauth fixture: errors[] not captured: $(jget "$out" '.errors[0]')" ;; esac
echo "PASS (2) real not-signed-in envelope normalizes to state=failed with unauthenticated=true and errors captured"

# ── 3. tool-then-answer fixture → state completed; a `user` tool-result never flips state, and the
#    LAST assistant text is the final reply (not the first). ────────────────────────────────────────
out="$(grok_exec_adapter_parse_events "$T/fixture-tool-then-answer.jsonl" 0)"; rc=$?
[ "$rc" -eq 0 ] || fail "tool fixture: parse_events should return 0 (turn completed), got $rc"
[ "$(jget "$out" .state)" = "completed" ]           || fail "tool fixture: state != completed"
[ "$(jget "$out" '.messages | length')" = "2" ]     || fail "tool fixture: expected 2 assistant messages"
[ "$(jget "$out" .final_agent_message)" = "Done." ] || fail "tool fixture: final_agent_message should be the LAST assistant text"
ok; echo "PASS (3) a tool-result (user) event does not flip turn state; the LAST assistant text is the final reply"

# ── 4a. Degrade paths: missing file, and jq-unavailable are typed failures, never a crash. ────────
out="$(grok_exec_adapter_parse_events "$T/does-not-exist.jsonl" 1)" && rc=0 || rc=$?
[ "$rc" -eq 1 ] || fail "missing-file: parse_events should return 1"
[ "$(jget "$out" .state)" = "failed" ] || fail "missing-file: state != failed"
ok; echo "PASS (4a) a missing raw-events file degrades to a typed state=failed object, not a crash"

# ── 4b. grok_exec_adapter_event_state maps every observed real event type; unknown types degrade. ──
[ "$(grok_exec_adapter_event_state system)" = "starting" ]     || fail "event-state: system"
[ "$(grok_exec_adapter_event_state assistant)" = "working" ]   || fail "event-state: assistant"
[ "$(grok_exec_adapter_event_state user)" = "working" ]        || fail "event-state: user"
[ "$(grok_exec_adapter_event_state stream_event)" = "working" ] || fail "event-state: stream_event"
[ "$(grok_exec_adapter_event_state result)" = "completed" ]    || fail "event-state: result"
[ "$(grok_exec_adapter_event_state error)" = "failed" ]        || fail "event-state: error"
[ "$(grok_exec_adapter_event_state some.unseen.type)" = "unknown" ] || fail "event-state: unknown type should degrade to 'unknown'"
ok; echo "PASS (4b) grok_exec_adapter_event_state maps every observed real event type; unseen types degrade to 'unknown'"

# ── 5. grok_exec_adapter_run argument/availability validation + isolation contract (hermetic). ─────
if grok_exec_adapter_run 2>/dev/null; then fail "run with no args should refuse (usage error)"; fi
if grok_exec_adapter_run "$T/does-not-exist-dir" "prompt" 2>/dev/null; then fail "run against a nonexistent workdir should refuse"; fi
# The isolation contract: a blanket-bypass permission mode is REFUSED (rc 2), never silently honored.
grok_exec_adapter_run "$T" "prompt" "" bypassPermissions 2>/dev/null && fail "run must refuse permission-mode bypassPermissions"
grok_exec_adapter_run "$T" "prompt" "" --always-approve 2>/dev/null && fail "run must refuse --always-approve"
out="$(GROK_BIN="$T/no-such-grok-binary" grok_exec_adapter_run "$T" "prompt" 2>/dev/null)" && rc=0 || rc=$?
[ "$rc" -eq 1 ] || fail "run with a missing grok binary should return 1, got $rc"
[ "$(jget "$out" .state_reason)" = "grok-binary-not-found" ] || fail "run with a missing grok binary should report grok-binary-not-found"
ok; echo "PASS (5) grok_exec_adapter_run validates args, refuses a blanket-bypass permission mode, and degrades on a missing binary"

# ── 6. STUB-BINARY end-to-end: a fake `grok` records the argv the adapter built and replays a fixture.
#    Proves the REAL invocation shape (streaming-messages-json + --cwd + a non-bypass --permission-mode,
#    never --always-approve) AND that run() folds the replayed stream to the right state. ─────────────
STUB="$T/stub-grok"
cat > "$STUB" <<STUBEOF
#!/usr/bin/env bash
# stub grok: record argv, then emit the fixture named by GROK_STUB_FIXTURE and exit GROK_STUB_RC.
printf '%s\n' "\$@" > "$T/stub-argv.txt"
cat "\${GROK_STUB_FIXTURE:-$T/fixture-success.jsonl}"
exit "\${GROK_STUB_RC:-0}"
STUBEOF
chmod +x "$STUB"

out="$(GROK_BIN="$STUB" GROK_STUB_FIXTURE="$T/fixture-success.jsonl" GROK_STUB_RC=0 grok_exec_adapter_run "$T" "Reply pong" grok-4.6)" && rc=0 || rc=$?
[ "$rc" -eq 0 ] || fail "stub run (success): expected rc 0, got $rc: $out"
[ "$(jget "$out" .state)" = "completed" ] || fail "stub run (success): state != completed"
[ "$(jget "$out" .final_agent_message)" = "pong" ] || fail "stub run (success): reply not carried through"
argv="$(cat "$T/stub-argv.txt")"
grep -qx -- '--output-format' <<< "$argv" || fail "stub argv: adapter must pass --output-format"
grep -qx -- 'streaming-messages-json' <<< "$argv" || fail "stub argv: adapter must request streaming-messages-json"
grep -qx -- '--cwd' <<< "$argv" || fail "stub argv: adapter must scope with --cwd"
grep -qx -- "$T" <<< "$argv" || fail "stub argv: adapter must pass the workdir to --cwd"
grep -qx -- '--permission-mode' <<< "$argv" || fail "stub argv: adapter must set an explicit --permission-mode"
grep -qx -- 'acceptEdits' <<< "$argv" || fail "stub argv: default permission-mode should be acceptEdits"
grep -qx -- 'grok-4.6' <<< "$argv" || fail "stub argv: model should be forwarded to --model"
if grep -qx -- '--always-approve' <<< "$argv"; then fail "stub argv: the bounded adapter must NEVER pass --always-approve"; fi
# and the unauthenticated replay through run() → state failed, unauthenticated flagged, rc 1
out="$(GROK_BIN="$STUB" GROK_STUB_FIXTURE="$T/fixture-unauth.jsonl" GROK_STUB_RC=1 grok_exec_adapter_run "$T" "Reply pong")" && rc=0 || rc=$?
[ "$rc" -eq 1 ] || fail "stub run (unauth): expected rc 1, got $rc"
[ "$(jget "$out" .unauthenticated)" = "true" ] || fail "stub run (unauth): unauthenticated flag not set"
ok; echo "PASS (6) end-to-end through a stub grok: the adapter's real argv uses streaming-messages-json + --cwd + a non-bypass mode (never --always-approve) and folds the replayed stream correctly"

# ── 7. STATIC isolation guard: the adapter's argv-building CODE never carries a blanket-bypass flag,
#    and always requests streaming-messages-json + --cwd + --permission-mode. Comments may NAME the
#    bypass (to explain why it's avoided); only CODE lines matter. ─────────────────────────────────
_adapter_code_lines="$(grep -vE '^[[:space:]]*#' "$ADAPTER")"
if grep -qF -- '--always-approve' <<< "$_adapter_code_lines"; then
  fail "grok-exec-adapter.sh must never build --always-approve into its argv (isolation contract)"
fi
grep -qF -- '--output-format streaming-messages-json' "$ADAPTER" || fail "grok-exec-adapter.sh must request --output-format streaming-messages-json"
grep -qF -- '--cwd' "$ADAPTER" || fail "grok-exec-adapter.sh must scope the invocation with --cwd"
grep -qF -- '--permission-mode' "$ADAPTER" || fail "grok-exec-adapter.sh must set an explicit --permission-mode"
ok; echo "PASS (7) the adapter's real argv-building code never carries a blanket bypass and always scopes via --output-format streaming-messages-json + --cwd + --permission-mode"

# ── 8. LIVE: one real bounded turn, via a real isolated detached worktree, asserting the ADAPTER
#    parsed grok's ACTUAL live output. Skips (not fail) if grok isn't installed; on an installed-but-
#    unauthenticated binary the honest degrade (state=failed + unauthenticated=true) is asserted. ────
if ! grok_exec_adapter_available; then
  echo "SKIP (8) grok not on PATH — live proof skipped (fixtures 1-7 above already prove the parser + run path)"
else
  LIVE_WT="$T/scratch-grok-exec-adapter-live"
  if ! git worktree add -q --detach "$LIVE_WT" HEAD >/dev/null 2>&1; then
    echo "SKIP (8) could not create an isolated worktree for the live probe (not inside a git repo?)"
  else
    trap 'git worktree remove --force "$LIVE_WT" >/dev/null 2>&1 || true; rm -rf "$T"' EXIT
    live_out="$(grok_exec_adapter_run "$LIVE_WT" "Reply with exactly and only the single word: herdgroklive")" && live_rc=0 || live_rc=$?
    lstate="$(jget "$live_out" .state)"
    levents="$(jget "$live_out" .raw_event_count)"
    [ "${levents:-0}" -ge 1 ] || fail "live run: grok emitted no parseable streaming-messages-json events at all: $live_out"
    if [ "$(jget "$live_out" .unauthenticated)" = "true" ]; then
      # Installed but not signed in (this machine): the adapter must still have parsed a real envelope
      # (init + result present) and reported the honest degrade — that IS the pass here.
      [ "$live_rc" -eq 1 ] || fail "live run (unauth): expected rc 1, got $live_rc"
      [ "$lstate" = "failed" ] || fail "live run (unauth): state should be failed, got $lstate"
      [ -n "$(jget "$live_out" .result_subtype)" ] || fail "live run (unauth): no terminal result event parsed"
      ok; echo "PASS (8) LIVE grok is installed-but-unauthenticated: adapter parsed the real streaming-messages-json envelope and reported the honest degrade (state=failed, unauthenticated=true)"
    else
      [ "$live_rc" -eq 0 ] || fail "live run: expected rc 0, got $live_rc: $live_out"
      [ "$lstate" = "completed" ] || fail "live run: state != completed: $live_out"
      sid="$(jget "$live_out" .session_id)"
      [ -n "$sid" ] && [ "$sid" != "null" ] || fail "live run: grok's real session_id was not captured"
      msg_lc="$(jget "$live_out" .final_agent_message | tr '[:upper:]' '[:lower:]')"
      case "$msg_lc" in *herdgroklive*) : ;; *) fail "live run: final_agent_message did not contain the requested word (got: $live_out)" ;; esac
      ok; echo "PASS (8) LIVE signed-in grok exec turn: adapter correctly parsed real session_id/state/reply"
    fi
  fi
fi

echo "─────────────────────────────────────────────"
echo "grok-exec-adapter.sh: $pass checks passed"
