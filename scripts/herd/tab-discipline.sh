#!/usr/bin/env bash
# tab-discipline.sh — THE RECONCILED TAB-DISCIPLINE SWEEP (HERD-569): the workspace's tab bar is
# reconciled against the set of tabs the invariant allows, every sweep cadence, by whichever seat's
# watcher gets there first.
#
# THE INVARIANT
# -------------
# Operator directive, 2026-08-05, verbatim: "there shouldn't be ANY other tabs spawned other than
# builders, or the scribe". The tab bar is the operator's SITUATIONAL-AWARENESS surface — one glance
# has to answer "what is the herd doing right now?" — so a tab that is neither a builder, the scribe,
# nor the control room is not a feature, it is noise that costs a re-read every time the eye passes.
#
# WHY A RECONCILE AND NOT A HOOK (docs/multi-seat-doctrine.md rule 1)
# -------------------------------------------------------------------
# The obvious fix is to stop each spawner from opening a tab. That is the CREATION LINT's job
# (scripts/herd/tab-create-lint.sh) and it is only half the property: a lint cannot see a tab opened
# by another seat, by an older build still running in the next window, or by a hand-run script. This
# sweep reconciles OBSERVED tabs against the registry, so the invariant holds regardless of WHO
# created the stray or WHEN — which is what makes it enforceable from any seat.
#
# THE ALLOWED SET — everything else is a stray
#   (a) a REGISTERED BUILDER TAB — a $TREES/.herd-tabs row whose kind field is `builder`;
#   (b) a LIVE BUILDER WORKTREE's tab — a tab whose label is the basename of a directory in
#       $WORKTREES_DIR. Belt to (a)'s braces: the registry write is best-effort (herd-review.sh
#       journals tab_registry_write_failed when it misses), and a builder whose row did not land must
#       NOT be vaporised for the engine's own bookkeeping slip;
#   (c) the SCRIBE drainer's tab ($HERD_AGENT_SCRIBE);
#   (d) the CONTROL ROOM's tab ($HERD_TAB_COORDINATOR, plus $HERD_WATCHER_TAB_ID — the id the watcher
#       was handed at spawn, so this sweep can never close the tab it is running in);
#   (e) a label matching a `label` row in templates/tab-discipline-exempt.tsv — the committed record
#       of the lanes that still, deliberately, own a tab (each paired with the `callsite` row that
#       lets the lint pass, so the two halves cannot drift apart).
#
# SAFETY: THIS FUNCTION CLOSES THINGS, SO EVERY UNKNOWN IS A REFUSAL
# ------------------------------------------------------------------
# A deny-list sweep is the inverse of agent-watch.sh's allowlist orphan sweep, and it fails in the
# opposite direction: where the orphan sweep's worst case is a stray tab that survives, this one's is
# a live builder that does not. Every input that could be missing is therefore a REFUSAL, not a
# guess:
#   • the workspace id is unresolvable  → sweep NOTHING. Scoping to this workspace's id is the whole
#     defence against the cross-project kill (issue #60): another project's tabs are not this
#     engine's business, and an unscoped enumeration is exactly how that lesson was learned.
#   • $TREES/.herd-tabs is absent       → sweep NOTHING. With no registry there is no way to tell a
#     builder tab from a stray, and "retire everything unrecognised" against a full tab bar is the
#     catastrophic outcome this guard exists to prevent. An empty tab bar is not worth that risk.
#   • herdr unreachable / headless / dry-run → sweep NOTHING, byte-quiet (fail-soft, per AGENTS.md).
#   • more strays than $HERD_TAB_DISCIPLINE_MAX (default 5) in one pass → retire the cap's worth and
#     journal the remainder. A sweep that suddenly wants to close a dozen tabs is likelier to be a
#     bad read of the world than a dozen real strays; the cap turns that into a slow, visible drain
#     instead of a one-tick wipe, and the next cadence takes the rest if it was real.
#
# SHIP-DORMANT (AGENTS.md): $TAB_DISCIPLINE defaults to `off` and off is a HARD no-op — no herdr call,
# no journal line, no file read. `report` detects and journals `tab_discipline_stray` WITHOUT closing
# anything (the safe way to watch what the sweep would do on a real control room); `on` retires and
# journals `tab_discipline_retired`. An unrecognized value reads `off`, so a typo can never arm a
# tab-closing path.
#
# Functions:
#   herd_tab_discipline_mode                 → echo off | report | on
#   herd_tab_discipline_exempt_file [<root>] → echo the resolved exemption-table path (may not exist)
#   herd_tab_discipline_classify             → PURE: `herdr tab list` JSON on stdin + env → strays
#   herd_tab_discipline_strays               → live wrapper: gather the world, print the strays
#   herd_tab_discipline_sweep                → the ACTION wrapper (close + journal + registry prune)
#
# Sourced by agent-watch.sh (the cadence caller). The classifier is a pure function of its stdin and
# environment so the hermetic tests can prove the allow rules without a herdr socket, and the P2b
# real-panes sim can prove the same rules against REAL tabs.

HERD_TAB_DISCIPLINE_SKIP_REASON=""

# herd_tab_discipline_mode — echo "on" | "report" | "off". Fail-soft: empty/unset/typo reads off, so
# an unrecognized value can never arm a pane-closing path (mirrors _effective_health_pane).
herd_tab_discipline_mode() {
  case "${TAB_DISCIPLINE:-off}" in
    on|true|yes|1) printf 'on' ;;
    report|advise|dry|dry-run) printf 'report' ;;
    *) printf 'off' ;;
  esac
}

# herd_tab_discipline_exempt_file [<root>] — the committed exemption table. Resolved from the engine
# home ($HERDKIT_HOME, else this file's own tree) so the SWEEP reads the same table the LINT does,
# whichever checkout the watcher is running from. Echoes a path; the caller tolerates its absence.
herd_tab_discipline_exempt_file() {
  local _td_root="${1:-}"
  if [ -z "$_td_root" ]; then
    _td_root="${HERDKIT_HOME:-}"
    if [ -z "$_td_root" ]; then
      local _td_here; _td_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || _td_here=""
      [ -n "$_td_here" ] && _td_root="$(cd "$_td_here/../.." 2>/dev/null && pwd)"
    fi
  fi
  [ -n "$_td_root" ] || return 0
  printf '%s/templates/tab-discipline-exempt.tsv' "$_td_root"
}

# herd_tab_discipline_classify — PURE. Reads `herdr tab list` JSON on stdin; prints one
# '<tab_id><TAB><label><TAB><reason>' line per STRAY. Everything it needs arrives in the environment
# so a fixture can drive it with no herdr, no worktrees and no config:
#   WS            REQUIRED workspace id. Empty ⇒ print nothing (never sweep unscoped).
#   REGISTRY      REQUIRED path to .herd-tabs. Absent/unreadable ⇒ print nothing.
#   BUILDER_KINDS space-separated registry kinds that count as a builder tab (default: "builder").
#   SCRIBE_LABEL  the scribe drainer's tab label.        COORD_LABEL  the control-room tab label.
#   SELF_TAB      this watcher's own tab id.             LIVE_SLUGS   newline list of worktree slugs.
#   EXEMPT_FILE   the exemption table (label rows).
# reason is `unregistered` (no registry row at all) or `kind:<k>` (a row, but not a builder's) — the
# operator-facing WHY that rides the journal event.
herd_tab_discipline_classify() {
  python3 -c '
import sys, json, os, fnmatch

ws       = os.environ.get("WS", "")
reg_path = os.environ.get("REGISTRY", "")
kinds    = set((os.environ.get("BUILDER_KINDS") or "builder").split())
scribe   = os.environ.get("SCRIBE_LABEL", "")
coord    = os.environ.get("COORD_LABEL", "")
self_tab = os.environ.get("SELF_TAB", "")
live     = set(os.environ.get("LIVE_SLUGS", "").split("\n")) - {""}
exempt_f = os.environ.get("EXEMPT_FILE", "")

# REFUSE rather than guess: no workspace scope, or no registry to tell a builder from a stray, means
# this pass has no safe opinion about any tab.
if not ws:
    raise SystemExit(0)
try:
    with open(reg_path, encoding="utf-8") as rf:
        rows = rf.readlines()
except Exception:
    raise SystemExit(0)

# registry: tab_id -> kind. Row shape is "<label> <tab_id> <kind>" (herd-feature/quick/driver/
# resolve/review/health all append it); a kind-less legacy row is NOT a builder claim.
registry = {}
for line in rows:
    parts = line.strip().split(" ", 2)
    if len(parts) >= 3 and parts[1]:
        registry[parts[1]] = parts[2].strip()

globs = []
try:
    with open(exempt_f, encoding="utf-8") as ef:
        for line in ef:
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            cols = line.rstrip("\n").split("\t")
            # kind, pattern, reason — a reason-less row is a malformed DECISION and excuses nothing
            # (the lint reds it as EXEMPT-MALFORMED; the sweep simply ignores it).
            if len(cols) >= 3 and cols[0] == "label" and cols[1] and cols[2].strip():
                globs.append(cols[1])
except Exception:
    pass

try:
    tabs = json.load(sys.stdin).get("result", {}).get("tabs", [])
except Exception:
    raise SystemExit(0)

for t in tabs:
    tab_id = t.get("tab_id", "") or ""
    label  = t.get("label", "") or ""
    if not tab_id or not label:
        continue                                   # cannot classify it ⇒ never touch it
    if t.get("workspace_id", "") != ws:
        continue                                   # another project entirely — not ours to reap
    if self_tab and tab_id == self_tab:
        continue                                   # (d) the tab this watcher is running in
    if label in (scribe, coord) and label:
        continue                                   # (c)/(d) the scribe and the control room
    if label in live:
        continue                                   # (b) a live builder worktree, registry row or not
    if any(fnmatch.fnmatchcase(label, g) for g in globs):
        continue                                   # (e) a committed, paired exemption
    kind = registry.get(tab_id)
    if kind in kinds:
        continue                                   # (a) a registered builder tab
    reason = "unregistered" if kind is None else ("kind:" + (kind or "?"))
    print("%s\t%s\t%s" % (tab_id, label, reason))
' 2>/dev/null || true
}

# herd_tab_discipline_strays — the live wrapper: gather this workspace's tabs and the world the
# classifier judges them against, then print its '<tab_id><TAB><label><TAB><reason>' lines. Touches
# NOTHING (the detection/action split agent-watch.sh's _orphan_tab_ids uses, so `herd sweep`-style
# narration and the live sweep can never disagree about what is a stray). Byte-quiet on every
# fail-soft path, with the why left in $HERD_TAB_DISCIPLINE_SKIP_REASON.
herd_tab_discipline_strays() {
  HERD_TAB_DISCIPLINE_SKIP_REASON=""
  if ! command -v herdr >/dev/null 2>&1; then
    HERD_TAB_DISCIPLINE_SKIP_REASON="herdr not available"; return 0
  fi
  local _td_ws; _td_ws="$(herd_resolve_workspace_id 2>/dev/null || true)"
  if [ -z "$_td_ws" ]; then
    HERD_TAB_DISCIPLINE_SKIP_REASON="workspace id unresolvable — refusing to sweep unscoped"; return 0
  fi
  local _td_trees="${TREES:-${WORKTREES_DIR:-}}"
  local _td_reg="$_td_trees/.herd-tabs"
  if [ -z "$_td_trees" ] || [ ! -f "$_td_reg" ]; then
    HERD_TAB_DISCIPLINE_SKIP_REASON="no tab registry at ${_td_reg:-<unset>} — cannot tell a builder tab from a stray"
    return 0
  fi
  local _td_tabs; _td_tabs="$(herdr tab list --workspace "$_td_ws" 2>/dev/null || true)"
  if [ -z "$_td_tabs" ]; then
    HERD_TAB_DISCIPLINE_SKIP_REASON="herdr returned no tab list (mux unreachable)"; return 0
  fi

  # Live builder slugs = the worktree pool's directory names. Cheap (no git call), and it is the same
  # ground truth the spawn gate counts builders from.
  local _td_live="" _td_d
  for _td_d in "$_td_trees"/*/; do
    [ -d "$_td_d" ] || continue
    _td_d="${_td_d%/}"
    _td_live="${_td_live}${_td_d##*/}"$'\n'
  done

  printf '%s' "$_td_tabs" | WS="$_td_ws" REGISTRY="$_td_reg" \
    SCRIBE_LABEL="${HERD_AGENT_SCRIBE:-}" COORD_LABEL="${HERD_TAB_COORDINATOR:-}" \
    SELF_TAB="${HERD_WATCHER_TAB_ID:-}" LIVE_SLUGS="$_td_live" \
    EXEMPT_FILE="$(herd_tab_discipline_exempt_file)" \
    herd_tab_discipline_classify
}

# herd_tab_discipline_sweep — the ACTION wrapper. Retires each stray through `herdr tab close`,
# journals `tab_discipline_retired` (label + reason — loud, never silent, per the item), and prunes any
# registry row the tab left behind. Under TAB_DISCIPLINE=report it journals `tab_discipline_stray` and
# closes NOTHING. Dry-run-inert; byte-quiet when there are no strays.
herd_tab_discipline_sweep() {
  local _td_mode; _td_mode="$(herd_tab_discipline_mode)"
  [ "$_td_mode" = off ] && return 0
  [ -z "${DRYRUN:-}" ] || return 0
  if command -v _herd_driver_is_headless >/dev/null 2>&1 && _herd_driver_is_headless; then return 0; fi
  # HERD-310: closing LIVE tabs from a builder worktree severs the operator's real control room. The
  # guard is a no-op from the control room (the watcher runs from the main checkout), so a real sweep
  # is byte-identical; a test driving this from a worktree is REFUSED and journaled.
  if command -v herd_context_pane_guard >/dev/null 2>&1 \
     && ! herd_context_pane_guard "herd_tab_discipline_sweep (stray tab close)"; then
    return 0
  fi

  local _td_strays; _td_strays="$(herd_tab_discipline_strays)"
  [ -n "$_td_strays" ] || return 0

  local _td_max="${HERD_TAB_DISCIPLINE_MAX:-5}" _td_done=0 _td_seen=0
  local _td_id _td_label _td_reason
  while IFS=$'\t' read -r _td_id _td_label _td_reason; do
    [ -n "$_td_id" ] || continue
    _td_seen=$((_td_seen + 1))
    if [ "$_td_mode" = report ]; then
      _td_can_journal && journal_append tab_discipline_stray tab_id "$_td_id" label "$_td_label" reason "$_td_reason" mode report
      continue
    fi
    if [ "$_td_done" -ge "$_td_max" ]; then continue; fi
    herdr tab close "$_td_id" >/dev/null 2>&1 || true
    _td_done=$((_td_done + 1))
    _td_can_journal && journal_append tab_discipline_retired tab_id "$_td_id" label "$_td_label" reason "$_td_reason"
    # A stray CAN carry a registry row (a review·/health· row whose kind is not `builder`); drop it so
    # the row does not outlive its tab and inflate the stale-tab tally (HERD-215's lesson).
    if command -v _herd_tabs_drop_row >/dev/null 2>&1; then
      _herd_tabs_drop_row "${TREES:-${WORKTREES_DIR:-.}}/.herd-tabs" "$_td_id"
    fi
  done <<EOF
$_td_strays
EOF

  if [ "$_td_mode" != report ] && [ "$_td_seen" -gt "$_td_done" ]; then
    _td_can_journal && journal_append tab_discipline_capped found "$_td_seen" retired "$_td_done" cap "$_td_max"
  fi
  return 0
}

# _td_can_journal — true when a journal is in scope. tab-discipline.sh is sourced by the watcher
# (which has journal.sh) but also by fixtures that do not, and a sweep must never abort on the absence
# of its own telemetry. Deliberately a PREDICATE rather than a `_td_journal <event> …` wrapper: the
# emission lint (HERD-442) resolves producers from the LITERAL event name at the journal_append call,
# and a wrapper forwarding "$@" hides every one of these events from it — which is exactly the
# consumer-with-no-visible-producer shape that lint exists to catch.
_td_can_journal() { command -v journal_append >/dev/null 2>&1; }
