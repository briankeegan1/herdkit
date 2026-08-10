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

# HERD-458: pin our own precondition — a CONFIGURED caller can leave ambient MAIN_HEALTH_TICK /
# HEALTH_CONCURRENCY / … already exported, which the slot-priority and cadence assertions below
# would otherwise inherit instead of the unset default. The shared harness scrub
# (scripts/herd/hermetic-env-scrub.sh) already does this once per suite run; re-arm it here too so
# this test is self-sufficient run alone.
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

# `gh` stub for the branch-CI leg (HERD-334/HERD-372/HERD-434): _main_health_ci_leg → `gh run list …
# --json …` → GH_RUNS (network-free, no real Actions calls). Every invocation's argv is ALSO appended
# to GH_CALLS (HERD-434) so a test can assert not just the RESULT but the exact `--branch` value the
# leg passed — the regression this closes (`--branch origin/main` silently matching zero runs) was
# invisible to a stub that only ever checked "$1 $2", never the rest of argv.
BIN="$T/bin"; mkdir -p "$BIN"
# GH_LOG_FAILED (HERD-476): the `gh run view <id> --log-failed` stub output, for the CI honest-identity
# leg (_main_health_ci_log_identity). Kept as simple/global as GH_RUNS — one scenario at a time.
# GH_WORKFLOW_RUN_RC (HERD-545): the exit code `gh workflow run …` (the starvation re-dispatch) hands
# back — default 0 (succeeds), same as the pre-existing catch-all `exit 0`, so every test written
# before HERD-545 is byte-unaffected; a starvation test sets it to non-zero to drive the local-fallback
# branch of _main_health_ci_redispatch.
# GH_UNAVAILABLE (HERD-545): simulates an offline/uninstalled gh WITHOUT ever removing this stub from
# $BIN — moving the stub aside used to let PATH fall through to a REAL system `gh`, which (this repo's
# own git remote being the real herdkit GitHub repo) then made a REAL, un-hermetic network call. The old
# _main_ci_classify's exact-sha filter happened to mask that (a fixture sha can never match a real
# GitHub run), but _main_ci_starve_scan (HERD-545) classifies the newest CONCLUSIVE run regardless of
# sha, so the leak stopped being harmless. $BIN stays FIRST on $PATH at all times now.
cat > "$BIN/gh" <<'GHSTUB'
#!/usr/bin/env bash
[ -n "${GH_UNAVAILABLE:-}" ] && exit 1
printf '%s\n' "$*" >> "${GH_CALLS:-/dev/null}"
case "$1 $2" in
  "run list")     printf '%s\n' "${GH_RUNS:-}"; exit 0 ;;
  "run view")     printf '%s\n' "${GH_LOG_FAILED:-}"; exit 0 ;;
  "workflow run") exit "${GH_WORKFLOW_RUN_RC:-0}" ;;
esac
exit 0
GHSTUB
chmod +x "$BIN/gh"
export PATH="$BIN:$PATH"
export GH_CALLS="$T/gh-calls.log"; : > "$GH_CALLS"
gcount() { local n; n="$(grep -c "$1" "$GH_CALLS" 2>/dev/null)" || n=0; printf '%s' "${n:-0}"; }

# ── source the real engine in lib mode, with every state path pinned into the sandbox ────────────────
# WORKTREES_DIR must be exported BEFORE sourcing: $TREES (and the main-health state paths derived from
# it at source time) are bound there. journal_append resolves its own path from WORKTREES_DIR too.
export AGENT_WATCH_LIB=1 NO_COLOR=1 HERD_DRIVER=headless
export HERD_CONFIG_FILE="$T/no-such-config"
export PROJECT_ROOT="$REPO" WORKTREES_DIR="$TREES_DIR"
export JOURNAL_FILE="$T/journal.jsonl"
export HERD_HEALTHCHECK_BIN="$HC"
# HERD-434: the REALISTIC remote-qualified form herd-config.sh itself defaults DEFAULT_BRANCH to
# ("origin/main") — not the bare "main" a bug-masking fixture would use. $HERD_BRANCH_NAME (derived
# from this at source time, herd-config.sh:794) is the bare form `gh run list --branch` actually wants.
export DEFAULT_BRANCH=origin/main
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"
for fn in reconcile_main_health _main_health_dispatch _main_health_died _main_health_autofix \
          _main_health_honest_identity _main_health_observed_pr main_health_tick \
          _main_health_ci_log_identity _main_health_autofix_spawn; do
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
MAIN_HEALTH_CI_GATE=on

[ "$HERD_BRANCH_NAME" = "main" ] || fail "setup: HERD_BRANCH_NAME did not derive to 'main' from DEFAULT_BRANCH=$DEFAULT_BRANCH (got '$HERD_BRANCH_NAME')"

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
grep -q 'app/greet.test.sh' <<< "$ROW" || fail "(b) the row does not name the failing test: $ROW"
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

# ── (f) RED LEDGER (HERD-539): the row carries its why + a last-verified stamp, and a reverify clears
#     it through the shared ledger, journaling red_cleared reason=reverified ─────────────────────────
reset_state
RED_LEDGER=on
printf 'red-file\n' > "$HC_MODE"
new_sha "fix: a change that reds main, with the red ledger on"
SHA="$(head_sha)"
reconcile_main_health; settle
[ -s "$MAIN_HEALTH_STATE" ] || fail "(f) setup: the red did not paint"
[ -s "$RED_LEDGER_FILE" ]   || fail "(f) RED_LEDGER=on did not write a ledger entry for the red"
ROW="$(build_main_health; printf '%s' "${MAIN_HEALTH:-}")"
grep -q 'verified 0m ago' <<< "$ROW" || fail "(f) the MAIN RED row carries no last-verified suffix: $ROW"
ok "(f) RED_LEDGER=on: a reproduced red is cached in the shared ledger and the row renders a verified-Xm-ago suffix"

# The cadence-driven re-verify clears it through herd_red_ledger_clear, journaling red_cleared once.
MAIN_HEALTH_RECHECK_MINS=30
printf 'green\n' > "$HC_MODE"
touch -t 200001010000 "$(_main_health_marker "$SHA")"
reconcile_main_health; settle
[ -s "$MAIN_HEALTH_STATE" ] && fail "(f) the green reverify did not clear main red"
[ "$(jcount "\"event\":\"red_cleared\".*\"key\":\"main_health:${SHA}\".*\"reason\":\"reverified\"")" -eq 1 ] \
  || fail "(f) the reverify clear did not journal red_cleared key=main_health:$SHA reason=reverified"
ROW="$(build_main_health; printf '%s' "${MAIN_HEALTH:-}")"
[ -z "$ROW" ] || fail "(f) the MAIN RED row survived the ledger-tracked clear: $ROW"
MAIN_HEALTH_RECHECK_MINS=0
RED_LEDGER=off
ok "(f) a cadence-driven reverify clears the ledger entry and journals red_cleared key=main_health:<sha> reason=reverified"

# RED_LEDGER=off (default): the exact same red produces a byte-identical row — no suffix, no ledger file.
reset_state
printf 'red-file\n' > "$HC_MODE"
new_sha "fix: a change that reds main, with the red ledger off (default)"
reconcile_main_health; settle
[ -s "$MAIN_HEALTH_STATE" ] || fail "(f) setup: the red did not paint with RED_LEDGER off"
[ -e "$RED_LEDGER_FILE" ] && fail "(f) RED_LEDGER=off (default) still wrote a ledger file"
ROW="$(build_main_health; printf '%s' "${MAIN_HEALTH:-}")"
grep -q 'verified' <<< "$ROW" && fail "(f) RED_LEDGER=off (default) still rendered a verified-ago suffix: $ROW"
ok "(f) RED_LEDGER=off (default): byte-identical MAIN RED row, no ledger file written"

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
grep -q '(observed)' <<< "$ROW" || fail "(a) an unattributed red renders a fictional PR: $ROW"
grep -q 'since #' <<< "$ROW" && fail "(a) an unattributed red claims a 'since #' PR: $ROW"
printf '%s\x1f%s\x1f%s\x1f%s\n' "deadbeef" "226" "app/greet.test.sh" "" > "$MAIN_HEALTH_STATE"
ROW="$(build_main_health; printf '%s' "${MAIN_HEALTH:-}")"
grep -q 'since #226' <<< "$ROW" || fail "(a) an attributed red lost its 'since #N': $ROW"
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
grep -q 'app/greet.test.sh' <<< "$ROW" || fail "(f) setup: the row does not name the local failing test: $ROW"
export GH_RUNS='[{"headSha":"'"$SHA372"'","status":"COMPLETED","conclusion":"FAILURE","workflowName":"build"}]'
_main_health_ci_leg
IFS=$'\x1f' read -r _f_sha _f_since _f_local _f_ci < "$MAIN_HEALTH_STATE"
[ "$_f_local" = "app/greet.test.sh" ] || fail "(f) the CI red overwrote the standing local identity: '$_f_local'"
grep -q 'CI build: FAILURE' <<< "$_f_ci" || fail "(f) the CI identity was not recorded: '$_f_ci'"
ROW="$(build_main_health; printf '%s' "${MAIN_HEALTH:-}")"
grep -q 'app/greet.test.sh' <<< "$ROW" || fail "(f) the row stopped naming the specific local test once CI also reds: $ROW"
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
grep -q 'CI build: FAILURE' <<< "$_g_ci" || fail "(g) the CI identity did not survive the local clear: '$_g_ci'"
[ "$(ncount 'main green')" -eq 0 ] || fail "(g) a partial (local-only) clear falsely notified full recovery"
ROW="$(build_main_health; printf '%s' "${MAIN_HEALTH:-}")"
grep -q 'MAIN RED' <<< "$ROW" || fail "(g) the row disappeared while the CI identity still stands: $ROW"
# The exact same (sha, conclusion) probed again (GH_RUNS unchanged) must not re-journal red or re-notify.
_main_health_ci_leg
[ "$(jcount '"result":"red"')" -eq "$RED_JOURNAL_BEFORE" ] || fail "(g) a standing CI red re-set (re-journaled) after an unrelated local clear"
[ "$(ncount 'MAIN RED')" -eq "$NOTIFY_BEFORE" ] || fail "(g) a standing CI red re-notified after an unrelated local clear"
ok "(g) a local-suite green clears only the local identity: the CI red stands with zero re-set churn"

# (h) CI itself recovering (a PASS bucket) clears the CI identity and the row disappears, since the
# local identity was already cleared in (g). A repeat PASS probe (nothing standing) must stay byte-quiet.
GREEN_JOURNAL_BEFORE="$(jcount '"result":"green"')"
export GH_RUNS='[{"headSha":"'"$SHA372"'","status":"COMPLETED","conclusion":"SUCCESS","workflowName":"build"}]'
_main_health_ci_leg
[ ! -s "$MAIN_HEALTH_STATE" ] || fail "(h) a CI recovery (PASS) did not clear the standing CI identity: $(cat "$MAIN_HEALTH_STATE")"
[ -z "$(cat "$MAIN_HEALTH_CI_STATE" 2>/dev/null || true)" ] || fail "(h) the CI dedup memo was not reset on recovery"
[ "$(ncount 'main green')" -eq 1 ] || fail "(h) the final (both-identities-clear) recovery did not notify once"
ROW="$(build_main_health; printf '%s' "${MAIN_HEALTH:-}")"
[ -z "$ROW" ] || fail "(h) the row survived once both identities cleared: $ROW"
# A repeat PASS probe with nothing standing must stay byte-quiet (no green re-journal every ~40s scan).
_main_health_ci_leg
[ "$(jcount '"result":"green"')" -eq "$((GREEN_JOURNAL_BEFORE + 1))" ] || fail "(h) a routinely-green branch-CI probe journaled on every scan"
ok "(h) a branch-CI recovery (PASS) clears the CI identity exactly once; a routinely-green branch stays byte-quiet"
unset GH_RUNS

# ── HERD-434: default branch's CI conclusion as a MAIN_HEALTH_TICK input ────────────────────────────
# GROUNDED: main merged 5 PRs (2026-07-28) while GitHub Actions CI stayed red on every one and
# MAIN_HEALTH_TICK reported green throughout — its local re-suite runs on the WATCHER'S OWN host, which
# can be green on a sha CI itself reds. _main_health_ci_leg (HERD-334) already probed `gh run list`, but
# passed the RAW $DEFAULT_BRANCH ("origin/main", herd-config.sh's own default) as `--branch`, which `gh
# run list` silently matches against ZERO runs — so the leg had been permanently, silently inert since
# it shipped. The fix passes $HERD_BRANCH_NAME (the bare form) instead, gated behind its own
# MAIN_HEALTH_CI_GATE (default off, ship-dormant, decoupled from MAIN_HEALTH_TICK's local re-suite).

# (i) the leg queries the BARE branch name, never the remote-qualified $DEFAULT_BRANCH — the exact
# regression that made every prior probe silently match nothing.
reset_state
new_sha "feat: a sha CI reds while local stays green"
SHA434="$(head_sha)"
printf 'green\n' > "$HC_MODE"
: > "$GH_CALLS"
export GH_RUNS='[{"headSha":"'"$SHA434"'","status":"COMPLETED","conclusion":"FAILURE","workflowName":"CI"}]'
_main_health_ci_leg
[ "$(gcount 'run list --branch main --limit')" -ge 1 ] || fail "(i) the leg did not query the BARE branch name 'main': $(cat "$GH_CALLS")"
[ "$(gcount 'branch origin/main')" -eq 0 ] || fail "(i) the leg queried the remote-qualified 'origin/main' (the HERD-434 regression): $(cat "$GH_CALLS")"
ok "(i) _main_health_ci_leg queries gh run list with the bare branch name, not the remote-qualified DEFAULT_BRANCH"

# (a, CI-gate) a red CI conclusion on the default branch's CURRENT head surfaces as a red main — the
# leg from (i) above already painted it; assert the row + journal + notify all agree.
[ -s "$MAIN_HEALTH_STATE" ] || fail "(a-ci) a failing CI conclusion did not paint MAIN RED"
ROW="$(build_main_health; printf '%s' "${MAIN_HEALTH:-}")"
grep -q 'MAIN RED' <<< "$ROW" || fail "(a-ci) the console row did not surface the CI-sourced red: $ROW"
[ "$(jcount "\"sha\":\"$SHA434\".*\"result\":\"red\"")" -ge 1 ] || fail "(a-ci) no red journal event named the CI-red sha"
ok "(a-ci) a failing default-branch CI conclusion surfaces as a red main (row + journal + notify)"
unset GH_RUNS

# (b1) gh UNAVAILABLE (offline/uninstalled) is fail-soft: never a red, never a crash, always rc 0.
reset_state
new_sha "feat: a sha probed while gh itself is unavailable"
SHA_OFFLINE="$(head_sha)"
GH_UNAVAILABLE=1 _main_health_ci_leg; RC=$?
[ "$RC" -eq 0 ] || fail "(b1) _main_health_ci_leg did not fail-soft (rc=$RC) when gh is unavailable"
[ ! -s "$MAIN_HEALTH_STATE" ] || fail "(b1) an unavailable gh painted a red anyway"
ok "(b1) an unavailable gh binary is fail-soft: no red, rc=0"

# (b2) a run still IN PROGRESS (not COMPLETED) for the current head is fail-soft: never a red — a
# pending CI run carries no verdict yet, the same "missing verdict is WAIT, never BLOCK" contract the
# health rail itself honors.
reset_state
new_sha "feat: a sha whose CI run has not completed yet"
SHA_PENDING="$(head_sha)"
export GH_RUNS='[{"headSha":"'"$SHA_PENDING"'","status":"IN_PROGRESS","conclusion":"","workflowName":"CI"}]'
_main_health_ci_leg; RC=$?
[ "$RC" -eq 0 ] || fail "(b2) _main_health_ci_leg did not fail-soft (rc=$RC) on a pending run"
[ ! -s "$MAIN_HEALTH_STATE" ] || fail "(b2) a still-pending CI run painted a red"
unset GH_RUNS
ok "(b2) a CI run still IN PROGRESS for the current head is fail-soft: no red"

# (c) MAIN_HEALTH_CI_GATE=off is byte-identical to before this feature: even with MAIN_HEALTH_TICK=on
# and a red CI conclusion sitting right there, the leg must not make a SINGLE `gh run list` call.
reset_state
new_sha "feat: a sha CI reds while the new gate stays off"
SHA_GATEOFF="$(head_sha)"
export GH_RUNS='[{"headSha":"'"$SHA_GATEOFF"'","status":"COMPLETED","conclusion":"FAILURE","workflowName":"CI"}]'
: > "$GH_CALLS"
MAIN_HEALTH_CI_GATE=off
_main_health_ci_leg; RC=$?
MAIN_HEALTH_CI_GATE=on
[ "$RC" -eq 0 ] || fail "(c) _main_health_ci_leg did not return 0 with the gate off"
[ ! -s "$GH_CALLS" ] || fail "(c) MAIN_HEALTH_CI_GATE=off still called gh: $(cat "$GH_CALLS")"
[ ! -s "$MAIN_HEALTH_STATE" ] || fail "(c) MAIN_HEALTH_CI_GATE=off painted a red anyway"
unset GH_RUNS
ok "(c) MAIN_HEALTH_CI_GATE=off never calls gh and never paints a red — byte-identical to before HERD-434"

# ── PR attribution: a trailing "(#N)" (the squash form) outranks an issue ref earlier in the subject ──
new_sha "Merge pull request #456 from other/seat"
[ "$(_main_health_observed_pr "$(head_sha)")" = "456" ] || fail "(a) merge-commit subject: wrong pr#"
new_sha "Fix #123 widget handling (#456)"
[ "$(_main_health_observed_pr "$(head_sha)")" = "456" ] || fail "(a) squash subject: the ISSUE ref was attributed, not the PR"
new_sha "chore: a commit that names no PR at all"
[ -z "$(_main_health_observed_pr "$(head_sha)")" ] || fail "(a) a PR number was invented for a subject that names none"
ok "(a) attribution: trailing (#N) wins over an earlier issue ref; no PR named → no PR invented"

# ── HERD-476 (i): an HONEST identity for kind=ci reds, parsed from the failing run's OWN logs ──────
# Before this fix, _main_health_ci_leg's render string ("CI <workflow>: <conclusion>") was the ONLY
# identity autofix ever saw for a branch-CI red — content-free, so EVERY kind=ci red skipped as
# dishonest, even when the failing run's own log (scripts/ci/run-suite.sh's "real-failed tests:"
# block) already named a real test. _main_health_ci_log_identity re-derives it from that log.

# (j) a kind=ci red whose run log names one real failing test is honest: MAIN_HEALTH_AUTOFIX files it,
# citing that test — not the generic conclusion string.
reset_state
MAIN_HEALTH_AUTOFIX=on
new_sha "feat: a sha whose branch CI reds with a real failing test in its log"
SHA476="$(head_sha)"
export GH_RUNS='[{"headSha":"'"$SHA476"'","status":"COMPLETED","conclusion":"FAILURE","workflowName":"CI","databaseId":9001}]'
export GH_LOG_FAILED="$(printf 'ubuntu-shard\trun tests\t   real-failed tests:\nubuntu-shard\trun tests\t     ✗ test-yolo-drain-mode.sh\n')"
_main_health_ci_leg
[ -s "$MAIN_HEALTH_STATE" ] || fail "(j) setup: the CI conclusion did not paint MAIN RED"
[ "$(jcount '"event":"main_health_autofix".*"result":"enqueued"')" -eq 1 ] || fail "(j) an honest CI-log identity did not file"
[ "$(jcount '"event":"main_health_autofix".*"failed":"test-yolo-drain-mode.sh"')" -eq 1 ] || fail "(j) the autofix journal did not cite the CI-log-derived test"
grep -q '^MAIN RED: fix test-yolo-drain-mode.sh$' "$SCRIBE_LOG" || fail "(j) the scribe title did not name the CI-log-derived test, not the generic conclusion: $(cat "$SCRIBE_LOG")"
IFS=$'\x1f' read -r _j_sha _j_since _j_local _j_ci < "$MAIN_HEALTH_STATE"
[ "$_j_ci" = "test-yolo-drain-mode.sh" ] || fail "(j) the log-derived identity was not persisted into the standing CI row (still the generic render?): '$_j_ci'"
ok "(j) a kind=ci red whose run log names a real failing test is honest: MAIN_HEALTH_AUTOFIX files it"
unset GH_RUNS GH_LOG_FAILED

# (j2) MARK-KEY MUST EQUAL CLEAR-KEY (review finding, PR #600): a green→red re-arm cycle for a kind=ci
# identity actually releases the shared-pool fix marker, so a LATER regression of the SAME CI test
# files fresh instead of dedup'ing forever. Before the persist fix above, the marker was claimed under
# the log-derived name but _main_health_clear released it under whatever the state file's ci field
# said — the generic "CI <workflow>: <conclusion>" render — so the marker leaked permanently.
reset_state
MAIN_HEALTH_AUTOFIX=on
new_sha "feat: a sha whose branch CI reds with a re-arm-able failing test"
SHA_R1="$(head_sha)"
export GH_RUNS='[{"headSha":"'"$SHA_R1"'","status":"COMPLETED","conclusion":"FAILURE","workflowName":"CI","databaseId":9101}]'
export GH_LOG_FAILED="$(printf 'ubuntu\trun\t   real-failed tests:\nubuntu\trun\t     ✗ test-rearm.sh\n')"
_main_health_ci_leg
[ "$(jcount '"event":"main_health_autofix".*"failed":"test-rearm.sh".*"result":"enqueued"')" -eq 1 ] || fail "(j2) setup: the first reproduction did not file"
IFS=$'\x1f' read -r _j2_sha _j2_since _j2_local _j2_ci < "$MAIN_HEALTH_STATE"
[ "$_j2_ci" = "test-rearm.sh" ] || fail "(j2) the standing CI identity was not persisted as the log-derived test name: '$_j2_ci'"

# CI recovers on the SAME sha (a later run of the same commit going green) — the leg's PASS branch
# clears the CI identity, which must release the marker under the SAME key it was claimed under.
export GH_RUNS='[{"headSha":"'"$SHA_R1"'","status":"COMPLETED","conclusion":"SUCCESS","workflowName":"CI","databaseId":9102}]'
_main_health_ci_leg
[ ! -s "$MAIN_HEALTH_STATE" ] || fail "(j2) the CI recovery did not clear the standing red: $(cat "$MAIN_HEALTH_STATE")"

# The SAME failing test regresses again (a new commit) — if the marker had leaked, this would dedup
# instead of filing fresh.
new_sha "feat: the same CI test regresses again after recovery"
SHA_R2="$(head_sha)"
export GH_RUNS='[{"headSha":"'"$SHA_R2"'","status":"COMPLETED","conclusion":"FAILURE","workflowName":"CI","databaseId":9103}]'
_main_health_ci_leg
[ "$(jcount '"event":"main_health_autofix".*"failed":"test-rearm.sh".*"result":"enqueued"')" -eq 2 ] || fail "(j2) a later regression of the same CI test did not file fresh — the fix marker leaked"
[ "$(jcount '"event":"main_health_autofix".*"failed":"test-rearm.sh".*"result":"dedup"')" -eq 0 ] || fail "(j2) a later regression was wrongly deduped against a leaked marker"
ok "(j2) a green→red re-arm cycle for a kind=ci identity releases the marker: a later regression of the same test files fresh (mark-key == clear-key)"
unset GH_RUNS GH_LOG_FAILED

# (k) TWO distinct failing tests in the same log are both captured, comma-joined and deduped — proof
# this is a real parse of every ✗ line, not a first-match shortcut (a regression that stopped at the
# first ✗ line, or hardcoded a single name, would fail this).
export GH_LOG_FAILED="$(printf 'ubuntu\trun\t   real-failed tests:\nubuntu\trun\t     ✗ test-a.sh\nubuntu\trun\t     ✗ test-b.sh (TIMEOUT after 120s)\n')"
_K_ID="$(_main_health_ci_log_identity 9002)"
grep -q 'test-a.sh' <<< "$_K_ID" || fail "(k) the first failing test was dropped: '$_K_ID'"
grep -q 'test-b.sh' <<< "$_K_ID" || fail "(k) the second failing test was dropped: '$_K_ID'"
ok "(k) multiple real-failed test names in one log are all captured, comma-joined"
unset GH_LOG_FAILED

# (l) an UNREADABLE ci log (gh run view returns nothing: offline, old gh, no matching run) skips with
# its OWN reason, ci-log-unreadable — and NEVER falls through to file off the generic conclusion
# string (the pre-fix dishonest-identity path). The red row itself still paints; only autofix declines.
reset_state
MAIN_HEALTH_AUTOFIX=on
new_sha "feat: a sha whose branch CI reds but the log is unreadable"
SHA476C="$(head_sha)"
export GH_RUNS='[{"headSha":"'"$SHA476C"'","status":"COMPLETED","conclusion":"FAILURE","workflowName":"CI","databaseId":9003}]'
export GH_LOG_FAILED=""
_main_health_ci_leg
[ -s "$MAIN_HEALTH_STATE" ] || fail "(l) the red row itself must still paint even though autofix could not file"
[ "$(jcount '"event":"main_health_autofix".*"reason":"ci-log-unreadable"')" -eq 1 ] || fail "(l) an unreadable CI log was not skipped with reason=ci-log-unreadable"
[ "$(jcount '"event":"main_health_autofix".*"reason":"dishonest-identity"')" -eq 0 ] || fail "(l) an unreadable CI log fell through to the generic dishonest-identity skip"
[ "$(grep -c . "$SCRIBE_LOG")" -eq 0 ] || fail "(l) an unreadable CI log filed an item anyway"
ok "(l) an unreadable/unparseable CI log skips with reason=ci-log-unreadable, never files off the generic conclusion string"
unset GH_RUNS GH_LOG_FAILED

# (m) no run id at all (an older `gh` whose --json omitted databaseId) degrades the same fail-soft way:
# empty, never a crash, never a guess.
[ -z "$(_main_health_ci_log_identity "")" ] || fail "(m) an empty run id produced a non-empty identity"
ok "(m) _main_health_ci_log_identity with no run id returns empty (fail-soft)"

# (n) an XFAIL-only log (run-suite.sh's ⚠️ env-sensitive line, no ✗ real-failure line) yields no
# identity — the parser is anchored on the REAL-failure glyph, never an env-sensitive skip note.
export GH_LOG_FAILED="$(printf 'ubuntu\trun\t⚠️  XFAIL (env-sensitive) test-flaky.sh: known issue\n')"
[ -z "$(_main_health_ci_log_identity 9004)" ] || fail "(n) an XFAIL-only log was treated as a real failing identity"
ok "(n) an XFAIL-only log (no ✗ real-failure line) yields no identity"
unset GH_LOG_FAILED
MAIN_HEALTH_AUTOFIX=off

# ── HERD-476 (ii): MAIN_HEALTH_AUTOFIX=spawn dispatches a tracked+claimed quick-lane build ─────────
# No stub: _main_health_autofix_spawn calls the REAL scripts/herd/spawn.sh, which only ENQUEUES into
# the durable spawn queue ($WORKTREES_DIR/spawn-queue/) — draining it into an actual herdr tab/agent is
# _drain_spawn_queue's job, never invoked here, so this stays fully hermetic: no worktree, no claim
# lookup, no network. TRACKED_SPAWNS / CLAIM_REQUIRED both default off, so spawn.sh's own gates pass
# through untouched, exactly the "tracked+claimed WHEN a project opts into those levers" contract.
SPAWN_Q="$TREES_DIR/spawn-queue"
spawn_reqs() { ls "$SPAWN_Q"/*.req 2>/dev/null | wc -l | tr -d ' '; }
latest_req() { ls -t "$SPAWN_Q"/*.req 2>/dev/null | sed -n '1p'; }

# (o) a FRESH honest local red under MAIN_HEALTH_AUTOFIX=spawn both files the scribe item AND
# dispatches a tracked+claimed quick-lane spawn. HERD-613: under the file backend (the default here,
# no synchronous create available to this tick) the spawn carries NO ref sidecar — the raw failing
# identity is not a tracker id, and threading it as HERD_ITEM_REF is the exact PRs-712/719 bug.
reset_state
MAIN_HEALTH_AUTOFIX=spawn
printf 'red-file\n' > "$HC_MODE"
new_sha "feat: reds main with autofix=spawn"
SHASPAWN="$(head_sha)"
reconcile_main_health; settle
[ "$(jcount '"event":"main_health_autofix".*"result":"enqueued"')" -eq 1 ] || fail "(o) autofix=spawn did not file the scribe item"
[ "$(jcount '"event":"main_health_autofix_spawn".*"result":"enqueued"')" -eq 1 ] || fail "(o) autofix=spawn did not journal a spawn enqueue"
[ "$(spawn_reqs)" -eq 1 ] || fail "(o) spawn.sh did not enqueue exactly one intent: $(ls "$SPAWN_Q" 2>/dev/null)"
REQ_O="$(latest_req)"
grep -q "^main-red-${SHASPAWN:0:8}-" "$REQ_O" || fail "(o) the spawn slug does not embed the red sha: $(cat "$REQ_O")"
[ "$(sed -n '2p' "$REQ_O")" = "quick" ] || fail "(o) the spawn did not use the quick lane: $(cat "$REQ_O")"
grep -q 'app/greet.test.sh' "$REQ_O" || fail "(o) the spawn task does not name the failing test: $(cat "$REQ_O")"
[ ! -e "${REQ_O%.req}.ref" ] \
  || fail "(o) HERD-613: the spawn carries a ref sidecar despite no real tracker id being available: $(cat "${REQ_O%.req}.ref" 2>/dev/null)"
ok "(o) MAIN_HEALTH_AUTOFIX=spawn files the scribe item AND dispatches an untracked quick-lane spawn — never the raw failing identity as a ref (HERD-613)"

# (p) the SAME identity's dedup'd reproduction never spawns a SECOND builder — spawn rides the exact
# shared-pool once-per-identity claim the file-only path already relies on.
MAIN_HEALTH_RECHECK_MINS=30
touch -t 200001010000 "$(_main_health_marker "$SHASPAWN")"
reconcile_main_health; settle
[ "$(jcount '"event":"main_health_autofix".*"result":"dedup"')" -ge 1 ] || fail "(p) the re-verify was not journaled as a dedup"
[ "$(spawn_reqs)" -eq 1 ] || fail "(p) a dedup'd reproduction spawned a SECOND builder for the same identity: $(ls "$SPAWN_Q" 2>/dev/null)"
MAIN_HEALTH_RECHECK_MINS=0
ok "(p) a dedup'd reproduction of the same identity never spawns a second builder"

# (q) MAIN_HEALTH_AUTOFIX=on (not the literal 'spawn') never touches spawn.sh — the file-only default
# is byte-unchanged by this feature.
reset_state
MAIN_HEALTH_AUTOFIX=on
printf 'red-file\n' > "$HC_MODE"
new_sha "feat: reds main with autofix=on (file-only, not spawn)"
reconcile_main_health; settle
[ "$(jcount '"event":"main_health_autofix".*"result":"enqueued"')" -eq 1 ] || fail "(q) setup: autofix=on did not file"
[ "$(spawn_reqs)" -eq 0 ] || fail "(q) MAIN_HEALTH_AUTOFIX=on (file-only) spawned a builder anyway: $(ls "$SPAWN_Q" 2>/dev/null)"
ok "(q) MAIN_HEALTH_AUTOFIX=on stays file-only: no spawn.sh call"

# (r) a MISSING spawn.sh journals no-spawn-sh and never blocks the file-only path (fail-soft).
reset_state
MAIN_HEALTH_AUTOFIX=spawn
printf 'red-tap\n' > "$HC_MODE"
new_sha "feat: reds main with autofix=spawn but spawn.sh is missing"
mv "$HERE/spawn.sh" "$HERE/spawn.sh.disabled"
reconcile_main_health; settle
mv "$HERE/spawn.sh.disabled" "$HERE/spawn.sh"
[ "$(jcount '"event":"main_health_autofix".*"result":"enqueued"')" -eq 1 ] || fail "(r) the scribe file did not still happen when spawn.sh is missing"
[ "$(jcount '"event":"main_health_autofix_spawn".*"reason":"no-spawn-sh"')" -eq 1 ] || fail "(r) a missing spawn.sh was not journaled as no-spawn-sh"
ok "(r) a missing spawn.sh journals no-spawn-sh and never blocks the file-only path"

# ── HERD-482: sanitize identity BEFORE slug/branch derivation (ANSI strip + prefer a test-file token)
# GROUNDED SHAPE: a colorized `gh run view --log-failed` line (CI logs are colorized by default) once
# rendered as branch main-red-<sha8>-0m-full-auto-fail-rc-1-see-var-folders-d — the ANSI reset code's
# digits+letter ("0m") survived tr/sed sanitization as literal text and ate the slug's 40-char budget
# ahead of anything a human would recognize. _main_health_ci_log_identity does not strip ANSI (it never
# needs to for the SCRIBE item text a human reads), so the fix lives at the ONE chokepoint every
# MAIN_HEALTH_AUTOFIX=spawn slug/branch derivation shares: _main_health_autofix_spawn.

# (s) an ANSI-colorized ✗ line that STILL names a real test file: the spawned slug names that file
# cleanly — no stray ANSI-derived digits/letters, no rc/path noise eating the character budget.
reset_state
MAIN_HEALTH_AUTOFIX=spawn
new_sha "feat: reds main via a colorized CI log line"
SHA482S="$(head_sha)"
export GH_RUNS='[{"headSha":"'"$SHA482S"'","status":"COMPLETED","conclusion":"FAILURE","workflowName":"CI","databaseId":9482}]'
export GH_LOG_FAILED="$(printf 'ubuntu\trun\t   real-failed tests:\nubuntu\trun\t     \xe2\x9c\x97 \x1b[31mtests/test-yolo-drain-mode.sh\x1b[0m rc 1 see /var/folders/xy/T/tmp.XXXXXX\n')"
_main_health_ci_leg
settle
[ "$(jcount '"event":"main_health_autofix".*"result":"enqueued"')" -eq 1 ] || fail "(s) setup: an ANSI-laden but honest CI identity did not file"
[ "$(spawn_reqs)" -eq 1 ] || fail "(s) spawn.sh did not enqueue exactly one intent: $(ls "$SPAWN_Q" 2>/dev/null)"
REQ_S="$(latest_req)"
SLUG_S="$(sed -n '1p' "$REQ_S")"
case "$SLUG_S" in *test-yolo-drain-mode-sh*) : ;; *) fail "(s) the spawned slug does not name the real test file: $SLUG_S" ;; esac
case "$SLUG_S" in *0m*) fail "(s) an ANSI escape's tail survived sanitization into the slug: $SLUG_S" ;; esac
case "$SLUG_S" in *$'\x1b'*) fail "(s) a raw ESC byte survived into the spawn queue file: $SLUG_S" ;; esac
ok "(s) an ANSI-colorized identity that names a real test file spawns a CLEAN slug (no ANSI residue, no rc/path noise)"
unset GH_RUNS GH_LOG_FAILED

# (t) an ANSI-colorized rc/path blob that names NO file at all reads DISHONEST — never filed, never
# spawned. Tightening _main_health_honest_identity to share _main_health_slug_identity's own ANSI-strip
# + token search means "sluggable" and "honest" can never diverge: no token survives for either purpose.
reset_state
MAIN_HEALTH_AUTOFIX=spawn
new_sha "feat: reds main via a colorized CI log line naming no file"
SHA482T="$(head_sha)"
export GH_RUNS='[{"headSha":"'"$SHA482T"'","status":"COMPLETED","conclusion":"FAILURE","workflowName":"CI","databaseId":9483}]'
export GH_LOG_FAILED="$(printf 'ubuntu\trun\t   real-failed tests:\nubuntu\trun\t     \xe2\x9c\x97 \x1b[31mfull-auto fail\x1b[0m rc 1 see /var/folders/xy/T/tmp.XXXXXX\n')"
_main_health_ci_leg
settle
[ "$(jcount '"event":"main_health_autofix".*"reason":"dishonest-identity"')" -eq 1 ] || fail "(t) an ANSI-laden rc/path blob with no file token was not skipped as dishonest"
[ "$(jcount '"event":"main_health_autofix".*"result":"enqueued"')" -eq 0 ] || fail "(t) a token-less rc/path blob filed a scribe item anyway"
[ "$(spawn_reqs)" -eq 0 ] || fail "(t) a dishonest identity spawned a builder anyway: $(ls "$SPAWN_Q" 2>/dev/null)"
ok "(t) an ANSI-laden rc/path blob with no file token reads dishonest — never filed, never spawned"
unset GH_RUNS GH_LOG_FAILED
MAIN_HEALTH_AUTOFIX=off

# ── HERD-545: CI-leg starvation under merge bursts ──────────────────────────────────────────────────
# GROUNDED (2026-08-05): MAIN RED stood anchored to an OLD sha's CI FAILURE while 17 merges in a row
# auto-cancelled every newer run before it could complete. The pre-fix leg (_main_ci_classify "$sha")
# only ever asked "is there a COMPLETED run for the CURRENT head" — during a burst the answer is "no"
# on every tick after the first, so the stale red could never be superseded OR even requalified as
# stale. _main_ci_starve_scan always classifies the newest CONCLUSIVE run in the window and counts the
# distinct newer shas that never got one of their own.

# (u1) a cancelled chain renders the standing red QUALIFIED — naming the anchor sha and the cancelled
# count — instead of leaving a bare "CI <workflow>: <conclusion>" that reads as a live verdict about
# whatever main happens to be at right now.
reset_state
new_sha "fix: this commit's CI run will fail and anchor the row"
SHA_ANCHOR="$(head_sha)"
export GH_RUNS='[{"headSha":"'"$SHA_ANCHOR"'","status":"COMPLETED","conclusion":"FAILURE","workflowName":"build"}]'
_main_health_ci_leg
[ -s "$MAIN_HEALTH_STATE" ] || fail "(u1) setup: the initial CI failure did not paint MAIN RED"
IFS=$'\x1f' read -r _u1s_sha _u1s_since _u1s_local _u1s_ci < "$MAIN_HEALTH_STATE"
[ "$_u1s_ci" = "CI build: FAILURE" ] || fail "(u1) setup: the FIRST detection did not render the plain (unqualified) message: '$_u1s_ci'"
[ "$(cat "$MAIN_HEALTH_CI_STATE")" = "$SHA_ANCHOR FAILURE 0" ] || fail "(u1) setup: the dedup memo did not record cancelled-count 0: $(cat "$MAIN_HEALTH_CI_STATE")"

# Three merges land back-to-back and every one of their CI runs is auto-cancelled before completing —
# the classic starvation shape. current HEAD moves to the newest (still-cancelled) sha.
new_sha "chore: merge burst 1 (its own CI run gets cancelled)"; SHA_C1="$(head_sha)"
new_sha "chore: merge burst 2 (its own CI run gets cancelled)"; SHA_C2="$(head_sha)"
new_sha "chore: merge burst 3 (its own CI run gets cancelled)"; SHA_C3="$(head_sha)"
export GH_RUNS='[
  {"headSha":"'"$SHA_C3"'","status":"COMPLETED","conclusion":"CANCELLED","workflowName":"build"},
  {"headSha":"'"$SHA_C2"'","status":"COMPLETED","conclusion":"CANCELLED","workflowName":"build"},
  {"headSha":"'"$SHA_C1"'","status":"COMPLETED","conclusion":"CANCELLED","workflowName":"build"},
  {"headSha":"'"$SHA_ANCHOR"'","status":"COMPLETED","conclusion":"FAILURE","workflowName":"build"}
]'
_main_health_ci_leg
[ -s "$MAIN_HEALTH_STATE" ] || fail "(u1) the anchor red vanished once newer runs started cancelling"
IFS=$'\x1f' read -r _u1_sha _u1_since _u1_local _u1_ci < "$MAIN_HEALTH_STATE"
[ "$_u1_sha" = "$SHA_ANCHOR" ] || fail "(u1) the pinned sha drifted off the anchor: '$_u1_sha'"
grep -q "CI red at ${SHA_ANCHOR:0:7}" <<< "$_u1_ci" || fail "(u1) the row did not name the anchor sha: '$_u1_ci'"
grep -q "3 newer runs cancelled" <<< "$_u1_ci" || fail "(u1) the row did not count the 3 cancelled newer runs: '$_u1_ci'"
grep -q "awaiting a completed run" <<< "$_u1_ci" || fail "(u1) the row did not say it is awaiting a fresh signal: '$_u1_ci'"
[ "$_u1_ci" = "CI build: FAILURE" ] && fail "(u1) the row stayed BARE despite 3 newer cancelled runs — the starvation regression itself"
ok "(u1) a cancelled-chain anchor red renders QUALIFIED (anchor sha + cancelled count), never a bare unqualified conclusion"

# (u2) a completed GREEN on a sha NEWER than (but not equal to) the pinned anchor clears the stale red
# — HERD-545 part 3. Before this fix the leg only ever looked for a PASS on the exact current head, so
# a green landing on any other sha in the window was invisible to it.
new_sha "fix: this commit's CI run finally completes green"
SHA_GREEN="$(head_sha)"
export GH_RUNS='[{"headSha":"'"$SHA_GREEN"'","status":"COMPLETED","conclusion":"SUCCESS","workflowName":"build"}]'
NOTIFY_GREEN_BEFORE="$(ncount 'main green')"
_main_health_ci_leg
[ ! -s "$MAIN_HEALTH_STATE" ] || fail "(u2) a green completed run on a NEWER sha did not clear the stale anchor red: $(cat "$MAIN_HEALTH_STATE")"
[ -z "$(cat "$MAIN_HEALTH_CI_STATE" 2>/dev/null || true)" ] || fail "(u2) the CI dedup memo was not reset on the newer-sha clear"
[ "$(ncount 'main green')" -eq "$((NOTIFY_GREEN_BEFORE + 1))" ] || fail "(u2) the newer-sha green did not notify recovery exactly once"
ok "(u2) a completed green on ANY newer sha clears the stale anchor, not only a green on the exact current head"
unset GH_RUNS

# (u3) starvation reaching the cancelled-count threshold (_MAIN_CI_STARVE_K), with no run in progress,
# requests a fresh CI signal exactly once per sha — never once per scan, and never while a run is still
# in flight ("re-dispatch once per sha only when idle").
reset_state
new_sha "fix: anchor commit for the re-dispatch test"
SHA_RD_ANCHOR="$(head_sha)"
export GH_RUNS='[{"headSha":"'"$SHA_RD_ANCHOR"'","status":"COMPLETED","conclusion":"FAILURE","workflowName":"build"}]'
_main_health_ci_leg
new_sha "chore: cancelled 1"; SHA_RD_C1="$(head_sha)"
new_sha "chore: cancelled 2"; SHA_RD_C2="$(head_sha)"
new_sha "chore: cancelled 3"; SHA_RD_C3="$(head_sha)"    # current HEAD, K=3 cancelled shas above the anchor
: > "$GH_CALLS"
export GH_RUNS='[
  {"headSha":"'"$SHA_RD_C3"'","status":"COMPLETED","conclusion":"CANCELLED","workflowName":"build"},
  {"headSha":"'"$SHA_RD_C2"'","status":"COMPLETED","conclusion":"CANCELLED","workflowName":"build"},
  {"headSha":"'"$SHA_RD_C1"'","status":"COMPLETED","conclusion":"CANCELLED","workflowName":"build"},
  {"headSha":"'"$SHA_RD_ANCHOR"'","status":"COMPLETED","conclusion":"FAILURE","workflowName":"build"}
]'
_main_health_ci_leg
[ "$(gcount 'workflow run build')" -eq 1 ] || fail "(u3) reaching K cancelled newer runs with nothing in progress did not request a fresh signal: $(cat "$GH_CALLS")"
[ "$(jcount "\"event\":\"main_health_ci_redispatch\".*\"sha\":\"$SHA_RD_C3\".*\"result\":\"dispatched\"")" -eq 1 ] || fail "(u3) the redispatch was not journaled as dispatched for the CURRENT head sha"
ok "(u3a) starvation reaching the K threshold with no run in progress requests a fresh CI signal (gh workflow run)"

# A repeat tick for the SAME sha must never ask gh again — guarded once per sha, not once per scan.
_main_health_ci_leg
[ "$(gcount 'workflow run build')" -eq 1 ] || fail "(u3) a repeat scan for the SAME still-starved sha asked gh workflow run again — the once-per-sha guard leaked"
ok "(u3b) a repeat scan for the SAME (still-starved) sha never re-asks gh — once-per-sha guard holds"

# A genuinely NEW head sha, still starved, re-arms the guard — it is per-sha, not a global one-shot.
new_sha "chore: cancelled 4 — a new head, still starved"; SHA_RD_C4="$(head_sha)"
export GH_RUNS='[
  {"headSha":"'"$SHA_RD_C4"'","status":"COMPLETED","conclusion":"CANCELLED","workflowName":"build"},
  {"headSha":"'"$SHA_RD_C3"'","status":"COMPLETED","conclusion":"CANCELLED","workflowName":"build"},
  {"headSha":"'"$SHA_RD_C2"'","status":"COMPLETED","conclusion":"CANCELLED","workflowName":"build"},
  {"headSha":"'"$SHA_RD_C1"'","status":"COMPLETED","conclusion":"CANCELLED","workflowName":"build"},
  {"headSha":"'"$SHA_RD_ANCHOR"'","status":"COMPLETED","conclusion":"FAILURE","workflowName":"build"}
]'
_main_health_ci_leg
[ "$(gcount 'workflow run build')" -eq 2 ] || fail "(u3) a NEW starved head sha did not get its own fresh-signal request"
ok "(u3c) a genuinely new starved head sha re-arms the re-dispatch guard (per-sha, not a global one-shot)"
unset GH_RUNS

# The idle gate: K cancelled newer runs is reached, but a run is STILL IN PROGRESS somewhere in the
# window — re-dispatch must be withheld (asking GitHub for ANOTHER run while one is already in flight
# would just create a second thing to get cancelled).
reset_state
new_sha "fix: anchor commit for the idle-gate test"
SHA_IDLE_ANCHOR="$(head_sha)"
export GH_RUNS='[{"headSha":"'"$SHA_IDLE_ANCHOR"'","status":"COMPLETED","conclusion":"FAILURE","workflowName":"build"}]'
_main_health_ci_leg
new_sha "chore: cancelled a"; SHA_IDLE_C1="$(head_sha)"
new_sha "chore: cancelled b"; SHA_IDLE_C2="$(head_sha)"
new_sha "chore: cancelled c"; SHA_IDLE_C3="$(head_sha)"
new_sha "chore: still running"; SHA_IDLE_C4="$(head_sha)"   # current HEAD — its run has not finished yet
: > "$GH_CALLS"
export GH_RUNS='[
  {"headSha":"'"$SHA_IDLE_C4"'","status":"IN_PROGRESS","conclusion":"","workflowName":"build"},
  {"headSha":"'"$SHA_IDLE_C3"'","status":"COMPLETED","conclusion":"CANCELLED","workflowName":"build"},
  {"headSha":"'"$SHA_IDLE_C2"'","status":"COMPLETED","conclusion":"CANCELLED","workflowName":"build"},
  {"headSha":"'"$SHA_IDLE_C1"'","status":"COMPLETED","conclusion":"CANCELLED","workflowName":"build"},
  {"headSha":"'"$SHA_IDLE_ANCHOR"'","status":"COMPLETED","conclusion":"FAILURE","workflowName":"build"}
]'
_main_health_ci_leg
[ "$(gcount 'workflow run')" -eq 0 ] || fail "(u3) a re-dispatch fired while a run in the window was STILL IN PROGRESS: $(cat "$GH_CALLS")"
ok "(u3d) re-dispatch is withheld while any run in the window is still in progress, even past the K threshold"
unset GH_RUNS

# (u4) when the live re-dispatch itself is unavailable (no workflow_dispatch trigger, an older gh, no
# write scope), the leg falls back to the LOCAL suite's OWN verdict for the exact starved sha — already
# being produced by the ordinary MAIN_HEALTH_TICK re-suite regardless of CI's health — and clears the
# stale CI anchor off of it, honestly tagged provenance=local-fallback.
reset_state
printf 'green\n' > "$HC_MODE"
new_sha "fix: anchor commit for the local-fallback test"
SHA_LF_ANCHOR="$(head_sha)"
export GH_RUNS='[{"headSha":"'"$SHA_LF_ANCHOR"'","status":"COMPLETED","conclusion":"FAILURE","workflowName":"build"}]'
_main_health_ci_leg
[ -s "$MAIN_HEALTH_STATE" ] || fail "(u4) setup: the CI failure did not paint MAIN RED"
new_sha "chore: cancelled x"; SHA_LF_C1="$(head_sha)"
new_sha "chore: cancelled y"; SHA_LF_C2="$(head_sha)"
new_sha "chore: cancelled z"; SHA_LF_C3="$(head_sha)"     # current HEAD
# The ordinary local re-suite verifies the CURRENT head sha clean, independent of CI's own starvation.
reconcile_main_health; settle
[ -e "$(_main_health_marker "$SHA_LF_C3")" ] || fail "(u4) setup: the local suite never produced a verdict for the current head sha"
_lf_local=""
if [ -s "$MAIN_HEALTH_STATE" ]; then
  IFS=$'\x1f' read -r _lf_sha _lf_since _lf_local _lf_ci < "$MAIN_HEALTH_STATE"
fi
[ -z "$_lf_local" ] || fail "(u4) setup: the local suite unexpectedly reproduced a red for the current head sha: '$_lf_local'"
export GH_WORKFLOW_RUN_RC=1     # the live re-dispatch is unavailable (no workflow_dispatch wired, e.g.)
export GH_RUNS='[
  {"headSha":"'"$SHA_LF_C3"'","status":"COMPLETED","conclusion":"CANCELLED","workflowName":"build"},
  {"headSha":"'"$SHA_LF_C2"'","status":"COMPLETED","conclusion":"CANCELLED","workflowName":"build"},
  {"headSha":"'"$SHA_LF_C1"'","status":"COMPLETED","conclusion":"CANCELLED","workflowName":"build"},
  {"headSha":"'"$SHA_LF_ANCHOR"'","status":"COMPLETED","conclusion":"FAILURE","workflowName":"build"}
]'
NOTIFY_LF_BEFORE="$(ncount 'main green')"
_main_health_ci_leg
[ "$(gcount 'workflow run build')" -eq 1 ] || fail "(u4) the leg never attempted the live re-dispatch before falling back"
[ "$(jcount "\"event\":\"main_health_ci_redispatch\".*\"sha\":\"$SHA_LF_C3\".*\"result\":\"fallback\"")" -eq 1 ] || fail "(u4) the failed live re-dispatch was not journaled as a fallback"
[ "$(jcount "\"event\":\"main_health_ci_redispatch\".*\"sha\":\"$SHA_LF_C3\".*\"result\":\"cleared\".*\"provenance\":\"local-fallback\"")" -eq 1 ] || fail "(u4) the local-suite fallback did not clear the stale CI anchor with an honest provenance tag"
[ ! -s "$MAIN_HEALTH_STATE" ] || fail "(u4) the stale CI anchor survived the local-fallback clear: $(cat "$MAIN_HEALTH_STATE")"
[ "$(ncount 'main green')" -eq "$((NOTIFY_LF_BEFORE + 1))" ] || fail "(u4) the local-fallback clear did not notify recovery exactly once"
ok "(u4) an unavailable live re-dispatch falls back to the local suite's own verdict, clearing the stale anchor with provenance=local-fallback"
unset GH_RUNS GH_WORKFLOW_RUN_RC

echo "ALL PASS ($pass checks)"
