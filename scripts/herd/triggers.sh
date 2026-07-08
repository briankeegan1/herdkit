#!/usr/bin/env bash
# triggers.sh — SCHEDULED / TRIGGERED RUNS (HERD-169): a cron-style trigger spawns a defined workflow
# (a named backlog-item template or a steps.tsv pipeline — whatever the task text names) on schedule by
# ENQUEUEING spawn intents onto the EXISTING durable spawn queue (spawn.sh / spawn-step.sh). This file
# NEVER touches the queue internals — it only calls spawn.sh, exactly like a coordinator would.
#
# ── The trigger list: .herd/triggers.tsv ──────────────────────────────────────────────────────────
# A trigger is COMMITTED DATA, like .herd/steps.tsv: one TAB-separated row per trigger; blank lines and
# lines whose first field starts with '#' are ignored:
#     name <TAB> schedule <TAB> lane <TAB> task <TAB> input
#   name      kebab-ish label, unique-ish; the snapshot key, the journal key, and the spawn slug prefix.
#   schedule  the cadence a `tick` fires this trigger on — one of:
#               @hourly | @daily | @weekly | every:<N>[smhd] (e.g. every:30m, every:2h) | manual
#             'manual' NEVER auto-fires on `tick`; it fires ONLY via `triggers.sh fire <name>`.
#   lane      quick | feature — the durable-queue lane each spawned intent runs in (same set spawn.sh
#             accepts).
#   task      the task text handed to the spawned builder (its "workflow"): a named backlog-item
#             template, a steps.tsv-pipeline instruction, or any prompt. Tokens substituted per spawn:
#               {item} → the delta input line that triggered this spawn · {name} → the trigger name.
#   input     a shell command whose STDOUT lines are the trigger's INPUT SET (one item per line). The
#             diff-against-last-run compares this set to the previous run's snapshot and spawns work
#             ONLY for the DELTA (new lines). An empty input set spawns nothing.
#
# ── DIFF-AGAINST-LAST-RUN (the core of HERD-169) ──────────────────────────────────────────────────
# Each fire stores a per-trigger LAST-RUN INPUT SNAPSHOT under .herd/trigger-state/<name>.snapshot
# (runtime state — gitignored, NOT the committed trigger). On the next fire the current input set is
# diffed against it and a spawn intent is enqueued for each NEW line only (comm -13: in-current,
# not-in-previous). Semantics:
#   • FIRST RUN (snapshot MISSING) ⇒ FULL RUN: every current line is a delta and is spawned, LOUDLY
#     LABELLED so a full fan-out from a cold trigger is never mistaken for a delta. Fail-soft baseline.
#   • UNCHANGED input ⇒ NO delta ⇒ NO spawn (the snapshot is rewritten identically; the schedule clock
#     still advances).
#   • CHANGED input ⇒ only the added lines spawn.
# FAIL-SOFT: if the input command exits non-zero we WARN, journal outcome=input-error, spawn nothing,
# and DO NOT overwrite the good snapshot or advance the clock — the next tick simply retries. A trigger
# never wedges a tick; a malformed row is skipped (run `triggers.sh validate` to surface it).
#
# ── HARD RULE: ships DORMANT, byte-identical when no triggers are defined ──────────────────────────
# An ABSENT or empty .herd/triggers.tsv ⇒ `tick` does nothing, writes no snapshot, no journal row, no
# spawn. Nothing else in the engine changes. This feature is default-off.
#
# Dual-purpose, like the engine's other shared helpers: SOURCE it for the triggers_* functions, OR run
# it as a CLI. Sourced AFTER herd-config.sh (PROJECT_ROOT / WORKTREES_DIR) and journal.sh:
#   . "$HERE/herd-config.sh"
#   . "$HERE/journal.sh"
#   . "$HERE/triggers.sh"
#
# The tick CADENCE (who calls `triggers.sh tick`) is the operator's cron or a scheduler; the SCHEDULE
# column decides which triggers are DUE when a tick lands, from a per-trigger last-fired timestamp. The
# sim (tests/test-triggers.sh) drives two ticks directly with --now to prove the diff behavior.

# The legal lanes + schedules. The ONE source of truth every validator/runner checks.
TRIGGERS_LANES="quick feature"

# triggers_file — path to the project's trigger list. HERD_TRIGGERS_FILE overrides it outright (the sim
# points it at a fixture). Empty output ⇒ no destination ⇒ callers treat the list as ABSENT (no-op).
triggers_file() {
  if [ -n "${HERD_TRIGGERS_FILE:-}" ]; then printf '%s' "$HERD_TRIGGERS_FILE"; return 0; fi
  [ -n "${PROJECT_ROOT:-}" ] || return 1
  printf '%s' "$PROJECT_ROOT/.herd/triggers.tsv"
}

# triggers_state_dir — where per-trigger snapshots + last-fired timestamps live. Under .herd/ per
# HERD-169; gitignored (runtime state, not committed). HERD_TRIGGERS_STATE_DIR overrides it (the sim).
triggers_state_dir() {
  if [ -n "${HERD_TRIGGERS_STATE_DIR:-}" ]; then printf '%s' "$HERD_TRIGGERS_STATE_DIR"; return 0; fi
  [ -n "${PROJECT_ROOT:-}" ] || return 1
  printf '%s' "$PROJECT_ROOT/.herd/trigger-state"
}

# triggers_enabled — 0 iff the list exists AND has at least one non-blank, non-comment row. The ONE
# chokepoint every entry point routes through so an absent/empty/comments-only list is byte-inert.
triggers_enabled() {
  local f; f="$(triggers_file)" || return 1
  [ -f "$f" ] || return 1
  awk -F'\t' '{ n=$1; sub(/^[[:space:]]+/,"",n); if (n!="" && substr(n,1,1)!="#") { found=1; exit } } END { exit(found?0:1) }' "$f" 2>/dev/null
}

# _triggers_trim <s> — strip leading/trailing whitespace (fields come straight off a TSV read).
_triggers_trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }

# _triggers_slugify <s> — filesystem/branch-safe slug fragment: non [A-Za-z0-9._-] → '-', collapsed,
# and capped so a long input line can't blow out the spawn slug / branch name.
_triggers_slugify() {
  local s="$1"
  s="${s//[^A-Za-z0-9._-]/-}"
  # collapse runs of '-' and trim leading/trailing '-'
  while case "$s" in *--*) true ;; *) false ;; esac; do s="${s//--/-}"; done
  s="${s#-}"; s="${s%-}"
  printf '%s' "${s:0:48}"
}

# _triggers_interval <schedule> — echo the cadence in SECONDS, or 'manual' for a manual trigger.
# Returns non-zero (prints nothing) for an unparseable schedule so validate can flag it and tick can
# fail-soft skip it (an unparseable schedule NEVER silently fires).
_triggers_interval() {
  local spec num unit
  case "$1" in
    manual)  printf 'manual'; return 0 ;;
    @hourly) printf '3600';   return 0 ;;
    @daily)  printf '86400';  return 0 ;;
    @weekly) printf '604800'; return 0 ;;
    every:*)
      spec="${1#every:}"
      num="${spec%[smhd]}"; unit="${spec##*[0-9]}"
      case "$num" in ''|*[!0-9]*) return 1 ;; esac
      case "$unit" in
        s) printf '%s' "$((num))" ;;
        m) printf '%s' "$((num * 60))" ;;
        h) printf '%s' "$((num * 3600))" ;;
        d) printf '%s' "$((num * 86400))" ;;
        *) return 1 ;;
      esac
      return 0 ;;
    *) return 1 ;;
  esac
}

# triggers_validate — validate every row like a config key: required fields present, lane + schedule
# drawn from their legal sets. One problem per bad row to stderr; 0 when the list is absent or wholly
# valid, 1 on any problem, 2 when the file path can't be resolved. Never mutates anything.
triggers_validate() {
  local f; f="$(triggers_file)" || { echo "triggers: cannot locate triggers.tsv (PROJECT_ROOT unset)" >&2; return 2; }
  [ -f "$f" ] || return 0
  local ln=0 problems=0 name sched lane task input nm
  while IFS=$'\t' read -r name sched lane task input || [ -n "$name" ]; do
    ln=$((ln + 1))
    nm="$(_triggers_trim "$name")"
    case "$nm" in ''|'#'*) continue ;; esac
    sched="$(_triggers_trim "$sched")"; lane="$(_triggers_trim "$lane")"
    task="$(_triggers_trim "$task")"; input="$(_triggers_trim "$input")"
    if [ -z "$sched" ] || [ -z "$lane" ] || [ -z "$task" ] || [ -z "$input" ]; then
      echo "triggers.tsv:$ln: '$nm' — 'schedule', 'lane', 'task' and 'input' are all required" >&2
      problems=$((problems + 1)); continue
    fi
    case " $TRIGGERS_LANES " in *" $lane "*) ;; *) echo "triggers.tsv:$ln: '$nm' — invalid lane='$lane' (want one of: $TRIGGERS_LANES)" >&2; problems=$((problems + 1)) ;; esac
    _triggers_interval "$sched" >/dev/null || { echo "triggers.tsv:$ln: '$nm' — invalid schedule='$sched' (want @hourly|@daily|@weekly|every:<N>[smhd]|manual)" >&2; problems=$((problems + 1)); }
  done < "$f"
  [ "$problems" -eq 0 ] || return 1
  return 0
}

# triggers_list — print each VALID row as: name<TAB>schedule<TAB>lane<TAB>task<TAB>input. Invalid rows
# are silently dropped (the runner is fail-soft); run `triggers_validate` to surface them.
triggers_list() {
  local f; f="$(triggers_file)" || return 0
  [ -f "$f" ] || return 0
  local name sched lane task input nm
  while IFS=$'\t' read -r name sched lane task input || [ -n "$name" ]; do
    nm="$(_triggers_trim "$name")"
    case "$nm" in ''|'#'*) continue ;; esac
    sched="$(_triggers_trim "$sched")"; lane="$(_triggers_trim "$lane")"
    task="$(_triggers_trim "$task")"; input="$(_triggers_trim "$input")"
    [ -n "$sched" ] && [ -n "$lane" ] && [ -n "$task" ] && [ -n "$input" ] || continue
    case " $TRIGGERS_LANES " in *" $lane "*) ;; *) continue ;; esac
    _triggers_interval "$sched" >/dev/null || continue
    printf '%s\t%s\t%s\t%s\t%s\n' "$nm" "$sched" "$lane" "$task" "$input"
  done < "$f"
}

# ── per-trigger state ──────────────────────────────────────────────────────────────────────────────
_triggers_snapshot_file() { local d; d="$(triggers_state_dir)" || return 1; printf '%s/%s.snapshot' "$d" "$(_triggers_slugify "$1")"; }
_triggers_last_file()     { local d; d="$(triggers_state_dir)" || return 1; printf '%s/%s.last'     "$d" "$(_triggers_slugify "$1")"; }
_triggers_now()           { printf '%s' "${HERD_TRIGGERS_NOW:-$(date +%s 2>/dev/null || echo 0)}"; }

# triggers_due <name> <schedule> [now] — 0 iff this trigger is DUE at <now>. A manual trigger is NEVER
# due (fires only via `fire`). A trigger with no last-fired timestamp is due (first run). Otherwise due
# iff now - last >= interval. An unparseable schedule is NOT due (fail-soft — never silently fires).
triggers_due() {
  local name="$1" sched="$2" now="${3:-$(_triggers_now)}"
  local iv lf last
  iv="$(_triggers_interval "$sched")" || return 1
  [ "$iv" = "manual" ] && return 1
  lf="$(_triggers_last_file "$name")" || return 1
  [ -f "$lf" ] || return 0
  last="$(cat "$lf" 2>/dev/null || echo 0)"
  case "$last" in ''|*[!0-9]*) return 0 ;; esac
  [ "$((now - last))" -ge "$iv" ]
}

# _triggers_spawn <slug> <lane> <task> — enqueue ONE spawn intent onto the durable spawn queue. Calls
# the real spawn.sh by default; HERD_TRIGGERS_SPAWN_CMD overrides the whole invocation for the sim
# (stub records the enqueue), the same stub-injection pattern steps.sh / push-gate use. NEVER touches
# the queue's files directly — the durable-queue contract stays entirely inside spawn.sh.
_triggers_spawn() {
  local slug="$1" lane="$2" task="$3"
  if [ -n "${HERD_TRIGGERS_SPAWN_CMD:-}" ]; then
    HERD_TRIGGER_SLUG="$slug" HERD_TRIGGER_LANE="$lane" HERD_TRIGGER_TASK="$task" \
      bash "$HERD_TRIGGERS_SPAWN_CMD" "$slug" "$lane" "$task"
    return $?
  fi
  local here; here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  bash "$here/spawn.sh" "$slug" "$lane" "$task"
}

# _triggers_render <template> <name> <item> — substitute {name}/{item} tokens (plain string replace, no
# regex, so an item with slashes/globs is safe).
_triggers_render() {
  local out="$1"
  out="${out//\{name\}/$2}"
  out="${out//\{item\}/$3}"
  printf '%s' "$out"
}

# triggers_run_one <name> <schedule> <lane> <task> <input> <now> — fire ONE trigger: compute the input
# set, diff against the last-run snapshot, enqueue a spawn for each delta, then persist the new snapshot
# + last-fired timestamp. Prints a human line summarizing the outcome. Returns 0 always (fail-soft: an
# input-command error is reported + journaled but never a non-zero exit that would wedge the tick).
triggers_run_one() {
  local name="$1" sched="$2" lane="$3" task="$4" input="$5" now="${6:-$(_triggers_now)}"
  local dir="${HERD_TRIGGERS_INPUT_DIR:-${PROJECT_ROOT:-$PWD}}"
  local snap last tmpcur out rc n=0 item slug rtask
  snap="$(_triggers_snapshot_file "$name")" || { echo "🛑 triggers: '$name' — cannot resolve state dir." >&2; return 0; }
  last="$(_triggers_last_file "$name")"     || return 0

  # 1. Current input set: the input command's stdout, blank lines dropped, sorted-unique.
  out="$( cd "$dir" 2>/dev/null && bash -c "$input" )"; rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "⚠️  trigger '$name': input command FAILED (rc=$rc) — fail-soft: spawning nothing, keeping the last snapshot, will retry next tick." >&2
    command -v journal_append >/dev/null 2>&1 && journal_append trigger_tick name "$name" schedule "$sched" outcome input-error rc "$rc" || true
    return 0
  fi
  mkdir -p "$(dirname "$snap")" 2>/dev/null || true
  tmpcur="$(mktemp "${snap}.cur.XXXXXX" 2>/dev/null)" || tmpcur="${snap}.cur.$$"
  printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | sort -u > "$tmpcur" 2>/dev/null || : > "$tmpcur"

  # 2. Diff against the previous snapshot → the delta lines to spawn.
  local first_run=0 deltas
  if [ ! -f "$snap" ]; then
    first_run=1
    deltas="$(cat "$tmpcur")"
  else
    # comm -13: lines present in the CURRENT set but absent from the PREVIOUS snapshot (the new work).
    deltas="$(comm -13 "$snap" "$tmpcur" 2>/dev/null)"
  fi

  # 3. Enqueue one spawn per delta line.
  if [ -n "$deltas" ]; then
    while IFS= read -r item; do
      [ -n "$item" ] || continue
      n=$((n + 1))
      slug="$(_triggers_slugify "$name-$item")"
      rtask="$(_triggers_render "$task" "$name" "$item")"
      if _triggers_spawn "$slug" "$lane" "$rtask" >/dev/null 2>&1; then
        command -v journal_append >/dev/null 2>&1 && journal_append trigger_spawn name "$name" slug "$slug" lane "$lane" item "$item" || true
      else
        echo "⚠️  trigger '$name': spawn enqueue FAILED for item '$item' (fail-soft: continuing)." >&2
      fi
    done <<EOF
$deltas
EOF
  fi

  # 4. Persist the new snapshot + advance the schedule clock (only on a successful input read).
  mv -f "$tmpcur" "$snap" 2>/dev/null || { rm -f "$tmpcur" 2>/dev/null; }
  printf '%s\n' "$now" > "$last" 2>/dev/null || true

  # 5. Report + journal.
  if [ "$first_run" = "1" ]; then
    echo "🌱 trigger '$name': FIRST RUN (no snapshot) — FULL RUN, enqueued $n spawn(s) for the baseline input set (fail-soft first-run label)."
    command -v journal_append >/dev/null 2>&1 && journal_append trigger_tick name "$name" schedule "$sched" outcome first-run spawns "$n" || true
  elif [ "$n" -gt 0 ]; then
    echo "🔁 trigger '$name': input changed — enqueued $n delta spawn(s)."
    command -v journal_append >/dev/null 2>&1 && journal_append trigger_tick name "$name" schedule "$sched" outcome delta spawns "$n" || true
  else
    echo "✅ trigger '$name': input unchanged — no delta, nothing spawned."
    command -v journal_append >/dev/null 2>&1 && journal_append trigger_tick name "$name" schedule "$sched" outcome no-change spawns 0 || true
  fi
  return 0
}

# triggers_tick [now] [--force] — the one entry point a scheduler calls. Fire every DUE trigger (or,
# with --force, every valid trigger regardless of schedule). BYTE-IDENTICAL no-op when the list is
# absent/empty. Returns 0 always (fail-soft).
triggers_tick() {
  local now="" force=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --force) force=1; shift ;;
      --now)   now="${2:-}"; shift 2 ;;
      *)       [ -z "$now" ] && now="$1"; shift ;;
    esac
  done
  [ -n "$now" ] || now="$(_triggers_now)"
  triggers_enabled || return 0
  local name sched lane task input
  while IFS=$'\t' read -r name sched lane task input; do
    [ -n "$name" ] || continue
    if [ "$force" != "1" ] && ! triggers_due "$name" "$sched" "$now"; then
      continue
    fi
    triggers_run_one "$name" "$sched" "$lane" "$task" "$input" "$now"
  done <<EOF
$(triggers_list)
EOF
  return 0
}

# triggers_fire <name> [now] — force-fire ONE named trigger regardless of its schedule (honors manual
# triggers; ignores due-ness). The operator/coordinator entry point + the manual-trigger path.
triggers_fire() {
  local want="$1" now="${2:-$(_triggers_now)}"
  triggers_enabled || { echo "triggers: no triggers defined." >&2; return 1; }
  local name sched lane task input found=0
  while IFS=$'\t' read -r name sched lane task input; do
    [ "$name" = "$want" ] || continue
    found=1
    triggers_run_one "$name" "$sched" "$lane" "$task" "$input" "$now"
  done <<EOF
$(triggers_list)
EOF
  [ "$found" = "1" ] || { echo "triggers: no valid trigger named '$want'." >&2; return 1; }
  return 0
}

# ── CLI dispatch (only when executed, never when sourced) ─────────────────────────────────────────
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -uo pipefail
  _TR_HERE="$(cd "$(dirname "$0")" && pwd)"
  # shellcheck source=scripts/herd/herd-config.sh
  . "$_TR_HERE/herd-config.sh"
  # shellcheck source=scripts/herd/journal.sh
  [ -f "$_TR_HERE/journal.sh" ] && . "$_TR_HERE/journal.sh"
  _tr_cmd="${1:-}"; shift 2>/dev/null || true
  case "$_tr_cmd" in
    tick)     triggers_tick "$@" ;;
    fire)     triggers_fire "$@" ;;
    validate) triggers_validate && echo "✅ triggers: .herd/triggers.tsv valid." ;;
    list)     triggers_list ;;
    due)      triggers_due "$@" && echo "due" || { echo "not-due"; exit 1; } ;;
    enabled)  triggers_enabled ;;
    file)     triggers_file; echo ;;
    *) echo "Usage: triggers.sh [tick [--now EPOCH] [--force] | fire <name> [EPOCH] | validate | list | due <name> <schedule> [EPOCH] | enabled | file]" >&2; exit 1 ;;
  esac
fi
