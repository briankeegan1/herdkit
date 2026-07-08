#!/usr/bin/env bash
# test-infra-breaker.sh — hermetic proof for the INFRA-timeout circuit breaker (HERD-110).
#
# The watcher re-dispatches a review for a candidate every tick until a verdict lands. When the
# ENVIRONMENT is dead (a claude exec-hang, an env failure, a reviewer that dies WITHOUT writing a
# verdict), that re-dispatch burns cycles forever — and across N PRs it multiplies. The breaker tracks
# CONSECUTIVE INFRA failures (non-verdict reviewer deaths — NEVER a real PASS/BLOCK verdict) globally;
# after INFRA_BREAKER_MAX in a row it OPENs (stops dispatch, surfaces a loud row + journal event), and
# after INFRA_BREAKER_COOLDOWN seconds it HALF-OPENs for a single probe (a real verdict closes it, a
# death re-opens it).
#
# This locks in the four load-bearing properties:
#   (1) BYTE-INERT by default — INFRA_BREAKER_MAX unset/0 → every breaker path is a no-op, no ledger.
#   (2) OPENs after N consecutive non-verdict deaths and SUPPRESSes dispatch (_breaker_gate → BLOCKED).
#   (3) CRITICAL: a real BLOCK (or PASS) verdict NEVER trips it — it RESETS the counter (INFRA≠verdict).
#   (4) HALF-OPEN admits EXACTLY ONE probe; a real verdict CLOSEs it; another death RE-OPENs it.
# Plus the review-gate integration: a planted INFRA-FAIL result counts against the breaker via the
# SHIPPED _review_gate_step, while a planted BLOCK/PASS result resets it — and both journal correctly.
#
# Fully hermetic: agent-watch.sh sourced in LIB mode (AGENT_WATCH_LIB=1 → helpers only, no loop / no
# re-exec) against a temp WORKTREES_DIR and a non-existent config, all in subshells so cases can't leak
# into each other. NO herdr, NO gh, NO network, NO model. python3 is a herd hard dep (for journal.sh).
# Run:  bash tests/test-infra-breaker.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WATCH="$ROOT/scripts/herd/agent-watch.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ PASS=$((PASS+1)); echo "PASS $1"; }

[ -f "$WATCH" ] || fail "missing agent-watch.sh at $WATCH"

# source_watcher <trees> [MAX] [COOLDOWN] — source the REAL watcher in lib mode with the breaker knobs
# in the CURRENT shell. Callers run each scenario in its own subshell so ledger state cannot leak.
source_watcher() {
  export AGENT_WATCH_LIB=1
  export HERD_CONFIG_FILE="$T/no-such-config"
  export WORKTREES_DIR="$1"
  export JOURNAL_FILE="$1/journal.jsonl"
  [ -n "${2:-}" ] && export INFRA_BREAKER_MAX="$2"
  [ -n "${3:-}" ] && export INFRA_BREAKER_COOLDOWN="$3"
  mkdir -p "$1" 2>/dev/null || true
  # shellcheck source=/dev/null
  . "$WATCH" || { echo "__SOURCE_FAILED__"; exit 1; }
}

# ── (1) BYTE-INERT when disabled (default) ───────────────────────────────────────────────────────
(
  WT="$T/off"; source_watcher "$WT"    # INFRA_BREAKER_MAX unset → herd-config.sh default 0 → off
  _breaker_enabled && { echo "breaker enabled when unset"; exit 1; }
  # A storm of infra deaths must write NO ledger and never gate.
  i=0; while [ "$i" -lt 9 ]; do _breaker_record_infra; i=$((i+1)); done
  [ "$(_breaker_gate 1)" = "PASS" ] || { echo "disabled gate not PASS"; exit 1; }
  [ -f "$WT/.agent-watch-infra-breaker" ] && { echo "disabled breaker wrote a ledger"; exit 1; }
  exit 0
) || fail "(1) disabled breaker was not byte-inert"
ok "(1) INFRA_BREAKER_MAX unset/0 → byte-inert: no ledger, gate always PASS, never enabled"

# Also prove an explicit 0 and a garbage value are OFF (fail-safe parse).
(
  source_watcher "$T/off2" 0 300
  _breaker_enabled && { echo "MAX=0 enabled"; exit 1; }
  export INFRA_BREAKER_MAX="garbage"
  _breaker_enabled && { echo "MAX=garbage enabled"; exit 1; }
  exit 0
) || fail "(1b) MAX=0 / non-numeric must parse as OFF"
ok "(1b) INFRA_BREAKER_MAX=0 and non-numeric parse as OFF (fail-safe)"

# ── (2) OPENs after N consecutive non-verdict deaths; dispatch suppressed ─────────────────────────
(
  WT="$T/open"; source_watcher "$WT" 3 300
  [ "$(_breaker_gate 10)" = "PASS" ] || { echo "fresh gate not PASS"; exit 1; }
  _breaker_record_infra; [ "$(_breaker_gate 10)" = "PASS" ] || { echo "1 death should not open"; exit 1; }
  _breaker_record_infra; [ "$(_breaker_gate 10)" = "PASS" ] || { echo "2 deaths should not open"; exit 1; }
  _breaker_record_infra   # 3rd consecutive → OPEN
  read -r st _ _ _ < "$WT/.agent-watch-infra-breaker"
  [ "$st" = "open" ] || { echo "not open after MAX deaths (state=$st)"; exit 1; }
  # Dispatch suppressed for EVERY candidate while cooling down.
  [ "$(_breaker_gate 10)" = "BLOCKED" ] || { echo "gate not BLOCKED while open"; exit 1; }
  [ "$(_breaker_gate 11)" = "BLOCKED" ] || { echo "sibling not BLOCKED while open"; exit 1; }
  # The trip is journaled loudly, exactly once.
  grep -q '"event":"infra_breaker_open"' "$JOURNAL_FILE" || { echo "no infra_breaker_open journal"; exit 1; }
  [ "$(grep -c '"event":"infra_breaker_open"' "$JOURNAL_FILE")" = "1" ] || { echo "open journaled != once"; exit 1; }
  exit 0
) || fail "(2) breaker did not OPEN + suppress dispatch after N consecutive deaths"
ok "(2) OPENs after INFRA_BREAKER_MAX consecutive non-verdict deaths; gate BLOCKED; journaled once"

# ── (3) CRITICAL: a real BLOCK/PASS verdict NEVER trips the breaker, and RESETS the counter ───────
(
  WT="$T/block"; source_watcher "$WT" 3 300
  # Interleave deaths with a real verdict: the reset means the counter never reaches the threshold.
  _breaker_record_infra; _breaker_record_infra   # 2 deaths (below threshold)
  _breaker_record_ok                              # a real verdict (PASS/BLOCK) → reset to 0
  read -r st fa _ _ < "$WT/.agent-watch-infra-breaker"
  [ "$st" = "closed" ] && [ "$fa" = "0" ] || { echo "verdict did not reset (state=$st fails=$fa)"; exit 1; }
  # Two MORE deaths after the reset still must NOT open (would have, without the reset).
  _breaker_record_infra; _breaker_record_infra
  [ "$(_breaker_gate 20)" = "PASS" ] || { echo "opened despite the interleaved verdict reset"; exit 1; }
  # And a long run of pure verdicts never opens and never even writes a trip.
  i=0; while [ "$i" -lt 9 ]; do _breaker_record_ok; i=$((i+1)); done
  [ "$(_breaker_gate 20)" = "PASS" ] || { echo "verdicts tripped the breaker"; exit 1; }
  grep -q '"event":"infra_breaker_open"' "$JOURNAL_FILE" 2>/dev/null && { echo "a verdict path journaled an open"; exit 1; }
  exit 0
) || fail "(3) a real verdict tripped the breaker OR failed to reset the counter"
ok "(3) a real BLOCK/PASS verdict NEVER trips the breaker and RESETS the counter (INFRA≠verdict)"

# ── (4) HALF-OPEN: exactly ONE probe; a real verdict CLOSEs it, a death RE-OPENs it ───────────────
(
  # cooldown=2 (not 1): with 1-second `date +%s` granularity a 1s cooldown races the boundary, so a
  # just-reopened breaker could read now-op=1>=1 and wrongly admit a probe. 2s + a 3s sleep is robust.
  WT="$T/half"; source_watcher "$WT" 2 2
  _breaker_record_infra; _breaker_record_infra   # → OPEN
  [ "$(_breaker_gate 30)" = "BLOCKED" ] || { echo "not blocked immediately after open"; exit 1; }
  sleep 3   # outlast the 2s cooldown
  # First candidate claims the single probe; siblings are blocked; the probe PR keeps PROBE across ticks.
  [ "$(_breaker_gate 30)" = "PROBE" ]   || { echo "first candidate not admitted as PROBE"; exit 1; }
  [ "$(_breaker_gate 31)" = "BLOCKED" ] || { echo "sibling admitted during half-open"; exit 1; }
  [ "$(_breaker_gate 32)" = "BLOCKED" ] || { echo "second sibling admitted during half-open"; exit 1; }
  [ "$(_breaker_gate 30)" = "PROBE" ]   || { echo "probe PR lost its claim across ticks"; exit 1; }
  # Probe yields a real verdict → CLOSE, normal dispatch resumes for everyone.
  _breaker_record_ok
  read -r st _ _ _ < "$WT/.agent-watch-infra-breaker"
  [ "$st" = "closed" ] || { echo "probe verdict did not close (state=$st)"; exit 1; }
  [ "$(_breaker_gate 31)" = "PASS" ] || { echo "dispatch did not resume after recovery"; exit 1; }
  grep -q '"event":"infra_breaker_close"' "$JOURNAL_FILE" || { echo "recovery not journaled"; exit 1; }

  # Re-open, probe again, but this time the probe DIES → RE-OPEN (fresh cooldown), block everyone.
  _breaker_record_infra; _breaker_record_infra
  sleep 3
  [ "$(_breaker_gate 40)" = "PROBE" ] || { echo "probe not re-admitted after re-open"; exit 1; }
  _breaker_record_infra   # the probe died again
  read -r st _ _ pb < "$WT/.agent-watch-infra-breaker"
  [ "$st" = "open" ] || { echo "probe death did not re-open (state=$st)"; exit 1; }
  [ "$(_breaker_gate 40)" = "BLOCKED" ] || { echo "not blocked after probe re-open"; exit 1; }
  exit 0
) || fail "(4) half-open probe / recovery / re-open behaviour wrong"
ok "(4) HALF-OPEN admits exactly ONE probe; a verdict CLOSEs it, a death RE-OPENs it (fresh cooldown)"

# ── (5) Review-gate integration: a planted non-verdict result counts; a real verdict resets ───────
(
  WT="$T/gate"; source_watcher "$WT" 3 300
  step_planted() {   # <pr> <sha> <verdict-line> → run the SHIPPED review gate over a planted result
    local pr="$1" sha="$2" line="$3" rf; rf="$(_review_result_file "$pr" "$sha")"
    printf '%s\n' "$line" > "$rf.tmp.$$"; mv "$rf.tmp.$$" "$rf"
    _review_gate_step "$pr" "slug-$pr" "$sha"
  }
  # Three distinct PRs whose reviewers die with no verdict (INFRA-FAIL) → three infra deaths → OPEN.
  [ "$(step_planted 50 s50 'REVIEW: INFRA-FAIL')" = "RETRY" ] || { echo "1st planted infra not RETRY"; exit 1; }
  [ "$(step_planted 51 s51 'REVIEW: INFRA-FAIL')" = "RETRY" ] || { echo "2nd planted infra not RETRY"; exit 1; }
  step_planted 52 s52 'REVIEW: INFRA-FAIL' >/dev/null
  read -r st _ _ _ < "$WT/.agent-watch-infra-breaker"
  [ "$st" = "open" ] || { echo "review-gate infra deaths did not open the breaker (state=$st)"; exit 1; }
  # A real BLOCK verdict through the SAME shipped gate resets/closes it (proves the gate distinguishes).
  [ "$(step_planted 53 s53 'REVIEW: BLOCK — rule: r | why: w | location: l')" = "BLOCK" ] \
    || { echo "planted BLOCK not collected as BLOCK"; exit 1; }
  read -r st _ _ _ < "$WT/.agent-watch-infra-breaker"
  [ "$st" = "closed" ] || { echo "a real BLOCK verdict did not close the breaker (state=$st)"; exit 1; }
  exit 0
) || fail "(5) review-gate integration: INFRA death vs real verdict mis-classified"
ok "(5) review gate: planted INFRA-FAIL deaths OPEN the breaker; a planted BLOCK verdict CLOSEs it"

echo "ALL PASS ($PASS checks) — test-infra-breaker.sh"
