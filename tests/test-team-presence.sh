#!/usr/bin/env bash
# test-team-presence.sh — hermetic unit tests for TEAMMATE BUILDER VISIBILITY on the ungated-PR rows
# (HERD-527, GitHub issue #639 phase 1).
#
# The watcher discovers work through LOCAL git worktrees, so a teammate's actively-being-built PR lands
# in the unconditional "ungated PRs" section labelled "ungated · no builder record · enable
# ADOPT_REMOTE_PRS or git worktree add to adopt" — an adopt nudge that is exactly wrong for a branch
# another operator is mid-build on (grounded: emberglen-godot, two operators, WATCHER_SCOPE=all).
# TEAM_PRESENCE=on joins the ungated PR to its tracker item (the shared `Refs:` parser + a token-exact
# branch fallback) and, when that item is IN PROGRESS and ASSIGNED, re-words the row and suppresses the
# nudge. Invariants asserted here:
#   • OFF (default) is BYTE-IDENTICAL — even with an attribution ledger sitting on disk, every ungated
#     row renders the pre-HERD-527 bytes, and the scan writes nothing at all.
#   • ON + in-progress + assigned → the compact '👤 #<pr> <title> · <assignee> — building <id>' row
#     (HERD-663), and the adopt nudge is GONE from that row.
#   • ON but the item is not in progress, or is in progress and UNASSIGNED, or resolves to nothing →
#     TODAY's row, unchanged.
#   • The `Refs:` join is the SHARED HERD-522 parser (a `## Refs:` heading resolves); the branch
#     fallback is TOKEN-EXACT (HERD-52 never claims feat/herd-527-*, and vice versa).
#   • TRACKER DOWN / no rich roster op → empty ledger → today's rows (fail-soft, never a red row).
#   • A failed `gh` body fetch never clobbers the last-known ledger (the PRS_LOOKUP_OK discipline).
#   • Nothing ungated → zero network: the ledger is cleared without a single gh/backend call.
#   • The leg NEVER writes the tracker (no backend op other than the read-only rich roster is invoked).
#
# Sources agent-watch.sh in lib mode (AGENT_WATCH_LIB=1 — helpers only, no polling loop, no console, no
# real network), pointing config discovery at a nonexistent file. NO_COLOR pins deterministic plain
# output.
# Run:  bash tests/test-team-presence.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../scripts/herd/agent-watch.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass(){ PASS=$((PASS+1)); }

[ -f "$WATCH" ] || fail "agent-watch.sh not found at $WATCH"
command -v python3 >/dev/null 2>&1 || fail "python3 required"

# ── Stub binaries on PATH ──────────────────────────────────────────────────────────────────────────
# `gh` is driven by $GH_MODE: bodies (the happy path), fail (a transient fetch failure), leak (any call
# is a bug — used to prove the zero-network paths).
BIN="$T/bin"; mkdir -p "$BIN"
cat > "$BIN/gh" <<'GH'
#!/usr/bin/env bash
case "${GH_MODE:-leak}" in
  bodies) cat "$GH_BODIES_FILE" ;;
  fail)   echo "gh: transient" >&2; exit 1 ;;
  *)      echo 'SENTINEL-NETWORK-LEAK'; exit 0 ;;
esac
GH
chmod +x "$BIN/gh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/git";   chmod +x "$BIN/git"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/herdr"; chmod +x "$BIN/herdr"
export PATH="$BIN:$PATH"
export GH_MODE=leak
export GH_BODIES_FILE="$T/bodies.json"

# ── A fake tracker backend exposing ONLY the read-only rich roster op ──────────────────────────────
# $ROSTER_FILE drives what it returns; ROSTER_MODE=norich models a backend (file/github/changelog) that
# never defines the OPTIONAL op, and ROSTER_MODE=down an unreachable/erroring tracker. A tracker WRITE
# from this leg would have to call one of the other _backend_* ops — none of which exist here, so any
# such attempt is a hard error rather than a silent mutation.
BACKENDS="$T/backends"; mkdir -p "$BACKENDS"
cat > "$BACKENDS/fake.sh" <<'BK'
#!/usr/bin/env bash
case "${ROSTER_MODE:-ok}" in
  norich) : ;;                                     # op simply not defined
  down)   _backend_list_open_rich() { echo "fake: tracker unreachable" >&2; return 1; } ;;
  *)      _backend_list_open_rich() { cat "$ROSTER_FILE"; } ;;
esac
BK
export SCRIBE_BACKEND_DIR="$BACKENDS"
export SCRIBE_BACKEND="fake"
export ROSTER_MODE=ok
export ROSTER_FILE="$T/roster.tsv"

# ── Source the watcher's helpers WITHOUT its live loop (lib mode), colors blanked ───────────────────
export AGENT_WATCH_LIB=1
export HERD_CONFIG_FILE="$T/no-such-config"
export WORKTREES_DIR="$T/trees"; mkdir -p "$WORKTREES_DIR"
export PROJECT_ROOT="$T/main"; mkdir -p "$PROJECT_ROOT/.herd"
export WORKSPACE_NAME="teampresencetest"
export WATCHER_OWNER="me-operator"
export NO_COLOR=1
export HERD_FAKE_NOW=1000000000
unset ORPHAN_PR_ROWS ADOPT_REMOTE_PRS TEAM_PRESENCE
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"
for fn in _team_presence_enabled _team_presence_load _team_presence_lookup \
          _team_presence_roster _team_presence_resolve _team_presence_scan; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined after sourcing"
done
[ -n "${TEAM_PRESENCE_LEDGER:-}" ] || fail "TEAM_PRESENCE_LEDGER not declared"
pass

# ── Shared fixtures ────────────────────────────────────────────────────────────────────────────────
# Three ungated PRs, exactly the "<epoch>\t<pr>\t<title>\t<branch>" shape _ungated_prs_scan writes.
UNGATED_ROWS="$(printf '%s\t101\tadd widget\tfeat/widget\n%s\t102\tfix leak\tfeat/herd-52-x\n%s\t103\tteam view\tfeat/herd-527-teammate\n' \
  "$HERD_FAKE_NOW" "$HERD_FAKE_NOW" "$HERD_FAKE_NOW")"
seed_ungated(){ printf '%s\n' "$UNGATED_ROWS" > "$UNGATED_PR_LEDGER"; }

# PR 101 declares its ref as a markdown HEADING — the HERD-522 decoration-tolerant parse must find it.
cat > "$GH_BODIES_FILE" <<'JSON'
[
  {"number":101,"body":"## Refs: HERD-500\n\nsome description"},
  {"number":102,"body":"no ref at all here"},
  {"number":103,"body":"Refs: <id>"}
]
JSON
# HERD-500 in progress + assigned · HERD-52 open (not started) · HERD-527 in progress + assigned ·
# HERD-901 in progress but UNASSIGNED.
printf '#HERD-500\tstarted\tIn Progress\tadd widget\tdesc\tAva Chen\thttps://x/500\n' > "$ROSTER_FILE"
printf '#HERD-52\tunstarted\tTodo\tfix leak\tdesc\tAva Chen\thttps://x/52\n'         >> "$ROSTER_FILE"
printf '#HERD-527\tstarted\tIn Progress\tteam view\tdesc\tBrian K\thttps://x/527\n'  >> "$ROSTER_FILE"
printf '#HERD-901\tstarted\tIn Progress\tunowned\tdesc\t\thttps://x/901\n'           >> "$ROSTER_FILE"

TODAY_ROW_101="🔓 #101 add widget feat/widget · ungated · no builder record · enable ADOPT_REMOTE_PRS or git worktree add to adopt"

# ── 1. DEFAULT IS OFF, and off is BYTE-IDENTICAL even with a populated ledger on disk ───────────────
seed_ungated
rm -f "$TEAM_PRESENCE_LEDGER"
build_ungated_prs
BASELINE="$UNGATED_PR_SECTION_ROWS"
[ -n "$BASELINE" ] || fail "the ungated section must render for the fixture"
grep -qF "$TODAY_ROW_101" <<< "$BASELINE" || fail "baseline row 101 not as expected: $BASELINE"

_team_presence_enabled && fail "TEAM_PRESENCE must default OFF"
# An attribution ledger left over from a previous ON run must be completely inert while off.
printf '101\tHERD-500\tAva Chen\n103\tHERD-527\tBrian K\n' > "$TEAM_PRESENCE_LEDGER"
UNGATED_PR_SECTION_ROWS=""
build_ungated_prs
[ "$UNGATED_PR_SECTION_ROWS" = "$BASELINE" ] \
  || fail "OFF must be byte-identical; got:$UNGATED_PR_SECTION_ROWS want:$BASELINE"
grep -q "building" <<< "$UNGATED_PR_SECTION_ROWS" && fail "no row may be attributed while OFF"
pass

# ── 2. The scan itself is byte-inert while OFF (no ledger write, no gh, no backend call) ────────────
rm -f "$TEAM_PRESENCE_LEDGER"
GH_MODE=leak _team_presence_scan || fail "_team_presence_scan must not error while off"
[ -e "$TEAM_PRESENCE_LEDGER" ] && fail "OFF must never create the presence ledger"
pass

# ── 3. ON: an in-progress + ASSIGNED item attributes the row and SUPPRESSES the adopt nudge ─────────
export TEAM_PRESENCE=on
_team_presence_enabled || fail "TEAM_PRESENCE=on must read as enabled"
seed_ungated
GH_MODE=bodies _team_presence_scan
[ -s "$TEAM_PRESENCE_LEDGER" ] || fail "an in-progress assigned item must produce an attribution row"
grep -q "^101	HERD-500	Ava Chen$" "$TEAM_PRESENCE_LEDGER" \
  || fail "PR 101 (## Refs: heading) must resolve via the shared HERD-522 parser: $(cat "$TEAM_PRESENCE_LEDGER")"
grep -q "^103	HERD-527	Brian K$" "$TEAM_PRESENCE_LEDGER" \
  || fail "PR 103 must resolve via the token-exact branch fallback: $(cat "$TEAM_PRESENCE_LEDGER")"
grep -q "^102	" "$TEAM_PRESENCE_LEDGER" \
  && fail "PR 102's item is NOT in progress — it must stay a plain ungated row"
pass

# ── 4. …and that is what the console actually renders ───────────────────────────────────────────────
UNGATED_PR_SECTION_ROWS=""
build_ungated_prs
grep -q "👤 #101 add widget · Ava Chen — building HERD-500" \
  <<< "$UNGATED_PR_SECTION_ROWS" || fail "row 101 not attributed: $UNGATED_PR_SECTION_ROWS"
grep -q "👤 #103 team view · Brian K — building HERD-527" \
  <<< "$UNGATED_PR_SECTION_ROWS" || fail "row 103 not attributed: $UNGATED_PR_SECTION_ROWS"
# The adopt nudge is gone from the attributed rows — but still present on the unattributed one.
grep -q "#101.*enable ADOPT_REMOTE_PRS" <<< "$UNGATED_PR_SECTION_ROWS" \
  && fail "the adopt nudge must be suppressed on an attributed row"
grep -q "#102 fix leak feat/herd-52-x · ungated · no builder record · enable ADOPT_REMOTE_PRS" \
  <<< "$UNGATED_PR_SECTION_ROWS" || fail "an unattributed row must keep today's wording verbatim"
grep -q "SENTINEL-NETWORK-LEAK" <<< "$UNGATED_PR_SECTION_ROWS" \
  && fail "the RENDER must never touch the network (the scan owns every fetch)"
pass

# ── 4b. HERD-663 TEAM_ALIASES overrides the attributed row's display name ──────────────────────────
export TEAM_ALIASES="Ava Chen=Ava,someoneelse=Someone Else"
UNGATED_PR_SECTION_ROWS=""
build_ungated_prs
grep -q "👤 #101 add widget · Ava — building HERD-500" <<< "$UNGATED_PR_SECTION_ROWS" \
  || fail "TEAM_ALIASES must override the attributed row's display name: $UNGATED_PR_SECTION_ROWS"
grep -q "👤 #103 team view · Brian K — building HERD-527" <<< "$UNGATED_PR_SECTION_ROWS" \
  || fail "a name with no TEAM_ALIASES entry must render unchanged: $UNGATED_PR_SECTION_ROWS"
unset TEAM_ALIASES
UNGATED_PR_SECTION_ROWS=""
build_ungated_prs
grep -q "👤 #101 add widget · Ava Chen — building HERD-500" <<< "$UNGATED_PR_SECTION_ROWS" \
  || fail "unsetting TEAM_ALIASES must revert to the tracker's own display name: $UNGATED_PR_SECTION_ROWS"
pass

# ── 5. In progress but UNASSIGNED attributes nothing ("someone" is not a name) ──────────────────────
printf '%s\t104\tunowned\tfeat/herd-901-x\n' "$HERD_FAKE_NOW" > "$UNGATED_PR_LEDGER"
GH_MODE=bodies _team_presence_scan
[ -s "$TEAM_PRESENCE_LEDGER" ] && fail "an UNASSIGNED in-progress item must not attribute: $(cat "$TEAM_PRESENCE_LEDGER")"
pass

# ── 6. The branch fallback is TOKEN-EXACT, never a prefix/substring match ───────────────────────────
# HERD-52 is not in progress, so the only in-progress candidate a sloppy substring matcher could pick
# for `feat/herd-52-x` is HERD-527 — it must not.
printf '%s\t102\tfix leak\tfeat/herd-52-x\n' "$HERD_FAKE_NOW" > "$UNGATED_PR_LEDGER"
GH_MODE=bodies _team_presence_scan
[ -s "$TEAM_PRESENCE_LEDGER" ] && fail "HERD-527 must not claim branch feat/herd-52-x: $(cat "$TEAM_PRESENCE_LEDGER")"
pass

# ── 7. A `Refs: <id>` PLACEHOLDER is not a ref, and a branch with no id resolves to nothing ─────────
printf '%s\t105\tplain\tfeat/nothing-here\n' "$HERD_FAKE_NOW" > "$UNGATED_PR_LEDGER"
GH_MODE=bodies _team_presence_scan
[ -s "$TEAM_PRESENCE_LEDGER" ] && fail "an unresolvable PR must attribute nothing"
pass

# ── 8. TRACKER DOWN → empty ledger → today's rows (fail-soft, never a red row) ──────────────────────
seed_ungated
GH_MODE=bodies _team_presence_scan     # prime a populated ledger first
[ -s "$TEAM_PRESENCE_LEDGER" ] || fail "precondition: the ledger should be populated here"
ROSTER_MODE=down GH_MODE=bodies _team_presence_scan
[ -s "$TEAM_PRESENCE_LEDGER" ] && fail "an unreachable tracker must clear the ledger, never keep stale attributions"
UNGATED_PR_SECTION_ROWS=""
build_ungated_prs
[ "$UNGATED_PR_SECTION_ROWS" = "$BASELINE" ] \
  || fail "tracker-down must fall back to today's rows exactly; got:$UNGATED_PR_SECTION_ROWS"
pass

# ── 9. A backend with NO rich roster op (file/github/changelog) is the same fail-soft path ──────────
seed_ungated
GH_MODE=bodies _team_presence_scan
[ -s "$TEAM_PRESENCE_LEDGER" ] || fail "precondition: the ledger should be populated here"
ROSTER_MODE=norich GH_MODE=bodies _team_presence_scan
[ -s "$TEAM_PRESENCE_LEDGER" ] && fail "a backend without _backend_list_open_rich must yield today's rows"
pass

# ── 10. A FAILED gh body fetch never clobbers the last-known ledger ─────────────────────────────────
seed_ungated
GH_MODE=bodies _team_presence_scan
grep -q "^101	HERD-500	Ava Chen$" "$TEAM_PRESENCE_LEDGER" || fail "precondition: 101 attributed"
GH_MODE=fail _team_presence_scan || fail "a failed fetch must not error"
grep -q "^101	HERD-500	Ava Chen$" "$TEAM_PRESENCE_LEDGER" \
  || fail "a transient gh failure must leave the last-known ledger intact"
pass

# ── 11. Nothing ungated → the ledger is cleared with ZERO network/tracker calls ─────────────────────
: > "$UNGATED_PR_LEDGER"
GH_MODE=leak ROSTER_MODE=down _team_presence_scan || fail "the no-ungated path must not error"
[ -s "$TEAM_PRESENCE_LEDGER" ] && fail "no ungated PRs → no attributions"
pass

# ── 12. _team_presence_resolve is PURE: same inputs, same rows, no files, no network ────────────────
ROSTER="$(cat "$ROSTER_FILE")"
BODIES="$(cat "$GH_BODIES_FILE")"
OUT1="$(GH_MODE=leak _team_presence_resolve "$UNGATED_ROWS" "$BODIES" "$ROSTER")"
OUT2="$(GH_MODE=leak _team_presence_resolve "$UNGATED_ROWS" "$BODIES" "$ROSTER")"
[ "$OUT1" = "$OUT2" ] || fail "the resolver must be deterministic"
[ "$OUT1" = "$(printf '101\tHERD-500\tAva Chen\n103\tHERD-527\tBrian K')" ] \
  || fail "unexpected resolver output: $OUT1"
# Malformed / empty inputs are fail-soft, never a crash.
_team_presence_resolve "$UNGATED_ROWS" 'not json' "$ROSTER" >/dev/null || fail "malformed bodies must not error"
[ -z "$(_team_presence_resolve "$UNGATED_ROWS" "$BODIES" '')" ] || fail "an empty roster must attribute nothing"
[ -z "$(_team_presence_resolve '' "$BODIES" "$ROSTER")" ] || fail "an empty ungated set must attribute nothing"
pass

echo "ok — $PASS team-presence assertions passed"
