#!/usr/bin/env bash
# test-reviewer-pane-lifecycle.sh — hermetic tests for the reviewer PANE LIFECYCLE (HERD-113):
#   (1) _dispatch_review lays down a registry row "<pid> -" for the (pr,sha) and passes the registry
#       seam to the reviewer; herd-review.sh overwrites it with its real pane id (agent-pane mode).
#   (2) ADOPT/never-duplicate: a dispatch that finds a LIVE reviewer for the same (pr,sha) — poller pid
#       alive OR (across a dead poller) its pane still present — skips instead of spawning a second one.
#   (3) RETIRE-ON-CONSUME: collecting a PASS/BLOCK verdict closes the reviewer's pane via the driver,
#       journals reviewer_pane_retired, and drops the registry row.
#   (4) STARTUP SWEEP: an ORPHANED row (dead poller, pane still live) is retired; a LIVE-poller row is
#       left (adopted); a row with a pending result file is left for the normal gate step to collect.
#   (5) STALE-SHA discard retires the stale reviewer's pane too.
#
# Sources agent-watch.sh in lib mode under the DEFAULT herdr-claude driver with a herdr stub whose pane
# liveness is driven by an "alive panes" file, so herd_driver_pane_alive / close_pane exercise the real
# driver seam. Stubs gh/git/claude too (NETWORK-FREE). Run:  bash tests/test-reviewer-pane-lifecycle.sh
# No `set -e`: some checks assert non-zero returns explicitly.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../scripts/herd/agent-watch.sh"
REVIEW="$HERE/../scripts/herd/herd-review.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

[ -f "$WATCH" ]  || fail "agent-watch.sh not found at $WATCH"
[ -f "$REVIEW" ] || fail "herd-review.sh not found at $REVIEW"
command -v python3 >/dev/null 2>&1 || fail "python3 required to run this test"

wait_for() {
  local deadline=$(( $(date +%s) + $1 )); shift
  while ! "$@" 2>/dev/null; do
    [ "$(date +%s)" -ge "$deadline" ] && return 1
    sleep 0.2
  done
  return 0
}

# ── Stub binaries on PATH ─────────────────────────────────────────────────────
BIN="$T/bin"; mkdir -p "$BIN"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/gh"; chmod +x "$BIN/gh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/git"; chmod +x "$BIN/git"

# herdr stub: `pane read <id>` succeeds ONLY when <id> is listed in $ALIVE_PANES (the liveness surface
# herd_driver_pane_alive probes). `pane close <id>` appends to $CLOSE_LOG and REMOVES it from alive.
# `agent list` reports every ALIVE pane as the review agent occupying it (name "review·stub") — the
# identity the HERD-134 guarded close verifies before retiring a reviewer pane; in production the
# reviewer pane is exactly such a review·<slug> agent. Everything else is a safe no-op. Byte-simple:
# this is the whole control surface the lifecycle touches.
ALIVE_PANES="$T/alive-panes"; : > "$ALIVE_PANES"
CLOSE_LOG="$T/close.log"; : > "$CLOSE_LOG"
cat > "$BIN/herdr" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "pane read")
    id="$3"
    grep -qxF "$id" "${ALIVE_PANES:-/dev/null}" 2>/dev/null && exit 0
    exit 1 ;;
  "pane close")
    id="$3"
    printf '%s\n' "$id" >> "${CLOSE_LOG:-/dev/null}" 2>/dev/null || true
    # a closed pane is no longer alive
    if [ -f "${ALIVE_PANES:-}" ]; then grep -vxF "$id" "$ALIVE_PANES" > "$ALIVE_PANES.tmp" 2>/dev/null || true; mv -f "$ALIVE_PANES.tmp" "$ALIVE_PANES" 2>/dev/null || true; fi
    exit 0 ;;
  "agent list")
    # Each alive pane IS the review agent occupying it — the identity herd_close_pane_verified checks.
    python3 -c '
import os, json
seen = []
try:
  with open(os.environ.get("ALIVE_PANES","")) as f:
    for l in f:
      p = l.strip()
      if p and p not in seen: seen.append(p)
except Exception:
  pass
print(json.dumps({"result": {"agents": [{"name": "review·stub", "pane_id": p, "agent_status": "working"} for p in seen]}}))
' 2>/dev/null || echo '{"result":{"agents":[]}}'
    exit 0 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$BIN/herdr"
export PATH="$BIN:$PATH" ALIVE_PANES CLOSE_LOG

# Stub reviewer (HERD_REVIEW_BIN seam): logs its spawn (proves dispatch counts), stays in flight for
# $STUB_DELAY, then writes the verdict atomically. It ALSO writes the registry pane id (mimicking the
# real herd-review.sh agent-pane path) when STUB_PANE is set — so we can drive retire-on-consume.
STUB_REVIEW="$T/stub-review.sh"
cat > "$STUB_REVIEW" <<'STUB'
#!/usr/bin/env bash
pr="$1"; slug="$2"
[ -n "${STUB_SPAWN_LOG:-}" ] && printf '%s %s\n' "$pr" "$slug" >> "$STUB_SPAWN_LOG"
if [ -n "${STUB_PANE:-}" ] && [ -n "${HERD_REVIEW_REGISTRY_FILE:-}" ]; then
  printf '%s %s\n' "$$" "$STUB_PANE" > "$HERD_REVIEW_REGISTRY_FILE"
  # register the pane as alive on the herdr liveness surface
  printf '%s\n' "$STUB_PANE" >> "${ALIVE_PANES:-/dev/null}"
fi
sleep "${STUB_DELAY:-0}"
if [ -n "${HERD_REVIEW_RESULT_FILE:-}" ]; then
  printf '%s\n' "${STUB_VERDICT:-REVIEW: PASS}" > "$HERD_REVIEW_RESULT_FILE.tmp.$$"
  mv "$HERD_REVIEW_RESULT_FILE.tmp.$$" "$HERD_REVIEW_RESULT_FILE"
fi
printf '%s\n' "${STUB_VERDICT:-REVIEW: PASS}"
STUB
chmod +x "$STUB_REVIEW"

# ── Source agent-watch.sh in lib mode (DEFAULT herdr-claude driver) ──────────
export AGENT_WATCH_LIB=1
export WORKTREES_DIR="$T/trees"; mkdir -p "$T/trees"
export JOURNAL_FILE="$T/journal.jsonl"; : > "$JOURNAL_FILE"
export HERD_CONFIG_FILE="$T/no-such-config"
export HERD_REVIEW_BIN="$STUB_REVIEW"
export REVIEW_CONCURRENCY=4
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"

for fn in _dispatch_review _review_gate_step _reviewer_registry_live _retire_reviewer_pane \
          _sweep_reviewer_registry _review_registry_file _discard_stale_reviews; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined after sourcing"
done
ok

export STUB_SPAWN_LOG="$T/spawns.log"

# ── (1) dispatch writes a registry row "<pid> -", then the reviewer fills in its pane id ──────────
: > "$STUB_SPAWN_LOG"; : > "$ALIVE_PANES"; : > "$CLOSE_LOG"
export STUB_DELAY=3 STUB_VERDICT="REVIEW: PASS" STUB_PANE="paneA"
s="$(_review_gate_step 1 slug-a aaa111)"
[ "$s" = "RUNNING" ] || fail "first step should dispatch (got $s)"
reg="$(_review_registry_file 1 aaa111)"
wait_for 5 test -s "$reg" || fail "registry row never written"
# after the stub reviewer runs, the row carries the real pane id (paneA) and paneA is alive
wait_for 5 sh -c "grep -q ' paneA$' '$reg'" || fail "reviewer did not record its pane id in the registry"
grep -qxF paneA "$ALIVE_PANES" || fail "reviewer pane not registered alive"
ok

# ── (2) ADOPT: never dispatch a second reviewer while one is LIVE for the same (pr,sha) ───────────
# (a) poller pid alive → live via the pid; a re-dispatch is a no-op (the inflight-pid guard also holds).
_reviewer_registry_live 1 aaa111 || fail "a live-poller registry should read live"
before="$(wc -l < "$STUB_SPAWN_LOG" | tr -d ' ')"
_dispatch_review 1 slug-a aaa111
after="$(wc -l < "$STUB_SPAWN_LOG" | tr -d ' ')"
[ "$before" = "$after" ] || fail "dispatch must ADOPT a live reviewer, not spawn a second"
ok
# (b) poller DEAD but pane still alive (a herdr reload orphan) and NO inflight marker (the poller was
# reaped on restart) → still live via the pane, so dispatch ADOPTS and journals reviewer_adopted.
bash -c 'exit 0' & deadpid=$!; wait "$deadpid" 2>/dev/null
printf '%s paneLIVE\n' "$deadpid" > "$(_review_registry_file 2 bbb222)"
printf 'paneLIVE\n' >> "$ALIVE_PANES"
_reviewer_registry_live 2 bbb222 || fail "dead-poller-but-live-pane should read LIVE (adopt across restart)"
: > "$STUB_SPAWN_LOG"
_dispatch_review 2 slug-b bbb222
[ ! -s "$STUB_SPAWN_LOG" ] || fail "must not duplicate into a still-live reviewer pane"
grep -q '"event":"reviewer_adopted"' "$JOURNAL_FILE" || fail "registry adopt should journal reviewer_adopted"
ok
# (c) poller dead AND pane gone → NOT live → a clean dispatch proceeds.
printf '%s paneGONE\n' "$deadpid" > "$(_review_registry_file 3 ccc333)"   # paneGONE not in ALIVE_PANES
_reviewer_registry_live 3 ccc333 && fail "dead poller + absent pane must read NOT live"
ok

# ── (3) RETIRE-ON-CONSUME: collecting the verdict closes the pane + journals + drops the row ──────
: > "$CLOSE_LOG"
wait_for 8 test -f "$(_review_result_file 1 aaa111)" || fail "PR 1 result never arrived"
s="$(_review_gate_step 1 slug-a aaa111)"
[ "$s" = "PASS" ] || fail "collect tick should report PASS (got $s)"
grep -qxF paneA "$CLOSE_LOG" || fail "verdict consumption did not close the reviewer pane (paneA)"
grep -q '"event":"reviewer_pane_retired"' "$JOURNAL_FILE" || fail "retire should journal reviewer_pane_retired"
[ ! -f "$(_review_registry_file 1 aaa111)" ] || fail "registry row not dropped after verdict consumption"
grep -qxF paneA "$ALIVE_PANES" && fail "paneA should no longer be alive after close"
ok

# ── (4) STARTUP SWEEP: retire orphans, adopt live pollers, spare pending-result rows ──────────────
: > "$CLOSE_LOG"; : > "$ALIVE_PANES"
# orphan: dead poller, pane still live → must be retired + row dropped.
printf '%s paneORPH\n' "$deadpid" > "$(_review_registry_file 10 sweep10)"
printf 'paneORPH\n' >> "$ALIVE_PANES"
printf '%s\n' "$deadpid" > "$(_review_inflight_file 10 sweep10)"
# live: this test's own pid alive → must be left untouched.
printf '%s paneLIVE2\n' "$$" > "$(_review_registry_file 11 sweep11)"
printf 'paneLIVE2\n' >> "$ALIVE_PANES"
# pending-result: dead poller but a verdict waiting → leave for the normal gate step to collect.
printf '%s panePEND\n' "$deadpid" > "$(_review_registry_file 12 sweep12)"
printf 'panePEND\n' >> "$ALIVE_PANES"
printf 'REVIEW: PASS\n' > "$(_review_result_file 12 sweep12)"

_sweep_reviewer_registry

grep -qxF paneORPH "$CLOSE_LOG" || fail "sweep did not retire the orphaned pane"
[ ! -f "$(_review_registry_file 10 sweep10)" ] || fail "sweep did not drop the orphaned registry row"
[ ! -f "$(_review_inflight_file 10 sweep10)" ] || fail "sweep did not drop the orphaned inflight marker"
[ -f "$(_review_registry_file 11 sweep11)" ] || fail "sweep wrongly removed a LIVE-poller row"
grep -qxF paneLIVE2 "$CLOSE_LOG" && fail "sweep wrongly closed a live reviewer's pane"
[ -f "$(_review_registry_file 12 sweep12)" ] || fail "sweep wrongly removed a pending-result row"
grep -qxF panePEND "$CLOSE_LOG" && fail "sweep wrongly closed a pane whose verdict is still pending"
ok

# ── (5) STALE-SHA discard retires the stale reviewer's pane ──────────────────────────────────────
: > "$CLOSE_LOG"
printf '%s paneSTALE\n' "$$" > "$(_review_registry_file 20 oldsha)"
printf 'paneSTALE\n' >> "$ALIVE_PANES"
_discard_stale_reviews 20 newsha
grep -qxF paneSTALE "$CLOSE_LOG" || fail "stale-sha discard did not retire the stale reviewer pane"
[ ! -f "$(_review_registry_file 20 oldsha)" ] || fail "stale-sha discard left the registry row behind"
ok

# ── (6) byte-quiet when there are no reviewer rows: sweep is a no-op, no journal, no close ────────
rm -f "$TREES"/.review-registry-* 2>/dev/null || true
: > "$CLOSE_LOG"; jbefore="$(wc -l < "$JOURNAL_FILE" | tr -d ' ')"
_sweep_reviewer_registry
[ ! -s "$CLOSE_LOG" ] || fail "sweep touched a pane with no reviewer rows present"
[ "$(wc -l < "$JOURNAL_FILE" | tr -d ' ')" = "$jbefore" ] || fail "sweep journaled with no orphans present"
ok

echo "ALL PASS ($pass checks)"
