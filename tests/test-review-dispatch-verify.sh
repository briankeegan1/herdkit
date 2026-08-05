#!/usr/bin/env bash
# test-review-dispatch-verify.sh — hermetic tests for HERD-523 / issues #633 + #634: REVIEW-dispatch
# wake verification, and the standalone review·<slug> viewer tab that leaked permanently.
#
# The two regressions, one subsystem (money-bets, 2026-08-04):
#   #633  herd-review.sh delivers the reviewer invocation into a split pane and takes the returned
#         pane id as proof the review is RUNNING. It only proves the command was DELIVERED. When the
#         pane never executed it, the gate polled a result file nobody would write for the full
#         HERD_REVIEW_AGENT_TIMEOUT (default 1800s) before falling through to the standalone viewer
#         tab — the fallback it could have taken in 20 seconds. Same delivered-vs-executed family as
#         the spawn stall PR #635 fixed (tests/test-spawn-wake-verify.sh).
#   #634  That standalone review·<slug> viewer tab's ONLY record is a line appended to .herd-tabs
#         under a bare `|| true`. Merge teardown AND the orphan sweep both key on that registry, so a
#         failed append leaves the tab live, unregistered and PERMANENTLY un-sweepable — with the
#         evidence swallowed.
#
# Asserts, against a STUBBED driver (no herdr server, no model, no network):
#   (1) herd_review_wake_verify — the shared wake helper's review edge:
#       a. a reviewer already "working" → rc 0, no retry sends, no pane closed, no tab allocated
#       b. a reviewer that NEVER starts → retries ONCE in the SAME pane (bare Enter, then exactly one
#          re-delivery of the invocation), allocates NO tab, CLOSES the stalled pane, journals
#          review_wake_result woke=0 pane_closed=1, escalates loudly, and returns 1 (the caller is told)
#       c. HERD_REVIEW_WAKE_VERIFY=off is a total no-op kill switch (rc 0, no sends, no journal)
#   (2) _close_review_viewer_tab (agent-watch.sh) — teardown by SLUG-LABELED lookup:
#       a. fires with an EMPTY .herd-tabs (the leak case: registration never landed)
#       b. matches the decorated "review·<slug> ✅" label too
#       c. does NOT close a PREFIX-COLLIDING slug's tab (slug "auth" vs tab "review·auth-retry")
#       d. byte-quiet no-op when there is no viewer tab (the common builder-tab-split placement)
#       e. drops the .herd-tabs row when one DID land, so a closed tab never lingers as a stale row
#   (3) herd-review.sh end-to-end, both legs:
#       a. a stalled agent-pane dispatch retries in-pane, closes the stalled pane, and falls back to
#          the standalone tab — with the single `tab create` happening AFTER the in-pane retry, never
#          as part of it
#       b. a .herd-tabs registration that FAILS journals tab_registry_write_failed instead of `|| true`
#
# NETWORK-FREE. Stubs herdr/gh/git/claude. python3 is a herd hard dep (journal.sh).
# Run:  bash tests/test-review-dispatch-verify.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
DRIVER="$ROOT/scripts/herd/driver.sh"
JOURNAL_SRC="$ROOT/scripts/herd/journal.sh"
WATCH="$ROOT/scripts/herd/agent-watch.sh"
REVIEW="$ROOT/scripts/herd/herd-review.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

for f in "$DRIVER" "$JOURNAL_SRC" "$WATCH" "$REVIEW"; do
  [ -f "$f" ] || fail "missing engine file: $f"
done
command -v python3 >/dev/null 2>&1 || fail "python3 required to run this test"

# ── stub binaries ────────────────────────────────────────────────────────────────────────────────
BIN="$T/bin"; mkdir -p "$BIN"
for cmd in gh git; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$cmd"; chmod +x "$BIN/$cmd"
done
# claude stub: the headless fallback reviewer, always PASS.
cat > "$BIN/claude" <<'STUB'
#!/usr/bin/env bash
printf '{"type":"result","subtype":"success","result":"REVIEW: PASS"}\n'
exit 0
STUB
chmod +x "$BIN/claude"

# herdr stub. Every call is logged verbatim to $HERDR_CALL_LOG (so ORDER is assertable — the
# in-pane retry must precede any tab allocation). Rosters come from response files so each case can
# shape them; agent_status is read live from $STUB_STATUS_FILE so a case can flip a stalled reviewer
# to "working" mid-run.
cat > "$BIN/herdr" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${HERDR_CALL_LOG:-/dev/null}" 2>/dev/null || true
case "$1 $2" in
  "workspace list")
    printf '{"result":{"workspaces":[{"workspace_id":"wA","label":"%s"}]}}\n' "${WORKSPACE_NAME:-herdkit}" ;;
  "agent list")
    st="$(cat "${STUB_STATUS_FILE:-/dev/null}" 2>/dev/null || true)"; st="${st:-idle}"
    if [ -n "${HERDR_AGENT_LIST_RESP:-}" ] && [ -f "${HERDR_AGENT_LIST_RESP}" ]; then
      STATUS="$st" RESP="${HERDR_AGENT_LIST_RESP}" python3 -c '
import json, os, sys
d = json.loads(open(os.environ["RESP"], encoding="utf-8").read())
for a in (d.get("result") or {}).get("agents") or []:
    if a.get("agent_status") == "@STATUS@":
        a["agent_status"] = os.environ["STATUS"]
sys.stdout.write(json.dumps(d) + "\n")
' 2>/dev/null || printf '{"result":{"agents":[]}}\n'
    else
      printf '{"result":{"agents":[]}}\n'
    fi ;;
  "pane list")
    cat "${HERDR_PANE_LIST_RESP:-/dev/null}" 2>/dev/null || printf '{"result":{"panes":[]}}\n' ;;
  "tab list")
    cat "${HERDR_TAB_LIST_RESP:-/dev/null}" 2>/dev/null || printf '{"result":{"tabs":[]}}\n' ;;
  "agent start")
    cat "${HERDR_AGENT_START_RESP:-/dev/null}" 2>/dev/null \
      || printf '{"result":{"agent":{"pane_id":""}}}\n' ;;
  "tab create")
    printf '{"result":{"tab":{"tab_id":"viewerTab1"},"root_pane":{"pane_id":"viewerRoot1"}}}\n' ;;
  *) : ;;
esac
exit 0
STUB
chmod +x "$BIN/herdr"
export PATH="$BIN:$PATH" NO_COLOR=1

export HERDR_CALL_LOG="$T/herdr-calls.log"
export HERDR_AGENT_LIST_RESP="$T/agent-list.json"
export HERDR_TAB_LIST_RESP="$T/tab-list.json"
export HERDR_PANE_LIST_RESP="$T/pane-list.json"
export HERDR_AGENT_START_RESP="$T/agent-start.json"
export STUB_STATUS_FILE="$T/agent-status"
printf '{"result":{"agents":[]}}\n' > "$HERDR_AGENT_LIST_RESP"
printf '{"result":{"tabs":[]}}\n'   > "$HERDR_TAB_LIST_RESP"
printf '{"result":{"panes":[]}}\n'  > "$HERDR_PANE_LIST_RESP"
printf '{"result":{"agent":{"pane_id":""}}}\n' > "$HERDR_AGENT_START_RESP"
echo idle > "$STUB_STATUS_FILE"

_reset() { : > "$HERDR_CALL_LOG"; : > "$JOURNAL_FILE"; }
_calls() { grep -c "$1" "$HERDR_CALL_LOG" 2>/dev/null || true; }

# ═══ (1) herd_review_wake_verify — the review edge of the shared wake helper ══════════════════════
# Sourced in a SUBSHELL-free section: driver.sh in lib mode (its documented zero-dependency contract)
# + journal.sh, with date/sleep mocked so the REAL backed-off poll loop terminates without wall clock.
export WORKTREES_DIR="$T/trees"; mkdir -p "$T/trees"
export JOURNAL_FILE="$T/journal.jsonl"; : > "$JOURNAL_FILE"
# shellcheck source=/dev/null
. "$JOURNAL_SRC" || fail "sourcing journal.sh failed"
# shellcheck source=/dev/null
. "$DRIVER" || fail "sourcing driver.sh (lib mode) failed"

CLOCK="$T/mock-clock"; echo 1000 > "$CLOCK"
date() {
  if [ "${1:-}" = "+%s" ]; then
    local n; n=$(( $(cat "$CLOCK" 2>/dev/null || echo 1000) + 1 )); echo "$n" > "$CLOCK"; printf '%s\n' "$n"
  else command date "$@"; fi
}
sleep() { :; }
export -f date sleep
export HERD_REVIEW_WAKE_WINDOW=4   # test seam: shrink the poll window (same class as HERD_SPAWN_WAKE_WINDOW)

# The reviewer registers as "review·rslug", which herdr carries SANITIZED as "review-rslug"
# (herd_agent_name_sanitize) — the lookup must resolve that itself from the bare branch slug.
printf '{"result":{"agents":[{"name":"review-rslug","pane_id":"reviewPane1","agent_status":"@STATUS@"}]}}\n' \
  > "$HERDR_AGENT_LIST_RESP"

# ── (1a) already executing → clean pass, nothing touched ─────────────────────────────────────────
_reset; echo working > "$STUB_STATUS_FILE"
herd_review_wake_verify "rslug" "reviewPane1" "REVIEWER INVOCATION"
[ "$?" -eq 0 ] || fail "1a: a reviewer that is already working must return 0"
ok
[ "$(_calls 'pane send-keys')" -eq 0 ] || fail "1a: no Enter should be sent to a working reviewer"
ok
[ "$(_calls 'pane run')" -eq 0 ] || fail "1a: the invocation must never be re-delivered to a working reviewer"
ok
[ "$(_calls 'pane close')" -eq 0 ] || fail "1a: a working reviewer's pane must NEVER be closed"
ok
[ "$(_calls 'tab create')" -eq 0 ] || fail "1a: verification must never allocate a tab"
ok
wl="$(grep 'review_wake_result' "$JOURNAL_FILE" | tail -1)"
grep -q '"woke":1' <<< "$wl" || fail "1a: review_wake_result must record woke=1 (got: $wl)"
ok
grep -q '"retried":"none"' <<< "$wl" || fail "1a: review_wake_result must record retried=none (got: $wl)"
ok

# ── (1b) never starts → ONE in-pane retry, NO tab, stalled pane closed, caller told ──────────────
_reset; echo idle > "$STUB_STATUS_FILE"
# The pane identity the guarded close proves before closing: the roster maps reviewPane1 →
# "agent:review-rslug", which carries the colon-anchored ":review" kind.
warn="$(herd_review_wake_verify "rslug" "reviewPane1" "REVIEWER INVOCATION" 2>&1 1>/dev/null)"; rc=$?
[ "$rc" -eq 1 ] || fail "1b: a verified stall must return 1 so the caller can fall back (got rc=$rc)"
ok
[ "$(_calls 'pane run reviewPane1')" -eq 1 ] \
  || fail "1b: the invocation must be re-delivered EXACTLY ONCE, into the SAME pane (log: $(cat "$HERDR_CALL_LOG"))"
ok
[ "$(_calls 'tab create')" -eq 0 ] \
  || fail "1b: the retry must NEVER allocate a fresh tab (log: $(cat "$HERDR_CALL_LOG"))"
ok
[ "$(_calls 'pane close reviewPane1')" -eq 1 ] \
  || fail "1b: the stalled pane must be closed exactly once — never left behind (log: $(cat "$HERDR_CALL_LOG"))"
ok
wl="$(grep 'review_wake_result' "$JOURNAL_FILE" | tail -1)"
grep -q '"woke":0' <<< "$wl" || fail "1b: review_wake_result must record woke=0 (got: $wl)"
ok
grep -q '"retried":"prompt"' <<< "$wl" || fail "1b: review_wake_result must record retried=prompt (got: $wl)"
ok
grep -q '"pane_closed":1' <<< "$wl" || fail "1b: review_wake_result must record pane_closed=1 (got: $wl)"
ok
grep -qi "never started executing" <<< "$warn" \
  || fail "1b: a verified stall must escalate LOUDLY (got: $warn)"
ok

# ── (1c) kill switch: HERD_REVIEW_WAKE_VERIFY=off is a total no-op ───────────────────────────────
_reset; echo idle > "$STUB_STATUS_FILE"
HERD_REVIEW_WAKE_VERIFY=off herd_review_wake_verify "rslug" "reviewPane1" "REVIEWER INVOCATION"
[ "$?" -eq 0 ] || fail "1c: the kill switch must return 0 (agent-pane mode proceeds exactly as before)"
ok
[ ! -s "$HERDR_CALL_LOG" ] && [ ! -s "$JOURNAL_FILE" ] \
  || fail "1c: HERD_REVIEW_WAKE_VERIFY=off must skip verification entirely (no herdr calls, no journal)"
ok

unset -f date sleep
unset HERD_REVIEW_WAKE_WINDOW

# ═══ (2) _close_review_viewer_tab — teardown by SLUG LABEL, with an EMPTY registry ════════════════
# agent-watch.sh in LIB mode (AGENT_WATCH_LIB=1 → helpers only, no loop), each case in a subshell so
# the sourced watcher never leaks into the rest of the file.
_viewer_case() {
  # <slug> <tab-list-json> [registry-seed]
  local _slug="$1" _tabs="$2" _seed="${3:-}"
  local _dir="$T/viewer-$_slug-$RANDOM"; mkdir -p "$_dir"
  printf '%s\n' "$_tabs" > "$HERDR_TAB_LIST_RESP"
  [ -n "$_seed" ] && printf '%s\n' "$_seed" > "$_dir/.herd-tabs"
  : > "$HERDR_CALL_LOG"
  (
    export AGENT_WATCH_LIB=1 HERD_CONFIG_FILE="$T/no-such-config" \
           WORKTREES_DIR="$_dir" TREES="$_dir" JOURNAL_FILE="$_dir/journal.jsonl" \
           WORKSPACE_NAME=herdkit
    # shellcheck source=/dev/null
    . "$WATCH" >/dev/null 2>&1 || { echo "__SOURCE_FAILED__" >&2; exit 1; }
    _close_review_viewer_tab "$_slug" verdict-consumed
  ) || fail "2: sourcing agent-watch.sh in lib mode failed"
  VIEWER_DIR="$_dir"
}

# ── (2a) EMPTY .herd-tabs — the leak case — still tears the viewer tab down ──────────────────────
_viewer_case vslug '{"result":{"tabs":[{"tab_id":"vTab1","label":"review·vslug","workspace_id":"wA"}]}}'
grep -q 'tab close vTab1' "$HERDR_CALL_LOG" \
  || fail "2a: the viewer tab must be closed by SLUG LABEL even with no .herd-tabs row (log: $(cat "$HERDR_CALL_LOG"))"
ok
grep -q 'review_viewer_tab_closed' "$VIEWER_DIR/journal.jsonl" 2>/dev/null \
  || fail "2a: closing the viewer tab must journal review_viewer_tab_closed"
ok

# ── (2b) the DECORATED label ("review·<slug> ✅") is the same tab ────────────────────────────────
_viewer_case vslug '{"result":{"tabs":[{"tab_id":"vTab2","label":"review·vslug ✅","workspace_id":"wA"}]}}'
grep -q 'tab close vTab2' "$HERDR_CALL_LOG" \
  || fail "2b: a decorated 'review·<slug> ✅' label must still match (log: $(cat "$HERDR_CALL_LOG"))"
ok

# ── (2c) a PREFIX-COLLIDING slug's tab is NOT someone else's to close ────────────────────────────
_viewer_case auth '{"result":{"tabs":[{"tab_id":"vTab3","label":"review·auth-retry","workspace_id":"wA"}]}}'
grep -q 'tab close' "$HERDR_CALL_LOG" \
  && fail "2c: slug 'auth' must NEVER close 'review·auth-retry' (log: $(cat "$HERDR_CALL_LOG"))"
ok
[ ! -s "$VIEWER_DIR/journal.jsonl" ] \
  || fail "2c: a non-match must be byte-quiet (journal: $(cat "$VIEWER_DIR/journal.jsonl"))"
ok

# ── (2d) no viewer tab at all (the common builder-tab split) → byte-quiet no-op ──────────────────
_viewer_case vslug '{"result":{"tabs":[{"tab_id":"bTab1","label":"vslug","workspace_id":"wA"}]}}'
grep -q 'tab close' "$HERDR_CALL_LOG" \
  && fail "2d: a split-placed review has no viewer tab — nothing may be closed"
ok
[ ! -s "$VIEWER_DIR/journal.jsonl" ] \
  || fail "2d: the common placement must journal nothing (journal: $(cat "$VIEWER_DIR/journal.jsonl"))"
ok

# ── (2e) a registration that DID land is dropped, and only that row ──────────────────────────────
_viewer_case vslug '{"result":{"tabs":[{"tab_id":"vTab5","label":"review·vslug","workspace_id":"wA"}]}}' \
  "$(printf 'other-slug otherTab builder\nreview·vslug vTab5 review')"
grep -q 'tab close vTab5' "$HERDR_CALL_LOG" || fail "2e: the registered viewer tab must be closed"
ok
grep -q 'vTab5' "$VIEWER_DIR/.herd-tabs" \
  && fail "2e: the closed tab's registry row must be dropped (registry: $(cat "$VIEWER_DIR/.herd-tabs"))"
ok
grep -q 'otherTab' "$VIEWER_DIR/.herd-tabs" \
  || fail "2e: every OTHER registry row must survive byte-identical (registry: $(cat "$VIEWER_DIR/.herd-tabs"))"
ok

# ── (2f) THE WIRING: teardown fires from VERDICT CONSUMPTION itself, with an EMPTY .herd-tabs ────
# (2a)-(2e) prove the helper; this proves _review_gate_step actually calls it — the leg that would
# otherwise regress silently if the call site were dropped. Drives the REAL gate step over a collected
# PASS result file, with no .herd-tabs at all.
GATE="$T/gate"; mkdir -p "$GATE"
: > "$HERDR_CALL_LOG"
printf '{"result":{"tabs":[{"tab_id":"gTab1","label":"review·gslug","workspace_id":"wA"}]}}\n' \
  > "$HERDR_TAB_LIST_RESP"
printf '{"result":{"agents":[]}}\n' > "$HERDR_AGENT_LIST_RESP"
(
  export AGENT_WATCH_LIB=1 HERD_CONFIG_FILE="$T/no-such-config" \
         WORKTREES_DIR="$GATE" TREES="$GATE" JOURNAL_FILE="$GATE/journal.jsonl" WORKSPACE_NAME=herdkit
  # shellcheck source=/dev/null
  . "$WATCH" >/dev/null 2>&1 || exit 1
  printf 'REVIEW: PASS\n' > "$(_review_result_file 77 deadbee)"
  tok="$(_review_gate_step 77 gslug deadbee)"
  [ "$tok" = "PASS" ] || { echo "gate step token was '$tok', expected PASS" >&2; exit 1; }
) || fail "2f: driving the real _review_gate_step over a collected PASS failed"
ok
[ ! -e "$GATE/.herd-tabs" ] \
  || fail "2f: the registry must have stayed absent — this case is the EMPTY-registry leak scenario"
ok
grep -q 'tab close gTab1' "$HERDR_CALL_LOG" \
  || fail "2f: verdict consumption must close the viewer tab with NO registry row (log: $(cat "$HERDR_CALL_LOG"))"
ok
grep -q '"event":"review_viewer_tab_closed"' "$GATE/journal.jsonl" \
  || fail "2f: verdict consumption must journal review_viewer_tab_closed"
ok

# ═══ (3) herd-review.sh end-to-end ════════════════════════════════════════════════════════════════
export WORKSPACE_NAME=herdkit
export HERD_CONFIG_FILE="$T/no-such-config"

# ── (3a) a stalled agent-pane dispatch: in-pane retry, pane closed, THEN the fallback tab ────────
E2E="$T/e2e-a"; mkdir -p "$E2E"
: > "$HERDR_CALL_LOG"
echo idle > "$STUB_STATUS_FILE"   # the reviewer never starts executing
# Roster: the builder (agent-pane placement is chosen) AND the reviewer herd-review.sh just started.
printf '{"result":{"agents":[{"name":"test-slug","pane_id":"builderPane1","agent_status":"idle"},{"name":"review-test-slug","pane_id":"reviewPane1","agent_status":"@STATUS@"}]}}\n' \
  > "$HERDR_AGENT_LIST_RESP"
printf '{"result":{"tabs":[{"tab_id":"builderTab1","label":"test-slug","workspace_id":"wA"}]}}\n' \
  > "$HERDR_TAB_LIST_RESP"
printf '{"result":{"agent":{"pane_id":"reviewPane1"}}}\n' > "$HERDR_AGENT_START_RESP"

# HERD_REVIEW_AGENT_TIMEOUT is shrunk to 8s ONLY so a REGRESSION fails fast: with the fix in place the
# agent-pane poll is never entered at all (the stall is caught in ~3 window-seconds and the fallback
# takes over). Without it, a regressed build would sit on the 1800s default and HANG the gate instead
# of reporting — which is precisely the #633 failure mode, and a test must never reproduce it in wall
# clock to prove it.
out="$(WORKTREES_DIR="$E2E" JOURNAL_FILE="$E2E/journal.jsonl" \
       HERD_REVIEW_WAKE_WINDOW=1 HERD_REVIEW_RESULT_FILE="$E2E/result" \
       HERD_REVIEW_AGENT_TIMEOUT=8 HERD_REVIEW_AGENT_POLL=1 \
       bash "$REVIEW" 91 test-slug 2>"$E2E/stderr")"
rc=$?

grep -q 'agent start' "$HERDR_CALL_LOG" || fail "3a: the agent-pane dispatch must be attempted first"
ok
grep -q 'pane run reviewPane1' "$HERDR_CALL_LOG" \
  || fail "3a: the stalled dispatch must be retried IN THE SAME pane (log: $(cat "$HERDR_CALL_LOG"))"
ok
grep -q 'pane close reviewPane1' "$HERDR_CALL_LOG" \
  || fail "3a: the stalled reviewer pane must not be left behind (log: $(cat "$HERDR_CALL_LOG"))"
ok
[ "$(_calls 'tab create')" -eq 1 ] \
  || fail "3a: exactly ONE tab is allocated — the fallback viewer, never the retry (got $(_calls 'tab create'))"
ok
# ORDER is the proof that the tab belongs to the FALLBACK and not to the retry.
retry_ln="$(awk '/pane run reviewPane1/{print NR; exit}' "$HERDR_CALL_LOG")"
tabc_ln="$(awk '/tab create/{print NR; exit}' "$HERDR_CALL_LOG")"
[ -n "$retry_ln" ] && [ -n "$tabc_ln" ] && [ "$retry_ln" -lt "$tabc_ln" ] \
  || fail "3a: the in-pane retry must happen BEFORE any tab is allocated (retry@$retry_ln tab@$tabc_ln)"
ok
grep -q '"event":"review_wake_result"' "$E2E/journal.jsonl" 2>/dev/null \
  || fail "3a: the stalled dispatch must journal review_wake_result (journal: $(cat "$E2E/journal.jsonl" 2>/dev/null))"
ok
grep -q '"woke":0' "$E2E/journal.jsonl" || fail "3a: review_wake_result must record the stall (woke=0)"
ok
# …and the review still completes on the fallback path instead of burning the 1800s agent timeout.
[ "$rc" -eq 0 ] || fail "3a: the review must still reach a verdict via the fallback (rc=$rc, stderr: $(cat "$E2E/stderr"))"
ok
grep -q '^REVIEW: PASS$' <<< "$out" || fail "3a: fallback reviewer verdict should be PASS (got: $out)"
ok

# ── (3b) a .herd-tabs registration that FAILS journals instead of `|| true` ──────────────────────
# Forcing a real append failure without root: make .herd-tabs a DIRECTORY — `>> dir` fails on every
# POSIX platform, exactly as an unwritable/full $WORKTREES_DIR would.
E2E="$T/e2e-b"; mkdir -p "$E2E/.herd-tabs"
: > "$HERDR_CALL_LOG"
printf '{"result":{"agents":[]}}\n' > "$HERDR_AGENT_LIST_RESP"   # no builder → standalone viewer tab
printf '{"result":{"tabs":[]}}\n'   > "$HERDR_TAB_LIST_RESP"

out="$(WORKTREES_DIR="$E2E" JOURNAL_FILE="$E2E/journal.jsonl" \
       HERD_REVIEW_RESULT_FILE="$E2E/result" \
       bash "$REVIEW" 92 test-slug 2>"$E2E/stderr")"
rc=$?

grep -q 'tab create' "$HERDR_CALL_LOG" || fail "3b: the standalone viewer tab should be created"
ok
grep -q '"event":"tab_registry_write_failed"' "$E2E/journal.jsonl" 2>/dev/null \
  || fail "3b: a failed .herd-tabs registration must JOURNAL, not '|| true' (journal: $(cat "$E2E/journal.jsonl" 2>/dev/null))"
ok
grep -q 'viewerTab1' "$E2E/journal.jsonl" \
  || fail "3b: the journaled failure must name the tab that is now unregistered"
ok
grep -qi 'could not register tab' "$E2E/stderr" \
  || fail "3b: the failure must also be loud on stderr (stderr: $(cat "$E2E/stderr"))"
ok
[ "$rc" -eq 0 ] || fail "3b: registration is not a gate on the review — it must still reach a verdict (rc=$rc)"
ok

echo "ALL PASS ($pass checks)"
