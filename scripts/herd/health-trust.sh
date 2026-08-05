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
# ── the record (FORMAT VERSION 2, HERD-560) ──────────────────────────────────────────────────────
#   $WORKTREES_DIR/.health-provenance-<sha>   one TAB-separated line, 10 fields:
#     1  version      the record format — literal "2"
#     2  sha          the HEAD sha the suite ran against
#     3  worktree     absolute path of the tree the suite ran in
#     4  profile      heavy | light
#     5  outcome      CLEAN | DATAENV | CODEERROR
#     6  duration     wall-clock seconds of the run
#     7  provenance   builder-local | watcher
#     8  tree_state   clean | dirty  (git status --porcelain at record time)
#     9  epoch        written-at stamp — when the record was written
#     10 log_digest   sha256 of the companion suite-log file (below), or "-" for a non-CLEAN outcome
#   Keyed by SHA ALONE (not pr+sha): a builder does not know its PR number — the PR may not exist
#   yet when the pre-PR heavy run finishes. The watcher joins on (candidate head sha, worktree).
#
#   $WORKTREES_DIR/.health-provenance-log-<sha>   the RAW suite log the run produced, written ONLY
#   for a CLEAN outcome (the record's whole claim is "this exact suite ran clean" — a non-CLEAN run's
#   log proves nothing an outcome=CODEERROR/DATAENV record doesn't already say). The reader re-hashes
#   this file and refuses the record when it is missing or its content no longer matches log_digest —
#   evidence with nothing behind it is not evidence. Pruned alongside the record by the same
#   HEALTH_TRUST_KEEP_DAYS sweep below (its name still matches the `.health-provenance-*` glob).
#
#   A pre-HERD-560 record (8 fields, no version) or a record naming an UNRECOGNIZED version reads as
#   ABSENT — exactly as if this sha had no record at all — never as an error: an engine upgrade must
#   never turn a stale-format leftover into a red gate, only into a full re-run.
#
#   FRESHNESS WINDOW: even a well-formed, digest-matched CLEAN record is refused when it is STALE —
#   either older than HEALTH_TRUST_MAX_AGE_SECS (default 21600s / 6h: the world may have moved on
#   since — a dependency bump, a config drift — that only a fresh suite run would see), or written
#   BEFORE the commit it claims to attest existed (the "record predates the branch's newest push"
#   case: a record cannot have tested a commit that did not exist yet).
#
# Functions (sourced, never executed):
#   herd_health_trust_on                       — 0 iff HEALTH_TRUST_BUILDER is on
#   herd_health_trust_file <trees> <sha>       — the record path for one sha
#   herd_health_trust_log_file <trees> <sha>   — the companion suite-log path for one sha
#   herd_health_trust_write <trees> <sha> <worktree> <profile> <outcome> <duration> [provenance] [log]
#   herd_health_trust_check <trees> <sha> <worktree>
#                                              — 0 = TRUSTED (prints the record's provenance),
#                                                1 = not trusted ($HERD_HEALTH_TRUST_REASON says why)
#
# FAIL-SOFT throughout: an unset/missing WORKTREES_DIR, an unwritable pool, a missing git, no sha256
# tool on PATH — every one of them is a silent skip on the write side and a plain "not trusted" (⇒
# full re-run) on the read side. This library never aborts a caller running under `set -euo pipefail`
# and never reds a gate.

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

# herd_health_trust_log_file <trees-dir> <sha> — the companion suite-log path a CLEAN record's digest
# is verified against. Same empty-argument contract as herd_health_trust_file.
herd_health_trust_log_file() {
  local _hl_trees="${1:-}" _hl_sha="${2:-}"
  [ -n "$_hl_trees" ] && [ -n "$_hl_sha" ] || return 1
  printf '%s' "${_hl_trees%/}/.health-provenance-log-$_hl_sha"
}

# _herd_health_trust_digest_file <path> — sha256 hex digest of <path>'s CONTENT (never a re-quoted
# string round-trip, so a trailing newline in the log can never desync the write-time and read-time
# hash). Empty on any failure (missing file, no hasher on PATH) — the caller treats "" as "no digest"
# and refuses to trust, never fabricates one. Tries sha256sum (Linux), then shasum -a 256 (macOS),
# then openssl dgst -sha256 (last-resort, everywhere) — whichever is first on PATH wins; the write
# side and the read side each pick independently, but sha256 is one deterministic algorithm so any
# tool computes the identical hex for identical bytes.
_herd_health_trust_digest_file() {
  local _hd_f="${1:-}"
  [ -n "$_hd_f" ] && [ -f "$_hd_f" ] || return 0
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$_hd_f" 2>/dev/null | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$_hd_f" 2>/dev/null | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$_hd_f" 2>/dev/null | awk '{print $NF}'
  fi
}

# herd_health_trust_write <trees> <sha> <worktree> <profile> <outcome> <duration> [provenance] [log]
# Write (atomically: temp + mv, mirroring the gate's own dispatch-file discipline) one provenance
# row, format VERSION 2 (HERD-560). tree_state is derived HERE, from the worktree itself, so a caller
# can never claim a clean tree it did not have. Silent no-op when the lever is off, when the pool is
# unusable, or when any required field is empty. Always returns 0 — a provenance record is an
# OPTIMIZATION, never a gate.
#
# [log] is the raw suite output for THIS run. Only for outcome=CLEAN is it persisted (atomically, same
# temp+mv discipline) to the companion `.health-provenance-log-<sha>` file and hashed into the
# record's log_digest field — a non-CLEAN outcome is never trusted regardless of digest (the reader
# refuses on outcome alone first), so hashing/storing its log buys nothing. Omitted, unreadable, or no
# sha256 tool on PATH → log_digest is "-", never a fabricated hash.
herd_health_trust_write() {
  herd_health_trust_on || return 0
  local _ht_trees="${1:-}" _ht_sha="${2:-}" _ht_wt="${3:-}" _ht_prof="${4:-}" _ht_out="${5:-}"
  local _ht_dur="${6:-0}" _ht_prov="${7:-builder-local}" _ht_log="${8:-}"
  local _ht_f _ht_logf _ht_state="dirty" _ht_dirty _ht_digest="-"
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
  _ht_logf="$(herd_health_trust_log_file "$_ht_trees" "$_ht_sha")"
  if [ "$_ht_out" = "CLEAN" ] && [ -n "$_ht_log" ] && [ -n "$_ht_logf" ]; then
    if printf '%s' "$_ht_log" > "$_ht_logf.tmp.$$" 2>/dev/null; then
      mv "$_ht_logf.tmp.$$" "$_ht_logf" 2>/dev/null
    fi
    rm -f "$_ht_logf.tmp.$$" 2>/dev/null || true
    if [ -f "$_ht_logf" ]; then
      _ht_digest="$(_herd_health_trust_digest_file "$_ht_logf")"
      [ -n "$_ht_digest" ] || _ht_digest="-"
    fi
  fi
  printf '2\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$_ht_sha" "$_ht_wt" "$_ht_prof" "$_ht_out" "$_ht_dur" "$_ht_prov" "$_ht_state" "$(date +%s)" \
    "$_ht_digest" > "$_ht_f.tmp.$$" 2>/dev/null && mv "$_ht_f.tmp.$$" "$_ht_f" 2>/dev/null
  rm -f "$_ht_f.tmp.$$" 2>/dev/null || true
  # PRUNE: a record is keyed by SHA, so nothing else ever reclaims one — every commit that ran a heavy
  # suite would leave a file in the shared pool forever. A record can only ever be honored for a PR's
  # CURRENT head, so anything older than HERD_HEALTH_TRUST_KEEP_DAYS (default 7) is dead weight.
  # Pruning here, on the write path, keeps the pool bounded without adding a sweep the watcher must
  # remember to run. Fail-soft: a find that cannot run just leaves the files. The glob also matches
  # `.health-provenance-log-*` (a plain prefix of `.health-provenance-*`), so a CLEAN record's
  # companion log is pruned in the same pass without a second -name clause.
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
  local _ht_trees="${1:-}" _ht_sha="${2:-}" _ht_wt="${3:-}" _ht_f _ht_line _ht_nfields
  local _ht_ver _ht_rsha _ht_rwt _ht_prof _ht_out _ht_dur _ht_prov _ht_state _ht_epoch _ht_digest _ht_ct

  if ! herd_health_trust_on; then HERD_HEALTH_TRUST_REASON="lever off"; return 1; fi
  if [ -z "$_ht_sha" ]; then HERD_HEALTH_TRUST_REASON="no head sha"; return 1; fi
  if ! _ht_f="$(herd_health_trust_file "$_ht_trees" "$_ht_sha")"; then
    HERD_HEALTH_TRUST_REASON="no worktree pool"; return 1
  fi
  if [ ! -f "$_ht_f" ]; then HERD_HEALTH_TRUST_REASON="no record for sha"; return 1; fi

  IFS= read -r _ht_line < "$_ht_f" 2>/dev/null || _ht_line=""
  _ht_nfields="$(awk -F'\t' '{print NF}' <<< "$_ht_line")"
  # OLD-FORMAT (pre-HERD-560, 8 fields, no version) reads as ABSENT — never an error: an engine
  # upgrade must never turn a stale-format leftover into a red gate, only into a plain full re-run,
  # exactly as if this sha had no record at all.
  if [ "$_ht_nfields" -eq 8 ]; then
    HERD_HEALTH_TRUST_REASON="old-format record (absent)"; return 1
  fi
  if [ "$_ht_nfields" -ne 10 ]; then
    HERD_HEALTH_TRUST_REASON="malformed record"; return 1
  fi
  IFS=$'\t' read -r _ht_ver _ht_rsha _ht_rwt _ht_prof _ht_out _ht_dur _ht_prov _ht_state _ht_epoch _ht_digest <<EOF
$_ht_line
EOF
  # A truncated/garbled record proves nothing — an interrupted write, or a format from another
  # engine version. Refuse it rather than guessing at the missing fields.
  if [ -z "${_ht_epoch:-}" ]; then HERD_HEALTH_TRUST_REASON="malformed record"; return 1; fi
  case "$_ht_epoch" in ''|*[!0-9]*) HERD_HEALTH_TRUST_REASON="malformed record"; return 1 ;; esac
  # An unrecognized version (a FUTURE format this engine build predates) reads as ABSENT too — the
  # same fail-soft-toward-full-re-run rule as an old-format record, never an error.
  if [ "$_ht_ver" != "2" ]; then
    HERD_HEALTH_TRUST_REASON="old-format record (absent)"; return 1
  fi

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

  # FRESHNESS WINDOW, part 1 — BOUNDED AGE (HERD-560): a record older than HEALTH_TRUST_MAX_AGE_SECS
  # (default 21600s / 6h) cannot be trusted no matter how clean its outcome — the world may have moved
  # on since (a dependency bump, a config drift landing on default) that only a fresh suite run would
  # see. 0/unset stays the pre-HERD-560 unbounded default; a non-numeric override falls back to it too.
  local _ht_maxage="${HEALTH_TRUST_MAX_AGE_SECS:-21600}"
  case "$_ht_maxage" in ''|*[!0-9]*) _ht_maxage=21600 ;; esac
  if [ "$_ht_maxage" -gt 0 ] 2>/dev/null; then
    local _ht_now; _ht_now="$(date +%s 2>/dev/null || echo 0)"
    if [ $(( _ht_now - _ht_epoch )) -gt "$_ht_maxage" ] 2>/dev/null; then
      HERD_HEALTH_TRUST_REASON="record older than ${_ht_maxage}s (stale by age)"; return 1
    fi
  fi

  # FRESHNESS WINDOW, part 2 — RECORD PREDATES THE BRANCH'S NEWEST PUSH: a record written BEFORE the
  # commit exists cannot have tested it (a recycled path, a clock skew, a hand-forged file). Resolve
  # the commit's own timestamp from the worktree; an unresolvable commit is refused too — we never
  # trust what we cannot date.
  _ht_ct="$(git -C "${_ht_wt:-$_ht_rwt}" show -s --format=%ct "$_ht_sha" 2>/dev/null)"
  case "${_ht_ct:-}" in
    ''|*[!0-9]*) HERD_HEALTH_TRUST_REASON="commit time unresolvable"; return 1 ;;
  esac
  if [ "$_ht_epoch" -lt "$_ht_ct" ] 2>/dev/null; then
    HERD_HEALTH_TRUST_REASON="record predates the commit"; return 1
  fi

  # DIGEST (HERD-560): the record's claimed suite-log digest must match the companion log file's
  # ACTUAL content. A missing/unreadable log, or one that no longer hashes to what was recorded,
  # proves nothing and is refused exactly like every disqualifier above — no signing, so this catches
  # a corrupted/truncated/swapped log, never a deliberately forged one (the threat model is staleness,
  # not forgery; see the header).
  local _ht_logf _ht_actual
  _ht_logf="$(herd_health_trust_log_file "$_ht_trees" "$_ht_sha")"
  if [ -z "$_ht_digest" ] || [ "$_ht_digest" = "-" ] || [ -z "$_ht_logf" ] || [ ! -f "$_ht_logf" ]; then
    HERD_HEALTH_TRUST_REASON="no suite log for record"; return 1
  fi
  _ht_actual="$(_herd_health_trust_digest_file "$_ht_logf")"
  if [ -z "$_ht_actual" ] || [ "$_ht_actual" != "$_ht_digest" ]; then
    HERD_HEALTH_TRUST_REASON="digest mismatch"; return 1
  fi

  printf '%s' "$_ht_prov"
  return 0
}
