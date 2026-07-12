#!/usr/bin/env bash
# test-health-pane-lifecycle.sh — hermetic tests for the HEALTH_PANE disposable-pane lifecycle
# (HERD-313 leg a). The in-flight healthcheck can be mirrored into a stamped `health·<slug>` VIEW pane
# that streams the live suite log and is retired the instant the suite ends. Modelled on the resolver
# pane (tests/test-resolver-pane-lifecycle.sh):
#   (1) LEVER OFF (the HEALTH_PANE=off default): _spawn_health_pane is a HARD no-op — no herdr call, no
#       registry row — and the reconcile is byte-inert (no pane touched, no journal line).
#   (2) UNKNOWN VALUE reads OFF (a typo can never arm a pane-closing path).
#   (3) LEVER ON: _spawn_health_pane stands up a `health·<slug>` pane, stamps its label, and records
#       "pane tab health·<slug>" in the sha-scoped registry.
#   (4) IDEMPOTENT: a second spawn for the same (pr,sha) creates no second pane.
#   (5) IN-FLIGHT KEEP: while the (pr,sha) inflight marker is pid-live the reconcile keeps the pane.
#   (6) RETIRE-ON-OUTCOME: once the marker is gone the reconcile closes the pane through the guarded
#       close, journals health_pane_retired, drops the row, and closes the now-empty tab + its
#       .herd-tabs allowlist row.
#   (7) GUARDED CLOSE (HERD-134): a registry id that now labels a NON-health pane is REFUSED, not closed.
#   (8) BYTE-QUIET with no health-pane rows: no herdr call, no close, no journal line.
#   (9) DRY-RUN INERT: a render must never close (or spawn) a pane.
#  (10) HEADLESS INERT: view-only driver stands up no pane even with the lever on.
#
# Sources agent-watch.sh in lib mode under the DEFAULT herdr-claude driver with a herdr stub whose pane
# LABELS drive herd_driver_pane_identity (a health pane is a labelled NON-agent pane, unlike a reviewer
# agent pane), so herd_driver_pane_alive / herd_close_pane_verified exercise the real driver seam.
# Stubs gh/git too (NETWORK-FREE). Run:  bash tests/test-health-pane-lifecycle.sh
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

# ── Stub binaries on PATH ─────────────────────────────────────────────────────
BIN="$T/bin"; mkdir -p "$BIN"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/gh";  chmod +x "$BIN/gh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/git"; chmod +x "$BIN/git"

# herdr stub — the control surface the health-pane lifecycle touches:
#   tab create … --label L     mint a fresh pane+tab (monotonic ids p<N>/t<N>), mark the pane alive,
#                              and record L as its label; emit the JSON the spawn parses.
#   pane rename <id> <label>   set/overwrite <id>'s label (what the guarded close proves against).
#   pane run <id> <cmd>        no-op (the tail command); logged.
#   pane read <id>             alive iff <id> is listed in $ALIVE_PANES (herd_driver_pane_alive).
#   pane close <id>            logs to $CLOSE_LOG and drops <id> from alive.
#   tab close <id>             logs to $TAB_CLOSE_LOG.
#   pane list                  the label roster (herd_driver_pane_identity source 2).
#   agent list                 EMPTY — a health pane is not an agent.
ALIVE_PANES="$T/alive-panes";     : > "$ALIVE_PANES"
PANE_LABELS="$T/pane-labels";     : > "$PANE_LABELS"   # "<pane> <label>" per line (last wins)
CLOSE_LOG="$T/close.log";         : > "$CLOSE_LOG"
TAB_CLOSE_LOG="$T/tab-close.log"; : > "$TAB_CLOSE_LOG"
HERDR_LOG="$T/herdr.log";         : > "$HERDR_LOG"
PANE_CTR="$T/pane-ctr";           printf '0' > "$PANE_CTR"
cat > "$BIN/herdr" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${HERDR_LOG:-/dev/null}" 2>/dev/null || true
case "$1 $2" in
  "tab create")
    # find --label
    lbl=""; while [ $# -gt 0 ]; do [ "$1" = "--label" ] && { lbl="$2"; break; }; shift; done
    n=$(( $(cat "${PANE_CTR:-/dev/null}" 2>/dev/null || echo 0) + 1 )); printf '%s' "$n" > "${PANE_CTR}"
    pane="p$n"; tab="t$n"
    printf '%s\n' "$pane" >> "${ALIVE_PANES:-/dev/null}" 2>/dev/null || true
    printf '%s %s\n' "$pane" "$lbl" >> "${PANE_LABELS:-/dev/null}" 2>/dev/null || true
    printf '{"result":{"tab":{"tab_id":"%s"},"root_pane":{"pane_id":"%s"}}}\n' "$tab" "$pane"
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
    python3 -c '
import os, json
panes = {}
try:
  with open(os.environ.get("PANE_LABELS","")) as f:
    for l in f:
      parts = l.split(None, 1)
      if len(parts) >= 2: panes[parts[0]] = parts[1].strip()   # last label wins
except Exception:
  pass
print(json.dumps({"result": {"panes": [{"pane_id": p, "label": lb} for p, lb in panes.items()]}}))
' 2>/dev/null || echo '{"result":{"panes":[]}}'
    exit 0 ;;
  "agent list") echo '{"result":{"agents":[]}}'; exit 0 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$BIN/herdr"
printf '#!/usr/bin/env bash\nprintf "claude 0.0.0-stub\\n"; exit 0\n' > "$BIN/claude"; chmod +x "$BIN/claude"
export PATH="$BIN:$PATH" ALIVE_PANES PANE_LABELS CLOSE_LOG TAB_CLOSE_LOG HERDR_LOG PANE_CTR

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

for fn in _effective_health_pane _health_pane_registry_file _spawn_health_pane \
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

# ── (2) LEVER ON: the render pass stands up + registers the health·<slug> pane ────────────────────
export HEALTH_PANE=on
[ "$(_effective_health_pane)" = on ] || fail "HEALTH_PANE=on must enable the health pane"
live_marker 42 shaB
_spawn_health_pane 42 slug-b shaB "$WT"
REG_B="$(_health_pane_registry_file 42 shaB)"
[ -f "$REG_B" ] || fail "on: spawn did not record its pane in the registry"
read -r PANE_B TAB_B LABEL_B < "$REG_B"
[ "$LABEL_B" = "health·slug-b" ] || fail "registry row must carry the health·<slug> stamp (got '$LABEL_B')"
grep -qxF "$PANE_B" "$ALIVE_PANES" || fail "health pane not registered alive"
grep -q '"event":"health_pane_spawned"' "$JOURNAL_FILE" || fail "spawn should journal health_pane_spawned"
grep -q "run $PANE_B tail" "$HERDR_LOG" || fail "the pane must stream the suite log via tail (got no tail run)"
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

# ── (5) RETIRE-ON-OUTCOME: marker gone → guarded close + journal + drop row + close tab ────────────
# Also seed the .herd-tabs allowlist row so the tab-prune is exercised.
printf '%s %s health\n' "slug-b" "$TAB_B" > "$TREES/.herd-tabs"
rm -f "$(_health_inflight_file "42-shaB")"    # the suite ended: the worker collected + freed the marker
: > "$CLOSE_LOG"; : > "$TAB_CLOSE_LOG"
_reconcile_health_panes
grep -qxF "$PANE_B" "$CLOSE_LOG" || fail "outcome landed: the health pane was not closed"
grep -qxF "$PANE_B" "$ALIVE_PANES" && fail "the pane should no longer be alive after the close"
grep -q '"event":"health_pane_retired"' "$JOURNAL_FILE" || fail "retire should journal health_pane_retired"
[ ! -f "$REG_B" ] || fail "registry row not dropped after the outcome landed"
grep -qxF "$TAB_B" "$TAB_CLOSE_LOG" || fail "the now-empty tab was not closed"
grep -q "$TAB_B" "$TREES/.herd-tabs" && fail "the .herd-tabs allowlist row was left behind"
_reconcile_health_panes   # idempotent on an already-retired pane
ok

# ── (6) GUARDED CLOSE (HERD-134): a row now labelling a NON-health pane is REFUSED ─────────────────
: > "$CLOSE_LOG"
printf 'p-build tX health·decoy\n' > "$(_health_pane_registry_file 44 shaD)"   # row CLAIMS health·, but…
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
printf 'p-dry tD health·slug-e\n' > "$(_health_pane_registry_file 45 shaE)"
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

echo "ALL PASS ($pass checks)"
