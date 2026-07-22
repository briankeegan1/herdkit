#!/usr/bin/env bash
# test-stale-resolve-tab-sweep.sh — hermetic tests for the STALE resolve-tab sweep (HERD-54): the
# proactive teardown of a resolve·<slug> conflict-resolver tab whose resolver finished/died AND whose
# PR is no longer CONFLICTING. Exercises agent-watch.sh in lib mode (AGENT_WATCH_LIB=1) with gh/herdr
# stubbed on PATH so NO network / real tab is ever touched.
#
# SAFETY INVARIANT under test: a tab is swept ONLY when BOTH (1) no live resolver agent for its slug
# (shared _resolver_agent_alive liveness with the resolver-respawn path, HERD-55) AND (2) the slug's
# PR is no longer CONFLICTING (absent from the open-PR list ⇒ merged/closed, or mergeable clean). A
# live resolver is ALWAYS spared; a still-CONFLICTING (or transient UNKNOWN) PR is left alone.
#
#   (1) helpers defined after sourcing
#   (2) _herd_tabs_drop_row prunes exactly one row, leaving the others byte-identical
#   (3) STALE: dead resolver + PR absent (merged/closed) → swept, row pruned, reason=stale-sweep
#   (4) STALE: dead resolver + PR mergeable clean → swept
#   (5) LIVE-SPARED: resolver agent alive → NOT swept even though the PR is clean
#   (6) CONFLICTING-NOOP: dead resolver but PR still CONFLICTING → NOT swept
#   (7) UNKNOWN-NOOP: dead resolver but PR mergeable UNKNOWN (transient) → NOT swept
#   (8) non-resolve registry rows (builder/review·) are never touched
#   (9) dry-run is inert
#
# Run:  bash tests/test-stale-resolve-tab-sweep.sh
# No `set -e`: several checks assert conditions explicitly.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../scripts/herd/agent-watch.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

[ -f "$WATCH" ] || fail "agent-watch.sh not found at $WATCH"
command -v python3 >/dev/null 2>&1 || fail "python3 required to run this test"

# ── Stub binaries on PATH (NETWORK-FREE) ──────────────────────────────────────
BIN="$T/bin"; mkdir -p "$BIN"
# gh: `gh pr list --json ...` → emit the fixture JSON from $GH_PRLIST (open PRs only, real behavior);
# everything else is a no-op. Log every call so we can assert the sweep is byte-inert when it should be.
export GH_LOG="$T/gh.log"; : > "$GH_LOG"
export GH_PRLIST="$T/prlist.json"; printf '[]\n' > "$GH_PRLIST"
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "list" ]; then
  cat "$GH_PRLIST" 2>/dev/null
fi
exit 0
STUB
# herdr: log calls; `tab close <id>` records the closed id; the list subcommands return empty-but-valid
# JSON so herd_resolve_workspace_id and any tab-list parse paths no-op cleanly.
export HERDR_LOG="$T/herdr.log"; : > "$HERDR_LOG"
export CLOSED="$T/closed.log"; : > "$CLOSED"
cat > "$BIN/herdr" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HERDR_LOG"
case "${1:-} ${2:-}" in
  "tab close") printf '%s\n' "${3:-}" >> "$CLOSED" ;;
  "workspace list") printf '{"result":{"workspaces":[]}}\n' ;;
  "tab list")       printf '{"result":{"tabs":[]}}\n' ;;
esac
exit 0
STUB
chmod +x "$BIN/gh" "$BIN/herdr"
export PATH="$BIN:$PATH"

# ── Source agent-watch.sh in lib mode ─────────────────────────────────────────
export AGENT_WATCH_LIB=1
export PROJECT_ROOT="$T/main"; mkdir -p "$PROJECT_ROOT"
export WORKTREES_DIR="$T/trees"; mkdir -p "$WORKTREES_DIR"      # TREES + registry live here
# HERD-310: hermetic sweep on a THROWAWAY fixture workspace with a STUB herdr — declare it disposable
# so herd_context_pane_guard allows the fixture tab closes (see test-sweep.sh for the full rationale).
export HERD_DISPOSABLE_WORKSPACE=1
export HERD_CONFIG_FILE="$T/no-such-config"
export JOURNAL_FILE="$T/journal.jsonl"; : > "$JOURNAL_FILE"
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"

REG="$WORKTREES_DIR/.herd-tabs"
reaped_events() { grep -c '"event":"reap_resolve_tab"' "$JOURNAL_FILE" 2>/dev/null || true; }
row_present()   { grep -qxF "$1" "$REG" 2>/dev/null; }
was_closed()    { grep -qxF "$1" "$CLOSED" 2>/dev/null; }

# ── fixtures ──────────────────────────────────────────────────────────────────
# agents_json <slug>...  — a driver roster JSON naming a live resolve·<slug> agent for each slug.
# HERD-418: herdr stores the SANITIZED name, never the raw dotted role — mirror that here.
agents_json() {
  local names="" s
  for s in "$@"; do names="${names:+$names, }{\"name\": \"$(herd_agent_name_sanitize "resolve·$s")\", \"agent_status\": \"working\"}"; done
  printf '{"result":{"agents":[%s]}}' "$names"
}
# pr_list "slug mergeable" ...  — fixture open-PR list (branch feat/<slug>, given mergeable state).
pr_list() {
  { printf '['
    local first=1 pair slug mrg
    for pair in "$@"; do slug="${pair%% *}"; mrg="${pair#* }"
      [ "$first" = 1 ] || printf ','; first=0
      printf '{"headRefName":"feat/%s","mergeable":"%s"}' "$slug" "$mrg"
    done
    printf ']\n'
  } > "$GH_PRLIST"
}
# reset per-scenario transient state
reset() { : > "$JOURNAL_FILE"; : > "$GH_LOG"; : > "$HERDR_LOG"; : > "$CLOSED"; : > "$REG"; printf '[]\n' > "$GH_PRLIST"; AGENTS_JSON='{"result":{"agents":[]}}'; }

# ── (1) helpers defined ───────────────────────────────────────────────────────
type _sweep_stale_resolve_tabs >/dev/null 2>&1 || fail "_sweep_stale_resolve_tabs not defined"
type _herd_tabs_drop_row       >/dev/null 2>&1 || fail "_herd_tabs_drop_row not defined"
type _resolver_agent_alive     >/dev/null 2>&1 || fail "_resolver_agent_alive not defined (shared liveness helper)"
[ "$TREES" = "$WORKTREES_DIR" ] || fail "TREES did not resolve to WORKTREES_DIR"
ok

# ── (2) _herd_tabs_drop_row prunes exactly one row ────────────────────────────
reset
{ printf 'resolve·aa tab-1 resolve\n'; printf 'bb tab-2 builder\n'; printf 'resolve·cc tab-3 resolve\n'; } > "$REG"
_herd_tabs_drop_row "$REG" tab-2
row_present 'resolve·aa tab-1 resolve' || fail "drop_row removed an unrelated row (tab-1)"
row_present 'resolve·cc tab-3 resolve' || fail "drop_row removed an unrelated row (tab-3)"
row_present 'bb tab-2 builder'         && fail "drop_row did not remove tab-2"
ok

# ── (3) STALE: dead resolver + PR absent (merged/closed) → swept ──────────────
reset
printf 'resolve·gone tab-gone resolve\n' > "$REG"
AGENTS_JSON="$(agents_json)"        # no live resolvers
pr_list                             # no open PRs → the slug's PR is merged/closed
_sweep_stale_resolve_tabs
was_closed tab-gone                              || fail "stale tab (PR merged/closed) was not closed"
[ "$(reaped_events)" -ge 1 ]                     || fail "sweep did not journal a reap_resolve_tab event"
grep -q '"reason":"stale-sweep"' "$JOURNAL_FILE" || fail "reap not journaled reason=stale-sweep"
grep -q '"slug":"gone"'          "$JOURNAL_FILE" || fail "reap did not name the stale slug"
row_present 'resolve·gone tab-gone resolve'      && fail "swept tab was not pruned from the registry"
ok

# ── (4) STALE: dead resolver + PR mergeable clean → swept ─────────────────────
reset
printf 'resolve·clean tab-clean resolve\n' > "$REG"
AGENTS_JSON="$(agents_json)"
pr_list "clean MERGEABLE"
_sweep_stale_resolve_tabs
was_closed tab-clean                        || fail "stale tab (PR clean) was not closed"
row_present 'resolve·clean tab-clean resolve' && fail "swept tab (clean) not pruned from registry"
ok

# ── (5) LIVE-SPARED: resolver agent alive → NOT swept (even with a clean PR) ──
reset
printf 'resolve·live tab-live resolve\n' > "$REG"
AGENTS_JSON="$(agents_json live)"   # a working resolve·live agent in the roster
pr_list "live MERGEABLE"
_sweep_stale_resolve_tabs
was_closed tab-live                        && fail "SAFETY VIOLATION: closed a tab with a live resolver agent"
[ "$(reaped_events)" -eq 0 ]               || fail "journaled a reap for a live-resolver tab"
row_present 'resolve·live tab-live resolve' || fail "live-spared tab wrongly pruned from registry"
ok

# ── (6) CONFLICTING-NOOP: dead resolver but PR still CONFLICTING → NOT swept ──
reset
printf 'resolve·conf tab-conf resolve\n' > "$REG"
AGENTS_JSON="$(agents_json)"
pr_list "conf CONFLICTING"
_sweep_stale_resolve_tabs
was_closed tab-conf                        && fail "closed a tab whose PR is still CONFLICTING"
[ "$(reaped_events)" -eq 0 ]               || fail "journaled a reap for a still-conflicting PR"
row_present 'resolve·conf tab-conf resolve' || fail "still-conflicting tab wrongly pruned"
ok

# ── (7) UNKNOWN-NOOP: dead resolver but mergeable UNKNOWN (transient) → NOT swept
reset
printf 'resolve·unk tab-unk resolve\n' > "$REG"
AGENTS_JSON="$(agents_json)"
pr_list "unk UNKNOWN"
_sweep_stale_resolve_tabs
was_closed tab-unk                       && fail "closed a tab whose PR mergeable is UNKNOWN (transient)"
[ "$(reaped_events)" -eq 0 ]             || fail "journaled a reap for an UNKNOWN-mergeable PR"
ok

# ── (8) non-resolve rows are never touched; a swept resolve row leaves them intact
reset
{ printf 'builder-slug tab-b builder\n'; printf 'review·rev tab-r review\n'; printf 'resolve·st tab-st resolve\n'; } > "$REG"
AGENTS_JSON="$(agents_json)"
pr_list      # all PRs merged/closed → resolve·st is stale
_sweep_stale_resolve_tabs
was_closed tab-st                     || fail "stale resolve row not swept alongside non-resolve rows"
was_closed tab-b                      && fail "sweep closed a plain builder tab"
was_closed tab-r                      && fail "sweep closed a review· tab"
row_present 'builder-slug tab-b builder' || fail "sweep pruned a builder row"
row_present 'review·rev tab-r review'    || fail "sweep pruned a review· row"
row_present 'resolve·st tab-st resolve'  && fail "swept resolve row not pruned"
ok

# ── (9) dry-run is inert ──────────────────────────────────────────────────────
reset
printf 'resolve·dry tab-dry resolve\n' > "$REG"
AGENTS_JSON="$(agents_json)"
pr_list
DRYRUN=1 _sweep_stale_resolve_tabs
was_closed tab-dry                      && fail "dry-run closed a tab"
[ "$(reaped_events)" -eq 0 ]            || fail "dry-run journaled a reap"
row_present 'resolve·dry tab-dry resolve' || fail "dry-run pruned the registry"
[ -s "$GH_LOG" ]                        && fail "dry-run made a gh call"
ok

echo "PASS: test-stale-resolve-tab-sweep.sh ($pass checks)"
