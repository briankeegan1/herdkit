#!/usr/bin/env bash
# test-drainer-liveness.sh — hermetic proof of the drainer singleton LIVENESS reclaim path (HERD-109).
#
# The scribe/researcher drainers are per-project singletons: an enqueue that finds a same-named drainer
# in `herdr agent list` short-circuits and spawns nothing. A LISTED but HUNG drainer (wedged claude
# session / stuck step) would then block the queue forever. This adds a heartbeat + a hung verdict so
# the enqueue path can RECLAIM the singleton (spawn a fresh drainer) when the drainer went silent.
#
# This test locks in, WITHOUT any herdr/model/network (a stale heartbeat is stubbed on disk):
#   (1) herd_drainer_hung verdict matrix — fresh / ancient / absent / disabled(0) / non-numeric.
#   (2) herd_drainer_heartbeat writes a fresh (not-hung) beat.
#   (3) RECLAIM DECISION — the exact `if hung → reclaim else already-running` branch scribe.sh /
#       research.sh use: an ancient heartbeat reclaims; a fresh one keeps the legacy short-circuit;
#       timeout=0 keeps it even when ancient (feature disabled → byte-identical legacy).
#   (4) INTEGRATION — a real `scribe-step.sh next` / `research-step.sh next` against an EMPTY queue
#       prints EMPTY *and* leaves a FRESH heartbeat (so a live drainer is never seen as hung), proving
#       the step scripts actually beat and the wiring is byte-identical on stdout ("EMPTY").
#
# Test surface named in the PR: tests/test-drainer-liveness.sh (+ scripts/herd/drainer-liveness.sh).
# Run:  bash tests/test-drainer-liveness.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LIB="$ROOT/scripts/herd/drainer-liveness.sh"
SCRIBE_STEP="$ROOT/scripts/herd/scribe-step.sh"
RESEARCH_STEP="$ROOT/scripts/herd/research-step.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass(){ PASS=$((PASS+1)); }

for f in "$LIB" "$SCRIBE_STEP" "$RESEARCH_STEP"; do
  [ -f "$f" ] || fail "missing required file: $f"
done

# shellcheck source=/dev/null
. "$LIB"

# An "ancient" mtime (year 2000) is unambiguously staler than ANY positive timeout; a "fresh" touch is
# now. `touch -t CCYYMMDDhhmm` is POSIX (works on GNU + BSD + uutils), so the stub is portable.
ANCIENT="200001010000"

# ── (1) herd_drainer_hung verdict matrix ─────────────────────────────────────────────────────────────
HB="$T/hb"

touch "$HB"                                                     # fresh beat
herd_drainer_hung "$HB" 900 && fail "(1) fresh heartbeat must NOT be hung"
pass; echo "PASS (1a) fresh heartbeat → not hung"

touch -t "$ANCIENT" "$HB"                                       # ancient beat
herd_drainer_hung "$HB" 900 || fail "(1) ancient heartbeat must be HUNG at timeout 900"
pass; echo "PASS (1b) ancient heartbeat → hung"

herd_drainer_hung "$HB" 0 && fail "(1) timeout 0 must DISABLE liveness (never hung), even when ancient"
pass; echo "PASS (1c) timeout 0 → disabled (never hung), byte-identical legacy"

herd_drainer_hung "$HB" "" && fail "(1) empty timeout must be treated as off (never hung)"
herd_drainer_hung "$HB" "abc" && fail "(1) non-numeric timeout must be treated as off (never hung)"
pass; echo "PASS (1d) empty / non-numeric timeout → off"

herd_drainer_hung "$T/does-not-exist" 900 && fail "(1) absent heartbeat must be treated as ALIVE (fail-soft)"
pass; echo "PASS (1e) absent heartbeat → alive (fail-soft, byte-identical legacy)"

# ── (2) herd_drainer_heartbeat writes a fresh, not-hung beat ─────────────────────────────────────────
HB2="$T/nested/dir/hb"                                          # dir does not exist yet
herd_drainer_heartbeat "$HB2"
[ -f "$HB2" ] || fail "(2) herd_drainer_heartbeat did not create the heartbeat file (incl. parent dirs)"
herd_drainer_hung "$HB2" 900 && fail "(2) a just-written heartbeat must not be hung"
herd_drainer_heartbeat "" ; herd_drainer_heartbeat   # empty / missing arg must be a silent no-op (no crash under set -e-less)
pass; echo "PASS (2) heartbeat write creates a fresh, not-hung beat (and no-ops on empty arg)"

# ── (3) RECLAIM DECISION — the exact scribe.sh / research.sh branch ───────────────────────────────────
# decide <heartbeat> <timeout> → prints "reclaim" (spawn fresh) or "keep" (legacy already-running).
decide(){ if herd_drainer_hung "$1" "$2"; then echo reclaim; else echo keep; fi; }

touch -t "$ANCIENT" "$HB"
[ "$(decide "$HB" 900)" = "reclaim" ] || fail "(3) hung drainer must RECLAIM the singleton"
pass; echo "PASS (3a) hung (ancient heartbeat) → reclaim + spawn fresh drainer"

touch "$HB"
[ "$(decide "$HB" 900)" = "keep" ] || fail "(3) live drainer must KEEP the legacy short-circuit"
pass; echo "PASS (3b) live (fresh heartbeat) → keep 'already running' (byte-identical legacy)"

touch -t "$ANCIENT" "$HB"
[ "$(decide "$HB" 0)" = "keep" ] || fail "(3) feature disabled (timeout 0) must KEEP legacy even when ancient"
pass; echo "PASS (3c) disabled (timeout 0) → keep legacy path even with an ancient heartbeat"

# ── (4) INTEGRATION — real *-step.sh 'next' on an EMPTY queue beats + prints EMPTY ────────────────────
cat > "$T/config" <<EOF
PROJECT_ROOT="$T/repo"
WORKTREES_DIR="$T/trees"
WORKSPACE_NAME="livetest"
SCRIBE_BACKEND="file"
BACKLOG_FILE="BACKLOG.md"
EOF
mkdir -p "$T/repo" "$T/trees"

# scribe: SCRIBE_POLL=0 → 'next' returns immediately (no sleep) on the empty queue.
out="$(HERD_CONFIG_FILE="$T/config" SCRIBE_POLL=0 bash "$SCRIBE_STEP" next 2>/dev/null)"
[ "$out" = "EMPTY" ] || fail "(4) scribe-step next on empty queue should print EMPTY, got: $out"
SB_HB="$T/trees/.scribe.heartbeat"
[ -f "$SB_HB" ] || fail "(4) scribe-step next did not write the scribe heartbeat at $SB_HB"
herd_drainer_hung "$SB_HB" 900 && fail "(4) scribe heartbeat should be FRESH right after a drain step (live drainer never seen as hung)"
pass; echo "PASS (4a) scribe-step next → EMPTY + fresh heartbeat"

# researcher: RESEARCH_POLL=0, RESEARCH_TREES points the read-only lane at a temp dir.
out="$(HERD_CONFIG_FILE="$T/config" RESEARCH_POLL=0 RESEARCH_TREES="$T/rtrees" bash "$RESEARCH_STEP" next 2>/dev/null)"
[ "$out" = "EMPTY" ] || fail "(4) research-step next on empty queue should print EMPTY, got: $out"
RS_HB="$T/rtrees/.research.heartbeat"
[ -f "$RS_HB" ] || fail "(4) research-step next did not write the researcher heartbeat at $RS_HB"
herd_drainer_hung "$RS_HB" 900 && fail "(4) researcher heartbeat should be FRESH right after a drain step"
pass; echo "PASS (4b) research-step next → EMPTY + fresh heartbeat"

echo
echo "ALL PASS ($PASS checks) — drainer singleton liveness: hung reclaimed, live kept, disabled=legacy."
