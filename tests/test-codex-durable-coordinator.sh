#!/usr/bin/env bash
# test-codex-durable-coordinator.sh — proof for scripts/herd/codex-durable-coordinator.sh (HERD-766,
# epic HERD-754 step 7).
#
# Parts 1-4 are HERMETIC: they drive the coordinator's session bookkeeping (_codex_durable_compose,
# init/steer/cancel argument validation) against a fake "in-flight" process (a real backgrounded
# `sleep`, standing in for codex so codex_durable's OWN pid-liveness logic is exercised for real) and
# hand-written turn fixtures reusing codex-exec-adapter.sh's already-proven parser — never a codex
# invocation. Part 5 is a static isolation-contract grep, mirroring test-codex-exec-adapter.sh's own
# part 6. Part 6 is the LIVE proof: if `codex` is on PATH, it drives a REAL session end-to-end (start,
# steer, mid-turn cancel, steer-after-cancel) in a real isolated detached worktree and asserts the
# SAME things this file's header claims were verified live before it was written: a stable thread_id
# across turns, real cross-turn context retention, and an orphan-free cancel. Skips (never fails) when
# codex is not installed.
#
# Run:  bash tests/test-codex-durable-coordinator.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
COORD="$HERE/../scripts/herd/codex-durable-coordinator.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ pass=$((pass+1)); }
jget(){ printf '%s' "$1" | jq -r "$2"; }

[ -f "$COORD" ] || fail "missing coordinator file: $COORD"
command -v jq >/dev/null 2>&1 || fail "jq required for this suite (the coordinator's own hard dependency)"

. "$COORD"

# ── 1. codex_durable_init validates args and scaffolds the session dir. ────────────────────────────
if codex_durable_init 2>/dev/null; then fail "init with no args should refuse (usage error)"; fi
if codex_durable_init "$T/sd-badwd" "$T/no-such-workdir" 2>/dev/null; then fail "init against a nonexistent workdir should refuse"; fi
mkdir -p "$T/wd1"
codex_durable_init "$T/sd1" "$T/wd1" || fail "init with valid args should succeed"
[ -d "$T/sd1/turns" ] || fail "init should create <session_dir>/turns"
[ "$(cat "$T/sd1/workdir")" = "$T/wd1" ] || fail "init should record workdir"
ok; echo "PASS (1) codex_durable_init validates args and scaffolds session_dir/{turns,workdir,turn}"

# ── 2. _codex_durable_compose: idle + completed turn (a fixture from the proven adapter format). ──
mkdir -p "$T/sd2/turns"; printf '%s' "$T/wd1" > "$T/sd2/workdir"; printf '1' > "$T/sd2/turn"
printf 'tid-abc-123' > "$T/sd2/thread_id"
cat > "$T/sd2/turns/001.jsonl" <<'EOF'
{"type":"thread.started","thread_id":"tid-abc-123"}
{"type":"turn.started"}
{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"hermetic-ok"}}
{"type":"turn.completed","usage":{"input_tokens":10,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":1,"reasoning_output_tokens":0}}
EOF
printf '0' > "$T/sd2/turns/001.exit"
out="$(codex_durable_status "$T/sd2")"; rc=$?
[ "$rc" -eq 0 ] || fail "status on a completed idle session should return 0, got $rc"
[ "$(jget "$out" .session_state)" = "idle" ]           || fail "compose: session_state != idle"
[ "$(jget "$out" .thread_id)" = "tid-abc-123" ]         || fail "compose: thread_id not surfaced"
[ "$(jget "$out" .turn_number)" = "1" ]                 || fail "compose: turn_number != 1"
[ "$(jget "$out" .pid)" = "null" ]                       || fail "compose: pid should be null when idle"
[ "$(jget "$out" .turn.state)" = "completed" ]           || fail "compose: nested turn.state != completed (adapter reuse broken)"
[ "$(jget "$out" .turn.final_agent_message)" = "hermetic-ok" ] || fail "compose: nested turn.final_agent_message not reused from the adapter parse"
ok; echo "PASS (2) codex_durable_status composes {session_state:idle, thread_id, turn_number, pid:null, turn:<reused adapter parse>} from disk state"

# ── 3. _codex_durable_compose: WORKING — a real live pid (a backgrounded sleep, standing in for a
#    real codex process) makes session_state=working and suppresses the (stale, in-flight) turn field. ──
( sleep 30 ) &
fake_pid=$!
disown "$fake_pid" 2>/dev/null || true
mkdir -p "$T/sd3/turns"; printf '%s' "$T/wd1" > "$T/sd3/workdir"; printf '1' > "$T/sd3/turn"
printf 'tid-working' > "$T/sd3/thread_id"
printf '%s' "$fake_pid" > "$T/sd3/pid"
out="$(codex_durable_status "$T/sd3")" && rc=0 || rc=$?
[ "$rc" -eq 1 ] || fail "status while working should return 1 (not idle+completed), got $rc"
[ "$(jget "$out" .session_state)" = "working" ] || fail "compose: session_state != working while pid is alive"
[ "$(jget "$out" .pid)" = "$fake_pid" ]          || fail "compose: pid should surface the live pid while working"
[ "$(jget "$out" .turn)" = "null" ]              || fail "compose: turn should be null while a turn is in flight"
kill -KILL "$fake_pid" 2>/dev/null || true
ok; echo "PASS (3) codex_durable_status reports session_state=working (turn:null) while the tracked pid is alive"

# ── 4. codex_durable_cancel: SIGTERMs a real live pid, marks status=cancelled, clears pid; a no-op
#    (still rc 0, session_state unchanged) when nothing is in flight. ──────────────────────────────
( sleep 30 ) &
fake_pid2=$!
disown "$fake_pid2" 2>/dev/null || true
mkdir -p "$T/sd4/turns"; printf '%s' "$T/wd1" > "$T/sd4/workdir"; printf '1' > "$T/sd4/turn"
printf '%s' "$fake_pid2" > "$T/sd4/pid"
out="$(codex_durable_cancel "$T/sd4" 3)" || true
[ "$(jget "$out" .session_state)" = "cancelled" ] || fail "cancel: session_state != cancelled"
[ "$(jget "$out" .pid)" = "null" ]                 || fail "cancel: pid should be cleared after cancel"
kill -0 "$fake_pid2" 2>/dev/null && fail "cancel: the tracked pid should be dead after cancel (SIGTERM never delivered?)"
out2="$(codex_durable_cancel "$T/sd4" 1)" || true
[ "$(jget "$out2" .session_state)" = "cancelled" ] || fail "cancel: a second no-op cancel should leave session_state cancelled"
if codex_durable_cancel 2>/dev/null; then fail "cancel with no args should refuse (usage error)"; fi
ok; echo "PASS (4) codex_durable_cancel SIGTERMs a live pid, records session_state=cancelled, and no-ops safely when nothing is in flight"

# ── 5. codex_durable_steer argument validation (hermetic — no codex invoked): refuses without a prior
#    thread_id, and refuses while a turn is already in flight. ────────────────────────────────────
if codex_durable_steer "$T/sd-never-started" "prompt" 2>/dev/null; then fail "steer without a prior start (no thread_id) should refuse"; fi
( sleep 30 ) &
fake_pid3=$!
disown "$fake_pid3" 2>/dev/null || true
mkdir -p "$T/sd5"; printf '%s' "$T/wd1" > "$T/sd5/workdir"; printf 'tid-busy' > "$T/sd5/thread_id"; printf '%s' "$fake_pid3" > "$T/sd5/pid"
if codex_durable_steer "$T/sd5" "prompt" 2>/dev/null; then fail "steer while a turn is in flight should refuse"; fi
kill -KILL "$fake_pid3" 2>/dev/null || true
ok; echo "PASS (5) codex_durable_steer refuses with no thread_id yet and refuses while a turn is already in flight"

# ── 6. Isolation contract: every launched turn scopes -C <workdir> --sandbox workspace-write at the
#    `exec` (parent) level for BOTH the start path and the resume/steer path, and never carries the
#    sandbox-bypass flag — a static grep of the real argv-building code, not a live call. ─────────────
_coord_code_lines="$(grep -vE '^[[:space:]]*#' "$COORD")"
if grep -qF -- '--dangerously-bypass-approvals-and-sandbox' <<< "$_coord_code_lines"; then
  fail "codex-durable-coordinator.sh must never carry the sandbox-bypass flag in code"
fi
grep -qF -- 'args=(exec -C "$workdir" --sandbox workspace-write)' "$COORD" || fail "every launched turn must scope -C/--sandbox at the exec (parent) level, including resume"
grep -qF -- 'args+=(resume "$thread_id")' "$COORD" || fail "resume must be appended AFTER the exec-level isolation flags, never carry its own -C/--sandbox"
ok; echo "PASS (6) the coordinator's real argv never carries the sandbox-bypass flag; -C/--sandbox are scoped at the exec level on every turn, including resume"

# ── 7. LIVE: a real session end-to-end — start, steer (context retained), mid-turn cancel (no
#    orphaned process), steer-after-cancel (same thread resumes cleanly). Skips if codex isn't
#    installed. ──────────────────────────────────────────────────────────────────────────────────
if ! codex_durable_available; then
  echo "SKIP (7) codex not on PATH — live proof skipped (parts 1-6 above already prove the bookkeeping/isolation)"
else
  LIVE_WT="$T/scratch-codex-durable-live"
  if ! git worktree add -q --detach "$LIVE_WT" HEAD >/dev/null 2>&1; then
    echo "SKIP (7) could not create an isolated worktree for the live probe (not inside a git repo?)"
  else
    trap 'rm -rf "$T"; git worktree remove --force "$LIVE_WT" >/dev/null 2>&1 || true' EXIT
    LIVE_SD="$T/durable-session-live"

    # codex_durable_start/steer are NON-BLOCKING launch calls whose own return code mirrors
    # codex_durable_status at the instant they return — that races the turn's real completion (a fast
    # turn may already show rc 0/completed; a slower one rc 1/still-working). Only codex_durable_wait's
    # return code is asserted as authoritative below; the launch calls themselves are only checked for
    # the fields that must be true immediately (thread_id captured, thread_id stable across turns).
    start_out="$(codex_durable_start "$LIVE_SD" "$LIVE_WT" "Reply with exactly and only the single word: herddurablelive")" || true
    tid="$(jget "$start_out" .thread_id)"
    [ -n "$tid" ] && [ "$tid" != "null" ] || fail "live start: thread_id was not captured"
    wait_out="$(codex_durable_wait "$LIVE_SD" 120)" && wait_rc=0 || wait_rc=$?
    [ "$wait_rc" -eq 0 ] || fail "live wait: expected rc 0, got $wait_rc: $wait_out"
    msg_lc="$(jget "$wait_out" .turn.final_agent_message | tr '[:upper:]' '[:lower:]')"
    case "$msg_lc" in *herddurablelive*) : ;; *) fail "live start/wait: reply did not contain the requested word (got: $wait_out)" ;; esac

    steer_out="$(codex_durable_steer "$LIVE_SD" "What single word did you just reply with? Answer ONLY that word, nothing else.")" || true
    [ "$(jget "$steer_out" .thread_id)" = "$tid" ] || fail "live steer: thread_id changed across turns (not the same durable session)"
    wait2_out="$(codex_durable_wait "$LIVE_SD" 120)" && wait2_rc=0 || wait2_rc=$?
    [ "$wait2_rc" -eq 0 ] || fail "live wait2: expected rc 0, got $wait2_rc: $wait2_out"
    recall_lc="$(jget "$wait2_out" .turn.final_agent_message | tr '[:upper:]' '[:lower:]')"
    case "$recall_lc" in *herddurablelive*) : ;; *) fail "live steer: model did not recall prior-turn content across the resume (got: $wait2_out)" ;; esac
    ok; echo "PASS (7a) LIVE start+wait+steer: real thread_id stable across turns, model recalls prior-turn content on resume"

    marker="/tmp/herd-durable-test-marker-$$"
    rm -f "$marker"
    steer_long_out="$(codex_durable_steer "$LIVE_SD" "Run this exact shell command and wait for it to finish: sleep 20 && touch $marker. Then reply DONE.")" || true
    [ "$(jget "$steer_long_out" .session_state)" = "working" ] || fail "live steer (long): expected session_state=working right after launch (got: $steer_long_out)"
    sleep 3
    cancel_out="$(codex_durable_cancel "$LIVE_SD" 5)" || true
    [ "$(jget "$cancel_out" .session_state)" = "cancelled" ] || fail "live cancel: session_state != cancelled (got: $cancel_out)"
    sleep 1
    if pgrep -f "sleep 20 && touch $marker" >/dev/null 2>&1; then
      fail "live cancel: the shell command codex was running is still alive — cancel leaked a process"
    fi
    [ -f "$marker" ] && fail "live cancel: the marker file exists — the cancelled command ran to completion instead of being interrupted"
    ok; echo "PASS (7b) LIVE mid-turn cancel: no leaked child process, the interrupted shell command never completed"

    resume_out="$(codex_durable_steer "$LIVE_SD" "Reply with exactly and only the single word: herddurablerecovered")" || true
    [ "$(jget "$resume_out" .thread_id)" = "$tid" ] || fail "live steer-after-cancel: thread_id changed — the cancelled session did not resume the same thread"
    resume_wait="$(codex_durable_wait "$LIVE_SD" 120)" && resume_rc=0 || resume_rc=$?
    [ "$resume_rc" -eq 0 ] || fail "live steer-after-cancel: expected rc 0, got $resume_rc: $resume_wait"
    recovered_lc="$(jget "$resume_wait" .turn.final_agent_message | tr '[:upper:]' '[:lower:]')"
    case "$recovered_lc" in *herddurablerecovered*) : ;; *) fail "live steer-after-cancel: reply did not contain the requested word (got: $resume_wait)" ;; esac
    ok; echo "PASS (7c) LIVE steer-after-cancel: the SAME thread_id resumes cleanly after a mid-turn cancel"
  fi
fi

echo "─────────────────────────────────────────────"
echo "codex-durable-coordinator.sh: $pass checks passed"
