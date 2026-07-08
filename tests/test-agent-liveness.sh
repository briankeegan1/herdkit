#!/usr/bin/env bash
# test-agent-liveness.sh — hermetic tests for the HERD-114 dead-agent-eyes probe + its consumers.
#
# The 2026-07-08 incident: a herdr server stop KILLED both in-flight builders' claude processes while
# their tabs/panes/worktrees persisted; `herd status` still read 'done · PR #220/#221' and a review
# bounce would have typed a re-task into a dead pane and failed the 15s wake. This suite drives the
# SHIPPED helpers against a file-backed herdr stub whose pane process-info can be flipped from a live
# `claude` foreground to a BARE shell (the killed-process signature), and asserts:
#   (A) herd_driver_agent_liveness — herdr-claude (claude→alive, bare→dead, delisted-but-labelled-pane
#       →dead via the label fallback, no agent + no labelled pane→MISSING, unreadable pane→unknown) AND
#       headless (live pid→alive, dead pid→dead, no record→unknown).
#   (B) _status_classify_builder — liveness='dead' ⇒ 'agentdead' (even with an open PR), never over a
#       WORKING agent, and byte-identical (unchanged bucket) when liveness is empty/unknown/alive.
#   (C) _handle_block_verdict — a review bounce PREFLIGHTS liveness: a dead agent escalates to
#       'needs you · agent dead' WITHOUT any `herdr pane run` wake, journals refix_escalated_dead once;
#       a LIVE agent falls straight through to the normal refix (a pane run IS attempted).
#   (D) _reconcile_dead_builder — a listed-but-dead agent (stale status, liveness='dead') crosses into
#       DEAD past grace exactly like a vanished one.
#   (E) layout_stale_agent_tabs — flags a single-pane drainer/reviewer tab left BARE by a crash; never
#       a live (claude) agent tab, a multi-pane control room, or a non-engine label.
#
# Sources agent-watch.sh + driver.sh + layout-reconcile.sh in lib mode. NETWORK-FREE, no real claude.
# Run:  bash tests/test-agent-liveness.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../scripts/herd/agent-watch.sh"
DRIVER="$HERE/../scripts/herd/driver.sh"
LAYOUT="$HERE/../scripts/herd/layout-reconcile.sh"
STATUS="$HERE/../scripts/herd/status.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

command -v python3 >/dev/null 2>&1 || fail "python3 required"

# ── file-backed herdr stub ────────────────────────────────────────────────────
# State under $S:  panes/<id>/cmd (foreground cmdline; empty ⇒ bare) · panes/<id>/tab · tabs/<id>
# (label) · agents.tsv ("name<TAB>pane_id<TAB>status" lines). A missing pane dir ⇒ gone process-info.
S="$T/herdr"; mkdir -p "$S/panes" "$S/tabs"; : > "$S/agents.tsv"
BIN="$T/bin"; mkdir -p "$BIN"
cat > "$BIN/gh"  <<'E'
#!/usr/bin/env bash
exit 0
E
cat > "$BIN/git" <<'E'
#!/usr/bin/env bash
exit 0
E
chmod +x "$BIN/gh" "$BIN/git"
cat > "$BIN/herdr" <<'STUB'
#!/usr/bin/env bash
S="${HERDR_STATE:?}"
case "${1:-} ${2:-}" in
  "agent list")
    python3 - "$S" <<'PY'
import sys,os,json
S=sys.argv[1]; f=os.path.join(S,"agents.tsv"); ags=[]
if os.path.exists(f):
    for ln in open(f):
        ln=ln.rstrip("\n")
        if not ln: continue
        p=ln.split("\t")
        ags.append({"name":p[0],"pane_id":(p[1] if len(p)>1 else ""),"agent_status":(p[2] if len(p)>2 else "")})
print(json.dumps({"result":{"agents":ags}}))
PY
    ;;
  "pane process-info")
    p="${4:-}"
    if [ ! -d "$S/panes/$p" ]; then printf '{"result":{}}\n'; exit 0; fi
    cmd=""; [ -f "$S/panes/$p/cmd" ] && cmd="$(cat "$S/panes/$p/cmd")"
    if [ -f "$S/panes/$p/root" ] && [ -n "$cmd" ]; then
      # claude launched AS the pane ROOT (no wrapping shell): shell_pid == the foreground process pid.
      printf '{"result":{"process_info":{"shell_pid":5151,"foreground_processes":[{"pid":5151,"cmdline":"%s"}]}}}\n' "$cmd"
    elif [ -n "$cmd" ]; then
      printf '{"result":{"process_info":{"shell_pid":4242,"foreground_processes":[{"pid":5151,"cmdline":"%s"}]}}}\n' "$cmd"
    else
      printf '{"result":{"process_info":{"shell_pid":4242,"foreground_processes":[]}}}\n'
    fi ;;
  "pane list")
    python3 - "$S" <<'PY'
import sys,os,json
S=sys.argv[1]; d=os.path.join(S,"panes"); panes=[]
if os.path.isdir(d):
    for p in sorted(os.listdir(d)):
        tf=os.path.join(d,p,"tab"); lf=os.path.join(d,p,"label")
        panes.append({"pane_id":p,
                      "tab_id":(open(tf).read().strip() if os.path.exists(tf) else ""),
                      "label":(open(lf).read().strip() if os.path.exists(lf) else "")})
print(json.dumps({"result":{"panes":panes}}))
PY
    ;;
  "tab list")
    python3 - "$S" <<'PY'
import sys,os,json
S=sys.argv[1]; d=os.path.join(S,"tabs")
tabs=[{"tab_id":t,"label":open(os.path.join(d,t)).read().strip()} for t in sorted(os.listdir(d))]
print(json.dumps({"result":{"tabs":tabs}}))
PY
    ;;
  "pane run")
    [ -n "${STUB_PANE_RUN_CALLS:-}" ] && printf '%s\n' "$3" >> "$STUB_PANE_RUN_CALLS"
    [ "${STUB_WAKE_ON_RUN:-0}" = "1" ] && [ -n "${STUB_AGENTS_TSV:-}" ] || true
    ;;
  "notification show") : ;;
  *) printf '{"result":{}}\n' ;;
esac
exit 0
STUB
chmod +x "$BIN/herdr"
export PATH="$BIN:$PATH"
export HERDR_STATE="$S"

# helpers to mutate stub state
set_agent()  { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$S/agents.tsv"; }   # name pane status
reset_agents(){ : > "$S/agents.tsv"; }
mk_pane()    { mkdir -p "$S/panes/$1"; printf '%s' "${3:-}" > "$S/panes/$1/tab"; printf '%s' "${2:-}" > "$S/panes/$1/cmd"; [ -n "${4:-}" ] && printf '%s' "$4" > "$S/panes/$1/label" || true; }  # id cmd tab [label]
mk_pane_root(){ mk_pane "$1" "$2" "$3"; : > "$S/panes/$1/root"; }  # id cmd tab — claude launched AS the pane root (shell_pid == fg pid)
mk_tab()     { printf '%s' "$2" > "$S/tabs/$1"; }   # id label

# ── source the libs in lib mode ───────────────────────────────────────────────
export AGENT_WATCH_LIB=1
export WORKTREES_DIR="$T/trees"; mkdir -p "$T/trees"
export HERD_CONFIG_FILE="$T/no-such-config"
export JOURNAL_FILE="$T/journal.jsonl"; : > "$JOURNAL_FILE"
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh failed"
# shellcheck source=/dev/null
. "$LAYOUT" || fail "sourcing layout-reconcile.sh failed"
# shellcheck source=/dev/null
. "$STATUS" || fail "sourcing status.sh failed"
render() { :; }

# ════════════════════════════════════════════════════════════════════════════
# (A) herd_driver_agent_liveness — the probe itself
# ════════════════════════════════════════════════════════════════════════════
# herdr-claude: a live claude foreground ⇒ alive
reset_agents; rm -rf "$S/panes"; mkdir -p "$S/panes"
mk_pane pane-live "claude --model x --dangerously-skip-permissions" tab-b
set_agent bob pane-live done
[ "$(herd_driver_agent_liveness bob)" = "alive" ] || fail "A1: claude foreground ⇒ alive"
ok
# herdr-claude: a bare shell (process killed) ⇒ dead
mk_pane pane-live "" tab-b            # flip the same pane to bare
[ "$(herd_driver_agent_liveness bob)" = "dead" ] || fail "A2: bare pane (claude gone) ⇒ dead"
ok
# herdr-claude: claude launched AS the pane ROOT (shell_pid == the claude pid — the lane runs claude
# with NO wrapping shell). The pane-shell exclusion must NOT drop this entry: it is POSITIVE alive
# evidence, not a bare shell. Regression guard for the fabricated-death false-positive (PR #260 review).
reset_agents; rm -rf "$S/panes"; mkdir -p "$S/panes"
mk_pane_root pane-croot "claude --model claude-opus-4-8 --dangerously-skip-permissions" tab-cr
set_agent crootbob pane-croot idle
[ "$(herd_driver_agent_liveness crootbob)" = "alive" ] || fail "A2b: claude-as-pane-root (shell_pid==claude pid) ⇒ alive (never a fabricated death)"
ok
# herdr-claude: a gone pane (no process-info) ⇒ unknown (fail-soft, never a fabricated death)
reset_agents; set_agent gonezo pane-absent done
[ "$(herd_driver_agent_liveness gonezo)" = "unknown" ] || fail "A3: gone pane ⇒ unknown"
ok
# herdr-claude: no agent record AND no pane carries the slug label ⇒ MISSING — herdr answered, so the
# agent pane is positively ABSENT (distinct from probe-blind 'unknown'). HERD-135.
reset_agents; rm -rf "$S/panes"; mkdir -p "$S/panes"
[ "$(herd_driver_agent_liveness nobody)" = "missing" ] || fail "A4: no agent + no labelled pane ⇒ missing"
ok
# herdr-claude: agent DELISTED from the roster but its pane persists LABELLED '<slug>' (bare shell) ⇒
# dead via the label fallback (found even though the roster dropped it), never mis-read as missing.
reset_agents; rm -rf "$S/panes"; mkdir -p "$S/panes"
mk_pane pane-ghost "" tab-g ghost      # bare pane (claude gone), labelled 'ghost', no agent record
[ "$(herd_driver_agent_liveness ghost)" = "dead" ] || fail "A4b: delisted agent, labelled pane present (bare) ⇒ dead"
ok
# _agent_liveness wrapper mirrors the driver seam
mk_pane pane-live "claude foo" tab-b; reset_agents; set_agent bob pane-live done
[ "$(_agent_liveness bob)" = "alive" ] || fail "A5: _agent_liveness wrapper ⇒ alive"
ok

# headless: a LIVE pid ⇒ alive, a DEAD pid ⇒ dead, no record ⇒ unknown
( export HERD_DRIVER=headless
  adir="$WORKTREES_DIR/.herd/agents"
  mkdir -p "$adir/hl-live" "$adir/hl-dead"
  echo $$ > "$adir/hl-live/pid"          # this subshell's own pid is alive
  echo 2147480000 > "$adir/hl-dead/pid"  # an implausibly-high, not-running pid
  [ "$(herd_driver_agent_liveness hl-live)" = "alive" ]  || { echo "A6a FAIL"; exit 1; }
  [ "$(herd_driver_agent_liveness hl-dead)" = "dead" ]   || { echo "A6b FAIL"; exit 1; }
  [ "$(herd_driver_agent_liveness hl-none)" = "unknown" ]|| { echo "A6c FAIL"; exit 1; }
) || fail "A6: headless pid liveness"
ok

# ════════════════════════════════════════════════════════════════════════════
# (B) _status_classify_builder — the 'agentdead' bucket
# ════════════════════════════════════════════════════════════════════════════
# has_agent astatus has_pr commits [liveness]
[ "$(_status_classify_builder 1 done 1 0 dead)" = "agentdead" ] || fail "B1: dead agent WITH a PR ⇒ agentdead"
ok
[ "$(_status_classify_builder 1 idle 0 0 dead)" = "agentdead" ] || fail "B2: dead idle agent ⇒ agentdead"
ok
[ "$(_status_classify_builder 1 working 0 0 dead)" = "building" ] || fail "B3: a WORKING agent is never overridden to dead (probe race)"
ok
# byte-identical when liveness is empty/unknown/alive (prior buckets preserved)
[ "$(_status_classify_builder 1 done 1 0)" = "done" ]        || fail "B4: no liveness ⇒ done (unchanged)"
[ "$(_status_classify_builder 1 done 1 0 unknown)" = "done" ]|| fail "B5: unknown liveness ⇒ done (unchanged)"
[ "$(_status_classify_builder 1 done 1 0 alive)" = "done" ]  || fail "B6: alive liveness ⇒ done (unchanged)"
[ "$(_status_classify_builder 1 idle 0 0 alive)" = "idle" ]  || fail "B7: alive idle ⇒ idle (unchanged)"
ok

# ════════════════════════════════════════════════════════════════════════════
# (C) _handle_block_verdict — refix wake PREFLIGHT
# ════════════════════════════════════════════════════════════════════════════
CALLS="$T/pane-run.calls"
export STUB_PANE_RUN_CALLS="$CALLS"
REVIEW_AUTOFIX=true; DRYRUN=""; REFIX_MAX_ROUNDS=3

# C1: a DEAD agent → escalate 'agent dead', NO pane run, journal refix_escalated_dead once, no round burned.
: > "$CALLS"; : > "$JOURNAL_FILE"; rm -f "$REFIX_STATE"
rm -rf "$S/panes"; mkdir -p "$S/panes"; reset_agents
mk_pane pane-dead "" tab-d                 # bare pane ⇒ dead
set_agent deadbob pane-dead done
DISPLAY=()
_handle_block_verdict "220" "deadbob" "sha-220" "0"
d="${DISPLAY[0]:-}"
printf '%s\n' "$d" | grep -q "agent dead" || fail "C1: a dead agent must escalate to 'agent dead' (got: $d)"
ok
[ "$(wc -l < "$CALLS")" -eq 0 ] || fail "C1: a dead agent must NOT be sent a wake (herdr pane run calls=$(wc -l < "$CALLS"))"
ok
grep -q 'refix_escalated_dead' "$JOURNAL_FILE" || fail "C1: must journal refix_escalated_dead"
ok
refix_attempted "220" "sha-220" && fail "C1: a dead-agent escalation must NOT burn a refix round"
ok
# idempotent: a second tick re-sets the row but does NOT re-journal / re-notify (deduped by marker)
before="$(grep -c 'refix_escalated_dead' "$JOURNAL_FILE")"
DISPLAY=(); _handle_block_verdict "220" "deadbob" "sha-220" "0"
after="$(grep -c 'refix_escalated_dead' "$JOURNAL_FILE")"
[ "$before" = "$after" ] || fail "C1: the dead escalation must journal only once per (pr,sha) ($before→$after)"
ok

# C1b: a MISSING agent (no roster entry, no labelled pane) → escalate 'agent missing', NO pane run,
# journal refix_escalated_missing once, no round burned (HERD-135). Same "never wake nobody" guarantee
# as the dead path, but a distinct cause: the pane vanished entirely rather than a killed process.
: > "$CALLS"; : > "$JOURNAL_FILE"; rm -f "$REFIX_STATE"
rm -rf "$S/panes"; mkdir -p "$S/panes"; reset_agents
DISPLAY=()
_handle_block_verdict "222" "ghostbob" "sha-222" "0"
d="${DISPLAY[0]:-}"
printf '%s\n' "$d" | grep -q "agent missing" || fail "C1b: a missing agent must escalate to 'agent missing' (got: $d)"
ok
[ "$(wc -l < "$CALLS")" -eq 0 ] || fail "C1b: a missing agent must NOT be sent a wake (herdr pane run calls=$(wc -l < "$CALLS"))"
ok
grep -q 'refix_escalated_missing' "$JOURNAL_FILE" || fail "C1b: must journal refix_escalated_missing"
ok
refix_attempted "222" "sha-222" && fail "C1b: a missing-agent escalation must NOT burn a refix round"
ok

# C2: a LIVE agent falls through to the NORMAL refix (a pane run IS attempted, row shows 'refixing').
: > "$CALLS"; : > "$JOURNAL_FILE"; rm -f "$REFIX_STATE"
rm -rf "$S/panes"; mkdir -p "$S/panes"; reset_agents
mk_pane pane-alive "claude working" tab-a  # live claude ⇒ alive
set_agent livebob pane-alive done
export HERD_REFIX_WAIT_TIMEOUT=1
# mock the clock/sleep so the backed-off wait poll terminates instantly (mirrors test-refix-wake)
CLOCK="$T/clk"; echo 1000 > "$CLOCK"
date() { if [ "${1:-}" = "+%s" ]; then n=$(( $(cat "$CLOCK") + 1 )); echo "$n" > "$CLOCK"; printf '%s\n' "$n"; else command date "$@"; fi; }
sleep() { :; }
DISPLAY=()
_handle_block_verdict "221" "livebob" "sha-221" "0"
d="${DISPLAY[0]:-}"
printf '%s\n' "$d" | grep -q "agent dead" && fail "C2: a LIVE agent must NOT escalate to 'agent dead' (got: $d)"
ok
[ "$(wc -l < "$CALLS")" -ge 1 ] || fail "C2: a live agent must be sent the normal wake (pane run) — calls=$(wc -l < "$CALLS")"
ok
grep -q 'refix_escalated_dead' "$JOURNAL_FILE" && fail "C2: a live agent must not journal refix_escalated_dead"
ok
unset -f date sleep

# ════════════════════════════════════════════════════════════════════════════
# (D) _reconcile_dead_builder — a listed-but-dead agent crosses into DEAD
# ════════════════════════════════════════════════════════════════════════════
DEAD_STATE="$T/.dead"; : > "$DEAD_STATE"
export HERD_TRANSCRIPT_ROOT="$T/no-transcripts"
NOW=2000000000; GRACE="$(_dead_grace_secs)"
# a stale-but-listed 'idle' agent whose PROCESS is dead: PENDING within grace, DEAD past it
v="$(HERD_NOW_EPOCH="$NOW" _reconcile_dead_builder listed-dead "$T/wt-ld" "idle" "dead")"
[ "$v" = "PENDING" ] || fail "D1: first sighting of a listed-but-dead agent ⇒ PENDING (got $v)"
ok
v="$(HERD_NOW_EPOCH="$((NOW+GRACE+1))" _reconcile_dead_builder listed-dead "$T/wt-ld" "idle" "dead")"
[ "$v" = "DEAD" ] || fail "D2: past grace ⇒ DEAD even though the agent is still listed (got $v)"
ok
# a listed agent with liveness alive/unknown stays ALIVE (unchanged behavior)
: > "$DEAD_STATE"
v="$(HERD_NOW_EPOCH="$NOW" _reconcile_dead_builder listed-live "$T/wt-ll" "idle" "alive")"
[ "$v" = "ALIVE" ] || fail "D3: a listed live agent ⇒ ALIVE (got $v)"
ok

# ════════════════════════════════════════════════════════════════════════════
# (E) layout_stale_agent_tabs — the eyes sweep flag
# ════════════════════════════════════════════════════════════════════════════
rm -rf "$S/panes" "$S/tabs"; mkdir -p "$S/panes" "$S/tabs"
WS="ws1"
# a crashed reviewer tab: single pane, bare (claude gone), reviewer label ⇒ FLAGGED
mk_tab tab-rv "review·featx";     mk_pane p-rv "" tab-rv
# a crashed scribe drainer: single bare pane ⇒ FLAGGED
mk_tab tab-sc "scribe-proj";      mk_pane p-sc "" tab-sc
# a LIVE reviewer (claude foreground) ⇒ NOT flagged
mk_tab tab-lv "review·featy";     mk_pane p-lv "claude review" tab-lv
# a non-engine (feature builder) bare tab ⇒ NOT flagged
mk_tab tab-ft "my-feature";       mk_pane p-ft "" tab-ft
# a multi-pane control room (coordinator) with a bare pane ⇒ NOT flagged (not single-pane, not labelled)
mk_tab tab-co "coordinator-proj"; mk_pane p-co1 "" tab-co; mk_pane p-co2 "claude coord" tab-co
out="$(layout_stale_agent_tabs "$WS")"
printf '%s\n' "$out" | grep -q "review·featx" || fail "E1: a crashed single-pane reviewer tab must be flagged (out: $out)"
ok
printf '%s\n' "$out" | grep -q "scribe-proj"  || fail "E2: a crashed single-pane scribe drainer must be flagged (out: $out)"
ok
printf '%s\n' "$out" | grep -q "review·featy" && fail "E3: a LIVE reviewer tab must NOT be flagged (out: $out)"
ok
printf '%s\n' "$out" | grep -q "my-feature"   && fail "E4: a non-engine feature tab must NOT be flagged (out: $out)"
ok
printf '%s\n' "$out" | grep -q "coordinator-proj" && fail "E5: a multi-pane control room must NOT be flagged (out: $out)"
ok
# every flagged row carries a bare|gone role
printf '%s\n' "$out" | grep "review·featx" | grep -qE '	(bare|gone)$' || fail "E6: a flagged row must record the dead role"
ok

echo "ALL PASS ($pass checks)"
