#!/usr/bin/env bash
# test-intent-queue-lib.sh — HERD-639 (Phase 2 of HERD-625): the SHARED intent-queue library
# (scripts/herd/intent-queue.sh) under its own unit, independent of any tenant.
#
# Phase 1 shipped the queue policy "extraction-shaped by discipline" (docs/spikes/coordinator-work-queue.md
# §8 names that as the risk it was accepting). Phase 2 extracted it, which only resolves that risk if
# the library is exercised AS a library — every op, over a queue directory passed as an argument, with
# no tenant globals in scope. That is what this file does; the tenants' own proofs live elsewhere
# (tests/test-spawn-queue-drain.sh unmodified = tenant #1 is byte-identical,
# tests/test-intent-queue-marker-tenant.sh = tenant #2 rides the same rails end to end).
#
# Cases:
#   (1)  IDENTITY        iq_id_of recovers the INTENT_ID from every file form the queue produces.
#   (2)  PRIORITY        iq_prio reads the .prio sidecar; absent/empty/malformed = the default band.
#   (3)  ORDER           lever OFF = the untouched FIFO by INTENT_ID; lever ON = lowest band first,
#                        FIFO within a band; MUTATION-PROOF: equal bands must collapse (3) back onto (1).
#   (4)  ENQUEUE         iq_enqueue mints FIFO-sortable ids (deterministic within one second) and
#                        publishes atomically; iq_mint_id/iq_publish are the sidecar-writing form.
#   (5)  CLAIM           iq_claim wins by atomic rename, serves DRAIN order, and restarts the stale clock.
#   (6)  OWNER LIVENESS  a LIVE owner keeps its claim past the reclaim threshold; a DEAD owner's claim
#                        is reclaimed and its sidecar GC'd; an orphaned .owner is swept.
#   (7)  DONE/SKIP       both consume the claim AND its sidecars; skip warns loudly.
#   (8)  RELEASE         round-trips byte-identically, KEEPS .ref/.after/.prio/.attempts, drops .owner,
#                        restarts the stale clock, and touches the CLAIM before renaming it. Plus the
#                        MIRROR CHECK: spawn-step.sh's inline release (frozen in place by
#                        tests/test-spawn-queue-drain.sh case 9) still agrees with iq_release.
#   (9)  CANCEL          §4.4 level 1 — an UNCLAIMED intent goes terminal .cancelled with its sidecars
#                        gone; a CLAIMED one cannot be cancelled (rc 1, loud, never a silent no-op).
#   (10) ESCALATE        §4.3 — the claim goes terminal .escalated and no later claim can serve it.
#   (11) TTL             iq_expired is true only past the TTL, and fail-soft (never expiring) on a zero
#                        TTL, an unparseable id, or a clock that ran backwards.
#   (12) CLAIM RACE      N racers, ONE intent: exactly one winner. The loser's `done` finds a vanished
#                        claim → iq_require_claim rc 1 → spawn-step.sh exit 3 → the drain's
#                        spawn_claim_lost. Phase 1's semantics, preserved through the extraction.
#   (13) ATTEMPTS        the transient counter accrues across releases and is GC'd with the intent.
#
# Hermetic: temp dirs only. No network, no herdr, no lanes, no watcher. The library is sourced from the
# repo (it IS the unit under test) and the INTENT_QUEUE resolver is extracted VERBATIM from the real
# herd-config.sh, so the lever's truthiness is the shipped rule and not a copy that can go stale.
#
# Run:  bash tests/test-intent-queue-lib.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
LIB="$REPO/scripts/herd/intent-queue.sh"
STEP="$REPO/scripts/herd/spawn-step.sh"
CONFIG="$REPO/scripts/herd/herd-config.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass(){ PASS=$((PASS+1)); }

for f in "$LIB" "$STEP" "$CONFIG"; do [ -f "$f" ] || fail "missing engine file: $f"; done

# The REAL lever resolver, extracted verbatim (never re-declared — see the header).
LEVER="$T/lever.sh"
sed -n '/^herd_intent_queue_on()/,/^}/p' "$CONFIG" > "$LEVER"
grep -q '^herd_intent_queue_on()' "$LEVER" || fail "could not extract herd_intent_queue_on from herd-config.sh"

# shellcheck source=/dev/null
. "$LEVER"
# shellcheck source=/dev/null
. "$LIB"

Q="$T/q"; mkdir -p "$Q"
age(){ python3 -c 'import os,sys,time; t=time.time()-600; os.utime(sys.argv[1],(t,t))' "$1"; }
mtime(){ python3 -c 'import os,sys;print(int(os.stat(sys.argv[1]).st_mtime))' "$1"; }
reset_q(){ rm -rf "$Q"; mkdir -p "$Q"; }

# ── (1) IDENTITY ─────────────────────────────────────────────────────────────────────────────────
for form in "$Q/1754-0000000001-99.req" "$Q/1754-0000000001-99.req.mine" \
            "$Q/1754-0000000001-99.escalated" "$Q/1754-0000000001-99.cancelled" \
            "1754-0000000001-99"; do
  [ "$(iq_id_of "$form")" = "1754-0000000001-99" ] || fail "(1) iq_id_of mangled '$form' → $(iq_id_of "$form")"
done
pass

# ── (2) PRIORITY ─────────────────────────────────────────────────────────────────────────────────
reset_q
printf '7\n' > "$Q/a.prio"; : > "$Q/b.prio"; printf 'urgent!\n' > "$Q/c.prio"; printf '  9 \n' > "$Q/d.prio"
[ "$(iq_prio "$Q" a)" = "7" ]                   || fail "(2) a numeric .prio was not read"
[ "$(iq_prio "$Q" b)" = "$IQ_PRIO_DEFAULT" ]    || fail "(2) an EMPTY .prio must degrade to the default band"
[ "$(iq_prio "$Q" c)" = "$IQ_PRIO_DEFAULT" ]    || fail "(2) a non-numeric .prio must degrade to the default band"
[ "$(iq_prio "$Q" d)" = "9" ]                   || fail "(2) a padded .prio was not sanitized to its digits"
[ "$(iq_prio "$Q" nosuch)" = "$IQ_PRIO_DEFAULT" ] || fail "(2) an ABSENT .prio must read as the default band"
pass

# ── (3) ORDER (+ mutation proof) ─────────────────────────────────────────────────────────────────
# Three intents enqueued in id order 1,2,3 with bands 90, 10, 50.
reset_q
for spec in "1-0000000001-1 90" "1-0000000002-1 10" "1-0000000003-1 50"; do
  set -- $spec
  printf 'payload\n' > "$Q/$1.req"; printf '%s\n' "$2" > "$Q/$1.prio"
done
order_ids(){ iq_order "$Q" | while IFS= read -r p; do iq_id_of "$p"; printf '\n'; done; }
unset INTENT_QUEUE
[ "$(order_ids)" = "1-0000000001-1
1-0000000002-1
1-0000000003-1" ] || fail "(3) LEVER OFF must be the untouched FIFO by INTENT_ID (got: $(order_ids | tr '\n' ' '))"
export INTENT_QUEUE=on
[ "$(order_ids)" = "1-0000000002-1
1-0000000003-1
1-0000000001-1" ] || fail "(3) LEVER ON must drain lowest band first (got: $(order_ids | tr '\n' ' '))"
# MUTATION PROOF (doc §7.7): force every band equal and the ordering assertion above must collapse to
# FIFO — otherwise it was passing over a queue that was FIFO anyway, i.e. it asserted nothing.
for f in "$Q"/*.prio; do printf '50\n' > "$f"; done
[ "$(order_ids)" = "1-0000000001-1
1-0000000002-1
1-0000000003-1" ] || fail "(3) with all bands EQUAL the order must be FIFO — the ordering assert is vacuous otherwise"
unset INTENT_QUEUE
pass

# ── (4) ENQUEUE ──────────────────────────────────────────────────────────────────────────────────
reset_q
id1="$(iq_enqueue "$Q" "kind-a
ref-1")"
id2="$(iq_enqueue "$Q" "kind-a
ref-2")"
[ -n "$id1" ] && [ -n "$id2" ] || fail "(4) iq_enqueue printed no INTENT_ID"
[ -f "$Q/$id1.req" ] && [ -f "$Q/$id2.req" ] || fail "(4) iq_enqueue did not publish a .req"
[ "$(sed -n 2p "$Q/$id1.req")" = "ref-1" ] || fail "(4) the multi-line payload did not survive the publish"
# HERD-443: two intents minted in the SAME second must still sort in enqueue order.
sorted="$(printf '%s\n%s\n' "$id1" "$id2" | sort)"
[ "${sorted%%$'\n'*}" = "$id1" ] || fail "(4) same-second INTENT_IDs do not sort FIFO ($id1 vs $id2)"
ls "$Q"/.tmp.* >/dev/null 2>&1 && fail "(4) a temp file leaked out of the atomic publish"
# the sidecar-writing form: mint → write sidecars → publish
id3="$(iq_mint_id "$Q")"
printf 'HERD-639\n' > "$Q/$id3.ref"
iq_publish "$Q" "$id3" "kind-b
ref-3" || fail "(4) iq_publish failed"
[ -f "$Q/$id3.req" ] && [ -f "$Q/$id3.ref" ] || fail "(4) mint+publish did not land intent + sidecar"
pass

# ── (5) CLAIM ────────────────────────────────────────────────────────────────────────────────────
reset_q
printf 'first\n'  > "$Q/1-0000000001-1.req"
printf 'second\n' > "$Q/1-0000000002-1.req"
printf '10\n'     > "$Q/1-0000000002-1.prio"
export INTENT_QUEUE=on
c1="$(iq_claim "$Q")" || fail "(5) iq_claim served nothing on a non-empty queue"
[ "$(iq_id_of "$c1")" = "1-0000000002-1" ] || fail "(5) iq_claim ignored the priority band (got $(iq_id_of "$c1"))"
[ -f "$c1" ] || fail "(5) the claim path does not exist"
[ ! -f "$Q/1-0000000002-1.req" ] || fail "(5) the claimed intent is still pending (.req survived the rename)"
unset INTENT_QUEUE
c2="$(iq_claim "$Q")" || fail "(5) the sibling intent was not claimable"
[ "$(iq_id_of "$c2")" = "1-0000000001-1" ] || fail "(5) the second claim served the wrong intent"
iq_claim "$Q" >/dev/null 2>&1 && fail "(5) an EMPTY queue must not serve a claim (rc 0 = a phantom intent)"
pass

# ── (6) OWNER LIVENESS ───────────────────────────────────────────────────────────────────────────
# A live owner keeps its claim however old the claim gets (HERD-237: a slow lane is normal, and
# re-serving its intent launches the same work twice).
reset_q
printf 'slow\n' > "$Q/1-0000000001-1.req"
mine="$(iq_claim "$Q")"
sleep 300 & LIVE=$!
iq_own "$mine" "$LIVE"
[ "$(head -1 "${mine%.req.mine}.owner")" = "$LIVE" ] || fail "(6) iq_own did not record the owner pid"
iq_owner_alive "${mine%.req.mine}.owner" || fail "(6) a LIVE owner did not read as alive"
age "$mine"
iq_claim "$Q" >/dev/null 2>&1 && fail "(6) an IN-FLIGHT claim was reclaimed — the work would run twice"
[ -f "$mine" ] || fail "(6) the in-flight claim vanished"
# …and a DEAD owner's claim ages back into the queue, sidecar GC'd.
kill "$LIVE" 2>/dev/null; wait "$LIVE" 2>/dev/null || true
iq_owner_alive "${mine%.req.mine}.owner" && fail "(6) a DEAD owner still read as alive"
again="$(iq_claim "$Q")" || fail "(6) an ABANDONED claim was never reclaimed"
[ "$(iq_id_of "$again")" = "1-0000000001-1" ] || fail "(6) the reclaim served the wrong intent"
ls "$Q"/*.owner >/dev/null 2>&1 && fail "(6) the dead owner's sidecar was not cleaned"
# an ORPHANED .owner (claim already consumed) is swept on the next claim pass
printf '1\n' > "$Q/orphan.owner"
iq_claim "$Q" >/dev/null 2>&1 || true
[ -f "$Q/orphan.owner" ] && fail "(6) an orphaned owner sidecar survived the sweep"
pass

# ── (7) DONE / SKIP ──────────────────────────────────────────────────────────────────────────────
reset_q
printf 'x\n' > "$Q/1-0000000001-1.req"
for s in ref after prio attempts; do printf 'v\n' > "$Q/1-0000000001-1.$s"; done
mine="$(iq_claim "$Q")"
iq_own "$mine" $$
iq_done "$mine"
[ -z "$(ls -A "$Q")" ] || fail "(7) iq_done left files behind: $(ls -A "$Q" | tr '\n' ' ')"
printf 'y\n' > "$Q/1-0000000002-1.req"; printf 'v\n' > "$Q/1-0000000002-1.ref"
mine="$(iq_claim "$Q")"
warn="$(iq_skip "$mine" "malformed on purpose" 2>&1 >/dev/null)"
case "$warn" in *"skipping intent"*"malformed on purpose"*) : ;; *) fail "(7) iq_skip was not loud (got: $warn)" ;; esac
[ -z "$(ls -A "$Q")" ] || fail "(7) iq_skip left files behind: $(ls -A "$Q" | tr '\n' ' ')"
pass

# ── (8) RELEASE (+ the spawn-step mirror) ────────────────────────────────────────────────────────
reset_q
payload='line one
line two'
printf '%s\n' "$payload" > "$Q/1-0000000001-1.req"
printf 'HERD-639\n' > "$Q/1-0000000001-1.ref"
printf 'dep\n'      > "$Q/1-0000000001-1.after"
printf '10\n'       > "$Q/1-0000000001-1.prio"
before="$(cat "$Q/1-0000000001-1.req")"
mine="$(iq_claim "$Q")"
iq_own "$mine" $$
age "$mine"; before_mtime="$(mtime "$mine")"
iq_release "$mine"
rel="$Q/1-0000000001-1.req"
[ -f "$rel" ] || fail "(8) release did not restore the .req"
[ "$(cat "$rel")" = "$before" ] || fail "(8) release altered the intent payload"
[ "$(ls "$Q"/*.req 2>/dev/null | wc -l | tr -d ' ')" = "1" ] || fail "(8) release produced a phantom second .req"
[ -s "$rel" ] || fail "(8) the released intent is EMPTY — the phantom-.req race"
for s in ref after prio; do [ -f "$Q/1-0000000001-1.$s" ] || fail "(8) release dropped the .$s sidecar"; done
[ -f "$Q/1-0000000001-1.owner" ] && fail "(8) release kept the .owner sidecar — the intent is owned by nobody"
[ "$(mtime "$rel")" -gt "$before_mtime" ] || fail "(8) release did not restart the stale clock (HERD-116 spin)"
# The properties above hold for BOTH orderings; only the ORDER closes the interleaving window, and no
# black-box test can schedule that interleaving reliably. Assert the order itself, in the source — and
# assert spawn-step.sh's INLINE mirror (kept in place by tests/test-spawn-queue-drain.sh case 9, which
# inspects that case body) still agrees, so the one duplicated rule in this slice cannot drift silently.
python3 - "$LIB" "$STEP" <<'ORDER' || fail "(8) release must drop the owner, touch the CLAIM, then rename it — in BOTH iq_release and spawn-step.sh's inline mirror, in that order"
import re, sys

def effects(body, var):
    """The release's three mutations, in source order, normalized over the body's own variable name."""
    want = [('.owner"', 'rm-owner'),
            ('touch "%s"' % var, 'touch-claim'),
            ('mv -f "%s"' % var, 'rename-claim')]
    found = []
    for needle, name in want:
        i = body.find(needle)
        if i < 0:
            sys.exit("missing %s (looked for %r)" % (name, needle))
        found.append((i, name))
    return [n for _, n in sorted(found)]

lib = re.search(r'^iq_release\(\) \{(.*?)^\}', open(sys.argv[1]).read(), re.S | re.M).group(1)
step = re.search(r'^  release\)(.*?)^    ;;', open(sys.argv[2]).read(), re.S | re.M).group(1)
a = effects(lib, '$_iqe_mine')
b = effects(step, '$mine')
if a != ['rm-owner', 'touch-claim', 'rename-claim']:
    sys.exit("iq_release effects out of order: %s" % a)
if a != b:
    sys.exit("spawn-step.sh's inline release has DRIFTED from iq_release: %s vs %s" % (b, a))
ORDER
pass

# ── (9) CANCEL ───────────────────────────────────────────────────────────────────────────────────
reset_q
printf 'z\n' > "$Q/1-0000000001-1.req"; printf 'r\n' > "$Q/1-0000000001-1.ref"
iq_cancel "$Q" "1-0000000001-1" || fail "(9) an UNCLAIMED intent could not be cancelled"
[ -f "$Q/1-0000000001-1.cancelled" ] || fail "(9) cancel did not produce the terminal .cancelled record"
[ -f "$Q/1-0000000001-1.ref" ] && fail "(9) cancel left a sidecar behind"
iq_claim "$Q" >/dev/null 2>&1 && fail "(9) a CANCELLED intent was still servable"
printf 'z\n' > "$Q/1-0000000002-1.req"
mine="$(iq_claim "$Q")"
iq_cancel "$Q" "1-0000000002-1" && fail "(9) a CLAIMED intent must NOT be cancellable (it is already launching)"
[ -f "$mine" ] || fail "(9) the failed cancel disturbed the live claim"
pass

# ── (10) ESCALATE ────────────────────────────────────────────────────────────────────────────────
reset_q
printf 'e\n' > "$Q/1-0000000001-1.req"
mine="$(iq_claim "$Q")"
iq_own "$mine" $$
iq_escalate "$mine" || fail "(10) iq_escalate failed on a live claim"
[ -f "$Q/1-0000000001-1.escalated" ] || fail "(10) escalate did not produce the terminal .escalated record"
[ -f "$Q/1-0000000001-1.owner" ] && fail "(10) escalate kept an owner sidecar for work that will never run"
iq_claim "$Q" >/dev/null 2>&1 && fail "(10) an ESCALATED intent was still servable — it must leave the drain set for good"
iq_escalate "$Q/1-0000000001-1.req.mine" && fail "(10) escalating a VANISHED claim must fail, not report success"
pass

# ── (11) TTL ─────────────────────────────────────────────────────────────────────────────────────
NOW=1000000
iq_expired "999000-0000000001-1" 500 "$NOW"  || fail "(11) an intent 1000s past a 500s TTL did not expire"
iq_expired "999900-0000000001-1" 500 "$NOW"  && fail "(11) an intent 100s into a 500s TTL expired early"
iq_expired "999000-0000000001-1" 0   "$NOW"  && fail "(11) TTL 0 must disable expiry entirely"
iq_expired "999000-0000000001-1" ""  "$NOW"  && fail "(11) an EMPTY TTL must fail soft (never expire)"
iq_expired "handmade"             500 "$NOW" && fail "(11) an unparseable INTENT_ID must fail soft (never expire)"
iq_expired "1000500-0000000001-1" 500 "$NOW" && fail "(11) a clock that ran backwards must fail soft (never expire)"
pass

# ── (12) CLAIM RACE ──────────────────────────────────────────────────────────────────────────────
# One intent, eight racers: the atomic rename must hand it to EXACTLY ONE. Then the loser's semantics,
# unchanged from Phase 1: `done` on a claim that has vanished is never a silent success — the library
# refuses it (rc 1), spawn-step.sh exits 3, and the drain's worker journals spawn_claim_lost.
reset_q
printf 'contested\n' > "$Q/1-0000000001-1.req"
: > "$T/winners"
for i in 1 2 3 4 5 6 7 8; do
  ( c="$(iq_claim "$Q" 2>/dev/null || true)"; [ -n "$c" ] && printf '%s\n' "$c" >> "$T/winners" ) &
done
wait
won="$(wc -l < "$T/winners" | tr -d ' ')"
[ "$won" = "1" ] || fail "(12) $won racers claimed ONE intent — the atomic-rename claim is not exclusive"
mine="$(sed -n 1p "$T/winners")"
[ -f "$mine" ] || fail "(12) the winner's claim does not exist"
rm -f "$mine"                                  # the loser's view: reclaimed (or already consumed) under us
iq_require_claim "$mine" done 2>/dev/null && fail "(12) iq_require_claim reported a VANISHED claim as present"
# …and the tenant CLI still turns that into the exit 3 the drain reads as spawn_claim_lost.
mkdir -p "$T/trees/spawn-queue"
printf 'WORKTREES_DIR="%s"\nexport WORKTREES_DIR\n' "$T/trees" > "$T/stub-config.sh"
ENGC="$T/eng"; mkdir -p "$ENGC"; cp "$STEP" "$ENGC/spawn-step.sh"; cp "$T/stub-config.sh" "$ENGC/herd-config.sh"
for verb in done release skip escalate; do
  WORKTREES_DIR="$T/trees" bash "$ENGC/spawn-step.sh" "$verb" "$T/trees/spawn-queue/gone.req.mine" why >/dev/null 2>&1
  [ "$?" = "3" ] || fail "(12) spawn-step.sh $verb on a vanished claim must exit 3 (a lost claim read as a success)"
done
pass

# ── (13) ATTEMPTS ────────────────────────────────────────────────────────────────────────────────
reset_q
printf 'a\n' > "$Q/1-0000000001-1.req"
[ "$(iq_attempts "$Q" 1-0000000001-1)" = "0" ] || fail "(13) a never-failed intent must report 0 attempts"
[ "$(iq_attempt_bump "$Q" 1-0000000001-1)" = "1" ] || fail "(13) the first bump must report 1"
mine="$(iq_claim "$Q")"; iq_release "$mine"
[ "$(iq_attempts "$Q" 1-0000000001-1)" = "1" ] || fail "(13) the attempt counter must survive a release"
[ "$(iq_attempt_bump "$Q" 1-0000000001-1)" = "2" ] || fail "(13) the counter did not accrue across ticks"
mine="$(iq_claim "$Q")"; iq_done "$mine"
[ -f "$Q/1-0000000001-1.attempts" ] && fail "(13) the attempts sidecar outlived its intent"
pass

echo "ALL PASS ($PASS checks)"
