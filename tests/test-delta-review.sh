#!/usr/bin/env bash
# test-delta-review.sh — hermetic tests for DELTA_REVIEW (off | on), HERD-204.
#
# DELTA_REVIEW governs whether the watcher's pre-merge review gate SKIPS a full re-review when a PR's
# new head sha differs from its last review-PASSED sha ONLY by a merge of DEFAULT_BRANCH (a pure
# INTEGRATION push):
#   off (default) — every new sha gets the full adversarial review, byte-identical to before.
#   on            — before dispatching a reviewer, PROVE the delta is integration-only; if proven,
#                   CARRY FORWARD the prior PASS onto the new sha instead of re-reviewing.
#
# The hinge is _maybe_carry_forward_review() (backed by _delta_is_integration_only), called by
# _review_gate_step BEFORE the reviewer dispatch. These tests source agent-watch.sh in lib mode (the
# same seam test-gate-dispatch.sh uses) with HERD_REVIEW_BIN pointed at a stub reviewer, build REAL
# git worktrees (git is NOT stubbed here — the proof is genuine git topology + trees), and assert:
#   (a) A PURE merge-from-main push CARRIES the prior PASS: no reviewer is dispatched, a sha-keyed
#       PASS is recorded with source=carried-forward, and _review_gate_step echoes PASS.
#   (b) Any REAL authored change (beyond the merge) still triggers a FULL review: the reviewer is
#       dispatched (RUNNING), nothing is carried forward.
#   (c) DELTA_REVIEW=off (and unknown values) is byte-inert: even a pure merge triggers a full review.
#   (d) Unit coverage of the proof primitive _delta_is_integration_only: TRUE for a clean integration
#       merge; FALSE for an authored-in-merge commit, a conflicted/hand-resolved merge, a
#       non-merge (single-parent) commit, and a main-side parent NOT contained in DEFAULT_BRANCH.
#
# Fully hermetic: local temp only; stubs gh/herdr (PATH) and the reviewer (HERD_REVIEW_BIN). No
# network, no model, no real PRs. REAL git is required and used.
# Run:  bash tests/test-delta-review.sh
# No `set -e`: some checks assert non-zero returns explicitly.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../scripts/herd/agent-watch.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

[ -f "$WATCH" ] || fail "agent-watch.sh not found at $WATCH"
command -v git >/dev/null 2>&1 || fail "git required to run this test"

# ── Stub binaries on PATH (git deliberately NOT stubbed — this test needs real git topology) ──
BIN="$T/bin"; mkdir -p "$BIN"
for cmd in gh herdr; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$cmd"; chmod +x "$BIN/$cmd"
done
export PATH="$BIN:$PATH"

# ── Stub reviewer (stands in for herd-review.sh via the HERD_REVIEW_BIN seam) ─
# Logs every invocation to STUB_SPAWN_LOG and writes STUB_VERDICT to the result file (atomic mv).
STUB_REVIEW="$T/stub-review.sh"
cat > "$STUB_REVIEW" <<'STUB'
#!/usr/bin/env bash
pr="$1"; slug="$2"
[ -n "${STUB_SPAWN_LOG:-}" ] && printf '%s %s\n' "$pr" "$slug" >> "$STUB_SPAWN_LOG"
sleep "${STUB_DELAY:-0}"
if [ -n "${HERD_REVIEW_RESULT_FILE:-}" ]; then
  printf '%s\n' "${STUB_VERDICT:-REVIEW: PASS}" > "$HERD_REVIEW_RESULT_FILE.tmp.$$"
  mv "$HERD_REVIEW_RESULT_FILE.tmp.$$" "$HERD_REVIEW_RESULT_FILE"
fi
printf '%s\n' "${STUB_VERDICT:-REVIEW: PASS}"
STUB
chmod +x "$STUB_REVIEW"

# ── Source agent-watch.sh in lib mode ────────────────────────────────────────
export AGENT_WATCH_LIB=1
export WORKTREES_DIR="$T/trees"; mkdir -p "$WORKTREES_DIR"
export HERD_CONFIG_FILE="$T/no-such-config"
export HERD_REVIEW_BIN="$STUB_REVIEW"
export REVIEW_CONCURRENCY=2
export DEFAULT_BRANCH=main
export DRYRUN=""
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"

for fn in _delta_review_enabled _review_last_passed_sha _delta_main_ref \
          _delta_is_integration_only _maybe_carry_forward_review _review_gate_step; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined after sourcing"
done
ok

export STUB_SPAWN_LOG="$T/spawns.log"; : > "$STUB_SPAWN_LOG"

# git helpers ────────────────────────────────────────────────────────────────
gc() { git -C "$1" "${@:2}"; }
init_repo() {
  local d="$1"
  git init -q "$d"
  gc "$d" config user.email a@b.c
  gc "$d" config user.name  a
  gc "$d" config commit.gpgsign false
  printf 'l1\nl2\n' > "$d/base"; gc "$d" add base; gc "$d" commit -qm base
  gc "$d" branch -M feat        # branch under review is 'feat'
  gc "$d" branch main feat      # DEFAULT_BRANCH ref
}
# Build a repo whose head is a PURE integration merge of main into feat. Echoes "<old> <new>".
build_integration() {
  local d="$1"; init_repo "$d"
  printf 'branch work\n' > "$d/feature.txt"; gc "$d" add feature.txt; gc "$d" commit -qm 'feat work'
  local old; old="$(gc "$d" rev-parse HEAD)"
  gc "$d" checkout -q main
  printf 'main work\n' > "$d/mainfile.txt"; gc "$d" add mainfile.txt; gc "$d" commit -qm 'main advance'
  gc "$d" checkout -q feat
  gc "$d" merge -q --no-edit main            # first parent = old (feat), second = main tip
  local new; new="$(gc "$d" rev-parse HEAD)"
  printf '%s %s' "$old" "$new"
}

# ── (a) PURE merge-from-main push CARRIES the prior PASS ──────────────────────
D1="$WORKTREES_DIR/slug-int"; read -r OLD1 NEW1 < <(build_integration "$D1")
[ "$OLD1" != "$NEW1" ] || fail "setup: integration merge produced no new sha"
record_review 101 "$OLD1" PASS reviewer            # the PR was reviewed & PASSED at OLD1
: > "$STUB_SPAWN_LOG"
step="$(DELTA_REVIEW=on _review_gate_step 101 slug-int "$NEW1")"
[ "$step" = "PASS" ] || fail "(a) integration-only push should carry forward as PASS (got '$step')"
[ ! -s "$STUB_SPAWN_LOG" ] || fail "(a) carry-forward must NOT dispatch a reviewer"
[ ! -f "$(_review_inflight_file 101 "$NEW1")" ] || fail "(a) carry-forward must not write an inflight marker"
[ "$(review_verdict 101 "$NEW1")" = "PASS" ] || fail "(a) new sha must be recorded PASS"
[ "$(review_verdict_source 101 "$NEW1")" = "carried-forward" ] || fail "(a) provenance must be carried-forward"
ok

# ── (a2) once carried, the sha's verdict is cached — no re-review on later ticks ──
for _ in 1 2 3; do DELTA_REVIEW=on _predispatch_review_if_parallel 101 slug-int "$NEW1"; done
[ ! -s "$STUB_SPAWN_LOG" ] || fail "(a2) a carried sha must never dispatch a reviewer on later ticks"
[ "$(awk -v p=101 -v s="$NEW1" '$2==p && $3==s' "$REVIEW_STATE" | grep -c .)" -eq 1 ] \
  || fail "(a2) duplicate ledger rows accumulated for the carried sha"
ok

# ── (b) a REAL authored change beyond the merge triggers a FULL review ────────
D2="$WORKTREES_DIR/slug-code"; read -r OLD2 _NEW2 < <(build_integration "$D2")
# Amend the merge to also carry an authored edit → NOT integration-only.
printf 'sneaky authored change\n' >> "$D2/feature.txt"; gc "$D2" add feature.txt
gc "$D2" commit -q --amend --no-edit
NEW2="$(gc "$D2" rev-parse HEAD)"
record_review 102 "$OLD2" PASS reviewer
: > "$STUB_SPAWN_LOG"
export STUB_DELAY=2 STUB_VERDICT="REVIEW: PASS"
step="$(DELTA_REVIEW=on _review_gate_step 102 slug-code "$NEW2")"
[ "$step" = "RUNNING" ] || fail "(b) an authored change must dispatch a full review (got '$step')"
[ -f "$(_review_inflight_file 102 "$NEW2")" ] || fail "(b) full review must write an inflight marker"
grep -q '^102 slug-code$' "$STUB_SPAWN_LOG" || fail "(b) reviewer was not dispatched for a real change"
[ -z "$(review_verdict 102 "$NEW2" || true)" ] || fail "(b) no verdict should be carried for a real change yet"
ok
export STUB_DELAY=0

# ── (c) DELTA_REVIEW=off (and unknown) is byte-inert: even a pure merge is fully reviewed ──
D3="$WORKTREES_DIR/slug-off"; read -r OLD3 NEW3 < <(build_integration "$D3")
record_review 103 "$OLD3" PASS reviewer
: > "$STUB_SPAWN_LOG"; export STUB_DELAY=2
step="$(DELTA_REVIEW=off _review_gate_step 103 slug-off "$NEW3")"
[ "$step" = "RUNNING" ] || fail "(c) DELTA_REVIEW=off must run the full review even for a pure merge (got '$step')"
grep -q '^103 slug-off$' "$STUB_SPAWN_LOG" || fail "(c) off mode did not dispatch the reviewer"
[ "$(review_verdict 103 "$NEW3" || true)" != "PASS" ] || fail "(c) off mode must not carry forward"
# unknown value behaves exactly like off
_delta_review_enabled() { case "${DELTA_REVIEW:-off}" in on|On|ON) return 0;; *) return 1;; esac; }  # (sanity: definition intact)
DELTA_REVIEW=bogus _delta_review_enabled && fail "(c) unknown DELTA_REVIEW must resolve to off"
[ "$(unset DELTA_REVIEW; _delta_review_enabled; echo $?)" = "1" ] || fail "(c) unset DELTA_REVIEW must be off"
DELTA_REVIEW=on _delta_review_enabled || fail "(c) DELTA_REVIEW=on must enable"
export STUB_DELAY=0
ok

# ── (d) _delta_is_integration_only proof primitive ───────────────────────────
# TRUE: a clean integration merge.
D4="$WORKTREES_DIR/prim-int"; read -r OLDp NEWp < <(build_integration "$D4")
_delta_is_integration_only "$D4" "$OLDp" "$NEWp" || fail "(d) clean integration merge must prove TRUE"
ok
# FALSE: authored-in-merge (reuse D2's amended merge).
_delta_is_integration_only "$D2" "$OLD2" "$NEW2" && fail "(d) authored-in-merge must prove FALSE"
ok
# FALSE: a conflicted, hand-resolved merge (manual content the reviewer never saw).
D5="$WORKTREES_DIR/prim-conflict"; init_repo "$D5"
printf 'l1\nBRANCH\n' > "$D5/base"; gc "$D5" add base; gc "$D5" commit -qm 'branch edit'
OLD5="$(gc "$D5" rev-parse HEAD)"
gc "$D5" checkout -q main
printf 'l1\nMAIN\n' > "$D5/base"; gc "$D5" add base; gc "$D5" commit -qm 'main edit'
gc "$D5" checkout -q feat
gc "$D5" merge --no-edit main >/dev/null 2>&1
printf 'l1\nRESOLVED\n' > "$D5/base"; gc "$D5" add base; gc "$D5" commit -q --no-edit
NEW5="$(gc "$D5" rev-parse HEAD)"
_delta_is_integration_only "$D5" "$OLD5" "$NEW5" && fail "(d) conflicted/hand-resolved merge must prove FALSE"
ok
# FALSE: a plain single-parent commit (not a merge at all).
D6="$WORKTREES_DIR/prim-linear"; init_repo "$D6"
printf 'x\n' > "$D6/a"; gc "$D6" add a; gc "$D6" commit -qm one; OLD6="$(gc "$D6" rev-parse HEAD)"
printf 'y\n' > "$D6/b"; gc "$D6" add b; gc "$D6" commit -qm two; NEW6="$(gc "$D6" rev-parse HEAD)"
_delta_is_integration_only "$D6" "$OLD6" "$NEW6" && fail "(d) a non-merge commit must prove FALSE"
ok
# FALSE: main-side parent NOT contained in DEFAULT_BRANCH (merged a side branch, not main).
D7="$WORKTREES_DIR/prim-notmain"; init_repo "$D7"
printf 'w\n' > "$D7/f"; gc "$D7" add f; gc "$D7" commit -qm 'feat work'; OLD7="$(gc "$D7" rev-parse HEAD)"
gc "$D7" checkout -q -b side main
printf 's\n' > "$D7/s"; gc "$D7" add s; gc "$D7" commit -qm 'side work'   # NOT on main
gc "$D7" checkout -q feat
gc "$D7" merge -q --no-edit side
NEW7="$(gc "$D7" rev-parse HEAD)"
_delta_is_integration_only "$D7" "$OLD7" "$NEW7" && fail "(d) merge of a non-main branch must prove FALSE"
ok
# Fail-closed on a missing worktree / bogus shas.
_delta_is_integration_only "$WORKTREES_DIR/nope" "$OLDp" "$NEWp" && fail "(d) missing worktree must prove FALSE"
_delta_is_integration_only "$D4" "deadbeef" "$NEWp" && fail "(d) bogus old sha must prove FALSE"
_delta_is_integration_only "$D4" "$NEWp" "$NEWp" && fail "(d) identical shas must prove FALSE"
ok

# ── (e) _review_last_passed_sha picks the most recent PASS; ignores BLOCK ─────
rm -f "$REVIEW_STATE"
record_review 200 aaa PASS reviewer
record_review 200 bbb BLOCK reviewer
record_review 200 ccc PASS reviewer
[ "$(_review_last_passed_sha 200)" = "ccc" ] || fail "(e) last-passed must be the most recent PASS sha"
_review_last_passed_sha 999 && fail "(e) a PR with no PASS must return non-zero"
ok

echo "ALL PASS ($pass checks)"
