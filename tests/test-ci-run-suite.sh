#!/usr/bin/env bash
# test-ci-run-suite.sh — hermetic test of scripts/ci/run-suite.sh, the cross-platform
# CI suite runner. Covers the ONE thing it adds over the healthcheck's plain loop: the
# per-platform env-sensitive ALLOWLIST classification. Also covers HERD-664 diff-scoped selection
# and HERD-665 bounded intra-shard parallelism (HERD_CI_SUITE_WORKERS): OFF (unset/0/garbage) is
# byte-identical to serial, ON preserves the same pass/fail/XFAIL bookkeeping and print order (the
# FIFO drain queue waits on launch order, not completion order), and actually overlaps in wall-clock.
#
# Fully hermetic: it points the runner at a TEMP tests dir of fake pass/fail scripts and a
# TEMP allowlist via the runner's env knobs, and forces the direct (non-bats) path. No real
# tests, no bats, no network. Run:  bash tests/test-ci-run-suite.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
RUNNER="$ROOT/scripts/ci/run-suite.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass(){ PASS=$((PASS+1)); }

[ -f "$RUNNER" ] || fail "missing runner: $RUNNER"

# ── a temp suite: one green, one red, one red-but-env-sensitive ──────────────────
TD="$T/tests"; mkdir -p "$TD"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TD/test-green.sh"
printf '#!/usr/bin/env bash\nexit 1\n' > "$TD/test-red.sh"
printf '#!/usr/bin/env bash\nexit 1\n' > "$TD/test-flaky-env.sh"
chmod +x "$TD"/*.sh

AL="$T/allow.tsv"
cat > "$AL" <<'EOF'
# comment ignored
name	platforms	reason
test-flaky-env.sh	windows	needs Git Bash python3 shim
EOF

run() {  # run(platform) -> sets RC + OUT
  OUT="$(HERD_CI_FORCE_DIRECT=1 HERD_CI_PLATFORM="$1" \
         HERD_CI_TESTS_DIR="$TD" HERD_CI_ALLOWLIST="$AL" \
         bash "$RUNNER" 2>&1)"; RC=$?
}

# (1) ubuntu: the env-sensitive test is NOT allowlisted here → counts as a real failure → rc 1.
run ubuntu
[ "$RC" -eq 1 ] || fail "ubuntu: expected rc 1 (real failures), got $RC"
grep -qE "real failures: +2" <<< "$OUT" || fail "ubuntu: expected 2 real failures.  Got:\n$OUT"
grep -qE "passed: +1" <<< "$OUT" || fail "ubuntu: expected 1 pass.  Got:\n$OUT"
pass

# (2) windows: test-flaky-env.sh is allowlisted → XFAIL, only test-red.sh is a real failure → rc 1.
run windows
[ "$RC" -eq 1 ] || fail "windows: expected rc 1 (one real failure remains), got $RC"
grep -q "XFAIL (env-sensitive) test-flaky-env.sh" <<< "$OUT" || fail "windows: expected XFAIL line.  Got:\n$OUT"
grep -qE "real failures: +1" <<< "$OUT" || fail "windows: expected 1 real failure.  Got:\n$OUT"
pass

# (3) an all-green suite exits 0 on every platform.
rm -f "$TD/test-red.sh" "$TD/test-flaky-env.sh"
run ubuntu
[ "$RC" -eq 0 ] || fail "all-green: expected rc 0, got $RC.  Out:\n$OUT"
grep -q "CI SUITE CLEAN" <<< "$OUT" || fail "all-green: expected CLEAN banner.  Got:\n$OUT"
pass

# (4) `all` in the platforms column allows on any platform.
printf '#!/usr/bin/env bash\nexit 1\n' > "$TD/test-any.sh"; chmod +x "$TD/test-any.sh"
printf 'name\tplatforms\treason\ntest-any.sh\tall\talways env-sensitive\n' > "$AL"
run macos
[ "$RC" -eq 0 ] || fail "all-platform allow: expected rc 0 on macos, got $RC.  Out:\n$OUT"
grep -q "XFAIL (env-sensitive) test-any.sh" <<< "$OUT" || fail "all-platform allow: expected XFAIL.  Got:\n$OUT"
pass

# (5) empty test dir → usage/setup error (rc 2), never a silent green.
ED="$T/empty"; mkdir -p "$ED"
OUT="$(HERD_CI_FORCE_DIRECT=1 HERD_CI_PLATFORM=ubuntu HERD_CI_TESTS_DIR="$ED" HERD_CI_ALLOWLIST="$AL" bash "$RUNNER" 2>&1)"; RC=$?
[ "$RC" -eq 2 ] || fail "empty dir: expected rc 2, got $RC.  Out:\n$OUT"
pass

# ── HERD-436 legibility: a test that supports the shared `--artifacts DIR --keep` convention (the
# sim/chaos family: test-gate-reconciler-chaos-sim.sh, test-merge-queue-sim.sh, test-merge-result-gate-
# sim.sh) must (a) have its failing checkpoint line(s) surfaced even when they scroll off a plain
# tail, and (b) have its scorecard.json survive past its own process into a caller-controlled dir —
# previously the test's own EXIT trap deleted its mktemp ART dir the instant it failed, discarding the
# one artifact that names which assertion actually failed.
TD2="$T/tests2"; mkdir -p "$TD2"
cat > "$TD2/test-artifact-red-sim.sh" <<'EOF'
#!/usr/bin/env bash
ART=""; KEEP=""
while [ $# -gt 0 ]; do
  case "$1" in
    --artifacts) ART="${2:-}"; KEEP=1; shift 2 ;;
    --keep)      KEEP=1; shift ;;
    *) shift ;;
  esac
done
[ -n "$ART" ] || ART="$(mktemp -d)"
mkdir -p "$ART"
echo "FAIL checkpoint_one: something specific broke"
for i in $(seq 1 20); do echo "noise line $i (padding past a 6/10-line tail)"; done
echo '{"result":"fail"}' > "$ART/scorecard.json"
exit 1
EOF
chmod +x "$TD2/test-artifact-red-sim.sh"
cat > "$TD2/test-artifact-green-sim.sh" <<'EOF'
#!/usr/bin/env bash
ART=""
while [ $# -gt 0 ]; do
  case "$1" in
    --artifacts) ART="${2:-}"; shift 2 ;;
    --keep)      shift ;;
    *) shift ;;
  esac
done
[ -n "$ART" ] || exit 1
mkdir -p "$ART"
echo '{"result":"pass"}' > "$ART/scorecard.json"
exit 0
EOF
chmod +x "$TD2/test-artifact-green-sim.sh"

ARTDIR="$T/artroot"
OUT="$(HERD_CI_FORCE_DIRECT=1 HERD_CI_PLATFORM=ubuntu HERD_CI_TESTS_DIR="$TD2" \
       HERD_CI_ARTIFACTS_DIR="$ARTDIR" bash "$RUNNER" 2>&1)"; RC=$?
[ "$RC" -eq 1 ] || fail "artifacts: expected rc 1 (the red sim fails), got $RC.  Out:\n$OUT"
grep -q "FAIL checkpoint_one: something specific broke" <<< "$OUT" \
  || fail "artifacts: expected the failing checkpoint line surfaced (not just a tail).  Got:\n$OUT"
[ -f "$ARTDIR/test-artifact-red-sim.sh/scorecard.json" ] \
  || fail "artifacts: expected scorecard.json to survive under $ARTDIR/test-artifact-red-sim.sh"
[ ! -e "$ARTDIR/test-artifact-green-sim.sh" ] \
  || fail "artifacts: a passing test's artifacts should be pruned, found $ARTDIR/test-artifact-green-sim.sh"
pass

# ══ HERD-664: DIFF-SCOPED SELECTION (scope FIRST, then shard) ═════════════════════
# The runner now takes the PR's base ref (HERD_CI_SCOPE_BASE_REF), diffs HEAD against its merge-base
# with it, scopes the curated set to what that diff can break, and shards the SCOPED set. Everything
# below drives the REAL runner over a REAL throwaway git repo — never a reimplementation of the
# composition — because the false-green shape here is precisely a runner that silently runs fewer
# tests than it claims. Each fixture test records the fact that it ran, so every assertion is about
# what the runner ACTUALLY executed, not about what its header said it would.
SR="$T/scoperepo"
mkdir -p "$SR/scripts/herd" "$SR/tests"
RUNLOG="$T/ran.log"
for n in alpha beta gamma delta epsilon core-guard; do
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "${0##*/}" >> "$HERD_TEST_RUNLOG"\nexit 0\n' \
    > "$SR/tests/test-$n.sh"
done
printf '#!/usr/bin/env bash\n: alpha\n' > "$SR/scripts/herd/alpha.sh"
printf '#!/usr/bin/env bash\n: beta\n'  > "$SR/scripts/herd/beta.sh"
printf 'test-core-guard.sh\n' > "$SR/tests/scope-core.tsv"     # the always-run core, in every selection
# an UNMAPPABLE path (fail-closed probe) — NOT README.md/docs/*.md: HERD-733 maps those to the
# doc-lint tests instead of failing closed, so the probe here must be a non-docs, non-paired path.
printf 'fixture blob\n' > "$SR/blob.dat"
# curated mode needs a herd.bats the runner's parse guard accepts (it never runs it AS bats).
printf '#!/usr/bin/env bats\n\n@test "fixture placeholder" {\n  true\n}\n' > "$SR/tests/herd.bats"
chmod +x "$SR/tests"/*.sh

GITQ=(git -C "$SR" -c user.email=t@t -c user.name=t)
"${GITQ[@]}" init -q
"${GITQ[@]}" add blob.dat scripts/herd/alpha.sh scripts/herd/beta.sh tests/herd.bats \
  tests/scope-core.tsv tests/test-alpha.sh tests/test-beta.sh tests/test-gamma.sh \
  tests/test-delta.sh tests/test-epsilon.sh tests/test-core-guard.sh
"${GITQ[@]}" commit -q -m base -- blob.dat scripts tests
"${GITQ[@]}" branch scope-base                                 # the "PR base branch" this diffs against

ALL_SIX="$(printf 'test-alpha.sh\ntest-beta.sh\ntest-core-guard.sh\ntest-delta.sh\ntest-epsilon.sh\ntest-gamma.sh\n')"
SCOPED_TWO="$(printf 'test-alpha.sh\ntest-core-guard.sh\n')"

scope_run() {  # scope_run <shard_index> <shard_count> [<base-ref>] → RC, OUT, RAN
  : > "$RUNLOG"
  OUT="$(HERD_CI_PLATFORM=ubuntu HERD_CI_TESTS_DIR="$SR/tests" \
         HERD_CI_SCOPE_REPO="$SR" HERD_CI_SCOPE_BASE_REF="${3-}" \
         HERD_CI_SHARD_INDEX="$1" HERD_CI_SHARD_COUNT="$2" \
         HERD_TEST_RUNLOG="$RUNLOG" \
         bash "$RUNNER" 2>&1)"; RC=$?
  RAN="$(LC_ALL=C sort "$RUNLOG")"
}

# The "PR": one mapped script changes. Its paired test + the always-run core is the whole selection.
printf '#!/usr/bin/env bash\n: alpha touched\n' > "$SR/scripts/herd/alpha.sh"
"${GITQ[@]}" commit -q -m touch-alpha -- scripts/herd/alpha.sh

# (6) SCOPED: the runner announces the narrowing loudly and runs EXACTLY the scoped tests.
scope_run 1 1 scope-base
[ "$RC" -eq 0 ] || fail "(6) scoped run: expected rc 0, got $RC.  Out:\n$OUT"
grep -q "scoped 2 of 6 curated tests" <<< "$OUT" \
  || fail "(6) scoped run must announce 'scoped N of M curated tests' in the header.  Got:\n$OUT"
[ "$RAN" = "$SCOPED_TWO" ] || fail "(6) scoped run executed the wrong tests.
--- ran ---
$RAN
--- want ---
$SCOPED_TWO"
grep -q "scoped=2/6" <<< "$OUT" || fail "(6) the summary banner must carry the scoped counts.  Got:\n$OUT"
pass

# (7) MUTATION-PROVE the composition IN THE RUNNER: scope-then-shard, unioned across a full matrix
# row, runs each scoped test EXACTLY once — no drop, no duplicate — and a shard with no scoped test
# exits 0 fast instead of erroring on an "empty" selection. This is the whole point of scoping FIRST:
# 4 shards over a 2-test selection means 2 runners have nothing to do, and they must say so and stop.
: > "$T/union.log"
empty_shards=0
for i in 1 2 3 4; do
  scope_run "$i" 4 scope-base
  [ "$RC" -eq 0 ] || fail "(7) shard $i/4: expected rc 0, got $RC.  Out:\n$OUT"
  cat "$RUNLOG" >> "$T/union.log"
  if [ -z "$RAN" ]; then
    empty_shards=$((empty_shards + 1))
    grep -q "has NO scoped tests" <<< "$OUT" \
      || fail "(7) shard $i/4 ran nothing but never said so — a silent empty shard.  Got:\n$OUT"
  fi
done
UNION="$(LC_ALL=C sort "$T/union.log")"
[ "$UNION" = "$SCOPED_TWO" ] || fail "(7) the union of scoped-then-sharded shards is not the scoped selection.
--- union ---
$UNION
--- want ---
$SCOPED_TWO"
[ "$empty_shards" -ge 1 ] || fail "(7) no shard came back empty — the empty-slice path was never exercised"
pass

# (8) FAIL-CLOSED, unmappable path: one file no rule maps re-arms the WHOLE curated set, and the run
# is identical to the unscoped one — the byte-identical guarantee that makes narrowing safe.
printf 'fixture blob touched\n' > "$SR/blob.dat"
"${GITQ[@]}" commit -q -m touch-blob -- blob.dat
scope_run 1 1 scope-base
[ "$RC" -eq 0 ] || fail "(8) fail-closed run: expected rc 0, got $RC.  Out:\n$OUT"
grep -q "scoped 6 of 6 curated tests (fail-closed:" <<< "$OUT" \
  || fail "(8) an unmappable path must announce a fail-closed FULL selection.  Got:\n$OUT"
[ "$RAN" = "$ALL_SIX" ] || fail "(8) fail-closed run must execute the entire curated set.
--- ran ---
$RAN
--- want ---
$ALL_SIX"
grep -q "scoped=" <<< "$OUT" && fail "(8) a fail-closed run is not a narrowed run — it must not claim a scoped count in the banner"
pass

# (9) FAIL-CLOSED, unobtainable diff: an unresolvable base ref can never read as "nothing changed".
scope_run 1 1 no-such-base-ref
[ "$RC" -eq 0 ] || fail "(9) unobtainable-diff run: expected rc 0, got $RC.  Out:\n$OUT"
grep -q "fail-closed: cannot diff" <<< "$OUT" \
  || fail "(9) an unresolvable base ref must say so and fall back.  Got:\n$OUT"
[ "$RAN" = "$ALL_SIX" ] || fail "(9) an unobtainable diff must run the entire curated set, ran:\n$RAN"
pass

# (10) LEVER OFF (no base ref — a push to main, or any caller that never opts in): the full curated
# set runs and the runner says NOTHING new, so the pre-HERD-664 output is untouched.
scope_run 1 1
[ "$RC" -eq 0 ] || fail "(10) unscoped run: expected rc 0, got $RC.  Out:\n$OUT"
[ "$RAN" = "$ALL_SIX" ] || fail "(10) an unscoped run must execute the entire curated set, ran:\n$RAN"
grep -q "scoped" <<< "$OUT" && fail "(10) the lever is OFF — the runner must not print a scope line.  Got:\n$OUT"
pass


# ══ HERD-665: BOUNDED INTRA-SHARD PARALLELISM (HERD_CI_SUITE_WORKERS) ═════════════════════════════
# Ship-dormant: the default (unset, or any non-numeric/zero garbage) must run exactly as before — same
# order, same pass/fail/XFAIL bookkeeping, same output modulo the one added ", workers=N" banner
# fragment once the knob is actually raised. A value > 1 must both (a) preserve that output and (b)
# actually overlap tests in wall-clock, or the knob is a no-op wearing a lever.
WD="$T/workers"; mkdir -p "$WD"
printf '#!/usr/bin/env bash\nexit 0\n' > "$WD/test-green-a.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$WD/test-green-b.sh"
printf '#!/usr/bin/env bash\nexit 1\n' > "$WD/test-red-c.sh"
printf '#!/usr/bin/env bash\nexit 1\n' > "$WD/test-flaky-env-d.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$WD/test-green-e.sh"
chmod +x "$WD"/*.sh
WAL="$T/workers-allow.tsv"
printf 'name\tplatforms\treason\ntest-flaky-env-d.sh\tall\tflaky by design\n' > "$WAL"

run_workers() {  # run_workers(<workers-or-empty>) -> sets RC + OUT
  OUT="$(HERD_CI_FORCE_DIRECT=1 HERD_CI_PLATFORM=ubuntu HERD_CI_TESTS_DIR="$WD" HERD_CI_ALLOWLIST="$WAL" \
         HERD_CI_SUITE_WORKERS="${1:-}" bash "$RUNNER" 2>&1)"; RC=$?
}

# (11) DEFAULT (unset) is unaffected: no "workers=" fragment appears anywhere in the output.
run_workers ""
DEFAULT_RC=$RC
[ "$DEFAULT_RC" -eq 1 ] || fail "(11) default workers: expected rc 1 (test-red-c real failure), got $RC.  Out:\n$OUT"
grep -q "workers=" <<< "$OUT" && fail "(11) the lever is OFF by default — the banner must not mention workers.  Got:\n$OUT"
DEFAULT_OUT="$OUT"
pass

# (12) HERD_CI_SUITE_WORKERS=1 explicitly is BYTE-IDENTICAL to the unset default (still serial).
run_workers "1"
[ "$OUT" = "$DEFAULT_OUT" ] || fail "(12) HERD_CI_SUITE_WORKERS=1 must be byte-identical to unset.
--- unset ---
$DEFAULT_OUT
--- workers=1 ---
$OUT"
pass

# (13) HERD_CI_SUITE_WORKERS=3: same pass/fail/XFAIL bookkeeping as serial, banner gains ONLY the
# ", workers=3" fragment — strip it and the two outputs must match line-for-line (the FIFO drain queue
# waits on the OLDEST-LAUNCHED pid, not the first-to-finish, so launch order — and therefore print
# order — never depends on how many run concurrently).
run_workers "3"
[ "$RC" -eq "$DEFAULT_RC" ] || fail "(13) workers=3: expected the same rc ($DEFAULT_RC) as serial, got $RC.  Out:\n$OUT"
STRIPPED="$(sed 's/, workers=3//' <<< "$OUT")"
[ "$STRIPPED" = "$DEFAULT_OUT" ] || fail "(13) workers=3 output (banner fragment aside) must match serial output.
--- serial ---
$DEFAULT_OUT
--- workers=3 (stripped) ---
$STRIPPED"
pass

# (14) Garbage / zero falls back to serial (1), never to an unbounded or zero-width queue.
run_workers "0"
[ "$OUT" = "$DEFAULT_OUT" ] || fail "(14) HERD_CI_SUITE_WORKERS=0 must fall back to serial (byte-identical).  Got:\n$OUT"
run_workers "banana"
[ "$OUT" = "$DEFAULT_OUT" ] || fail "(14) a non-numeric HERD_CI_SUITE_WORKERS must fall back to serial (byte-identical).  Got:\n$OUT"
pass

# (15) The knob actually overlaps tests in wall-clock — proof it is not a no-op. 6 tests that each
# sleep 1s: serial must take >=6s; workers=6 must take comfortably under that (a generous <4s bound
# leaves headroom for a loaded CI box while still proving real overlap, not 1.0x).
SD="$T/slow"; mkdir -p "$SD"
i=1
while [ "$i" -le 6 ]; do
  printf '#!/usr/bin/env bash\nsleep 1\nexit 0\n' > "$SD/test-slow-$i.sh"
  i=$((i + 1))
done
chmod +x "$SD"/*.sh
time_workers() {  # time_workers(<workers-or-empty>) -> prints elapsed whole seconds
  local t0 t1
  t0=$(date +%s)
  HERD_CI_FORCE_DIRECT=1 HERD_CI_PLATFORM=ubuntu HERD_CI_TESTS_DIR="$SD" \
    HERD_CI_SUITE_WORKERS="${1:-}" bash "$RUNNER" >/dev/null 2>&1
  t1=$(date +%s)
  printf '%s' "$((t1 - t0))"
}
SERIAL_SECS="$(time_workers "")"
PARALLEL_SECS="$(time_workers "6")"
[ "$SERIAL_SECS" -ge 6 ] || fail "(15) 6x 1s tests serial should take >=6s, took ${SERIAL_SECS}s"
[ "$PARALLEL_SECS" -lt "$SERIAL_SECS" ] \
  || fail "(15) workers=6 (${PARALLEL_SECS}s) should be faster than serial (${SERIAL_SECS}s) — the knob did not overlap anything"
[ "$PARALLEL_SECS" -lt 4 ] \
  || fail "(15) workers=6 took ${PARALLEL_SECS}s for 6x 1s tests — expected comfortably under 4s of real overlap"
pass

echo "PASS: test-ci-run-suite ($PASS checks)"
