#!/usr/bin/env bash
# test-prompt-order.sh — prompt-cache-aware ORDERING lint for every prompt-generating script.
#
# WHY: Anthropic's prompt cache keys on the longest shared PREFIX (5-minute TTL). To let many
# close-in-time agent prompts share a cached prefix, the STABLE preamble (standing workflow rules /
# reviewer checklist) MUST LEAD and the UNIQUE per-invocation content (caller task, PR number,
# branch slug, private result-file path) MUST TRAIL. If the unique content leads, every prompt has a
# different prefix and NOTHING caches.
#
# This is a STATIC SOURCE lint (no herdr/claude/network): it parses each prompt-assembling line and
# asserts, for each prompt string, that the stable marker appears BEFORE any unique token.
#
# Covers all three prompt-generating paths named in the spec:
#   • scripts/herd/herd-quick.sh   — builder SPEC = $RULES (stable) … $TASK (unique)
#   • scripts/herd/herd-feature.sh — builder SPEC = $RULES (stable) … $TASK (unique)
#   • scripts/herd/herd-review.sh  — reviewer TASK and AGENT_TASK: checklist/rules preamble (stable)
#                                    … PR number / slug / result-file (unique) trailing
#
# Run:  bash tests/test-prompt-order.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="$HERE/../scripts/herd"
QUICK="$SCRIPTS/herd-quick.sh"
FEATURE="$SCRIPTS/herd-feature.sh"
REVIEW="$SCRIPTS/herd-review.sh"

fail(){ echo "FAIL: $1" >&2; exit 1; }
for f in "$QUICK" "$FEATURE" "$REVIEW"; do [ -f "$f" ] || fail "missing prompt-generating script: $f"; done

# idx_of "$haystack" "$needle" → byte index of first occurrence, or -1 if absent.
idx_of(){ local h="$1" n="$2" pre="${1%%"$2"*}"; if [ "$pre" = "$h" ]; then echo -1; else echo "${#pre}"; fi; }

# assert_before <label> <segment> <stable-marker> <unique-token...>
# Asserts the stable marker is present and every listed unique token, when present, appears AFTER it.
assert_before(){
  local label="$1" seg="$2" stable="$3"; shift 3
  local s; s="$(idx_of "$seg" "$stable")"
  [ "$s" -ge 0 ] || fail "$label: stable marker '$stable' not found in the prompt — cannot lead with it"
  local u ui
  for u in "$@"; do
    ui="$(idx_of "$seg" "$u")"
    [ "$ui" -lt 0 ] && continue                              # token absent in this prompt → nothing to order
    [ "$ui" -gt "$s" ] || fail "$label: unique token '$u' (idx $ui) appears BEFORE stable marker '$stable' (idx $s) — breaks the shared cache prefix"
  done
}

# ── Lanes: SPEC must be "$RULES" (stable) THEN "$TASK" (unique) in the non-empty-task branch ──────
# Extract just the then-branch SPEC value so the `[ -n "$TASK" ]` guard's own $TASK doesn't count.
lane_check(){
  local script="$1" name; name="$(basename "$script")"
  local line; line="$(grep -E 'then[[:space:]]+SPEC=' "$script" | head -1)"
  [ -n "$line" ] || fail "$name: no 'then SPEC=' assignment found (prompt assembly moved?)"
  local seg="${line#*then SPEC=}"; seg="${seg%%; else*}"    # isolate the SPEC value in the non-empty branch
  # $RULES (stable) must lead; $TASK (unique caller content) must trail. Match the exact variable
  # references so unrelated substrings can't spoof an ordering.
  assert_before "$name SPEC" "$seg" '$RULES' '$TASK'
  echo "  ok: $name — builder SPEC leads with \$RULES, trails with \$TASK"
}
lane_check "$QUICK"
lane_check "$FEATURE"

# ── Reviewer: TASK and AGENT_TASK must lead with the stable checklist/rules and trail with the ────
#    unique per-PR content (PR number, branch slug, private result-file path).
review_check(){
  local var="$1"
  local line; line="$(grep -E "^${var}=" "$REVIEW" | head -1)"
  [ -n "$line" ] || fail "herd-review.sh: no '^${var}=' assignment found (prompt assembly moved?)"
  local seg="${line#*=}"                                    # the assigned prompt value
  # ${CHECKLIST_TEXT} is the stable risk checklist that anchors the shared preamble; ${PR}, ${SLUG}
  # and the per-PR ${_agent_result_file} path are the unique tokens that must all trail it. Match the
  # exact ${…} references — bare 'PR' would false-match 'PRE-MERGE' in the stable preamble.
  assert_before "herd-review.sh $var" "$seg" '${CHECKLIST_TEXT}' '${PR}' '${SLUG}' '${_agent_result_file}'
  echo "  ok: herd-review.sh — $var leads with the stable checklist/rules, trails with PR/slug/result-file"
}
review_check TASK
review_check AGENT_TASK

echo "ALL PASS"
