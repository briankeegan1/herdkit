#!/usr/bin/env bash
# test-tab-discipline.sh — hermetic tests for the TAB DISCIPLINE invariant (HERD-569): only builder
# tabs, the scribe, the control room and the committed exemptions may exist in the workspace.
#
# Two shared legs, proven here without a herdr socket, a workspace or a model:
#   the CREATION LINT  scripts/herd/tab-create-lint.sh  — no NEW tab-create call site outside the
#                      builder-lane / scribe / control-room modules
#   the RECONCILED SWEEP scripts/herd/tab-discipline.sh — the observed tab bar is reconciled against
#                      the allowed set, and ALLOWED TABS ARE NEVER TOUCHED
#
# Proves — LINT:
#   (1)  The REAL tree is clean, and its exemption table is well-formed and non-stale.
#   (2)  MUTATION-PROVE: a tab create in a NON-allowed production module REDS.
#   (3)  The same call in an ALLOWED module (driver/herd-feature/herd-quick/scribe/coordinator/
#        bin/herd) is clean — the allow list is by role, not by luck.
#   (4)  The driver's create-tab SEAM is caught too (a tab create by another name).
#   (5)  SIM/TEST FIXTURES stay clean: the identical call under sim/ / experiment/ / tests/ is
#        classified, counted, never flagged (real tabs in DISPOSABLE workspaces are correct there).
#   (6)  PROSE is not mistaken for a call ("herdr is the multiplexer lanes drive (tab create, …)").
#   (7)  A `callsite` exemption row WITH a reason suppresses; a reason-less row reds EXEMPT-MALFORMED;
#        a row that excuses nothing reds STALE-EXEMPT (the ratchet cannot rot).
#   (8)  FAIL-SOFT: a tree with no engine surface → skip (exit 2), never a red.
#
# Proves — SWEEP:
#   (9)  MUTATION-PROVE THE ALLOWED SET: a registered builder tab, a live-worktree builder tab whose
#        registry row never landed, the scribe tab, the control-room tab, this watcher's own tab, an
#        exempted label, and ANOTHER WORKSPACE's tab are NEVER classified as strays.
#  (10)  A stray IS classified: an unregistered tab, and a registered tab whose kind is not `builder`.
#  (11)  REFUSALS, not guesses: no workspace id, no .herd-tabs registry, or unparseable tab JSON each
#        classify NOTHING — the inputs that could vaporise a live builder are hard stops.
#  (12)  MODE resolution is fail-safe: unset/typo/empty read `off`; on/report read themselves.
#  (13)  BYTE-IDENTICAL WHEN OFF: the sweep with TAB_DISCIPLINE unset makes ZERO herdr calls and
#        writes ZERO journal events.
#  (14)  ARMED: `on` closes exactly the strays, journals tab_discipline_retired with label+reason, and
#        prunes the stray's registry row — while every allowed tab is untouched.
#  (15)  `report` journals tab_discipline_stray and closes NOTHING.
#  (16)  The per-pass CAP bounds a runaway sweep and journals tab_discipline_capped.
#
# Proves — the REVIEW VIEWER conversion (herd-review.sh):
#  (17)  The headless viewer is PANE-FIRST: it splits into the builder's tab, only opens a standalone
#        tab when no builder tab was resolved, journals that fallback, and registers a registry row
#        ONLY for the standalone tab.
#
# Network-free, socket-free: temp dirs, fixtures and shell-function stubs only.
# Run:  bash tests/test-tab-discipline.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LINT="$ROOT/scripts/herd/tab-create-lint.sh"
SWEEP="$ROOT/scripts/herd/tab-discipline.sh"
EXEMPT="$ROOT/templates/tab-discipline-exempt.tsv"

[ -f "$LINT" ]  || { echo "FAIL: missing lint: $LINT" >&2; exit 1; }
[ -f "$SWEEP" ] || { echo "FAIL: missing sweep: $SWEEP" >&2; exit 1; }
# shellcheck source=/dev/null
. "$LINT"
# shellcheck source=/dev/null
. "$SWEEP"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { PASS=$((PASS+1)); }

# make_file <dir> <relpath> <body...> — write an engine-surface file with the given trailing lines.
make_file() {
  local d="$1" rel="$2"; shift 2
  mkdir -p "$d/$(dirname "$rel")"
  { printf '#!/usr/bin/env bash\n'; printf '%s\n' "$@"; } > "$d/$rel"
}

# The literal call under test, assembled at RUNTIME so this test file does not itself trip the lint
# it is exercising (tests/ is fixture-classified, but a test that only passes because of its own
# classification proves nothing about the grammar).
CALL="herdr tab"' '"create --label x --no-focus"
SEAM_CALL="herd_driver"'_create_tab --label x'

# ── 1. Real tree is clean ─────────────────────────────────────────────────────────────────────────
real_out="$(herd_tab_create_lint "$ROOT")"; real_rc=$?
if [ "$real_rc" -ne 0 ]; then
  grep -E '^(TAB-CREATE|EXEMPT-MALFORMED|STALE-EXEMPT)' <<< "$real_out" >&2
  fail "(1) real tree opens a tab outside the builder-lane/scribe/control-room modules, or its exemption table is malformed/stale"
fi
grep -q '^ADVISORY:' <<< "$real_out" || fail "(1) advisory summary line missing"
grep -qE 'ADVISORY:.*[1-9][0-9]* fixture file' <<< "$real_out" \
  || fail "(1) the real tree's sim/test fixtures must be scanned and counted, not silently unscanned"
grep -qE 'ADVISORY:.*[1-9][0-9]* excused' <<< "$real_out" \
  || fail "(1) the baseline exemption rows must be COUNTED, so the debt stays visible instead of fading into a bare 'clean'"
pass
echo "PASS (1) real tree: every tab create is in an allowed module or a reasoned exemption row"

# ── 2. Mutation-prove: an out-of-module tab create reds ───────────────────────────────────────────
TM="$T/mutate"
make_file "$TM" scripts/herd/probe.sh "$CALL"
out="$(herd_tab_create_lint "$TM")"; rc=$?
[ "$rc" -eq 1 ] || fail "(2) an out-of-module tab create must red (exit 1, got $rc): $out"
grep -q 'TAB-CREATE .*probe.sh:2: TAB opened outside' <<< "$out" \
  || fail "(2) expected a TAB-CREATE line naming probe.sh:2 (got: $out)"
pass
echo "PASS (2) mutation-prove: a NEW tab-create call site outside the allowed modules REDS"

# ── 3. The allowed modules are clean ──────────────────────────────────────────────────────────────
for mod in scripts/herd/driver.sh scripts/herd/herd-feature.sh scripts/herd/herd-quick.sh \
           scripts/herd/scribe.sh scripts/herd/coordinator.sh bin/herd; do
  TA="$T/allow-$(basename "$mod")"; rm -rf "$TA"
  mkdir -p "$TA/scripts/herd"
  make_file "$TA" "$mod" "$CALL"
  out="$(herd_tab_create_lint "$TA")"; rc=$?
  [ "$rc" -eq 0 ] || fail "(3) $mod owns an allowed tab's lifecycle and must stay clean (got rc=$rc): $out"
  grep -q '^TAB-CREATE' <<< "$out" && fail "(3) $mod should not be flagged: $out"
done
pass
echo "PASS (3) the builder-lane / scribe / control-room modules may open their own tabs"

# ── 4. The driver create-tab SEAM is caught ───────────────────────────────────────────────────────
TS="$T/seam"
make_file "$TS" scripts/herd/probe.sh "$SEAM_CALL"
out="$(herd_tab_create_lint "$TS")"; rc=$?
[ "$rc" -eq 1 ] || fail "(4) a call to the driver create-tab seam must red (got rc=$rc): $out"
grep -q 'TAB-CREATE .*probe.sh:2: driver tab-create SEAM' <<< "$out" \
  || fail "(4) expected the SEAM class (got: $out)"
pass
echo "PASS (4) the driver create-tab seam is a tab create by another name, and is caught"

# ── 5. Sim / experiment / test fixtures stay clean ────────────────────────────────────────────────
for fx in scripts/herd/sim/s.sh scripts/herd/experiment/e.sh tests/t.sh; do
  TF="$T/fx-$(echo "$fx" | tr '/.' '--')"; rm -rf "$TF"
  make_file "$TF" scripts/herd/plain.sh 'echo "a production file with no tab create"'
  make_file "$TF" "$fx" "$CALL"
  out="$(herd_tab_create_lint "$TF")"; rc=$?
  [ "$rc" -eq 0 ] || fail "(5) $fx is a DISPOSABLE-workspace fixture and must stay clean (got rc=$rc): $out"
  grep -qE 'ADVISORY:.*1 fixture file' <<< "$out" \
    || fail "(5) $fx must be SCANNED and counted as a fixture, not silently unscanned: $out"
done
pass
echo "PASS (5) sim/experiment/test fixtures are classified and counted, never flagged"

# ── 6. Prose is not a call ────────────────────────────────────────────────────────────────────────
TP="$T/prose"
make_file "$TP" scripts/herd/probe.sh \
  'echo "  herdr is the terminal/agent multiplexer that lanes drive (tab create, agent start)"' \
  'echo "The server rejects every socket command while these disagree (tab list/create, pane split)"'
out="$(herd_tab_create_lint "$TP")"; rc=$?
[ "$rc" -eq 0 ] || fail "(6) English prose naming the command must not read as a call (got rc=$rc): $out"
pass
echo "PASS (6) prose that merely names the command is not mistaken for a call site"

# ── 7. The exemption table: suppression, malformed, stale ─────────────────────────────────────────
TE="$T/exempt"
make_file "$TE" scripts/herd/probe.sh "$CALL"
mkdir -p "$TE/templates"
printf 'kind\tpattern\treason\n' > "$TE/templates/tab-discipline-exempt.tsv"
printf 'callsite\tscripts/herd/probe.sh\tdeliberate journaled fallback; retired when the pane split lands\n' \
  >> "$TE/templates/tab-discipline-exempt.tsv"
out="$(herd_tab_create_lint "$TE")"; rc=$?
[ "$rc" -eq 0 ] || fail "(7a) a reasoned callsite row must suppress the hit (got rc=$rc): $out"
grep -qE 'ADVISORY:.*1 excused' <<< "$out" || fail "(7a) the excused hit must be COUNTED: $out"

printf 'callsite\tscripts/herd/probe.sh\t\n' > "$TE/templates/tab-discipline-exempt.tsv"
out="$(herd_tab_create_lint "$TE")"; rc=$?
[ "$rc" -eq 1 ] || fail "(7b) a reason-less exemption row must red, not silently launder the finding (got rc=$rc)"
grep -q '^EXEMPT-MALFORMED scripts/herd/probe.sh' <<< "$out" || fail "(7b) expected EXEMPT-MALFORMED: $out"

printf 'callsite\tscripts/herd/nosuch.sh\tan exemption that excuses nothing\n' > "$TE/templates/tab-discipline-exempt.tsv"
out="$(herd_tab_create_lint "$TE")"; rc=$?
[ "$rc" -eq 1 ] || fail "(7c) a stale exemption row must red (got rc=$rc): $out"
grep -q '^STALE-EXEMPT scripts/herd/nosuch.sh' <<< "$out" || fail "(7c) expected STALE-EXEMPT: $out"
pass
echo "PASS (7) exemption rows suppress WITH a reason, red without one, and red when they excuse nothing"

# ── 8. Fail-soft outside an engine tree ───────────────────────────────────────────────────────────
TN="$T/notengine"; mkdir -p "$TN/src"
: > "$TN/src/app.py"
# Redirected, NOT captured in a command substitution: the skip REASON is set by the function, and a
# subshell would swallow it — the same trap the sibling guards' callers have to avoid.
herd_tab_create_lint "$TN" > "$T/skip.out"; rc=$?
out="$(cat "$T/skip.out")"
[ "$rc" -eq 2 ] || fail "(8) a consuming project must SKIP (exit 2), never red (got rc=$rc): $out"
[ -n "$HERD_TAB_CREATE_SKIP_REASON" ] || fail "(8) a skip must carry its reason"
pass
echo "PASS (8) fail-soft: a non-engine tree skips before a file is read"

# ══ THE SWEEP ═════════════════════════════════════════════════════════════════════════════════════

# A workspace where every ALLOWED shape is present at once, plus two strays.
W="$T/ws"; mkdir -p "$W/trees"
cat > "$W/tabs.json" <<'JSON'
{"result":{"tabs":[
 {"tab_id":"tb1","label":"registered-builder","workspace_id":"WS"},
 {"tab_id":"tb2","label":"unregistered-builder","workspace_id":"WS"},
 {"tab_id":"ts","label":"scribe-proj","workspace_id":"WS"},
 {"tab_id":"tc","label":"coordinator-proj","workspace_id":"WS"},
 {"tab_id":"tw","label":"watcher-host","workspace_id":"WS"},
 {"tab_id":"tx","label":"resolve·other","workspace_id":"WS"},
 {"tab_id":"tf","label":"foreign-project","workspace_id":"OTHERWS"},
 {"tab_id":"th","label":"health·registered-builder","workspace_id":"WS"},
 {"tab_id":"tz","label":"some-stray","workspace_id":"WS"}
]}}
JSON
# The registry knows the builder and the health tab; the SECOND builder's row never landed (the
# best-effort write herd-review.sh journals tab_registry_write_failed for), and it is spared by its
# live worktree instead.
printf 'registered-builder tb1 builder\nhealth·registered-builder th health\n' > "$W/trees/.herd-tabs"
mkdir -p "$W/trees/registered-builder" "$W/trees/unregistered-builder"

classify() {
  WS="${WS_OVERRIDE-WS}" REGISTRY="${REG_OVERRIDE-$W/trees/.herd-tabs}" \
  SCRIBE_LABEL=scribe-proj COORD_LABEL=coordinator-proj SELF_TAB=tw \
  LIVE_SLUGS="$(printf 'registered-builder\nunregistered-builder')" EXEMPT_FILE="$EXEMPT" \
    herd_tab_discipline_classify < "${JSON_OVERRIDE-$W/tabs.json}"
}

strays="$(classify)"

# ── 9. Mutation-prove: no allowed tab is ever selected ────────────────────────────────────────────
for keep in tb1 tb2 ts tc tw tx tf; do
  grep -q "^${keep}	" <<< "$strays" \
    && fail "(9) ALLOWED tab '$keep' was classified a stray — the sweep would close it: $strays"
done
pass
echo "PASS (9) builder (registered + live-worktree), scribe, control room, own tab, exempted label and another workspace's tab are NEVER strays"

# ── 10. …and the strays ARE selected ──────────────────────────────────────────────────────────────
grep -q '^th	health·registered-builder	kind:health$' <<< "$strays" \
  || fail "(10) a registered tab whose kind is not 'builder' must be a stray: $strays"
grep -q '^tz	some-stray	unregistered$' <<< "$strays" \
  || fail "(10) an unregistered tab must be a stray: $strays"
[ "$(grep -c . <<< "$strays")" -eq 2 ] || fail "(10) exactly two strays expected, got: $strays"
pass
echo "PASS (10) a non-builder registered tab and an unregistered tab are strays, with their reason"

# ── 11. Refusals, not guesses ─────────────────────────────────────────────────────────────────────
[ -z "$(WS_OVERRIDE="" classify)" ] \
  || fail "(11) an unresolvable workspace id must classify NOTHING (never sweep unscoped)"
[ -z "$(REG_OVERRIDE="$W/trees/.no-such-registry" classify)" ] \
  || fail "(11) an absent .herd-tabs must classify NOTHING (no way to tell a builder from a stray)"
printf 'not json at all\n' > "$W/garbage.json"
[ -z "$(JSON_OVERRIDE="$W/garbage.json" classify)" ] \
  || fail "(11) unparseable tab JSON must classify NOTHING"
pass
echo "PASS (11) missing workspace scope, missing registry and unreadable tab JSON are hard stops"

# ── 12. Mode resolution is fail-safe ──────────────────────────────────────────────────────────────
unset TAB_DISCIPLINE
[ "$(herd_tab_discipline_mode)" = off ] || fail "(12) unset must read off"
for v in "" "ON-ish" "yesss" "0" "no"; do
  [ "$(TAB_DISCIPLINE="$v" herd_tab_discipline_mode)" = off ] \
    || fail "(12) an unrecognized value ('$v') must read off — a typo can never arm a tab-closing path"
done
[ "$(TAB_DISCIPLINE=on herd_tab_discipline_mode)" = on ]         || fail "(12) on must read on"
[ "$(TAB_DISCIPLINE=report herd_tab_discipline_mode)" = report ] || fail "(12) report must read report"
pass
echo "PASS (12) mode resolution: unset/empty/typo read off; on and report read themselves"

# ── The armed sweep, against stubbed herdr + journal ──────────────────────────────────────────────
# Shell-function stubs: `command -v` finds them exactly as it finds the real binary, so the sweep runs
# its REAL code path with no socket. Every herdr invocation is recorded, so "byte-identical when off"
# is an assertion about the calls made, not about the output.
HERDR_LOG="$T/herdr.log"; JOURNAL_LOG="$T/journal.log"
TREES="$W/trees"; WORKTREES_DIR="$W/trees"
HERD_AGENT_SCRIBE=scribe-proj; HERD_TAB_COORDINATOR=coordinator-proj; HERD_WATCHER_TAB_ID=tw
herdr() {
  printf '%s\n' "$*" >> "$HERDR_LOG"
  case "$1 ${2:-}" in "tab list") cat "$W/tabs.json" ;; esac
}
journal_append() { printf '%s\n' "$*" >> "$JOURNAL_LOG"; }
herd_resolve_workspace_id() { printf 'WS'; }
# A faithful stand-in for agent-watch.sh's registry prune (the sweep calls it only when it exists, so
# without this the prune leg would go unexercised rather than fail).
_herd_tabs_drop_row() {
  local reg="$1" tid="$2" keep=""
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in *" $tid "*) continue ;; esac
    keep="${keep}${line}"$'\n'
  done < "$reg"
  printf '%s' "$keep" > "$reg"
}
herd_tab_discipline_exempt_file() { printf '%s' "$EXEMPT"; }

# ── 13. Byte-identical when off ───────────────────────────────────────────────────────────────────
: > "$HERDR_LOG"; : > "$JOURNAL_LOG"
reg_before="$(cat "$W/trees/.herd-tabs")"
unset TAB_DISCIPLINE
herd_tab_discipline_sweep || fail "(13) the off path must succeed"
[ ! -s "$HERDR_LOG" ]   || fail "(13) TAB_DISCIPLINE off made a herdr call: $(cat "$HERDR_LOG")"
[ ! -s "$JOURNAL_LOG" ] || fail "(13) TAB_DISCIPLINE off journaled: $(cat "$JOURNAL_LOG")"
[ "$(cat "$W/trees/.herd-tabs")" = "$reg_before" ] || fail "(13) TAB_DISCIPLINE off touched the registry"
pass
echo "PASS (13) ship-dormant: off is a HARD no-op — zero herdr calls, zero journal events"

# ── 14. Armed: exactly the strays are retired, allowed tabs untouched ─────────────────────────────
: > "$HERDR_LOG"; : > "$JOURNAL_LOG"
TAB_DISCIPLINE=on herd_tab_discipline_sweep || fail "(14) the armed sweep must succeed"
grep -q '^tab close th$' "$HERDR_LOG" || fail "(14) the health· stray was not closed: $(cat "$HERDR_LOG")"
grep -q '^tab close tz$' "$HERDR_LOG" || fail "(14) the unregistered stray was not closed: $(cat "$HERDR_LOG")"
for keep in tb1 tb2 ts tc tw tx tf; do
  grep -q "^tab close ${keep}\$" "$HERDR_LOG" \
    && fail "(14) an ALLOWED tab ($keep) was closed — the invariant's whole point is that it is not"
done
[ "$(grep -c '^tab close ' "$HERDR_LOG")" -eq 2 ] || fail "(14) exactly two closes expected: $(cat "$HERDR_LOG")"
grep -q 'tab_discipline_retired .*label health·registered-builder reason kind:health' "$JOURNAL_LOG" \
  || fail "(14) the retirement must journal its label AND why: $(cat "$JOURNAL_LOG")"
grep -q 'tab_discipline_retired .*label some-stray reason unregistered' "$JOURNAL_LOG" \
  || fail "(14) the unregistered retirement must journal its label AND why: $(cat "$JOURNAL_LOG")"
grep -q ' th ' "$W/trees/.herd-tabs" \
  && fail "(14) the retired stray's registry row must be pruned, or it outlives its tab and inflates the stale-tab tally"
grep -q '^registered-builder tb1 builder$' "$W/trees/.herd-tabs" \
  || fail "(14) the prune must leave every OTHER registry row byte-identical"
pass
echo "PASS (14) armed: exactly the strays close, each journaled with label + reason; every allowed tab survives"

# ── 15. report detects and journals, closes nothing ───────────────────────────────────────────────
: > "$HERDR_LOG"; : > "$JOURNAL_LOG"
TAB_DISCIPLINE=report herd_tab_discipline_sweep || fail "(15) the report sweep must succeed"
grep -q '^tab close ' "$HERDR_LOG" && fail "(15) report mode must close NOTHING: $(cat "$HERDR_LOG")"
[ "$(grep -c 'tab_discipline_stray ' "$JOURNAL_LOG")" -eq 2 ] \
  || fail "(15) report mode must journal every stray it found: $(cat "$JOURNAL_LOG")"
pass
echo "PASS (15) report mode journals what it WOULD retire and closes nothing"

# ── 16. The per-pass cap bounds a runaway sweep ───────────────────────────────────────────────────
: > "$HERDR_LOG"; : > "$JOURNAL_LOG"
TAB_DISCIPLINE=on HERD_TAB_DISCIPLINE_MAX=1 herd_tab_discipline_sweep || fail "(16) the capped sweep must succeed"
[ "$(grep -c '^tab close ' "$HERDR_LOG")" -eq 1 ] \
  || fail "(16) the cap must bound the closes in one pass: $(cat "$HERDR_LOG")"
grep -q 'tab_discipline_capped found 2 retired 1 cap 1' "$JOURNAL_LOG" \
  || fail "(16) a capped pass must say so, loudly: $(cat "$JOURNAL_LOG")"
pass
echo "PASS (16) a runaway sweep is capped per pass and journals the deferral"

unset -f herdr journal_append herd_resolve_workspace_id herd_tab_discipline_exempt_file

# ── 17. The review viewer is pane-first, tab-fallback-only ────────────────────────────────────────
# A structural proof of the HERD-569 conversion in herd-review.sh: the placement block must SPLIT into
# the builder's tab, reach the standalone tab create ONLY when that produced no pane, journal the
# fallback, and register a registry row ONLY for a standalone tab. (The live placement itself is
# exercised against REAL panes by the P2b real-panes scenario's reviewsplit leg.)
RV="$ROOT/scripts/herd/herd-review.sh"
rv_block="$(awk '/^  if \[ "\$_AGENT_PANE_MODE" = "0" \]; then$/,/^  fi$/' "$RV")"
[ -n "$rv_block" ] || fail "(17) could not locate the viewer-placement block in herd-review.sh"
grep -q 'herdr pane split' <<< "$rv_block" \
  || fail "(17) the viewer must SPLIT into the builder's tab — that is the whole conversion"
split_line="$(grep -n 'herdr pane split' <<< "$rv_block" | head -1 | cut -d: -f1)"          # pipe-ok: one short block through head/cut in a command substitution
create_line="$(grep -n 'tab create' <<< "$rv_block" | head -1 | cut -d: -f1)"                # pipe-ok: same
[ -n "$split_line" ] && [ -n "$create_line" ] || fail "(17) expected both a split and a tab-create in the block"
[ "$split_line" -lt "$create_line" ] \
  || fail "(17) the split must be attempted BEFORE the tab create — pane-first, tab-fallback-only"
grep -q 'if \[ -z "${ROOT:-}" \]; then' <<< "$rv_block" \
  || fail "(17) the standalone tab must be guarded on the split having produced no pane"
grep -q 'journal_append review_viewer_tab_fallback' <<< "$rv_block" \
  || fail "(17) the fallback must journal its reason so it stays visible and diagnosable"
grep -q '\[ "\$_VIEW_SPLIT" = "0" \]' <<< "$rv_block" \
  || fail "(17) only a STANDALONE tab may get a .herd-tabs row — registering the builder's tab would hand the orphan sweep a licence to close it"
pass
echo "PASS (17) the headless review viewer splits into the builder's tab and only falls back to a tab when it is gone"

echo
echo "ALL ${PASS} TAB-DISCIPLINE CHECKS PASSED"
