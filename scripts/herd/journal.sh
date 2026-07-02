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

# _journal_file — resolve the journal path LAZILY on every call, so a component that sets
# WORKTREES_DIR after sourcing (the hermetic tests do) still lands in the right place. A test seam,
# JOURNAL_FILE, overrides the derived path outright. Empty output ⇒ no destination ⇒ caller drops.
_journal_file() {
  if [ -n "${JOURNAL_FILE:-}" ]; then printf '%s' "$JOURNAL_FILE"; return 0; fi
  [ -n "${WORKTREES_DIR:-}" ] || return 1
  printf '%s' "$WORKTREES_DIR/.herd/journal.jsonl"
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
  # backslashes, and control bytes). ts is computed here so the object always has a real timestamp.
  local line ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" || return 0
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
