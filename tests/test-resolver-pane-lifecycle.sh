#!/usr/bin/env bash
# test-resolver-pane-lifecycle.sh — hermetic tests for the resolver PANE LIFECYCLE (HERD-280):
#   (1) LEVER OFF (the RESOLVER_PANE=off default): the dispatch lane hands herd-resolve.sh NO registry
#       seam, so no row is written and the whole retire path is byte-inert (no herdr call, no journal).
#   (2) LEVER ON: the lane passes $HERD_RESOLVE_REGISTRY_FILE (+ pr/sha) and the resolver records its
#       pane there.
#   (3) RETIRE-ON-RESULT: `RESOLVE: DONE` — the watcher's registry-vs-verdict reconcile closes the pane
#       via the driver, journals resolver_pane_retired reason=result-consumed, and drops the row.
#   (4) ESCALATE KEEPS THE PANE: `RESOLVE: ESCALATE` leaves the pane open (and its row intact) for the
#       human the needs-you row addresses — no close, no retire event, on this tick or any later one.
#   (5) TAB PLACEMENT: retiring a standalone-tab resolver also closes the now-empty tab and prunes its
#       .herd-tabs sweep-allowlist row.
#   (6) GUARDED CLOSE (HERD-134): a registry pane id that now names the BUILDER is REFUSED, not closed.
#   (7) BYTE-QUIET: a seat with no resolver rows reconciles without touching a pane or the journal.
#
# Sources agent-watch.sh in lib mode under the DEFAULT herdr-claude driver with a herdr stub whose pane
# liveness is driven by an "alive panes" file and whose agent roster maps pane -> agent identity, so
# herd_driver_pane_alive / herd_close_pane_verified exercise the real driver seam. Stubs gh/git too
# (NETWORK-FREE). Run:  bash tests/test-resolver-pane-lifecycle.sh
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

# herdr stub. The whole control surface this lifecycle touches:
#   pane read <id>    alive iff <id> is listed in $ALIVE_PANES (herd_driver_pane_alive)
#   pane close <id>   logs to $CLOSE_LOG and drops <id> from alive
#   tab close <id>    logs to $TAB_CLOSE_LOG
#   agent list        the roster, built from $PANE_AGENTS ("<pane> <agent-name>" per line) — the LIVE
#                     identity herd_close_pane_verified proves a pane against before closing it
ALIVE_PANES="$T/alive-panes";     : > "$ALIVE_PANES"
PANE_AGENTS="$T/pane-agents";     : > "$PANE_AGENTS"
CLOSE_LOG="$T/close.log";         : > "$CLOSE_LOG"
TAB_CLOSE_LOG="$T/tab-close.log"; : > "$TAB_CLOSE_LOG"
HERDR_LOG="$T/herdr.log";         : > "$HERDR_LOG"
cat > "$BIN/herdr" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${HERDR_LOG:-/dev/null}" 2>/dev/null || true
case "$1 $2" in
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
  "agent list")
    python3 -c '
import os, json
agents = []
try:
  with open(os.environ.get("PANE_AGENTS","")) as f:
    for l in f:
      parts = l.split()
      if len(parts) >= 2:
        agents.append({"name": parts[1], "pane_id": parts[0], "agent_status": "idle"})
except Exception:
  pass
print(json.dumps({"result": {"agents": agents}}))
' 2>/dev/null || echo '{"result":{"agents":[]}}'
    exit 0 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$BIN/herdr"
export PATH="$BIN:$PATH" ALIVE_PANES PANE_AGENTS CLOSE_LOG TAB_CLOSE_LOG HERDR_LOG

# Stub resolver (HERD_RESOLVE_BIN seam). Stands in for herd-resolve.sh: it records whether the lane
# handed it the registry seam, and when it did, writes the row the real lane writes after its pane is up.
STUB_RESOLVE="$T/stub-resolve.sh"
cat > "$STUB_RESOLVE" <<'STUB'
#!/usr/bin/env bash
slug="$1"
if [ -n "${HERD_RESOLVE_REGISTRY_FILE:-}" ]; then
  printf 'registry %s %s %s\n' "$slug" "${HERD_RESOLVE_PR:--}" "${HERD_RESOLVE_SHA:--}" >> "${STUB_SPAWN_LOG:-/dev/null}"
  printf '%s %s %s %s %s\n' "${STUB_PANE:-paneX}" "${STUB_TAB:--}" "${STUB_PLACEMENT:-split}" \
    "${HERD_RESOLVE_PR:--}" "${HERD_RESOLVE_SHA:--}" > "$HERD_RESOLVE_REGISTRY_FILE"
  printf '%s\n' "${STUB_PANE:-}" >> "${ALIVE_PANES:-/dev/null}"
  printf '%s resolve·%s\n' "${STUB_PANE:-}" "$slug" >> "${PANE_AGENTS:-/dev/null}"
else
  printf 'noregistry %s\n' "$slug" >> "${STUB_SPAWN_LOG:-/dev/null}"
fi
exit 0
STUB
chmod +x "$STUB_RESOLVE"

# ── Source agent-watch.sh in lib mode (DEFAULT herdr-claude driver) ──────────
export AGENT_WATCH_LIB=1
export WORKTREES_DIR="$T/trees"; mkdir -p "$T/trees"
export JOURNAL_FILE="$T/journal.jsonl"; : > "$JOURNAL_FILE"
export HERD_CONFIG_FILE="$T/no-such-config"
export HERD_RESOLVE_BIN="$STUB_RESOLVE"
export STUB_SPAWN_LOG="$T/spawns.log"; : > "$STUB_SPAWN_LOG"
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"

for fn in _resolver_pane_enabled _resolve_registry_file _retire_resolver_pane \
          _reconcile_resolver_panes _spawn_resolver_lane _resolve_result_file; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined after sourcing"
done
ok

# A dispatch through the real lane body, with a unique inflight marker (its lock holder).
dispatch() {
  local slug="$1" pr="$2" sha="$3"
  _spawn_resolver_lane "$slug" "$pr" "$sha" "$T/marker-$pr-$sha" >/dev/null 2>&1
}

# ── (1) LEVER OFF (default): no registry seam, no row, no reconcile action ────────────────────────
[ "${RESOLVER_PANE:-off}" = off ] || fail "RESOLVER_PANE must default to off (ship-dormant)"
_resolver_pane_enabled && fail "_resolver_pane_enabled must be false by default"
: > "$STUB_SPAWN_LOG"; : > "$CLOSE_LOG"
jbefore="$(wc -l < "$JOURNAL_FILE" | tr -d ' ')"
dispatch slug-off 40 shaOFF
grep -q '^noregistry slug-off$' "$STUB_SPAWN_LOG" || fail "lever off must NOT hand the resolver a registry seam"
[ ! -f "$(_resolve_registry_file 40 shaOFF)" ] || fail "lever off wrote a registry row"
printf 'RESOLVE: DONE\n' > "$(_resolve_result_file 40 shaOFF)"
_reconcile_resolver_panes
[ ! -s "$CLOSE_LOG" ] || fail "lever off: reconcile closed a pane"
ok

# An unrecognized value reads OFF — a typo can never arm a pane-closing path.
( export RESOLVER_PANE=maybe; _resolver_pane_enabled ) && fail "an unknown RESOLVER_PANE value must read off"
ok

# ── (2) LEVER ON: the lane hands over the registry seam and the resolver records its pane ─────────
export RESOLVER_PANE=on
_resolver_pane_enabled || fail "RESOLVER_PANE=on must enable the resolver pane"
: > "$STUB_SPAWN_LOG"
export STUB_PANE="paneR" STUB_TAB="-" STUB_PLACEMENT="split"
dispatch slug-b 42 shaB
grep -q '^registry slug-b 42 shaB$' "$STUB_SPAWN_LOG" || fail "lever on must pass the registry seam + pr/sha"
REG_B="$(_resolve_registry_file 42 shaB)"
[ -f "$REG_B" ] || fail "resolver did not record its pane in the registry"
grep -q '^paneR - split 42 shaB$' "$REG_B" || fail "registry row shape wrong: $(cat "$REG_B")"
grep -qxF paneR "$ALIVE_PANES" || fail "resolver pane not registered alive"
ok

# ── (3) no verdict yet → the resolver is in flight; reconcile keeps hands off ─────────────────────
: > "$CLOSE_LOG"
_reconcile_resolver_panes
[ ! -s "$CLOSE_LOG" ] || fail "reconcile closed a pane whose resolver has not reported"
[ -f "$REG_B" ] || fail "reconcile dropped a row with no verdict"
ok

# ── (4) ESCALATE KEEPS THE PANE (and its row) — evidence for the human, on every later tick ───────
printf 'RESOLVE: ESCALATE\n' > "$(_resolve_result_file 42 shaB)"
_reconcile_resolver_panes
_reconcile_resolver_panes    # idempotent: a second tick must not change its mind
[ ! -s "$CLOSE_LOG" ] || fail "ESCALATE must KEEP the resolver pane open"
grep -qxF paneR "$ALIVE_PANES" || fail "ESCALATE closed the resolver pane"
[ -f "$REG_B" ] || fail "ESCALATE dropped the registry row (a later tick could not spare the pane)"
grep -q '"event":"resolver_pane_retired"' "$JOURNAL_FILE" && fail "ESCALATE must not journal a retire"
ok

# ── (5) RETIRE-ON-RESULT: DONE closes the pane, journals result-consumed, drops the row ───────────
printf 'RESOLVE: DONE\n' > "$(_resolve_result_file 42 shaB)"
_reconcile_resolver_panes
grep -qxF paneR "$CLOSE_LOG" || fail "DONE did not close the resolver pane (paneR)"
grep -qxF paneR "$ALIVE_PANES" && fail "paneR should no longer be alive after the close"
grep -q '"event":"resolver_pane_retired"' "$JOURNAL_FILE" || fail "retire should journal resolver_pane_retired"
grep -q '"reason":"result-consumed"' "$JOURNAL_FILE" || fail "retire should journal reason=result-consumed"
[ ! -f "$REG_B" ] || fail "registry row not dropped after the verdict was consumed"
# The WORKTREE lifecycle is untouched: retiring a pane is not reaping a tree.
_reconcile_resolver_panes    # idempotent on an already-retired dispatch
ok

# ── (6) TAB PLACEMENT: the standalone tab + its sweep-allowlist row go too ────────────────────────
: > "$CLOSE_LOG"; : > "$TAB_CLOSE_LOG"
printf 'paneT tabT tab 43 shaC\n' > "$(_resolve_registry_file 43 shaC)"
printf 'RESOLVE: DONE\n'         > "$(_resolve_result_file 43 shaC)"
printf 'paneT\n'                >> "$ALIVE_PANES"
printf 'paneT resolve·slug-c\n' >> "$PANE_AGENTS"
printf 'resolve·slug-c tabT resolve\n' > "$TREES/.herd-tabs"
_reconcile_resolver_panes
grep -qxF paneT "$CLOSE_LOG"     || fail "tab-placed resolver pane not closed"
grep -qxF tabT  "$TAB_CLOSE_LOG" || fail "tab-placed resolver left its empty tab behind"
grep -q 'tabT' "$TREES/.herd-tabs" && fail "tab-placed resolver left its .herd-tabs allowlist row behind"
[ ! -f "$(_resolve_registry_file 43 shaC)" ] || fail "tab-placed registry row not dropped"
ok

# ── (7) GUARDED CLOSE (HERD-134): a row now naming the BUILDER is REFUSED, never closed ───────────
: > "$CLOSE_LOG"
printf 'paneBUILD - split 44 shaD\n' > "$(_resolve_registry_file 44 shaD)"
printf 'RESOLVE: DONE\n'            > "$(_resolve_result_file 44 shaD)"
printf 'paneBUILD\n'               >> "$ALIVE_PANES"
printf 'paneBUILD slug-d\n'        >> "$PANE_AGENTS"   # a BUILDER pane, not a resolve·<slug> one
rbefore="$(grep -c '"event":"resolver_pane_retired"' "$JOURNAL_FILE" 2>/dev/null || printf 0)"
_reconcile_resolver_panes
grep -qxF paneBUILD "$CLOSE_LOG" && fail "the guarded close must REFUSE a pane that is not a resolver"
grep -qxF paneBUILD "$ALIVE_PANES" || fail "the builder pane was killed by a stale resolver registry id"
grep -q '"event":"pane_close_refused"' "$JOURNAL_FILE" || fail "a refused close must journal pane_close_refused"
rafter="$(grep -c '"event":"resolver_pane_retired"' "$JOURNAL_FILE" 2>/dev/null || printf 0)"
[ "$rbefore" = "$rafter" ] || fail "a refused close must not journal a retire"
[ ! -f "$(_resolve_registry_file 44 shaD)" ] || fail "a row pointing at the wrong pane must not linger to be retried"
ok

# ── (8) BYTE-QUIET with no resolver rows: no herdr call, no close, no journal line ────────────────
rm -f "$TREES"/.resolve-registry-* 2>/dev/null || true
: > "$CLOSE_LOG"; : > "$HERDR_LOG"
jbefore="$(wc -l < "$JOURNAL_FILE" | tr -d ' ')"
_reconcile_resolver_panes
[ ! -s "$CLOSE_LOG" ] || fail "reconcile touched a pane with no resolver rows present"
[ ! -s "$HERDR_LOG" ] || fail "reconcile called herdr with no resolver rows present"
[ "$(wc -l < "$JOURNAL_FILE" | tr -d ' ')" = "$jbefore" ] || fail "reconcile journaled with no rows present"
ok

# ── (9) DRY-RUN INERT: a render must never close a pane ───────────────────────────────────────────
printf 'paneDRY - split 45 shaE\n' > "$(_resolve_registry_file 45 shaE)"
printf 'RESOLVE: DONE\n'           > "$(_resolve_result_file 45 shaE)"
printf 'paneDRY\n'                >> "$ALIVE_PANES"
printf 'paneDRY resolve·slug-e\n' >> "$PANE_AGENTS"
: > "$CLOSE_LOG"
( DRYRUN=1; _reconcile_resolver_panes; _retire_resolver_pane 45 shaE result-consumed )
[ ! -s "$CLOSE_LOG" ] || fail "dry-run closed a pane"
[ -f "$(_resolve_registry_file 45 shaE)" ] || fail "dry-run dropped a registry row"
ok

echo "ALL PASS ($pass checks)"
