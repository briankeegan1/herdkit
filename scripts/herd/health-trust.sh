#!/usr/bin/env bash
# health-trust.sh — THE shared SHA-MATCHED BUILDER-LOCAL HEALTH TRUST library (HERD-531).
#
# THE COST THIS EXISTS TO CUT: the health gate is the pipeline's dominant expense (~350 hermetic
# tests, 20-60 min per suite). When a builder runs the HEAVY profile itself before opening its PR,
# the watcher then re-runs that IDENTICAL suite against the IDENTICAL commit — the same tests, the
# same tree, the same box — and pays for it twice. Nothing recorded that the first run happened, so
# the second run had no way to know it was redundant.
#
# WHAT THIS ADDS: an ENGINE-AUTHORED PROVENANCE RECORD. When a heavy healthcheck completes, the
# shared healthcheck entry (scripts/herd/healthcheck.sh) writes one row into the shared worktree
# pool describing what was proven — sha, worktree, profile, outcome, duration, provenance and
# whether the working tree was clean. The watcher's health dispatch (agent-watch.sh) reads that row
# and, ONLY when it attests a CLEAN heavy run of the EXACT head sha from a CLEAN tree at the SAME
# worktree, downgrades its own run to the LIGHT profile as a smoke and journals `health_trusted`.
#
# TRUST IS FAIL-CLOSED BY CONSTRUCTION. Every one of these is a full re-run, exactly as today:
#   • HEALTH_TRUST_BUILDER off (the default — see the dormancy note below)
#   • no record for this sha, an unreadable/short/garbled record, or an empty sha
#   • a record whose recorded sha is not THIS head sha (stale — the builder ran an older commit)
#   • profile != heavy (a light record proves nothing about the full suite)
#   • outcome != CLEAN (a CODEERROR or a tolerated-but-noted DATAENV run is never trusted)
#   • provenance != builder-local (the watcher's OWN runs are stamped `watcher` so a trusted run can
#     never be used to justify the next trusted run — trust always traces back to a real heavy suite)
#   • tree_state != clean (the builder's heavy run tested UNCOMMITTED edits; the sha alone does not
#     describe what actually ran)
#   • the record's worktree path is not the worktree the watcher is about to gate
#   • the record predates the commit it claims to attest (it cannot have tested a commit that did
#     not exist yet — this is the "record older than the sha's push" case), or the commit's own
#     timestamp cannot be resolved at all
#
# SHIP-DORMANT: HEALTH_TRUST_BUILDER defaults to off, and off is a HARD no-op on BOTH sides — no
# record is written (zero filesystem side effects in the shared pool) and no record is read. The
# single key gates the writer and the reader together on purpose: they share one project config, so
# a project that has not opted in behaves byte-identically to before this library existed.
#
# ── the record ────────────────────────────────────────────────────────────────────────────────────
#   $WORKTREES_DIR/.health-provenance-<sha>   one TAB-separated line, 8 fields:
#     1 sha         the HEAD sha the suite ran against
#     2 worktree    absolute path of the tree the suite ran in
#     3 profile     heavy | light
#     4 outcome     CLEAN | DATAENV | CODEERROR
#     5 duration    wall-clock seconds of the run
#     6 provenance  builder-local | watcher
#     7 tree_state  clean | dirty  (git status --porcelain at record time)
#     8 epoch       when the record was written
#   Keyed by SHA ALONE (not pr+sha): a builder does not know its PR number — the PR may not exist
#   yet when the pre-PR heavy run finishes. The watcher joins on (candidate head sha, worktree).
#
# Functions (sourced, never executed):
#   herd_health_trust_on                       — 0 iff HEALTH_TRUST_BUILDER is on
#   herd_health_trust_file <trees> <sha>       — the record path for one sha
#   herd_health_trust_write <trees> <sha> <worktree> <profile> <outcome> <duration> [provenance]
#   herd_health_trust_check <trees> <sha> <worktree>
#                                              — 0 = TRUSTED (prints the record's provenance),
#                                                1 = not trusted ($HERD_HEALTH_TRUST_REASON says why)
#
# FAIL-SOFT throughout: an unset/missing WORKTREES_DIR, an unwritable pool, a missing git — every one
# of them is a silent skip on the write side and a plain "not trusted" (⇒ full re-run) on the read
# side. This library never aborts a caller running under `set -euo pipefail` and never reds a gate.

# The last herd_health_trust_check verdict's one-line why (for a journal/console note).
HERD_HEALTH_TRUST_REASON=""

# herd_health_trust_on — the lever. Unrecognized values read as OFF (a typo can never arm a path
# that SKIPS the authoritative suite: fail toward running the full gate).
herd_health_trust_on() {
  case "$(printf '%s' "${HEALTH_TRUST_BUILDER:-off}" | tr '[:upper:]' '[:lower:]')" in
    1|true|on|yes|enable|enabled) return 0 ;;
    *) return 1 ;;
  esac
}

# _herd_health_trust_abspath <path> — the PHYSICAL absolute path of <path>, used to normalize the
# worktree on BOTH the write and the check side. The builder is handed the worktree by one route
# (the lane's own `$WORKTREES_DIR/<slug>`) and the watcher by another, and on macOS a pool under
# /tmp resolves to /private/tmp for one of them — a raw string compare would then refuse a perfectly
# good record forever. Normalizing identically on both sides makes the comparison mean what it says.
# Falls back to the raw argument when the path cannot be entered (fail-soft; the compare then simply
# stays a string compare, i.e. today's conservative behavior).
_herd_health_trust_abspath() {
  local _ha_p="${1:-}" _ha_r
  [ -n "$_ha_p" ] || return 0
  _ha_r="$(cd "$_ha_p" 2>/dev/null && pwd -P 2>/dev/null)" || _ha_r=""
  printf '%s' "${_ha_r:-$_ha_p}"
}

# herd_health_trust_file <trees-dir> <sha> — the provenance record path. Empty (and rc 1) when
# either argument is empty, so a caller can never write to a `/.health-provenance-` stub.
herd_health_trust_file() {
  local _ht_trees="${1:-}" _ht_sha="${2:-}"
  [ -n "$_ht_trees" ] && [ -n "$_ht_sha" ] || return 1
  printf '%s' "${_ht_trees%/}/.health-provenance-$_ht_sha"
}

# herd_health_trust_write <trees> <sha> <worktree> <profile> <outcome> <duration> [provenance]
# Write (atomically: temp + mv, mirroring the gate's own dispatch-file discipline) one provenance
# row. tree_state is derived HERE, from the worktree itself, so a caller can never claim a clean
# tree it did not have. Silent no-op when the lever is off, when the pool is unusable, or when any
# required field is empty. Always returns 0 — a provenance record is an OPTIMIZATION, never a gate.
herd_health_trust_write() {
  herd_health_trust_on || return 0
  local _ht_trees="${1:-}" _ht_sha="${2:-}" _ht_wt="${3:-}" _ht_prof="${4:-}" _ht_out="${5:-}"
  local _ht_dur="${6:-0}" _ht_prov="${7:-builder-local}" _ht_f _ht_state="dirty" _ht_dirty
  [ -n "$_ht_trees" ] && [ -d "$_ht_trees" ] || return 0
  [ -n "$_ht_sha" ] && [ -n "$_ht_wt" ] && [ -n "$_ht_prof" ] && [ -n "$_ht_out" ] || return 0
  case "$_ht_dur" in ''|*[!0-9]*) _ht_dur=0 ;; esac
  # A tree with NO uncommitted change is the only tree whose sha fully describes what ran. `git
  # status --porcelain` is empty exactly then; any failure (no git, not a checkout) leaves the
  # default "dirty", which the reader refuses — fail-closed, never fail-open.
  if _ht_dirty="$(git -C "$_ht_wt" status --porcelain 2>/dev/null)"; then
    [ -n "$_ht_dirty" ] || _ht_state="clean"
  fi
  _ht_wt="$(_herd_health_trust_abspath "$_ht_wt")"
  _ht_f="$(herd_health_trust_file "$_ht_trees" "$_ht_sha")" || return 0
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$_ht_sha" "$_ht_wt" "$_ht_prof" "$_ht_out" "$_ht_dur" "$_ht_prov" "$_ht_state" "$(date +%s)" \
    > "$_ht_f.tmp.$$" 2>/dev/null && mv "$_ht_f.tmp.$$" "$_ht_f" 2>/dev/null
  rm -f "$_ht_f.tmp.$$" 2>/dev/null || true
  # PRUNE: a record is keyed by SHA, so nothing else ever reclaims one — every commit that ran a heavy
  # suite would leave a file in the shared pool forever. A record can only ever be honored for a PR's
  # CURRENT head, so anything older than HERD_HEALTH_TRUST_KEEP_DAYS (default 7) is dead weight.
  # Pruning here, on the write path, keeps the pool bounded without adding a sweep the watcher must
  # remember to run. Fail-soft: a find that cannot run just leaves the files.
  local _ht_keep="${HERD_HEALTH_TRUST_KEEP_DAYS:-7}"
  case "$_ht_keep" in ''|*[!0-9]*) _ht_keep=7 ;; esac
  find "$_ht_trees" -maxdepth 1 -name '.health-provenance-*' -mtime "+$_ht_keep" \
    -exec rm -f {} + 2>/dev/null || true
  return 0
}

# herd_health_trust_check <trees> <sha> <worktree> — is there a record that EARNS a skip of the full
# re-run for this exact (sha, worktree)? Prints the record's provenance token on stdout and returns 0
# when trusted; returns 1 otherwise with $HERD_HEALTH_TRUST_REASON naming the disqualifier (every
# such case is a full re-run, exactly as before this library). Read-only; never mutates the record.
herd_health_trust_check() {
  HERD_HEALTH_TRUST_REASON=""
  local _ht_trees="${1:-}" _ht_sha="${2:-}" _ht_wt="${3:-}" _ht_f _ht_line
  local _ht_rsha _ht_rwt _ht_prof _ht_out _ht_dur _ht_prov _ht_state _ht_epoch _ht_ct

  if ! herd_health_trust_on; then HERD_HEALTH_TRUST_REASON="lever off"; return 1; fi
  if [ -z "$_ht_sha" ]; then HERD_HEALTH_TRUST_REASON="no head sha"; return 1; fi
  if ! _ht_f="$(herd_health_trust_file "$_ht_trees" "$_ht_sha")"; then
    HERD_HEALTH_TRUST_REASON="no worktree pool"; return 1
  fi
  if [ ! -f "$_ht_f" ]; then HERD_HEALTH_TRUST_REASON="no record for sha"; return 1; fi

  IFS= read -r _ht_line < "$_ht_f" 2>/dev/null || _ht_line=""
  IFS=$'\t' read -r _ht_rsha _ht_rwt _ht_prof _ht_out _ht_dur _ht_prov _ht_state _ht_epoch <<EOF
$_ht_line
EOF
  # A truncated/garbled record proves nothing — an interrupted write, or a format from another
  # engine version. Refuse it rather than guessing at the missing fields.
  if [ -z "${_ht_epoch:-}" ]; then HERD_HEALTH_TRUST_REASON="malformed record"; return 1; fi
  case "$_ht_epoch" in ''|*[!0-9]*) HERD_HEALTH_TRUST_REASON="malformed record"; return 1 ;; esac

  # STALE SHA: the record must name the very commit being gated. (The filename already carries the
  # sha, but a record whose BODY disagrees with its own name is corrupt, not merely stale.)
  if [ "$_ht_rsha" != "$_ht_sha" ]; then HERD_HEALTH_TRUST_REASON="stale sha in record"; return 1; fi
  if [ "$_ht_prof" != "heavy" ]; then HERD_HEALTH_TRUST_REASON="profile=$_ht_prof (not heavy)"; return 1; fi
  if [ "$_ht_out" != "CLEAN" ]; then HERD_HEALTH_TRUST_REASON="outcome=$_ht_out (not CLEAN)"; return 1; fi
  if [ "$_ht_prov" != "builder-local" ]; then
    HERD_HEALTH_TRUST_REASON="provenance=$_ht_prov (not builder-local)"; return 1
  fi
  if [ "$_ht_state" != "clean" ]; then
    HERD_HEALTH_TRUST_REASON="tree_state=$_ht_state (uncommitted edits at run time)"; return 1
  fi
  if [ -n "$_ht_wt" ]; then
    _ht_wt="$(_herd_health_trust_abspath "$_ht_wt")"
    if [ "$_ht_rwt" != "$_ht_wt" ]; then
      HERD_HEALTH_TRUST_REASON="record worktree $_ht_rwt != $_ht_wt"; return 1
    fi
  fi

  # RECORD-OLDER-THAN-THE-SHA: a record written BEFORE the commit exists cannot have tested it (a
  # recycled path, a clock skew, a hand-forged file). Resolve the commit's own timestamp from the
  # worktree; an unresolvable commit is refused too — we never trust what we cannot date.
  _ht_ct="$(git -C "${_ht_wt:-$_ht_rwt}" show -s --format=%ct "$_ht_sha" 2>/dev/null)"
  case "${_ht_ct:-}" in
    ''|*[!0-9]*) HERD_HEALTH_TRUST_REASON="commit time unresolvable"; return 1 ;;
  esac
  if [ "$_ht_epoch" -lt "$_ht_ct" ] 2>/dev/null; then
    HERD_HEALTH_TRUST_REASON="record predates the commit"; return 1
  fi

  printf '%s' "$_ht_prov"
  return 0
}
