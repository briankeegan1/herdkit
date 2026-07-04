#!/usr/bin/env bash
# fleet.sh — helpers for the DETERMINISTIC (no-LLM) multi-project fan-out behind `herd fleet`
# (P0 of the Master / fleet coordinator EPIC). Sourced by bin/herd; defines functions only, so
# sourcing is side-effect-free and safe before bin/herd finishes wiring its own helpers.
#
# The model: a flat PROJECT REGISTRY (one line per project) that the fan-out loops over. Every
# per-project action DELEGATES to that project's own `herd` command in that project's directory —
# fleet.sh never reimplements update/reload and never mutates a project's tree beyond what the
# delegated command already does. Read-mostly by construction.
#
# Registry file (default ~/.herd/fleet; override with HERD_FLEET_FILE for tests / alt homes):
#   one record per line, pipe-delimited:  name|path|repo
#   blank lines and #-comments are ignored. `name` is the project's WORKSPACE_NAME, `path` its
#   PROJECT_ROOT, `repo` its HERD_REPO (may be empty).
#
# Dependencies it leans on: each project's committed `.herd/config` (WORKSPACE_NAME / PROJECT_ROOT /
# WORKTREES_DIR / DEFAULT_BRANCH / HERD_REPO), the per-project journal at
# $WORKTREES_DIR/.herd/journal.jsonl, and the per-workspace watcher argv0 marker herd-watch-<slug>
# (issue #60 attribution — the same marker _list_project_watchers in bin/herd reaps by).
#
# This file uses say/ok/warn/die + the colour vars from bin/herd. They are resolved at CALL time
# (bash late-binds function/name lookups), so it is fine that bin/herd defines them AFTER sourcing.

# ── Registry path + safe field helpers ──────────────────────────────────────
_fleet_registry_file() { printf '%s' "${HERD_FLEET_FILE:-$HOME/.herd/fleet}"; }

# _fleet_slug <workspace-name> — the sanitized workspace slug, byte-identical to herd-config.sh's
# _HERD_WS_SLUG derivation, so herd-watch-<slug> here matches the live watcher's argv0 marker.
_fleet_slug() {
  local s; s="$(printf '%s' "$1" | tr -c 'A-Za-z0-9_-' '-')"
  [ -n "$s" ] || s="project"
  printf '%s' "$s"
}

# _fleet_sanitize <value> — strip the pipe delimiter, CRs and newlines from a value before it goes
# into a registry record, so a stray char can never corrupt the one-record-per-line format.
_fleet_sanitize() { printf '%s' "$1" | tr -d '|\r\n'; }

# _fleet_read_config <project-path> — source that project's .herd/config in an ISOLATED subshell
# (so its vars never leak into the fleet process or bleed between projects) and print one TAB-
# delimited row:  workspace<TAB>project_root<TAB>worktrees_dir<TAB>default_branch<TAB>repo
# Applies the SAME fallbacks herd-config.sh does. Returns non-zero if there is no config to read.
_fleet_read_config() {
  local path="$1" cfg="$1/.herd/config"
  [ -f "$cfg" ] || return 1
  (
    set +eu 2>/dev/null || true
    PROJECT_ROOT=""; WORKTREES_DIR=""; WORKSPACE_NAME=""; DEFAULT_BRANCH=""; HERD_REPO=""
    # shellcheck source=/dev/null
    . "$cfg" 2>/dev/null || exit 1
    : "${PROJECT_ROOT:="$path"}"
    : "${WORKTREES_DIR:="${PROJECT_ROOT}-trees"}"
    : "${DEFAULT_BRANCH:="origin/main"}"
    : "${WORKSPACE_NAME:="$(basename "$PROJECT_ROOT")"}"
    printf '%s\t%s\t%s\t%s\t%s\n' \
      "$WORKSPACE_NAME" "$PROJECT_ROOT" "$WORKTREES_DIR" "$DEFAULT_BRANCH" "$HERD_REPO"
  )
}

# _fleet_each REGISTRY-CALLBACK — read the registry and call `$1 name path repo` per valid record,
# skipping blanks/comments. Returns 1 (and the caller reports empty) when the registry is missing or
# has no records. Central so every subcommand iterates the registry identically.
_fleet_each() {
  local cb="$1" reg; reg="$(_fleet_registry_file)"
  [ -f "$reg" ] || return 1
  local seen=0 line name path repo
  while IFS='|' read -r name path repo; do
    case "$name" in ''|'#'*) continue ;; esac
    [ -n "$path" ] || continue
    seen=1
    "$cb" "$name" "$path" "$repo"
  done < "$reg"
  [ "$seen" -eq 1 ]
}

# _fleet_repo_slug <target-path> — resolve owner/repo from the TARGET path's OWN `origin` remote,
# ALWAYS via `git -C "$target"` so it reads the registered tree's remote and never the caller's cwd
# remote (issue #128: registering project B from inside project A's checkout must record B's repo).
# Normalizes the common git URL forms — scp-form `git@host:owner/repo.git`, `ssh://…`, `https://…`,
# `git://…` — down to `owner/repo`, mirroring bin/herd's _gh_repo_slug stripping. Prints EMPTY (and
# the caller records an empty field + a note) when the target has no origin remote, git is absent, or
# the URL cannot be parsed into an owner/repo pair. This is a repo IDENTITY (the project's own code
# repo), distinct from the config's HERD_REPO (where ENGINE bugs escalate — herdkit for every project,
# which is exactly what used to leak into every registry row).
_fleet_repo_slug() {
  local path="$1" url p owner repo
  command -v git >/dev/null 2>&1 || return 0
  url="$(git -C "$path" remote get-url origin 2>/dev/null || true)"
  [ -n "$url" ] || return 0
  p="${url%.git}"          # drop a trailing .git
  p="${p%/}"               # drop a trailing slash
  p="${p##*://}"           # strip a scheme:// prefix (https://, ssh://, git://)
  p="${p#*@}"              # strip a user@ prefix (git@…)
  p="${p/://}"             # scp-form host:owner → host/owner (first ':' only). NB: the replacement is
                           # a bare '/', NOT '\/' — bash keeps the backslash verbatim in ${v/p/repl},
                           # which would corrupt a bare-SSH slug (git@host:proj → host\/proj).
  # Require an owner segment: a slash must separate owner from repo. A single-segment URL (a bare
  # `myrepo` with no owner) is rejected here — NOT via owner==repo, which would wrongly blank valid
  # matching-name slugs like eslint/eslint or prettier/prettier (issue #128 review).
  case "$p" in */*) ;; *) return 0 ;; esac
  repo="${p##*/}"          # last path segment is the repo
  p="${p%/*}"              # …strip it, leaving …/owner (host, if any, precedes owner)
  owner="${p##*/}"         # the segment before the repo is the owner (host drops away)
  [ -n "$owner" ] && [ -n "$repo" ] && printf '%s/%s' "$owner" "$repo"
}

# ── register / list / discover ───────────────────────────────────────────────

# fleet_register <path> — resolve <path>, read its .herd/config, and append (or refresh) its
# name|path|repo record in the registry. Idempotent: re-registering the same path rewrites its row
# rather than duplicating it. Fails loudly (die) when the path has no .herd/config.
fleet_register() {
  local raw="${1:-}"
  [ -n "$raw" ] || die "usage: herd fleet register <project-path>"
  local path
  path="$(cd "$raw" 2>/dev/null && pwd -P)" || die "no such directory: $raw"
  [ -f "$path/.herd/config" ] || die "not a herd project (no .herd/config): $path"

  local row; row="$(_fleet_read_config "$path")" || die "could not read $path/.herd/config"
  local name repo pr
  name="$(_fleet_sanitize "$(printf '%s' "$row" | cut -f1)")"
  pr="$(printf '%s' "$row" | cut -f2)"       # resolved PROJECT_ROOT — canonical registry path
  [ -n "$pr" ] && path="$pr"
  path="$(_fleet_sanitize "$path")"
  # Repo IDENTITY comes from the TARGET tree's own origin remote (issue #128) — NOT the config's
  # HERD_REPO (that is the engine-escalation repo, herdkit for every project) and NOT the caller's cwd.
  repo="$(_fleet_sanitize "$(_fleet_repo_slug "$path")")"
  [ -n "$repo" ] || warn "no parseable origin remote at $path — registered with an empty repo field"

  local reg; reg="$(_fleet_registry_file)"
  mkdir -p "$(dirname "$reg")" 2>/dev/null || die "cannot create registry dir: $(dirname "$reg")"
  if [ ! -f "$reg" ]; then
    printf '# herdkit fleet registry — one project per line: name|path|repo\n' > "$reg" \
      || die "cannot write registry: $reg"
  fi

  # Drop any existing record for this path (idempotent refresh), then append the fresh row.
  local tmp; tmp="$(mktemp)" || die "mktemp failed"
  local ln lp lr
  while IFS='|' read -r ln lp lr; do
    case "$ln" in '#'*) printf '%s\n' "$ln|$lp|$lr" >> "$tmp"; continue ;; esac
    [ "$lp" = "$path" ] && continue          # replaced below
    [ -n "$ln" ] && printf '%s\n' "$ln|$lp|$lr" >> "$tmp"
  done < "$reg"
  printf '%s|%s|%s\n' "$name" "$path" "$repo" >> "$tmp"
  mv "$tmp" "$reg" || { rm -f "$tmp"; die "cannot update registry: $reg"; }

  ok "registered ${c_bold}$name${c_rst} → $path${repo:+  ($repo)}"
}

# fleet_list — print the registry as a simple table (name, path, repo). Empty registry is a
# friendly note, not an error.
fleet_list() {
  local reg; reg="$(_fleet_registry_file)"
  if [ ! -f "$reg" ]; then
    say "no fleet registry yet ($reg) — add a project with: herd fleet register <path>"
    return 0
  fi
  local n=0 name path repo
  printf '%s%-16s %-44s %s%s\n' "$c_bold" "PROJECT" "PATH" "REPO" "$c_rst"
  while IFS='|' read -r name path repo; do
    case "$name" in ''|'#'*) continue ;; esac
    n=$((n+1))
    printf '%-16s %-44s %s\n' "$name" "$path" "${repo:-—}"
  done < "$reg"
  if [ "$n" -eq 0 ]; then
    say "(registry is empty — add a project with: herd fleet register <path>)"
  else
    say ""
    say "$n project(s) · registry: $reg"
  fi
}

# _fleet_registered_paths — print the canonical PROJECT_ROOT of every registered project, one per
# line (skipping blanks/comments). Discover uses this to DEDUP projects already in the registry, and
# to derive its default scan roots. The registry stores the SAME resolved PROJECT_ROOT that
# _fleet_read_config yields, so a discovered project's path matches its registry line byte-for-byte.
_fleet_registered_paths() {
  local reg; reg="$(_fleet_registry_file)"
  [ -f "$reg" ] || return 0
  local n p r
  while IFS='|' read -r n p r; do
    case "$n" in ''|'#'*) continue ;; esac
    [ -n "$p" ] && printf '%s\n' "$p"
  done < "$reg"
}

# _fleet_discover_default_roots — the scan roots `discover` uses when given none: "sensible parents"
# (the EPIC's phrase for auto-discovery). HERD_FLEET_DISCOVER_ROOTS (colon-separated) overrides — a
# test seam AND the inline default until a real scan-roots CONFIG KEY lands. (FOLLOW-UP: a
# HERD_FLEET_DISCOVER_ROOTS / scan-roots key in capabilities.tsv — the config schema is locked this
# wave, so no new key is added here.) Otherwise: the parent dir of each already-registered project
# (to surface its untracked siblings) plus the parent of PROJECT_ROOT / CWD. Order-preserving +
# de-duplicated; callers still skip any entry that is not a directory.
_fleet_discover_default_roots() {
  if [ -n "${HERD_FLEET_DISCOVER_ROOTS:-}" ]; then
    printf '%s' "$HERD_FLEET_DISCOVER_ROOTS" | tr ':' '\n' | awk 'NF && !seen[$0]++'
    return 0
  fi
  {
    local p
    while IFS= read -r p; do
      [ -n "$p" ] && dirname "$p"
    done < <(_fleet_registered_paths)
    dirname "${PROJECT_ROOT:-$PWD}"
  } | awk 'NF && !seen[$0]++'
}

# fleet_discover [--register|--yes] [<root>...] — scan the given roots (default: the sensible parents
# from _fleet_discover_default_roots) for .herd/config files and print each herd project found
# (workspace / path / repo / STATUS). A project ALREADY in the registry is listed but marked
# `registered` and never re-offered (dedup); a not-yet-registered one is marked `new`. With
# --register / --yes each NEW project is added to the registry. Default is a DRY RUN — it writes
# nothing. This is the auto-discovery helper; `herdr workspace list` separately enumerates the LIVE
# ones. Non-directory roots and roots with no projects are handled gracefully (warn / friendly note).
fleet_discover() {
  local do_register=""
  case "${1:-}" in --register|-r|--yes|-y) do_register=1; shift ;; esac

  # Roots: explicit args win; otherwise fall back to the sensible-parents default so a bare
  # `herd fleet discover` still does something useful.
  local roots=()
  if [ "$#" -gt 0 ]; then
    roots=("$@")
  else
    local d
    while IFS= read -r d; do [ -n "$d" ] && roots+=("$d"); done < <(_fleet_discover_default_roots)
  fi
  [ "${#roots[@]}" -gt 0 ] \
    || die "usage: herd fleet discover [--register] [<root>...]  (no default roots could be resolved)"

  # Snapshot the already-registered canonical paths once, for dedup lookups in the scan loop.
  local registered_paths; registered_paths="$(_fleet_registered_paths)"

  local root found=0 new=0 already=0
  printf '%s%-16s %-40s %-14s %s%s\n' "$c_bold" "PROJECT" "PATH" "REPO" "STATUS" "$c_rst"
  for root in "${roots[@]}"; do
    [ -d "$root" ] || { warn "not a directory, skipping: $root"; continue; }
    local rootabs; rootabs="$(cd "$root" 2>/dev/null && pwd -P)" || { warn "cannot enter: $root"; continue; }
    # Bounded scan for .herd/config; the project root is the dir that OWNS the .herd dir.
    while IFS= read -r cfg; do
      [ -n "$cfg" ] || continue
      local proj; proj="$(cd "$(dirname "$cfg")/.." 2>/dev/null && pwd -P)" || continue
      local row; row="$(_fleet_read_config "$proj")" || continue
      local name repo
      name="$(printf '%s' "$row" | cut -f1)"
      proj="$(printf '%s' "$row" | cut -f2)"
      # Same repo-identity source as register: the project's OWN origin remote (issue #128), so the
      # discover table's REPO column matches what --register would store — never the config's HERD_REPO.
      repo="$(_fleet_repo_slug "$proj")"
      found=$((found+1))

      local status
      if printf '%s\n' "$registered_paths" | grep -qxF "$proj"; then
        already=$((already+1))
        status="${c_dim}registered${c_rst}"
      else
        new=$((new+1))
        status="${c_grn}new${c_rst}"
        if [ -n "$do_register" ]; then
          # Subshell so a stray die() inside fleet_register (e.g. config vanished mid-scan) cannot
          # abort the whole discover run — we record the failure per project and keep going.
          if ( fleet_register "$proj" ) >/dev/null 2>&1; then
            status="${c_grn}registered ✓${c_rst}"
          else
            status="${c_red}register failed${c_rst}"
          fi
        fi
      fi
      printf '%-16s %-40s %-14s %s\n' "$name" "$proj" "${repo:-—}" "$status"
    done < <(find "$rootabs" -maxdepth "${HERD_FLEET_DISCOVER_DEPTH:-5}" -type f -path '*/.herd/config' 2>/dev/null | sort -u)
  done

  say ""
  if [ "$found" -eq 0 ]; then
    say "no herd projects found under: ${roots[*]}"
  elif [ -n "$do_register" ]; then
    say "$found project(s) found ($new newly registered, $already already in registry)"
  else
    say "$found project(s) found ($new new, $already already registered)"
    if [ "$new" -gt 0 ]; then
      say "register the new one(s) with: herd fleet discover --register <root>..."
    fi
  fi
  return 0
}

# ── status rollup ────────────────────────────────────────────────────────────

# _fleet_branch <project-path> — current branch (or a short SHA if detached); '—' when not a repo.
_fleet_branch() {
  local b
  b="$(git -C "$1" rev-parse --abbrev-ref HEAD 2>/dev/null)" || { printf '—'; return; }
  if [ "$b" = "HEAD" ]; then
    b="$(git -C "$1" rev-parse --short HEAD 2>/dev/null)"; b="detached@${b:-?}"
  fi
  printf '%s' "$b"
}

# _fleet_open_prs <project-path> <repo> — open-PR count via gh; '?' when gh is absent/unauthed/fails
# (never fatal — status must render even fully offline).
_fleet_open_prs() {
  command -v gh >/dev/null 2>&1 || { printf '?'; return; }
  local n
  n="$(cd "$1" 2>/dev/null && gh pr list --state open --json number --jq 'length' 2>/dev/null)" \
    || { printf '?'; return; }
  case "$n" in ''|*[!0-9]*) printf '?' ;; *) printf '%s' "$n" ;; esac
}

# _fleet_watcher_state <workspace-name> — 'alive' if a process whose argv0 EXACTLY equals this
# project's herd-watch-<slug> marker is running, else 'down'; '?' when pgrep is unavailable. Matches
# argv0 exactly (not a pgrep substring) so workspace "north" never reads "northern"'s watcher.
_fleet_watcher_state() {
  command -v pgrep >/dev/null 2>&1 || { printf '?'; return; }
  local marker; marker="herd-watch-$(_fleet_slug "$1")"
  local pid a0
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    a0="$(ps -o args= -p "$pid" 2>/dev/null | awk '{print $1}')"
    if [ "$a0" = "$marker" ]; then printf 'alive'; return; fi
  done < <(pgrep -f "$marker" 2>/dev/null || true)
  printf 'down'
}

# _fleet_last_activity <worktrees-dir> — last journal event as "ts event", or '—' if none. The
# journal lives at $WORKTREES_DIR/.herd/journal.jsonl (journal.sh _journal_file).
_fleet_last_activity() {
  local jf="$1/.herd/journal.jsonl"
  [ -f "$jf" ] || { printf '—'; return; }
  local last; last="$(tail -n 1 "$jf" 2>/dev/null)"
  [ -n "$last" ] || { printf '—'; return; }
  printf '%s' "$last" | python3 -c '
import sys, json
try:
    o = json.loads(sys.stdin.readline() or "{}")
    ts = str(o.get("ts", "?")); ev = str(o.get("event", "?"))
    sys.stdout.write((ts + " " + ev).strip() or "-")
except Exception:
    sys.stdout.write("-")
' 2>/dev/null || printf '—'
}

# _fleet_status_row name path repo — the per-project rollup callback (used by _fleet_each).
_fleet_status_row() {
  local name="$1" path="$2" repo="$3"
  if [ ! -d "$path" ] || [ ! -f "$path/.herd/config" ]; then
    printf '%-16s %-22s %5s  %-7s %s\n' "$name" "${c_yel}missing${c_rst}" "—" "—" "path gone: $path"
    return
  fi
  local row; row="$(_fleet_read_config "$path")" || row=""
  local wt; wt="$(printf '%s' "$row" | cut -f3)"
  [ -n "$wt" ] || wt="${path}-trees"

  local branch prs watcher activity
  branch="$(_fleet_branch "$path")"
  prs="$(_fleet_open_prs "$path" "$repo")"
  watcher="$(_fleet_watcher_state "$name")"
  activity="$(_fleet_last_activity "$wt")"

  local wcol="$watcher"
  case "$watcher" in
    alive) wcol="${c_grn}alive${c_rst}" ;;
    down)  wcol="${c_red}down${c_rst}" ;;
  esac
  printf '%-16s %-22s %5s  %-16s %s\n' "$name" "$branch" "$prs" "$wcol" "$activity"
}

# fleet_status — loop the registry and print a per-project rollup table.
fleet_status() {
  printf '%s%-16s %-22s %5s  %-7s %s%s\n' "$c_bold" "PROJECT" "BRANCH" "PRs" "WATCHER" "LAST ACTIVITY" "$c_rst"
  if ! _fleet_each _fleet_status_row; then
    say "no fleet registry yet ($(_fleet_registry_file)) — add a project with: herd fleet register <path>"
    return 0
  fi
}

# ── upgrade / reload fan-out ─────────────────────────────────────────────────

# _fleet_fanout <verb> <herd-arg>... — run `herd <herd-arg>...` inside every registered project and
# print a per-project outcome table. <verb> is the human label for the header/summary; the remaining
# args are the herd command line delegated verbatim into each project (e.g. `update`, or `config set
# KEY VALUE`). The delegated command owns all guards (the upgrade guard already refuses on a dirty
# tree / mid-flight builders; `config set` validates against capabilities.tsv), so bulk fan-out
# inherits that safety and never reimplements it here. HERD_FLEET_HERD_BIN overrides which herd binary
# is invoked (test seam); defaults to this engine's.
_fleet_fanout() {
  local verb="$1"; shift
  local herd_bin="${HERD_FLEET_HERD_BIN:-${HERDKIT_HOME:-}/bin/herd}"
  local reg; reg="$(_fleet_registry_file)"
  if [ ! -f "$reg" ]; then
    say "no fleet registry yet ($reg) — add a project with: herd fleet register <path>"
    return 0
  fi

  say "${c_bold}herd fleet $verb${c_rst} — running 'herd $*' across the fleet"
  say ""
  printf '%s%-16s %-9s %s%s\n' "$c_bold" "PROJECT" "OUTCOME" "DETAIL" "$c_rst"

  local ok_n=0 fail_n=0 skip_n=0 name path repo
  while IFS='|' read -r name path repo; do
    case "$name" in ''|'#'*) continue ;; esac
    [ -n "$path" ] || continue

    if [ ! -d "$path" ] || [ ! -f "$path/.herd/config" ]; then
      skip_n=$((skip_n+1))
      printf '%-16s %b%-9s%b %s\n' "$name" "$c_yel" "skipped" "$c_rst" "no project at $path"
      continue
    fi

    # Capture via `if` (not a bare `out=$(...)`) so a non-zero delegated command does not trip the
    # caller's `set -e`; we WANT to record the failure and keep fanning out, not abort the fleet.
    local out rc last
    if out="$( cd "$path" 2>/dev/null && HERD_NONINTERACTIVE=1 "$herd_bin" "$@" 2>&1 )"; then
      rc=0
    else
      rc=$?
    fi
    last="$(printf '%s' "$out" | grep -v '^[[:space:]]*$' | tail -n 1 || true)"
    if [ "$rc" -eq 0 ]; then
      ok_n=$((ok_n+1))
      printf '%-16s %b%-9s%b %s\n' "$name" "$c_grn" "ok" "$c_rst" "$last"
    else
      fail_n=$((fail_n+1))
      printf '%-16s %b%-9s%b %s\n' "$name" "$c_red" "failed" "$c_rst" "${last:-exit $rc}"
    fi
  done < "$reg"

  say ""
  say "fleet $verb: ${c_grn}$ok_n ok${c_rst}, ${c_red}$fail_n failed${c_rst}, ${c_yel}$skip_n skipped${c_rst}"
  [ "$fail_n" -eq 0 ]
}

fleet_upgrade() { _fleet_fanout upgrade update; }
fleet_reload()  { _fleet_fanout reload  reload; }

# ── policy propagation (P4) ───────────────────────────────────────────────────
# fleet_set <KEY> <VALUE> — propagate ONE policy across the whole fleet by delegating to each
# registered project's own `herd config set <KEY> <VALUE>` in that project's directory (deterministic,
# no LLM). This is the ONLY writing subcommand in the fleet layer, and even it writes NOTHING itself:
# `herd config set` owns all validation (it rejects unknown keys against capabilities.tsv, refuses
# DENY_PATHS / secret-shaped keys, and restarts the watcher / re-renders the skill for the keys that
# need it), so an invalid KEY/VALUE fails PER PROJECT and is reported — never silently applied. Use it
# to set e.g. MERGE_POLICY / a model tier / TOKEN_MODE fleet-wide in one command; the result is the
# same per-project outcome table the upgrade/reload fan-out prints.
fleet_set() {
  local key="${1:-}"
  { [ -n "$key" ] && [ "$#" -ge 2 ]; } \
    || die "usage: herd fleet set <KEY> <VALUE>   (propagates 'herd config set' across the fleet)"
  local value="$2"
  _fleet_fanout "set $key" config set "$key" "$value"
}

# ── digest / standup (P1) ────────────────────────────────────────────────────
# A DETERMINISTIC (no-LLM) cross-project rollup: aggregate every REGISTERED project's
# .herd/journal.jsonl over a time window and print a per-project standup (shipped / needs-you /
# blocked / in-flight / gate failures) plus one fleet-wide summary line. Read-only — it never
# writes a journal or mutates a tree. The journal format + the live-plus-archives file set are the
# SAME ones `herd log`/`herd why` parse (see bin/herd _journal_all_files / _JOURNAL_FMT); this reuses
# that JSONL contract rather than inventing a new one.

# _fleet_journal_files <worktrees-dir> — print this project's journal files (rotated archives oldest
# first, then the live journal last), one path per line. Mirrors bin/herd's _journal_all_files, which
# is coupled to that command's globals; the file layout is identical.
_fleet_journal_files() {
  local dir="$1/.herd"
  [ -d "$dir" ] || return 0
  ls -1 "$dir"/journal-*.jsonl 2>/dev/null | sort || true
  [ -f "$dir/journal.jsonl" ] && printf '%s\n' "$dir/journal.jsonl"
}

# _fleet_digest_project_lines name path repo — emit this project's manifest block for the aggregator:
#   P<TAB>name<TAB>ok|missing
#   F<TAB><journal-path>            (0+ lines; absent for a missing/journal-less project)
# A path that is gone or not a herd project is marked `missing` (reported, never fatal).
_fleet_digest_project_lines() {
  local name="$1" path="$2"
  if [ ! -d "$path" ] || [ ! -f "$path/.herd/config" ]; then
    printf 'P\t%s\tmissing\n' "$name"
    return 0
  fi
  local row wt
  row="$(_fleet_read_config "$path")" || row=""
  wt="$(printf '%s' "$row" | cut -f3)"
  [ -n "$wt" ] || wt="${path}-trees"
  printf 'P\t%s\tok\n' "$name"
  local f
  while IFS= read -r f; do
    [ -n "$f" ] && printf 'F\t%s\n' "$f"
  done < <(_fleet_journal_files "$wt")
}

# The aggregator (python): reads the P/F manifest on stdin, filters each journal to events at-or-after
# the window cutoff, reduces per PR to a single standup state (shipped > needs-you > blocked >
# in-flight), tallies gate-failure events, and prints the per-project blocks + a fleet summary line.
# Window is HERD_FLEET_SINCE (a duration like 24h/7d/90m/1w; bare number = hours). "Now" is
# HERD_FLEET_NOW when set (ISO-8601 or epoch seconds; a test seam) else the real UTC clock.
_FLEET_DIGEST_PY='
import sys, os, re
from datetime import datetime, timedelta, timezone

def parse_ts(s):
    if not s:
        return None
    s = str(s).strip()
    try:
        # epoch seconds (test seam convenience)
        if re.fullmatch(r"\d+", s):
            return datetime.fromtimestamp(int(s), timezone.utc)
        return datetime.fromisoformat(s.replace("Z", "+00:00"))
    except Exception:
        return None

def parse_duration(s):
    s = (s or "24h").strip().lower()
    m = re.fullmatch(r"(\d+)\s*([smhdw]?)", s)
    if not m:
        raise ValueError("bad --since duration: %r (use e.g. 24h, 7d, 90m, 1w)" % s)
    n = int(m.group(1)); unit = m.group(2) or "h"
    return timedelta(seconds=n * {"s":1,"m":60,"h":3600,"d":86400,"w":604800}[unit])

# JSON: prefer the stdlib json; every line is one object.
import json

since_raw = os.environ.get("HERD_FLEET_SINCE", "24h")
try:
    window = parse_duration(since_raw)
except ValueError as e:
    sys.stderr.write(str(e) + "\n"); sys.exit(2)

now_env = os.environ.get("HERD_FLEET_NOW", "")
now = parse_ts(now_env) if now_env else datetime.now(timezone.utc)
if now is None:
    sys.stderr.write("bad HERD_FLEET_NOW: %r\n" % now_env); sys.exit(2)
cutoff = now - window

# ── read the manifest: ordered projects, each with its journal file list ─────
projects = []      # [(name, status, [files])]
cur = None
for raw in sys.stdin:
    line = raw.rstrip("\n")
    if not line:
        continue
    parts = line.split("\t")
    tag = parts[0]
    if tag == "P":
        name = parts[1] if len(parts) > 1 else "?"
        status = parts[2] if len(parts) > 2 else "ok"
        cur = [name, status, []]
        projects.append(cur)
    elif tag == "F" and cur is not None and len(parts) > 1:
        cur[2].append(parts[1])

FAIL_HC = {"CODEERROR"}   # FLAKY/CLEAN are not code failures

def digest_project(files):
    # Per-PR event reduction over the window.
    prs = {}           # pr -> flags dict
    gate_fails = 0
    saw_event = False
    def pr_state(p):
        return prs.setdefault(p, {"merged":False,"held":False,"escalated":False,
                                  "blocked":False,"dispatched":False,"reaped":False})
    rows = []
    for path in files:
        try:
            fh = open(path, encoding="utf-8")
        except OSError:
            continue
        with fh:
            for ln in fh:
                ln = ln.strip()
                if not ln:
                    continue
                try:
                    o = json.loads(ln)
                except Exception:
                    continue
                ts = parse_ts(o.get("ts"))
                if ts is None or ts < cutoff:
                    continue
                rows.append(o)
    # Process chronologically so held/released toggles resolve in order.
    rows.sort(key=lambda o: str(o.get("ts", "")))
    for o in rows:
        saw_event = True
        ev = o.get("event", "")
        pr = o.get("pr")
        pr = None if pr in (None, "") else str(pr)
        if ev == "merge" and pr:
            pr_state(pr)["merged"] = True
        elif ev == "hold_applied" and pr:
            pr_state(pr)["held"] = True
        elif ev == "hold_released" and pr:
            pr_state(pr)["held"] = False
        elif ev == "review_escalated" and pr:
            pr_state(pr)["escalated"] = True
            gate_fails += 1
        elif ev == "review_dispatched" and pr:
            pr_state(pr)["dispatched"] = True
        elif ev == "reap" and pr:
            pr_state(pr)["reaped"] = True
        elif ev == "verdict_recorded" and pr:
            if str(o.get("value", "")).upper() == "BLOCK":
                pr_state(pr)["blocked"] = True
                gate_fails += 1
        elif ev == "healthcheck_outcome":
            if str(o.get("outcome", "")).upper() in FAIL_HC:
                gate_fails += 1
        elif ev == "infra_event":
            gate_fails += 1

    shipped, needs, blocked, inflight = [], [], [], []
    for p, f in prs.items():
        if f["merged"]:
            shipped.append(p)
        elif f["held"] or f["escalated"]:
            needs.append(p)
        elif f["blocked"]:
            blocked.append(p)
        elif f["dispatched"] and not f["reaped"]:
            inflight.append(p)
    def key(p):
        try: return (0, int(p))
        except ValueError: return (1, p)
    for lst in (shipped, needs, blocked, inflight):
        lst.sort(key=key)
    return {"shipped":shipped,"needs":needs,"blocked":blocked,"inflight":inflight,
            "gate_fails":gate_fails,"saw_event":saw_event}

def fmt_prs(lst):
    return "  (%s)" % ", ".join("#" + p for p in lst) if lst else ""

# Human window label (echo the raw --since; it is already the natural phrase).
win = since_raw
print("herd fleet digest — standup over last %s (since %s)" %
      (win, cutoff.strftime("%Y-%m-%dT%H:%M:%SZ")))
print("")

tot = {"projects":0,"shipped":0,"needs":0,"blocked":0,"inflight":0,"gate_fails":0,"missing":0}
for name, status, files in projects:
    tot["projects"] += 1
    print(name)
    if status != "ok":
        tot["missing"] += 1
        print("  (unreachable — path or .herd/config missing)")
        print("")
        continue
    d = digest_project(files)
    tot["shipped"]  += len(d["shipped"])
    tot["needs"]    += len(d["needs"])
    tot["blocked"]  += len(d["blocked"])
    tot["inflight"] += len(d["inflight"])
    tot["gate_fails"] += d["gate_fails"]
    if not d["saw_event"]:
        print("  (no activity in window)")
        print("")
        continue
    print("  shipped:    %3d%s" % (len(d["shipped"]), fmt_prs(d["shipped"])))
    print("  needs you:  %3d%s" % (len(d["needs"]), fmt_prs(d["needs"])))
    print("  blocked:    %3d%s" % (len(d["blocked"]), fmt_prs(d["blocked"])))
    print("  in-flight:  %3d%s" % (len(d["inflight"]), fmt_prs(d["inflight"])))
    print("  gate fails: %3d" % d["gate_fails"])
    print("")

miss = (" · %d unreachable" % tot["missing"]) if tot["missing"] else ""
print("Fleet: %d project%s · %d shipped · %d need you · %d blocked · %d in-flight · %d gate failure%s%s  ·  window: last %s" % (
    tot["projects"], "" if tot["projects"]==1 else "s",
    tot["shipped"], tot["needs"], tot["blocked"], tot["inflight"],
    tot["gate_fails"], "" if tot["gate_fails"]==1 else "s", miss, win))
'

# fleet_digest [--since <duration>] — the cross-project standup. Default window: last 24h.
fleet_digest() {
  local since="24h"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --since)   since="${2:-}"; [ -n "$since" ] || die "--since requires a duration (e.g. 24h, 7d)"; shift 2 ;;
      --since=*) since="${1#--since=}"; [ -n "$since" ] || die "--since requires a duration (e.g. 24h, 7d)"; shift ;;
      -h|--help)
        cat <<EOF
usage: herd fleet digest [--since <duration>]

  Cross-project DAILY DIGEST / standup, aggregated from every registered project's
  .herd/journal.jsonl (deterministic, no LLM). Per project over the window:
  shipped (merged), needs-you (holds/escalations), blocked (BLOCK verdicts),
  in-flight (active reviews), and gate-failure count; plus a fleet-wide summary.

  --since <duration>   window to roll up (default 24h). Suffixes: s m h d w; a bare
                       number is hours. Examples: --since 24h, --since 7d, --since 90m
EOF
        return 0 ;;
      *) die "usage: herd fleet digest [--since <duration>]" ;;
    esac
  done

  local reg; reg="$(_fleet_registry_file)"
  if [ ! -f "$reg" ]; then
    say "no fleet registry yet ($reg) — add a project with: herd fleet register <path>"
    return 0
  fi

  local manifest
  manifest="$(_fleet_each _fleet_digest_project_lines)" || manifest=""
  if [ -z "$manifest" ]; then
    say "no fleet registry yet ($reg) — add a project with: herd fleet register <path>"
    return 0
  fi

  printf '%s\n' "$manifest" | HERD_FLEET_SINCE="$since" python3 -c "$_FLEET_DIGEST_PY"
}

# ── attention inbox (P2) ─────────────────────────────────────────────────────
# A DETERMINISTIC (no-LLM) cross-project ATTENTION INBOX: ONE view of what needs the human RIGHT
# NOW across every REGISTERED project — blocked PRs (review BLOCK), human-verify / approval holds,
# CONFLICTING PRs, failed health gates, and escalated reviews. Read-only. It combines two sources
# per project, REUSING the P0 registry loader + the journal helpers rather than reinventing them:
#   • that project's .herd/journal.jsonl — the watcher's own record of holds / verdicts / gate
#     outcomes (the SAME JSONL contract `herd why`/the digest parse), reduced to the CURRENT state
#     of each PR (a hold that was released, a BLOCK that later passed, or a merged PR clears itself);
#   • the LIVE open PRs from gh (per project repo) — the authoritative source for CONFLICTING, which
#     is a mergeability fact gh computes, not a journal event.
# Every item prints as  project · PR# · reason · suggested action; a project with nothing pending
# shows as clean; an unreachable project (or one where gh is unavailable) is reported, never fatal.

# _fleet_inbox_gh_prs <project-path> — emit this project's LIVE open PRs for the manifest:
#   G<TAB><pr><TAB><branch><TAB><mergeable>   (0+ lines)
#   X<TAB>gh-missing | X<TAB>gh-error         (when gh is absent / unauthed / fails)
# Never fatal: gh problems become an X note the aggregator surfaces, so journal-derived items still
# render fully offline. Mirrors _fleet_open_prs' "gh is best-effort" contract, richer fields.
_fleet_inbox_gh_prs() {
  local path="$1"
  command -v gh >/dev/null 2>&1 || { printf 'X\tgh-missing\n'; return 0; }
  local json rc
  # Capture via `if` so a non-zero gh (unauthed / offline) does not trip the caller's set -e.
  if json="$( cd "$path" 2>/dev/null && gh pr list --state open --limit 200 \
                --json number,headRefName,mergeable 2>/dev/null )"; then
    rc=0
  else
    rc=$?
  fi
  [ "$rc" -eq 0 ] || { printf 'X\tgh-error\n'; return 0; }
  [ -n "$json" ] || return 0
  printf '%s' "$json" | python3 -c '
import sys, json
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if not isinstance(data, list):
    sys.exit(0)
for pr in data:
    if not isinstance(pr, dict):
        continue
    num = pr.get("number", "")
    if num == "":
        continue
    br = str(pr.get("headRefName", "") or "").replace("\t", " ").replace("\n", " ")
    mg = str(pr.get("mergeable", "") or "").replace("\t", " ").replace("\n", " ")
    sys.stdout.write("G\t%s\t%s\t%s\n" % (num, br, mg))
' 2>/dev/null || true
}

# _fleet_inbox_project_lines name path repo — emit this project's manifest block for the aggregator:
#   P<TAB>name<TAB>ok|missing
#   F<TAB><journal-path>            (0+; the same file set the digest reads)
#   G<TAB><pr><TAB><branch><TAB><mergeable> / X<TAB><note>   (from _fleet_inbox_gh_prs)
# A path that is gone or not a herd project is marked `missing` (reported, never fatal).
_fleet_inbox_project_lines() {
  local name="$1" path="$2"
  if [ ! -d "$path" ] || [ ! -f "$path/.herd/config" ]; then
    printf 'P\t%s\tmissing\n' "$name"
    return 0
  fi
  local row wt
  row="$(_fleet_read_config "$path")" || row=""
  wt="$(printf '%s' "$row" | cut -f3)"
  [ -n "$wt" ] || wt="${path}-trees"
  printf 'P\t%s\tok\n' "$name"
  local f
  while IFS= read -r f; do
    [ -n "$f" ] && printf 'F\t%s\n' "$f"
  done < <(_fleet_journal_files "$wt")
  _fleet_inbox_gh_prs "$path"
}

# The aggregator (python): reads the P/F/G/X manifest on stdin. For each project it reduces the
# journal to the CURRENT per-PR state (chronologically, so hold_applied→hold_released, BLOCK→PASS,
# and merge/reap toggles resolve in order), joins that with gh's CONFLICTING PRs, and prints one
# attention line per (PR, reason) with a suggested action, plus a fleet-wide count.
_FLEET_INBOX_PY='
import sys, json

def prkey(p):
    try:
        return (0, int(p))
    except (TypeError, ValueError):
        return (1, str(p))

# ── read the manifest: ordered projects, each with journal files + gh PRs + notes ─
projects = []      # list of dicts
cur = None
for raw in sys.stdin:
    line = raw.rstrip("\n")
    if not line:
        continue
    parts = line.split("\t")
    tag = parts[0]
    if tag == "P":
        cur = {"name": parts[1] if len(parts) > 1 else "?",
               "status": parts[2] if len(parts) > 2 else "ok",
               "files": [], "gh": [], "notes": []}
        projects.append(cur)
    elif tag == "F" and cur is not None and len(parts) > 1:
        cur["files"].append(parts[1])
    elif tag == "G" and cur is not None and len(parts) >= 4:
        cur["gh"].append((parts[1], parts[2], parts[3]))
    elif tag == "X" and cur is not None and len(parts) > 1:
        cur["notes"].append(parts[1])

def slug_from_branch(b):
    # Worktrees live at $WORKTREES_DIR/<slug>; the slug is the last path segment of the branch
    # (e.g. feat/login-fix -> login-fix), matching agent-watch.sh basename(worktree) convention.
    return b.rsplit("/", 1)[-1] if b else ""

def reduce_journal(files):
    rows = []
    for path in files:
        try:
            fh = open(path, encoding="utf-8")
        except OSError:
            continue
        with fh:
            for ln in fh:
                ln = ln.strip()
                if not ln:
                    continue
                try:
                    rows.append(json.loads(ln))
                except Exception:
                    continue
    rows.sort(key=lambda o: str(o.get("ts", "")))
    st = {}
    def S(p):
        return st.setdefault(p, {"blocked": False, "held": False, "hold_kind": "",
                                 "escalated": False, "health": False, "done": False, "slug": ""})
    for o in rows:
        ev = o.get("event", "")
        pr = o.get("pr")
        pr = None if pr in (None, "") else str(pr)
        if pr is None:
            continue
        s = S(pr)
        sl = o.get("slug")
        if sl:
            s["slug"] = str(sl)
        if ev == "merge" or (ev == "reap" and str(o.get("reason", "")) == "merged"):
            s["done"] = True
            s["blocked"] = s["held"] = s["escalated"] = s["health"] = False
        elif ev == "verdict_recorded":
            s["blocked"] = str(o.get("value", "")).upper() == "BLOCK"
            s["escalated"] = False           # a fresh verdict supersedes an earlier escalation
        elif ev == "review_escalated":
            s["escalated"] = True
        elif ev == "review_dispatched":
            s["escalated"] = False           # a re-review is underway; wait for its verdict
        elif ev == "hold_applied":
            s["held"] = True
            s["hold_kind"] = str(o.get("kind", ""))
        elif ev == "hold_released":
            s["held"] = False
        elif ev == "healthcheck_outcome":
            oc = str(o.get("outcome", "")).upper()
            if oc == "CODEERROR":
                s["health"] = True
            elif oc in ("CLEAN", "FLAKY"):
                s["health"] = False
    return st

def project_items(p):
    st = reduce_journal(p["files"])
    # gh gives the AUTHORITATIVE set of currently-open PRs. A journal-derived attention item
    # (BLOCK / hold / escalation / failed health gate) for a PR that is no longer open — closed or
    # merged OUT OF BAND, so the journal never saw a merge/reap to clear it — is STALE and must be
    # dropped (issue #131: a 2-day-old BLOCK row kept surfacing on a since-CLOSED PR). When gh is
    # UNAVAILABLE we cannot prove a PR is closed, so we FAIL OPEN and keep journal items (same
    # best-effort posture the CONFLICTING check already takes offline).
    gh_down = any(str(n).startswith("gh") for n in p["notes"])
    open_prs = set(str(pr) for pr, branch, mergeable in p["gh"])
    conflicts = {}
    for pr, branch, mergeable in p["gh"]:
        if str(mergeable).upper() == "CONFLICTING":
            conflicts[str(pr)] = branch
    items = []   # (pr, reason, action)
    for pr, s in st.items():
        if s["done"]:
            continue
        # Cross-check against the live open-PR set — drop stale rows for closed/merged PRs.
        if not gh_down and pr not in open_prs:
            continue
        if s["held"]:
            kind = s["hold_kind"]
            if kind == "human-verify":
                reason = "human-verify hold"
            elif kind == "approve":
                reason = "approval hold"
            else:
                reason = "hold (%s)" % kind if kind else "hold"
            items.append((pr, reason, "herd-approve.sh approve %s" % pr))
        if s["blocked"]:
            items.append((pr, "review BLOCK", "herd why %s" % pr))
        if s["escalated"]:
            items.append((pr, "review escalated", "herd why %s" % pr))
        if s["health"]:
            items.append((pr, "health gate failed", "herd why %s" % pr))
    for pr, branch in conflicts.items():
        sl = st.get(pr, {}).get("slug") or slug_from_branch(branch) or pr
        items.append((pr, "CONFLICTING", "herd-resolve.sh %s" % sl))
    items.sort(key=lambda it: (prkey(it[0]), it[1]))
    return items

print("herd fleet inbox — what needs you right now across the fleet")
print("")

tot_items = 0
proj_needy = 0
clean = 0
missing = 0
for p in projects:
    name = p["name"]
    print(name)
    if p["status"] != "ok":
        missing += 1
        print("  (unreachable — path or .herd/config missing)")
        print("")
        continue
    gh_down = any(str(n).startswith("gh") for n in p["notes"])
    items = project_items(p)
    if not items:
        clean += 1
        print("  ✓ clean — nothing pending")
        if gh_down:
            print("  (gh unavailable — CONFLICTING PRs not checked)")
        print("")
        continue
    proj_needy += 1
    for pr, reason, action in items:
        tot_items += 1
        print("  #%-5s %-20s → %s" % (pr, reason, action))
    if gh_down:
        print("  (gh unavailable — CONFLICTING PRs not checked)")
    print("")

miss = (" · %d unreachable" % missing) if missing else ""
print("Fleet: %d item%s need you across %d project%s · %d clean%s" % (
    tot_items, "" if tot_items == 1 else "s",
    proj_needy, "" if proj_needy == 1 else "s",
    clean, miss))
'

# fleet_inbox — the cross-project attention inbox. No window: it reports the CURRENT state.
fleet_inbox() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help)
        cat <<EOF
usage: herd fleet inbox

  Cross-project ATTENTION INBOX (deterministic, no LLM): ONE view of what needs
  you RIGHT NOW across every registered project. Per project it surfaces each
  pending item as  PR# · reason · suggested action:
    review BLOCK          a reviewer blocked the PR          -> herd why <pr>
    human-verify hold     a HUMAN-VERIFY step is pending     -> herd-approve.sh approve <pr>
    approval hold         MERGE_POLICY=approve is waiting    -> herd-approve.sh approve <pr>
    review escalated      the review needs a human call      -> herd why <pr>
    health gate failed    the healthcheck hit a CODE error   -> herd why <pr>
    CONFLICTING           the PR no longer merges cleanly    -> herd-resolve.sh <slug>
  plus a fleet-wide count. Holds/blocks/gates come from each project's journal
  (current state — a released hold or merged PR clears itself); CONFLICTING comes
  from live gh. A project with nothing pending shows as clean; an unreachable
  project (or one where gh is unavailable) is reported, never fatal.
EOF
        return 0 ;;
      *) die "usage: herd fleet inbox   (no arguments; try: herd fleet inbox --help)" ;;
    esac
  done

  local reg; reg="$(_fleet_registry_file)"
  if [ ! -f "$reg" ]; then
    say "no fleet registry yet ($reg) — add a project with: herd fleet register <path>"
    return 0
  fi

  local manifest
  manifest="$(_fleet_each _fleet_inbox_project_lines)" || manifest=""
  if [ -z "$manifest" ]; then
    say "no fleet registry yet ($reg) — add a project with: herd fleet register <path>"
    return 0
  fi

  printf '%s\n' "$manifest" | python3 -c "$_FLEET_INBOX_PY"
}

# ── governance: global concurrency view (P4) ──────────────────────────────────
# A READ-ONLY fleet-wide GOVERNANCE view: total in-flight BUILDERS + REVIEWS summed across every
# registered project. The Claude account usage limit is ACCOUNT-WIDE (observed 2026-07-02: two sibling
# projects competing for one quota caused a mid-task limit hit), so surfacing the fleet-wide in-flight
# total in one place is how the operator avoids limit-hits. It aggregates from each project's own
# watcher/agent STATE — the SAME signals agent-watch.sh itself uses — rather than re-deriving them:
#   • builders = ACTIVE FEATURE worktrees (git worktree list, main checkout excluded) — exactly the
#                FEATS set agent-watch.sh renders under "in flight".
#   • reviews  = live .review-inflight-<pr>-<sha> markers under $WORKTREES_DIR whose reviewer pid is
#                still alive — mirrors agent-watch.sh's _count_live_reviews (dead markers are reaped by
#                the owning watcher, so a severed reviewer's stale marker never inflates the count).
# Read-only: it never spawns, kills, or writes anything. Unreachable projects are reported, not fatal.

# _fleet_count_builders <project-path> — count of ACTIVE FEATURE worktrees for this project (all of
# its git worktrees minus the main checkout, i.e. one per in-flight builder). '0' when git is absent
# or the path is not a git repo. Mirrors agent-watch.sh's FEATS enumeration (MAIN excluded).
_fleet_count_builders() {
  local path="$1"
  command -v git >/dev/null 2>&1 || { printf '0'; return; }
  local main; main="$(git -C "$path" rev-parse --show-toplevel 2>/dev/null)" || { printf '0'; return; }
  git -C "$path" worktree list --porcelain 2>/dev/null | awk -v main="$main" '
    /^worktree /{ p = substr($0, 10); if (p != main) n++ }
    END { print n+0 }'
}

# _fleet_count_reviews <worktrees-dir> — count of LIVE in-flight reviews: one per .review-inflight-*
# marker whose recorded reviewer pid is still alive. Byte-for-byte the predicate agent-watch.sh's
# _count_live_reviews applies, so the fleet total agrees with each project's own concurrency gauge.
_fleet_count_reviews() {
  local wt="$1" n=0 f pid
  for f in "$wt"/.review-inflight-*; do
    [ -e "$f" ] || continue
    pid="$(head -1 "$f" 2>/dev/null || true)"
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && n=$((n+1))
  done
  printf '%s' "$n"
}

# fleet_governance — the cross-project concurrency rollup. No window / no arguments: it reports the
# CURRENT in-flight state. Per project: builders, reviews, their sum, and whether the watcher is alive
# (a 'down' watcher means its counts may be stale); plus one fleet-wide total.
fleet_governance() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help)
        cat <<EOF
usage: herd fleet governance

  Fleet-wide GLOBAL CONCURRENCY view (deterministic, no LLM, read-only): total in-flight
  BUILDERS + REVIEWS summed across every registered project. The Claude account usage limit
  is ACCOUNT-WIDE, so this one number is how you avoid a fleet-wide limit-hit. Per project:
    BUILDERS   active feature worktrees (git worktree list, main checkout excluded)
    REVIEWS    live .review-inflight markers (reviewer pid still alive)
    IN-FLIGHT  builders + reviews for that project
    WATCHER    is that project's watcher alive? (a 'down' watcher means counts may be stale)
  plus a fleet-wide total. Counts come from each project's own watcher/agent state — the same
  signals agent-watch.sh uses. An unreachable project (path/.herd/config gone) is reported,
  never fatal. Soft in-flight cap: HERD_FLEET_INFLIGHT_SOFTCAP (inline default 6).
EOF
        return 0 ;;
      *) die "usage: herd fleet governance   (no arguments; try: herd fleet governance --help)" ;;
    esac
  done

  local reg; reg="$(_fleet_registry_file)"
  if [ ! -f "$reg" ]; then
    say "no fleet registry yet ($reg) — add a project with: herd fleet register <path>"
    return 0
  fi

  say "${c_bold}herd fleet governance${c_rst} — in-flight agents across the fleet (usage limit is account-wide)"
  say ""
  printf '%s%-16s %8s %8s %9s  %-7s%s\n' "$c_bold" "PROJECT" "BUILDERS" "REVIEWS" "IN-FLIGHT" "WATCHER" "$c_rst"

  local tot_b=0 tot_r=0 nproj=0 nmiss=0 name path repo
  while IFS='|' read -r name path repo; do
    case "$name" in ''|'#'*) continue ;; esac
    [ -n "$path" ] || continue

    if [ ! -d "$path" ] || [ ! -f "$path/.herd/config" ]; then
      nmiss=$((nmiss+1))
      printf '%-16s %8s %8s %9s  %b%s%b\n' "$name" "—" "—" "—" "$c_yel" "unreachable" "$c_rst"
      continue
    fi
    nproj=$((nproj+1))

    local row wt; row="$(_fleet_read_config "$path")" || row=""
    wt="$(printf '%s' "$row" | cut -f3)"; [ -n "$wt" ] || wt="${path}-trees"

    local b r inflight watcher wcol
    b="$(_fleet_count_builders "$path")"
    r="$(_fleet_count_reviews "$wt")"
    inflight=$((b + r))
    tot_b=$((tot_b + b)); tot_r=$((tot_r + r))

    watcher="$(_fleet_watcher_state "$name")"
    wcol="$watcher"
    case "$watcher" in
      alive) wcol="${c_grn}alive${c_rst}" ;;
      down)  wcol="${c_red}down${c_rst}" ;;
    esac
    printf '%-16s %8s %8s %9s  %-16s\n' "$name" "$b" "$r" "$inflight" "$wcol"
  done < "$reg"

  local tot=$((tot_b + tot_r))
  say ""
  local miss=""; [ "$nmiss" -gt 0 ] && miss=" · ${c_yel}$nmiss unreachable${c_rst}"
  say "Fleet: ${c_bold}$tot in-flight${c_rst} ($tot_b builder(s) + $tot_r review(s)) across $nproj project(s)$miss"

  # Soft account-wide guard: the usage limit is ONE quota for the whole fleet. This threshold is an
  # inline default for now — a real FLEET_INFLIGHT_SOFTCAP config key is a deliberate FOLLOW-UP
  # (another builder owns capabilities.tsv this cycle, so no new key is added here).
  local softcap="${HERD_FLEET_INFLIGHT_SOFTCAP:-6}"
  case "$softcap" in ''|*[!0-9]*) softcap=6 ;; esac
  if [ "$tot" -ge "$softcap" ]; then
    warn "fleet in-flight ($tot) ≥ soft cap ($softcap) — the Claude usage limit is account-wide; consider pausing new spawns to avoid a limit-hit"
  fi
}

# ── room — the NL MASTER-COORDINATOR agent (P3 of the fleet-coordinator EPIC) ─────────────────────
# A launcher that opens the natural-language master-coordinator in its OWN meta-workspace, THIN over
# the shipped deterministic `herd fleet` helpers (register/status/digest/inbox/set/upgrade/reload/
# discover) plus each project's own read-only `herd why/log/status`. It renders a skill from the live
# registry and starts ONE herdr tab running `claude --model $MODEL_COORDINATOR /fleet-coordinator` in
# a dedicated fleet workspace — no watcher/backlog panes (that is per-project control-room furniture;
# the master only rolls up and delegates DOWN to each project's coordinator/watcher).

# _fleet_room_dir — the meta-workspace cwd that holds the rendered fleet skill (its
# .claude/commands/fleet-coordinator.md). Default: a `fleet-room` sibling of the registry file (so
# it moves with HERD_FLEET_FILE and stays under ~/.herd by default). HERD_FLEET_ROOM_DIR overrides.
_fleet_room_dir() { printf '%s' "${HERD_FLEET_ROOM_DIR:-$(dirname "$(_fleet_registry_file)")/fleet-room}"; }

# _fleet_room_agent_exists <agent-name> — 'yes' if a herdr agent whose name EXACTLY equals the fleet
# coordinator name is already running, else empty. Reuses the SAME `herdr agent list` JSON contract
# agent-watch.sh parses ({"result":{"agents":[{"name":…}]}}). Never fatal: if herdr/python3 is absent
# or the list can't be parsed it prints nothing, so the caller treats "unknown" as "not up" and takes
# the normal launch path (issue #132: an already-running room must be ADOPTED, not re-started).
_fleet_room_agent_exists() {
  local name="$1"
  herdr agent list 2>/dev/null | NAME="$name" python3 -c '
import sys, json, os
name = os.environ["NAME"]
try:
    agents = (json.load(sys.stdin).get("result") or {}).get("agents") or []
    if any(a.get("name") == name for a in agents):
        sys.stdout.write("yes")
except Exception:
    pass
' 2>/dev/null || true
}

# render_fleet_skill — render templates/fleet-coordinator.md.tmpl into the room's
# .claude/commands/fleet-coordinator.md, substituting the LIVE registry (project bullet list, count,
# registry path) plus the model tier and engine paths. Pure bash string replacement, exactly like
# render_skill — so a project path containing / & | is safe. Prints the rendered file's path.
render_fleet_skill() {
  local tmpl="${HERD_FLEET_SKILL_TMPL:-$TEMPLATES_DIR/fleet-coordinator.md.tmpl}"
  [ -f "$tmpl" ] || die "fleet skill template missing: $tmpl"
  local room; room="$(_fleet_room_dir)"
  local out_dir="$room/.claude/commands"
  mkdir -p "$out_dir" || die "cannot create fleet room commands dir: $out_dir"
  local out="$out_dir/fleet-coordinator.md"

  # Build {{FLEET_PROJECTS}} — one bullet per registered project (name · path · repo).
  local reg; reg="$(_fleet_registry_file)"
  local FLEET_PROJECTS='' count=0 name path repo
  if [ -f "$reg" ]; then
    while IFS='|' read -r name path repo; do
      case "$name" in ''|'#'*) continue ;; esac
      [ -n "$path" ] || continue
      count=$((count+1))
      FLEET_PROJECTS="${FLEET_PROJECTS}"$'\n'"- **${name}** — \`${path}\`${repo:+  (${repo})}"
    done < "$reg"
  fi
  FLEET_PROJECTS="${FLEET_PROJECTS#$'\n'}"   # drop the leading newline for a clean first bullet
  [ -n "$FLEET_PROJECTS" ] || FLEET_PROJECTS="_(registry empty)_"

  local model="${MODEL_COORDINATOR:-claude-opus-4-8}"
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line//\{\{FLEET_PROJECTS\}\}/$FLEET_PROJECTS}"
    line="${line//\{\{FLEET_COUNT\}\}/$count}"
    line="${line//\{\{FLEET_REGISTRY\}\}/$reg}"
    line="${line//\{\{FLEET_ROOM_DIR\}\}/$room}"
    line="${line//\{\{MODEL_COORDINATOR\}\}/$model}"
    line="${line//\{\{SCRIPTS_DIR\}\}/$SCRIPTS_DIR}"
    printf '%s\n' "$line"
  done < "$tmpl" > "$out"
  printf '%s' "$out"
}

# fleet_room — render the fleet skill and open (or refocus) the master-coordinator agent in its own
# herdr workspace. Refuses (non-zero) on an empty registry, pointing at register/discover. Every
# herdr interaction goes through the `herdr` CLI on PATH so it is stubbable in tests.
fleet_room() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help)
        cat <<EOF
usage: herd fleet room

  Open the NL MASTER-COORDINATOR agent in its own meta-workspace: an LLM seat that manages every
  registered project THROUGH the shipped 'herd fleet' rollups + each project's read-only 'herd
  why/log/status', and delegates work DOWN to each project's coordinator (via 'herdr pane run').
  It NEVER edits a project's files and NEVER merges — always delegates.

  Renders templates/fleet-coordinator.md.tmpl from the live registry, then launches ONE herdr tab
  running:  claude --model \$MODEL_COORDINATOR /fleet-coordinator
  Refuses when the registry is empty — add projects with 'herd fleet register' / 'herd fleet discover'.

  Model:     ${MODEL_COORDINATOR:-claude-opus-4-8}
  Room cwd:  $(_fleet_room_dir)
  Registry:  $(_fleet_registry_file)
EOF
        return 0 ;;
      *) die "usage: herd fleet room   (no arguments; try: herd fleet room --help)" ;;
    esac
  done

  # Refuse gracefully on an empty registry — the master has nothing to manage.
  local nproj; nproj="$(_fleet_registered_paths | grep -c . || true)"
  if [ "${nproj:-0}" -eq 0 ]; then
    say "no projects registered — the fleet room needs at least one project."
    say "  add one:     herd fleet register <path>"
    say "  auto-find:   herd fleet discover --register"
    return 1
  fi

  command -v herdr   >/dev/null 2>&1 || die "herdr not found — the fleet room needs the herdr CLI on PATH"
  command -v python3 >/dev/null 2>&1 || die "python3 not found — required to parse herdr JSON output"

  local room; room="$(_fleet_room_dir)"
  local skill; skill="$(render_fleet_skill)" || die "could not render the fleet skill"
  local model="${MODEL_COORDINATOR:-claude-opus-4-8}"
  local label="${HERD_FLEET_WS_LABEL:-fleet}"
  local tab_label="fleet-room"
  local agent_name="fleet-coordinator"
  local cmd="/fleet-coordinator"

  # ADOPT an already-running room instead of failing (issue #132). If a fleet-coordinator agent is
  # already up, `herdr agent start` would refuse — which used to surface as the misleading "could not
  # start the fleet-coordinator agent". Detect it FIRST (before we touch any workspace/tab), leave its
  # live session untouched, and just refresh the skill (already re-rendered above) so a re-run picks up
  # a changed registry. Then point the human at it and exit clean.
  if [ "$(_fleet_room_agent_exists "$agent_name")" = "yes" ]; then
    ok "room already up — herdr agent focus $agent_name"
    say "   skill refreshed: $skill"
    return 0
  fi

  # Resolve the fleet's OWN herdr workspace (labeled $label) — reuse if it already exists, else
  # create a dedicated one. We only ever touch a workspace with our own fleet label, never the
  # ambient/focused one (the same multi-tenancy discipline coordinator.sh uses per project).
  local WS TAB
  WS="$(herdr workspace list 2>/dev/null | LABEL="$label" python3 -c \
    'import sys,json,os; d=json.load(sys.stdin); print(next((w["workspace_id"] for w in (d.get("result") or {}).get("workspaces",[]) if w.get("label")==os.environ["LABEL"]), ""))' \
    2>/dev/null)" || WS=""

  if [ -n "$WS" ]; then
    # REUSE: focus our workspace, close any existing fleet-room tab for a clean relaunch, open fresh.
    herdr workspace focus "$WS" >/dev/null 2>&1 || true
    local existing
    existing="$(herdr tab list --workspace "$WS" 2>/dev/null | LABEL="$tab_label" python3 -c \
      'import sys,json,os; d=json.load(sys.stdin); print(next((t["tab_id"] for t in (d.get("result") or {}).get("tabs",[]) if t.get("label")==os.environ["LABEL"]), ""))' \
      2>/dev/null)" || existing=""
    [ -n "$existing" ] && herdr tab close "$existing" >/dev/null 2>&1 || true
    local created
    created="$(herdr tab create --workspace "$WS" --cwd "$room" --label "$tab_label" --focus 2>/dev/null)" \
      || die "could not create the fleet-room tab"
    TAB="$(printf '%s' "$created" | python3 -c \
      'import sys,json; print(json.load(sys.stdin)["result"]["tab"]["tab_id"])' 2>/dev/null)" \
      || die "could not parse the fleet-room tab id from herdr"
  else
    # CREATE: no fleet workspace yet. Create it labeled up front; its root tab becomes the room tab.
    local created
    created="$(herdr workspace create --cwd "$room" --label "$label" --focus 2>/dev/null)" \
      || die "could not create the fleet workspace"
    local parsed
    parsed="$(printf '%s' "$created" | python3 -c \
      'import sys,json; d=json.load(sys.stdin)["result"]; print(d["workspace"]["workspace_id"], d["tab"]["tab_id"])' 2>/dev/null)" \
      || die "could not parse the fleet workspace create result from herdr"
    read -r WS TAB <<< "$parsed"
    herdr tab rename "$TAB" "$tab_label" >/dev/null 2>&1 || true
  fi

  # The NL master-coordinator agent: ONE tab, running the rendered skill. No watcher/backlog panes.
  # No existing room was found above, so this is a GENUINE start failure — report it with a clearer,
  # actionable message (not the old bare "could not start …"), pointing at the likely herdr cause.
  herdr agent start "$agent_name" --workspace "$WS" --cwd "$room" --tab "$TAB" \
    -- claude --model "$model" "$cmd" >/dev/null 2>&1 \
    || die "could not start the fleet-coordinator agent in workspace $WS — herdr agent start failed (check 'herdr agent list' / that herdr is healthy). No existing room was detected, so this is a real launch failure."

  ok "fleet room up — ${c_bold}$agent_name${c_rst} managing $nproj project(s) via $cmd"
  say "   skill:     $skill"
  say "   focus it:  herdr agent focus $agent_name"
  # Permission posture (issue #132b): the fleet seat is a HUMAN seat by design — it runs INTERACTIVE
  # claude, so its first fleet-CLI call will prompt for approval. That is intentional; we do NOT pass
  # --dangerously-skip-permissions to the room (the master delegates DOWN and must stay human-gated).
  say "   note:      interactive seat — first fleet-CLI call will ask for approval (human seat by design)"
}
