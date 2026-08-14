#!/usr/bin/env bash
# test-watcher-exempt.sh — hermetic proof of the ONE shared watcher-identity check (HERD-266).
#
# `herd status` used to alarm '⚠ 2 watcher mains alive' on a perfectly healthy control room. Two root
# causes, both proven here against a SYNTHETIC process table planted through the $HERD_SWEEP_PS_CMD
# seam (the same seam tests/test-sweep.sh uses), so not one real process is consulted:
#
#   (1) TRANSIENT TICK FORKS — the watcher's tick loop forks constantly and every fork inherits the
#       herd-watch-<ws> argv0. bin/herd's _list_project_watchers exempted only marker-owned pids, so a
#       sub-second fork alive at sample time counted as a second "watcher main" (~20 observed live,
#       all children of the canonical watcher). sweep.sh's sweep_stray_watchers ALREADY exempted a
#       fork whose ppid is the canonical watcher. Both seats now call watcher_list_mains — one check,
#       one answer — for the exemptions that are PROVABLE. sweep keeps its extra gate-child HEURISTIC
#       local to its detection-only surface; see (e) and (g) for why hoisting it would be a safety bug.
#   (2) SELF-RESTART HANDOFF — a WATCHER_SELF_RESTART exec briefly shows more than one tagged main.
#       The outgoing image records a TTL-bounded handoff marker; the alarm stays silent through it.
#
# And the property neither fix may break: a GENUINE ORPHAN DUPLICATE — parent dead, no gate child, no
# marker, no handoff — must STILL be listed AND still alarm. A duplicate races the shared .git object
# store; silencing one would be a far worse bug than the false alarm this fixes.
#
# Asserts:
#   (a) canonical + transient child fork            → exactly 1 main listed, no alarm
#   (b) genuine orphan duplicate                    → listed, AND the alarm verifies as real
#   (c) self-restart handoff (fresh marker)         → no alarm; a STALE marker alarms again
#   (d) a marker-owned gate worker                  → exempt from the listing (HERD-185/217/237/245)
#   (e) sweep.sh's DETECTION-only gate-child guard spares a reparented fork that the LISTING keeps
#   (f) the alarm's persistence re-sample: a main that vanishes between samples never alarms
#   (h) HERD-524 (#636): a DECOY whose command line merely CONTAINS the watcher script path but which
#       lacks the argv0 tag is NEVER counted; the real tagged pid still is
#   (i) HERD-524 (#636): a ROTATING transient — a DIFFERENT untracked tagged fork alive at every sample —
#       never alarms. Every sample sees "2 mains", but no single pid survives them all
#   (j) HERD-524 (#636): a candidate that dies between the last scan and the render drops out silently
#   (k) HERD-524: watcher_legacy_cmd — the shared "is this command line EXECUTING agent-watch.sh?"
#       predicate the untagged-legacy KILL leg must pass a candidate through
#   (l) HERD-743 (GH #812): a YOUNG non-lock-holder (a losing HERD-209/252 singleton spawn still working
#       through its own refusal) that survives the base persistence window but dies before the lock
#       cross-check's settle window elapses → no alarm, even though it outlived the base ~0.6s window
#   (m) HERD-743: the SAME young-non-lock-holder duplicate still alarms once it AGES past the settle
#       window (a genuine duplicate that merely isn't the lock holder is never permanently silenced), and
#       an UNREADABLE/absent lockfile skips the cross-check entirely — today's persistence-only behavior
#   (g) THE SAFETY RAIL (PR #387 review): a lock-absent STRAY that has dispatched a gate worker is
#       STILL listed. watcher_list_mains feeds _stop_project_watcher's SIGTERM loop, not just the
#       status count, and the gate-child guard cannot tell such a stray from a reparented fork — on
#       macOS (no setsid) a review worker is a DIRECT CHILD of the watcher main that dispatched it,
#       and the inflight marker records the WORKER's pid, not the dispatcher's. Exempting it would
#       make _stop_project_watcher report "no running watcher found", drop the lockfile, and let the
#       caller spawn a second main on top of the survivor — the exact emergency this code prevents.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
PASS=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok()   { PASS=$(( PASS + 1 )); }

T="$(mktemp -d)"
cleanup() { [ -n "${CANON:-}" ] && kill "$CANON" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT

TREESDIR="$T/trees"; mkdir -p "$TREESDIR"
export WORKTREES_DIR="$TREESDIR"
export HERD_WATCH_ARGV0="herd-watch-wxws"
# The canonical lock path herd-config.sh derives from WORKSPACE_NAME, so the sweep.sh seat in (e) —
# which re-loads the config and recomputes it — reads the very same lockfile this test writes.
export HERD_WATCHER_LOCK="$TREESDIR/.watcher-wxws.pid"

# shellcheck source=/dev/null
. "$REPO/scripts/herd/watcher-exempt.sh"
# shellcheck source=/dev/null
. "$REPO/scripts/herd/status.sh"

for fn in watcher_list_mains watcher_pid_exempt watcher_handoff_active watcher_legacy_cmd \
          _status_dup_verified _status_pid_alive _status_watcher_live_pids _status_pid_intersect; do
  declare -f "$fn" >/dev/null 2>&1 || fail "(0) $fn not defined after sourcing"
done
ok; echo "PASS (0) the shared check + the status alarm helpers load"

# The CANONICAL watcher must be a genuinely LIVE pid: watcher_canonical_pid kill -0's the lockfile.
sleep 60 & CANON=$!
disown 2>/dev/null || true
printf '%s\n' "$CANON" > "$HERD_WATCHER_LOCK"

FORK=800002      # a transient tick fork: ppid == canonical  → exempt from the listing (child guard)
GATEFORK=800003  # reparented to init, still parenting a gate worker → LISTED (only sweep spares it)
HCPID=800004     # GATEFORK's live healthcheck worker (untagged)
ORPHAN=800006    # a GENUINE orphan duplicate: parent dead, no gate child, no marker → LISTED

# A live inflight marker owns MARKED. watcher_marker_pids falls back to `kill -0` when agent-watch.sh's
# richer _marker_live is not in scope — so the pid it names must be alive. Reuse the canonical sleep's
# liveness by pointing the marker at a second real process.
sleep 60 & MARKED_REAL=$!
disown 2>/dev/null || true
printf '%s\n' "$MARKED_REAL" > "$TREESDIR/.health-inflight-main-abc123"

_plant_table() {   # $1 = destination script; writes the fixture table
  cat > "$1" <<EOF
#!/usr/bin/env bash
# pid ppid pgid command   — argv0 (the command's first token) is what tags a watcher.
printf '%s 1 %s herd-watch-wxws bash agent-watch.sh --watch\n'  "$CANON"       "$CANON"
printf '%s %s %s herd-watch-wxws bash agent-watch.sh\n'         "$FORK"        "$CANON"    "$CANON"
printf '%s 1 %s herd-watch-wxws bash agent-watch.sh\n'          "$GATEFORK"    "$GATEFORK"
printf '%s %s %s bash scripts/herd/healthcheck.sh /w/tree\n'    "$HCPID"       "$GATEFORK" "$GATEFORK"
printf '%s 1 %s herd-watch-wxws bash agent-watch.sh\n'          "$MARKED_REAL" "$MARKED_REAL"
printf '%s 1 %s herd-watch-wxws bash agent-watch.sh\n'          "$ORPHAN"      "$ORPHAN"
printf '900001 1 900001 herd-watch-otherws bash agent-watch.sh\n'
# HERD-524 (#636) DECOYS — command lines that CONTAIN the watcher script path but carry NO argv0 tag:
# a coordinator's own 'bash -c' wrapper (the report's own example) and a tail on the watcher log.
printf '900010 1 900010 bash -c herd status; pgrep -af /w/scripts/herd/agent-watch.sh\n'
printf '900011 1 900011 tail -f /w/trees/agent-watch.sh.log\n'
EOF
  chmod +x "$1"
}
_plant_table "$T/ps-all"
export HERD_SWEEP_PS_CMD="$T/ps-all"

MAINS="$(watcher_list_mains)"

# ── (a) canonical + transient child fork ────────────────────────────────────────────────────────
grep -qx "$CANON" <<< "$MAINS" || fail "(a) the canonical watcher was not listed: '$MAINS'"
grep -qx "$FORK" <<< "$MAINS" \
  && fail "(a) a transient tick fork (ppid == canonical) was counted as a watcher main — the false alarm"
ok; echo "PASS (a) a transient tick fork is exempt; the canonical watcher is listed"

# ── (d) the marker-owned exemption (HERD-185 / HERD-217 / HERD-237 / HERD-245) ──────────────────
grep -qx "$MARKED_REAL" <<< "$MAINS" \
  && fail "(d) a LIVE inflight-marker worker was listed as a duplicate watcher — the kill path would sever it"
grep -qx "$HCPID" <<< "$MAINS" && fail "(d) an untagged healthcheck worker was mistaken for a watcher"
grep -qx 900001 <<< "$MAINS" && fail "(d) ANOTHER workspace's tagged watcher was listed (issue #60)"
ok; echo "PASS (d) a marker-owned gate worker is exempt; a foreign workspace is never listed"

# ── (g) THE SAFETY RAIL: a gate-running stray is NEVER exempt from the listing ──────────────────
# GATEFORK parents a live healthcheck. sweep.sh's detection surface spares it (assertion (e)); the
# LISTING must not, because that same list is what _stop_project_watcher SIGTERMs.
grep -qx "$GATEFORK" <<< "$MAINS" \
  || fail "(g) a tagged main that had dispatched a gate worker was EXEMPTED from the kill list — \
'herd reload' would report 'no running watcher found', drop the lock, and spawn a second main on top of it"
ok; echo "PASS (g) a gate-running stray stays on the kill list (the duplicate safety rail holds)"

# ── (b) a genuine orphan duplicate is STILL listed ──────────────────────────────────────────────
grep -qx "$ORPHAN" <<< "$MAINS" \
  || fail "(b) a GENUINE orphan duplicate (parent dead, no gate child, no marker) was silenced: '$MAINS'"
[ "$(printf '%s\n' "$MAINS" | grep -c .)" -eq 3 ] \
  || fail "(b) expected exactly 3 mains (canonical + gate-running stray + orphan), got: '$(printf '%s' "$MAINS" | tr '\n' ' ')'"
# … and the status alarm VERIFIES it as real (every re-sample still sees them), reporting the pids
# that SURVIVED every sample rather than the first sample's.
SURV="$(HERD_STATUS_DUP_SAMPLES=3 HERD_STATUS_DUP_SLEEP=0 _status_dup_verified "$MAINS")" \
  || fail "(b) a persistent genuine duplicate did not verify — the alarm would never fire"
[ "$(printf '%s\n' "$SURV" | grep -c .)" -gt 1 ] \
  || fail "(b) the verified alarm reported <=1 surviving main: '$SURV' (would print '⚠ 1 watcher mains alive')"
ok; echo "PASS (b) a genuine orphan duplicate is listed; the alarm verifies it and reports the survivors"

# ── (c) self-restart handoff suppresses the alarm; a STALE marker does not ──────────────────────
printf '%s\n%s\n' "$CANON" "$(date +%s)" > "$TREESDIR/.watcher-handoff"
watcher_handoff_active || fail "(c) a fresh handoff marker did not read as active"
HERD_STATUS_DUP_SAMPLES=3 HERD_STATUS_DUP_SLEEP=0 _status_dup_verified "$MAINS" >/dev/null \
  && fail "(c) the duplicate alarm fired DURING a self-restart generation handoff (false red)"
# The pids are still LISTED through the handoff — `herd reload` must still be able to stop them.
grep -qx "$ORPHAN" <<< "$(watcher_list_mains)" \
  || fail "(c) the handoff removed a pid from watcher_list_mains — the kill path would go blind"
# A crashed exec's marker ages out and stops masking a real duplicate.
printf '%s\n%s\n' "$CANON" "$(( $(date +%s) - WATCHER_HANDOFF_TTL - 5 ))" > "$TREESDIR/.watcher-handoff"
watcher_handoff_active && fail "(c) an EXPIRED handoff marker still read as active — a real duplicate could hide forever"
HERD_STATUS_DUP_SAMPLES=3 HERD_STATUS_DUP_SLEEP=0 _status_dup_verified "$MAINS" >/dev/null \
  || fail "(c) an expired handoff marker still suppressed the alarm"
# A corrupt marker (no epoch) must fail toward telling the truth.
printf '%s\n' "$CANON" > "$TREESDIR/.watcher-handoff"
watcher_handoff_active && fail "(c) a marker with no epoch read as active"
rm -f "$TREESDIR/.watcher-handoff"
watcher_handoff_active && fail "(c) an ABSENT handoff marker read as active"
ok; echo "PASS (c) a fresh handoff silences the alarm; stale/corrupt/absent markers never mask a duplicate"

# ── (f) the persistence re-sample: a main that vanishes between samples never alarms ────────────
# The FIRST `ps` sample shows the orphan; every later one does not (the fork exited). This is the
# transient-fork case that the exemptions cannot attribute — only TIME can tell it from a duplicate.
cat > "$T/ps-vanishing" <<EOF
#!/usr/bin/env bash
n=0; [ -f "$T/ps-calls" ] && n="\$(cat "$T/ps-calls")"
printf '%s\n' "\$(( n + 1 ))" > "$T/ps-calls"
printf '%s 1 %s herd-watch-wxws bash agent-watch.sh --watch\n' "$CANON" "$CANON"
[ "\$n" -eq 0 ] && printf '%s 1 %s herd-watch-wxws bash agent-watch.sh\n' "$ORPHAN" "$ORPHAN"
exit 0
EOF
chmod +x "$T/ps-vanishing"
FIRST="$(HERD_SWEEP_PS_CMD="$T/ps-vanishing" watcher_list_mains)"
[ "$(printf '%s\n' "$FIRST" | grep -c .)" -eq 2 ] || fail "(f) fixture: the first sample should see 2 mains"
HERD_SWEEP_PS_CMD="$T/ps-vanishing" HERD_STATUS_DUP_SAMPLES=3 HERD_STATUS_DUP_SLEEP=0 \
  _status_dup_verified "$FIRST" >/dev/null \
  && fail "(f) a main that vanished after the first sample still alarmed — the console cries wolf"
ok; echo "PASS (f) the alarm re-samples: a vanishing transient main never reds the console"

# ── (h) HERD-524 (#636): a script-path DECOY is never counted; the tagged pid still is ───────────
# The report: 'pgrep -af herd-watch|agent-watch' matches a coordinator's OWN 'bash -c' wrapper, because
# the wrapper's command line CONTAINS the path. Only the argv0 tag distinguishes a watcher, and the
# count must key on nothing else — the warning it feeds tells a human to kill what it names.
grep -qx 900010 <<< "$MAINS" \
  && fail "(h) a 'bash -c' wrapper whose command line CONTAINS the watcher script path was counted as a watcher main"
grep -qx 900011 <<< "$MAINS" \
  && fail "(h) a 'tail -f' on the watcher log was counted as a watcher main (script-path match, not argv0)"
grep -qx "$CANON" <<< "$MAINS" || fail "(h) the real argv0-tagged watcher stopped being counted"
ok; echo "PASS (h) a script-path decoy is not a watcher main; the argv0-tagged pid is"

# ── (i) HERD-524 (#636): a ROTATING transient never alarms ──────────────────────────────────────
# THE REPORTED BUG. The tick loop forks CONTINUOUSLY, so "more than one main in every sample" is not
# evidence of a duplicate: emberglen-godot saw '2 watcher mains alive (pids 7512 781304)' and, ten
# minutes later, '(pids 7512 794193)' — a healthy control room with exactly one watcher (7512) and a
# DIFFERENT short-lived fork alive at each sample. Only pid IDENTITY across samples can tell the two
# apart, so the check intersects the samples instead of counting them.
cat > "$T/ps-rotating" <<EOF
#!/usr/bin/env bash
n=0; [ -f "$T/ps-rot-calls" ] && n="\$(cat "$T/ps-rot-calls")"
printf '%s\n' "\$(( n + 1 ))" > "$T/ps-rot-calls"
printf '%s 1 %s herd-watch-wxws bash agent-watch.sh --watch\n' "$CANON" "$CANON"
# a NEW untracked tagged fork every sample (ppid 1 ⇒ neither marker-owned nor a child of the lock)
printf '%s 1 %s herd-watch-wxws bash agent-watch.sh\n' "\$(( 781304 + n ))" "\$(( 781304 + n ))"
exit 0
EOF
chmod +x "$T/ps-rotating"
ROT="$(HERD_SWEEP_PS_CMD="$T/ps-rotating" watcher_list_mains)"
[ "$(printf '%s\n' "$ROT" | grep -c .)" -eq 2 ] || fail "(i) fixture: every sample should show 2 mains"
HERD_SWEEP_PS_CMD="$T/ps-rotating" HERD_STATUS_DUP_SAMPLES=3 HERD_STATUS_DUP_SLEEP=0 \
  _status_dup_verified "$ROT" >/dev/null \
  && fail "(i) a rotating transient fork alarmed — the #636 false red: every sample sees 2 mains, but \
no single pid survives them all, and the operator is told to kill a pid that is already gone"
ok; echo "PASS (i) a different transient fork at every sample never alarms (#636)"

# ── (j) HERD-524 (#636): a pid that dies between the last scan and the render drops out ─────────
# Even an intersected pid can exit during the final sample gap. The warning names pids an operator (or
# an autonomous coordinator) is told to kill, so each survivor is re-verified ALIVE immediately before
# it is printed; when that leaves ≤1 main there is no warning at all. Call budget: this test's own
# watcher_list_mains is table call 1, the two re-samples are 2 and 3, the liveness re-verify is 4.
_plant_dying() {   # $1 = destination, $2 = the call number from which ORPHAN is GONE (0 = never)
  cat > "$1" <<EOF
#!/usr/bin/env bash
n=0; [ -f "$T/ps-dying-calls" ] && n="\$(cat "$T/ps-dying-calls")"
n=\$(( n + 1 )); printf '%s\n' "\$n" > "$T/ps-dying-calls"
printf '%s 1 %s herd-watch-wxws bash agent-watch.sh --watch\n' "$CANON" "$CANON"
if [ "$2" -eq 0 ] || [ "\$n" -lt "$2" ]; then
  printf '%s 1 %s herd-watch-wxws bash agent-watch.sh\n' "$ORPHAN" "$ORPHAN"
fi
exit 0
EOF
  chmod +x "$1"
}
# CONTROL — the same fixture with a pid that never dies MUST still alarm (this rail may not go silent).
_plant_dying "$T/ps-dying" 0
: > "$T/ps-dying-calls"
LIVE="$(HERD_SWEEP_PS_CMD="$T/ps-dying" watcher_list_mains)"
SURV="$(HERD_SWEEP_PS_CMD="$T/ps-dying" HERD_STATUS_DUP_SAMPLES=3 HERD_STATUS_DUP_SLEEP=0 \
  _status_dup_verified "$LIVE")" \
  || fail "(j) control: a persistent duplicate stopped alarming — the rail went silent"
grep -qx "$ORPHAN" <<< "$SURV" || fail "(j) control: the surviving duplicate was not reported: '$SURV'"
# … and the same duplicate, gone by the render (call 4), alarms NOT AT ALL.
_plant_dying "$T/ps-dying" 4
printf '0\n' > "$T/ps-dying-calls"
DYING="$(HERD_SWEEP_PS_CMD="$T/ps-dying" watcher_list_mains)"
[ "$(printf '%s\n' "$DYING" | grep -c .)" -eq 2 ] || fail "(j) fixture: the first scan should see 2 mains"
HERD_SWEEP_PS_CMD="$T/ps-dying" HERD_STATUS_DUP_SAMPLES=3 HERD_STATUS_DUP_SLEEP=0 \
  _status_dup_verified "$DYING" >/dev/null \
  && fail "(j) a candidate that died between the last scan and the render was still named — an \
operator following the remedy line kills the one healthy watcher"
# The liveness helper itself: a pid absent from the (synthetic) table is not alive, a listed one is.
[ "$(HERD_SWEEP_PS_CMD="$T/ps-dying" _status_watcher_live_pids "$CANON"$'\n'"$ORPHAN")" = "$CANON" ] \
  || fail "(j) _status_watcher_live_pids kept a pid the process table no longer holds"
ok; echo "PASS (j) a pid that dies between scan and render drops out silently (control still alarms)"

# ── (l)/(m) HERD-743 (GH #812): the lock-holder cross-check ─────────────────────────────────────
# CANON holds $HERD_WATCHER_LOCK for this whole file. LOSER is a second herd-watch-wxws-tagged pid that
# is NOT the lock holder — exactly a losing HERD-209/252 singleton spawn still working through its own
# refusal. HERD_SWEEP_PS_ETIME_CMD plants its synthetic age; without it every pid here reads "unreadable"
# and _wx_pid_settled's fail-open would treat it as already-settled, silently defeating these two cases.
LOSER=800030
_plant_loser_table() {   # $1 = destination, $2 = the call number ($3="" ⇒ never) from which LOSER is gone
  cat > "$1" <<EOF
#!/usr/bin/env bash
n=0; [ -f "$T/ps-loser-calls" ] && n="\$(cat "$T/ps-loser-calls")"
n=\$(( n + 1 )); printf '%s\n' "\$n" > "$T/ps-loser-calls"
printf '%s 1 %s herd-watch-wxws bash agent-watch.sh --watch\n' "$CANON" "$CANON"
if [ -z "$2" ] || [ "\$n" -lt "$2" ]; then
  printf '%s 1 %s herd-watch-wxws bash agent-watch.sh\n' "$LOSER" "$LOSER"
fi
exit 0
EOF
  chmod +x "$1"
}
cat > "$T/ps-loser-young" <<'ETIME'
#!/usr/bin/env bash
printf '00:01'
ETIME
chmod +x "$T/ps-loser-young"
cat > "$T/ps-loser-old" <<'ETIME'
#!/usr/bin/env bash
printf '00:05'
ETIME
chmod +x "$T/ps-loser-old"

# (l) LOSER survives the base 3-sample window (still alive through call 5) but is YOUNG (1s, under the
# 2s default settle window) and dies (call 6) during the cross-check's extra wait → no alarm.
_plant_loser_table "$T/ps-loser" 6
: > "$T/ps-loser-calls"
LFIRST="$(HERD_SWEEP_PS_CMD="$T/ps-loser" watcher_list_mains)"
[ "$(printf '%s\n' "$LFIRST" | grep -c .)" -eq 2 ] || fail "(l) fixture: the first sample should see 2 mains"
HERD_SWEEP_PS_CMD="$T/ps-loser" HERD_SWEEP_PS_ETIME_CMD="$T/ps-loser-young" \
  HERD_STATUS_DUP_SAMPLES=3 HERD_STATUS_DUP_SLEEP=0 HERD_STATUS_DUP_SETTLE_ROUNDS=10 \
  _status_dup_verified "$LFIRST" >/dev/null \
  && fail "(l) a young non-lock-holder (a losing singleton spawn, HERD-209/252) still alarmed after \
outliving the base ~0.6s persistence window — an operator following the remedy could kill the real watcher"
ok; echo "PASS (l) a young non-lock-holder that dies during the settle window never alarms, even once it outlives the base window"

# (m) SAME shape, but LOSER never dies and reads OLD (5s, past the settle window) from the first look —
# a genuine duplicate that simply isn't the lock holder must still alarm, and without extra delay.
_plant_loser_table "$T/ps-loser-persist" ""
: > "$T/ps-loser-calls"
PFIRST="$(HERD_SWEEP_PS_CMD="$T/ps-loser-persist" watcher_list_mains)"
SURV="$(HERD_SWEEP_PS_CMD="$T/ps-loser-persist" HERD_SWEEP_PS_ETIME_CMD="$T/ps-loser-old" \
  HERD_STATUS_DUP_SAMPLES=3 HERD_STATUS_DUP_SLEEP=0 HERD_STATUS_DUP_SETTLE_ROUNDS=10 \
  _status_dup_verified "$PFIRST")" \
  || fail "(m) a genuine persistent duplicate that is NOT the lock holder stopped alarming — the lock \
cross-check must never permanently silence a real duplicate"
grep -qx "$LOSER" <<< "$SURV" || fail "(m) the persistent non-lock-holder duplicate was not reported: '$SURV'"
# … and an UNREADABLE/absent lockfile skips the cross-check entirely: the SAME young-and-dying LOSER
# fixture from (l) now alarms, because the base persistence-only check (today's behavior) never learns
# LOSER isn't the lock holder in the first place.
_plant_loser_table "$T/ps-loser-nolock" 6
: > "$T/ps-loser-calls"
NLFIRST="$(HERD_SWEEP_PS_CMD="$T/ps-loser-nolock" watcher_list_mains)"
( unset HERD_WATCHER_LOCK
  HERD_SWEEP_PS_CMD="$T/ps-loser-nolock" HERD_SWEEP_PS_ETIME_CMD="$T/ps-loser-young" \
    HERD_STATUS_DUP_SAMPLES=3 HERD_STATUS_DUP_SLEEP=0 \
    _status_dup_verified "$NLFIRST" >/dev/null ) \
  || fail "(m) an unreadable lockfile changed the alarm behavior — the cross-check must fail-soft to \
today's persistence-only check, not gate the alarm on a lock it could not read"
ok; echo "PASS (m) a genuine non-lock-holder duplicate still alarms (no delay once already old); an unreadable lockfile skips the cross-check"

# ── (k) HERD-524: the shared untagged-legacy predicate (a KILL path's proof) ────────────────────
# _stop_project_watcher's phase-2 leg finds UNTAGGED legacy watchers with 'pgrep -f agent-watch.sh' —
# a SUBSTRING match over the whole command line — and then SIGTERM/SIGKILLs what it matched. Every
# candidate must first be proven to be EXECUTING the script.
watcher_legacy_cmd "bash /w/scripts/herd/agent-watch.sh --watch" \
  || fail "(k) an untagged legacy watcher was not recognized — phase 2 would stop reaping relics"
watcher_legacy_cmd "/bin/bash -x /w/scripts/herd/agent-watch.sh" \
  || fail "(k) a shell option before the script path defeated the predicate"
watcher_legacy_cmd "/w/scripts/herd/agent-watch.sh --watch" \
  || fail "(k) a shebang-exec'd watcher (argv0 IS the script) was not recognized"
watcher_legacy_cmd "bash -c herd status; pgrep -af /w/scripts/herd/agent-watch.sh" \
  && fail "(k) a 'bash -c' wrapper MENTIONING the script path passed as a legacy watcher — this leg kills what it matches"
watcher_legacy_cmd "tail -f /w/trees/agent-watch.sh.log" \
  && fail "(k) a tail on the watcher log passed as a legacy watcher"
watcher_legacy_cmd "bash /w/scripts/herd/healthcheck.sh /w/tree # agent-watch.sh" \
  && fail "(k) a DIFFERENT script whose command line mentions agent-watch.sh passed"
watcher_legacy_cmd "" && fail "(k) an empty command line passed (a pid that exited between scan and ps)"
grep -q 'watcher_legacy_cmd "$scmd" || continue' "$REPO/bin/herd" \
  || fail "(k) _stop_project_watcher's legacy leg no longer routes candidates through the shared predicate"
ok; echo "PASS (k) the untagged-legacy KILL leg proves a candidate executes the script (no substring match)"

# ── (e) sweep's DETECTION-only gate-child guard ────────────────────────────────────────────────
# sweep_stray_watchers = watcher_list_mains, minus the lockfile pid, minus the gate-child heuristic.
# That last guard lives HERE and nowhere else: on a surface that only detects, sparing a false stray is
# right (leg 5 would SIGKILL in-flight gate work); on the listing, sparing one would blind the kill
# path. So GATEFORK must be ABSENT from sweep's strays and PRESENT in watcher_list_mains — the two
# surfaces agree about the canonical watcher and the orphan, and differ ONLY by that heuristic.
# Load sweep.sh the way the CLI does (agent-watch.sh in LIB mode) and drive it against the SAME table.
mkdir -p "$T/proj/.herd" "$T/proj/scripts"
cat > "$T/proj/.herd/config" <<EOF
PROJECT_ROOT=$T/proj
WORKTREES_DIR=$TREESDIR
WORKSPACE_NAME=wxws
EOF
STRAY="$( cd "$T/proj" && HERD_HERMETIC_GUARD=1 AGENT_WATCH_LIB=1 \
  bash -c '. "'"$REPO"'/scripts/herd/sweep.sh" >/dev/null 2>&1; sweep_stray_watchers' 2>/dev/null )"
if [ -n "$STRAY" ]; then
grep -qx "$ORPHAN" <<< "$STRAY" \
    || fail "(e) sweep_stray_watchers did not list the genuine orphan the shared check lists: '$STRAY'"
grep -qx "$CANON" <<< "$STRAY" && fail "(e) sweep_stray_watchers listed the canonical watcher"
grep -qx "$FORK" <<< "$STRAY" && fail "(e) sweep_stray_watchers listed a transient tick fork"
grep -qx "$GATEFORK" <<< "$STRAY" \
    && fail "(e) sweep_stray_watchers listed a fork parenting a live healthcheck — leg 5 would SIGKILL in-flight gate work (HERD-217)"
  ok; echo "PASS (e) sweep spares a gate-parenting fork that the kill list still counts"
else
  # sweep.sh could not be loaded in this environment (it pulls in agent-watch.sh's full substrate).
  # Prove the structure instead of skipping silently: sweep reads the SHARED listing, and the
  # gate-child guard is applied THERE and only there.
  grep -q 'watcher_list_mains "$table"' "$REPO/scripts/herd/sweep.sh" \
    || fail "(e) sweep_stray_watchers no longer reads the SHARED watcher_list_mains — the two seats can drift again"
  grep -q '_sweep_watcher_has_gate_child "$pid" "$table" && continue' "$REPO/scripts/herd/sweep.sh" \
    || fail "(e) sweep_stray_watchers lost its detection-only gate-child guard (HERD-217)"
  grep -q 'watcher_has_gate_child' "$REPO/scripts/herd/watcher-exempt.sh" \
    && grep -q 'watcher_has_gate_child' <<< "$(grep -E '^_wx_exempt\(\)' -A8 "$REPO/scripts/herd/watcher-exempt.sh" || true)" \
    && fail "(e) the gate-child guard leaked back into _wx_exempt — it would blind _stop_project_watcher"
  ok; echo "PASS (e) the gate-child guard lives on sweep's detection surface only (structural)"
fi

kill "$MARKED_REAL" 2>/dev/null || true
echo
echo "ALL PASS ($PASS checks)"
