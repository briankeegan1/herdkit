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
#       BASELINE-AWARE (HERD-190): a heavy code error whose failing tests ALL already fail on the base
#       (origin/main) is INHERITED — surfaced as a tolerated ⚠️, not blocked — so a fix-PR never
#       deadlocks on a base failure it did not introduce. See the baseline-aware gate section below;
#       byte-identical when the base is green, fully fail-soft, and only ever downgrades (never reds).
#   • light — no project command: per-changed-file syntax only (bash -n / py_compile / gofmt -e).
#       Fast. Source types it has NO dependency-free probe for (.rs/.java/.ts/…) are never silently
#       green-lit — they are flagged-the-absence with a loud ⚠️ (like the interaction gate), so a
#       diff that only touches an unprobed language reads as ⚠️, never a confident ✅.
#       After the syntax pass it also runs the SHARED caps-sync guard (scripts/herd/caps-sync-lint.sh,
#       HERD-220) — the same lint the heavy project gate runs — so a builder whose change grows the
#       capability surface without touching templates/capabilities.tsv sees the red here, pre-PR,
#       instead of bouncing off the merge gate. Skipped in trees with no manifest (every consumer).
#       Then the SHARED doc-drift guard (scripts/herd/doc-drift-lint.sh, HERD-168) — README.md +
#       docs/*.md must not reference a herd command (or a README CONFIG_KEY) absent from the
#       capabilities manifest. Docs-only diffs run light under HEALTHCHECK_HEAVY_GLOB, so this is
#       the pre-PR gate that catches doc drift (the heavy suite also wraps tests/test-doc-drift.sh).
#
# Profile selection (auto):
#   * no $HEALTHCHECK_CMD configured        → always light (pure syntax gate)
#   * $HEALTHCHECK_HEAVY_GLOB set + matches → heavy;  set + no match → light
#   * $HEALTHCHECK_HEAVY_GLOB empty + a cmd → always heavy (e.g. a project with no "app" axis)
#   * $HEALTHCHECK_HEAVY_GLOB is an INVALID regex → LOUD warning + heavy (never silently under-gate)
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
# Fail-soft on our own infra: a partially-upgraded engine tree missing the lint must SKIP the
# caps-sync guard (rc 2), never break the healthcheck it is a part of.
if [ -f "$HERE/caps-sync-lint.sh" ]; then
  . "$HERE/caps-sync-lint.sh"
else
  HERD_CAPS_SYNC_SKIP_REASON="caps-sync-lint.sh not present"
  herd_caps_sync_lint() { return 2; }
fi
# Fail-soft on our own infra: a partially-upgraded engine tree missing the lint must SKIP the
# doc-drift guard (rc 2), never break the healthcheck it is a part of.
if [ -f "$HERE/doc-drift-lint.sh" ]; then
  . "$HERE/doc-drift-lint.sh"
else
  HERD_DOC_DRIFT_SKIP_REASON="doc-drift-lint.sh not present"
  herd_doc_drift_lint() { return 2; }
fi
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

# ── baseline-aware gate (HERD-190) ────────────────────────────────────────────
# The heavy gate evaluates the worktree's ABSOLUTE pass/fail. When the base (origin/main) itself
# carries known-failing tests — landed by an ungated merge — a PR that merely INHERITS one of them
# fails the full-suite gate on a bug it did not introduce, and two such fix-PRs can DEADLOCK on each
# other's inherited failure (proven live 2026-07-08). Fix: when a heavy run is a CODE error, compute
# the base's known-failure set and let only INTRODUCED failures (present in the PR, absent in the
# base) block. A failure set entirely contained in the base is inherited → surfaced, not blocking.
#
# Conventions honored: FAIL-SOFT (any inability to resolve/parse the base → today's behavior, block)
# and BYTE-IDENTICAL when the base is green (an empty base known-failure set means every PR failure
# is introduced → the verdict + output are exactly the pre-HERD-190 code error). Only ever DOWNGRADES
# a red to a tolerated ⚠️; it can never turn a green into a red, and never masks an introduced failure.
#
# Scope: the GATING (full, non --oneline) path only — the --oneline status pane emits one summary line
# with no TAP to diff, and it does not gate merges. The base suite runs at most once per red PR and is
# cached by base sha (HERD_BASELINE_CACHE), so the two-fix-PR deadlock reuses one base run.
#   HERD_BASELINE_DIR   — optional existing base (origin/main) checkout to run the base suite in; the
#                         watcher passes $MAIN so no throwaway worktree is created. Absent → a detached
#                         worktree of $DEFAULT_BRANCH is added + removed (fail-soft if that is refused).
#   HERD_BASELINE_CACHE — optional dir for the sha-keyed base known-failure cache (watcher passes $TREES).

# _baseline_aware_enabled — the feature is on (BASELINE_AWARE_GATE, default "on") AND this is the
# gating full-mode run. Any unrecognized value reads as off (fail toward the classic absolute gate).
_baseline_aware_enabled() {
  [ -z "$ONELINE" ] || return 1
  case "$(printf '%s' "${BASELINE_AWARE_GATE:-on}" | tr '[:upper:]' '[:lower:]')" in
    1|true|on|yes|enable|enabled) return 0 ;;
    *) return 1 ;;
  esac
}

# _baseline_notok_set <suite-output> — the set of FAILING test identities in a bats/TAP suite output:
# the description after 'not ok N ', sorted-unique. The leading 'not ok <N>' NUMBER is stripped on
# purpose — a fix-PR that adds/removes a test renumbers the plan, so comparing by number would read an
# unchanged inherited failure as introduced. Empty when the output carries no TAP 'not ok' (a non-bats
# suite, or a suite that passed) → the caller then treats the base as green and blocks (byte-identical).
_baseline_notok_set() {
  printf '%s\n' "$1" | sed -n -E 's/^not ok[[:space:]]*[0-9]*[[:space:]]*//p' \
    | sed -e 's/[[:space:]]*$//' | sort -u
}

# _baseline_all_inherited <pr-set> <base-set> — return 0 IFF the PR has ≥1 failing test AND every one
# of them is also in the base's known-failure set (introduced set empty). Both args are newline sets
# from _baseline_notok_set (already sorted-unique, so comm's sort precondition holds). An empty PR set
# (nothing to subtract) or an empty base set (base green → all introduced) returns 1 (block).
_baseline_all_inherited() {
  [ -n "$1" ] && [ -n "$2" ] || return 1
  [ -z "$(comm -23 <(printf '%s\n' "$1") <(printf '%s\n' "$2"))" ]
}

# _baseline_base_set — the base (origin/main) known-failure set, printed as a sorted-unique newline
# set (empty = base green / unresolvable → caller blocks). Resolves a base checkout (an explicit
# HERD_BASELINE_DIR, else a throwaway detached worktree of $DEFAULT_BRANCH), runs the SAME heavy suite
# there in FULL mode, and caches the extracted set by base sha. Fail-soft throughout: any git/worktree
# failure yields the empty set, which routes the caller to the classic absolute (blocking) verdict.
_baseline_base_set() {
  local _bl_dir="" _bl_created="" _bl_base_sha _bl_pr_sha _bl_cache_dir _bl_cache _bl_out _bl_set _bl_tmp
  if [ -n "${HERD_BASELINE_DIR:-}" ] && [ -d "$HERD_BASELINE_DIR" ] \
     && _bl_base_sha="$(git -C "$HERD_BASELINE_DIR" rev-parse HEAD 2>/dev/null)" && [ -n "$_bl_base_sha" ]; then
    _bl_dir="$HERD_BASELINE_DIR"
  else
    _bl_base_sha="$(git -C "$DIR" rev-parse "$DEFAULT_BRANCH" 2>/dev/null || true)"
    [ -n "$_bl_base_sha" ] || return 0                       # base ref unresolvable → empty set (block)
    _bl_tmp="$(mktemp -d 2>/dev/null || true)"
    [ -n "$_bl_tmp" ] || return 0
    _bl_dir="$_bl_tmp/base"
    if ! git -C "$DIR" worktree add --detach "$_bl_dir" "$_bl_base_sha" >/dev/null 2>&1; then
      rm -rf "$_bl_tmp" 2>/dev/null || true
      return 0                                                # base checkout refused → empty set (block)
    fi
    _bl_created="$_bl_tmp"
  fi

  # Self-comparison guard: if the worktree IS the base commit, nothing could have been introduced —
  # but an empty/degenerate PR is not the deadlock this fixes, so fall back to the classic verdict.
  _bl_pr_sha="$(git -C "$DIR" rev-parse HEAD 2>/dev/null || true)"
  if [ -n "$_bl_pr_sha" ] && [ "$_bl_pr_sha" = "$_bl_base_sha" ]; then
    [ -n "$_bl_created" ] && { git -C "$DIR" worktree remove --force "$_bl_dir" >/dev/null 2>&1 || true; rm -rf "$_bl_created" 2>/dev/null || true; }
    return 0
  fi

  _bl_cache_dir="${HERD_BASELINE_CACHE:-${TMPDIR:-/tmp}}"
  _bl_cache="$_bl_cache_dir/.herd-baseline-notok-$_bl_base_sha"
  if [ -f "$_bl_cache" ]; then
    cat "$_bl_cache" 2>/dev/null || true
    [ -n "$_bl_created" ] && { git -C "$DIR" worktree remove --force "$_bl_dir" >/dev/null 2>&1 || true; rm -rf "$_bl_created" 2>/dev/null || true; }
    return 0
  fi

  # Run the base suite in FULL mode (TAP), extract + cache its known-failure set. A tolerated data/env
  # (⚠️, rc 2) or clean (rc 0) base simply yields no 'not ok' lines → an empty set (base green).
  _bl_out="$(bash -c "cd '$_bl_dir' && $HEALTHCHECK_CMD '$_bl_dir'" 2>&1)"
  _bl_set="$(_baseline_notok_set "$_bl_out")"
  printf '%s\n' "$_bl_set" > "$_bl_cache" 2>/dev/null || true
  [ -n "$_bl_created" ] && { git -C "$DIR" worktree remove --force "$_bl_dir" >/dev/null 2>&1 || true; rm -rf "$_bl_created" 2>/dev/null || true; }
  printf '%s\n' "$_bl_set"
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
    else
      # Validate the glob up front, exactly as the commit-convention lint validates COMMIT_CONVENTION
      # (see run_commit_convention_lint below): probe the pattern against empty input — a VALID egrep
      # yields no match (exit 1), an INVALID one makes grep exit ≥2. An invalid glob must NOT silently
      # route to LIGHT: the bucketing `grep -qE` below would itself error ≥2 (read by `-q` as "no
      # match" → light), UNDER-gating a change on a broken operator glob. Instead fail LOUD toward
      # HEAVY (the thorough side) so a malformed HEALTHCHECK_HEAVY_GLOB can never weaken the gate.
      grep -qE "$HEALTHCHECK_HEAVY_GLOB" </dev/null 2>/dev/null
      if [ "$?" -ge 2 ]; then
        echo "⚠️  invalid HEALTHCHECK_HEAVY_GLOB regex (routing to HEAVY): $HEALTHCHECK_HEAVY_GLOB" >&2
        MODE="heavy"
      elif printf '%s\n' "$changed" | grep -qE "$HEALTHCHECK_HEAVY_GLOB"; then
        MODE="heavy"
      else
        MODE="light"
      fi
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
  # BASELINE-AWARE GATE (HERD-190): a CODE error whose failing tests ALL already fail on the base
  # (origin/main) is INHERITED, not introduced by this change — surface it as a tolerated ⚠️ (exit 0)
  # instead of blocking. Byte-identical when the base is green (empty base set → all failures counted
  # as introduced → the classic code error below runs unchanged). Fail-soft: an unresolvable/unparseable
  # base yields an empty set and blocks exactly as before.
  if [ "$rc" -eq 1 ] && _baseline_aware_enabled; then
    local _pr_set _base_set _pr_n
    _pr_set="$(_baseline_notok_set "$out")"
    if [ -n "$_pr_set" ]; then
      _base_set="$(_baseline_base_set)"
      if _baseline_all_inherited "$_pr_set" "$_base_set"; then
        _pr_n="$(printf '%s\n' "$_pr_set" | grep -c .)"
        echo "⚠️  INHERITED BASE FAILURE(S) — ${_pr_n} failing test(s) already fail on ${DEFAULT_BRANCH}; NOT introduced by this change (tolerated, not a code bug)"
        printf '%s\n' "$out"
        exit 0
      fi
    fi
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

  # caps-sync guard (HERD-220) — the SAME lint the heavy project gate runs (scripts/herd/caps-sync-lint.sh),
  # so a manifest miss is caught here, pre-PR, instead of bouncing at the authoritative merge gate.
  # Same red semantics as the syntax pass (exit 1). Skipped (silently, never red) in any tree with no
  # capabilities manifest — i.e. every consuming project — so the light verdict stays byte-identical
  # for a diff that touches no engine surface.
  local caps_errs caps_rc
  caps_errs="$(herd_caps_sync_lint "$DEFAULT_BRANCH")"; caps_rc=$?
  if [ "$caps_rc" -eq 1 ]; then
    if [ -n "$ONELINE" ]; then echo "❌ caps-sync — $(printf '%s' "$caps_errs" | head -1)";
    else echo "❌ CAPS-SYNC: capabilities manifest not updated alongside engine change"; printf '%s\n' "$caps_errs"; fi
    exit 1
  fi

  # doc-drift guard (HERD-168 / HERD-96) — README.md + docs/*.md must not reference a `herd <subcommand>`
  # (or a README CONFIG_KEY) absent from templates/capabilities.tsv. Docs-only diffs run this LIGHT
  # profile under HEALTHCHECK_HEAVY_GLOB, so this is the gate that actually catches doc drift pre-PR
  # (the heavy suite also wraps tests/test-doc-drift.sh via herd.bats). Same red semantics as
  # caps-sync. Skipped (never red) when the shared lint is absent or the tree has no manifest/docs.
  local drift_errs drift_rc
  drift_errs="$(herd_doc_drift_lint ".")"; drift_rc=$?
  if [ "$drift_rc" -eq 1 ]; then
    if [ -n "$ONELINE" ]; then echo "❌ doc-drift — $(printf '%s' "$drift_errs" | grep '^DRIFT' | head -1)";
    else echo "❌ DOC-DRIFT: README/docs reference a command (or README key) absent from capabilities.tsv"; printf '%s\n' "$drift_errs" | grep '^DRIFT' || printf '%s\n' "$drift_errs"; fi
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
#   AL_STATE  = DISABLED | CLEAN | WARN | CODEERROR
#   AL_REASON = first offending "sha:line" (CODEERROR); the fixed warning text (WARN)
#   AL_FULL   = all offending "sha:line" pairs, newline-separated (empty unless CODEERROR)
# HERD-159: unknown NON-EMPTY values WARN (like COMMIT_CONVENTION's invalid-regex path) instead of
# silently disabling the lint — a typo (ATTRIBUTION_POLICY=no-ai-co-author) must never ride the off
# path unnoticed. Empty/unset remains the intentional off switch (byte-identical, no warn).
AL_STATE="DISABLED"; AL_REASON=""; AL_FULL=""
run_attribution_lint() {
  case "${ATTRIBUTION_POLICY:-}" in
    no-ai-coauthor) ;;
    '') return 0 ;;   # off (default "") → zero behavior change
    *)
      # Non-empty unrecognized value → WARN and skip (mirrors COMMIT_CONVENTION invalid regex).
      AL_STATE="WARN"
      AL_REASON="invalid ATTRIBUTION_POLICY (lint skipped): $ATTRIBUTION_POLICY"
      return 0
      ;;
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

# ── commit-convention lint: every PR commit subject must match COMMIT_CONVENTION (HERD-124) ──────
# Keyed on COMMIT_CONVENTION (an egrep pattern; independent of the heavy/light profile and the other
# gates). Default '' → the lint never runs and output is byte-identical. Every commit subject on
# <DEFAULT_BRANCH>..HEAD must match the pattern; a non-matching subject is a code-error naming the
# sha + subject + pattern. Fail-soft: an INVALID regex warns and skips the lint (never a false red).
# Sets:
#   CC_STATE  = DISABLED | CLEAN | WARN | CODEERROR
#   CC_REASON = first offending "sha:subject" (CODEERROR); the fixed warning text (WARN)
#   CC_FULL   = all offending "sha:subject" pairs, newline-separated (empty unless CODEERROR)
CC_STATE="DISABLED"; CC_REASON=""; CC_FULL=""
run_commit_convention_lint() {
  local _cc_pat="${COMMIT_CONVENTION:-}"
  [ -n "$_cc_pat" ] || return 0     # off (default "") → zero behavior change
  # Fail-soft regex validation: probe the pattern against empty input. A VALID egrep yields no match
  # (exit 1); an INVALID one makes grep exit ≥2. Never red on a bad pattern — warn and skip.
  grep -qE "$_cc_pat" </dev/null 2>/dev/null
  if [ "$?" -ge 2 ]; then
    CC_STATE="WARN"
    CC_REASON="invalid COMMIT_CONVENTION regex (lint skipped): $_cc_pat"
    return 0
  fi
  local _cc_violations
  _cc_violations="$(_herd_commit_convention_scan "$DEFAULT_BRANCH" "$_cc_pat")"
  if [ -z "$_cc_violations" ]; then
    CC_STATE="CLEAN"
    return 0
  fi
  CC_STATE="CODEERROR"
  CC_REASON="$(printf '%s' "$_cc_violations" | head -1)"
  CC_FULL="$_cc_violations"
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
run_commit_convention_lint

# Combined exit: a real CODE error on ANY gate blocks the merge.
RC=0
[ "$MAIN_RC" -eq 1 ] && RC=1
[ "$IG_STATE" = "CODEERROR" ] && RC=1
[ "$AL_STATE" = "CODEERROR" ] && RC=1
[ "$CC_STATE" = "CODEERROR" ] && RC=1

if [ -n "$ONELINE" ]; then
  # Exactly ONE line — the watcher paints healthcheck --oneline as a single status row.
  if [ "$RC" -eq 1 ]; then
    if [ "$MAIN_RC" -eq 1 ]; then printf '%s\n' "$MAIN_OUT"
    elif [ "$IG_STATE" = "CODEERROR" ]; then printf '❌ interaction — %s\n' "$IG_REASON"
    elif [ "$AL_STATE" = "CODEERROR" ]; then printf '❌ attribution — %s\n' "$AL_REASON"
    else printf '❌ commit-convention — %s\n' "$CC_REASON"; fi
  else
    case "$IG_STATE" in
      WARN)    printf '⚠️  %s\n' "$IG_REASON" ;;
      DATAENV) printf '⚠️  interaction data/env (not a code bug) — %s\n' "$IG_REASON" ;;
      *)       if [ "$AL_STATE" = "WARN" ]; then printf '⚠️  attribution — %s\n' "$AL_REASON"
               elif [ "$CC_STATE" = "WARN" ]; then printf '⚠️  commit-convention — %s\n' "$CC_REASON"
               else printf '%s\n' "$MAIN_OUT"; fi ;;
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
  WARN)     printf '⚠️  ATTRIBUTION LINT: %s\n' "$AL_REASON" ;;
  CODEERROR) printf '❌ ATTRIBUTION LINT: AI co-author marker found\n'
             [ -n "$AL_FULL" ] && printf '%s\n' "$AL_FULL" ;;
esac
case "$CC_STATE" in
  DISABLED) : ;;
  CLEAN)    printf '✅ COMMIT CONVENTION LINT CLEAN\n' ;;
  WARN)     printf '⚠️  COMMIT CONVENTION LINT: %s\n' "$CC_REASON" ;;
  CODEERROR) printf '❌ COMMIT CONVENTION LINT: subject does not match /%s/\n' "$COMMIT_CONVENTION"
             [ -n "$CC_FULL" ] && printf '%s\n' "$CC_FULL" ;;
esac
exit "$RC"
