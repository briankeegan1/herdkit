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
#   (3) RETIRED RESOLUTION (HERD-306) — post-cutover herd_engine_impl resolves the SOLE engine 'python'
#       (unset and typo alike), and the retired ENGINE_IMPL=shadow WARNs loudly. The shadow_journal
#       ENCODER stays — it is the parity oracle, not the retired live dispatch.
#   (4) RETIRED SHADOW TICK — the live per-tick shadow dispatch is gone: herd_engine_shadow_tick is a
#       HARD no-op (returns 0, writes NO shadow journal) even when armed with ENGINE_IMPL=shadow + a
#       fixture. Only the retired-value warning fires. The parity oracle (parity-run.sh → shadow_runtime)
#       is invoked out-of-band and is unaffected.
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
# WORKTREES_DIR="" (empty, falsy) so ShadowJournal(path=None) finds no destination, as the
# test_journal_failure_never_raises assertion requires; a non-empty WORKTREES_DIR would resolve a
# path and cause that test to return True instead of False.
HERD_CONFIG_FILE="$T/no-such-config" WORKTREES_DIR="" \
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

# ── (3) retired resolution: the sole engine is 'python'; ENGINE_IMPL=shadow WARNs (HERD-306) ────────
off_impl="$(bash -c '. "'"$REPO"'/scripts/herd/engine-version.sh"; herd_engine_impl' 2>/dev/null)"
[ "$off_impl" = python ] || fail "default ENGINE_IMPL must resolve the sole engine 'python', got '$off_impl'"
typo_impl="$(bash -c 'ENGINE_IMPL=pythonn; . "'"$REPO"'/scripts/herd/engine-version.sh"; herd_engine_impl' 2>/dev/null)"
[ "$typo_impl" = python ] || fail "a typo ENGINE_IMPL must resolve 'python', got '$typo_impl'"
warn="$(bash -c 'ENGINE_IMPL=shadow; . "'"$REPO"'/scripts/herd/engine-version.sh"; herd_engine_impl' 2>&1 >/dev/null)"
printf '%s' "$warn" | grep -qi 'RETIRED' || fail "ENGINE_IMPL=shadow must WARN that it is retired (got: '$warn')"
pass

# ── (4) retired shadow tick: a HARD no-op even when armed — writes NO shadow journal ────────────────
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
  bash -c '. "'"$REPO"'/scripts/herd/engine-version.sh"; herd_engine_shadow_tick' 2>/dev/null \
  || fail "retired herd_engine_shadow_tick must still return 0 (a hard no-op)"
[ ! -e "$ondir/.herd/journal-shadow.jsonl" ] || fail "retired shadow tick wrote a shadow journal (must be a no-op)"
# No gate event leaks anywhere.
if [ -f "$ondir/.herd/journal.jsonl" ]; then
  grep -Eq '"event":"(merge|verdict_recorded|healthcheck_outcome|stale_dup_hold)"' "$ondir/.herd/journal.jsonl" \
    && fail "the retired shadow tick leaked a gate event into the journal"
fi
pass

echo "ALL PASS ($PASS/4 shadow-runtime checks: unit invariants, journal parity, retired resolution, retired shadow tick)"
