#!/usr/bin/env bash
# test-backend-file.sh — hermetic test of the file backend's _backend_item_state op.
# The existing ops (add/mark/list) are covered by integration with the scribe; this test
# focuses on the new 4th op which can be exercised without a git repo.
# Run:  bash tests/test-backend-file.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BACKEND="$HERE/../scripts/herd/backends/file.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
TAB="$(printf '\t')"
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass(){ PASS=$((PASS+1)); }

export BACKLOG_FILE="$T/BACKLOG.md"
export DEFAULT_BRANCH="origin/main"
export HERD_REMOTE="origin"
export HERD_BRANCH_NAME="main"

run_state() {
  ( . "$BACKEND"
    ITEM_STATE=""
    _backend_item_state "$1"
    printf 'ITEM_STATE=%s\n' "${ITEM_STATE:-}" )
}

# run_op — source the backend inside the temp git repo and run a queue/unqueue op, echoing its result
# contract. The planned-marker ops (HERD-52) commit the annotation to $BACKLOG_FILE; there is no
# remote, so their pull/push are fail-soft no-ops and only the local commit + file edit are exercised.
run_op() {
  ( cd "$T" && . "$BACKEND"
    _BACKEND_RESULT=""
    "$@"
    printf 'RESULT=%s\n' "${_BACKEND_RESULT:-}" )
}

# run_claim REF WHO — run the pre-spawn claim in the repo, echoing its result contract.
run_claim() {
  ( cd "$T" && . "$BACKEND"
    _CLAIM_RESULT=""; _CLAIM_OWNER=""
    _backend_claim_item "$1" "$2"
    printf 'CLAIM=%s OWNER=%s\n' "${_CLAIM_RESULT:-}" "${_CLAIM_OWNER:-}" )
}

# Write a fake BACKLOG.md with items in each emoji state.
cat > "$BACKLOG_FILE" <<'BACKLOG'
## Backlog

🔜 open-feature — a queued item
🚧 wip-feature — an in-progress item
✅ done-feature — a shipped item
BACKLOG

# A real (local-only) git repo so the planned-marker ops' commit path runs; no remote, so their
# pull/push fail soft. Committed once up front so the marker edits are the only new commits.
git -C "$T" init -q
git -C "$T" config user.email t@t.t
git -C "$T" config user.name t
git -C "$T" add BACKLOG.md
git -C "$T" commit -q -m "seed backlog"

# 1. Slug matching a 🔜 line → open.
out="$(run_state "repo#open-feature")"
echo "$out" | grep -q "ITEM_STATE=open" || fail "🔜 item should return open ($out)"
pass

# 2. Slug matching a 🚧 line → in-progress.
out="$(run_state "repo#wip-feature")"
echo "$out" | grep -q "ITEM_STATE=in-progress" || fail "🚧 item should return in-progress ($out)"
pass

# 3. Slug matching a ✅ line → closed.
out="$(run_state "repo#done-feature")"
echo "$out" | grep -q "ITEM_STATE=closed" || fail "✅ item should return closed ($out)"
pass

# 4. Unknown slug (not in file) → open (safe default).
out="$(run_state "repo#no-such-item")"
echo "$out" | grep -q "ITEM_STATE=open" || fail "missing slug should default to open ($out)"
pass

# 5. Ref without link prefix (bare slug) is also handled.
out="$(run_state "done-feature")"
echo "$out" | grep -q "ITEM_STATE=closed" || fail "bare slug without # prefix should still match ($out)"
pass

# ── HERD-52 planned-work markers ────────────────────────────────────────────────────────────────
# 6. queue_item → annotates the item's line with a 📌 marker naming who + blocker + [<epoch>], and
#    reports DONE. The annotation lands ON the 🔜 line so it also shows up in _backend_list_open.
out="$(run_op _backend_queue_item repo#open-feature alice open-blocker)"
echo "$out" | grep -q "RESULT=DONE" || fail "queue_item did not report DONE ($out)"
grep -qE '📌 queued by alice: sequenced after open-blocker \[[0-9]+\]' "$BACKLOG_FILE" \
  || fail "queue_item did not annotate the item line with the 📌 marker ($(grep open-feature "$BACKLOG_FILE"))"
grep -q "🔜 open-feature" "$BACKLOG_FILE" || fail "queue_item clobbered the item's own text/emoji"
pass

# 7. list_queued → emits one TSV line per marker ("<text>\t<who>\t<detail>\t<epoch>"); only the
#    marked item appears.
lq="$( cd "$T" && . "$BACKEND"; _backend_list_queued )"
echo "$lq" | grep -qE "open-feature.*${TAB}alice${TAB}sequenced after open-blocker${TAB}[0-9]+$" \
  || fail "list_queued did not emit the parsed marker line ($lq)"
[ "$(printf '%s\n' "$lq" | grep -c 'alice')" = "1" ] || fail "list_queued emitted more than the one marker ($lq)"
pass

# 8. queue_item is idempotent-ish: re-queuing REFRESHES the marker in place (no duplicate 📌 on the line).
run_op _backend_queue_item repo#open-feature alice open-blocker >/dev/null
[ "$(grep -c '📌' "$BACKLOG_FILE")" = "1" ] || fail "re-queue duplicated the 📌 marker instead of refreshing it"
pass

# 9. queue_item with NO blocker → "sequenced next".
run_op _backend_queue_item repo#open-feature alice "" >/dev/null
grep -q "📌 queued by alice: sequenced next" "$BACKLOG_FILE" || fail "queue_item (no blocker) did not fall back to 'sequenced next'"
pass

# 10. unqueue_item → strips the marker; DONE. A second unqueue with no marker present → NOCHANGE.
out="$(run_op _backend_unqueue_item repo#open-feature alice)"
echo "$out" | grep -q "RESULT=DONE" || fail "unqueue_item did not report DONE ($out)"
grep -q '📌' "$BACKLOG_FILE" && fail "unqueue_item left a 📌 marker behind ($(grep open-feature "$BACKLOG_FILE"))"
grep -q "🔜 open-feature — a queued item" "$BACKLOG_FILE" || fail "unqueue_item did not restore the item's line cleanly"
out2="$(run_op _backend_unqueue_item repo#open-feature alice)"
echo "$out2" | grep -q "RESULT=NOCHANGE" || fail "unqueue_item with no marker should be NOCHANGE ($out2)"
pass

# 11. CLAIM-poisoning regression (reviewer BLOCK): a queue marker embeds ANOTHER item's slug
#     (…sequenced after <blocker>…). That must NOT become a match surface for the blocker's own claim.
#     Repro: hold alpha behind beta (queue alpha --after beta), then spawn the blocker → claim beta.
#     BETA must be the one claimed; ALPHA must stay 🔜.
printf -- '- 🔜 alpha — first\n- 🔜 beta — second\n' >> "$BACKLOG_FILE"
git -C "$T" add BACKLOG.md; git -C "$T" commit -q -m "add alpha/beta"
run_op _backend_queue_item repo#alpha alice beta >/dev/null
grep -qE '🔜 alpha .*📌 queued by alice: sequenced after beta' "$BACKLOG_FILE" \
  || fail "queue did not mark alpha with the beta blocker ($(grep alpha "$BACKLOG_FILE"))"
cl="$(run_claim repo#beta bob)"
echo "$cl" | grep -q "CLAIM=CLAIMED" || fail "claim of beta did not report CLAIMED ($cl)"
grep -qE '🚧 beta .*\(claimed by bob\)' "$BACKLOG_FILE" \
  || fail "claim did not flip BETA to 🚧 owned by bob ($(grep -E 'alpha|beta' "$BACKLOG_FILE"))"
grep -qE '🚧 alpha' "$BACKLOG_FILE" && fail "claim of beta wrongly flipped ALPHA — marker-poisoning regression"
grep -qE '🔜 alpha' "$BACKLOG_FILE" || fail "alpha should remain 🔜 open after claiming beta"
pass

# 12. item_state is marker-aware too: alpha's line names beta in its marker, but item_state repo#beta
#     must read BETA's own state (in-progress after the claim), never alpha's.
st="$( cd "$T" && . "$BACKEND"; ITEM_STATE=""; _backend_item_state repo#beta; printf '%s\n' "${ITEM_STATE:-}" )"
[ "$st" = "in-progress" ] || fail "item_state repo#beta should be in-progress after the claim, got '$st'"
pass

echo "ALL PASS ($PASS checks)"
