#!/usr/bin/env bash
# test-lever-reachability-lint.sh — hermetic tests for the shared INERT-LEVER guard (HERD-556):
# scripts/herd/lever-reachability-lint.sh reds a templates/capabilities.tsv config key whose only
# consumers sit inside bash functions the production entrypoints cannot reach — the shape that made
# HEALTH_PANE and HEALTH_TRUST_BUILDER silent no-ops for weeks (their consumers hung off
# `_healthcheck_gate`, defined-but-never-called since the P5b port).
#
# Proves:
#   (1)  The REAL tree is clean (every finding is either fixed or on the exemption baseline), and the
#        exemption file itself is well-formed and non-stale.
#   (2)  MUTATION-PROVE, direct: a fixture lever consumed ONLY inside a never-called function reds,
#        naming the lever AND the dead enclosing function.
#   (3)  MUTATION-PROVE, inverse: moving that one consumer into a called path greens it. Same tree,
#        same key, one line moved — so the red in (2) is about reachability and nothing else.
#   (4)  MUTATION-PROVE, TRANSITIVE: the grounded shape — the consumer sits in a function that DOES
#        have a caller, whose caller is itself dead. A one-hop "is it called" rule reports clean here;
#        this is exactly how HEALTH_PANE hid, so it must red.
#   (5)  An EXEMPTED lever is silent (exit 0, no LEVER-UNREACHABLE line).
#   (6)  A reasonless exemption row reds as EXEMPT-MALFORMED — a row is a decision, not a silencer.
#   (7)  A STALE exemption (the key is reachable again, or gone) reds — the ratchet cannot rot.
#   (8)  SCAN-SURFACE ASYMMETRY (the guards-blind antidote): a sim or a test calling the dead function
#        does NOT make it live. The sandbox sims call `_healthcheck_gate` directly and stayed green
#        through the entire window production stopped calling it.
#   (9)  A python-side consumer keeps the lever green — os.environ has no dead-function class.
#  (10)  herd-config.sh's own `: "${KEY:=default}"` / `export KEY` lines are DECLARATIONS, not
#        consumers. Counting them would green every key on the tree — the toothless failure.
#  (11)  FAIL-SOFT: a tree with no capability manifest → skip (exit 2), never a red.
#
# Network-free: temp dirs + fixtures only. Run:  bash tests/test-lever-reachability-lint.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LINT="$ROOT/scripts/herd/lever-reachability-lint.sh"

[ -f "$LINT" ] || { echo "FAIL: missing lint: $LINT" >&2; exit 1; }
# shellcheck source=/dev/null
. "$LINT"

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not available"; exit 0; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { PASS=$((PASS+1)); }

# ── 1. Real tree is clean ─────────────────────────────────────────────────────────────────────────
real_out="$(herd_lever_reachability_lint "$ROOT")"; real_rc=$?
if [ "$real_rc" -ne 0 ]; then
  printf '%s\n' "$real_out" | grep -E '^(LEVER-UNREACHABLE|EXEMPT-MALFORMED|STALE-EXEMPT)' >&2
  fail "(1) real tree has an inert lever — wire the consumer onto a reachable path, or record it in tests/lever-reachability-exempt.tsv with its reason"
fi
grep -q '^ADVISORY:' <<< "$real_out" || fail "(1) advisory summary line missing"
pass
echo "PASS (1) real tree: every capabilities.tsv config key reaches a live consumer or is on the recorded baseline"

# ── fixture builder ───────────────────────────────────────────────────────────────────────────────
# A minimal engine-shaped tree: the capability manifest, a herd-config.sh that DECLARES the lever, an
# agent-watch.sh holding the functions, and a bin/herd entrypoint whose TOP-LEVEL line is the only
# root. $1 = dir, $2 = the body of the "watcher" file (the part under test).
make_tree() {
  local d="$1" watcher="$2"
  rm -rf "$d"
  mkdir -p "$d/templates" "$d/scripts/herd" "$d/bin" "$d/tests"
  printf 'name\tkind\tdescription\n' > "$d/templates/capabilities.tsv"
  printf 'FIXTURE_LEVER\tconfig\ta fixture lever\n' >> "$d/templates/capabilities.tsv"
  # DECLARATION only — must never count as a consumer (leg 10).
  {
    printf '#!/usr/bin/env bash\n'
    printf ': "${FIXTURE_LEVER:="off"}"   # the fixture lever, off by default\n'
    printf 'export FIXTURE_LEVER\n'
  } > "$d/scripts/herd/herd-config.sh"
  printf '%s' "$watcher" > "$d/scripts/herd/agent-watch.sh"
  # The ONLY entrypoint: a top-level call, so _live_tick roots the reachability closure.
  printf '#!/usr/bin/env bash\n_live_tick "$@"\n' > "$d/bin/herd"
}

# The dead shape: the lever's only reader sits in a function nothing calls.
WATCHER_DEAD='#!/usr/bin/env bash
_never_called() {
  case "${FIXTURE_LEVER:-off}" in on) return 0 ;; *) return 1 ;; esac
}
_live_tick() {
  echo tick
}
'

# The live shape: the SAME reader line, moved into the function the entrypoint calls.
WATCHER_LIVE='#!/usr/bin/env bash
_never_called() {
  return 1
}
_live_tick() {
  case "${FIXTURE_LEVER:-off}" in on) return 0 ;; *) return 1 ;; esac
}
'

# The transitive shape (the grounded HEALTH_PANE chain): the reader HAS a caller, and that caller has
# a caller — but the chain roots in a function the entrypoint never reaches.
WATCHER_TRANSITIVE='#!/usr/bin/env bash
_effective_fixture() {
  case "${FIXTURE_LEVER:-off}" in on) printf on ;; *) printf off ;; esac
}
_spawn_fixture() {
  [ "$(_effective_fixture)" = on ] || return 0
  echo spawned
}
_never_called() {
  _spawn_fixture "$@"
}
_live_tick() {
  echo tick
}
'

# ── 2. Mutation-prove, direct ─────────────────────────────────────────────────────────────────────
TD="$T/dead"; make_tree "$TD" "$WATCHER_DEAD"
out="$(herd_lever_reachability_lint "$TD")"; rc=$?
[ "$rc" -eq 1 ] || fail "(2) a lever consumed only in a never-called function must red (exit 1, got $rc): $out"
grep -q '^LEVER-UNREACHABLE FIXTURE_LEVER ' <<< "$out" \
  || fail "(2) expected a LEVER-UNREACHABLE line naming FIXTURE_LEVER (got: $out)"
grep -q '_never_called' <<< "$out" \
  || fail "(2) the finding must NAME the dead enclosing function (got: $out)"
pass
echo "PASS (2) mutation-prove: a lever whose only consumer sits in a never-called function reds, naming lever + dead function"

# ── 3. Mutation-prove, inverse: move the consumer onto a called path → green ──────────────────────
TL="$T/live"; make_tree "$TL" "$WATCHER_LIVE"
out="$(herd_lever_reachability_lint "$TL")"; rc=$?
[ "$rc" -eq 0 ] || fail "(3) the same lever read from the entrypoint's own function must be clean (exit 0, got $rc): $out"
grep -q '^LEVER-UNREACHABLE' <<< "$out" && fail "(3) no finding expected once the consumer is reachable (got: $out)"
pass
echo "PASS (3) mutation-prove inverse: moving that one consumer into a called path greens it — the red is about reachability, nothing else"

# ── 4. Mutation-prove, transitive: a live-LOOKING chain that roots in a corpse ────────────────────
TT="$T/transitive"; make_tree "$TT" "$WATCHER_TRANSITIVE"
out="$(herd_lever_reachability_lint "$TT")"; rc=$?
[ "$rc" -eq 1 ] || fail "(4) a consumer whose caller-chain roots in a dead function must red (exit 1, got $rc): $out"
grep -q '^LEVER-UNREACHABLE FIXTURE_LEVER ' <<< "$out" \
  || fail "(4) expected FIXTURE_LEVER flagged through the transitive chain (got: $out)"
grep -q '_effective_fixture' <<< "$out" \
  || fail "(4) the finding must name the ENCLOSING reader (_effective_fixture), not just the chain root (got: $out)"
pass
echo "PASS (4) transitive: the grounded HEALTH_PANE shape (reader → caller → corpse) reds; a one-hop rule would not"

# ── 5. An exempted lever is silent ────────────────────────────────────────────────────────────────
printf 'FIXTURE_LEVER\tintentional: bash-only knob kept for downstream projects\n' \
  > "$TD/tests/lever-reachability-exempt.tsv"
out="$(herd_lever_reachability_lint "$TD")"; rc=$?
[ "$rc" -eq 0 ] || fail "(5) an exempted lever must be clean (exit 0, got $rc): $out"
grep -q '^LEVER-UNREACHABLE' <<< "$out" && fail "(5) no finding expected for an exempted lever (got: $out)"
grep -q '1 exempt (1 silencing a finding)' <<< "$out" \
  || fail "(5) the ADVISORY must still COUNT the silenced finding — an exemption is visible debt, not a delete (got: $out)"
pass
echo "PASS (5) exempted lever → silent, but the ADVISORY still counts it as silencing a real finding"

# ── 6. A reasonless exemption row reds ────────────────────────────────────────────────────────────
printf 'FIXTURE_LEVER\n' > "$TD/tests/lever-reachability-exempt.tsv"
out="$(herd_lever_reachability_lint "$TD")"; rc=$?
[ "$rc" -eq 1 ] || fail "(6) a bare exemption row must red (exit 1, got $rc): $out"
grep -q '^EXEMPT-MALFORMED FIXTURE_LEVER' <<< "$out" \
  || fail "(6) expected EXEMPT-MALFORMED for the reasonless row (got: $out)"
pass
echo "PASS (6) a reasonless exemption row reds as EXEMPT-MALFORMED — a row on this list is a decision, not a silencer"

# ── 7. A stale exemption reds ─────────────────────────────────────────────────────────────────────
# Same exemption, but against the tree where the lever is REACHABLE: the row no longer excuses
# anything and must be dropped.
printf 'FIXTURE_LEVER\tintentional: bash-only knob kept for downstream projects\n' \
  > "$TL/tests/lever-reachability-exempt.tsv"
out="$(herd_lever_reachability_lint "$TL")"; rc=$?
[ "$rc" -eq 1 ] || fail "(7) an exemption for a now-reachable lever must red (exit 1, got $rc): $out"
grep -q '^STALE-EXEMPT FIXTURE_LEVER' <<< "$out" \
  || fail "(7) expected STALE-EXEMPT once the lever became reachable (got: $out)"
rm -f "$TL/tests/lever-reachability-exempt.tsv"
pass
echo "PASS (7) an exemption that no longer excuses anything reds as STALE-EXEMPT — the ratchet cannot rot"

# ── 8. Scan-surface asymmetry: a sim/test caller does not resurrect a corpse ──────────────────────
# This is the leg that decides whether the guard can see the incident at all. sandbox-concurrency-
# scenario.sh and sandbox-shared-config-scenario.sh both call `_healthcheck_gate` DIRECTLY and passed
# green through the whole window production stopped calling it. A fixture that keeps a corpse warm is
# not a caller.
TS="$T/sim-caller"; make_tree "$TS" "$WATCHER_DEAD"
mkdir -p "$TS/scripts/herd/sim"
printf '#!/usr/bin/env bash\n_never_called\n' > "$TS/scripts/herd/sim/scenario.sh"
printf '#!/usr/bin/env bash\n_never_called\n' > "$TS/tests/test-fixture.sh"
out="$(herd_lever_reachability_lint "$TS")"; rc=$?
[ "$rc" -eq 1 ] || fail "(8) a sim/test call must NOT count as a production caller (expected exit 1, got $rc): $out"
grep -q '^LEVER-UNREACHABLE FIXTURE_LEVER ' <<< "$out" \
  || fail "(8) expected FIXTURE_LEVER still flagged despite the sim + test call sites (got: $out)"
pass
echo "PASS (8) a sim or test calling the dead function does not make it live — the scan surface is asymmetric on purpose"

# ── 9. A python-side consumer keeps the lever green ──────────────────────────────────────────────
TP="$T/py-consumer"; make_tree "$TP" "$WATCHER_DEAD"
mkdir -p "$TP/pysrc/herd"
printf 'import os\nMODE = os.environ.get("FIXTURE_LEVER", "off")\n' > "$TP/pysrc/herd/live_runtime.py"
out="$(herd_lever_reachability_lint "$TP")"; rc=$?
[ "$rc" -eq 0 ] || fail "(9) a python consumer must keep the lever clean (exit 0, got $rc): $out"
grep -q '^LEVER-UNREACHABLE' <<< "$out" && fail "(9) no finding expected with a live python consumer (got: $out)"
pass
echo "PASS (9) a pysrc consumer keeps the lever green — os.environ has no dead-function class"

# ── 10. herd-config.sh declarations are not consumers ────────────────────────────────────────────
# The whole check collapses if `: "${KEY:=default}"` counts: those lines sit at TOP LEVEL in
# herd-config.sh, so every key on the tree would look reachable and the guard would report clean
# forever. Leg (2) already depends on this — assert it directly so the reason is on the record.
grep -q ': "${FIXTURE_LEVER:="off"}"' "$TD/scripts/herd/herd-config.sh" \
  || fail "(10) fixture drift: herd-config.sh no longer carries the declaration this leg asserts about"
grep -qx 'export FIXTURE_LEVER' "$TD/scripts/herd/herd-config.sh" \
  || fail "(10) fixture drift: herd-config.sh no longer carries the export line"
rm -f "$TD/tests/lever-reachability-exempt.tsv"
out="$(herd_lever_reachability_lint "$TD")"; rc=$?
[ "$rc" -eq 1 ] || fail "(10) a declared-but-unreachable lever must still red — declarations are not consumers (got exit $rc): $out"
pass
echo "PASS (10) herd-config.sh's declaration + export lines do not count as consumers (else every key would read reachable)"

# ── 11. Fail-soft: no capability manifest → skip, never a red ────────────────────────────────────
TNS="$T/nosurface"; mkdir -p "$TNS/somewhere"
HERD_LEVER_REACHABILITY_SKIP_REASON=""
herd_lever_reachability_lint "$TNS" >/dev/null 2>&1; skip_rc=$?
[ "$skip_rc" -eq 2 ] || fail "(11) a tree with no templates/capabilities.tsv → skip (exit 2, got $skip_rc)"
[ -n "${HERD_LEVER_REACHABILITY_SKIP_REASON:-}" ] || fail "(11) HERD_LEVER_REACHABILITY_SKIP_REASON must be set on skip"
pass
echo "PASS (11) a tree with no engine capability surface → skip (exit 2), never a red"

echo
echo "ALL PASS ($PASS checks) — an inert lever is caught pre-PR, mutation-proven both ways and through a transitive chain."
