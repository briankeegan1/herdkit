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
# Sequenced AFTER HERD-123 (PUSH_GATE=human), this reuses the SAME sha-keyed hold plumbing as the
# push-gate / merge-approval holds: a per-slug ledger with awaiting/approved/released records, released
# by herd-approve.sh, invalidated by a new commit (the sha changes). One live approve-hold per slug at
# a time (a held step stops the pipeline), so approve <slug> unambiguously targets it.
#
# Dual-purpose, like the engine's other shared helpers: SOURCE it for the steps_* functions
# (herd-approve.sh releases holds; agent-watch.sh runs the pre/post-merge seams; the lanes thread the
# builder-seam rule), OR run it as a CLI (`steps.sh run <seam>` from a seam; `steps.sh validate`).
# Sourced AFTER herd-config.sh (which provides PROJECT_ROOT / WORKTREES_DIR) and journal.sh:
#   . "$HERE/herd-config.sh"
#   . "$HERE/journal.sh"
#   . "$HERE/steps.sh"
#
# ── Ledger + record layout (mirrors .agent-watch-push-holds so it parses identically) ─────────────
# Ledger  $WORKTREES_DIR/.agent-watch-step-holds — append-only, one space-separated record per line,
# sha-last:
#     <epoch> awaiting <slug> <sha>     — a step with hold=approve is holding this sha
#     <epoch> approved <slug> <sha>     — a human approved this exact sha (herd-approve.sh approve)
#     <epoch> released <slug> <sha>     — the hold was released + the pipeline resumed past the step
# Detail  $WORKTREES_DIR/.agent-watch-step-hold-<slug> — KEY=value metadata resume needs (rewritten
# on each hold): the held step's name, seam (at), worktree dir, and sha.

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
steps_hold_detail() { [ -n "${WORKTREES_DIR:-}" ] || return 1; printf '%s' "$WORKTREES_DIR/.agent-watch-step-hold-$1"; }

_steps_epoch() { date +%s 2>/dev/null || echo 0; }
_steps_worktree_sha() { git -C "$1" rev-parse HEAD 2>/dev/null || true; }

# _steps_current <slug> — the sha of the latest 'awaiting' record for <slug> not yet 'released'. Empty
# when there is no live hold. Last-write-wins, mirroring push-gate's _pg_current.
_steps_current() {
  local slug="$1" ledger; ledger="$(steps_hold_ledger)" || return 0
  [ -f "$ledger" ] || return 0
  local awaiting="" released="" state s sha
  while read -r _ state s sha; do
    [ "$s" = "$slug" ] || continue
    case "$state" in
      awaiting) awaiting="$sha" ;;
      released) released="$sha" ;;
    esac
  done < "$ledger"
  [ -n "$awaiting" ] || return 0
  [ "$released" = "$awaiting" ] && return 0        # released ⇒ the hold is cleared
  printf '%s' "$awaiting"
}

# steps_hold_awaiting_sha <slug> — PUBLIC single-slug probe: the sha this slug currently holds for
# step approval, or empty. herd-approve.sh selects the step-approval path on a non-empty result.
steps_hold_awaiting_sha() { _steps_current "$1"; }

# steps_hold_is_approved <slug> <sha> — 0 iff an approval record exists for this exact sha.
steps_hold_is_approved() {
  local ledger; ledger="$(steps_hold_ledger)" || return 1
  grep -q "^[0-9]* approved $1 $2$" "$ledger" 2>/dev/null
}
# steps_hold_is_released <slug> <sha> — 0 iff a released record exists for this exact sha.
steps_hold_is_released() {
  local ledger; ledger="$(steps_hold_ledger)" || return 1
  grep -q "^[0-9]* released $1 $2$" "$ledger" 2>/dev/null
}

# steps_hold_list — print every LIVE step-hold as: <slug> <sha> <step> <dir>. Skips holds whose latest
# state is released. Used by herd-approve.sh `list`.
steps_hold_list() {
  local ledger; ledger="$(steps_hold_ledger)" || return 0
  [ -f "$ledger" ] || return 0
  local slugs slug sha detail dir step
  slugs="$(awk '{print $3}' "$ledger" 2>/dev/null | awk '!seen[$0]++')"
  while IFS= read -r slug; do
    [ -n "$slug" ] || continue
    sha="$(_steps_current "$slug")" || true
    [ -n "$sha" ] || continue
    dir=""; step=""
    detail="$(steps_hold_detail "$slug")" || true
    if [ -f "$detail" ]; then
      dir="$(sed -n 's/^dir=//p' "$detail" 2>/dev/null | head -1)"
      step="$(sed -n 's/^step=//p' "$detail" 2>/dev/null | head -1)"
    fi
    printf '%s %s %s %s\n' "$slug" "$sha" "${step:-?}" "$dir"
  done <<EOF
$slugs
EOF
}

# _steps_hold_record <slug> <step> <at> <dir> <sha> — record the awaiting hold + its detail file.
# Idempotent: re-recording the same live sha does not append a duplicate 'awaiting'.
_steps_hold_record() {
  local slug="$1" step="$2" at="$3" dir="$4" sha="$5"
  local ledger detail tmp
  ledger="$(steps_hold_ledger)" || { echo "🛑 steps: WORKTREES_DIR unset — cannot record a hold." >&2; return 1; }
  detail="$(steps_hold_detail "$slug")"
  tmp="$detail.tmp.$$"
  {
    printf 'sha=%s\n' "$sha"
    printf 'slug=%s\n' "$slug"
    printf 'step=%s\n' "$step"
    printf 'at=%s\n' "$at"
    printf 'dir=%s\n' "$dir"
  } > "$tmp" 2>/dev/null || { echo "🛑 steps: cannot write hold detail for '$slug'." >&2; return 1; }
  mv -f "$tmp" "$detail" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; echo "🛑 steps: cannot install hold detail for '$slug'." >&2; return 1; }
  # Idempotent + BOUNDED: at most ONE 'awaiting' row per (slug, sha) EVER. Skip the append if an
  # awaiting record for this EXACT sha already exists — whether still live OR already released. A
  # released hold is CONSUMED (terminal for this sha; a new hold needs a new commit ⇒ a new sha), so
  # never re-append after release — that is what keeps the ledger from growing unbounded across the
  # watcher's per-tick re-runs of the pre-merge seam. grep (not _steps_current) so a degenerate empty
  # sha still records on its first hold.
  if grep -q "^[0-9]* awaiting $slug $sha$" "$ledger" 2>/dev/null; then
    return 0
  fi
  printf '%s awaiting %s %s\n' "$(_steps_epoch)" "$slug" "$sha" >> "$ledger" 2>/dev/null \
    || { echo "🛑 steps: cannot append to the step-hold ledger." >&2; return 1; }
  command -v journal_append >/dev/null 2>&1 && journal_append step_hold_awaiting slug "$slug" step "$step" at "$at" sha "$sha" dir "$dir" || true
  return 0
}

# steps_hold_approve <slug> — record a human approval for <slug>'s current awaiting sha. Idempotent.
# Echoes the approved sha (empty + non-zero when there is no live hold).
steps_hold_approve() {
  local slug="$1" sha ledger
  sha="$(_steps_current "$slug")" || true
  [ -n "$sha" ] || { echo "steps: no live step-hold for '$slug' to approve." >&2; return 1; }
  ledger="$(steps_hold_ledger)" || return 1
  if ! steps_hold_is_approved "$slug" "$sha"; then
    printf '%s approved %s %s\n' "$(_steps_epoch)" "$slug" "$sha" >> "$ledger" 2>/dev/null \
      || { echo "steps: cannot record approval for '$slug'." >&2; return 1; }
    command -v journal_append >/dev/null 2>&1 && journal_append step_hold_approved slug "$slug" sha "$sha" || true
  fi
  printf '%s' "$sha"
}

# steps_hold_release <slug> — the RESUME step herd-approve.sh runs after recording approval: verify the
# hold is intact + approved for the CURRENT worktree HEAD, mark it released, then RESUME the pipeline —
# re-running the held step's seam from the step AFTER the held one. FAIL-SOFT: a stale (new-commit),
# corrupt, or unapproved hold refuses LOUDLY and resumes NOTHING. Returns the resumed seam's rc (0 when
# the remaining steps pass or there is no watcher-driven seam to resume).
steps_hold_release() {
  local slug="$1"
  local sha detail step at dir head ledger
  sha="$(_steps_current "$slug")" || true
  if [ -z "$sha" ]; then
    echo "🛑 steps: no live step-hold for '$slug' — nothing to release." >&2
    return 1
  fi
  detail="$(steps_hold_detail "$slug")" || return 1
  if [ ! -f "$detail" ]; then
    echo "🛑 steps: hold record for '$slug' is missing its detail file ($detail) — REFUSING to resume a corrupt hold." >&2
    return 1
  fi
  step="$(sed -n 's/^step=//p' "$detail" | head -1)"
  at="$(sed -n 's/^at=//p' "$detail" | head -1)"
  dir="$(sed -n 's/^dir=//p' "$detail" | head -1)"
  if [ -z "$step" ] || [ -z "$at" ]; then
    echo "🛑 steps: hold record for '$slug' is corrupt (step='$step' at='$at') — REFUSING to resume." >&2
    return 1
  fi
  # Sha invalidation: if the worktree still resolves, HEAD must equal the held/approved sha. A new
  # commit after the hold changes HEAD ⇒ the approval is stale (same semantics as push-gate / merge).
  if [ -n "$dir" ] && [ -d "$dir" ]; then
    head="$(_steps_worktree_sha "$dir")"
    if [ -n "$head" ] && [ "$head" != "$sha" ]; then
      echo "🛑 steps: '$slug' HEAD ($head) no longer matches the held sha ($sha) — a new commit invalidated the approval. Re-run the step and re-approve." >&2
      return 1
    fi
  fi
  if ! steps_hold_is_approved "$slug" "$sha"; then
    echo "🛑 steps: '$slug' (sha $sha) is not approved — run 'herd-approve.sh approve $slug' first." >&2
    return 1
  fi
  ledger="$(steps_hold_ledger)" || return 1
  if ! steps_hold_is_released "$slug" "$sha"; then
    printf '%s released %s %s\n' "$(_steps_epoch)" "$slug" "$sha" >> "$ledger" 2>/dev/null || true
    command -v journal_append >/dev/null 2>&1 && journal_append step_hold_released slug "$slug" step "$step" at "$at" sha "$sha" || true
  fi
  echo "▶️  steps: '$slug' step '$step' approved — resuming the $at pipeline past it…"
  # Resume the remaining steps of that seam (the built-in gates already passed for this stage).
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
    # An approve-hold is idempotent + resumable: check the ledger BEFORE (re-)executing.
    if [ "$hold" = "approve" ] && [ -n "$sha" ]; then
      # RELEASED ⇒ this (slug,sha) hold was approved + CONSUMED: skip past it WITHOUT re-executing or
      # re-recording. This branch — NOT the _steps_current gate below (which is empty once released,
      # steps.sh _steps_current) — is what lets the watcher-owned seam proceed: do_merge re-runs
      # steps_run_at pre-merge from the top every tick with no --resume-after, so the released hold must
      # be recognised here or it re-executes and re-holds forever (the merge never lands).
      if steps_hold_is_released "$slug" "$sha"; then
        continue
      fi
      # Still AWAITING for this exact sha ⇒ HELD, without re-running the step.
      if [ "$(_steps_current "$slug")" = "$sha" ]; then
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
    enabled)  steps_enabled ;;
    file)     steps_file; echo ;;
    *) echo "Usage: steps.sh [run <seam> [--slug S --dir D --sha SHA --resume-after STEP] | validate | list [seam] | holds | approve <slug> | release <slug> | enabled | file]" >&2; exit 1 ;;
  esac
fi
