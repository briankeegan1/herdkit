#!/usr/bin/env bash
# test-py-shadow-runtime.sh — gate proof for the P3c SHADOW watcher runtime (HERD-316, EPIC HERD-300).
#
# P3c ports the watcher state machine to asyncio Python and runs it in SHADOW MODE: dry-run beside the
# live bash watcher, mutating nothing, emitting only .herd/journal-shadow.jsonl in journal.sh-identical
# shapes so the two event streams can be diffed for parity. This test proves the four load-bearing
# claims of that runtime, all hermetically (no herdr, gh, network, or model; python3 stdlib only):
#
#   (1) UNIT INVARIANTS — tests/test_shadow_runtime.py: dry-run (no mutation surface, shadow-journal
#       only), gate outcomes, semaphore bounds, cancel-on-supersession, the guarded P3b import.
#   (2) JOURNAL PARITY — the shadow journal ENCODING is BYTE-IDENTICAL to what scripts/herd/journal.sh
#       writes for the same (event, args). Drives the REAL journal.sh and herd.shadow_journal off one
#       set of cases and diffs the lines — the parity oracle P3 shadow mode depends on (contract §7).
#   (3) BYTE-IDENTICAL-OFF — the bash ENGINE_IMPL wiring (engine-version.sh) is a HARD no-op under the
#       ship default ENGINE_IMPL=bash: herd_engine_impl resolves 'bash' (and a typo reads as 'bash'),
#       and herd_engine_shadow_tick returns 0 having written NOTHING.
#   (4) DRY-RUN DISPATCH — armed with ENGINE_IMPL=shadow + a sim fixture, herd_engine_shadow_tick runs
#       the Python runtime and it writes ONLY the shadow journal; the real journal.jsonl gains no gate
#       events from the shadow pass (the engine's own engine_shadow_dispatched marker aside).
#
# Run:  bash tests/test-py-shadow-runtime.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 required" >&2; exit 1; }
for f in pysrc/herd/shadow_runtime.py pysrc/herd/shadow_journal.py scripts/herd/journal.sh \
         scripts/herd/engine-version.sh; do
  [ -f "$REPO/$f" ] || { echo "FAIL: missing $f" >&2; exit 1; }
done

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }
PASS=0
pass() { PASS=$((PASS + 1)); }

# ── (1) unit invariants ───────────────────────────────────────────────────────────────────────────
PYTHONPATH="$REPO/pysrc" python3 "$HERE/test_shadow_runtime.py" >/dev/null 2>&1 \
  || fail "stdlib unit tests failed (run: PYTHONPATH=pysrc python3 tests/test_shadow_runtime.py)"
pass

# ── (2) journal encoding parity vs the REAL journal.sh ──────────────────────────────────────────────
# A fixture table of (event  arg arg …) cases, one per line, fields separated by the UNIT SEPARATOR
# \x1f — NOT a tab: `read` treats tab as IFS-whitespace and would COLLAPSE an empty field, but the
# encoders must agree on an empty-string value too. \x1f is non-whitespace, so `read -a` preserves
# every field including empties (the same seam tests/test-py-decisions.sh uses). Values exercise the
# integer-coercion edges the two encoders must agree on: plain ints, a negative, a zero-padded int, a
# bare "-", an EMPTY string, a decimal (stays a string), and ordinary text.
SEP=$'\x1f'
CASES="$T/cases"
{
  printf 'merge%spr%s101%sslug%sfeat-a%ssha%saaa%smethod%ssquash%sreason%sgates_passed\n' \
    "$SEP" "$SEP" "$SEP" "$SEP" "$SEP" "$SEP" "$SEP" "$SEP" "$SEP" "$SEP"
  printf 'verdict_recorded%spr%s7%ssha%sdeadbeef%svalue%sBLOCK%ssource%sreviewer\n' \
    "$SEP" "$SEP" "$SEP" "$SEP" "$SEP" "$SEP" "$SEP" "$SEP"
  printf 'healthcheck_outcome%spr%s42%sslug%sfeat-x%soutcome%sCODEERROR\n' \
    "$SEP" "$SEP" "$SEP" "$SEP" "$SEP" "$SEP"
  printf 'refix_bounce%spr%s9%ssha%sc0ffee%sslug%ss%sround%s3%srule%sreview%slocation%s(shadow)\n' \
    "$SEP" "$SEP" "$SEP" "$SEP" "$SEP" "$SEP" "$SEP" "$SEP" "$SEP" "$SEP" "$SEP" "$SEP"
  printf 'coerce_edges%sa%s5%sb%s-5%sc%s007%sd%s-%se%s%sf%s1.5%sg%shello\n' \
    "$SEP" "$SEP" "$SEP" "$SEP" "$SEP" "$SEP" "$SEP" "$SEP" "$SEP" "$SEP" "$SEP" "$SEP" "$SEP" "$SEP"
} > "$CASES"

export HERD_JOURNAL_NOW="2026-07-10T00:00:00Z"

BOUT="$T/bash.out"; POUT="$T/py.out"; : > "$BOUT"; : > "$POUT"
# BASH side: source journal.sh once, append each case to a fresh JOURNAL_FILE, capture the line.
while IFS= read -r line; do
  [ -n "$line" ] || continue
  IFS="$SEP" read -r -a argv <<< "$line"
  jf="$T/one.jsonl"; : > "$jf"
  JOURNAL_FILE="$jf" bash -c '. "'"$REPO"'/scripts/herd/journal.sh"; journal_append "$@"' _ "${argv[@]}"
  cat "$jf" >> "$BOUT"
done < "$CASES"

# PYTHON side: encode the same argv through herd.shadow_journal.encode_event.
PYTHONPATH="$REPO/pysrc" python3 - "$CASES" >> "$POUT" <<'PY' || fail "python encoder errored"
import os, sys
from herd.shadow_journal import encode_event
ts = os.environ["HERD_JOURNAL_NOW"]
for line in open(sys.argv[1], encoding="utf-8"):
    line = line.rstrip("\n")
    if not line:
        continue
    parts = line.split("\x1f")
    event, args = parts[0], parts[1:]
    print(encode_event(event, args, ts=ts))
PY

bl="$(wc -l < "$BOUT" | tr -d ' ')"; pl="$(wc -l < "$POUT" | tr -d ' ')"
[ "$bl" = "$pl" ] || fail "line count mismatch: journal.sh=$bl shadow_journal=$pl"
if ! cmp -s "$BOUT" "$POUT"; then
  ln="$(diff "$BOUT" "$POUT" | grep -m1 -oE '^[0-9]+' || echo '?')"
  echo "---- first journal-encoding divergence at line $ln ----" >&2
  echo "journal.sh    : $(sed -n "${ln}p" "$BOUT")" >&2
  echo "shadow_journal: $(sed -n "${ln}p" "$POUT")" >&2
  fail "journal encoding parity: journal.sh and shadow_journal disagree"
fi
pass

# ── (3) byte-identical-OFF: the bash wiring is a hard no-op under the ship default ─────────────────
off_impl="$(bash -c '. "'"$REPO"'/scripts/herd/engine-version.sh"; herd_engine_impl')"
[ "$off_impl" = bash ] || fail "default ENGINE_IMPL must resolve 'bash', got '$off_impl'"
typo_impl="$(bash -c 'ENGINE_IMPL=pythonn; . "'"$REPO"'/scripts/herd/engine-version.sh"; herd_engine_impl')"
[ "$typo_impl" = bash ] || fail "a typo ENGINE_IMPL must read as 'bash', got '$typo_impl'"
# The dormant tick writes nothing while off: run it with a shadow-journal path set and assert absence.
offdir="$T/off"; mkdir -p "$offdir/.herd"
SHADOW_JOURNAL_FILE="$offdir/.herd/journal-shadow.jsonl" WORKTREES_DIR="$offdir" \
  bash -c '. "'"$REPO"'/scripts/herd/engine-version.sh"; herd_engine_shadow_tick' \
  || fail "herd_engine_shadow_tick returned nonzero while OFF (must be a hard no-op)"
[ ! -e "$offdir/.herd/journal-shadow.jsonl" ] || fail "shadow tick wrote a journal while ENGINE_IMPL=bash (not a no-op)"
pass

# ── (4) armed dry-run dispatch writes ONLY the shadow journal ──────────────────────────────────────
ondir="$T/on"; mkdir -p "$ondir/.herd"
cat > "$T/fixture.json" <<'JSON'
{"config":{"MERGE_POLICY":"auto","REVIEW_CONCURRENCY":2,"HEALTH_CONCURRENCY":1},
 "candidates":[
   {"pr":301,"sha":"s1","slug":"a","health":"CLEAN","review":"PASS"},
   {"pr":302,"sha":"s2","slug":"b","health":"CODEERROR","review":"PASS"},
   {"pr":303,"sha":"s3","slug":"c","stale":true}
 ]}
JSON
HERDKIT_HOME="$REPO" WORKTREES_DIR="$ondir" ENGINE_IMPL=shadow HERD_ENGINE_SHADOW_SYNC=1 \
  HERD_ENGINE_SHADOW_FIXTURE="$T/fixture.json" \
  SHADOW_JOURNAL_FILE="$ondir/.herd/journal-shadow.jsonl" \
  bash -c '. "'"$REPO"'/scripts/herd/engine-version.sh"; herd_engine_shadow_tick' \
  || fail "armed shadow tick returned nonzero"
[ -s "$ondir/.herd/journal-shadow.jsonl" ] || fail "armed shadow tick produced no shadow journal"
# The shadow stream must carry the expected terminal events and NEVER perform a real merge elsewhere.
grep -q '"event":"merge"' "$ondir/.herd/journal-shadow.jsonl" || fail "no merge event in shadow stream"
grep -q '"event":"stale_dup_hold"' "$ondir/.herd/journal-shadow.jsonl" || fail "no stale hold in shadow stream"
# The real journal.jsonl must contain ONLY the engine's own engine_shadow_dispatched marker (if any) —
# never a gate event (verdict_recorded / healthcheck_outcome / merge) from the shadow pass.
if [ -f "$ondir/.herd/journal.jsonl" ]; then
  if grep -Eq '"event":"(merge|verdict_recorded|healthcheck_outcome|stale_dup_hold)"' "$ondir/.herd/journal.jsonl"; then
    fail "a shadow-pass gate event leaked into the REAL journal.jsonl (must be dry-run)"
  fi
fi
pass

echo "ALL PASS ($PASS/4 shadow-runtime checks: unit invariants, journal parity, byte-identical-off, dry-run dispatch)"
