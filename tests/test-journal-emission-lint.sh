#!/usr/bin/env bash
# test-journal-emission-lint.sh — hermetic tests for the shared CONSUMER-ONLY EVENT guard (HERD-442):
# scripts/herd/journal-emission-lint.sh reds any journal event NAME a consumer parses that no producer
# emits.
#
# Proves:
#   (1)  The REAL tree is clean — every consumer-parsed event has a live producer or an allowlist row.
#   (2)  A consumer with NO producer REDS, and the report names the consuming site.
#   (3)  Adding the producer clears it — the lint is keyed on the producer, not on a name list.
#   (4)  NON-VACUOUS: pulling a producer OUT of the real tree reds it. This is the mutation that
#        actually happened (ede7d45 deleted human_verify_policy's producer), so it is asserted
#        against the real tree, not only a fixture.
#   (5)  A SIM is NOT a producer: an event journaled only under scripts/herd/sim/ still reds. This is
#        the self-fulfilling-guard case — sandbox-resolver-respawn-scenario.sh has been green over a
#        production emission that has not existed since P5b.
#   (6)  DYNAMIC producers are resolved: `journal_append "$1"` through a wrapper's call sites, and
#        `journal_append "$ev"` through same-file literal assignments.
#   (7)  A `"prefix_$kind"` emitter covers every name with that prefix.
#   (8)  The ALLOWLIST suppresses a name — and only the names it lists.
#   (9)  The PYTHON producer half counts: journal.append("x", …) in pysrc/herd satisfies a consumer.
#  (10)  FAIL-SOFT: a tree with no engine journal surface → skip (exit 2), never a red.
#  (11)  The §3.4 event catalog in docs/engine-contract.md is itself a consumer.
#  (12)  The LIFECYCLE alphabet is NOT mistaken for journal events (the bare `EVENTS` tuple in
#        statemachine.py / shadow_runtime.py names transitions, which nothing ever writes to JSONL).
#
# Network-free: temp dirs + fixtures only. Run:  bash tests/test-journal-emission-lint.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LINT="$ROOT/scripts/herd/journal-emission-lint.sh"

[ -f "$LINT" ] || { echo "FAIL: missing lint: $LINT" >&2; exit 1; }
# shellcheck source=/dev/null
. "$LINT"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok() { PASS=$((PASS+1)); }

# _fixture <dir> — a minimal tree with the surface the lint requires (journal.sh + pysrc/herd), plus
# an empty consumer + producer file for the test to fill in.
_fixture() {
  mkdir -p "$1/scripts/herd/sim" "$1/pysrc/herd" "$1/bin" "$1/docs"
  : > "$1/scripts/herd/journal.sh"
  : > "$1/pysrc/herd/__init__.py"
  : > "$1/scripts/herd/journal-audit.sh"
  : > "$1/scripts/herd/producer.sh"
}

# ── (1) the real tree is clean ────────────────────────────────────────────────────────────────────
out="$(herd_journal_emission_lint "$ROOT")"; rc=$?
[ "$rc" -eq 0 ] || fail "(1) the real tree must be clean; got rc=$rc:
$out"
grep -q '^ADVISORY:' <<< "$out" || fail "(1) expected an ADVISORY summary, got: $out"
grep -q '^EMISSION-ORPHAN' <<< "$out" && fail "(1) real tree reported an orphan: $out"
ok

# ── (2) a consumer with no producer REDS, naming the site ─────────────────────────────────────────
F="$T/orphan"; _fixture "$F"
printf 'if ev == "ghost_event":\n    pass\n' > "$F/pysrc/herd/why.py"
out="$(herd_journal_emission_lint "$F")"; rc=$?
[ "$rc" -eq 1 ] || fail "(2) an unproduced consumer must red (rc=1); got rc=$rc: $out"
grep -q 'EMISSION-ORPHAN ghost_event' <<< "$out" || fail "(2) orphan not named: $out"
grep -q 'pysrc/herd/why.py:1' <<< "$out" || fail "(2) consuming site not named: $out"
ok

# ── (3) adding the producer clears it ─────────────────────────────────────────────────────────────
printf 'journal_append ghost_event pr "$1"\n' > "$F/scripts/herd/producer.sh"
out="$(herd_journal_emission_lint "$F")"; rc=$?
[ "$rc" -eq 0 ] || fail "(3) a produced consumer must be clean; got rc=$rc: $out"
ok

# ── (4) NON-VACUOUS against the REAL tree: remove a producer, the lint must red ──────────────────
# The exact mutation ede7d45 performed. Copy the tree by reference where possible: only the one file
# that carries the producer is rewritten, so this stays fast and the rest of the surface is genuine.
M="$T/mutant"
mkdir -p "$M"
for d in scripts pysrc bin docs; do cp -R "$ROOT/$d" "$M/$d"; done
grep -q 'journal.append("human_verify_policy"' "$M/pysrc/herd/live_runtime.py" \
  || fail "(4) precondition: live_runtime.py must produce human_verify_policy"
python3 - "$M/pysrc/herd/live_runtime.py" <<'PYX'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
s = s.replace('self.journal.append("human_verify_policy"', 'self.journal.append("REMOVED_BY_TEST"')
open(p, "w", encoding="utf-8").write(s)
PYX
out="$(herd_journal_emission_lint "$M")"; rc=$?
[ "$rc" -eq 1 ] || fail "(4) deleting a real producer must red; got rc=$rc: $out"
grep -q 'EMISSION-ORPHAN human_verify_policy' <<< "$out" \
  || fail "(4) the deleted producer's event must be reported: $out"
ok

# ── (5) a SIM is not a producer ───────────────────────────────────────────────────────────────────
S="$T/simonly"; _fixture "$S"
printf 'if ev == "sim_only_event":\n    pass\n' > "$S/pysrc/herd/why.py"
printf 'journal_append sim_only_event pr 1\n' > "$S/scripts/herd/sim/scenario.sh"
out="$(herd_journal_emission_lint "$S")"; rc=$?
[ "$rc" -eq 1 ] || fail "(5) a sim-only emission must NOT count as a producer; got rc=$rc: $out"
grep -q 'EMISSION-ORPHAN sim_only_event' <<< "$out" || fail "(5) not reported: $out"
ok

# ── (6) dynamic producers are resolved ────────────────────────────────────────────────────────────
D="$T/dynamic"; _fixture "$D"
printf 'if ev == "wrapped_event":\n    pass\nif ev == "var_event":\n    pass\n' > "$D/pysrc/herd/why.py"
cat > "$D/scripts/herd/producer.sh" <<'SH'
_wrap() {
  journal_append "$1" component x
}
_emit_it() {
  _wrap wrapped_event x
}
_local_var() {
  local _e=var_event
  journal_append "$_e" pr "$1"
}
SH
out="$(herd_journal_emission_lint "$D")"; rc=$?
[ "$rc" -eq 0 ] || fail "(6) dynamic producers must be resolved; got rc=$rc: $out"
ok

# ── (7) a prefix emitter covers its family ────────────────────────────────────────────────────────
P="$T/prefix"; _fixture "$P"
printf 'if ev == "retire_converged":\n    pass\n' > "$P/pysrc/herd/why.py"
printf 'journal_append "retire_$kind" slug "$1"\n' > "$P/scripts/herd/producer.sh"
out="$(herd_journal_emission_lint "$P")"; rc=$?
[ "$rc" -eq 0 ] || fail "(7) a prefix emitter must cover its family; got rc=$rc: $out"
ok

# ── (8) the allowlist suppresses only what it lists ───────────────────────────────────────────────
A="$T/allow"; _fixture "$A"
printf 'if ev == "allowed_event":\n    pass\nif ev == "other_event":\n    pass\n' > "$A/pysrc/herd/why.py"
_save="$HERD_JOURNAL_EMISSION_ALLOW"
HERD_JOURNAL_EMISSION_ALLOW='
allowed_event|dropped on purpose, for this test
'
out="$(herd_journal_emission_lint "$A")"; rc=$?
HERD_JOURNAL_EMISSION_ALLOW="$_save"
[ "$rc" -eq 1 ] || fail "(8) the un-allowlisted name must still red; got rc=$rc: $out"
grep -q 'EMISSION-ORPHAN other_event' <<< "$out" || fail "(8) other_event must red: $out"
grep -q 'EMISSION-ORPHAN allowed_event' <<< "$out" && fail "(8) allowlisted name leaked: $out"
ok

# ── (9) the python producer half counts ───────────────────────────────────────────────────────────
Y="$T/pyprod"; _fixture "$Y"
printf 'if ev == "py_made_event":\n    pass\n' > "$Y/pysrc/herd/why.py"
printf 'x.journal.append("py_made_event", "pr", 1)\n' > "$Y/pysrc/herd/emitter.py"
out="$(herd_journal_emission_lint "$Y")"; rc=$?
[ "$rc" -eq 0 ] || fail "(9) a python producer must satisfy a consumer; got rc=$rc: $out"
ok

# ── (10) fail-soft on a tree with no engine journal surface ───────────────────────────────────────
N="$T/notengine"; mkdir -p "$N/src"
out="$(herd_journal_emission_lint "$N")"; rc=$?
[ "$rc" -eq 2 ] || fail "(10) a non-engine tree must SKIP (rc=2), never red; got rc=$rc: $out"
[ -z "$out" ] || fail "(10) a skip must print nothing; got: $out"
# The reason is read DIRECTLY, not through `$(…)`: a command substitution runs the function in a
# subshell, so the variable it sets there can never reach this scope. Same shape as the other shared
# lints (the gate surfaces branch on the rc and use the reason only when they call in-scope).
HERD_JOURNAL_EMISSION_SKIP_REASON=""
herd_journal_emission_lint "$N" >/dev/null
[ -n "$HERD_JOURNAL_EMISSION_SKIP_REASON" ] || fail "(10) a skip must carry a reason"
ok

# ── (11) the §3.4 event catalog is a consumer ─────────────────────────────────────────────────────
C="$T/contract"; _fixture "$C"
cat > "$C/docs/engine-contract.md" <<'MD'
### 3.4 Event catalog (names, required fields)

| Event | Keys | Anchor |
|---|---|---|
| `documented_only` | pr, sha | somewhere |

## 4. Next section
MD
out="$(herd_journal_emission_lint "$C")"; rc=$?
[ "$rc" -eq 1 ] || fail "(11) a documented-but-unproduced event must red; got rc=$rc: $out"
grep -q 'EMISSION-ORPHAN documented_only' <<< "$out" || fail "(11) not reported: $out"
ok

# ── (12) the lifecycle alphabet is not mistaken for journal events ────────────────────────────────
L="$T/lifecycle"; _fixture "$L"
cat > "$L/pysrc/herd/statemachine.py" <<'PYF'
EVENTS = (
    "health_clean", "decide_merge", "approved",
)
for ev in ("new_sha", "sibling_restale"):
    pass
PYF
out="$(herd_journal_emission_lint "$L")"; rc=$?
[ "$rc" -eq 0 ] || fail "(12) the transition alphabet must not be read as journal events: $out"
ok

# ── (13) a WRAPPED python emit is still a producer ────────────────────────────────────────────────
# A long emit routinely puts the event name on the line after `journal.append(`. A per-line producer
# scan misses it and reports a live producer as an orphan — a guard whose scan surface is narrower
# than the code it guards, which is this whole bug class turned on the lint itself. Caught for real:
# the restored hv_body_unreadable emit wraps exactly this way.
W="$T/wrapped"; _fixture "$W"
printf 'if ev == "wrapped_emit":\n    pass\n' > "$W/pysrc/herd/why.py"
cat > "$W/pysrc/herd/emitter.py" <<'PYF'
def go(self, cand):
    self.journal.append(
        "wrapped_emit", "pr", cand.pr, "sha", cand.sha)
PYF
out="$(herd_journal_emission_lint "$W")"; rc=$?
[ "$rc" -eq 0 ] || fail "(13) a wrapped python emit must count as a producer; got rc=$rc: $out"
ok

# ── (14) parses under EVERY bash on this box, not just the ambient one ────────────────────────────
# The builder's light gate runs `bash -n` with the AMBIENT bash. On macOS that is 3.2, which parses a
# here-document inside a command substitution differently from bash 5.x: 5.x ends the heredoc at the
# first line whose PREFIX matches the delimiter, so `<<'PY'` was closed early by the body line
# `PY_APPEND = …` and the remaining python was parsed as shell. Locally green, ubuntu red — and
# because this file is SOURCED by healthcheck.sh, the syntax error surfaced inside UNRELATED tests'
# output (test-attribution-lint, test-baseline-gate) rather than pointing at itself.
#
# So this file is syntax-checked against every bash the box has, newest included. On a single-bash
# host the loop still runs once and the check is honest about covering only what is installed.
_bashes=""
for _b in /bin/bash /usr/bin/bash /usr/local/bin/bash /opt/homebrew/bin/bash "$(command -v bash 2>/dev/null)"; do
  case " $_bashes " in *" $_b "*) continue ;; esac
  [ -x "$_b" ] || continue
  _bashes="$_bashes $_b"
  "$_b" -n "$LINT" 2>/dev/null || fail "(14) $LINT does not parse under $_b ($("$_b" --version | head -1))"
done
[ -n "$_bashes" ] || fail "(14) no bash found to syntax-check with"
ok

echo "ALL PASS ($PASS checks · parsed under:$_bashes)"
