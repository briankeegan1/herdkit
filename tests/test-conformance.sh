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
#   (f) GATE/AUTOFIX RATCHET (HERD-424, audit P3.2) — NO flag, on by construction whenever
#       templates/capability-class.tsv exists: a capability EXPLICITLY classified gate|autofix must
#       carry a real, EXISTING proof_kind=sim row or PLAIN `report`/`run` fails loudly (missing vs rot
#       reasons) — in both human text and --json — on top of the existing rot check. An UNCLASSIFIED
#       capability never counts even when it has no proof at all (explicit metadata only, never
#       description-guessed), a synthetic brand-new gate/autofix capability with ZERO proof rows fails
#       by construction, a fixture with NO class file at all is byte-identical to before this ratchet
#       existed, and an absent proof map keeps the ratchet fail-soft (nothing to enforce) exactly like
#       the unqualified command always was.
#
# All wiring goes through the env seams cmd_conformance exposes: HERD_CAPABILITIES_FILE (the manifest),
# HERD_CONFORMANCE_FILE (the proof map), HERD_CAPABILITY_CLASS_FILE (the gate/autofix class map),
# HERD_CONFORMANCE_ROOT (proof_ref base), HERD_CONFORMANCE_OUT (run output). Run:  bash tests/test-conformance.sh
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
# GREEN → mapped, ROT → rot, NONE → none-yet (explicit note), GAP → unmapped (NO row: the ratchet target)
CAPS="$T/caps.tsv"
printf 'name\tkind\tdescription\n'          >  "$CAPS"
printf 'CAP_GREEN\tconfig\tmapped-green\n'  >> "$CAPS"
printf 'CAP_ROT\tconfig\tmapped-missing\n'  >> "$CAPS"
printf 'CAP_NONE\tconfig\tnone-yet\n'       >> "$CAPS"
printf 'CAP_GAP\tconfig\tunmapped\n'        >> "$CAPS"

MAP="$T/map.tsv"
printf 'capability\tproof_kind\tproof_ref\n'                     >  "$MAP"
printf 'CAP_GREEN\tunit\ttests/good.sh\n'                        >> "$MAP"
printf 'CAP_ROT\tunit\ttests/gone.sh\n'                          >> "$MAP"   # ref intentionally does NOT exist
printf 'CAP_NONE\tnone-yet\tunit: no test asserts CAP_NONE yet\n' >> "$MAP"  # a prose note, never rot
# CAP_GAP carries NO row at all → unmapped (the no-new-unmapped RATCHET target)

# HERD_CAPABILITY_CLASS_FILE defaults to a path that never exists — every assertion below that does not
# explicitly opt into a class map (only the STRICT block near the end does) proves --strict is a byte-
# identical no-op absent classification, and never accidentally reads this repo's OWN capability-class.tsv.
export HERD_CAPABILITIES_FILE="$CAPS" HERD_CONFORMANCE_FILE="$MAP" HERD_CONFORMANCE_ROOT="$ROOT" \
       HERD_CAPABILITY_CLASS_FILE="$T/no-class-file-here.tsv"

# ── (a)+(b)+(c) report --json shape + the four verdict classes ──────────────────────────────────────
J="$T/report.json"
"$HERD" conformance report --json > "$J"; rc=$?
[ "$rc" -eq 1 ] || fail "report --json should exit 1 when rot present (got $rc)"; okp

[ "$(jq_field "$J" total)" = "4" ]                     || fail "total != 4"; okp
[ "$(jq_field "$J" counts.mapped)" = "1" ]             || fail "counts.mapped != 1"; okp
[ "$(jq_field "$J" counts.none_yet)" = "1" ]           || fail "counts.none_yet != 1"; okp
[ "$(jq_field "$J" counts.unmapped)" = "1" ]           || fail "counts.unmapped != 1"; okp
[ "$(jq_field "$J" counts.rot)" = "1" ]                || fail "counts.rot != 1"; okp
[ "$(jq_field "$J" counts.dangling_refs)" = "1" ]      || fail "counts.dangling_refs != 1"; okp

# per-capability status is emitted in manifest order: GREEN, ROT, NONE, GAP
[ "$(jq_field "$J" capabilities.0.status)" = "mapped" ]   || fail "CAP_GREEN not mapped"; okp
[ "$(jq_field "$J" capabilities.1.status)" = "rot" ]      || fail "CAP_ROT not rot"; okp
[ "$(jq_field "$J" capabilities.2.status)" = "none-yet" ] || fail "CAP_NONE not none-yet"; okp
[ "$(jq_field "$J" capabilities.3.status)" = "unmapped" ] || fail "CAP_GAP not unmapped"; okp

# a none-yet capability carries its note and NO proof objects (its 3rd column is prose, not a path)
[ "$(jq_field "$J" capabilities.2.note)" = "unit: no test asserts CAP_NONE yet" ] || fail "none-yet note not carried"; okp
[ "$(jq_field "$J" 'capabilities.2.proofs')" = "[]" ] || fail "none-yet capability must carry no proof objects"; okp

# proof objects carry kind/ref/exists
[ "$(jq_field "$J" capabilities.0.proofs.0.exists)" = "True" ]  || fail "green proof exists!=True"; okp
[ "$(jq_field "$J" capabilities.1.proofs.0.exists)" = "False" ] || fail "rot proof exists!=False"; okp
[ "$(jq_field "$J" capabilities.0.proofs.0.ref)" = "tests/good.sh" ] || fail "green proof ref wrong"; okp

# none_yet[] / unmapped[] (the ratchet list) / rot[]
[ "$(jq_field "$J" none_yet.0.capability)" = "CAP_NONE" ] || fail "none_yet[0].capability != CAP_NONE"; okp
[ "$(jq_field "$J" none_yet.0.note)" = "unit: no test asserts CAP_NONE yet" ] || fail "none_yet[0].note wrong"; okp
[ "$(jq_field "$J" unmapped.0)" = "CAP_GAP" ]          || fail "unmapped[0] != CAP_GAP (ratchet target)"; okp
[ "$(jq_field "$J" rot.0.capability)" = "CAP_ROT" ]    || fail "rot[0].capability != CAP_ROT"; okp
[ "$(jq_field "$J" rot.0.ref)" = "tests/gone.sh" ]     || fail "rot[0].ref != tests/gone.sh"; okp

# ── (c) human report mentions each class + rot drives the exit code ─────────────────────────────────
H="$("$HERD" conformance report)"; rc=$?
[ "$rc" -eq 1 ] || fail "human report should exit 1 on rot (got $rc)"; okp
grep -q "1 mapped · 1 none-yet · 1 unmapped · 1 rot" <<< "$H" || fail "human summary line wrong: $H"; okp
grep -q "CAP_ROT" <<< "$H" || fail "human report omits ROT capability"; okp
grep -q "CAP_NONE" <<< "$H" || fail "human report omits NONE-YET capability"; okp
grep -q "unit: no test asserts CAP_NONE yet" <<< "$H" || fail "human report omits the none-yet note"; okp
# the RATCHET advisory fires on an unmapped capability (added since mapping began, no proof row)
grep -q "UNMAPPED" <<< "$H" || fail "ratchet advisory section missing"; okp
grep -q "ADVISORY" <<< "$H" || fail "ratchet advisory must be labeled advisory (never a gate)"; okp
grep -q "CAP_GAP" <<< "$H" || fail "ratchet advisory omits the unmapped capability"; okp

# ── (c) none-yet + unmapped WITHOUT rot exits 0 — the ratchet is advisory only, never a gate ────────
CLEAN="$T/clean.tsv"
printf 'capability\tproof_kind\tproof_ref\n'                     >  "$CLEAN"
printf 'CAP_GREEN\tunit\ttests/good.sh\n'                        >> "$CLEAN"
printf 'CAP_NONE\tnone-yet\tunit: still no proof\n'              >> "$CLEAN"  # CAP_ROT now unmapped, CAP_GAP too
CH="$(HERD_CONFORMANCE_FILE="$CLEAN" "$HERD" conformance report)"; rc=$?
[ "$rc" -eq 0 ] || fail "report should exit 0 when only none-yet+unmapped, no rot (got $rc)"; okp
grep -q "UNMAPPED" <<< "$CH" || fail "advisory should still fire (CAP_ROT/CAP_GAP now unmapped) at exit 0"; okp

# ── (e) FAIL-SOFT: absent proof map → soft note, every capability unmapped, exit 0 ──────────────────
HF="$(HERD_CONFORMANCE_FILE="$T/nope.tsv" "$HERD" conformance report)"; rc=$?
[ "$rc" -eq 0 ] || fail "absent map should exit 0 (got $rc)"; okp
grep -q "no proof map found" <<< "$HF" || fail "absent map missing soft note"; okp
grep -q "4 capabilities · 0 mapped · 0 none-yet · 4 unmapped" <<< "$HF" || fail "absent map should read all-unmapped: $HF"; okp

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

# ── (f) GATE/AUTOFIX RATCHET: explicit classification, missing-sim, rot, none-yet, synthetic new cap ──
# NO --strict flag anywhere below — the audit's own words were "make herd conformance report red on
# gate-class gaps", so this is PLAIN `report` / `run`. Six capabilities, ONE deliberately named/
# described to sound exactly like a gate ("CAP_LOOKS_LIKE_GATE...") yet left OUT of the class file — it
# must never surface as a ratchet violation, proving the mechanism reads ONLY the explicit class map and
# never guesses from capabilities.tsv prose.
SCAPS="$T/scaps.tsv"
printf 'name\tkind\tdescription\n'                                                          >  "$SCAPS"
printf 'CAP_STRICT_OK\tconfig\ta purely cosmetic docs helper, unrelated to gating\n'         >> "$SCAPS"
printf 'CAP_STRICT_NONE\tconfig\tclassified gate, only a none-yet note so far\n'             >> "$SCAPS"
printf 'CAP_STRICT_ROT\tconfig\tclassified autofix, its sim proof_ref rotted\n'              >> "$SCAPS"
printf 'CAP_STRICT_UNITONLY\tconfig\tclassified gate, proven by unit only, no sim\n'         >> "$SCAPS"
printf 'CAP_STRICT_NEW\tconfig\tsynthetic brand-new autofix, zero proof rows at all\n'       >> "$SCAPS"
printf 'CAP_LOOKS_LIKE_GATE_BUT_UNCLASSED\tconfig\tTHE ULTIMATE MERGE GATE (never classified)\n' >> "$SCAPS"
SMAP="$T/smap.tsv"
printf 'capability\tproof_kind\tproof_ref\n'                     >  "$SMAP"
printf 'CAP_STRICT_OK\tsim\ttests/good.sh\n'                     >> "$SMAP"
printf 'CAP_STRICT_NONE\tnone-yet\tunit: no proof yet\n'         >> "$SMAP"
printf 'CAP_STRICT_ROT\tsim\ttests/gone-sim.sh\n'                >> "$SMAP"   # ref intentionally absent
printf 'CAP_STRICT_UNITONLY\tunit\ttests/good.sh\n'              >> "$SMAP"
# CAP_STRICT_NEW and CAP_LOOKS_LIKE_GATE_BUT_UNCLASSED carry NO row at all.
SCLASS="$T/sclass.tsv"
printf 'capability\tclass\tnote\n'          >  "$SCLASS"
printf 'CAP_STRICT_OK\tgate\tok\n'          >> "$SCLASS"
printf 'CAP_STRICT_NONE\tgate\tnone\n'      >> "$SCLASS"
printf 'CAP_STRICT_ROT\tautofix\trot\n'     >> "$SCLASS"
printf 'CAP_STRICT_UNITONLY\tgate\tunit-only\n' >> "$SCLASS"
printf 'CAP_STRICT_NEW\tautofix\tnew\n'     >> "$SCLASS"

# plain report --json: 4 violations (NONE/ROT/UNITONLY/NEW), OK and the unclassed look-alike clean.
SJ="$T/ratchet-report.json"
HERD_CAPABILITIES_FILE="$SCAPS" HERD_CONFORMANCE_FILE="$SMAP" HERD_CAPABILITY_CLASS_FILE="$SCLASS" \
  "$HERD" conformance report --json > "$SJ"; rc=$?
[ "$rc" -eq 1 ] || fail "report should exit 1 on ratchet violations, no flag required (got $rc)"; okp
[ "$(jq_field "$SJ" ratchet.class_present)" = "True" ] || fail "ratchet.class_present != True"; okp
[ "$(jq_field "$SJ" ratchet.map_present)" = "True" ]   || fail "ratchet.map_present != True"; okp
[ "$(jq_field "$SJ" ratchet.count)" = "4" ]            || fail "ratchet.count != 4"; okp
[ "$(jq_field "$SJ" ratchet.violations.0.capability)" = "CAP_STRICT_NONE" ]   || fail "violations[0] != CAP_STRICT_NONE"; okp
[ "$(jq_field "$SJ" ratchet.violations.0.class)" = "gate" ]                   || fail "violations[0].class != gate"; okp
[ "$(jq_field "$SJ" ratchet.violations.0.reason)" = "missing" ]              || fail "violations[0].reason != missing"; okp
[ "$(jq_field "$SJ" ratchet.violations.1.capability)" = "CAP_STRICT_ROT" ]    || fail "violations[1] != CAP_STRICT_ROT"; okp
[ "$(jq_field "$SJ" ratchet.violations.1.class)" = "autofix" ]               || fail "violations[1].class != autofix"; okp
[ "$(jq_field "$SJ" ratchet.violations.1.reason)" = "rot" ]                  || fail "violations[1].reason != rot"; okp
[ "$(jq_field "$SJ" ratchet.violations.2.capability)" = "CAP_STRICT_UNITONLY" ] || fail "violations[2] != CAP_STRICT_UNITONLY"; okp
[ "$(jq_field "$SJ" ratchet.violations.2.reason)" = "missing" ]              || fail "violations[2] (unit-only, no sim) reason != missing"; okp
[ "$(jq_field "$SJ" ratchet.violations.3.capability)" = "CAP_STRICT_NEW" ]   || fail "violations[3] != CAP_STRICT_NEW (synthetic new cap must fail by construction)"; okp
[ "$(jq_field "$SJ" ratchet.violations.3.reason)" = "missing" ]              || fail "violations[3].reason != missing"; okp
python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
vcaps = {v["capability"] for v in d["ratchet"]["violations"]}
assert "CAP_STRICT_OK" not in vcaps, "CAP_STRICT_OK (real sim proof) must not be a ratchet violation"
assert "CAP_LOOKS_LIKE_GATE_BUT_UNCLASSED" not in vcaps, "an unclassified capability must NEVER be a ratchet violation, no matter its description"
' "$SJ" || fail "OK/unclassed leaked into ratchet.violations"; okp

# plain report human text: the GATE/AUTOFIX RATCHET section names each violator with its reason.
SH="$(HERD_CAPABILITIES_FILE="$SCAPS" HERD_CONFORMANCE_FILE="$SMAP" HERD_CAPABILITY_CLASS_FILE="$SCLASS" \
  "$HERD" conformance report)"
grep -q "GATE/AUTOFIX RATCHET" <<< "$SH" || fail "human report missing a GATE/AUTOFIX RATCHET section"; okp
grep -q "CAP_STRICT_NONE \[gate\]" <<< "$SH" || fail "human report omits CAP_STRICT_NONE"; okp
grep -q "CAP_STRICT_ROT \[autofix\]" <<< "$SH" || fail "human report omits CAP_STRICT_ROT"; okp
grep -q "rot" <<< "$SH" || fail "human report omits the rot reason text"; okp
grep -q "CAP_STRICT_NEW \[autofix\]" <<< "$SH" || fail "human report omits the synthetic new capability"; okp

# the ratchet retains the SAME fail-soft doctrine as the base command for a wholly absent proof map.
SJ3="$T/ratchet-nomap.json"
HERD_CAPABILITIES_FILE="$SCAPS" HERD_CONFORMANCE_FILE="$T/no-such-map.tsv" HERD_CAPABILITY_CLASS_FILE="$SCLASS" \
  "$HERD" conformance report --json > "$SJ3"; rc=$?
[ "$rc" -eq 0 ] || fail "report on an absent proof map should still exit 0 (fail-soft, got $rc)"; okp
[ "$(jq_field "$SJ3" ratchet.map_present)" = "False" ] || fail "ratchet.map_present != False on an absent map"; okp
[ "$(jq_field "$SJ3" ratchet.count)" = "0" ]           || fail "ratchet.count should be 0 when the proof map itself is absent"; okp
NOMAP_H="$(HERD_CAPABILITIES_FILE="$SCAPS" HERD_CONFORMANCE_FILE="$T/no-such-map.tsv" HERD_CAPABILITY_CLASS_FILE="$SCLASS" \
  "$HERD" conformance report)"
grep -q "RATCHET: skipped" <<< "$NOMAP_H" || fail "human report should note the ratchet skipped on an absent map"; okp

# a WHOLLY ABSENT class file (the global test default) is byte-identical to before this ratchet existed:
# no ratchet section at all, and the exit code is governed only by the pre-existing rot/gap rules.
SJ4="$T/ratchet-noclassfile.json"
HERD_CAPABILITIES_FILE="$SCAPS" HERD_CONFORMANCE_FILE="$SMAP" \
  "$HERD" conformance report --json > "$SJ4"; rc=$?
[ "$rc" -eq 1 ] || fail "no class file: report should still exit 1 from CAP_STRICT_ROT's plain rot (got $rc)"; okp
[ "$(jq_field "$SJ4" ratchet.class_present)" = "False" ] || fail "ratchet.class_present should be False with no class file"; okp
[ "$(jq_field "$SJ4" ratchet.count)" = "0" ]             || fail "ratchet.count should be 0 with no class file"; okp
NOCLASS_H="$(HERD_CAPABILITIES_FILE="$SCAPS" HERD_CONFORMANCE_FILE="$SMAP" "$HERD" conformance report)"
grep -q "RATCHET" <<< "$NOCLASS_H" && fail "no class file: human report must omit the ratchet section entirely"; okp

# existing non-gate capabilities (the original a/b/c fixture, no classification anywhere) keep their OLD
# advisory behavior verbatim — their rot/gap status still drives the exit code, but NEVER through
# ratchet.violations (they carry no class row at all; the global default class file never exists).
LEGACY_J="$T/legacy-ratchet.json"
"$HERD" conformance report --json > "$LEGACY_J"; rc=$?
[ "$rc" -eq 1 ] || fail "legacy fixture should still exit 1 from its own CAP_ROT (got $rc)"; okp
[ "$(jq_field "$LEGACY_J" ratchet.count)" = "0" ] || fail "legacy fixture has no classified capabilities — ratchet.count must be 0"; okp
[ "$(jq_field "$LEGACY_J" counts.rot)" = "1" ]    || fail "legacy fixture's own rot count regressed"; okp

# ── (f) run: violations land in conformance.json's ratchet key and drive the exit code, no flag needed ─
SOUT="$T/ratchet-run.json"
HERD_CAPABILITIES_FILE="$SCAPS" HERD_CONFORMANCE_FILE="$SMAP" HERD_CAPABILITY_CLASS_FILE="$SCLASS" \
  "$HERD" conformance run --out "$SOUT" >/dev/null; rc=$?
[ "$rc" -eq 1 ] || fail "run should exit 1 on ratchet violations, no flag required (got $rc)"; okp
[ "$(jq_field "$SOUT" ratchet.count)" = "4" ]       || fail "run ratchet.count != 4"; okp
[ "$(jq_field "$SOUT" summary.pass)" = "1" ]        || fail "run summary.pass != 1 (CAP_STRICT_UNITONLY)"; okp
[ "$(jq_field "$SOUT" summary.missing)" = "1" ]     || fail "run summary.missing != 1 (CAP_STRICT_ROT ref gone)"; okp
[ "$(jq_field "$SOUT" summary.fail)" = "0" ]        || fail "run summary.fail should be 0 — the ratchet, not a proof failure, drove this exit"; okp

# an absent class file makes the ratchet a clean no-op even on a fixture with a genuinely rotted ref
# (run's own exit code then depends only on summary.fail, which is 0 here).
SOUT3="$T/noclass-run.json"
HERD_CAPABILITIES_FILE="$SCAPS" HERD_CONFORMANCE_FILE="$SMAP" HERD_CAPABILITY_CLASS_FILE="$T/still-no-class.tsv" \
  "$HERD" conformance run --out "$SOUT3" >/dev/null; rc=$?
[ "$rc" -eq 0 ] || fail "run with no class file should exit 0 (got $rc)"; okp
[ "$(jq_field "$SOUT3" ratchet.count)" = "0" ] || fail "run ratchet.count should be 0 with no class file"; okp

echo "ALL PASS — $pass conformance assertions"
