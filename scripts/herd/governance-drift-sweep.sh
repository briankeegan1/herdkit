#!/usr/bin/env bash
# governance-drift-sweep.sh — periodic, ADVISORY governance-DRIFT sweep (HERD-125).
#
# The problem: `herd init`'s adoption pass (HERD-119) imports gates from an OPTIONAL CLAUDE.md /
# AGENTS.md into .herd/config ONCE, at onboarding. After that the two drift apart — someone edits the
# prose ("all changes must be reviewed by a human before they are pushed") but never runs the matching
# `herd config set PUSH_GATE human`, so the WRITTEN policy and the ENFORCED policy silently disagree.
# This sweep re-runs the adoption pass's EXACT extraction (scripts/herd/governance.sh — the same
# _gov_statements + _gov_match + templates/governance-map.tsv init used) and diffs the config-key rules
# CLAUDE.md/AGENTS.md would map to against the project's EFFECTIVE .herd/config. A difference is
# surfaced LOUDLY as an advisory; it is NEVER auto-applied.
#
# BINDING CONSTRAINTS (HERD-125):
#   • ADVISORY-ONLY — the sweep NEVER writes .herd/config, never runs `herd config set`, never edits
#     any tracked file. It only reports: a stdout advisory (the coordinator/watcher surface), one
#     `governance_drift` journal event per drifted key, and — only with --pr — one PR comment.
#   • FAIL-SOFT — a missing table, an unreadable source, no python/gh, a malformed config: every path
#     degrades to "nothing to report" rather than erroring. Governance prose is one optional input.
#   • SILENT WHEN IN SYNC OR NO PROSE — no CLAUDE.md/AGENTS.md, or every mapped rule already matching
#     the effective config, produces BYTE-IDENTICAL silence: zero stdout, zero journal, zero comment.
#
# Usage:
#   governance-drift-sweep.sh [--pr N]
#     (default)  re-extract the governance sources, diff mapped rules vs the effective config, and
#                PRINT a loud advisory per drifted key (+ journal a governance_drift event each).
#                Prints NOTHING and journals NOTHING when the prose and config are in sync.
#     --pr N     additionally post ONE consolidated advisory as a comment on PR #N (gh pr comment).
#
# Hermetic seams (default to the real sources/gh; the tests override them):
#   HERD_CONFIG_FILE      the .herd/config to read effective values from (herd-config.sh seam).
#   HERD_GOVERNANCE_MAP   the pattern table to map against (governance.sh seam).
#   HERD_GOV_SOURCES      SPACE-separated governance source files to scan, overriding the default
#                         "$PROJECT_ROOT/CLAUDE.md $PROJECT_ROOT/AGENTS.md".
#   JOURNAL_FILE          the journal to append governance_drift events to (journal.sh seam).
#   HERD_DRIFT_PR_COMMENT the `gh pr comment`-shaped command used by --pr (default: gh pr comment).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/herd-config.sh"    # PROJECT_ROOT + the project's EFFECTIVE config values, in scope below.
# shellcheck source=/dev/null
. "$HERE/journal.sh"        # journal_append (best-effort, silent).
# shellcheck source=/dev/null
. "$HERE/governance.sh"     # _gov_statements / _gov_match / _gov_map_file — the SHARED extraction.

# ── argument parsing ─────────────────────────────────────────────────────────
PR=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --pr)   shift; PR="${1:?--pr needs a PR number}" ;;
    --pr=*) PR="${1#--pr=}" ;;
    -h|--help) sed -n '2,35p' "$0"; exit 0 ;;
    *) echo "governance-drift-sweep: unknown argument: $1 (usage: governance-drift-sweep.sh [--pr N])" >&2; exit 2 ;;
  esac
  shift
done
case "$PR" in ''|*[!0-9]*) PR="" ;; esac   # non-numeric → no PR comment

# ── governance sources ───────────────────────────────────────────────────────
# The OPTIONAL prose inputs, in the same order the adoption pass reads them (CLAUDE.md then AGENTS.md).
# Each is scanned SEPARATELY so a drift line can name the FILE the rule was written in.
if [ -n "${HERD_GOV_SOURCES:-}" ]; then
  # shellcheck disable=SC2206  # deliberate word-split: HERD_GOV_SOURCES is a space-separated list
  GOV_SOURCES=( ${HERD_GOV_SOURCES} )
else
  GOV_SOURCES=( "$PROJECT_ROOT/CLAUDE.md" "$PROJECT_ROOT/AGENTS.md" )
fi

# _effective <KEY> — the project's EFFECTIVE config value for KEY, read from the vars herd-config.sh
# put in scope (the committed baseline + the config.local overlay + engine fallbacks). Unset → empty
# (the ${!k-} guard keeps this safe under `set -u`); an empty effective value is a real "off/default".
_effective() {
  local _k="$1"
  printf '%s' "${!_k-}"
}

# ── drift scan ───────────────────────────────────────────────────────────────
# For every governance source present, re-extract statements and map each (deterministic table only —
# no LLM in a background sweep) to a surface. Only the config-key surface is comparable to .herd/config;
# provisioning/hook rows are not effective-config gates and are ignored here. A mapped rule whose
# proposed value differs from the effective config is DRIFT. Accumulate as newline-delimited records,
# deduped by KEY=WANT (first evidence + source kept) so one rule is reported once.
#
# Fields are joined by US (0x1f), NOT a tab: the CUR field is EMPTY in the common "drifted from an
# unset/default" case, and tab is IFS-whitespace — `read` would collapse the empty field and shift
# every later column. US is non-whitespace, so empty fields survive intact. Governance prose + map
# labels are plain text and never contain US.
SEP=$'\x1f'
drift=""          # "<source>US<KEY>US<WANT>US<CUR>US<label>US<evidence>" per drifted (KEY,WANT)
seen=""           # "|KEY=WANT|" dedup ledger

_scan_source() {
  local src="$1" base stmt m surface target label pair key want cur
  base="$(basename "$src")"
  while IFS= read -r stmt; do
    [ -n "$stmt" ] || continue
    m="$(_gov_match "$stmt")" || true
    [ -n "$m" ] || continue
    surface="${m%%$'\t'*}"; m="${m#*$'\t'}"
    target="${m%%$'\t'*}"; label="${m#*$'\t'}"
    [ "$surface" = "config-key" ] || continue        # only config-key rules are effective-config gates
    # target is SPACE-separated KEY=VALUE pair(s); compare each against the effective config.
    for pair in $target; do
      key="${pair%%=*}"; want="${pair#*=}"
      { [ -n "$key" ] && [ "$key" != "$pair" ]; } || continue
      case "$seen" in *"|${key}=${want}|"*) continue ;; esac
      seen="${seen}|${key}=${want}|"
      cur="$(_effective "$key")"
      [ "$cur" != "$want" ] || continue              # already in sync → no drift, stay silent
      drift="${drift}${base}${SEP}${key}${SEP}${want}${SEP}${cur}${SEP}${label}${SEP}${stmt}"$'\n'
    done
  done <<< "$(_gov_statements "$src")"
}

for _src in "${GOV_SOURCES[@]}"; do
  _scan_source "$_src"
done

# In sync or no prose → BYTE-IDENTICAL silence: no stdout, no journal, no comment.
ndrift="$(printf '%s' "$drift" | grep -c . || true)"
[ "$ndrift" -gt 0 ] || exit 0

# ── report: stdout advisory + one journal event per drifted key ──────────────
# The advisory names each drifted KEY, what the prose now says, what the config enforces, and the
# exact `herd config set` to adopt — but is explicit that NOTHING is auto-applied.
{
  printf '⚠️  governance-drift-sweep: %d governance rule(s) in your CLAUDE.md/AGENTS.md have drifted from the effective .herd/config.\n' "$ndrift"
  printf '   ADVISORY ONLY — nothing is auto-applied. Adopt a rule with the shown `herd config set`, or update the prose.\n\n'
}
comment_body="$(printf '⚠️ **governance drift** — %d rule(s) in CLAUDE.md/AGENTS.md disagree with the effective `.herd/config` (advisory; nothing auto-applied):\n\n' "$ndrift")"

while IFS="$SEP" read -r src key want cur label evidence; do
  [ -n "$key" ] || continue
  cur_show="${cur:-<unset>}"
  printf '   • %s\n' "$label"
  printf '     %s now says: %s=%s\n' "$src" "$key" "$want"
  printf '     evidence: "%s"\n' "$evidence"
  printf '     config says: %s=%s\n' "$key" "$cur_show"
  printf '     run: herd config set %s %s   (advisory — NEVER auto-applied)\n\n' "$key" "$want"
  # One journal event per drifted key so `herd log`/an audit can see when + what drifted.
  journal_append governance_drift key "$key" claude_value "$want" config_value "$cur" \
    source "$src" label "$label" component sweep
  comment_body="${comment_body}$(printf -- '- **%s** — %s now says `%s=%s`, config says `%s=%s`. Adopt: `herd config set %s %s`' \
      "$label" "$src" "$key" "$want" "$key" "$cur_show" "$key" "$want")"$'\n'
done <<< "$drift"

# ── optional PR comment (only with --pr N) ───────────────────────────────────
if [ -n "$PR" ]; then
  if command -v gh >/dev/null 2>&1 || [ -n "${HERD_DRIFT_PR_COMMENT:-}" ]; then
    if (cd "$PROJECT_ROOT" && ${HERD_DRIFT_PR_COMMENT:-gh pr comment} "$PR" --body "$comment_body") >/dev/null 2>&1; then
      printf '   💬 posted the drift advisory as a comment on PR #%s.\n' "$PR"
    else
      printf '   ⚠️  could not post the drift advisory to PR #%s (left as a console/journal advisory only).\n' "$PR" >&2
    fi
  fi
fi

exit 0
