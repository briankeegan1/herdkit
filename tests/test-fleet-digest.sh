#!/usr/bin/env bash
# test-fleet-digest.sh — hermetic tests for `herd fleet digest` (P1 cross-project standup).
#
# Design (mirrors test-fleet.sh):
#   • Fully hermetic: a temp HERD_FLEET_FILE registry + temp fake projects, each with its own
#     .herd/config and a hand-written .herd/journal.jsonl of known events; temp $HOME so the default
#     ~/.herd/fleet is never touched.
#   • Deterministic time: HERD_FLEET_NOW pins "now" to a fixed instant so the 24h window (and a wider
#     --since) select an exact, known set of events regardless of the real clock. No network, no gh.
#
# What it asserts: per-project aggregation over the window (shipped / needs-you / blocked / in-flight
# / gate failures), correct fleet summary counts, the window boundary (older events excluded until a
# wider --since is passed), hold_applied→hold_released cancelling a needs-you, and graceful handling
# of an empty journal (no activity), an unreachable project, and an empty registry.
#
# Run:  bash tests/test-fleet-digest.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
HERD="$HERE/../bin/herd"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass=0
ok(){ pass=$((pass+1)); }

export HOME="$T/home"; mkdir -p "$HOME"
export HERD_FLEET_FILE="$T/registry/fleet"
# Pin "now" so the default 24h window has cutoff 2026-07-02T12:00:00Z.
export HERD_FLEET_NOW="2026-07-03T12:00:00Z"

# _mkproj <name> — a fake herd project (no git needed; digest never shells out to git). Its journal
# lives at <root>-trees/.herd/journal.jsonl, the same place fleet.sh resolves via WORKTREES_DIR.
_mkproj() {
  local name="$1" root="$T/proj/$1"
  mkdir -p "$root/.herd" "$T/proj/$1-trees/.herd"
  local rr; rr="$(cd "$root" && pwd -P)"
  cat > "$root/.herd/config" <<CFG
PROJECT_ROOT="$rr"
WORKTREES_DIR="$rr-trees"
DEFAULT_BRANCH="origin/main"
WORKSPACE_NAME="$name"
HERD_REPO="me/$name"
CFG
  printf '%s' "$rr"
}
_journal() { printf '%s' "$1"; }   # readability no-op

ALPHA="$(_mkproj alpha)"
BETA="$(_mkproj beta)"

# alpha's journal: a mix inside the 24h window plus one merge OUTSIDE it (older than cutoff).
cat > "$T/proj/alpha-trees/.herd/journal.jsonl" <<'JL'
{"ts":"2026-07-01T10:00:00Z","event":"merge","pr":99,"sha":"old"}
{"ts":"2026-07-03T09:00:00Z","event":"merge","pr":8,"sha":"aa"}
{"ts":"2026-07-03T10:00:00Z","event":"merge","pr":7,"sha":"bb"}
{"ts":"2026-07-03T08:00:00Z","event":"hold_applied","pr":11,"kind":"human-verify"}
{"ts":"2026-07-03T07:00:00Z","event":"verdict_recorded","pr":12,"value":"BLOCK","source":"reviewer"}
{"ts":"2026-07-03T06:00:00Z","event":"review_dispatched","pr":13,"sha":"cc"}
{"ts":"2026-07-03T06:30:00Z","event":"healthcheck_outcome","pr":13,"outcome":"CODEERROR"}
{"ts":"2026-07-03T05:00:00Z","event":"hold_applied","pr":14,"kind":"approve"}
{"ts":"2026-07-03T05:30:00Z","event":"hold_released","pr":14,"kind":"approve","reason":"approved"}
JL

# beta: reachable, but an empty journal → "no activity in window".
: > "$T/proj/beta-trees/.herd/journal.jsonl"

bash "$HERD" fleet register "$ALPHA" >/dev/null
bash "$HERD" fleet register "$BETA"  >/dev/null

# ── 1. default 24h digest: alpha's per-project aggregation ────────────────────
out="$(bash "$HERD" fleet digest)"
alpha_block="$(printf '%s' "$out" | awk '/^alpha$/{f=1;next} /^[a-zA-Z]/{f=0} f')"
printf '%s' "$alpha_block" | grep -Eq 'shipped: +2' || fail "alpha should have 2 shipped (#7,#8), got: $alpha_block"
printf '%s' "$alpha_block" | grep -q '#7'  || fail "alpha shipped list should name #7"
printf '%s' "$alpha_block" | grep -q '#8'  || fail "alpha shipped list should name #8"
printf '%s' "$alpha_block" | grep -Eq 'needs you: +1' || fail "alpha should have 1 needs-you (#11)"
printf '%s' "$alpha_block" | grep -q '#11' || fail "alpha needs-you should name #11"
printf '%s' "$alpha_block" | grep -Eq 'blocked: +1'   || fail "alpha should have 1 blocked (#12)"
printf '%s' "$alpha_block" | grep -q '#12' || fail "alpha blocked should name #12"
printf '%s' "$alpha_block" | grep -Eq 'in-flight: +1' || fail "alpha should have 1 in-flight (#13)"
printf '%s' "$alpha_block" | grep -q '#13' || fail "alpha in-flight should name #13"
printf '%s' "$alpha_block" | grep -Eq 'gate fails: +2' || fail "alpha should have 2 gate fails (BLOCK+CODEERROR)"
ok

# ── 2. the older merge (#99) is OUTSIDE the 24h window → excluded ─────────────
printf '%s' "$alpha_block" | grep -q '#99' && fail "merge #99 (older than 24h cutoff) must not appear"
ok

# ── 3. a hold that was RELEASED does not linger as needs-you (#14 dropped) ────
printf '%s' "$alpha_block" | grep -q '#14' && fail "#14 hold was released → must not show as needs-you"
ok

# ── 4. beta with an empty journal reports no activity, not a crash ────────────
beta_block="$(printf '%s' "$out" | awk '/^beta$/{f=1;next} /^[a-zA-Z]/{f=0} f')"
printf '%s' "$beta_block" | grep -qi "no activity" || fail "beta (empty journal) should report no activity"
ok

# ── 5. fleet summary line tallies across all projects ────────────────────────
printf '%s' "$out" | grep -q "^Fleet:" || fail "digest missing the fleet summary line"
summary="$(printf '%s' "$out" | grep '^Fleet:')"
printf '%s' "$summary" | grep -q "2 projects"     || fail "summary should count 2 projects, got: $summary"
printf '%s' "$summary" | grep -q "2 shipped"      || fail "summary should tally 2 shipped"
printf '%s' "$summary" | grep -q "1 need you"     || fail "summary should tally 1 need-you"
printf '%s' "$summary" | grep -q "1 blocked"      || fail "summary should tally 1 blocked"
printf '%s' "$summary" | grep -q "1 in-flight"    || fail "summary should tally 1 in-flight"
printf '%s' "$summary" | grep -q "2 gate failures" || fail "summary should tally 2 gate failures"
ok

# ── 6. a WIDER --since window pulls in the older merge (#99) ──────────────────
out7d="$(bash "$HERD" fleet digest --since 7d)"
a7="$(printf '%s' "$out7d" | awk '/^alpha$/{f=1;next} /^[a-zA-Z]/{f=0} f')"
printf '%s' "$a7" | grep -Eq 'shipped: +3' || fail "--since 7d should include #99 → 3 shipped, got: $a7"
printf '%s' "$a7" | grep -q '#99' || fail "--since 7d should name #99"
printf '%s' "$out7d" | grep '^Fleet:' | grep -q "3 shipped" || fail "7d summary should tally 3 shipped"
ok

# ── 7. a TIGHTER --since window narrows the set (2h → only #7 merged) ─────────
# cutoff = 2026-07-03T10:00:00Z; only the merge at 10:00:00 (#7) is at-or-after it.
out2h="$(bash "$HERD" fleet digest --since 2h)"
a2="$(printf '%s' "$out2h" | awk '/^alpha$/{f=1;next} /^[a-zA-Z]/{f=0} f')"
printf '%s' "$a2" | grep -Eq 'shipped: +1' || fail "--since 2h should include only #7 → 1 shipped, got: $a2"
printf '%s' "$a2" | grep -q '#7'  || fail "--since 2h should name #7"
printf '%s' "$a2" | grep -q '#8'  && fail "--since 2h (cutoff 10:00) must exclude #8 (merged 09:00)"
ok

# ── 8. an UNREACHABLE (missing) project is reported, not fatal ────────────────
printf 'ghost|%s/proj/ghost|me/ghost\n' "$T" >> "$HERD_FLEET_FILE"
out="$(bash "$HERD" fleet digest)"
ghost_block="$(printf '%s' "$out" | awk '/^ghost$/{f=1;next} /^[a-zA-Z]/{f=0} f')"
printf '%s' "$ghost_block" | grep -qi "unreachable" || fail "missing project should be reported as unreachable"
printf '%s' "$out" | grep '^Fleet:' | grep -q "3 projects" || fail "summary should still count the ghost project"
# aggregation of the reachable projects still renders (alpha present after the ghost).
printf '%s' "$out" | grep -q "^alpha$" || fail "digest should continue past the unreachable project"
ok

# ── 9. a completely MISSING journal file (no journal.jsonl at all) → no activity ─
GAMMA="$(_mkproj gamma)"
rm -f "$T/proj/gamma-trees/.herd/journal.jsonl"   # dir exists, file does not
bash "$HERD" fleet register "$GAMMA" >/dev/null
# drop the ghost line so this run is clean.
grep -v '^ghost|' "$HERD_FLEET_FILE" > "$HERD_FLEET_FILE.tmp" && mv "$HERD_FLEET_FILE.tmp" "$HERD_FLEET_FILE"
out="$(bash "$HERD" fleet digest)"
g_block="$(printf '%s' "$out" | awk '/^gamma$/{f=1;next} /^[a-zA-Z]/{f=0} f')"
printf '%s' "$g_block" | grep -qi "no activity" || fail "gamma (no journal file) should report no activity, not crash"
ok

# ── 10. empty registry is a friendly note, not a crash ───────────────────────
out="$(HERD_FLEET_FILE="$T/none/fleet" bash "$HERD" fleet digest)"
printf '%s' "$out" | grep -qi "no fleet registry\|register" || fail "empty-registry digest should hint how to add a project"
ok

# ── 11. --since with no value fails loudly ───────────────────────────────────
if bash "$HERD" fleet digest --since >/dev/null 2>&1; then
  fail "--since with no argument should exit non-zero"
fi
ok

# ── 12. --help renders usage without touching the registry ───────────────────
out="$(bash "$HERD" fleet digest --help)"
printf '%s' "$out" | grep -qi "standup\|--since" || fail "digest --help should describe the command"
ok

echo "ALL PASS ($pass checks)"
