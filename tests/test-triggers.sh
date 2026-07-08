#!/usr/bin/env bash
# test-triggers.sh — hermetic test + SIM for SCHEDULED / TRIGGERED RUNS (HERD-169). No herdr, no
# network, no real lanes: triggers.sh is driven directly, the durable spawn queue is exercised two
# ways (a stub via HERD_TRIGGERS_SPAWN_CMD for the diff sim, and the REAL spawn.sh against a temp queue
# to prove intents actually land), and the schedule clock is driven with --now.
#
# The headline SIM (Case 3) drives TWO scheduled ticks:
#   tick 1 (first run) → full run · tick 2 with UNCHANGED input → no spawn · a CHANGED input → delta spawn.
#
# Run:  bash tests/test-triggers.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
TRIG="$ROOT/scripts/herd/triggers.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass(){ PASS=$((PASS+1)); }

TAB=$'\t'

# A spawn STUB: records "slug|lane|task" per enqueue so the sim can assert exactly what was spawned.
SPAWNLOG="$T/spawn.log"
STUB="$T/spawn-stub.sh"
cat > "$STUB" <<'STUB'
#!/usr/bin/env bash
printf '%s|%s|%s\n' "$1" "$2" "$3" >> "$SPAWNLOG"
exit 0
STUB
chmod +x "$STUB"
export SPAWNLOG

# Common env: point the trigger list + state dir + input dir at the temp sandbox, freeze `date` off the
# stub is unnecessary (we pass --now), and route spawns through the stub.
STATE="$T/state"
export HERD_TRIGGERS_STATE_DIR="$STATE"
export HERD_TRIGGERS_SPAWN_CMD="$STUB"
export HERD_TRIGGERS_INPUT_DIR="$T"
export PROJECT_ROOT="$T/proj"; mkdir -p "$PROJECT_ROOT/.herd"

INPUT_A="$T/input-a"; INPUT_B="$T/input-b"
FIX="$T/triggers.tsv"
export HERD_TRIGGERS_FILE="$FIX"

run(){ bash "$TRIG" "$@"; }

# ── Case 1: validate — a wholly-valid list passes; bad rows are each flagged ─────────────────────────
printf 'watch-a\t@hourly\tquick\tFix {item} for {name}.\tcat %s\n' "$INPUT_A" >  "$FIX"
printf 'watch-b\t@hourly\tfeature\tBuild {item}.\tcat %s\n'          "$INPUT_B" >> "$FIX"
run validate >/dev/null 2>&1 || fail "(1) a valid triggers.tsv must validate clean"
run enabled              || fail "(1) triggers_enabled must be true for a non-empty list"

BAD="$T/bad.tsv"
{
  printf 'no-lane\t@hourly\tboguslane\tt\tcat x\n'
  printf 'bad-sched\tevery:30x\tquick\tt\tcat x\n'
  printf 'missing\t@daily\tquick\t\tcat x\n'
} > "$BAD"
verr="$(HERD_TRIGGERS_FILE="$BAD" run validate 2>&1)"; vrc=$?
[ "$vrc" -eq 1 ] || fail "(1) a triggers.tsv with bad rows must exit 1 (got $vrc)"
printf '%s' "$verr" | grep -q "invalid lane='boguslane'"   || fail "(1) bad lane not flagged"
printf '%s' "$verr" | grep -q "invalid schedule='every:30x'" || fail "(1) bad schedule not flagged"
printf '%s' "$verr" | grep -q "'missing' — 'schedule'"     || fail "(1) missing required field not flagged"
pass
echo "PASS (1) validate: valid list clean, bad lane/schedule/missing-field each flagged"

# ── Case 2: interval + due-ness unit checks ─────────────────────────────────────────────────────────
iv(){ bash -c '. "$1"; _triggers_interval "$2"' _ "$TRIG" "$2" 2>/dev/null; }
[ "$(iv x @hourly)" = "3600" ]   || fail "(2) @hourly must be 3600s"
[ "$(iv x @daily)"  = "86400" ]  || fail "(2) @daily must be 86400s"
[ "$(iv x @weekly)" = "604800" ] || fail "(2) @weekly must be 604800s"
[ "$(iv x every:30m)" = "1800" ] || fail "(2) every:30m must be 1800s"
[ "$(iv x every:2h)"  = "7200" ] || fail "(2) every:2h must be 7200s"
[ "$(iv x every:3d)"  = "259200" ] || fail "(2) every:3d must be 259200s"
[ "$(iv x manual)" = "manual" ] || fail "(2) manual must report 'manual'"
iv x every:5x >/dev/null 2>&1 && fail "(2) every:5x must be unparseable"
iv x nonsense >/dev/null 2>&1 && fail "(2) an unknown schedule must be unparseable"
# due: no last-fire → due; within interval → not due; past interval → due; manual → never due.
NOW=1000000000
run due watch-a @hourly "$NOW" >/dev/null 2>&1 || fail "(2) first-ever fire (no .last) must be due"
mkdir -p "$STATE"; printf '%s\n' "$NOW" > "$STATE/watch-a.last"
run due watch-a @hourly "$((NOW + 60))"   >/dev/null 2>&1 && fail "(2) 60s after a fire, @hourly must NOT be due"
run due watch-a @hourly "$((NOW + 3600))" >/dev/null 2>&1 || fail "(2) 3600s after a fire, @hourly must be due"
run due watch-a manual  "$((NOW + 999999))" >/dev/null 2>&1 && fail "(2) a manual trigger must NEVER be due on a tick"
rm -rf "$STATE"
pass
echo "PASS (2) interval parsing (@hourly/@daily/@weekly/every:<N>[smhd]) + schedule due-ness"

# ── Case 3: THE SIM — two scheduled ticks (first run → full · unchanged → none · changed → delta) ───
: > "$SPAWNLOG"; rm -rf "$STATE"
printf 'x\ny\n'  > "$INPUT_A"    # watch-a baseline
printf 'one\n'   > "$INPUT_B"    # watch-b baseline
printf 'watch-a\t@hourly\tquick\tFix {item} for {name}.\tcat %s\n' "$INPUT_A" >  "$FIX"
printf 'watch-b\t@hourly\tfeature\tBuild {item}.\tcat %s\n'        "$INPUT_B" >> "$FIX"

# Tick 1 — first run: EVERYTHING spawns, loudly labelled as a full run.
T1="$(run tick --now "$NOW" 2>&1)"
printf '%s' "$T1" | grep -q "watch-a': FIRST RUN" || fail "(3) tick1 must announce watch-a FIRST RUN ($T1)"
printf '%s' "$T1" | grep -q "watch-b': FIRST RUN" || fail "(3) tick1 must announce watch-b FIRST RUN"
grep -q '^watch-a-x|quick|Fix x for watch-a.$'  "$SPAWNLOG" || fail "(3) tick1 must spawn watch-a-x with rendered task ($(cat "$SPAWNLOG"))"
grep -q '^watch-a-y|quick|Fix y for watch-a.$'  "$SPAWNLOG" || fail "(3) tick1 must spawn watch-a-y"
grep -q '^watch-b-one|feature|Build one.$'      "$SPAWNLOG" || fail "(3) tick1 must spawn watch-b-one with the feature lane"
[ "$(wc -l < "$SPAWNLOG")" -eq 3 ] || fail "(3) tick1 must spawn exactly 3 (got $(wc -l < "$SPAWNLOG"): $(cat "$SPAWNLOG"))"
[ -f "$STATE/watch-a.snapshot" ] && [ -f "$STATE/watch-b.snapshot" ] || fail "(3) tick1 must persist per-trigger snapshots"

# Between ticks: watch-a UNCHANGED; watch-b gains a new line "two".
printf 'one\ntwo\n' > "$INPUT_B"

# A tick only 60s later: NOT due (@hourly) → nothing fires at all.
: > "$SPAWNLOG"
run tick --now "$((NOW + 60))" >/dev/null 2>&1
[ ! -s "$SPAWNLOG" ] || fail "(3) a not-due tick (60s later) must spawn nothing ($(cat "$SPAWNLOG"))"

# Tick 2 — 2h later, both due: watch-a unchanged → NO spawn; watch-b → ONLY the delta 'two'.
: > "$SPAWNLOG"
T2="$(run tick --now "$((NOW + 7200))" 2>&1)"
printf '%s' "$T2" | grep -q "watch-a': input unchanged" || fail "(3) tick2 watch-a must report 'input unchanged' ($T2)"
printf '%s' "$T2" | grep -q "watch-b': input changed"   || fail "(3) tick2 watch-b must report 'input changed'"
grep -q '^watch-b-two|feature|Build two.$' "$SPAWNLOG" || fail "(3) tick2 must spawn the delta watch-b-two ($(cat "$SPAWNLOG"))"
grep -q 'watch-a' "$SPAWNLOG" && fail "(3) tick2 must NOT re-spawn unchanged watch-a"
grep -q 'watch-b-one' "$SPAWNLOG" && fail "(3) tick2 must NOT re-spawn the already-seen watch-b-one"
[ "$(wc -l < "$SPAWNLOG")" -eq 1 ] || fail "(3) tick2 must spawn exactly 1 delta (got $(wc -l < "$SPAWNLOG"): $(cat "$SPAWNLOG"))"
pass
echo "PASS (3) SIM: tick1 full run (3 spawns) · not-due tick silent · tick2 unchanged→0 + changed→1 delta"

# ── Case 4: FAIL-SOFT — an input command error spawns nothing and PRESERVES the last snapshot ────────
: > "$SPAWNLOG"
printf 'fragile\t@hourly\tquick\tt {item}\tsh -c "exit 7"\n' > "$FIX"
# Seed a good snapshot + an OLD last-fire so the trigger is due.
mkdir -p "$STATE"; printf 'keep-me\n' > "$STATE/fragile.snapshot"; printf '1\n' > "$STATE/fragile.last"
ferr="$(run tick --now "$NOW" 2>&1)"
[ ! -s "$SPAWNLOG" ] || fail "(4) an input-error trigger must spawn nothing ($(cat "$SPAWNLOG"))"
printf '%s' "$ferr" | grep -q "input command FAILED" || fail "(4) an input error must be reported loudly ($ferr)"
[ "$(cat "$STATE/fragile.snapshot")" = "keep-me" ] || fail "(4) a failed input read must NOT overwrite the good snapshot"
[ "$(cat "$STATE/fragile.last")" = "1" ] || fail "(4) a failed input read must NOT advance the schedule clock"
pass
echo "PASS (4) fail-soft: input error spawns nothing, keeps the snapshot + clock, warns loudly"

# ── Case 5: manual triggers — never fire on tick, fire on `fire` ─────────────────────────────────────
: > "$SPAWNLOG"; rm -rf "$STATE"
printf 'on-demand\tmanual\tquick\tGo {item}\tprintf "a\\nb\\n"\n' > "$FIX"
run tick --now "$NOW" >/dev/null 2>&1
[ ! -s "$SPAWNLOG" ] || fail "(5) a manual trigger must NOT fire on a tick ($(cat "$SPAWNLOG"))"
run fire on-demand "$NOW" >/dev/null 2>&1 || fail "(5) 'fire' on a manual trigger must run"
grep -q '^on-demand-a|quick|Go a$' "$SPAWNLOG" || fail "(5) fire must spawn on-demand-a"
grep -q '^on-demand-b|quick|Go b$' "$SPAWNLOG" || fail "(5) fire must spawn on-demand-b"
run fire no-such-trigger "$NOW" >/dev/null 2>&1 && fail "(5) firing an unknown trigger must exit non-zero"
pass
echo "PASS (5) manual triggers: silent on tick, fire-on-demand spawns; unknown name errors"

# ── Case 6: DORMANCY — absent + empty + comments-only list is a byte-identical no-op ─────────────────
: > "$SPAWNLOG"; rm -rf "$STATE"
rm -f "$FIX"                     # absent
run enabled 2>/dev/null && fail "(6) an ABSENT list must report not-enabled"
run tick --now "$NOW" >/dev/null 2>&1 || fail "(6) a tick on an absent list must be a clean no-op"
printf '# just a comment\n\n' > "$FIX"   # comments-only
run enabled 2>/dev/null && fail "(6) a comments-only list must report not-enabled"
run tick --now "$NOW" >/dev/null 2>&1
[ ! -s "$SPAWNLOG" ] || fail "(6) a dormant list must spawn nothing"
[ ! -d "$STATE" ] || fail "(6) a dormant list must write NO state under .herd/"
pass
echo "PASS (6) dormancy: absent/empty/comments-only list → not-enabled, no spawn, no state written"

# ── Case 7: the REAL spawn.sh path — a delta actually LANDS an intent on the durable queue ──────────
: > "$SPAWNLOG"
unset HERD_TRIGGERS_SPAWN_CMD    # use the real scripts/herd/spawn.sh this time
QTREES="$T/qtrees"; mkdir -p "$QTREES"
PROJ2="$T/proj2"; mkdir -p "$PROJ2/.herd"
cat > "$PROJ2/.herd/config" <<EOF
PROJECT_ROOT="$PROJ2"
WORKSPACE_NAME="trigtest"
SCRIBE_BACKEND="file"
BACKLOG_FILE="BACKLOG.md"
WORKTREES_DIR="$QTREES"
EOF
REALIN="$T/realin"; printf 'alpha\n' > "$REALIN"
printf 'realq\t@hourly\tfeature\tShip {item}\tcat %s\n' "$REALIN" > "$FIX"
( cd "$PROJ2" && HERD_CONFIG_FILE="$PROJ2/.herd/config" HERD_TRIGGERS_FILE="$FIX" \
    HERD_TRIGGERS_STATE_DIR="$T/rstate" HERD_TRIGGERS_INPUT_DIR="$T" \
    bash "$TRIG" tick --now "$NOW" >/dev/null 2>&1 )
req="$(ls "$QTREES/spawn-queue"/*.req 2>/dev/null | head -1)"
[ -n "$req" ] || fail "(7) the real spawn.sh must land a .req intent on the durable queue"
[ "$(sed -n '1p' "$req")" = "realq-alpha" ] || fail "(7) queued intent slug wrong ($(sed -n '1p' "$req"))"
[ "$(sed -n '2p' "$req")" = "feature" ]     || fail "(7) queued intent lane wrong ($(sed -n '2p' "$req"))"
[ "$(sed -n '3p' "$req")" = "Ship alpha" ]  || fail "(7) queued intent task wrong ($(sed -n '3p' "$req"))"
pass
echo "PASS (7) real spawn.sh: a trigger delta enqueues a well-formed intent onto the durable queue"

echo
echo "ALL PASS ($PASS checks) — scheduled/triggered runs: validate, schedule due-ness, two-tick diff sim, fail-soft, manual, dormancy, real-queue enqueue."
