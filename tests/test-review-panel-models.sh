#!/usr/bin/env bash
# test-review-panel-models.sh — hermetic proof of the MIXED-VENDOR REVIEW PANEL (HERD-276).
#
# REVIEW_PANEL (HERD-107) fanned out N reviewer passes on ONE model; driver-qualified MODEL refs
# (HERD-151) could name a runtime but nothing consumed them in the review gate. HERD-276 wires them:
# REVIEW_PANEL_MODELS declares one panelist per (optionally '<driver>:<model>') ref, each dispatched
# through ITS OWN runtime, and REVIEW_PANEL_POLICY chooses how their verdicts fold.
#
# Asserts, in order:
#   (1) REF PARSING — the ref list splits on arbitrary whitespace, counts correctly, and is DORMANT
#       (zero refs) when unset/blank. Eager validation accepts a bare model + a shipped '<driver>:<model>'
#       and REFUSES an unknown driver prefix or an empty model after the prefix.
#   (2) POLICY RESOLUTION — any-block is the default AND the fail-strict landing spot for a typo; the
#       three recognized policies pass through verbatim; a typo is reported as such.
#   (3) MERGE-POLICY TRUTH TABLE — the shared resolver (herd_review_merge_verdicts), the ONE fold every
#       enforcement surface shares, over every (policy × verdict-mix) cell, INCLUDING the invariant a
#       merge gate lives or dies by: a NON-REPORTING panelist can move the fold toward INFRA (a retry)
#       but NEVER toward BLOCK, and never turns a BLOCK into a PASS.
#   (4) DISPATCH (end-to-end, real herd-review.sh) — each panelist launches through its OWN driver's
#       runtime binary: a `stub:…` ref runs `stub-agent`, a bare ref runs `claude`, in ONE panel.
#   (5) MISSING DRIVER BINARY = INFRA, NEVER A FALSE BLOCK — a configured vendor whose binary is not
#       installed reports INFRA; under any-block a clean co-panelist still PASSes, under all-pass the
#       coverage gap folds to INFRA-FAIL (exit 2, a retry), and NOTHING anywhere emits a BLOCK.
#   (6) PER-PANELIST PROVENANCE — the journal carries one review_panelist_verdict row per panelist with
#       its ref/driver/model/verdict, plus one sha-keyed review_panel_folded row naming the policy.
#   (7) SHIP-DORMANT — with REVIEW_PANEL_MODELS unset the review runs exactly ONE claude reviewer (the
#       pre-HERD-276 single-model path); `stub-agent` is never invoked.
#   (8) WIRING — the seam is sourced, the manifest documents both keys, and the resolver is not
#       re-implemented inline in herd-review.sh.
#
# Fully hermetic: temp dirs + fake runtimes on PATH. NO herdr, NO gh, NO network, NO model.
# Run:  bash tests/test-review-panel-models.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SCRIPTS="$ROOT/scripts/herd"
PANEL="$SCRIPTS/review-panel.sh"
DRIVER="$SCRIPTS/driver.sh"
REVIEW="$SCRIPTS/herd-review.sh"
CONFIG="$SCRIPTS/herd-config.sh"
CAPS="$ROOT/templates/capabilities.tsv"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASSN=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ PASSN=$((PASSN+1)); }

for f in "$PANEL" "$DRIVER" "$REVIEW" "$CONFIG" "$CAPS"; do
  [ -f "$f" ] || fail "missing required file: $f"
done
command -v python3 >/dev/null 2>&1 || fail "python3 required"

# Pure libraries — source them straight into this shell for the unit sections.
# shellcheck source=/dev/null
. "$DRIVER"
# shellcheck source=/dev/null
. "$PANEL"

################################################################################
# 1 — REF PARSING + eager validation
################################################################################
[ "$(herd_review_panel_ref_count "")" = "0" ]                       || fail "1a: blank ref list must be dormant (0 panelists)"
[ "$(REVIEW_PANEL_MODELS=""; herd_review_panel_ref_count)" = "0" ]  || fail "1b: unset REVIEW_PANEL_MODELS must be dormant"
[ "$(herd_review_panel_ref_count "opus")" = "1" ]                   || fail "1c: one bare ref = 1 panelist"
[ "$(herd_review_panel_ref_count "opus  stub:m1   grok:grok-4")" = "3" ] \
  || fail "1d: refs must split on arbitrary whitespace (want 3)"
# Order is preserved and a colon INSIDE the model id survives (ollama:llama3:8b → driver ollama).
got="$(herd_review_panel_refs "a stub:m1" | tr '\n' ',')"
[ "$got" = "a,stub:m1," ] || fail "1e: ref order/parsing wrong: got '$got'"

herd_review_panel_validate_refs "" 2>/dev/null           || fail "1f: an EMPTY ref list is valid (dormant), not an error"
herd_review_panel_validate_refs "stub:m1" 2>/dev/null    || fail "1g: a shipped '<driver>:<model>' ref must validate"
herd_review_panel_validate_refs "opus stub:m1" 2>/dev/null || fail "1h: a bare ref + a qualified ref must validate"
if herd_review_panel_validate_refs "stub:m1 codx:gpt-5" 2>/dev/null; then
  fail "1i: an UNKNOWN driver prefix must be refused eagerly"
fi
if herd_review_panel_validate_refs "stub:" 2>/dev/null; then
  fail "1j: a '<driver>:' ref with an EMPTY model must be refused eagerly"
fi
ok; echo "PASS (1) ref parsing + eager validation"

################################################################################
# 2 — POLICY RESOLUTION (default, passthrough, fail-strict on a typo)
################################################################################
[ "$(REVIEW_PANEL_POLICY=""; herd_review_panel_policy)" = "any-block" ]         || fail "2a: unset policy must default to any-block"
[ "$(REVIEW_PANEL_POLICY="all-pass"; herd_review_panel_policy)" = "all-pass" ]  || fail "2b: all-pass must pass through"
[ "$(REVIEW_PANEL_POLICY="majority"; herd_review_panel_policy)" = "majority" ]  || fail "2c: majority must pass through"
# A typo must land on the SAFEST policy (any-block), never the laxest (majority) — a fat-fingered key
# can never widen the gate. Case-sensitivity is part of the contract.
[ "$(REVIEW_PANEL_POLICY="ANY-BLOCK"; herd_review_panel_policy)" = "any-block" ] || fail "2d: a typo must fail STRICT to any-block"
[ "$(REVIEW_PANEL_POLICY="majorityy"; herd_review_panel_policy)" = "any-block" ] || fail "2e: an unrecognized policy must fail STRICT to any-block, not to majority"
( REVIEW_PANEL_POLICY="majorityy"; herd_review_panel_policy_is_typo )  || fail "2f: a typo must be reportable as a typo"
( REVIEW_PANEL_POLICY="majority";  herd_review_panel_policy_is_typo )  && fail "2g: a valid policy is not a typo"
( REVIEW_PANEL_POLICY="";          herd_review_panel_policy_is_typo )  && fail "2h: an unset policy is not a typo"
ok; echo "PASS (2) policy resolution (fail-strict to any-block)"

################################################################################
# 3 — MERGE-POLICY TRUTH TABLE (the shared resolver)
################################################################################
# _mk <name> <kind> — write a panelist verdict file. kind: pass | block | infra (no verdict line) |
# empty (a file the runtime never wrote to). BLOCK carries the structured HERD-104 shape.
_mk(){
  local f="$T/tt/$1"
  mkdir -p "$T/tt"
  case "$2" in
    pass)  printf 'REVIEW: PASS\n' > "$f" ;;
    block) printf 'REVIEW: BLOCK — rule: off-by-one | why: overshoots | location: f.sh:1\n' > "$f" ;;
    infra) printf 'REVIEW: INFRA-FAIL — driver binary not installed\n' > "$f" ;;
    empty) : > "$f" ;;
  esac
  printf '%s' "$f"
}
# _fold <policy> <kind>… — build one file per kind (in order) and fold; echo "<rc>|<line>".
_fold(){
  local policy="$1"; shift
  rm -rf "$T/tt"; mkdir -p "$T/tt"
  local i=0 files=() k
  for k in "$@"; do files+=("$(_mk "$(printf 'm.%03d' "$i")" "$k")"); i=$((i+1)); done
  local line rc=0
  # bash 3.2 + `set -u`: an EMPTY array expansion is an unbound-variable error, so guard it. The
  # zero-panelist fold is a real case (a panel that dispatched nobody must be INFRA, not a pass).
  line="$(herd_review_merge_verdicts "$policy" ${files[@]+"${files[@]}"})" || rc=$?
  printf '%s|%s' "$rc" "$line"
}
# _want <label> <policy> <expect-rc> <expect-grep|-> <kind>…
_want(){
  local label="$1" policy="$2" erc="$3" egrep="$4"; shift 4
  local r; r="$(_fold "$policy" "$@")"
  local rc="${r%%|*}" line="${r#*|}"
  [ "$rc" = "$erc" ] || fail "3 $label: rc=$rc want $erc (line: '$line')"
  if [ "$egrep" = "-" ]; then
    [ -z "$line" ] || fail "3 $label: expected NO verdict line, got '$line'"
  else
    printf '%s' "$line" | grep -q "$egrep" || fail "3 $label: line '$line' does not match '$egrep'"
  fi
}
# rc contract: 0 = PASS, 1 = BLOCK, 2 = INFRA (no line).

# ── any-block: any BLOCK blocks; else any PASS passes; else INFRA. (Today's fold, byte-identical.)
_want "any-block/all-pass"      any-block 0 '^REVIEW: PASS$'  pass pass pass
_want "any-block/one-block"     any-block 1 '^REVIEW: BLOCK'  pass block pass
_want "any-block/all-block"     any-block 1 '^REVIEW: BLOCK'  block block
_want "any-block/pass+infra"    any-block 0 '^REVIEW: PASS$'  pass infra empty
_want "any-block/all-infra"     any-block 2 '-'               infra empty
_want "any-block/none"          any-block 2 '-'
# A lone BLOCK among a crowd of silent panelists still blocks — silence never dilutes a real finding.
_want "any-block/block+infra"   any-block 1 '^REVIEW: BLOCK'  infra block empty

# ── all-pass: EVERY dispatched panelist must PASS; a silent panelist is a coverage gap → INFRA.
_want "all-pass/all-pass"       all-pass  0 '^REVIEW: PASS$'  pass pass pass
_want "all-pass/one-block"      all-pass  1 '^REVIEW: BLOCK'  pass block
_want "all-pass/pass+infra"     all-pass  2 '-'               pass infra
_want "all-pass/pass+empty"     all-pass  2 '-'               pass empty
_want "all-pass/all-infra"      all-pass  2 '-'               infra infra
# A BLOCK still dominates a coverage gap: the finding is real, report it rather than a retry.
_want "all-pass/block+infra"    all-pass  1 '^REVIEW: BLOCK'  block infra

# ── majority: blocks >= passes → BLOCK (ties fail safe); a lone dissenter no longer blocks.
_want "majority/2pass-1block"   majority  0 '^REVIEW: PASS$'  pass pass block
_want "majority/1pass-1block"   majority  1 '^REVIEW: BLOCK'  pass block
_want "majority/1pass-2block"   majority  1 '^REVIEW: BLOCK'  pass block block
_want "majority/all-pass"       majority  0 '^REVIEW: PASS$'  pass pass
_want "majority/all-infra"      majority  2 '-'               infra empty
# Non-reporting panelists are NOT votes: 2 PASS + 1 silent is a majority PASS, not a tie.
_want "majority/2pass-1infra"   majority  0 '^REVIEW: PASS$'  pass pass infra
# ...and 1 PASS + 1 BLOCK + 1 silent still ties → BLOCK. Silence cannot rescue a merge.
_want "majority/1p-1b-1infra"   majority  1 '^REVIEW: BLOCK'  pass block infra

# ── The load-bearing invariant, stated directly: a non-reporting panelist NEVER creates a BLOCK.
for pol in any-block all-pass majority; do
  r="$(_fold "$pol" pass infra empty)"
  case "${r#*|}" in
    *BLOCK*) fail "3 invariant: policy $pol turned silent panelists into a BLOCK ('${r#*|}')" ;;
  esac
done
# A PASS-carrying advisory tail (HERD-105) survives the fold verbatim under every policy.
rm -rf "$T/tt"; mkdir -p "$T/tt"
printf 'REVIEW: PASS — advisory: naming | advisory: tests\n' > "$T/tt/m.000"
line="$(herd_review_merge_verdicts any-block "$T/tt/m.000")"
[ "$line" = "REVIEW: PASS — advisory: naming | advisory: tests" ] \
  || fail "3 advisory: PASS advisory tail was mangled by the fold: '$line'"
# An INFRA fold always leaves a human-readable reason for the caller's INFRA-FAIL line.
rm -rf "$T/tt"; mkdir -p "$T/tt"; : > "$T/tt/m.000"
herd_review_merge_verdicts all-pass "$T/tt/m.000" >/dev/null 2>&1
[ -n "$HERD_REVIEW_PANEL_REASON" ] || fail "3 reason: an INFRA fold must set HERD_REVIEW_PANEL_REASON"
ok; echo "PASS (3) merge-policy truth table (25 cells + invariants)"

################################################################################
# 4-7 — END-TO-END through the REAL herd-review.sh
################################################################################
BIN="$T/bin"; mkdir -p "$BIN" "$T/trees"
for cmd in gh git; do printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$cmd"; chmod +x "$BIN/$cmd"; done
cat > "$BIN/herdr" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "agent list") printf '{"result":{"agents":[]}}\n' ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$BIN/herdr"

# _runtime <name> <verdict-text> — a fake agent runtime that logs its invocation (name + the --model it
# was handed) and emits ONE stream-json result line carrying <verdict-text>. This is how we observe
# WHICH vendor binary each panelist actually launched — the whole point of the feature.
_runtime(){
  cat > "$BIN/$1" <<STUB
#!/usr/bin/env bash
m=""; prev=""
for a in "\$@"; do [ "\$prev" = "--model" ] && { m="\$a"; break; }; prev="\$a"; done
printf '%s %s\n' "$1" "\$m" >> "\$PANEL_CALLS"
printf '{"type":"result","subtype":"success","result":"%s"}\n' "$2"
STUB
  chmod +x "$BIN/$1"
}
export PATH="$BIN:$PATH"

# _run <pr> <env-assignments…> — run the REAL herd-review.sh in PR mode; echo "<rc>|<verdict>".
# Every run gets a fresh call log + journal so the assertions below are independent.
_run(){
  local pr="$1"; shift
  export PANEL_CALLS="$T/calls-$pr"; : > "$PANEL_CALLS"
  export JOURNAL_FILE="$T/j-$pr"; : > "$JOURNAL_FILE"
  local out rc
  out="$(env "$@" HERD_NO_PANE=1 PANEL_CALLS="$PANEL_CALLS" \
        HERD_REVIEW_RESULT_FILE="$T/res-$pr" WORKTREES_DIR="$T/trees" \
        HERD_CONFIG_FILE="$T/no-such-config" JOURNAL_FILE="$JOURNAL_FILE" \
        HERD_REVIEW_MODEL="fallback-model" \
        bash "$REVIEW" "$pr" "slug-$pr" 2>/dev/null)"
  rc=$?
  printf '%s|%s' "$rc" "$out"
}
_calls(){ cat "$T/calls-$1" 2>/dev/null; }

# ── 4. MIXED-VENDOR DISPATCH: a bare ref and a stub: ref in ONE panel launch DIFFERENT binaries.
_runtime claude     'REVIEW: PASS'
_runtime stub-agent 'REVIEW: PASS'
r="$(_run 301 REVIEW_PANEL_MODELS="bare-model stub:stub-model")"
[ "${r%%|*}" = "0" ] || fail "4a: mixed-vendor all-PASS panel should exit 0 (got ${r%%|*}, out '${r#*|}')"
printf '%s' "${r#*|}" | grep -qx 'REVIEW: PASS' || fail "4a: combined verdict should be 'REVIEW: PASS'"
[ "$(_calls 301 | grep -c .)" = "2" ]        || fail "4b: two refs must dispatch exactly 2 panelists, got: $(_calls 301 | tr '\n' ';')"
_calls 301 | grep -qx 'claude bare-model'    || fail "4c: the BARE ref must launch 'claude' with the bare model, got: $(_calls 301 | tr '\n' ';')"
_calls 301 | grep -qx 'stub-agent stub-model' || fail "4d: the 'stub:' ref must launch 'stub-agent' with the DRIVER-STRIPPED model, got: $(_calls 301 | tr '\n' ';')"
# The panel size comes from the REF COUNT — REVIEW_PANEL is not consulted once refs are set.
r="$(_run 302 REVIEW_PANEL_MODELS="stub:a stub:b stub:c" REVIEW_PANEL="1")"
[ "$(_calls 302 | grep -c .)" = "3" ] || fail "4e: panel size must be the ref count (3), not REVIEW_PANEL=1"
# ...and it engages at a SINGLE ref: that panelist must run its own ref, not $REVIEW_MODEL.
r="$(_run 303 REVIEW_PANEL_MODELS="stub:solo")"
[ "$(_calls 303 | grep -c .)" = "1" ]         || fail "4f: a one-ref panel should dispatch exactly 1 panelist"
_calls 303 | grep -qx 'stub-agent solo'       || fail "4g: a one-ref panel must launch THAT ref, not HERD_REVIEW_MODEL"
# ...without native-burst: the mixed panel still runs every panelist (serially), it just isn't concurrent.
r="$(_run 304 REVIEW_PANEL_MODELS="stub:a stub:b")"
[ "${r%%|*}" = "0" ]                  || fail "4h: a mixed panel must run with NATIVE_BURST off"
[ "$(_calls 304 | grep -c .)" = "2" ] || fail "4i: burst-off must still dispatch every panelist (serially)"
# ...and WITH native-burst on, concurrency is bounded but every panelist still votes.
r="$(_run 305 REVIEW_PANEL_MODELS="stub:a stub:b stub:c" NATIVE_BURST=on REVIEW_CONCURRENCY=2)"
[ "${r%%|*}" = "0" ]                  || fail "4j: bounded-concurrent mixed panel should exit 0"
[ "$(_calls 305 | grep -c .)" = "3" ] || fail "4k: every panelist must run under a concurrency bound"
ok; echo "PASS (4) mixed-vendor dispatch — each panelist launches its own runtime"

# ── 5. MISSING DRIVER BINARY = INFRA, never a false BLOCK.
rm -f "$BIN/stub-agent"                      # the configured vendor is NOT installed
r="$(_run 310 REVIEW_PANEL_MODELS="stub:gone")"
[ "${r%%|*}" = "2" ] || fail "5a: a panel whose only vendor binary is missing must be INFRA-FAIL (exit 2), got ${r%%|*}"
printf '%s' "${r#*|}" | grep -q '^REVIEW: INFRA-FAIL' || fail "5b: missing binary must emit INFRA-FAIL, got '${r#*|}'"
printf '%s' "${r#*|}" | grep -q 'BLOCK' && fail "5c: a missing driver binary must NEVER surface as a BLOCK"
[ "$(_calls 310 | grep -c .)" = "0" ] || fail "5d: a missing binary must be probed BEFORE dispatch (nothing should run)"
# any-block: a clean co-panelist still carries the merge — an absent vendor is not a veto.
r="$(_run 311 REVIEW_PANEL_MODELS="bare-model stub:gone" REVIEW_PANEL_POLICY=any-block)"
[ "${r%%|*}" = "0" ]                            || fail "5e: any-block + one clean panelist must PASS despite an absent vendor"
printf '%s' "${r#*|}" | grep -qx 'REVIEW: PASS' || fail "5f: any-block combined verdict should be PASS"
# all-pass: the same absent vendor is a COVERAGE GAP → INFRA-FAIL (a bounded retry), still never a BLOCK.
r="$(_run 312 REVIEW_PANEL_MODELS="bare-model stub:gone" REVIEW_PANEL_POLICY=all-pass)"
[ "${r%%|*}" = "2" ]                                 || fail "5g: all-pass + an absent vendor must be INFRA-FAIL (exit 2), got ${r%%|*}"
printf '%s' "${r#*|}" | grep -q '^REVIEW: INFRA-FAIL' || fail "5h: all-pass coverage gap must emit INFRA-FAIL"
printf '%s' "${r#*|}" | grep -q 'BLOCK' && fail "5i: an all-pass coverage gap must NEVER surface as a BLOCK"
# An UNRESOLVABLE ref (unknown driver) at dispatch behaves the same way: INFRA, never BLOCK.
r="$(_run 313 REVIEW_PANEL_MODELS="codx:gpt-5")"
[ "${r%%|*}" = "2" ]                                  || fail "5j: an unresolvable ref must fold to INFRA-FAIL"
printf '%s' "${r#*|}" | grep -q 'BLOCK' && fail "5k: an unresolvable ref must never surface as a BLOCK"
# A real BLOCK from a reachable vendor still blocks, even beside an absent one (findings dominate gaps).
_runtime stub-agent 'REVIEW: BLOCK — rule: off-by-one | why: overshoots | location: f.sh:1'
r="$(_run 314 REVIEW_PANEL_MODELS="stub:here grok:absent" REVIEW_PANEL_POLICY=all-pass)"
[ "${r%%|*}" = "1" ]                             || fail "5l: a genuine BLOCK must dominate an absent co-panelist (exit 1)"
printf '%s' "${r#*|}" | grep -q '^REVIEW: BLOCK' || fail "5m: the structured BLOCK line must survive the fold"
ok; echo "PASS (5) missing driver binary = INFRA, never a false BLOCK"

# ── 6. PER-PANELIST PROVENANCE in the journal.
_runtime stub-agent 'REVIEW: PASS'
r="$(_run 320 REVIEW_PANEL_MODELS="bare-model stub:stub-model" REVIEW_PANEL_POLICY=majority)"
J="$T/j-320"
[ -s "$J" ] || fail "6a: no journal was written"
[ "$(grep -c 'review_panelist_verdict' "$J")" = "2" ] || fail "6b: expected one review_panelist_verdict row per panelist"
grep -q '"ref": *"stub:stub-model"' "$J" || grep -q '"ref":"stub:stub-model"' "$J" \
  || fail "6c: journal must carry each panelist's REF: $(cat "$J")"
grep -q 'stub' "$J"          || fail "6d: journal must carry the resolved DRIVER per panelist"
grep -q 'review_panel_folded' "$J" || fail "6e: the fold itself must be journaled (policy + panelists)"
grep -q 'majority' "$J"      || fail "6f: the folded row must name the effective policy"
ok; echo "PASS (6) per-panelist verdict provenance + sha-keyed fold row"

# ── 7. SHIP-DORMANT: unset REVIEW_PANEL_MODELS ⇒ a single claude reviewer, stub-agent never touched.
r="$(_run 330 HERD_X=1)"                       # no REVIEW_PANEL_MODELS, no NATIVE_BURST
[ "${r%%|*}" = "0" ]                            || fail "7a: the dormant default review should exit 0"
printf '%s' "${r#*|}" | grep -qx 'REVIEW: PASS' || fail "7b: the dormant default review should PASS"
[ "$(_calls 330 | grep -c .)" = "1" ]           || fail "7c: dormant must run a SINGLE reviewer, got $(_calls 330 | grep -c .)"
_calls 330 | grep -qx 'claude fallback-model'   || fail "7d: dormant must run claude on HERD_REVIEW_MODEL, got: $(_calls 330 | tr '\n' ';')"
_calls 330 | grep -q 'stub-agent'  && fail "7e: dormant must NEVER launch a non-default runtime"
grep -q 'review_panelist_verdict' "$T/j-330" 2>/dev/null \
  && fail "7f: dormant must emit no panelist-provenance rows (byte-identical journal)"
grep -q 'review_panel_folded' "$T/j-330" 2>/dev/null \
  && fail "7f': dormant must emit no panel-fold row"
# The classic native-burst panel (no refs, REVIEW_PANEL>1) is untouched: still N× the single model.
r="$(_run 331 NATIVE_BURST=on REVIEW_PANEL=3 REVIEW_CONCURRENCY=3)"
[ "${r%%|*}" = "0" ]                  || fail "7g: the classic single-model panel must still exit 0"
[ "$(_calls 331 | grep -c .)" = "3" ] || fail "7h: the classic panel must still run 3 passes"
[ "$(_calls 331 | grep -cx 'claude fallback-model')" = "3" ] \
  || fail "7i: the classic panel must run all 3 passes on REVIEW_MODEL via claude"
ok; echo "PASS (7) ship-dormant — unset keys keep the single-model path"

################################################################################
# 8 — WIRING: sourced seam, no inline re-implementation, manifest rows present.
################################################################################
grep -q 'review-panel.sh' "$REVIEW"            || fail "8a: herd-review.sh must source review-panel.sh"
grep -q 'herd_review_merge_verdicts' "$REVIEW" || fail "8b: herd-review.sh must fold through the SHARED resolver"
grep -q 'herd_driver_oneshot_exec_as' "$REVIEW" || fail "8c: herd-review.sh must dispatch panelists through the driver seam"
grep -q 'review-panel.sh' "$ROOT/bin/herd"     || fail "8d: bin/herd must source review-panel.sh for eager ref validation"
grep -q 'herd_review_panel_validate_refs' "$ROOT/bin/herd" || fail "8e: 'herd config set' must validate refs eagerly"
grep -qE '^: "\$\{REVIEW_PANEL_MODELS:=""\}"' "$CONFIG"        || fail "8f: herd-config.sh must default REVIEW_PANEL_MODELS to empty (dormant)"
grep -qE '^: "\$\{REVIEW_PANEL_POLICY:="any-block"\}"' "$CONFIG" || fail "8g: herd-config.sh must default REVIEW_PANEL_POLICY to any-block"
# The one-shot incantation must still live ONLY in the driver seam: the panel dispatches through
# herd_driver_oneshot_exec_as, never a raw `claude -p "$…"` (the same rail test-oneshot-exec-seam.sh
# holds the drainer sites to). The bare-word `claude` fallback when a driver binds no runtime is the
# documented degrade-to-today's-behavior, and lives beside the identical fallback in driver.sh.
grep -q 'claude -p "\$' "$REVIEW" && fail "8h: herd-review.sh must not call a raw 'claude -p' (route it through the driver seam)"
# The panel must never fold verdicts with its own inline grep — one resolver, or the two enforcement
# surfaces drift (the merge-policy.sh lesson). _combine_verdicts is a thin adapter, nothing more.
[ "$(grep -c 'REVIEW: (PASS|BLOCK)' "$PANEL")" -ge 1 ] \
  || fail "8h': the verdict-line parser must live in review-panel.sh"
# Portable tab-delimited manifest check (BSD grep has no -P; \t is not a tab in BRE/ERE).
awk -F'\t' '$1=="REVIEW_PANEL_MODELS" && $2=="config"{f=1} END{exit f?0:1}' "$CAPS" \
  || fail "8i: capabilities.tsv must document REVIEW_PANEL_MODELS"
awk -F'\t' '$1=="REVIEW_PANEL_POLICY" && $2=="config" && $8=="any-block|all-pass|majority"{f=1} END{exit f?0:1}' "$CAPS" \
  || fail "8j: capabilities.tsv must document REVIEW_PANEL_POLICY with its enum value_shape"
awk -F'\t' '$1=="review-panel.sh" && $2=="lane"{f=1} END{exit f?0:1}' "$CAPS" \
  || fail "8k: capabilities.tsv must document the review-panel.sh library"
ok; echo "PASS (8) wiring + manifest"

echo "ALL PASS ($PASSN sections) — test-review-panel-models.sh"
