#!/usr/bin/env bash
# test-conformance.sh — hermetic tests for the capability CONFORMANCE MATRIX (HERD-144).
#
# Exercises `herd conformance report` / `run` against a SCRATCH matrix (no real capabilities.tsv, no
# real tests, no herdr/gh/network/model), asserting:
#   (a) the three verdict classes — mapped-green (proof_ref exists), mapped-missing-ref/ROT (proof_ref
#       gone), and unmapped/GAP (capability with no mapping row).
#   (b) the `report --json` shape: total, counts{mapped,gap,rot,dangling_refs}, per-capability
#       status+proofs, and the gaps[] / rot[] lists.
#   (c) report exit status — non-zero ONLY when rot is present; gaps alone exit 0 (report-only).
#   (d) `run` verdicts (pass/fail/missing/skipped), the --kind filter, and the conformance.json shape
#       (sha/timestamp/summary/results).
#   (e) FAIL-SOFT: an ABSENT proof map is a soft note, every capability reads as a gap, exit 0.
#
# All wiring goes through the env seams cmd_conformance exposes: HERD_CAPABILITIES_FILE (the manifest),
# HERD_CONFORMANCE_FILE (the proof map), HERD_CONFORMANCE_ROOT (proof_ref base), HERD_CONFORMANCE_OUT
# (run output). Run:  bash tests/test-conformance.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
HERD="$HERE/../bin/herd"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass=0; okp(){ pass=$((pass+1)); }

# JSON field probe: python3 is a documented hard dep (herd doctor gates it) and the engine already
# leans on it; here it just reads a field out of the emitted JSON for assertions.
jq_field(){ python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."):
    d = d[int(k)] if k.lstrip("-").isdigit() else d[k]
print(d)' "$1" "$2"; }

ROOT="$T/root"; mkdir -p "$ROOT/tests"
printf '#!/usr/bin/env bash\nexit 0\n' > "$ROOT/tests/good.sh"
printf '#!/usr/bin/env bash\nexit 1\n' > "$ROOT/tests/bad.sh"

# ── Scratch matrix: one capability per verdict class ────────────────────────────────────────────────
CAPS="$T/caps.tsv"
printf 'name\tkind\tdescription\n'          >  "$CAPS"
printf 'CAP_GREEN\tconfig\tmapped-green\n'  >> "$CAPS"
printf 'CAP_ROT\tconfig\tmapped-missing\n'  >> "$CAPS"
printf 'CAP_GAP\tconfig\tunmapped\n'        >> "$CAPS"

MAP="$T/map.tsv"
printf 'capability\tproof_kind\tproof_ref\n' >  "$MAP"
printf 'CAP_GREEN\tunit\ttests/good.sh\n'    >> "$MAP"
printf 'CAP_ROT\tunit\ttests/gone.sh\n'      >> "$MAP"      # ref intentionally does NOT exist

export HERD_CAPABILITIES_FILE="$CAPS" HERD_CONFORMANCE_FILE="$MAP" HERD_CONFORMANCE_ROOT="$ROOT"

# ── (a)+(b)+(c) report --json shape + the three verdict classes ─────────────────────────────────────
J="$T/report.json"
"$HERD" conformance report --json > "$J"; rc=$?
[ "$rc" -eq 1 ] || fail "report --json should exit 1 when rot present (got $rc)"; okp

[ "$(jq_field "$J" total)" = "3" ]                     || fail "total != 3"; okp
[ "$(jq_field "$J" counts.mapped)" = "1" ]             || fail "counts.mapped != 1"; okp
[ "$(jq_field "$J" counts.gap)" = "1" ]                || fail "counts.gap != 1"; okp
[ "$(jq_field "$J" counts.rot)" = "1" ]                || fail "counts.rot != 1"; okp
[ "$(jq_field "$J" counts.dangling_refs)" = "1" ]      || fail "counts.dangling_refs != 1"; okp

# per-capability status is emitted in manifest order: GREEN, ROT, GAP
[ "$(jq_field "$J" capabilities.0.status)" = "mapped" ] || fail "CAP_GREEN not mapped"; okp
[ "$(jq_field "$J" capabilities.1.status)" = "rot" ]    || fail "CAP_ROT not rot"; okp
[ "$(jq_field "$J" capabilities.2.status)" = "gap" ]    || fail "CAP_GAP not gap"; okp

# proof objects carry kind/ref/exists
[ "$(jq_field "$J" capabilities.0.proofs.0.exists)" = "True" ]  || fail "green proof exists!=True"; okp
[ "$(jq_field "$J" capabilities.1.proofs.0.exists)" = "False" ] || fail "rot proof exists!=False"; okp
[ "$(jq_field "$J" capabilities.0.proofs.0.ref)" = "tests/good.sh" ] || fail "green proof ref wrong"; okp

# gaps[] and rot[] lists
[ "$(jq_field "$J" gaps.0)" = "CAP_GAP" ]              || fail "gaps[0] != CAP_GAP"; okp
[ "$(jq_field "$J" rot.0.capability)" = "CAP_ROT" ]    || fail "rot[0].capability != CAP_ROT"; okp
[ "$(jq_field "$J" rot.0.ref)" = "tests/gone.sh" ]     || fail "rot[0].ref != tests/gone.sh"; okp

# ── (c) human report mentions each class + rot drives the exit code ─────────────────────────────────
H="$("$HERD" conformance report)"; rc=$?
[ "$rc" -eq 1 ] || fail "human report should exit 1 on rot (got $rc)"; okp
printf '%s' "$H" | grep -q "1 mapped · 1 gap · 1 rot" || fail "human summary line wrong: $H"; okp
printf '%s' "$H" | grep -q "CAP_ROT" || fail "human report omits ROT capability"; okp
printf '%s' "$H" | grep -q "CAP_GAP" || fail "human report omits GAP capability"; okp

# ── (c) a clean map (no rot) exits 0 even with gaps present ──────────────────────────────────────────
CLEAN="$T/clean.tsv"
printf 'capability\tproof_kind\tproof_ref\n' >  "$CLEAN"
printf 'CAP_GREEN\tunit\ttests/good.sh\n'    >> "$CLEAN"    # CAP_ROT/CAP_GAP now unmapped → gaps only
HERD_CONFORMANCE_FILE="$CLEAN" "$HERD" conformance report >/dev/null; rc=$?
[ "$rc" -eq 0 ] || fail "report should exit 0 when only gaps (got $rc)"; okp

# ── (e) FAIL-SOFT: absent proof map → soft note, all gaps, exit 0 ───────────────────────────────────
HF="$(HERD_CONFORMANCE_FILE="$T/nope.tsv" "$HERD" conformance report)"; rc=$?
[ "$rc" -eq 0 ] || fail "absent map should exit 0 (got $rc)"; okp
printf '%s' "$HF" | grep -q "no proof map found" || fail "absent map missing soft note"; okp
printf '%s' "$HF" | grep -q "3 capabilities · 0 mapped · 3 gap" || fail "absent map should read all-gap: $HF"; okp

# ── (d) run verdicts + conformance.json shape + --kind filter ───────────────────────────────────────
RCAPS="$T/rcaps.tsv"
printf 'name\tkind\tdescription\n'                  >  "$RCAPS"
printf 'CAP_A\tconfig\ta\nCAP_B\tconfig\tb\nCAP_S\tconfig\ts\nCAP_M\tconfig\tm\n' >> "$RCAPS"
RMAP="$T/rmap.tsv"
printf 'capability\tproof_kind\tproof_ref\n' >  "$RMAP"
printf 'CAP_A\tunit\ttests/good.sh\n'        >> "$RMAP"
printf 'CAP_B\tunit\ttests/bad.sh\n'         >> "$RMAP"
printf 'CAP_S\tsim\ttests/good.sh\n'         >> "$RMAP"    # non-unit kind → no runner → skipped
printf 'CAP_M\tunit\ttests/missing.sh\n'     >> "$RMAP"    # ref gone → missing
OUT="$T/run.json"
HERD_CAPABILITIES_FILE="$RCAPS" HERD_CONFORMANCE_FILE="$RMAP" \
  "$HERD" conformance run --kind unit --out "$OUT" >/dev/null; rc=$?
[ "$rc" -eq 1 ] || fail "run should exit 1 when a proof fails (got $rc)"; okp
[ -n "$(jq_field "$OUT" sha)" ]                     || fail "run json missing sha"; okp
[ -n "$(jq_field "$OUT" timestamp)" ]               || fail "run json missing timestamp"; okp
[ "$(jq_field "$OUT" kind_filter)" = "unit" ]       || fail "run kind_filter != unit"; okp
[ "$(jq_field "$OUT" summary.pass)" = "1" ]         || fail "run pass != 1"; okp
[ "$(jq_field "$OUT" summary.fail)" = "1" ]         || fail "run fail != 1"; okp
[ "$(jq_field "$OUT" summary.skipped)" = "1" ]      || fail "run skipped != 1 (sim not skipped?)"; okp
[ "$(jq_field "$OUT" summary.missing)" = "1" ]      || fail "run missing != 1"; okp

# all-pass run exits 0
OUT2="$T/run2.json"
PMAP="$T/pmap.tsv"
printf 'capability\tproof_kind\tproof_ref\n' >  "$PMAP"
printf 'CAP_A\tunit\ttests/good.sh\n'        >> "$PMAP"
HERD_CAPABILITIES_FILE="$RCAPS" HERD_CONFORMANCE_FILE="$PMAP" \
  "$HERD" conformance run --out "$OUT2" >/dev/null; rc=$?
[ "$rc" -eq 0 ] || fail "all-pass run should exit 0 (got $rc)"; okp

echo "ALL PASS — $pass conformance assertions"
