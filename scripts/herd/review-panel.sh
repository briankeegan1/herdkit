#!/usr/bin/env bash
# review-panel.sh — THE shared resolver for the MIXED-VENDOR review panel (HERD-276).
#
# WHY THIS FILE EXISTS
# -------------------
# Two seams shipped independently and never met:
#   • REVIEW_PANEL (HERD-107) fans out N concurrent read-only reviewer passes over the SAME diff —
#     but every panelist runs on the ONE $REVIEW_MODEL, so N eyes share one model's blind spots.
#   • Driver-qualified MODEL refs (HERD-151, '<driver>:<model>') let any role pin a RUNTIME + model,
#     and templates/drivers/{codex,grok,stub}.driver exist.
# REVIEW_PANEL_MODELS wires them together: a space-separated list of (optionally driver-qualified)
# refs, ONE PANELIST PER REF, each dispatched through its own runtime via herd_driver_oneshot_exec.
# Independent vendors have independent blind spots, so a mixed panel raises real-bug recall in a way
# N copies of one model cannot.
#
# The second half of the wiring is the VERDICT MERGE POLICY. With one model, "any BLOCK blocks" is the
# only sane fold. With a mixed panel an operator may want a different bar, so REVIEW_PANEL_POLICY picks
# one — and this file is the ONE place any enforcement surface resolves it. An inline re-implementation
# in the local-review path vs the PR path is exactly how a gate starts merging what another surface
# would have blocked (the merge-policy.sh lesson, HERD-210).
#
# THE POLICIES (evaluated over the DISPATCHED panelists; a panelist that reached no PASS/BLOCK verdict
# — a dead runtime, a missing driver binary, a crash — is NON-REPORTING, never a vote):
#
#   any-block   (default; today's behavior, byte-identical)
#               >=1 BLOCK          → BLOCK
#               else >=1 PASS      → PASS
#               else               → INFRA   (every panelist died: retry, never a cached BLOCK)
#
#   all-pass    (strictest: demands a clean sweep — an unreachable vendor is a COVERAGE GAP, not a pass)
#               >=1 BLOCK          → BLOCK
#               else every dispatched panelist PASSed → PASS
#               else               → INFRA   (a silent panelist means the bar was never met)
#
#   majority    (a lone dissenting vendor no longer blocks; ties break FAIL-SAFE toward BLOCK)
#               no reporting panelist → INFRA
#               blocks >= passes      → BLOCK
#               else                  → PASS
#
# INVARIANTS this file guarantees, and tests/test-review-panel-models.sh locks:
#   • DORMANT: REVIEW_PANEL_MODELS unset ⇒ no refs ⇒ callers keep their single-model panel, and the
#     default policy any-block folds verdicts exactly as the pre-HERD-276 _combine_verdicts did.
#   • NEVER A FALSE BLOCK: a non-reporting panelist can only ever move a verdict toward INFRA (retry),
#     never toward BLOCK. A missing driver binary is an INFRASTRUCTURE fact, not a correctness finding.
#   • FAIL-STRICT ON A TYPO: an unrecognized REVIEW_PANEL_POLICY resolves to any-block — the SAFEST
#     policy (most likely to block) — never to the laxest. A fat-fingered key can never widen the gate.
#
# Pure library: sourcing it only defines functions. Reads files, writes nothing. Bash 3.2 clean.
# Sourced by scripts/herd/herd-review.sh (both enforcement surfaces) and bin/herd (eager `config set`
# ref validation). Depends on driver.sh's herd_model_resolve for ref validation — the caller sources it.

# HERD_REVIEW_PANEL_REASON — set by herd_review_merge_verdicts on an INFRA fold to the one-line WHY
# (which the caller puts in its REVIEW: INFRA-FAIL line). Cleared on every call.
HERD_REVIEW_PANEL_REASON=""

# herd_review_panel_refs [raw] — echo the panel's model refs, ONE PER LINE, in declaration order.
# Reads $REVIEW_PANEL_MODELS when [raw] is omitted. Whitespace-separated; blank/unset → no output
# (the DORMANT case: zero refs means "no mixed-vendor panel", not "a panel of zero").
herd_review_panel_refs() {
  local raw="${1-${REVIEW_PANEL_MODELS:-}}" r
  [ -n "$raw" ] || return 0
  # Intentional word-splitting: the key's value shape IS a whitespace-separated ref list.
  # shellcheck disable=SC2086
  for r in $raw; do printf '%s\n' "$r"; done
}

# herd_review_panel_ref_count [raw] — how many panelists the ref list declares (0 when dormant).
herd_review_panel_ref_count() {
  local n; n="$(herd_review_panel_refs "$@" | grep -c . 2>/dev/null || true)"
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  printf '%s' "$n"
}

# herd_review_panel_policy — echo the effective verdict merge policy: any-block | all-pass | majority.
# Recognized value wins verbatim; empty/unset OR an unrecognized value (a typo) → any-block, the
# fail-safe default. Case-SENSITIVE, mirroring merge-policy.sh's contract.
herd_review_panel_policy() {
  case "${REVIEW_PANEL_POLICY:-}" in
    any-block|all-pass|majority) printf '%s' "$REVIEW_PANEL_POLICY" ;;
    *)                           printf 'any-block' ;;
  esac
}

# herd_review_panel_policy_is_typo — success iff REVIEW_PANEL_POLICY is set to something non-empty
# that is NOT a recognized policy (so a caller can journal/warn once about a silently-corrected key).
herd_review_panel_policy_is_typo() {
  case "${REVIEW_PANEL_POLICY:-}" in
    '') return 1 ;;
    any-block|all-pass|majority) return 1 ;;
    *) return 0 ;;
  esac
}

# herd_review_panel_verdict_line <file> — echo the LAST canonical 'REVIEW: PASS|BLOCK' line in <file>
# (leading whitespace stripped), or nothing + return 1 when the file holds no verdict at all. An
# 'REVIEW: INFRA-FAIL' line is deliberately NOT a verdict: a panelist that could not run has no vote.
herd_review_panel_verdict_line() {
  local f="${1:-}" line
  [ -f "$f" ] || return 1
  line="$(grep -E '^[[:space:]]*REVIEW: (PASS|BLOCK)' "$f" 2>/dev/null | tail -1 | sed -E 's/^[[:space:]]+//')"
  [ -n "$line" ] || return 1
  printf '%s' "$line"
}

# herd_review_merge_verdicts <policy> <member-file>… — THE resolver. Folds the per-panelist verdict
# files into ONE verdict line under <policy> and echoes it. Every enforcement surface calls THIS.
#
#   return 0 + a 'REVIEW: PASS…'  line   → the merge bar was met
#   return 1 + a 'REVIEW: BLOCK…' line   → a genuine, reviewer-backed correctness refusal
#   return 2 + NO output                 → INFRA: no verdict could be folded. $HERD_REVIEW_PANEL_REASON
#                                          carries the why. The caller reports INFRA-FAIL and RETRIES —
#                                          it must never cache this against the sha as a BLOCK.
#
# Determinism: members are folded in ARGUMENT order, so the FIRST BLOCK (and, absent one, the FIRST
# PASS) is the line echoed. Callers pass a sorted glob, so the same panel folds to the same bytes.
# Pure: reads the files, mutates only $HERD_REVIEW_PANEL_REASON.
herd_review_merge_verdicts() {
  local policy="${1:-any-block}"; shift 2>/dev/null || true
  HERD_REVIEW_PANEL_REASON=""

  local f line block="" pass="" dispatched=0 blocks=0 passes=0
  for f in "$@"; do
    dispatched=$((dispatched+1))
    line="$(herd_review_panel_verdict_line "$f" 2>/dev/null)" || continue
    case "$line" in
      "REVIEW: BLOCK"*)
        blocks=$((blocks+1)); [ -z "$block" ] && block="$line" ;;
      "REVIEW: PASS"|"REVIEW: PASS "*)
        passes=$((passes+1));  [ -z "$pass" ]  && pass="$line"  ;;
    esac
  done
  local reporting=$((blocks+passes)) silent=$((dispatched-blocks-passes))

  # A BLOCK is a genuine finding under EVERY policy except majority, where it must out-vote the
  # PASSes (ties fail safe toward BLOCK). Nothing below can turn a BLOCK into a PASS by adding
  # panelists that failed to report — silence is never a vote.
  case "$policy" in
    all-pass)
      if [ "$blocks" -gt 0 ]; then printf '%s' "$block"; return 1; fi
      if [ "$dispatched" -gt 0 ] && [ "$passes" -eq "$dispatched" ]; then printf '%s' "$pass"; return 0; fi
      HERD_REVIEW_PANEL_REASON="policy all-pass needs every one of ${dispatched} panelist(s) to PASS; only ${passes} reported PASS (${silent} reached no verdict) — infrastructure gap, not a block"
      return 2
      ;;
    majority)
      if [ "$reporting" -eq 0 ]; then
        HERD_REVIEW_PANEL_REASON="policy majority: none of ${dispatched} panelist(s) reached a verdict — infrastructure failure, not a block"
        return 2
      fi
      if [ "$blocks" -ge "$passes" ]; then printf '%s' "$block"; return 1; fi
      printf '%s' "$pass"; return 0
      ;;
    *)  # any-block (default, and the fail-safe landing spot for a typo'd policy)
      if [ "$blocks" -gt 0 ]; then printf '%s' "$block"; return 1; fi
      if [ "$passes" -gt 0 ]; then printf '%s' "$pass";  return 0; fi
      HERD_REVIEW_PANEL_REASON="none of ${dispatched} panelist(s) reached a verdict — infrastructure failure, not a block"
      return 2
      ;;
  esac
}

# herd_review_panel_validate_refs [raw] — EAGER validation for `herd config set REVIEW_PANEL_MODELS`.
# Every ref must resolve through herd_model_resolve (driver.sh): a bare model is fine (default driver),
# a '<driver>:<model>' ref must name a SHIPPED templates/drivers/<driver>.driver and a non-empty model.
# Returns 0 when every ref resolves. On the first bad ref: prints herd_model_resolve's LOUD one-line
# error to stderr (plus which panelist position failed) and returns 1 — so a typo is refused at WRITE
# time rather than surfacing hours later as a dead panelist mid-gate. An EMPTY list is valid (dormant).
# Fail-soft on a missing resolver: with driver.sh unsourced we cannot judge, so we accept (never a
# false refusal) — callers that care source driver.sh first.
herd_review_panel_validate_refs() {
  local raw="${1-${REVIEW_PANEL_MODELS:-}}" ref i=0 rc=0
  [ -n "$raw" ] || return 0
  command -v herd_model_resolve >/dev/null 2>&1 || return 0
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    i=$((i+1))
    if ! herd_model_resolve "$ref" >/dev/null; then
      printf '❌ herd: REVIEW_PANEL_MODELS panelist %s (%s) is not a usable model ref (see the error above).\n' \
        "$i" "'$ref'" >&2
      rc=1
      break
    fi
  done <<EOF
$(herd_review_panel_refs "$raw")
EOF
  return "$rc"
}
