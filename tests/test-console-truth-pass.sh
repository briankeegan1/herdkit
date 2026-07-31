#!/usr/bin/env bash
# test-console-truth-pass.sh — hermetic tests for the CONSOLE / PR-PAGE TRUTH PASS (HERD-453 + HERD-455,
# GitHub issue #569). Four operator-observed counts, all on 2026-07-31, all the same shape: a row that
# renders a LEDGER without re-checking the world the ledger claims to describe.
#
#   COUNT 1 — RESOLVER-BLIND needs-you. The console said 'export-concurrency-keys #565 · needs you ·
#     conflict' while `herdr agent list` showed resolve·export-concurrency-keys at status=working on that
#     exact conflict. The refix rails already implement "needs-you means NOBODY is on it" for BUILDER
#     agents; the conflict rail consulted no agent at all.
#       (1a) a live WORKING resolver renders 'resolving · awaiting push', flair busy, and NO respawn is
#            queued (a second resolver on the same worktree races the first on merge/push)
#       (1b) it flips BACK to needs-you the moment the resolver dies / stops working — and the queue
#            re-arms with it
#       (1c) an ESCALATE verdict stays needs-you even with a live pane (terminal for the sha)
#       (1d) an unreadable/blind roster falls through to the honest needs-you (fail toward asking)
#
#   COUNT 2 — STALE MAIN-HEALTH VERDICT. 'MAIN RED — BATS FAILED (observed)' rendered for a sha three
#     merges old, with nothing in the row admitting it.
#       (2a) a verdict pinned to the OBSERVED head renders byte-identically to the pre-HERD-453 row
#       (2b) a verdict pinned to an older sha renders both shas + the ·outdated· qualifier
#       (2c) ANCESTOR-CLEAR: a green on a DESCENDANT clears a red pinned to its ancestor…
#       (2d) …and a green on an ANCESTOR does NOT clear a red pinned to a descendant (older evidence
#            must never wipe a newer red — the late-collected-worker case)
#       (2e) a no-slot re-verify RETRIES: the defer memo counts attempts + ages, the row says so, and
#            the retry converges to a verdict the moment the slot frees
#
#   COUNT 3 — MAIN STALE dirty-tree twin (HERD-455 / GH #569). '.agent-watch-main-freshness' held
#     'uncommitted changes' through 10+ minutes of a provably clean tree and TWO watcher restarts.
#       (3a) the RENDER itself drops a verdict live git status disproves — within one tick, no restart
#       (3b) it clears even when every reconcile guard is blind ($MAIN parked off the default branch —
#            the exact shape that strands _main_fresh_recheck)
#       (3c) a GENUINELY dirty tree keeps its row, byte-identical (no false clear)
#       (3d) DRYRUN withholds the disproved row but mutates nothing
#
#   COUNT 4 — PHASE LABELS. 'gating · herd/gates (BLOCKED)' rendered while the pipeline was RUNNING.
#       (4a) a live health worker → the shared health-running row
#       (4b) a live reviewer → 'review · in progress (<age>)'
#       (4c) neither → the caller's fallback, verbatim
#
# Sources agent-watch.sh in lib mode and drives the real functions against a REAL local git repo and
# REAL marker files. journal_append is overridden to a log. No network, no gh, no herdr.
# Run:  bash tests/test-console-truth-pass.sh
set -uo pipefail
HERE_T="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE_T/../scripts/herd/agent-watch.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

[ -f "$WATCH" ] || fail "agent-watch.sh not found at $WATCH"
command -v git >/dev/null 2>&1 || fail "git required to run this test"

# ── Stub gh / herdr on PATH (network-free); git stays REAL ────────────────────────────────────────
BIN="$T/bin"; mkdir -p "$BIN"
for cmd in gh herdr; do printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$cmd"; chmod +x "$BIN/$cmd"; done
export PATH="$BIN:$PATH"

# ── Source agent-watch.sh in lib mode ─────────────────────────────────────────────────────────────
export AGENT_WATCH_LIB=1
export WORKTREES_DIR="$T/trees"; mkdir -p "$T/trees"
export HERD_CONFIG_FILE="$T/no-such-config"
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"
for fn in _active_resolve_note _active_fix_note _conflict_row _classify_conflict \
          _main_health_observed_sha _main_health_verdict_state _main_health_green_supersedes \
          _main_health_defer_note _main_health_defer _main_health_clear build_main_health \
          _main_fresh_reason_disproved build_main_freshness _main_fresh_hold \
          _gate_health_inflight _gate_phase_row; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined"
done

JLOG="$T/journal.log"; : > "$JLOG"
journal_append() { printf '%s\n' "$*" >> "$JLOG"; }
herd_driver_notify() { :; }

# ── A REAL git repo standing in for the shared $MAIN checkout ─────────────────────────────────────
ORIGIN="$T/origin.git"; git init -q --bare "$ORIGIN"
MAIN="$T/main"; git clone -q "$ORIGIN" "$MAIN" 2>/dev/null
git -C "$MAIN" checkout -q -B main
git -C "$MAIN" config user.email t@t.test; git -C "$MAIN" config user.name tester
printf 'hello\n' > "$MAIN/README.md"
git -C "$MAIN" add -A; git -C "$MAIN" commit -q -m c1; git -C "$MAIN" push -q origin main
SHA1="$(git -C "$MAIN" rev-parse HEAD)"
printf 'more\n' >> "$MAIN/README.md"
git -C "$MAIN" commit -qam c2; git -C "$MAIN" push -q origin main
SHA2="$(git -C "$MAIN" rev-parse HEAD)"
printf 'even more\n' >> "$MAIN/README.md"
git -C "$MAIN" commit -qam c3; git -C "$MAIN" push -q origin main
SHA3="$(git -C "$MAIN" rev-parse HEAD)"

HERD_REMOTE=origin; HERD_BRANCH_NAME=main; DEFAULT_BRANCH=origin/main
TREES="$WORKTREES_DIR"; mkdir -p "$TREES"
MAIN_FRESH_STATE="$TREES/.agent-watch-main-freshness"
MAIN_FRESH_RESTART="$TREES/.agent-watch-main-restart"
MAIN_HEALTH_STATE="$TREES/.agent-watch-main-health"
MAIN_HEALTH_DEFER="$TREES/.agent-watch-main-health-defer"
US=$'\x1f'

# Colors OFF so every assertion below reads the plain row text.
C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_DIM=""; C_BOLD=""; C_RESET=""

# ══════════════════════════════════════════════════════════════════════════════════════════════════
# COUNT 1 — the conflict row is resolver-aware, from the SHARED row-truth check
# ══════════════════════════════════════════════════════════════════════════════════════════════════
# A roster in the exact shape `herdr agent list --json` returns. `name` is the SANITIZED registered
# identity (herd_agent_name_sanitize), which is what _resolver_agent_status matches on.
roster() {  # roster <sanitized-name> <status>   (empty name ⇒ an EMPTY but readable roster)
  if [ -z "${1:-}" ]; then printf '{"result":{"agents":[]}}'; return 0; fi
  printf '{"result":{"agents":[{"name":"%s","agent_status":"%s"}]}}' "$1" "$2"
}
RESOLVER_NAME="$(herd_agent_name_sanitize "resolve·feat-x")"

# THE GAP, precisely. The two branches that DO consult _resolver_in_flight (a resolver dispatched for
# this sha, or for an older one) already hold on a working resolver — they were never the bug. The
# FIRST-CONFLICT branch is: `count == 0` means THIS SEAT has no dispatch record for this PR, which is
# not the same as "no resolver is working it". A resolver dispatched by ANOTHER SEAT, spawned by hand,
# or surviving a lost/swept local ledger leaves count == 0 while resolve·<slug> is genuinely working —
# and that branch consulted no agent at all before painting needs-you and queueing a second resolver
# onto the same worktree. That is the live 2026-07-31 row, so that is the branch driven here.
classify() {  # classify <AGENTS_JSON>  → sets DISPLAY[0]/FLAIR_STATE[0]/CONF_*
  DISPLAY=(); FLAIR_STATE=()
  CONF_IDX=(); CONF_SLUG=(); CONF_PR=(); CONF_BRANCH=(); CONF_SHA=(); CONF_REASON=()
  AGENTS_JSON="$1" _classify_conflict 0 565 feat-x feat/x newsha
}

# An EMPTY local resolver ledger — this seat has dispatched nothing for PR #565.
RESOLVE_STATE="$TREES/.agent-watch-resolve"; : > "$RESOLVE_STATE"
# The liveness oracles below must read the ROSTER, not a live herdr: pin the probe to 'unknown' (blind)
# so only a POSITIVE roster status can ever suppress needs-you — precisely the doctrine under test.
_resolver_probe() { printf 'unknown'; }
_resolver_lane_starting() { return 1; }
_restale_note() { :; }
_restale_decorate_row() { :; }
_RESOLVER_DEAD_GRACE=0

# (1a) LIVE WORKING resolver → 'resolving · awaiting push', busy flair, NO respawn queued.
classify "$(roster "$RESOLVER_NAME" working)"
case "${DISPLAY[0]}" in
  *"resolving · awaiting push"*) ok ;;
  *) fail "1a: live working resolver still renders: ${DISPLAY[0]}" ;;
esac
case "${DISPLAY[0]}" in *"needs you"*) fail "1a: row still says needs you: ${DISPLAY[0]}" ;; esac
[ "${FLAIR_STATE[0]}" = "busy" ] || fail "1a: flair not downgraded to busy (got ${FLAIR_STATE[0]})"
[ "${#CONF_IDX[@]}" -eq 0 ] || fail "1a: a respawn was queued over a live resolver"

# (1b) The resolver stops working (idle) → the row flips BACK to the honest needs-you AND re-queues.
classify "$(roster "$RESOLVER_NAME" idle)"
case "${DISPLAY[0]}" in
  *"needs you · conflict"*) ok ;;
  *) fail "1b: an idle resolver must not suppress needs-you: ${DISPLAY[0]}" ;;
esac
[ "${#CONF_IDX[@]}" -eq 1 ] || fail "1b: the respawn was not re-queued once the resolver went idle"

# …and the same when the resolver is GONE from the roster entirely (dead).
classify "$(roster "" "")"
case "${DISPLAY[0]}" in
  *"needs you · conflict"*) ok ;;
  *) fail "1b: a dead resolver must read needs-you: ${DISPLAY[0]}" ;;
esac

# (1c) ESCALATE is TERMINAL for the sha — a still-open working pane must never bury it. Driven from
#      REAL state (a dispatch row for this sha + the resolver's own verdict file), not stubs, so the
#      classifier's actual terminal path runs.
printf '%s 565 feat-x feat/x newsha dispatched\n' "$(date +%s)" > "$RESOLVE_STATE"
printf 'RESOLVE: ESCALATE\n' > "$(_resolve_result_file 565 newsha)"
_resolve_claim_publish_terminal() { :; }
classify "$(roster "$RESOLVER_NAME" working)"
case "${DISPLAY[0]}" in
  *"needs you · resolver escalated"*) ok ;;
  *) fail "1c: an ESCALATE verdict must stay needs-you: ${DISPLAY[0]}" ;;
esac
rm -f "$(_resolve_result_file 565 newsha)"; : > "$RESOLVE_STATE"

# (1d) A BLIND roster (unreadable JSON) proves nothing → the honest needs-you, never silence.
classify 'not json at all'
case "${DISPLAY[0]}" in
  *"needs you · conflict"*) ok ;;
  *) fail "1d: a blind roster must fall through to needs-you: ${DISPLAY[0]}" ;;
esac
# …and the shared check itself agrees, at its own seam.
AGENTS_JSON="$(roster "$RESOLVER_NAME" working)" _active_fix_note 565 newsha feat-x conflict >/dev/null \
  || fail "1d: the shared row-truth check does not see a working resolver"
AGENTS_JSON="$(roster "" "")" _active_fix_note 565 newsha feat-x conflict >/dev/null \
  && fail "1d: the shared row-truth check invented work-in-flight from an empty roster"
ok

# ══════════════════════════════════════════════════════════════════════════════════════════════════
# COUNT 2 — a MAIN RED verdict is sha-current, ancestor-honest, and admits a starved re-verify
# ══════════════════════════════════════════════════════════════════════════════════════════════════
MAIN_HEALTH_TICK=on
git -C "$MAIN" checkout -q main
git -C "$MAIN" reset -q --hard "$SHA3"

# (2a) verdict pinned to the OBSERVED head → byte-identical to the pre-HERD-453 row.
printf '%s%s%s%s%s%s%s\n' "$SHA3" "$US" "42" "$US" "BATS FAILED" "$US" "" > "$MAIN_HEALTH_STATE"
build_main_health
EXPECTED_CURRENT="    🚨 MAIN RED — BATS FAILED (since #42)"$'\n'
[ "$MAIN_HEALTH" = "$EXPECTED_CURRENT" ] || fail "2a: current verdict row drifted: $(printf '%q' "$MAIN_HEALTH")"
ok

# (2b) verdict pinned to a sha main has moved past → both shas + ·outdated·.
printf '%s%s%s%s%s%s%s\n' "$SHA1" "$US" "?" "$US" "BATS FAILED" "$US" "" > "$MAIN_HEALTH_STATE"
build_main_health
case "$MAIN_HEALTH" in
  *"·outdated·"*) ok ;;
  *) fail "2b: a 3-merge-stale verdict rendered with no qualifier: $MAIN_HEALTH" ;;
esac
case "$MAIN_HEALTH" in *"sha ${SHA1:0:7}"*) ok ;; *) fail "2b: the row does not name the verdict's sha: $MAIN_HEALTH" ;; esac
case "$MAIN_HEALTH" in *"main is at ${SHA3:0:7}"*) ok ;; *) fail "2b: the row does not name observed main: $MAIN_HEALTH" ;; esac
case "$MAIN_HEALTH" in *"(observed)"*) ok ;; *) fail "2b: the honest 'since' attribution was lost: $MAIN_HEALTH" ;; esac
[ "$(_main_health_verdict_state "$SHA3")" = current  ] || fail "2b: head sha not classified current"
[ "$(_main_health_verdict_state "$SHA1")" = outdated ] || fail "2b: stale sha not classified outdated"
[ "$(_main_health_verdict_state "")"      = unknown  ] || fail "2b: empty sha not classified unknown"

# The lever still owns the row: MAIN_HEALTH_TICK=off renders NOTHING, red state file or not.
MAIN_HEALTH_TICK=off; build_main_health
[ -z "$MAIN_HEALTH" ] || fail "2b: the row rendered with MAIN_HEALTH_TICK=off"
MAIN_HEALTH_TICK=on
ok

# (2c) ANCESTOR-CLEAR — a green on a DESCENDANT clears a red pinned to its ancestor.
_main_health_fix_clear() { :; }
printf '%s%s%s%s%s%s%s\n' "$SHA1" "$US" "42" "$US" "BATS FAILED" "$US" "" > "$MAIN_HEALTH_STATE"
: > "$JLOG"
_main_health_clear 44 "$SHA3"
[ -e "$MAIN_HEALTH_STATE" ] && fail "2c: a descendant green did not clear the ancestor red"
grep -q 'result green' "$JLOG" || fail "2c: the green transition was not journaled"
ok

# (2d) …and the converse: a green on an ANCESTOR must NOT wipe a red pinned to a descendant.
printf '%s%s%s%s%s%s%s\n' "$SHA3" "$US" "42" "$US" "BATS FAILED" "$US" "" > "$MAIN_HEALTH_STATE"
: > "$JLOG"
_main_health_clear 44 "$SHA1"
[ -s "$MAIN_HEALTH_STATE" ] || fail "2d: an ANCESTOR green wiped a newer red (older evidence won)"
grep -q 'reason stale-green' "$JLOG" || fail "2d: the refused clear was not journaled"
ok
# Fail-soft: an unorderable pair (a sha git does not know) still clears — never strand a red on a
# comparison we could not make.
_main_health_green_supersedes deadbeefdeadbeef "$SHA3" || fail "2d: an unverifiable comparison failed closed"
_main_health_green_supersedes "$SHA3" "$SHA3"          || fail "2d: identical shas must supersede"
_main_health_green_supersedes "$SHA3" "$SHA1"          || fail "2d: descendant must supersede ancestor"
_main_health_green_supersedes "$SHA2" "$SHA3"          && fail "2d: ancestor must NOT supersede descendant"
_main_health_green_supersedes "$SHA1" "$SHA3"          && fail "2d: distant ancestor must NOT supersede"
ok
# A REWRITTEN default branch (force-push / rebase) leaves the pin dangling and UNORDERED against every
# later HEAD. That must still clear — "descendant required" would strand such a red forever.
git -C "$MAIN" checkout -q --detach "$SHA1"
printf 'rewritten history\n' >> "$MAIN/README.md"
git -C "$MAIN" commit -qam rewritten
ORPHAN="$(git -C "$MAIN" rev-parse HEAD)"
git -C "$MAIN" checkout -q main
_main_health_green_supersedes "$SHA3" "$ORPHAN" || fail "2d: an unordered (rewritten-history) pin was stranded"
ok

# (2e) A no-slot re-verify RETRIES until a verdict lands — and says so while it waits.
rm -f "$MAIN_HEALTH_DEFER"
printf '%s%s%s%s%s%s%s\n' "$SHA1" "$US" "?" "$US" "BATS FAILED" "$US" "" > "$MAIN_HEALTH_STATE"
: > "$JLOG"
HERD_FAKE_NOW=1000 _main_health_defer "?" "$SHA3" no-slot
[ "$(grep -c 'reason no-slot' "$JLOG")" -eq 1 ] || fail "2e: the first deferral did not journal"
for n in 2 3; do HERD_FAKE_NOW=$((1000 + n)) _main_health_defer "?" "$SHA3" no-slot; done
read -r _d_sha _d_reason _d_first _d_n < "$MAIN_HEALTH_DEFER"
[ "$_d_sha" = "$SHA3" ] && [ "$_d_reason" = "no-slot" ] || fail "2e: defer memo lost its (sha,reason)"
[ "$_d_first" = "1000" ] || fail "2e: the first-defer epoch did not stick (got $_d_first)"
[ "$_d_n" -eq 3 ] || fail "2e: the retry attempts did not accumulate (got $_d_n)"
[ "$(grep -c 'reason no-slot' "$JLOG")" -eq 1 ] || fail "2e: a standing deferral spammed the journal"
# …and the console SAYS the re-verify is deferred, instead of reading as silence.
NOTE="$(HERD_FAKE_NOW=1180 _main_health_defer_note)"
case "$NOTE" in
  "re-verify deferred: no-slot 3m ×3") ok ;;
  *) fail "2e: defer note wrong: '$NOTE'" ;;
esac
MAIN_HEALTH_TICK=on
HERD_FAKE_NOW=1180 build_main_health
case "$MAIN_HEALTH" in
  *"re-verify deferred: no-slot 3m ×3"*) ok ;;
  *) fail "2e: the MAIN RED row does not carry the standing deferral: $MAIN_HEALTH" ;;
esac
# A deferral for a sha main has ALREADY moved past is spent, not standing → no decoration.
printf '%s no-slot 1000 9\n' "$SHA1" > "$MAIN_HEALTH_DEFER"
[ -z "$(HERD_FAKE_NOW=1180 _main_health_defer_note)" ] || fail "2e: a spent deferral still decorates"
# A LEGACY 2-field memo (written by an older engine) is read defensively → nothing extra, never a crash.
printf '%s no-slot\n' "$SHA3" > "$MAIN_HEALTH_DEFER"
[ -z "$(_main_health_defer_note)" ] || fail "2e: a legacy memo produced a bogus note"
ok
# CONVERGENCE: the retry is what ends the starvation — once the slot frees, the SAME reconcile path
# that kept deferring dispatches, and the memo is dropped (re-arming the journal for the next run).
rm -f "$MAIN_HEALTH_DEFER"; : > "$JLOG"
HERD_FAKE_NOW=2000 _main_health_defer "?" "$SHA3" no-slot
[ -s "$MAIN_HEALTH_DEFER" ] || fail "2e: no deferral recorded"
_health_slot_free() { return 0; }
_bg_health_worker() { _BG_HEALTH_PID=$$; _BG_HEALTH_PGID=$$; }
HERD_HEALTHCHECK_BIN="$T/fake-healthcheck.sh"; : > "$HERD_HEALTHCHECK_BIN"
lifecycle_spawn() { :; }; _rotate_health_logs() { :; }
_main_health_dispatch "?" "$SHA3" observed-sha || fail "2e: the retry never dispatched once the slot freed"
[ -e "$MAIN_HEALTH_DEFER" ] && fail "2e: the defer memo survived a real dispatch (journal never re-arms)"
grep -q 'result dispatched' "$JLOG" || fail "2e: the converging dispatch was not journaled"
ok

# ══════════════════════════════════════════════════════════════════════════════════════════════════
# COUNT 3 — the freshness row is reconciled against LIVE git status at RENDER time (HERD-455 / #569)
# ══════════════════════════════════════════════════════════════════════════════════════════════════
rm -f "$MAIN_FRESH_STATE" "$MAIN_FRESH_RESTART"
git -C "$MAIN" checkout -q main
git -C "$MAIN" reset -q --hard "$SHA3"
git -C "$MAIN" clean -qfd
_self_restart_quiescing() { return 1; }

# (3a) The EXACT #569 ledger — 'dirty-tree 0 1' — against a provably clean tree. One render tick, no
#      restart: the row is gone and the ledger is dropped, journaling the recovery once.
printf 'dirty-tree 0 1\n' > "$MAIN_FRESH_STATE"
: > "$JLOG"
build_main_freshness
[ -z "$MAIN_FRESHNESS" ] || fail "3a: a disproved dirty-tree row still painted: $MAIN_FRESHNESS"
[ -e "$MAIN_FRESH_STATE" ] && fail "3a: the disproved ledger row survived the render tick"
grep -q 'main_fresh_recovered' "$JLOG" || fail "3a: the recovery was not journaled"
ok

# (3b) It clears even where the reconcile is BLIND. $MAIN parked on another named branch is exactly
#      the shape that returns _main_fresh_recheck early — and it used to leave the render painting.
git -C "$MAIN" checkout -q -b parked
printf 'dirty-tree 0 1\n' > "$MAIN_FRESH_STATE"
: > "$JLOG"
_main_fresh_recheck            # the recovery path: silently declines (off the default branch)
[ -s "$MAIN_FRESH_STATE" ] || fail "3b: precondition — the recheck was expected to decline here"
build_main_freshness
[ -z "$MAIN_FRESHNESS" ] || fail "3b: the render trusted a ledger no reconcile could invalidate"
[ -e "$MAIN_FRESH_STATE" ] && fail "3b: the ledger row survived while the reconcile was blind"
ok
git -C "$MAIN" checkout -q main; git -C "$MAIN" branch -qD parked

# (3c) A GENUINELY dirty tree keeps its row, byte-identical — the check only ever WITHHOLDS a paint.
printf 'contamination\n' >> "$MAIN/README.md"
printf 'dirty-tree 2 0\n' > "$MAIN_FRESH_STATE"
build_main_freshness
EXPECTED_DIRTY="    ⚠️  MAIN STALE — behind origin/main by 2 · uncommitted changes in the checkout · commit or stash them"$'\n'
[ "$MAIN_FRESHNESS" = "$EXPECTED_DIRTY" ] || fail "3c: a REAL dirty row drifted: $(printf '%q' "$MAIN_FRESHNESS")"
[ -s "$MAIN_FRESH_STATE" ] || fail "3c: a real hold was cleared"
ok
_main_fresh_reason_disproved dirty-tree && fail "3c: a dirty tree read as disproved"
# A reason no read-only probe can refute is never touched (it asserts a heal attempt, not the tree).
git -C "$MAIN" checkout -q -- README.md
_main_fresh_reason_disproved ff-failed    && fail "3c: ff-failed must never be refuted read-only"
_main_fresh_reason_disproved rebase-failed && fail "3c: rebase-failed must never be refuted read-only"
_main_fresh_reason_disproved push-failed  && fail "3c: push-failed must never be refuted read-only"
_main_fresh_reason_disproved dirty-tree   || fail "3c: a clean tree must disprove dirty-tree"
_main_fresh_reason_disproved local-commits || fail "3c: a 0-ahead HEAD must disprove local-commits"
ok
# …and a HEAD genuinely ahead of origin keeps its local-commits hold.
printf 'local work\n' >> "$MAIN/README.md"; git -C "$MAIN" commit -qam local-work
_main_fresh_reason_disproved local-commits && fail "3c: an ahead HEAD read as disproved"
git -C "$MAIN" reset -q --hard "$SHA3"
ok

# (3d) DRYRUN withholds the disproved row but mutates NOTHING (an observation run writes no state).
printf 'dirty-tree 0 1\n' > "$MAIN_FRESH_STATE"
: > "$JLOG"
DRYRUN=1 build_main_freshness
[ -z "$MAIN_FRESHNESS" ] || fail "3d: dry-run painted a disproved row"
[ -s "$MAIN_FRESH_STATE" ] || fail "3d: dry-run deleted state"
[ -s "$JLOG" ] && fail "3d: dry-run journaled"
rm -f "$MAIN_FRESH_STATE"
ok
# No ledger at all ⇒ byte-inert (the happy path costs one `[ -s ]` and paints nothing).
build_main_freshness
[ -z "$MAIN_FRESHNESS" ] || fail "3d: a fresh \$MAIN painted something"
ok

# ══════════════════════════════════════════════════════════════════════════════════════════════════
# COUNT 4 — gate rows name the LIVE phase, read from the engine's own in-flight markers
# ══════════════════════════════════════════════════════════════════════════════════════════════════
FALLBACK="    🩺 feat-x #565 · gating · awaiting herd/gates blessing (BLOCKED)"
# A pid that is genuinely alive for the duration of this test (so _marker_live's recycling-guard
# identity check passes against a real, matching process start-time): this very shell.
LIVE_PID=$$

# (4c) first (the byte-identical baseline): no marker at all → the fallback, VERBATIM.
ROW="$(_gate_phase_row "feat-x" " #565 ·" 565 abc123 "$FALLBACK")"
[ "$ROW" = "$FALLBACK" ] || fail "4c: fallback not passed through verbatim: $ROW"
ok
# …and an empty sha can never invent a phase.
ROW="$(_gate_phase_row "feat-x" " #565 ·" 565 "" "$FALLBACK")"
[ "$ROW" = "$FALLBACK" ] || fail "4c: an empty sha produced a phase row: $ROW"
ok

# (4b) a live REVIEWER → 'review · in progress (<age>)' — the leg that was invisible on BOTH branches.
_marker_write "$(_review_inflight_file 565 abc123)" "$LIVE_PID"
ROW="$(_gate_phase_row "feat-x" " #565 ·" 565 abc123 "$FALLBACK")"
case "$ROW" in
  *"review · in progress"*) ok ;;
  *) fail "4b: a live reviewer did not surface: $ROW" ;;
esac
case "$ROW" in *"BLOCKED"*) fail "4b: blocked language survived a RUNNING pipeline: $ROW" ;; esac
ok

# (4a) a live HEALTH worker outranks it → the SHARED health-running row (identical bytes to the row
#      the health gate step itself emits, so the two renders in one tick never disagree).
_marker_write "$(_health_inflight_file "565-abc123")" "$LIVE_PID"
printf 'ok 1\nok 2\n' > "$(_health_log_file "565-abc123")"
ROW="$(_gate_phase_row "feat-x" " #565 ·" 565 abc123 "$FALLBACK")"
EXPECT_HEALTH="$(_health_running_row "feat-x" " #565 ·" "$(_health_inflight_file "565-abc123")" "$(_health_log_file "565-abc123")")"
[ "$ROW" = "$EXPECT_HEALTH" ] || fail "4a: the phase row is not the shared health row: $ROW"
ok
_gate_health_inflight 565 abc123 || fail "4a: the shared inflight predicate missed a live worker"
_gate_health_inflight 565 nosuch && fail "4a: the inflight predicate invented a worker"
ok

# A DEAD marker is not a phase: a crashed worker must fall back, never freeze a 'running' row.
_marker_write "$(_health_inflight_file "565-abc123")" 999999
rm -f "$(_review_inflight_file 565 abc123)"
ROW="$(_gate_phase_row "feat-x" " #565 ·" 565 abc123 "$FALLBACK")"
[ "$ROW" = "$FALLBACK" ] || fail "4a: a dead marker still rendered a live phase: $ROW"
ok

echo "PASS — console truth pass (HERD-453 + HERD-455 / GH #569): $pass assertions"
