#!/usr/bin/env bash
# test-human-verify-hold.sh — hermetic tests for the per-PR HUMAN-VERIFY hold.
#
# Fully hermetic: stubs gh (pr view/list/merge/comment) and herdr/git on PATH; touches nothing
# outside $T; never runs the live watch loop (agent-watch.sh is sourced in AGENT_WATCH_LIB=1 mode).
#
# Covers:
#   • human-verify.sh parser — block form, inline form, absent marker, bare marker (no steps),
#     bullet/decoration stripping
#   • pr_human_verify_held — per-PR: a PR whose body carries the marker is held while a sibling
#     without it auto-merges
#   • _hold_decision — every (policy × hv × approved) combination, including "no double-hold" in
#     approve/observe mode
#   • ledger REUSE — the hold uses the SAME $APPROVALS ledger as MERGE_POLICY=approve; no parallel
#     ledger file is created
#   • sha-keyed release + re-hold on a new commit
#   • console wording (_hold_ready_label + the merging label in the source)
#   • herd-approve.sh list surfaces the declared HUMAN-VERIFY steps
#   • MERGE_POLICY=approve with a HUMAN-VERIFY body behaves exactly like plain approve (no double-hold)
# Run:  bash tests/test-human-verify-hold.sh
# No `set -e`: several checks assert non-zero returns explicitly.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../scripts/herd/agent-watch.sh"
HV="$HERE/../scripts/herd/human-verify.sh"
APPROVE="$HERE/../scripts/herd/herd-approve.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

[ -f "$WATCH" ]   || fail "agent-watch.sh not found at $WATCH"
[ -f "$HV" ]      || fail "human-verify.sh not found at $HV"
[ -f "$APPROVE" ] || fail "herd-approve.sh not found at $APPROVE"
command -v python3 >/dev/null 2>&1 || fail "python3 required"

# ── Stub binaries on PATH — no network, no side-effects beyond $T ────────────────────────────────
BIN="$T/bin"; mkdir -p "$BIN"
BODIES="$T/bodies"; mkdir -p "$BODIES"
export BODIES
cat > "$BIN/gh" << 'STUB'
#!/usr/bin/env bash
# Minimal gh stub. Recognizes:
#   pr merge <n> ...            → append to $GH_MERGE_LOG
#   pr comment ...              → no-op
#   pr view <n> --json body ... → print $BODIES/<n> (the PR body), empty if none
#   pr view <n> --json title ...→ print a synthetic title
#   pr list ...                 → empty JSON array
case "$1 $2" in
  "pr merge")   printf 'merge %s\n' "$3" >> "${GH_MERGE_LOG:-/dev/null}"; exit 0 ;;
  "pr comment") exit 0 ;;
  "pr list")    echo '[]'; exit 0 ;;
  "pr view")
    num="$3"
    allargs="$*"
    case "$allargs" in
      # HV_GH_FAIL / HV_GH_HANG (HERD-237): make the BODY read fail or wedge, so a test can prove the
      # human-verify gate fails CLOSED rather than reading an unreadable body as "no steps declared".
      *"--json body"*)
        [ -n "${HV_GH_HANG:-}" ] && exec sleep 30
        [ -n "${HV_GH_FAIL:-}" ] && exit 1
        [ -f "$BODIES/$num" ] && cat "$BODIES/$num" || true ;;
      *"--json title"*) printf 'title for PR %s' "$num" ;;
      *)                : ;;
    esac
    exit 0 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$BIN/gh"
for cmd in git herdr; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$cmd"; chmod +x "$BIN/$cmd"
done
export PATH="$BIN:$PATH"

export WORKTREES_DIR="$T/trees"; mkdir -p "$WORKTREES_DIR"
export HERD_CONFIG_FILE="$T/no-such-config"

# ── 1. Parser: human_verify_steps / human_verify_has ─────────────────────────────────────────────
. "$HV" || fail "sourcing human-verify.sh failed"
type human_verify_steps >/dev/null 2>&1 || fail "human_verify_steps not defined"
type human_verify_has   >/dev/null 2>&1 || fail "human_verify_has not defined"

# Block form: marker line then one step per line, ending at a blank line.
BLOCK_BODY="$(printf 'Summary of the change.\n\nHUMAN-VERIFY:\n- run coordinator.sh and confirm .herd-panes appears\n- reload and confirm the panes refresh\n\nMore notes here.\n')"
steps="$(printf '%s' "$BLOCK_BODY" | human_verify_steps)"
[ "$(printf '%s' "$steps" | grep -c .)" = "2" ] || fail "block form should yield 2 steps, got: $steps"
ok
printf '%s' "$steps" | grep -q 'run coordinator.sh and confirm .herd-panes appears' || fail "step 1 text missing"
ok
printf '%s' "$steps" | grep -q 'reload and confirm the panes refresh' || fail "step 2 text missing"
ok
printf '%s' "$steps" | grep -q '^- ' && fail "bullet marker should be stripped from steps"
ok
printf '%s' "$BLOCK_BODY" | human_verify_has || fail "block form should be a hold"
ok

# Inline form: HUMAN-VERIFY: <single step> on one line.
INLINE_BODY="$(printf 'Fix.\n\nHUMAN-VERIFY: run the live smoke test on port 8501\n')"
printf '%s' "$INLINE_BODY" | human_verify_has || fail "inline form should be a hold"
ok
printf '%s' "$INLINE_BODY" | human_verify_steps | grep -q 'run the live smoke test on port 8501' || fail "inline step text missing"
ok

# Decorated marker (**HUMAN-VERIFY:**) with markdown bullets and mixed case.
DECOR_BODY="$(printf '**HUMAN-VERIFY:**\n* Confirm the reload refreshes panes\n1. Then check the backlog pane\n')"
[ "$(printf '%s' "$DECOR_BODY" | human_verify_steps | grep -c .)" = "2" ] || fail "decorated form should yield 2 steps"
ok
printf '%s' "$DECOR_BODY" | human_verify_steps | grep -q '^Confirm the reload refreshes panes$' || fail "'*' bullet not stripped"
ok
printf '%s' "$DECOR_BODY" | human_verify_steps | grep -q '^Then check the backlog pane$' || fail "'1.' ordered marker not stripped"
ok

# Dash- and plus-bulleted markers: a builder naturally writes the whole block as a `-` list
# ("- HUMAN-VERIFY:" over "- step" lines). These MUST hold — a missing bullet in the marker class
# fails OPEN (no hold, silent auto-merge), the exact bypass this gate exists to prevent.
DASH_BODY="$(printf 'Adds a thing.\n\n- HUMAN-VERIFY:\n- run the live smoke test\n- confirm the pane reloads\n')"
printf '%s' "$DASH_BODY" | human_verify_has || fail "'- HUMAN-VERIFY:' must be a hold (fails open otherwise)"
ok
[ "$(printf '%s' "$DASH_BODY" | human_verify_steps | grep -c .)" = "2" ] || fail "'- HUMAN-VERIFY:' block should yield 2 steps"
ok
printf '%s' "$DASH_BODY" | human_verify_steps | grep -q '^run the live smoke test$' || fail "'-' marker: step 1 text/de-bullet wrong"
ok
PLUS_BODY="$(printf '+ HUMAN-VERIFY: verify the reload refreshes panes\n')"
printf '%s' "$PLUS_BODY" | human_verify_has || fail "'+ HUMAN-VERIFY:' (inline) must be a hold"
ok
printf '%s' "$PLUS_BODY" | human_verify_steps | grep -q '^verify the reload refreshes panes$' || fail "'+' inline marker step text wrong"
ok

# Absent marker → not a hold, no steps.
NOMARK_BODY="$(printf 'Just a normal PR body.\nNo manual steps here.\n')"
! printf '%s' "$NOMARK_BODY" | human_verify_has || fail "absent marker should NOT be a hold"
ok
[ -z "$(printf '%s' "$NOMARK_BODY" | human_verify_steps)" ] || fail "absent marker should yield no steps"
ok

# Bare marker with NO steps → not a hold (nothing to verify).
BARE_BODY="$(printf 'HUMAN-VERIFY:\n\nUnrelated paragraph.\n')"
! printf '%s' "$BARE_BODY" | human_verify_has || fail "bare marker with no steps should NOT be a hold"
ok

# Empty body → not a hold.
! printf '' | human_verify_has || fail "empty body should NOT be a hold"
ok

# ── 2. Source agent-watch.sh in lib mode ─────────────────────────────────────────────────────────
export AGENT_WATCH_LIB=1
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"
for fn in _hold_decision _hold_ready_label pr_human_verify_held pr_human_verify_steps _pr_body \
          approval_is_approved approval_awaiting_noted record_approval_awaiting; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined"
done
ok

# ── 3. _hold_decision — every combination ────────────────────────────────────────────────────────
# auto, no human-verify → always MERGE (normal auto-merge).
[ "$(_hold_decision auto '' '')"  = "MERGE" ] || fail "auto/no-hv/unapproved → MERGE"
ok
[ "$(_hold_decision auto '' '1')" = "MERGE" ] || fail "auto/no-hv/approved → MERGE"
ok
# auto, human-verify → HOLD until approved, then MERGE.
[ "$(_hold_decision auto '1' '')"  = "HOLD"  ] || fail "auto/hv/unapproved → HOLD"
ok
[ "$(_hold_decision auto '1' '1')" = "MERGE" ] || fail "auto/hv/approved → MERGE"
ok
# approve → HOLD/MERGE regardless of hv (no double-hold: hv is ignored, single hold path).
[ "$(_hold_decision approve '' '')"  = "HOLD"  ] || fail "approve/unapproved → HOLD"
ok
[ "$(_hold_decision approve '' '1')" = "MERGE" ] || fail "approve/approved → MERGE"
ok
[ "$(_hold_decision approve '1' '')"  = "HOLD"  ] || fail "approve/hv/unapproved → HOLD (hv ignored)"
ok
[ "$(_hold_decision approve '1' '1')" = "MERGE" ] || fail "approve/hv/approved → MERGE (hv ignored)"
ok
# observe → never merges, hv irrelevant.
[ "$(_hold_decision observe '' '1')"  = "OBSERVE" ] || fail "observe → OBSERVE"
ok
[ "$(_hold_decision observe '1' '1')" = "OBSERVE" ] || fail "observe/hv → OBSERVE"
ok

# ── 4. Per-PR: held PR vs auto-merging sibling ───────────────────────────────────────────────────
printf 'Adds a live feature.\n\nHUMAN-VERIFY:\n- click through the new tab in the running app\n' > "$BODIES/100"
printf 'Refactors a helper. No manual steps.\n' > "$BODIES/200"
  pr_human_verify_held 100 || fail "PR 100 (marker) should be held"
ok
! pr_human_verify_held 200 || fail "PR 200 (no marker) should NOT be held"
ok
# In auto mode the sibling PRs diverge: 100 holds, 200 auto-merges.
hv100=""; pr_human_verify_held 100 && hv100=1
hv200=""; pr_human_verify_held 200 && hv200=1
[ "$(_hold_decision auto "$hv100" '')" = "HOLD"  ] || fail "PR 100 should HOLD in auto"
ok
[ "$(_hold_decision auto "$hv200" '')" = "MERGE" ] || fail "PR 200 should MERGE in auto (sibling auto-merges)"
ok

# ── 5. Ledger REUSE + sha-keyed release + re-hold on new commit ───────────────────────────────────
rm -f "$APPROVALS"
SHA_A="aaaaaaaaaaaa"; SHA_B="bbbbbbbbbbbb"
# First sight of PR 100 @ SHA_A: not yet awaiting-noted, not approved → HOLD path records awaiting.
! approval_awaiting_noted 100 "$SHA_A" || fail "no awaiting record should exist yet"
ok
record_approval_awaiting 100 "$SHA_A"
approval_awaiting_noted 100 "$SHA_A" || fail "awaiting record should now exist"
ok
# The hold reuses the approve ledger file — the awaiting line is in $APPROVALS, not a parallel file.
grep -q '^[0-9]* awaiting 100 '"$SHA_A"'$' "$APPROVALS" || fail "awaiting record not in \$APPROVALS ledger"
ok
[ "$APPROVALS" = "$WORKTREES_DIR/.agent-watch-approvals" ] || fail "hold must reuse .agent-watch-approvals, got $APPROVALS"
ok
# No parallel human-verify/hold ledger file was created anywhere in the trees dir.
extra="$(find "$WORKTREES_DIR" -maxdepth 1 -type f \( -name '*human-verify*' -o -name '*hold*' \) 2>/dev/null)"
[ -z "$extra" ] || fail "a parallel ledger was created: $extra"
ok
# Still held before approval.
approved=""; approval_is_approved 100 "$SHA_A" && approved=1
[ "$(_hold_decision auto '1' "$approved")" = "HOLD" ] || fail "held before approval"
ok
# Human approves SHA_A (exactly what herd-approve.sh approve writes) → releases → MERGE.
printf '%s approved 100 %s\n' "1234567890" "$SHA_A" >> "$APPROVALS"
approved=""; approval_is_approved 100 "$SHA_A" && approved=1
[ "$(_hold_decision auto '1' "$approved")" = "MERGE" ] || fail "approval should release the hold"
ok
# Re-hold on a NEW commit: SHA_B has no approval → HOLD again (sha-keyed).
approvedB=""; approval_is_approved 100 "$SHA_B" && approvedB=1
[ "$(_hold_decision auto '1' "$approvedB")" = "HOLD" ] || fail "new commit (SHA_B) should re-hold"
ok

# ── 6. Console wording ───────────────────────────────────────────────────────────────────────────
[ "$(_hold_ready_label '1' 100)" = "ready · human-verify pending · herd-approve.sh approve 100" ] \
  || fail "human-verify ready label wording wrong: $(_hold_ready_label '1' 100)"
ok
[ "$(_hold_ready_label '' 100)" = "ready · awaiting approval" ] \
  || fail "plain approve ready label wording wrong: $(_hold_ready_label '' 100)"
ok
# The merging label for a released human-verify hold is present in the watcher source.
grep -q 'merging (human-verified)' "$WATCH" || fail "watcher missing 'merging (human-verified)' label"
ok

# ── 7. herd-approve.sh list surfaces the declared steps ──────────────────────────────────────────
rm -f "$APPROVALS"
printf '1000 awaiting 100 %s\n' "$SHA_A" > "$APPROVALS"
list_out="$(cd "$WORKTREES_DIR" && WORKTREES_DIR="$WORKTREES_DIR" HERD_CONFIG_FILE="$HERD_CONFIG_FILE" \
  PATH="$PATH" BODIES="$BODIES" bash "$APPROVE" list 2>&1)"
printf '%s' "$list_out" | grep -q 'click through the new tab in the running app' \
  || fail "herd-approve.sh list did not surface the HUMAN-VERIFY step. Output:
$list_out"
ok
printf '%s' "$list_out" | grep -qi 'human-verify' \
  || fail "herd-approve.sh list should label the human-verify steps. Output:
$list_out"
ok

# ── 8. MERGE_POLICY=approve with a HUMAN-VERIFY body behaves exactly like plain approve ────────────
# In approve mode the watcher never even parses the marker (hv_hold stays ""), so the decision is
# identical whether or not the body has a HUMAN-VERIFY block — a single hold, released by approval.
[ "$(_hold_decision approve '' '')"  = "$(_hold_decision approve '1' '')"  ] || fail "approve: hv must not change the unapproved decision (no double-hold)"
ok
[ "$(_hold_decision approve '' '1')" = "$(_hold_decision approve '1' '1')" ] || fail "approve: hv must not change the approved decision"
ok

# ── 9. HERD-237: an UNREADABLE body fails CLOSED (the merge gate's only human-verify signal) ──────
# In AUTOMERGE mode pr_human_verify_held is the ONLY thing that turns a green-gated PR into a hold.
# _gh_timeout returns 124 with EMPTY stdout on expiry; if _pr_body swallows that, an unreadable body is
# indistinguishable from "no HUMAN-VERIFY block" and the PR merges with its manual steps never run.

# (a) gh's own failure ⇒ _pr_body propagates the rc; pr_human_verify_held reports UNKNOWN (2).
HV_GH_FAIL=1 _pr_body 100 >/dev/null 2>&1 && fail "(9a) _pr_body returned success on a failed gh"
HV_GH_FAIL=1 pr_human_verify_held 100; hv_rc=$?
[ "$hv_rc" -eq 2 ] || fail "(9a) an unreadable body must report UNKNOWN (2), got rc=$hv_rc"
ok

# (b) a WEDGED gh ⇒ the same, bounded by the deadline (this is the shipped 124 path).
export HERD_GH_TIMEOUT_SECS=2
_hv_start=$(date +%s)
HV_GH_HANG=1 _pr_body 100 >/dev/null 2>&1; body_rc=$?
_hv_elapsed=$(( $(date +%s) - _hv_start ))
[ "$body_rc" -eq 124 ] || fail "(9b) a wedged body fetch must return 124, got $body_rc"
[ "$_hv_elapsed" -lt 15 ] || fail "(9b) the body fetch was not bounded (${_hv_elapsed}s)"
HV_GH_HANG=1 pr_human_verify_held 100; hv_rc=$?
[ "$hv_rc" -eq 2 ] || fail "(9b) a timed-out body must report UNKNOWN (2), got rc=$hv_rc"
unset HERD_GH_TIMEOUT_SECS
ok

# (c) an EMPTY body that was READ is still an honest "no hold" — rc 1, never 2.
: > "$BODIES/300"
pr_human_verify_held 300; hv_rc=$?
[ "$hv_rc" -eq 1 ] || fail "(9c) a readable empty body must be 'no hold' (1), got rc=$hv_rc"
ok

# (d) THE TRAP, made explicit: a caller that treats the tri-state as a boolean merges an unreadable PR.
# This is what the code did before HERD-237, and why the merge gate must branch on rc 2 by name.
hv_bool=""; HV_GH_FAIL=1 pr_human_verify_held 100 && hv_bool=1
[ -z "$hv_bool" ] || fail "(9d) precondition"
[ "$(_hold_decision auto "$hv_bool" '')" = "MERGE" ] \
  || fail "(9d) precondition: a boolean read of the unreadable case decides MERGE"
# …so assert the SHIPPED gate does not do that: it must handle the non-zero rc before setting hv_hold.
python3 - "$WATCH" <<'GATE' || fail "(9d) the merge gate does not fail CLOSED on an unreadable PR body"
import re, sys
src = open(sys.argv[1], encoding='utf-8').read()
i = src.index('hv_rc=0; hv_body="$(_pr_body "$prnum")"')
j = src.index('printf \'%s\' "$hv_body" | human_verify_has && hv_hold=1', i)
between = src[i:j]
# the unreadable branch must journal and `continue` BEFORE hv_hold can ever be set
sys.exit(0 if ('hv_body_unreadable' in between and 'continue' in between) else 1)
GATE
ok

echo "ALL PASS ($pass checks)"
