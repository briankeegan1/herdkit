#!/usr/bin/env bash
# push-gate.sh — the shared helper for the PUSH_GATE=human hold convention (HERD-123).
#
# PUSH_GATE=human closes the ONE missing gate seam: it holds a FINISHED builder for human review
# BEFORE anything reaches GitHub — gate-then-upload. (PR_FLOW=draft gates AFTER the push, once a PR
# is already public; MERGE_POLICY=approve gates AFTER the review, once the PR exists. This one gates
# BEFORE the push, while the diff is still only local.)
#
# The flow, with PUSH_GATE=human in .herd/config:
#   1. The builder lane completes its work + healthcheck exactly as today, then — INSTEAD of running
#      `git push` / `gh pr create` — runs:
#          push-gate.sh hold <slug> --title <t> --body-file <f>
#      from inside its worktree. That records a sha-keyed 'awaiting' push-hold (mirroring the
#      herd-approve awaiting-approval ledger) and STOPS. Nothing is pushed; the diff stays local.
#   2. The watcher renders 'ready · awaiting push approval' with the worktree path so a human can
#      review the LOCAL diff (git -C <dir> diff <base>...HEAD).
#   3. A human runs `herd-approve.sh approve <slug>` — which records the approval for the awaiting sha
#      and RESUMES: push + PR creation + the normal post-PR gates proceed.
#   4. A NEW commit after the hold invalidates a prior approval — the sha changes, so resume refuses
#      the stale approval and a fresh `hold` must be recorded (same sha-keyed semantics as merge
#      approval).
#
# Default '' (off) → this file is never reached; the lanes are byte-identical to before. Ships
# dormant/default-off. FAIL-SOFT toward safety: a corrupt/stale hold record surfaces LOUDLY and
# refuses — it NEVER silently pushes.
#
# Dual-purpose, like the engine's other shared helpers: SOURCE it for the push_gate_* functions
# (herd-approve.sh surfaces + resumes holds; agent-watch.sh renders them), OR run it as a CLI
# (`push-gate.sh hold …` from the builder; `push-gate.sh resume …` from herd-approve). Sourced AFTER
# herd-config.sh (which provides WORKTREES_DIR / HERD_REMOTE / HERD_BRANCH_NAME):
#   . "$HERE/herd-config.sh"
#   . "$HERE/push-gate.sh"
#
# ── Ledger + record layout ───────────────────────────────────────────────────
# Ledger  $WORKTREES_DIR/.agent-watch-push-holds — append-only, one space-separated record per line,
# sha-last so it parses exactly like .agent-watch-approvals:
#     <epoch> awaiting <slug> <sha>     — the builder is holding this sha for push approval
#     <epoch> approved <slug> <sha>     — a human approved this exact sha (herd-approve.sh approve)
#     <epoch> pushed   <slug> <sha>     — resume completed for this sha (the hold is cleared)
# Detail  $WORKTREES_DIR/.agent-watch-push-hold-<slug> — the PR metadata resume needs, KEY=value
# (rewritten on each hold); body lives in the sibling .body file (multiline).

# push_gate_mode — normalize ${PUSH_GATE:-} to the single supported ON value. Echoes 'human' when the
# gate is on, nothing otherwise. The ONE chokepoint every caller routes through so an unknown value
# fails SAFE (off), never a surprise hold.
push_gate_mode() {
  case "${PUSH_GATE:-}" in
    human) printf 'human' ;;
    *)     printf '' ;;
  esac
}

# push_gate_ledger — path to the append-only push-hold ledger. Requires WORKTREES_DIR (set by
# herd-config.sh); empty output ⇒ no destination ⇒ callers no-op.
push_gate_ledger() {
  [ -n "${WORKTREES_DIR:-}" ] || return 1
  printf '%s' "$WORKTREES_DIR/.agent-watch-push-holds"
}
push_gate_detail_file() { [ -n "${WORKTREES_DIR:-}" ] || return 1; printf '%s' "$WORKTREES_DIR/.agent-watch-push-hold-$1"; }
push_gate_body_file()   { [ -n "${WORKTREES_DIR:-}" ] || return 1; printf '%s' "$WORKTREES_DIR/.agent-watch-push-hold-$1.body"; }

# _pg_epoch — current unix time; the sim/tests never need it deterministic (records are keyed by sha,
# not time), so a plain date is fine. Falls back to 0 if date is unavailable.
_pg_epoch() { date +%s 2>/dev/null || echo 0; }

# _pg_worktree_sha <dir> — the local HEAD sha of a worktree. Empty on any failure (not a git tree).
_pg_worktree_sha() { git -C "$1" rev-parse HEAD 2>/dev/null || true; }

# _pg_current <slug> — echo the sha of the LATEST 'awaiting' record for <slug> that has NOT already
# been 'pushed'. Empty when there is no live hold. This is the single source of truth for "which sha
# is this slug currently holding". Last-write-wins (a re-hold after a new commit supersedes the old).
_pg_current() {
  local slug="$1" ledger; ledger="$(push_gate_ledger)" || return 0
  [ -f "$ledger" ] || return 0
  local awaiting="" pushed=""
  local state s sha
  while read -r _ state s sha; do
    [ "$s" = "$slug" ] || continue
    case "$state" in
      awaiting) awaiting="$sha" ;;
      pushed)   pushed="$sha" ;;
    esac
  done < "$ledger"
  [ -n "$awaiting" ] || return 0
  # A 'pushed' record for the same sha clears the hold (resume already completed for it).
  [ "$pushed" = "$awaiting" ] && return 0
  printf '%s' "$awaiting"
}

# push_gate_awaiting_sha <slug> — the sha this slug is currently holding for push approval, or empty
# when there is no live hold. The PUBLIC single-slug probe (agent-watch.sh renders the console row
# from it). Presence-driven: an empty value means no row, so the console is byte-identical when the
# feature is off (no builder ever wrote a hold).
push_gate_awaiting_sha() { _pg_current "$1"; }

# push_gate_is_approved <slug> <sha> — 0 iff an approval record exists for this exact sha.
push_gate_is_approved() {
  local ledger; ledger="$(push_gate_ledger)" || return 1
  grep -q "^[0-9]* approved $1 $2$" "$ledger" 2>/dev/null
}

# push_gate_list — print every LIVE push-hold, one per line as: <slug> <sha> <dir>. Used by both
# `herd-approve.sh list` and the watcher's console row. Skips holds whose latest state is 'pushed'.
push_gate_list() {
  local ledger; ledger="$(push_gate_ledger)" || return 0
  [ -f "$ledger" ] || return 0
  # Unique slugs in the ledger, then keep only those with a live (unpushed) awaiting sha.
  local slugs slug sha detail dir
  slugs="$(awk '{print $3}' "$ledger" 2>/dev/null | awk '!seen[$0]++')"
  while IFS= read -r slug; do
    [ -n "$slug" ] || continue
    sha="$(_pg_current "$slug")" || true
    [ -n "$sha" ] || continue
    dir=""
    detail="$(push_gate_detail_file "$slug")" || true
    if [ -f "$detail" ]; then
      dir="$(sed -n 's/^dir=//p' "$detail" 2>/dev/null | head -1)"  # pipe-ok: head in a command or process substitution; pipeline status not gated
    fi
    printf '%s %s %s\n' "$slug" "$sha" "$dir"
  done <<EOF
$slugs
EOF
}

# push_gate_hold <slug> [--dir <worktree>] [--branch <name>] [--base <ref>] [--title <t>] [--body-file <f>]
# The builder calls this INSTEAD of push. It records the awaiting push-hold and the metadata resume
# will need. Idempotent: re-holding the same sha does not append a duplicate 'awaiting' record.
# Fail-loud: refuses (non-zero, message) if the worktree HEAD can't be resolved — never a silent hold.
push_gate_hold() {
  local slug="$1"; shift || true
  [ -n "$slug" ] || { echo "push-gate: hold requires <slug>" >&2; return 2; }
  local dir="" branch="" base="" title="" body_file=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --dir)       dir="${2:-}"; shift 2 ;;
      --branch)    branch="${2:-}"; shift 2 ;;
      --base)      base="${2:-}"; shift 2 ;;
      --title)     title="${2:-}"; shift 2 ;;
      --body-file) body_file="${2:-}"; shift 2 ;;
      *) echo "push-gate: hold: unknown arg: $1" >&2; return 2 ;;
    esac
  done
  # Defaults: dir = the worktree we're standing in (the builder runs this from its worktree); branch =
  # that worktree's current branch; base = the configured default branch; title = last commit subject.
  [ -n "$dir" ] || dir="$PWD"
  local sha; sha="$(_pg_worktree_sha "$dir")"
  if [ -z "$sha" ]; then
    echo "🛑 push-gate: cannot resolve HEAD of '$dir' — not a git worktree? Refusing to record a hold." >&2
    return 1
  fi
  [ -n "$branch" ] || branch="$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  [ -n "$base" ]   || base="${HERD_BRANCH_NAME:-main}"
  [ -n "$title" ]  || title="$(git -C "$dir" log -1 --format=%s 2>/dev/null || true)"
  [ -n "$title" ]  || title="$slug"

  local ledger detail body
  ledger="$(push_gate_ledger)" || { echo "🛑 push-gate: WORKTREES_DIR unset — cannot record a hold." >&2; return 1; }
  detail="$(push_gate_detail_file "$slug")"
  body="$(push_gate_body_file "$slug")"

  # Detail file (rewritten each hold, atomically via temp+mv so resume never reads a half-written one).
  local tmp="$detail.tmp.$$"
  {
    printf 'sha=%s\n' "$sha"
    printf 'dir=%s\n' "$dir"
    printf 'branch=%s\n' "$branch"
    printf 'base=%s\n' "$base"
    printf 'title=%s\n' "$title"
  } > "$tmp" 2>/dev/null || { echo "🛑 push-gate: cannot write hold detail for '$slug'." >&2; return 1; }
  mv -f "$tmp" "$detail" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; echo "🛑 push-gate: cannot install hold detail for '$slug'." >&2; return 1; }

  # Body file: caller-provided body if given, else a minimal generated body from the commit log.
  if [ -n "$body_file" ] && [ -f "$body_file" ]; then
    cp -f "$body_file" "$body" 2>/dev/null || true
  else
    git -C "$dir" log "$base..HEAD" --format='%s%n%n%b' > "$body" 2>/dev/null || printf '%s\n' "$title" > "$body" 2>/dev/null || true
  fi

  # Append the awaiting record, unless this exact sha is already the live hold (idempotent re-run).
  if [ "$(_pg_current "$slug")" = "$sha" ]; then
    printf 'ℹ️  push-gate: %s is already holding %.8s for push approval (no change).\n' "$slug" "$sha"
  else
    printf '%s awaiting %s %s\n' "$(_pg_epoch)" "$slug" "$sha" >> "$ledger" 2>/dev/null \
      || { echo "🛑 push-gate: cannot append to the push-hold ledger." >&2; return 1; }
    command -v journal_append >/dev/null 2>&1 && journal_append push_hold_awaiting slug "$slug" sha "$sha" dir "$dir" || true
  fi
  printf '🛑 PUSH GATE (human): %s is HELD before push. Nothing was pushed; the diff is local at:\n' "$slug"
  printf '   %s\n' "$dir"
  printf '   A human reviews it, then:  bash %s/herd-approve.sh approve %s\n' "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" "$slug"
  return 0
}

# push_gate_approve <slug> — record a human approval for <slug>'s current awaiting sha. Idempotent.
# Prints the approved sha on stdout (empty + non-zero if there is no live hold to approve).
push_gate_approve() {
  local slug="$1" sha ledger
  sha="$(_pg_current "$slug")" || true
  [ -n "$sha" ] || { echo "push-gate: no live push-hold for '$slug' to approve." >&2; return 1; }
  ledger="$(push_gate_ledger)" || return 1
  if ! push_gate_is_approved "$slug" "$sha"; then
    printf '%s approved %s %s\n' "$(_pg_epoch)" "$slug" "$sha" >> "$ledger" 2>/dev/null \
      || { echo "push-gate: cannot record approval for '$slug'." >&2; return 1; }
    command -v journal_append >/dev/null 2>&1 && journal_append push_hold_approved slug "$slug" sha "$sha" || true
  fi
  printf '%s' "$sha"
}

# _pg_push <dir> <branch> — push the worktree's HEAD to the feature branch on the remote. Overridable
# for the sandbox sim via HERD_PUSH_GATE_PUSH_CMD (a script run with HERD_PG_* in its env), the same
# stub-injection pattern main_health_tick uses with HERD_HEALTHCHECK_BIN.
_pg_push() {
  local dir="$1" branch="$2"
  if [ -n "${HERD_PUSH_GATE_PUSH_CMD:-}" ]; then
    HERD_PG_DIR="$dir" HERD_PG_BRANCH="$branch" bash "$HERD_PUSH_GATE_PUSH_CMD"
  else
    ( cd "$dir" && git push -u "${HERD_REMOTE:-origin}" "HEAD:$branch" )
  fi
}

# _pg_pr_create <dir> <branch> <base> <title> <body-file> — open the PR. Overridable for the sim via
# HERD_PUSH_GATE_PR_CMD (run with HERD_PG_* in its env); default is a real `gh pr create`.
_pg_pr_create() {
  local dir="$1" branch="$2" base="$3" title="$4" body_file="$5"
  if [ -n "${HERD_PUSH_GATE_PR_CMD:-}" ]; then
    HERD_PG_DIR="$dir" HERD_PG_BRANCH="$branch" HERD_PG_BASE="$base" HERD_PG_TITLE="$title" HERD_PG_BODYFILE="$body_file" bash "$HERD_PUSH_GATE_PR_CMD"
  else
    ( cd "$dir" && gh pr create --title "$title" --body-file "$body_file" --head "$branch" --base "$base" )
  fi
}

# push_gate_resume <slug> — the RESUME step herd-approve.sh runs after recording approval: verify the
# hold is intact + approved for the CURRENT worktree HEAD, then push + open the PR. FAIL-SOFT toward
# safety at every branch — a stale/corrupt/unapproved hold refuses LOUDLY and pushes NOTHING.
push_gate_resume() {
  local slug="$1"
  local sha detail dir branch base title body
  sha="$(_pg_current "$slug")" || true
  if [ -z "$sha" ]; then
    echo "🛑 push-gate: no live push-hold for '$slug' — nothing to resume." >&2
    return 1
  fi
  detail="$(push_gate_detail_file "$slug")" || return 1
  body="$(push_gate_body_file "$slug")" || return 1
  if [ ! -f "$detail" ]; then
    echo "🛑 push-gate: hold record for '$slug' is missing its detail file ($detail) — REFUSING to push a corrupt hold." >&2
    return 1
  fi
  dir="$(sed -n 's/^dir=//p' "$detail" | head -1)"  # pipe-ok: head in a command or process substitution; pipeline status not gated
  branch="$(sed -n 's/^branch=//p' "$detail" | head -1)"  # pipe-ok: head in a command or process substitution; pipeline status not gated
  base="$(sed -n 's/^base=//p' "$detail" | head -1)"  # pipe-ok: head in a command or process substitution; pipeline status not gated
  title="$(sed -n 's/^title=//p' "$detail" | head -1)"  # pipe-ok: head in a command or process substitution; pipeline status not gated
  if [ -z "$dir" ] || [ -z "$branch" ] || [ ! -d "$dir" ]; then
    echo "🛑 push-gate: hold record for '$slug' is corrupt (dir='$dir' branch='$branch') — REFUSING to push." >&2
    return 1
  fi
  # Sha invalidation: the worktree HEAD must still equal the held/approved sha. A new commit after the
  # hold changes HEAD → the approval is stale (same semantics as a new commit invalidating a merge
  # approval). Refuse and tell the operator to re-hold.
  local head; head="$(_pg_worktree_sha "$dir")"
  if [ "$head" != "$sha" ]; then
    echo "🛑 push-gate: '$slug' HEAD ($head) no longer matches the held sha ($sha) — a new commit invalidated the approval. Re-run 'push-gate.sh hold $slug' and re-approve." >&2
    return 1
  fi
  if ! push_gate_is_approved "$slug" "$sha"; then
    echo "🛑 push-gate: '$slug' (sha $sha) is not approved — run 'herd-approve.sh approve $slug' first." >&2
    return 1
  fi
  [ -f "$body" ] || printf '%s\n' "$title" > "$body" 2>/dev/null || true

  echo "⬆️  push-gate: approved — pushing '$slug' ($branch) and opening its PR…"
  if ! _pg_push "$dir" "$branch"; then
    echo "🛑 push-gate: push failed for '$slug' — the hold stays open (nothing partially recorded)." >&2
    command -v journal_append >/dev/null 2>&1 && journal_append push_hold_push_failed slug "$slug" sha "$sha" || true
    return 1
  fi
  if ! _pg_pr_create "$dir" "$branch" "$base" "$title" "$body"; then
    echo "🛑 push-gate: PR creation failed for '$slug' — the branch is pushed; open the PR manually or retry approve." >&2
    command -v journal_append >/dev/null 2>&1 && journal_append push_hold_pr_failed slug "$slug" sha "$sha" || true
    return 1
  fi
  # Mark the hold satisfied so the console row + `list` clear; the awaiting record's history is kept.
  local ledger; ledger="$(push_gate_ledger)" || true
  [ -n "$ledger" ] && printf '%s pushed %s %s\n' "$(_pg_epoch)" "$slug" "$sha" >> "$ledger" 2>/dev/null || true
  command -v journal_append >/dev/null 2>&1 && journal_append push_hold_resumed slug "$slug" sha "$sha" || true
  echo "✅ push-gate: '$slug' pushed and its PR opened — the watcher takes it from here (gates + merge)."
  return 0
}

# ── CLI dispatch (only when executed, never when sourced) ────────────────────
# Sourced by herd-approve.sh / agent-watch.sh for the functions above; run directly by the builder
# (`hold`) and by herd-approve's resume path (`resume`). The guard keeps sourcing side-effect-free.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -uo pipefail
  _PG_HERE="$(cd "$(dirname "$0")" && pwd)"
  # shellcheck source=scripts/herd/herd-config.sh
  . "$_PG_HERE/herd-config.sh"
  # Journal is best-effort; source it so hold/resume can emit events (no-op if it drops).
  # shellcheck source=scripts/herd/journal.sh
  [ -f "$_PG_HERE/journal.sh" ] && . "$_PG_HERE/journal.sh"
  _pg_cmd="${1:-}"; shift 2>/dev/null || true
  case "$_pg_cmd" in
    hold)    push_gate_hold "$@" ;;
    approve) push_gate_approve "$@" >/dev/null && echo "✅ push-gate: approval recorded." ;;
    resume)  push_gate_resume "$@" ;;
    list)    push_gate_list ;;
    mode)    push_gate_mode; echo ;;
    *) echo "Usage: push-gate.sh [hold <slug> [--dir D --branch B --base R --title T --body-file F] | approve <slug> | resume <slug> | list | mode]" >&2; exit 1 ;;
  esac
fi
