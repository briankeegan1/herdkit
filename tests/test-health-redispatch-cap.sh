#!/usr/bin/env bash
# test-health-redispatch-cap.sh — hermetic tests for the HERD-742 / GitHub #813 bound on VERDICTLESS
# health-worker re-dispatch, and for the .progress verdict salvage that avoids burning a lap at all.
#
# GROUNDED INCIDENT (emberglen-godot PR #425): a health worker killed before its one-shot verdict write
# leaves a 0-byte <log>, so the collector reads no verdict, the corpse sweep journals health_died, and
# the next tick dispatches the SAME suite again — 83 laps over ~15 h, a full suite burned every ~11 min,
# and never a needs-you row. HEALTH_EARLY_REAP_SECS / HEALTH_INFLIGHT_TIMEOUT bound a LIVE worker, not
# this dead-and-restarted cycle; HERD-736's counter only made it VISIBLE.
#
# Covers:
#   (1)  the new seams are defined after sourcing, and the cap constant is the documented 3
#   (2)  laps 1..N-1 dispatch exactly as before — the bound changes nothing until it is reached
#   (3)  the Nth consecutive verdictless lap CAPS: no new suite, QUEUED (never a fabricated red),
#        a durable cap marker, a distinct health_redispatch_cap journal event
#   (4)  the escalation ROW: needs-you, naming the lap count AND the .progress path AND the remedy
#   (5)  the render half (_gate_phase_row) paints that same row off the marker — the ENGINE-AGNOSTIC
#        surface, so a cap armed by the Python engine is visible on the console
#   (6)  arming clears the counter, and removing the marker re-arms with a FULL fresh budget
#   (7)  RESET-ON-PROGRESS: a terminal verdict collect clears counter + cap marker …
#   (8)  … but an unparseable/truncated worker payload does NOT (that path re-dispatches; clearing
#        the budget there would hand THAT loop the very unboundedness this closes)
#   (9)  SALVAGE: a complete FAILING .progress tail becomes a CODEERROR verdict with no new suite —
#        TAP shape and project-wrapper "[health-progress]" shape both
#   (10) salvage REFUSES an incomplete tail and an all-pass tail (never fabricates a CLEAN)
#   (11) stale-sha hygiene: _discard_stale_health sweeps the counter + cap marker of a superseded sha
#   (12) CROSS-ENGINE: pysrc/herd/live_runtime.py's LiveGates.health enforces the SAME bound over the
#        SAME files (cap at N, no dispatch, same journal event), the bash render half paints the row
#        off a marker PYTHON wrote, and the same tail salvages …
#   (13) … and its mirrored predicates agree with bash's on an identical fixture matrix (the
#        anti-drift guard for the two mirrored implementations)
#
# Sources agent-watch.sh in lib mode with HERD_HEALTHCHECK_BIN pointed at a stub that HANGS, so every
# lap is a real dispatch whose worker is then reaped verdictless exactly as the corpse sweep reaps one.
# Stubs gh/git/herdr (NETWORK-FREE); temp WORKTREES_DIR.  Run:  bash tests/test-health-redispatch-cap.sh
# No `set -e`: several checks assert non-zero returns explicitly.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
WATCH="$REPO/scripts/herd/agent-watch.sh"

if [ -f "$REPO/scripts/herd/hermetic-env-scrub.sh" ]; then
  # shellcheck source=/dev/null
  . "$REPO/scripts/herd/hermetic-env-scrub.sh"
  herd_hermetic_env_scrub "$REPO/scripts/herd/herd-config.sh"
fi

T="$(mktemp -d)"; trap '_kill_leftovers; rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

# Any worker we start hangs on purpose; never leak one past the run.
_LEFTOVERS=""
_track() { _LEFTOVERS="$_LEFTOVERS $1"; }
_kill_leftovers() { local p; for p in $_LEFTOVERS; do kill -KILL "-$p" 2>/dev/null || true; kill -KILL "$p" 2>/dev/null || true; done; }

[ -f "$WATCH" ] || fail "agent-watch.sh not found at $WATCH"
command -v python3 >/dev/null 2>&1 || fail "python3 required to run this test"

# ── Stub binaries on PATH (network-free) ─────────────────────────────────────
BIN="$T/bin"; mkdir -p "$BIN"
for cmd in gh git herdr; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$cmd"; chmod +x "$BIN/$cmd"
done
export PATH="$BIN:$PATH"

# Stub healthcheck: records each invocation, then HANGS — a suite that never reaches its verdict write,
# which is exactly the worker state the corpse sweep reaps as `health_died`.
STUB_HC="$T/stub-healthcheck.sh"
cat > "$STUB_HC" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$STUB_HC_LOG"
sleep 300
STUB
chmod +x "$STUB_HC"

# ── Source agent-watch.sh in lib mode ────────────────────────────────────────
export AGENT_WATCH_LIB=1
export WORKTREES_DIR="$T/trees"; mkdir -p "$T/trees"
export HERD_CONFIG_FILE="$T/no-such-config"
export HERD_HEALTHCHECK_BIN="$STUB_HC"
export STUB_HC_LOG="$T/hc-invocations.log"; : > "$STUB_HC_LOG"
export JOURNAL_FILE="$T/journal.jsonl"; : > "$JOURNAL_FILE"
export HERD_HEALTH_TERM_SLEEP="0.02"
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"
render() { :; }
TREES="$WORKTREES_DIR"   # what _health_inflight_file / the cap + counter files key off
WT="$T/wt"; mkdir -p "$WT"

hc_invocations() { grep -c '' "$STUB_HC_LOG" 2>/dev/null || printf 0; }
journal_count()  { grep -c "\"$1\"" "$JOURNAL_FILE" 2>/dev/null || printf 0; }

# lap <pr> <slug> <sha> — ONE verdictless lap: dispatch through the real gate, then reap the worker the
# way _sweep_gate_corpses reaps a corpse (terminate the group, drop marker + dispatch scratch). Leaves
# the 0-byte log behind exactly as a killed one-shot worker does.
lap() {
  local _pr="$1" _slug="$2" _sha="$3" _key="$1-$3" _m _n=0
  DISPLAY=(); _HC_RESULT=""
  _healthcheck_gate "$_pr" "$_slug" "$WT" 0 "$_sha"
  _m="$(_health_inflight_file "$_key")"
  [ -f "$_m" ] || return 0                       # capped / queued — nothing was dispatched
  _track "$(_marker_pid "$_m")"
  while [ "$_n" -lt 200 ] && [ ! -s "$STUB_HC_LOG" ]; do sleep 0.02; _n=$((_n + 1)); done
  _health_terminate_worker "$_m" >/dev/null 2>&1
  rm -f "$_m" "$(_health_dispatch_file "$_key")" 2>/dev/null || true
}

# ── (1) seams defined + the documented constant ──────────────────────────────
for fn in _health_redispatch_capped _health_redispatch_cap_arm _health_redispatch_cap_clear \
          _health_redispatch_cap_file _health_redispatch_cap_row _health_dispatch_count \
          _health_salvage_detail; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined after sourcing"
done
[ "$_HEALTH_VERDICTLESS_REDISPATCH_MAX" = "3" ] \
  || fail "cap should be 3 (got '$_HEALTH_VERDICTLESS_REDISPATCH_MAX')"
ok

# ── (2) laps 1..2 dispatch exactly as before ─────────────────────────────────
PR=101; SHA=aaaaaaa1; KEY="$PR-$SHA"
lap "$PR" slug-cap "$SHA"
[ "$_HC_RESULT" = "RUNNING" ] || fail "lap 1 should dispatch (got '$_HC_RESULT')"
[ "$(_health_dispatch_count "$KEY")" = "1" ] || fail "lap 1 should leave the counter at 1"
lap "$PR" slug-cap "$SHA"
[ "$(_health_dispatch_count "$KEY")" = "2" ] || fail "lap 2 should leave the counter at 2"
[ -f "$(_health_redispatch_cap_file "$KEY")" ] && fail "must NOT cap before the budget is burned"
[ "$(hc_invocations)" = "2" ] || fail "laps 1-2 should have run the suite twice (got $(hc_invocations))"
ok

# ── (3) the Nth lap caps: no new suite, QUEUED, marker, journal event ────────
lap "$PR" slug-cap "$SHA"                       # lap 3 — the last one the budget allows
[ "$(hc_invocations)" = "3" ] || fail "lap 3 should still run the suite (got $(hc_invocations))"
DISPLAY=(); _HC_RESULT=""
_healthcheck_gate "$PR" slug-cap "$WT" 0 "$SHA" # lap 4 — capped
[ "$_HC_RESULT" = "QUEUED" ] \
  || fail "a capped key must HOLD (QUEUED), never a fabricated verdict (got '$_HC_RESULT')"
[ "$(hc_invocations)" = "3" ] || fail "a capped key must NOT dispatch a 4th suite (got $(hc_invocations))"
[ -f "$(_health_redispatch_cap_file "$KEY")" ] || fail "the cap marker should be armed"
[ -e "$(_health_inflight_file "$KEY")" ] && fail "a capped key must take no slot"
[ ! -f "$(_health_result_file "$PR" "$SHA")" ] \
  || fail "a capped key must NOT cache a verdict — there IS no verdict"
[ "$(journal_count health_redispatch_cap)" = "1" ] || fail "expected one health_redispatch_cap event"
grep -q '"count":"3"' "$JOURNAL_FILE" || grep -q '"count":3' "$JOURNAL_FILE" \
  || fail "the cap event should carry the lap count"
ok
# a standing cap is a STATE, not a repeating event
DISPLAY=(); _HC_RESULT=""
_healthcheck_gate "$PR" slug-cap "$WT" 0 "$SHA"
[ "$(journal_count health_redispatch_cap)" = "1" ] || fail "the cap event must not repeat every tick"
[ "$(hc_invocations)" = "3" ] || fail "a standing cap must keep refusing to dispatch"
ok

# ── (4) the escalation ROW: blocker AND remedy ───────────────────────────────
row="${DISPLAY[0]:-}"
grep -q "needs you" <<< "$row"      || fail "the capped row must be a needs-you row (got: $row)"
grep -q "3×" <<< "$row"             || fail "the row must name the lap count (got: $row)"
grep -q "re-dispatch STOPPED" <<< "$row" || fail "the row must say nothing is retrying it (got: $row)"
grep -q "$(_health_heartbeat_file "$KEY")" <<< "$row" \
  || fail "the row must name the .progress path to read (got: $row)"
grep -q "rm $(_health_redispatch_cap_file "$KEY")" <<< "$row" \
  || fail "the row must name the re-arm remedy (got: $row)"
ok

# ── (5) the render half paints the SAME row off the marker (engine-agnostic) ─
prow="$(_gate_phase_row "$(_slug_cell slug-cap)" " #${PR} ·" "$PR" "$SHA" "FALLBACK-ROW")"
grep -q "needs you" <<< "$prow" || fail "_gate_phase_row must surface a capped key (got: $prow)"
grep -q "FALLBACK-ROW" <<< "$prow" && fail "_gate_phase_row must not fall through when capped"
ok
# … and is byte-identical to the fallback for a key that is NOT capped
prow2="$(_gate_phase_row "$(_slug_cell slug-other)" " #999 ·" 999 "beefbeef" "FALLBACK-ROW")"
[ "$prow2" = "FALLBACK-ROW" ] || fail "an uncapped key must render exactly the caller's fallback"
ok

# ── (6) arming cleared the counter; clearing the marker re-arms a FULL budget ─
[ -f "$(_health_dispatch_count_file "$KEY")" ] \
  && fail "arming must clear the counter (else a hand-cleared cap re-caps instantly)"
rm -f "$(_health_redispatch_cap_file "$KEY")"
lap "$PR" slug-cap "$SHA"
[ "$(hc_invocations)" = "4" ] || fail "removing the cap marker should re-arm the gate (got $(hc_invocations))"
[ "$(_health_dispatch_count "$KEY")" = "1" ] || fail "the re-armed budget should start over at 1"
ok

# ── (7) RESET-ON-PROGRESS: a terminal verdict clears counter + cap marker ────
PR=102; SHA=bbbbbbb2; KEY="$PR-$SHA"
printf '2\n' > "$(_health_dispatch_count_file "$KEY")"
printf '%s\n' "$(date +%s)	$PR	$SHA	slug-reset	3" > "$(_health_redispatch_cap_file "$KEY")"
printf 'CLEAN\tclean\n' > "$(_health_dispatch_file "$KEY")"     # a landed terminal verdict
DISPLAY=(); _HC_RESULT=""
_healthcheck_gate "$PR" slug-reset "$WT" 0 "$SHA"
[ "$_HC_RESULT" = "CLEAN" ] || fail "a landed CLEAN should collect (got '$_HC_RESULT')"
[ -f "$(_health_dispatch_count_file "$KEY")" ] && fail "a terminal verdict must clear the counter"
[ -f "$(_health_redispatch_cap_file "$KEY")" ] && fail "a terminal verdict must clear the cap marker"
ok

# ── (8) … but an unparseable payload must NOT refund the budget ──────────────
PR=103; SHA=ccccccc3; KEY="$PR-$SHA"
printf '2\n' > "$(_health_dispatch_count_file "$KEY")"
printf 'GARBAGE-NOT-A-VERDICT\n' > "$(_health_dispatch_file "$KEY")"
DISPLAY=(); _HC_RESULT=""
_healthcheck_gate "$PR" slug-bad "$WT" 0 "$SHA"
[ "$_HC_RESULT" = "RUNNING" ] || fail "an unparseable payload is an infra death (got '$_HC_RESULT')"
[ "$(_health_dispatch_count "$KEY")" = "2" ] \
  || fail "an unparseable payload must leave the lap budget standing (got $(_health_dispatch_count "$KEY"))"
ok

# ── (9) SALVAGE from a complete FAILING .progress tail ───────────────────────
PR=104; SHA=ddddddd4; KEY="$PR-$SHA"
: > "$(_health_log_file "$KEY")"                                  # the 0-byte one-shot log
cat > "$(_health_heartbeat_file "$KEY")" <<'PROG'
1..3
ok 1 first thing
not ok 2 tests/test-widget.sh reproduced a real failure
ok 3 third thing
PROG
before="$(hc_invocations)"
DISPLAY=(); _HC_RESULT=""
_healthcheck_gate "$PR" slug-salv "$WT" 0 "$SHA"
[ "$_HC_RESULT" = "CODEERROR" ] || fail "a complete failing tail should salvage a red (got '$_HC_RESULT')"
[ "$(hc_invocations)" = "$before" ] || fail "salvage must not burn a lap"
grep -q "not ok 2 tests/test-widget.sh" "$(_health_result_file "$PR" "$SHA")" \
  || fail "the salvaged verdict should carry the failing line"
grep -q "salvaged from the .progress companion" "$(_health_result_file "$PR" "$SHA")" \
  || fail "a salvaged verdict must be TAGGED as salvaged"
[ "$(journal_count health_verdict_salvaged)" -ge 1 ] || fail "expected a health_verdict_salvaged event"
grep -q "needs you" <<< "${DISPLAY[0]:-}" || fail "a salvaged red should paint the health needs-you row"
ok
# project-wrapper shape ("suite: N tests" + per-file completion lines)
PR=105; SHA=eeeeeee5; KEY="$PR-$SHA"
: > "$(_health_log_file "$KEY")"
cat > "$(_health_heartbeat_file "$KEY")" <<'PROG'
suite: 2 tests
[health-progress] test-alpha.sh ok
[health-progress] test-beta.sh FAIL
PROG
DISPLAY=(); _HC_RESULT=""
_healthcheck_gate "$PR" slug-salv2 "$WT" 0 "$SHA"
[ "$_HC_RESULT" = "CODEERROR" ] || fail "a complete failing wrapper tail should salvage (got '$_HC_RESULT')"
grep -q "test-beta.sh FAIL" "$(_health_result_file "$PR" "$SHA")" \
  || fail "the salvaged verdict should name the failing test file"
ok

# ── (10) salvage REFUSES an incomplete tail and an all-pass tail ─────────────
PR=106; SHA=fffffff6; KEY="$PR-$SHA"
: > "$(_health_log_file "$KEY")"
printf '1..5\nok 1 a\nnot ok 2 b\n' > "$(_health_heartbeat_file "$KEY")"   # 2 of 5 — incomplete
[ -z "$(_health_salvage_detail "$(_health_log_file "$KEY")")" ] \
  || fail "an INCOMPLETE tail must never be salvaged"
ok
PR=107; SHA=ggggggg7; KEY="$PR-$SHA"
: > "$(_health_log_file "$KEY")"
printf '1..2\nok 1 a\nok 2 b\n' > "$(_health_heartbeat_file "$KEY")"       # complete, all-pass
[ -z "$(_health_salvage_detail "$(_health_log_file "$KEY")")" ] \
  || fail "an all-pass tail must never be salvaged (a fabricated CLEAN could MERGE unverified code)"
before="$(hc_invocations)"
lap "$PR" slug-pass "$SHA"
[ "$(hc_invocations)" = "$(( before + 1 ))" ] \
  || fail "an all-pass tail must fall through to the ordinary (bounded) re-dispatch"
[ -f "$(_health_result_file "$PR" "$SHA")" ] && fail "an all-pass tail must NEVER cache a CLEAN"
ok
# a real (non-empty) log is never salvaged over — the collector owns that path
PR=108; SHA=hhhhhhh8; KEY="$PR-$SHA"
printf 'real suite output\n' > "$(_health_log_file "$KEY")"
printf '1..1\nnot ok 1 boom\n' > "$(_health_heartbeat_file "$KEY")"
[ -z "$(_health_salvage_detail "$(_health_log_file "$KEY")")" ] \
  || fail "salvage must never run over a log that has real bytes"
ok

# ── (11) stale-sha hygiene ──────────────────────────────────────────────────
PR=109; OLD=1111111a; NEW=2222222b
printf '3\n' > "$(_health_dispatch_count_file "$PR-$OLD")"
printf 'x\n'  > "$(_health_redispatch_cap_file "$PR-$OLD")"
printf '1\n' > "$(_health_dispatch_count_file "$PR-$NEW")"
printf 'x\n'  > "$(_health_redispatch_cap_file "$PR-$NEW")"
_discard_stale_health "$PR" "$NEW"
[ -f "$(_health_redispatch_cap_file "$PR-$OLD")" ] \
  && fail "a cap marker for a superseded sha must be swept (else it paints a stale needs-you row)"
[ -f "$(_health_dispatch_count_file "$PR-$OLD")" ] && fail "a superseded sha's counter must be swept"
[ -f "$(_health_redispatch_cap_file "$PR-$NEW")" ] || fail "the CURRENT sha's cap marker must survive"
[ -f "$(_health_dispatch_count_file "$PR-$NEW")" ] || fail "the CURRENT sha's counter must survive"
ok

# ── (12) CROSS-ENGINE: the LIVE python dispatcher enforces the SAME bound ────
PSTATE="$T/pstate"; mkdir -p "$PSTATE"
PWT="$T/pwt"; mkdir -p "$PWT"; printf 'gitdir: /pool\n' > "$PWT/.git"
printf '3\n' > "$PSTATE/.health-dispatch-count-201-abc1234"
PYTHONPATH="$REPO/pysrc" python3 - <<PYEOF || fail "(12) python cap"
import json, os, sys
sys.path.insert(0, "$REPO/pysrc")
from herd.live_runtime import LiveGates, LiveState, LiveJournal, LiveCandidate, WAIT

os.environ["WORKTREES_DIR"] = "$PSTATE"
state = LiveState(state_dir="$PSTATE"); state.dir = "$PSTATE"
j = LiveJournal("$PSTATE/j.jsonl")
gates = LiveGates("/nonexistent-home", state, j, config={"HEALTH_CONCURRENCY": "1"})
cand = LiveCandidate(pr=201, sha="abc1234", slug="feat-201", worktree="$PWT")

assert gates.health(cand) == WAIT, "a capped key must HOLD, never a fabricated verdict"
cap = "$PSTATE/.health-redispatch-cap-201-abc1234"
assert os.path.exists(cap), "python must arm the SAME cap-marker file bash reads"
assert not os.path.exists("$PSTATE/.health-inflight-201-abc1234"), "a capped key must not dispatch"
assert not os.path.exists("$PSTATE/.health-result-201-abc1234"), "a capped key must not cache a verdict"
assert not os.path.exists("$PSTATE/.health-dispatch-count-201-abc1234"), "arming must clear the counter"
evs = [json.loads(l) for l in open("$PSTATE/j.jsonl", encoding="utf-8") if l.strip()]
caps = [e for e in evs if e.get("event") == "health_redispatch_cap"]
assert len(caps) == 1, "expected exactly one health_redispatch_cap event, got %r" % caps
assert str(caps[0].get("count")) == "3", "the event must carry the lap count: %r" % caps[0]
assert gates.health(cand) == WAIT and len(
    [e for e in (json.loads(l) for l in open("$PSTATE/j.jsonl", encoding="utf-8") if l.strip())
     if e.get("event") == "health_redispatch_cap"]) == 1, "a standing cap must not re-journal"
print("python: capped, no dispatch, one event")
PYEOF
ok
# the console row for a PYTHON-armed cap is painted by the BASH render half off that same marker —
# the whole escalation surface for the live engine, so it must parse a marker it did not write.
_saved_trees="$TREES"; TREES="$PSTATE"
pyrow="$(_health_redispatch_cap_row "$(_slug_cell feat-201)" " #201 ·" "201-abc1234")"
TREES="$_saved_trees"
grep -q "needs you" <<< "$pyrow" || fail "bash must paint a needs-you row for a python-armed cap"
grep -q "3×" <<< "$pyrow" || fail "the row must read the lap count out of python's marker (got: $pyrow)"
ok
# … and the same salvage, on the same file shapes
: > "$PSTATE/.health-log-202-def5678"
cat > "$PSTATE/.health-log-202-def5678.progress" <<'PROG'
1..2
ok 1 fine
not ok 2 tests/test-widget.sh reproduced a real failure
PROG
PYTHONPATH="$REPO/pysrc" python3 - <<PYEOF || fail "(12) python salvage"
import json, os, sys
sys.path.insert(0, "$REPO/pysrc")
from herd.live_runtime import LiveGates, LiveState, LiveJournal, LiveCandidate

os.environ["WORKTREES_DIR"] = "$PSTATE"
state = LiveState(state_dir="$PSTATE"); state.dir = "$PSTATE"
j = LiveJournal("$PSTATE/j2.jsonl")
gates = LiveGates("/nonexistent-home", state, j, config={"HEALTH_CONCURRENCY": "1"})
cand = LiveCandidate(pr=202, sha="def5678", slug="feat-202", worktree="$PWT")

assert gates.health(cand) == "CODEERROR", "a complete failing tail should salvage a red"
assert not os.path.exists("$PSTATE/.health-inflight-202-def5678"), "salvage must not burn a lap"
cached = open("$PSTATE/.health-result-202-def5678", encoding="utf-8").read()
assert "not ok 2 tests/test-widget.sh" in cached, "salvaged verdict should carry the failing line"
assert "salvaged from the .progress companion" in cached, "a salvaged verdict must be TAGGED"
evs = [json.loads(l) for l in open("$PSTATE/j2.jsonl", encoding="utf-8") if l.strip()]
assert [e for e in evs if e.get("event") == "health_verdict_salvaged"], "expected the salvage event"
print("python: salvaged, no dispatch")
PYEOF
ok

# ── (13) mirrored predicates agree, bash vs python, on one fixture matrix ────
# The two implementations are deliberate mirrors (multi-seat doctrine rule 2 — one notion of the bound).
# Drive both over the SAME files so the mirror cannot drift silently.
FX="$T/fx"; mkdir -p "$FX"
: > "$FX/log-complete-fail";   printf '1..2\nok 1 a\nnot ok 2 boom\n' > "$FX/log-complete-fail.progress"
: > "$FX/log-complete-pass";   printf '1..2\nok 1 a\nok 2 b\n'        > "$FX/log-complete-pass.progress"
: > "$FX/log-partial";         printf '1..9\nnot ok 1 boom\n'         > "$FX/log-partial.progress"
: > "$FX/log-no-companion"
bash_answers="$T/bash-answers.txt"; : > "$bash_answers"
for f in log-complete-fail log-complete-pass log-partial log-no-companion; do
  printf '%s|%s\n' "$f" "$(_health_salvage_detail "$FX/$f")" >> "$bash_answers"
done
# capped(): probe the shared predicate through its real file inputs, at, below and above the bound
capped_bash="$T/capped-bash.txt"; : > "$capped_bash"
for n in 0 2 3 7; do
  printf '%s\n' "$n" > "$(_health_dispatch_count_file "probe-$n")"
  if _health_redispatch_capped "probe-$n"; then
    printf '%s|yes\n' "$n" >> "$capped_bash"
  else
    printf '%s|no\n' "$n" >> "$capped_bash"
  fi
  rm -f "$(_health_dispatch_count_file "probe-$n")"
done
PYTHONPATH="$REPO/pysrc" python3 - "$FX" "$bash_answers" "$capped_bash" <<'PYEOF' || fail "(13) bash/python mirror drift"
import os, sys
from herd.live_runtime import _health_salvage_detail, _health_redispatch_capped
fx, bash_answers, capped_bash = sys.argv[1:4]
for line in open(bash_answers, encoding="utf-8"):
    name, _, expected = line.rstrip("\n").partition("|")
    got = _health_salvage_detail(os.path.join(fx, name))
    assert got == expected, "salvage mirror drift on %s: bash=%r python=%r" % (name, expected, got)
for line in open(capped_bash, encoding="utf-8"):
    n, _, expected = line.rstrip("\n").partition("|")
    path = os.path.join(fx, "count-%s" % n)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("%s\n" % n)
    got = "yes" if _health_redispatch_capped(path, os.path.join(fx, "no-such-cap")) else "no"
    assert got == expected, "cap mirror drift at n=%s: bash=%s python=%s" % (n, expected, got)
print("mirror: bash and python agree on every fixture")
PYEOF
ok

echo "PASS ($pass checks) — health re-dispatch cap + .progress salvage (HERD-742)"
