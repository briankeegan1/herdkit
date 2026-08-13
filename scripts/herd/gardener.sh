#!/usr/bin/env bash
# gardener.sh — the MAINTENANCE GARDENER (HERD-673, tuned HERD-730): a periodic, ADVISORY doc-drift
# sweep that files its own backlog. Composed entirely from shipped primitives — the trigger pack
# (triggers.sh, HERD-169) schedules it, the specialist roster (.herd/agents/docs-gardener.md, HERD-667)
# gives the weekly agent run its persona, and scribe.sh does the actual filing — this file is the ONE
# deterministic mechanism in between: cursor + diff + dedup + rollup + cap, testable with no LLM in
# the loop.
#
# CONTRACT — FILES, NEVER EDITS. Each `run` diffs merge events journaled since its OWN stored cursor
# (a byte offset into the project journal, kept under the worktree pool — never committed) against two
# small, deterministic sets:
#   SURFACE  bin/herd, scripts/herd/*.sh, templates/capabilities.tsv, templates/conformance.tsv
#   DOC      README.md, docs/** (excluding the two GENERATED docs below), templates/*.tmpl,
#            templates/capabilities.tsv (it IS the manifest the rendered docs derive from, so a merge
#            touching it alongside a SURFACE script is documented, not drift)
#   GENERATED docs/codemap.md and docs/symbol-index.md are never drift EVIDENCE in either direction —
#            not proof of documentation (a merge regenerating only these is still undocumented drift for
#            any SURFACE file it also touches) and never themselves a drift TARGET.
# A merge that touches SURFACE but touches NO file in DOC is real drift — UNLESS the surface file's own
# diff in that merge touches only its leading `#`-comment header block (shebang + contiguous comment
# lines), which self-documents a minor diff and is never flagged.
#
# A run's findings are ONE UNIT OF REVIEW: every drifted file found in a run is grouped by SUBSYSTEM
# (the file's own directory) into ONE rollup tracker item per run — never one item per file (HERD-730:
# the first live run filed fifty one-file items, pure noise). A PER-SIGNATURE FILING COOLDOWN (a stamp
# file per surface-file signature, HERD_GARDENER_COOLDOWN_SECS — default 7d) still gates ROLLUP
# MEMBERSHIP per file, so a standing, still-unaddressed drift is not re-included every run (the
# HERD-512 anomaly-rail lesson). A PER-RUN FILING CAP (HERD_GARDENER_MAX_FINDINGS — default 20, 0 =
# unlimited) bounds how many distinct drifted files land in one run's rollup; anything beyond the cap
# is stated LOUDLY in the rollup body (never a silent drop), and the cursor is HELD BACK (not advanced)
# so the same merge window is honestly rescanned next run — already-filed files skip via cooldown,
# capped-out ones get a fresh shot.
# Zero findings is not silence: it still advances the cursor and journals exactly one
# `gardener_run findings=0` event. Filing goes through scripts/herd/scribe.sh exactly like a human
# coordinator's request; gardener.sh never writes README.md/docs/**/templates/*.tmpl itself.
#
# `--dry-run` previews what WOULD file (surfaced files + evidence + cooldown/cap status) without calling
# scribe.sh, stamping cooldown, or advancing the cursor — safe to run repeatedly.
#
# CURSOR INIT: an absent, corrupt, or rotated/shrunk cursor always re-baselines at the CURRENT journal
# EOF (never offset 0) — a run's job on a fresh or invalidated cursor is to establish a baseline, never
# to back-scan the journal's whole history as archaeology.
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
#   HERD_GARDENER_MAX_FINDINGS   the per-run rollup filing cap (default 20; 0 = unlimited).
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

# _gardener_max_findings — the per-run rollup filing cap; non-numeric falls soft to the documented
# default of 20. 0 means unlimited (every non-cooldown finding lands in the rollup).
_gardener_max_findings() {
  local v="${HERD_GARDENER_MAX_FINDINGS:-20}"
  case "$v" in ''|*[!0-9]*) printf 20 ;; *) printf '%s' "$v" ;; esac
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
# docs/codemap.md and docs/symbol-index.md are GENERATED docs (herd codemap / herd symbol-index) and
# never count as doc evidence — a merge regenerating only these still counts as undocumented for any
# SURFACE file it also touches. templates/capabilities.tsv DOES count: it is the manifest the rendered
# docs derive from, so a merge touching it alongside a SURFACE script is documented, not drift.
_gardener_is_doc() {
  case "$1" in
    docs/codemap.md|docs/symbol-index.md) return 1 ;;
    README.md|docs/*|templates/*.tmpl|templates/capabilities.tsv) return 0 ;;
    *) return 1 ;;
  esac
}

# _gardener_header_end <sha> <path> — the 1-based line number of the LAST line of <path>'s leading
# `#`-comment header block (shebang + contiguous comment lines) as it existed at <sha>, or empty if the
# file has no such header (first line isn't a comment). FAIL-SOFT: an unresolvable sha/path prints
# nothing.
_gardener_header_end() {
  local sha="$1" path="$2"
  git -C "${PROJECT_ROOT:-.}" show "${sha}:${path}" 2>/dev/null | awk '
    /^#/ { last = NR; next }
    { exit }
    END { if (last > 0) print last }
  '
}

# _gardener_header_only_change <sha> <path> — true iff <path>'s own diff in merge <sha> touches ONLY
# lines inside its leading `#`-comment header block on BOTH sides of the change (old and new blob) — a
# self-documenting minor diff (HERD-730) that should never count as drift. Scoped to actual shipped
# scripts (bin/herd, scripts/herd/*.sh); manifests/tsv rows don't have a comment-header convention.
# FAIL-SOFT: any unresolvable git call (no parent, no header, malformed hunk) returns false — the
# safest default is "still counts as drift," never silently excusing a real change.
_gardener_header_only_change() {
  local sha="$1" path="$2"
  case "$path" in
    bin/herd|scripts/herd/*.sh) : ;;
    *) return 1 ;;
  esac
  local diff old_head new_head
  diff="$(git -C "${PROJECT_ROOT:-.}" diff-tree -p --no-color --no-commit-id -r "$sha" -- "$path" 2>/dev/null)"
  [ -n "$diff" ] || return 1
  old_head="$(_gardener_header_end "${sha}^" "$path")"; old_head="${old_head:-0}"
  new_head="$(_gardener_header_end "$sha" "$path")"; new_head="${new_head:-0}"
  [ "$old_head" -gt 0 ] 2>/dev/null || return 1
  [ "$new_head" -gt 0 ] 2>/dev/null || return 1
  # Walk the unified diff line-by-line (not just hunk-header ranges, which include unchanged CONTEXT
  # lines): only actual added/removed lines must fall within the header boundary on their own side.
  printf '%s\n' "$diff" | awk -v oh="$old_head" -v nh="$new_head" '
    /^@@/ {
      line = $0
      sub(/^@@ -/, "", line)
      sub(/ @@.*/, "", line)
      split(line, parts, " \\+")
      split(parts[1], oarr, ",")
      split(parts[2], narr, ",")
      oline = oarr[1] + 0
      nline = narr[1] + 0
      next
    }
    /^diff / || /^index / || /^--- / || /^\+\+\+ / { next }
    /^-/ { if (oline > oh) bad = 1; oline++; next }
    /^\+/ { if (nline > nh) bad = 1; nline++; next }
    /^ / { oline++; nline++; next }
    END { exit (bad ? 1 : 0) }
  '
}

# _gardener_subsystem_for <path> — the rollup grouping bucket for a drifted file: its own directory
# (bin, scripts/herd, scripts/herd/backends, templates, …) — no hardcoded taxonomy, so any future
# SURFACE addition buckets naturally.
_gardener_subsystem_for() {
  case "$1" in
    */*) printf '%s' "${1%/*}" ;;
    *)   printf '%s' "(root)" ;;
  esac
}

# _gardener_render_rollup_body <rows> — <rows> is "<file>\t<prs>\n"*; renders a "## subsystem" section
# per distinct subsystem with one "- file — PR(s) ..." line each, subsystems and files sorted for
# determinism.
_gardener_render_rollup_body() {
  local rows="$1" tagged
  tagged="$(printf '%s\n' "$rows" | while IFS=$'\t' read -r f prs; do
    [ -n "$f" ] || continue
    printf '%s\t%s\t%s\n' "$(_gardener_subsystem_for "$f")" "$f" "$prs"
  done)"
  printf '%s\n' "$tagged" | sort -t "$(printf '\t')" -k1,1 -k2,2 | awk -F'\t' '
    $1 != prev { if (prev != "") print ""; print "## " $1; prev = $1 }
    { print "- " $2 " — PR(s) " $3 }
  '
}

# _gardener_count_subsystems <rows> — distinct subsystem count across <rows>, for the rollup summary line.
_gardener_count_subsystems() {
  local rows="$1"
  printf '%s\n' "$rows" | awk -F'\t' '$1 != "" { print $1 }' | while IFS= read -r f; do
    _gardener_subsystem_for "$f"; printf '\n'
  done | sort -u | grep -c .
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

  # CURSOR INIT (HERD-730): absent OR corrupt OR rotated/shrunk always re-baselines at the CURRENT
  # journal EOF — never offset 0. A run's job on an invalidated cursor is to establish a baseline, not
  # to back-scan the journal's whole history as archaeology.
  local offset first_run=0
  if [ ! -f "$cursor_file" ]; then
    first_run=1
    offset="$size"
  else
    offset="$(cat "$cursor_file" 2>/dev/null || echo '')"
    case "$offset" in ''|*[!0-9]*) first_run=1; offset="$size" ;; esac
    if [ "$first_run" -eq 0 ] && [ "$offset" -gt "$size" ]; then
      first_run=1
      offset="$size"
    fi
  fi

  local nfindings=0 nfiled=0 nskipped=0 ncapped=0

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
          if _gardener_is_surface "$f" && ! _gardener_header_only_change "$sha" "$f"; then
            surface_files="${surface_files}${f}"$'\n'
          fi
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

      # Partition grouped findings: cooldown-skip (never counted toward the cap), then within-cap →
      # rolled into this run's ONE item, beyond-cap → truncated (loudly), reconsidered next run.
      local cap; cap="$(_gardener_max_findings)"
      local to_file="" n_considered=0
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
        n_considered=$((n_considered + 1))
        if [ "$cap" -gt 0 ] && [ "$n_considered" -gt "$cap" ]; then
          ncapped=$((ncapped + 1))
          continue
        fi
        to_file="${to_file}${gfile}"$'\t'"${gprs}"$'\n'
      done <<EOF
$grouped
EOF

      if [ "$dry" -eq 1 ]; then
        if [ -n "$to_file" ]; then
          while IFS=$'\t' read -r gfile gprs; do
            [ -n "$gfile" ] || continue
            echo "🌱 [dry-run] would file: '$gfile' — merged PR(s) $gprs touched it without a README.md/docs/**/templates/*.tmpl update."
          done <<EOF
$to_file
EOF
        fi
        [ "$ncapped" -eq 0 ] || echo "🌱 [dry-run] per-run cap ($cap) would truncate $ncapped additional finding(s) this run — they'd be reconsidered next run."
      elif [ -n "$to_file" ]; then
        local nfile nsub title body sections
        nfile="$(printf '%s\n' "$to_file" | grep -c .)"
        nsub="$(_gardener_count_subsystems "$to_file")"
        sections="$(_gardener_render_rollup_body "$to_file")"
        title="Docs drift rollup: $nfile file(s) across $nsub subsystem(s)"
        title="${title:0:78}"
        body="Maintenance gardener (HERD-673/HERD-730): this run found $nfile drifted surface file(s) across $nsub subsystem(s) — each merged without touching README.md, docs/**, or templates/*.tmpl in the same merge. Grouped by subsystem:

$sections"
        if [ "$ncapped" -gt 0 ]; then
          body="$body

TRUNCATED: $ncapped additional drifted file(s) found this run are NOT listed above — the per-run filing cap is $cap. They remain undocumented and will be reconsidered (un-cooldowned) next run."
        fi
        body="$body

Please check whether docs need an update for each path above, or let a path cooldown-expire if its change was genuinely doc-inert."

        if bash "$(_gardener_scribe_cmd)" "$title
$body" >/dev/null 2>&1; then
          while IFS=$'\t' read -r gfile gprs; do
            [ -n "$gfile" ] || continue
            nfiled=$((nfiled + 1))
            sig="$(_gardener_sig "$gfile")"
            _gardener_stamp_cooldown "$sig"
            command -v journal_append >/dev/null 2>&1 && journal_append gardener_finding file "$gfile" prs "$gprs" result filed
          done <<EOF
$to_file
EOF
          if [ "$ncapped" -gt 0 ]; then
            echo "📝 gardener: filed a rollup drift finding covering $nfiled file(s) across $nsub subsystem(s) ($ncapped more truncated by the per-run cap)."
          else
            echo "📝 gardener: filed a rollup drift finding covering $nfiled file(s) across $nsub subsystem(s)."
          fi
        else
          while IFS=$'\t' read -r gfile gprs; do
            [ -n "$gfile" ] || continue
            command -v journal_append >/dev/null 2>&1 && journal_append gardener_finding file "$gfile" prs "$gprs" result scribe-failed
          done <<EOF
$to_file
EOF
          echo "⚠️  gardener: could not enqueue the rollup drift finding (fail-soft: continuing)." >&2
        fi
      elif [ "$ncapped" -gt 0 ]; then
        echo "🌱 gardener: every drifted file this run was truncated by the per-run cap ($cap) — none filed, all reconsidered next run."
      fi
    fi
  fi

  if [ "$dry" -eq 1 ]; then
    echo "🌱 gardener: dry-run — cursor NOT advanced, nothing filed, no cooldown stamped."
    return 0
  fi

  if [ "$ncapped" -eq 0 ]; then
    printf '%s\n' "$size" > "$cursor_file" 2>/dev/null || true
  else
    # Honest truncation (HERD-730): hold the cursor back so this SAME merge window is rescanned next
    # run — already-filed files skip via cooldown, capped-out ones get a fresh shot at the rollup.
    echo "🌱 gardener: cursor NOT advanced — $ncapped finding(s) were truncated by the per-run cap; this merge window will be rescanned next run."
  fi
  if [ "$nfindings" -eq 0 ]; then
    if [ "$first_run" -eq 1 ]; then
      echo "🌱 gardener: FIRST RUN — baseline cursor established at the current journal EOF; no history replayed."
    else
      echo "🌱 gardener: zero findings this run."
    fi
  fi
  command -v journal_append >/dev/null 2>&1 && \
    journal_append gardener_run findings "$nfindings" filed "$nfiled" skipped "$nskipped" capped "$ncapped" first_run "$first_run"
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
