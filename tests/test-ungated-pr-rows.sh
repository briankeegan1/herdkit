#!/usr/bin/env bash
# test-ungated-pr-rows.sh — hermetic unit tests for the UNGATED-PR truth console section (HERD-460,
# GitHub issue #574): an open PR against the default branch with no builder/worktree record silently
# bypasses the merge gate (MERGE_POLICY=auto only ever gates a PR the watcher discovered via a git
# worktree). Unlike ORPHAN_PR_ROWS (HERD-330, an opt-in nicety this section builds on top of), this
# row carries NO config gate — it is computed and rendered unconditionally, whenever such a PR is
# observed, and is zero-cost (no ledger, no section) when none exist. Invariants:
#   • UNCONDITIONAL: fires with ORPHAN_PR_ROWS=off AND ADOPT_REMOTE_PRS=off (both defaults) — no lever
#     needs to be flipped for the row to appear.
#   • Exactly the OPEN PRs NOT in the claimed set become rows — a PR a worktree owns is excluded.
#   • A PR the adopt leg already recorded as SUCCESSFULLY adopted (ADOPT_PR_LEDGER, keyed by exact
#     (pr,sha)) is excluded even though it is not yet in the claimed set (one-tick rediscovery lag).
#   • A FAILED open-PR fetch (PRS_LOOKUP_OK=0) is never fabricated into "nothing ungated": the scan is
#     a no-op and never clobbers the previous tick's ledger.
#   • Malformed roster is fail-soft: empty ledger, never a crash.
#   • Zero network: the scan reads PRS_JSON verbatim; no gh/git call is made.
#   • Turning ORPHAN_PR_ROWS/ADOPT_REMOTE_PRS on or off never changes this section's behavior — the two
#     features are fully independent.
#
# Sources agent-watch.sh in lib mode (AGENT_WATCH_LIB=1 — helpers only, no polling loop, no console,
# no real network), pointing config discovery at a nonexistent file. NO_COLOR pins deterministic plain
# output.
# Run:  bash tests/test-ungated-pr-rows.sh
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
printf '#!/usr/bin/env bash\necho SENTINEL-NETWORK-LEAK\nexit 0\n' > "$BIN/gh";  chmod +x "$BIN/gh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/git";  chmod +x "$BIN/git"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/herdr"; chmod +x "$BIN/herdr"
export PATH="$BIN:$PATH"

# ── Source the watcher's helpers WITHOUT its live loop (lib mode), colors blanked (NO_COLOR) ────────
export AGENT_WATCH_LIB=1
export HERD_CONFIG_FILE="$T/no-such-config"
export WORKTREES_DIR="$T/trees"; mkdir -p "$WORKTREES_DIR"
export PROJECT_ROOT="$T/main"; mkdir -p "$PROJECT_ROOT/.herd"
export WORKSPACE_NAME="ungatedtest"
export WATCHER_OWNER="me-operator"
export NO_COLOR=1
export HERD_FAKE_NOW=1000000000    # deterministic epoch for every scan
# Both sibling levers left UNSET (default off) for the whole file — the point of this feature is that
# neither needs to be on.
unset ORPHAN_PR_ROWS ADOPT_REMOTE_PRS
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"
for fn in _ungated_prs_scan _ungated_pr_classify _ungated_pr_row build_ungated_prs; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined after sourcing"
done
pass

# A three-PR open roster (base fields exactly as `gh pr list` returns them, including headRefOid).
PRS='[
  {"number":101,"title":"add widget","headRefName":"feat/widget","headRefOid":"aaa111"},
  {"number":102,"title":"fix leak","headRefName":"feat/leak","headRefOid":"bbb222"},
  {"number":103,"title":"tidy docs","headRefName":"feat/docs","headRefOid":"ccc333"}
]'

# ── 1. UNCONDITIONAL: with both sibling levers OFF, the scan still writes the ungated ledger ────────
rm -f "$UNGATED_PR_LEDGER" "$ADOPT_PR_LEDGER"
PRS_LOOKUP_OK=1 _ungated_prs_scan "$PRS" "102"
[ -s "$UNGATED_PR_LEDGER" ] || fail "the ungated-PR scan must fire with no config key set at all"
n=$(wc -l < "$UNGATED_PR_LEDGER" | tr -cd '0-9')
[ "$n" = "2" ] || fail "expected 2 ungated rows (101,103; 102 is claimed), got $n"
grep -q "^${HERD_FAKE_NOW}	101	add widget	feat/widget	$" "$UNGATED_PR_LEDGER" || fail "PR 101 row missing/misshaped"
grep -q "^${HERD_FAKE_NOW}	103	tidy docs	feat/docs	$"  "$UNGATED_PR_LEDGER" || fail "PR 103 row missing/misshaped"
grep -q "	102	" "$UNGATED_PR_LEDGER" && fail "claimed PR 102 must NOT be an ungated row"
pass

# ── 2. build_ungated_prs renders every ledger row (NO_COLOR → plain); exact wording asserted ────────
UNGATED_PR_SECTION_ROWS=""
build_ungated_prs
[ -n "$UNGATED_PR_SECTION_ROWS" ] || fail "a non-empty ledger must populate the section"
grep -q "🔓 #101 add widget feat/widget · ungated · no builder record · enable ADOPT_REMOTE_PRS or git worktree add to adopt" <<< "$UNGATED_PR_SECTION_ROWS" \
  || fail "row 101 not rendered as expected: $UNGATED_PR_SECTION_ROWS"
grep -q "#103 tidy docs feat/docs" <<< "$UNGATED_PR_SECTION_ROWS" || fail "row 103 not rendered"
grep -q "#102" <<< "$UNGATED_PR_SECTION_ROWS" && fail "claimed PR 102 must not render"
grep -q "SENTINEL-NETWORK-LEAK" <<< "$UNGATED_PR_SECTION_ROWS" && fail "a network stub was invoked"
pass

# ── 3. A PR the adopt leg already recorded as ADOPTED is excluded even though still unclaimed ────────
rm -f "$UNGATED_PR_LEDGER"
printf '101\taaa111\tadopted\n' > "$ADOPT_PR_LEDGER"
PRS_LOOKUP_OK=1 _ungated_prs_scan "$PRS" ""
n=$(wc -l < "$UNGATED_PR_LEDGER" | tr -cd '0-9')
[ "$n" = "2" ] || fail "expected 2 ungated rows (102,103) once 101 is recorded adopted, got $n"
grep -q "	101	" "$UNGATED_PR_LEDGER" && fail "an already-adopted (pr,sha) must not render as ungated"
grep -q "	102	" "$UNGATED_PR_LEDGER" || fail "PR 102 should still be ungated"
rm -f "$ADOPT_PR_LEDGER"
pass

# ── 4. A DIFFERENT sha for an adopted PR number still renders (adoption is sha-exact, not PR-only) ──
rm -f "$UNGATED_PR_LEDGER"
printf '101\tSOME-OTHER-SHA\tadopted\n' > "$ADOPT_PR_LEDGER"
PRS_LOOKUP_OK=1 _ungated_prs_scan "$PRS" ""
grep -q "	101	" "$UNGATED_PR_LEDGER" || fail "a stale adopted-sha record must not suppress a NEW sha's ungated row"
rm -f "$ADOPT_PR_LEDGER"
pass

# ── 5. A FAILED fetch (PRS_LOOKUP_OK=0) never clobbers the last-known ledger ─────────────────────────
printf '%s\t%s\t%s\t%s\n' "$HERD_FAKE_NOW" 200 "prior ungated" "feat/prior" > "$UNGATED_PR_LEDGER"
PRS_LOOKUP_OK=0 _ungated_prs_scan "$PRS" ""
grep -q "	200	prior ungated	" "$UNGATED_PR_LEDGER" || fail "a failed lookup must not rewrite the ledger"
pass

# ── 6. Malformed roster is fail-soft: empty ledger, never a crash ───────────────────────────────────
PRS_LOOKUP_OK=1 _ungated_prs_scan 'not json' "" || fail "malformed roster must not error"
[ ! -s "$UNGATED_PR_LEDGER" ] || fail "malformed roster must yield an empty ledger"
pass

# ── 7. render() frame includes the 'ungated PRs' header with BOTH sibling levers off ────────────────
HDR_LINE="hdr"; RULE="----"; LANDED="  — none —"; DISPLAY=(); last_frame=""
UNGATED_PR_SECTION_ROWS=""
render >/dev/null 2>&1 || true
case "${frame:-}" in *"ungated PRs"*) fail "empty section must not render the ungated PRs header" ;; esac
UNGATED_PR_SECTION_ROWS=$'    🔓 #101 add widget feat/widget · x\n'
last_frame=""
render >/dev/null 2>&1 || true
case "${frame:-}" in *"ungated PRs"*) : ;; *) fail "a non-empty section must render the ungated PRs header, with NO config key set" ;; esac
pass

# ── 8. HERD-663 AUTHOR FALLBACK: a PR authored by someone other than this seat (WATCHER_OWNER=
#      me-operator, set at the top of this file) renders the compact '👤 ... authored by <author>
#      (no tracker claim)' row with the adopt nudge suppressed; a PR this seat authored itself keeps
#      today's adopt-nudge row verbatim ──────────────────────────────────────────────────────────────
rm -f "$UNGATED_PR_LEDGER" "$ADOPT_PR_LEDGER"
PRS_AUTHORED='[
  {"number":201,"title":"teammate work","headRefName":"feat/teammate","headRefOid":"ddd444","author":{"login":"teammate-x"}},
  {"number":202,"title":"my own PR","headRefName":"feat/mine","headRefOid":"eee555","author":{"login":"me-operator"}}
]'
PRS_LOOKUP_OK=1 _ungated_prs_scan "$PRS_AUTHORED" ""
grep -q "^${HERD_FAKE_NOW}	201	teammate work	feat/teammate	teammate-x$" "$UNGATED_PR_LEDGER" \
  || fail "PR 201's author must be recorded in the ledger: $(cat "$UNGATED_PR_LEDGER")"
UNGATED_PR_SECTION_ROWS=""
build_ungated_prs
grep -q "👤 #201 teammate work · authored by teammate-x (no tracker claim)" <<< "$UNGATED_PR_SECTION_ROWS" \
  || fail "PR 201 must render the author-fallback row: $UNGATED_PR_SECTION_ROWS"
grep -q "#201.*enable ADOPT_REMOTE_PRS" <<< "$UNGATED_PR_SECTION_ROWS" \
  && fail "the adopt nudge must be suppressed on an author-fallback row"
grep -q "🔓 #202 my own PR feat/mine · ungated · no builder record · enable ADOPT_REMOTE_PRS or git worktree add to adopt" \
  <<< "$UNGATED_PR_SECTION_ROWS" || fail "PR 202 (this seat's own PR) must keep today's adopt-nudge row: $UNGATED_PR_SECTION_ROWS"
pass

# ── 9. Explicitly OFF ADOPT_REMOTE_PRS drops the "enable ADOPT_REMOTE_PRS" clause from the base row —
#      unset (default) keeps it, since flipping it on there is still live advice. herd-config.sh's
#      `: "${ADOPT_REMOTE_PRS:="off"}"` default-ASSIGNS the runtime var the moment it loads, so "left
#      unset" and "the operator wrote off" are indistinguishable via $ADOPT_REMOTE_PRS itself — this
#      writes/removes the KEY IN THE CONFIG FILE (what _adopt_remote_prs_config_value actually reads)
#      to prove the two really are told apart ────────────────────────────────────────────────────────
_adopt_remote_prs_enabled && fail "precondition: ADOPT_REMOTE_PRS must already read off (unset==default==off)"
printf 'ADOPT_REMOTE_PRS=off\n' > "$T/no-such-config"
UNGATED_PR_SECTION_ROWS=""
build_ungated_prs
grep -q "🔓 #202 my own PR feat/mine · ungated · no builder record · git worktree add to adopt" \
  <<< "$UNGATED_PR_SECTION_ROWS" || fail "an explicit ADOPT_REMOTE_PRS=off in the config file must drop the enable-it suggestion: $UNGATED_PR_SECTION_ROWS"
grep -q "enable ADOPT_REMOTE_PRS" <<< "$UNGATED_PR_SECTION_ROWS" \
  && fail "no row may suggest enabling ADOPT_REMOTE_PRS once it is explicitly off"
rm -f "$T/no-such-config"
UNGATED_PR_SECTION_ROWS=""
build_ungated_prs
grep -q "🔓 #202 my own PR feat/mine · ungated · no builder record · enable ADOPT_REMOTE_PRS or git worktree add to adopt" \
  <<< "$UNGATED_PR_SECTION_ROWS" || fail "no config file at all (implicit default) must keep the enable-it suggestion: $UNGATED_PR_SECTION_ROWS"
pass

# ── 10. TEAM_ALIASES overrides the author-fallback row's display name too (HERD-663 shares the same
#       lookup with the TEAM_PRESENCE attributed row, tested in test-team-presence.sh) ────────────────
export TEAM_ALIASES="teammate-x=Teammate X"
UNGATED_PR_SECTION_ROWS=""
build_ungated_prs
grep -q "👤 #201 teammate work · authored by Teammate X (no tracker claim)" <<< "$UNGATED_PR_SECTION_ROWS" \
  || fail "TEAM_ALIASES must override the author-fallback display name: $UNGATED_PR_SECTION_ROWS"
unset TEAM_ALIASES
rm -f "$UNGATED_PR_LEDGER" "$ADOPT_PR_LEDGER"
pass

echo "ok — $PASS ungated-PR-rows assertions passed"
