#!/usr/bin/env bash
# healthcheck.sh <worktree-dir> [--oneline] [--heavy|--light|--auto] — is the change clean?
#
# Two profiles, auto-selected from what the worktree's diff (vs the default branch) touches —
# so a one-line script tweak isn't forced through the project's full (possibly slow) gate:
#
#   • heavy — run the PROJECT health command ($HEALTHCHECK_CMD from .herd/config), invoked as
#       $HEALTHCHECK_CMD <worktree-dir> --heavy [--oneline].  It owns the project-specific notion of
#       "healthy" (boot a server, run the test suite, shellcheck + bats, …) and MUST exit:
#         0 = clean (or only a tolerated data/env issue)
#         1 = a real CODE error
#         2 = a data/env issue (tolerated — treated as clean, surfaced as a ⚠️)
#       PROFILE FORWARDING (HERD-551 / GH #674): the resolved profile is passed through as $2 — dir
#       stays $1 — so a profile-aware project script (one that runs extra/slower probes ONLY under
#       --heavy) actually sees the request instead of silently defaulting to its own light behavior
#       while the wrapper reports clean. A script that ignores $2 (like herdkit's own, and the
#       templates/healthcheck.*.sh examples) is byte-identical either way.
#       CONTRADICTION HARD-ERROR (HERD-551): if a --heavy run's output contains a line starting with
#       the literal marker "HEAVY-SKIPPED:" — the documented convention for a project script that
#       received --heavy but still skipped its heavy probes (missing tool, env cap, a stale default,
#       …) — healthcheck.sh fails LOUDLY (exit 1) regardless of the script's own exit code. A --heavy
#       request that silently downgrades must never read as clean.
#       BASELINE-AWARE (HERD-190): a heavy code error whose failing tests ALL already fail on the base
#       (origin/main) is INHERITED — surfaced as a tolerated ⚠️, not blocked — so a fix-PR never
#       deadlocks on a base failure it did not introduce. See the baseline-aware gate section below;
#       byte-identical when the base is green, fully fail-soft, and only ever downgrades (never reds).
#   • light — no project command: per-changed-file syntax only (bash -n / py_compile / gofmt -e).
#       Fast. Source types it has NO dependency-free probe for (.rs/.java/.ts/…) are never silently
#       green-lit — they are flagged-the-absence with a loud ⚠️ (like the interaction gate), so a
#       diff that only touches an unprobed language reads as ⚠️, never a confident ✅.
#       EXTENSIONLESS files (bin/herd, hooks) are classified by SHEBANG (HERD-505) so the engine's own
#       CLI is probed too; an interpreter with no probe here skips silently (fail-soft, never red).
#       After the syntax pass it also runs the SHARED caps-sync guard (scripts/herd/caps-sync-lint.sh,
#       HERD-220) — the same lint the heavy project gate runs — so a builder whose change grows the
#       capability surface without touching templates/capabilities.tsv sees the red here, pre-PR,
#       instead of bouncing off the merge gate. Skipped in trees with no manifest (every consumer).
#       Then the SHARED doc-drift guard (scripts/herd/doc-drift-lint.sh, HERD-168 / HERD-254) —
#       README.md + docs/*.md + templates/*.tmpl must not reference a herd command (or a README
#       CONFIG_KEY) absent from the capabilities manifest. Docs/tmpl-only diffs run light under
#       HEALTHCHECK_HEAVY_GLOB, so this is the pre-PR gate that catches doc drift (the heavy suite
#       also wraps tests/test-doc-drift.sh).
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
# journal.sh only defines functions (no source-time side effects) and journal_append is best-effort +
# always-0, so a partially-upgraded tree missing it must not break the healthcheck. Sourced solely so
# the HERD-361 baseline-sandbox breadcrumb can journal a loud note when the sandbox can't be created.
if [ -f "$HERE/journal.sh" ]; then
  # shellcheck source=/dev/null
  . "$HERE/journal.sh"
fi
# Fail-soft on our own infra: a partially-upgraded engine tree missing the lint must SKIP the
# caps-sync guard (rc 2), never break the healthcheck it is a part of.
# Prefer the tree-under-test's copy when present so a branch that changes the lint is linted by
# its own version; fall back to the engine's copy only when the tree lacks it (HERD-309).
_HERD_LINT_SRC="$HERE/caps-sync-lint.sh"
[ -f "$DIR/scripts/herd/caps-sync-lint.sh" ] && _HERD_LINT_SRC="$DIR/scripts/herd/caps-sync-lint.sh"
if [ -f "$_HERD_LINT_SRC" ]; then
  . "$_HERD_LINT_SRC"
else
  HERD_CAPS_SYNC_SKIP_REASON="caps-sync-lint.sh not present"
  herd_caps_sync_lint() { return 2; }
fi
# Fail-soft on our own infra: a partially-upgraded engine tree missing the lint must SKIP the
# doc-drift guard (rc 2), never break the healthcheck it is a part of.
# Prefer the tree-under-test's copy when present (HERD-309).
_HERD_LINT_SRC="$HERE/doc-drift-lint.sh"
[ -f "$DIR/scripts/herd/doc-drift-lint.sh" ] && _HERD_LINT_SRC="$DIR/scripts/herd/doc-drift-lint.sh"
if [ -f "$_HERD_LINT_SRC" ]; then
  . "$_HERD_LINT_SRC"
else
  HERD_DOC_DRIFT_SKIP_REASON="doc-drift-lint.sh not present"
  herd_doc_drift_lint() { return 2; }
fi
# Fail-soft on our own infra: a partially-upgraded engine tree missing the lint must SKIP the
# gate-coverage guard (rc 2), never break the healthcheck it is a part of.
# Prefer the tree-under-test's copy when present (HERD-309).
_HERD_LINT_SRC="$HERE/gate-coverage-lint.sh"
[ -f "$DIR/scripts/herd/gate-coverage-lint.sh" ] && _HERD_LINT_SRC="$DIR/scripts/herd/gate-coverage-lint.sh"
if [ -f "$_HERD_LINT_SRC" ]; then
  . "$_HERD_LINT_SRC"
else
  HERD_GATE_COVERAGE_SKIP_REASON="gate-coverage-lint.sh not present"
  herd_gate_coverage_lint() { return 2; }
fi
# Fail-soft on our own infra: a partially-upgraded engine tree missing the lint must SKIP the
# pipe-safety guard (rc 2), never break the healthcheck it is a part of.
# Prefer the tree-under-test's copy when present (HERD-309).
_HERD_LINT_SRC="$HERE/pipe-safety-lint.sh"
[ -f "$DIR/scripts/herd/pipe-safety-lint.sh" ] && _HERD_LINT_SRC="$DIR/scripts/herd/pipe-safety-lint.sh"
if [ -f "$_HERD_LINT_SRC" ]; then
  . "$_HERD_LINT_SRC"
else
  HERD_PIPE_SAFETY_SKIP_REASON="pipe-safety-lint.sh not present"
  herd_pipe_safety_lint() { return 2; }
fi
# Fail-soft on our own infra: a partially-upgraded engine tree missing the lint must SKIP the
# consumer-only-event guard (rc 2), never break the healthcheck it is a part of.
# Prefer the tree-under-test's copy when present (HERD-309).
_HERD_LINT_SRC="$HERE/journal-emission-lint.sh"
[ -f "$DIR/scripts/herd/journal-emission-lint.sh" ] && _HERD_LINT_SRC="$DIR/scripts/herd/journal-emission-lint.sh"
if [ -f "$_HERD_LINT_SRC" ]; then
  . "$_HERD_LINT_SRC"
else
  HERD_JOURNAL_EMISSION_SKIP_REASON="journal-emission-lint.sh not present"
  herd_journal_emission_lint() { return 2; }
fi
# Fail-soft on our own infra: a partially-upgraded engine tree missing the lint must SKIP the
# git-scope guard (rc 2), never break the healthcheck it is a part of.
# Prefer the tree-under-test's copy when present (HERD-309).
_HERD_LINT_SRC="$HERE/git-scope-lint.sh"
[ -f "$DIR/scripts/herd/git-scope-lint.sh" ] && _HERD_LINT_SRC="$DIR/scripts/herd/git-scope-lint.sh"
if [ -f "$_HERD_LINT_SRC" ]; then
  . "$_HERD_LINT_SRC"
else
  HERD_GIT_SCOPE_SKIP_REASON="git-scope-lint.sh not present"
  herd_git_scope_lint() { return 2; }
fi
# Fail-soft on our own infra: a partially-upgraded engine tree missing the lint must SKIP the
# env-export guard (rc 2), never break the healthcheck it is a part of.
# Prefer the tree-under-test's copy when present (HERD-309).
_HERD_LINT_SRC="$HERE/env-export-lint.sh"
[ -f "$DIR/scripts/herd/env-export-lint.sh" ] && _HERD_LINT_SRC="$DIR/scripts/herd/env-export-lint.sh"
if [ -f "$_HERD_LINT_SRC" ]; then
  . "$_HERD_LINT_SRC"
else
  HERD_ENV_EXPORT_SKIP_REASON="env-export-lint.sh not present"
  herd_env_export_lint() { return 2; }
fi
# Fail-soft on our own infra: a partially-upgraded engine tree missing the lint must SKIP the
# test-cap-ledger guard (rc 2), never break the healthcheck it is a part of.
# Prefer the tree-under-test's copy when present (HERD-309).
_HERD_LINT_SRC="$HERE/test-cap-ledger.sh"
[ -f "$DIR/scripts/herd/test-cap-ledger.sh" ] && _HERD_LINT_SRC="$DIR/scripts/herd/test-cap-ledger.sh"
if [ -f "$_HERD_LINT_SRC" ]; then
  . "$_HERD_LINT_SRC"
else
  HERD_TEST_CAP_LEDGER_SKIP_REASON="test-cap-ledger.sh not present"
  herd_test_cap_ledger_lint() { return 2; }
fi
# SHA-MATCHED BUILDER-LOCAL TRUST (HERD-531): the shared provenance-record library. Sourcing DEFINES
# functions only and writes nothing; the record itself is written at the very END of this script, and
# only when HEALTH_TRUST_BUILDER is on. Fail-soft on our own infra (a partially-upgraded engine tree
# missing it) with a no-op writer, exactly like the lints above. Prefer the tree-under-test's copy
# when present so a branch that changes the library is exercised by its own version (HERD-309).
_HERD_LINT_SRC="$HERE/health-trust.sh"
[ -f "$DIR/scripts/herd/health-trust.sh" ] && _HERD_LINT_SRC="$DIR/scripts/herd/health-trust.sh"
if [ -f "$_HERD_LINT_SRC" ]; then
  # shellcheck source=scripts/herd/health-trust.sh
  . "$_HERD_LINT_SRC"
else
  herd_health_trust_write() { return 0; }
fi
# Wall-clock start for the provenance record's duration field. Taken BEFORE the profile runs and
# after every source, so it measures the run this record describes.
_HC_T0="$(date +%s 2>/dev/null || echo 0)"
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
#   HERD_BASELINE_DIR   — optional existing base (origin/main) checkout whose HEAD supplies the base
#                         SHA (the watcher passes $MAIN, the authoritative default-branch tree). HERD-361:
#                         the base suite is NEVER run inside this live checkout — it is always run in a
#                         DISPOSABLE detached worktree at that sha, so a suite test that stages/stashes in
#                         $PWD can only contaminate the throwaway, never the shared checkout. Absent → the
#                         base sha is resolved from this worktree's view of $DEFAULT_BRANCH instead.
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

# _baseline_sandbox_note <why> <base-sha> — HERD-361 fail-soft breadcrumb: the base suite could NOT be
# sandboxed (mktemp / worktree add refused), so the caller returns the empty set (classic block) rather
# than fall back to running INSIDE the live shared checkout. Loud on stderr (lands in the streamed
# healthcheck log) AND journaled when journal_append is in scope, so the skip is never silent.
_baseline_sandbox_note() {
  printf '⚠️  baseline sandbox unavailable (%s) — base suite NOT run; blocking on the classic absolute verdict (never run in the live shared checkout)\n' "${1:-unknown}" >&2
  if command -v journal_append >/dev/null 2>&1; then
    journal_append baseline_sandbox result unavailable reason "${1:-unknown}" base "${2:-}" component healthcheck
  fi
}

# _baseline_base_set — the base (origin/main) known-failure set, printed as a sorted-unique newline
# set (empty = base green / unresolvable → caller blocks). Resolves the base SHA (an explicit
# HERD_BASELINE_DIR's HEAD, else this worktree's view of $DEFAULT_BRANCH), then runs the SAME heavy
# suite in FULL mode inside a DISPOSABLE detached worktree at that sha, and caches the extracted set by
# base sha. HERD-361: the suite is ALWAYS sandboxed — even when HERD_BASELINE_DIR ($MAIN) is supplied it
# is only read for the sha, never used as the run dir, so a suite test that stages/stashes in $PWD can
# only ever dirty the throwaway. Fail-soft throughout: any git/worktree failure yields the empty set
# (classic blocking verdict) — with a LOUD note, never a silent fall-through to the live checkout.
_baseline_base_set() {
  local _bl_dir="" _bl_created="" _bl_base_sha _bl_pr_sha _bl_cache_dir _bl_cache _bl_out _bl_set _bl_tmp
  # Resolve the base SHA. Prefer HERD_BASELINE_DIR's HEAD (the authoritative default-branch tree the
  # watcher passes) so the cache key matches its intent; else this worktree's default-branch ref.
  if [ -n "${HERD_BASELINE_DIR:-}" ] && [ -d "$HERD_BASELINE_DIR" ] \
     && _bl_base_sha="$(git -C "$HERD_BASELINE_DIR" rev-parse HEAD 2>/dev/null)" && [ -n "$_bl_base_sha" ]; then
    :
  else
    _bl_base_sha="$(git -C "$DIR" rev-parse "$DEFAULT_BRANCH" 2>/dev/null || true)"
  fi
  [ -n "$_bl_base_sha" ] || return 0                          # base ref unresolvable → empty set (block)

  # Self-comparison guard: if the worktree IS the base commit, nothing could have been introduced —
  # but an empty/degenerate PR is not the deadlock this fixes, so fall back to the classic verdict.
  _bl_pr_sha="$(git -C "$DIR" rev-parse HEAD 2>/dev/null || true)"
  if [ -n "$_bl_pr_sha" ] && [ "$_bl_pr_sha" = "$_bl_base_sha" ]; then
    return 0
  fi

  # Cache hit → return the memoized set with NO suite run at all (so no sandbox is even created).
  _bl_cache_dir="${HERD_BASELINE_CACHE:-${TMPDIR:-/tmp}}"
  _bl_cache="$_bl_cache_dir/.herd-baseline-notok-$_bl_base_sha"
  if [ -f "$_bl_cache" ]; then
    cat "$_bl_cache" 2>/dev/null || true
    return 0
  fi

  # HERD-361: SANDBOX the base suite in a throwaway detached worktree at the base sha — NEVER run inside
  # the live HERD_BASELINE_DIR. `git worktree add` only registers under the source's .git and never
  # touches its working tree or index, so adding FROM the live shared checkout leaves it pristine while
  # guaranteeing the base sha is reachable (it is that checkout's own HEAD). Prefer HERD_BASELINE_DIR as
  # the source for exactly that reachability; else $DIR (which shares $MAIN's object store).
  local _bl_src="$DIR"
  [ -n "${HERD_BASELINE_DIR:-}" ] && [ -d "$HERD_BASELINE_DIR" ] && _bl_src="$HERD_BASELINE_DIR"
  _bl_tmp="$(mktemp -d 2>/dev/null || true)"
  if [ -z "$_bl_tmp" ]; then
    _baseline_sandbox_note "mktemp failed" "$_bl_base_sha"; return 0
  fi
  _bl_dir="$_bl_tmp/base"
  if ! git -C "$_bl_src" worktree add --detach "$_bl_dir" "$_bl_base_sha" >/dev/null 2>&1; then
    rm -rf "$_bl_tmp" 2>/dev/null || true
    _baseline_sandbox_note "worktree add refused" "$_bl_base_sha"; return 0
  fi
  _bl_created="$_bl_tmp"

  # Run the base suite in FULL mode (TAP), extract + cache its known-failure set. A tolerated data/env
  # (⚠️, rc 2) or clean (rc 0) base simply yields no 'not ok' lines → an empty set (base green).
  # HERD-551: forward --heavy here too — the base run must be the SAME profile as the PR run it is
  # diffed against, else a profile-aware project script would compare a heavy PR suite's failures
  # against a light base run's (near-empty) known-failure set and never find anything "inherited".
  _bl_out="$(bash -c "cd '$_bl_dir' && $HEALTHCHECK_CMD '$_bl_dir' --heavy" 2>&1)"
  _bl_set="$(_baseline_notok_set "$_bl_out")"
  printf '%s\n' "$_bl_set" > "$_bl_cache" 2>/dev/null || true
  git -C "$_bl_src" worktree remove --force "$_bl_dir" >/dev/null 2>&1 || true
  rm -rf "$_bl_created" 2>/dev/null || true
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
      elif grep -qE "$HEALTHCHECK_HEAVY_GLOB" <<< "$changed"; then   # here-string, not a pipe (HERD-297: no EPIPE if grep -q exits early on a >16KB diff)
        MODE="heavy"
      else
        MODE="light"
      fi
    fi
  fi
fi

# ── HERD-529 LEG A: cross-worktree LOCAL SUITE SLOT ───────────────────────────────────────────────
# HEALTH_CONCURRENCY (agent-watch.sh) serializes only the WATCHER's own dispatch loop; it has no
# visibility into a builder running `healthcheck.sh --heavy` locally, ahead of its own PR, in its own
# worktree. GROUNDED 2026-08-05: an 8-builder fleet ran up to 8 simultaneous builder-local heavy
# suites — box saturation, a tolerated-as-DATA/ENV 1800s bats timeout that actually meant the suite
# asserted nothing that run. This section mirrors agent-watch.sh's HERD-185 restart-safe marker
# machinery (pid + start-time + dispatch-ts, so a dead/recycled holder's slot self-reclaims) under a
# DISTINCT namespace (`.local-suite-slot-*`) in the SAME cross-worktree pool ($WORKTREES_DIR) the
# watcher's `.health-inflight-*` markers live in — a separate accounting system, never colliding with
# HEALTH_CONCURRENCY's, capping ALL heavy suite runs on this box (builder-local AND watcher-dispatched)
# under LOCAL_SUITE_CONCURRENCY (herd-config.sh, default 2).
_lss_now_epoch() { printf '%s' "${HERD_FAKE_NOW:-$(date +%s)}"; }

# _lss_pid_starttime <pid> — same stable per-process token as agent-watch.sh's _pid_starttime, so a
# recycled pid is never mistaken for its former holder. HERD_PID_STARTTIME_CMD is honored as the same
# test seam agent-watch.sh's version defines, so a shared test fixture can stub both identically.
_lss_pid_starttime() {
  local p="${1:-}"; [ -n "$p" ] || return 0
  if [ -n "${HERD_PID_STARTTIME_CMD:-}" ]; then "$HERD_PID_STARTTIME_CMD" "$p" 2>/dev/null; return 0; fi
  ps -o lstart= -p "$p" 2>/dev/null | tr -s '[:space:]' ' ' | sed -e 's/^ //' -e 's/ $//'
}

# _lss_pool_dir — the cross-worktree pool directory, or empty when unresolved/missing. Fail-soft
# entry point: every caller below treats an empty result as "run unslotted, exactly as today".
_lss_pool_dir() {
  [ -n "${WORKTREES_DIR:-}" ] && [ -d "$WORKTREES_DIR" ] && printf '%s' "$WORKTREES_DIR"
}

_lss_marker_write() {
  local f="$1"
  { printf '%s\n' "$$"; printf '%s\n' "$(_lss_pid_starttime "$$")"; printf '%s\n' "$(_lss_now_epoch)"; } \
    > "$f" 2>/dev/null || true
}
_lss_marker_pid()       { sed -n '1p' "$1" 2>/dev/null; }
_lss_marker_starttime() { sed -n '2p' "$1" 2>/dev/null; }

# _lss_marker_live <file> — true iff the marker's pid is alive AND (recycling guard) its current
# start-time still matches the recorded one. Mirrors agent-watch.sh's _marker_live (HERD-185).
_lss_marker_live() {
  local f="$1" pid st cur
  pid="$(_lss_marker_pid "$f")"; [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  st="$(_lss_marker_starttime "$f")"; [ -n "$st" ] || return 0
  cur="$(_lss_pid_starttime "$pid")"; [ -n "$cur" ] || return 0
  [ "$cur" = "$st" ]
}

# _lss_reclaim_stale <pool> — drop every .local-suite-slot-* marker whose recorded holder is
# dead/recycled, so a crashed/killed builder never wedges the pool. Run on every acquire attempt.
_lss_reclaim_stale() {
  local pool="$1" f
  for f in "$pool"/.local-suite-slot-*; do
    [ -e "$f" ] || continue
    case "$f" in *.lock) continue ;; esac
    _lss_marker_live "$f" || rm -f "$f" 2>/dev/null || true
  done
}

# _lss_count_live <pool> — number of markers whose holder is VERIFIED live right now.
_lss_count_live() {
  local pool="$1" n=0 f
  for f in "$pool"/.local-suite-slot-*; do
    [ -e "$f" ] || continue
    case "$f" in *.lock) continue ;; esac
    _lss_marker_live "$f" && n=$((n+1))
  done
  printf '%s' "$n"
}

# _lss_lock / _lss_unlock <pool> — a short-held `mkdir` mutex (atomic, no flock(1) dependency — this
# runs on macOS builder boxes too) guarding ONLY the read-count-then-write critical section below,
# never the suite run itself. Bounded retry (~5s default) so a wedged/vanished lock-holder can never
# hang an acquire attempt forever; on timeout the caller proceeds WITHOUT the lock — a benign race
# that can only over-admit by a slot or two, never under-admit or deadlock.
_lss_lock() {
  local pool="$1" i=0 max="${HERD_LOCAL_SUITE_LOCK_TRIES:-50}"
  case "$max" in ''|*[!0-9]*) max=50 ;; esac
  while [ "$i" -lt "$max" ]; do
    mkdir "$pool/.local-suite-slot.lock" 2>/dev/null && return 0
    sleep 0.1 2>/dev/null || sleep 1
    i=$((i+1))
  done
  return 1
}
_lss_unlock() { rmdir "$1/.local-suite-slot.lock" 2>/dev/null || true; }

# _lss_try_acquire <pool> <cap> — claim the first free numbered slot (1..cap); prints its marker path
# on success (exit 0); prints nothing on failure (exit 1 — every slot is live right now).
_lss_try_acquire() {
  local pool="$1" cap="$2" i marker locked=0
  _lss_lock "$pool" && locked=1
  _lss_reclaim_stale "$pool"
  i=1
  while [ "$i" -le "$cap" ]; do
    marker="$pool/.local-suite-slot-$i"
    if [ ! -e "$marker" ] || ! _lss_marker_live "$marker"; then
      _lss_marker_write "$marker"
      [ "$locked" -eq 1 ] && _lss_unlock "$pool"
      printf '%s' "$marker"
      return 0
    fi
    i=$((i+1))
  done
  [ "$locked" -eq 1 ] && _lss_unlock "$pool"
  return 1
}

# _lss_release — drop this run's own marker (idempotent; safe to call with none held). Wired as an
# EXIT trap so a crash/interrupt still frees the slot promptly — the NEXT acquirer's
# _lss_reclaim_stale self-heals a marker this trap somehow missed (a SIGKILL, e.g.).
_LSS_MARKER=""
_lss_release() { [ -n "$_LSS_MARKER" ] && rm -f "$_LSS_MARKER" 2>/dev/null; _LSS_MARKER=""; }

# _lss_acquire — HERD-529: claim a cross-worktree local-suite slot before running the heavy profile.
# Prints a VISIBLE 'waiting for a local suite slot (n ahead, cap N)' line — one per retry — on every
# attempt that finds no free slot, so the builder pane always shows WHY it is waiting (never a silent
# stall). Written to STDERR, deliberately: run_heavy() executes inside run_profile()'s
# `MAIN_OUT="$(run_profile)"` command substitution, which captures only stdout — a wait line on stdout
# would sit invisibly buffered inside $MAIN_OUT until the ENTIRE suite finishes (defeating the whole
# point). Stderr passes straight through a `$(...)` capture uncaptured, so it reaches the builder's
# terminal / tailed log the instant it's printed — genuinely unbuffered, not just unflushed. Fail-soft:
# no resolvable pool dir (WORKTREES_DIR unset/missing) → returns immediately, running unslotted exactly
# as before this feature existed.
_lss_acquire() {
  local pool cap live
  pool="$(_lss_pool_dir)"
  [ -n "$pool" ] || return 0
  cap="$(herd_numeric LOCAL_SUITE_CONCURRENCY 2)"
  case "$cap" in ''|*[!0-9]*) cap=2 ;; esac
  [ "$cap" -ge 1 ] 2>/dev/null || cap=1
  trap '_lss_release' EXIT
  while :; do
    _LSS_MARKER="$(_lss_try_acquire "$pool" "$cap")" && break
    live="$(_lss_count_live "$pool")"
    printf 'waiting for a local suite slot (%s ahead, cap %s)\n' "$live" "$cap" >&2
    sleep "${HERD_LOCAL_SUITE_SLOT_POLL_SECS:-2}" 2>/dev/null || sleep 2
  done
}

# ── heavy profile: delegate to the project health command ────────────────────
run_heavy() {
  if [ -z "$HEALTHCHECK_CMD" ]; then run_light; return; fi
  _lss_acquire
  # Resolve the command relative to the worktree (it's a committed project file).
  local out rc
  # HERD-533 STREAM: the previous shape captured the WHOLE suite's output into $out via a bare
  # command substitution, so nothing reached our own stdout — and thus the dispatch log the async
  # health worker redirects healthcheck.sh's stdout into — until the suite fully exited (a ~9-minute
  # black box: the tailable log sat at 0 bytes the whole run). HEALTHCHECK_PROGRESS_LOG (HERD-494's
  # convention: the async worker sets it to a per-run companion path) lets us ALSO tee the command's
  # raw output there AS IT RUNS, independent of the $out capture below, so a `tail -f` on that path
  # shows real progress instead of nothing. Purely additive: $out/$rc are computed EXACTLY as before
  # (tee is a transparent passthrough of the same bytes; `pipefail`, scoped to this one subshell via
  # the command substitution, keeps $HEALTHCHECK_CMD's — not tee's — exit code). With the env var
  # unset (every caller except the async worker) the tee target is /dev/null: byte-identical.
  # HERD-551 / GH #674: forward the resolved profile — dir stays $1, profile is $2 — so a
  # profile-aware project script actually sees --heavy instead of defaulting to light while this
  # wrapper reports clean. See the header contract comment above.
  [ -n "${HEALTHCHECK_PROGRESS_LOG:-}" ] && { : > "$HEALTHCHECK_PROGRESS_LOG"; } 2>/dev/null
  if [ -n "$ONELINE" ]; then
    out="$(set -o pipefail; bash -c "cd '$DIR' && $HEALTHCHECK_CMD '$DIR' --heavy --oneline" 2>&1 | tee -a "${HEALTHCHECK_PROGRESS_LOG:-/dev/null}")"; rc=$?
  else
    out="$(set -o pipefail; bash -c "cd '$DIR' && $HEALTHCHECK_CMD '$DIR' --heavy" 2>&1 | tee -a "${HEALTHCHECK_PROGRESS_LOG:-/dev/null}")"; rc=$?
  fi
  # HERD-551 / GH #674 CONTRADICTION HARD-ERROR: a project script invoked with --heavy that still
  # emits the documented "HEAVY-SKIPPED:" marker is telling us it did NOT run its heavy probes —
  # trusting its exit code here would be exactly the silent-clean gate-integrity hole GH #674 found
  # (six heavy probes + visual regression never ran while the gate reported clean). This check runs
  # BEFORE the baseline-aware downgrade and the normal rc dispatch below, and fires regardless of rc
  # (0/1/2) — a script that skips heavy work and still exits 0 is the exact failure mode being closed.
  if grep -q '^HEAVY-SKIPPED:' <<< "$out"; then
    echo "❌ HEAVY/LIGHT CONTRADICTION: wrapper invoked --heavy but the project health command reports it skipped heavy work (see the HEAVY-SKIPPED: line below) — refusing to report this as clean"
    printf '%s\n' "$out"
    command -v journal_append >/dev/null 2>&1 && journal_append heavy_skipped_contradiction result blocked component healthcheck
    exit 1
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
# EXTENSIONLESS executables (bin/herd, git hooks, …) carry their language in the SHEBANG, not the
# filename, so the extension-keyed bucketing below used to skip them outright — the engine's own CLI,
# bin/herd, went entirely unprobed by the light gate (HERD-505). They are now classified by their
# first line and folded into the matching bucket; an unrecognized interpreter skips SILENTLY.
#
# _shebang_lang <file> — the light-probe bucket for an extensionless file, read from its shebang:
# "sh" (→ bash -n), "py" (→ py_compile), or NOTHING at all. Empty means SKIP SILENTLY (fail-soft):
# no shebang, an unreadable/binary file, or an interpreter we have no dependency-free probe for
# (perl, node, awk, ruby, zsh …) must never red the gate and must never be counted as "unchecked"
# either — we make no claim about a language we never promised to probe. One awk pass, no pipes and
# no word-splitting, so a shebang containing a glob char or CRLF line ending cannot misbehave.
_shebang_lang() {
  awk 'NR==1 {
         if ($0 !~ /^#!/) exit
         gsub(/\r/, "", $0)
         sub(/^#![[:space:]]*/, "", $0)
         n = split($0, w, /[[:space:]]+/)
         for (i = 1; i <= n; i++) {
           t = w[i]
           sub(/^.*\//, "", t)                                   # basename of the interpreter word
           # Skip the `env` trampoline plus its own flags (-S, -i) and VAR=val prefixes, so
           # "#!/usr/bin/env -S python3 -u" resolves exactly like "#!/usr/bin/python3".
           if (t == "" || t == "env" || t ~ /^-/ || t ~ /=/) continue
           if (t == "bash" || t == "sh") print "sh"
           else if (t ~ /^python[0-9.]*$/) print "py"
           exit
         }
       }' "$1" 2>/dev/null
}
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
      # Everything else: an EXTENSIONLESS file (basename with no dot) is classified by its shebang —
      # that is the only place bin/herd and friends declare their language. Any other extension
      # (docs, JSON, config) falls through and is ignored exactly as before.
      *)
        case "${f##*/}" in
          *.*) ;;                                                # extensioned but unrecognized → ignore
          *)
            case "$(_shebang_lang "$f")" in
              sh) sh+=("$f") ;;
              py) py+=("$f") ;;
            esac
            ;;
        esac
        ;;
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
    if [ -n "$ONELINE" ]; then echo "❌ light syntax — $(printf '%s' "$syntax_errs" | head -1)";  # pipe-ok: head in a command or process substitution; pipeline status not gated
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
    if [ -n "$ONELINE" ]; then echo "❌ caps-sync — $(printf '%s' "$caps_errs" | head -1)";  # pipe-ok: head in a command or process substitution; pipeline status not gated
    else echo "❌ CAPS-SYNC: capabilities manifest not updated alongside engine change"; printf '%s\n' "$caps_errs"; fi
    exit 1
  fi

  # doc-drift guard (HERD-168 / HERD-96 / HERD-254) — README.md + docs/*.md + templates/*.tmpl must
  # not reference a `herd <subcommand>` (or a README CONFIG_KEY) absent from templates/capabilities.tsv.
  # Docs/tmpl-only diffs run this LIGHT profile under HEALTHCHECK_HEAVY_GLOB, so this is the gate that
  # actually catches doc drift pre-PR (the heavy suite also wraps tests/test-doc-drift.sh via herd.bats).
  # Same red semantics as caps-sync. Skipped (never red) when the shared lint is absent or the tree
  # has no manifest / no README-docs-tmpl surface.
  local drift_errs drift_rc
  drift_errs="$(herd_doc_drift_lint ".")"; drift_rc=$?
  if [ "$drift_rc" -eq 1 ]; then
    if [ -n "$ONELINE" ]; then echo "❌ doc-drift — $(printf '%s' "$drift_errs" | grep '^DRIFT' | head -1)";  # pipe-ok: head in a command or process substitution; pipeline status not gated
    else echo "❌ DOC-DRIFT: README/docs/templates reference a command (or README key) absent from capabilities.tsv"; printf '%s\n' "$drift_errs" | grep '^DRIFT' || printf '%s\n' "$drift_errs"; fi
    exit 1
  fi

  # gate-coverage guard (HERD-292) — every tests/test-*.sh must be referenced in tests/herd.bats
  # OR listed in tests/gate-coverage-exempt.tsv. A new test file that never lands in herd.bats sits
  # ungated at the merge gate indefinitely; this lint catches it pre-PR. Same red semantics as
  # caps-sync / doc-drift. Skipped (never red) when the shared lint is absent or the tree has no
  # tests/herd.bats (i.e. every consuming project).
  local gcov_errs gcov_rc
  gcov_errs="$(herd_gate_coverage_lint ".")"; gcov_rc=$?
  if [ "$gcov_rc" -eq 1 ]; then
    if [ -n "$ONELINE" ]; then echo "❌ gate-coverage — $(printf '%s' "$gcov_errs" | grep '^UNGATED' | head -1)";  # pipe-ok: head in a command or process substitution; pipeline status not gated
    else echo "❌ GATE-COVERAGE: tests/test-*.sh exists but is not wired into tests/herd.bats (add to bats or to tests/gate-coverage-exempt.tsv)"; printf '%s\n' "$gcov_errs" | grep '^UNGATED' || printf '%s\n' "$gcov_errs"; fi
    exit 1
  fi

  # pipe-safety guard (HERD-299) — a NEW '<producer> | grep -q/-m' (or '| head') is a latent false-red
  # under `set -o pipefail` (the EPIPE that turned macOS CI chronically red, HERD-297). The SAME lint
  # the heavy gate runs (scripts/herd/pipe-safety-lint.sh), so it is caught here pre-PR. Same red
  # semantics as caps-sync / gate-coverage. A verified-small producer opts out with '# pipe-ok: <why>'.
  # Skipped (never red) when the shared lint is absent or the tree has no engine scan surface.
  local pipe_errs pipe_rc
  pipe_errs="$(herd_pipe_safety_lint ".")"; pipe_rc=$?
  if [ "$pipe_rc" -eq 1 ]; then
    if [ -n "$ONELINE" ]; then echo "❌ pipe-safety — $(printf '%s' "$pipe_errs" | grep '^PIPE-UNSAFE' | head -1)";  # pipe-ok: head in a command substitution; status not gated
    else echo "❌ PIPE-SAFETY: '<producer> | grep -q/-m/head' is EPIPE-unsafe under pipefail (grep files/here-strings directly, or annotate '# pipe-ok: <why>' for a verified-small producer)"; printf '%s\n' "$pipe_errs" | grep '^PIPE-UNSAFE' || printf '%s\n' "$pipe_errs"; fi  # pipe-ok: the pattern appears in this line's MESSAGE TEXT, not as a pipeline
    exit 1
  fi

  # git-scope guard (HERD-435 / issue #547) — engine/project ISOLATION: a production engine path may
  # not stage repo-wide (`git add -A|.|-u`, `git commit -a`) or commit without a `--` pathspec, so an
  # unrelated repo (or an operator's mid-edit) sitting in or beside the tree can never be swept into a
  # herdkit commit. The SAME lint the heavy gate runs (scripts/herd/git-scope-lint.sh). Same red
  # semantics as caps-sync / pipe-safety. scripts/herd/sim/, scripts/herd/experiment/ and tests/ are
  # classified FIXTURE (throwaway temp repos) and never flagged; a deliberate exception annotates with
  # '# herd-scope-ok: <why>'. Skipped (never red) when the lint is absent or the tree has no engine
  # git surface.
  # consumer-only-event guard (HERD-442) — every journal event name a CONSUMER parses must have a
  # live PRODUCER. `human_verify_policy`, `hold_released` and `merged_external` each shipped as a
  # consumer reading an event nobody writes; the journal is best-effort, so a missing event is
  # indistinguishable from "it did not happen this run" and no other rail can see it. The SAME lint
  # the heavy gate runs (scripts/herd/journal-emission-lint.sh). Same red semantics as caps-sync /
  # pipe-safety. A deliberately-unproduced event opts out in the lint's allowlist, with its reason.
  # Skipped (never red) when the lint is absent or the tree has no engine journal surface.
  local jemit_errs jemit_rc
  jemit_errs="$(herd_journal_emission_lint ".")"; jemit_rc=$?
  if [ "$jemit_rc" -eq 1 ]; then
    if [ -n "$ONELINE" ]; then echo "❌ journal-emission — $(printf '%s' "$jemit_errs" | grep '^EMISSION-ORPHAN' | head -1)";  # pipe-ok: head in a command substitution; status not gated
    else echo "❌ JOURNAL-EMISSION: a consumer parses an event name no producer emits (add the producer, or allowlist it with its reason in journal-emission-lint.sh)"; printf '%s\n' "$jemit_errs" | grep '^EMISSION-ORPHAN' || printf '%s\n' "$jemit_errs"; fi
    exit 1
  fi

  local gscope_errs gscope_rc
  gscope_errs="$(herd_git_scope_lint ".")"; gscope_rc=$?
  if [ "$gscope_rc" -eq 1 ]; then
    if [ -n "$ONELINE" ]; then echo "❌ git-scope — $(printf '%s' "$gscope_errs" | grep '^GIT-SCOPE' | head -1)";  # pipe-ok: head in a command substitution; status not gated
    else echo "❌ GIT-SCOPE: a production engine path stages repo-wide or commits without a pathspec (name the paths, or annotate '# herd-scope-ok: <why>')"; printf '%s\n' "$gscope_errs" | grep '^GIT-SCOPE' || printf '%s\n' "$gscope_errs"; fi
    exit 1
  fi

  # env-export guard (HERD-449) — a config knob the Python engine core reads from os.environ
  # (pysrc/herd/live_runtime.py's _CORE_ENV_KEYS) must be `export`ed by herd-config.sh, or the
  # `live_runtime --tick` CHILD process never sees it and silently defaults (the bug that starved
  # HEALTH_CONCURRENCY/REVIEW_CONCURRENCY). Same red semantics as caps-sync / git-scope. Skipped
  # (never red) when the shared lint is absent or the tree has no herd-config.sh + pysrc.
  local eexp_errs eexp_rc
  eexp_errs="$(herd_env_export_lint ".")"; eexp_rc=$?
  if [ "$eexp_rc" -eq 1 ]; then
    if [ -n "$ONELINE" ]; then echo "❌ env-export — $(printf '%s' "$eexp_errs" | head -1) set but not exported";  # pipe-ok: head in a command substitution; status not gated
    else echo "❌ ENV-EXPORT: a config key the Python engine core reads from os.environ is set but not \`export\`ed by herd-config.sh (the child tick process never sees it)"; printf '%s\n' "$eexp_errs"; fi
    exit 1
  fi

  # test-cap-ledger guard (HERD-478) — tests/test-caps.tsv (the per-test timeout ledger
  # scripts/ci/run-suite.sh reads) must carry no bare rows (reason + measured-baseline mandatory)
  # and no STALE row (a listed test whose measured-baseline now sits comfortably under the default
  # cap). The SAME lint the heavy gate runs (scripts/herd/test-cap-ledger.sh). Same red semantics as
  # caps-sync / env-export. Skipped (never red) when the shared lint is absent or the tree has no
  # tests/ directory at all.
  local tcl_errs tcl_rc
  tcl_errs="$(herd_test_cap_ledger_lint ".")"; tcl_rc=$?
  if [ "$tcl_rc" -eq 1 ]; then
    if [ -n "$ONELINE" ]; then echo "❌ test-cap-ledger — $(printf '%s' "$tcl_errs" | grep -E '^(MALFORMED|STALE)' | head -1)";  # pipe-ok: head in a command substitution; status not gated
    else echo "❌ TEST-CAP-LEDGER: tests/test-caps.tsv carries a bare or stale row"; printf '%s\n' "$tcl_errs" | grep -E '^(MALFORMED|STALE)' || printf '%s\n' "$tcl_errs"; fi
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
  AL_REASON="$(printf '%s' "$_al_violations" | head -1)"  # pipe-ok: head in a command or process substitution; pipeline status not gated
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
  CC_REASON="$(printf '%s' "$_cc_violations" | head -1)"  # pipe-ok: head in a command or process substitution; pipeline status not gated
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
  grep -qE "$APP_SURFACE_GLOB" <<< "$changed" || return 0   # diff misses the app surface (here-string, not a pipe — HERD-297)

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

# ── provenance record (HERD-531) ──────────────────────────────────────────────────────────────────
# Record what this run PROVED, so a later run of the identical suite against the identical commit can
# be skipped instead of paid for twice (see scripts/herd/health-trust.sh for the record's shape and
# the fail-closed rules that decide whether it is ever honored).
#
# Recorded ONLY for a GATING HEAVY run: --oneline is the status pane's summary row (no suite, no gate
# authority) and the light profile proves nothing about the full suite, so neither may ever author a
# record a heavy re-run could be skipped on. The outcome recorded is the COMBINED verdict — an
# interaction/attribution/commit-convention code error is a red this run cannot attest away either.
# The record is stamped `builder-local` unless the caller declares otherwise: agent-watch.sh's own
# health workers pass HERD_HEALTH_PROVENANCE=watcher, so a watcher run can never be mistaken for the
# builder-local evidence that justifies trusting it (trust always traces back to a real heavy suite).
# Best-effort and silent: writing a record can never change this script's verdict or exit status.
# $HEALTHCHECK_CMD must be non-empty too: with no project health command, run_heavy DELEGATES to
# run_light (see run_heavy's first line), so MODE=heavy would otherwise stamp a heavy record on a run
# that was only the syntax/lint gate. Record what actually ran, never what was asked for.
if [ "$MODE" = "heavy" ] && [ -z "$ONELINE" ] && [ -n "$HEALTHCHECK_CMD" ]; then
  _hc_prov_outcome="CLEAN"
  if [ "$RC" -eq 1 ]; then
    _hc_prov_outcome="CODEERROR"
  else
    case "$MAIN_OUT" in "⚠️"*) _hc_prov_outcome="DATAENV" ;; esac
  fi
  _hc_prov_sha="$(git -C "$DIR" rev-parse HEAD 2>/dev/null || true)"
  _hc_prov_now="$(date +%s 2>/dev/null || echo 0)"
  _hc_prov_dur=$(( _hc_prov_now - _HC_T0 )); [ "$_hc_prov_dur" -ge 0 ] 2>/dev/null || _hc_prov_dur=0
  herd_health_trust_write "${WORKTREES_DIR:-}" "$_hc_prov_sha" "$DIR" heavy \
    "$_hc_prov_outcome" "$_hc_prov_dur" "${HERD_HEALTH_PROVENANCE:-builder-local}" || true
fi

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
