#!/usr/bin/env bash
# test-operator-inbox.sh — hermetic unit tests for the cross-seat OPERATOR INBOX (HERD-184): the
# OPERATOR_INBOX=on|off lever, the two feeds (PR comments + tracker comments), and the invariants the
# feature MUST hold:
#   • OFF (default) is byte-inert: _inbox_scan is a no-op (no ledger, no notify) and
#     build_operator_inbox leaves OPERATOR_INBOX_ROWS empty, so render() adds nothing.
#   • A cross-author comment SURFACES exactly once — it lands in the inbox ledger, fires ONE
#     notification, and a SECOND scan (same comment id still present) neither re-records nor re-notifies.
#   • The reader is fail-soft and self-excludes: a comment authored by THIS seat is never surfaced.
#
# Sources agent-watch.sh in lib mode (AGENT_WATCH_LIB=1 — helpers only, no polling loop, no console,
# no real network), pointing config discovery at a nonexistent file so herd-config.sh falls back to its
# generic defaults (OPERATOR_INBOX defaults off). The PR feed's single network call
# (_inbox_fetch_pr_comments) and the notification sink (herd_driver_notify) are overridden in-process;
# the TRACKER feed is exercised through the REAL subshell-source path against a fake backend file that
# implements the optional _backend_list_inbox_comments op.
# Run:  bash tests/test-operator-inbox.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../scripts/herd/agent-watch.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass(){ PASS=$((PASS+1)); }

[ -f "$WATCH" ] || fail "agent-watch.sh not found at $WATCH"
command -v python3 >/dev/null 2>&1 || fail "python3 required"

# ── Stub binaries on PATH so a stray call can never hit the real network ───────────────────────────
BIN="$T/bin"; mkdir -p "$BIN"
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
# If anything reaches the real gh, hand back an empty comment set / sentinel login (a leak is visible).
case "$*" in
  "api user -q .login") printf 'sentinel-gh-user\n'; exit 0 ;;
  *) printf '{"comments":[]}\n'; exit 0 ;;
esac
STUB
chmod +x "$BIN/gh"
for cmd in git herdr; do printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$cmd"; chmod +x "$BIN/$cmd"; done
export PATH="$BIN:$PATH"

# ── Source the watcher's helpers WITHOUT its live loop (lib mode), colors blanked (NO_COLOR) ────────
export AGENT_WATCH_LIB=1
export HERD_CONFIG_FILE="$T/no-such-config"
export WORKTREES_DIR="$T/trees"; mkdir -p "$WORKTREES_DIR"
export PROJECT_ROOT="$T/main"; mkdir -p "$PROJECT_ROOT/.herd"
export WORKSPACE_NAME="inboxtest"
export WATCHER_OWNER="me-operator"   # pins the seat identity → no gh lookup
export NO_COLOR=1                    # deterministic plain output for byte assertions
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"
for fn in _operator_inbox_enabled _inbox_extract_pr_comments _inbox_pr_numbers _inbox_seen \
          _inbox_mark_seen _inbox_record _inbox_scan build_operator_inbox; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined after sourcing"
done
pass

# ── 1. _operator_inbox_enabled: default OFF; on|true|1|yes|enable enable it; anything else is OFF ───
unset OPERATOR_INBOX
_operator_inbox_enabled && fail "must be OFF by default (unset)"; pass
for v in on ON true 1 yes enable enabled; do
  OPERATOR_INBOX="$v" _operator_inbox_enabled || fail "should be ON for '$v'"
done; pass
for v in off "" 0 no garbage; do
  OPERATOR_INBOX="$v" _operator_inbox_enabled && fail "should be OFF for '$v'"
done; pass

# ── 2. _inbox_pr_numbers: extracts open PR numbers from the tick's `gh pr list` JSON ───────────────
nums="$(printf '%s' '[{"number":11},{"number":12},{"number":13}]' | _inbox_pr_numbers | tr '\n' ',')"
[ "$nums" = "11,12,13," ] || fail "_inbox_pr_numbers wrong: [$nums]"; pass

# ── 3. _inbox_extract_pr_comments: keeps OTHER authors, drops MY own comments, emits id/login/snip ──
FIX='{"comments":[
 {"id":"c1","author":{"login":"teammate"},"body":"dont self-merge, main broke"},
 {"id":"c2","author":{"login":"me-operator"},"body":"my own reply — must be excluded"},
 {"id":"c3","author":{"login":"bot"},"body":"line one\nline two"}
]}'
out="$(printf '%s' "$FIX" | _inbox_extract_pr_comments "me-operator")"
printf '%s\n' "$out" | grep -q "^c1	teammate	dont self-merge, main broke$" || fail "c1 (teammate) must surface: [$out]"; pass
printf '%s\n' "$out" | grep -q "me-operator" && fail "my own comment (c2) must be excluded: [$out]"; pass
printf '%s\n' "$out" | grep -q "^c3	bot	line one line two$" || fail "c3 must surface whitespace-flattened: [$out]"; pass

# ── 4. OFF is byte-inert: _inbox_scan writes nothing; build leaves the section empty even with a ledger
OPERATOR_INBOX=off
NOTIFY_LOG="$T/notify.log"; : > "$NOTIFY_LOG"
herd_driver_notify() { printf '%s\t%s\n' "$1" "$2" >> "$NOTIFY_LOG"; }        # capture notifications
_inbox_fetch_pr_comments() { printf '%s' "$FIX"; }                            # would-be PR comments
rm -f "$INBOX_LEDGER" "$INBOX_SEEN_STATE"
_inbox_scan '[{"number":11}]'
[ ! -e "$INBOX_LEDGER" ]     || fail "OFF _inbox_scan must not write the ledger"; pass
[ ! -s "$NOTIFY_LOG" ]       || fail "OFF _inbox_scan must not notify"; pass
# Even a pre-existing ledger renders NOTHING when off (byte-identical console).
printf '%s\tpr\t#9\tstranger\tleftover\n' "$(date +%s)" > "$INBOX_LEDGER"
OPERATOR_INBOX_ROWS="dirty"; build_operator_inbox
[ -z "$OPERATOR_INBOX_ROWS" ] || fail "OFF build_operator_inbox must leave the section empty"; pass
rm -f "$INBOX_LEDGER" "$INBOX_SEEN_STATE"

# ── 5. ON, PR feed: a cross-author comment SURFACES once (ledger + notify), then DEDUPS on re-scan ──
OPERATOR_INBOX=on
: > "$NOTIFY_LOG"
_inbox_scan '[{"number":11}]'
[ -s "$INBOX_LEDGER" ] || fail "ON scan must record the surfaced comment"
grep -q "	pr	#11	teammate	dont self-merge, main broke$" "$INBOX_LEDGER" || fail "ledger row wrong: [$(cat "$INBOX_LEDGER")]"; pass
grep -q "me-operator" "$INBOX_LEDGER" && fail "my own comment must never be recorded"; pass
# One notification per NEW comment (c1 + c3 = 2), none for my own (c2).
_n="$(grep -c 'inbox · PR #11' "$NOTIFY_LOG" || true)"
[ "$_n" -eq 2 ] || fail "expected 2 inbox notifications (c1,c3), got $_n"; pass
# Re-scan: same comment ids are already seen → NO new ledger rows, NO new notifications.
before="$(wc -l < "$INBOX_LEDGER")"; : > "$NOTIFY_LOG"
_inbox_scan '[{"number":11}]'
after="$(wc -l < "$INBOX_LEDGER")"
[ "$before" = "$after" ] || fail "re-scan must not duplicate ledger rows ($before → $after)"; pass
[ ! -s "$NOTIFY_LOG" ]   || fail "re-scan must not re-notify an already-seen comment"; pass

# ── 6. build_operator_inbox ON renders the surfaced entry (newest-first, cyan 📬, @author) ──────────
OPERATOR_INBOX_ROWS=""; build_operator_inbox
printf '%s' "$OPERATOR_INBOX_ROWS" | grep -q '📬 #11 @teammate dont self-merge, main broke' \
  || fail "inbox section missing the surfaced PR comment: [$OPERATOR_INBOX_ROWS]"; pass

# ── 7. TRACKER feed via the REAL subshell-source path against a fake backend op ─────────────────────
# A backend that implements the optional _backend_list_inbox_comments op feeds the tracker half; a
# backend without it (file/github/jira) simply yields an empty tracker feed (proven by the no-op).
mkdir -p "$T/backends"
cat > "$T/backends/fake.sh" <<'BK'
#!/usr/bin/env bash
_backend_list_inbox_comments() {
  # "#<ref>\t<author>\t<comment-id>\t<snippet>" — a cross-operator reply on a claimed item.
  printf '#HERD-7\tother-op\tlin-abc\tplease rebase before we merge\n'
}
BK
rm -f "$INBOX_LEDGER" "$INBOX_SEEN_STATE"; : > "$NOTIFY_LOG"
_inbox_fetch_pr_comments() { printf '{"comments":[]}'; }   # isolate the tracker feed
SCRIBE_BACKEND=fake SCRIBE_BACKEND_DIR="$T/backends" _inbox_scan '[]'
grep -q "	tracker	#HERD-7	other-op	please rebase before we merge$" "$INBOX_LEDGER" \
  || fail "tracker comment must surface: [$(cat "$INBOX_LEDGER" 2>/dev/null)]"; pass
grep -q 'inbox · #HERD-7' "$NOTIFY_LOG" || fail "tracker comment must notify"; pass
# A backend WITHOUT the op → empty tracker feed, no error, no new rows.
rm -f "$INBOX_LEDGER" "$INBOX_SEEN_STATE"
SCRIBE_BACKEND=file SCRIBE_BACKEND_DIR="$HERE/../scripts/herd/backends" _inbox_scan '[]'
[ ! -s "$INBOX_LEDGER" ] || fail "a backend without the op must yield an empty tracker feed"; pass

echo "PASS ($PASS assertions) — tests/test-operator-inbox.sh"
