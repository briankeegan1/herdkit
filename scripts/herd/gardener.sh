#!/usr/bin/env bash
# gardener.sh — the MAINTENANCE GARDENER (HERD-673): a periodic, ADVISORY doc-drift sweep that files
# its own backlog. Composed entirely from shipped primitives — the trigger pack (triggers.sh, HERD-169)
# schedules it, the specialist roster (.herd/agents/docs-gardener.md, HERD-667) gives the weekly agent
# run its persona, and scribe.sh does the actual filing — this file is the ONE deterministic mechanism
# in between: cursor + diff + dedup + cooldown, testable with no LLM in the loop.
#
# CONTRACT — FILES, NEVER EDITS. Each `run` diffs merge events journaled since its OWN stored cursor
# (a byte offset into the project journal, kept under the worktree pool — never committed) against two
# small, deterministic sets:
#   SURFACE  bin/herd, scripts/herd/*.sh, templates/capabilities.tsv, templates/conformance.tsv
#   DOC      README.md, docs/**, templates/*.tmpl
# A merge that touches SURFACE but touches NO file in DOC is real drift: the front door (or a rendered
# rail) plausibly still describes the pre-merge world. Drift is grouped by the SURFACE FILE itself (not
# by PR) so the SAME undocumented file recurring across several merges — in one run, or across several
# weekly runs — collapses into ONE dedup-keyed tracker item quoting every merged PR#, instead of one
# item per PR. Filing goes through scripts/herd/scribe.sh exactly like a human coordinator's request;
# gardener.sh never writes README.md/docs/**/templates/*.tmpl itself. A PER-SIGNATURE FILING COOLDOWN
# (a stamp file per surface-file signature, HERD_GARDENER_COOLDOWN_SECS — default 7d) means a standing,
# still-unaddressed drift is not re-filed every run (the HERD-512 anomaly-rail lesson). Zero findings is
# not silence: it still advances the cursor and journals exactly one `gardener_run findings=0` event.
#
# `--dry-run` previews what WOULD file (surfaced file + evidence + cooldown status) without calling
# scribe.sh, stamping cooldown, or advancing the cursor — safe to run repeatedly.
#
# SHIP-DORMANT: gated behind MAINTENANCE_GARDENER=off (default, herd-config.sh). off → `run` prints one
# disabled notice and returns 0; no journal read, no state dir touched, no scribe call — byte-inert.
# FAIL-SOFT: no journal yet, an unresolvable state dir, a `git` that can't diff a merge sha, or a failed
# scribe.sh enqueue each degrade to "nothing to report for this piece" rather than a hard error — a
# gardener run can never wedge the scheduler that fires it.
#
# Dual-purpose like triggers.sh / scribe.sh: SOURCE it for the gardener_* functions, or run it as a CLI.
# Sourced AFTER herd-config.sh (PROJECT_ROOT / WORKTREES_DIR) and journal.sh:
#   . "$HERE/herd-config.sh"
#   . "$HERE/journal.sh"
#   . "$HERE/gardener.sh"
#
# Hermetic seams (default to the real journal/git/scribe; tests override them):
#   JOURNAL_FILE              the journal to read merge events from (journal.sh's own seam).
#   HERD_GARDENER_STATE_DIR   overrides the cursor/cooldown state directory (default: under WORKTREES_DIR).
#   HERD_GARDENER_DIFF_CMD    a `<script> <sha>` overriding how changed-files-per-merge are resolved
#                             (default: `git diff-tree --no-commit-id --name-only -r <sha>`).
#   HERD_GARDENER_SCRIBE      overrides the scribe.sh path/stub a finding is filed through.
#   HERD_GARDENER_COOLDOWN_SECS  the per-signature filing cooldown window (default 604800 = 7 days).
#   HERD_GARDENER_NOW         overrides "now" for cooldown math (epoch seconds).

# _gardener_enabled — 0 iff MAINTENANCE_GARDENER opts in. Default OFF; only on|true|1|yes|enable|enabled
# enable it (the same tolerant-boolean idiom oss-triage.sh / ci-repair.sh use for their own gate key).
_gardener_enabled() {
  case "$(printf '%s' "${MAINTENANCE_GARDENER:-off}" | tr '[:upper:]' '[:lower:]')" in
    1|true|on|yes|enable|enabled) return 0 ;;
    *) return 1 ;;
  esac
}

# _gardener_state_dir — where the cursor + per-signature cooldown stamps live: runtime state under the
# worktree pool, never committed (mirrors oss-triage.sh's $TREES/.herd/oss-triage/ convention).
# HERD_GARDENER_STATE_DIR overrides it outright (the test seam).
_gardener_state_dir() {
  if [ -n "${HERD_GARDENER_STATE_DIR:-}" ]; then printf '%s' "$HERD_GARDENER_STATE_DIR"; return 0; fi
  [ -n "${WORKTREES_DIR:-}" ] || return 1
  printf '%s/.herd/gardener' "$WORKTREES_DIR"
}

_gardener_now() { printf '%s' "${HERD_GARDENER_NOW:-$(date +%s 2>/dev/null || echo 0)}"; }

# _gardener_cooldown_secs — the configured per-signature filing-cooldown window; non-numeric falls soft
# to the documented 7-day default (mirrors agent-watch.sh's _anomaly_file_cooldown_secs).
_gardener_cooldown_secs() {
  local v="${HERD_GARDENER_COOLDOWN_SECS:-604800}"
  case "$v" in ''|*[!0-9]*) printf 604800 ;; *) printf '%s' "$v" ;; esac
}

# _gardener_sig <file> — a filesystem-safe, stable signature for a drifted surface file: the path
# itself, sanitized (mirrors _anomaly_file_stamp_path's tr, HERD-673 needs no cryptographic hash — the
# path IS the identity).
_gardener_sig() { printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '_'; }

# _gardener_in_cooldown <sig> — fail-soft toward "not in cooldown" (file it) on 0/off/missing/garbled,
# exactly like agent-watch.sh's _anomaly_file_in_cooldown.
_gardener_in_cooldown() {
  local sig="$1" state win stampf last now
  state="$(_gardener_state_dir)" || return 1
  win="$(_gardener_cooldown_secs)"
  [ "$win" -gt 0 ] || return 1
  stampf="$state/cooldown/$sig.stamp"
  [ -f "$stampf" ] || return 1
  last="$(cat "$stampf" 2>/dev/null)" || return 1
  case "$last" in ''|*[!0-9]*) return 1 ;; esac
  now="$(_gardener_now)"
  [ "$now" -ge "$last" ] || return 1     # clock went backwards — never hold on that
  [ $(( now - last )) -lt "$win" ]
}

# _gardener_stamp_cooldown <sig> — arm the cooldown. Never fatal: an unwritable state dir just disarms it.
_gardener_stamp_cooldown() {
  local sig="$1" state
  state="$(_gardener_state_dir)" || return 0
  mkdir -p "$state/cooldown" 2>/dev/null || true
  printf '%s\n' "$(_gardener_now)" > "$state/cooldown/$sig.stamp" 2>/dev/null || true
}

# _gardener_is_surface <path> — a shipped-surface file the front door / rendered rails are supposed to
# describe. Kept intentionally small: exactly the three surfaces caps-sync-lint.sh itself gates on,
# plus the manifest that ratchet requires alongside them.
_gardener_is_surface() {
  case "$1" in
    bin/herd|scripts/herd/*.sh|templates/capabilities.tsv|templates/conformance.tsv) return 0 ;;
    *) return 1 ;;
  esac
}

# _gardener_is_doc <path> — the doc-target set a merge touching SURFACE is expected to keep pace with.
_gardener_is_doc() {
  case "$1" in
    README.md|docs/*|templates/*.tmpl) return 0 ;;
    *) return 1 ;;
  esac
}

# _gardener_files_for_sha <sha> — the changed-files list for one merge commit. HERD_GARDENER_DIFF_CMD
# overrides the whole invocation (a synthetic fixture's sha→files stub); default is a real `git
# diff-tree`. FAIL-SOFT: an unresolvable sha (shallow clone, rewritten history) prints nothing, so that
# merge is silently treated as touching nothing — never a false drift flag.
_gardener_files_for_sha() {
  local sha="$1"
  if [ -n "${HERD_GARDENER_DIFF_CMD:-}" ]; then
    bash "$HERD_GARDENER_DIFF_CMD" "$sha" 2>/dev/null
    return 0
  fi
  git -C "${PROJECT_ROOT:-.}" diff-tree --no-commit-id --name-only -r "$sha" 2>/dev/null
}

# _gardener_scribe_cmd — the scribe.sh invocation a finding is filed through. HERD_GARDENER_SCRIBE
# overrides it outright (the test seam — a stub that records the call instead of spawning a real drainer).
_gardener_scribe_cmd() {
  if [ -n "${HERD_GARDENER_SCRIBE:-}" ]; then printf '%s' "$HERD_GARDENER_SCRIBE"; return 0; fi
  local here; here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  printf '%s/scribe.sh' "$here"
}

# _gardener_merges_since <journal-file> <byte-offset> — print "<pr>\t<sha>" for every `merge` event
# after <byte-offset>. python3 does the JSON parse (the same hard dependency journal.sh itself leans on
# for every write) so a malformed/partial trailing line from a concurrent writer is silently skipped
# rather than corrupting the scan.
_gardener_merges_since() {
  local jf="$1" offset="$2"
  tail -c +"$((offset + 1))" "$jf" 2>/dev/null | grep '"event":"merge"' 2>/dev/null | python3 -c '
import sys, json
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        obj = json.loads(line)
    except Exception:
        continue
    if obj.get("event") != "merge":
        continue
    sha = obj.get("sha", "")
    if not sha:
        continue
    print("%s\t%s" % (obj.get("pr", ""), sha))
' 2>/dev/null
  return 0
}

# gardener_run [--dry-run] — the ONE entry point a scheduler (or an operator, or the docs-gardener
# agent) calls. See the file header for the full contract. Always returns 0 (fail-soft throughout).
gardener_run() {
  local dry=0
  case "${1:-}" in --dry-run) dry=1 ;; esac

  if ! _gardener_enabled; then
    echo "🌱 gardener: MAINTENANCE_GARDENER is off (default) — nothing to do."
    return 0
  fi

  local jf=""
  if command -v _journal_file >/dev/null 2>&1; then jf="$(_journal_file 2>/dev/null || true)"; fi
  [ -n "$jf" ] || jf="${JOURNAL_FILE:-${WORKTREES_DIR:+$WORKTREES_DIR/.herd/journal.jsonl}}"
  if [ -z "$jf" ] || [ ! -f "$jf" ]; then
    echo "🌱 gardener: no journal to read yet — nothing to do."
    return 0
  fi

  local state; state="$(_gardener_state_dir)"
  if [ -z "$state" ]; then
    echo "🌱 gardener: cannot resolve a state dir (WORKTREES_DIR unset) — nothing to do." >&2
    return 0
  fi
  [ "$dry" -eq 1 ] || mkdir -p "$state" 2>/dev/null || true
  local cursor_file="$state/cursor"
  local size; size="$(wc -c < "$jf" 2>/dev/null | tr -cd '0-9')"; size="${size:-0}"

  local offset first_run=0
  if [ ! -f "$cursor_file" ]; then
    first_run=1
    offset="$size"     # pin at EOF: a first run never replays the journal's whole history
  else
    offset="$(cat "$cursor_file" 2>/dev/null || echo 0)"
    case "$offset" in ''|*[!0-9]*) offset=0 ;; esac
    [ "$offset" -le "$size" ] || offset=0   # journal rotated/shrank since — restart from 0
  fi

  local nfindings=0 nfiled=0 nskipped=0

  if [ "$first_run" -eq 0 ] && [ "$offset" -lt "$size" ]; then
    local merges; merges="$(_gardener_merges_since "$jf" "$offset")"
    local candidates=""    # "<file>\t<pr>" rows, one per undocumented-surface merge×file
    if [ -n "$merges" ]; then
      local pr sha files f doc_hit surface_files
      while IFS=$'\t' read -r pr sha; do
        [ -n "$sha" ] || continue
        files="$(_gardener_files_for_sha "$sha")"
        [ -n "$files" ] || continue
        doc_hit=0; surface_files=""
        while IFS= read -r f; do
          [ -n "$f" ] || continue
          _gardener_is_doc "$f" && doc_hit=1
          _gardener_is_surface "$f" && surface_files="${surface_files}${f}"$'\n'
        done <<EOF
$files
EOF
        if [ "$doc_hit" -eq 0 ] && [ -n "$surface_files" ]; then
          while IFS= read -r f; do
            [ -n "$f" ] || continue
            candidates="${candidates}${f}"$'\t'"${pr}"$'\n'
          done <<EOF
$surface_files
EOF
        fi
      done <<EOF
$merges
EOF
    fi

    if [ -n "$candidates" ]; then
      # Group by FILE: one line per distinct drifted file, PRs comma-joined (dedups exact repeats too).
      local grouped
      grouped="$(printf '%s' "$candidates" | sort -u | awk -F'\t' '
        { if (!($1 in seen)) { order[++n] = $1; seen[$1] = "" }
          seen[$1] = seen[$1] (seen[$1] == "" ? "" : ",") $2 }
        END { for (i = 1; i <= n; i++) print order[i] "\t" seen[order[i]] }
      ')"
      local gfile gprs sig
      while IFS=$'\t' read -r gfile gprs; do
        [ -n "$gfile" ] || continue
        nfindings=$((nfindings + 1))
        sig="$(_gardener_sig "$gfile")"
        if _gardener_in_cooldown "$sig"; then
          nskipped=$((nskipped + 1))
          echo "🌿 gardener: '$gfile' drifted (PR(s) $gprs) but is in its filing cooldown — not re-filed."
          if [ "$dry" -eq 0 ]; then
            command -v journal_append >/dev/null 2>&1 && journal_append gardener_finding file "$gfile" prs "$gprs" result cooldown-skip
          fi
          continue
        fi
        if [ "$dry" -eq 1 ]; then
          echo "🌱 [dry-run] would file: '$gfile' — merged PR(s) $gprs touched it without a README.md/docs/**/templates/*.tmpl update."
          continue
        fi
        local title body
        title="Docs drift: $gfile changed without a README/docs update"
        title="${title:0:78}"
        body="Maintenance gardener (HERD-673): merged PR(s) $gprs modified \`$gfile\`, but none of them touched README.md, docs/**, or templates/*.tmpl in the same merge. Evidence: \`$gfile\` — PR(s) $gprs. Please check whether the docs need an update, or let this file cooldown-expire if the change was genuinely doc-inert."
        if bash "$(_gardener_scribe_cmd)" "$title
$body" >/dev/null 2>&1; then
          nfiled=$((nfiled + 1))
          _gardener_stamp_cooldown "$sig"
          command -v journal_append >/dev/null 2>&1 && journal_append gardener_finding file "$gfile" prs "$gprs" result filed
          echo "📝 gardener: filed a drift finding for '$gfile' (PR(s) $gprs)."
        else
          command -v journal_append >/dev/null 2>&1 && journal_append gardener_finding file "$gfile" prs "$gprs" result scribe-failed
          echo "⚠️  gardener: could not enqueue a finding for '$gfile' (fail-soft: continuing)." >&2
        fi
      done <<EOF
$grouped
EOF
    fi
  fi

  if [ "$dry" -eq 1 ]; then
    echo "🌱 gardener: dry-run — cursor NOT advanced, nothing filed, no cooldown stamped."
    return 0
  fi

  printf '%s\n' "$size" > "$cursor_file" 2>/dev/null || true
  if [ "$nfindings" -eq 0 ]; then
    if [ "$first_run" -eq 1 ]; then
      echo "🌱 gardener: FIRST RUN — baseline cursor established at the current journal EOF; no history replayed."
    else
      echo "🌱 gardener: zero findings this run."
    fi
  fi
  command -v journal_append >/dev/null 2>&1 && \
    journal_append gardener_run findings "$nfindings" filed "$nfiled" skipped "$nskipped" first_run "$first_run"
  return 0
}

# ── CLI dispatch (only when executed, never when sourced) ─────────────────────────────────────────
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -uo pipefail
  _GD_HERE="$(cd "$(dirname "$0")" && pwd)"
  # shellcheck source=scripts/herd/herd-config.sh
  . "$_GD_HERE/herd-config.sh"
  # shellcheck source=scripts/herd/journal.sh
  [ -f "$_GD_HERE/journal.sh" ] && . "$_GD_HERE/journal.sh"
  _gd_cmd="${1:-}"; shift 2>/dev/null || true
  case "$_gd_cmd" in
    run)     gardener_run "$@" ;;
    enabled) _gardener_enabled && echo "on" || { echo "off"; exit 1; } ;;
    cursor)  _gd_state="$(_gardener_state_dir 2>/dev/null || true)"
             [ -n "$_gd_state" ] && cat "$_gd_state/cursor" 2>/dev/null || echo 0 ;;
    *) echo "Usage: gardener.sh [run [--dry-run] | enabled | cursor]" >&2; exit 1 ;;
  esac
fi
