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
# UNRESOLVABLE refs (HERD-411, evidence 2026-07-22): PR #515 carried `Refs: #514` — a GitHub-style
# issue ref filed while the Linear scribe was down. #514 can NEVER resolve through SCRIBE_BACKEND=linear
# (or any non-github backend), yet the old probe defaulted every read failure to `open` (the
# `${ITEM_STATE:-open}` fallback) and re-tried the impossible heal EVERY sweep, journaling
# tracker_state_heal_failed found_state=open result=NOCHANGE and re-posting a console ⚠ row on a
# ~22min cadence forever (no-false-red-consoles). Two independent defenses now short-circuit that:
#   • ref/backend SHAPE mismatch (_tsweep_ref_backend_mismatch) — a bare `#N`/`N` numeric ref can only
#     ever resolve against github (linear/jira/changelog identifiers always carry a non-numeric team
#     key, e.g. HERD-411); classified unresolvable on sight, never even probed.
#   • generic resolve-FAILURE (the `unknown` branch) — when `_backend_item_state` itself fails or
#     leaves ITEM_STATE unset (vs a backend explicitly resolving to `open`), the ref goes silent for
#     the first _TSWEEP_UNRESOLVABLE_AFTER-1 sweeps (transient blips retry quietly) and only escalates
#     to unresolvable after that many CONSECUTIVE failures.
# Either path journals ONE tracker_state_unresolvable event and ledgers the ref with a trailing
# `unresolvable` marker (_tsweep_ledgered only reads column 2, so this is byte-compatible with the
# existing healed/closed ledger rows) so it is never re-probed and never re-alarmed. It deliberately
# never touches the console-note ledger for this case: console-section.sh's tracker-heal renderer
# treats any non-`healed` status as a permanently-loud row, and an unresolvable ref will never produce
# a future `healed` row to supersede it — writing there would recreate the exact every-sweep-⚠ this
# fixes. LATENT HAZARD, noted honestly: if a numeric-only slug were ever a real identifier on some
# future non-github backend, this shape check would misclassify it before ever probing — no backend in
# this repo uses bare-number identifiers today.
#
# Hermetic seams (default to the real gh/backend; the tests override them):
#   HERD_TSWEEP_PRS_FILE      file of "<pr#>\t<ref>" lines, bypassing gh AND the body-parse entirely.
#   HERD_TSWEEP_PRS_JSON_FILE file of RAW `gh pr list --json number,body` output — exercises the real
#                             multi-line-body parse path (the seam the line-oriented bug had escaped).
#   SCRIBE_BACKEND[_DIR]      the active backend + its dir (same seam scribe-step.sh / _reconcile use).
#   HERD_TSWEEP_LEDGER        confirmed-Done ledger path (default $WORKTREES_DIR/.agent-watch-tracker-swept).
#   HERD_TSWEEP_NOTE_FILE     console-note surface the watcher renders (default …/.agent-watch-tracker-heals).
#   HERD_TSWEEP_UNRESOLVED_FILE  per-ref consecutive-resolve-failure counters (HERD-411), default
#                             $WORKTREES_DIR/.agent-watch-tracker-unresolved-counts.
#   JOURNAL_FILE              journal.sh's own test seam for the tracker_state_healed events.
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
UNRESOLVED_FILE="${HERD_TSWEEP_UNRESOLVED_FILE:-$WORKTREES_DIR/.agent-watch-tracker-unresolved-counts}"
# Consecutive resolve-failures a ref tolerates (silent retry) before it is classified unresolvable and
# ledgered off. Small on purpose: this is a backstop for a ref the backend provably cannot see, not a
# retry budget for a slow network — a genuinely transient blip clears the streak on its next success.
_TSWEEP_UNRESOLVABLE_AFTER=3

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
# Prints one TAB line "<item-state>\t<heal-result>" where item-state ∈ open|in-progress|closed|unknown
# and heal-result ∈ "" (no heal attempted — already closed, or unresolvable) | DONE | NOCHANGE.
# Sources the backend the way _reconcile_via_ref does (secrets + backend inside a subshell so the
# _backend_* funcs never leak), and, when the item is NOT closed, re-issues the VERIFIED update-state
# with the HERD-85 attribution envs so the backend's own tracker_write event is stamped
# component=sweep + the healing PR.
#
# HERD-411: `state` is `unknown` ONLY when `_backend_item_state` itself failed (nonzero) or left
# ITEM_STATE unset — NOT whenever it happens to resolve to `open`. The old code collapsed both into
# `open` (`${ITEM_STATE:-open}`) and drove every genuine resolve-failure through the heal-attempt path
# forever; a backend that explicitly resolves a ref to open is still trusted exactly as before.
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
    if _backend_item_state "$ref" >/dev/null 2>&1; then
      state="${ITEM_STATE:-unknown}"
    else
      state="unknown"
    fi
    if [ "$state" = "closed" ] || [ "$state" = "unknown" ]; then
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

# ── HERD-411: unresolvable-ref classification ───────────────────────────────────
# _tsweep_ref_backend_mismatch REF — true when REF is shaped like a bare GitHub issue ref (optionally
# `#`-prefixed digits, e.g. `#514` or `514`) while the ACTIVE backend is not github. Every non-github
# backend's identifiers carry a non-numeric key (HERD-411, PROJ-7, a changelog slug) — a bare number
# can only ever resolve against github, so probing it through any other backend is provably wasted,
# not a transient miss. See the file-header LATENT HAZARD note.
_tsweep_ref_backend_mismatch() {
  local bare="${1#\#}"
  [ -n "$bare" ] || return 1
  case "$bare" in *[!0-9]*) return 1 ;; esac
  [ "${SCRIBE_BACKEND:-file}" = "github" ] && return 1
  return 0
}

# _tsweep_gh_evidence REF — best-effort, READ-ONLY: when HERD_REPO names a repo and gh is on PATH,
# looks up the bare numeric ref as a github issue purely to record found-state EVIDENCE in the
# unresolvable journal event's detail. Never a resolution path — mixing github's numbering into a
# non-github backend's heal would risk resolving the WRONG item if a numeric id ever collides with a
# real local one (the latent hazard above). Fail-soft: prints nothing on any absence/error.
_tsweep_gh_evidence() {
  local num="${1#\#}"
  [ -n "${HERD_REPO:-}" ] || return 0
  command -v gh >/dev/null 2>&1 || return 0
  gh issue view "$num" -R "$HERD_REPO" --json state 2>/dev/null \
    | python3 -c 'import sys, json
try: print(json.load(sys.stdin).get("state", "").lower())
except Exception: pass' 2>/dev/null || true
}

# ── HERD-411: per-ref consecutive resolve-failure counters ─────────────────────
# One "<ref> <count>" line per ref currently mid-streak; a ref that resolves (or is ledgered) has no
# line at all, so a healthy sweep carries none. Rewritten wholesale on each bump/clear — these files
# stay tiny (only refs actively failing to resolve appear).
_tsweep_unresolved_count() {
  [ -s "$UNRESOLVED_FILE" ] || { printf '0'; return 0; }
  local n
  n="$(awk -v r="$1" '$1==r{print $2; exit}' "$UNRESOLVED_FILE" 2>/dev/null)"
  case "${n:-}" in ''|*[!0-9]*) printf '0' ;; *) printf '%s' "$n" ;; esac
}
_tsweep_unresolved_bump() {
  local ref="$1" n dir
  n="$(_tsweep_unresolved_count "$ref")"; n=$((n + 1))
  dir="${UNRESOLVED_FILE%/*}"
  [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null || { printf '%s' "$n"; return 0; }
  if [ -s "$UNRESOLVED_FILE" ]; then
    awk -v r="$ref" '$1!=r{print}' "$UNRESOLVED_FILE" > "$UNRESOLVED_FILE.tmp" 2>/dev/null \
      && mv "$UNRESOLVED_FILE.tmp" "$UNRESOLVED_FILE"
  fi
  printf '%s %s\n' "$ref" "$n" >> "$UNRESOLVED_FILE" 2>/dev/null || true
  printf '%s' "$n"
}
_tsweep_unresolved_clear() {
  [ -s "$UNRESOLVED_FILE" ] || return 0
  awk -v r="$1" '$1!=r{print}' "$UNRESOLVED_FILE" > "$UNRESOLVED_FILE.tmp" 2>/dev/null \
    && mv "$UNRESOLVED_FILE.tmp" "$UNRESOLVED_FILE" || true
}

# _tsweep_mark_unresolvable REF PR REASON — the backend can PROVABLY never resolve REF (a shape
# mismatch) or has failed to resolve it _TSWEEP_UNRESOLVABLE_AFTER sweeps running. Journal ONE event
# for the audit trail, then ledger it with a trailing `unresolvable` marker so _tsweep_ledgered skips
# it on every future sweep — no more backend reads, no more per-sweep ⚠ for a ref the backend cannot
# even see (no-false-red-consoles). Deliberately never writes the console-note ledger — see the
# file-header rationale (a non-`healed` note there renders as a PERMANENT loud row that can never be
# superseded).
_tsweep_mark_unresolvable() {
  local ref="$1" pr="$2" reason="$3"
  journal_append tracker_state_unresolvable ref "$ref" pr "$pr" component sweep reason "$reason"
  _tsweep_record "$ref" "$pr" unresolvable
  echo "tracker-state-sweep: $ref is unresolvable ($reason) — ledgered; no further sweeps will probe it."
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
# $3 (optional) appends a 4th column marker (HERD-411: "unresolvable"). _tsweep_ledgered only ever
# reads column 2, so an omitted $3 stays byte-identical to the pre-HERD-411 3-column row.
_tsweep_record() {
  local dir="${LEDGER%/*}" marker="${3:-}"
  [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null || return 0
  if [ -n "$marker" ]; then
    printf '%s %s %s %s\n' "$(date +%s 2>/dev/null || echo 0)" "$1" "$2" "$marker" >> "$LEDGER" 2>/dev/null || true
  else
    printf '%s %s %s\n' "$(date +%s 2>/dev/null || echo 0)" "$1" "$2" >> "$LEDGER" 2>/dev/null || true
  fi
}

# ── run ────────────────────────────────────────────────────────────────────────
if ! _tsweep_backend_supported; then
  echo "tracker-state-sweep: backend '${SCRIBE_BACKEND:-file}' has no update-state op — sweep is inert (nothing to heal via dispatch)."
  exit 0
fi

healed=0 failed=0 checked=0 scanned=0 unresolvable=0
while IFS=$'\t' read -r pr ref; do
  [ -n "${ref:-}" ] || continue
  scanned=$((scanned + 1))
  _tsweep_ledgered "$ref" && continue          # already confirmed Done (or unresolvable) — no backend read

  # HERD-411: a ref/backend shape mismatch (a bare github-style #N under a non-github backend) can
  # NEVER resolve — classify it unresolvable immediately, without ever probing the backend.
  if _tsweep_ref_backend_mismatch "$ref"; then
    reason="ref-shape mismatch: '$ref' cannot resolve under SCRIBE_BACKEND=${SCRIBE_BACKEND:-file}"
    gh_state="$(_tsweep_gh_evidence "$ref")"
    [ -n "$gh_state" ] && reason="$reason (github issue currently $gh_state)"
    _tsweep_mark_unresolvable "$ref" "$pr" "$reason"
    unresolvable=$((unresolvable + 1))
    continue
  fi

  checked=$((checked + 1))
  IFS=$'\t' read -r state result < <(_tsweep_probe_and_heal "$ref" "$pr")
  case "$state" in
    closed)
      _tsweep_unresolved_clear "$ref"
      _tsweep_record "$ref" "$pr" ;;           # confirmed Done at read time — ledger + move on
    unknown)
      # HERD-411: the backend genuinely FAILED to resolve this ref (vs resolving it to open) — go
      # silent for the first few sweeps (a transient blip retries quietly), then stop alarming.
      n="$(_tsweep_unresolved_bump "$ref")"
      if [ "$n" -ge "$_TSWEEP_UNRESOLVABLE_AFTER" ]; then
        _tsweep_mark_unresolvable "$ref" "$pr" "backend failed to resolve $n consecutive sweeps"
        _tsweep_unresolved_clear "$ref"
        unresolvable=$((unresolvable + 1))
      fi ;;
    *)
      # The item drifted (open / in-progress) despite a merged PR — heal it.
      _tsweep_unresolved_clear "$ref"
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

if [ "$healed" -eq 0 ] && [ "$failed" -eq 0 ] && [ "$unresolvable" -eq 0 ]; then
  echo "tracker-state-sweep: no tracker drift — $scanned merged ref(s) scanned, $checked re-checked, all Done. Nothing to heal."
else
  echo "tracker-state-sweep: healed $healed, $failed still unhealed, $unresolvable unresolvable (of $checked re-checked / $scanned scanned)."
fi
exit 0
