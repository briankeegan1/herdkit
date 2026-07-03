#!/usr/bin/env bash
# test-external-consumer-audit.sh — hermetic proof of the Phase-4 external-consumer abstraction audit
# rig (docs/external-consumer-audit.md).
#
# Asserts:
#   (a) DETERMINISM — external-consumer-fixture.sh builds a byte-identical synthetic Go repo every
#       run: two independent builds share the same HEAD sha AND tracked-tree manifest. The generic
#       Go layout is present (go.mod, cmd/, internal/) and — crucially — NO herdkit conventions are
#       (no BACKLOG.md, no app/ dir, no .herd/): that is what makes it a true external consumer.
#   (b) LEAKS REPRODUCE — external-consumer-probe.sh drives the REAL scout/render/healthcheck logic
#       against the fixture, exits 0, emits a well-shaped scorecard.json, and every documented leak
#       reproduces (result=leaks-confirmed, skipped=0).
#   (c) THE HEADLINE LEAK, DIRECTLY — a broken .go source passes scripts/herd/healthcheck.sh's light
#       profile as CLEAN with exit 0 (a generic consumer with no HEALTHCHECK_CMD gets zero real
#       gating), while an equivalent broken .sh is correctly caught (exit 1) — proving the gap is
#       stack-specific, not a broken gate.
#
# Fully hermetic: local git only, NO herdr, NO network, NO model, NO doctor gate. Mirrors the
# throwaway-git conventions of tests/test-sandbox-sim.sh.
# Run:  bash tests/test-external-consumer-audit.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
FIXTURE="$HERE/../scripts/herd/sim/external-consumer-fixture.sh"
PROBE="$HERE/../scripts/herd/sim/external-consumer-probe.sh"
HEALTHCHECK="$HERE/../scripts/herd/healthcheck.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail(){ echo "FAIL: $1" >&2; exit 1; }
command -v git     >/dev/null 2>&1 || fail "git required"
command -v python3 >/dev/null 2>&1 || fail "python3 required"
[ -f "$FIXTURE" ] || fail "missing $FIXTURE"
[ -f "$PROBE" ]   || fail "missing $PROBE"

# ── (a) DETERMINISM ─────────────────────────────────────────────────────────────
sha1="$(bash "$FIXTURE" "$T/fx1" | awk '/^HEAD:/{print $2}')"
sha2="$(bash "$FIXTURE" "$T/fx2" | awk '/^HEAD:/{print $2}')"
[ -n "$sha1" ] || fail "(a) fixture 1 emitted no HEAD sha"
[ "$sha1" = "$sha2" ] || fail "(a) fixture is NON-deterministic: $sha1 != $sha2"
man1="$(git -C "$T/fx1" ls-files -s)"; man2="$(git -C "$T/fx2" ls-files -s)"
[ "$man1" = "$man2" ] || fail "(a) tracked-tree manifest differs between builds"

# Generic Go layout present …
[ -f "$T/fx1/go.mod" ]                         || fail "(a) go.mod missing from fixture"
[ -f "$T/fx1/cmd/greetd/main.go" ]             || fail "(a) cmd/greetd/main.go missing"
[ -f "$T/fx1/internal/greet/greet.go" ]        || fail "(a) internal/greet/greet.go missing"
# … and NO herdkit conventions (this is the whole point of a generic external consumer).
[ ! -e "$T/fx1/BACKLOG.md" ] || fail "(a) fixture must NOT ship a BACKLOG.md (it's a generic consumer)"
[ ! -e "$T/fx1/app" ]        || fail "(a) fixture must NOT ship an app/ dir (Go uses cmd/ + internal/)"
[ ! -e "$T/fx1/.herd/config" ] || fail "(a) fixture must NOT ship a .herd/config (greenfield consumer)"
# Idempotent rebuild.
sha1b="$(bash "$FIXTURE" "$T/fx1" | awk '/^HEAD:/{print $2}')"
[ "$sha1b" = "$sha1" ] || fail "(a) rebuild is not idempotent: $sha1b != $sha1"
echo "PASS (a) deterministic synthetic Go consumer fixture — HEAD $sha1"

# ── (b) LEAKS REPRODUCE VIA THE PROBE ───────────────────────────────────────────
ART="$T/probe-run"
bash "$PROBE" --artifacts "$ART" >"$T/probe.out" 2>"$T/probe.err" \
  || fail "(b) probe exited non-zero; stderr:$(cat "$T/probe.err")"
SC="$ART/scorecard.json"
[ -f "$SC" ] || fail "(b) probe emitted no scorecard.json"
python3 - "$SC" <<'PY' || fail "(b) scorecard shape/expectations wrong"
import json,sys
d=json.load(open(sys.argv[1]))
assert d["scenario"]=="external-consumer-abstraction-audit", d["scenario"]
assert d["result"]=="leaks-confirmed", d["result"]
assert d["skipped"]==0, ("unexpected skipped probes", d["skipped"])
assert d["leaks"]>=5, ("expected >=5 leaks", d["leaks"])
names={p["name"] for p in d["probes"]}
for want in ("scout-detects-go","light-profile-ignores-go","app-glob-mismatch","rendered-skill-tooling"):
    assert want in names, ("missing probe", want)
for p in d["probes"]:
    assert p["status"] in ("leak","clean","skip"), p
print("scorecard ok: leaks=%d clean=%d skip=%d" % (d["leaks"],d["clean"],d["skipped"]))
PY
echo "PASS (b) all documented leaks reproduce — $(sed -n 's/.*"result": *"\([^"]*\)".*/\1/p' "$SC" | head -1)"

# ── (c) THE HEADLINE LEAK, DIRECTLY AGAINST healthcheck.sh ───────────────────────
# Build a fresh fixture, break a .go file, and confirm the light profile calls it CLEAN.
bash "$FIXTURE" "$T/fx3" >/dev/null || fail "(c) fixture build failed"
printf '\nfunc broken( {\n' >> "$T/fx3/internal/greet/greet.go"
out_go="$(HERD_CONFIG_FILE=/dev/null bash "$HEALTHCHECK" "$T/fx3" --oneline 2>&1)"; rc_go=$?
[ "$rc_go" -eq 0 ] || fail "(c) expected broken .go to pass light profile (exit 0), got rc=$rc_go: $out_go"
printf '%s' "$out_go" | grep -qi 'clean' || fail "(c) expected 'clean' verdict for broken .go, got: $out_go"
echo "PASS (c1) broken .go silently passes the light healthcheck: '$out_go' (exit 0)"

# Control: an equivalent broken .sh IS caught — proving the gate works, the gap is stack-specific.
mkdir -p "$T/fx3/scripts"
printf 'if then fi\n' > "$T/fx3/scripts/oops.sh"
git -C "$T/fx3" add scripts/oops.sh >/dev/null 2>&1
out_sh="$(HERD_CONFIG_FILE=/dev/null bash "$HEALTHCHECK" "$T/fx3" --oneline 2>&1)"; rc_sh=$?
[ "$rc_sh" -eq 1 ] || fail "(c) expected broken .sh to be caught (exit 1), got rc=$rc_sh: $out_sh"
echo "PASS (c2) an equivalent broken .sh IS caught (exit 1) — the light-profile gap is stack-specific"

echo
echo "ALL PASS — external-consumer abstraction-audit rig is sound and every leak reproduces."
