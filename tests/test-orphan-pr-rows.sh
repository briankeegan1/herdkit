#!/usr/bin/env bash
# test-orphan-pr-rows.sh — hermetic unit tests for the ORPHAN-PR advisory console section (HERD-330):
# the ORPHAN_PR_ROWS=on|off lever, the DYNAMIC discovery (open PRs in the tick's PRS_JSON that no
# discovered worktree claims), and the invariants the feature MUST hold:
#   • OFF (default) is byte-inert: _orphan_prs_scan writes NO ledger and build_orphan_prs leaves
#     ORPHAN_PR_SECTION_ROWS empty, so render() adds nothing.
#   • ON: exactly the OPEN PRs NOT in the claimed set become rows — a PR a worktree owns is excluded.
#   • DYNAMIC + self-correcting: the ledger is rewritten whole each scan, so an adopted PR (now in the
#     claimed set) or a closed PR (gone from PRS_JSON) simply stops being rendered — no stale row.
#   • A FAILED open-PR fetch (PRS_LOOKUP_OK=0) is never fabricated into "no orphans": the scan is a
#     no-op and never clobbers the previous tick's ledger.
#   • Zero network: the scan reads PRS_JSON verbatim; no gh/git call is made.
#
# Sources agent-watch.sh in lib mode (AGENT_WATCH_LIB=1 — helpers only, no polling loop, no console,
# no real network), pointing config discovery at a nonexistent file so herd-config.sh falls back to its
# generic defaults (ORPHAN_PR_ROWS defaults off). NO_COLOR pins deterministic plain output.
# Run:  bash tests/test-orphan-pr-rows.sh
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
# gh/git leaks are visible as a sentinel that would corrupt any assertion.
printf '#!/usr/bin/env bash\necho SENTINEL-NETWORK-LEAK\nexit 0\n' > "$BIN/gh";  chmod +x "$BIN/gh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/git";  chmod +x "$BIN/git"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/herdr"; chmod +x "$BIN/herdr"
export PATH="$BIN:$PATH"

# ── Source the watcher's helpers WITHOUT its live loop (lib mode), colors blanked (NO_COLOR) ────────
export AGENT_WATCH_LIB=1
export HERD_CONFIG_FILE="$T/no-such-config"
export WORKTREES_DIR="$T/trees"; mkdir -p "$WORKTREES_DIR"
export PROJECT_ROOT="$T/main"; mkdir -p "$PROJECT_ROOT/.herd"
export WORKSPACE_NAME="orphantest"
export WATCHER_OWNER="me-operator"
export NO_COLOR=1
export HERD_FAKE_NOW=1000000000    # deterministic epoch for every scan
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"
for fn in _orphan_pr_rows_enabled _orphan_prs_scan _orphan_pr_classify _orphan_pr_row build_orphan_prs; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined after sourcing"
done
pass

# ── 1. _orphan_pr_rows_enabled: default OFF; on|true|1|yes|enable enable it; anything else is OFF ───
unset ORPHAN_PR_ROWS
_orphan_pr_rows_enabled && fail "must be OFF by default (unset)"; pass
for v in on ON true 1 yes enable enabled; do
  ORPHAN_PR_ROWS="$v" _orphan_pr_rows_enabled || fail "should be ON for '$v'"
done; pass
for v in off "" 0 no garbage; do
  ORPHAN_PR_ROWS="$v" _orphan_pr_rows_enabled && fail "should be OFF for '$v'"
done; pass

# A three-PR open roster (base fields exactly as `gh pr list` returns them).
PRS='[
  {"number":101,"title":"add widget","headRefName":"feat/widget"},
  {"number":102,"title":"fix leak","headRefName":"feat/leak"},
  {"number":103,"title":"tidy docs","headRefName":"feat/docs"}
]'

# ── 2. OFF is byte-inert: no ledger written, no section rendered ────────────────────────────────────
rm -f "$ORPHAN_PR_LEDGER"
ORPHAN_PR_ROWS=off PRS_LOOKUP_OK=1 _orphan_prs_scan "$PRS" "102"
[ ! -e "$ORPHAN_PR_LEDGER" ] || fail "OFF must not write the orphan ledger"
ORPHAN_PR_SECTION_ROWS="sentinel"
ORPHAN_PR_ROWS=off build_orphan_prs
[ -z "$ORPHAN_PR_SECTION_ROWS" ] || fail "OFF must leave ORPHAN_PR_SECTION_ROWS empty"
pass

# ── 3. ON: only the UNCLAIMED open PRs become rows (102 is claimed → excluded) ──────────────────────
rm -f "$ORPHAN_PR_LEDGER"
ORPHAN_PR_ROWS=on PRS_LOOKUP_OK=1 _orphan_prs_scan "$PRS" "102"
[ -s "$ORPHAN_PR_LEDGER" ] || fail "ON must write the orphan ledger"
n=$(wc -l < "$ORPHAN_PR_LEDGER" | tr -cd '0-9')
[ "$n" = "2" ] || fail "expected 2 orphan rows (101,103), got $n"
grep -q "^${HERD_FAKE_NOW}	101	add widget	feat/widget$" "$ORPHAN_PR_LEDGER" || fail "PR 101 row missing/misshaped"
grep -q "^${HERD_FAKE_NOW}	103	tidy docs	feat/docs$"  "$ORPHAN_PR_LEDGER" || fail "PR 103 row missing/misshaped"
grep -q "	102	" "$ORPHAN_PR_LEDGER" && fail "claimed PR 102 must NOT be an orphan row"
pass

# ── 4. build_orphan_prs renders every ledger row (NO_COLOR → plain); content is human-legible ───────
ORPHAN_PR_SECTION_ROWS=""
ORPHAN_PR_ROWS=on build_orphan_prs
[ -n "$ORPHAN_PR_SECTION_ROWS" ] || fail "ON with orphans must populate the section"
printf '%s' "$ORPHAN_PR_SECTION_ROWS" | grep -q "🪹 #101 add widget feat/widget · no worktree here — adopt or handle manually" \
  || fail "row 101 not rendered as expected: $ORPHAN_PR_SECTION_ROWS"
printf '%s' "$ORPHAN_PR_SECTION_ROWS" | grep -q "#103 tidy docs feat/docs" || fail "row 103 not rendered"
printf '%s' "$ORPHAN_PR_SECTION_ROWS" | grep -q "#102" && fail "claimed PR 102 must not render"
# No network leak reached any assertion.
printf '%s' "$ORPHAN_PR_SECTION_ROWS" | grep -q "SENTINEL-NETWORK-LEAK" && fail "a network stub was invoked"
pass

# ── 5. DYNAMIC self-correction: adopt 101 (now claimed) + close 103 (gone from roster) → only 102-less
#      set. Rewrite drops the stale rows without any explicit clear. ────────────────────────────────
PRS2='[
  {"number":101,"title":"add widget","headRefName":"feat/widget"},
  {"number":102,"title":"fix leak","headRefName":"feat/leak"}
]'
ORPHAN_PR_ROWS=on PRS_LOOKUP_OK=1 _orphan_prs_scan "$PRS2" "101 102"
n=$(wc -l < "$ORPHAN_PR_LEDGER" | tr -cd '0-9')
[ "$n" = "0" ] || fail "after adopting 101 and closing 103, expected 0 orphan rows, got $n"
ORPHAN_PR_SECTION_ROWS="sentinel"
ORPHAN_PR_ROWS=on build_orphan_prs
[ -z "$ORPHAN_PR_SECTION_ROWS" ] || fail "empty ledger must render no section"
pass

# ── 6. A FAILED fetch (PRS_LOOKUP_OK=0) never clobbers the last-known ledger ─────────────────────────
printf '%s\t%s\t%s\t%s\n' "$HERD_FAKE_NOW" 200 "prior orphan" "feat/prior" > "$ORPHAN_PR_LEDGER"
ORPHAN_PR_ROWS=on PRS_LOOKUP_OK=0 _orphan_prs_scan "$PRS" ""
grep -q "	200	prior orphan	" "$ORPHAN_PR_LEDGER" || fail "a failed lookup must not rewrite the ledger"
pass

# ── 7. Malformed roster is fail-soft: empty ledger, never a crash ───────────────────────────────────
ORPHAN_PR_ROWS=on PRS_LOOKUP_OK=1 _orphan_prs_scan 'not json' "" || fail "malformed roster must not error"
[ ! -s "$ORPHAN_PR_LEDGER" ] || fail "malformed roster must yield an empty ledger"
pass

# ── 8. render() frame: OFF omits the 'orphan PRs' header; ON+orphans includes it ────────────────────
# Minimal render() context (globals it reads). We only assert the orphan section's presence/absence.
HDR_LINE="hdr"; RULE="----"; LANDED="  — none —"; DISPLAY=(); last_frame=""
render >/dev/null 2>&1 || true   # OFF: ORPHAN_PR_SECTION_ROWS is empty from test 5
case "${frame:-}" in *"orphan PRs"*) fail "OFF/empty must not render the orphan PRs header" ;; esac
ORPHAN_PR_SECTION_ROWS=$'    🪹 #101 add widget feat/widget · x\n'
last_frame=""
render >/dev/null 2>&1 || true
case "${frame:-}" in *"orphan PRs"*) : ;; *) fail "ON+orphans must render the orphan PRs header" ;; esac
pass

echo "ok — $PASS orphan-PR-rows assertions passed"
