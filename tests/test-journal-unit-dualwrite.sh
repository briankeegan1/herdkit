#!/usr/bin/env bash
# test-journal-unit-dualwrite.sh — hermetic proof of the HERD-397 work-unit dual-write
# (scripts/herd/journal.sh, spike: docs/spikes/work-unit-abstraction.md Phase 2).
#
# Covers:
#   (1) journal_unit_ref composes "kind:id" — the single format both journal.sh's own dual-write
#       and work-unit.sh's wunit_ref delegate to.
#   (2) every journal_append call carrying a `pr` key gets an ADDITIVE unit="git-pr:<n>" key —
#       every original field (including pr itself) passes through byte-for-byte and in order.
#   (3) an event with no `pr` key is untouched — no unit key is added.
#   (4) a caller that already supplies its own `unit` (a future non-git-pr writer) is left alone —
#       journal.sh never overwrites it with the git-pr-derived ref.
#   (5) wunit_ref (scripts/herd/work-unit.sh) delegates to the SAME journal_unit_ref, so the facade
#       can never drift from the format journal.sh's dual-write actually writes.
#   (6) BYTE-IDENTICAL READERS: `herd why <pr>` / `herd log --pr N` produce IDENTICAL output whether
#       the fixture journal carries the new unit= field or not — no reader may depend on unit= yet.
#
# Fully hermetic: writes only under a mktemp dir. Run:  bash tests/test-journal-unit-dualwrite.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
JOURNAL_SH="$REPO/scripts/herd/journal.sh"
WORK_UNIT_SH="$REPO/scripts/herd/work-unit.sh"
HERD_BIN="$REPO/bin/herd"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

[ -f "$JOURNAL_SH" ] || fail "journal.sh not found at $JOURNAL_SH"
command -v python3 >/dev/null 2>&1 || fail "python3 required to run this test"

_field() {
  python3 -c '
import sys, json
with open(sys.argv[1]) as f:
    lines = [l for l in f if l.strip()]
o = json.loads(lines[int(sys.argv[2])])
v = o.get(sys.argv[3], "<MISSING>")
sys.stdout.write(str(v))
' "$1" "$2" "$3"
}
_has_key() {
  python3 -c '
import sys, json
with open(sys.argv[1]) as f:
    lines = [l for l in f if l.strip()]
o = json.loads(lines[int(sys.argv[2])])
sys.exit(0 if sys.argv[3] in o else 1)
' "$1" "$2" "$3"
}

# ── (1) journal_unit_ref: the canonical composer ─────────────────────────────────────────────────
# shellcheck source=/dev/null
. "$JOURNAL_SH" || fail "sourcing journal.sh failed"
type journal_unit_ref >/dev/null 2>&1 || fail "journal_unit_ref not defined after sourcing journal.sh"
ok
[ "$(journal_unit_ref git-pr 42)" = "git-pr:42" ] || fail "journal_unit_ref git-pr 42 should compose git-pr:42"
ok

# ── (2) additive dual-write on a pr-carrying event ───────────────────────────────────────────────
export JOURNAL_FILE="$T/j1/journal.jsonl"
journal_append merge pr 42 slug feat-x sha deadbeef method --merge reason gates_passed
[ "$(_field "$JOURNAL_FILE" 0 pr)" = "42" ]                || fail "pr field must survive unchanged"
ok
[ "$(_field "$JOURNAL_FILE" 0 unit)" = "git-pr:42" ]       || fail "unit field must be additively derived from pr"
ok
[ "$(_field "$JOURNAL_FILE" 0 slug)" = "feat-x" ]          || fail "slug field must survive unchanged"
ok
[ "$(_field "$JOURNAL_FILE" 0 sha)" = "deadbeef" ]         || fail "sha field must survive unchanged"
ok
[ "$(_field "$JOURNAL_FILE" 0 method)" = "--merge" ]       || fail "method field must survive unchanged"
ok
[ "$(_field "$JOURNAL_FILE" 0 reason)" = "gates_passed" ]  || fail "reason field must survive unchanged"
ok

# ── (3) no pr key -> no unit key added ───────────────────────────────────────────────────────────
export JOURNAL_FILE="$T/j2/journal.jsonl"
journal_append sweep_closed tab_id tab-123 reason orphan
_has_key "$JOURNAL_FILE" 0 unit && fail "an event with no pr key must not gain a unit key"
ok

# ── (4) an explicit unit is never overwritten by the git-pr-derived ref ─────────────────────────
export JOURNAL_FILE="$T/j3/journal.jsonl"
journal_append custom_apply pr 7 unit "doc:xyz" path docs/spikes/foo.md
[ "$(_field "$JOURNAL_FILE" 0 unit)" = "doc:xyz" ] || fail "an explicit unit key must win over the git-pr-derived one"
ok
[ "$(_field "$JOURNAL_FILE" 0 pr)" = "7" ]         || fail "pr field must still survive alongside an explicit unit"
ok

# ── (5) wunit_ref (work-unit.sh) delegates to the same composer ─────────────────────────────────
(
  set -uo pipefail
  MAINDIR="$T/proj"; TREESDIR="$T/proj-trees"
  mkdir -p "$MAINDIR" "$TREESDIR"
  git init -q -b main "$MAINDIR"
  git -C "$MAINDIR" config user.email t@t.local; git -C "$MAINDIR" config user.name t
  echo base > "$MAINDIR/f.txt"; git -C "$MAINDIR" add -A; git -C "$MAINDIR" commit -qm base
  git -C "$MAINDIR" update-ref refs/remotes/origin/main HEAD

  export HERD_DRIVER=headless
  export PROJECT_ROOT="$MAINDIR" WORKTREES_DIR="$TREESDIR" WORKSPACE_NAME=dualwritews
  export DEFAULT_BRANCH="origin/main"
  export HERD_CONFIG_FILE="$T/no-such-config"
  export JOURNAL_FILE="$T/wref-journal.jsonl"; : > "$JOURNAL_FILE"

  # shellcheck source=/dev/null
  . "$WORK_UNIT_SH" || { echo "FAIL: sourcing work-unit.sh failed"; exit 1; }
  out="$(wunit_ref git-pr 42)"
  [ "$out" = "git-pr:42" ] || { echo "FAIL: wunit_ref git-pr 42 = '$out', expected git-pr:42"; exit 1; }
  echo WUNIT_REF_OK
) > "$T/wref.out" 2>&1 || { cat "$T/wref.out" >&2; fail "(5) wunit_ref delegation failed"; }
grep -q WUNIT_REF_OK "$T/wref.out" || { cat "$T/wref.out" >&2; fail "(5) wunit_ref did not compose the expected ref"; }
ok

# ── (6) byte-identical readers: herd why / herd log ignore the new unit= field ──────────────────
unset JOURNAL_FILE   # sections (2)-(4) left an override exported; readers must use the fixture below
PROJ="$T/rproj"; TREES="$T/rtrees"
mkdir -p "$PROJ/.herd" "$TREES/.herd"
cat > "$PROJ/.herd/config" <<CFG
PROJECT_ROOT="$PROJ"
WORKTREES_DIR="$TREES"
WORKSPACE_NAME="dualwrite-rtest"
CFG

# Fixture A: today's shape (no unit field) — the pre-dual-write baseline. Includes `pr_restale`,
# which has NO dedicated describe() branch in herd why (bin/herd, pysrc/herd/why.py) — it hits the
# GENERIC fallback dump both readers fall back to for the ~200 event types describe() doesn't
# special-case. A review caught that an earlier version of this fixture used ONLY describe()-branch
# events, so it could never fail on a fallback-dump regression even though the fallback is the common
# path (describe() special-cases ~18 of the ~200+ events scripts/herd/*.sh emits).
cat > "$TREES/.herd/journal.jsonl" <<'JNL'
{"ts":"2026-07-02T14:03:12Z","event":"review_dispatched","pr":54,"sha":"abc1234def","pid":12345,"model":"claude-opus-4-8"}
{"ts":"2026-07-02T14:09:44Z","event":"healthcheck_attempted","pr":54,"slug":"feat-x","attempt":1,"result":"clean"}
{"ts":"2026-07-02T14:09:45Z","event":"healthcheck_outcome","pr":54,"slug":"feat-x","outcome":"CLEAN"}
{"ts":"2026-07-02T14:10:00Z","event":"pr_restale","pr":54,"sha":"abc1234def","slug":"feat-x","kind":"health","laps":2}
{"ts":"2026-07-02T14:10:01Z","event":"verdict_recorded","pr":54,"sha":"abc1234def","value":"PASS","source":"reviewer"}
{"ts":"2026-07-02T14:10:02Z","event":"merge","pr":54,"slug":"feat-x","sha":"abc1234def","method":"--merge","reason":"gates_passed"}
{"ts":"2026-07-02T14:10:05Z","event":"reap","pr":54,"slug":"feat-x","sha":"abc1234def","reason":"merged"}
JNL
why_before="$(cd "$PROJ" && HERD_NONINTERACTIVE=1 bash "$HERD_BIN" why 54 2>&1)"
log_before="$(cd "$PROJ" && HERD_NONINTERACTIVE=1 bash "$HERD_BIN" log --pr 54 2>&1)"
# Sanity: the fallback dump actually renders pr_restale's non-pr fields, so this fixture would have
# caught a regression that leaks `unit=` into it (if it doesn't, the byte-identical diff below is
# vacuous for the exact gap this test exists to close).
printf '%s\n' "$why_before" | grep -q 'kind=health' || fail "fixture sanity: pr_restale must hit herd why's fallback dump"
ok

# Fixture B: same events, dual-written (unit= additive on every line) — what journal_append now emits.
cat > "$TREES/.herd/journal.jsonl" <<'JNL'
{"ts":"2026-07-02T14:03:12Z","event":"review_dispatched","pr":54,"sha":"abc1234def","pid":12345,"model":"claude-opus-4-8","unit":"git-pr:54"}
{"ts":"2026-07-02T14:09:44Z","event":"healthcheck_attempted","pr":54,"slug":"feat-x","attempt":1,"result":"clean","unit":"git-pr:54"}
{"ts":"2026-07-02T14:09:45Z","event":"healthcheck_outcome","pr":54,"slug":"feat-x","outcome":"CLEAN","unit":"git-pr:54"}
{"ts":"2026-07-02T14:10:00Z","event":"pr_restale","pr":54,"sha":"abc1234def","slug":"feat-x","kind":"health","laps":2,"unit":"git-pr:54"}
{"ts":"2026-07-02T14:10:01Z","event":"verdict_recorded","pr":54,"sha":"abc1234def","value":"PASS","source":"reviewer","unit":"git-pr:54"}
{"ts":"2026-07-02T14:10:02Z","event":"merge","pr":54,"slug":"feat-x","sha":"abc1234def","method":"--merge","reason":"gates_passed","unit":"git-pr:54"}
{"ts":"2026-07-02T14:10:05Z","event":"reap","pr":54,"slug":"feat-x","sha":"abc1234def","reason":"merged","unit":"git-pr:54"}
JNL
why_after="$(cd "$PROJ" && HERD_NONINTERACTIVE=1 bash "$HERD_BIN" why 54 2>&1)"
log_after="$(cd "$PROJ" && HERD_NONINTERACTIVE=1 bash "$HERD_BIN" log --pr 54 2>&1)"

[ "$why_before" = "$why_after" ] || fail "herd why output must be byte-identical whether or not unit= is present"
ok
[ "$log_before" = "$log_after" ] || fail "herd log --pr output must be byte-identical whether or not unit= is present"
ok

echo "ALL PASS ($pass checks)"
