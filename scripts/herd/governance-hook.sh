#!/usr/bin/env bash
# governance-hook.sh <target> — the SESSION-TIME governance enforcer rendered into a project's
# .claude/settings by `herd governance hooks render` (HERD-131). Invoked by Claude Code as a
# PreToolUse hook: it reads the hook payload on stdin, extracts the Bash tool's command, and enforces
# ONE governance rule at the keyboard — early and cheap — COMPLEMENTING the merge-time watcher gate
# (dual-surface enforcement: a rule binds at both layers, so a violation is caught by whichever fires
# first regardless of origin).
#
# Claude Code PreToolUse contract: stdin is a JSON object with .tool_name and .tool_input.command.
#   exit 0 → allow (a WARN rule prints guidance to stderr but still allows)
#   exit 2 → BLOCK the tool call; stderr is fed back to the model as the reason
# Unknown / unrecognized <target> → fail-OPEN (exit 0): a spec this build does not know must never
# silently block work.
#
# Targets (each rendered from a surface==hook row of templates/governance-map.tsv):
#   pre-commit:no-ai-coauthor  BLOCK a `git commit` whose message carries an AI attribution trailer
#                              (Co-Authored-By: Claude… / Generated with Claude…) — the session-time
#                              sibling of the ATTRIBUTION_POLICY merge-time lint (HERD-121).
#   pre-push:human-gate        WARN before a `git push` — a human review is expected first
#                              (PUSH_GATE=human, HERD-123). Advisory: warns, never blocks.
#   pre-action:run-checks      WARN before a `git commit`/`git push` — run lint/test/format first.
#   pre-action:format          WARN before a `git commit` — format the code first.
set -uo pipefail

target="${1:-}"

# The raw PreToolUse payload. `cat || true` under pipefail keeps an empty/absent stdin a clean no-op.
payload="$(cat 2>/dev/null || true)"

# _gh_command — the Bash tool's command string from the payload. Prefer jq for an exact field read;
# without it, fall back to the raw payload (the substring checks below are robust to the surrounding
# JSON — the command text appears literally in it, and no key name collides with git/trailer markers).
_gh_command() {
  if command -v jq >/dev/null 2>&1; then
    local c
    c="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null)"
    [ -n "$c" ] && { printf '%s' "$c"; return 0; }
  fi
  printf '%s' "$payload"
}

cmd="$(_gh_command)"
lower="$(printf '%s' "$cmd" | tr '[:upper:]' '[:lower:]')"

_is_git_commit() { case "$lower" in *"git "*commit*) return 0 ;; *) return 1 ;; esac; }
_is_git_push()   { case "$lower" in *"git "*push*)   return 0 ;; *) return 1 ;; esac; }

# _has_ai_trailer — the SAME AI-attribution markers the HERD-121 merge-time lint blocks
# (co-authored-by: claude / generated with claude), plus the anthropic no-reply address.
_has_ai_trailer() {
  case "$lower" in
    *"co-authored-by: claude"*|*"generated with claude"*|*"generated with [claude"*|*"noreply@anthropic.com"*)
      return 0 ;;
    *) return 1 ;;
  esac
}

_block() { printf 'herd governance: %s\n' "$1" >&2; exit 2; }
_warn()  { printf 'herd governance: %s\n' "$1" >&2; exit 0; }

case "$target" in
  pre-commit:no-ai-coauthor)
    if _is_git_commit && _has_ai_trailer; then
      _block "blocked — this commit message carries an AI attribution trailer (ATTRIBUTION_POLICY=no-ai-coauthor). Remove the Co-Authored-By / Generated-with line before committing."
    fi
    ;;
  pre-push:human-gate)
    if _is_git_push; then
      _warn "PUSH_GATE=human — a human review is expected before this push lands. From a builder worktree, hold for review via push-gate.sh instead of pushing directly."
    fi
    ;;
  pre-action:run-checks)
    if _is_git_commit || _is_git_push; then
      _warn "run the project checks (lint / test / format) before committing or pushing."
    fi
    ;;
  pre-action:format)
    if _is_git_commit; then
      _warn "format the code before committing."
    fi
    ;;
  *) : ;;   # unknown target → fail-open (never block on a spec this build does not recognize)
esac

exit 0
