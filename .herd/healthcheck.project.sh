#!/usr/bin/env bash
# .herd/healthcheck.project.sh — herdkit's OWN health command (the dogfood gate).
# Called by scripts/herd/healthcheck.sh for the heavy profile:
#     .herd/healthcheck.project.sh <worktree-dir> [--oneline]
#
# herdkit has no app — health = the scripts are syntactically sound and the tests pass:
#   1) bash -n over every engine + CLI script               (always available; the hard gate)
#   2) shellcheck over them IF installed                    (best-effort lint)
#   3) the hermetic test suite (tests/*.sh) + bats IF present
#
# CONTRACT: exit 0 = clean · 1 = code error · 2 = data/env (tolerated). herdkit has no data/env
# axis, so it only ever returns 0 or 1.
set -u
DIR="${1:?usage: healthcheck.project.sh <worktree-dir> [--oneline]}"
ONELINE=""; [ "${2:-}" = "--oneline" ] && ONELINE=1
cd "$DIR" 2>/dev/null || { echo "no such dir: $DIR"; exit 1; }

errs=""

# 1. bash -n over all shell scripts (engine + CLI + tests + templates).
while IFS= read -r f; do
  [ -n "$f" ] || continue
  e="$(bash -n "$f" 2>&1)" || errs="${errs}bash -n $f → $(printf '%s' "$e" | tail -1)"$'\n'
done < <(
  { find scripts bin templates tests -type f -name '*.sh' 2>/dev/null
    [ -f bin/herd ] && echo bin/herd; } | sort -u
)

if [ -n "$errs" ]; then
  [ -n "$ONELINE" ] && echo "syntax: $(printf '%s' "$errs" | head -1)" || { echo "SYNTAX ERROR"; printf '%s' "$errs"; }
  exit 1
fi

# 2. shellcheck (best-effort lint — only fail on errors, not style).
sc_note="shellcheck: skipped (not installed)"
if command -v shellcheck >/dev/null 2>&1; then
  if sc="$(shellcheck -S error scripts/herd/*.sh scripts/herd/backends/*.sh bin/herd 2>&1)"; then
    sc_note="shellcheck: clean"
  else
    [ -n "$ONELINE" ] && echo "shellcheck: $(printf '%s' "$sc" | head -1)" || { echo "SHELLCHECK ERRORS"; printf '%s\n' "$sc"; }
    exit 1
  fi
fi

# 3. Tests — bats if present, else run the hermetic *.sh tests directly.
#
# HERMETICITY LEAK-GUARD: a hermetic test must NEVER create a real tab/pane in the user's LIVE
# herdr workspace. We snapshot the live inventory before and after the suite and FAIL LOUDLY if
# the suite leaves a new ORPHAN tab behind. This is exactly the class of bug that let a stray
# 'review·<slug>' tab (with an orphaned 'tail -f') leak from test-review-pane-v2.sh scenario 4
# and perpetually reappear on every full-suite run. Skipped when herdr is not installed.
#
# WHY ORPHANS, not "any tab delta": this workspace is SHARED with real running agents. During the
# tens of seconds the suite runs, the live coordinator/watcher legitimately spawns and reaps real
# lane tabs (scribe-*, coordinator-*, feature slugs) and close+recreates tabs on gate cycles — a
# raw before/after tab diff false-fails on that churn. But every real lane tab is AGENT-BACKED:
# its agent_status is 'idle' or 'working'. A tab leaked by a hermetic test that escaped its stubs
# is an ORPHAN — herd-review.sh's standalone fallback creates a bare tab running 'tail -f' with NO
# controlling agent, so its agent_status is 'unknown' (or missing). So we count only ORPHAN tabs
# (status not idle/working) and their panes, and fail only on a NET INCREASE. Watcher recreates of
# an existing orphan net to zero; real lane churn never touches the orphan count. This is immune to
# concurrent activity while still catching the exact leak this PR fixes. SCOPING (issue #78): the scan
# is restricted to THIS project's OWN herdr workspace (WORKSPACE_NAME → workspace_id) so an orphan in a
# SIBLING project's workspace — or any other workspace entirely — never trips this guard; only a tab
# leaked into OUR workspace counts. (Residual: a real headless review·<slug> tab spawned by the watcher
# in this same window is also an orphan and could trip the guard — rare, transient, and self-heals on
# re-run; a genuine leak persists and re-trips.)
_hk_workspace_id() {
  # Resolve THIS project's herdr workspace id (WORKSPACE_NAME → workspace_id via 'herdr workspace
  # list'). Prints the id (no trailing newline) on success; empty when herdr is absent, the list
  # call fails, or WORKSPACE_NAME is unset/unmatched (e.g. coordinator has not created the workspace
  # yet). Used to SCOPE the orphan scan below to our OWN workspace only (issue #78).
  command -v herdr >/dev/null 2>&1 || return 0
  local _ws=""
  [ -f .herd/config ] && _ws="$(. .herd/config 2>/dev/null && printf '%s' "${WORKSPACE_NAME:-}")"
  [ -n "$_ws" ] || return 0
  herdr workspace list 2>/dev/null | LABEL="$_ws" python3 -c '
import sys, json, os
try:
    wss = (json.load(sys.stdin).get("result") or {}).get("workspaces") or []
    print(next((str(w.get("workspace_id", "")) for w in wss
                if str(w.get("label", "")) == os.environ["LABEL"]), ""), end="")
except Exception:
    pass
' 2>/dev/null || true
}

_hk_orphans() {
  # Emits 'orphan-tabs:<N>' and 'orphan-panes:<M>' — N = live tabs with no controlling agent
  # (agent_status not in idle/working), M = their combined pane_count. Empty when herdr absent.
  # SCOPED to $1 (this project's workspace id) when non-empty, so orphans in a SIBLING project's
  # workspace are never counted (issue #78); falls back to ALL workspaces when $1 is empty (herdr
  # present but our workspace unresolved — no worse than the pre-#78 behaviour). Read-only; never
  # mutates the workspace.
  command -v herdr >/dev/null 2>&1 || return 0
  herdr tab list 2>/dev/null | WSID="${1:-}" python3 -c '
import sys, json, os
try:
    tabs = (json.load(sys.stdin).get("result") or {}).get("tabs") or []
    wsid = os.environ.get("WSID", "")
    if wsid:
        # Scope to THIS project workspace — ignore tabs owned by any other workspace.
        tabs = [t for t in tabs if str(t.get("workspace_id", "")) == wsid]
    orphans = [t for t in tabs if str(t.get("agent_status", "")) not in ("idle", "working")]
    print("orphan-tabs:%d" % len(orphans))
    print("orphan-panes:%d" % sum(int(t.get("pane_count", 0) or 0) for t in orphans))
    # Emit the orphan labels too so a real leak can be named in the failure message.
    for lbl in sorted(str(t.get("label", "")) for t in orphans):
        print("orphan-label:" + lbl)
except Exception:
    pass
' 2>/dev/null || true
}
# Resolve our workspace ONCE and reuse it for both the before and after snapshots, so the two are
# scoped identically (issue #78 — the scan must never count another workspace's or sibling project's
# tab, in either snapshot).
_hk_wsid="$(_hk_workspace_id)"
_hk_orphans_before="$(_hk_orphans "$_hk_wsid")"

t_note="tests: none"
if command -v bats >/dev/null 2>&1 && ls tests/*.bats >/dev/null 2>&1; then
  if to="$(bats tests/*.bats 2>&1)"; then t_note="tests: bats pass"; else
    [ -n "$ONELINE" ] && echo "bats: $(printf '%s' "$to" | tail -1)" || { echo "BATS FAILED"; printf '%s\n' "$to"; }
    exit 1
  fi
elif ls tests/test-*.sh >/dev/null 2>&1; then
  fails=0
  for t in tests/test-*.sh; do bash "$t" >/dev/null 2>&1 || fails=$((fails+1)); done
  if [ "$fails" -eq 0 ]; then t_note="tests: hermetic suite pass"; else
    [ -n "$ONELINE" ] && echo "tests: $fails failed" || echo "TESTS FAILED: $fails"
    exit 1
  fi
fi

# Leak-guard verdict: fail LOUDLY on a NET INCREASE in orphan tabs or orphan panes.
leak_note="tab-leak-guard: clean"
if command -v herdr >/dev/null 2>&1; then
  _hk_orphans_after="$(_hk_orphans "$_hk_wsid")"
  _hk_leak="$(BEF="$_hk_orphans_before" AFT="$_hk_orphans_after" python3 -c '
import os
def parse(s):
    tabs = panes = 0
    labels = []
    for line in s.splitlines():
        if line.startswith("orphan-tabs:"):  tabs  = int(line.split(":",1)[1] or 0)
        elif line.startswith("orphan-panes:"): panes = int(line.split(":",1)[1] or 0)
        elif line.startswith("orphan-label:"): labels.append(line.split(":",1)[1])
    return tabs, panes, labels
bt, bp, bl = parse(os.environ["BEF"])
at, ap, al = parse(os.environ["AFT"])
if at > bt or ap > bp:
    # Name the orphan label(s) present after but not before, best-effort.
    from collections import Counter
    new = list((Counter(al) - Counter(bl)).elements())
    print("orphan tabs %d->%d, orphan panes %d->%d%s" % (
        bt, at, bp, ap, (" — new: " + ", ".join(sorted(new))) if new else ""))
' 2>/dev/null || true)"
  if [ -n "$_hk_leak" ]; then
    if [ -n "$ONELINE" ]; then
      echo "tab-leak-guard: suite leaked an orphan tab into the live workspace — $_hk_leak"
    else
      echo "TAB-LEAK-GUARD: the test suite left an orphan tab/pane in the live workspace"
      echo "  (a hermetic test escaped its stubs and created a real, agent-less herdr tab)"
      echo "  $_hk_leak"
    fi
    exit 1
  fi
else
  leak_note="tab-leak-guard: skipped (herdr not installed)"
fi

# 4. leak-guard — no single-consumer (Northstar) literal may leak into the generic engine.
# The pattern list lives HERE in .herd/ (outside the scanned surface: scripts/herd + bin/herd +
# templates), so this guard never matches itself. The documented generic placeholder
# "$HOME/source/myproject" in templates/config.example is allowed; everything else under
# $HOME/source/ is a hardcoded leak.
lg_note="leak-guard: clean"
leak_pat='northstar|/Users/macbookpro|\$HOME/source/|streamlit|app/dashboard\.py'
leak_files=()
while IFS= read -r f; do [ -n "$f" ] && leak_files+=("$f"); done < <(
  { find scripts/herd -type f 2>/dev/null
    [ -f bin/herd ] && echo bin/herd
    find templates -type f 2>/dev/null; } | sort -u
)
if [ "${#leak_files[@]}" -gt 0 ]; then
  if hits="$(grep -HinE "$leak_pat" "${leak_files[@]}" 2>/dev/null | grep -vE '\$HOME/source/myproject')"; then
    [ -n "$ONELINE" ] && echo "leak-guard: $(printf '%s' "$hits" | head -1)" \
      || { echo "LEAK-GUARD: single-consumer literal in generic engine"; printf '%s\n' "$hits"; }
    exit 1
  fi
fi

# 5. caps-sync guard — a PR adding a cmd_* subcommand to bin/herd, a new config key to
# herd-config.sh, or a new lane script under scripts/herd/ without also touching
# templates/capabilities.tsv is a CODE error (the manifest must stay in sync).
caps_note="caps-sync: clean"
_hc_branch="origin/main"
if [ -f .herd/config ]; then
  _hc_branch="$(. .herd/config 2>/dev/null && printf '%s' "${DEFAULT_BRANCH:-origin/main}")" \
    || _hc_branch="origin/main"
fi
if _hc_changed="$(git diff --name-only "$_hc_branch" 2>/dev/null)"; then
  _hc_manifest_touched=0
  case "$_hc_changed" in *"templates/capabilities.tsv"*) _hc_manifest_touched=1 ;; esac
  _hc_sync_errs=""

  if printf '%s\n' "$_hc_changed" | grep -qxE 'bin/herd'; then
    _hc_new_cmds="$(git diff "$_hc_branch" -- bin/herd 2>/dev/null \
      | grep -E '^\+[[:space:]]*cmd_[a-z_]+\(\)' || true)"
    if [ -n "$_hc_new_cmds" ] && [ "$_hc_manifest_touched" -eq 0 ]; then
      _hc_sync_errs="${_hc_sync_errs}bin/herd adds cmd_*: also update templates/capabilities.tsv"$'\n'
    fi
  fi

  if printf '%s\n' "$_hc_changed" | grep -qxE 'scripts/herd/herd-config\.sh'; then
    _hc_new_keys="$(git diff "$_hc_branch" -- scripts/herd/herd-config.sh 2>/dev/null \
      | grep -E '^\+[[:space:]]*:[[:space:]]+"?\$\{[A-Z_]+:=' || true)"
    if [ -n "$_hc_new_keys" ] && [ "$_hc_manifest_touched" -eq 0 ]; then
      _hc_sync_errs="${_hc_sync_errs}herd-config.sh adds config keys: also update templates/capabilities.tsv"$'\n'
    fi
  fi

  _hc_added_lanes="$(git diff --diff-filter=A --name-only "$_hc_branch" 2>/dev/null \
    | grep -Ex 'scripts/herd/[^/]+\.sh' | grep -vxE 'scripts/herd/herd-config\.sh' || true)"
  if [ -n "$_hc_added_lanes" ] && [ "$_hc_manifest_touched" -eq 0 ]; then
    _hc_sync_errs="${_hc_sync_errs}new lane script added: also update templates/capabilities.tsv"$'\n'
  fi

  if [ -n "$_hc_sync_errs" ]; then
    caps_note="caps-sync: VIOLATION"
    if [ -n "$ONELINE" ]; then
      echo "caps-sync: $(printf '%s' "$_hc_sync_errs" | head -1)"
    else
      echo "CAPS-SYNC: capabilities manifest not updated alongside engine change"
      printf '%s' "$_hc_sync_errs"
    fi
    exit 1
  fi
else
  caps_note="caps-sync: skipped (no diff against $_hc_branch)"
fi

[ -n "$ONELINE" ] && echo "clean — bash -n ok; $sc_note; $t_note; $leak_note; $lg_note; $caps_note" || { echo "HEALTHCHECK CLEAN"; echo "  $sc_note"; echo "  $t_note"; echo "  $leak_note"; echo "  $lg_note"; echo "  $caps_note"; }
exit 0
