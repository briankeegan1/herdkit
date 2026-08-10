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
# `unresolvable` marker (this sweep's own _tsweep_ledgered only reads column 2, so THIS reader is
# byte-compatible with the existing healed/closed ledger rows). BUT $LEDGER (a.k.a.
# $TRACKER_SWEEP_LEDGER) has a SECOND reader outside this file: agent-watch.sh's
# _pms_tracker_ledgered, whose contract is "the tracker sweep CONFIRMED this ref Done" — column-2-only
# would wrongly satisfy that for an unresolvable row too, silently deferring reconcile_backlog for an
# item that never shipped (HERD-411 review finding). _pms_tracker_ledgered guards against this itself
# (it requires NF==3), but any THIRD reader of this file must apply the same guard — column 2 alone
# means "this ref appears in the ledger", not "this ref is Done"; column count (3 vs 4) is what
# distinguishes them.
#
# HERD-502 (evidence 2026-08-03: the live 'full-auto'/#606 incident — a malformed `Refs:` line
# captured a diagnostic token, not a real identifier, and the resolver bug below let it read as
# "open" forever): _tsweep_mark_unresolvable ALSO writes exactly ONE console note, status
# `escalated`. Earlier this function deliberately never touched the console-note ledger, reasoning
# that any note would render as a permanently-loud row with no future `healed` row to supersede it —
# true, but that made a genuinely-abandoned ref TOTALLY SILENT on the console, which is its own
# failure mode (no-false-red-consoles cuts both ways: a real, permanent problem should stay visible,
# not vanish). It is safe to write exactly once because _tsweep_ledgered skips this ref on every
# future sweep — this function can never run for it again — and console-section.sh's supersede logic
# (extended for HERD-502 to also treat `escalated` as a superseding status, alongside `healed`) hides
# any older `failed` rows already sitting in the ledger for the same ref, so the net effect on screen
# is ONE row, not N-per-sweep spam plus a straggling tail of now-stale `failed` duplicates.
# LATENT HAZARD, noted honestly: if a numeric-only slug were ever a real identifier on some future
# non-github backend, the shape check above would misclassify it before ever probing — no backend in
# this repo uses bare-number identifiers today.
#
# HERD-624 (evidence: after a file→github backend switch, a merged PR's Refs: line still names the
# OLD backend's ref shape — the tracker-state-sweep re-probes it against the NEW backend forever,
# marks it `unresolvable` correctly (HERD-411/HERD-502), but that ledgered row has no path off the
# console: agent-watch.sh's "reconcile pending" section only treats a 3-column `done` row as
# confirmed, so the row nags permanently). THREE LEGS close this: (a) `herd backend switch` itself
# resolves or retires every pending reconcile intent BEFORE the flip, while the old backend can still
# answer for it (bin/herd's cmd_backend_switch); (b) _tsweep_age_unresolvable_to_retired below ages a
# standing `unresolvable` ref to a terminal `retired` marker after _TSWEEP_RETIRE_AFTER sweeps —
# the HERD-613-leg-3 lesson ("a row nobody can act on needs a terminal, quiet path") applied here
# too, and console-section.sh classifies `retired` as CALM so it ages off-screen normally instead of
# staying loud forever; (c) _tsweep_ref_backend_mismatch now also runs pr-ref.sh's shared per-backend
# SHAPE check (HERD-613), so a `herd backend switch` survivor ref classifies unresolvable on sight
# instead of burning _TSWEEP_UNRESOLVABLE_AFTER retries first.
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
# THE shared `Refs:` parser (HERD-522) — this sweep is the merge-time reconcile's BACKSTOP, so reading
# a ref even slightly differently from it is the one drift that would make the backstop miss exactly
# what the primary path missed. Defines HERD_PR_REF_PY + three functions; sourcing is idempotent.
# shellcheck source=/dev/null
. "$HERE/pr-ref.sh"
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
# ACK_FILE (HERD-613 LEG 3) — the SAME ack sidecar agent-watch.sh's TRACKER_HEAL_ACK / bin/herd's
# `herd tracker-heals ack` write/read; this sweep is the ONLY auto-writer (the auto-retire leg below).
ACK_FILE="${HERD_TSWEEP_ACK_FILE:-$WORKTREES_DIR/.agent-watch-tracker-heals-acked}"
UNRESOLVED_FILE="${HERD_TSWEEP_UNRESOLVED_FILE:-$WORKTREES_DIR/.agent-watch-tracker-unresolved-counts}"
# Consecutive resolve-failures a ref tolerates (silent retry) before it is classified unresolvable and
# ledgered off. Small on purpose: this is a backstop for a ref the backend provably cannot see, not a
# retry budget for a slow network — a genuinely transient blip clears the streak on its next success.
_TSWEEP_UNRESOLVABLE_AFTER=3
# RETIRE_FILE (HERD-624 LEG 2) — a "<ref> <count>" counter PARALLEL to $UNRESOLVED_FILE, reusing its
# exact bump/clear shape, but counting SWEEPS a ref has sat `unresolvable` in $LEDGER (not resolve
# attempts — an unresolvable ref is never re-probed, so there is nothing left to retry). See
# _tsweep_age_unresolvable_to_retired.
RETIRE_FILE="${HERD_TSWEEP_RETIRE_FILE:-$WORKTREES_DIR/.agent-watch-tracker-retire-counts}"
# Sweeps an `unresolvable` ref sits ledgered before it graduates to the terminal `retired` marker.
# Deliberately looser than _TSWEEP_UNRESOLVABLE_AFTER: `unresolvable` already means "the backend can
# never see this," so `retired` is not a second correctness gate — it exists purely to move a
# permanently-loud console row (HERD-502's `escalated` note, and agent-watch.sh's "reconcile pending"
# row) to a terminal, CALM-aging state once the ref has been visibly given-up-on for a while, not on
# the very next tick.
_TSWEEP_RETIRE_AFTER=5

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
# _merged_refs — "<pr#>\t<ref>" per line, ONE LINE PER REF: a PR carrying N distinct `Refs: <id>`
# lines (HERD-587, GH #708 — a PR with four bare Refs lines, three items left open for two hours until
# hand-closed) contributes N rows, not one. Every ref is extracted by the SHARED parser (pr-ref.sh's
# HERD_PR_REF_PY / pr_ref_all_from_body, HERD-522/HERD-587) — not a local re-derivation of its
# defenses, which is what this used to be: HTML comment blocks stripped first (a PR-template example
# 'Refs:' lives inside a comment and would otherwise poison the extractor), every decoration-tolerant
# `Refs:` token taken (not just the first), template placeholders (<...>, none, n/a) dropped, duplicate
# refs on the same PR collapsed to one row. Best-effort + fail-soft: no gh / offline / body-less all
# yield fewer (or zero) lines, never a hard error.
#
# This is what makes the multi-ref BACKSTOP work with ZERO changes to the loop below: the main loop
# already treats each "<pr>\t<ref>" row as an independent unit (its own ledger check, its own
# probe/heal, its own journal line) — that was already true for the ordinary case of two DIFFERENT PRs
# each carrying one ref. A PR with three refs is now just three rows through the exact same loop, so a
# ref that failed to heal at merge time (agent-watch.sh's reconcile_backlog) gets retried on its own,
# independently of its siblings on the same PR, next sweep.
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
  printf '%s' "$json" | python3 -c "$HERD_PR_REF_PY"'
import sys, json
try:
    prs = json.load(sys.stdin)
except Exception:
    prs = []
for pr in prs if isinstance(prs, list) else []:
    num = pr.get("number")
    if num is None:
        continue
    for ref in pr_ref_all_from_body(pr.get("body") or ""):
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
# _tsweep_ref_backend_mismatch REF — true when REF can PROVABLY never resolve under the ACTIVE
# SCRIBE_BACKEND. Two independent checks:
#   (1) the original HERD-411 case: REF is shaped like a bare GitHub issue ref (optionally
#       `#`-prefixed digits, e.g. `#514` or `514`) while the active backend is not github. Every
#       non-github backend's identifiers carry a non-numeric key (HERD-411, PROJ-7, a changelog
#       slug) — a bare number can only ever resolve against github. Kept as its own branch (rather
#       than folded into (2)) because it must also fire under a backend with NO fixed shape at all
#       (pr-ref.sh's shape table only names linear/jira/github) — see the file-header LATENT HAZARD
#       note and tests/test-tracker-state-sweep.sh case (9), which exercises exactly this under a
#       shape-less "stub" backend.
#   (2) HERD-624: the shared per-backend SHAPE check (pr-ref.sh, HERD-613) — a ref that fails the
#       ACTIVE backend's own known fixed shape can never be a native id under it. This generalizes
#       (1) beyond bare numbers: a `herd backend switch` survivor ref minted under the OLD backend
#       (a linear/jira `HERD-123` under a new github backend, or a file-backend title slug under
#       any shaped backend — file/changelog define no fixed shape, so pr-ref.sh's own "NO SHAPE
#       TEST" invariant already exempts a ref surviving INTO one of those) is caught on sight,
#       exactly like (1), instead of burning _TSWEEP_UNRESOLVABLE_AFTER silent retries against a
#       backend it was never minted for. One shared parser, not a second one.
_tsweep_ref_backend_mismatch() {
  local ref="$1" backend="${SCRIBE_BACKEND:-file}" bare="${1#\#}"
  [ -n "$ref" ] || return 1
  case "$bare" in
    '') ;;
    *[!0-9]*) ;;
    *) [ "$backend" = "github" ] || return 0 ;;
  esac
  herd_pr_ref_shape_ok "$ref" "$backend" && return 1
  return 0
}

# _tsweep_gh_evidence REF — best-effort, READ-ONLY: when TRACKER_REPO names a repo and gh is on PATH,
# looks up the bare numeric ref as a github issue purely to record found-state EVIDENCE in the
# unresolvable journal event's detail. Never a resolution path — mixing github's numbering into a
# non-github backend's heal would risk resolving the WRONG item if a numeric id ever collides with a
# real local one (the latent hazard above). Fail-soft: prints nothing on any absence/error.
# TRACKER_REPO is NOT set by this script — it is the existing config key herd-config.sh already
# sources above (default EMPTY: `: "${TRACKER_REPO:=""}"`), the SAME one the github backend uses for
# its own issue ops (HERD-534: this used to read HERD_REPO — the report/triage escalation key, never
# this project's own tracker repo — so a project with HERD_REPO configured but a non-github
# SCRIBE_BACKEND had this evidence lookup silently probe a STRANGER's repo). This function adds no new
# required input: on a project that has TRACKER_REPO configured, the evidence lookup fires for free;
# everywhere else it stays silently empty (fail-soft), exactly as before this function existed.
_tsweep_gh_evidence() {
  local num="${1#\#}"
  [ -n "${TRACKER_REPO:-}" ] || return 0
  command -v gh >/dev/null 2>&1 || return 0
  gh issue view "$num" -R "$TRACKER_REPO" --json state 2>/dev/null \
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
  # HERD-502: surface EXACTLY ONE distinct console row for a ref the sweep has given up on. Before
  # this, a ref reaching this function left NO trace on the console at all (by design — see the
  # file-header rationale: any note here used to render as a PERMANENTLY loud row, and this ref will
  # never produce a future `healed` row to supersede it). That silence is itself a problem: an
  # operator watching the console had no way to learn "the sweep stopped trying $ref" short of
  # reading the journal. A single `escalated` note is now safe because _tsweep_ledgered skips this
  # ref on every future sweep — this function can never run for it again, so exactly one row is ever
  # written — and console-section.sh's supersede logic (HERD-502) retroactively hides any OLDER
  # `failed` rows already sitting in the ledger for this same ref, so the net effect on screen is ONE
  # row, never the N-per-sweep spam this closes out (the live 'full-auto'/#606 incident: 20/20
  # console slots and 11+ journal events for a ref that could never resolve).
  _tsweep_note escalated "$ref" "$pr" unknown
  echo "tracker-state-sweep: $ref is unresolvable ($reason) — ledgered; no further sweeps will probe it."
}

# ── HERD-624 LEG 2: age a standing `unresolvable` ref to a terminal `retired` state ────────────────
# The problem this closes: once _tsweep_mark_unresolvable ledgers a ref, _tsweep_ledgered skips it on
# every future sweep — correct (no more wasted backend reads), but it means the ref's `escalated`
# console note (HERD-502, deliberately LOUD-forever, because most escalations are a real standing
# problem) and any downstream "reconcile pending" row (agent-watch.sh's build_reconcile_pending, which
# only treats a 3-column `done` ledger row as confirmed) never have a path off the screen. That is
# fine for a genuine, ongoing drift — but for a `herd backend switch` survivor (HERD-624: a ref minted
# under a backend that is no longer active) it is a PERMANENT false alarm nobody can ever act on, the
# exact HERD-613-leg-3 lesson ("a row nobody can ever act on must have a terminal, quiet path")
# applied to reconcile intents instead of shape-invalid refs.
#
# _tsweep_retire_count/_bump/_clear mirror _tsweep_unresolved_count/_bump/_clear exactly (same file
# shape, same tiny footprint — only refs actively aging appear).
_tsweep_retire_count() {
  [ -s "$RETIRE_FILE" ] || { printf '0'; return 0; }
  local n
  n="$(awk -v r="$1" '$1==r{print $2; exit}' "$RETIRE_FILE" 2>/dev/null)"
  case "${n:-}" in ''|*[!0-9]*) printf '0' ;; *) printf '%s' "$n" ;; esac
}
_tsweep_retire_bump() {
  local ref="$1" n dir
  n="$(_tsweep_retire_count "$ref")"; n=$((n + 1))
  dir="${RETIRE_FILE%/*}"
  [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null || { printf '%s' "$n"; return 0; }
  if [ -s "$RETIRE_FILE" ]; then
    awk -v r="$ref" '$1!=r{print}' "$RETIRE_FILE" > "$RETIRE_FILE.tmp" 2>/dev/null \
      && mv "$RETIRE_FILE.tmp" "$RETIRE_FILE"
  fi
  printf '%s %s\n' "$ref" "$n" >> "$RETIRE_FILE" 2>/dev/null || true
  printf '%s' "$n"
}
_tsweep_retire_clear() {
  [ -s "$RETIRE_FILE" ] || return 0
  awk -v r="$1" '$1!=r{print}' "$RETIRE_FILE" > "$RETIRE_FILE.tmp" 2>/dev/null \
    && mv "$RETIRE_FILE.tmp" "$RETIRE_FILE" || true
}

# _tsweep_retired REF — true iff REF already carries a terminal 4-column `retired` row in $LEDGER.
_tsweep_retired() {
  [ -n "${1:-}" ] || return 1
  [ -s "$LEDGER" ] || return 1
  awk -v r="$1" '$2==r && NF==4 && $4=="retired"{f=1} END{exit !f}' "$LEDGER" 2>/dev/null
}

# _tsweep_mark_retired REF PR — journal ONE tracker_reconcile_retired event (the ref survives in the
# journal + the ledger even though the console row will age out), ledger a terminal 4-column `retired`
# row (reusing _tsweep_record's existing marker column — byte-compatible with every other 3/4-column
# reader), and write ONE calm `retired` console note. console-section.sh classifies `retired` as CALM
# (age out after CONSOLE_ROW_RETENTION), unlike `escalated`'s deliberate loud-forever — this is the
# whole point of the leg.
_tsweep_mark_retired() {
  local ref="$1" pr="$2"
  journal_append tracker_reconcile_retired ref "$ref" pr "$pr" component sweep \
    reason "retired: pre-switch ref"
  _tsweep_record "$ref" "$pr" retired
  _tsweep_note retired "$ref" "$pr" unknown
  _tsweep_retire_clear "$ref"
  echo "tracker-state-sweep: $ref retired (HERD-624) — its unresolvable state has aged out; the console row will clear on the normal calm retention window."
}

# _tsweep_age_unresolvable_to_retired — the per-sweep pass: every DISTINCT ref currently ledgered
# `unresolvable` (and not already `retired`) has sat there N sweeps; once that reaches
# _TSWEEP_RETIRE_AFTER it graduates. Runs unconditionally (independent of _merged_refs/gh) because it
# operates purely on $LEDGER's own already-ledgered rows, not on a fresh PR scan.
_tsweep_age_unresolvable_to_retired() {
  [ -s "$LEDGER" ] || return 0
  local ref pr n
  while IFS=' ' read -r _ ref pr _marker; do
    [ -n "${ref:-}" ] && [ "${_marker:-}" = "unresolvable" ] || continue
    _tsweep_retired "$ref" && continue
    n="$(_tsweep_retire_bump "$ref")"
    [ "$n" -ge "$_TSWEEP_RETIRE_AFTER" ] && _tsweep_mark_retired "$ref" "$pr"
  done < <(awk 'NF==4 && $4=="unresolvable"{print}' "$LEDGER" 2>/dev/null | awk '!seen[$2]++')
  return 0
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

# ── HERD-613 LEG 3: one-time migration — drop two known-malformed historical rows ──────────────────
# PRs 712/719 (epochs 1785994821 / 1785998819) escalated on a comma-joined TEST-FILENAME "ref" — never
# a tracker id — before LEG 2's shape guard existed to keep it out of NOTE_FILE in the first place, and
# before the auto-retire leg below existed to clear it off the console. Named by epoch, NOT a live
# pattern match — a genuine future escalation must never be silently swept by a broad filter. Idempotent:
# once these two rows are gone, every future run is a no-op (nothing matches, the file is untouched).
_TSWEEP_MIGRATE_DROP_EPOCHS="1785994821 1785998819"
_tsweep_migrate_drop_epochs() {
  [ -s "$NOTE_FILE" ] || return 0
  local e hit=0
  for e in $_TSWEEP_MIGRATE_DROP_EPOCHS; do
    grep -q "^${e} " "$NOTE_FILE" 2>/dev/null && hit=1
  done
  [ "$hit" -eq 1 ] || return 0
  local tmp="$NOTE_FILE.tmp.$$"
  EPOCHS="$_TSWEEP_MIGRATE_DROP_EPOCHS" awk '
    BEGIN { n = split(ENVIRON["EPOCHS"], a, " "); for (i = 1; i <= n; i++) drop[a[i]] = 1 }
    !($1 in drop)
  ' "$NOTE_FILE" > "$tmp" 2>/dev/null && mv "$tmp" "$NOTE_FILE" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  echo "tracker-state-sweep: HERD-613 one-time migration — dropped the two known-malformed PR-712/719 heal rows."
}

# ── HERD-613 LEG 3: auto-retire — an escalated row whose ref FAILS the shape guard clears itself ───
# tracker-state-sweep.sh's own _tsweep_mark_unresolvable (HERD-502) writes exactly ONE `escalated` row
# per ref it gives up on — necessarily loud (console-section.sh never ages an escalated row out on its
# own), because most escalations are a real, standing problem an operator must see. But a ref that
# FAILS pr-ref.sh's HERD-613 per-backend shape guard can never be a real tracker id in the first place
# (PRs 712/719's comma-joined test filenames) — no operator action will ever make it resolve, so
# leaving it loud forever just trains the operator to ignore the section. Auto-ack it: the SAME
# mechanism `herd tracker-heals ack` uses (an exact ledger-line match in ACK_FILE), so the console
# clears immediately while the ledger — and the journal's original tracker_state_unresolvable event —
# keep the full history. GUARDRAIL: a VALID-shaped ref that genuinely will not resolve is untouched by
# this loop — it stays loud, exactly as HERD-502 designed it, because only a shape-invalid ref can ever
# reach this branch.
_tsweep_auto_retire_shape_invalid() {
  [ -s "$NOTE_FILE" ] || return 0
  local backend="${SCRIBE_BACKEND:-file}" line epoch status ref rest dir
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    epoch="" status="" ref="" rest=""
    read -r epoch status ref rest <<EOF
$line
EOF
    [ "${status:-}" = "escalated" ] || continue
    [ -n "${ref:-}" ] || continue
    herd_pr_ref_shape_ok "$ref" "$backend" && continue    # a valid-shaped ref stays loud — never touched
    herd_console_acked "$ACK_FILE" "$line" && continue     # already acked (manually or a prior sweep)
    dir="${ACK_FILE%/*}"
    [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null || continue
    printf '%s\n' "$line" >> "$ACK_FILE" 2>/dev/null || continue
    echo "tracker-state-sweep: auto-retired escalated row for '$ref' — its ref fails the SCRIBE_BACKEND=$backend shape guard and can never resolve (HERD-613)."
  done < "$NOTE_FILE"
  herd_console_trim "$ACK_FILE"
}

_tsweep_migrate_drop_epochs
_tsweep_auto_retire_shape_invalid

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

# HERD-624 LEG 2: age any ref that has sat `unresolvable` in $LEDGER long enough to a terminal
# `retired` state. Independent of the scan above (it reads $LEDGER's own rows, not a fresh PR list),
# so it still runs on a sweep that finds nothing new to heal.
_tsweep_age_unresolvable_to_retired

if [ "$healed" -eq 0 ] && [ "$failed" -eq 0 ] && [ "$unresolvable" -eq 0 ]; then
  echo "tracker-state-sweep: no tracker drift — $scanned merged ref(s) scanned, $checked re-checked, all Done. Nothing to heal."
else
  echo "tracker-state-sweep: healed $healed, $failed still unhealed, $unresolvable unresolvable (of $checked re-checked / $scanned scanned)."
fi
exit 0
