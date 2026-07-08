#!/usr/bin/env bash
# steps.sh — the shared PIPELINE STEPS runner (HERD-132): operator-defined lane stages with
# hold/approve semantics, so an operator can plug their OWN skill or shell command in as a pipeline
# stage instead of being limited to the built-in seams' fixed contents.
#
# The lane pipeline (build → healthcheck → review → merge) has configurable CONTENTS at fixed seams
# but is not EXTENSIBLE — you cannot declare a custom stage. This closes that gap with a declarative
# step list, .herd/steps.tsv, whose rows ADD checks at four seams. Concrete wants it serves: an
# operator's own PR-review skill as a peer-review stage, a documentation-pass step, or an arbitrary
# "run this and STOP and show me" checkpoint.
#
# ── The step list: .herd/steps.tsv ───────────────────────────────────────────────────────────────
# One TAB-separated row per step; blank lines and lines whose first field starts with '#' are ignored:
#     name <TAB> at <TAB> run <TAB> on_fail <TAB> hold
#   name     a kebab-ish label, unique-ish; used in the console/journal and as the hold key suffix.
#   at       WHEN the step runs — one of: post-build | post-healthcheck | pre-merge | post-merge.
#            post-build / post-healthcheck run in the BUILDER's Claude Code session (skill: steps work
#            there); pre-merge / post-merge run in the WATCHER's merge sequence (shell steps).
#   run      a shell command, OR 'skill:<name>' — a repo .claude/skills skill invoked in the builder's
#            Claude Code session (the repo's .claude/skills travels with the worktree).
#   on_fail  block (default) — a non-zero step BLOCKS the lane at that seam; warn — journal + continue.
#   hold     none (default) — proceed; notify — journal + notify but continue; approve — record a
#            sha-keyed hold and STOP until a human runs `herd-approve.sh approve <slug>`.
#
# ── HARD RULES (see HERD-132) ────────────────────────────────────────────────────────────────────
#   • An EMPTY or ABSENT step list ⇒ a BYTE-IDENTICAL pipeline: steps_run_at returns 0 immediately,
#     writing NO journal event, NO ledger row, NO console row. The feature ships dormant/default-off.
#   • Steps ADD checks; they NEVER replace or bypass the built-in review/healthcheck floor. The seams
#     run steps AFTER the built-in gates for that stage (agent-watch runs pre-merge steps only after
#     the review + health gates PASS), so a step can only ADD a hold, never remove one.
#   • FAIL-SOFT: a missing/erroring step command routes through its on_fail semantics (a missing
#     binary is rc 127 → block/warn), NEVER a wedged lane. A corrupt/unresolvable hold refuses LOUDLY.
#   • Every step execution journals a `step_run` event carrying name + outcome (pass|warn|fail|held).
#
# ── hold=approve reuses the sha-keyed herd-approve ledger ─────────────────────────────────────────
# Sequenced AFTER HERD-123 (PUSH_GATE=human), this reuses the SAME hold plumbing as the push-gate /
# merge-approval holds: a per-slug ledger with awaiting/approved/released records, released by
# herd-approve.sh, invalidated by a new commit (the sha changes). Records are keyed by (slug, sha,
# STEP-NAME) — NOT (slug, sha) alone — so N distinct hold=approve steps at ONE sha each get their own
# awaiting/approved/released triple and each requires its OWN approval (approving one never consumes
# another's gate). Steps hold SEQUENTIALLY (a held step stops the pipeline), so at most one is live at a
# time and approve <slug> unambiguously targets the current (earliest still-live) one.
#
# Dual-purpose, like the engine's other shared helpers: SOURCE it for the steps_* functions
# (herd-approve.sh releases holds; agent-watch.sh runs the pre/post-merge seams; the lanes thread the
# builder-seam rule), OR run it as a CLI (`steps.sh run <seam>` from a seam; `steps.sh validate`).
# Sourced AFTER herd-config.sh (which provides PROJECT_ROOT / WORKTREES_DIR) and journal.sh:
#   . "$HERE/herd-config.sh"
#   . "$HERE/journal.sh"
#   . "$HERE/steps.sh"
#
# ── Ledger + record layout ─────────────────────────────────────────────────────────────────────
# Ledger  $WORKTREES_DIR/.agent-watch-step-holds — append-only, one space-separated record per line,
# STEP-last (so a step name never collides with the sha column):
#     <epoch> awaiting <slug> <sha> <step>   — the hold=approve step <step> is holding this sha
#     <epoch> approved <slug> <sha> <step>   — a human approved this exact (sha, step)
#     <epoch> released <slug> <sha> <step>   — that hold was released + the pipeline resumed past <step>
# Detail  $WORKTREES_DIR/.agent-watch-step-hold-<slug>-<step> — KEY=value metadata resume needs (one
# file PER held step): the held step's name, seam (at), worktree dir, and sha.

# The four legal seams, in pipeline order. The ONE source of truth every validator/runner checks.
STEPS_SEAMS="post-build post-healthcheck pre-merge post-merge"

# steps_file — path to the project's step list. A test seam, HERD_STEPS_FILE, overrides it outright
# (the sim points it at a fixture). Empty output ⇒ no destination ⇒ callers treat the list as ABSENT
# (byte-identical no-op).
steps_file() {
  if [ -n "${HERD_STEPS_FILE:-}" ]; then printf '%s' "$HERD_STEPS_FILE"; return 0; fi
  [ -n "${PROJECT_ROOT:-}" ] || return 1
  printf '%s' "$PROJECT_ROOT/.herd/steps.tsv"
}

# steps_enabled — 0 iff the step list exists AND has at least one non-blank, non-comment row. The ONE
# chokepoint every entry point routes through so an absent/empty/comments-only list is byte-inert.
steps_enabled() {
  local f; f="$(steps_file)" || return 1
  [ -f "$f" ] || return 1
  # Any line whose first tab-field is non-empty and not a comment counts as a real row.
  awk -F'\t' '{ n=$1; sub(/^[[:space:]]+/,"",n); if (n!="" && substr(n,1,1)!="#") { found=1; exit } } END { exit(found?0:1) }' "$f" 2>/dev/null
}

# _steps_trim <s> — strip leading/trailing whitespace (fields come straight off a TSV read).
_steps_trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }

# _steps_norm_onfail / _steps_norm_hold — normalize an optional column to its default. Unknown values
# are returned VERBATIM so steps_validate can flag them; the runner treats an unknown as its safe
# default (block / none) via its own case, never a surprise.
_steps_norm_onfail() { local v; v="$(_steps_trim "$1")"; printf '%s' "${v:-block}"; }
_steps_norm_hold()   { local v; v="$(_steps_trim "$1")"; printf '%s' "${v:-none}"; }

# steps_validate — validate every row of the step list like a config key: required fields present, and
# at/on_fail/hold drawn from their legal sets. Prints one problem per bad row to stderr; returns 0 when
# the list is absent or wholly valid, 1 on any problem, 2 when PROJECT_ROOT can't be resolved. Never
# mutates anything.
steps_validate() {
  local f; f="$(steps_file)" || { echo "steps: cannot locate steps.tsv (PROJECT_ROOT unset)" >&2; return 2; }
  [ -f "$f" ] || return 0                       # absent list = valid (empty pipeline)
  local ln=0 problems=0 name at run onfail hold nm
  while IFS=$'\t' read -r name at run onfail hold || [ -n "$name" ]; do
    ln=$((ln + 1))
    nm="$(_steps_trim "$name")"
    case "$nm" in ''|'#'*) continue ;; esac     # blank / comment
    at="$(_steps_trim "$at")"; run="$(_steps_trim "$run")"
    onfail="$(_steps_norm_onfail "$onfail")"; hold="$(_steps_norm_hold "$hold")"
    if [ -z "$at" ] || [ -z "$run" ]; then
      echo "steps.tsv:$ln: '$nm' — 'at' and 'run' are required" >&2; problems=$((problems + 1)); continue
    fi
    case " $STEPS_SEAMS " in *" $at "*) ;; *) echo "steps.tsv:$ln: '$nm' — invalid at='$at' (want one of: $STEPS_SEAMS)" >&2; problems=$((problems + 1)) ;; esac
    case "$onfail" in block|warn) ;; *) echo "steps.tsv:$ln: '$nm' — invalid on_fail='$onfail' (want: block | warn)" >&2; problems=$((problems + 1)) ;; esac
    case "$hold" in none|notify|approve) ;; *) echo "steps.tsv:$ln: '$nm' — invalid hold='$hold' (want: none | notify | approve)" >&2; problems=$((problems + 1)) ;; esac
  done < "$f"
  [ "$problems" -eq 0 ] || return 1
  return 0
}

# steps_list [seam] — print each valid row as: name<TAB>at<TAB>run<TAB>on_fail<TAB>hold. With a seam
# argument, only rows for that seam. Invalid rows are silently dropped (the runner is fail-soft — a
# malformed row must never wedge a lane); run `steps_validate` to surface them.
steps_list() {
  local want="${1:-}"
  local f; f="$(steps_file)" || return 0
  [ -f "$f" ] || return 0
  local name at run onfail hold nm
  while IFS=$'\t' read -r name at run onfail hold || [ -n "$name" ]; do
    nm="$(_steps_trim "$name")"
    case "$nm" in ''|'#'*) continue ;; esac
    at="$(_steps_trim "$at")"; run="$(_steps_trim "$run")"
    onfail="$(_steps_norm_onfail "$onfail")"; hold="$(_steps_norm_hold "$hold")"
    [ -n "$at" ] && [ -n "$run" ] || continue
    case " $STEPS_SEAMS " in *" $at "*) ;; *) continue ;; esac
    case "$onfail" in block|warn) ;; *) continue ;; esac
    case "$hold" in none|notify|approve) ;; *) continue ;; esac
    [ -z "$want" ] || [ "$at" = "$want" ] || continue
    printf '%s\t%s\t%s\t%s\t%s\n' "$nm" "$at" "$run" "$onfail" "$hold"
  done < "$f"
}

# steps_has_seam <seam> — 0 iff at least one VALID step targets <seam>. The lanes' tail uses it to
# decide whether to thread the builder-seam rule (keeping the prompt byte-identical when there are no
# builder-seam steps), and the watcher uses it to skip the pre/post-merge seams cheaply.
steps_has_seam() {
  local want="$1"
  [ -n "$(steps_list "$want" 2>/dev/null | head -1)" ]
}

# steps_builder_rule <slug> <dir> <engine-dir> <pr-create-cmd> — the BUILDER-seam rule text threaded
# into the lanes' prompt (herd-feature.sh / herd-quick.sh), or EMPTY when the project defines no
# post-build / post-healthcheck step (so the prompt stays byte-identical). Emits a leading space so it
# concatenates onto the rules string like PUSH_GATE_RULE / LOCAL_REVIEW_RULE. Same threading pattern as
# the other opt-in lane rules; the watcher owns the pre/post-merge seams (never mentioned here).
steps_builder_rule() {
  local slug="$1" dir="$2" engine="$3" pr_cmd="$4"
  local has_pb has_ph; has_pb=1; has_ph=1
  steps_has_seam post-build       || has_pb=0
  steps_has_seam post-healthcheck || has_ph=0
  [ "$has_pb" = "1" ] || [ "$has_ph" = "1" ] || return 0
  local rule=" PIPELINE STEPS (custom stages, HERD-132): this project defines extra pipeline steps in .herd/steps.tsv that run IN THIS SESSION."
  if [ "$has_pb" = "1" ]; then
    rule="$rule After your work is committed, run:  bash $engine/steps.sh run post-build --slug $slug --dir \"$dir\"  (the post-build stage)."
  fi
  if [ "$has_ph" = "1" ]; then
    rule="$rule After the healthcheck passes and BEFORE '$pr_cmd', run:  bash $engine/steps.sh run post-healthcheck --slug $slug --dir \"$dir\"  (the post-healthcheck stage)."
  fi
  rule="$rule Each step prints + journals its outcome. For a step whose command is 'skill:<name>', INVOKE that skill (from .claude/skills) yourself in this session before continuing. If the runner exits non-zero with a 'blocking the lane' message (on_fail=block), FIX the cause and re-run before opening the PR. If it stops with an approve-HOLD (exit 20), STOP — a human reviews and runs 'herd-approve.sh approve $slug' to resume the remaining steps."
  printf '%s' "$rule"
}

# ── hold=approve ledger (mirrors push-gate's .agent-watch-push-holds) ─────────────────────────────
steps_hold_ledger() { [ -n "${WORKTREES_DIR:-}" ] || return 1; printf '%s' "$WORKTREES_DIR/.agent-watch-step-holds"; }
# _steps_detail_key <step> — filesystem-safe rendering of a step name for the per-step detail filename.
_steps_detail_key() { local s="$1"; printf '%s' "${s//[^A-Za-z0-9._-]/_}"; }
# steps_hold_detail <slug> <step> — the per-(slug,step) detail file. <step> is required so distinct
# hold=approve steps at one sha never share (and clobber) a detail file.
steps_hold_detail() { [ -n "${WORKTREES_DIR:-}" ] || return 1; printf '%s' "$WORKTREES_DIR/.agent-watch-step-hold-$1-$(_steps_detail_key "${2:-}")"; }

_steps_epoch() { date +%s 2>/dev/null || echo 0; }
_steps_worktree_sha() { git -C "$1" rev-parse HEAD 2>/dev/null || true; }

# _steps_live_hold <slug> — echo "<sha><TAB><step>" of the live approve-hold for <slug>, or empty.
#
# LATEST-sha-wins with explicit supersession of stale-sha rows. This MIRRORS push-gate.sh _pg_current's
# last-write-wins semantic (the correct sibling): the sha of the LAST 'awaiting' record in file order is
# the CURRENT sha, and any 'awaiting' rows at an OLDER sha are SUPERSEDED — a new commit pushed during a
# live hold appends a fresh awaiting row for the new sha, so the old sha's row must never be what a human
# approves. An earliest-in-file-order rule (the #249-family defect this fixes) would keep selecting the
# stale sha whose HEAD no longer matches, wedging `steps_hold_release` on the sha-invalidation guard
# FOREVER — approval could never target the current commit. WITHIN the current sha, steps hold
# sequentially, so the EARLIEST awaiting row at that sha whose (sha,step) is not released is the one a
# human approves next (an already-released sibling step at the same sha is skipped).
_steps_live_hold() {
  local slug="$1" ledger; ledger="$(steps_hold_ledger)" || return 0
  [ -f "$ledger" ] || return 0
  local _ state s sha step released_keys="" cur_sha=""
  # Pass 1: collect the released (sha,step) keys AND track the CURRENT sha = the sha of the last
  # 'awaiting' record for this slug in file order (last-write-wins). A newer commit's awaiting row,
  # appended later, thereby SUPERSEDES older stale-sha awaiting rows.
  while read -r _ state s sha step; do
    [ "$s" = "$slug" ] || continue
    case "$state" in
      released) released_keys="$released_keys|$sha $step|" ;;
      awaiting) cur_sha="$sha" ;;
    esac
  done < "$ledger"
  [ -n "$cur_sha" ] || return 0
  # Pass 2: among awaiting rows AT the current sha only (stale-sha rows are superseded), the first whose
  # (sha,step) is not released is the live hold. All current-sha steps released ⇒ no live hold.
  while read -r _ state s sha step; do
    [ "$s" = "$slug" ] || continue
    [ "$state" = "awaiting" ] || continue
    [ "$sha" = "$cur_sha" ] || continue
    case "$released_keys" in *"|$sha $step|"*) continue ;; esac
    printf '%s\t%s' "$sha" "$step"
    return 0
  done < "$ledger"
  return 0
}

# _steps_current <slug> — the sha of the earliest still-live hold for <slug>, or empty. (Step-agnostic
# convenience over _steps_live_hold; the public probe below builds on it.)
_steps_current() {
  local lh; lh="$(_steps_live_hold "$1")" || return 0
  [ -n "$lh" ] || return 0
  printf '%s' "${lh%%$'\t'*}"
}

# steps_hold_awaiting_sha <slug> — PUBLIC single-slug probe: the sha this slug currently holds for
# step approval, or empty. herd-approve.sh selects the step-approval path on a non-empty result.
steps_hold_awaiting_sha() { _steps_current "$1"; }

# steps_hold_is_approved <slug> <sha> <step> — 0 iff an approval record exists for this exact (sha,step).
steps_hold_is_approved() {
  local ledger; ledger="$(steps_hold_ledger)" || return 1
  grep -q "^[0-9]* approved $1 $2 $3$" "$ledger" 2>/dev/null
}
# steps_hold_is_released <slug> <sha> <step> — 0 iff a released record exists for this exact (sha,step).
steps_hold_is_released() {
  local ledger; ledger="$(steps_hold_ledger)" || return 1
  grep -q "^[0-9]* released $1 $2 $3$" "$ledger" 2>/dev/null
}

# ── non-approve step memoization (once-per-(slug,sha,step)) ────────────────────────────────────────
# The watcher re-runs the pre-merge seam every ~4s (do_merge, no --resume-after). Without a memo, a
# non-approve step (hold=none/notify) would RE-EXECUTE + re-journal + re-notify on EVERY tick, spamming
# the operator and re-running side effects. A 'done' record memoizes a non-approve step that has already
# fired at a given sha so it fires EXACTLY ONCE per (slug,sha,step). Keyed by sha, so a new commit (new
# sha) legitimately re-fires it. approve-holds are NOT memoized here — they use the awaiting/released
# ledger; block-FAILS are NOT memoized — they must keep re-running until the cause is fixed.
# steps_step_memoized <slug> <sha> <step> — 0 iff this (sha,step) already fired (a 'done' record exists).
steps_step_memoized() {
  local ledger; ledger="$(steps_hold_ledger)" || return 1
  grep -q "^[0-9]* done $1 $2 $3$" "$ledger" 2>/dev/null
}
# _steps_memo_record <slug> <sha> <step> — record the 'done' memo for a non-approve step that just fired.
# Idempotent + fail-soft. A degenerate empty sha is not memoized (can't key stably) ⇒ per-tick fallback.
_steps_memo_record() {
  local slug="$1" sha="$2" step="$3" ledger
  [ -n "$sha" ] || return 0
  ledger="$(steps_hold_ledger)" || return 0
  grep -q "^[0-9]* done $slug $sha $step$" "$ledger" 2>/dev/null && return 0
  printf '%s done %s %s %s\n' "$(_steps_epoch)" "$slug" "$sha" "$step" >> "$ledger" 2>/dev/null || true
}

# steps_hold_purge <slug> — F9 backstop (HERD-157): drop EVERY step-hold ledger row for <slug> and remove
# its per-step detail files. A merged/reaped PR is terminal — its holds are phantom, and a lingering
# 'awaiting' row would haunt `herd-approve.sh list` / steps_hold_list forever (the step-hold analogue of
# purge_pr_approvals). Called from the reap path (_reap_slug), so both a merge and the startup sweep
# clear it. Fully fail-soft + idempotent: an absent ledger / already-purged slug no-ops.
steps_hold_purge() {
  local slug="$1" ledger tmp step detail steps_seen
  [ -n "$slug" ] || return 0
  ledger="$(steps_hold_ledger)" || return 0
  [ -f "$ledger" ] || return 0
  # Remove the EXACT per-step detail files first, derived from this slug's ledger rows — never a glob,
  # so a sibling slug that shares a filename prefix (e.g. 'foo' vs 'foo-bar') is never clobbered.
  steps_seen="$(awk -v s="$slug" '$3==s {print $5}' "$ledger" 2>/dev/null | awk 'NF && !seen[$0]++')"
  while IFS= read -r step; do
    [ -n "$step" ] || continue
    detail="$(steps_hold_detail "$slug" "$step")" || continue
    rm -f "$detail" 2>/dev/null || true
  done <<EOF
$steps_seen
EOF
  # Then drop every ledger row for this slug (slug is field 3; exact compare so a substring slug is
  # never clobbered). Atomic rewrite via temp+mv; a hiccup leaves the ledger untouched.
  if [ -s "$ledger" ]; then
    tmp="$(mktemp "$ledger.XXXXXX" 2>/dev/null)" || return 0
    if awk -v s="$slug" '$3 != s' "$ledger" > "$tmp" 2>/dev/null; then
      mv -f "$tmp" "$ledger" 2>/dev/null || rm -f "$tmp" 2>/dev/null
    else
      rm -f "$tmp" 2>/dev/null
    fi
  fi
  return 0
}

# steps_hold_list — print every LIVE step-hold as: <slug> <sha> <step> <dir>. One row per slug (steps
# hold sequentially, so a slug has at most one live hold). Skips released holds. Used by herd-approve.sh.
steps_hold_list() {
  local ledger; ledger="$(steps_hold_ledger)" || return 0
  [ -f "$ledger" ] || return 0
  local slugs slug lh sha step detail dir
  slugs="$(awk '{print $3}' "$ledger" 2>/dev/null | awk '!seen[$0]++')"
  while IFS= read -r slug; do
    [ -n "$slug" ] || continue
    lh="$(_steps_live_hold "$slug")" || true
    [ -n "$lh" ] || continue
    sha="${lh%%$'\t'*}"; step="${lh##*$'\t'}"
    dir=""
    detail="$(steps_hold_detail "$slug" "$step")" || true
    [ -f "$detail" ] && dir="$(sed -n 's/^dir=//p' "$detail" 2>/dev/null | head -1)"
    printf '%s %s %s %s\n' "$slug" "$sha" "${step:-?}" "$dir"
  done <<EOF
$slugs
EOF
}

# _steps_hold_record <slug> <step> <at> <dir> <sha> — record the awaiting hold + its detail file, keyed
# by (slug, sha, step). Idempotent + BOUNDED: at most ONE 'awaiting' row per (slug, sha, step) EVER —
# whether still live OR already released (a released hold is terminal for that step; a new hold needs a
# new commit ⇒ a new sha). That per-step ceiling keeps the ledger from growing across the watcher's
# per-tick re-runs of the pre-merge seam, AND lets N distinct approve-steps at one sha each hold once.
_steps_hold_record() {
  local slug="$1" step="$2" at="$3" dir="$4" sha="$5"
  local ledger detail tmp
  ledger="$(steps_hold_ledger)" || { echo "🛑 steps: WORKTREES_DIR unset — cannot record a hold." >&2; return 1; }
  detail="$(steps_hold_detail "$slug" "$step")"
  tmp="$detail.tmp.$$"
  {
    printf 'sha=%s\n' "$sha"
    printf 'slug=%s\n' "$slug"
    printf 'step=%s\n' "$step"
    printf 'at=%s\n' "$at"
    printf 'dir=%s\n' "$dir"
  } > "$tmp" 2>/dev/null || { echo "🛑 steps: cannot write hold detail for '$slug'." >&2; return 1; }
  mv -f "$tmp" "$detail" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; echo "🛑 steps: cannot install hold detail for '$slug'." >&2; return 1; }
  # grep (not _steps_live_hold) so a degenerate empty sha still records on its first hold for the step.
  if grep -q "^[0-9]* awaiting $slug $sha $step$" "$ledger" 2>/dev/null; then
    return 0
  fi
  printf '%s awaiting %s %s %s\n' "$(_steps_epoch)" "$slug" "$sha" "$step" >> "$ledger" 2>/dev/null \
    || { echo "🛑 steps: cannot append to the step-hold ledger." >&2; return 1; }
  command -v journal_append >/dev/null 2>&1 && journal_append step_hold_awaiting slug "$slug" step "$step" at "$at" sha "$sha" dir "$dir" || true
  return 0
}

# steps_hold_approve <slug> — record a human approval for <slug>'s CURRENT (earliest still-live) hold,
# keyed by its (sha, step). Idempotent. Echoes the approved sha (empty + non-zero when no live hold).
steps_hold_approve() {
  local slug="$1" lh sha step ledger
  lh="$(_steps_live_hold "$slug")" || true
  [ -n "$lh" ] || { echo "steps: no live step-hold for '$slug' to approve." >&2; return 1; }
  sha="${lh%%$'\t'*}"; step="${lh##*$'\t'}"
  ledger="$(steps_hold_ledger)" || return 1
  if ! steps_hold_is_approved "$slug" "$sha" "$step"; then
    printf '%s approved %s %s %s\n' "$(_steps_epoch)" "$slug" "$sha" "$step" >> "$ledger" 2>/dev/null \
      || { echo "steps: cannot record approval for '$slug'." >&2; return 1; }
    command -v journal_append >/dev/null 2>&1 && journal_append step_hold_approved slug "$slug" step "$step" sha "$sha" || true
  fi
  printf '%s' "$sha"
}

# steps_hold_release <slug> — the RESUME step herd-approve.sh runs after recording approval: verify the
# CURRENT (earliest still-live) hold is intact + approved for the CURRENT worktree HEAD, mark THAT
# (sha, step) released, then RESUME the pipeline from the step AFTER the released one. A sha with several
# approve-steps releases them ONE AT A TIME: resuming past step-a re-holds on step-b, and the next
# approve targets step-b. FAIL-SOFT: a stale (new-commit), corrupt, or unapproved hold refuses LOUDLY
# and resumes NOTHING. Returns the resumed seam's rc (0 when the remaining steps pass or there is none).
steps_hold_release() {
  local slug="$1"
  local lh sha step detail at dir head ledger
  lh="$(_steps_live_hold "$slug")" || true
  if [ -z "$lh" ]; then
    echo "🛑 steps: no live step-hold for '$slug' — nothing to release." >&2
    return 1
  fi
  sha="${lh%%$'\t'*}"; step="${lh##*$'\t'}"
  detail="$(steps_hold_detail "$slug" "$step")" || return 1
  if [ ! -f "$detail" ]; then
    echo "🛑 steps: hold record for '$slug' step '$step' is missing its detail file ($detail) — REFUSING to resume a corrupt hold." >&2
    return 1
  fi
  at="$(sed -n 's/^at=//p' "$detail" | head -1)"
  dir="$(sed -n 's/^dir=//p' "$detail" | head -1)"
  if [ -z "$step" ] || [ -z "$at" ]; then
    echo "🛑 steps: hold record for '$slug' is corrupt (step='$step' at='$at') — REFUSING to resume." >&2
    return 1
  fi
  # Sha invalidation: if the worktree still resolves, HEAD must equal the held/approved sha. A new
  # commit after the hold changes HEAD ⇒ the approval is stale (same semantics as push-gate / merge).
  # A worktree that was RECORDED (non-empty dir) but is now GONE must NOT silently bypass this check
  # (HERD-157): we can no longer confirm HEAD==sha, and a vanished worktree means the PR merged/reaped
  # — its holds should be PURGED (steps_hold_purge in the reap path), never resumed. Refuse LOUDLY so a
  # phantom hold can't be released against a commit nobody can verify.
  if [ -n "$dir" ] && [ ! -d "$dir" ]; then
    echo "🛑 steps: '$slug' worktree ($dir) is gone — cannot verify HEAD against the held sha ($sha). REFUSING to resume a hold whose sha can't be confirmed (a merged/reaped PR's holds are purged, not resumed)." >&2
    return 1
  fi
  if [ -n "$dir" ] && [ -d "$dir" ]; then
    head="$(_steps_worktree_sha "$dir")"
    if [ -n "$head" ] && [ "$head" != "$sha" ]; then
      echo "🛑 steps: '$slug' HEAD ($head) no longer matches the held sha ($sha) — a new commit invalidated the approval. Re-run the step and re-approve." >&2
      return 1
    fi
  fi
  if ! steps_hold_is_approved "$slug" "$sha" "$step"; then
    echo "🛑 steps: '$slug' step '$step' (sha $sha) is not approved — run 'herd-approve.sh approve $slug' first." >&2
    return 1
  fi
  ledger="$(steps_hold_ledger)" || return 1
  if ! steps_hold_is_released "$slug" "$sha" "$step"; then
    printf '%s released %s %s %s\n' "$(_steps_epoch)" "$slug" "$sha" "$step" >> "$ledger" 2>/dev/null || true
    command -v journal_append >/dev/null 2>&1 && journal_append step_hold_released slug "$slug" step "$step" at "$at" sha "$sha" || true
  fi
  echo "▶️  steps: '$slug' step '$step' approved — resuming the $at pipeline past it…"
  # Resume the remaining steps of that seam (the built-in gates already passed for this stage). If a
  # LATER approve-step at this sha exists, the resume re-holds on it (return 20) and it needs its own
  # approval — a sha with N approve-steps requires N approvals.
  steps_run_at "$at" --slug "$slug" ${dir:+--dir "$dir"} --sha "$sha" --resume-after "$step"
}

# ── seam runner ──────────────────────────────────────────────────────────────────────────────────
# _steps_kind <run> — shell | skill.
_steps_kind() { case "$1" in skill:*) printf 'skill' ;; *) printf 'shell' ;; esac; }

# _steps_exec_shell <cmd> <dir> — run a shell step in <dir>. Overridable for the sim via
# HERD_STEPS_SHELL_CMD (run with HERD_STEP_* in env), the stub-injection pattern push-gate uses for its
# push/PR steps. A missing binary is rc 127 → routed through on_fail (fail-soft), never a wedge.
_steps_exec_shell() {
  local cmd="$1" dir="$2"
  if [ -n "${HERD_STEPS_SHELL_CMD:-}" ]; then
    HERD_STEP_CMD="$cmd" HERD_STEP_DIR="$dir" bash "$HERD_STEPS_SHELL_CMD"; return $?
  fi
  ( cd "$dir" 2>/dev/null && bash -c "$cmd" )
}

# _steps_exec_skill <name> <dir> — a 'skill:<name>' step. Overridable for the sim via
# HERD_STEPS_SKILL_CMD (run with HERD_STEP_* in env). By default the skill is INVOKED by the builder's
# Claude Code session; this helper can only GATE on the skill's presence in the repo's .claude/skills
# (which travels with the worktree): present → runnable (rc 0), absent → rc 127 → on_fail.
_steps_exec_skill() {
  local name="$1" dir="$2"
  if [ -n "${HERD_STEPS_SKILL_CMD:-}" ]; then
    HERD_STEP_SKILL="$name" HERD_STEP_DIR="$dir" bash "$HERD_STEPS_SKILL_CMD"; return $?
  fi
  if [ -d "$dir/.claude/skills/$name" ] || [ -f "$dir/.claude/skills/$name.md" ] || [ -f "$dir/.claude/skills/$name/SKILL.md" ]; then
    return 0
  fi
  echo "steps: skill '$name' not found under $dir/.claude/skills — cannot invoke." >&2
  return 127
}

# _steps_exec <run> <dir> — dispatch a step's run value to the shell/skill executor; echoes nothing,
# returns the step's exit code.
_steps_exec() {
  case "$1" in
    skill:*) _steps_exec_skill "${1#skill:}" "$2" ;;
    *)       _steps_exec_shell "$1" "$2" ;;
  esac
}

# steps_run_at <seam> [--slug S] [--dir D] [--sha SHA] [--resume-after STEP] — run every valid step for
# <seam>, in file order. This is the ONE entry point the lanes' tail + the watcher's gate sequence
# call. BYTE-IDENTICAL no-op when the step list is absent/empty (returns 0, journals nothing).
#
# Per step: execute run; on non-zero → on_fail (warn: journal + continue; block: journal + RETURN 1,
# blocking the seam). On success → journal step_run pass, then apply hold (none: continue; notify:
# journal + notify + continue; approve: record a sha-keyed hold + RETURN 20 = HELD, stopping the
# pipeline). An approve-hold is idempotent + resumable: while a live hold for this sha is awaiting, a
# re-run returns HELD WITHOUT re-executing the step; once released, a re-run (or --resume-after) skips
# past it. Exit codes: 0 all steps done · 1 a block-step failed · 20 an approve-step is HELD.
steps_run_at() {
  local seam="$1"; shift || true
  local slug="" dir="" sha="" resume_after=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --slug)          slug="${2:-}"; shift 2 ;;
      --dir)           dir="${2:-}"; shift 2 ;;
      --sha)           sha="${2:-}"; shift 2 ;;
      --resume-after)  resume_after="${2:-}"; shift 2 ;;
      *) echo "steps: run: unknown arg: $1" >&2; return 2 ;;
    esac
  done
  case " $STEPS_SEAMS " in *" $seam "*) ;; *) echo "steps: run: unknown seam '$seam'" >&2; return 2 ;; esac
  steps_enabled || return 0                        # absent/empty list ⇒ byte-identical no-op
  [ -n "$dir" ] || dir="$PWD"
  [ -n "$slug" ] || slug="$(basename "$dir" 2>/dev/null || echo step)"
  [ -n "$sha" ] || sha="$(_steps_worktree_sha "$dir")"

  local skipping=0; [ -n "$resume_after" ] && skipping=1
  local name at run onfail hold kind rc
  while IFS=$'\t' read -r name at run onfail hold; do
    # steps_list already filtered to valid rows for this seam and normalized on_fail/hold.
    kind="$(_steps_kind "$run")"
    if [ "$skipping" = "1" ]; then
      [ "$name" = "$resume_after" ] && skipping=0   # resume with the step AFTER the held one
      continue
    fi
    # Non-approve steps fire ONCE per (slug,sha,step): the watcher re-runs the pre-merge seam every
    # ~4s, and without this memo a pass/notify step would re-execute + re-journal + re-notify every
    # tick. Once memoized (already fired at this sha) skip it silently. Keyed by sha ⇒ a new commit
    # re-fires it. approve-holds are handled by the ledger branch below, not memoized here.
    if [ "$hold" != "approve" ] && [ -n "$sha" ] && steps_step_memoized "$slug" "$sha" "$name"; then
      continue
    fi
    # An approve-hold is idempotent + resumable: check the ledger for THIS (slug,sha,step) BEFORE
    # (re-)executing. Every check is per-step so N approve-steps at one sha each gate independently.
    if [ "$hold" = "approve" ] && [ -n "$sha" ]; then
      # RELEASED ⇒ THIS step's (slug,sha,step) hold was approved + CONSUMED: skip past it WITHOUT
      # re-executing or re-recording. Keyed by step name — NOT (slug,sha) alone — so approving ONE
      # approve-step never consumes a SIBLING approve-step's gate at the same sha. This branch is what
      # lets the watcher-owned seam proceed: do_merge re-runs steps_run_at pre-merge from the top every
      # tick with no --resume-after, so a released hold must be recognised here or it re-holds forever.
      if steps_hold_is_released "$slug" "$sha" "$name"; then
        continue
      fi
      # Already AWAITING for this exact (slug,sha,step) ⇒ this step ran + held on an earlier pass ⇒ still
      # HELD, without re-running the step (idempotent; keeps the ledger bounded to one awaiting per step).
      if grep -q "^[0-9]* awaiting $slug $sha $name$" "$(steps_hold_ledger)" 2>/dev/null; then
        command -v journal_append >/dev/null 2>&1 && journal_append step_run name "$name" at "$seam" kind "$kind" slug "$slug" sha "$sha" outcome held || true
        return 20
      fi
    fi
    # Redirect the step's stdin from /dev/null: the loop reads its row list on fd 0 (the heredoc
    # below), so a step command that reads stdin (cat, a prompt) must not consume the remaining rows.
    _steps_exec "$run" "$dir" </dev/null; rc=$?
    if [ "$rc" -ne 0 ]; then
      if [ "$onfail" = "warn" ]; then
        command -v journal_append >/dev/null 2>&1 && journal_append step_run name "$name" at "$seam" kind "$kind" slug "$slug" sha "$sha" outcome warn rc "$rc" || true
        # Memoize the warn so it doesn't re-warn every tick (a block-FAIL below is NOT memoized — it
        # must keep re-running until fixed).
        [ "$hold" != "approve" ] && _steps_memo_record "$slug" "$sha" "$name"
        continue
      fi
      command -v journal_append >/dev/null 2>&1 && journal_append step_run name "$name" at "$seam" kind "$kind" slug "$slug" sha "$sha" outcome fail rc "$rc" || true
      echo "🛑 steps: '$name' ($seam) FAILED (rc=$rc, on_fail=block) — blocking the lane at this seam." >&2
      return 1
    fi
    command -v journal_append >/dev/null 2>&1 && journal_append step_run name "$name" at "$seam" kind "$kind" slug "$slug" sha "$sha" outcome pass || true
    case "$hold" in
      notify)
        command -v journal_append >/dev/null 2>&1 && journal_append step_hold_notify slug "$slug" step "$name" at "$seam" sha "$sha" || true
        command -v herd_driver_notify >/dev/null 2>&1 && herd_driver_notify "🐑 step '$name'" "$slug: $seam checkpoint reached" default || true
        ;;
      approve)
        _steps_hold_record "$slug" "$name" "$seam" "$dir" "$sha" || return 1
        command -v journal_append >/dev/null 2>&1 && journal_append step_run name "$name" at "$seam" kind "$kind" slug "$slug" sha "$sha" outcome held || true
        echo "🛑 steps: '$name' ($seam) reached an approve-HOLD for '$slug'. Nothing proceeds past it until a human runs:  bash $(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/herd-approve.sh approve $slug" >&2
        return 20
        ;;
    esac
    # Memoize a non-approve step that PASSED (none/notify) so it fires once per (slug,sha,step). An
    # approve-hold returned 20 above and never reaches here; a block-fail returned 1 and is not memoized.
    [ "$hold" != "approve" ] && _steps_memo_record "$slug" "$sha" "$name"
  done <<EOF
$(steps_list "$seam")
EOF
  return 0
}

# ── CLI dispatch (only when executed, never when sourced) ─────────────────────────────────────────
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -uo pipefail
  _ST_HERE="$(cd "$(dirname "$0")" && pwd)"
  # shellcheck source=scripts/herd/herd-config.sh
  . "$_ST_HERE/herd-config.sh"
  # shellcheck source=scripts/herd/journal.sh
  [ -f "$_ST_HERE/journal.sh" ] && . "$_ST_HERE/journal.sh"
  # driver.sh gives herd_driver_notify for hold=notify (best-effort; absent ⇒ notify is skipped).
  # shellcheck source=scripts/herd/driver.sh
  [ -f "$_ST_HERE/driver.sh" ] && . "$_ST_HERE/driver.sh"
  _st_cmd="${1:-}"; shift 2>/dev/null || true
  case "$_st_cmd" in
    run)      steps_run_at "$@" ;;
    validate) steps_validate && echo "✅ steps: .herd/steps.tsv valid." ;;
    list)     steps_list "$@" ;;
    holds)    steps_hold_list ;;
    approve)  steps_hold_approve "$@" >/dev/null && steps_hold_release "$@" ;;
    release)  steps_hold_release "$@" ;;
    purge)    steps_hold_purge "$@" ;;
    enabled)  steps_enabled ;;
    file)     steps_file; echo ;;
    *) echo "Usage: steps.sh [run <seam> [--slug S --dir D --sha SHA --resume-after STEP] | validate | list [seam] | holds | approve <slug> | release <slug> | purge <slug> | enabled | file]" >&2; exit 1 ;;
  esac
fi
