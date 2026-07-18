#!/usr/bin/env bash
# test-finish-stall-watchdog.sh — hermetic test for the watcher's FINISH-LINE WATCHDOG (HERD-392): a
# builder whose agent went done/idle while its worktree carries real, unshipped work (uncommitted
# changes, or commits ahead of its own remote branch) and NO open PR is a finish-line stall, not a
# benign spare and not a wedge (wedge deliberately exempts a clean, committed-ahead tree as "in
# flight" — this leg exists to catch exactly that gap when it sits too long, grounded on six live
# instances 2026-07-16..18).
#
# Conventions mirror tests/test-wedged-builder.sh: sources agent-watch.sh's pure helpers via the
# AGENT_WATCH_LIB guard, points every ledger/journal path at a temp dir, drives the clock with the
# HERD_NOW_EPOCH seam, and stubs the driver send-text / wait-working seams so nothing touches a real
# pane. UNLIKE wedge, the clock lives in the shared pool (pysrc/herd/store.py finish_stall_*
# accessors) — this test drives the REAL store module against a scratch WORKTREES_DIR, exactly like
# tests/test-main-health-autofix-dedup.sh.
#
# Asserts:
#   • FINISH_STALL_MIN ship-dormant: unset/0/non-numeric ⇒ the whole leg is OFF, byte-identical (no
#     git probe beyond the tick's own, no python3 shellout, no journal, no notification)
#   • the pure classifier over every synthetic state (PR ⇒ NOT_STALLED; working ⇒ NOT_STALLED; no
#     work ⇒ NOT_STALLED; limit-parked ⇒ NOT_STALLED; within grace ⇒ PENDING; past grace + pending
#     state ⇒ FIRST_STALL; past grace + retasked state ⇒ SECOND_STALL; escalated state ⇒ ESCALATED)
#   • the real git probe: commits ahead of ORIGIN (not base) for a pushed-then-advanced branch, and
#     the never-pushed fallback (ahead of DEFAULT_BRANCH)
#   • end-to-end reconciliation: PENDING → FIRST_STALL (re-task delivered) → resets the clock to
#     'retasked' → a SECOND grace window escalates; a re-task that never lands escalates immediately
#   • the shared-pool clock is durable across "seats" (a fresh accessor call sees the same anchor)
#   • the console rows: calm re-task-sent vs red needs-you, no leak of the banned 'idle' word
#   • never fires while a PR exists or while the agent is working (escape hatches)
# Run:  bash tests/test-finish-stall-watchdog.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../scripts/herd/agent-watch.sh"
PYSRC="$HERE/../pysrc"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ pass=$((pass+1)); }

[ -f "$WATCH" ] || fail "agent-watch.sh not found at $WATCH"
[ -f "$PYSRC/herd/store.py" ] || fail "pysrc/herd/store.py not found"
command -v git >/dev/null 2>&1 || fail "git required to run this test"
command -v python3 >/dev/null 2>&1 || fail "python3 required to run this test"

BIN="$T/bin"; mkdir -p "$BIN"
cat > "$BIN/herdr" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "notification" ] && [ "${2:-}" = "show" ]; then
  printf '%s\n' "${3:-}" >> "${HERDR_NOTIFY_LOG:?HERDR_NOTIFY_LOG unset}"
fi
exit 0
STUB
chmod +x "$BIN/herdr"
export PATH="$BIN:$PATH"

export AGENT_WATCH_LIB=1
export HERD_CONFIG_FILE="$T/no-such-config"
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"
for fn in _finish_stall_min _finish_stall_enabled _finish_stall_grace_secs \
          _finish_stall_commits_ahead _classify_finish_stall _finish_stall_record \
          _finish_stall_mark _finish_stall_state _finish_stall_reset _finish_stall_clear \
          _finish_stall_retask _row_finish_stall _reconcile_finish_stall _finish_stall_note_escape; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined"
done

export JOURNAL_FILE="$T/journal.log"
export HERDR_NOTIFY_LOG="$T/notify.log"; : > "$HERDR_NOTIFY_LOG"
export TREES="$T/pool"; mkdir -p "$TREES"
DEFAULT_BRANCH=main

NOW=1000000000

# ── FINISH_STALL_MIN ship-dormant ────────────────────────────────────────────────────────────────
( unset FINISH_STALL_MIN; _finish_stall_enabled ) && fail "unset FINISH_STALL_MIN must be OFF"
FINISH_STALL_MIN=""    _finish_stall_enabled && fail "empty FINISH_STALL_MIN must be OFF"
FINISH_STALL_MIN=0     _finish_stall_enabled && fail "0 must be OFF"
FINISH_STALL_MIN=xx    _finish_stall_enabled && fail "non-numeric must be OFF"
FINISH_STALL_MIN=-1    _finish_stall_enabled && fail "negative (non-numeric per the guard) must be OFF"
FINISH_STALL_MIN=30    _finish_stall_enabled || fail "a positive integer must be ON"
[ "$(FINISH_STALL_MIN=30 _finish_stall_grace_secs)" = "1800" ] || fail "30m should be 1800s"
[ "$(FINISH_STALL_MIN=1  _finish_stall_grace_secs)" = "60"   ] || fail "1m should be 60s"
( unset FINISH_STALL_MIN; [ "$(_finish_stall_grace_secs)" = "0" ] ) || fail "off should read grace 0"
ok

GRACE=1800   # 30m, the suggested default
PAST="$((NOW - GRACE - 1))"

# ── the pure classifier ──────────────────────────────────────────────────────────────────────────
# args: agent-status has-pr has-work limit-parked state first-seen now grace
[ "$(_classify_finish_stall done 1 1 0 pending "$PAST" "$NOW" "$GRACE")" = "NOT_STALLED" ] \
  || fail "an open PR must always escape, whatever the work/age"
[ "$(_classify_finish_stall working 0 1 0 pending "$PAST" "$NOW" "$GRACE")" = "NOT_STALLED" ] \
  || fail "a working agent must never stall (escape hatch)"
[ "$(_classify_finish_stall done 0 0 0 pending "$PAST" "$NOW" "$GRACE")" = "NOT_STALLED" ] \
  || fail "no work (clean, nothing ahead) must never stall"
[ "$(_classify_finish_stall done 0 1 1 pending "$PAST" "$NOW" "$GRACE")" = "NOT_STALLED" ] \
  || fail "a limit-parked agent must never stall (it cannot act on a nudge)"
[ "$(_classify_finish_stall "" 0 1 0 pending "$PAST" "$NOW" "$GRACE")" = "NOT_STALLED" ] \
  || fail "no agent record ⇒ NOT_STALLED (the dead reconciliation's business)"
ok

[ "$(_classify_finish_stall done 0 1 0 pending ""             "$NOW" "$GRACE")" = "PENDING" ] \
  || fail "first sighting ⇒ PENDING"
[ "$(_classify_finish_stall idle 0 1 0 pending "$((NOW-1))"   "$NOW" "$GRACE")" = "PENDING" ] \
  || fail "idle counts (unlike wedge) and within grace ⇒ PENDING"
ok

[ "$(_classify_finish_stall done 0 1 0 pending  "$PAST" "$NOW" "$GRACE")" = "FIRST_STALL" ] \
  || fail "past grace + no prior re-task ⇒ FIRST_STALL"
[ "$(_classify_finish_stall done 0 1 0 ""       "$PAST" "$NOW" "$GRACE")" = "FIRST_STALL" ] \
  || fail "past grace + empty state (defensive) ⇒ FIRST_STALL"
[ "$(_classify_finish_stall done 0 1 0 retasked "$PAST" "$NOW" "$GRACE")" = "SECOND_STALL" ] \
  || fail "past grace + already retasked once ⇒ SECOND_STALL"
[ "$(_classify_finish_stall done 0 1 0 escalated "$PAST" "$NOW" "$GRACE")" = "ESCALATED" ] \
  || fail "past grace + already escalated ⇒ stays ESCALATED"
ok

# a non-numeric age comparison never crashes (garbage state falls to FIRST_STALL, the safe default)
[ "$(_classify_finish_stall done 0 1 0 junk "$PAST" "$NOW" "$GRACE")" = "FIRST_STALL" ] \
  || fail "garbage state should read as a first crossing, not crash"
ok

# ── the real git probes ─────────────────────────────────────────────────────────────────────────
mkgit() {
  local d="$1"; mkdir -p "$d"; git -C "$d" init -q
  git -C "$d" checkout -q -b main 2>/dev/null || git -C "$d" checkout -q main
  git -C "$d" config user.email t@t.test; git -C "$d" config user.name herd-test
  printf 'base\n' > "$d/base.txt"; git -C "$d" add -A; git -C "$d" commit -qm base
}

WT_NEVERPUSHED="$T/wt-neverpushed"; mkgit "$WT_NEVERPUSHED"
git -C "$WT_NEVERPUSHED" checkout -q -b feat
printf 'w\n' > "$WT_NEVERPUSHED/w.txt"; git -C "$WT_NEVERPUSHED" add -A; git -C "$WT_NEVERPUSHED" commit -qm w
[ "$(_finish_stall_commits_ahead "$WT_NEVERPUSHED" feat)" = "1" ] \
  || fail "never-pushed branch: falls back to ahead-of-base, should read 1"

# a bare remote so we can prove the origin/<branch>..HEAD measurement (not ahead-of-base)
BARE="$T/bare.git"; git init -q --bare "$BARE"
WT_PUSHED="$T/wt-pushed"; mkgit "$WT_PUSHED"
git -C "$WT_PUSHED" remote add origin "$BARE"
git -C "$WT_PUSHED" checkout -q -b feat2
printf 'w1\n' > "$WT_PUSHED/w1.txt"; git -C "$WT_PUSHED" add -A; git -C "$WT_PUSHED" commit -qm w1
git -C "$WT_PUSHED" push -q origin feat2
[ "$(_finish_stall_commits_ahead "$WT_PUSHED" feat2)" = "0" ] \
  || fail "fully pushed branch should read 0 ahead of origin"
printf 'w2\n' > "$WT_PUSHED/w2.txt"; git -C "$WT_PUSHED" add -A; git -C "$WT_PUSHED" commit -qm w2
[ "$(_finish_stall_commits_ahead "$WT_PUSHED" feat2)" = "1" ] \
  || fail "one unpushed commit past a pushed base should read 1 (ahead of ORIGIN, not base)"
ok

[ "$(_finish_stall_commits_ahead "$T" nosuchbranch)" = "0" ] || fail "a non-repo path should read 0"
ok

# ── the shared-pool clock, direct accessor exercise ────────────────────────────────────────────
[ -z "$(_finish_stall_record clockslug)" ] || fail "an unseen slug must have no record"
rec="$(_finish_stall_mark clockslug "$NOW")"
[ "$rec" = "$(printf '%s\tpending' "$NOW")" ] || fail "first mark should anchor at NOW/pending, got: $rec"
rec2="$(_finish_stall_mark clockslug 999)"
[ "$rec2" = "$rec" ] || fail "a second mark must NOT move the anchor (get-or-create), got: $rec2"
_finish_stall_state clockslug retasked
[ "$(_finish_stall_record clockslug)" = "$(printf '%s\tretasked' "$NOW")" ] \
  || fail "set-state must preserve the anchor while flipping the state word"
_finish_stall_reset clockslug 555 escalated
[ "$(_finish_stall_record clockslug)" = "$(printf '555\tescalated')" ] \
  || fail "reset must overwrite BOTH the anchor and the state"
_finish_stall_clear clockslug
[ -z "$(_finish_stall_record clockslug)" ] || fail "clear must drop the record entirely"
ok

# durable across a fresh accessor call (simulates a second seat / a later tick reading the same pool)
_finish_stall_mark seatslug "$NOW" >/dev/null
[ "$(_finish_stall_record seatslug)" = "$(printf '%s\tpending' "$NOW")" ] \
  || fail "a fresh read must see the SAME anchor another call just wrote (shared pool, not seat memory)"
ok

# ── _finish_stall_note_escape (PR #502 review fix) ──────────────────────────────────────────────
# Called from a tick branch where the signature does not hold THIS tick (working / limit-parked) but
# the slug has not necessarily truly escaped. MUST preserve 'retasked'/'escalated' (the record has to
# survive the very working period a delivered re-task itself causes), and MUST clear an un-actioned
# 'pending' anchor (or nothing) so a self-resuming builder serves a fresh grace window.
FINISH_STALL_MIN=30
_finish_stall_mark note-pending "$NOW" >/dev/null
_finish_stall_note_escape note-pending
[ -z "$(_finish_stall_record note-pending)" ] || fail "note-escape must clear an un-actioned pending record"

_finish_stall_reset note-retasked "$NOW" retasked
_finish_stall_note_escape note-retasked
[ "$(_finish_stall_record note-retasked)" = "$(printf '%s\tretasked' "$NOW")" ] \
  || fail "note-escape must PRESERVE a retasked record — this is the exact PR #502 BLOCK"

_finish_stall_reset note-escalated "$NOW" escalated
_finish_stall_note_escape note-escalated
[ "$(_finish_stall_record note-escalated)" = "$(printf '%s\tescalated' "$NOW")" ] \
  || fail "note-escape must PRESERVE an escalated record"

_finish_stall_note_escape note-absent   # never seen — must not create anything or crash
[ -z "$(_finish_stall_record note-absent)" ] || fail "note-escape on an unseen slug must stay unseen"

( unset FINISH_STALL_MIN
  _finish_stall_reset note-off "$NOW" retasked
  _finish_stall_note_escape note-off
)
[ "$(_finish_stall_record note-off)" = "$(printf '%s\tretasked' "$NOW")" ] \
  || fail "note-escape must be a hard no-op (touch nothing) when the leg is off"
_finish_stall_clear note-off
ok

# ── console rows ─────────────────────────────────────────────────────────────────────────────────
row="$(NO_COLOR=1 _row_finish_stall "slugcell" "12m")"
case "$row" in *"needs-you"*"push + open the PR by hand"*) : ;; *) fail "the needs-you row must name the remedy, got: $row" ;; esac
case "$row" in *"12m"*) : ;; *) fail "the row must carry its age, got: $row" ;; esac
case "$row" in *"awaiting task"*) fail "must NEVER read as an awaiting-task spare" ;; esac
case "$row" in *"✅"*) fail "must NEVER render as a success" ;; esac
printf '%s' "$row" | grep -qw 'idle' && fail "the row leaked the banned 'idle' word: $row"
ok

retasked_row="$(NO_COLOR=1 _row_finish_stall "slugcell" "1m" retasked)"
case "$retasked_row" in *"re-task sent"*) : ;; *) fail "the retasked row must say the nudge was sent, got: $retasked_row" ;; esac
case "$retasked_row" in *"needs-you"*) fail "a retasked row must not also demand human action" ;; esac
ok

# ── end-to-end reconciliation ───────────────────────────────────────────────────────────────────
# Stub the driver seams so nothing touches a real pane.
SENT="$T/sent.log"; : > "$SENT"
PANE_ID="pane-1"; WAKE_OK=1
_find_builder_pane_id_any() { printf '%s' "$PANE_ID"; }
_agent_status()             { printf 'done'; }
herd_driver_send_text()     { printf '%s\n' "$2" >> "$SENT"; }
_wait_agent_working()       { [ "$WAKE_OK" = "1" ]; }

DIRTY_WT="$T/wt-dirty-e2e"; mkgit "$DIRTY_WT"
printf 'wip\n' > "$DIRTY_WT/wip.txt"   # uncommitted tracked-worthy change (untracked counts as dirty)

# off (the default): FINISH_STALL_MIN unset ⇒ OFF, hard no-op — no journal, no pane, no notification.
( unset FINISH_STALL_MIN
  v="$(HERD_NOW_EPOCH="$NOW" _reconcile_finish_stall off-e2e "$DIRTY_WT" done feat)"
  [ "$v" = "OFF" ] || fail "off: should verdict OFF, got $v"
)
[ -s "$SENT" ] && fail "off: must never touch a pane"
[ -s "$HERDR_NOTIFY_LOG" ] && fail "off: must never notify"
[ -z "$(_finish_stall_record off-e2e)" ] || fail "off: must never write a record"
ok

export FINISH_STALL_MIN=30
GRACE="$(_finish_stall_grace_secs)"

# tick 1: first sighting ⇒ PENDING, no side effects yet
v="$(HERD_NOW_EPOCH="$NOW" _reconcile_finish_stall e2e-slug "$DIRTY_WT" done feat)"
[ "$v" = "PENDING" ] || fail "tick1: first sighting should be PENDING, got $v"
[ -s "$SENT" ] && fail "tick1: PENDING must never touch a pane"
rec="$(_finish_stall_record e2e-slug)"
[ "$rec" = "$(printf '%s\tpending' "$NOW")" ] || fail "tick1: should anchor at NOW/pending, got: $rec"
ok

# tick 2: still within grace ⇒ PENDING, anchor unmoved
v="$(HERD_NOW_EPOCH="$((NOW + GRACE - 1))" _reconcile_finish_stall e2e-slug "$DIRTY_WT" done feat)"
[ "$v" = "PENDING" ] || fail "tick2: still within grace should be PENDING, got $v"
[ "$(_finish_stall_record e2e-slug)" = "$(printf '%s\tpending' "$NOW")" ] || fail "tick2: anchor must be preserved"
ok

# tick 3: past grace ⇒ FIRST_STALL, re-task delivered (WAKE_OK=1) ⇒ resets to 'retasked' at the new now
T3="$((NOW + GRACE + 1))"
v="$(HERD_NOW_EPOCH="$T3" _reconcile_finish_stall e2e-slug "$DIRTY_WT" done feat)"
[ "$v" = "FIRST_STALL" ] || fail "tick3: past grace should be FIRST_STALL, got $v"
[ "$(grep -c . "$SENT")" -ge 1 ] || fail "tick3: the driver seam must have been sent the nudge"
grep -q 'gh pr create' "$SENT" || fail "tick3: the nudge must tell the agent to open a NON-DRAFT PR"
grep -qi 'healthcheck' "$SENT" || fail "tick3: the nudge must tell the agent to run the healthcheck"
rec="$(_finish_stall_record e2e-slug)"
[ "$rec" = "$(printf '%s\tretasked' "$T3")" ] || fail "tick3: a successful wake must RESET the clock to (now, retasked), got: $rec"
grep -q '🔁' "$HERDR_NOTIFY_LOG" || fail "tick3: a delivered re-task must notify calmly"
grep -q '⚠️' "$HERDR_NOTIFY_LOG" && fail "tick3: a delivered re-task must NOT also shout needs-you"
grep -q finish_stall_wake "$JOURNAL_FILE" || fail "tick3: the wake must be journaled"
ok

# tick 3b: the nudge just delivered flips the agent to 'working' — the REAL tick loop routes a
# working, PR-less builder to the working branch, which calls _finish_stall_note_escape, NEVER
# _reconcile_finish_stall (PR #502 review: the previous unconditional clear() there wiped the
# 'retasked' record the instant the nudge landed, so SECOND_STALL could never be reached and the
# watchdog re-nudged forever instead of escalating). Simulate that exact branch here.
_finish_stall_note_escape e2e-slug
rec="$(_finish_stall_record e2e-slug)"
[ "$rec" = "$(printf '%s\tretasked' "$T3")" ] \
  || fail "tick3b: the working-branch escape must PRESERVE the retasked record, got: $rec"
ok

# tick 4: right after the reset, still within the SECOND grace window ⇒ PENDING again (quiet)
: > "$HERDR_NOTIFY_LOG"; : > "$SENT"
v="$(HERD_NOW_EPOCH="$((T3 + 5))" _reconcile_finish_stall e2e-slug "$DIRTY_WT" done feat)"
[ "$v" = "PENDING" ] || fail "tick4: right after the reset should be PENDING (quiet), got $v"
[ -s "$SENT" ] && fail "tick4: must not re-send during the second grace window"
ok

# tick 4b: the agent dips back to 'working' again for a moment mid-window (still no PR) — the escape
# call must keep preserving 'retasked' through EVERY such dip, not just the first.
_finish_stall_note_escape e2e-slug
[ "$(_finish_stall_record e2e-slug)" = "$(printf '%s\tretasked' "$T3")" ] \
  || fail "tick4b: a second working dip must still preserve the retasked record"
ok

# tick 5: a SECOND full grace window elapses without escaping ⇒ escalate
T5="$((T3 + GRACE + 1))"
v="$(HERD_NOW_EPOCH="$T5" _reconcile_finish_stall e2e-slug "$DIRTY_WT" done feat)"
[ "$v" = "SECOND_STALL" ] || fail "tick5: a second stall past threshold should be SECOND_STALL, got $v"
[ -s "$SENT" ] && fail "tick5: escalation must NOT deliver a second nudge"
rec="$(_finish_stall_record e2e-slug)"
case "$rec" in *escalated) : ;; *) fail "tick5: state should flip to escalated, got: $rec" ;; esac
grep -q '⚠️' "$HERDR_NOTIFY_LOG" || fail "tick5: escalation must fire the needs-you notification"
grep -q finish_stall_escalated "$JOURNAL_FILE" || fail "tick5: escalation must journal finish_stall_escalated"
ok

# tick 6: escalated is terminal — it keeps rendering, nothing new fires
: > "$HERDR_NOTIFY_LOG"
BEFORE_LINES="$(wc -l < "$JOURNAL_FILE")"
v="$(HERD_NOW_EPOCH="$((T5 + 60))" _reconcile_finish_stall e2e-slug "$DIRTY_WT" done feat)"
[ "$v" = "ESCALATED" ] || fail "tick6: should stay ESCALATED, got $v"
[ -s "$HERDR_NOTIFY_LOG" ] && fail "tick6: an already-escalated slug must not re-notify"
AFTER_LINES="$(wc -l < "$JOURNAL_FILE")"
[ "$BEFORE_LINES" = "$AFTER_LINES" ] || fail "tick6: an already-escalated slug must not journal again"
ok

# an escape (the tree goes back clean + PR-less, or work disappears) clears the record
git -C "$DIRTY_WT" add -A; git -C "$DIRTY_WT" commit -qm wip -q 2>/dev/null || true
rm -f "$DIRTY_WT/wip.txt"
CLEAN_WT="$T/wt-clean-escape"; mkgit "$CLEAN_WT"
v="$(HERD_NOW_EPOCH="$((T5 + 120))" _reconcile_finish_stall e2e-slug "$CLEAN_WT" done feat)"
[ "$v" = "NOT_STALLED" ] || fail "escape: a clean, nothing-ahead tree should be NOT_STALLED, got $v"
[ -z "$(_finish_stall_record e2e-slug)" ] || fail "escape: NOT_STALLED must clear the record"
ok

# a wake that never lands escalates on the VERY FIRST crossing (no second chance)
: > "$SENT"; : > "$HERDR_NOTIFY_LOG"; WAKE_OK=0
NOWAKE_WT="$T/wt-nowake"; mkgit "$NOWAKE_WT"; printf 'x\n' > "$NOWAKE_WT/x.txt"
v="$(HERD_NOW_EPOCH="$NOW" _reconcile_finish_stall nowake-slug "$NOWAKE_WT" done feat)"
[ "$v" = "PENDING" ] || fail "nowake: first sighting should be PENDING, got $v"
v="$(HERD_NOW_EPOCH="$((NOW + GRACE + 1))" _reconcile_finish_stall nowake-slug "$NOWAKE_WT" done feat)"
[ "$v" = "FIRST_STALL" ] || fail "nowake: past grace should be FIRST_STALL, got $v"
rec="$(_finish_stall_record nowake-slug)"
case "$rec" in *escalated) : ;; *) fail "nowake: an undelivered nudge must escalate immediately, got: $rec" ;; esac
grep -q '⚠️' "$HERDR_NOTIFY_LOG" || fail "nowake: an undelivered nudge must fire the needs-you notification"
grep -q finish_stall_escalated "$JOURNAL_FILE" || fail "nowake: must journal finish_stall_escalated"
WAKE_OK=1
ok

# no agent pane at all ⇒ still escalates (never crashes, never silently drops the slug)
: > "$SENT"; : > "$HERDR_NOTIFY_LOG"; PANE_ID=""
NOPANE_WT="$T/wt-nopane"; mkgit "$NOPANE_WT"; printf 'x\n' > "$NOPANE_WT/x.txt"
v="$(HERD_NOW_EPOCH="$NOW" _reconcile_finish_stall nopane-slug "$NOPANE_WT" done feat)"
v="$(HERD_NOW_EPOCH="$((NOW + GRACE + 1))" _reconcile_finish_stall nopane-slug "$NOPANE_WT" done feat)"
[ "$v" = "FIRST_STALL" ] || fail "nopane: past grace should be FIRST_STALL, got $v"
[ -s "$SENT" ] && fail "nopane: must never send when there is no pane"
case "$(_finish_stall_record nopane-slug)" in *escalated) : ;; *) fail "nopane: must escalate when no pane exists" ;; esac
PANE_ID="pane-1"
ok

echo "ALL PASS ($pass checks)"
