#!/usr/bin/env bash
# test-health-pane-lifecycle.sh — hermetic tests for the HEALTH_PANE disposable-pane lifecycle
# (HERD-313 leg a, placement fixed by HERD-568). The in-flight healthcheck can be mirrored into a
# stamped `health·<slug>` VIEW pane that streams the live suite log and is retired the instant the
# suite ends. Modelled on the resolver pane (tests/test-resolver-pane-lifecycle.sh):
#   (1) LEVER OFF (the HEALTH_PANE=off default): _spawn_health_pane is a HARD no-op — no herdr call, no
#       registry row — and the reconcile is byte-inert (no pane touched, no journal line).
#   (2) UNKNOWN VALUE reads OFF (a typo can never arm a pane-closing path).
#   (3) LEVER ON, NO BUILDER TAB: _spawn_health_pane falls back to a standalone `health·<slug>` tab,
#       stamps its label, records "pane tab tab health·<slug>" in the sha-scoped registry, and journals
#       the no-builder-tab reason.
#   (4) IDEMPOTENT: a second spawn for the same (pr,sha) creates no second pane.
#   (5) IN-FLIGHT KEEP: while the (pr,sha) inflight marker is pid-live the reconcile keeps the pane.
#   (6) RETIRE-ON-OUTCOME: once the marker is gone the reconcile closes the pane through the guarded
#       close, journals health_pane_retired, drops the row, and — in `tab` placement only — closes the
#       now-empty tab + its .herd-tabs allowlist row.
#   (7) GUARDED CLOSE (HERD-134): a registry id that now labels a NON-health pane is REFUSED, not closed.
#   (8) BYTE-QUIET with no health-pane rows: no herdr call, no close, no journal line.
#   (9) DRY-RUN INERT: a render must never close (or spawn) a pane.
#  (10) HEADLESS INERT: view-only driver stands up no pane even with the lever on.
#
# HERD-554 turned the reconcile into a FULL invariant — one pane per OBSERVED in-flight suite, asserted
# both ways every tick off the `.health-inflight-<pr>-<sha>` markers instead of a bash dispatch-site
# hook, so the lever finally works under ENGINE_IMPL=python. Its cases (numbered 11–18 in the body):
#  (11) PYTHON-STYLE DISPATCH: a marker + live log and NOTHING else gains a pane on the reconcile pass.
#  (12) IDEMPOTENT ACROSS TICKS: a second tick neither duplicates nor closes the live pane.
#  (13) ROUND TRIP: the same reconcile retires the pane it created, and never re-creates it after.
#  (14) LEVER OFF (and a typo value): a live suite + a matching worktree row creates NOTHING.
#  (15) UNUSABLE MARKERS: a corpse pid, the `main-<sha>` rail, and a PR no worktree claims mint no pane.
#  (16)/(17) DRY-RUN and HEADLESS are inert on the CREATE half too.
#  (18) NO DISPATCH-SITE HOOK LEFT: _spawn_health_pane has exactly one call site — the reconcile.
#
# HERD-568 fixed the PLACEMENT DEFECT (every health pane opened a brand-new standalone tab, full fish
# greeting + fastfetch, even when the builder's own tab was still open) and the observed-live sidecar
# gap (the pane tailed a log that stays 0 bytes until the suite ends under the python engine). New cases:
#  (19) SPLIT PLACEMENT: a live builder tab (found via .herd-tabs) gets the health pane as a SPLIT off
#       that tab's ROOT pane — never a new tab, never the agent's own pane, and no .herd-tabs row (the
#       pane lives inside a tab this seat does not own).
#  (20) SANITIZED/TRUNCATED .herd-tabs LABEL: a builder row written under the sanitized slug is still
#       found.
#  (21) FALLBACK PLACEMENT: a .herd-tabs row names a tab that no longer exists (a reaped builder) →
#       the standalone-tab fallback, journaled reason=no-builder-tab.
#  (22) RETIRE (split placement): the pane closes but the BUILDER'S TAB is left open.
#  (23) VIEW COMMAND: every spawn (split or fallback) execs health-pane-view.sh with the log AND the
#       inflight-marker path, never a bare `tail`.
#
# Sources agent-watch.sh in lib mode under the DEFAULT herdr-claude driver with a herdr stub whose pane
# LABELS + TAB MEMBERSHIP drive herd_driver_pane_identity / _herd_herdr_tab_root_pane, so
# herd_driver_pane_alive / herd_close_pane_verified / the split-placement lookup all exercise the real
# driver seam. Stubs gh/git too (NETWORK-FREE). Run:  bash tests/test-health-pane-lifecycle.sh
# No `set -e`: some checks assert non-zero returns explicitly.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../scripts/herd/agent-watch.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

[ -f "$WATCH" ] || fail "agent-watch.sh not found at $WATCH"
command -v python3 >/dev/null 2>&1 || fail "python3 required to run this test"
# Canonical scripts/herd dir — matches agent-watch.sh's own $HERE (cd+pwd), so the view-command
# assertions below compare the SAME absolute path agent-watch.sh itself composes, not a "../"-relative
# string that would never appear byte-for-byte in $HERDR_LOG.
WATCH_HERE="$(cd "$(dirname "$WATCH")" && pwd)"
HPV_SH="$WATCH_HERE/health-pane-view.sh"
[ -f "$HPV_SH" ] || fail "health-pane-view.sh not found at $HPV_SH"

# ── Stub binaries on PATH ─────────────────────────────────────────────────────
BIN="$T/bin"; mkdir -p "$BIN"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/gh";  chmod +x "$BIN/gh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/git"; chmod +x "$BIN/git"

# herdr stub — the control surface the health-pane lifecycle touches:
#   tab create … --label L     mint a fresh pane+tab (monotonic ids p<N>/t<N>), mark the pane alive,
#                              record L as its label and its tab membership; emit the create JSON.
#   pane split <base> …        mint a fresh pane in the SAME TAB as <base> (from $PANE_TABS), mark it
#                              alive; emit the split JSON. Empty pane_id when <base>'s tab is unknown.
#   pane rename <id> <label>   set/overwrite <id>'s label (what the guarded close proves against).
#   pane run <id> <cmd>        no-op (the view command); logged.
#   pane read <id>             alive iff <id> is listed in $ALIVE_PANES (herd_driver_pane_alive).
#   pane close <id>            logs to $CLOSE_LOG and drops <id> from alive.
#   tab close <id>             logs to $TAB_CLOSE_LOG.
#   pane list                  the label + tab_id roster (herd_driver_pane_identity source 2, AND
#                              _herd_herdr_tab_root_pane's tab->root-pane lookup).
#   agent list                 the roster from $PANE_AGENTS ("<pane> <agent-name> <tab>" per line) —
#                              a health pane is never an agent, so this stays empty unless a test seeds
#                              a fixture builder agent for the herdr-agent-list fallback lookup.
ALIVE_PANES="$T/alive-panes";     : > "$ALIVE_PANES"
PANE_LABELS="$T/pane-labels";     : > "$PANE_LABELS"   # "<pane> <label>" per line (last wins)
PANE_TABS="$T/pane-tabs";         : > "$PANE_TABS"      # "<pane> <tab>" per line (last wins)
PANE_AGENTS="$T/pane-agents";     : > "$PANE_AGENTS"    # "<pane> <name> <tab>" per line
CLOSE_LOG="$T/close.log";         : > "$CLOSE_LOG"
TAB_CLOSE_LOG="$T/tab-close.log"; : > "$TAB_CLOSE_LOG"
HERDR_LOG="$T/herdr.log";         : > "$HERDR_LOG"
PANE_CTR="$T/pane-ctr";           printf '0' > "$PANE_CTR"
cat > "$BIN/herdr" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${HERDR_LOG:-/dev/null}" 2>/dev/null || true
case "$1 $2" in
  "tab create")
    lbl=""; while [ $# -gt 0 ]; do [ "$1" = "--label" ] && { lbl="$2"; break; }; shift; done
    n=$(( $(cat "${PANE_CTR:-/dev/null}" 2>/dev/null || echo 0) + 1 )); printf '%s' "$n" > "${PANE_CTR}"
    pane="p$n"; tab="t$n"
    printf '%s\n' "$pane" >> "${ALIVE_PANES:-/dev/null}" 2>/dev/null || true
    printf '%s %s\n' "$pane" "$lbl" >> "${PANE_LABELS:-/dev/null}" 2>/dev/null || true
    printf '%s %s\n' "$pane" "$tab" >> "${PANE_TABS:-/dev/null}" 2>/dev/null || true
    printf '{"result":{"tab":{"tab_id":"%s"},"root_pane":{"pane_id":"%s"}}}\n' "$tab" "$pane"
    exit 0 ;;
  "pane split")
    base="$3"
    btab="$(awk -v p="$base" '$1==p{t=$2} END{print t}' "${PANE_TABS:-/dev/null}" 2>/dev/null)"
    [ -n "$btab" ] || { printf '{"result":{}}\n'; exit 0; }
    n=$(( $(cat "${PANE_CTR:-/dev/null}" 2>/dev/null || echo 0) + 1 )); printf '%s' "$n" > "${PANE_CTR}"
    pane="p$n"
    printf '%s\n' "$pane" >> "${ALIVE_PANES:-/dev/null}" 2>/dev/null || true
    printf '%s %s\n' "$pane" "$btab" >> "${PANE_TABS:-/dev/null}" 2>/dev/null || true
    printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "$pane"
    exit 0 ;;
  "pane rename")
    printf '%s %s\n' "$3" "$4" >> "${PANE_LABELS:-/dev/null}" 2>/dev/null || true
    exit 0 ;;
  "pane run")   exit 0 ;;
  "pane read")
    grep -qxF "$3" "${ALIVE_PANES:-/dev/null}" 2>/dev/null && exit 0
    exit 1 ;;
  "pane close")
    printf '%s\n' "$3" >> "${CLOSE_LOG:-/dev/null}" 2>/dev/null || true
    if [ -f "${ALIVE_PANES:-}" ]; then grep -vxF "$3" "$ALIVE_PANES" > "$ALIVE_PANES.tmp" 2>/dev/null || true; mv -f "$ALIVE_PANES.tmp" "$ALIVE_PANES" 2>/dev/null || true; fi
    exit 0 ;;
  "tab close")
    printf '%s\n' "$3" >> "${TAB_CLOSE_LOG:-/dev/null}" 2>/dev/null || true
    exit 0 ;;
  "pane list")
    # ORDER MATTERS: _herd_herdr_tab_root_pane picks the FIRST-listed pane for a tab_id as that tab's
    # root — so this must preserve PANE_TABS' append order (creation order: the root pane is always
    # written before any pane later split off it), never sort/reorder by pane_id.
    python3 -c '
import os, json
labels = {}
try:
  with open(os.environ.get("PANE_LABELS","")) as f:
    for l in f:
      parts = l.split(None, 1)
      if len(parts) >= 2: labels[parts[0]] = parts[1].strip()   # last label wins
except Exception:
  pass
tabs = {}
order = []
try:
  with open(os.environ.get("PANE_TABS","")) as f:
    for l in f:
      parts = l.split()
      if len(parts) >= 2:
        pid, tab = parts[0], parts[1]
        if pid not in tabs: order.append(pid)
        tabs[pid] = tab   # last tab wins; position stays FIRST-seen
except Exception:
  pass
for pid in labels:
  if pid not in tabs:
    order.append(pid); tabs[pid] = ""
print(json.dumps({"result": {"panes": [
  {"pane_id": p, "label": labels.get(p, ""), "tab_id": tabs.get(p, "")} for p in order
]}}))
' 2>/dev/null || echo '{"result":{"panes":[]}}'
    exit 0 ;;
  "agent list")
    python3 -c '
import os, json
agents = []
try:
  with open(os.environ.get("PANE_AGENTS","")) as f:
    for l in f:
      parts = l.split()
      if len(parts) >= 2:
        a = {"name": parts[1], "pane_id": parts[0], "agent_status": "idle"}
        if len(parts) >= 3: a["tab_id"] = parts[2]
        agents.append(a)
except Exception:
  pass
print(json.dumps({"result": {"agents": agents}}))
' 2>/dev/null || echo '{"result":{"agents":[]}}'
    exit 0 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$BIN/herdr"
printf '#!/usr/bin/env bash\nprintf "claude 0.0.0-stub\\n"; exit 0\n' > "$BIN/claude"; chmod +x "$BIN/claude"
export PATH="$BIN:$PATH" ALIVE_PANES PANE_LABELS PANE_TABS PANE_AGENTS CLOSE_LOG TAB_CLOSE_LOG HERDR_LOG PANE_CTR

# ── Source agent-watch.sh in lib mode (DEFAULT herdr-claude driver) ──────────
export AGENT_WATCH_LIB=1
export WORKTREES_DIR="$T/trees"; mkdir -p "$T/trees"
export JOURNAL_FILE="$T/journal.jsonl"; : > "$JOURNAL_FILE"
export HERD_CONFIG_FILE="$T/no-such-config"
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"
TREES="$WORKTREES_DIR"
# Hermetic seal: journal writes must land in the sandbox.
case "$(_journal_file)" in "$T"/*) : ;; *) fail "journal escapes the sandbox: '$(_journal_file)'" ;; esac

for fn in _effective_health_pane _health_pane_registry_file _health_builder_tab _spawn_health_pane \
          _retire_health_pane _reconcile_health_panes; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined after sourcing"
done
ok

WT="$T/wt"; mkdir -p "$WT"
# live_marker <pr> <sha> — plant a pid-live inflight marker (a real sleeper as the holder).
LIVE_PIDS=""
live_marker() { local p; sleep 300 </dev/null >/dev/null 2>/dev/null & p=$!; disown "$p" 2>/dev/null || true; LIVE_PIDS="$LIVE_PIDS $p"; _marker_write "$(_health_inflight_file "$1-$2")" "$p"; }
cleanup_pids() { for p in $LIVE_PIDS; do kill "$p" 2>/dev/null || true; done; }
trap 'cleanup_pids; rm -rf "$T"' EXIT

# ── (1) LEVER OFF (default): no spawn, no registry row, no reconcile action ────────────────────────
[ "${HEALTH_PANE:-off}" = off ] || fail "HEALTH_PANE must default to off (ship-dormant)"
[ "$(_effective_health_pane)" = off ] || fail "_effective_health_pane must be off by default"
: > "$HERDR_LOG"
live_marker 40 shaOFF
_spawn_health_pane 40 slug-off shaOFF "$WT"
[ ! -f "$(_health_pane_registry_file 40 shaOFF)" ] || fail "lever off wrote a health-pane registry row"
[ ! -s "$HERDR_LOG" ] || fail "lever off called herdr to stand up a pane"
: > "$CLOSE_LOG"
_reconcile_health_panes
[ ! -s "$CLOSE_LOG" ] || fail "lever off: reconcile closed a pane"
ok

# An unrecognized value reads OFF.
[ "$(HEALTH_PANE=maybe _effective_health_pane)" = off ] || fail "an unknown HEALTH_PANE value must read off"
ok

# ── (2) LEVER ON, NO BUILDER TAB: falls back to a standalone tab, journaled no-builder-tab ─────────
export HEALTH_PANE=on
[ "$(_effective_health_pane)" = on ] || fail "HEALTH_PANE=on must enable the health pane"
live_marker 42 shaB
_spawn_health_pane 42 slug-b shaB "$WT"
REG_B="$(_health_pane_registry_file 42 shaB)"
[ -f "$REG_B" ] || fail "on: spawn did not record its pane in the registry"
read -r PANE_B TAB_B PLACEMENT_B LABEL_B < "$REG_B"
[ "$PLACEMENT_B" = tab ] || fail "no builder tab present: placement must be 'tab' (got '$PLACEMENT_B')"
[ "$LABEL_B" = "health·slug-b" ] || fail "registry row must carry the health·<slug> stamp (got '$LABEL_B')"
grep -qxF "$PANE_B" "$ALIVE_PANES" || fail "health pane not registered alive"
grep -q '"event":"health_pane_spawned"' "$JOURNAL_FILE" || fail "spawn should journal health_pane_spawned"
grep -q '"event":"infra_event".*"component":"health_pane".*"reason":"no-builder-tab"' "$JOURNAL_FILE" \
  || fail "the standalone-tab fallback must journal reason=no-builder-tab"
LOG_B="$(_health_log_file "42-shaB")"; MARK_B="$(_health_inflight_file "42-shaB")"
grep -qF "run $PANE_B bash $HPV_SH $LOG_B $MARK_B" "$HERDR_LOG" \
  || fail "the pane must exec health-pane-view.sh with the log AND the inflight-marker path"
grep -qF "run $PANE_B tail" "$HERDR_LOG" && fail "a bare 'tail' must never be typed into the pane directly"
ok

# ── (3) IDEMPOTENT: a second spawn for the same (pr,sha) makes no second pane ──────────────────────
before_ctr="$(cat "$PANE_CTR")"
_spawn_health_pane 42 slug-b shaB "$WT"
[ "$(cat "$PANE_CTR")" = "$before_ctr" ] || fail "spawn must be idempotent per (pr,sha) — a second pane was created"
ok

# ── (4) IN-FLIGHT KEEP: reconcile keeps the pane while the marker is pid-live ──────────────────────
: > "$CLOSE_LOG"
_reconcile_health_panes
[ ! -s "$CLOSE_LOG" ] || fail "reconcile closed a pane whose suite is still in flight"
[ -f "$REG_B" ] || fail "reconcile dropped an in-flight row"
ok

# ── (5) RETIRE-ON-OUTCOME: marker gone → guarded close + journal + drop row + close tab (tab mode) ─
rm -f "$(_health_inflight_file "42-shaB")"    # the suite ended: the worker collected + freed the marker
: > "$CLOSE_LOG"; : > "$TAB_CLOSE_LOG"
_reconcile_health_panes
grep -qxF "$PANE_B" "$CLOSE_LOG" || fail "outcome landed: the health pane was not closed"
grep -qxF "$PANE_B" "$ALIVE_PANES" && fail "the pane should no longer be alive after the close"
grep -q '"event":"health_pane_retired"' "$JOURNAL_FILE" || fail "retire should journal health_pane_retired"
[ ! -f "$REG_B" ] || fail "registry row not dropped after the outcome landed"
grep -qxF "$TAB_B" "$TAB_CLOSE_LOG" || fail "tab placement: the now-empty tab was not closed"
grep -q "$TAB_B" "$TREES/.herd-tabs" && fail "the .herd-tabs allowlist row was left behind"
_reconcile_health_panes   # idempotent on an already-retired pane
ok

# ── (6) GUARDED CLOSE (HERD-134): a row now labelling a NON-health pane is REFUSED ─────────────────
: > "$CLOSE_LOG"
printf 'p-build tX tab health·decoy\n' > "$(_health_pane_registry_file 44 shaD)"   # row CLAIMS health·, but…
printf 'p-build\n'                >> "$ALIVE_PANES"
printf 'p-build slug-d\n'         >> "$PANE_LABELS"   # …the LIVE pane label is a builder, not health·
rbefore="$(grep -c '"event":"health_pane_retired"' "$JOURNAL_FILE" 2>/dev/null || printf 0)"
# no inflight marker for 44-shaD ⇒ reconcile treats it as ended and tries to retire it
_reconcile_health_panes
grep -qxF "p-build" "$CLOSE_LOG" && fail "the guarded close must REFUSE a pane whose live label is not health·"
grep -qxF "p-build" "$ALIVE_PANES" || fail "a neighbour pane was killed by a stale health-pane registry id"
grep -q '"event":"pane_close_refused"' "$JOURNAL_FILE" || fail "a refused close must journal pane_close_refused"
rafter="$(grep -c '"event":"health_pane_retired"' "$JOURNAL_FILE" 2>/dev/null || printf 0)"
[ "$rbefore" = "$rafter" ] || fail "a refused close must not journal a retire"
[ ! -f "$(_health_pane_registry_file 44 shaD)" ] || fail "a row pointing at the wrong pane must not linger"
ok

# ── (7) BYTE-QUIET with no health-pane rows: no herdr call, no close, no journal line ──────────────
rm -f "$TREES"/.health-pane-registry-* 2>/dev/null || true
: > "$CLOSE_LOG"; : > "$HERDR_LOG"
jbefore="$(wc -l < "$JOURNAL_FILE" | tr -d ' ')"
_reconcile_health_panes
[ ! -s "$CLOSE_LOG" ] || fail "reconcile touched a pane with no health-pane rows present"
[ ! -s "$HERDR_LOG" ] || fail "reconcile called herdr with no health-pane rows present"
[ "$(wc -l < "$JOURNAL_FILE" | tr -d ' ')" = "$jbefore" ] || fail "reconcile journaled with no rows present"
ok

# ── (8) DRY-RUN INERT: a render must never spawn or close a pane ──────────────────────────────────
printf 'p-dry tD tab health·slug-e\n' > "$(_health_pane_registry_file 45 shaE)"
printf 'p-dry\n'                 >> "$ALIVE_PANES"
printf 'p-dry health·slug-e\n'   >> "$PANE_LABELS"
: > "$CLOSE_LOG"; : > "$HERDR_LOG"
( DRYRUN=1; _spawn_health_pane 46 slug-f shaF "$WT"; _reconcile_health_panes; _retire_health_pane 45 shaE outcome-landed )
[ ! -s "$CLOSE_LOG" ] || fail "dry-run closed a pane"
[ ! -f "$(_health_pane_registry_file 46 shaF)" ] || fail "dry-run spawned a pane/row"
[ -f "$(_health_pane_registry_file 45 shaE)" ] || fail "dry-run dropped a registry row"
rm -f "$(_health_pane_registry_file 45 shaE)" 2>/dev/null || true
ok

# ── (9) HEADLESS INERT: view-only driver stands up no pane even with the lever on ─────────────────
: > "$HERDR_LOG"
( export HERD_DRIVER=headless; live_marker 47 shaG; _spawn_health_pane 47 slug-g shaG "$WT" )
[ ! -f "$(_health_pane_registry_file 47 shaG)" ] || fail "headless stood up a health pane (should be view-only)"
ok

# ══ HERD-554: the RECONCILED-INVARIANT create half ═════════════════════════════════════════════════
# _reconcile_health_panes now asserts BOTH directions of "one health·<slug> pane per OBSERVED in-flight
# suite" every tick, keyed off the `.health-inflight-<pr>-<sha>` markers rather than a dispatch-site
# hook. That is what makes the lever work under ENGINE_IMPL=python, where live_runtime.py dispatches the
# suite and the bash render pass's automerge-candidate branch (the old spawn site) is never reached.
# The pr→(slug,dir) identity comes from $FEATS — the same discovery records the console rows use.
#
# feat_rec <dir> <slug> <pr#> <sha> — one \037-separated _discover_feature_worktrees record. The fields
# past prnum are the ones the reconcile does not read; they are filled in the shipped shape so the
# fixture stays a faithful stand-in for a real row.
feat_rec() {
  printf '%s\037%s\037feat/%s\037%s\037MERGEABLE\037BLOCKED\037working\037%s\037me\037branch\037\0370' \
    "$1" "$2" "$2" "$3" "$4"
}
export HEALTH_PANE=on
rm -f "$TREES"/.health-pane-registry-* 2>/dev/null || true

# ── (10) PYTHON-STYLE DISPATCH: marker + log ONLY (no bash dispatch event) still gains a pane ──────
# This is the HERD-554 regression itself. Nothing here calls a spawn hook: the ONLY inputs are the two
# state files the Python engine writes (_marker_write over .health-inflight-<pr>-<sha>, and the live
# .health-log-<pr>-<sha> it tees the suite into) plus the observed worktree row. Under the old
# dispatch-site hook this produced NO pane at all. No builder tab is registered for this slug, so this
# also exercises the fallback placement through the full reconcile path (not just a direct spawn call).
PY_DIR="$T/trees/py-builder"; mkdir -p "$PY_DIR"
FEATS=("$(feat_rec "$PY_DIR" py-builder 70 shaPY)")
live_marker 70 shaPY
printf 'suite line 1\n' > "$(_health_log_file "70-shaPY")"
: > "$HERDR_LOG"
_reconcile_health_panes
REG_PY="$(_health_pane_registry_file 70 shaPY)"
[ -f "$REG_PY" ] || fail "(10) reconcile did not stand up a pane for a live python-dispatched suite"
read -r PANE_PY TAB_PY PLACEMENT_PY LABEL_PY < "$REG_PY"
[ "$LABEL_PY" = "health·py-builder" ] || fail "(10) pane must be stamped health·<slug> (got '$LABEL_PY')"
[ "$PLACEMENT_PY" = tab ] || fail "(10) no builder tab registered for py-builder — must fall back to 'tab' (got '$PLACEMENT_PY')"
grep -qxF "$PANE_PY" "$ALIVE_PANES" || fail "(10) the reconciled pane is not alive"
grep -qF "run $PANE_PY bash $HPV_SH $(_health_log_file "70-shaPY")" "$HERDR_LOG" \
  || fail "(10) the pane must exec health-pane-view.sh over the sha-scoped health log"
grep -qF -- "--cwd $PY_DIR" "$HERDR_LOG" || fail "(10) the pane must open in the builder worktree"
grep -q '"event":"health_pane_spawned"' "$JOURNAL_FILE" || fail "(10) a reconciled spawn must journal health_pane_spawned"
ok

# ── (11) IDEMPOTENT ACROSS TICKS: a second reconcile makes no second pane, and keeps the live one ──
before_ctr="$(cat "$PANE_CTR")"
: > "$CLOSE_LOG"
_reconcile_health_panes
[ "$(cat "$PANE_CTR")" = "$before_ctr" ] || fail "(11) a second reconcile tick created a second pane"
[ ! -s "$CLOSE_LOG" ] || fail "(11) a second reconcile tick closed the still-in-flight pane"
[ -f "$REG_PY" ] || fail "(11) a second reconcile tick dropped the in-flight row"
ok

# ── (12) ROUND TRIP: the suite ends → the SAME reconcile retires the pane it created ───────────────
rm -f "$(_health_inflight_file "70-shaPY")"
: > "$CLOSE_LOG"
_reconcile_health_panes
grep -qxF "$PANE_PY" "$CLOSE_LOG" || fail "(12) the reconciled pane was not retired once its suite ended"
[ ! -f "$REG_PY" ] || fail "(12) the registry row survived the retire"
: > "$HERDR_LOG"
_reconcile_health_panes
[ ! -s "$HERDR_LOG" ] || fail "(12) a retired suite must not be re-created by the next tick (marker is gone)"
ok

# ── (13) LEVER OFF: a live suite + a matching worktree row creates NOTHING ─────────────────────────
OFF_DIR="$T/trees/off-builder"; mkdir -p "$OFF_DIR"
FEATS=("$(feat_rec "$OFF_DIR" off-builder 71 shaOF)")
live_marker 71 shaOF
: > "$HERDR_LOG"
( export HEALTH_PANE=off; _reconcile_health_panes )
[ ! -f "$(_health_pane_registry_file 71 shaOF)" ] || fail "(13) lever off created a health-pane row"
[ ! -s "$HERDR_LOG" ] || fail "(13) lever off called herdr during the reconcile"
( export HEALTH_PANE=maybe; _reconcile_health_panes )
[ ! -f "$(_health_pane_registry_file 71 shaOF)" ] || fail "(13) an unrecognized HEALTH_PANE value created a pane"
ok

# ── (14) DEAD / UNKNOWN / NON-PR markers never mint a pane ─────────────────────────────────────────
# (a) a corpse marker (its recorded pid is long gone) is not a live suite;
# (b) the `main-<sha>` MAIN_HEALTH_TICK rail has no worktree and no slug — no health·<slug> pane;
# (c) a live suite whose PR no worktree row claims is unidentifiable — no pane, no guess.
DEAD_DIR="$T/trees/dead-builder"; mkdir -p "$DEAD_DIR"
FEATS=("$(feat_rec "$DEAD_DIR" dead-builder 72 shaDD)")
_marker_write "$(_health_inflight_file "72-shaDD")" 999999            # (a) pid that cannot be alive
live_marker main shaMAIN                                              # (b)
live_marker 73 shaORPH                                                # (c) no FEATS row for pr 73
: > "$HERDR_LOG"
_reconcile_health_panes
[ ! -f "$(_health_pane_registry_file 72 shaDD)" ]   || fail "(14a) a dead marker stood a pane up over a corpse"
[ ! -f "$(_health_pane_registry_file main shaMAIN)" ] || fail "(14b) the main-health rail got a health·<slug> pane"
[ ! -f "$(_health_pane_registry_file 73 shaORPH)" ] || fail "(14c) a PR with no observed worktree got a pane"
[ ! -s "$HERDR_LOG" ] || fail "(14) an unusable marker still called herdr"
ok

# ── (15) DRY-RUN INERT on the create half too ──────────────────────────────────────────────────────
DRY_DIR="$T/trees/dry-builder"; mkdir -p "$DRY_DIR"
FEATS=("$(feat_rec "$DRY_DIR" dry-builder 74 shaDR)")
live_marker 74 shaDR
: > "$HERDR_LOG"
( DRYRUN=1; _reconcile_health_panes )
[ ! -f "$(_health_pane_registry_file 74 shaDR)" ] || fail "(15) dry-run reconcile created a pane"
[ ! -s "$HERDR_LOG" ] || fail "(15) dry-run reconcile called herdr"
ok

# ── (16) HEADLESS INERT on the create half too ────────────────────────────────────────────────────
: > "$HERDR_LOG"
( export HERD_DRIVER=headless; _reconcile_health_panes )
[ ! -f "$(_health_pane_registry_file 74 shaDR)" ] || fail "(16) headless reconcile created a pane"
ok

# ── (17) NO DISPATCH-SITE HOOK LEFT: the spawn primitive has exactly ONE caller, the reconcile ─────
# The whole point of HERD-554 is that no engine-specific dispatch path decides whether a pane exists.
# A second call site would silently re-introduce the bash-only leg this fix removed.
CALLERS="$(grep -c '^[[:space:]]*[^#]*_spawn_health_pane ' "$WATCH" || true)"
[ "$CALLERS" = "1" ] || fail "(17) _spawn_health_pane must have exactly ONE call site (the reconcile); found $CALLERS"
ok
unset FEATS

# ══ HERD-568: PLACEMENT — a SPLIT inside the builder's own tab, standalone only as a fallback ════════

# ── (18) SPLIT PLACEMENT: a live builder tab gets the health pane as a split off its ROOT pane ──────
# Fixture: a builder tab "tBUILD" with TWO panes — "pRoot" (the task-spec-viewer / app-preview pane,
# listed FIRST — the split target) and "pAgent" (the builder's own Claude agent pane, split=right off
# root at spawn time — must NEVER be split into), registered in .herd-tabs exactly the way
# herd-feature.sh / herd-quick.sh write it: "<slug> <tab> builder".
printf 'pRoot\npAgent\n'    >> "$ALIVE_PANES"
printf 'pRoot task-spec·live-builder\n' >> "$PANE_LABELS"
printf 'pAgent live-builder\n' >> "$PANE_LABELS"
printf 'pRoot tBUILD\npAgent tBUILD\n' >> "$PANE_TABS"
printf 'live-builder tBUILD builder\n' >> "$TREES/.herd-tabs"
[ "$(_health_builder_tab live-builder)" = "tBUILD" ] || fail "(18) _health_builder_tab did not resolve the .herd-tabs row"
LB_DIR="$T/trees/live-builder"; mkdir -p "$LB_DIR"
: > "$HERDR_LOG"
live_marker 80 shaLB
_spawn_health_pane 80 live-builder shaLB "$LB_DIR"
REG_LB="$(_health_pane_registry_file 80 shaLB)"
[ -f "$REG_LB" ] || fail "(18) spawn did not record a registry row"
read -r PANE_LB TAB_LB PLACEMENT_LB LABEL_LB < "$REG_LB"
[ "$PLACEMENT_LB" = split ] || fail "(18) a live builder tab must place the pane as a SPLIT (got '$PLACEMENT_LB')"
[ "$TAB_LB" = "tBUILD" ] || fail "(18) the split pane must record the BUILDER's tab id, not a fresh one (got '$TAB_LB' want 'tBUILD')"
[ "$PANE_LB" != "pRoot" ] || fail "(18) the health pane must be a NEW pane, never the root pane itself"
[ "$LABEL_LB" = "health·live-builder" ] || fail "(18) split pane must still carry the health·<slug> stamp"
grep -qxF "$PANE_LB" "$ALIVE_PANES" || fail "(18) the split pane is not alive"
grep -qF "pane split pRoot --direction down" "$HERDR_LOG" || fail "(18) must split OFF THE ROOT pane, direction down"
grep -qF "pane split pAgent" "$HERDR_LOG" && fail "(18) must never split the agent pane"
grep -qF "tab create" "$HERDR_LOG" && fail "(18) a live builder tab must never mint a fresh standalone tab"
grep -q "^live-builder tBUILD builder\$" "$TREES/.herd-tabs" || fail "(18) the pre-existing builder .herd-tabs row must be untouched"
[ "$(grep -c "^live-builder .* health\$" "$TREES/.herd-tabs" 2>/dev/null || true)" = "0" ] \
  || fail "(18) a split-placed pane must NOT get its own .herd-tabs row — it lives inside the builder's tab"
grep -q '"event":"health_pane_spawned".*"placement":"split"' "$JOURNAL_FILE" \
  || fail "(18) health_pane_spawned must record placement=split"
SHALB_LINES="$(grep '"sha":"shaLB"' "$JOURNAL_FILE" || true)"
grep -q "no-builder-tab" <<< "$SHALB_LINES" \
  && fail "(18) a real builder tab must never journal the no-builder-tab fallback reason"
ok

# ── (19) SANITIZED/TRUNCATED .herd-tabs LABEL is still found ───────────────────────────────────────
UGLY_SLUG="Weird Slug!!"
SAN="$(herd_agent_name_sanitize "$UGLY_SLUG")"
printf 'pRoot2\n'          >> "$ALIVE_PANES"
printf 'pRoot2 tUGLY\n'    >> "$PANE_TABS"
printf '%s tUGLY builder\n' "$SAN" >> "$TREES/.herd-tabs"
[ "$(_health_builder_tab "$UGLY_SLUG")" = "tUGLY" ] || fail "(19) a sanitized .herd-tabs label must still resolve"
ok

# ── (20) FALLBACK PLACEMENT: a .herd-tabs row names a tab that no longer exists (a reaped builder) ─
# The row is stale (the builder tab closed) but nothing prunes .herd-tabs synchronously — the pane
# lookup for that tab_id then finds nothing in `pane list`, so _herd_herdr_tab_root_pane returns empty
# and the spawn must fall through to the standalone-tab fallback, journaled reason=no-builder-tab.
printf 'reaped-builder tGONE builder\n' >> "$TREES/.herd-tabs"
[ "$(_health_builder_tab reaped-builder)" = "tGONE" ] || fail "(20) the stale row must still resolve to a tab id"
REAP_DIR="$T/trees/reaped-builder"; mkdir -p "$REAP_DIR"
: > "$HERDR_LOG"
live_marker 81 shaRP
_spawn_health_pane 81 reaped-builder shaRP "$REAP_DIR"
REG_RP="$(_health_pane_registry_file 81 shaRP)"
[ -f "$REG_RP" ] || fail "(20) spawn did not record a registry row"
read -r PANE_RP TAB_RP PLACEMENT_RP LABEL_RP < "$REG_RP"
[ "$PLACEMENT_RP" = tab ] || fail "(20) a reaped builder tab must fall back to placement=tab (got '$PLACEMENT_RP')"
[ "$TAB_RP" != "tGONE" ] || fail "(20) the fallback must mint its OWN standalone tab, not reuse the gone one"
grep -qF "tab create" "$HERDR_LOG" || fail "(20) the fallback must create a standalone tab"
grep -q '"event":"infra_event".*"component":"health_pane".*"reason":"no-builder-tab"' "$JOURNAL_FILE" \
  || fail "(20) a reaped builder tab must journal reason=no-builder-tab"
grep -q "$TAB_RP" "$TREES/.herd-tabs" || fail "(20) the standalone fallback tab must be registered in .herd-tabs"
ok

# ── (21) RETIRE (split placement): the pane closes, but the BUILDER'S TAB is left open ─────────────
rm -f "$(_health_inflight_file "80-shaLB")"
: > "$CLOSE_LOG"; : > "$TAB_CLOSE_LOG"
_reconcile_health_panes
grep -qxF "$PANE_LB" "$CLOSE_LOG" || fail "(21) the split-placed health pane was not closed on outcome"
grep -qxF "tBUILD" "$TAB_CLOSE_LOG" && fail "(21) retiring a SPLIT pane must never close the builder's own tab"
[ ! -f "$REG_LB" ] || fail "(21) the registry row survived the retire"
grep -qxF "pRoot" "$ALIVE_PANES" || fail "(21) the builder's root pane must still be alive after retiring its neighbour"
ok

echo "ALL PASS ($pass checks)"
