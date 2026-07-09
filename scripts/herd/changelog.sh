#!/usr/bin/env bash
# changelog.sh — journal-driven CHANGELOG + release-tag helper (HERD-256 / HERD-168 part 2/3).
#
# DETERMINISTIC (no LLM): reads merge events from the engine journal
# (.herd/journal.jsonl, plus rotated archives) and conventional-commit subjects, then emits or
# updates a CHANGELOG.md section. A companion tag helper promotes [Unreleased] to a versioned
# heading and cuts a local git tag. Ship-dormant / read-mostly: never auto-run by the watcher;
# an operator (or a release runbook step) invokes it explicitly.
#
# Invoked by bin/herd (`herd changelog …`) or standalone:
#   bash scripts/herd/changelog.sh generate [--since <tag|YYYY-MM-DD>] [--file PATH] [--dry-run] [--stdout]
#   bash scripts/herd/changelog.sh tag <version> [--date YYYY-MM-DD] [--file PATH] [--dry-run] [--no-tag]
#
# Subject resolution (first hit wins), fully offline + deterministic:
#   1. HERD_CHANGELOG_SUBJECTS — optional TSV path (pr<TAB>subject); hermetic test seam
#   2. journal event field `title` or `subject` when present
#   3. git log -1 --format=%s <sha> when the merge event's sha resolves locally
#   4. git log --all --grep='(#N)' --format=%s -1 (squash/merge subjects that cite the PR)
#   5. fallback: humanized slug, else "PR #N"
#
# CHANGELOG ownership: generate rewrites only the ## [Unreleased] body (or creates the file).
# Prior versioned sections are left untouched. Entries are Keep-a-Changelog-style grouped bullets
# derived from the conventional-commit type prefix (feat/fix/docs/…); unknown prefixes land under
# "Changes". Deduped by PR number (first merge event chronologically wins).
set -euo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/herd-config.sh"

# ── paths / seams ──────────────────────────────────────────────────────────────────────────────
# PROJECT_ROOT comes from herd-config.sh when a project config is loaded; fall back to cwd so the
# script is usable from a bare checkout (and hermetic fixtures that export PROJECT_ROOT themselves).
ROOT="${HERD_CHANGELOG_ROOT:-${PROJECT_ROOT:-$(pwd)}}"
ROOT="$(cd "$ROOT" 2>/dev/null && pwd -P || printf '%s' "$ROOT")"
CHANGELOG_FILE_DEFAULT="$ROOT/CHANGELOG.md"

_die()  { printf 'herd changelog: %s\n' "$*" >&2; exit 2; }
_say()  { printf '%s\n' "$*"; }
_warn() { printf 'herd changelog: %s\n' "$*" >&2; }

_usage() {
  cat <<'EOF'
usage: herd changelog <subcommand>

  generate [--since <tag|YYYY-MM-DD>] [--file PATH] [--dry-run] [--stdout]
      Read journal merge events (+ conventional-commit subjects) and write/update the
      ## [Unreleased] section of CHANGELOG.md. Default --since = most recent v* tag (by
      version sort) when one exists; otherwise all merge events. --stdout prints the
      section body only (no file write). --dry-run prints the full file that would be written.

  tag <version> [--date YYYY-MM-DD] [--file PATH] [--dry-run] [--no-tag]
      Promote ## [Unreleased] → ## [version] - date, insert a fresh empty [Unreleased],
      and create a local annotated git tag v<version>. Does NOT commit, push, or publish
      (npm/Homebrew remain HUMAN-VERIFY steps — see docs/releasing.md). --no-tag rewrites
      the changelog only. Version may be given as 0.1.0 or v0.1.0.

  preview …   alias for generate --stdout
  help        this help

Ship-dormant: never auto-run. Deterministic given the same journal + git subjects.
EOF
}

# ── journal resolution ─────────────────────────────────────────────────────────────────────────
# Prefer JOURNAL_FILE (test seam / operator pin). Else WORKTREES_DIR/.herd/journal.jsonl (+ archives).
# Prints paths oldest→newest, one per line. Empty when nothing exists.
_cl_journal_files() {
  if [ -n "${JOURNAL_FILE:-}" ]; then
    [ -f "$JOURNAL_FILE" ] && printf '%s\n' "$JOURNAL_FILE"
    return 0
  fi
  local dir="${WORKTREES_DIR:-}/.herd"
  [ -n "${WORKTREES_DIR:-}" ] && [ -d "$dir" ] || return 0
  ls -1 "$dir"/journal-*.jsonl 2>/dev/null | sort || true
  [ -f "$dir/journal.jsonl" ] && printf '%s\n' "$dir/journal.jsonl"
  return 0
}

# Most recent v* tag by version sort (git tag -l 'v*' --sort=v:refname). Empty if none.
_cl_last_version_tag() {
  git -C "$ROOT" tag -l 'v*' --sort=v:refname 2>/dev/null | tail -n1 || true
}

# Resolve --since bound to an ISO date prefix usable for lexical ts compare.
#   • empty → empty (no bound)
#   • YYYY-MM-DD → as-is
#   • tag name (with or without v) → that tag's committer date (UTC, YYYY-MM-DD)
_cl_resolve_since() {
  local raw="${1:-}"
  [ -n "$raw" ] || { printf ''; return 0; }
  case "$raw" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]*)
      printf '%s' "${raw:0:10}"
      return 0
      ;;
  esac
  local tag="$raw"
  case "$tag" in v*) ;; *) tag="v$tag" ;; esac
  local d
  d="$(git -C "$ROOT" log -1 --format=%cI "$tag" 2>/dev/null || true)"
  [ -n "$d" ] || _die "cannot resolve --since '$raw' (not a YYYY-MM-DD date or known git tag)"
  printf '%s' "${d:0:10}"
}

# Load optional subject map: pr → subject. File format: pr<TAB>subject (or pr|subject).
# Sets associative-like parallel arrays via a temp file keyed "pr<TAB>subject" for python.
_cl_subjects_file() {
  if [ -n "${HERD_CHANGELOG_SUBJECTS:-}" ] && [ -f "$HERD_CHANGELOG_SUBJECTS" ]; then
    printf '%s' "$HERD_CHANGELOG_SUBJECTS"
  fi
}

# Resolve one subject's text for a merge event. Args: pr sha slug
_cl_resolve_subject() {
  local pr="$1" sha="$2" slug="$3"
  local subj="" map
  map="$(_cl_subjects_file)"
  if [ -n "$map" ]; then
    # TSV: pr<TAB>subject  (also accept pr|subject). Subject may contain spaces.
    subj="$(awk -F'[\t|]' -v p="$pr" '
      $1 == p {
        s = $0
        sub(/^[^|\t]+[|\t]/, "", s)
        gsub(/^[ \t]+|[ \t]+$/, "", s)
        print s
        exit
      }' "$map" 2>/dev/null || true)"
    [ -n "$subj" ] && { printf '%s' "$subj"; return 0; }
  fi
  if [ -n "$sha" ] && [ "$sha" != "null" ]; then
    subj="$(git -C "$ROOT" log -1 --format=%s "$sha" 2>/dev/null || true)"
    [ -n "$subj" ] && { printf '%s' "$subj"; return 0; }
  fi
  if [ -n "$pr" ]; then
    subj="$(git -C "$ROOT" log --all --grep="(#${pr})" --format=%s -1 2>/dev/null || true)"
    [ -n "$subj" ] && { printf '%s' "$subj"; return 0; }
    subj="$(git -C "$ROOT" log --all --grep="#${pr}" --format=%s -1 2>/dev/null || true)"
    [ -n "$subj" ] && { printf '%s' "$subj"; return 0; }
  fi
  if [ -n "$slug" ]; then
    # humanize slug: dashes/underscores → spaces
    printf '%s' "$slug" | sed 's/[-_]/ /g'
    return 0
  fi
  printf 'PR #%s' "$pr"
}

# Conventional-commit type → Keep-a-Changelog section heading.
_cl_section_for() {
  local subj="$1" type
  type="$(printf '%s' "$subj" | sed -nE 's/^([a-zA-Z]+)(\([^)]*\))?(!)?:.*/\1/p' | tr '[:upper:]' '[:lower:]')"
  case "$type" in
    feat|feature)           printf 'Features' ;;
    fix|bugfix)             printf 'Fixes' ;;
    docs|doc)               printf 'Documentation' ;;
    perf)                   printf 'Performance' ;;
    refactor)               printf 'Refactoring' ;;
    test|tests)             printf 'Tests' ;;
    build|ci|chore|style)   printf 'Maintenance' ;;
    revert)                 printf 'Reverts' ;;
    *)                      printf 'Changes' ;;
  esac
}

# Strip a trailing "(#N)" / "(N)" that we re-add ourselves so bullets stay uniform.
_cl_strip_pr_suffix() {
  printf '%s' "$1" | sed -E 's/[[:space:]]*\((#?[0-9]+)\)$//'
}

# Collect merge events → TSV lines: ts\tpr\tsha\tslug\ttitle_from_event
# Dedup by pr (first chronologically). Filtered by since_day (YYYY-MM-DD or empty).
_cl_collect_merges() {
  local since_day="${1:-}"
  local files
  files="$(_cl_journal_files)"
  if [ -z "$files" ]; then
    return 0
  fi
  printf '%s\n' "$files" | HERD_CL_SINCE="$since_day" python3 -c '
import sys, os, json
since = os.environ.get("HERD_CL_SINCE", "").strip()
# first-seen order: chronological, dedupe by pr
seen = set()
rows = []
for path in sys.stdin.read().split("\n"):
    path = path.strip()
    if not path:
        continue
    try:
        f = open(path, encoding="utf-8")
    except OSError:
        continue
    with f:
        for raw in f:
            raw = raw.strip()
            if not raw:
                continue
            try:
                o = json.loads(raw)
            except Exception:
                continue
            if o.get("event") != "merge":
                continue
            pr = o.get("pr")
            if pr is None or pr == "":
                continue
            pr_s = str(pr)
            ts = str(o.get("ts", ""))
            if since and ts[:10] < since:
                continue
            if pr_s in seen:
                continue
            seen.add(pr_s)
            title = o.get("title") or o.get("subject") or ""
            sha = o.get("sha") or ""
            slug = o.get("slug") or ""
            rows.append((ts, pr_s, str(sha), str(slug), str(title)))
rows.sort(key=lambda r: r[0])
for ts, pr, sha, slug, title in rows:
    # TSV with no raw tabs in fields
    def clean(s):
        return s.replace("\t", " ").replace("\n", " ")
    print("\t".join(clean(x) for x in (ts, pr, sha, slug, title)))
'
}

# Build the markdown body of ## [Unreleased] (without the heading itself).
# stdin unused; uses journal + git. Prints the body (possibly empty with a placeholder note).
_cl_build_unreleased_body() {
  local since_day="${1:-}"
  local line ts pr sha slug title_ev subj section body
  # section → bullet lines (stable order of sections enforced below)
  local tmp
  tmp="$(mktemp)"
  while IFS=$'\t' read -r ts pr sha slug title_ev; do
    [ -n "$pr" ] || continue
    if [ -n "$title_ev" ]; then
      subj="$title_ev"
    else
      subj="$(_cl_resolve_subject "$pr" "$sha" "$slug")"
    fi
    [ -n "$subj" ] || subj="PR #$pr"
    subj="$(_cl_strip_pr_suffix "$subj")"
    section="$(_cl_section_for "$subj")"
    # bullet: "- <subject> (#pr)"
    printf '%s\t- %s (#%s)\n' "$section" "$subj" "$pr" >> "$tmp"
  done < <(_cl_collect_merges "$since_day")

  if [ ! -s "$tmp" ]; then
    printf '_No merges in scope yet._\n'
    rm -f "$tmp"
    return 0
  fi

  # Stable section order (Keep-a-Changelog-ish), then any remaining alphabetically.
  local order="Features Fixes Performance Documentation Refactoring Tests Maintenance Reverts Changes"
  local sec
  for sec in $order; do
    if grep -q "^${sec}"$'\t' "$tmp" 2>/dev/null; then
      printf '### %s\n\n' "$sec"
      # bullets sorted for determinism
      awk -F'\t' -v s="$sec" '$1==s {print $2}' "$tmp" | LC_ALL=C sort
      printf '\n'
    fi
  done
  # Any unexpected section names (shouldn't happen with _cl_section_for) — emit sorted.
  awk -F'\t' '{print $1}' "$tmp" | LC_ALL=C sort -u | while IFS= read -r sec; do
    case " $order " in *" $sec "*) continue ;; esac
    printf '### %s\n\n' "$sec"
    awk -F'\t' -v s="$sec" '$1==s {print $2}' "$tmp" | LC_ALL=C sort
    printf '\n'
  done
  rm -f "$tmp"
}

# Compose a full CHANGELOG.md: keep versioned sections, replace/create [Unreleased].
# $1 = path to existing (or empty), $2 = new unreleased body (no heading).
# Prints the full file to stdout.
_cl_compose_changelog() {
  local existing="${1:-}" body="$2"
  HERD_CL_EXISTING="$existing" HERD_CL_BODY="$body" python3 -c '
import os, re, sys
existing_path = os.environ.get("HERD_CL_EXISTING") or ""
body = os.environ.get("HERD_CL_BODY") or ""
# Ensure body ends with a single trailing newline, no leading blank-only bloat.
body = body.rstrip() + "\n"

text = ""
if existing_path and os.path.isfile(existing_path):
    with open(existing_path, encoding="utf-8") as f:
        text = f.read()

unreleased_re = re.compile(
    r"^## \[Unreleased\][^\n]*\n(.*?)(?=^## |\Z)",
    re.M | re.S,
)

new_block = "## [Unreleased]\n\n" + body
if not text.strip():
    out = "# Changelog\n\n" + new_block
    if not out.endswith("\n"):
        out += "\n"
    sys.stdout.write(out)
    sys.exit(0)

if unreleased_re.search(text):
    out = unreleased_re.sub(lambda m: new_block + ("\n" if not new_block.endswith("\n") else ""), text, count=1)
    # collapse accidental triple blank lines introduced by the swap
    out = re.sub(r"\n{3,}", "\n\n", out)
    if not out.endswith("\n"):
        out += "\n"
    sys.stdout.write(out)
    sys.exit(0)

# No Unreleased yet: insert after the first H1 (title) or at top.
m = re.search(r"^# .+\n", text, re.M)
if m:
    insert_at = m.end()
    # skip one blank line after title if present
    if insert_at < len(text) and text[insert_at] == "\n":
        insert_at += 1
    out = text[:insert_at] + "\n" + new_block + "\n" + text[insert_at:].lstrip("\n")
else:
    out = new_block + "\n" + text
out = re.sub(r"\n{3,}", "\n\n", out)
if not out.endswith("\n"):
    out += "\n"
sys.stdout.write(out)
'
}

# ── generate ───────────────────────────────────────────────────────────────────────────────────
cmd_generate() {
  local since_raw="" file="$CHANGELOG_FILE_DEFAULT" dry=0 stdout_only=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --since)   since_raw="${2:-}"; [ -n "$since_raw" ] || _die "--since requires a tag or YYYY-MM-DD"; shift 2 ;;
      --since=*) since_raw="${1#--since=}"; shift ;;
      --file)    file="${2:-}"; [ -n "$file" ] || _die "--file requires a path"; shift 2 ;;
      --file=*)  file="${1#--file=}"; shift ;;
      --dry-run) dry=1; shift ;;
      --stdout)  stdout_only=1; shift ;;
      -h|--help) _usage; return 0 ;;
      *) _die "generate: unknown argument '$1' (see herd changelog help)" ;;
    esac
  done
  # Default since = last v* tag (so regenerate only covers post-release merges).
  if [ -z "$since_raw" ]; then
    since_raw="$(_cl_last_version_tag)"
  fi
  local since_day=""
  if [ -n "$since_raw" ]; then
    since_day="$(_cl_resolve_since "$since_raw")"
  fi

  local body
  body="$(_cl_build_unreleased_body "$since_day")"

  if [ "$stdout_only" -eq 1 ]; then
    printf '## [Unreleased]\n\n%s' "$body"
    return 0
  fi

  local composed
  composed="$(_cl_compose_changelog "$file" "$body")"

  if [ "$dry" -eq 1 ]; then
    printf '%s' "$composed"
    return 0
  fi

  local dir
  dir="$(dirname "$file")"
  [ -d "$dir" ] || mkdir -p "$dir"
  # Idempotent write: skip rewrite when content is byte-identical.
  if [ -f "$file" ] && printf '%s' "$composed" | cmp -s "$file" -; then
    _say "changelog up to date: $file"
    return 0
  fi
  printf '%s' "$composed" > "$file"
  local n
  n="$(printf '%s\n' "$body" | grep -cE '^- ' || true)"
  _say "wrote $file ([Unreleased]: ${n} entr$( [ "$n" = "1" ] && echo y || echo ies )${since_day:+ · since $since_day})"
}

# ── tag / release ──────────────────────────────────────────────────────────────────────────────
cmd_tag() {
  local ver="${1:-}"; shift || true
  [ -n "$ver" ] || _die "usage: herd changelog tag <version> [--date YYYY-MM-DD] [--file PATH] [--dry-run] [--no-tag]"
  case "$ver" in
    -h|--help) _usage; return 0 ;;
  esac
  # strip leading v for the heading; tag always has v prefix
  local bare="$ver"
  case "$bare" in v*) bare="${bare#v}" ;; esac
  case "$bare" in
    [0-9]*) ;;
    *) _die "version must look like 0.1.0 (got '$ver')" ;;
  esac
  local tag="v$bare"
  local file="$CHANGELOG_FILE_DEFAULT" dry=0 no_tag=0 date=""
  date="$(date -u +%Y-%m-%d 2>/dev/null || date +%Y-%m-%d)"
  while [ $# -gt 0 ]; do
    case "$1" in
      --date)    date="${2:-}"; [ -n "$date" ] || _die "--date requires YYYY-MM-DD"; shift 2 ;;
      --date=*)  date="${1#--date=}"; shift ;;
      --file)    file="${2:-}"; [ -n "$file" ] || _die "--file requires a path"; shift 2 ;;
      --file=*)  file="${1#--file=}"; shift ;;
      --dry-run) dry=1; shift ;;
      --no-tag)  no_tag=1; shift ;;
      -h|--help) _usage; return 0 ;;
      *) _die "tag: unknown argument '$1'" ;;
    esac
  done
  case "$date" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *) _die "--date must be YYYY-MM-DD (got '$date')" ;;
  esac

  # Ensure [Unreleased] reflects the latest journal before promoting (best-effort; still works
  # if the journal is empty — promotes whatever is currently under Unreleased).
  if [ "$dry" -eq 0 ]; then
    cmd_generate --file "$file" >/dev/null || true
  fi

  local new_text
  new_text="$(HERD_CL_FILE="$file" HERD_CL_VER="$bare" HERD_CL_DATE="$date" python3 -c '
import os, re, sys
path = os.environ["HERD_CL_FILE"]
ver = os.environ["HERD_CL_VER"]
date = os.environ["HERD_CL_DATE"]
if not os.path.isfile(path):
    text = "# Changelog\n\n## [Unreleased]\n\n_No merges in scope yet._\n"
else:
    with open(path, encoding="utf-8") as f:
        text = f.read()
# Promote first ## [Unreleased] heading to versioned; insert a fresh empty Unreleased above it.
pat = re.compile(r"^## \[Unreleased\][^\n]*$", re.M)
m = pat.search(text)
if not m:
    # No Unreleased — prepend title + Unreleased + versioned empty section is wrong; create Unreleased then promote.
    if not re.search(r"^# ", text, re.M):
        text = "# Changelog\n\n" + text
    text = re.sub(r"(^# .+\n\n?)", r"\1## [Unreleased]\n\n_No merges in scope yet._\n\n", text, count=1, flags=re.M)
    m = pat.search(text)
if not m:
    print("herd changelog: internal error — could not locate [Unreleased]", file=sys.stderr)
    sys.exit(1)
# Replace the Unreleased heading with versioned; insert fresh Unreleased before it.
fresh = "## [Unreleased]\n\n_No merges in scope yet._\n\n## [%s] - %s" % (ver, date)
out = text[:m.start()] + fresh + text[m.end():]
out = re.sub(r"\n{3,}", "\n\n", out)
if not out.endswith("\n"):
    out += "\n"
sys.stdout.write(out)
')"

  if [ "$dry" -eq 1 ]; then
    printf '%s' "$new_text"
    if [ "$no_tag" -eq 0 ]; then
      _warn "[dry-run] would create annotated tag $tag (not pushed)"
    fi
    return 0
  fi

  printf '%s' "$new_text" > "$file"
  _say "promoted [Unreleased] → [$bare] - $date in $file"

  if [ "$no_tag" -eq 1 ]; then
    _say "skipped git tag (--no-tag)"
    return 0
  fi

  if git -C "$ROOT" rev-parse "$tag" >/dev/null 2>&1; then
    _die "tag $tag already exists — delete it first or pick a new version"
  fi
  # Annotated tag, message = version. Local only; push is HUMAN-VERIFY (docs/releasing.md).
  git -C "$ROOT" tag -a "$tag" -m "$tag"
  _say "created local tag $tag"
  _say "next: commit CHANGELOG.md if dirty, then: git push origin $tag && gh release create $tag --generate-notes"
}

# ── router ─────────────────────────────────────────────────────────────────────────────────────
main() {
  local sub="${1:-generate}"
  case "$sub" in
    generate|gen) shift || true; cmd_generate "$@" ;;
    preview)      shift || true; cmd_generate --stdout "$@" ;;
    tag|release)  shift || true; cmd_tag "$@" ;;
    help|-h|--help) _usage ;;
    -*)
      # bare flags → generate
      cmd_generate "$@"
      ;;
    *)
      # unknown word: if it looks like a version, treat as tag; else error
      case "$sub" in
        v[0-9]*|[0-9]*.[0-9]*) cmd_tag "$@" ;;
        *) _die "unknown subcommand '$sub' (see herd changelog help)" ;;
      esac
      ;;
  esac
}

main "$@"
