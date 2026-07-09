#!/usr/bin/env bash
# posture-lint.sh — the CONFIG-POSTURE DOCTOR (HERD-154): a deterministic, no-LLM, report-only lint
# behind `herd doctor --posture`. Custom .herd/config setups deviate SILENTLY — an operator can wire
# a knob combination that CONFLICTS or DEAD-ENDS (a lever that is superseded/ignored by another key),
# or land on an effective posture that NO test/sim ever exercises, and nothing tells them. This helper
# is what tells them, in two passes:
#
#   (1) COHERENCE LINT — flag knob combinations that conflict or dead-end, each with a fix hint. Every
#       rule is DERIVED from a documented supersede/ignored-when relationship in the capabilities
#       manifest (templates/capabilities.tsv), e.g. "WATCHER_AUTOMERGE … superseded by MERGE_POLICY
#       when set", "WATCHER_OWNER … Ignored under the default WATCHER_SCOPE=mine". Purely mechanical:
#       an "explicitly set" probe of the config file(s) crossed with the effective value of the key
#       that supersedes/gates it.
#
#   (2) SIM-PROVEN HONESTY LINE — report whether the operator's EFFECTIVE posture combo (merge policy,
#       human-verify policy, push gate, PR flow, custom steps) equals one of the CANONICAL postures
#       (templates/postures.tsv) that the posture-matrix sim proves (scripts/herd/sim/
#       sandbox-posture-matrix.sh, driven hermetically by tests/test-sandbox-posture-matrix.sh — the
#       conformance proof_ref for templates/postures.tsv). A match ⇒ your combo is exercised; a miss ⇒
#       it is a silent, never-exercised custom posture, and the closest canonical posture + the keys
#       you deviate on are named.
#
# CONVENTIONS: fail-soft, REPORT-ONLY. `herd doctor --posture` NEVER blocks a run and always exits 0 —
# it is an advisory, not a gate. A missing postures.tsv / posture-lib.sh degrades the honesty line to a
# dim note; it never errors. Human-facing output only (no machine parses it), so the ✓/⚠ marks are safe.
#
# DISTINCT from HERD-161 (config manifest self-enforcement — does every key exist?) and HERD-153 (the
# posture sim matrix itself): this reads BOTH to lint an operator's LIVE config, it does not define
# postures or run the sim.
#
# Entry point: herd_doctor_posture   (cmd_doctor sources this and calls it under `herd doctor --posture`).
# Assumes the caller has already sourced herd-config.sh (so the effective config is in the environment)
# and herd-preflight.sh (for _herd_doctor_find_config / _herd_brand). Bash 3.2 clean; no jq, no network.

_posture_lint_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# _posture_is_set <key> <file...> — return 0 iff KEY is EXPLICITLY assigned (KEY= or `export KEY=`) in
# any of the given shell-sourced config files. This is how we distinguish an operator override from an
# engine default: herd-config.sh has already applied defaults to the environment, so the environment
# alone cannot tell "operator set MERGE_POLICY=auto" from "loader defaulted it". Skips blanks/comments.
_posture_is_set() {
  local key="$1"; shift
  local f
  for f in "$@"; do
    [ -n "$f" ] && [ -f "$f" ] || continue
    grep -qE "^[[:space:]]*(export[[:space:]]+)?${key}=" "$f" && return 0
  done
  return 1
}

# _posture_effective_merge_policy — resolve the EFFECTIVE merge policy exactly as agent-watch.sh /
# cmd_reload do: MERGE_POLICY (auto|approve|observe) wins; else the legacy WATCHER_AUTOMERGE boolean
# derives it (false/no/off/0 → approve, anything else → auto). This is the single seam the doctor and
# the watcher must agree on, so the honesty line reflects what the watcher will ACTUALLY do.
_posture_effective_merge_policy() {
  case "${MERGE_POLICY:-}" in
    auto|approve|observe) printf '%s' "$MERGE_POLICY" ;;
    *)
      case "${WATCHER_AUTOMERGE:-true}" in
        false|no|off|0) printf 'approve' ;;
        *)              printf 'auto' ;;
      esac ;;
  esac
}

# _posture_steps_active <steps-file> — return 0 iff the project has a NON-EMPTY .herd/steps.tsv (at
# least one non-blank, non-comment row): the operator has wired custom pipeline steps. Mirrors the
# STEPS_PROFILE=<id> dimension the custom-steps canonical posture carries.
_posture_steps_active() {
  local f="$1"
  [ -n "$f" ] && [ -f "$f" ] || return 1
  grep -qE '^[[:space:]]*[^#[:space:]]' "$f"
}

# _posture_op_tuple — the operator's EFFECTIVE posture, as a stable, field-labelled 5-tuple joined by
# '|'. The five fields are exactly the dimensions the canonical postures vary over (templates/
# postures.tsv): merge policy, human-verify policy, push gate, PR flow, custom steps present. Each
# reads the effective value (env, with the same inline defaults the consumers use).
_posture_op_tuple() {
  local merge hv push flow steps sf
  merge="$(_posture_effective_merge_policy)"
  hv="${HUMAN_VERIFY_POLICY:-hold}"
  push="${PUSH_GATE:-}"; [ -n "$push" ] || push="none"
  flow="${PR_FLOW:-direct}"
  sf="${HERD_STEPS_FILE:-${PROJECT_ROOT:-}/.herd/steps.tsv}"
  if _posture_steps_active "$sf"; then steps="yes"; else steps="no"; fi
  printf 'merge=%s|hv=%s|push=%s|flow=%s|steps=%s' "$merge" "$hv" "$push" "$flow" "$steps"
}

# _posture_canonical_tuple <name> — the same 5-tuple for a CANONICAL posture: start from the engine
# defaults (an unlisted key falls back to its default, per postures.tsv's contract) and overlay the
# posture's KEY=VALUE bundle. STEPS_PROFILE=<id> is not a config key — it maps to steps=yes.
_posture_canonical_tuple() {
  local name="$1" kv k v
  local merge="auto" hv="hold" push="none" flow="direct" steps="no"
  for kv in $(posture_keys "$name" 2>/dev/null); do
    k="${kv%%=*}"; v="${kv#*=}"
    case "$k" in
      MERGE_POLICY)        merge="$v" ;;
      HUMAN_VERIFY_POLICY) hv="$v" ;;
      PUSH_GATE)           push="$v"; [ -n "$push" ] || push="none" ;;
      PR_FLOW)             flow="$v" ;;
      STEPS_PROFILE)       steps="yes" ;;
    esac
  done
  printf 'merge=%s|hv=%s|push=%s|flow=%s|steps=%s' "$merge" "$hv" "$push" "$flow" "$steps"
}

# _posture_tuple_pretty <tuple> — render a 5-tuple as a human-readable one-liner.
_posture_tuple_pretty() {
  local t="$1"
  printf 'merge-policy=%s, human-verify=%s, push-gate=%s, pr-flow=%s, custom-steps=%s' \
    "$(_posture_tuple_field "$t" merge)" \
    "$(_posture_tuple_field "$t" hv)" \
    "$(_posture_tuple_field "$t" push)" \
    "$(_posture_tuple_field "$t" flow)" \
    "$(_posture_tuple_field "$t" steps)"
}

# _posture_tuple_field <tuple> <key> — pull one labelled field's value out of a '|'-joined tuple.
_posture_tuple_field() {
  local t="$1" key="$2" seg
  local IFS='|'
  for seg in $t; do
    case "$seg" in "$key="*) printf '%s' "${seg#*=}"; return 0 ;; esac
  done
}

# ── the coherence-lint rules — each derived from a documented capabilities.tsv relationship ──────────
# A rule appends "<finding>\t<fix>" to $_POSTURE_FINDINGS (one per line) when the incoherent condition
# holds. cfg/local are the operator's config file(s) for the "explicitly set" probe.
_posture_add_finding() { _POSTURE_FINDINGS="${_POSTURE_FINDINGS}${1}"$'\t'"${2}"$'\n'; }

_posture_coherence_rules() {
  local cfg="$1" local="$2"
  _POSTURE_FINDINGS=""

  # R1 — WATCHER_AUTOMERGE is "superseded by MERGE_POLICY when set" (capabilities.tsv). Both explicitly
  #      set ⇒ the legacy lever is dead weight; if it IMPLIES the opposite of the effective policy it is
  #      an outright silent CONTRADICTION (the operator likely believes the legacy lever still applies).
  if _posture_is_set MERGE_POLICY "$cfg" "$local" && _posture_is_set WATCHER_AUTOMERGE "$cfg" "$local"; then
    local eff wa_implies
    eff="$(_posture_effective_merge_policy)"
    case "${WATCHER_AUTOMERGE:-true}" in false|no|off|0) wa_implies="approve" ;; *) wa_implies="auto" ;; esac
    if [ "$eff" != "$wa_implies" ]; then
      _posture_add_finding \
        "WATCHER_AUTOMERGE=${WATCHER_AUTOMERGE} CONTRADICTS MERGE_POLICY=${MERGE_POLICY}: the legacy lever implies '${wa_implies}', but MERGE_POLICY takes precedence, so the effective policy is '${eff}'." \
        "MERGE_POLICY wins — delete WATCHER_AUTOMERGE from .herd/config (it is read only when MERGE_POLICY is unset/empty)."
    else
      _posture_add_finding \
        "WATCHER_AUTOMERGE=${WATCHER_AUTOMERGE} is superseded by MERGE_POLICY=${MERGE_POLICY} (both set): the legacy lever is dead weight." \
        "Delete WATCHER_AUTOMERGE from .herd/config — MERGE_POLICY is the live merge lever."
    fi
  fi

  # R2 — WATCHER_OWNER is "Ignored under the default WATCHER_SCOPE=mine" (capabilities.tsv): it only
  #      binds team-mode auto-merge ownership (WATCHER_SCOPE=all).
  local scope="${WATCHER_SCOPE:-mine}"
  if _posture_is_set WATCHER_OWNER "$cfg" "$local" && [ "$scope" != "all" ]; then
    _posture_add_finding \
      "WATCHER_OWNER is set but WATCHER_SCOPE=${scope}: WATCHER_OWNER binds team-mode auto-merge ownership only under WATCHER_SCOPE=all, so here it has no effect." \
      "Set WATCHER_SCOPE=all to run team-mode auto-merge, or drop WATCHER_OWNER."
  fi

  # R3 — LOCAL_REVIEW_GLOB is "Ignored under LOCAL_REVIEW none/pre-pr" (capabilities.tsv): only
  #      LOCAL_REVIEW=risk-scoped consults it.
  local lr="${LOCAL_REVIEW:-none}"
  if [ -n "${LOCAL_REVIEW_GLOB:-}" ] && [ "$lr" != "risk-scoped" ]; then
    _posture_add_finding \
      "LOCAL_REVIEW_GLOB is set but LOCAL_REVIEW=${lr}: the glob is consulted ONLY under LOCAL_REVIEW=risk-scoped, so it is ignored." \
      "Set LOCAL_REVIEW=risk-scoped to scope the pre-PR review by that glob, or drop LOCAL_REVIEW_GLOB."
  fi

  # R4 — REVIEW_MODEL_CHEAP / REVIEW_ESCALATE_MAXFILES are each "ignored when REVIEW_ESCALATE_GLOB is
  #      blank" (capabilities.tsv): review tiering is off, so these levers never fire.
  if [ -z "${REVIEW_ESCALATE_GLOB:-}" ]; then
    local k
    for k in REVIEW_MODEL_CHEAP REVIEW_ESCALATE_MAXFILES; do
      if _posture_is_set "$k" "$cfg" "$local"; then
        _posture_add_finding \
          "${k} is set but REVIEW_ESCALATE_GLOB is blank: risk-tiered review is off, so ${k} has no effect." \
          "Set REVIEW_ESCALATE_GLOB to enable risk-tiered review, or drop ${k}."
      fi
    done
  fi

  # R5 — REVIEW_MODEL_DOCS is "ignored when DOCS_ONLY_GLOB is blank" (capabilities.tsv): the docs-only
  #      reviewer tier never triggers without a glob to match pure-docs diffs.
  if [ -z "${DOCS_ONLY_GLOB:-}" ] && _posture_is_set REVIEW_MODEL_DOCS "$cfg" "$local"; then
    _posture_add_finding \
      "REVIEW_MODEL_DOCS is set but DOCS_ONLY_GLOB is blank: the docs-only reviewer tier never triggers, so it has no effect." \
      "Set DOCS_ONLY_GLOB to route pure-docs diffs to REVIEW_MODEL_DOCS, or drop it."
  fi
}

# ── herd_doctor_posture — the `herd doctor --posture` entry point. Report-only; always returns 0. ────
herd_doctor_posture() {
  local brand; brand="$(_herd_brand 2>/dev/null || printf 'herd')"
  printf '%s doctor --posture \xe2\x80\x94 config coherence + sim-proven honesty (deterministic, no-LLM, report-only)\n\n' "$brand"

  # Resolve the operator's config file(s) for the "explicitly set" probe (reuses the doctor's finder).
  local cfg="" local=""
  if command -v _herd_doctor_find_config >/dev/null 2>&1; then cfg="$(_herd_doctor_find_config)"; fi
  [ -n "$cfg" ] && local="$(dirname "$cfg")/config.local"

  # ── (1) COHERENCE LINT ────────────────────────────────────────────────────────────────────────
  printf 'Coherence (knob combinations that conflict or dead-end):\n'
  _posture_coherence_rules "$cfg" "$local"
  if [ -z "$_POSTURE_FINDINGS" ]; then
    printf '  \xe2\x9c\x93 no incoherent knob combinations detected\n'
  else
    local finding fix
    while IFS=$'\t' read -r finding fix; do
      [ -n "$finding" ] || continue
      printf '  \xe2\x9a\xa0 %s\n' "$finding"
      printf '      fix: %s\n' "$fix"
    done <<< "$_POSTURE_FINDINGS"
  fi

  # ── (2) SIM-PROVEN HONESTY LINE ───────────────────────────────────────────────────────────────
  printf '\nSim-proven honesty (is your effective posture exercised by a test/sim?):\n'
  # Load the canonical-posture reader; degrade soft if it or the table is unavailable.
  local plib="$_posture_lint_here/sim/posture-lib.sh"
  if [ ! -f "$plib" ]; then
    printf '  \xe2\x9a\xa0 posture table reader not found (%s) \xe2\x80\x94 skipping the honesty check\n' "$plib"
    printf '\ndoctor --posture: report-only \xe2\x80\x94 advisory, never blocks a run.\n'
    return 0
  fi
  # shellcheck source=/dev/null
  . "$plib"
  local pfile; pfile="$(posture_file 2>/dev/null || true)"
  if [ -z "$pfile" ] || [ ! -f "$pfile" ]; then
    printf '  \xe2\x9a\xa0 canonical postures table not found (%s) \xe2\x80\x94 skipping the honesty check\n' "${pfile:-templates/postures.tsv}"
    printf '\ndoctor --posture: report-only \xe2\x80\x94 advisory, never blocks a run.\n'
    return 0
  fi

  local op_tuple match p ct
  op_tuple="$(_posture_op_tuple)"
  match=""
  for p in $(posture_names); do
    ct="$(_posture_canonical_tuple "$p")"
    if [ "$ct" = "$op_tuple" ]; then match="$p"; break; fi
  done

  if [ -n "$match" ]; then
    printf '  \xe2\x9c\x93 your effective posture (%s) matches the '\''%s'\'' posture\n' "$(_posture_tuple_pretty "$op_tuple")" "$match"
    printf '      \xe2\x86\x92 exercised by the posture-matrix sim: tests/test-sandbox-posture-matrix.sh (scripts/herd/sim/sandbox-posture-matrix.sh)\n'
    printf '        intent: %s\n' "$(posture_intent "$match")"
  else
    # Unexercised: find the closest canonical posture (most matching fields) and name the deviations.
    local best="" best_score="-1" best_diff=""
    for p in $(posture_names); do
      ct="$(_posture_canonical_tuple "$p")"
      local score=0 diff="" opv cpv fld
      for fld in merge hv push flow steps; do
        opv="$(_posture_tuple_field "$op_tuple" "$fld")"
        cpv="$(_posture_tuple_field "$ct" "$fld")"
        if [ "$opv" = "$cpv" ]; then score=$((score+1)); else diff="$diff $fld"; fi
      done
      if [ "$score" -gt "$best_score" ]; then best_score="$score"; best="$p"; best_diff="$diff"; fi
    done
    printf '  \xe2\x9a\xa0 your effective posture (%s) matches NO canonical posture\n' "$(_posture_tuple_pretty "$op_tuple")"
    printf '      \xe2\x86\x92 it is NOT exercised by the posture-matrix sim or any conformance proof \xe2\x80\x94 this custom combo deviates silently\n'
    if [ -n "$best" ]; then
      printf '      closest canonical posture: '\''%s'\'' (differs in:%s)\n' "$best" "$best_diff"
    fi
    printf '      fix: adopt a canonical posture (templates/postures.tsv), or add a posture row + a posture-matrix sim proof so your combo is covered.\n'
  fi

  printf '\ndoctor --posture: report-only \xe2\x80\x94 advisory, never blocks a run.\n'
  return 0
}
