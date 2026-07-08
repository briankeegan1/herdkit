#!/usr/bin/env bash
# herd-advise.sh "<question>" [context…] — a MID-FLIGHT strong-model ADVISOR a builder calls for a
# SECOND OPINION on a hard decision, WITHOUT escalating its whole lane to a stronger model tier.
#
# WHY THIS EXISTS (HERD-101): a builder running on a cheaper tier (MODEL_QUICK, or a sonnet
# MODEL_FEATURE) sometimes hits ONE genuinely hard judgment call — an API shape, a tricky invariant,
# a "which of these two designs is safer" fork — where a stronger model's read is worth having. The
# blunt tool is to re-spawn the whole lane on Opus, which pays the strong tier for the ENTIRE task.
# This is the scalpel: a ONE-SHOT query to a strong advisor model whose advice the builder reads and
# then keeps going on its own tier. It is a pull, not a push — the builder decides when a decision is
# hard enough to ask.
#
# CONTRACT:
#   • ONE-SHOT: a single `claude -p` query against the advisor model (ADVISE_MODEL, default
#     $MODEL_ADVISE, which itself defaults to the $MODEL_FEATURE / Opus tier). The advice is printed
#     to STDOUT for the builder to read. No agent, no herdr tab, no repo mutation, no journal write.
#   • ADDITIVE + FAIL-SOFT: an absent advisor model or a failed/empty model call degrades GRACEFULLY —
#     a clear one-line "unavailable" message on stdout and exit 0, NEVER a hard error / stack trace.
#     A builder that never calls it sees byte-identical behavior; nothing else in the engine reads it.
#   • CONTEXT is OPTIONAL: any args after the question are appended verbatim as context, and — when
#     stdin is not a terminal — piped stdin is appended too (so a builder can pipe a diff/snippet in).
#
# Usage:
#   herd advise "<question>" [context…]
#   some-command | herd advise "<question>"
#
# Overrides (env): ADVISE_MODEL (advisor model id), HERD_CLAUDE_FLAGS (claude flags).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/herd-config.sh"

_advise_usage() {
  printf 'usage: herd advise "<question>" [context…]   (extra context may also be piped on stdin)\n' >&2
}

# ── arg parse ────────────────────────────────────────────────────────────────
# The FIRST positional is the question; every remaining positional is inline context. -h/--help
# prints usage. A missing/empty question is the one HARD error (a usage mistake, not a degraded run).
QUESTION=""
CONTEXT_ARGS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) _advise_usage; exit 0 ;;
    --) shift; break ;;
    -?*) printf 'herd advise: unknown flag %s\n' "$1" >&2; _advise_usage; exit 2 ;;
    *)  if [ -z "$QUESTION" ]; then QUESTION="$1"; else CONTEXT_ARGS+=("$1"); fi ;;
  esac
  shift
done
# Anything after a literal `--` is also inline context (lets a builder pass leading-dash context).
while [ "$#" -gt 0 ]; do CONTEXT_ARGS+=("$1"); shift; done

if [ -z "${QUESTION//[[:space:]]/}" ]; then
  printf 'herd advise: no question given.\n' >&2
  _advise_usage
  exit 2
fi

# ── assemble optional context (inline args + piped stdin) ─────────────────────
CONTEXT=""
if [ "${#CONTEXT_ARGS[@]}" -gt 0 ]; then
  CONTEXT="$(printf '%s\n' "${CONTEXT_ARGS[@]}")"
fi
# Append piped stdin only when stdin is NOT a terminal — reading a tty here would hang the builder.
if [ ! -t 0 ]; then
  _stdin="$(cat 2>/dev/null || true)"
  if [ -n "${_stdin//[[:space:]]/}" ]; then
    CONTEXT="${CONTEXT:+$CONTEXT$'\n'}$_stdin"
  fi
fi

# ── resolve the advisor model + fail-soft degrade helper ──────────────────────
# ADVISE_MODEL env wins; else the config-resolved MODEL_ADVISE (which herd-config.sh defaults to the
# MODEL_FEATURE / Opus tier). Never escalates the caller's lane — this is a separate, one-off query.
ADVISE_MODEL="${ADVISE_MODEL:-${MODEL_ADVISE:-}}"
CLAUDE_FLAGS="${HERD_CLAUDE_FLAGS:---dangerously-skip-permissions}"

# _advise_degrade <reason> — print a CLEAR, machine-greppable unavailable line and exit 0 (fail-soft).
# The builder reads this on stdout exactly where it would have read advice, so an unavailable advisor
# never crashes the caller — it just tells the builder to proceed on its own judgment.
_advise_degrade() {
  printf 'herd advise: unavailable — %s. Proceed on your own judgment.\n' "$1"
  exit 0
}

[ -n "${ADVISE_MODEL//[[:space:]]/}" ] || _advise_degrade "no advisor model configured (MODEL_ADVISE is empty)"
command -v claude >/dev/null 2>&1 || _advise_degrade "the 'claude' CLI is not on PATH"

# ── one-shot advisor query ────────────────────────────────────────────────────
PROMPT="You are a STRONG-MODEL ADVISOR giving a coding agent a CONCISE second opinion on a hard
decision it hit mid-task. It is running on a cheaper model tier and pulled you in for THIS one call
only — it will act on your answer itself, so be direct and decision-oriented, not exhaustive.

Answer the question below. Lead with a clear recommendation, then the KEY reasoning and the main
risk or tradeoff. If the question is underspecified, state the assumption you are answering under
rather than asking a follow-up (this is one-shot; there is no back-and-forth). Do not ask to see the
repo or run commands — reason from what you are given.

QUESTION:
$QUESTION"
if [ -n "${CONTEXT//[[:space:]]/}" ]; then
  PROMPT="$PROMPT

CONTEXT PROVIDED BY THE BUILDER:
$CONTEXT"
fi

# Single-shot, non-interactive. Capture stdout; a non-zero exit OR empty output is a fail-soft
# degrade, never a hard error. stderr from claude is dropped so a transient warning cannot corrupt
# the advice the builder reads.
# shellcheck disable=SC2086  # $CLAUDE_FLAGS intentionally word-splits (mirrors the lanes' usage)
advice="$(claude -p "$PROMPT" --model "$ADVISE_MODEL" $CLAUDE_FLAGS 2>/dev/null)" || advice=""

if [ -z "${advice//[[:space:]]/}" ]; then
  _advise_degrade "the advisor model call returned no advice (model=$ADVISE_MODEL)"
fi

printf '%s\n' "$advice"
