#!/usr/bin/env bash
# test-main-health-chain-reconcile.sh — hermetic proof of the HERD-612 main-health reconcile legs.
#
# Four live-diagnosed failure shapes of the main-health rail (2026-08-07 → 2026-08-10), all of which
# ended the same way: a MAIN RED row standing for days with the evidence to retire it already on disk.
# Each leg below is asserted against the REAL functions in scripts/herd/agent-watch.sh (AGENT_WATCH_LIB=1),
# replaying the exact observed sequences:
#
#   (1) ANCHOR SURVIVES A REFUSABLE CLEAR — the root cause of the 4-day red. _main_health_ci_leg's pass
#       bucket deleted $MAIN_HEALTH_CI_STATE BEFORE calling _main_health_clear, which has a legitimate
#       REFUSAL path (HERD-453: a green whose sha is a STRICT ANCESTOR of the pinned red is not evidence
#       about the pinned tree). At 2026-08-07T00:33:41Z exactly that fired — green 72812f1 was a strict
#       ancestor of pinned 3bdd006 — so the anchor was gone, the clear refused, and every later pass read
#       the empty anchor as "no standing red" and returned byte-quiet without ever calling clear again.
#       Unlimited green evidence, zero reachable clear calls. Proven here: the refusal LEAVES the anchor
#       standing, and a later DESCENDANT green still clears through the ordinary path.
#   (2) ORPHAN-RECONCILE — the display ledger holding a CI-scoped identity while the anchor is absent is
#       a state nothing else can heal (only the fail bucket writes that file, and only on a CHANGED
#       conclusion). The reconcile recreates the anchor from the ledger row, which is what self-heals the
#       instance the pre-fix code left on this box.
#   (3) CHAIN-DEATH COLLECTION — `main_health result=dispatched pid=47281 sha=0f50601` never got a
#       terminal: the suite COMPLETED (its log read HEALTHCHECK CLEAN) but the worker died before the
#       verdict write. A dead pid with a complete log is now COLLECTED on the next tick; a dead pid with
#       no usable log re-dispatches (or retires honestly) instead of stranding.
#   (5) RECHECK ONE-SHOT (MAIN_HEALTH_RECHECK_ONESHOT, ship-dormant) — a red pinned to a sha that already
#       carries a run-once marker, with MAIN_HEALTH_RECHECK_MINS=0 and a quiescent main, has ZERO
#       clearing triggers: nothing in the engine can ever ask again. Proven both ways (off → byte-
#       identical, on → exactly one re-verify per sha).
#
# (Leg 4, the journal-audit blind spot for event=main_health result=dispatched, is proven in
# tests/test-journal-audit.sh alongside the other dispatch_no_outcome cases.)
#
# Hermetic: a throwaway git fixture stands in for $MAIN, the healthcheck binary is a stub on disk, `gh`
# is a stub on $PATH, and the notify edge is spied on (no herdr, no drainer, no network, no model).
# Run:  bash tests/test-main-health-chain-reconcile.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../scripts/herd/agent-watch.sh"
# Resolved HERE, before the source below: agent-watch.sh defines its own $HERE, so a path built from it
# further down would point inside scripts/herd instead of the repo root.
AUDIT="$HERE/../scripts/herd/journal-audit.sh"

# Pin our own precondition (HERD-458): a CONFIGURED caller can leave ambient MAIN_HEALTH_* / HEALTH_*
# exported, which every cadence assertion below would otherwise inherit instead of the unset default.
if [ -f "$HERE/../scripts/herd/hermetic-env-scrub.sh" ]; then
  # shellcheck source=/dev/null
  . "$HERE/../scripts/herd/hermetic-env-scrub.sh"
  herd_hermetic_env_scrub "$HERE/../scripts/herd/herd-config.sh"
fi

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ pass=$((pass+1)); printf 'ok — %s\n' "$1"; }

[ -f "$WATCH" ] || fail "agent-watch.sh not found at $WATCH"
command -v git >/dev/null 2>&1 || fail "git required"

# ── fixture: a throwaway repo that plays $MAIN, plus stub healthcheck + gh binaries ──────────────────
REPO="$T/main"; TREES_DIR="$T/trees"; mkdir -p "$REPO" "$TREES_DIR"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name  tester
printf 'seed\n' > "$REPO/seed.txt"
git -C "$REPO" add -A && git -C "$REPO" commit -q -m "Merge pull request #77 from someone/branch"

HC="$T/hc.sh"
cat > "$HC" <<'HCSTUB'
#!/usr/bin/env bash
case "$(cat "$HC_MODE" 2>/dev/null)" in
  red-file) echo "❌ code error — app/greet.test.sh → greet.test FAIL"; exit 1 ;;
  *)        echo "✅ clean — all tests pass"; exit 0 ;;
esac
HCSTUB
chmod +x "$HC"
export HC_MODE="$T/hc-mode"; printf 'green\n' > "$HC_MODE"

# $BIN stays FIRST on $PATH at all times: moving a stub aside would let PATH fall through to a REAL
# `gh` and make a live network call against this repo's own GitHub remote (the HERD-545 lesson).
BIN="$T/bin"; mkdir -p "$BIN"
cat > "$BIN/gh" <<'GHSTUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${GH_CALLS:-/dev/null}"
case "$1 $2" in
  "run list")     printf '%s\n' "${GH_RUNS:-}"; exit 0 ;;
  "workflow run") exit "${GH_WORKFLOW_RUN_RC:-0}" ;;
esac
exit 0
GHSTUB
chmod +x "$BIN/gh"
export PATH="$BIN:$PATH"
export GH_CALLS="$T/gh-calls.log"; : > "$GH_CALLS"

# ── source the real engine in lib mode, every state path pinned into the sandbox ─────────────────────
export AGENT_WATCH_LIB=1 NO_COLOR=1 HERD_DRIVER=headless
export HERD_CONFIG_FILE="$T/no-such-config"
export PROJECT_ROOT="$REPO" WORKTREES_DIR="$TREES_DIR"
export JOURNAL_FILE="$T/journal.jsonl"
export HERD_HEALTHCHECK_BIN="$HC"
export DEFAULT_BRANCH=origin/main
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"
for fn in reconcile_main_health _reconcile_main_health_chains _main_health_ci_anchor_reconcile \
          _main_health_red_oneshot _main_health_log_terminal_rc _main_health_detail_from_log \
          _main_health_clear _main_health_ci_leg _main_health_died _collect_main_health; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined after sourcing"
done
case "$MAIN_HEALTH_STATE" in "$TREES_DIR"/*) : ;; *) fail "MAIN_HEALTH_STATE escapes the sandbox" ;; esac
case "$MAIN_HEALTH_CI_STATE" in "$TREES_DIR"/*) : ;; *) fail "MAIN_HEALTH_CI_STATE escapes the sandbox" ;; esac

NOTIFY_LOG="$T/notify.log"; : > "$NOTIFY_LOG"
herd_driver_notify() { printf '%s\n' "$1" >> "$NOTIFY_LOG"; }
_main_health_scribe() { :; }

# ── helpers ─────────────────────────────────────────────────────────────────────────────────────────
head_sha() { git -C "$REPO" rev-parse HEAD; }
new_sha() {
  printf '%s\n' "$RANDOM$RANDOM" >> "$REPO/seed.txt"
  git -C "$REPO" add -A && git -C "$REPO" commit -q -m "${1:-chore: advance main}"
}
# grep -c already prints 0 on no-match (and exits 1) — a `|| printf 0` fallback would print it TWICE.
jcount() { local n; n="$(grep -c "$1" "$JOURNAL_FILE" 2>/dev/null)" || n=0; printf '%s' "${n:-0}"; }
ncount() { local n; n="$(grep -c "$1" "$NOTIFY_LOG"   2>/dev/null)" || n=0; printf '%s' "${n:-0}"; }
reset_state() {
  rm -rf "$TREES_DIR"; mkdir -p "$TREES_DIR"
  : > "$JOURNAL_FILE"; : > "$NOTIFY_LOG"; : > "$GH_CALLS"
}
# pin_red <sha> <since-pr> <local-identity> <ci-identity> — write the display ledger row directly, which
# is exactly the state _main_health_set_red leaves behind (US-separated, empty field = identity absent).
pin_red() { printf '%s\x1f%s\x1f%s\x1f%s\n' "$1" "$2" "$3" "$4" > "$MAIN_HEALTH_STATE"; }
ledger_field() {   # ledger_field <1..4>
  local _a _b _c _d
  IFS=$'\x1f' read -r _a _b _c _d < "$MAIN_HEALTH_STATE" 2>/dev/null || true
  case "$1" in 1) printf '%s' "$_a" ;; 2) printf '%s' "$_b" ;; 3) printf '%s' "$_c" ;; 4) printf '%s' "$_d" ;; esac
}
# chain <sha> <pr> — lay down the sidecar a dispatch writes and nothing else: the exact corpse a worker
# that died before its verdict write leaves behind (pr# sidecar, no marker, no result, no live worker).
chain() { printf '%s\n' "${2:-77}" > "$(_main_health_pr_file "$1")"; }
mhlog()  { local _l_sha="$1"; shift; printf '%s\n' "$@" > "$(_health_log_file "main-$_l_sha")"; }   # mhlog <sha> <line>...
# settle — DRAIN every backgrounded main-health worker, then collect, exactly as successive ticks do.
# Not "wait for one result": a tick-level reconcile can dispatch for the current HEAD as well as recover
# the chain under test, and a worker still running when the next block calls reset_state would write its
# result into the freshly recreated $TREES and pollute an unrelated assertion.
settle() {
  local n=0
  while [ "$n" -lt 400 ]; do
    _collect_main_health
    ls "$TREES_DIR"/.health-inflight-main-* >/dev/null 2>&1 || break
    sleep 0.05; n=$((n + 1))
  done
  _collect_main_health
}

MAIN_HEALTH_TICK=on
MAIN_HEALTH_RECHECK_MINS=0
MAIN_HEALTH_RECHECK_ONESHOT=off
MAIN_HEALTH_AUTOFIX=off
MAIN_HEALTH_CI_GATE=on

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# (1) THE AUG-7 REPLAY: a stale-green refusal must LEAVE THE ANCHOR STANDING
# ════════════════════════════════════════════════════════════════════════════════════════════════════
reset_state
ANCESTOR="$(head_sha)"                       # plays 72812f1 — the green that arrived too late
new_sha "fix: the merge that reds main"
PINNED="$(head_sha)"                         # plays 3bdd006 — the sha the CI red is pinned to
pin_red "$PINNED" "77" "" "CI build: FAILURE"
printf '%s failure 0\n' "$PINNED" > "$MAIN_HEALTH_CI_STATE"

export GH_RUNS='[{"headSha":"'"$ANCESTOR"'","status":"COMPLETED","conclusion":"SUCCESS","workflowName":"build","databaseId":1}]'
_main_health_ci_leg || fail "(1) _main_health_ci_leg returned non-zero on the ancestor-green pass"
[ "$(jcount '"reason":"stale-green"')" -eq 1 ] || fail "(1) the ancestor green did not take the HERD-453 refusal path"
[ -s "$MAIN_HEALTH_CI_STATE" ] || fail "(1) THE BUG: the refused clear left the anchor deleted — the CI red is now orphaned and unclearable"
[ -s "$MAIN_HEALTH_STATE" ] || fail "(1) the display ledger row vanished on a refused clear"
[ "$(ledger_field 4)" = "CI build: FAILURE" ] || fail "(1) the CI identity did not survive the refusal: '$(ledger_field 4)'"
[ "$(jcount '"event":"main_health_ci_anchor".*"result":"held"')" -eq 1 ] || fail "(1) the held anchor was not journaled"
ok "(1) a stale-green (strict-ancestor) refusal leaves \$MAIN_HEALTH_CI_STATE standing, not orphaned"

# Repeat scans keep refusing and keep the anchor — the deadlock is that the SECOND pass used to be
# byte-quiet forever, so assert the clear is still being REACHED, not just that the file is there.
_main_health_ci_leg
[ "$(jcount '"reason":"stale-green"')" -eq 2 ] || fail "(1) a later pass no longer reaches the clear at all (the deadlock)"
ok "(1) every later pass still REACHES the clear (an empty anchor would have gone byte-quiet forever)"

# And the payoff: a DESCENDANT green — the evidence that was always legitimate — clears it.
new_sha "fix: the change that actually repairs main"
DESCENDANT="$(head_sha)"
export GH_RUNS='[{"headSha":"'"$DESCENDANT"'","status":"COMPLETED","conclusion":"SUCCESS","workflowName":"build","databaseId":2}]'
_main_health_ci_leg
[ ! -s "$MAIN_HEALTH_STATE" ] || fail "(1) a descendant green did not clear the CI red: $(cat "$MAIN_HEALTH_STATE")"
[ ! -s "$MAIN_HEALTH_CI_STATE" ] || fail "(1) the anchor survived a REAL clear (it must only survive a refusal)"
[ "$(ncount 'main green')" -eq 1 ] || fail "(1) recovery was not notified exactly once"
ok "(1) a later DESCENDANT green clears the surviving anchor and retires the row — the deadlock is broken"

# A PARTIAL clear (the CI identity goes, a local red stays) still retires the anchor: the CI red really
# did clear, so keeping its anchor would re-open the same orphan class from the other side.
reset_state
pin_red "$PINNED" "77" "app/greet.test.sh" "CI build: FAILURE"
printf '%s failure 0\n' "$PINNED" > "$MAIN_HEALTH_CI_STATE"
export GH_RUNS='[{"headSha":"'"$PINNED"'","status":"COMPLETED","conclusion":"SUCCESS","workflowName":"build","databaseId":3}]'
_main_health_ci_leg
[ -s "$MAIN_HEALTH_STATE" ] || fail "(1) a partial clear wiped the standing LOCAL red"
[ -z "$(ledger_field 4)" ] || fail "(1) the CI identity was not cleared: '$(ledger_field 4)'"
[ ! -s "$MAIN_HEALTH_CI_STATE" ] || fail "(1) a partial clear kept the anchor for a CI red that is gone"
ok "(1) a PARTIAL clear (CI cleared, local still red) drops the anchor — only a refusal keeps it"

# EVERY collected verdict journals a TERMINAL for its own sha — including the one that clears nothing.
# Review BLOCK on the first cut of this PR: with a CI-scoped red standing (field4 set, field3 empty) —
# the HERD-434 "5 PRs merged while CI stayed red" composition this feature exists for — a later local
# suite going GREEN reaches _main_health_clear with an EMPTY own-identity, took the partial branch, and
# journaled NOTHING (the partial_clear line was guarded on the own-identity being non-empty). The engine
# was right (nothing to clear, the row stays up for the live CI red) but its dispatch chain ended with
# no terminal event at all, so leg 4's auditor could only read it as STRANDED — a false, unclearable
# finding per merged sha for the whole CI-red window. The journal must record a collected verdict even
# when that verdict moved nothing.
reset_state
pin_red "$PINNED" "77" "" "CI build: FAILURE"          # CI-scoped red standing, no local identity
printf '%s FAILURE 0\n' "$PINNED" > "$MAIN_HEALTH_CI_STATE"
chain "$DESCENDANT" 830
mhlog "$DESCENDANT" "✅ HEALTHCHECK CLEAN"
_reconcile_main_health_chains
_collect_main_health
[ "$(jcount '"sha":"'"$DESCENDANT"'"')" -ge 1 ] || fail "(1) the collected local green journaled NOTHING for its own sha — its dispatch chain has no terminal"
[ "$(jcount '"sha":"'"$DESCENDANT"'","result":"partial_clear"')" -eq 1 ] || fail "(1) the local green did not journal a partial_clear terminal: $(cat "$JOURNAL_FILE")"
grep -q '"cleared":"no"' "$JOURNAL_FILE" || fail "(1) the terminal does not record that this scope was already clear (nothing was moved)"
[ -s "$MAIN_HEALTH_STATE" ] || fail "(1) the local green wiped the standing CI red"
[ "$(ledger_field 4)" = "CI build: FAILURE" ] || fail "(1) the CI identity did not survive a local-scope green: '$(ledger_field 4)'"
[ "$(ncount 'main green')" -eq 0 ] || fail "(1) a partial (local-only) clear falsely notified full recovery"
ok "(1) a green collected in a scope that was NOT red still journals a terminal (cleared=no) — no chain ends silent"

# …and the terminal is honest the other way too: when this scope really was red, cleared=yes.
reset_state
pin_red "$PINNED" "77" "app/greet.test.sh" "CI build: FAILURE"
chain "$DESCENDANT" 831
mhlog "$DESCENDANT" "✅ HEALTHCHECK CLEAN"
_reconcile_main_health_chains
_collect_main_health
grep -q '"cleared":"yes"' "$JOURNAL_FILE" || fail "(1) a green that really did clear the local identity was not recorded as cleared=yes"
[ -z "$(ledger_field 3)" ] || fail "(1) the local identity was not cleared: '$(ledger_field 3)'"
ok "(1) the same terminal distinguishes a real clear (cleared=yes) from a no-op one (cleared=no)"

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# (2) ORPHAN-RECONCILE: a CI-scoped ledger row with no anchor self-heals
# ════════════════════════════════════════════════════════════════════════════════════════════════════
reset_state
pin_red "$PINNED" "77" "" "CI build: FAILURE"
rm -f "$MAIN_HEALTH_CI_STATE"                       # the live orphan the pre-fix code left on this box
_main_health_ci_anchor_reconcile || fail "(2) anchor reconcile returned non-zero"
[ -s "$MAIN_HEALTH_CI_STATE" ] || fail "(2) the orphaned CI row did not recreate its anchor"
grep -q "^${PINNED} " "$MAIN_HEALTH_CI_STATE" || fail "(2) the recreated anchor is not keyed on the pinned sha: $(cat "$MAIN_HEALTH_CI_STATE")"
grep -q ' FAILURE ' "$MAIN_HEALTH_CI_STATE" || fail "(2) the conclusion was not recovered from the ledger identity: $(cat "$MAIN_HEALTH_CI_STATE")"
[ "$(jcount '"reason":"orphaned-ledger-row"')" -eq 1 ] || fail "(2) the reconcile was not journaled"
ok "(2) a CI-scoped ledger row with an absent anchor recreates the anchor from the row itself"

# Reconciled, not event-driven: a second pass with the anchor now standing is a byte-quiet no-op.
_main_health_ci_anchor_reconcile
[ "$(jcount '"reason":"orphaned-ledger-row"')" -eq 1 ] || fail "(2) the reconcile re-fired with a healthy anchor standing"
ok "(2) a standing anchor is never re-written (the invariant is reconciled, not re-applied)"

# END-TO-END: the self-heal is only worth anything if the NEXT pass can now clear. This is the exact
# sequence the live box will run on its first tick after this merge.
export GH_RUNS='[{"headSha":"'"$DESCENDANT"'","status":"COMPLETED","conclusion":"SUCCESS","workflowName":"build","databaseId":4}]'
_main_health_ci_leg
[ ! -s "$MAIN_HEALTH_STATE" ] || fail "(2) the self-healed anchor still could not be cleared by a descendant green"
ok "(2) end-to-end: orphan → reconciled anchor → the very next descendant green retires the row"

# The conclusion token is round-tripped VERBATIM, whatever case it carries. Production is UPPERCASE —
# pysrc/herd/ci_verdict.py uppercases every conclusion (classify_runs: str(...).upper()) before the fail
# bucket builds "CI <workflow>: <conclusion>" — so the uppercase fixture above IS the live shape; this
# lowercase pass exists so the reconstruction can never quietly become case-normalizing, which would
# make the rebuilt anchor differ from the fail bucket's own line and cost one extra re-render.
reset_state
pin_red "$PINNED" "77" "" "CI build: failure"
rm -f "$MAIN_HEALTH_CI_STATE"
_main_health_ci_anchor_reconcile
grep -q " failure 0$" "$MAIN_HEALTH_CI_STATE" || fail "(2) the conclusion token was case-normalized instead of round-tripped: $(cat "$MAIN_HEALTH_CI_STATE")"
ok "(2) the conclusion is restored verbatim in either case (production uppercases via ci_verdict.py)"

# The qualified (starvation) identity shape carries its own cancelled count back into the anchor.
reset_state
pin_red "$PINNED" "77" "" "CI red at ${PINNED:0:7} · 4 newer runs cancelled · awaiting a completed run"
rm -f "$MAIN_HEALTH_CI_STATE"
_main_health_ci_anchor_reconcile
grep -q " 4$" "$MAIN_HEALTH_CI_STATE" || fail "(2) the cancelled count was not recovered: $(cat "$MAIN_HEALTH_CI_STATE")"
ok "(2) a HERD-545 qualified identity restores its cancelled count into the anchor"

# NEVER for a LOCAL-only red (the CI leg owns no clear for it) and never with the CI lever off.
reset_state
pin_red "$PINNED" "77" "app/greet.test.sh" ""
_main_health_ci_anchor_reconcile
[ ! -e "$MAIN_HEALTH_CI_STATE" ] || fail "(2) a LOCAL-only red invented a CI anchor"
MAIN_HEALTH_CI_GATE=off
pin_red "$PINNED" "77" "" "CI build: FAILURE"
_main_health_ci_anchor_reconcile
[ ! -e "$MAIN_HEALTH_CI_STATE" ] || fail "(2) MAIN_HEALTH_CI_GATE=off is not byte-inert: it wrote an anchor"
MAIN_HEALTH_CI_GATE=on
ok "(2) no anchor for a LOCAL-only red, and MAIN_HEALTH_CI_GATE=off stays byte-inert"

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# (3) CHAIN-DEATH COLLECTION: a dead pid with a COMPLETE log is collected, not stranded
# ════════════════════════════════════════════════════════════════════════════════════════════════════
# The live shape verbatim: the red is pinned to an ANCESTOR sha, the DEAD chain belongs to a newer sha
# whose suite log reads CLEAN, and main has since advanced past both (so the HEAD rules cannot see it).
reset_state
DEAD_SHA="$DESCENDANT"
pin_red "$ANCESTOR" "77" "app/greet.test.sh" ""
chain "$DEAD_SHA" 812
mhlog "$DEAD_SHA" "✅ HEALTHCHECK CLEAN" "all suites pass"
new_sha "chore: main moves on while a verdict is stranded"
_main_health_died "$DEAD_SHA" || fail "(3) setup: the fixture is not the died-chain state the HEAD path also uses"

reconcile_main_health || fail "(3) reconcile_main_health returned non-zero"
[ -e "$(_health_dispatch_file "main-$DEAD_SHA")" ] || fail "(3) the dead worker's completed log was not collected into a result file"
[ "$(jcount '"reason":"dead-pid-complete-log"')" -eq 1 ] || fail "(3) the chain collection was not journaled"
IFS=$'\t' read -r _c3_rc _c3_detail < "$(_health_dispatch_file "main-$DEAD_SHA")"
[ "$_c3_rc" = "0" ] || fail "(3) a HEALTHCHECK CLEAN log did not collect as rc 0 (got '$_c3_rc')"
ls "$TREES_DIR"/.health-write-chain-* >/dev/null 2>&1 && fail "(3) the staging temp file leaked into \$TREES"
ok "(3) a dead pid whose suite log is COMPLETE gets its result file written on the next tick"

# …and the ordinary collector routes it, retiring the pinned ANCESTOR red exactly as a live collect would.
_collect_main_health
[ "$(jcount '"sha":"'"$DEAD_SHA"'","result":"green"')" -eq 1 ] || fail "(3) the recovered verdict did not route as green"
[ ! -s "$MAIN_HEALTH_STATE" ] || fail "(3) the recovered green did not retire the red pinned to the ancestor sha"
[ -e "$(_main_health_marker "$DEAD_SHA")" ] || fail "(3) no run-once marker after the recovered collect"
[ ! -e "$(_main_health_pr_file "$DEAD_SHA")" ] || fail "(3) the pr# sidecar survived collection (the chain is still 'open')"
[ "$(ncount 'main green')" -eq 1 ] || fail "(3) recovery was not notified exactly once"
ok "(3) the recovered verdict routes through the ORDINARY collector: green, marker, sidecars freed, row retired"
settle                                        # drain the same tick's HEAD dispatch before the next block

# A dead chain whose log reproduces a RED collects as a red, naming the failing test — the collection is
# a verdict, not an amnesty.
reset_state
chain "$DEAD_SHA" 813
mhlog "$DEAD_SHA" "❌ CODE ERROR" "not ok 41 hermetic watcher health-cache test passes"
_reconcile_main_health_chains                 # the chain pass ALONE: a HEAD suite going green in the
_collect_main_health                          # same tick would clear the very row this asserts on
[ -s "$MAIN_HEALTH_STATE" ] || fail "(3) a CODE ERROR log collected without painting MAIN RED"
grep -q 'not ok 41' <<< "$(ledger_field 3)" || fail "(3) the collected red does not name the failing test: '$(ledger_field 3)'"
ok "(3) a dead chain whose log reproduces a red collects as MAIN RED, naming the failing test"

# A tab-leak-guard trip stays INFRA through this path too — the shared detail derivation is what keeps
# the collector's exemption from being re-implemented (and forgotten) here.
reset_state
chain "$DEAD_SHA" 814
mhlog "$DEAD_SHA" "❌ CODE ERROR" "tab-leak-guard: suite leaked an orphan tab into the live workspace — 3 -> 4"
_reconcile_main_health_chains
_collect_main_health
[ ! -s "$MAIN_HEALTH_STATE" ] || fail "(3) a leak-guard trip recovered from a log painted MAIN RED"
[ "$(jcount '"reason":"tab-leak-guard"')" -eq 1 ] || fail "(3) the leak-guard trip did not route to an infra_event"
ok "(3) a leak-guard trip recovered from a dead chain is infra, never MAIN RED (exemption not re-derived)"

# A log with NO terminal banner proves nothing: never collected, whatever it happens to contain.
reset_state
chain "$DEAD_SHA" 815
mhlog "$DEAD_SHA" "running suite…" "ok 1 something"
_reconcile_main_health_chains
[ ! -e "$(_health_dispatch_file "main-$DEAD_SHA")" ] || fail "(3) a truncated (mid-suite) log was collected as a verdict"
[ "$(jcount '"reason":"dead-pid-complete-log"')" -eq 0 ] || fail "(3) a truncated log journaled a chain collection"
ok "(3) a log with no terminal banner is never collected — the banner IS the completeness proof"

# A RETRY IN FLIGHT is not a verdict: "<log>" holds run 1's red while "<log>.retry" is mid-write, and
# collecting run 1 would paint a red the retry-before-red path may well have absorbed.
reset_state
chain "$DEAD_SHA" 816
mhlog "$DEAD_SHA" "❌ CODE ERROR" "not ok 7 flaky under load"
printf 'partial retry output\n' > "$(_health_log_file "main-$DEAD_SHA").retry"
_reconcile_main_health_chains
[ ! -e "$(_health_dispatch_file "main-$DEAD_SHA")" ] || fail "(3) run 1's red was collected while a retry was in flight"
ok "(3) a worker that died mid-RETRY never collects run 1's red (a false MAIN RED is the costlier mistake)"

# …but once the retry log itself is complete, IT is the verdict that gets collected. (Fresh chain: the
# pass above legitimately RETIRED that one — a logless dead chain for a stale, unpinned sha is a
# terminal outcome, so replaying it would be asserting against an already-closed chain.)
reset_state
chain "$DEAD_SHA" 816
mhlog "$DEAD_SHA" "❌ CODE ERROR" "not ok 7 flaky under load"
printf '%s\n' "✅ HEALTHCHECK CLEAN" > "$(_health_log_file "main-$DEAD_SHA").retry"
_reconcile_main_health_chains
IFS=$'\t' read -r _c3_rc _c3_detail < "$(_health_dispatch_file "main-$DEAD_SHA")"
[ "$_c3_rc" = "0" ] || fail "(3) the completed RETRY log was not the collected verdict (got rc '$_c3_rc')"
ok "(3) a completed retry log outranks run 1 — the retry's own verdict is what lands"

# A dead chain with NO log at all, for a sha that is neither HEAD nor the pinned red: retire it honestly
# rather than re-running a ~9-minute heavy suite for a tree nothing is pinned to.
reset_state
STALE_SHA="$ANCESTOR"
chain "$STALE_SHA" 817
_reconcile_main_health_chains
[ "$(jcount '"reason":"chain-death-no-log"')" -eq 1 ] || fail "(3) a stale logless chain was not retired with an infra_event"
[ -e "$(_main_health_marker "$STALE_SHA")" ] || fail "(3) the retired chain left no run-once marker (it can strand again)"
[ ! -e "$(_main_health_pr_file "$STALE_SHA")" ] || fail "(3) the retired chain left its sidecar behind"
[ "$(jcount '"result":"dispatched"')" -eq 0 ] || fail "(3) a stale, unpinned sha re-ran a heavy suite for nothing"
ok "(3) a logless dead chain for a stale, unpinned sha retires as an infra_event — a terminal, not a strand"

# …but the PINNED sha's own green is the one verdict that can retire the standing row, so IT re-dispatches
# immediately, bounded by the same death budget a serially-dying worker is bounded by.
reset_state
pin_red "$STALE_SHA" "77" "app/greet.test.sh" ""
chain "$STALE_SHA" 818
_reconcile_main_health_chains
[ "$(jcount '"provenance":"chain-death"')" -eq 1 ] || fail "(3) the PINNED sha's dead chain did not re-dispatch immediately"
settle
[ "$(cat "$(_main_health_retry_file "$STALE_SHA")" 2>/dev/null || printf 0)" = "0" ] || fail "(3) the death budget was not released by a successful collect"
ok "(3) a logless dead chain for the PINNED sha re-dispatches immediately (its green is the only clearing evidence)"

# The death budget is real: a chain that keeps dying with no log stops after _MAIN_HEALTH_DIED_MAX.
reset_state
pin_red "$STALE_SHA" "77" "app/greet.test.sh" ""
chain "$STALE_SHA" 819
printf '%s\n' "$_MAIN_HEALTH_DIED_MAX" > "$(_main_health_retry_file "$STALE_SHA")"
_reconcile_main_health_chains
[ "$(jcount '"provenance":"chain-death"')" -eq 0 ] || fail "(3) a capped chain re-dispatched anyway"
[ "$(jcount '"reason":"chain-death-no-log"')" -eq 1 ] || fail "(3) a capped chain did not surface as an infra_event"
ok "(3) serial logless deaths are bounded by _MAIN_HEALTH_DIED_MAX — an infra_event, never a suite loop"

# The CURRENT HEAD stays the died branch's own business, provenance and all — byte-identical to HERD-222.
reset_state
HEAD_SHA="$(head_sha)"
chain "$HEAD_SHA" 820
reconcile_main_health
[ "$(jcount '"provenance":"died"')" -eq 1 ] || fail "(3) the HEAD died branch stopped owning the current sha"
[ "$(jcount '"provenance":"chain-death"')" -eq 0 ] || fail "(3) the chain pass poached the HEAD sha from the died branch"
settle
ok "(3) the current HEAD's dead chain is still the HERD-222 died branch's, unchanged (provenance=died)"

# MAIN_HEALTH_TICK=off is byte-inert for the whole leg.
reset_state
chain "$DEAD_SHA" 821
mhlog "$DEAD_SHA" "✅ HEALTHCHECK CLEAN"
MAIN_HEALTH_TICK=off
_reconcile_main_health_chains
[ ! -e "$(_health_dispatch_file "main-$DEAD_SHA")" ] || fail "(3) MAIN_HEALTH_TICK=off collected a chain"
[ ! -s "$JOURNAL_FILE" ] || fail "(3) MAIN_HEALTH_TICK=off journaled: $(cat "$JOURNAL_FILE")"
MAIN_HEALTH_TICK=on
ok "(3) MAIN_HEALTH_TICK=off is byte-inert: no collection, no journal, no state"

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# (5) RECHECK ONE-SHOT: a standing red always keeps at least one armed clearing trigger
# ════════════════════════════════════════════════════════════════════════════════════════════════════
# The zero-trigger composition, verbatim: the pinned sha ALREADY has a run-once verdict marker, the
# cadence is 0 (the default), and main is quiescent — so nothing can ever re-ask.
arm_zero_trigger() {
  reset_state
  printf 'green\n' > "$HC_MODE"
  ZT_SHA="$(head_sha)"
  pin_red "$ZT_SHA" "77" "app/greet.test.sh" ""
  : > "$(_main_health_marker "$ZT_SHA")"
}

MAIN_HEALTH_RECHECK_ONESHOT=off
arm_zero_trigger
reconcile_main_health
[ "$(jcount '"result":"dispatched"')" -eq 0 ] || fail "(5) the default (off) lever re-verified a marked sha"
[ ! -s "$JOURNAL_FILE" ] || fail "(5) the default (off) lever journaled: $(cat "$JOURNAL_FILE")"
[ ! -e "$TREES_DIR/.main-health-oneshot-$ZT_SHA" ] || fail "(5) the default (off) lever wrote a one-shot marker"
ok "(5) MAIN_HEALTH_RECHECK_ONESHOT=off (default) is byte-identical: a marked sha is never re-run"

MAIN_HEALTH_RECHECK_ONESHOT=on
arm_zero_trigger
reconcile_main_health
[ "$(jcount '"reason":"no-trigger-armed"')" -eq 1 ] || fail "(5) a red with no armed trigger did not fire the one-shot re-verify"
[ "$(jcount '"provenance":"red-oneshot"')" -eq 2 ] || fail "(5) the one-shot's dispatch + recheck were not both stamped provenance=red-oneshot"
settle
[ ! -s "$MAIN_HEALTH_STATE" ] || fail "(5) the one-shot's green verdict did not retire the stale red"
[ "$(ncount 'main green')" -eq 1 ] || fail "(5) recovery was not notified exactly once"
ok "(5) MAIN_HEALTH_RECHECK_ONESHOT=on: a trigger-less red fires ONE re-verify and self-heals"

# ONE-shot means one: the per-sha marker survives the collect, so a still-red sha never loops the suite.
arm_zero_trigger
: > "$TREES_DIR/.main-health-oneshot-$ZT_SHA"          # this sha already spent its one-shot
reconcile_main_health
[ "$(jcount '"reason":"no-trigger-armed"')" -eq 0 ] || fail "(5) the one-shot re-fired for a sha that already spent it"
ok "(5) the once-guard is per-sha and survives restarts — a red can never loop the heavy suite"

# A busy HEALTH_CONCURRENCY slot DEFERS the one-shot rather than consuming it (the same rule the died
# budget follows: spend nothing until the suite is actually running).
arm_zero_trigger
printf '%s\n' "$$" > "$(_health_inflight_file "busy-probe")"     # hold the only slot with a LIVE pid
reconcile_main_health
[ "$(jcount '"reason":"no-trigger-armed"')" -eq 0 ] || fail "(5) the one-shot claimed to dispatch while the slot was busy"
[ ! -e "$TREES_DIR/.main-health-oneshot-$ZT_SHA" ] || fail "(5) a deferred one-shot consumed its once-guard"
rm -f "$(_health_inflight_file "busy-probe")"
reconcile_main_health
[ "$(jcount '"reason":"no-trigger-armed"')" -eq 1 ] || fail "(5) the deferred one-shot did not fire once the slot freed"
settle
ok "(5) a busy health slot defers the one-shot instead of consuming it; it fires once the slot frees"

# A CI-ONLY red never fires the LOCAL one-shot: a local green cannot clear a CI identity (HERD-372), and
# the CI leg is that identity's own trigger.
arm_zero_trigger
pin_red "$ZT_SHA" "77" "" "CI build: FAILURE"
reconcile_main_health
[ "$(jcount '"reason":"no-trigger-armed"')" -eq 0 ] || fail "(5) a CI-only red fired a local one-shot that could never clear it"
ok "(5) a CI-scoped red never fires the local one-shot (scope rules hold; the CI leg owns its clear)"

# A nonzero cadence takes over completely — the one-shot is the floor beneath it, never a second rail.
arm_zero_trigger
MAIN_HEALTH_RECHECK_MINS=30
touch -t 200001010000 "$(_main_health_marker "$ZT_SHA")"
reconcile_main_health
[ "$(jcount '"provenance":"recheck"')" -eq 1 ] || fail "(5) the ordinary cadence stopped re-verifying"
[ "$(jcount '"reason":"no-trigger-armed"')" -eq 0 ] || fail "(5) the one-shot fired alongside an armed cadence"
MAIN_HEALTH_RECHECK_MINS=0
settle
ok "(5) with MAIN_HEALTH_RECHECK_MINS armed the ordinary cadence owns the re-verify; the one-shot stays silent"

MAIN_HEALTH_RECHECK_ONESHOT=off

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# (4) CROSS-CHECK: the REAL auditor against the REAL engine's OWN journal
# ════════════════════════════════════════════════════════════════════════════════════════════════════
# Leg 4 asserts a property OF the journal ("every dispatched chain reaches a terminal") while the engine
# is what WRITES that journal, so proving each half against its own hand-written fixture proves nothing
# about the pair. That gap is not theoretical: it is exactly how the first cut of this PR shipped a
# false-finding bug (a partial clear that journaled nothing) — and replaying a real journal through the
# real scanner immediately turned up a SECOND one the fixtures could not see (a terminal written in the
# same whole-second as its dispatch read as "not later"). So the auditor is driven here over the journal
# the engine above actually produced, never a transcription of it.
audit_strand_findings() {
  local _au_now _au_n
  # An hour ahead of the events this test just wrote, so every dispatch is past the TTL.
  _au_now="$(date -u -v+1H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '+1 hour' +%Y-%m-%dT%H:%M:%SZ)"
  rm -f "$T/audit-seen" "$T/audit-inbox"
  JOURNAL_AUDIT=on JOURNAL_AUDIT_ACT=off \
  HERD_JOURNAL_AUDIT_INBOX="$T/audit-inbox" HERD_JOURNAL_AUDIT_SEEN="$T/audit-seen" \
  HERD_APPROVALS_FILE="$T/audit-approvals" HERD_JOURNAL_AUDIT_PR_BODY_CMD="/usr/bin/true" \
  HERD_JOURNAL_AUDIT_NOW="$_au_now" JOURNAL_AUDIT_DISPATCH_TTL=1 JOURNAL_AUDIT_RED_TTL=999999 \
  JOURNAL_AUDIT_MERGE_GRACE=999999 JOURNAL_AUDIT_PUSHED_GRACE=999999 \
    bash "$AUDIT" >/dev/null 2>&1
  _au_n="$(grep -c '"kind":"dispatch_no_outcome"' "$JOURNAL_FILE" 2>/dev/null)" || _au_n=0
  printf '%s' "${_au_n:-0}"
}
[ -f "$AUDIT" ] || fail "(4) journal-audit.sh not found at $AUDIT"

# THE COMPOSITION THE REVIEW BLOCKED ON: a CI-scoped red standing while the local suite goes green on a
# newer sha, collected through the real collector. Every merged sha does this for the whole duration of
# a CI-red window, so a false finding here is not an edge case — it is a per-merge alarm.
reset_state
pin_red "$PINNED" "78" "" "CI build: FAILURE"
printf '%s FAILURE 0
' "$PINNED" > "$MAIN_HEALTH_CI_STATE"
printf 'green\n' > "$HC_MODE"
_main_health_dispatch 78 "$DESCENDANT" observed-sha || fail "(4) setup: the suite did not dispatch"
settle
[ "$(jcount '"sha":"'"$DESCENDANT"'","result":"dispatched"')" -eq 1 ] || fail "(4) setup: no dispatch event to reconcile"
[ -s "$MAIN_HEALTH_STATE" ] || fail "(4) setup: the local green wiped the standing CI red"
[ "$(audit_strand_findings)" -eq 0 ] || fail "(4) the REAL auditor called a completed chain stranded: $(cat "$JOURNAL_FILE")"
ok "(4) cross-check: a real collected-under-CI-red chain raises ZERO dispatch_no_outcome findings"

# The auditor is not merely silent — it still catches the real thing. A dispatch the engine journals and
# nothing ever collects (journaled through the engine's OWN emitter, so the shape is authentic) is the
# Aug-7 strand, and it must still surface.
reset_state
journal_append main_health pr 812 sha "$DEAD_SHA" result dispatched pid 999999 provenance observed-sha
[ "$(audit_strand_findings)" -eq 1 ] || fail "(4) a genuinely stranded chain went unreported: $(cat "$JOURNAL_FILE")"
ok "(4) cross-check: a genuinely stranded chain still surfaces as dispatch_no_outcome"

# ── unit floor: the log classifier both new paths route through ──────────────────────────────────────
LOGT="$T/classify.log"
printf '%s\n' "✅ HEALTHCHECK CLEAN" > "$LOGT"; [ "$(_main_health_log_terminal_rc "$LOGT")" = "0" ] || fail "(u) CLEAN banner ≠ rc 0"
printf '%s\n' "✅ clean — all tests pass" > "$LOGT"; [ "$(_main_health_log_terminal_rc "$LOGT")" = "0" ] || fail "(u) --oneline clean banner ≠ rc 0"
printf '%s\n' "⚠️  DATA/ENV ISSUE (tolerated, not a code bug)" > "$LOGT"; [ "$(_main_health_log_terminal_rc "$LOGT")" = "0" ] || fail "(u) data/env banner ≠ rc 0"
printf '%s\n' "⚠️  INHERITED BASE FAILURE(S) — 2 failing test(s) already fail on origin/main" > "$LOGT"; [ "$(_main_health_log_terminal_rc "$LOGT")" = "0" ] || fail "(u) inherited-base banner ≠ rc 0"
printf '%s\n' "❌ CODE ERROR" > "$LOGT"; [ "$(_main_health_log_terminal_rc "$LOGT")" = "1" ] || fail "(u) CODE ERROR banner ≠ rc 1"
printf '%s\n' "❌ code error — app/greet.test.sh FAIL" > "$LOGT"; [ "$(_main_health_log_terminal_rc "$LOGT")" = "1" ] || fail "(u) --oneline code-error banner ≠ rc 1"
printf '%s\n' "1..40" "ok 1 something" > "$LOGT"; _main_health_log_terminal_rc "$LOGT" >/dev/null && fail "(u) a bannerless log was classified as terminal"
: > "$LOGT"; _main_health_log_terminal_rc "$LOGT" >/dev/null && fail "(u) an empty log was classified as terminal"
_main_health_log_terminal_rc "$T/no-such-log" >/dev/null && fail "(u) a missing log was classified as terminal"
ok "(u) _main_health_log_terminal_rc: every healthcheck banner classified, everything else refused"

printf '\n%s checks passed — HERD-612 main-health chain/anchor reconcile.\n' "$pass"
