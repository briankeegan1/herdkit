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
#   one record per line, pipe-delimited:  name|path|repo|aliases
#   blank lines and #-comments are ignored. `name` is the project's WORKSPACE_NAME, `path` its
#   PROJECT_ROOT, `repo` its HERD_REPO (may be empty). `aliases` (HERD-387) is OPTIONAL and
#   comma-separated (e.g. `alpha-svc,alpha`); a row with no aliases omits the trailing field
#   entirely, so every pre-existing 3-field row (and every register call that never used --alias)
#   stays byte-identical to before this field existed. `herd fleet resolve` is the ONE consumer that
#   matches free text against name + aliases; every other reader still only cares about name/path/repo.
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

# _fleet_sanitize_alias <value> — like _fleet_sanitize, plus strips the comma (the aliases-field
# join delimiter) and trims surrounding whitespace, so a stray char in a free-typed --alias value
# can never corrupt the CSV aliases field or produce a blank-looking candidate.
_fleet_sanitize_alias() {
  local v; v="$(_fleet_sanitize "$1")"
  v="${v//,/}"
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  printf '%s' "$v"
}

# _fleet_read_config <project-path> — read that project's .herd/config and print one TAB-delimited row:
#   workspace<TAB>project_root<TAB>worktrees_dir<TAB>default_branch<TAB>repo
# Thin adopter of the shared _herd_read_project_config seam (scripts/herd/herd-config.sh), which owns
# the isolated-subshell source + the fallbacks — so the direct `. .herd/config` lives in the config
# module, not here. `herd fleet` does NOT globally load the config module (loading the CURRENT project's
# config would clobber ambient env, e.g. fleet_room's MODEL_COORDINATOR), so lazily source the seam's
# sibling module HERE, only when the reader is not already defined — confined to the read path fleet_room
# never touches. The source runs inside this function's `$(…)` subshell, so it never leaks globals into
# the fleet process. Returns non-zero if there is no config to read.
_fleet_read_config() {
  if ! declare -f _herd_read_project_config >/dev/null 2>&1; then
    local _frc_dir; _frc_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=/dev/null
    . "$_frc_dir/herd-config.sh"
  fi
  _herd_read_project_config "$1"
}

# _fleet_each REGISTRY-CALLBACK — read the registry and call `$1 name path repo [aliases]` per valid
# record, skipping blanks/comments. Returns 1 (and the caller reports empty) when the registry is
# missing or has no records. Central so every subcommand iterates the registry identically. The read
# always captures a 4th (aliases) field even though most callbacks ignore it — otherwise a row that
# HAS aliases would spill its 4th field into `repo` (bash's `read` appends any extra fields, IFS
# chars and all, onto the last named variable).
_fleet_each() {
  local cb="$1" reg; reg="$(_fleet_registry_file)"
  [ -f "$reg" ] || return 1
  local seen=0 line name path repo alias
  while IFS='|' read -r name path repo alias; do
    case "$name" in ''|'#'*) continue ;; esac
    [ -n "$path" ] || continue
    seen=1
    "$cb" "$name" "$path" "$repo" "$alias"
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

# ── new — one-command spin-up (HERD-410) ─────────────────────────────────────
# `herd fleet new <path>` replaces the hand-rolled chain a fleet-room operator used to type by hand
# to stand up a NEW money-bet project: mkdir + git init + gh repo create + herd init + register.
# Orchestrates that chain deterministically, delegating every step to the SAME command a human would
# run (never re-implementing git/gh/herd init logic here) — mirroring fleet.sh's existing "delegate,
# never reimplement" discipline (see the file header). Fail-soft on the optional remote leg
# (--no-remote / no gh / no gh auth all degrade to "no remote", never a crash); everything else is a
# hard failure (die) since a half-seeded project is worse than a refused one.
#
# PRESERVING OPTIONALITY (the actual bug this item fixes): the fleet path used to run `herd init`
# under HERD_NONINTERACTIVE=1, which silently skipped the archetype/posture interviews and dropped a
# non-code money-bet to code-shaped defaults with zero mention. `herd fleet new` fixes this at the
# ORCHESTRATION layer (not inside `herd init` itself — direct `herd init` callers keep their existing
# byte-identical non-interactive contract, see bin/herd's HERD-410 note above cmd_init's interview):
#   • --archetype / --posture given            → passed straight through to `herd init` as flags.
#   • neither flag given, but a real tty IS present → no flags passed; `herd init`'s OWN interactive
#     archetype/posture interviews run, so a human still gets full optionality.
#   • neither flag given AND no tty (scripted / HERD_NONINTERACTIVE)  → THIS function picks the
#     defaults itself (archetype=code, posture=solo-auto — today's implicit shape) and PRINTS them
#     loudly BEFORE delegating, then passes them to `herd init` as explicit flags so the choice is
#     recorded, never silent.
_fleet_new_usage() {
  cat <<EOF
usage: herd fleet new <path> [--archetype <name>] [--posture <name>] [--no-remote]
                       [--repo-name <name>] [--public] [--alias <name>]...

  One-command project spin-up (HERD-410): mkdir + git init + 'herd init' + commit the rendered
  .herd/ project files + 'gh repo create' (unless --no-remote) + 'herd fleet register'.

  <path>              directory to create (or reuse, if empty / not yet a herd project)
  --archetype <name>  project archetype (templates/archetypes.tsv) — passed to 'herd init'
  --posture <name>    operating posture (templates/postures.tsv) — passed to 'herd init'
                       Neither flag + a real tty: 'herd init' runs its own interactive interview.
                       Neither flag + no tty: defaults (archetype=code, posture=solo-auto) are
                       applied AND PRINTED LOUDLY — never silently.
  --no-remote          skip 'gh repo create' — local-only repo, registered with an empty repo field
  --repo-name <name>  override the GitHub repo name (default: the sanitized directory basename)
  --public             create the GitHub repo public (default: private)
  --alias <name>       passed through to 'herd fleet register' (repeatable)

Archetypes: $(type archetype_names >/dev/null 2>&1 && archetype_names | tr '\n' ' ' || printf '(unavailable)')
Postures:   $(type posture_names >/dev/null 2>&1 && posture_names | tr '\n' ' ' || printf '(unavailable)')
EOF
}

fleet_new() {
  local raw="" archetype="" posture="" no_remote="" repo_name="" visibility="--private"
  local aliases=() no_more_opts=""
  while [ "$#" -gt 0 ]; do
    if [ -n "$no_more_opts" ]; then
      [ -z "$raw" ] || die "usage: herd fleet new <path> [...]  (try: herd fleet new --help)"
      raw="$1"; shift; continue
    fi
    case "$1" in
      --)              no_more_opts=1; shift ;;
      --archetype)     [ -n "${2+set}" ] || die "--archetype requires a value"; archetype="$2"; shift 2 ;;
      --archetype=*)   archetype="${1#--archetype=}"; shift ;;
      --posture)       [ -n "${2+set}" ] || die "--posture requires a value"; posture="$2"; shift 2 ;;
      --posture=*)     posture="${1#--posture=}"; shift ;;
      --no-remote)     no_remote=1; shift ;;
      --repo-name)     [ -n "${2+set}" ] || die "--repo-name requires a value"; repo_name="$2"; shift 2 ;;
      --repo-name=*)   repo_name="${1#--repo-name=}"; shift ;;
      --public)        visibility="--public"; shift ;;
      --alias)         [ -n "${2+set}" ] || die "--alias requires a value"; aliases+=("$2"); shift 2 ;;
      --alias=*)       aliases+=("${1#--alias=}"); shift ;;
      -h|--help)       _fleet_new_usage; return 0 ;;
      -*)              die "unknown option: $1 (try: herd fleet new --help; use '--' before a path starting with '-')" ;;
      *)
        [ -z "$raw" ] || die "usage: herd fleet new <path> [...]  (try: herd fleet new --help)"
        raw="$1"; shift ;;
    esac
  done
  [ -n "$raw" ] || { _fleet_new_usage >&2; die "usage: herd fleet new <path> [--archetype <name>] [--posture <name>] [--no-remote]"; }

  # Validate archetype/posture NAMES up front (before touching the filesystem) when given, so a typo
  # refuses cleanly rather than after mkdir/git init have already run.
  if [ -n "$archetype" ]; then
    type archetype_exists >/dev/null 2>&1 && archetype_exists "$archetype" \
      || die "unknown --archetype '$archetype' — see templates/archetypes.tsv for the canonical names"
  fi
  if [ -n "$posture" ]; then
    type posture_exists >/dev/null 2>&1 && posture_exists "$posture" \
      || die "unknown --posture '$posture' — see templates/postures.tsv for the canonical names"
  fi

  mkdir -p -- "$raw" || die "cannot create directory: $raw"
  local path; path="$(cd -- "$raw" 2>/dev/null && pwd -P)" || die "cannot resolve directory: $raw"

  say "${c_bold}herd fleet new${c_rst} — spinning up $path"
  say ""

  # 1. git init (idempotent — a pre-existing .git is left alone).
  if [ -d "$path/.git" ]; then
    say "  ${c_dim}git: $path already a repo${c_rst}"
  else
    git -C "$path" init -q || die "git init failed at $path"
    ok "git init: $path"
  fi

  # 2. PRESERVE OPTIONALITY (HERD-410): neither flag + no tty ⇒ pick + LOUDLY print the defaults
  #    ourselves and pass them through explicitly, so the choice is recorded, never silent. Neither
  #    flag + a real tty ⇒ pass nothing; 'herd init' runs its own interactive interview below.
  if [ -z "$archetype" ] && [ -z "$posture" ] && { [ ! -t 0 ] || [ -n "${HERD_NONINTERACTIVE:-}" ]; }; then
    archetype="code"; posture="solo-auto"
    warn "no --archetype/--posture flags and no tty — applying defaults LOUDLY (never silently): archetype=$archetype posture=$posture. Override with 'herd fleet new $raw --archetype <name> --posture <name>'."
  fi

  # 3. herd init — delegated (never re-implemented here). Flags win when set; otherwise 'herd init'
  #    decides for itself (its own interactive picker, or its own byte-identical non-interactive
  #    default) exactly as a direct 'herd init' call would.
  local herd_bin="${HERD_FLEET_HERD_BIN:-${HERDKIT_HOME:-}/bin/herd}"
  local init_args=(init)
  [ -n "$archetype" ] && init_args+=(--archetype "$archetype")
  [ -n "$posture" ]   && init_args+=(--posture "$posture")
  say ""
  say "${c_bold}herd init${c_rst} ${c_dim}(delegated)${c_rst}"
  ( cd "$path" && "$herd_bin" "${init_args[@]}" ) || die "herd init failed at $path"
  [ -f "$path/.herd/config" ] || die "herd init did not produce $path/.herd/config"

  # 4. NEVER .herd/secrets or .herd/config.local (amendment): 'herd init' only gitignores these on
  #    conditional/interactive paths (a linear key given; the grounding interview's graphify yes) —
  #    guarantee both are covered regardless, so a scripted spin-up can never leak either into git.
  _ensure_gitignored "$path" '.herd/secrets'
  _ensure_gitignored "$path" '.herd/config.local'

  # 5. Commit the rendered .herd/ project files (amendment) — config, healthcheck.project.sh,
  #    steps.tsv/links if created, .gitignore, and a seeded BACKLOG.md — so builder worktrees inherit
  #    the gates from day one. Named `git add`, never `git add -A`: secrets/config.local and the
  #    per-machine rendered skill (.claude/commands/*.md, already gitignored by render_skill) must
  #    never land in this commit even if something else stages them first.
  local commit_paths=() f
  for f in .gitignore .herd/config .herd/healthcheck.project.sh .herd/steps.tsv .herd/links BACKLOG.md; do
    [ -e "$path/$f" ] && commit_paths+=("$f")
  done
  if [ "${#commit_paths[@]}" -gt 0 ]; then
    ( cd "$path" && git add -- "${commit_paths[@]}" ) || die "git add failed at $path"
    if ( cd "$path" && git diff --cached --quiet 2>/dev/null ); then
      say "  ${c_dim}(nothing new to commit)${c_rst}"
    else
      ( cd "$path" && git commit -q -m "chore: seed herd project (herd fleet new)" ) \
        || die "git commit failed at $path"
      ok "committed: ${commit_paths[*]}"
    fi
  fi

  # 6. gh repo create — fail-soft optional leg. --no-remote skips cleanly; a missing/unauthenticated
  #    gh degrades to the SAME "no remote" outcome with a loud warning, never a crash.
  local repo_slug=""
  if [ -n "$no_remote" ]; then
    say "  ${c_dim}--no-remote: skipping gh repo create${c_rst}"
  elif ! command -v gh >/dev/null 2>&1; then
    warn "gh CLI not found — skipping remote repo creation (degrades to --no-remote); create one later with 'gh repo create' + 'git remote add origin <url>'"
  elif ! gh auth status >/dev/null 2>&1; then
    warn "gh not authenticated (gh auth status failed) — skipping remote repo creation (degrades to --no-remote); run 'gh auth login', then create the remote by hand"
  else
    local name owner
    name="${repo_name:-$(_fleet_slug "$(basename "$path")")}"
    owner="$(gh api user --jq .login 2>/dev/null || true)"
    if [ -z "$owner" ]; then
      warn "could not resolve the gh account (gh api user) — skipping remote repo creation"
    elif gh repo create "$owner/$name" "$visibility" >/dev/null 2>&1; then
      repo_slug="$owner/$name"
      local push_url; push_url="$(gh repo view "$repo_slug" --json url --jq .url 2>/dev/null)"
      [ -n "$push_url" ] && push_url="${push_url}.git"
      if [ -n "$push_url" ]; then
        git -C "$path" remote add origin "$push_url" 2>/dev/null \
          || git -C "$path" remote set-url origin "$push_url"
        local branch; branch="$(git -C "$path" symbolic-ref --quiet --short HEAD 2>/dev/null || echo main)"
        if git -C "$path" push -q -u origin "$branch" 2>/dev/null; then
          ok "gh repo create: $repo_slug ($visibility) — pushed $branch"
        else
          warn "created $repo_slug but 'git push' failed — push by hand: git -C $path push -u origin $branch"
        fi
      else
        warn "created $repo_slug but could not resolve its clone URL (gh repo view) — add the remote by hand"
      fi
    else
      warn "gh repo create failed for $owner/$name — continuing without a remote (create it by hand, then 'git remote add origin <url>')"
    fi
  fi

  # 7. Register in the fleet registry (requirement 6) — delegates to fleet_register, never
  #    re-implementing the registry write here.
  local reg_args=("$path") a
  # Bash-3.2-clean: "${aliases[@]}" on a declared-but-EMPTY array is an unbound-variable error under
  # `set -u` on stock macOS bash (see fleet_register's own out_a guard above) — skip the loop entirely
  # when no --alias was given, the common case.
  if [ "${#aliases[@]}" -gt 0 ]; then
    for a in "${aliases[@]}"; do reg_args+=(--alias "$a"); done
  fi
  fleet_register "${reg_args[@]}"

  # 8. Journal the create (requirement 6) — best-effort, isolated subshell (mirrors _fleet_read_config's
  #    lazy-source technique) so it can NEVER clobber this process's own ambient env, and never fatal.
  (
    cd "$path" 2>/dev/null || exit 0
    HERD_CONFIG_FILE="$path/.herd/config"; export HERD_CONFIG_FILE
    _fn_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=/dev/null
    . "$_fn_dir/herd-config.sh"  2>/dev/null || exit 0
    # shellcheck source=/dev/null
    . "$_fn_dir/journal.sh"      2>/dev/null || exit 0
    journal_append fleet_project_created path "$path" archetype "${archetype:-}" posture "${posture:-}" \
      remote "${repo_slug:-none}"
  ) 2>/dev/null || true

  say ""
  ok "herd fleet new complete: $path"
  [ -n "$repo_slug" ] && say "  remote:      $repo_slug ($visibility)"
  say "  registry:    $(_fleet_registry_file)"
  say "  Next:        cd $path && bash ${HERDKIT_HOME:-\$HERDKIT_HOME}/scripts/herd/coordinator.sh   # launch the control room"
}

# ── register / list / discover ───────────────────────────────────────────────

# fleet_register <path> [--alias <name>]... — resolve <path>, read its .herd/config, and append
# (or refresh) its name|path|repo[|aliases] record in the registry. Idempotent: re-registering the
# same path rewrites its row rather than duplicating it. Fails loudly (die) when the path has no
# .herd/config. --alias (repeatable, HERD-387) sets the row's ALIASES — free-text names `herd fleet
# resolve` also matches, e.g. a project whose WORKSPACE_NAME is "svc-alpha" registered with
# --alias alpha --alias alpha-svc so "alpha" resolves it. A register call that passes NO --alias
# preserves whatever aliases the row already had (a plain re-register, e.g. from `discover
# --register` or a re-run script, must never silently wipe curated aliases); passing --alias always
# REPLACES the row's alias set with exactly what was given (drop all with `--alias ''` — an empty
# value sanitizes to nothing and is skipped, so this is really "no aliases").
fleet_register() {
  local raw="" aliases=() no_more_opts=""
  while [ "$#" -gt 0 ]; do
    if [ -n "$no_more_opts" ]; then
      [ -z "$raw" ] || die "usage: herd fleet register <project-path> [--alias <name>]..."
      raw="$1"; shift; continue
    fi
    case "$1" in
      --)
        no_more_opts=1; shift ;;   # end-of-options: a path starting with '-' is still registerable
      --alias)
        [ -n "${2+set}" ] || die "--alias requires a value"
        aliases+=("$2"); shift 2 ;;
      --alias=*)
        aliases+=("${1#--alias=}"); shift ;;
      -h|--help)
        say "usage: herd fleet register <project-path> [--alias <name>]...   (use '--' before a path starting with '-')"
        return 0 ;;
      -*) die "unknown option: $1 (try: herd fleet register --help; use '--' before a path starting with '-')" ;;
      *)
        [ -z "$raw" ] || die "usage: herd fleet register <project-path> [--alias <name>]..."
        raw="$1"; shift ;;
    esac
  done
  [ -n "$raw" ] || die "usage: herd fleet register <project-path> [--alias <name>]..."
  local path
  # `cd --` (not a bare `cd`): bash's cd builtin treats ANY leading-'-' argument as an option itself
  # (not just the exact `-`), so a genuinely dash-leading relative path would fail to resolve here
  # even after the argv parser above got past it via its own `--` terminator.
  path="$(cd -- "$raw" 2>/dev/null && pwd -P)" || die "no such directory: $raw"
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

  # Sanitize + de-dup the requested aliases (order-preserving), then CSV-join. Empty after sanitize
  # (e.g. `--alias ' '`) is dropped rather than stored as a blank candidate.
  local new_alias_csv=""
  if [ "${#aliases[@]}" -gt 0 ]; then
    local a a_clean seen_a="" out_a=()
    for a in "${aliases[@]}"; do
      a_clean="$(_fleet_sanitize_alias "$a")"
      [ -n "$a_clean" ] || continue
      case ",$seen_a," in *",$a_clean,"*) continue ;; esac
      seen_a="$seen_a,$a_clean"
      out_a+=("$a_clean")
    done
    # Guard the join on a non-empty out_a: under bash 3.2 (stock macOS `/usr/bin/bash`, what `env
    # bash` resolves to there) `"${out_a[*]}"` on a DECLARED-BUT-EMPTY array is an unbound-variable
    # error under `set -u` — the documented "--alias '' drops all aliases" path (every supplied
    # alias sanitizes to nothing, e.g. `--alias ''` / `--alias '  '` / `--alias ','`) hit exactly
    # this and aborted the function before the registry was ever rewritten (bash 4.4+ fixed this
    # array quirk, but bin/herd must not assume a modern bash).
    if [ "${#out_a[@]}" -gt 0 ]; then
      local IFS=','; new_alias_csv="${out_a[*]}"; unset IFS
    fi
  fi

  local reg; reg="$(_fleet_registry_file)"
  mkdir -p "$(dirname "$reg")" 2>/dev/null || die "cannot create registry dir: $(dirname "$reg")"
  if [ ! -f "$reg" ]; then
    printf '# herdkit fleet registry — one project per line: name|path|repo|aliases\n' > "$reg" \
      || die "cannot write registry: $reg"
  fi

  # Drop any existing record for this path (idempotent refresh), then append the fresh row. Every
  # OTHER row (including its own aliases field, if any) is reconstructed byte-for-byte via the same
  # split/rejoin the original 3-field code used — `la` is simply empty for a 3-field row, so
  # `$ln|$lp|$lr${la:+|$la}` degrades back to `$ln|$lp|$lr` and the format stays untouched for every
  # project that never used --alias.
  local tmp; tmp="$(mktemp)" || die "mktemp failed"
  local ln lp lr la final_alias="$new_alias_csv"
  while IFS='|' read -r ln lp lr la; do
    case "$ln" in '#'*) printf '%s\n' "$ln|$lp|$lr${la:+|$la}" >> "$tmp"; continue ;; esac
    if [ "$lp" = "$path" ]; then
      [ "${#aliases[@]}" -eq 0 ] && final_alias="$la"   # no --alias this call: keep what was there
      continue                                          # replaced below
    fi
    [ -n "$ln" ] && printf '%s\n' "$ln|$lp|$lr${la:+|$la}" >> "$tmp"
  done < "$reg"
  printf '%s|%s|%s%s\n' "$name" "$path" "$repo" "${final_alias:+|$final_alias}" >> "$tmp"
  mv "$tmp" "$reg" || { rm -f "$tmp"; die "cannot update registry: $reg"; }

  ok "registered ${c_bold}$name${c_rst} → $path${repo:+  ($repo)}${final_alias:+  [aliases: ${final_alias//,/, }]}"
}

# fleet_list — print the registry as a simple table (name, path, repo, aliases). Empty registry is
# a friendly note, not an error.
fleet_list() {
  local reg; reg="$(_fleet_registry_file)"
  if [ ! -f "$reg" ]; then
    say "no fleet registry yet ($reg) — add a project with: herd fleet register <path>"
    return 0
  fi
  local n=0 name path repo alias disp
  printf '%s%-16s %-44s %-14s %s%s\n' "$c_bold" "PROJECT" "PATH" "REPO" "ALIASES" "$c_rst"
  while IFS='|' read -r name path repo alias; do
    case "$name" in ''|'#'*) continue ;; esac
    n=$((n+1))
    disp="${alias:-—}"; [ -n "$alias" ] && disp="${alias//,/, }"
    printf '%-16s %-44s %-14s %s\n' "$name" "$path" "${repo:-—}" "$disp"
  done < "$reg"
  if [ "$n" -eq 0 ]; then
    say "(registry is empty — add a project with: herd fleet register <path>)"
  else
    say ""
    say "$n project(s) · registry: $reg"
  fi
}

# ── resolve — deterministic NL pre-resolver (HERD-387) ───────────────────────
# `herd fleet resolve <free text>` matches free text against the registry (name + --alias values)
# with a FIXED precedence, so the `fleet room` NL master-coordinator (templates/fleet-coordinator.md.tmpl)
# can resolve "the obvious case" without ever calling an LLM, and only falls back to its own judgment
# when this refuses. Case-insensitive throughout (free text from a human/agent, not a slug). Tiers,
# evaluated in order — the FIRST tier with any hit decides the outcome (a later tier is never tried
# once an earlier one matched anything, even ambiguously):
#   1. exact       — the input equals a project's canonical name
#   2. alias       — the input equals one of a project's --alias values
#   3. prefix      — the input is an unambiguous PREFIX of a project's name or an alias
#   4. FAIL        — nothing matched any tier
# Exactly one hit at a tier resolves (prints the canonical NAME on stdout, exit 0). More than one hit
# at a tier is AMBIGUOUS (candidates listed on stderr, exit 2) — it never silently falls through to a
# later, looser tier. No hit at any tier exits 1 listing the registered projects. Read-only.
_fleet_resolve_candidates() {
  local reg; reg="$(_fleet_registry_file)"
  [ -f "$reg" ] || return 0
  local name path repo alias
  while IFS='|' read -r name path repo alias; do
    case "$name" in ''|'#'*) continue ;; esac
    [ -n "$path" ] || continue
    printf '%s\t%s\t%s\n' "$name" "$path" "$alias"
  done < "$reg"
}

_FLEET_RESOLVE_PY='
import sys, os

query = os.environ.get("FLEET_RESOLVE_QUERY", "").strip()
qlow = query.lower()

# Each row keeps its PATH alongside name/aliases: uniqueness is judged per REGISTRY ROW, not per
# printed name — two different rows that happen to share a canonical name (a hand-edited registry,
# or two directories both registered as e.g. "app") are two DIFFERENT projects and must still be
# flagged ambiguous, never silently collapsed into "pick one" just because their names print the same.
rows = []
for raw in sys.stdin:
    line = raw.rstrip("\n")
    if not line:
        continue
    parts = line.split("\t")
    name = parts[0] if len(parts) > 0 else ""
    path = parts[1] if len(parts) > 1 else ""
    aliases_raw = parts[2] if len(parts) > 2 else ""
    aliases = [a for a in aliases_raw.split(",") if a]
    if name:
        rows.append((name, path, aliases))

if not rows:
    sys.stderr.write("no fleet registry yet — add a project with: herd fleet register <path>\n")
    sys.exit(1)

# An empty/whitespace-only query is NO INFORMATION, not a valid target: every name/alias trivially
# "starts with" "" (str.startswith("") is always True), so the prefix tier would otherwise resolve
# it with total confidence whenever exactly one project happens to be registered — a false-confident
# answer for a caller that trusts exit 0 as a proven resolution. Refuse explicitly instead.
if not qlow:
    sys.stderr.write("usage: herd fleet resolve <free text>   (empty query cannot resolve anything)\n")
    sys.exit(1)

def label(name, path):
    return "%s (%s)" % (name, path) if path else name

def emit_ambiguous(tier, hits):
    uniq = sorted(set(hits), key=lambda h: (h[0], h[1]))
    sys.stderr.write("ambiguous fleet target %r (%s match on: %s)\n" %
                      (query, tier, ", ".join(label(n, p) for n, p in uniq)))
    sys.stderr.write("candidates:\n")
    for n, p in uniq:
        sys.stderr.write("  - %s\n" % label(n, p))
    sys.exit(2)

tiers = []

exact = [(name, path) for name, path, aliases in rows if name.lower() == qlow]
tiers.append(("exact", exact))

alias_hits = [(name, path) for name, path, aliases in rows if qlow in (a.lower() for a in aliases)]
tiers.append(("alias", alias_hits))

prefix_hits = []
for name, path, aliases in rows:
    if name.lower().startswith(qlow) or any(a.lower().startswith(qlow) for a in aliases):
        prefix_hits.append((name, path))
tiers.append(("prefix", prefix_hits))

for tier, hits in tiers:
    uniq = sorted(set(hits))
    if len(uniq) == 1:
        print(uniq[0][0])
        sys.exit(0)
    if len(uniq) > 1:
        emit_ambiguous(tier, uniq)

sys.stderr.write("no fleet project matches %r\n" % query)
sys.stderr.write("registered projects: %s\n" % ", ".join(sorted({n for n, _, _ in rows})))
sys.exit(1)
'

# fleet_resolve <free text> — resolve free text to exactly one registered project's canonical name
# (see the tier doc above). Prints the resolved name on stdout and exits 0 on a clean match; prints
# an explanation + candidates on stderr and exits non-zero (2 = ambiguous, 1 = no match / no
# registry / usage) otherwise. `<free text>` may be multiple words (joined with spaces) so a caller
# does not have to fight shell quoting for a natural phrase like `herd fleet resolve the alpha one`.
fleet_resolve() {
  case "${1:-}" in
    --)
      shift ;;   # explicit end-of-options: everything after is literal query text (even -h/a leading '-')
    -h|--help)
      cat <<EOF
usage: herd fleet resolve <free text>

  Deterministic (no-LLM) pre-resolver: matches <free text> against the fleet registry's project
  names and --alias values, case-insensitive, with fixed precedence:
    1. exact name match
    2. alias match
    3. unambiguous prefix match (name or alias)
  The first tier with any hit decides the outcome. Exactly one hit resolves (prints the canonical
  name, exit 0). More than one hit at that tier is ambiguous (candidates listed, exit 2). No hit at
  any tier exits 1. Intended as the deterministic FIRST call for the 'fleet room' NL
  master-coordinator before it falls back to its own judgment.
  Use 'herd fleet resolve -- <text>' to resolve a query that itself starts with '-' (e.g. a project
  literally named '-h').
EOF
      return 0 ;;
  esac
  [ "$#" -ge 1 ] || die "usage: herd fleet resolve <free text>"
  local query="$*"
  FLEET_RESOLVE_QUERY="$query" python3 -c "$_FLEET_RESOLVE_PY" < <(_fleet_resolve_candidates)
}

# _fleet_registered_paths — print the canonical PROJECT_ROOT of every registered project, one per
# line (skipping blanks/comments). Discover uses this to DEDUP projects already in the registry, and
# to derive its default scan roots. The registry stores the SAME resolved PROJECT_ROOT that
# _fleet_read_config yields, so a discovered project's path matches its registry line byte-for-byte.
_fleet_registered_paths() {
  local reg; reg="$(_fleet_registry_file)"
  [ -f "$reg" ] || return 0
  local n p r a
  while IFS='|' read -r n p r a; do
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
      if printf '%s\n' "$registered_paths" | grep -qxF "$proj"; then  # pipe-ok: bounded membership list, under a pipe buffer
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

# ── relationship graph (HERD-386) ────────────────────────────────────────────
# `herd fleet graph` rolls up the registry (nodes) plus each project's OWN `.herd/links` (edges
# labeled "link") and `.herd/deps` (edges labeled "blocked-on"/"watch", reusing the exact row format
# `herd depend`/dep-watcher.sh already own — see bin/herd's _deps_kind_of / DEPS_FILE minimal-read
# comment) into ONE deterministic text or --json rollup. A link/dep target is resolved against the
# SAME registry: matched by repo identity first (byte-for-byte against a registry row's repo field —
# the same identity fleet_register/_fleet_repo_slug derive), falling back to a name match when the
# repo is empty/unknown. Never mutates anything; a missing registry/links/deps file is simply an
# empty graph (fail-soft), never an error.

# _fleet_graph_link_repo <links-file> <link-name> — the repo field for <link-name> in a project's OWN
# .herd/links (name|repo|backend|target, same parse as cmd_link_list); empty if absent/not found.
_fleet_graph_link_repo() {
  local f="$1" name="$2" line lname lrest lrepo
  [ -f "$f" ] || return 0
  while IFS= read -r line; do
    case "$line" in '#'*|'') continue ;; esac
    lname="${line%%|*}"; lrest="${line#*|}"; lrepo="${lrest%%|*}"
    [ "$lname" = "$name" ] && { printf '%s' "$lrepo"; return 0; }
  done < "$f"
}

# _fleet_graph_resolve <registry-file> <peer-name> <peer-repo> — resolve a link/dep peer against the
# fleet registry. Prints "STATUS<TAB>resolved-name":
#   registered    — matched a registry row whose project path + .herd/config are present
#   unreachable   — matched a registry row whose project path/.herd/config is gone
#   unregistered  — no matching registry row at all (resolved-name is empty)
# Repo match wins (the durable cross-project identity); name match is the fallback for a peer whose
# .herd/links has no repo recorded yet.
_fleet_graph_resolve() {
  local reg="$1" pname="$2" prepo="$3" name path repo alias mname="" mpath=""
  if [ -n "$prepo" ] && [ -f "$reg" ]; then
    while IFS='|' read -r name path repo alias; do
      case "$name" in ''|'#'*) continue ;; esac
      if [ "$repo" = "$prepo" ]; then mname="$name"; mpath="$path"; break; fi
    done < "$reg"
  fi
  if [ -z "$mname" ] && [ -f "$reg" ]; then
    while IFS='|' read -r name path repo alias; do
      case "$name" in ''|'#'*) continue ;; esac
      if [ "$name" = "$pname" ]; then mname="$name"; mpath="$path"; break; fi
    done < "$reg"
  fi
  if [ -z "$mname" ]; then
    printf 'unregistered\t'
  elif [ -d "$mpath" ] && [ -f "$mpath/.herd/config" ]; then
    printf 'registered\t%s' "$mname"
  else
    printf 'unreachable\t%s' "$mname"
  fi
}

# _fleet_graph_manifest — walk the registry and emit a TSV manifest on stdout for the renderer:
#   P<TAB>name<TAB>path<TAB>repo<TAB>ok|missing
#   E<TAB>name<TAB>kind<TAB>ref<TAB>repo<TAB>status<TAB>resolved-name   (0+ per project)
# kind is "link" (from .herd/links; ref = the link name) or "blocked-on"/"watch" (from .herd/deps;
# ref = "<link>#<id>", the SAME ref format herd depend/deps already use). A project whose path or
# .herd/config is gone contributes only its P row (missing), never an error.
_fleet_graph_manifest() {
  local reg; reg="$(_fleet_registry_file)"
  [ -f "$reg" ] || return 0
  local name path repo alias
  while IFS='|' read -r name path repo alias; do
    case "$name" in ''|'#'*) continue ;; esac
    [ -n "$path" ] || continue
    if [ ! -d "$path" ] || [ ! -f "$path/.herd/config" ]; then
      printf 'P\t%s\t%s\t%s\tmissing\n' "$name" "$path" "$repo"
      continue
    fi
    printf 'P\t%s\t%s\t%s\tok\n' "$name" "$path" "$repo"

    local links_file="$path/.herd/links" line lname lrest lrepo target status rname
    if [ -f "$links_file" ]; then
      while IFS= read -r line; do
        case "$line" in '#'*|'') continue ;; esac
        lname="${line%%|*}"; lrest="${line#*|}"; lrepo="${lrest%%|*}"
        [ -n "$lname" ] || continue
        target="$(_fleet_graph_resolve "$reg" "$lname" "$lrepo")"
        status="${target%%$'\t'*}"; rname="${target#*$'\t'}"
        printf 'E\t%s\tlink\t%s\t%s\t%s\t%s\n' "$name" "$lname" "$lrepo" "$status" "$rname"
      done < "$links_file"
    fi

    local deps_file="$path/.herd/deps" kind rest ref lname2 lrepo2
    if [ -f "$deps_file" ]; then
      while IFS= read -r line; do
        case "$line" in
          'blocked-on: '*) kind="blocked-on"; rest="${line#blocked-on: }" ;;
          'watch: '*)      kind="watch";      rest="${line#watch: }" ;;
          *) continue ;;
        esac
        ref="${rest%%[[:space:]]*}"
        [ -n "$ref" ] || continue
        lname2="${ref%%#*}"
        lrepo2="$(_fleet_graph_link_repo "$links_file" "$lname2")"
        target="$(_fleet_graph_resolve "$reg" "$lname2" "$lrepo2")"
        status="${target%%$'\t'*}"; rname="${target#*$'\t'}"
        printf 'E\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$kind" "$ref" "$lrepo2" "$status" "$rname"
      done < "$deps_file"
    fi
  done < "$reg"
}

# The renderer (python): reads the P/E manifest on stdin and prints either the human tree/edge-list
# (default) or the --json shape (AS_JSON=1) — one analysis pass, two presentations, mirroring
# cmd_conformance_report's text/--json split.
_FLEET_GRAPH_PY='
import sys, os, json

projects = []
by_name = {}
for raw in sys.stdin:
    line = raw.rstrip("\n")
    if not line:
        continue
    parts = line.split("\t")
    tag = parts[0]
    if tag == "P":
        name = parts[1] if len(parts) > 1 else "?"
        path = parts[2] if len(parts) > 2 else ""
        repo = parts[3] if len(parts) > 3 else ""
        status = parts[4] if len(parts) > 4 else "ok"
        p = {"name": name, "path": path, "repo": repo, "reachable": status == "ok", "edges": []}
        projects.append(p)
        by_name[name] = p
    elif tag == "E":
        name = parts[1] if len(parts) > 1 else ""
        p = by_name.get(name)
        if p is None:
            continue
        kind = parts[2] if len(parts) > 2 else ""
        ref = parts[3] if len(parts) > 3 else ""
        repo = parts[4] if len(parts) > 4 else ""
        status = parts[5] if len(parts) > 5 else "unregistered"
        to_project = parts[6] if len(parts) > 6 else ""
        p["edges"].append({
            "kind": kind, "ref": ref, "repo": repo, "status": status,
            "to_project": to_project or None,
        })

registry = os.environ.get("REGFILE", "")

if os.environ.get("AS_JSON") == "1":
    out = {
        "registry": registry,
        "nodes": [
            {"name": p["name"], "path": p["path"], "repo": p["repo"], "reachable": p["reachable"]}
            for p in projects
        ],
        "edges": [dict(e, **{"from": p["name"]}) for p in projects for e in p["edges"]],
    }
    json.dump(out, sys.stdout, indent=2)
    print()
else:
    if not projects:
        print("no fleet registry yet (%s) — add a project with: herd fleet register <path>" % registry)
        sys.exit(0)
    for p in projects:
        header = p["name"] + (("  (%s)" % p["repo"]) if p["repo"] else "")
        print(header)
        if not p["reachable"]:
            print("  (unreachable — path or .herd/config missing)")
            print("")
            continue
        if not p["edges"]:
            print("  (no links or deps)")
            print("")
            continue
        for e in p["edges"]:
            extra = ("  (%s)" % e["repo"]) if e["repo"] else ""
            resolved = ("  = %s" % e["to_project"]) if e["to_project"] else ""
            print("  %-11s -> %-24s%s  [%s]%s" % (e["kind"], e["ref"], extra, e["status"], resolved))
        print("")
'

# fleet_graph [--json] — the deterministic relationship-graph rollup (HERD-386): registry projects as
# nodes, each project's OWN .herd/links + .herd/deps as labeled edges. Plain text by default
# (tree/edge-list, glow-friendly); --json for machine use. Fail-soft: an empty/missing registry prints
# the same friendly note as fleet_status/fleet_list rather than an error.
fleet_graph() {
  local as_json=0
  case "${1:-}" in
    --json) as_json=1; shift ;;
    -h|--help) say "usage: herd fleet graph [--json]"; return 0 ;;
  esac
  [ "$#" -eq 0 ] || die "usage: herd fleet graph [--json]"
  local reg; reg="$(_fleet_registry_file)"
  REGFILE="$reg" AS_JSON="$as_json" python3 -c "$_FLEET_GRAPH_PY" < <(_fleet_graph_manifest)
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

  local ok_n=0 fail_n=0 skip_n=0 name path repo alias
  while IFS='|' read -r name path repo alias; do
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
# fleet_set <KEY> <VALUE>  |  fleet_set --profile <file> — propagate policy across the whole fleet by
# delegating to each registered project's OWN validated herd command in that project's directory
# (deterministic, no LLM). This is the ONLY writing subcommand in the fleet layer, and even it writes
# NOTHING itself:
#   • <KEY> <VALUE>      → `herd config set <KEY> <VALUE>` per project (rejects unknown keys against
#                          capabilities.tsv, refuses DENY_PATHS / secret keys, restarts / re-renders).
#   • --profile <file>   → a GOVERNANCE PROFILE (HERD-126): `herd governance apply --yes <file>` per
#                          project, so a whole governance stance (merge / gate / PR / attribution /
#                          commit policy) rolls out in one command. apply owns the malformed-profile
#                          refusal and the structural secret/machine exclusion, so an invalid profile
#                          fails PER PROJECT and is reported — never silently or partially applied.
# The profile path is resolved to ABSOLUTE first, since the fan-out cd's into each project directory
# before delegating. Either form prints the same per-project outcome table as upgrade/reload.
fleet_set() {
  case "${1:-}" in
    --profile|--governance)
      local file="${2:-}"
      [ -n "$file" ] || die "usage: herd fleet set --profile <file>   (applies a governance profile across the fleet)"
      [ -f "$file" ] || die "no such governance profile: $file"
      local abs; abs="$(cd "$(dirname "$file")" 2>/dev/null && pwd)/$(basename "$file")"
      [ -f "$abs" ] || die "could not resolve governance profile path: $file"
      _fleet_fanout "governance" governance apply --yes "$abs"
      return $?
      ;;
  esac
  local key="${1:-}"
  { [ -n "$key" ] && [ "$#" -ge 2 ]; } \
    || die "usage: herd fleet set <KEY> <VALUE>  |  herd fleet set --profile <file>"
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
        elif ev == "retire_converged" and pr:
            # The retirement invariant (HERD-164) journals retire_converged once a branch has
            # provably reached main and its worktree/tab/ref are torn down: the terminal proof a PR
            # SHIPPED. It is the ONLY terminal signal for a PR merged OUT OF BAND (another seat, on
            # GitHub), where this journal has no local merge event, only BLOCK verdicts on the
            # superseded shas. Rank it as merged so shipped wins over a stale blocked/held (HERD-290).
            pr_state(pr)["merged"] = True
        elif ev == "merged_external" and pr:
            # merged_external (HERD-291): explicit marker emitted by the post-merge reconcile sweep
            # when it detects a PR merged by another seat or the gh UI. Rank it as shipped so
            # externally-merged PRs surface in the shipped bucket rather than staying blocked/held.
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
        if ev == "merge" or (ev == "reap" and str(o.get("reason", "")) == "merged") \
                or ev == "retire_converged" or ev == "merged_external":
            # retire_converged (HERD-164) is the terminal proof the branch reached main. For a PR
            # merged OUT OF BAND (another seat / GitHub) it is the ONLY local terminal signal, since
            # this journal never saw a merge. Treat it as done so stale BLOCK rows on the superseded
            # shas clear even when gh is down (fail-open) (HERD-290).
            # merged_external (HERD-291): explicit marker for cross-seat merges; same terminal proof.
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

  local tot_b=0 tot_r=0 nproj=0 nmiss=0 name path repo alias
  while IFS='|' read -r name path repo alias; do
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

  # Build {{FLEET_PROJECTS}} — one bullet per registered project (name · path · repo · aliases). The
  # canonical name AND its aliases are baked in so the room's NL dispatch (and its `herd fleet
  # resolve` pre-resolver, HERD-387) can be resolved straight from this list without re-reading the
  # registry file itself.
  local reg; reg="$(_fleet_registry_file)"
  local FLEET_PROJECTS='' count=0 name path repo alias
  if [ -f "$reg" ]; then
    while IFS='|' read -r name path repo alias; do
      case "$name" in ''|'#'*) continue ;; esac
      [ -n "$path" ] || continue
      count=$((count+1))
      FLEET_PROJECTS="${FLEET_PROJECTS}"$'\n'"- **${name}** — \`${path}\`${repo:+  (${repo})}${alias:+  · aliases: ${alias//,/, }}"
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
  # Routed through the driver seam (herd_driver_launch_agent) so HERD_DRIVER=headless spawns a detached
  # fleet-coordinator; the default herdr-claude driver emits the identical argv. HUMAN seat by design:
  # no flags (interactive, human-gated) and focus=yes (omit --no-focus) — byte-identical to the old call.
  herd_driver_launch_agent \
    name="$agent_name" workspace="$WS" cwd="$room" tab="$TAB" focus=yes \
    model="$model" pointer="$cmd" >/dev/null 2>&1 \
    || die "could not start the fleet-coordinator agent in workspace $WS — herdr agent start failed (check 'herdr agent list' / that herdr is healthy). No existing room was detected, so this is a real launch failure."

  ok "fleet room up — ${c_bold}$agent_name${c_rst} managing $nproj project(s) via $cmd"
  say "   skill:     $skill"
  say "   focus it:  herdr agent focus $agent_name"
  # Permission posture (issue #132b): the fleet seat is a HUMAN seat by design — it runs INTERACTIVE
  # claude, so its first fleet-CLI call will prompt for approval. That is intentional; we do NOT pass
  # --dangerously-skip-permissions to the room (the master delegates DOWN and must stay human-gated).
  say "   note:      interactive seat — first fleet-CLI call will ask for approval (human seat by design)"
}
