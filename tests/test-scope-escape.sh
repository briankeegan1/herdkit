#!/usr/bin/env bash
# test-scope-escape.sh — hermetic tests for HERD-575 scoping-escape telemetry
# (scripts/herd/scope-escape.sh), the shared detector behind:
#   • .herd/healthcheck.project.sh's scoped-run recorder (herd_scope_gate_record)
#   • scripts/herd/agent-watch.sh's main-health/CI red chokepoint (_scope_escape_detect, called from
#     _main_health_set_red), which asks herd_scope_gate_was_scoped then herd_scope_escape_check
#
# Covers:
#   (1) a scoped gate run journals ONE `gate_scoped` event naming its sha
#   (2) herd_scope_gate_was_scoped is true for a recorded sha, false for an unrecorded one
#   (3) a red on an ALREADY-SCOPED sha, whose failing test is absent from the RECOMPUTED selection,
#       journals ONE `scope_escape` event and returns a candidate row naming the miss
#   (4) a red on a sha that was NEVER recorded scoped journals nothing (the unscoped-run case)
#   (5) a red whose failing test IS present in the recomputed selection is not an escape (scoping
#       would have caught it) — journals nothing
#   (6) a failing identity that names no test-*.sh token cannot prove a miss — journals nothing
#   (7) a recompute that comes back as the FULL curated set proves nothing — journals nothing
#   (8) herd_scope_escape_append_candidate appends the row once, is idempotent on a repeat, and never
#       materializes a candidate file that does not already exist
#   (9) the committed tests/suite-deps-candidates.tsv ledger exists with its documented header, and
#       both production call sites (the recorder, the detector) are actually wired
#
# Fully hermetic: a mktemp'd JOURNAL_FILE + fixture tests/ dir; no real git checkout, no herdr/gh/
# network/model. Run:  bash tests/test-scope-escape.sh
# No `set -e`: several checks assert non-zero returns explicitly.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SHARD="$ROOT/scripts/herd/suite-shard.sh"
JOURNAL_LIB="$ROOT/scripts/herd/journal.sh"
LIB="$ROOT/scripts/herd/scope-escape.sh"
WRAPPER="$ROOT/.herd/healthcheck.project.sh"
WATCH="$ROOT/scripts/herd/agent-watch.sh"
LEDGER="$ROOT/tests/suite-deps-candidates.tsv"

for f in "$SHARD" "$JOURNAL_LIB" "$LIB"; do
  [ -f "$f" ] || { echo "FAIL: missing required file: $f" >&2; exit 1; }
done
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 required to run this test" >&2; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ PASS=$((PASS+1)); echo "PASS $1"; }

export JOURNAL_FILE="$T/journal.jsonl"
jcount() { local n; n="$(grep -c "$1" "$JOURNAL_FILE" 2>/dev/null)" || n=0; printf '%s' "${n:-0}"; }

# shellcheck source=/dev/null
. "$SHARD"
# shellcheck source=/dev/null
. "$JOURNAL_LIB"
# shellcheck source=/dev/null
. "$LIB"

# ── fixture tests dir: two curated tests, no core names present (an isolated fixture, mirroring
# tests/test-suite-scope.sh's own `# suite-deps:` fixture shape) ───────────────────────────────────
FIX="$T/tests"; mkdir -p "$FIX"
printf '#!/usr/bin/env bash\necho "ALL PASS"\n' > "$FIX/test-alpha.sh"
printf '#!/usr/bin/env bash\necho "ALL PASS"\n' > "$FIX/test-orphan.sh"
CURATED="$(herd_suite_curated_tests "$FIX")"
[ "$CURATED" = "$(printf 'test-alpha.sh\ntest-orphan.sh')" ] \
  || fail "fixture setup: unexpected curated set: $CURATED"

SHA1="deadbeef1111111111111111111111deadbeef"
SHA2="deadbeef2222222222222222222222deadbeef"

# scripts/herd/alpha.sh is name-paired to test-alpha.sh; test-orphan.sh declares no suite-deps, so a
# diff to alpha.sh narrows to test-alpha.sh alone — this is the "undeclared dependency" shape a scope
# escape proves: test-orphan.sh actually depends on alpha.sh, but nothing says so.
SEL="$(herd_suite_tests_for_diff "$FIX" scripts/herd/alpha.sh)"
[ "$SEL" = "test-alpha.sh" ] || fail "fixture setup: expected selection 'test-alpha.sh', got: $SEL"

# ── (1) a scoped gate run journals ONE gate_scoped event naming its sha ────────────────────────────
herd_scope_gate_record "$SHA1" "$SEL" "$CURATED"
[ "$(jcount '"event":"gate_scoped"')" -eq 1 ] || fail "(1) expected exactly 1 gate_scoped event"
grep -q "\"sha\":\"$SHA1\"" "$JOURNAL_FILE" || fail "(1) gate_scoped event does not name sha $SHA1"
grep -q '"selected":1' "$JOURNAL_FILE" || fail "(1) gate_scoped event should record selected=1"
grep -q '"total":2' "$JOURNAL_FILE" || fail "(1) gate_scoped event should record total=2"
ok "(1) a narrowed gate run journals one gate_scoped event with sha + selected/total counts"

# ── (2) herd_scope_gate_was_scoped: true for the recorded sha, false for an unrecorded one ─────────
herd_scope_gate_was_scoped "$SHA1" || fail "(2) SHA1 was recorded scoped and must read true"
herd_scope_gate_was_scoped "$SHA2" && fail "(2) SHA2 was never recorded and must read false"
herd_scope_gate_was_scoped "" && fail "(2) an empty sha must never read true"
ok "(2) herd_scope_gate_was_scoped distinguishes a recorded sha from an unrecorded one"

# ── (3) a red on the scoped sha, missing from the recompute, is a proven escape ─────────────────────
ROW="$(herd_scope_escape_check "$SHA1" "test-orphan.sh failed (see log)" "$FIX" scripts/herd/alpha.sh)"
rc=$?
[ "$rc" -eq 0 ] || fail "(3) a genuine miss must return 0, got $rc"
[ -n "$ROW" ] || fail "(3) a genuine miss must print a candidate row"
grep -qF -- "test-orphan.sh" <<< "$ROW" || fail "(3) candidate row must name the missed test: $ROW"
grep -qF -- "scripts/herd/alpha.sh" <<< "$ROW" || fail "(3) candidate row must name the changed path: $ROW"
grep -qF -- "$SHA1" <<< "$ROW" || fail "(3) candidate row must name the sha: $ROW"
[ "$(printf '%s' "$ROW" | awk -F'\t' '{print NF}')" -eq 3 ] || fail "(3) candidate row must be 3 tab-separated fields: $ROW"
[ "$(jcount '"event":"scope_escape"')" -eq 1 ] || fail "(3) expected exactly 1 scope_escape event"
grep -q "\"event\":\"scope_escape\".*\"sha\":\"$SHA1\"" "$JOURNAL_FILE" \
  || fail "(3) scope_escape event does not name sha $SHA1"
grep -q '"failed":"test-orphan.sh"' "$JOURNAL_FILE" || fail "(3) scope_escape event does not name the missed test"
ok "(3) a red missing from the recomputed selection journals one scope_escape event + a candidate row"

# ── (4) unscoped-run red journals nothing ────────────────────────────────────────────────────────────
herd_scope_escape_check "$SHA2" "test-orphan.sh failed (see log)" "$FIX" scripts/herd/alpha.sh \
  && fail "(4) an unrecorded sha must never read as an escape"
[ "$(jcount '"event":"scope_escape"')" -eq 1 ] || fail "(4) an unscoped-run red must journal nothing new"
ok "(4) a red on a sha whose gate never ran scoped journals nothing"

# ── (5) a failing test the recompute WOULD have caught is not an escape ────────────────────────────
herd_scope_escape_check "$SHA1" "test-alpha.sh failed (see log)" "$FIX" scripts/herd/alpha.sh \
  && fail "(5) a test present in the recomputed selection must never read as an escape"
[ "$(jcount '"event":"scope_escape"')" -eq 1 ] || fail "(5) a caught-by-recompute red must journal nothing new"
ok "(5) a failing test already covered by the recomputed selection is not an escape"

# ── (6) a failing identity naming no test-*.sh token cannot prove a miss ────────────────────────────
herd_scope_escape_check "$SHA1" "some non code-shaped infra failure" "$FIX" scripts/herd/alpha.sh \
  && fail "(6) an identity naming no test file must never read as an escape"
[ "$(jcount '"event":"scope_escape"')" -eq 1 ] || fail "(6) an unidentifiable failure must journal nothing new"
ok "(6) a failing identity that names no test-*.sh file journals nothing"

# ── (7) a recompute that comes back as the FULL curated set proves nothing ─────────────────────────
herd_scope_escape_check "$SHA1" "test-orphan.sh failed" "$FIX" README.md \
  && fail "(7) a full-curated-set recompute must never read as an escape"
[ "$(jcount '"event":"scope_escape"')" -eq 1 ] || fail "(7) a full-set recompute must journal nothing new"
ok "(7) a recompute that falls back to the whole curated set is never reported as an escape"

# ── (8) candidate append: once, idempotent, never materializes a new file ──────────────────────────
CANDF="$T/candidates.tsv"
printf 'test\tchanged_paths\tsha\tstatus\n' > "$CANDF"
CROW="${ROW}"$'\t'"candidate"
herd_scope_escape_append_candidate "$CANDF" "$CROW"
[ "$(grep -c . "$CANDF")" -eq 2 ] || fail "(8) expected header + 1 candidate row after the first append"
grep -qxF -- "$CROW" "$CANDF" || fail "(8) the candidate row was not appended verbatim"
herd_scope_escape_append_candidate "$CANDF" "$CROW"
[ "$(grep -c . "$CANDF")" -eq 2 ] || fail "(8) a repeat append must be idempotent (no duplicate row)"
NOFILE="$T/does-not-exist.tsv"
herd_scope_escape_append_candidate "$NOFILE" "$CROW"
[ -e "$NOFILE" ] && fail "(8) append must never materialize a candidate file that did not already exist"
ok "(8) the candidate row is appended once, repeat appends are idempotent, and a missing ledger is never created"

# ── (9) the committed ledger + both production call sites are wired ────────────────────────────────
[ -f "$LEDGER" ] || fail "(9) tests/suite-deps-candidates.tsv is not committed"
grep -qE '^test[[:space:]]+changed_paths[[:space:]]+sha[[:space:]]+status$' "$LEDGER" \
  || fail "(9) tests/suite-deps-candidates.tsv is missing its documented header row"
if [ -f "$WRAPPER" ]; then
  grep -q 'herd_scope_gate_record' "$WRAPPER" \
    || fail "(9) .herd/healthcheck.project.sh does not call herd_scope_gate_record"
  ok "(9a) the healthcheck wrapper records a scoped gate's selection"
else
  ok "(9a) skipped — no .herd/healthcheck.project.sh in this tree (a consuming project)"
fi
if [ -f "$WATCH" ]; then
  grep -q '_scope_escape_detect' "$WATCH" || fail "(9) agent-watch.sh does not define/call _scope_escape_detect"
  grep -q 'herd_scope_gate_was_scoped\|herd_scope_escape_check' "$WATCH" \
    || fail "(9) agent-watch.sh's scope-escape hook never calls into scope-escape.sh"
  ok "(9b) the main-health red leg is wired to the scope-escape detector"
else
  ok "(9b) skipped — no scripts/herd/agent-watch.sh in this tree (a consuming project)"
fi

echo
echo "ALL PASS ($PASS checks) — HERD-575: a scoped gate's sha is recorded, a later red on that sha"
echo "proves an escape ONLY when the recomputed selection genuinely misses the failing test, an"
echo "unscoped-run red journals nothing, and the candidate ledger heals idempotently."
