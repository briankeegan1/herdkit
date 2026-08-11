#!/usr/bin/env bash
# test-queue-plan-surface.sh — HERD-642 (Phase 5 of HERD-625, the final phase): the candidate list as a
# first-class surface. Two legs, proven here against the shipped code:
#
#   (a) GENERATION PUBLISH / SUPERSEDE as a coordinator command — `herd queue plan` publishes the whole
#       priority-ordered candidate list and retires the previous generation ATOMICALLY.
#   (b) THE "planned work" CONSOLE SECTION — the watch pane renders that plan through the shared
#       bounded-section helper, and renders NOTHING when there is no plan.
#
# Cases:
#   (1) GENERATION POLICY   iq_generation / iq_gen_of / iq_gen_superseded: an UNSTAMPED intent is always
#                           live (that is what keeps every ad-hoc spawn.sh enqueue unaffected), a stamped
#                           one is live only while the pointer names its generation.
#   (2) ATOMIC SWAP         the whole point of §4.4. With generation A live and B staged, the drain set
#                           holds EXACTLY A; after ONE pointer rename it holds EXACTLY B. Never both,
#                           never neither — asserted over iq_order AND over a real iq_claim, plus a
#                           source assertion that the swap IS a single rename (no copy window).
#   (3) RETIRE              iq_gen_retire drops the superseded generation's PENDING intents and their
#                           sidecars, leaves the live generation alone, and never touches a CLAIMED
#                           intent (a claim means a lane is already launching — doc §4.4 level 2).
#   (4) PLAN ROWS           iq_plan_rows — the ONE reader behind both surfaces: drain order, priority
#                           band, ref, and the blocker column (after= / ttl). Empty when no plan is live.
#   (5) CONSOLE SECTION     build_queue_plan (extracted from agent-watch.sh) renders the plan from a
#                           FIXTURE QUEUE, top candidate FIRST, and is EMPTY — so render() omits the
#                           section and the console is byte-identical — with no plan published, with the
#                           INTENT_QUEUE lever off, and once the queue drains. Calm retention applies.
#   (6) THE COMMAND         the real `herd queue plan` / `herd queue list`, end to end: it validates
#                           before publishing (a bad line changes NOTHING), stamps bands in line order,
#                           supersedes the previous generation in one call, and lists what is pending.
#   (7) MUTATION-PROOF      make the pointer swap a no-op and (2) MUST go red. An atomicity assertion
#                           that passes over a queue where nothing was superseded asserts nothing.
#
# Hermetic: temp dirs only. No network, no herdr, no lanes, no live watcher. The library is sourced from
# the repo, the console section is EXTRACTED from agent-watch.sh (sed), the INTENT_QUEUE resolver is
# extracted VERBATIM from the real herd-config.sh, and `herd queue` is the real bin/herd — so every
# assertion is against shipped code, never a copy that can go stale.
#
# Run:  bash tests/test-queue-plan-surface.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
LIB="$REPO/scripts/herd/intent-queue.sh"
WATCH="$REPO/scripts/herd/agent-watch.sh"
CONSOLE="$REPO/scripts/herd/console-section.sh"
CONFIG="$REPO/scripts/herd/herd-config.sh"
SPAWN="$REPO/scripts/herd/spawn.sh"
HERD_BIN="$REPO/bin/herd"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass(){ PASS=$((PASS+1)); }

for f in "$LIB" "$WATCH" "$CONSOLE" "$CONFIG" "$SPAWN" "$HERD_BIN"; do
  [ -f "$f" ] || fail "missing engine file: $f"
done

# The REAL lever resolver, extracted verbatim — iq_lever_on delegates to it, so the truthiness under
# test is the shipped rule and not a copy that can drift.
LEVER="$T/lever.sh"
sed -n '/^herd_intent_queue_on()/,/^}/p' "$CONFIG" > "$LEVER"
grep -q '^herd_intent_queue_on()' "$LEVER" || fail "could not extract herd_intent_queue_on from herd-config.sh"

# shellcheck source=/dev/null
. "$LEVER"
# shellcheck source=/dev/null
. "$CONSOLE"
# shellcheck source=/dev/null
. "$LIB"

Q="$T/q"; mkdir -p "$Q"
reset_q(){ rm -rf "$Q"; mkdir -p "$Q"; }
export INTENT_QUEUE=on

# plant <id> <slug> <lane> [gen] [prio] [ref] [after] — a pending intent in the spawn tenant's frozen
# positional payload shape (line 1 slug, line 2 lane, line 3+ task).
plant() {
  local id="$1" slug="$2" lane="$3" gen="${4:-}" prio="${5:-}" ref="${6:-}" after="${7:-}"
  printf '%s\n%s\ntask for %s\n' "$slug" "$lane" "$slug" > "$Q/$id.req"
  [ -n "$gen" ]   && printf '%s\n' "$gen"   > "$Q/$id.gen"
  [ -n "$prio" ]  && printf '%s\n' "$prio"  > "$Q/$id.prio"
  [ -n "$ref" ]   && printf '%s\n' "$ref"   > "$Q/$id.ref"
  [ -n "$after" ] && printf '%s\n' "$after" > "$Q/$id.after"
  return 0
}
order_ids(){ iq_order "$Q" | while IFS= read -r p; do iq_id_of "$p"; printf '\n'; done; }

# ── (1) GENERATION POLICY ────────────────────────────────────────────────────────────────────────
reset_q
plant 1-0000000001-1 unstamped quick
plant 1-0000000002-1 stamped-a quick genA
[ -z "$(iq_generation "$Q")" ] || fail "(1) a queue with no pointer must report NO live generation"
[ "$(iq_gen_of "$Q" 1-0000000002-1)" = "genA" ] || fail "(1) iq_gen_of did not read the .gen sidecar"
[ -z "$(iq_gen_of "$Q" 1-0000000001-1)" ]       || fail "(1) an unstamped intent must report no generation"
iq_gen_superseded "$Q" 1-0000000001-1 && fail "(1) an UNSTAMPED intent must never read as superseded — every ad-hoc spawn.sh enqueue is one"
iq_gen_superseded "$Q" 1-0000000002-1 || fail "(1) a stamped intent with NO live pointer must read as superseded"
iq_gen_publish "$Q" genA || fail "(1) iq_gen_publish failed"
[ "$(iq_generation "$Q")" = "genA" ] || fail "(1) the pointer does not name the published generation"
iq_gen_superseded "$Q" 1-0000000002-1 && fail "(1) the LIVE generation's intent must not read as superseded"
iq_gen_superseded "$Q" 1-0000000001-1 && fail "(1) publishing a generation must not retire UNSTAMPED intents"
ls "$Q"/.tmp.* >/dev/null 2>&1 && fail "(1) a temp file leaked out of the atomic pointer swap"
pass

# ── (2) ATOMIC SWAP — exactly one generation is live at every instant ────────────────────────────
# Generation A is live and draining; generation B is fully STAGED (its intents on disk, stamped, with
# their bands) but not yet pointed at. This is precisely the window `herd queue plan` opens between
# enqueueing the new plan and flipping the pointer, and nothing of B may be claimable inside it.
stage_two_generations() {
  reset_q
  plant 1-0000000001-1 a-first  quick genA 10
  plant 1-0000000002-1 a-second quick genA 20
  plant 2-0000000001-1 b-first  quick genB 10
  plant 2-0000000002-1 b-second quick genB 20
  iq_gen_publish "$Q" genA || fail "(2) could not publish generation A"
}
stage_two_generations
[ "$(order_ids)" = "1-0000000001-1
1-0000000002-1" ] || fail "(2) with A live and B staged the drain set must be EXACTLY A (got: $(order_ids | tr '\n' ' '))"
claimed="$(iq_claim "$Q")" || fail "(2) A's top candidate was not claimable"
[ "$(iq_id_of "$claimed")" = "1-0000000001-1" ] || fail "(2) the claim ignored A's priority order"
iq_release "$claimed"

# THE SWAP. One pointer rename, and the drain set must invert completely: nothing of A, all of B.
iq_gen_publish "$Q" genB || fail "(2) could not publish generation B"
[ "$(order_ids)" = "2-0000000001-1
2-0000000002-1" ] || fail "(2) after the swap the drain set must be EXACTLY B (got: $(order_ids | tr '\n' ' '))"
claimed="$(iq_claim "$Q")" || fail "(2) B's top candidate was not claimable after the swap"
[ "$(iq_id_of "$claimed")" = "2-0000000001-1" ] || fail "(2) the post-swap claim served a superseded intent ($(iq_id_of "$claimed"))"
iq_release "$claimed"
# …and NEITHER-live is impossible too: the pointer is replaced, never emptied first.
[ -n "$(iq_generation "$Q")" ] || fail "(2) the swap left NO live generation — a window where nothing drains"
pass

# The atomicity argument itself is a property of the SOURCE, not of any schedulable interleaving: no
# black-box test can catch a write-then-move that is only briefly torn. Assert the mechanism — the
# pointer is built in a temp file inside the queue dir and moved into place in ONE rename, exactly the
# shape tests/test-intent-queue-lib.sh case (8) asserts for iq_release's touch-before-rename.
python3 - "$LIB" <<'ATOMIC' || fail "(2) iq_gen_publish must write a temp file in the queue dir and install it with ONE mv — anything else has a window where the plan is half-published"
import re, sys
body = re.search(r'^iq_gen_publish\(\) \{(.*?)^\}', open(sys.argv[1]).read(), re.S | re.M).group(1)
i_tmp = body.find('mktemp "$_iqgp_q/')
i_wr  = body.find('> "$_iqgp_tmp"')
i_mv  = body.find('mv "$_iqgp_tmp"')
if min(i_tmp, i_wr, i_mv) < 0:
    sys.exit("iq_gen_publish is missing the mktemp-in-qdir / write / mv shape")
if not (i_tmp < i_wr < i_mv):
    sys.exit("iq_gen_publish's steps are out of order: mktemp %d, write %d, mv %d" % (i_tmp, i_wr, i_mv))
if re.search(r'>\s*"\$\(iq_gen_pointer', body) or re.search(r'\bcp\b', body):
    sys.exit("iq_gen_publish writes the pointer in place (or copies it) — that has a torn-read window")
ATOMIC
pass

# ── (3) RETIRE — the superseded generation's PENDING intents, and nothing else ───────────────────
stage_two_generations
iq_gen_publish "$Q" genB || fail "(3) could not publish generation B"
[ "$(iq_gen_retire "$Q")" = "2" ] || fail "(3) iq_gen_retire must report the two superseded intents it dropped"
[ -e "$Q/1-0000000001-1.req" ] && fail "(3) a superseded intent survived the retire"
[ -e "$Q/1-0000000001-1.prio" ] && fail "(3) a superseded intent's sidecar survived the retire"
[ -f "$Q/2-0000000001-1.req" ] || fail "(3) the LIVE generation was retired — the plan would be gone"
[ -f "$Q/2-0000000001-1.gen" ] || fail "(3) the live generation's stamp was dropped"
ls "$Q"/*.retiring >/dev/null 2>&1 && fail "(3) the retire left a .retiring corpse in the queue"

# A CLAIMED intent of the superseded generation is a lane that is ALREADY LAUNCHING. Retiring it would
# GC the sidecars out from under a live worker; doc §4.4 level 2 says that is countermanded through the
# builder, never by editing the queue underneath it.
reset_q
plant 1-0000000001-1 launching quick genA 10 HERD-1
iq_gen_publish "$Q" genA || fail "(3) could not publish generation A"
claimed="$(iq_claim "$Q")" || fail "(3) precondition: the intent must be claimable"
iq_own "$claimed" $$
iq_gen_publish "$Q" genB || fail "(3) could not publish generation B"
[ "$(iq_gen_retire "$Q")" = "0" ] || fail "(3) a CLAIMED intent must not be retired by a supersede"
[ -f "$claimed" ] || fail "(3) the retire destroyed a live claim"
[ -f "$Q/1-0000000001-1.ref" ] || fail "(3) the retire GC'd a live claim's sidecar — the worker loses its ref"

# The assertion above only covers an intent claimed BEFORE the retire walks. The dangerous case is the
# claim landing between the glob and the removal: `rm -f` reports success on a path a drain has just
# renamed to .req.mine, and the sidecar GC that follows would then run against a LIVE claim. No
# black-box test can schedule that interleaving (same limitation tests/test-intent-queue-lib.sh case (8)
# names for release's touch-before-rename), so assert the MECHANISM in the source: claim the file by
# rename first, and only GC when that rename won.
# …and the claimed-at-publish-time intent still gets a path OUT. Once the drain RELEASES it (a
# dependency hold is released back to .req at end-of-tick), the next retire pass sweeps it — otherwise
# it would sit in the queue forever, unclaimable but still painting a "spawn holds ⏳ waiting" row for
# work no plan asks for. The watcher runs exactly this pass every tick for exactly this case.
iq_release "$claimed"
[ -f "$Q/1-0000000001-1.req" ] || fail "(3) precondition: the released intent should be pending again"
[ "$(iq_gen_retire "$Q")" = "1" ] || fail "(3) a RELEASED superseded intent must be retired by the next pass — it can never drain again, so it needs a path out"
[ -e "$Q/1-0000000001-1.req" ] && fail "(3) the released superseded intent survived the sweep"
# The watcher must actually run that pass; a repair nothing calls is not a repair.
grep -q 'iq_gen_retire "\$_dsq_q"' "$WATCH" \
  || fail "(3) agent-watch.sh's _drain_spawn_queue does not sweep superseded intents each tick"

python3 - "$LIB" <<'RETIRE' || fail "(3) iq_gen_retire must claim each superseded intent by RENAME before removing it and its sidecars — a bare rm races a concurrent claim and GCs a live worker's sidecars"
import re, sys
body = re.search(r'^iq_gen_retire\(\) \{(.*?)^\}', open(sys.argv[1]).read(), re.S | re.M).group(1)
i_mv = body.find('mv "$_iqgr_f"')
i_sc = body.find('iq_sidecars_rm')
if i_mv < 0:
    sys.exit("iq_gen_retire does not rename the intent it is retiring")
if i_sc < 0 or i_sc < i_mv:
    sys.exit("iq_gen_retire GCs sidecars without having won the rename first")
if re.search(r'rm -f "\$_iqgr_f"(?!\.)', body):
    sys.exit("iq_gen_retire removes the globbed .req path directly — that is the race")
RETIRE
pass

# ── (4) PLAN ROWS — the one reader behind both surfaces ──────────────────────────────────────────
NOW=2000000000
reset_q
[ -z "$(iq_plan_rows "$Q")" ] || fail "(4) an EMPTY queue must yield no plan rows"
plant "$((NOW - 10))-0000000002-1" second feature genA 20 HERD-2
plant "$((NOW - 10))-0000000001-1" first  quick   genA 10 HERD-1
plant "$((NOW - 10))-0000000003-1" third  feature genA 30 HERD-3 "#41"
plant "$((NOW - 10))-0000000004-1" alien  quick   genOLD 5 HERD-4
[ -z "$(iq_plan_rows "$Q")" ] \
  || fail "(4) with NO generation published there must be no plan — this is what keeps the console byte-identical"
iq_gen_publish "$Q" genA || fail "(4) could not publish generation A"
rows="$(iq_plan_rows "$Q" 0 "$NOW")"
[ "$(printf '%s\n' "$rows" | grep -c .)" = "3" ] \
  || fail "(4) the plan must hold exactly the LIVE generation's three candidates (got: $rows)"
[ "$(printf '%s\n' "$rows" | cut -f4 | tr '\n' ' ')" = "first second third " ] \
  || fail "(4) plan rows must be in DRAIN order (got: $(printf '%s\n' "$rows" | cut -f4 | tr '\n' ' '))"
grep -q $'\tfirst\tquick\tHERD-1\t$' <<< "$(printf '%s\n' "$rows" | sed -n 1p)" \
  || fail "(4) the top row must carry slug/lane/ref and an EMPTY blocker (got: $(sed -n 1p <<< "$rows"))"
[ "$(printf '%s\n' "$rows" | sed -n 1p | cut -f3)" = "10" ] || fail "(4) the plan row lost its priority band"
[ "$(printf '%s\n' "$rows" | sed -n 3p | cut -f7)" = "after=#41" ] \
  || fail "(4) a dependency-held candidate must name its blocker (got: $(printf '%s\n' "$rows" | sed -n 3p | cut -f7))"
# TTL: the same queue read with a TTL the candidates are past marks them as the drain will treat them —
# escalated, not launched. The blocker column is what the queue KNOWS, never a guess.
[ "$(iq_plan_rows "$Q" 5 "$NOW" | sed -n 1p | cut -f7)" = "ttl" ] \
  || fail "(4) a candidate past the TTL must be marked ttl (the drain will escalate it, not launch it)"

# THE BYTE-IDENTICAL GUARANTEE, in the reader itself: a pool that has only ever seen ad-hoc `spawn.sh`
# enqueues — pending intents, NO stamps, NO pointer — has no PLAN, however full its queue is. Without
# this the section would appear on every project with a busy spawn queue, which is exactly the
# console-changed-for-everyone regression this phase must not ship.
QADHOC="$T/qadhoc"; mkdir -p "$QADHOC"
plant_in(){ local d="$1" id="$2" slug="$3"; printf '%s\nquick\ntask\n' "$slug" > "$d/$id.req"; }
plant_in "$QADHOC" "$((NOW - 10))-0000000007-1" adhoc-one
plant_in "$QADHOC" "$((NOW - 10))-0000000008-1" adhoc-two
[ "$(iq_order "$QADHOC" | grep -c .)" = "2" ] || fail "(4) precondition: both ad-hoc intents must be in the drain set"
[ -z "$(iq_plan_rows "$QADHOC" 0 "$NOW")" ] \
  || fail "(4) unstamped ad-hoc intents must NOT read as a published plan (got: $(iq_plan_rows "$QADHOC" 0 "$NOW"))"
pass

# ── (5) CONSOLE SECTION — rendered from a fixture queue, omitted when there is no plan ───────────
# The section function is EXTRACTED from agent-watch.sh, so the code under test is the shipped renderer.
SECT_SRC="$T/section.sh"
: > "$SECT_SRC"
for fn in _queue_plan_row build_queue_plan; do
  sed -n "/^$fn()/,/^}/p" "$WATCH" >> "$SECT_SRC"
  grep -q "^$fn()" "$SECT_SRC" || fail "(5) could not extract $fn from agent-watch.sh"
done
mkdir -p "$T/trees/spawn-queue"
cat > "$T/harness.sh" <<HARNESS
TREES="$T/trees"
QUEUE_PLAN_LEDGER="$T/trees/.agent-watch-queue-plan"
INTENT_TTL=0
C_RED=""; C_RESET=""; C_DIM=""; C_BOLD=""; C_YELLOW=""
_now_epoch(){ printf '%s' "\${HERD_FAKE_NOW:-$NOW}"; }
epoch_to_hhmm(){ printf '11:11'; }
_slug_cell(){ printf '%s' "\$1"; }
. "$LEVER"
. "$CONSOLE"
. "$LIB"
. "$SECT_SRC"
HARNESS
PQ="$T/trees/spawn-queue"
LEDGER="$T/trees/.agent-watch-queue-plan"
section(){ ( . "$T/harness.sh"; "$@" >/dev/null 2>&1; build_queue_plan; printf '%s' "$QUEUE_PLAN_ROWS" ); }

# (5a) NO PLAN → no section, and no derived ledger either — even with a BUSY queue. The fixture carries
# an unstamped ad-hoc intent alongside the (unpointed-at) plan candidates precisely because that is the
# shape of every project that never published a plan: the watch frame must stay byte-identical there.
cp "$Q"/*.req "$Q"/*.gen "$Q"/*.prio "$Q"/*.ref "$Q"/*.after "$PQ"/ 2>/dev/null || true
cp "$QADHOC"/*.req "$PQ"/ 2>/dev/null || true
rm -f "$PQ/.gen"
out="$(INTENT_QUEUE=on section true)"
[ -z "$out" ] || fail "(5a) a queue with no published plan must render NO section (got: $out)"
[ -e "$LEDGER" ] && fail "(5a) the derived ledger must not exist when there is no plan"
pass

# (5b) PLAN LIVE → the section renders, TOP CANDIDATE FIRST, naming priority, lane, ref and blocker.
# The ad-hoc unstamped intent from (5a) is still in this fixture queue and MUST appear too, in its own
# default band, behind the plan: it is a pending candidate this pool will really drain, and a section
# that showed only the stamped ones would be a pane telling a second seat something untrue by omission.
printf 'genA\n' > "$PQ/.gen"
out="$(INTENT_QUEUE=on section true)"
grep -q "next-up" <<< "$out" || fail "(5b) the plan did not render a next-up row (got: $out)"
[ "$(printf '%s\n' "$out" | grep -c 'next-up')" = "5" ] \
  || fail "(5b) the section must render every pending candidate — 3 planned + the 2 ad-hoc ones (got: $out)"
grep -q 'adhoc-one' <<< "$out" \
  || fail "(5b) an ad-hoc pending intent must still appear once a plan is live (the pane must not omit work it will drain)"
[ "$(printf '%s\n' "$out" | sed -n 1p | grep -c 'first')" = "1" ] \
  || fail "(5b) the section must lead with the TOP candidate, not the last (got: $(printf '%s\n' "$out" | sed -n 1p))"
[ "$(printf '%s\n' "$out" | sed -n 4p | grep -c 'adhoc-one')" = "1" ] \
  || fail "(5b) the unbanded ad-hoc candidate must sort BEHIND the published plan (got: $(printf '%s\n' "$out" | sed -n 4p))"
grep -q 'p10' <<< "$out"    || fail "(5b) the row does not name the priority band"
grep -q 'HERD-1' <<< "$out" || fail "(5b) the row does not name the tracker ref"
grep -q 'after #41' <<< "$out" || fail "(5b) a dependency-held candidate must show its blocker on the pane"
[ -s "$LEDGER" ] || fail "(5b) the derived ledger was not written"
# BOUNDED, like every other console section: a long plan shows its TOP candidates and stops. A section
# that grew with the queue is the "operator learns to ignore it" failure console-section.sh exists for.
plant_in "$PQ" "$((NOW - 10))-0000000009-1" adhoc-three
out_capped="$(INTENT_QUEUE=on section true)"
[ "$(printf '%s\n' "$out_capped" | grep -c 'next-up')" = "5" ] \
  || fail "(5b) the section must stay bounded at 5 rows however long the plan is (got: $out_capped)"
grep -q 'first' <<< "$out_capped" || fail "(5b) the bound must keep the TOP candidates, not the tail"
grep -q 'adhoc-three' <<< "$out_capped" && fail "(5b) the bound dropped the wrong end of the plan"
rm -f "$PQ/$((NOW - 10))-0000000009-1.req"
pass

# (5c) LEVER OFF → byte-identical console: no section, and the derived ledger is REMOVED (a plan
# published before the lever was disarmed must not keep painting a plan the FIFO drain does not follow).
out_off="$( unset INTENT_QUEUE; section true )"
[ -z "$out_off" ] || fail "(5c) with INTENT_QUEUE off the section must be EMPTY (got: $out_off)"
[ -e "$LEDGER" ] && fail "(5c) the derived ledger survived the lever going off"
pass

# (5d) DRAINED → the section clears itself on the next tick (it is derived from live queue state, not an
# event log): the plan's last candidate leaving the queue leaves no row and no ledger behind.
out="$(INTENT_QUEUE=on section true)"
[ -n "$out" ] || fail "(5d) precondition: the section should render before the queue drains"
rm -f "$PQ"/*.req
out="$(INTENT_QUEUE=on section true)"
[ -z "$out" ] || fail "(5d) a fully drained plan must leave NO rows on the console (got: $out)"
[ -e "$LEDGER" ] && fail "(5d) the derived ledger outlived the plan it described"
pass

# (5e) CALM RETENTION — a plan nobody re-published ages off the display like every other calm row,
# through the SHARED classifier (herd_console_classify_queue_plan), not a private rule.
printf 'genA\n' > "$PQ/.gen"
cp "$Q"/*.req "$Q"/*.gen "$Q"/*.prio "$Q"/*.ref "$PQ"/ 2>/dev/null || true
out_now="$(INTENT_QUEUE=on section true)"
[ -n "$out_now" ] || fail "(5e) precondition: the fresh plan must render"
out_old="$( . "$T/harness.sh"; HERD_FAKE_NOW=$(( NOW + 100000 )) build_queue_plan
            printf '%s' "$QUEUE_PLAN_ROWS" )"
[ -z "$out_old" ] || fail "(5e) a plan row past CONSOLE_ROW_RETENTION must age off the display (got: $out_old)"
[ "$(herd_console_classify_queue_plan "$(printf '%s\t%s' "$NOW" x)")" = "$(printf '%s\tcalm' "$NOW")" ] \
  || fail "(5e) a plan row must classify CALM — the loud rails for this queue are spawn holds and spawn intents"
pass

# ── (6) THE COMMAND — the real `herd queue plan` / `herd queue list` end to end ──────────────────
PROJ="$T/proj"; mkdir -p "$PROJ/.herd"
CTREES="$T/ctrees"; mkdir -p "$CTREES"
cat > "$PROJ/.herd/config" <<EOF
PROJECT_ROOT="$PROJ"
WORKSPACE_NAME="testws"
SCRIBE_BACKEND="file"
BACKLOG_FILE="BACKLOG.md"
WORKTREES_DIR="$CTREES"
INTENT_QUEUE="on"
EOF
CQ="$CTREES/spawn-queue"
run_herd(){ ( cd "$PROJ" && HERD_CONFIG_FILE="$PROJ/.herd/config" HERMETIC_TEST=1 NO_COLOR=1 \
  bash "$HERD_BIN" "$@" 2>&1 ); }

out="$(run_herd queue list)" || fail "(6) herd queue list failed on a virgin pool: $out"
grep -q "no plan published" <<< "$out" || fail "(6) a virgin pool must say plainly that no plan is published (got: $out)"

# A MALFORMED plan must change NOTHING — publishing half a list is worse than publishing none.
printf 'good-one\tquick\t-\t-\treal task\nbad-lane\tsideways\t-\t-\tnope\n' > "$T/bad.tsv"
out="$(run_herd queue plan --file "$T/bad.tsv")" && fail "(6) a plan with an invalid lane must FAIL"
grep -q "lane must be quick or feature" <<< "$out" || fail "(6) the refusal must name the bad field (got: $out)"
ls "$CQ"/*.req >/dev/null 2>&1 && fail "(6) a REFUSED plan published intents — validation must precede any publish"
[ -e "$CQ/.gen" ] && fail "(6) a refused plan moved the generation pointer"

# …and a well-formed one publishes the whole list, in line order, with bands 10/20/30.
printf 'alpha\tquick\tHERD-A\t-\tbuild alpha\nbeta\tfeature\tHERD-B\t-\tbuild beta\n' > "$T/plan1.tsv"
out="$(run_herd queue plan --file "$T/plan1.tsv")" || fail "(6) herd queue plan failed: $out"
grep -q "published plan" <<< "$out" || fail "(6) publish printed no confirmation (got: $out)"
gen1="$(sed -n 1p "$CQ/.gen")"
[ -n "$gen1" ] || fail "(6) publish left no live generation pointer"
[ "$(ls -1 "$CQ"/*.req 2>/dev/null | wc -l | tr -d ' ')" = "2" ] || fail "(6) the plan's two candidates are not queued"
for f in "$CQ"/*.gen; do
  [ "$(sed -n 1p "$f")" = "$gen1" ] || fail "(6) a candidate is not stamped with the published generation"
done
bands="$(cat "$CQ"/*.prio 2>/dev/null | sort | tr '\n' ' ')"
[ "$bands" = "10 20 " ] || fail "(6) line order must become bands 10/20 (got: $bands)"
out="$(run_herd queue list)" || fail "(6) herd queue list failed: $out"
grep -q "alpha" <<< "$out" || fail "(6) list does not name the top candidate (got: $out)"
grep -q "HERD-B" <<< "$out" || fail "(6) list does not carry the tracker refs"
[ "$(printf '%s\n' "$out" | grep -c '📋')" = "2" ] || fail "(6) list must show both pending candidates (got: $out)"
pass

# RE-PUBLISH supersedes the whole previous generation in ONE call: no per-intent cancels, and the old
# candidates are gone from both the queue and the plan.
printf 'gamma\tquick\tHERD-C\t-\tbuild gamma\n' > "$T/plan2.tsv"
out="$(run_herd queue plan --file "$T/plan2.tsv")" || fail "(6) re-publish failed: $out"
grep -q "superseded $gen1" <<< "$out" || fail "(6) the re-publish did not report superseding the previous plan (got: $out)"
gen2="$(sed -n 1p "$CQ/.gen")"
[ "$gen2" != "$gen1" ] || fail "(6) the generation did not change on re-publish"
[ "$(ls -1 "$CQ"/*.req 2>/dev/null | wc -l | tr -d ' ')" = "1" ] \
  || fail "(6) the superseded generation's pending intents were not retired ($(ls "$CQ"))"
out="$(run_herd queue list)" || fail "(6) herd queue list failed after re-publish: $out"
grep -q "gamma" <<< "$out" || fail "(6) list does not show the NEW plan"
grep -q "alpha" <<< "$out" && fail "(6) list still shows a SUPERSEDED candidate — the plan surface is lying"
pass

# ── (7) MUTATION-PROOF — neutralize the swap and (2) MUST go red ─────────────────────────────────
# (2) would pass vacuously if `iq_gen_publish` were a no-op and the queue merely happened to hold one
# generation. Replace it with a no-op, re-run (2)'s exact assertion, and require the failure.
(
  # shellcheck source=/dev/null
  . "$LEVER"; . "$LIB"
  iq_gen_publish(){ return 0; }          # the mutation: the pointer never moves
  reset_q
  plant 1-0000000001-1 a-first  quick genA 10
  plant 2-0000000001-1 b-first  quick genB 10
  printf 'genA\n' > "$Q/.gen"            # A live, by hand — publish is now inert
  iq_gen_publish "$Q" genB
  got="$(order_ids | tr -d '\n')"
  [ "$got" = "2-0000000001-1" ] && exit 1   # B live ⇒ the mutation was NOT detected
  exit 0
) || fail "(7) MUTATION NOT DETECTED — the drain set inverted with a no-op iq_gen_publish, so (2) asserts nothing about the swap"
pass

echo "ALL PASS ($PASS checks)"
