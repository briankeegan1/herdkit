#!/usr/bin/env bash
# test-review-sever-protect.sh — HERD-245: in-flight reviews must NOT be severed by a watcher
# process-group kill (the herdr pane-recycle / `herd reload` shape). Genuinely past-deadline
# reviews are still reaped by the corpse sweep (unchanged).
#
# Asserts:
#   (1) _bg_new_session launches a child whose pgid != the caller's pgid (process-group isolation).
#   (2) ACTIVE review survives a process-group kill of a stand-in "watcher" parent (the reload shape).
#   (3) Past-deadline live reviewer is still SIGTERMed + reaped by _sweep_gate_corpses (timeout path).
#   (4) _dispatch_review records a live detached pid that produces a verdict after a group-kill of
#       a sibling-in-group sleeper (simulates watcher death without killing the review).
#
# Fully hermetic: temp dir only, stubbed reviewer, no network/model/panes.
#
# HERD-253: every assertion needs an env that can put a command in its own process group. Where
# neither setsid(1) nor python3 exists, this prints "SKIP (env: ...)" and exits 0 (the tolerated-env
# convention, cf. test-backlog-view-render.sh). The probe measures the ENV only — a regression that
# removes isolation from _bg_new_session still reds check (1) rather than skipping.
#
# Run:  bash tests/test-review-sever-protect.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../scripts/herd/agent-watch.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"; kill $(jobs -p) 2>/dev/null || true; kill "${LIVEPID:-}" "${REV_PID:-}" 2>/dev/null || true' EXIT
pass=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ pass=$((pass+1)); }
[ -f "$WATCH" ] || fail "agent-watch.sh not found at $WATCH"

# ── stub binaries on PATH ─────────────────────────────────────────────────────
BIN="$T/bin"; mkdir -p "$BIN"
for cmd in gh git herdr; do printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$cmd"; chmod +x "$BIN/$cmd"; done
export PATH="$BIN:$PATH"

# ── source agent-watch.sh in lib mode ─────────────────────────────────────────
export AGENT_WATCH_LIB=1
export HERD_DRIVER=headless
export WORKTREES_DIR="$T/trees"; mkdir -p "$T/trees"
export HERD_CONFIG_FILE="$T/no-such-config"
export JOURNAL_FILE="$T/journal.jsonl"; : > "$JOURNAL_FILE"
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"
render() { :; }

for fn in _bg_new_session _dispatch_review _sweep_gate_corpses _marker_write _marker_live \
          _review_inflight_file _review_result_file _review_pid_live; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined after sourcing"
done
ok

TREES="$WORKTREES_DIR"

# ── pgid helpers + env capability probe (HERD-253) ────────────────────────────
# Every assertion here rests on new-session isolation, and the split does not always land at fork:
# without setsid(1) (macOS) _bg_new_session reaches a new session via a python3 fork+exec that calls
# setsid() a few ms LATER, and a shell with no job control (any non-interactive builder sandbox or
# coordinator shell, as opposed to the watcher's interactive tty pane) starts the background child
# inside the caller's group. So poll for the split instead of sampling it once. If a trivial command
# can never be split off at all, this env cannot host the behaviour under test — SKIP rather than
# red, since the protection logic itself is env-independent and is exercised wherever it can run.
_pgid_of(){ ps -o pgid= -p "$1" 2>/dev/null | tr -d ' '; }

# _await_pgid_split <pid> <pgid-to-differ-from> — 0 once <pid> lives elsewhere, 1 after ~3s.
_await_pgid_split(){
  local pid="$1" other="$2" cur _i
  for _i in $(seq 1 30); do
    cur="$(_pgid_of "$pid")"
    [ -n "$cur" ] || return 1   # child already gone — nothing left to observe
    [ "$cur" != "$other" ] && return 0
    sleep 0.1
  done
  return 1
}

# Launch <cmd...> in a session of its own, mirroring _bg_new_session's fallback chain, so the test
# harness can group-kill a stand-in watcher without taking itself down. Never the plain-background
# last resort: an unsplit child would put that kill on OUR group. The probe below proves one of
# these two paths works here before any caller relies on it.
_test_new_session(){
  if command -v setsid >/dev/null 2>&1; then
    setsid "$@" &
  else
    python3 -c 'import os,sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' "$@" &
  fi
  _TEST_NEW_SESSION_PID=$!
  # Disowned: these children are group-killed on purpose below, and an un-disowned job makes the
  # shell report the kill ("Terminated: 15") onto the suite's stderr.
  disown "$_TEST_NEW_SESSION_PID" 2>/dev/null || true
}

# _env_can_split — can THIS env put a trivial command in a process group of its own?
# Deliberately probes with the test's own launcher, never with _bg_new_session: probing through the
# function under test would turn a real HERD-245 regression (isolation removed) into a SKIP, and the
# suite would go green on exactly the bug it exists to catch. The env is the only variable here.
_env_can_split(){
  command -v setsid >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1 || return 1
  local pid rc=0
  _test_new_session sleep 5
  pid="$_TEST_NEW_SESSION_PID"
  [ -n "$pid" ] || return 1
  _await_pgid_split "$pid" "$MYPGID" || rc=1
  kill "$pid" 2>/dev/null || true
  return "$rc"
}

MYPGID="$(_pgid_of $$)"
if [ -z "$MYPGID" ] || ! _env_can_split; then
  echo "SKIP (env: no pgid isolation available)"
  exit 0
fi

# ── (1) _bg_new_session isolates process group ────────────────────────────────
_bg_new_session sleep 60
CHILD="$_BG_NEW_SESSION_PID"
[ -n "$CHILD" ] || fail "(1) _bg_new_session returned empty pid"
kill -0 "$CHILD" 2>/dev/null || fail "(1) child not alive right after launch"
_await_pgid_split "$CHILD" "$MYPGID" \
  || fail "(1) child pgid ($(_pgid_of "$CHILD")) must differ from caller pgid ($MYPGID) — no isolation"
kill "$CHILD" 2>/dev/null || true; wait "$CHILD" 2>/dev/null || true
ok

# ── (2) ACTIVE review survives process-group kill of a stand-in watcher ───────
# Model: a "watcher" shell in its own process group launches a reviewer via _bg_new_session
# (as _dispatch_review does). An external actor kills the watcher's process group (the herdr
# pane-recycle shape). The reviewer must still be alive.
STUB_REVIEW="$T/stub-review.sh"
cat > "$STUB_REVIEW" <<'STUB'
#!/usr/bin/env bash
# Long-running reviewer: sleep then write PASS (if not severed first).
sleep "${STUB_REVIEW_SLEEP:-8}"
rf="${HERD_REVIEW_RESULT_FILE:-}"
if [ -n "$rf" ]; then
  printf 'REVIEW: PASS\n' > "${rf}.tmp.$$" && mv -f "${rf}.tmp.$$" "$rf"
fi
exit 0
STUB
chmod +x "$STUB_REVIEW"

WATCHER_SH="$T/fake-watcher.sh"
cat > "$WATCHER_SH" <<EOF
#!/usr/bin/env bash
# Stand-in watcher: join a known process group, launch reviewer via the shipped helper, write pids.
set -u
export AGENT_WATCH_LIB=1 HERD_DRIVER=headless WORKTREES_DIR="$TREES" HERD_CONFIG_FILE="$T/no-such-config"
export JOURNAL_FILE="$JOURNAL_FILE" HERD_REVIEW_BIN="$STUB_REVIEW" STUB_REVIEW_SLEEP=8
# shellcheck source=/dev/null
. "$WATCH"
render() { :; }
_dispatch_review 901 slug-survives shasurv901
# Emit watcher pid + review pid for the outer harness.
printf '%s %s\n' "\$\$" "\$(head -1 "$TREES/.review-inflight-901-shasurv901")"
# Stay alive until group-killed (the pane-held watcher shape).
sleep 120
EOF
chmod +x "$WATCHER_SH"

# Launch fake watcher in its own session so we can group-kill it without killing this test.
_test_new_session bash "$WATCHER_SH" > "$T/watcher-out" 2>"$T/watcher-err"
# Wait for the dispatch to land.
for _i in 1 2 3 4 5 6 7 8 9 10; do
  [ -s "$T/watcher-out" ] && break
  sleep 0.2
done
[ -s "$T/watcher-out" ] || fail "(2) fake watcher never reported pids: $(cat "$T/watcher-err" 2>/dev/null)"
read -r WPID RPID < "$T/watcher-out"
[ -n "$WPID" ] && [ -n "$RPID" ] || fail "(2) bad watcher-out: '$(cat "$T/watcher-out")'"
kill -0 "$RPID" 2>/dev/null || fail "(2) precondition: reviewer pid $RPID must be alive before group-kill"
# Process-group kill of the WATCHER (not the reviewer — they must be in different groups).
WPGID="$(_pgid_of "$WPID")"
[ -n "$WPGID" ] || fail "(2) watcher pgid unreadable"
_await_pgid_split "$RPID" "$WPGID" \
  || fail "(2) reviewer still shares watcher pgid ($WPGID) — isolation broken"
kill -TERM -"$WPGID" 2>/dev/null || true
sleep 0.4
# Watcher should be dead; reviewer must still be alive.
kill -0 "$WPID" 2>/dev/null && fail "(2) watcher should have died from group-kill"
kill -0 "$RPID" 2>/dev/null || fail "(2) ACTIVE reviewer was severed by watcher process-group kill (HERD-245 regression)"
# Let the stub finish and write its verdict (proves it was not merely zombie).
for _i in $(seq 1 40); do
  [ -f "$TREES/.review-result-901-shasurv901" ] && break
  sleep 0.25
done
[ -f "$TREES/.review-result-901-shasurv901" ] || fail "(2) surviving reviewer never wrote a verdict"
grep -q '^REVIEW: PASS' "$TREES/.review-result-901-shasurv901" \
  || fail "(2) verdict not PASS: $(cat "$TREES/.review-result-901-shasurv901")"
kill "$RPID" 2>/dev/null || true
ok

# ── (3) Past-deadline live reviewer still reaped (timeout path unchanged) ─────
: > "$JOURNAL_FILE"
export REVIEW_INFLIGHT_TIMEOUT=3
sleep 300 & LIVEPID=$!; disown "$LIVEPID" 2>/dev/null || true
LST="$(_pid_starttime "$LIVEPID")"
NOW="$(date +%s)"
RINF="$(_review_inflight_file 902 shaTO)"
# Plant past-deadline marker directly (3-line body: pid, starttime, dispatch_ts far in the past).
printf '%s\n%s\n%s\n' "$LIVEPID" "$LST" "$((NOW - 9999))" > "$RINF"
_sweep_gate_corpses
[ ! -e "$RINF" ] || fail "(3) past-deadline reviewer must be reaped"
grep -q '"reason":"review_timeout"' "$JOURNAL_FILE" || fail "(3) must journal review_timeout"
sleep 0.3
kill -0 "$LIVEPID" 2>/dev/null && fail "(3) past-deadline reviewer must have been SIGTERMed"
{ wait "$LIVEPID"; } 2>/dev/null || true; LIVEPID=""
unset REVIEW_INFLIGHT_TIMEOUT
ok

# ── (4) _dispatch_review end-to-end: detached pid + adopt on re-entry ──────────
export HERD_REVIEW_BIN="$STUB_REVIEW" STUB_REVIEW_SLEEP=2
rm -f "$TREES"/.review-* 2>/dev/null || true
_dispatch_review 903 slug-e2e shae2e903
RPID2="$(head -1 "$(_review_inflight_file 903 shae2e903)" 2>/dev/null || true)"
[ -n "$RPID2" ] || fail "(4) dispatch left no inflight pid"
kill -0 "$RPID2" 2>/dev/null || fail "(4) dispatched reviewer not alive"
# Re-entry must ADOPT, not double-dispatch.
_dispatch_review 903 slug-e2e shae2e903
RPID3="$(head -1 "$(_review_inflight_file 903 shae2e903)" 2>/dev/null || true)"
[ "$RPID2" = "$RPID3" ] || fail "(4) re-dispatch replaced the live reviewer ($RPID2 → $RPID3)"
# Wait for verdict.
for _i in $(seq 1 30); do
  [ -f "$(_review_result_file 903 shae2e903)" ] && break
  sleep 0.2
done
[ -f "$(_review_result_file 903 shae2e903)" ] || fail "(4) e2e reviewer never wrote a verdict"
grep -q '^REVIEW: PASS' "$(_review_result_file 903 shae2e903)" || fail "(4) e2e verdict not PASS"
ok

echo "ALL PASS ($pass checks)"
