#!/usr/bin/env bash
# test-fleet-inbox.sh — hermetic tests for `herd fleet inbox` (P2 cross-project attention inbox).
#
# Design (mirrors test-fleet-digest.sh):
#   • Fully hermetic: a temp HERD_FLEET_FILE registry + temp fake projects, each with its own
#     .herd/config and a hand-written .herd/journal.jsonl of known watcher events; temp $HOME so the
#     default ~/.herd/fleet is never touched.
#   • A stub `gh` on PATH returns canned open-PR JSON per project (keyed by the project dir basename)
#     so CONFLICTING PRs are exercised WITHOUT the network. Dropping the stub from PATH exercises the
#     gh-unavailable path.
#
# What it asserts: the four core attention items surface with the RIGHT project + suggested action —
# review BLOCK, human-verify hold, failed health gate (all journal-derived), and CONFLICTING (gh) —
# a released hold and a merged PR clear themselves (no stale items), a clean project shows nothing,
# the fleet summary tallies correctly, and unreachable / gh-down / empty-registry are graceful.
#
# Run:  bash tests/test-fleet-inbox.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
HERD="$HERE/../bin/herd"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass=0
ok(){ pass=$((pass+1)); }

export HOME="$T/home"; mkdir -p "$HOME"
export HERD_FLEET_FILE="$T/registry/fleet"

# ── stub gh: canned `gh pr list` JSON per project (fixture keyed by cwd basename) ──
export FAKE_GH_DIR="$T/gh"; mkdir -p "$FAKE_GH_DIR"
mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'GH'
#!/usr/bin/env bash
# minimal gh stub — only implements `pr list --json ...`, returns the fixture for $PWD's project.
# FAKE_GH_FAIL=1 makes it exit non-zero (simulating an unauthed/offline gh) so callers can exercise
# the gh-unavailable path without disturbing PATH (which must keep python3 reachable).
[ "${FAKE_GH_FAIL:-}" = "1" ] && { echo "gh: not authenticated" >&2; exit 1; }
case "$*" in
  *"pr list"*)
    f="$FAKE_GH_DIR/$(basename "$PWD").json"
    if [ -f "$f" ]; then cat "$f"; else echo "[]"; fi ;;
  *) echo "[]" ;;
esac
GH
chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH"

# _mkproj <name> — a fake herd project. Its journal lives at <root>-trees/.herd/journal.jsonl,
# the same place fleet.sh resolves via WORKTREES_DIR.
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

ALPHA="$(_mkproj alpha)"
BETA="$(_mkproj beta)"

# alpha's journal — a mix that reduces to: #11 human-verify hold, #12 review BLOCK, #13 health gate
# failed, #20 hold released (cleared), #30 blocked-then-merged (cleared).
cat > "$T/proj/alpha-trees/.herd/journal.jsonl" <<'JL'
{"ts":"2026-07-03T07:00:00Z","event":"verdict_recorded","pr":12,"value":"BLOCK","source":"reviewer"}
{"ts":"2026-07-03T08:00:00Z","event":"hold_applied","pr":11,"kind":"human-verify","slug":"login-fix"}
{"ts":"2026-07-03T06:30:00Z","event":"healthcheck_outcome","pr":13,"slug":"api-gate","outcome":"CODEERROR"}
{"ts":"2026-07-03T05:00:00Z","event":"hold_applied","pr":20,"kind":"approve","slug":"docs"}
{"ts":"2026-07-03T05:30:00Z","event":"hold_released","pr":20,"kind":"approve","reason":"approved"}
{"ts":"2026-07-03T04:00:00Z","event":"verdict_recorded","pr":30,"value":"BLOCK"}
{"ts":"2026-07-03T09:00:00Z","event":"merge","pr":30,"slug":"shipped"}
JL

# alpha's live PRs (gh): #14 CONFLICTING (attention), #8 MERGEABLE (no attention).
cat > "$FAKE_GH_DIR/alpha.json" <<'J'
[{"number":14,"headRefName":"feat/widget","mergeable":"CONFLICTING"},
 {"number":8,"headRefName":"feat/clean","mergeable":"MERGEABLE"}]
J

# beta: reachable, empty journal + no open PRs → clean.
: > "$T/proj/beta-trees/.herd/journal.jsonl"
echo '[]' > "$FAKE_GH_DIR/beta.json"

bash "$HERD" fleet register "$ALPHA" >/dev/null
bash "$HERD" fleet register "$BETA"  >/dev/null

out="$(bash "$HERD" fleet inbox)"
alpha_block="$(printf '%s' "$out" | awk '/^alpha$/{f=1;next} /^[a-zA-Z]/{f=0} f')"
beta_block="$(printf '%s'  "$out" | awk '/^beta$/{f=1;next}  /^[a-zA-Z]/{f=0} f')"

# ── 1. review BLOCK surfaces on the right project with the right action ────────
printf '%s' "$alpha_block" | grep -q '#12' || fail "alpha should surface blocked PR #12"
printf '%s' "$alpha_block" | grep '#12' | grep -qi 'BLOCK'          || fail "#12 should be labelled a review BLOCK"
printf '%s' "$alpha_block" | grep '#12' | grep -q 'herd why 12'     || fail "#12 action should be 'herd why 12'"
ok

# ── 2. human-verify hold surfaces with the approve action ─────────────────────
printf '%s' "$alpha_block" | grep -q '#11' || fail "alpha should surface human-verify hold PR #11"
printf '%s' "$alpha_block" | grep '#11' | grep -qi 'human-verify'   || fail "#11 should be labelled a human-verify hold"
printf '%s' "$alpha_block" | grep '#11' | grep -q 'herd-approve.sh approve 11' || fail "#11 action should be 'herd-approve.sh approve 11'"
ok

# ── 3. failed health gate surfaces with the inspect action ────────────────────
printf '%s' "$alpha_block" | grep -q '#13' || fail "alpha should surface failed health gate PR #13"
printf '%s' "$alpha_block" | grep '#13' | grep -qi 'health'         || fail "#13 should be labelled a failed health gate"
printf '%s' "$alpha_block" | grep '#13' | grep -q 'herd why 13'     || fail "#13 action should be 'herd why 13'"
ok

# ── 4. CONFLICTING PR (from gh) surfaces with the resolve action + slug ───────
printf '%s' "$alpha_block" | grep -q '#14' || fail "alpha should surface CONFLICTING PR #14"
printf '%s' "$alpha_block" | grep '#14' | grep -qi 'CONFLICTING'    || fail "#14 should be labelled CONFLICTING"
printf '%s' "$alpha_block" | grep '#14' | grep -q 'herd-resolve.sh widget' || fail "#14 action should resolve slug 'widget' (from feat/widget)"
ok

# ── 5. a MERGEABLE PR (#8) is NOT an attention item ───────────────────────────
printf '%s' "$alpha_block" | grep -q '#8'  && fail "MERGEABLE PR #8 must not appear as attention"
ok

# ── 6. a RELEASED hold (#20) and a MERGED PR (#30) clear themselves ───────────
printf '%s' "$alpha_block" | grep -q '#20' && fail "#20 hold was released → must not appear"
printf '%s' "$alpha_block" | grep -q '#30' && fail "#30 was merged → must not appear (blocked-then-merged clears)"
ok

# ── 7. a clean project shows nothing pending, not items ───────────────────────
printf '%s' "$beta_block" | grep -qi 'clean'  || fail "beta (empty) should report clean"
printf '%s' "$beta_block" | grep -q '#'       && fail "clean project beta must list no PR items"
ok

# ── 8. fleet summary tallies items/projects/clean ─────────────────────────────
printf '%s' "$out" | grep -q '^Fleet:' || fail "inbox missing the fleet summary line"
summary="$(printf '%s' "$out" | grep '^Fleet:')"
printf '%s' "$summary" | grep -q '4 items'          || fail "summary should tally 4 items, got: $summary"
printf '%s' "$summary" | grep -q 'across 1 project'  || fail "summary should count 1 needy project"
printf '%s' "$summary" | grep -q '1 clean'           || fail "summary should count 1 clean project"
ok

# ── 9. an UNREACHABLE (missing) project is reported, not fatal ─────────────────
printf 'ghost|%s/proj/ghost|me/ghost\n' "$T" >> "$HERD_FLEET_FILE"
out2="$(bash "$HERD" fleet inbox)"
ghost_block="$(printf '%s' "$out2" | awk '/^ghost$/{f=1;next} /^[a-zA-Z]/{f=0} f')"
printf '%s' "$ghost_block" | grep -qi 'unreachable' || fail "missing project should be reported as unreachable"
printf '%s' "$out2" | grep '^Fleet:' | grep -q '1 unreachable' || fail "summary should count the ghost as unreachable"
printf '%s' "$out2" | grep -q '^alpha$' || fail "inbox should continue past the unreachable project"
# drop the ghost line so later runs are clean
grep -v '^ghost|' "$HERD_FLEET_FILE" > "$HERD_FLEET_FILE.tmp" && mv "$HERD_FLEET_FILE.tmp" "$HERD_FLEET_FILE"
ok

# ── 10. gh unavailable: journal items still render; conflict is skipped + noted ─
out3="$(FAKE_GH_FAIL=1 bash "$HERD" fleet inbox)"
a3="$(printf '%s' "$out3" | awk '/^alpha$/{f=1;next} /^[a-zA-Z]/{f=0} f')"
printf '%s' "$a3" | grep -q '#11' || fail "gh-down: journal-derived hold #11 should still surface"
printf '%s' "$a3" | grep -q '#12' || fail "gh-down: journal-derived BLOCK #12 should still surface"
printf '%s' "$a3" | grep -q '#14' && fail "gh-down: CONFLICTING #14 (gh-only) must not appear without gh"
printf '%s' "$a3" | grep -qi 'gh unavailable' || fail "gh-down should note that conflicts were not checked"
ok

# ── 11. empty registry is a friendly note, not a crash ────────────────────────
out4="$(HERD_FLEET_FILE="$T/none/fleet" bash "$HERD" fleet inbox)"
printf '%s' "$out4" | grep -qi 'no fleet registry\|register' || fail "empty-registry inbox should hint how to add a project"
ok

# ── 12. --help renders usage without touching the registry ────────────────────
outh="$(bash "$HERD" fleet inbox --help)"
printf '%s' "$outh" | grep -qi 'attention inbox\|needs you' || fail "inbox --help should describe the command"
ok

# ── 13. an unknown argument fails loudly ──────────────────────────────────────
if bash "$HERD" fleet inbox bogus >/dev/null 2>&1; then
  fail "inbox with an unexpected argument should exit non-zero"
fi
ok

echo "ALL PASS ($pass checks)"
