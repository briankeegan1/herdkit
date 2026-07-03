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
  repo="$(_fleet_sanitize "$(printf '%s' "$row" | cut -f5)")"
  [ -n "$pr" ] && path="$pr"
  path="$(_fleet_sanitize "$path")"

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

# fleet_discover [--register] <root>... — scan the given roots for .herd/config files and print the
# herd projects found (workspace / path / repo). With --register, also add each to the registry.
# This is the auto-discovery helper; `herdr workspace list` separately enumerates the LIVE ones.
fleet_discover() {
  local do_register=""
  case "${1:-}" in --register|-r) do_register=1; shift ;; esac
  [ "$#" -gt 0 ] || die "usage: herd fleet discover [--register] <root>..."

  local root found=0
  printf '%s%-16s %-44s %s%s\n' "$c_bold" "PROJECT" "PATH" "REPO" "$c_rst"
  for root in "$@"; do
    [ -d "$root" ] || { warn "not a directory, skipping: $root"; continue; }
    # Bounded scan for .herd/config; the project root is the dir that OWNS the .herd dir.
    while IFS= read -r cfg; do
      [ -n "$cfg" ] || continue
      local proj; proj="$(cd "$(dirname "$cfg")/.." 2>/dev/null && pwd -P)" || continue
      local row; row="$(_fleet_read_config "$proj")" || continue
      local name repo
      name="$(printf '%s' "$row" | cut -f1)"
      proj="$(printf '%s' "$row" | cut -f2)"
      repo="$(printf '%s' "$row" | cut -f5)"
      found=$((found+1))
      printf '%-16s %-44s %s\n' "$name" "$proj" "${repo:-—}"
      [ -n "$do_register" ] && fleet_register "$proj" >/dev/null 2>&1
    done < <(find "$root" -maxdepth "${HERD_FLEET_DISCOVER_DEPTH:-5}" -type f -path '*/.herd/config' 2>/dev/null | sort -u)
  done
  say ""
  if [ "$found" -eq 0 ]; then
    say "no herd projects found under: $*"
  else
    say "$found project(s) found${do_register:+ (registered)}"
  fi
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

# _fleet_fanout <herd-subcommand> <verb> — run `herd <subcommand>` inside every registered project
# and print a per-project outcome table. The delegated command owns all guards (the upgrade guard
# already refuses on a dirty tree / mid-flight builders), so bulk fan-out inherits that safety.
# HERD_FLEET_HERD_BIN overrides which herd binary is invoked (test seam); defaults to this engine's.
_fleet_fanout() {
  local sub="$1" verb="$2"
  local herd_bin="${HERD_FLEET_HERD_BIN:-${HERDKIT_HOME:-}/bin/herd}"
  local reg; reg="$(_fleet_registry_file)"
  if [ ! -f "$reg" ]; then
    say "no fleet registry yet ($reg) — add a project with: herd fleet register <path>"
    return 0
  fi

  say "${c_bold}herd fleet $verb${c_rst} — running 'herd $sub' across the fleet"
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
    if out="$( cd "$path" 2>/dev/null && HERD_NONINTERACTIVE=1 "$herd_bin" "$sub" 2>&1 )"; then
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

fleet_upgrade() { _fleet_fanout update upgrade; }
fleet_reload()  { _fleet_fanout reload  reload;  }
