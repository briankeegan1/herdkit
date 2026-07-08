#!/usr/bin/env bash
# test-native-burst.sh — hermetic tests for HERD-107: the native-burst bounded read-only FAN-OUT seam
# (scripts/herd/burst.sh) and its wiring into the research lane + the pre-merge review panel.
#
# The seam's contract (the properties this test LOCKS):
#   • herd_burst_bound honors REVIEW_CONCURRENCY as the CEILING and is 1 when the feature is OFF (so
#     every caller is byte-identical to its pre-burst behavior by default).
#   • herd_burst NEVER runs more than <bound> workers at once — the "never exceeds the cap" invariant.
#   • bound<=1 is a STRICT serial loop, in argument order — the "WRITES stay serial" invariant (a write
#     lane runs at bound 1 and is provably never concurrent).
#   • the review PANEL combines member verdicts FAIL-SAFE: any BLOCK ⇒ BLOCK, else any PASS ⇒ PASS,
#     else (all members died) ⇒ INFRA-FAIL — never a way to turn a BLOCK into a PASS.
#   • additive/config-gated wiring: research.sh + herd-review.sh gate every burst behavior on the seam.
#
# Fully hermetic: sources burst.sh directly + stubs claude/gh/git/herdr on PATH for the review panel.
# NO network, NO model, NO live herdr pane. No `set -e` (several checks assert non-zero returns).
# Run:  bash tests/test-native-burst.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
BURST="$ROOT/scripts/herd/burst.sh"
REVIEW="$ROOT/scripts/herd/herd-review.sh"
RESEARCH="$ROOT/scripts/herd/research.sh"
CONFIG="$ROOT/scripts/herd/herd-config.sh"
CAPS="$ROOT/templates/capabilities.tsv"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ pass=$((pass+1)); }

for f in "$BURST" "$REVIEW" "$RESEARCH" "$CONFIG" "$CAPS"; do
  [ -f "$f" ] || fail "missing required file: $f"
done
command -v python3 >/dev/null 2>&1 || fail "python3 required"

# shellcheck source=/dev/null
. "$BURST" || fail "sourcing burst.sh failed"
for fn in herd_burst_enabled herd_burst_bound herd_burst; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined after sourcing burst.sh"
done
ok

################################################################################
# 1 — herd_burst_enabled: on/1/true/yes ⇒ enabled; anything else (incl. unset) ⇒ off (fail safe).
################################################################################
for v in on ON On 1 true TRUE yes Y; do
  ( NATIVE_BURST="$v"; herd_burst_enabled ) || fail "1: NATIVE_BURST=$v should be ENABLED"
done
for v in off OFF 0 false no "" garbage 2; do
  ( NATIVE_BURST="$v"; herd_burst_enabled ) && fail "1: NATIVE_BURST=$v should be OFF"
done
( unset NATIVE_BURST; herd_burst_enabled ) && fail "1: unset NATIVE_BURST should be OFF"
ok

################################################################################
# 2 — herd_burst_bound: OFF ⇒ always 1; ON ⇒ REVIEW_CONCURRENCY ceiling, requested may only LOWER it.
################################################################################
# OFF → 1 regardless of REVIEW_CONCURRENCY or a requested size.
[ "$(NATIVE_BURST=off REVIEW_CONCURRENCY=8 herd_burst_bound)" = "1" ]   || fail "2a: off ⇒ bound 1"
[ "$(NATIVE_BURST=off REVIEW_CONCURRENCY=8 herd_burst_bound 5)" = "1" ] || fail "2b: off ⇒ bound 1 even with requested"
# ON, no requested → REVIEW_CONCURRENCY.
[ "$(NATIVE_BURST=on REVIEW_CONCURRENCY=4 herd_burst_bound)" = "4" ]    || fail "2c: on ⇒ bound == REVIEW_CONCURRENCY"
# ON, requested BELOW ceiling → requested (a caller may ask for fewer lanes).
[ "$(NATIVE_BURST=on REVIEW_CONCURRENCY=4 herd_burst_bound 2)" = "2" ]  || fail "2d: requested below ceiling honored"
# ON, requested ABOVE ceiling → capped at REVIEW_CONCURRENCY (the ceiling always wins).
[ "$(NATIVE_BURST=on REVIEW_CONCURRENCY=2 herd_burst_bound 9)" = "2" ]  || fail "2e: requested above ceiling capped to REVIEW_CONCURRENCY"
# ON, garbage REVIEW_CONCURRENCY → default 2; garbage requested → the ceiling; requested 0 → clamp to 1.
[ "$(NATIVE_BURST=on REVIEW_CONCURRENCY=xx herd_burst_bound)" = "2" ]   || fail "2f: non-numeric REVIEW_CONCURRENCY ⇒ default 2"
[ "$(NATIVE_BURST=on REVIEW_CONCURRENCY=4 herd_burst_bound zz)" = "4" ] || fail "2g: non-numeric requested ⇒ ceiling"
[ "$(NATIVE_BURST=on REVIEW_CONCURRENCY=4 herd_burst_bound 0)" = "1" ]  || fail "2h: requested 0 ⇒ clamp to 1"
ok

################################################################################
# 3 — herd_burst NEVER exceeds the cap (peak concurrency). A worker atomically bumps a live counter,
#     records the peak, sleeps so overlap is observable, then decrements. Peak must stay <= bound.
################################################################################
LIVE="$T/live"; PEAK="$T/peak"; ORDER="$T/order"; LOCK="$T/lock.d"
_bt_lock(){   while ! mkdir "$LOCK" 2>/dev/null; do sleep 0.005; done; }
_bt_unlock(){ rmdir "$LOCK" 2>/dev/null || true; }
_bt_reset(){ printf '0\n' > "$LIVE"; printf '0\n' > "$PEAK"; : > "$ORDER"; rmdir "$LOCK" 2>/dev/null || true; }
# Worker: bump live, track peak, sleep, drop live; also append its arg to $ORDER for the serial test.
bt_worker(){
  _bt_lock
  local cur peak
  cur=$(( $(cat "$LIVE") + 1 )); printf '%s\n' "$cur" > "$LIVE"
  peak=$(cat "$PEAK"); [ "$cur" -gt "$peak" ] && printf '%s\n' "$cur" > "$PEAK"
  _bt_unlock
  sleep 0.15
  _bt_lock; printf '%s\n' "$(( $(cat "$LIVE") - 1 ))" > "$LIVE"; _bt_unlock
  printf '%s\n' "$1" >> "$ORDER"
}

# bound 3 over 9 jobs → peak must be >1 (proves real concurrency) and <=3 (the cap).
_bt_reset
herd_burst 3 bt_worker 1 2 3 4 5 6 7 8 9 || fail "3a: herd_burst returned non-zero on all-success workers"
p="$(cat "$PEAK")"
[ "$p" -le 3 ] || fail "3a: peak concurrency $p exceeded the cap of 3"
[ "$p" -gt 1 ] || fail "3a: peak concurrency $p — bound 3 never actually ran concurrently"
ok

# bound 1 over 5 jobs → STRICT serial: peak == 1 AND argument order preserved (the WRITES-serial contract).
_bt_reset
herd_burst 1 bt_worker a b c d e || fail "3b: serial herd_burst returned non-zero"
p="$(cat "$PEAK")"
[ "$p" -eq 1 ] || fail "3b: bound 1 must be strictly serial (peak was $p, expected 1)"
got="$(tr '\n' ' ' < "$ORDER" | sed 's/ *$//')"
[ "$got" = "a b c d e" ] || fail "3b: serial order not preserved (got '$got')"
ok

# bound 0 / non-numeric ⇒ treated as serial (never concurrent) — a WRITE lane can never accidentally burst.
_bt_reset
herd_burst 0 bt_worker x y z || fail "3c: bound 0 returned non-zero"
[ "$(cat "$PEAK")" -eq 1 ] || fail "3c: bound 0 must degrade to strictly serial"
_bt_reset
herd_burst notanumber bt_worker x y z || fail "3d: non-numeric bound returned non-zero"
[ "$(cat "$PEAK")" -eq 1 ] || fail "3d: non-numeric bound must degrade to strictly serial"
ok

# bound larger than the job count → peak never exceeds the number of jobs (can't over-fan-out).
_bt_reset
herd_burst 8 bt_worker 1 2 3 || fail "3e: over-provisioned bound returned non-zero"
[ "$(cat "$PEAK")" -le 3 ] || fail "3e: peak exceeded the job count"
ok

################################################################################
# 4 — herd_burst return code + usage: non-zero iff a worker fails; usage error (no fn) ⇒ 2.
################################################################################
bt_pass(){ return 0; }
bt_onefail(){ [ "$1" = "3" ] && return 1; return 0; }
herd_burst 3 bt_pass 1 2 3 4 || fail "4a: all-success should return 0"
if herd_burst 3 bt_onefail 1 2 3 4; then fail "4b: a failing worker should make herd_burst return non-zero"; fi
herd_burst 1 bt_pass 1 2 3 || fail "4c: serial all-success should return 0"
rc=0; herd_burst 3 || rc=$?; [ "$rc" -eq 2 ] || fail "4d: missing worker fn should return 2 (got $rc)"
ok

################################################################################
# 5 — Review PANEL end-to-end (herd-review.sh, real script; claude/gh/git/herdr stubbed).
#     Proves the seam fans out N reviewer passes and folds them FAIL-SAFE.
################################################################################
BIN="$T/bin"; mkdir -p "$BIN"
for cmd in gh git; do printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$cmd"; chmod +x "$BIN/$cmd"; done
cat > "$BIN/herdr" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "agent list") printf '{"result":{"agents":[]}}\n' ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$BIN/herdr"
export PATH="$BIN:$PATH"

# _panel_stub <mode> — write a claude stub whose behavior across the N concurrent members is
# RACE-FREE deterministic via an atomic `mkdir` claim:
#   allpass  — every member prints REVIEW: PASS
#   allblock — every member prints a structured REVIEW: BLOCK
#   oneblock — EXACTLY ONE member (the mkdir winner) prints BLOCK; the rest PASS  → combined BLOCK
#   onepass  — EXACTLY ONE member prints PASS; the rest print NO verdict           → combined PASS
#   noverdict— no member prints a verdict                                          → INFRA-FAIL
# Every invocation also appends a line to $PANEL_CALLS so the test can count members that ran.
_panel_stub(){
  local mode="$1"
  # MODE and the claim/call-log paths are BAKED as literals at generation time ($ expands now); the
  # runtime references (\$MODE, \$CLAIM, \$1) stay literal so the generated stub reads its own vars.
  cat > "$BIN/claude" <<STUB
#!/usr/bin/env bash
printf 'x\n' >> "$PANEL_CALLS"
MODE="$mode"
CLAIM="$PANEL_CLAIM"
emit(){ printf '{"type":"result","subtype":"success","result":"%s"}\n' "\$1"; exit 0; }
PASS='REVIEW: PASS'
BLOCK='REVIEW: BLOCK — rule: off-by-one | why: overshoots | location: f.sh:1'
case "\$MODE" in
  allpass)  emit "\$PASS" ;;
  allblock) emit "\$BLOCK" ;;
  oneblock) if mkdir "\$CLAIM" 2>/dev/null; then emit "\$BLOCK"; else emit "\$PASS"; fi ;;
  onepass)  if mkdir "\$CLAIM" 2>/dev/null; then emit "\$PASS"; else emit "no verdict here"; fi ;;
  noverdict) emit "nothing to see" ;;
esac
STUB
  chmod +x "$BIN/claude"
}

# _run_panel <mode> <pr> — run herd-review.sh PR mode with a 3-member panel; echo "rc|verdict".
_run_panel(){
  local mode="$1" pr="$2"
  export PANEL_CALLS="$T/calls-$pr"; : > "$PANEL_CALLS"
  export PANEL_CLAIM="$T/claim-$pr.d"; rm -rf "$PANEL_CLAIM"
  _panel_stub "$mode"
  local out rc
  out="$(HERD_NO_PANE=1 NATIVE_BURST=on REVIEW_PANEL=3 REVIEW_CONCURRENCY=3 \
        HERD_REVIEW_RESULT_FILE="$T/res-$pr" WORKTREES_DIR="$T/trees" \
        HERD_CONFIG_FILE="$T/no-such-config" JOURNAL_FILE="$T/j-$pr" \
        bash "$REVIEW" "$pr" "slug-$pr" 2>/dev/null)"
  rc=$?
  printf '%s|%s' "$rc" "$out"
}
mkdir -p "$T/trees"

# 5a — all members PASS → combined PASS (exit 0), and exactly 3 members ran (real fan-out of 3).
r="$(_run_panel allpass 101)"
[ "${r%%|*}" = "0" ]                            || fail "5a: all-PASS panel should exit 0 (got ${r%%|*})"
printf '%s' "${r#*|}" | grep -qx 'REVIEW: PASS' || fail "5a: all-PASS panel should emit 'REVIEW: PASS'"
[ "$(wc -l < "$T/calls-101" | tr -cd 0-9)" = "3" ] || fail "5a: panel should have run exactly 3 members"
ok

# 5b — all members BLOCK → combined BLOCK (exit 1), structured line preserved.
r="$(_run_panel allblock 102)"
[ "${r%%|*}" = "1" ]                                  || fail "5b: all-BLOCK panel should exit 1"
printf '%s' "${r#*|}" | grep -q '^REVIEW: BLOCK — rule: off-by-one' || fail "5b: BLOCK line must survive"
ok

# 5c — FAIL-SAFE: exactly ONE member BLOCKs among PASSes → combined BLOCK (a single finding blocks).
r="$(_run_panel oneblock 103)"
[ "${r%%|*}" = "1" ]                     || fail "5c: one BLOCK among PASSes MUST block the merge (exit 1)"
printf '%s' "${r#*|}" | grep -q '^REVIEW: BLOCK' || fail "5c: combined verdict must be BLOCK"
ok

# 5d — one member PASSes while the rest die with no verdict → combined PASS (one clean review = today's bar).
r="$(_run_panel onepass 104)"
[ "${r%%|*}" = "0" ]                            || fail "5d: one PASS + dead members should still PASS (exit 0)"
printf '%s' "${r#*|}" | grep -qx 'REVIEW: PASS' || fail "5d: combined verdict must be PASS"
ok

# 5e — NO member reaches a verdict → INFRA-FAIL (exit 2), never a cached BLOCK.
r="$(_run_panel noverdict 105)"
[ "${r%%|*}" = "2" ]                                 || fail "5e: a total member wipeout must be INFRA-FAIL (exit 2)"
printf '%s' "${r#*|}" | grep -q '^REVIEW: INFRA-FAIL' || fail "5e: combined verdict must be INFRA-FAIL"
ok

################################################################################
# 6 — DEFAULT-OFF byte-identical: with NATIVE_BURST unset, a PR review takes the single-reviewer path
#     (one claude call, panel dormant) — the pre-burst behavior.
################################################################################
export PANEL_CALLS="$T/calls-default"; : > "$PANEL_CALLS"
export PANEL_CLAIM="$T/claim-default.d"; rm -rf "$PANEL_CLAIM"
_panel_stub allpass
out="$(HERD_NO_PANE=1 HERD_REVIEW_RESULT_FILE="$T/res-default" WORKTREES_DIR="$T/trees" \
      HERD_CONFIG_FILE="$T/no-such-config" JOURNAL_FILE="$T/j-default" \
      bash "$REVIEW" 200 slug-default 2>/dev/null)"; rc=$?
[ "$rc" -eq 0 ] || fail "6: default review should exit 0"
printf '%s\n' "$out" | grep -qx 'REVIEW: PASS' || fail "6: default review should PASS"
[ "$(wc -l < "$PANEL_CALLS" | tr -cd 0-9)" = "1" ] || fail "6: default (burst off) must run a SINGLE reviewer, not a panel"
ok

################################################################################
# 7 — Source invariants: the wiring is present AND gated (config-gated + additive).
################################################################################
grep -q 'burst.sh' "$RESEARCH"                 || fail "7a: research.sh must source burst.sh"
grep -q 'herd_burst_enabled' "$RESEARCH"       || fail "7b: research.sh must gate its burst hint on herd_burst_enabled"
grep -q 'burst.sh' "$REVIEW"                    || fail "7c: herd-review.sh must source burst.sh"
grep -q 'herd_burst ' "$REVIEW"                 || fail "7d: herd-review.sh must use herd_burst for the panel"
grep -q '_combine_verdicts' "$REVIEW"           || fail "7e: herd-review.sh must combine panel verdicts"
grep -qE '^: "\$\{NATIVE_BURST:="off"\}"' "$CONFIG" || fail "7f: herd-config.sh must default NATIVE_BURST to off"
grep -qE '^: "\$\{REVIEW_PANEL:="1"\}"'    "$CONFIG" || fail "7g: herd-config.sh must default REVIEW_PANEL to 1"
# Portable tab-delimited column check (BSD grep has no -P/PCRE, and \t is not a tab in BRE/ERE) —
# match the manifest's own `name<TAB>kind` columns via awk, the repo's canonical tsv-assert style.
awk -F'\t' '$1=="NATIVE_BURST" && $2=="config"{f=1} END{exit f?0:1}' "$CAPS" || fail "7h: capabilities.tsv must document NATIVE_BURST"
awk -F'\t' '$1=="REVIEW_PANEL" && $2=="config"{f=1} END{exit f?0:1}' "$CAPS" || fail "7i: capabilities.tsv must document REVIEW_PANEL"
ok

echo "ALL PASS ($pass checks)"
