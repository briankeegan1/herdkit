#!/usr/bin/env bash
# test-config-set-watcher-skip.sh — hermetic proof of HERD-519 leg (a): the watcher-restart
# side-effect of `herd config set` is CONDITIONAL on a watcher existing, and BOUNDED when one does.
#
# THE DEFECT. A watcher-affecting `config set` called cmd_reload unconditionally. With no control room
# running, reload's rebuild leg reaches the pane/socket surface (`herdr workspace list`), which blocks
# without bound when the herdr server is gone or wedged — so the command sat there forever printing
# nothing, and (if it ever got past) relaunched a headless watcher nobody asked for. It is the loudest
# paper cut on a fresh collaborator clone (epic HERD-517).
#
# What this asserts:
#   (A) NO LIVE WATCHER → the restart is SKIPPED: rc=0, promptly, with a one-line note; the KEY still
#       lands in .herd/config; the coordinator skill is still re-rendered; cmd_reload never runs.
#   (B) A LIVE WATCHER (planted under this workspace's argv0, the shared watcher-exempt.sh identity)
#       → the restart STILL runs and still stops that watcher. The lever is not a blanket off-switch.
#   (C) A WEDGED pane surface → the restart is stopped at the bound (HERD_CONFIG_RELOAD_TIMEOUT) and
#       the failure is LOUD but NON-FATAL: rc=0, a warning naming the un-restarted watcher, and the
#       value still written — and (HERD-540) the bound reaps the reload's WHOLE subtree, so not even
#       a GRANDCHILD of the wedged surface survives it.
#   (D) A NON-watcher key is untouched by all of this (byte-identical no-op path).
#
# Fully hermetic: temp git repos, stub herdr/pgrep on PATH, no network, no real daemon. The only
# processes it creates are its own `sleep` decoys, planted under this fixture's unique argv0.
# Run:  bash tests/test-config-set-watcher-skip.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
HERD="$HERE/../bin/herd"
[ -f "$HERD" ] || { echo "FAIL: missing $HERD" >&2; exit 1; }

T="$(mktemp -d)"
# WEDGE_PIDS — every pid the wedged-herdr stub of leg (C) puts into the process table (its own, and
# the GRANDCHILD sleeper it forks). Leg (C) asserts none of them outlives the bound; the EXIT trap
# reaps them regardless so a regression leaks nothing onto the machine running the suite. It lives
# OUTSIDE $T because the trap removes $T before it reaps.
WEDGE_PIDS="$(mktemp)"
trap 'rm -rf "$T"; _reap_decoys; rm -f "$WEDGE_PIDS"' EXIT
PASS=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { PASS=$((PASS + 1)); echo "PASS: $1"; }

DECOYS=""
_reap_decoys() {
  local p
  for p in $DECOYS $(cat "$WEDGE_PIDS" 2>/dev/null || true); do kill -9 "$p" 2>/dev/null || true; done
}

# _reap_wedged_herdr — kill any HANGING stub herdr (and its sleep) left behind by leg (C). The bound
# stops the reload SUBSHELL and its DIRECT children; a herdr that was a GRANDCHILD at expiry outlives
# it, and while that orphan is harmless to the operator (the command already returned), it must not
# outlive this fixture. $BIN is a fresh mktemp path, so this match can only ever name our own stub.
_reap_wedged_herdr() {
  local p k
  for p in $(ps -eo pid=,command= 2>/dev/null | grep -F "$BIN/herdr" | grep -v grep | awk '{print $1}'); do
    for k in $(ps -eo pid=,ppid= 2>/dev/null | awk -v pp="$p" '$2 == pp { print $1 }'); do
      kill -9 "$k" 2>/dev/null || true
    done
    kill -9 "$p" 2>/dev/null || true
  done
  return 0
}

# ── stubs on PATH ────────────────────────────────────────────────────────────────────────────────
BIN="$T/bin"; mkdir -p "$BIN"
# pgrep: `-P` (children of a pid) delegates to the REAL pgrep so the bounded-reload descendant kill is
# exercised faithfully; every other form — the engine's `pgrep -f agent-watch.sh` legacy-stray scan —
# returns only planted pids, so no real process on this machine is ever a candidate.
cat > "$BIN/pgrep" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "-P" ]; then
  [ -x /usr/bin/pgrep ] && exec /usr/bin/pgrep -P "${2:-}"
  exit 1
fi
IFS=':' read -ra pids <<< "${FAKE_STRAY_PIDS:-}"
for p in "${pids[@]}"; do [ -n "$p" ] && printf '%s\n' "$p"; done
exit 0
STUB
chmod +x "$BIN/pgrep"
# herdr: absent-by-default (exit 1). The wedged-surface leg swaps in a HANGING one.
printf '#!/usr/bin/env bash\nexit 1\n' > "$BIN/herdr"; chmod +x "$BIN/herdr"
export PATH="$BIN:$PATH"

# ── capabilities manifest (stub): one watcher-affecting key, one plain key ───────────────────────
CAPS="$T/capabilities.tsv"
{
  printf 'name\tkind\tdescription\twhen_to_surface\trequires\tscope\tgovernance\tvalue_shape\n'
  printf 'WORKSPACE_NAME\tconfig\tProject label\tAlways required\twatcher\t\t\tfree\n'
  printf 'REVIEW_CONCURRENCY\tconfig\tMax parallel reviews\tRaise for throughput\twatcher\t\t\tnumeric\n'
  printf 'SCRIBE_BACKEND\tconfig\tWork-tracker backend\tSet for a tracker\t\t\t\tfree\n'
} > "$CAPS"
export HERD_CAPABILITIES_FILE="$CAPS"

# _make_project <dir> <workspace> — a committed hermetic repo with a minimal .herd/config.
_make_project() {
  local r="$1" ws="$2" r_real
  mkdir -p "$r"; git -C "$r" init -q -b main
  git -C "$r" config user.email t@t.local; git -C "$r" config user.name t
  git -C "$r" commit -q --allow-empty -m base
  r_real="$(cd "$r" && pwd -P)"
  mkdir -p "$r/.herd" "$r/trees"
  cat > "$r/.herd/config" <<CFG
# .herd/config — HERD-519 leg (a) fixture
HERD_VERSION=1
PROJECT_ROOT="$r_real"
WORKTREES_DIR="$r_real/trees"
DEFAULT_BRANCH="origin/main"
WORKSPACE_NAME="$ws"
SCRIBE_BACKEND="file"
REVIEW_CONCURRENCY="2"
CFG
}

# _run <dir> <args...> — run the CLI in <dir>, capturing output + rc + elapsed seconds.
_run() {
  local r="$1"; shift
  local t0=$SECONDS
  OUT="$( cd "$r" && HERD_NONINTERACTIVE=1 HERD_SKIP_DOCTOR=1 FAKE_STRAY_PIDS="" \
            bash "$HERD" "$@" 2>&1 )"
  RC=$?
  ELAPSED=$((SECONDS - t0))
}

# _plant_watcher <workspace-slug> — a decoy process carrying THIS workspace's watcher argv0, which is
# exactly the identity scripts/herd/watcher-exempt.sh enumerates. Echoes its pid. The decoy's own
# stdout/stderr go to /dev/null: it outlives this function, and a child holding the command
# substitution's pipe open would block the caller until the decoy exits.
_plant_watcher() {
  bash -c "exec -a herd-watch-$1 sleep 300" >/dev/null 2>&1 &
  local p=$!
  # Give the exec a moment to land in the process table under its new argv0.
  local i=0
  while [ "$i" -lt 25 ]; do
    grep -q "herd-watch-$1" <<< "$(ps -o command= -p "$p" 2>/dev/null)" && break
    sleep 0.2; i=$((i + 1))
  done
  printf '%s' "$p"
}

# ══ (A) no live watcher → SKIP the restart, promptly, with the note ═════════════════════════════
P="$T/nowatcher"; _make_project "$P" "hk519-none"
_run "$P" config set REVIEW_CONCURRENCY 5
[ "$RC" -eq 0 ] || fail "(A) config set on a watcher key returned rc=$RC with no watcher running: $OUT"
[ "$ELAPSED" -lt 30 ] || fail "(A) config set took ${ELAPSED}s — it must return promptly, not hang"
ok "A1 config set on a watcher key with no watcher returns rc=0 promptly (${ELAPSED}s)"

grep -qi 'no live watcher' <<< "$OUT" || fail "(A) no note explaining the skipped restart: $OUT"
grep -qi 'skipped' <<< "$OUT"         || fail "(A) the note does not say the restart was SKIPPED: $OUT"
ok "A2 the skip is narrated in one line naming the reason"

grep -qi 'rebuilding the control room' <<< "$OUT" \
  && fail "(A) herd reload ran anyway — the restart was not skipped: $OUT"
ok "A3 cmd_reload never runs when no watcher exists"

grep -qE '^[[:space:]]*REVIEW_CONCURRENCY="5"' "$P/.herd/config" \
  || fail "(A) the key did not land in .herd/config: $(grep REVIEW_CONCURRENCY "$P/.herd/config")"
ok "A4 the key still lands in .herd/config (only the restart is skipped)"

[ -f "$P/.claude/commands/coordinator.md" ] \
  || fail "(A) the coordinator skill was not re-rendered on the skip path"
ok "A5 the coordinator skill is still re-rendered (a local write, no socket)"

# ══ (B) a live watcher → the restart STILL runs, and still stops it ═════════════════════════════
Q="$T/watcher"; _make_project "$Q" "hk519-live"
WPID="$(_plant_watcher hk519-live)"; DECOYS="$DECOYS $WPID"
kill -0 "$WPID" 2>/dev/null || fail "(B) the planted decoy watcher did not start"
OUT="$( cd "$Q" && HERD_NONINTERACTIVE=1 HERD_SKIP_DOCTOR=1 FAKE_STRAY_PIDS="" \
          HERD_RELOAD_SKIP_LAUNCH=1 HERD_RELOAD_SIGTERM_POLLS=15 \
          bash "$HERD" config set REVIEW_CONCURRENCY 7 2>&1 )"; RC=$?
[ "$RC" -eq 0 ] || fail "(B) config set failed with a live watcher (rc=$RC): $OUT"
grep -qi 'restarting the watcher' <<< "$OUT" \
  || fail "(B) the restart did not run although a watcher was alive: $OUT"
grep -qi 'no live watcher' <<< "$OUT" \
  && fail "(B) the skip note fired although a watcher was alive: $OUT"
ok "B1 a live watcher still triggers the restart (the skip is not a blanket off-switch)"

_i=0; while [ "$_i" -lt 25 ] && kill -0 "$WPID" 2>/dev/null; do sleep 0.2; _i=$((_i + 1)); done
kill -0 "$WPID" 2>/dev/null && fail "(B) the live watcher was not stopped by the restart"
ok "B2 the restart actually stops the live watcher"

# ══ (C) a WEDGED pane surface → bounded, loud, non-fatal ═══════════════════════════════════════
# The herdr stub now HANGS, reproducing the wedged socket that caused the original hang.
# HERD_RELOAD_SKIP_LAUNCH=fallback keeps the herdr path live while making a real headless watcher
# spawn impossible even if the bound were broken.
#
# THE BOUND MUST OUTLAST THE RELOAD'S OWN RUN-UP (HERD-540). It was 1s, which is SHORTER than the
# ~2s cmd_reload spends stopping the planted watcher and re-rendering the skill before it ever calls
# `herdr` — so on most runs the reload was stopped before it reached the wedged surface at all, and
# this leg silently proved a bound against the watcher-stop instead. That is also what made the leaked
# orphan a ~1-in-30 flake rather than a certainty: the leak only happened on the runs that DID reach
# herdr. A bound comfortably past the run-up makes every run exercise the wedge (C4 fails loudly if
# one ever does not), at the cost of a few seconds of wall clock.
#
# HERD-540: the stub hangs in a FORKED GRANDCHILD, not in its own process, which is what the real
# herdr does (a wrapper whose child makes the blocking socket call) and what the live defect needed:
# the reload subshell's DIRECT child is this stub, so a reap that TERMs only `pgrep -P <subshell>`
# leaves the sleeper orphaned — holding the `$(herdr workspace list)` command-substitution pipe open
# long after the 1s bound returned. Both pids are recorded so C4 can assert neither survives.
cat > "$BIN/herdr" <<STUB
#!/usr/bin/env bash
sleep 120 &
printf '%s %s\n' "\$\$" "\$!" >> "$WEDGE_PIDS"
wait
STUB
chmod +x "$BIN/herdr"
W="$T/wedged"; _make_project "$W" "hk519-wedge"
WPID2="$(_plant_watcher hk519-wedge)"; DECOYS="$DECOYS $WPID2"
# The output is captured to a FILE, not through `$( )`. A command substitution reads its pipe until
# EVERY holder of the write end closes it — including a leaked herdr GRANDCHILD that the bound's
# direct-children sweep missed — so a pipe capture here times the ORPHAN'S `sleep 120`, not the
# command: `herd config set` returns at the 1s bound with the right rc and output, yet ELAPSED reads
# ~121s and this leg fails its own <60s assertion. That is what TIMED OUT this test against
# scripts/ci/run-suite.sh's 120s per-test cap in main-health (intermittent: whether the in-flight
# herdr is a child or a grandchild at expiry decides it). A file capture measures the command itself,
# which is what the bound is a claim about.
WEDGED_OUT="$T/wedged.out"
t0=$SECONDS
( cd "$W" && HERD_NONINTERACTIVE=1 HERD_SKIP_DOCTOR=1 FAKE_STRAY_PIDS="" \
    HERD_RELOAD_SKIP_LAUNCH=fallback HERD_RELOAD_SIGTERM_POLLS=15 \
    HERD_CONFIG_RELOAD_TIMEOUT=8 \
    bash "$HERD" config set REVIEW_CONCURRENCY 9 ) > "$WEDGED_OUT" 2>&1; RC=$?
ELAPSED=$((SECONDS - t0))
OUT="$(cat "$WEDGED_OUT")"
_reap_wedged_herdr
printf '#!/usr/bin/env bash\nexit 1\n' > "$BIN/herdr"; chmod +x "$BIN/herdr"
[ "$RC" -eq 0 ] || fail "(C) a wedged reload made config set FATAL (rc=$RC) — it must warn, not die: $OUT"
[ "$ELAPSED" -lt 60 ] || fail "(C) the bound did not hold — config set took ${ELAPSED}s against a wedged herdr"
ok "C1 a wedged pane surface is bounded (${ELAPSED}s) and non-fatal (rc=0)"

grep -qi 'did not finish within' <<< "$OUT" || fail "(C) the timeout was not reported loudly: $OUT"
grep -qi "herd reload" <<< "$OUT" || fail "(C) the warning does not tell the operator how to finish: $OUT"
ok "C2 the timeout warns loudly and names the manual follow-up"

grep -qE '^[[:space:]]*REVIEW_CONCURRENCY="9"' "$W/.herd/config" \
  || fail "(C) the key was lost when the restart timed out"
ok "C3 the value is written even when the restart is abandoned"

# C4 (HERD-540) — NO DESCENDANT of the abandoned reload survives the bound, at ANY depth. The stub
# recorded its own pid and its forked sleeper's; a short poll absorbs TERM→exit latency (the reap has
# already waited out its own SIGKILL grace, so anything still alive here is genuinely leaked). Note
# that a leak also shows up ABOVE as a blown C1: an orphan holding the `$(herdr workspace list)`
# command-substitution pipe open keeps THIS test's own `$( … )` capture blocked for the sleeper's full
# 120s — the exact shape of the intermittent main-health timeout HERD-538's builder hit.
WEDGE_SEEN="$(tr -s '[:space:]' ' ' < "$WEDGE_PIDS")"
[ -n "$(printf '%s' "$WEDGE_SEEN" | tr -d ' ')" ] \
  || fail "(C) the wedged herdr stub never ran — leg C no longer exercises the reap"
_i=0; LEAKED=""
while [ "$_i" -lt 25 ]; do
  LEAKED=""
  for _p in $WEDGE_SEEN; do kill -0 "$_p" 2>/dev/null && LEAKED="$LEAKED $_p"; done
  [ -z "$LEAKED" ] && break
  sleep 0.2; _i=$((_i + 1))
done
[ -z "$LEAKED" ] \
  || fail "(C) the bound leaked descendants past the reload it abandoned:$LEAKED — $(ps -o pid=,ppid=,command= -p "$(printf '%s' "$LEAKED" | sed 's/^ //; s/ /,/g')" 2>/dev/null | tr '\n' ';')"
ok "C4 the bound reaps the reload's WHOLE subtree — not even a grandchild outlives it (HERD-540)"

# ══ (D) a NON-watcher key is untouched by any of this ══════════════════════════════════════════
D="$T/plain"; _make_project "$D" "hk519-plain"
_run "$D" config set SCRIBE_BACKEND changelog
[ "$RC" -eq 0 ] || fail "(D) a plain key set failed: $OUT"
grep -qi 'no live watcher' <<< "$OUT" && fail "(D) the watcher note leaked onto a non-watcher key: $OUT"
grep -qi 'restarting the watcher' <<< "$OUT" && fail "(D) a non-watcher key restarted the watcher: $OUT"
grep -qi 'no watcher restart or skill re-render required' <<< "$OUT" \
  || fail "(D) the non-watcher path's narration changed: $OUT"
ok "D1 a non-watcher key keeps its byte-identical no-op path"

echo "ALL PASS ($PASS checks)"
