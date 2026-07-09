#!/usr/bin/env bash
# tracker-state-sweep.sh — periodic, ADVISORY tracker-state SELF-HEAL sweep (HERD-86).
#
# The problem (evidence 2026-07-07, two recurrences: HERD-67 after PR #187, HERD-69 after PR #197):
# a merged PR's tracker item can end up NOT Done. The post-merge auto-reconcile hook
# (agent-watch.sh:reconcile_backlog → _reconcile_via_ref) is the primary path, but a transient
# backend write failure at merge time (the exact HERD-67 incident, now VERIFIED at the write in
# HERD-70) or an untracked merge can leave the item stuck open — and today only a human notices.
#
# This is the BACKSTOP: a cheap periodic sweep that re-asserts Done for recently-merged PRs whose
# tracker item drifted. For each recently-merged PR carrying a `Refs: <id>` line it reads the item's
# CURRENT state through the ACTIVE backend; if the item is NOT already closed (Done), it re-issues the
# VERIFIED update-state (HERD-70 semantics: _backend_update_state reports DONE only on a confirmed
# transition), journals a `tracker_state_healed` event attributed to component=sweep (building on the
# HERD-85 tracker_write attribution the backends already emit), and surfaces a console note so the
# drift is VISIBLE, never silently corrected. It is deliberately:
#   • ADVISORY + IDEMPOTENT — a ref confirmed Done is recorded in a ledger and never re-read; a heal
#     that FAILS is NOT ledgered, so it stays visible and retries next sweep. Re-running is safe.
#   • CHEAP — steady-state does ONE `gh pr list` and ZERO backend reads (every recent ref already
#     ledgered). Only a genuinely-unhealed ref costs one backend read (+ one write iff it drifted).
#   • BACKEND-SCOPED — only backends with a real `_backend_update_state` op (linear/github/changelog)
#     participate. The default `file` backend records state by editing BACKLOG.md (the scribe/
#     coordinator's domain, NOT a sweep's) so the sweep is byte-inert there — mirroring
#     _reconcile_via_ref's fall-through. Never edits BACKLOG.md, never merges, never touches git.
#
# Usage:
#   tracker-state-sweep.sh [--limit N]
#     --limit N   how many recent merged PRs to look back over (default 50).
#
# Hermetic seams (default to the real gh/backend; the tests override them):
#   HERD_TSWEEP_PRS_FILE      file of "<pr#>\t<ref>" lines, bypassing gh AND the body-parse entirely.
#   HERD_TSWEEP_PRS_JSON_FILE file of RAW `gh pr list --json number,body` output — exercises the real
#                             multi-line-body parse path (the seam the line-oriented bug had escaped).
#   SCRIBE_BACKEND[_DIR]   the active backend + its dir (same seam scribe-step.sh / _reconcile use).
#   HERD_TSWEEP_LEDGER     confirmed-Done ledger path (default $WORKTREES_DIR/.agent-watch-tracker-swept).
#   HERD_TSWEEP_NOTE_FILE  console-note surface the watcher renders (default …/.agent-watch-tracker-heals).
#   JOURNAL_FILE           journal.sh's own test seam for the tracker_state_healed events.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/herd-config.sh"
# shellcheck source=/dev/null
. "$HERE/journal.sh"
# Bounded console ledgers (HERD-243) — sourced for herd_console_trim, the ONE tail-keep bound shared
# with the watcher's builder-notes ledger. Defines functions + constants only.
# shellcheck source=/dev/null
. "$HERE/console-section.sh"
REPO="$PROJECT_ROOT"

_tsweep_die() { echo "tracker-state-sweep: $1" >&2; exit "${2:-1}"; }
command -v python3 >/dev/null 2>&1 || _tsweep_die "python3 is required" 1

# ── argument parsing ─────────────────────────────────────────────────────────
LIMIT="${TSWEEP_LIMIT:-50}"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --limit)   shift; LIMIT="${1:?--limit needs a number}" ;;
    --limit=*) LIMIT="${1#--limit=}" ;;
    -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
    *) _tsweep_die "unknown argument: $1 (usage: tracker-state-sweep.sh [--limit N])" 2 ;;
  esac
  shift
done
case "$LIMIT" in ''|*[!0-9]*) LIMIT=50 ;; esac

LEDGER="${HERD_TSWEEP_LEDGER:-$WORKTREES_DIR/.agent-watch-tracker-swept}"
NOTE_FILE="${HERD_TSWEEP_NOTE_FILE:-$WORKTREES_DIR/.agent-watch-tracker-heals}"

# ── backend resolution (mirrors scribe-step.sh / _reconcile_via_ref) ──────────
BACKEND_DIR="${SCRIBE_BACKEND_DIR:-$HERE/backends}"
BACKEND_FILE="$BACKEND_DIR/${SCRIBE_BACKEND:-file}.sh"

# _tsweep_backend_supported — the sweep only runs for a backend that can DISPATCH a state write. The
# file backend records state by editing BACKLOG.md (owned by the scribe/coordinator), so it has no
# _backend_update_state op and the sweep is inert there — exactly _reconcile_via_ref's fall-through.
_tsweep_backend_supported() {
  [ -f "$BACKEND_FILE" ] || return 1
  (
    # shellcheck source=/dev/null
    . "$BACKEND_FILE" 2>/dev/null || exit 1
    command -v _backend_update_state >/dev/null 2>&1 || exit 1
    command -v _backend_item_state   >/dev/null 2>&1 || exit 1
  )
}

# ── data source: recently-merged PRs with their Refs ──────────────────────────
# _merged_refs — "<pr#>\t<ref>" per line, one per recently-merged PR that carries an explicit
# `Refs: <id>` line. The ref is extracted with the SAME defenses as agent-watch's _reconcile_pr_ref:
# HTML comment blocks are stripped first (a PR-template example 'Refs:' lives inside a comment and
# would otherwise poison the extractor), then the first line-anchored `Refs:` token is taken, and
# template placeholders (<...>, none, n/a) are dropped. Best-effort + fail-soft: no gh / offline /
# body-less all yield fewer (or zero) lines, never a hard error.
#
# CRITICAL: PR bodies are MULTI-LINE. We take the RAW JSON array (gh --json, NO -q) and parse it with
# python's json.load — NOT a jq `\(.number)\t\(.body)` template piped line-by-line, which spills each
# body across many stdout lines so only the body's first line carries the number+tab and the deeper
# `Refs:` line arrives tab-less and is dropped (the live-repo defect the PRS_FILE seam masked: a repo
# of ref-carrying merges scanned 0). json.load keeps each PR's body intact as one field.
_merged_refs() {
  if [ -n "${HERD_TSWEEP_PRS_FILE:-}" ]; then cat "$HERD_TSWEEP_PRS_FILE"; return 0; fi
  local json
  if [ -n "${HERD_TSWEEP_PRS_JSON_FILE:-}" ]; then          # test seam: raw `gh pr list --json` output
    json="$(cat "$HERD_TSWEEP_PRS_JSON_FILE")"
  else
    command -v gh >/dev/null 2>&1 || return 0
    json="$(cd "$REPO" && gh pr list --state merged --limit "$LIMIT" --json number,body 2>/dev/null)" || return 0
  fi
  [ -n "$json" ] || return 0
  printf '%s' "$json" | python3 -c '
import sys, re, json
try:
    prs = json.load(sys.stdin)
except Exception:
    prs = []
for pr in prs if isinstance(prs, list) else []:
    num  = pr.get("number")
    body = pr.get("body") or ""
    if num is None:
        continue
    body = re.sub(r"<!--.*?-->", "", body, flags=re.DOTALL)   # strip template comments first
    ref = ""
    for ln in body.splitlines():
        m = re.match(r"\s*[Rr][Ee][Ff][Ss]:\s*(\S+)", ln)      # first line-anchored Refs: token
        if m:
            ref = m.group(1)
            break
    if ref and not (ref.startswith("<") or ref.lower() in ("none", "n/a", "na")):
        print("%s\t%s" % (num, ref))
' 2>/dev/null || true
}

# ── heal one ref through the active backend, in an isolated subshell ───────────
# Prints one TAB line "<item-state>\t<heal-result>" where item-state ∈ open|in-progress|closed and
# heal-result ∈ "" (no heal attempted — already closed) | DONE | NOCHANGE. Sources the backend the
# way _reconcile_via_ref does (secrets + backend inside a subshell so the _backend_* funcs never leak),
# and, when the item is NOT closed, re-issues the VERIFIED update-state with the HERD-85 attribution
# envs so the backend's own tracker_write event is stamped component=sweep + the healing PR.
_tsweep_probe_and_heal() {
  local ref="$1" pr="$2"
  (
    _secrets="$REPO/.herd/secrets"
    # shellcheck source=/dev/null
    [ -f "$_secrets" ] && . "$_secrets"
    # shellcheck source=/dev/null
    . "$BACKEND_FILE" 2>/dev/null || { printf 'unknown\t\n'; exit 0; }
    cd "$REPO" 2>/dev/null || true
    ITEM_STATE=""
    _backend_item_state "$ref" >/dev/null 2>&1 || true
    state="${ITEM_STATE:-open}"
    if [ "$state" = "closed" ]; then
      printf '%s\t\n' "$state"
      exit 0
    fi
    # Drift: the merged item is not Done. Re-issue the VERIFIED heal (HERD-70), attributed to the
    # sweep (HERD-85). _backend_update_state sets _BACKEND_RESULT=DONE only on a confirmed transition.
    export HERD_COMPONENT="sweep" HERD_TW_PR="$pr"
    _BACKEND_RESULT=""
    _backend_update_state "$ref" done >/dev/null 2>&1 || true
    printf '%s\t%s\n' "$state" "${_BACKEND_RESULT:-NOCHANGE}"
  )
}

# ── console-note surface (the watcher renders the last lines) ──────────────────
# One append-only line per heal ACTION: "<epoch> <status> <ref> <pr> <found-state>".
# status ∈ healed | failed. Trimmed ON WRITE to the last CONSOLE_LEDGER_MAX lines by the shared
# bounded-section helper (HERD-243) — the same bound the builder-notes ledger uses — so a
# persistently-failing heal (which re-appends every sweep, by design: it stays visible until it
# succeeds) can never grow unbounded. Display age-out lives in the watcher's build_tracker_drift.
_tsweep_note() {
  local status="$1" ref="$2" pr="$3" state="$4" epoch
  [ -n "$NOTE_FILE" ] || return 0
  epoch="$(date +%s 2>/dev/null || echo 0)"
  local dir="${NOTE_FILE%/*}"
  [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null || return 0
  printf '%s %s %s %s %s\n' "$epoch" "$status" "$ref" "$pr" "$state" >> "$NOTE_FILE" 2>/dev/null || return 0
  herd_console_trim "$NOTE_FILE"
}

# ── ledger: refs already confirmed Done (skip → no backend read) ──────────────
_tsweep_ledgered() {
  [ -s "$LEDGER" ] || return 1
  awk -v r="$1" '$2==r{f=1} END{exit !f}' "$LEDGER" 2>/dev/null
}
_tsweep_record() {
  local dir="${LEDGER%/*}"
  [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null || return 0
  printf '%s %s %s\n' "$(date +%s 2>/dev/null || echo 0)" "$1" "$2" >> "$LEDGER" 2>/dev/null || true
}

# ── run ────────────────────────────────────────────────────────────────────────
if ! _tsweep_backend_supported; then
  echo "tracker-state-sweep: backend '${SCRIBE_BACKEND:-file}' has no update-state op — sweep is inert (nothing to heal via dispatch)."
  exit 0
fi

healed=0 failed=0 checked=0 scanned=0
while IFS=$'\t' read -r pr ref; do
  [ -n "${ref:-}" ] || continue
  scanned=$((scanned + 1))
  _tsweep_ledgered "$ref" && continue          # already confirmed Done — no backend read
  checked=$((checked + 1))
  IFS=$'\t' read -r state result < <(_tsweep_probe_and_heal "$ref" "$pr")
  case "$state" in
    closed)
      _tsweep_record "$ref" "$pr" ;;           # confirmed Done at read time — ledger + move on
    unknown)
      : ;;                                      # backend read errored — retry next sweep, no note
    *)
      # The item drifted (open / in-progress) despite a merged PR — heal it.
      if [ "$result" = "DONE" ]; then
        journal_append tracker_state_healed ref "$ref" pr "$pr" found_state "$state" component sweep
        _tsweep_note healed "$ref" "$pr" "$state"
        _tsweep_record "$ref" "$pr"
        echo "🩹 tracker-state-sweep: healed $ref (was '$state') — merged PR #$pr is now marked Done."
        healed=$((healed + 1))
      else
        journal_append tracker_state_heal_failed ref "$ref" pr "$pr" found_state "$state" component sweep result "${result:-NOCHANGE}"
        _tsweep_note failed "$ref" "$pr" "$state"
        echo "⚠️  tracker-state-sweep: FAILED to heal $ref (found '$state', merged PR #$pr) — left unhealed for retry next sweep." >&2
        failed=$((failed + 1))
      fi ;;
  esac
done < <(_merged_refs)

if [ "$healed" -eq 0 ] && [ "$failed" -eq 0 ]; then
  echo "tracker-state-sweep: no tracker drift — $scanned merged ref(s) scanned, $checked re-checked, all Done. Nothing to heal."
else
  echo "tracker-state-sweep: healed $healed, $failed still unhealed (of $checked re-checked / $scanned scanned)."
fi
exit 0
