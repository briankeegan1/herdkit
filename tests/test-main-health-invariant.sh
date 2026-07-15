#!/usr/bin/env bash
# test-main-health-invariant.sh — hermetic test of MAIN-HEALTH AS A RECONCILED INVARIANT (HERD-222).
#
# Before HERD-222 the main-health suite ran ONLY as a do_merge side-effect, so three states stranded:
# a merge by ANOTHER seat never ran it at all, a no-slot deferral waited for the next MERGE (not the
# next tick), and a worker killed mid-suite left its sha with no verdict and nothing to re-dispatch it.
# reconcile_main_health closes all three with one rule — every OBSERVED main sha ends with a collected
# verdict — plus two ship-dormant levers.
#
# Asserted here, driving the REAL functions from scripts/herd/agent-watch.sh (AGENT_WATCH_LIB=1):
#   (a) OBSERVED-SHA — a main HEAD that no do_merge ever announced dispatches EXACTLY ONE suite
#       (provenance=observed-sha); a second reconcile on the marked sha dispatches nothing; a NEW sha
#       dispatches again. The 'since' attribution is the PR named in the commit subject, or "?".
#   (b) RED RE-VERIFY — with MAIN_HEALTH_RECHECK_MINS>0 a standing red re-runs the CURRENT sha only
#       after the cadence elapses; a green re-verify clears the state and notifies recovery ONCE.
#   (c) DIED WORKER — a worker killed before collect (the health_died corpse) is re-dispatched, once
#       per tick, and the re-dispatch is BOUNDED (_MAIN_HEALTH_DIED_MAX) so a serially-dying worker
#       surfaces as an infra_event instead of looping a heavy suite forever.
#   (d) AUTOFIX — MAIN_HEALTH_AUTOFIX=on files ONE scribe item per distinct HONEST failing identity
#       (a TAP 'not ok' line, or a concrete test file); a content-free classifier banner files nothing.
#       Dedup is a SHARED-POOL invariant (HERD-371, pysrc/herd/store.py), not seat memory: a second
#       reproduction of the SAME identity journals result=dedup instead of silently doing nothing; a
#       green run clears the marker so a LATER regression of the same test files fresh; a DIFFERENT
#       failing test is never conflated with an already-marked one.
#   (e) LEVERS OFF → BYTE-IDENTICAL — MAIN_HEALTH_RECHECK_MINS=0 never re-runs a marked sha,
#       MAIN_HEALTH_AUTOFIX=off never enqueues or journals, MAIN_HEALTH_TICK=off is fully inert.
#
# Hermetic: a throwaway git fixture stands in for $MAIN, the healthcheck binary is a stub on disk, and
# the notify + scribe edges are spied on (no herdr, no drainer, no network, no model).
# Run:  bash tests/test-main-health-invariant.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../scripts/herd/agent-watch.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ pass=$((pass+1)); printf 'ok — %s\n' "$1"; }

[ -f "$WATCH" ] || fail "agent-watch.sh not found at $WATCH"
command -v git >/dev/null 2>&1 || fail "git required"

# ── fixture: a throwaway repo that plays $MAIN, plus a stub healthcheck bin ──────────────────────────
REPO="$T/main"; TREES_DIR="$T/trees"; mkdir -p "$REPO" "$TREES_DIR"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name  tester
printf 'seed\n' > "$REPO/seed.txt"
git -C "$REPO" add -A && git -C "$REPO" commit -q -m "Merge pull request #77 from someone/branch"

# The stub's verdict is switched by a control file, so one binary drives green, red and slow runs. The
# RED shapes are the two the classifier must tell apart: an HONEST failing identity (a concrete test
# file / a TAP 'not ok' line) and a content-free classifier banner.
HC="$T/hc.sh"
cat > "$HC" <<'HCSTUB'
#!/usr/bin/env bash
case "$(cat "$HC_MODE" 2>/dev/null)" in
  green) echo "✅ clean — all tests pass"; exit 0 ;;
  red-file) echo "❌ code error — app/greet.test.sh → greet.test FAIL"; exit 1 ;;
  red-tap) printf '%s\n' "❌ CODE ERROR" "not ok 41 hermetic watcher health-cache test passes"; exit 1 ;;
  red-banner) echo "❌ CODE ERROR"; exit 1 ;;
  slow) sleep 30; echo "✅ clean"; exit 0 ;;
  *) echo "✅ clean"; exit 0 ;;
esac
HCSTUB
chmod +x "$HC"
export HC_MODE="$T/hc-mode"; printf 'green\n' > "$HC_MODE"

# `gh` stub for the branch-CI leg (HERD-334/HERD-372): _main_health_ci_leg → `gh run list … --json …` →
# GH_RUNS (network-free, no real Actions calls).
BIN="$T/bin"; mkdir -p "$BIN"
cat > "$BIN/gh" <<'GHSTUB'
#!/usr/bin/env bash
case "$1 $2" in
  "run list") printf '%s\n' "${GH_RUNS:-}"; exit 0 ;;
esac
exit 0
GHSTUB
chmod +x "$BIN/gh"
export PATH="$BIN:$PATH"

# ── source the real engine in lib mode, with every state path pinned into the sandbox ────────────────
# WORKTREES_DIR must be exported BEFORE sourcing: $TREES (and the main-health state paths derived from
# it at source time) are bound there. journal_append resolves its own path from WORKTREES_DIR too.
export AGENT_WATCH_LIB=1 NO_COLOR=1 HERD_DRIVER=headless
export HERD_CONFIG_FILE="$T/no-such-config"
export PROJECT_ROOT="$REPO" WORKTREES_DIR="$TREES_DIR"
export JOURNAL_FILE="$T/journal.jsonl"
export HERD_HEALTHCHECK_BIN="$HC"
export DEFAULT_BRANCH=main
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"
for fn in reconcile_main_health _main_health_dispatch _main_health_died _main_health_autofix \
          _main_health_honest_identity _main_health_observed_pr main_health_tick; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined after sourcing"
done
case "$(_journal_file)" in "$T"/*) : ;; *) fail "journal path escapes the sandbox" ;; esac
case "$MAIN_HEALTH_STATE" in "$TREES_DIR"/*) : ;; *) fail "MAIN_HEALTH_STATE escapes the sandbox" ;; esac

# Spy on the two side-effecting edges. Both are real seams the shipped code calls; replacing them keeps
# the test off the desktop and out of the scribe drainer while still proving they were reached.
NOTIFY_LOG="$T/notify.log"; : > "$NOTIFY_LOG"
SCRIBE_LOG="$T/scribe.log"; : > "$SCRIBE_LOG"
herd_driver_notify() { printf '%s\n' "$1" >> "$NOTIFY_LOG"; }
_main_health_scribe() { printf '%s\n' "$1" >> "$SCRIBE_LOG"; }

# ── helpers ─────────────────────────────────────────────────────────────────────────────────────────
head_sha() { git -C "$REPO" rev-parse HEAD; }
# settle — await the backgrounded worker's dispatch result (bounded), then collect it, exactly as the
# watcher tick does. Returns immediately when nothing was dispatched (the inert / deferred paths).
settle() {
  local n=0
  while [ "$n" -lt 400 ]; do
    ls "$TREES_DIR"/.health-dispatch-main-* >/dev/null 2>&1 && break
    ls "$TREES_DIR"/.health-inflight-main-* >/dev/null 2>&1 || break
    sleep 0.05; n=$((n + 1))
  done
  _collect_main_health
}
# grep -c already prints 0 on no-match (and exits 1) — a `|| printf 0` fallback would print it TWICE.
jcount() { local n; n="$(grep -c "$1" "$JOURNAL_FILE" 2>/dev/null)" || n=0; printf '%s' "${n:-0}"; }
ncount() { local n; n="$(grep -c "$1" "$NOTIFY_LOG"   2>/dev/null)" || n=0; printf '%s' "${n:-0}"; }
reset_state() {
  rm -rf "$TREES_DIR"; mkdir -p "$TREES_DIR"
  : > "$JOURNAL_FILE"; : > "$NOTIFY_LOG"; : > "$SCRIBE_LOG"
}
# new_sha <subject> — advance $MAIN's HEAD, as a merge by ANY seat would.
new_sha() {
  printf '%s\n' "$RANDOM$RANDOM" >> "$REPO/seed.txt"
  git -C "$REPO" add -A && git -C "$REPO" commit -q -m "$1"
}

MAIN_HEALTH_TICK=on
MAIN_HEALTH_RECHECK_MINS=0
MAIN_HEALTH_AUTOFIX=off

# ── (a) OBSERVED-SHA: a HEAD nobody announced dispatches exactly one suite ───────────────────────────
reset_state
printf 'green\n' > "$HC_MODE"
reconcile_main_health || fail "(a) reconcile_main_health returned non-zero"
[ "$(jcount '"provenance":"observed-sha"')" -eq 1 ] || fail "(a) observed sha did not dispatch exactly one suite"
settle
[ "$(jcount '"result":"green"')" -eq 1 ] || fail "(a) the collected verdict was not green"
[ -e "$(_main_health_marker "$(head_sha)")" ] || fail "(a) no run-once marker after collect"
# The commit subject names PR #77 — that is the honest attribution for a merge this seat never made.
[ "$(_main_health_observed_pr "$(head_sha)")" = "77" ] || fail "(a) observed pr# not read from the commit subject"
ok "(a) an observed main sha dispatches one suite (provenance=observed-sha) and collects a verdict"

# A second reconcile on the SAME sha is a no-op: the marker is the run-once invariant.
reconcile_main_health
[ "$(jcount '"result":"dispatched"')" -eq 1 ] || fail "(a) a marked sha re-dispatched"
ok "(a) a sha that already has a verdict never re-dispatches"

# A NEW sha — a cross-seat merge, with no do_merge on this seat — dispatches again on the next tick.
new_sha "chore: another seat merged this"
reconcile_main_health
[ "$(jcount '"result":"dispatched"')" -eq 2 ] || fail "(a) a new main sha did not dispatch"
settle
[ "$(jcount '"result":"green"')" -eq 2 ] || fail "(a) the new sha did not collect green"
ok "(a) a cross-seat merge (HEAD moved, no do_merge) dispatches within one tick"

# do_merge's fast path stays redundant-but-harmless: main_health_tick on a marked sha does nothing.
main_health_tick 99
[ "$(jcount '"result":"dispatched"')" -eq 2 ] || fail "(a) main_health_tick re-dispatched a marked sha"
ok "(a) main_health_tick on an already-reconciled sha is a no-op (redundant but harmless)"

# ── (b) RED RE-VERIFY: a stale red self-heals on the cadence, recovery notified once ─────────────────
reset_state
printf 'red-file\n' > "$HC_MODE"
new_sha "fix: a change that reds main"
reconcile_main_health; settle
[ -s "$MAIN_HEALTH_STATE" ] || fail "(b) a reproduced red left no state file"
[ "$(ncount 'MAIN RED')" -eq 1 ] || fail "(b) MAIN RED was not notified exactly once"
ROW="$(build_main_health; printf '%s' "${MAIN_HEALTH:-}")"
printf '%s' "$ROW" | grep -q 'app/greet.test.sh' || fail "(b) the row does not name the failing test: $ROW"
ok "(b) a reproduced red paints MAIN RED once, naming the failing test"

# Cadence OFF (the default): a marked sha is never re-verified, however old the verdict.
MAIN_HEALTH_RECHECK_MINS=0
touch -t 200001010000 "$(_main_health_marker "$(head_sha)")"
reconcile_main_health
[ "$(jcount '"result":"dispatched"')" -eq 1 ] || fail "(e) RECHECK_MINS=0 re-verified a marked sha"
[ "$(jcount '"result":"recheck"')" -eq 0 ]    || fail "(e) RECHECK_MINS=0 journaled a recheck"
ok "(e) MAIN_HEALTH_RECHECK_MINS=0 (default) never re-runs a sha that has a verdict"

# Cadence ON, but the verdict is FRESH → still no re-verify (the rate limit is what makes this safe).
MAIN_HEALTH_RECHECK_MINS=30
: > "$(_main_health_marker "$(head_sha)")"       # a just-collected verdict
reconcile_main_health
[ "$(jcount '"result":"dispatched"')" -eq 1 ] || fail "(b) a fresh verdict was re-verified before the cadence elapsed"
ok "(b) the re-verify is rate-limited: a fresh verdict is not re-run"

# Cadence elapsed + main since FIXED → the re-verify clears the red and notifies recovery exactly once.
printf 'green\n' > "$HC_MODE"
touch -t 200001010000 "$(_main_health_marker "$(head_sha)")"
reconcile_main_health
[ "$(jcount '"provenance":"recheck"')" -eq 1 ] || fail "(b) an elapsed cadence did not re-verify the current sha"
settle
[ -s "$MAIN_HEALTH_STATE" ] && fail "(b) a green re-verify did not clear the red state"
[ "$(ncount 'main green')" -eq 1 ] || fail "(b) recovery was not notified exactly once"
ROW="$(build_main_health; printf '%s' "${MAIN_HEALTH:-}")"
[ -z "$ROW" ] || fail "(b) the MAIN RED row survived recovery: $ROW"
# And the now-green sha settles: no further re-verify (the state file is what drives the cadence).
reconcile_main_health
[ "$(jcount '"result":"dispatched"')" -eq 2 ] || fail "(b) a green sha kept re-verifying"
ok "(b) a stale red re-verifies on the cadence, clears itself, and notifies recovery once"
MAIN_HEALTH_RECHECK_MINS=0

# ── (c) DIED WORKER: a killed suite is re-dispatched, once, and bounded ──────────────────────────────
reset_state
printf 'slow\n' > "$HC_MODE"
new_sha "chore: a sha whose worker will die"
SHA="$(head_sha)"

# kill_worker — kill the backgrounded worker recorded in the inflight marker, reap it so its pid can
# never read as live, then let the corpse sweep do what it does on a restart: drop the marker, journal
# health_died. That is exactly the state that used to strand the sha forever.
kill_worker() {
  local pid; pid="$(_marker_pid "$(_health_inflight_file "main-$SHA")")"
  [ -n "$pid" ] || fail "(c) no worker pid recorded in the inflight marker"
  kill -9 "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  _sweep_gate_corpses
}

reconcile_main_health
[ "$(jcount '"provenance":"observed-sha"')" -eq 1 ] || fail "(c) the first dispatch did not happen"
kill_worker
[ "$(jcount '"reason":"health_died"')" -ge 1 ] || fail "(c) the corpse sweep did not journal health_died"
_main_health_died "$SHA" || fail "(c) a killed-before-collect sha is not detected as died"

reconcile_main_health
[ "$(jcount '"provenance":"died"')" -eq 1 ] || fail "(c) a died sha was not re-dispatched"
# A live re-dispatch must not be dispatched AGAIN on the very next tick.
reconcile_main_health
[ "$(jcount '"provenance":"died"')" -eq 1 ] || fail "(c) the died sha re-dispatched while its worker was live"
ok "(c) a worker that died before collect is re-dispatched exactly once per tick"

kill_worker
reconcile_main_health
[ "$(jcount '"provenance":"died"')" -eq 2 ] || fail "(c) the second death did not re-dispatch"
kill_worker
reconcile_main_health
[ "$(jcount '"reason":"died-cap"')" -eq 1 ] || fail "(c) serial deaths did not reach the died-cap"
[ -e "$(_main_health_marker "$SHA")" ] || fail "(c) the capped sha was not marked (the loop would continue)"
reconcile_main_health
[ "$(jcount '"provenance":"died"')" -eq 2 ] || fail "(c) the capped sha kept re-dispatching"
[ -s "$MAIN_HEALTH_STATE" ] && fail "(c) an infra death painted MAIN RED (it must never)"
ok "(c) serial worker deaths are bounded: an infra_event, never an endless suite loop"

# (c') THE DEATH BUDGET COUNTS DEATHS, NOT TICKS (review BLOCK, round 1). HEALTH_CONCURRENCY defaults to
# 1 and that slot is shared with every per-PR gate suite, so a died sha routinely meets ticks on which no
# dispatch is possible. If a deferred tick charged a death, three slot-contended ticks would reach the cap
# and mark a sha whose suite NEVER RAN — silently abandoning the invariant, suppressing a real MAIN RED,
# and (at the default RECHECK_MINS=0) stranding that sha permanently.
reset_state
printf 'slow\n' > "$HC_MODE"
new_sha "chore: a sha whose worker dies into a busy slot"
SHA="$(head_sha)"
reconcile_main_health                                    # dispatch #1 (a free slot)
kill_worker                                              # → died, no verdict, budget still 0

# Occupy the ONLY health slot with a live foreign holder, exactly as a per-PR gate suite does.
sleep 60 & HOLDER=$!
_marker_write "$(_health_inflight_file "probe-busy")" "$HOLDER"
_health_slot_free && fail "(c') the planted holder did not occupy the health slot"

for _t in 1 2 3 4; do reconcile_main_health; done        # four ticks, all of them deferrals
[ "$(jcount '"provenance":"died"')" -eq 0 ] || fail "(c') a deferred tick dispatched a suite"
[ "$(jcount '"reason":"died-cap"')" -eq 0 ] || fail "(c') slot contention burned the death budget to the cap"
[ -e "$(_main_health_marker "$SHA")" ] && fail "(c') a sha whose suite never ran was marked as verified"
[ "$(cat "$(_main_health_retry_file "$SHA")" 2>/dev/null || printf 0)" -eq 0 ] \
  || fail "(c') a deferred tick was charged as a death"
# The deferral is journaled ONCE, not once per tick (the defer memo), and it is honest about the reason.
[ "$(jcount '"reason":"no-slot"')" -eq 1 ] || fail "(c') the no-slot deferral was not journaled exactly once"
ok "(c') a busy health slot never charges a death, never caps, never marks an unverified sha"

# Free the slot: the very next tick must re-dispatch the still-died sha — it was deferred, not abandoned.
kill -9 "$HOLDER" 2>/dev/null || true; wait "$HOLDER" 2>/dev/null || true
rm -f "$(_health_inflight_file "probe-busy")"
printf 'green\n' > "$HC_MODE"
_main_health_died "$SHA" || fail "(c') the sha stopped being died while merely deferred"
reconcile_main_health
[ "$(jcount '"provenance":"died"')" -eq 1 ] || fail "(c') the deferred died sha did not re-dispatch once the slot freed"
settle
[ "$(jcount '"result":"green"')" -ge 1 ] || fail "(c') the re-dispatched sha never reached a verdict"
ok "(c') once the slot frees, the deferred sha re-dispatches and reaches a verdict"

# (c'') The RECHECK path must not drop the run-once marker on a tick that only defers.
reset_state
printf 'red-file\n' > "$HC_MODE"
new_sha "feat: a red we will try to recheck into a busy slot"
reconcile_main_health; settle
[ -s "$MAIN_HEALTH_STATE" ] || fail "(c'') setup: the red did not paint"
MAIN_HEALTH_RECHECK_MINS=30
touch -t 200001010000 "$(_main_health_marker "$(head_sha)")"
sleep 60 & HOLDER=$!
_marker_write "$(_health_inflight_file "probe-busy")" "$HOLDER"
reconcile_main_health
[ -e "$(_main_health_marker "$(head_sha)")" ] || fail "(c'') a deferred recheck dropped the run-once marker"
[ "$(jcount '"result":"recheck"')" -eq 0 ]   || fail "(c'') a deferred recheck journaled as if it ran"
kill -9 "$HOLDER" 2>/dev/null || true; wait "$HOLDER" 2>/dev/null || true
rm -f "$(_health_inflight_file "probe-busy")"
MAIN_HEALTH_RECHECK_MINS=0
ok "(c'') a recheck that defers on a busy slot leaves the marker and the verdict intact"

# ── (d) AUTOFIX: one item per distinct HONEST identity; a banner files nothing ───────────────────────
reset_state
MAIN_HEALTH_AUTOFIX=on
printf 'red-file\n' > "$HC_MODE"
new_sha "feat: reds main with an honest failing test"
reconcile_main_health; settle
[ "$(jcount '"event":"main_health_autofix".*"result":"enqueued"')" -eq 1 ] || fail "(d) an honest red filed no item"
[ "$(grep -c . "$SCRIBE_LOG")" -ge 1 ] || fail "(d) nothing reached the scribe seam"
grep -q '^MAIN RED: fix app/greet.test.sh$' "$SCRIBE_LOG" || fail "(d) the scribe title is not a short line naming the test"
grep -q 'Failing test:' "$SCRIBE_LOG" || fail "(d) the scribe body does not cite the failing test"
ok "(d) MAIN_HEALTH_AUTOFIX=on files ONE scribe item citing the failing test"

# The SAME failure reproduced by a re-verify must not re-file (the shared-pool dedup marker, HERD-371):
# exactly one enqueue overall, and the SECOND reproduction is journaled as an honest dedup — never a
# silent no-op indistinguishable from "nothing happened".
MAIN_HEALTH_RECHECK_MINS=30
touch -t 200001010000 "$(_main_health_marker "$(head_sha)")"
reconcile_main_health; settle
[ "$(jcount '"event":"main_health_autofix".*"result":"enqueued"')" -eq 1 ] || fail "(d) the same failure was re-filed"
[ "$(jcount '"event":"main_health_autofix".*"result":"dedup"')" -eq 1 ]    || fail "(d) the second reproduction was not journaled as a dedup"
MAIN_HEALTH_RECHECK_MINS=0
ok "(d) a re-verify that reproduces the same failure files nothing more, journaled as a dedup"

# A green run clears the shared-pool marker, so a LATER regression of the SAME test files fresh.
printf 'green\n' > "$HC_MODE"
MAIN_HEALTH_RECHECK_MINS=30
touch -t 200001010000 "$(_main_health_marker "$(head_sha)")"
reconcile_main_health; settle
[ -s "$MAIN_HEALTH_STATE" ] && fail "(d) the green re-verify did not clear main red"
MAIN_HEALTH_RECHECK_MINS=0
printf 'red-file\n' > "$HC_MODE"
new_sha "feat: the same failing test regresses again after main went green"
reconcile_main_health; settle
[ "$(jcount '"event":"main_health_autofix".*"result":"enqueued"')" -eq 2 ] || fail "(d) a regression of the same test after green did not file fresh"
ok "(d) a green run clears the marker: a LATER regression of the same test files fresh"

# A DIFFERENT failing test is never conflated with an already-marked one — it always files.
printf 'red-tap\n' > "$HC_MODE"
new_sha "feat: a different test reds main while the pool still holds no marker for it"
reconcile_main_health; settle
[ "$(jcount '"event":"main_health_autofix".*"result":"enqueued"')" -eq 3 ] || fail "(d) a different failing test did not file"
ok "(d) a different failing test files fresh, independent of any other identity's marker"

# A content-free classifier banner is NOT an honest identity: skip, file nothing.
reset_state
printf 'red-banner\n' > "$HC_MODE"
new_sha "feat: reds main with no honest identity"
reconcile_main_health; settle
[ -s "$MAIN_HEALTH_STATE" ] || fail "(d) the banner red did not paint MAIN RED (it still must)"
[ "$(jcount '"result":"skipped".*"reason":"dishonest-identity"')" -eq 1 ] || fail "(d) a banner-only red was not skipped"
[ "$(grep -c . "$SCRIBE_LOG")" -eq 0 ] || fail "(d) a banner-only red filed an item"
ok "(d) a content-free classifier banner files nothing (the alarm never cries wolf into the tracker)"

# A TAP 'not ok' line is honest even though it names no file.
_main_health_honest_identity "not ok 41 hermetic watcher health-cache test passes" \
                             "not ok 41 hermetic watcher health-cache test passes" \
  || fail "(d) a TAP not-ok line is not treated as an honest identity"
_main_health_honest_identity "❌ CODE ERROR" "❌ CODE ERROR" \
  && fail "(d) the classifier banner is treated as an honest identity"
_main_health_honest_identity "tab-leak-guard: suite leaked an orphan tab into the live workspace — 3 -> 4" \
                             "tab-leak-guard: suite leaked an orphan tab" \
  && fail "(d) a tab-leak-guard infra trip is treated as an honest identity"
ok "(d) honest-identity classification: TAP not-ok yes; banner no; leak-guard infra no"

# ── (e) LEVERS OFF → BYTE-IDENTICAL ─────────────────────────────────────────────────────────────────
reset_state
MAIN_HEALTH_AUTOFIX=off
printf 'red-file\n' > "$HC_MODE"
new_sha "feat: reds main with autofix off"
reconcile_main_health; settle
[ -s "$MAIN_HEALTH_STATE" ] || fail "(e) the red still must paint with autofix off"
[ "$(jcount 'main_health_autofix')" -eq 0 ] || fail "(e) MAIN_HEALTH_AUTOFIX=off journaled an autofix line"
[ "$(grep -c . "$SCRIBE_LOG")" -eq 0 ]      || fail "(e) MAIN_HEALTH_AUTOFIX=off enqueued a scribe item"
ok "(e) MAIN_HEALTH_AUTOFIX=off: no scribe item, no journal line"

# MAIN_HEALTH_TICK=off is fully inert: no dispatch, no journal, no state written, no row rendered.
reset_state
MAIN_HEALTH_TICK=off
new_sha "chore: a sha the disabled tick must ignore"
reconcile_main_health || fail "(e) the disabled reconcile returned non-zero"
[ "$(grep -c . "$JOURNAL_FILE")" -eq 0 ] || fail "(e) MAIN_HEALTH_TICK=off wrote a journal line"
ls "$TREES_DIR"/.health-dispatch-main-* >/dev/null 2>&1 && fail "(e) MAIN_HEALTH_TICK=off dispatched a suite"
ls "$TREES_DIR"/.main-health-*          >/dev/null 2>&1 && fail "(e) MAIN_HEALTH_TICK=off wrote a marker"
MAIN_HEALTH_TICK=on
ok "(e) MAIN_HEALTH_TICK=off is byte-inert: no suite, no journal, no marker"

# ── honest 'since' label: an observed sha with no PR renders "(observed)", never "(since #?)" ────────
# State fields are US(0x1f)-joined, not tab — tab is IFS-whitespace and `read` collapses an empty field.
reset_state
printf '%s\x1f%s\x1f%s\x1f%s\n' "deadbeef" "?" "app/greet.test.sh" "" > "$MAIN_HEALTH_STATE"
ROW="$(build_main_health; printf '%s' "${MAIN_HEALTH:-}")"
printf '%s' "$ROW" | grep -q '(observed)'  || fail "(a) an unattributed red renders a fictional PR: $ROW"
printf '%s' "$ROW" | grep -q 'since #'     && fail "(a) an unattributed red claims a 'since #' PR: $ROW"
printf '%s\x1f%s\x1f%s\x1f%s\n' "deadbeef" "226" "app/greet.test.sh" "" > "$MAIN_HEALTH_STATE"
ROW="$(build_main_health; printf '%s' "${MAIN_HEALTH:-}")"
printf '%s' "$ROW" | grep -q 'since #226' || fail "(a) an attributed red lost its 'since #N': $ROW"
ok "(a) the row names the PR when it knows one, and says (observed) when it does not"

# ── HERD-372: identity preservation + scope-aware clear ─────────────────────────────────────────────
# (f) a branch-CI red MERGES into, never replaces, a standing local-suite failing-test identity: set
# local red, then fire a CI red (via the REAL _main_health_ci_leg) for the SAME sha — both identities
# survive, and the row still names the MORE SPECIFIC (local) identity, not the generic CI conclusion.
reset_state
printf 'red-file\n' > "$HC_MODE"
new_sha "feat: reds main locally so HERD-372 can layer a CI red on top"
SHA372="$(head_sha)"
reconcile_main_health; settle
[ -s "$MAIN_HEALTH_STATE" ] || fail "(f) setup: the local suite did not paint MAIN RED"
ROW="$(build_main_health; printf '%s' "${MAIN_HEALTH:-}")"
printf '%s' "$ROW" | grep -q 'app/greet.test.sh' || fail "(f) setup: the row does not name the local failing test: $ROW"
export GH_RUNS='[{"headSha":"'"$SHA372"'","status":"COMPLETED","conclusion":"FAILURE","workflowName":"build"}]'
_main_health_ci_leg
IFS=$'\x1f' read -r _f_sha _f_since _f_local _f_ci < "$MAIN_HEALTH_STATE"
[ "$_f_local" = "app/greet.test.sh" ] || fail "(f) the CI red overwrote the standing local identity: '$_f_local'"
printf '%s' "$_f_ci" | grep -q 'CI build: FAILURE' || fail "(f) the CI identity was not recorded: '$_f_ci'"
ROW="$(build_main_health; printf '%s' "${MAIN_HEALTH:-}")"
printf '%s' "$ROW" | grep -q 'app/greet.test.sh' || fail "(f) the row stopped naming the specific local test once CI also reds: $ROW"
ok "(f) a branch-CI red merges into (never replaces) a standing local-suite identity; the row keeps naming the specific test"

# (g) a local-suite green clears ONLY the local identity — a live CI red keeps standing, with ZERO
# re-set churn on a later CI tick that reproduces the exact same (sha, conclusion).
RED_JOURNAL_BEFORE="$(jcount '"result":"red"')"
NOTIFY_BEFORE="$(ncount 'MAIN RED')"
printf 'green\n' > "$HC_MODE"
: > "$(_main_health_marker "$SHA372")"          # simulate the local suite's own collect calling clear(local)
_main_health_clear "?" "$SHA372" local
[ -s "$MAIN_HEALTH_STATE" ] || fail "(g) the CI red vanished when only the LOCAL identity cleared"
IFS=$'\x1f' read -r _g_sha _g_since _g_local _g_ci < "$MAIN_HEALTH_STATE"
[ -z "$_g_local" ] || fail "(g) the local identity was not cleared: '$_g_local'"
printf '%s' "$_g_ci" | grep -q 'CI build: FAILURE' || fail "(g) the CI identity did not survive the local clear: '$_g_ci'"
[ "$(ncount 'main green')" -eq 0 ] || fail "(g) a partial (local-only) clear falsely notified full recovery"
ROW="$(build_main_health; printf '%s' "${MAIN_HEALTH:-}")"
printf '%s' "$ROW" | grep -q 'MAIN RED' || fail "(g) the row disappeared while the CI identity still stands: $ROW"
# The exact same (sha, conclusion) probed again (GH_RUNS unchanged) must not re-journal red or re-notify.
_main_health_ci_leg
[ "$(jcount '"result":"red"')" -eq "$RED_JOURNAL_BEFORE" ] || fail "(g) a standing CI red re-set (re-journaled) after an unrelated local clear"
[ "$(ncount 'MAIN RED')" -eq "$NOTIFY_BEFORE" ] || fail "(g) a standing CI red re-notified after an unrelated local clear"
ok "(g) a local-suite green clears only the local identity: the CI red stands with zero re-set churn"
unset GH_RUNS

# ── PR attribution: a trailing "(#N)" (the squash form) outranks an issue ref earlier in the subject ──
new_sha "Merge pull request #456 from other/seat"
[ "$(_main_health_observed_pr "$(head_sha)")" = "456" ] || fail "(a) merge-commit subject: wrong pr#"
new_sha "Fix #123 widget handling (#456)"
[ "$(_main_health_observed_pr "$(head_sha)")" = "456" ] || fail "(a) squash subject: the ISSUE ref was attributed, not the PR"
new_sha "chore: a commit that names no PR at all"
[ -z "$(_main_health_observed_pr "$(head_sha)")" ] || fail "(a) a PR number was invented for a subject that names none"
ok "(a) attribution: trailing (#N) wins over an earlier issue ref; no PR named → no PR invented"

echo "ALL PASS ($pass checks)"
