#!/usr/bin/env bash
# test-wedged-builder.sh — hermetic test for the watcher's WEDGED-builder classification (HERD-278):
# a builder whose agent reads 'done' while its branch has NO open PR and its tree carries nothing
# pushable is a WEDGE, not a success and not a spare (three live incidents 2026-07-09: the console
# said "awaiting task · assign or retire" and a human woke each one by hand).
#
# It sources agent-watch.sh's pure helpers via the AGENT_WATCH_LIB guard (loads the helpers WITHOUT
# entering the live watch loop), points every ledger path at a temp dir, drives the clock with the
# HERD_NOW_EPOCH seam, and asserts:
#   • the pure classifier over every synthetic state (done+PR ⇒ ✅ / NOT_WEDGED; done+no-PR+no-diff
#     past grace ⇒ WEDGED; done+no-PR+dirty ⇒ WEDGED; within grace ⇒ PENDING; working/idle ⇒ never)
#   • WEDGE_GRACE_MIN honored (minutes → seconds), 10m default, garbage falls back
#   • reconciliation: first-seen anchor, one ⚠️ notification per record, ledger clears on escape
#   • the real git probes (commits-ahead / dirty) on real temp worktrees
#   • the console rows: red 'finished without PR · wake or inspect', calm auto-wake variant, and no
#     leak of the banned 'idle' word
#   • WEDGE_AUTOWAKE ships DORMANT: off ⇒ hard no-op (no pane touched, no journal event, no ledger
#     write); on ⇒ ONE nudge through the driver send-text seam, at most once per record
#   • building (a 'working' agent) is untouched: _classify_builder still says BUILD/BUILDING
# Run:  bash tests/test-wedged-builder.sh
# No `set -e`: some checks deliberately expect a non-zero predicate return; we assert explicitly.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../scripts/herd/agent-watch.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ pass=$((pass+1)); }

[ -f "$WATCH" ] || fail "agent-watch.sh not found at $WATCH"
command -v git >/dev/null 2>&1 || fail "git required to run this test"

# ── stub `herdr` on PATH so a fired notification is captured, never a real popup ──────────────────
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
for fn in _classify_wedged_builder _reconcile_wedged_builder _wedge_grace_secs _row_wedged \
          _wedge_autowake_on _maybe_autowake_wedged_builder _wedge_commits_ahead _wedge_dirty; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined"
done

# Redirect every stateful path at the temp dir (plain globals; safe to reassign post-source).
WEDGE_STATE="$T/.agent-watch-wedged"
export HERDR_NOTIFY_LOG="$T/notify.log"; : > "$HERDR_NOTIFY_LOG"
export JOURNAL_FILE="$T/journal.log"

NOW=1000000000
GRACE="$(_wedge_grace_secs)"
[ "$GRACE" = "600" ] || fail "default grace should be 10m (600s), got $GRACE"

# ── the pure classifier ──────────────────────────────────────────────────────────────────────────
# args: agent-status has-pr commits-ahead dirty first-seen now grace
PAST="$((NOW - GRACE - 1))"

# done + an open PR ⇒ the builder delivered. Never a wedge (this is the ✅ row).
[ "$(_classify_wedged_builder done 1 0 0 "$PAST" "$NOW" "$GRACE")" = "NOT_WEDGED" ] \
  || fail "done + open PR ⇒ NOT_WEDGED (✅, never a wedge)"
[ "$(_classify_wedged_builder done 1 0 1 "$PAST" "$NOW" "$GRACE")" = "NOT_WEDGED" ] \
  || fail "done + open PR + dirty ⇒ NOT_WEDGED (the PR is the proof of delivery)"
ok

# done + no PR + no commits + clean, PAST grace ⇒ WEDGED (it never started delivering)
[ "$(_classify_wedged_builder done 0 0 0 "$PAST" "$NOW" "$GRACE")" = "WEDGED" ] \
  || fail "done + no PR + no diff past grace ⇒ WEDGED"
# done + no PR + dirty, PAST grace ⇒ WEDGED (it stopped halfway), with or without commits
[ "$(_classify_wedged_builder done 0 0 1 "$PAST" "$NOW" "$GRACE")" = "WEDGED" ] \
  || fail "done + no PR + dirty past grace ⇒ WEDGED"
[ "$(_classify_wedged_builder done 0 3 1 "$PAST" "$NOW" "$GRACE")" = "WEDGED" ] \
  || fail "done + no PR + commits + dirty past grace ⇒ WEDGED (uncommitted work is stranded)"
ok

# done + no PR + commits ahead + CLEAN ⇒ not a wedge: a pushable commit series, PR in flight /
# PUSH_GATE-held. This is the no-false-red clause.
[ "$(_classify_wedged_builder done 0 2 0 "$PAST" "$NOW" "$GRACE")" = "NOT_WEDGED" ] \
  || fail "done + no PR + committed + clean ⇒ NOT_WEDGED (its PR is a push away)"
ok

# WITHIN grace ⇒ PENDING, never a flag (a builder mid-`gh pr create` shows the exact signature)
[ "$(_classify_wedged_builder done 0 0 0 ""              "$NOW" "$GRACE")" = "PENDING" ] \
  || fail "first sighting ⇒ PENDING"
[ "$(_classify_wedged_builder done 0 0 0 "$((NOW-1))"    "$NOW" "$GRACE")" = "PENDING" ] \
  || fail "within grace ⇒ PENDING"
[ "$(_classify_wedged_builder done 0 0 1 "$((NOW-GRACE+1))" "$NOW" "$GRACE")" = "PENDING" ] \
  || fail "one second inside grace ⇒ PENDING"
ok

# every non-'done' status escapes: working is building, idle is a genuine spare, empty is the dead path
[ "$(_classify_wedged_builder working 0 0 0 "$PAST" "$NOW" "$GRACE")" = "NOT_WEDGED" ] \
  || fail "working ⇒ NOT_WEDGED (building)"
[ "$(_classify_wedged_builder idle    0 0 0 "$PAST" "$NOW" "$GRACE")" = "NOT_WEDGED" ] \
  || fail "idle ⇒ NOT_WEDGED (a genuine unassigned spare)"
[ "$(_classify_wedged_builder ""      0 0 0 "$PAST" "$NOW" "$GRACE")" = "NOT_WEDGED" ] \
  || fail "no agent record ⇒ NOT_WEDGED (that is the dead reconciliation's business)"
ok

# a non-numeric commit probe reads as 0 (never crashes the tick loop's arithmetic)
[ "$(_classify_wedged_builder done 0 xx 0 "$PAST" "$NOW" "$GRACE")" = "WEDGED" ] \
  || fail "garbage commit count should read as 0, not crash"
ok

# ── building stays building: the existing classifier is untouched ─────────────────────────────────
# (edit-age changes commits agent-status transcript quiet quiet-elapsed)
[ "$(_classify_builder 5 1 0 working no 600 5)" = "BUILD_UNCOMMITTED" ] \
  || fail "a working agent with fresh edits still classifies BUILD_UNCOMMITTED (🔨)"
ok

# ── WEDGE_GRACE_MIN override is honored (minutes → seconds) ───────────────────────────────────────
[ "$(WEDGE_GRACE_MIN=5  _wedge_grace_secs)" = "300" ] || fail "WEDGE_GRACE_MIN=5 should be 300s"
[ "$(WEDGE_GRACE_MIN=0  _wedge_grace_secs)" = "0"   ] || fail "WEDGE_GRACE_MIN=0 should be 0s (honored)"
[ "$(WEDGE_GRACE_MIN=   _wedge_grace_secs)" = "600" ] || fail "unset WEDGE_GRACE_MIN should default to 600s"
[ "$(WEDGE_GRACE_MIN=xx _wedge_grace_secs)" = "600" ] || fail "non-numeric WEDGE_GRACE_MIN should default to 600s"
ok

# ── the git probes, against real worktrees ────────────────────────────────────────────────────────
mkgit() {  # mkgit <dir> — a repo on `main` with one base commit
  local d="$1"; mkdir -p "$d"; git -C "$d" init -q
  git -C "$d" checkout -q -b main 2>/dev/null || git -C "$d" checkout -q main
  git -C "$d" config user.email t@t.test; git -C "$d" config user.name herd-test
  printf 'base\n' > "$d/base.txt"; git -C "$d" add -A; git -C "$d" commit -qm base
}
DEFAULT_BRANCH=main

WT_CLEAN="$T/wt-clean"; mkgit "$WT_CLEAN"
[ "$(_wedge_commits_ahead "$WT_CLEAN")" = "0" ] || fail "a base-only tree has 0 commits ahead"
[ "$(_wedge_dirty "$WT_CLEAN")" = "0" ]         || fail "a committed tree is not dirty"

WT_DIRTY="$T/wt-dirty"; mkgit "$WT_DIRTY"
printf 'wip\n' > "$WT_DIRTY/wip.txt"
[ "$(_wedge_dirty "$WT_DIRTY")" = "1" ] || fail "an untracked file makes the tree dirty"

WT_AHEAD="$T/wt-ahead"; mkgit "$WT_AHEAD"
git -C "$WT_AHEAD" checkout -q -b feat
printf 'work\n' > "$WT_AHEAD/work.txt"; git -C "$WT_AHEAD" add -A; git -C "$WT_AHEAD" commit -qm work
[ "$(_wedge_commits_ahead "$WT_AHEAD")" = "1" ] || fail "one commit ahead of main should read 1"
[ "$(_wedge_dirty "$WT_AHEAD")" = "0" ]         || fail "the committed-ahead tree is clean"

# a directory that is not a git repo at all: probes fail SOFT (0 / 0), never abort
[ "$(_wedge_commits_ahead "$T")" = "0" ] || fail "a non-repo path should read 0 commits ahead"
ok

# ── reconciliation: an empty, done builder ages in through PENDING → WEDGED ───────────────────────
: > "$WEDGE_STATE"
v="$(HERD_NOW_EPOCH="$NOW" _reconcile_wedged_builder wedgy "$WT_CLEAN" done)"
[ "$v" = "PENDING" ] || fail "first sighting should be PENDING, got $v"
[ "$(wedge_first_seen wedgy)" = "$NOW" ] || fail "PENDING should record the first-seen anchor"
! wedge_notified wedgy || fail "PENDING must not be marked notified"
[ -s "$HERDR_NOTIFY_LOG" ] && fail "PENDING must NOT fire a notification"
ok

v="$(HERD_NOW_EPOCH="$((NOW + GRACE - 1))" _reconcile_wedged_builder wedgy "$WT_CLEAN" done)"
[ "$v" = "PENDING" ] || fail "still within grace should stay PENDING, got $v"
[ "$(wedge_first_seen wedgy)" = "$NOW" ] || fail "the anchor must be preserved across ticks"
ok

v="$(HERD_NOW_EPOCH="$((NOW + GRACE + 1))" _reconcile_wedged_builder wedgy "$WT_CLEAN" done)"
[ "$v" = "WEDGED" ] || fail "past grace should be WEDGED, got $v"
wedge_notified wedgy || fail "WEDGED should flip the record to notified"
[ "$(wedge_first_seen wedgy)" = "$NOW" ] || fail "WEDGED must preserve the original first-seen anchor"
grep -q "wedgy" "$HERDR_NOTIFY_LOG" || fail "WEDGED should fire one ⚠️ notification"
ok

# the notification is deduped: a second WEDGED tick does not fire again
: > "$HERDR_NOTIFY_LOG"
v="$(HERD_NOW_EPOCH="$((NOW + GRACE + 60))" _reconcile_wedged_builder wedgy "$WT_CLEAN" done)"
[ "$v" = "WEDGED" ] || fail "still wedged should remain WEDGED, got $v"
[ -s "$HERDR_NOTIFY_LOG" ] && fail "the WEDGED notification must fire at most once per record"
ok

# an escape (the agent goes back to working) clears the record — the next wedge serves the full grace
v="$(HERD_NOW_EPOCH="$((NOW + GRACE + 90))" _reconcile_wedged_builder wedgy "$WT_CLEAN" working)"
[ "$v" = "NOT_WEDGED" ] || fail "a working agent should be NOT_WEDGED, got $v"
[ -z "$(wedge_first_seen wedgy)" ] || fail "NOT_WEDGED should clear the wedge record"
ok

# a DIRTY done builder wedges the same way (half-finished work, stranded)
: > "$WEDGE_STATE"
v="$(HERD_NOW_EPOCH="$NOW" _reconcile_wedged_builder dirty-slug "$WT_DIRTY" done)"
[ "$v" = "PENDING" ] || fail "dirty first sighting should be PENDING, got $v"
v="$(HERD_NOW_EPOCH="$((NOW + GRACE + 1))" _reconcile_wedged_builder dirty-slug "$WT_DIRTY" done)"
[ "$v" = "WEDGED" ] || fail "dirty past grace should be WEDGED, got $v"
ok

# a done builder with a clean, committed-ahead tree NEVER wedges and never gets a record
: > "$WEDGE_STATE"
v="$(HERD_NOW_EPOCH="$((NOW + GRACE + 1))" _reconcile_wedged_builder ahead-slug "$WT_AHEAD" done)"
[ "$v" = "NOT_WEDGED" ] || fail "committed + clean should be NOT_WEDGED, got $v"
[ -z "$(wedge_first_seen ahead-slug)" ] || fail "a NOT_WEDGED builder must never get a wedge record"
ok

# an idle spare never wedges and never gets a record
v="$(HERD_NOW_EPOCH="$((NOW + GRACE + 1))" _reconcile_wedged_builder spare "$WT_CLEAN" idle)"
[ "$v" = "NOT_WEDGED" ] || fail "an idle spare should be NOT_WEDGED, got $v"
[ -z "$(wedge_first_seen spare)" ] || fail "an idle spare must never get a wedge record"
ok

# ── the console rows ──────────────────────────────────────────────────────────────────────────────
row="$(NO_COLOR=1 _row_wedged "slugcell" "12m")"
case "$row" in
  *"finished without PR · wake or inspect"*) : ;;
  *) fail "the wedged row must name the state + remedy, got: $row" ;;
esac
case "$row" in *"12m"*) : ;; *) fail "the wedged row must carry its age, got: $row" ;; esac
case "$row" in *"awaiting task"*) fail "a wedge must NEVER read as an awaiting-task spare" ;; esac
case "$row" in *"✅"*) fail "a wedge must NEVER render as a success" ;; esac
printf '%s' "$row" | grep -qw 'idle' && fail "the wedged row leaked the banned 'idle' word: $row"
ok

woke="$(NO_COLOR=1 _row_wedged "slugcell" "12m" woken)"
case "$woke" in
  *"finished without PR · auto-wake sent"*) : ;;
  *) fail "the woken row must say the nudge was sent, got: $woke" ;;
esac
case "$woke" in *"wake or inspect"*) fail "a woken row must not still ask the human to wake it" ;; esac
ok

# ── WEDGE_AUTOWAKE ships DORMANT ──────────────────────────────────────────────────────────────────
( unset WEDGE_AUTOWAKE; _wedge_autowake_on ) && fail "unset WEDGE_AUTOWAKE must be OFF"
WEDGE_AUTOWAKE=off  _wedge_autowake_on && fail "off must be OFF"
WEDGE_AUTOWAKE=junk _wedge_autowake_on && fail "garbage must be OFF"
WEDGE_AUTOWAKE=on   _wedge_autowake_on || fail "on must be ON"
WEDGE_AUTOWAKE=true _wedge_autowake_on || fail "true must be ON"
WEDGE_AUTOWAKE=1    _wedge_autowake_on || fail "1 must be ON"
ok

# Stub the three wake-path seams so nothing touches a real pane. Each records its calls.
SENT="$T/sent.log"; : > "$SENT"
PANE_ID="pane-1"; WAKE_OK=1
_find_builder_pane_id_any() { printf '%s' "$PANE_ID"; }
_agent_status()             { printf 'done'; }
herd_driver_send_text()     { printf '%s\n' "$2" >> "$SENT"; }
_wait_agent_working()       { [ "$WAKE_OK" = "1" ]; }

# OFF ⇒ hard no-op: no pane touched, nothing sent, no ledger write.
: > "$WEDGE_STATE"; : > "$SENT"; : > "$HERDR_NOTIFY_LOG"
v="$(WEDGE_AUTOWAKE=off _maybe_autowake_wedged_builder off-slug)"
[ "$v" = "OFF" ] || fail "WEDGE_AUTOWAKE=off should verdict OFF, got $v"
[ -s "$SENT" ] && fail "the OFF path must never send a nudge"
[ -z "$(wedge_state_of off-slug)" ] || fail "the OFF path must never write the ledger"
ok

# DRYRUN ⇒ intent only, no send.
v="$(DRYRUN=1 WEDGE_AUTOWAKE=on _maybe_autowake_wedged_builder dry-slug 2>/dev/null)"
[ "$v" = "DRYRUN" ] || fail "DRYRUN should verdict DRYRUN, got $v"
[ -s "$SENT" ] && fail "DRYRUN must never send a nudge"
ok

# ON + a live pane + the agent flips to working ⇒ exactly ONE nudge, budget spent.
: > "$SENT"
record_wedge_seen wake-slug "$NOW"
v="$(WEDGE_AUTOWAKE=on HERD_NOW_EPOCH="$NOW" _maybe_autowake_wedged_builder wake-slug)"
[ "$v" = "WOKE" ] || fail "a delivered + accepted nudge should verdict WOKE, got $v"
[ "$(grep -c . "$SENT")" -ge 1 ] || fail "ON must send the nudge through the driver send-text seam"
grep -q 'gh pr create' "$SENT" || fail "the nudge must tell the agent to open its PR"
wedge_woken wake-slug || fail "a WOKE nudge must flip the record to woken"
[ "$(wedge_first_seen wake-slug)" = "$NOW" ] || fail "the woken flip must preserve the first-seen anchor"
ok

# at most once per record: a second call on a woken slug sends nothing
: > "$SENT"
v="$(WEDGE_AUTOWAKE=on _maybe_autowake_wedged_builder wake-slug)"
[ "$v" = "ALREADY" ] || fail "a second wake on the same record should verdict ALREADY, got $v"
[ -s "$SENT" ] && fail "the at-most-once rail must not re-send the nudge"
ok

# a nudge that does NOT wake the agent leaves the record un-woken (the red row returns next tick)
: > "$SENT"; WAKE_OK=0
record_wedge_seen nowake-slug "$NOW"
v="$(WEDGE_AUTOWAKE=on _maybe_autowake_wedged_builder nowake-slug)"
[ "$v" = "NO_WAKE" ] || fail "an undelivered wake should verdict NO_WAKE, got $v"
wedge_woken nowake-slug && fail "a failed wake must NOT spend the record's woken flag"
ok

# no agent pane ⇒ NO_PANE, nothing sent, nothing woken
: > "$SENT"; PANE_ID=""; WAKE_OK=1
v="$(WEDGE_AUTOWAKE=on _maybe_autowake_wedged_builder nopane-slug)"
[ "$v" = "NO_PANE" ] || fail "a missing pane should verdict NO_PANE, got $v"
[ -s "$SENT" ] && fail "NO_PANE must never send a nudge"
ok

# ── the lever both ways, end-to-end through the reconciliation ────────────────────────────────────
# OFF (the default): a WEDGED crossing surfaces the ⚠️ notification and sends nothing.
: > "$WEDGE_STATE"; : > "$SENT"; : > "$HERDR_NOTIFY_LOG"; PANE_ID="pane-1"; WAKE_OK=1
v="$(WEDGE_AUTOWAKE=off HERD_NOW_EPOCH="$((NOW - GRACE - 1))" _reconcile_wedged_builder offw "$WT_CLEAN" done)"
[ "$v" = "PENDING" ] || fail "off: first sighting should be PENDING, got $v"
v="$(WEDGE_AUTOWAKE=off HERD_NOW_EPOCH="$NOW" _reconcile_wedged_builder offw "$WT_CLEAN" done)"
[ "$v" = "WEDGED" ] || fail "off: past grace should be WEDGED, got $v"
[ -s "$SENT" ] && fail "off: the dormant lever must never touch a pane"
grep -q '⚠️' "$HERDR_NOTIFY_LOG" || fail "off: the WEDGED crossing must fire the ⚠️ notification"
ok

# ON: the same crossing delivers ONE nudge, flips the record to woken, and fires the 🔁 notification
# INSTEAD of the ⚠️ — an operator whose builder is working again must not be told to go wake it.
: > "$WEDGE_STATE"; : > "$SENT"; : > "$HERDR_NOTIFY_LOG"
v="$(WEDGE_AUTOWAKE=on HERD_NOW_EPOCH="$((NOW - GRACE - 1))" _reconcile_wedged_builder onw "$WT_CLEAN" done)"
[ "$v" = "PENDING" ] || fail "on: first sighting should be PENDING, got $v"
[ -s "$SENT" ] && fail "on: the grace window gates the nudge — a PENDING builder is never woken"
v="$(WEDGE_AUTOWAKE=on HERD_NOW_EPOCH="$NOW" _reconcile_wedged_builder onw "$WT_CLEAN" done)"
[ "$v" = "WEDGED" ] || fail "on: past grace should be WEDGED, got $v"
grep -q 'gh pr create' "$SENT" || fail "on: the WEDGED crossing must deliver the nudge"
wedge_woken onw || fail "on: a landed nudge must flip the record to woken"
grep -q '🔁' "$HERDR_NOTIFY_LOG" || fail "on: a woken builder must fire the 🔁 notification"
grep -q '⚠️' "$HERDR_NOTIFY_LOG" && fail "on: a woken builder must NOT also shout 'wake or inspect it'"
ok

# ON but the nudge does not land: the ⚠️ still fires — a failed remedy never silences the red.
: > "$WEDGE_STATE"; : > "$SENT"; : > "$HERDR_NOTIFY_LOG"; WAKE_OK=0
v="$(WEDGE_AUTOWAKE=on HERD_NOW_EPOCH="$((NOW - GRACE - 1))" _reconcile_wedged_builder sadw "$WT_CLEAN" done)"
[ "$v" = "PENDING" ] || fail "on/no-wake: first sighting should be PENDING, got $v"
v="$(WEDGE_AUTOWAKE=on HERD_NOW_EPOCH="$NOW" _reconcile_wedged_builder sadw "$WT_CLEAN" done)"
[ "$v" = "WEDGED" ] || fail "on/no-wake: past grace should be WEDGED, got $v"
grep -q '⚠️' "$HERDR_NOTIFY_LOG" || fail "on/no-wake: a nudge that did not take must still surface ⚠️"
wedge_woken sadw && fail "on/no-wake: a failed nudge must not mark the record woken"
ok

echo "ALL PASS ($pass checks)"
