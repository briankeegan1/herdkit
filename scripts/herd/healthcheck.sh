#!/usr/bin/env bash
# healthcheck.sh <worktree-dir> [--oneline] [--heavy|--light|--auto] — is the change clean?
#
# Two profiles, auto-selected from what the worktree's diff (vs the default branch) touches —
# so a one-line script tweak isn't forced through the project's full (possibly slow) gate:
#
#   • heavy — run the PROJECT health command ($HEALTHCHECK_CMD from .herd/config), invoked as
#       $HEALTHCHECK_CMD <worktree-dir> [--oneline].  It owns the project-specific notion of
#       "healthy" (boot a server, run the test suite, shellcheck + bats, …) and MUST exit:
#         0 = clean (or only a tolerated data/env issue)
#         1 = a real CODE error
#         2 = a data/env issue (tolerated — treated as clean, surfaced as a ⚠️)
#   • light — no project command: per-changed-file syntax only (bash -n / py_compile / gofmt -e).
#       Fast. Source types it has NO dependency-free probe for (.rs/.java/.ts/…) are never silently
#       green-lit — they are flagged-the-absence with a loud ⚠️ (like the interaction gate), so a
#       diff that only touches an unprobed language reads as ⚠️, never a confident ✅.
#
# Profile selection (auto):
#   * no $HEALTHCHECK_CMD configured        → always light (pure syntax gate)
#   * $HEALTHCHECK_HEAVY_GLOB set + matches → heavy;  set + no match → light
#   * $HEALTHCHECK_HEAVY_GLOB empty + a cmd → always heavy (e.g. a project with no "app" axis)
#   * can't tell what changed                → heavy (the thorough side)
#
# --heavy / --light force a profile; --auto (default) detects from the diff. Shared by
# herd-feature.sh, herd-quick.sh, and used by agent-watch.sh as the pre-merge gate (--oneline by
# app-monitor.sh for the live status pane).
#
# ── Interaction gate (framework-generic; layered on top of either profile) ────────────────────
# A render smoke ("does the app boot / render?") is blind to broken interactivity: a widget whose
# value no longer affects output still renders clean and passes. Two OPTIONAL .herd/config keys
# let a project close that gap WITHOUT the engine hardcoding any UI framework:
#   • APP_SURFACE_GLOB     — egrep of diff paths that constitute the app surface (e.g. '^app/').
#                            EMPTY (default) → the gate is OFF entirely: zero behavior change for
#                            every existing project.
#   • INTERACTION_TEST_CMD — project command that DRIVES a widget/input and asserts the dependent
#                            output actually changed (e.g. a UI test harness: set an input, re-run,
#                            assert the dependent output moved). Invoked as
#                            $INTERACTION_TEST_CMD <worktree-dir> [--oneline]; same exit contract
#                            as HEALTHCHECK_CMD — 0 clean · 1 code error · 2 data/env (tolerated).
# When the diff touches APP_SURFACE_GLOB:
#   · INTERACTION_TEST_CMD set   → run it and GATE (a code error blocks the merge, like the heavy
#                                  profile; exit 2 is tolerated as a data/env ⚠️).
#   · INTERACTION_TEST_CMD empty → emit a loud one-line WARNING (flag-the-absence, never red): the
#                                  render smoke cannot see widget→output causality, so the PR gate
#                                  trail records the gap instead of silently green-lighting it.
# The gate is keyed on APP_SURFACE_GLOB alone — independent of the heavy/light HEALTHCHECK_HEAVY_GLOB.
#
# Exit: 0 = clean (or only data/env issues) · 1 = real code error.
set -u
DIR=""
ONELINE=""
MODE="auto"
for a in "$@"; do
  case "$a" in
    --oneline) ONELINE=1 ;;
    --heavy|--app)   MODE="heavy" ;;
    --light)   MODE="light" ;;
    --auto)    MODE="auto" ;;
    -*) echo "❌ unknown flag: $a (usage: healthcheck.sh <dir> [--oneline] [--heavy|--light|--auto])"; exit 1 ;;
    *)  [ -z "$DIR" ] && DIR="$a" ;;
  esac
done
[ -n "$DIR" ] || { echo "usage: healthcheck.sh <worktree-dir> [--oneline] [--heavy|--light|--auto]"; exit 1; }
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/herd-config.sh"
. "$HERE/commit-lint.sh"
cd "$DIR" 2>/dev/null || { echo "❌ no such dir: $DIR"; exit 1; }
PY="$(command -v python3 || true)"

# Everything this worktree changes vs the default branch: committed+uncommitted (diff) plus
# brand-new untracked files (a freshly added script wouldn't show in `git diff` yet). Paths are
# repo-root-relative, so the heavy glob (e.g. '^app/') cleanly means "touches the heavy path".
_changed_files() {
  {
    git diff --name-only "$DEFAULT_BRANCH" 2>/dev/null \
      || git diff --name-only "$HERD_BRANCH_NAME" 2>/dev/null
    git ls-files --others --exclude-standard 2>/dev/null
  } | sort -u
}

# ── resolve the profile ──────────────────────────────────────────────────────
if [ "$MODE" = "auto" ]; then
  if [ -z "$HEALTHCHECK_CMD" ]; then
    MODE="light"                       # no project command → syntax-only gate
  else
    changed="$(_changed_files)"
    if [ -z "$changed" ]; then
      MODE="heavy"                     # can't tell what changed → thorough
    elif [ -z "$HEALTHCHECK_HEAVY_GLOB" ]; then
      MODE="heavy"                     # no "app" axis → every change is heavy
    elif printf '%s\n' "$changed" | grep -qE "$HEALTHCHECK_HEAVY_GLOB"; then
      MODE="heavy"
    else
      MODE="light"
    fi
  fi
fi

# ── heavy profile: delegate to the project health command ────────────────────
run_heavy() {
  if [ -z "$HEALTHCHECK_CMD" ]; then run_light; return; fi
  # Resolve the command relative to the worktree (it's a committed project file).
  local out rc
  if [ -n "$ONELINE" ]; then
    out="$(bash -c "cd '$DIR' && $HEALTHCHECK_CMD '$DIR' --oneline" 2>&1)"; rc=$?
  else
    out="$(bash -c "cd '$DIR' && $HEALTHCHECK_CMD '$DIR'" 2>&1)"; rc=$?
  fi
  local last; last="$(printf '%s' "$out" | tail -1)"
  case "$rc" in
    0) if [ -n "$ONELINE" ]; then echo "✅ clean — $last"; else echo "✅ HEALTHCHECK CLEAN"; printf '%s\n' "$out"; fi; exit 0 ;;
    1) if [ -n "$ONELINE" ]; then echo "❌ code error — $last"; else echo "❌ CODE ERROR"; printf '%s\n' "$out"; fi; exit 1 ;;
    *) if [ -n "$ONELINE" ]; then echo "⚠️  data/env (not a code bug) — $last"; else echo "⚠️  DATA/ENV ISSUE (tolerated, not a code bug)"; printf '%s\n' "$out"; fi; exit 0 ;;
  esac
}

# ── light profile: per-changed-file syntax ───────────────────────────────────
# Recognized source types get a syntax-only probe that needs NO project deps — a lone file parses
# or it doesn't: bash -n (*.sh), py_compile (*.py), gofmt -e (*.go, a pure Go parser that ships with
# the toolchain). Source types we have no dependency-free probe for (.rs/.java/.ts/…) are NOT
# silently green: they are flagged-the-absence with a loud ⚠️ and folded into the summary, so a diff
# that only touches an unprobed language never reads as a confident ✅ (Leak B, external-consumer
# audit). A missing toolchain (e.g. no gofmt) is a data/env ⚠️ — never red. Non-source files (docs,
# JSON, config) are ignored exactly as before. Only a REAL parse/syntax error is red (exit 1).
run_light() {
  changed="$(_changed_files)"
  sh=(); py=(); go=(); unchecked=()
  while IFS= read -r f; do
    [ -n "$f" ] && [ -f "$f" ] || continue
    case "$f" in
      *.sh) sh+=("$f") ;;
      *.py) py+=("$f") ;;
      *.go) go+=("$f") ;;
      # Source types with no dependency-free syntax probe here — a real compile would need the
      # project's deps/toolchain, so we flag their presence rather than risk a false red or a false
      # green. Extend this list (and add a probe above) as safe single-file checks become available.
      *.rs|*.java|*.ts|*.tsx|*.js|*.jsx|*.mjs|*.cjs|*.rb|*.c|*.h|*.cc|*.cpp|*.cxx|*.hpp|*.hh|*.cs|*.kt|*.kts|*.swift|*.php|*.scala|*.m|*.mm|*.pl|*.lua|*.dart|*.ex|*.exs|*.clj|*.hs)
        unchecked+=("$f") ;;
    esac
  done <<EOF
$changed
EOF

  syntax_errs=""
  for f in "${sh[@]:-}"; do
    [ -n "$f" ] || continue
    err="$(bash -n "$f" 2>&1)" || syntax_errs="${syntax_errs}bash -n $f → $(printf '%s' "$err" | tail -1)"$'\n'
  done
  if [ -n "$PY" ]; then
    for f in "${py[@]:-}"; do
      [ -n "$f" ] || continue
      err="$("$PY" -m py_compile "$f" 2>&1)" || syntax_errs="${syntax_errs}py_compile $f → $(printf '%s' "$err" | tail -1)"$'\n'
    done
  fi

  # Go: gofmt -e is a pure parser (no build, no deps) and ships with the Go toolchain. Present →
  # probe and red only on a REAL parse error. Absent → the *.go files are unchecked-for-lack-of-
  # toolchain, a data/env ⚠️ (never red), and never a confident clean.
  ngo=${#go[@]}; gofmt_missing=0
  if [ "$ngo" -gt 0 ]; then
    if command -v gofmt >/dev/null 2>&1; then
      for f in "${go[@]:-}"; do
        [ -n "$f" ] || continue
        err="$(gofmt -e "$f" 2>&1 >/dev/null)" || syntax_errs="${syntax_errs}gofmt -e $f → $(printf '%s' "$err" | tail -1)"$'\n'
      done
    else
      gofmt_missing=1
    fi
  fi

  if [ -n "$syntax_errs" ]; then
    if [ -n "$ONELINE" ]; then echo "❌ light syntax — $(printf '%s' "$syntax_errs" | head -1)";
    else echo "❌ LIGHT CHECK: SYNTAX ERROR"; printf '%s' "$syntax_errs"; fi
    exit 1
  fi

  nsh=${#sh[@]}; npy=${#py[@]}; nun=${#unchecked[@]}
  # Per-language breakdown of the unchecked files (bash 3.2 has no assoc arrays → derive with sort):
  # e.g. "2 rs, 1 java". Deterministic (alphabetical) so the summary line is stable.
  unchecked_summary=""
  if [ "$nun" -gt 0 ]; then
    unchecked_summary="$(printf '%s\n' "${unchecked[@]:-}" | sed -e '/^$/d' -e 's/.*\.//' \
      | sort | uniq -c | awk '{printf "%s%d %s", (NR>1?", ":""), $1, $2}')"
  fi

  # A "gap" is anything that stops this from being a confident clean: an unprobed language, or a
  # probe we could not run (missing toolchain). Either flips the verdict to a loud ⚠️ — exit 0
  # (a warning, like the interaction gate), never red, never a silent ✅.
  gap=0
  [ "$nun" -gt 0 ] && gap=1
  [ "$gofmt_missing" -eq 1 ] && gap=1

  if [ -n "$ONELINE" ]; then
    if [ "$gap" -eq 1 ]; then
      msg="⚠️  light: ${nsh} sh, ${npy} py"
      [ "$ngo" -gt 0 ] && [ "$gofmt_missing" -eq 0 ] && msg="$msg, ${ngo} go"
      msg="$msg ok"
      [ "$nun" -gt 0 ] && msg="$msg · unchecked: ${unchecked_summary} (no light probe)"
      [ "$gofmt_missing" -eq 1 ] && msg="$msg · ${ngo} go unchecked (gofmt not found — data/env)"
      echo "$msg"
    elif [ "$ngo" -gt 0 ]; then
      echo "✅ light clean — ${nsh} sh, ${npy} py, ${ngo} go ok"
    else
      echo "✅ light clean — ${nsh} sh, ${npy} py ok"
    fi
    exit 0
  fi

  if [ "$gap" -eq 1 ]; then
    echo "⚠️  LIGHT CHECK: UNCHECKED FILE TYPES (flagged, not a confident clean)"
  else
    echo "✅ LIGHT CHECK CLEAN (non-heavy change)"
  fi
  echo "   shell:  ${nsh} changed *.sh — bash -n ok"
  echo "   python: ${npy} changed *.py — py_compile ok"
  [ "$ngo" -gt 0 ] && [ "$gofmt_missing" -eq 0 ] && echo "   go:     ${ngo} changed *.go — gofmt -e ok"
  [ "$gofmt_missing" -eq 1 ] && echo "   ⚠️  go: gofmt not found — ${ngo} changed *.go unchecked (data/env, not a code error)"
  [ "$nun" -gt 0 ] && echo "   ⚠️  unchecked: ${unchecked_summary} files (no light probe) — flagged, never green-lit"
  exit 0
}

# ── attribution lint: scan PR commits for AI co-author markers (HERD-121) ──────────────────────
# Keyed on ATTRIBUTION_POLICY (independent of the heavy/light profile and the interaction gate). Sets:
#   AL_STATE  = DISABLED | CLEAN | CODEERROR
#   AL_REASON = first offending "sha:line" (empty when not CODEERROR)
#   AL_FULL   = all offending "sha:line" pairs, newline-separated (empty unless CODEERROR)
AL_STATE="DISABLED"; AL_REASON=""; AL_FULL=""
run_attribution_lint() {
  case "${ATTRIBUTION_POLICY:-}" in
    no-ai-coauthor) ;;
    *) return 0 ;;   # off (default "") or unknown value → zero behavior change
  esac
  local _al_violations
  _al_violations="$(_herd_attr_scan "$DEFAULT_BRANCH")"
  if [ -z "$_al_violations" ]; then
    AL_STATE="CLEAN"
    return 0
  fi
  AL_STATE="CODEERROR"
  AL_REASON="$(printf '%s' "$_al_violations" | head -1)"
  AL_FULL="$_al_violations"
}

# ── interaction gate: run INTERACTION_TEST_CMD, or flag its absence, for app-surface PRs ──────
# Keyed on APP_SURFACE_GLOB (independent of the heavy/light profile). Sets:
#   IG_STATE  = DISABLED | WARN | CLEAN | DATAENV | CODEERROR
#   IG_REASON = one-line reason (tail of the command output; the fixed warning text for WARN)
#   IG_FULL   = full command output (empty unless the command actually ran)
IG_STATE="DISABLED"; IG_REASON=""; IG_FULL=""
run_interaction_gate() {
  [ -n "$APP_SURFACE_GLOB" ] || return 0            # feature off → zero behavior change
  local changed; changed="$(_changed_files)"
  [ -n "$changed" ] || return 0                     # nothing changed to compare → nothing to gate
  printf '%s\n' "$changed" | grep -qE "$APP_SURFACE_GLOB" || return 0   # diff misses the app surface

  if [ -z "$INTERACTION_TEST_CMD" ]; then           # app-surface PR, but no interaction tests declared
    IG_STATE="WARN"
    IG_REASON="app-surface PR with no interaction tests declared — render smoke cannot see widget→output causality"
    return 0
  fi

  local out rc
  if [ -n "$ONELINE" ]; then
    out="$(bash -c "cd '$DIR' && $INTERACTION_TEST_CMD '$DIR' --oneline" 2>&1)"; rc=$?
  else
    out="$(bash -c "cd '$DIR' && $INTERACTION_TEST_CMD '$DIR'" 2>&1)"; rc=$?
  fi
  IG_FULL="$out"; IG_REASON="$(printf '%s' "$out" | tail -1)"
  case "$rc" in
    0) IG_STATE="CLEAN" ;;
    1) IG_STATE="CODEERROR" ;;
    *) IG_STATE="DATAENV" ;;
  esac
}

# ── run the selected profile, then fold the interaction gate into one verdict ─────────────────
# run_heavy/run_light print their verdict and exit; capture both inside a command substitution so
# a single coherent healthcheck result can layer the interaction gate on top. (Wrapped in a
# function because bash 3.2 mis-parses a `case`'s `)` inside `$( … )`.)
run_profile() {
  case "$MODE" in
    heavy) run_heavy ;;
    light) run_light ;;
  esac
}
MAIN_OUT="$(run_profile)"; MAIN_RC=$?

run_interaction_gate
run_attribution_lint

# Combined exit: a real CODE error on ANY gate blocks the merge.
RC=0
[ "$MAIN_RC" -eq 1 ] && RC=1
[ "$IG_STATE" = "CODEERROR" ] && RC=1
[ "$AL_STATE" = "CODEERROR" ] && RC=1

if [ -n "$ONELINE" ]; then
  # Exactly ONE line — the watcher paints healthcheck --oneline as a single status row.
  if [ "$RC" -eq 1 ]; then
    if [ "$MAIN_RC" -eq 1 ]; then printf '%s\n' "$MAIN_OUT"
    elif [ "$IG_STATE" = "CODEERROR" ]; then printf '❌ interaction — %s\n' "$IG_REASON"
    else printf '❌ attribution — %s\n' "$AL_REASON"; fi
  else
    case "$IG_STATE" in
      WARN)    printf '⚠️  %s\n' "$IG_REASON" ;;
      DATAENV) printf '⚠️  interaction data/env (not a code bug) — %s\n' "$IG_REASON" ;;
      *)       printf '%s\n' "$MAIN_OUT" ;;
    esac
  fi
  exit "$RC"
fi

# Full mode: the profile's verdict, then the interaction-gate section, then the attribution lint.
printf '%s\n' "$MAIN_OUT"
case "$IG_STATE" in
  DISABLED) : ;;
  CLEAN)     printf '✅ INTERACTION TESTS CLEAN — %s\n' "$IG_REASON" ;;
  WARN)      printf '⚠️  INTERACTION TESTS: %s\n' "$IG_REASON" ;;
  DATAENV)   printf '⚠️  INTERACTION TESTS: data/env (not a code bug) — %s\n' "$IG_REASON"
             [ -n "$IG_FULL" ] && printf '%s\n' "$IG_FULL" ;;
  CODEERROR) printf '❌ INTERACTION TESTS FAILED — %s\n' "$IG_REASON"
             [ -n "$IG_FULL" ] && printf '%s\n' "$IG_FULL" ;;
esac
case "$AL_STATE" in
  DISABLED) : ;;
  CLEAN)    printf '✅ ATTRIBUTION LINT CLEAN\n' ;;
  CODEERROR) printf '❌ ATTRIBUTION LINT: AI co-author marker found\n'
             [ -n "$AL_FULL" ] && printf '%s\n' "$AL_FULL" ;;
esac
exit "$RC"
