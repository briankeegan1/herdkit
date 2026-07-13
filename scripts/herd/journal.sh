#!/usr/bin/env bash
# journal.sh — the herdkit engine journal: an append-only JSONL record of every key gate event
# (review dispatch, verdict, healthcheck attempt/outcome, refix bounce, merge, reap, reload, infra
# death). It is the forensic substrate for `herd why <pr>` and `herd log` — post-mortem eyes on a
# gate after the fact, instead of process archaeology.
#
# Sourced (never executed) by engine components AFTER herd-config.sh, which provides WORKTREES_DIR:
#   . "$HERE/herd-config.sh"
#   . "$HERE/journal.sh"
# then, at any key step:
#   journal_append review_dispatched pr "$pr" sha "$sha" pid "$pid" model "$model"
#
# CONTRACT (why this file is safe to sprinkle everywhere):
#   • BEST-EFFORT, SILENT: every operation is wrapped so it can NEVER break, slow-fault, or abort a
#     caller — even a caller running under `set -euo pipefail`. An unwritable journal (read-only FS,
#     missing dir it can't create, no python3) simply drops the entry. journal_append ALWAYS returns 0.
#   • ATOMIC SINGLE-LINE APPENDS: each event is one JSON object written with a single O_APPEND
#     printf. Lines stay well under PIPE_BUF (4 KiB), so concurrent writers (watcher + reviewers +
#     CLI) interleave whole lines, never shredded fragments. No lockfile needed.
#   • ONE JSON OBJECT PER LINE: always carries "ts" (ISO-8601 UTC) and "event"; extra key/value
#     pairs follow. Integer-looking values are emitted as JSON numbers, everything else as strings.
#   • SELF-ROTATING: before each append, if the journal has grown past JOURNAL_MAX_MB it is renamed
#     to journal-<stamp>.jsonl and archives older than JOURNAL_KEEP_DAYS are pruned. Never unbounded.

# _journal_ts — THE SINGLE SOURCE of every journal timestamp: ISO-8601 UTC, always Z-suffixed.
# Every journal write derives its ts here and NOWHERE else — no caller (and no other writer on any
# path, including the auto-refix bounce) formats its own time. This is deliberate: a writer that used
# a local clock — `date` without -u — while stamping a Z suffix once emitted a *future* Z timestamp
# (local wall-clock + tz offset, labelled UTC), poisoning `herd why` chronology and any ts-sorted
# tooling (the HERD-42 scorer parses this journal). Routing all writes through one -u helper makes
# that class of bug unrepresentable. A test seam, HERD_JOURNAL_NOW, overrides the clock outright with
# a caller-supplied ISO string so a unit can assert a deterministic ts; it defaults to `date -u`.
_journal_ts() {
  if [ -n "${HERD_JOURNAL_NOW:-}" ]; then printf '%s' "$HERD_JOURNAL_NOW"; return 0; fi
  date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null
}

# _journal_in_test_context — HERD-223: is this process a hermetic test (or a child of one)?
# True when any of the suite/test signals is set. Those vars are NEVER set in production lanes
# (watcher, builders, CLI on a real project) — the dogfood healthcheck / CI suite / individual
# hermetic tests set them. Used only as a fail-safe redirect so a forgotten JOURNAL_FILE export
# cannot pollute the live project journal. INERT in production.
_journal_in_test_context() {
  # Use ${VAR-} (no colon) so the caps-sync ghost scan does not treat these as config knobs;
  # HERD_* is already exempt, but HERMETIC_TEST / BATS_* are plain test harness signals.
  [ -n "${HERMETIC_TEST-}" ] && return 0
  [ -n "${HERD_HERMETIC_GUARD-}" ] && return 0
  [ -n "${HERD_JOURNAL_HERMETIC-}" ] && return 0
  [ -n "${BATS_TEST_FILENAME-}" ] && return 0
  [ -n "${BATS_TEST_NAME-}" ] && return 0
  return 1
}

# _journal_path_is_verdict <path> — TRUE when a path-typed value is actually a REVIEWER VERDICT that
# leaked into a filesystem seam (HERD-360). Two tells, neither of which any legitimate journal path
# carries: it begins with the literal 'REVIEW:' verdict prefix, or it contains an embedded newline.
# Cheap + pure (no subshell), so it is safe to call on every _journal_file resolution.
_journal_path_is_verdict() {
  case "$1" in
    "REVIEW:"*) return 0 ;;
  esac
  case "$1" in
    *"
"*) return 0 ;;   # an embedded newline — a verdict/multiline blob, never a real path
  esac
  return 1
}

# _journal_reject_verdict_path <bad-path> — a verdict-shaped value reached the journal path seam. Point
# this process's journal at a SAFE per-process fallback (deterministic from $$, never the bad path) and
# record ONE loud infra_event there naming the offending value (truncated + newline-stripped so it can
# never itself re-contaminate a path). Idempotent per process via a file-presence check (the redirect
# variable cannot persist — journal_append runs _journal_impl in a subshell — so the guard is on disk).
_journal_reject_verdict_path() {
  _HERD_JOURNAL_VERDICT_REDIRECT="${TMPDIR:-/tmp}/herd-journal-verdict-reject-$$.jsonl"
  if ! grep -q 'verdict-shaped journal path rejected' "$_HERD_JOURNAL_VERDICT_REDIRECT" 2>/dev/null; then
    # Neutralize the bad seam INSIDE this subshell (JOURNAL_FILE = the clean fallback, WORKTREES_DIR
    # empty) so this append resolves straight to the fallback and never re-enters the reject branch.
    ( JOURNAL_FILE="$_HERD_JOURNAL_VERDICT_REDIRECT" WORKTREES_DIR="" \
        journal_append infra_event component journal \
          reason "verdict-shaped journal path rejected (HERD-360) — channel leak, never mkdir'd" \
          offending "$(printf '%.160s' "$1" | tr '\n' ' ')" ) 2>/dev/null || true
  fi
  return 0
}

# _journal_file — resolve the journal path LAZILY on every call, so a component that sets
# WORKTREES_DIR after sourcing (the hermetic tests do) still lands in the right place. A test seam,
# JOURNAL_FILE, overrides the derived path outright. Empty output ⇒ no destination ⇒ caller drops.
#
# HERD-223 GUARD: when a test context has NOT exported JOURNAL_FILE, do NOT fall through to
# $WORKTREES_DIR/.herd/journal.jsonl — that path is almost always the REAL project journal
# (a test inside a worktree sources the committed .herd/config, which pins WORKTREES_DIR to the
# main checkout's pool). Fail-safe redirect to a throwaway per-process file under TMPDIR instead.
# Production is byte-identical: the test signals are unset, so the historical path is used.
#
# HERD-360 CHANNEL GUARD: a journal path is a FILESYSTEM path; a reviewer VERDICT is not. A severed
# review prints 'REVIEW: INFRA-FAIL — … (SIGTERM/SIGPIPE) …' to stdout, and a caller that captures that
# stdout into a path-typed variable (JOURNAL_FILE / WORKTREES_DIR) once fed it straight into the mkdir
# in _journal_impl — mkdir -p split it at the 'SIGTERM/SIGPIPE' slash and grew a stray dir tree in the
# shared checkout. REFUSE any resolved path that is verdict-shaped: redirect this process's journal to a
# safe fallback and record ONE loud infra_event there, so the leak is visible but NEVER becomes a
# filesystem call. Production paths are never verdict-shaped, so this branch is byte-inert on real lanes.
_journal_file() {
  local _jf=""
  if [ -n "${JOURNAL_FILE:-}" ]; then
    _jf="$JOURNAL_FILE"
  elif _journal_in_test_context; then
    # Stable per-process redirect so concurrent appends inside one test land in one file.
    if [ -z "${_HERD_TEST_JOURNAL_REDIRECT:-}" ]; then
      _HERD_TEST_JOURNAL_REDIRECT="${TMPDIR:-/tmp}/herd-test-journal-$$.jsonl"
    fi
    _jf="$_HERD_TEST_JOURNAL_REDIRECT"
  elif [ -n "${WORKTREES_DIR:-}" ]; then
    _jf="$WORKTREES_DIR/.herd/journal.jsonl"
  else
    return 1
  fi
  if _journal_path_is_verdict "$_jf"; then
    _journal_reject_verdict_path "$_jf"
    printf '%s' "$_HERD_JOURNAL_VERDICT_REDIRECT"
    return 0
  fi
  printf '%s' "$_jf"
  return 0
}

# _journal_max_bytes — rotation threshold. JOURNAL_MAX_BYTES (test seam) wins; else JOURNAL_MAX_MB
# (default 10) × 1 MiB. Bash arithmetic is integer, so the byte seam lets tests trigger rotation
# without writing 10 MB of events.
_journal_max_bytes() {
  if [ -n "${JOURNAL_MAX_BYTES:-}" ]; then printf '%s' "$JOURNAL_MAX_BYTES"; return 0; fi
  local mb="${JOURNAL_MAX_MB:-10}"
  case "$mb" in ''|*[!0-9]*) mb=10 ;; esac
  printf '%s' "$(( mb * 1048576 ))"
}

# _journal_impl — the real work, run inside a strict-mode-neutralized subshell by journal_append.
# May exit non-zero / early at any point; the wrapper absorbs it.
_journal_impl() {
  local event="${1:-}"; [ -n "$event" ] || return 0
  shift || true

  local jf; jf="$(_journal_file)" || return 0
  [ -n "$jf" ] || return 0
  local dir="${jf%/*}"

  # Rotate an oversized journal BEFORE appending (best-effort; a failed rotate still lets us append).
  if [ -f "$jf" ]; then
    local sz max
    sz="$(wc -c < "$jf" 2>/dev/null | tr -cd '0-9')"; sz="${sz:-0}"
    max="$(_journal_max_bytes)"
    if [ "$sz" -ge "$max" ] 2>/dev/null; then
      local stamp base archive n
      stamp="$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || echo rotated)"
      base="${jf##*/}"
      # Pick an archive name that does NOT already exist: the stamp is only second-resolution, so two
      # rotations within the same second (rapid growth, or a small threshold) would otherwise collide
      # and the second mv would clobber the first archive — losing events. Disambiguate with pid + a
      # counter until the name is free.
      archive="$dir/${base%.jsonl}-${stamp}.jsonl"
      n=0
      while [ -e "$archive" ]; do
        n=$((n + 1))
        archive="$dir/${base%.jsonl}-${stamp}-$$-${n}.jsonl"
      done
      # mv is atomic; a racing second writer that finds no journal just skips rotation.
      mv "$jf" "$archive" 2>/dev/null || true
      # Prune archives older than the retention window.
      find "$dir" -maxdepth 1 -type f -name "${base%.jsonl}-*.jsonl" \
        -mtime "+${JOURNAL_KEEP_DAYS:-30}" -delete 2>/dev/null || true
    fi
  fi

  [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null || return 0

  # Encode via python3 for correct JSON escaping of arbitrary values (stderr tails carry quotes,
  # backslashes, and control bytes). ts comes from the ONE shared UTC helper (_journal_ts) so the
  # object always has a real, UTC timestamp — never a caller-formatted or local-clock one.
  local line ts
  ts="$(_journal_ts)" || return 0
  [ -n "$ts" ] || return 0
  line="$(HERD_J_EVENT="$event" HERD_J_TS="$ts" python3 -c '
import sys, json, os
obj = {"ts": os.environ["HERD_J_TS"], "event": os.environ["HERD_J_EVENT"]}
a = sys.argv[1:]
for i in range(0, len(a) - 1, 2):
    k = a[i]
    v = a[i + 1]
    # Emit clean integers as JSON numbers (pid, exit_code, attempt, pr); everything else as a string.
    if v and (v.lstrip("-").isdigit()):
        try:
            obj[k] = int(v)
            continue
        except ValueError:
            pass
    obj[k] = v
sys.stdout.write(json.dumps(obj, separators=(",", ":"), ensure_ascii=False))
' "$@" 2>/dev/null)" || return 0
  [ -n "$line" ] || return 0

  # Single-write atomic append. O_APPEND + a sub-PIPE_BUF line ⇒ concurrent-writer safe.
  printf '%s\n' "$line" >> "$jf" 2>/dev/null || return 0
  return 0
}

# journal_append <event_type> [key value]... — append one event. The PUBLIC entry point.
# Runs the implementation in a subshell with strict modes disabled so NOTHING it does — a failed
# python3, a read-only journal, a set -e caller — can propagate out. Always returns 0.
journal_append() {
  ( set +e +u +o pipefail 2>/dev/null || true; _journal_impl "$@" ) >/dev/null 2>&1 || true
  return 0
}
