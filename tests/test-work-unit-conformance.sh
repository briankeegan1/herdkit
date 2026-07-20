#!/usr/bin/env bash
# test-work-unit-conformance.sh — the CONFORMANCE TIE between the bash wunit_* reference model
# (scripts/herd/work-unit.sh) and the python adapter interface (pysrc/herd/work_unit.py), promised by
# the P3c amendment (docs/spikes/work-unit-abstraction.md §9.3) and landed by P5 (HERD-404).
#
# §9.3 already points two SEPARATE conformance.tsv rows (WORK_UNIT_KIND -> tests/test-work-unit-kind.sh
# and -> tests/test_live_runtime.py) at "the identical resolution contract" — but nothing before this
# file actually cross-checked the two implementations against EACH OTHER; they could drift onto
# different definitions of "git-pr" or "supported kind" and neither file's own suite would notice. This
# test reads both sides' live values (never re-hardcodes an assumed answer on one side) and asserts they
# agree, for git-pr specifically:
#
#   (A) KIND IDENTITY + DEFAULT — bash's wunit_resolve_adapter (no-arg default) and python's
#       herd.work_unit.DEFAULT_KIND resolve to the SAME literal, and it is "git-pr".
#   (B) HARD-REFUSAL PARITY — an unsupported kind is refused by BOTH sides (bash: nonzero rc + empty
#       stdout; python: UnsupportedWorkUnitKind), never a silent fallback on either.
#   (C) GATE-STATUS VOCABULARY CONTAINMENT — the exact status words bash's wunit_gate ever prints
#       ("pass"/"wait", read live from its own source, not assumed) are each members of the spike §2.2
#       canonical vocabulary (pass|hold|block|wait|error) AND each appears among the status words
#       python's GitPrAdapter.gate actually emits (read live via grep, not assumed) — so bash's
#       simpler 2-state boolean-derived gate can never drift onto a status word python's fuller
#       state machine does not also recognize as the same real-world state.
#
# Fully hermetic: stubs gh/git; no network; no live watcher loop. Run:
#   bash tests/test-work-unit-conformance.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WUNIT="$ROOT/scripts/herd/work-unit.sh"
PYMOD="$ROOT/pysrc/herd/work_unit.py"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); echo "  ok: $1"; }

[ -f "$WUNIT" ] || fail "missing $WUNIT"
[ -f "$PYMOD" ] || fail "missing $PYMOD"
command -v python3 >/dev/null 2>&1 || fail "python3 required"

# ══════════════════════════════════════════════════════════════════════════════
# (A) + (B) KIND IDENTITY/DEFAULT + HARD-REFUSAL PARITY
# ══════════════════════════════════════════════════════════════════════════════
BOGUS="conformance-bogus-kind"

bash_default="$(
  set -uo pipefail
  do_merge() { :; }; reconcile_backlog() { :; }; _reap_slug() { :; }; _cand_gates_ready() { :; }
  export -f do_merge reconcile_backlog _reap_slug _cand_gates_ready
  unset WORK_UNIT_KIND 2>/dev/null || true
  # shellcheck source=/dev/null
  . "$WUNIT" >/dev/null 2>&1
  wunit_resolve_adapter 2>/dev/null
)" || fail "(A) bash wunit_resolve_adapter (no-arg default) errored"
[ -n "$bash_default" ] || fail "(A) bash wunit_resolve_adapter printed nothing for the default kind"

py_default="$(PYTHONPATH="$ROOT/pysrc" python3 -c 'from herd.work_unit import DEFAULT_KIND; print(DEFAULT_KIND)')" \
  || fail "(A) python DEFAULT_KIND import failed"

[ "$bash_default" = "$py_default" ] \
  || fail "(A) bash default kind '$bash_default' != python DEFAULT_KIND '$py_default' — the two sides drifted"
[ "$bash_default" = "git-pr" ] \
  || fail "(A) shared default kind is '$bash_default', expected git-pr"
ok "(A) bash wunit_resolve_adapter and python DEFAULT_KIND agree on the default kind ('$bash_default')"

bash_bogus_out="$(
  set -uo pipefail
  do_merge() { :; }; reconcile_backlog() { :; }; _reap_slug() { :; }; _cand_gates_ready() { :; }
  export -f do_merge reconcile_backlog _reap_slug _cand_gates_ready
  # shellcheck source=/dev/null
  . "$WUNIT" >/dev/null 2>&1
  wunit_resolve_adapter "$BOGUS" 2>/dev/null
)"
bash_bogus_rc=0
(
  set -uo pipefail
  do_merge() { :; }; reconcile_backlog() { :; }; _reap_slug() { :; }; _cand_gates_ready() { :; }
  export -f do_merge reconcile_backlog _reap_slug _cand_gates_ready
  # shellcheck source=/dev/null
  . "$WUNIT" >/dev/null 2>&1
  wunit_resolve_adapter "$BOGUS" >/dev/null 2>&1
) || bash_bogus_rc=$?
[ "$bash_bogus_rc" -ne 0 ] || fail "(B) bash wunit_resolve_adapter must hard-refuse an unsupported kind (rc=0)"
[ -z "$bash_bogus_out" ] || fail "(B) bash wunit_resolve_adapter must print NOTHING on stdout for an unsupported kind, got '$bash_bogus_out'"

py_refused="$(PYTHONPATH="$ROOT/pysrc" python3 -c "
from herd.work_unit import resolve_adapter, UnsupportedWorkUnitKind
try:
    resolve_adapter('$BOGUS')
    print('NO-RAISE-BUG')
except UnsupportedWorkUnitKind:
    print('REFUSED')
")" || fail "(B) python resolve_adapter bogus-kind check errored"
[ "$py_refused" = "REFUSED" ] || fail "(B) python resolve_adapter did not hard-refuse '$BOGUS' (got '$py_refused')"
ok "(B) bash + python both hard-refuse the same unsupported kind ('$BOGUS'), never a silent fallback"

# ══════════════════════════════════════════════════════════════════════════════
# (C) GATE-STATUS VOCABULARY CONTAINMENT
# ══════════════════════════════════════════════════════════════════════════════
SPIKE_VOCAB="pass hold block wait error"

# Read bash's wunit_gate literal outputs LIVE from its own source (never assumed) — the two printf
# arguments inside the wunit_gate function body (sed prints from the `wunit_gate() {` line to its
# closing `}`; portable, no gawk-only 3-arg match()).
bash_gate_words="$(sed -n '/^wunit_gate() {/,/^}/p' "$WUNIT" | grep -oE "printf '[a-z]+" | sed "s/printf '//" | sort -u)"
[ -n "$bash_gate_words" ] || fail "(C) could not extract wunit_gate's printf literals from $WUNIT"

py_gate_words="$(grep -oE 'GateResult\(status="[a-z]+"' "$PYMOD" | grep -oE '"[a-z]+"' | tr -d '"' | sort -u)"
[ -n "$py_gate_words" ] || fail "(C) could not extract GateResult status literals from $PYMOD"

for w in $bash_gate_words; do
  case " $SPIKE_VOCAB " in *" $w "*) : ;; *) fail "(C) bash wunit_gate emits '$w', not in the spike §2.2 canonical vocabulary ($SPIKE_VOCAB)" ;; esac
  found=0
  for pw in $py_gate_words; do [ "$pw" = "$w" ] && found=1 && break; done
  [ "$found" -eq 1 ] || fail "(C) bash wunit_gate can print status '$w', but python's GitPrAdapter.gate never emits that word (python words: $py_gate_words) — the two gates drifted onto different vocabularies"
done
ok "(C) every status word bash's wunit_gate can print ($(echo $bash_gate_words)) is in the spike vocabulary AND recognized by python's GateResult usage"

echo
echo "ALL PASS ($pass checks)"
