#!/usr/bin/env bash
# scripts/herd/sim/builder-chaos-sim.sh — the RECOVERY-HYGIENE adversary for HERD-162.
#
# The claim the recovery paths make: a builder can be force-killed at ANY point in its lifecycle and
# the watcher's recovery will act only on POSITIVE evidence, clean up the corpse it finds, never
# destroy work, never stack a respawn on a corpse, never leave an immortal ledger row, and never leave
# a tracker item claimed by a dead process. A claim like that is worth what its adversary proves.
#
# For each LIFECYCLE STAGE a builder can die at, this sim:
#   1. builds a fresh fixture — a real git repo, a real worktree on a real branch, a real task spec, a
#      stub herdr whose agent registry ENFORCES agent_name_taken (a name stays held until the pane or
#      tab holding it is closed — the single fact that made the pre-HERD-162 respawn structurally fail),
#      a tab registry, the four slug-keyed ledgers, and a BACKLOG.md carrying a real file-backend claim;
#   2. FORCE-KILLS the builder in the shape that stage produces — vanished agent, listed-but-unwakeable
#      session, limit-parked, mid-work, already-respawned-once;
#   3. runs the watcher's dead-builder reconcile in a CHILD PROCESS with zero inherited memory (two
#      ticks: the first records the anchor, the second crosses into DEAD — the grace window is real);
#   4. asserts the CLEANUP INVARIANTS below hold, whatever the stage.
#
# The invariants, each checked at every stage it applies to:
#   I1 NO CORPSE       — before a respawn creates anything, the dead agent's registry row and builder
#                        tab are gone. The corpse is reaped as STEP 0, never cleaned up after the fact.
#   I2 NO STACKING     — a slug never ends a tick with two agents, and never with an orphan tab.
#   I3 NO IMMORTAL ROW — the slug's terminal reap closes all four slug-keyed ledgers.
#   I4 NO WORK LOST    — a killed builder that produced commits or dirt keeps its worktree, its branch
#                        and its tab. Recovery that cannot prove a tree disposable never touches it.
#   I5 HONEST CLAIM    — the tracker claim is released IFF the builder is genuinely abandoned (dead,
#                        clean, not respawning); otherwise it is HELD, and the hold is said out loud.
#   I6 PROVENANCE      — every cleanup action leaves a journal event naming what it did.
#
# Then the RESTART half: the reconcile child is KILLED mid-corpse-reap (pane closed, tab not yet), and
# a brand-new process must converge to a clean world and a single live agent — the corpse reap is an
# idempotent reconciliation, not a one-shot side effect.
#
# Hermetic: a local git repo, a stub `herdr` on PATH, the journal pinned to the artifacts dir. NO
# network, NO model, NO real tab, and it never touches the operator's control room.
#   bash scripts/herd/sim/builder-chaos-sim.sh [--artifacts DIR] [--keep]
# Exit: 0 = every checkpoint passed · 1 = at least one failed. Writes <artifacts>/scorecard.json.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../agent-watch.sh"

c_bold=$'\033[1m'; c_dim=$'\033[2m'; c_grn=$'\033[32m'; c_red=$'\033[31m'; c_rst=$'\033[0m'
step() { printf '\n%s[%s]%s %s\n' "$c_bold" "$1" "$c_rst" "$2"; }
ok()   { printf '  %s✓%s %s\n' "$c_grn" "$c_rst" "$*"; PASS=$((PASS+1)); _card pass "$*"; }
bad()  { printf '  %s✗%s %s\n' "$c_red" "$c_rst" "$*"; FAIL=$((FAIL+1)); _card fail "$*"; }
info() { printf '  %s→%s %s\n' "$c_dim" "$c_rst" "$*"; }
PASS=0; FAIL=0
CARD=""
_card() { CARD="${CARD}$1"$'\t'"$2"$'\n'; }
# assert <message> <command…> / refute <message> <command…> — ONE checkpoint each. The command's own
# exit status is the verdict, so a checkpoint reads as the claim it makes and no `$?` is ever juggled.
assert() { local m="$1"; shift; if "$@"; then ok "$m"; else bad "$m"; fi; }
refute() { local m="$1"; shift; if "$@"; then bad "$m"; else ok "$m"; fi; }

ART=""; KEEP=""
while [ $# -gt 0 ]; do
  case "$1" in
    --artifacts) ART="${2:-}"; KEEP=1; shift 2 ;;
    --keep)      KEEP=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -n "$ART" ] || ART="$(mktemp -d)"
mkdir -p "$ART"
[ -n "$KEEP" ] || trap 'rm -rf "$ART"' EXIT

[ -f "$WATCH" ] || { echo "agent-watch.sh not found at $WATCH" >&2; exit 1; }
for b in git python3; do command -v "$b" >/dev/null 2>&1 || { echo "$b required" >&2; exit 1; }; done

# ── the stub herdr: an agent registry that ENFORCES agent_name_taken ──────────────────────────────
# This is the whole fidelity of the sim. Under real herdr an agent NAME is held by its registration
# until the pane (or the tab containing it) goes away — `claude` is the pane's ROOT process. So:
#   agent start <name> … --tab <t>  → FAILS (exit 1) when <name> is already registered; else registers
#                                     it on a fresh pane inside <t>
#   pane close <p>                  → drops the agent registered on pane <p> (the name becomes free)
#   tab close <t>                   → drops the tab AND every agent living in it
# A sim that let `agent start` succeed over a corpse would prove nothing: the bug under test IS the
# name collision. Every invocation is also appended, in order, to $ACTIONS.
BIN="$ART/bin"; mkdir -p "$BIN"
cat > "$BIN/herdr" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${ACTIONS:-/dev/null}"
W="${WORLD:?WORLD unset}"
case "$1 ${2:-}" in
  "workspace list") printf '{"result":{"workspaces":[{"name":"simws","workspace_id":"ws1"}]}}\n' ;;
  "agent list")     python3 -c 'import json,os; print(json.dumps({"result":{"agents":json.load(open(os.environ["WORLD"]))["agents"]}}))' ;;
  "tab list")       python3 -c 'import json,os; print(json.dumps({"result":{"tabs":json.load(open(os.environ["WORLD"]))["tabs"]}}))' ;;
  "notification show") printf '%s\n' "$*" >> "${NOTIFY:-/dev/null}" ;;   # title AND body — the claim clause lives in the body
  "tab create")
      python3 -c '
import json, os, sys
w = json.load(open(os.environ["WORLD"]))
n = w["seq"] = w["seq"] + 1
label = ""
a = sys.argv[1:]
for i, t in enumerate(a):
    if t == "--label" and i + 1 < len(a): label = a[i+1]
tab = {"tab_id": "tab-%d" % n, "label": label, "workspace_id": "ws1"}
w["tabs"].append(tab)
json.dump(w, open(os.environ["WORLD"], "w"))
print(json.dumps({"result": {"tab": {"tab_id": tab["tab_id"]}, "root_pane": {"pane_id": "pane-root-%d" % n}}}))' "$@" ;;
  "tab close")
      TAB="${3:-}" python3 -c '
import json, os
w = json.load(open(os.environ["WORLD"])); tid = os.environ["TAB"]
w["tabs"]   = [t for t in w["tabs"]   if t["tab_id"] != tid]
w["agents"] = [a for a in w["agents"] if a.get("tab_id") != tid]
json.dump(w, open(os.environ["WORLD"], "w"))' ;;
  "pane close")
      PANE="${3:-}" python3 -c '
import json, os
w = json.load(open(os.environ["WORLD"])); pid = os.environ["PANE"]
w["agents"] = [a for a in w["agents"] if a.get("pane_id") != pid]
json.dump(w, open(os.environ["WORLD"], "w"))' ;;
  "agent start")
      NAME="${3:-}" ARGS="$*" python3 -c '
import json, os, sys
w = json.load(open(os.environ["WORLD"])); name = os.environ["NAME"]
if any(a.get("name") == name for a in w["agents"]):
    sys.stderr.write("agent_name_taken: %s\n" % name); sys.exit(1)   # the real herdr constraint
args = os.environ["ARGS"].split()
tab = args[args.index("--tab") + 1] if "--tab" in args else ""
n = w["seq"] = w["seq"] + 1
w["agents"].append({"name": name, "pane_id": "pane-%d" % n, "tab_id": tab, "agent_status": "working"})
json.dump(w, open(os.environ["WORLD"], "w"))' || exit 1 ;;
esac
exit 0
STUB
chmod +x "$BIN/herdr"

# ── the reconcile CHILD: a whole watcher lifetime, from `source` to death ─────────────────────────
# Each tick runs in a FRESH process. A crashed tick and the tick that follows share nothing but the
# filesystem — which is exactly what "recovery acts on positive evidence" has to mean.
#
# CRASH_AFTER names the corpse-reap step after which the process dies (exit 9, before it can do
# anything else). The wrapper is installed HERE, in the sim, by copying the shipped function and
# appending the death — the engine carries no crash seam.
cat > "$ART/tick.sh" <<'CHILD'
#!/usr/bin/env bash
set -uo pipefail
export AGENT_WATCH_LIB=1
# shellcheck source=/dev/null
. "$WATCH_SH" || { echo "SOURCE-FAIL"; exit 2; }
MAIN="$SIM_MAIN"; TREES="$SIM_TREES"
DEAD_STATE="$TREES/.agent-watch-dead"
DEAD_RESPAWN_STATE="$TREES/.agent-watch-respawn"
LIMIT_STATE="$TREES/.agent-watch-limit"
SENDKEYS_STATE="$TREES/.agent-watch-limit-sendkeys"
DEFAULT_BRANCH="main"; DRYRUN=""; WORKSPACE_NAME="simws"
# HERD-310: the pane guard requires sandbox-* or HERD_DISPOSABLE_WORKSPACE=1; declare disposable so
# the sim's retirement tick can close stub tabs without being refused.
export WORKSPACE_NAME
export HERD_DISPOSABLE_WORKSPACE=1

crash_after() {
  eval "$(declare -f "$1" | sed "1s/^$1/__orig_$1/")"
  eval "$1() { __orig_$1 \"\$@\"; exit 9; }"
}
case "${CRASH_AFTER:-none}" in
  # kill the tick with the corpse's PANE closed but its TAB (and registry row) still standing — the
  # half-reaped world a SIGKILL between two herdr calls actually leaves behind.
  after-pane-close) crash_after herd_close_pane_verified ;;
  none) : ;;
esac

case "${SIM_ENTRY:-reconcile}" in
  reconcile)
    v="$(_reconcile_dead_builder "$SIM_SLUG" "$TREES/$SIM_SLUG" "${SIM_ASTATUS:-}" "${SIM_LIVENESS:-}")"
    printf 'VERDICT %s\n' "$v" ;;
  corpse)
    if _reap_builder_corpse "$SIM_SLUG" "$TREES/$SIM_SLUG"; then printf 'CORPSE free\n'; else printf 'CORPSE held\n'; fi ;;
  respawn)
    if _respawn_builder_in_worktree "$SIM_SLUG" "$TREES/$SIM_SLUG" 2>/dev/null; then printf 'RESPAWN ok\n'; else printf 'RESPAWN failed\n'; fi ;;
  reap)
    _reap_slug "$SIM_SLUG" "$TREES/$SIM_SLUG" "${SIM_PR:-}" "${SIM_SHA:-}" "${SIM_REASON:-merged}"
    printf 'REAP done\n' ;;
esac
CHILD

# tick <scenario-dir> <slug> — one watcher lifetime. Extra config comes from the caller's environment.
tick() {
  local scn="$1" slug="$2"
  PATH="$BIN:$PATH" \
  WATCH_SH="$WATCH" SIM_MAIN="$scn/main" SIM_TREES="$scn/trees" SIM_SLUG="$slug" \
  WORLD="$scn/world.json" ACTIONS="$scn/actions.log" NOTIFY="$scn/notify.log" \
  HERD_CONFIG_FILE="$scn/no-config" JOURNAL_FILE="$scn/journal.jsonl" HERD_JOURNAL_HERMETIC=1 \
  PROJECT_ROOT="$scn/main" BACKLOG_FILE="$scn/main/BACKLOG.md" SCRIBE_BACKEND=file \
  HERD_REMOTE=origin HERD_BRANCH_NAME=main WATCHER_OWNER=simop DEAD_GRACE_MIN=0 \
  HERD_DISPOSABLE_WORKSPACE=1 \
    bash "$ART/tick.sh" 2>/dev/null
}

# ── the fixture: a real repo, a real worktree, a real claim, a real corpse ─────────────────────────
# fixture <scenario-dir> <slug> <clean|commits|dirty> [agent-shape: live|vanished]
fixture() {
  local scn="$1" slug="$2" mode="$3" shape="${4:-live}"
  local main="$scn/main" trees="$scn/trees"
  rm -rf "$scn"; mkdir -p "$main" "$trees"
  git -C "$main" init -q -b main
  git -C "$main" config user.email sim@sim; git -C "$main" config user.name sim
  echo base > "$main/file.txt"
  # A real file-backend claim, stamped by this sim's operator identity. Releasing it is a real edit.
  printf -- '- 🚧 HERD-162 — recovery hygiene (claimed by simop)\n' > "$main/BACKLOG.md"
  git -C "$main" add -A; git -C "$main" commit -qm base

  git -C "$main" worktree add -q -b "feat/$slug" "$trees/$slug" main
  case "$mode" in
    clean)   : ;;
    commits) echo "the feature" > "$trees/$slug/file.txt"
             git -C "$trees/$slug" -c user.email=sim@sim -c user.name=sim commit -qam "$slug" ;;
    dirty)   echo "work a human has not committed" >> "$trees/$slug/file.txt" ;;
  esac

  # The externalized task spec the respawn re-points a fresh agent at, and the tracker-ref marker the
  # lane writes at spawn (this is what makes the slug's claim discoverable at death).
  printf 'build the thing\n' > "$trees/$slug.task.md"
  printf 'HERD-162\n' > "$trees/.herd-ref-$slug"

  # The herdr world. `live` = the corpse is still REGISTERED (the HERD-114 shape: herdr lists an agent
  # whose process is dead) — the case where the name is held and a naive respawn dies on it.
  # `vanished` = the agent row is gone but its tab lingers.
  if [ "$shape" = live ]; then
    cat > "$scn/world.json" <<EOF
{"seq":100,"agents":[{"name":"$slug","pane_id":"pane-corpse","tab_id":"tab-corpse","agent_status":"idle"},
                     {"name":"$slug-neighbour","pane_id":"pane-nb","tab_id":"tab-nb","agent_status":"working"}],
 "tabs":[{"tab_id":"tab-corpse","label":"$slug","workspace_id":"ws1"},
         {"tab_id":"tab-nb","label":"$slug-neighbour","workspace_id":"ws1"}]}
EOF
  else
    cat > "$scn/world.json" <<EOF
{"seq":100,"agents":[{"name":"$slug-neighbour","pane_id":"pane-nb","tab_id":"tab-nb","agent_status":"working"}],
 "tabs":[{"tab_id":"tab-corpse","label":"$slug","workspace_id":"ws1"},
         {"tab_id":"tab-nb","label":"$slug-neighbour","workspace_id":"ws1"}]}
EOF
  fi
  printf '%s tab-corpse builder\n%s-neighbour tab-nb builder\n' "$slug" "$slug" > "$trees/.herd-tabs"
  : > "$scn/actions.log"; : > "$scn/notify.log"; : > "$scn/journal.jsonl"
}

# ── world probes ──────────────────────────────────────────────────────────────────────────────────
agents_named()  { python3 -c 'import json,os,sys; w=json.load(open(sys.argv[1])); print(sum(1 for a in w["agents"] if a["name"]==sys.argv[2]))' "$1/world.json" "$2"; }
tab_exists()    { python3 -c 'import json,sys; w=json.load(open(sys.argv[1])); print("yes" if any(t["tab_id"]==sys.argv[2] for t in w["tabs"]) else "no")' "$1/world.json" "$2"; }
tabs_labelled() { python3 -c 'import json,sys; w=json.load(open(sys.argv[1])); print(sum(1 for t in w["tabs"] if t["label"]==sys.argv[2]))' "$1/world.json" "$2"; }
claimed()       { grep -q 'claimed by' "$1/main/BACKLOG.md" && printf 'yes' || printf 'no'; }
# ledger_has <scn> <slug> <ledger> — 0 iff that one slug-keyed ledger still carries a row for <slug>.
ledger_has()    { [ -s "$1/trees/.agent-watch-$3" ] && grep -q "^$2 " "$1/trees/.agent-watch-$3"; }
# ledger_rows <scn> <slug> — every slug-keyed ledger still carrying a row for <slug>. Empty ⇒ purged.
ledger_rows()   {
  local out="" f
  for f in dead respawn limit limit-sendkeys; do ledger_has "$1" "$2" "$f" && out="${out}$f "; done
  printf '%s' "$out"; }
journaled()     { grep -q "\"event\":\"$2\"" "$1/journal.jsonl" 2>/dev/null; }

# ── terminal-corpse-STATE probes (HERD-326) ───────────────────────────────────────────────────────
# The reap's END STATE, polled — a timing-tolerant read of the same invariants, not a WEAKER one. These
# sit ALONGSIDE the ORDERING checks below (they do not replace them): `ordered` still proves the corpse
# is reaped BEFORE the respawn creates anything (the anti-stacking / agent_name_taken guard), while
# these state polls absorb a late herdr round-trip under heavy box load (the PR #431 false-red) where a
# one-shot read would false-red. Each predicate is a plain 0/1 on the world file.
corpse_tab_gone() { [ "$(tab_exists "$1" tab-corpse)" = no ]; }
agents_is()       { [ "$(agents_named "$1" "$2")" = "$3" ]; }
tablabel_is()     { [ "$(tabs_labelled "$1" "$2")" = "$3" ]; }
# poll_state <tries> <sleep> <predicate…> — succeed the INSTANT <predicate> holds; else re-check up to
# <tries> times, sleeping <sleep> between tries. On the happy path the first check already holds — no
# sleep, no behavioural change, byte-identical output.
poll_state() {
  local _t="$1" _s="$2"; shift 2
  local _i=0
  while [ "$_i" -lt "$_t" ]; do "$@" && return 0; _i=$((_i+1)); [ "$_i" -lt "$_t" ] && sleep "$_s"; done
  return 1
}
# ordered <scn> <earlier-pattern> <later-pattern> — the ORDERING invariant, kept but made TIMING-
# TOLERANT (HERD-326). Under heavy box load a child can flush its actions-log lines a beat late, so we
# POLL until BOTH patterns are present (or the budget is spent) BEFORE comparing their line numbers —
# only the racy "read before the lines exist" is removed, never the invariant. 0 IFF both appear AND
# the first precedes the second. A respawn that stacks on a corpse — the new agent starting BEFORE the
# corpse pane closes, the agent_name_taken bug — still FAILS here (later line < earlier line), which a
# terminal state-only check could NOT catch.
ordered() {
  local scn="$1" early="$2" late="$3" a="" b="" i=0
  while [ "$i" -lt 30 ]; do
    a="$(grep -n -- "$early" "$scn/actions.log" 2>/dev/null | head -1 | cut -d: -f1)"
    b="$(grep -n -- "$late"  "$scn/actions.log" 2>/dev/null | head -1 | cut -d: -f1)"
    { [ -n "$a" ] && [ -n "$b" ]; } && break
    i=$((i+1)); sleep 0.1
  done
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]
}

# two_ticks <scn> <slug> — the grace window is real: tick 1 records the anchor (PENDING), tick 2 crosses
# into DEAD. Each is a fresh process. Echoes tick 2's verdict.
two_ticks() {
  local scn="$1" slug="$2"
  tick "$scn" "$slug" >/dev/null
  tick "$scn" "$slug" | sed -n 's/^VERDICT //p'
}

# ══ PART 1 — kill the builder at every lifecycle stage ════════════════════════════════════════════
step stages "force-kill a builder at each lifecycle stage; assert the cleanup invariants hold"

# ── stage: PRE-COMMIT, agent still registered (the HERD-114 corpse). Respawn must reap it first. ──
scn="$ART/s-precommit"; SLUG=precommit
fixture "$scn" "$SLUG" clean live
v="$(DEAD_BUILDER_AUTORESPAWN=on CLAIM_RELEASE=release two_ticks "$scn" "$SLUG")"
assert "precommit · a vanished-but-registered builder crosses into DEAD" test "$v" = DEAD
assert "precommit · I2 exactly ONE agent holds the slug after the respawn (no stacking)" poll_state 30 0.1 agents_is "$scn" "$SLUG" 1
assert "precommit · I1 the corpse tab reaches its terminal reaped state (gone)" poll_state 30 0.1 corpse_tab_gone "$scn"
assert "precommit · I2 exactly ONE tab carries the slug label (no orphan)" poll_state 30 0.1 tablabel_is "$scn" "$SLUG" 1
assert "precommit · I1 the corpse is reaped BEFORE the respawn tab is created" ordered "$scn" 'pane close pane-corpse' 'tab create'
refute "precommit · I1 the corpse's tab-registry row is pruned" grep -q "^precommit tab-corpse" "$scn/trees/.herd-tabs"
assert "precommit · I6 the corpse reap is journaled" journaled "$scn" builder_corpse_reaped
assert "precommit · the respawn is journaled" journaled "$scn" builder_respawned
assert "precommit · I5 a RESPAWNED builder keeps its claim (the fresh agent owns the item)" test "$(claimed "$scn")" = yes
assert "precommit · I5 the 💀 notification says the claim is held, and why" grep -q 'held (respawning)' "$scn/notify.log"
# The neighbour is never collateral: same tab-registry file, adjacent slug prefix, live agent.
assert "precommit · a live neighbour agent survives the reap" test "$(agents_named "$scn" "$SLUG-neighbour")" = 1
assert "precommit · a live neighbour's tab survives the reap" test "$(tab_exists "$scn" tab-nb)" = yes

# ── stage: PRE-COMMIT, autorespawn OFF. Nothing will restart it ⇒ the claim goes back. ───────────
scn="$ART/s-abandoned"; SLUG=abandoned
fixture "$scn" "$SLUG" clean live
v="$(CLAIM_RELEASE=release two_ticks "$scn" "$SLUG")"
assert "abandoned · a dead builder nobody will restart crosses into DEAD" test "$v" = DEAD
assert "abandoned · I5 the claim is RELEASED — the item is re-pickable" test "$(claimed "$scn")" = no
assert "abandoned · I6 the release is journaled" journaled "$scn" claim_released
assert "abandoned · I5 the 💀 notification names the released claim" grep -q 'released — re-pickable' "$scn/notify.log"
assert "abandoned · autorespawn off ⇒ the corpse is left exactly as found (byte-inert)" test "$(agents_named "$scn" "$SLUG")" = 1

# ── stage: PRE-COMMIT, abandoned, but the tracker write CANNOT LAND (unreachable remote) ─────────
# For the file backend the tracker IS the remote's BACKLOG.md — it is what every other operator reads.
# A release whose push is rejected leaves the item wedged there, so reporting it released (and saying
# "re-pickable" on the 💀) is strictly worse than the wedge: the second seat still aborts on ALREADY,
# now without a warning. The recovery must fail LOUD, keep the claim, and strand no `Release:` commit
# for the next `pull --rebase` + push to carry onto whatever that seat has since landed on the line.
scn="$ART/s-pushfail"; SLUG=pushfail
fixture "$scn" "$SLUG" clean live
git -C "$scn/main" remote add origin "$scn/no-such-remote.git"
head0="$(git -C "$scn/main" rev-parse HEAD)"
v="$(CLAIM_RELEASE=release two_ticks "$scn" "$SLUG")"
assert "pushfail · a dead builder whose claim cannot be released still crosses into DEAD" test "$v" = DEAD
assert "pushfail · I5 the item stays claimed — the remote never saw the release" test "$(claimed "$scn")" = yes
refute "pushfail · I5/I6 an unlanded release is NOT journaled as claim_released" journaled "$scn" claim_released
assert "pushfail · I5 the 💀 notification says the claim is STILL HELD" grep -q 'still held' "$scn/notify.log"
refute "pushfail · I5 the 💀 notification never calls a wedged item re-pickable" grep -q 're-pickable' "$scn/notify.log"
assert "pushfail · no orphan 'Release:' commit is stranded on the branch" test "$(git -C "$scn/main" rev-parse HEAD)" = "$head0"
assert "pushfail · the main checkout is left clean, never half-applied" test -z "$(git -C "$scn/main" status --porcelain)"

# ── stage: MID-WORK (commits). Recovery must destroy nothing and must NOT hand the item away. ────
scn="$ART/s-commits"; SLUG=midwork
fixture "$scn" "$SLUG" commits live
v="$(DEAD_BUILDER_AUTORESPAWN=on CLAIM_RELEASE=release two_ticks "$scn" "$SLUG")"
assert "midwork · a builder killed after committing crosses into DEAD" test "$v" = DEAD
assert "midwork · I4 the worktree survives" test -d "$scn/trees/$SLUG"
assert "midwork · I4 the branch survives" git -C "$scn/main" show-ref --verify --quiet "refs/heads/feat/$SLUG"
assert "midwork · I4 the tab survives (no corpse reap on a tree with work)" test "$(tab_exists "$scn" tab-corpse)" = yes
assert "midwork · I4 no respawn ran over the committed work" test "$(agents_named "$scn" "$SLUG")" = 1
assert "midwork · I6 the escalation is journaled" journaled "$scn" builder_dead_has_work
assert "midwork · I5 the claim is HELD — releasing it would invite a duplicate build on unrecovered work" test "$(claimed "$scn")" = yes
assert "midwork · I5 the hold is stated out loud, not silent" grep -q 'HELD (worktree has work' "$scn/notify.log"

# ── stage: MID-WORK (uncommitted dirt). Same rails — dirt is work. ───────────────────────────────
scn="$ART/s-dirty"; SLUG=dirtywork
fixture "$scn" "$SLUG" dirty live
v="$(DEAD_BUILDER_AUTORESPAWN=on CLAIM_RELEASE=release two_ticks "$scn" "$SLUG")"
assert "dirtywork · a builder killed with uncommitted changes crosses into DEAD" test "$v" = DEAD
assert "dirtywork · I4 the uncommitted work survives verbatim" grep -q 'has not committed' "$scn/trees/$SLUG/file.txt"
assert "dirtywork · I5 the claim is held over unrecovered dirt" test "$(claimed "$scn")" = yes

# ── stage: DIED AGAIN, after spending its one respawn. Escalate; hand the item back. ─────────────
scn="$ART/s-again"; SLUG=diedagain
fixture "$scn" "$SLUG" clean live
printf '%s 900 respawned\n' "$SLUG" > "$scn/trees/.agent-watch-respawn"   # the budget is already spent
v="$(DEAD_BUILDER_AUTORESPAWN=on CLAIM_RELEASE=release two_ticks "$scn" "$SLUG")"
assert "diedagain · a second death crosses into DEAD" test "$v" = DEAD
assert "diedagain · I2 the at-most-once budget denies a second respawn (no loop)" test "$(agents_named "$scn" "$SLUG")" = 1
assert "diedagain · I6 the escalation is journaled" journaled "$scn" builder_dead_again
assert "diedagain · I5 nothing will restart it ⇒ the claim is released" test "$(claimed "$scn")" = no

# ── stage: LIMIT-PARKED, then killed. The stale limit target must never reach the fresh builder. ──
scn="$ART/s-limit"; SLUG=parked
fixture "$scn" "$SLUG" clean live
printf '%s 900 99999999999 scheduled\n' "$SLUG" > "$scn/trees/.agent-watch-limit"
printf '%s 900 cleared\n' "$SLUG" > "$scn/trees/.agent-watch-limit-sendkeys"
v="$(DEAD_BUILDER_AUTORESPAWN=on CLAIM_RELEASE=release two_ticks "$scn" "$SLUG")"
assert "parked · a builder killed while limit-parked crosses into DEAD" test "$v" = DEAD
assert "parked · the respawn succeeds over the corpse" test "$(agents_named "$scn" "$SLUG")" = 1
refute "parked · I3 the stale limit target is purged (no --continue is injected into the fresh builder)" ledger_has "$scn" "$SLUG" limit
refute "parked · I3 the stale sendkeys row is purged (the fresh builder's first park is handled cleanly)" ledger_has "$scn" "$SLUG" limit-sendkeys

# ── stage: LISTED BUT UNWAKEABLE (a herdr crash: the agent is listed, its process is dead) ───────
scn="$ART/s-unwakeable"; SLUG=unwakeable
fixture "$scn" "$SLUG" clean live
tick "$scn" "$SLUG" >/dev/null
v="$(SIM_ASTATUS=idle SIM_LIVENESS=dead DEAD_BUILDER_AUTORESPAWN=on CLAIM_RELEASE=release \
       tick "$scn" "$SLUG" | sed -n 's/^VERDICT //p')"
assert "unwakeable · a positive liveness=dead probe overrides the stale listing" test "$v" = DEAD
assert "unwakeable · I1/I2 the corpse is reaped and exactly one fresh agent holds the name" poll_state 30 0.1 agents_is "$scn" "$SLUG" 1
assert "unwakeable · I1 the corpse tab reaches its terminal reaped state (gone)" poll_state 30 0.1 corpse_tab_gone "$scn"
assert "unwakeable · I1 the name is freed BEFORE agent start (the agent_name_taken bug)" ordered "$scn" 'pane close pane-corpse' 'agent start'

# ══ PART 2 — the terminal reap closes every ledger the slug opened ════════════════════════════════
step reap "the slug's terminal reap leaves no immortal ledger row"
scn="$ART/s-reap"; SLUG=reaped
fixture "$scn" "$SLUG" clean live
printf '%s 900 notified\n'          "$SLUG" > "$scn/trees/.agent-watch-dead"
printf '%s 900 respawned\n'         "$SLUG" > "$scn/trees/.agent-watch-respawn"
printf '%s 900 99999999999 scheduled\n' "$SLUG" > "$scn/trees/.agent-watch-limit"
printf '%s 900 cleared\n'           "$SLUG" > "$scn/trees/.agent-watch-limit-sendkeys"
printf '%s-neighbour 900 notified\n' "$SLUG" >> "$scn/trees/.agent-watch-dead"
assert "reap · the fixture seeded all four slug-keyed ledgers" test -n "$(ledger_rows "$scn" "$SLUG")"
SIM_ENTRY=reap SIM_PR=77 SIM_SHA=deadbeef SIM_REASON=merged tick "$scn" "$SLUG" >/dev/null
assert "reap · I3 every slug-keyed ledger row is closed with the slug" test -z "$(ledger_rows "$scn" "$SLUG")"
assert "reap · I3 a prefix-sharing neighbour's row is untouched (the purge is row-exact)" grep -q "^$SLUG-neighbour " "$scn/trees/.agent-watch-dead"
assert "reap · I6 the ledger purge is journaled" journaled "$scn" slug_ledgers_purged
assert "reap · the worktree is gone" test ! -d "$scn/trees/$SLUG"
# Idempotence: reaping a converged slug again changes nothing and says nothing.
before="$(grep -c slug_ledgers_purged "$scn/journal.jsonl")"
SIM_ENTRY=reap SIM_PR=77 SIM_SHA=deadbeef SIM_REASON=merged tick "$scn" "$SLUG" >/dev/null
assert "reap · a converged slug is a fixed point — re-reaping is a silent no-op" test "$(grep -c slug_ledgers_purged "$scn/journal.jsonl")" = "$before"

# ══ PART 3 — RESTART: kill the reconcile mid-corpse-reap; the next process must converge ══════════
step restart "SIGKILL the recovery mid-corpse-reap — a fresh process converges to one live agent"
scn="$ART/s-crash"; SLUG=crashed
fixture "$scn" "$SLUG" clean live

# Tick 1: the doomed process. It closes the corpse's PANE and dies before closing its TAB — the exact
# half-reaped world a kill between two herdr calls leaves on disk. (Its exit status is irrelevant.)
SIM_ENTRY=corpse CRASH_AFTER=after-pane-close tick "$scn" "$SLUG" >/dev/null
assert "crash · the pane close landed (the corpse's agent row is gone)" test "$(agents_named "$scn" "$SLUG")" = 0
assert "crash · the tab close never happened (the crash window is real)" test "$(tab_exists "$scn" tab-corpse)" = yes
assert "crash · the registry row still stands" grep -q "^$SLUG tab-corpse" "$scn/trees/.herd-tabs"

# Tick 2: a brand-new process, zero inherited memory. This is the whole claim.
out="$(SIM_ENTRY=corpse tick "$scn" "$SLUG")"
assert "crash · the next process finishes the reap and reports the name FREE" test "$out" = "CORPSE free"
assert "crash · I1 the orphan tab is converged away" test "$(tab_exists "$scn" tab-corpse)" = no
refute "crash · I1 the registry row is converged away" grep -q "^$SLUG tab-corpse" "$scn/trees/.herd-tabs"

# Tick 3: the respawn now succeeds, exactly once, over a world with no corpse left to stack on.
out="$(SIM_ENTRY=respawn tick "$scn" "$SLUG")"
assert "crash · the respawn succeeds after the interrupted reap converged" test "$out" = "RESPAWN ok"
assert "crash · I2 exactly ONE agent holds the slug (never stacked on the corpse)" test "$(agents_named "$scn" "$SLUG")" = 1
assert "crash · I2 exactly ONE tab carries the slug label" test "$(tabs_labelled "$scn" "$SLUG")" = 1

# And the counterfactual that makes all of the above mean something: a respawn attempted WITHOUT the
# corpse ever being reaped dies on agent_name_taken, exactly as it did before HERD-162.
scn="$ART/s-counterfactual"; SLUG=nocorpsereap
fixture "$scn" "$SLUG" clean live
refute "counterfactual · a bare 'agent start' over a live corpse DOES fail agent_name_taken (the sim models the real constraint)" \
  env PATH="$BIN:$PATH" WORLD="$scn/world.json" ACTIONS="$scn/actions.log" herdr agent start "$SLUG" --tab tab-corpse

# ── scorecard ────────────────────────────────────────────────────────────────────────────────────
step scorecard "results"
info "artifacts: $ART"
CARD="$CARD" ART="$ART" PASS="$PASS" FAIL="$FAIL" python3 -c '
import json, os
rows = [l.split("\t", 1) for l in os.environ["CARD"].splitlines() if "\t" in l]
p, f = int(os.environ["PASS"]), int(os.environ["FAIL"])
card = {"scenario": "builder-chaos", "artifacts_dir": os.environ["ART"],
        "result": "pass" if f == 0 else "fail", "passed": p, "failed": f, "skipped": 0,
        "checkpoints": [{"name": n, "status": s} for s, n in rows]}
json.dump(card, open(os.path.join(os.environ["ART"], "scorecard.json"), "w"), indent=2)
' 2>/dev/null || true
printf '  %s%s passed%s · %s%s failed%s\n' "$c_grn" "$PASS" "$c_rst" \
  "$([ "$FAIL" -gt 0 ] && printf '%s' "$c_red" || printf '%s' "$c_dim")" "$FAIL" "$c_rst"
[ "$FAIL" -eq 0 ] && { echo "ALL PASS ($PASS checkpoints)"; exit 0; }
exit 1
