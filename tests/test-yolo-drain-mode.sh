#!/usr/bin/env bash
# test-yolo-drain-mode.sh — hermetic proof of the YOLO posture + coordinator DRAIN MODE (HERD-466).
#
# Two halves, both proven here:
#
#   HALF 1 — the `yolo` row in templates/postures.tsv and the `herd posture` command that applies it:
#     (A) the row carries EVERY lever the feature promises, and every key/value it sets is accepted
#         by the manifest's own value-domain validation (the check `herd config set` runs).
#     (B) `herd posture list|show` read the canonical table; `apply` is ATOMIC (a bundle carrying one
#         bad key/value writes NOTHING), prints the full delta, applies through the validated
#         `herd config set`, leaves `herd config lint` clean, and re-applying is a hard no-op.
#         A non-interactive apply without --yes refuses and writes nothing.
#
#   HALF 2 — the DRAIN MODE section rendered into the coordinator skill:
#     (C) the RENDER carries the section — the 7-step loop, the three declared stop conditions, and
#         the "NOT gateless" statement — with no unsubstituted {{tokens}}, and it comes from the
#         TEMPLATE (deleting the render and re-rendering reproduces it byte-identically).
#     (D) the drain SIM (scripts/herd/sim/yolo-drain-scenario.sh): 3 stub items drain to zero
#         hands-free with a scorecard asserting ZERO coordinator prompts, and each stop condition is
#         MUTATION-PROVEN — the budget ceiling halts the loop with items still open, the resolver's
#         ESCALATE halts it, and a weaker posture (the control arm) drains with prompts > 0.
#     (E) the new posture is wired into the posture-matrix routing, so it cannot ship unexercised.
#
# Fully hermetic: temp git repos, local git only, no network, no gh, no herdr, no model.
# Run:  bash tests/test-yolo-drain-mode.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
HERD="$ROOT/bin/herd"
POSTURES="$ROOT/templates/postures.tsv"
CAPS="$ROOT/templates/capabilities.tsv"
TMPL="$ROOT/templates/coordinator.md.tmpl"
SIM="$ROOT/scripts/herd/sim/yolo-drain-scenario.sh"
MATRIX="$ROOT/scripts/herd/sim/sandbox-posture-matrix.sh"
CONC="$ROOT/scripts/herd/sim/sandbox-concurrency-scenario.sh"

for f in "$HERD" "$POSTURES" "$CAPS" "$TMPL" "$SIM" "$MATRIX" "$CONC"; do
  [ -f "$f" ] || { echo "FAIL: missing $f" >&2; exit 1; }
done
command -v git >/dev/null 2>&1 || { echo "FAIL: git required" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 required" >&2; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { PASS=$((PASS + 1)); echo "PASS: $1"; }

SKILL_REL=".claude/commands/coordinator.md"

# _mkproj <dir> — a committed hermetic git repo with herdkit stood up in it.
_mkproj() {
  local d="$1"
  mkdir -p "$d"
  git -C "$d" init -q -b main
  git -C "$d" config user.email t@t.local; git -C "$d" config user.name t
  git -C "$d" commit -q --allow-empty -m base
  ( cd "$d" && HERD_NONINTERACTIVE=1 HERD_SKIP_DOCTOR=1 bash "$HERD" init ) >/dev/null 2>&1 \
    || fail "herd init failed in $d"
}
# _herd <dir> <args...> — run the CLI in <dir>, non-interactive, no doctor.
_herd() { local d="$1"; shift; ( cd "$d" && HERD_NONINTERACTIVE=1 HERD_SKIP_DOCTOR=1 bash "$HERD" "$@" ); }

# _sc <scorecard> <key> — read a top-level scalar from a scenario scorecard. A JSON bool prints as
# lowercase true/false (not Python's True/False) so a shell comparison reads the JSON literal.
_sc() { python3 -c 'import json,sys
try:
    v = json.load(open(sys.argv[1])).get(sys.argv[2], "")
    print(json.dumps(v) if isinstance(v, bool) else v)
except Exception: print("")' "$1" "$2" 2>/dev/null; }

# ── A. the posture row: every promised lever, every value accepted by the manifest ────────────────
YOLO_KEYS="$(awk -F'\t' '$1=="yolo"{print $2}' "$POSTURES")"
[ -n "$YOLO_KEYS" ] || fail "A1: no 'yolo' row in templates/postures.tsv"
ok "A1 templates/postures.tsv carries a 'yolo' row"

# The 18 levers the tracker item enumerates. Every one must be in the bundle at the stated value.
EXPECTED="MERGE_POLICY=auto HUMAN_VERIFY_POLICY=auto REVIEW_AUTOFIX=true HEALTHCHECK_AUTOFIX=true \
STALE_BASE_AUTOFIX=on DRAFT_AUTO_PROMOTE=on DEAD_BUILDER_AUTORESPAWN=on WEDGE_AUTOWAKE=on \
MAIN_HEALTH_AUTOFIX=on CI_AUTOREPAIR=on MERGE_FAIRNESS=on SWEEP_AUTO=auto WATCHER_SELF_RESTART=on \
COORDINATOR_WATCHDOG=on ADOPT_REMOTE_PRS=on COORDINATOR_AUTONOMY=full TRACKED_SPAWNS=required \
CLAIM_REQUIRED=on"
for kv in $EXPECTED; do
  case " $YOLO_KEYS " in
    *" $kv "*) ;;
    *) fail "A2: the yolo posture does not set $kv" ;;
  esac
done
ok "A2 the yolo bundle sets all 18 levers (16 auto + TRACKED_SPAWNS + CLAIM_REQUIRED)"

# YOLO is fast, not off-book: the audit-trail keys must NOT be relaxed.
case " $YOLO_KEYS " in *" TRACKED_SPAWNS=off "*|*" CLAIM_REQUIRED=off "*) fail "A3: yolo relaxes the audit trail" ;; esac
ok "A3 yolo keeps the audit trail (never TRACKED_SPAWNS=off / CLAIM_REQUIRED=off)"

# VALUE-DOMAIN VALIDATION: every key exists in capabilities.tsv and its value_shape admits the value.
# This is the same manifest the `herd config set` write-time check reads, asserted directly here so a
# posture can never carry a value the setter would refuse at apply time.
YOLO_KEYS="$YOLO_KEYS" CAPS="$CAPS" python3 - <<'PY' || fail "A4: a yolo key/value is not admitted by capabilities.tsv value_shape"
import os, re, sys
caps = {}
for row in open(os.environ["CAPS"], encoding="utf-8").read().split("\n")[1:]:
    col = row.split("\t")
    if len(col) < 8 or col[1] != "config":
        continue
    caps[col[0]] = col[7]
bad = []
for kv in os.environ["YOLO_KEYS"].split():
    k, _, v = kv.partition("=")
    if k not in caps:
        bad.append(f"{k}: no kind=config row in capabilities.tsv"); continue
    shape = caps[k]
    if shape in ("", "free", "glob"):
        continue
    if shape == "numeric":
        if not re.fullmatch(r"\d+", v): bad.append(f"{k}={v}: not numeric")
        continue
    if v not in shape.split("|"):
        bad.append(f"{k}={v}: not in the enum [{shape}]")
for b in bad:
    print("  " + b, file=sys.stderr)
sys.exit(1 if bad else 0)
PY
ok "A4 every yolo key/value is admitted by its capabilities.tsv value_shape"

# ── B. herd posture list | show | apply ───────────────────────────────────────────────────────────
P="$T/proj"; _mkproj "$P"

# The CLI styles its output, so strip ANSI before matching a bare posture name. Capture first and
# grep a here-string — never `producer | grep -q` (HERD-297: grep's early exit EPIPEs the producer).
LIST="$(_herd "$P" posture list 2>&1 | awk '{ gsub(/\033\[[0-9;]*m/, ""); print }')"
grep -qx '  yolo' <<< "$LIST" || fail "B1: 'herd posture list' does not list yolo"
ok "B1 herd posture list surfaces the yolo posture"

SHOW="$(_herd "$P" posture show yolo 2>&1)" || fail "B2: 'herd posture show yolo' failed"
grep -q 'COORDINATOR_AUTONOMY="full"' <<< "$SHOW" || fail "B2: show did not print the bundle"
ok "B2 herd posture show prints the full KEY=VALUE bundle"

_herd "$P" posture show no-such-posture >/dev/null 2>&1 \
  && fail "B3: show accepted an unknown posture"
ok "B3 an unknown posture name is refused"

# A NON-INTERACTIVE apply WITHOUT --yes must refuse — and write nothing.
CFG_BEFORE="$(cat "$P/.herd/config")"
_herd "$P" posture apply yolo >/dev/null 2>&1 && fail "B4: a non-interactive apply without --yes succeeded"
[ "$CFG_BEFORE" = "$(cat "$P/.herd/config")" ] || fail "B4: the refused apply still wrote to .herd/config"
ok "B4 a non-interactive apply without --yes refuses and writes nothing"

# ATOMIC: a posture whose bundle carries ONE bad value must write NOTHING at all.
BADTBL="$T/bad-postures.tsv"
printf 'name\tkeys\tintent\n' > "$BADTBL"
printf 'halfbad\tMERGE_POLICY=auto SWEEP_AUTO=definitely-not-a-value\tone good key, one out-of-domain value\n' >> "$BADTBL"
printf 'unknownkey\tNOT_A_REAL_HERD_KEY=1\ta key absent from the manifest\n' >> "$BADTBL"
for bad in halfbad unknownkey; do
  CFG_BEFORE="$(cat "$P/.herd/config")"
  ( cd "$P" && HERD_NONINTERACTIVE=1 POSTURES_FILE="$BADTBL" bash "$HERD" posture apply --yes --no-reload "$bad" ) >/dev/null 2>&1 \
    && fail "B5: apply accepted the invalid posture '$bad'"
  [ "$CFG_BEFORE" = "$(cat "$P/.herd/config")" ] || fail "B5: the refused '$bad' apply still wrote to .herd/config"
done
ok "B5 a bundle carrying one bad key/value is refused ATOMICALLY — zero writes"

# The real apply: full delta printed, every key applied through the validated setter.
OUT="$(_herd "$P" posture apply --yes --no-reload yolo 2>&1)" || fail "B6: 'herd posture apply --yes yolo' failed"
grep -q 'config delta' <<< "$OUT" || fail "B6: apply printed no config delta"
grep -q 'MERGE_POLICY' <<< "$OUT"  || fail "B6: the delta does not name MERGE_POLICY"
grep -q '→' <<< "$OUT"             || fail "B6: the delta printed no current→new arrows"
ok "B6 apply prints the full current→new config delta"

# Every lever must hold its bundle value where the ENGINE will read it. Assert through `herd config
# get`, which resolves .herd/config.local over .herd/config exactly as load time does — NOT by
# grepping the two files together, which would pass on a baseline write a pinned overlay shadows.
for kv in $EXPECTED; do
  k="${kv%%=*}"; v="${kv#*=}"
  GOT="$(_herd "$P" config get "$k" 2>/dev/null | tail -1)"
  [ "$GOT" = "$v" ] || fail "B7: $k reads \"$GOT\" at load time, not the posture's \"$v\""
done
ok "B7 all 18 levers hold their bundle value at LOAD TIME (overlay precedence resolved)"

_herd "$P" config lint >/dev/null 2>&1 || fail "B8: 'herd config lint' is red on an applied-yolo config"
ok "B8 herd config lint is clean against an applied-yolo fixture"

# Idempotent: a second apply changes nothing and says so.
OUT2="$(_herd "$P" posture apply --yes --no-reload yolo 2>&1)" || fail "B9: the second apply failed"
grep -q "already on posture 'yolo'" <<< "$OUT2" || fail "B9: the re-apply did not report a no-op"
grep -q '(unchanged)' <<< "$OUT2" || fail "B9: the re-apply printed no unchanged rows"
ok "B9 re-applying an already-applied posture is a hard no-op"

# The posture doctor recognises the applied posture as a CANONICAL, sim-exercised one — the drift
# check this whole feature exists to satisfy.
_DOC="$(_herd "$P" doctor --posture 2>&1)"
grep -q "matches the 'yolo' posture" <<< "$_DOC" \
  || fail "B10: doctor --posture does not recognise the applied yolo posture"
ok "B10 herd doctor --posture recognises the applied posture as canonical"

# The control-room guard covers the new actuator: a builder worktree may not apply a posture.
WT="$T/wt"
git -C "$P" worktree add -q "$WT" -b feat/guard-probe main 2>/dev/null || fail "B11: could not add a probe worktree"
GUARD_RC=0
( cd "$WT" && HERD_NONINTERACTIVE=1 bash "$HERD" posture apply --yes --no-reload yolo ) >/dev/null 2>&1 || GUARD_RC=$?
[ "$GUARD_RC" -eq 3 ] || fail "B11: 'posture apply' from a builder worktree was not refused by the context guard (rc=$GUARD_RC)"
ok "B11 the context guard refuses 'posture apply' from a builder worktree"

# ── B12. OVERLAY SHADOW — the apply must change the layer that WINS, not one nothing reads ────────
# .herd/config.local is sourced after .herd/config, so a key the operator pinned with
# `herd config set --local` wins at load time. An apply that writes only the baseline for such a key
# changes nothing the engine ever reads, yet would still print "applied" — an affirmative claim of a
# transition that never happened. For MERGE_POLICY that means the drain silently never merges while
# the operator believes full-auto is on. Reproduce that exact setup and assert the EFFECTIVE value.
S="$T/shadow"; _mkproj "$S"
# HERD_INIT_DEFER_APPLY=1 only skips the live external-consistency probe (offline hermetic run); the
# validated write path, and the overlay routing being asserted, are the real ones.
( cd "$S" && HERD_NONINTERACTIVE=1 HERD_INIT_DEFER_APPLY=1 bash "$HERD" config set --local MERGE_POLICY approve ) >/dev/null 2>&1 \
  || fail "B12: could not pin MERGE_POLICY in the per-user overlay"
[ "$(_herd "$S" config get MERGE_POLICY 2>/dev/null | tail -1)" = approve ] \
  || fail "B12: the fixture did not end up with an overlay-shadowed MERGE_POLICY"

SOUT="$(_herd "$S" posture apply --yes --no-reload yolo 2>&1)" || fail "B12: apply failed on the shadowed fixture"
[ "$(_herd "$S" config get MERGE_POLICY 2>/dev/null | tail -1)" = auto ] \
  || fail "B12: MERGE_POLICY still reads \"$(_herd "$S" config get MERGE_POLICY 2>/dev/null | tail -1)\" at load time — the apply wrote a layer the overlay shadows"
grep -q 'config.local' <<< "$SOUT" || fail "B12: the report never named the overlay layer it wrote"
# Every other non-machine-scoped lever must land at load time too, shadowed key or not.
for kv in $EXPECTED; do
  k="${kv%%=*}"; v="${kv#*=}"
  [ "$(_herd "$S" config get "$k" 2>/dev/null | tail -1)" = "$v" ] \
    || fail "B12: $k does not read \"$v\" at load time after the apply"
done
ok "B12 an overlay-pinned key is applied to the layer that WINS — the effective value really changes"

# ── B13. EARNED SUCCESS — never report a posture the project is not on ────────────────────────────
# The bundle pre-validation and `herd config set` are not the same check: the setter also refuses,
# e.g., a MODEL_* ref whose driver prefix ships no driver definition. When a key does not take, the
# apply must name it and exit NON-ZERO rather than announce the posture as applied.
REFTBL="$T/badref-postures.tsv"
printf 'name\tkeys\tintent\n' > "$REFTBL"
printf 'badref\tMODEL_REVIEW=nosuchdriver:m1\ta driver prefix that ships no driver definition\n' >> "$REFTBL"
V="$T/verify"; _mkproj "$V"
BEFORE_MR="$(_herd "$V" config get MODEL_REVIEW 2>/dev/null | tail -1)"
VOUT="$( cd "$V" && HERD_NONINTERACTIVE=1 POSTURES_FILE="$REFTBL" bash "$HERD" posture apply --yes --no-reload badref 2>&1 )" \
  && fail "B13: apply reported success for a key the setter refused"
grep -q 'did NOT take' <<< "$VOUT"      || fail "B13: the un-applied key was not named"
grep -q 'NOT fully applied' <<< "$VOUT" || fail "B13: the apply did not refuse to report the posture as active"
grep -q 'control room rebuilt' <<< "$VOUT" && fail "B13: the watcher was rebuilt despite the posture not applying"
[ "$(_herd "$V" config get MODEL_REVIEW 2>/dev/null | tail -1)" = "$BEFORE_MR" ] \
  || fail "B13: the refused value landed anyway"
ok "B13 a key that does not take is named and the apply exits non-zero without claiming the posture"

# ── C. the RENDER carries drain mode ──────────────────────────────────────────────────────────────
R="$T/render"; _mkproj "$R"
[ -f "$R/$SKILL_REL" ] || fail "C0: init did not render the coordinator skill"

# The section and its load-bearing content must be in the RENDER, not only the template.
grep -q '^## Drain mode' "$R/$SKILL_REL"           || fail "C1: the render has no '## Drain mode' section"
grep -q 'YOLO is NOT gateless' "$R/$SKILL_REL"     || fail "C1: the render omits the NOT-gateless statement"
ok "C1 the rendered skill carries the Drain mode section and the NOT-gateless statement"

DRAIN="$(awk '/^## Drain mode/,/^## Rules/' "$R/$SKILL_REL")"
for step in \
  'Drain, route and ack builder notes' \
  'Collision-map every open' \
  'Spawn to capacity on disjoint surfaces' \
  'Dispatch the resolver for any DIRTY PR' \
  'Let the gates merge' \
  'Reconcile and close' \
  'Repeat'
do
  grep -qF "$step" <<< "$DRAIN" || fail "C2: the drain loop is missing the step: $step"
done
ok "C2 the render carries all 7 loop steps"

for stop in 'Backlog empty' 'BUDGET_DAILY' 'Genuine escalation'; do
  grep -qF "$stop" <<< "$DRAIN" || fail "C3: the render is missing the stop condition: $stop"
done
grep -qF 'Stop conditions — the only three' <<< "$DRAIN" || fail "C3: the three stop conditions are not declared as exhaustive"
ok "C3 the render declares exactly three stop conditions (backlog-empty, budget ceiling, escalation)"

grep -qF 'herd posture apply --yes yolo' <<< "$DRAIN" \
  || fail "C4: the drain section does not name the posture-apply incantation"
ok "C4 the drain section names 'herd posture apply --yes yolo'"

# Nothing driver-specific was tokenized into the new section, and no token survived the render.
grep -qE '\{\{[A-Za-z_][A-Za-z0-9_]*\}\}' "$R/$SKILL_REL" \
  && fail "C5: the render left an unsubstituted {{token}}"
grep -n 'DRIVER' <<< "$(awk '/^## Drain mode/,/^## Rules/' "$TMPL")" \
  && fail "C5: the drain-mode TEMPLATE section tokenizes a driver capability — it must stay runtime-independent"
ok "C5 the render leaves no {{token}} and the drain section is driver-independent"

# RENDER EQUIVALENCE: the section is GENERATED. Deleting the render and re-rendering reproduces it
# byte-identically — proof the content lives in the template, never in a hand-edited render.
cp "$R/$SKILL_REL" "$T/render-1.md"
rm -f "$R/$SKILL_REL"
_herd "$R" render >/dev/null 2>&1 || fail "C6: 'herd render' failed"
cmp -s "$T/render-1.md" "$R/$SKILL_REL" || fail "C6: re-rendering did not reproduce the skill byte-identically"
ok "C6 the drain section is generated: delete + 'herd render' reproduces the skill byte-identically"

# The drain section must survive a posture change too (it is unconditional doctrine, not knob-gated).
_herd "$R" posture apply --yes --no-reload yolo >/dev/null 2>&1 || fail "C7: apply failed in the render fixture"
_herd "$R" render >/dev/null 2>&1 || fail "C7: re-render after the posture apply failed"
grep -q '^## Drain mode' "$R/$SKILL_REL" || fail "C7: the drain section vanished after a posture apply + re-render"
grep -q '^## Operating posture' "$R/$SKILL_REL" \
  || fail "C7: COORDINATOR_AUTONOMY=full did not render the Operating posture block"
ok "C7 the drain section survives a posture apply, alongside the rendered Operating posture block"

# ── D. the drain SIM — hands-free drain + mutation-proven stop conditions ─────────────────────────
S1="$T/sim-yolo"
bash "$SIM" --artifacts "$S1" >"$T/sim-yolo.out" 2>&1 || {
  tail -30 "$T/sim-yolo.out" >&2; fail "D1: the yolo drain sim did not pass"; }
[ "$(_sc "$S1/scorecard.json" result)" = pass ]            || fail "D1: scorecard result is not pass"
[ "$(_sc "$S1/scorecard.json" items_total)" = 3 ]          || fail "D1: the sim did not seed 3 items"
[ "$(_sc "$S1/scorecard.json" items_drained)" = 3 ]        || fail "D1: the sim did not drain all 3 items"
[ "$(_sc "$S1/scorecard.json" items_remaining)" = 0 ]      || fail "D1: items were left pending"
[ "$(_sc "$S1/scorecard.json" coordinator_prompts)" = 0 ]  || fail "D1: the drain was NOT hands-free (prompts > 0)"
[ "$(_sc "$S1/scorecard.json" stop_reason)" = backlog-empty ] || fail "D1: wrong stop reason"
[ "$(_sc "$S1/scorecard.json" digest_emitted)" = true ]    || fail "D1: no completion digest on the backlog-empty stop"
[ -s "$S1/digest.txt" ]                                    || fail "D1: the digest file is missing/empty"
ok "D1 sim: 3 stub items drain to ZERO hands-free — scorecard asserts 0 coordinator prompts + a digest"

# The loop really did the collision-map/bundle and resolver legs, not just N independent merges.
[ "$(_sc "$S1/scorecard.json" bundles)" -ge 1 ]             || fail "D2: no same-surface bundle was formed"
[ "$(_sc "$S1/scorecard.json" resolver_dispatches)" -ge 1 ] || fail "D2: the resolver was never dispatched on the DIRTY PR"
[ "$(_sc "$S1/scorecard.json" notes_routed)" -ge 3 ]        || fail "D2: builder notes were not drained each cycle"
[ "$(_sc "$S1/scorecard.json" gate_failures)" = 0 ]         || fail "D2: a gate failure slipped through"
ok "D2 sim: same-surface items bundled, the DIRTY PR went to the resolver, notes drained every cycle"

# MUTATION 1 — the BUDGET_DAILY ceiling must HALT the loop, not merely be measured.
S2="$T/sim-budget"
bash "$SIM" --artifacts "$S2" --budget 0.5 --capacity 1 >"$T/sim-budget.out" 2>&1 || {
  tail -30 "$T/sim-budget.out" >&2; fail "D3: the budget-ceiling run did not pass its own assertions"; }
[ "$(_sc "$S2/scorecard.json" stop_reason)" = budget-ceiling ] || fail "D3: the budget ceiling did not stop the loop"
[ "$(_sc "$S2/scorecard.json" items_remaining)" -gt 0 ]        || fail "D3: the backlog drained anyway — the ceiling was not enforced"
[ "$(_sc "$S2/scorecard.json" digest_emitted)" = false ]       || fail "D3: a completion digest was emitted on a budget stop"
ok "D3 mutation: the BUDGET_DAILY ceiling HALTS the drain with items still open (enforced, not measured)"

# MUTATION 2 — a resolver ESCALATE is a genuine escalation stop.
S3="$T/sim-escalate"
bash "$SIM" --artifacts "$S3" --escalate-at 02 >"$T/sim-escalate.out" 2>&1 || {
  tail -30 "$T/sim-escalate.out" >&2; fail "D4: the escalation run did not pass its own assertions"; }
[ "$(_sc "$S3/scorecard.json" stop_reason)" = escalation ]  || fail "D4: the resolver punt did not stop the loop"
[ "$(_sc "$S3/scorecard.json" escalations)" -ge 1 ]         || fail "D4: no escalation was recorded"
[ "$(_sc "$S3/scorecard.json" items_remaining)" -gt 0 ]     || fail "D4: the drain continued past the escalation"
ok "D4 mutation: a resolver ESCALATE halts the drain and is reported as the stop reason"

# CONTROL ARM — the prompt count is not a constant. Under a posture that owns fewer rails the SAME
# work still ships, but with real coordinator pauses. If this ever reads 0 the measurement is broken.
S4="$T/sim-solo"
bash "$SIM" --artifacts "$S4" --posture solo-auto >"$T/sim-solo.out" 2>&1 || {
  tail -30 "$T/sim-solo.out" >&2; fail "D5: the solo-auto control run errored"; }
[ "$(_sc "$S4/scorecard.json" items_drained)" = 3 ]            || fail "D5: the control arm did not drain the backlog"
[ "$(_sc "$S4/scorecard.json" coordinator_prompts)" -gt 0 ] \
  || fail "D5: solo-auto reported ZERO coordinator prompts — the prompt measurement is not lever-driven"
ok "D5 control arm: the same drain under solo-auto costs real coordinator prompts (> 0)"

# ── E. the new posture is wired into the posture matrix (it cannot ship unexercised) ──────────────
grep -qE '^\s+solo-auto\|full-auto\|yolo\|' "$MATRIX" \
  || fail "E1: sandbox-posture-matrix.sh has no scenario mapping for 'yolo'"
grep -qE '^\s+solo-auto\|full-auto\|yolo\|' "$CONC" \
  || fail "E1: sandbox-concurrency-scenario.sh refuses the 'yolo' posture"
ok "E1 the yolo posture is routed by the posture matrix and accepted by its scenario"

# GNU grep's -E does NOT treat '\t' as a tab escape (it warns "stray \ before t" and matches a
# literal 't') — only ugrep/BSD-flavoured greps do, which let this pass here while failing on every
# CI leg (both ubuntu and macOS run real GNU grep). Splice in an actual tab byte instead.
POSTURE_CMD_RE='^herd posture <list\|show\|apply>'$'\t'
grep -qE "$POSTURE_CMD_RE" "$CAPS" \
  || fail "E2: no capabilities.tsv row for 'herd posture'"
grep -qE "$POSTURE_CMD_RE" "$ROOT/templates/conformance.tsv" \
  || fail "E2: no conformance.tsv proof row for 'herd posture'"
ok "E2 the new command carries its capabilities + conformance rows"

echo
echo "ALL $PASS CHECKS PASSED — yolo posture + coordinator drain mode (HERD-466)"
