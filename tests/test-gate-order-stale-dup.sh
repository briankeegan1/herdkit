#!/usr/bin/env bash
# test-gate-order-stale-dup.sh — the GATE ORDER ratchet (HERD-227).
#
# The stale/duplicate gate is deterministic and cheap; the review and the healthcheck are neither.
# Until HERD-227 the gate ran LAST, so every stale-base cycle paid for a full ~9-min heavy suite and
# an Opus review on a sha the gate's own autofix bounce was about to supersede (PR #328, 2026-07-09:
# healthcheck_started 14:23:57 → CLEAN 14:26:22 → stale_dup_hold 14:26:24 → doomed BLOCK 14:29:57).
#
# This suite pins BOTH halves of the fix:
#
#   (1) STRUCTURAL — in agent-watch.sh's action pass, the `_stale_dup_gate_step` call on $candsha
#       precedes BOTH `_predispatch_review_if_parallel` and `_healthcheck_gate`. This is the ordering
#       invariant itself; the behavioral checks below cannot observe it (the action pass is inline in
#       the main loop, past the AGENT_WATCH_LIB source cutoff).
#   (2) STALE-BASE HOLD — driven through a faithful replay of that call order against a real git
#       fixture: the gate returns HOLD, the caller dispatches nothing, and the journal carries a
#       stale_dup_hold with ZERO review_dispatched / healthcheck_started events for that sha.
#   (3) FRESH BASE — the identical replay dispatches exactly as before: review_dispatched then
#       healthcheck_started, in that order, and no stale_dup_hold. Proceeding is byte-quiet.
#   (4) STALE_DUP_DETECT=off — byte-identical to (3), even on the stale fixture.
#   (5) DRY-RUN — the gate is a strict no-op (the pre-HERD-227 pass `continue`d before ever reaching
#       it, so evaluating under dry-run would newly post PR comments). No hold, no gh comment.
#   (6) FAIL-SOFT — an evaluation error (nonzero with no _STALE_DUP_KIND) PROCEEDS on today's order.
#   (7) HOLD is once-per-sha — a second tick on the same sha re-renders the row but posts no second
#       PR comment (the stale_dup_held_noted guard survives the hoist).
#
# Hermetic: a real local git repo (no network), stubbed gh/herdr, a stub reviewer via HERD_REVIEW_BIN.
# Run:  bash tests/test-gate-order-stale-dup.sh
# No `set -e`: several checks assert non-zero returns explicitly.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../scripts/herd/agent-watch.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); echo "PASS: $1"; }

[ -f "$WATCH" ] || fail "agent-watch.sh not found at $WATCH"
command -v python3 >/dev/null 2>&1 || fail "python3 required"
command -v git >/dev/null 2>&1 || fail "git required"

# ── (1) STRUCTURAL: the action pass decides stale-dup before it dispatches anything ───────────
line_of() { grep -F -n -- "$1" "$WATCH" | head -n1 | cut -d: -f1; }
count_of() { grep -F -c -- "$1" "$WATCH" 2>/dev/null | head -n1 | tr -d ' '; }

L_GATE="$(line_of '_stale_dup_gate_step "$prnum" "$slug" "$dir" "$candsha"')"
L_REVIEW="$(line_of '_predispatch_review_if_parallel "$prnum"')"
L_HEALTH="$(line_of '_healthcheck_gate "$prnum"')"
[ -n "$L_GATE" ]   || fail "(1) no _stale_dup_gate_step call on \$candsha in the action pass"
[ -n "$L_REVIEW" ] || fail "(1) no _predispatch_review_if_parallel call found"
[ -n "$L_HEALTH" ] || fail "(1) no _healthcheck_gate call found"
[ "$(count_of '_predispatch_review_if_parallel "$prnum"')" = "1" ] || fail "(1) expected exactly one review pre-dispatch callsite"
[ "$(count_of '_healthcheck_gate "$prnum"')" = "1" ]               || fail "(1) expected exactly one healthcheck gate callsite"
[ "$L_GATE" -lt "$L_REVIEW" ] || fail "(1) stale-dup gate (line $L_GATE) must precede the review pre-dispatch (line $L_REVIEW)"
[ "$L_GATE" -lt "$L_HEALTH" ] || fail "(1) stale-dup gate (line $L_GATE) must precede the healthcheck gate (line $L_HEALTH)"
ok "(1) action pass evaluates stale-dup before review pre-dispatch and healthcheck"

# ── Stubs ─────────────────────────────────────────────────────────────────────
BIN="$T/bin"; mkdir -p "$BIN"
GH_LOG="$T/gh.log"; : > "$GH_LOG"
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
[ -n "${GH_LOG:-}" ] && printf '%s\n' "$*" >> "$GH_LOG"
exit 0
STUB
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/herdr"
chmod +x "$BIN/gh" "$BIN/herdr"
export GH_LOG PATH="$BIN:$PATH"

STUB_REVIEW="$T/stub-review.sh"
cat > "$STUB_REVIEW" <<'STUB'
#!/usr/bin/env bash
if [ -n "${HERD_REVIEW_RESULT_FILE:-}" ]; then
  printf 'REVIEW: PASS\n' > "$HERD_REVIEW_RESULT_FILE.tmp.$$"
  mv "$HERD_REVIEW_RESULT_FILE.tmp.$$" "$HERD_REVIEW_RESULT_FILE"
fi
STUB
chmod +x "$STUB_REVIEW"

. "$HERE/../scripts/herd/sim/sim-notify-stub.sh" || fail "cannot source notify stub"
sim_notify_install "$T" || fail "sim_notify_install failed"

# ── Git fixture: one repo, a STALE branch and a FRESH branch off the same main ────────────────
# main:      c1(A=v1) ── c2(A=v2)          ← the merge that strands feat/stale
# feat/stale:  └─ (A=branch)               ← touches A.txt, which main moved → provable stale base
# feat/fresh:            └─ (B=new)        ← cut from main's tip → merge-base == base tip → fresh
REPO="$T/repo"
git init -q "$REPO" 2>/dev/null || fail "git init failed"
git -C "$REPO" config user.email t@t.test
git -C "$REPO" config user.name  tester
git -C "$REPO" checkout -q -b main
printf 'v1\n' > "$REPO/A.txt"; git -C "$REPO" add A.txt; git -C "$REPO" commit -qm c1
git -C "$REPO" checkout -q -b feat/stale
printf 'branch\n' > "$REPO/A.txt"; git -C "$REPO" commit -qam stale-work
STALE_SHA="$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" checkout -q main
printf 'v2\n' > "$REPO/A.txt"; git -C "$REPO" commit -qam c2
git -C "$REPO" checkout -q -b feat/fresh
printf 'new\n' > "$REPO/B.txt"; git -C "$REPO" add B.txt; git -C "$REPO" commit -qm fresh-work
FRESH_SHA="$(git -C "$REPO" rev-parse HEAD)"

# ── Source agent-watch.sh in lib mode ────────────────────────────────────────
export AGENT_WATCH_LIB=1 HERD_DRIVER=headless
export WORKTREES_DIR="$T/trees"; mkdir -p "$T/trees"
export HERD_CONFIG_FILE="$T/no-such-config"
export JOURNAL_FILE="$T/journal.jsonl"; : > "$JOURNAL_FILE"
export DEFAULT_BRANCH="main"
export GATE_DISPATCH=parallel          # so the review pre-dispatch is live, not a no-op
export REVIEW_CONCURRENCY=4
export HERD_REVIEW_BIN="$STUB_REVIEW"
# This PR carries no tracker ref → the DUPLICATE leg is skipped fail-soft; STALE BASE is the subject.
BODY="$T/pr-body.txt"; printf 'a PR body with no tracker ref\n' > "$BODY"
export HERD_STALE_DUP_BODY_FILE="$BODY"
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"

for fn in _stale_dup_gate_step stale_dup_check _predispatch_review_if_parallel _handle_stale_dup; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined after sourcing"
done
ok "(1b) _stale_dup_gate_step is lib-visible"

render() { :; }
_detect_limit_hit() { return 1; }
DISPLAY=()

# _healthcheck_gate is a ~9-min real suite; stand in for it with the one thing we assert on — the
# healthcheck_started event it journals at dispatch (agent-watch.sh: journal_append healthcheck_started).
_healthcheck_gate() {
  journal_append healthcheck_started pr "$1" slug "$2" sha "${5:-}" pid 0 log_path stub
  _HC_RESULT=CLEAN
}

# action_pass <pr#> <slug> <dir> <sha> <branch> — a faithful replay of agent-watch.sh's per-candidate
# call order, which check (1) pins to the real source. Everything expensive sits behind the gate.
action_pass() {
  local prnum="$1" slug="$2" dir="$3" candsha="$4" branch="$5" idx=0
  _stale_dup_gate_step "$prnum" "$slug" "$dir" "$candsha" "$branch" "$idx" || return 1
  _predispatch_review_if_parallel "$prnum" "$slug" "$candsha"
  _HC_RESULT=""; _healthcheck_gate "$prnum" "$slug" "$dir" "$idx" "$candsha"
  return 0
}

events() { python3 - "$JOURNAL_FILE" "$1" <<'PY'
import sys, json
want = sys.argv[2]
n = 0
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    line = line.strip()
    if not line: continue
    try: e = json.loads(line)
    except Exception: continue
    if e.get("event") == want: n += 1
print(n)
PY
}
event_order() { python3 - "$JOURNAL_FILE" <<'PY'
import sys, json
out = []
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    line = line.strip()
    if not line: continue
    try: e = json.loads(line)
    except Exception: continue
    ev = e.get("event")
    if ev in ("stale_dup_hold", "review_dispatched", "healthcheck_started"):
        out.append(ev)
print(" ".join(out))
PY
}
comments() { awk '/pr comment/{n++} END{print n+0}' "$GH_LOG" 2>/dev/null || printf '0'; }
reset_state() {
  : > "$JOURNAL_FILE"; : > "$GH_LOG"; : > "$STALE_DUP_STATE"; : > "$REFIX_STATE"
  rm -f "$TREES"/.review-* 2>/dev/null || true
  DISPLAY=(); DRYRUN=""
  unset STALE_DUP_DETECT STALE_BASE_AUTOFIX 2>/dev/null || true
}
TREES="$WORKTREES_DIR"

# ── (2) STALE BASE → HOLD, and nothing expensive is dispatched for that sha ────────────────────
reset_state
git -C "$REPO" checkout -q feat/stale
action_pass 41 stale-slug "$REPO" "$STALE_SHA" feat/stale && fail "(2) stale-base PR must HOLD"
[ "$(events stale_dup_hold)" = "1" ]      || fail "(2) expected exactly one stale_dup_hold"
[ "$(events review_dispatched)" = "0" ]   || fail "(2) a stale-base sha must dispatch NO review"
[ "$(events healthcheck_started)" = "0" ] || fail "(2) a stale-base sha must start NO healthcheck"
[ "$(event_order)" = "stale_dup_hold" ]   || fail "(2) unexpected event order: $(event_order)"
printf '%s\n' "${DISPLAY[0]:-}" | grep -q 'needs you' || fail "(2) hold must render a needs-you row (got: ${DISPLAY[0]:-})"
[ "$(comments)" -ge 1 ] || fail "(2) hold must post the once-per-sha PR comment"
ok "(2) stale-base holds before any review/healthcheck dispatch"

# ── (7) once-per-sha: a second tick re-renders but never re-comments ──────────────────────────
: > "$GH_LOG"; : > "$JOURNAL_FILE"
action_pass 41 stale-slug "$REPO" "$STALE_SHA" feat/stale && fail "(7) second tick must still HOLD"
[ "$(comments)" = "0" ]              || fail "(7) second tick must not re-comment"
[ "$(events stale_dup_hold)" = "0" ] || fail "(7) second tick must not re-journal the hold"
[ "$(events healthcheck_started)" = "0" ] || fail "(7) second tick must still dispatch nothing"
ok "(7) hold side effects stay once-per-sha across the hoist"

# ── (3) FRESH BASE → dispatches exactly as before, in the same order ──────────────────────────
reset_state
git -C "$REPO" checkout -q feat/fresh
action_pass 42 fresh-slug "$REPO" "$FRESH_SHA" feat/fresh || fail "(3) fresh-base PR must PROCEED"
[ "$(events stale_dup_hold)" = "0" ]      || fail "(3) fresh base must not hold"
[ "$(events review_dispatched)" = "1" ]   || fail "(3) fresh base must dispatch exactly one review"
[ "$(events healthcheck_started)" = "1" ] || fail "(3) fresh base must start exactly one healthcheck"
[ "$(event_order)" = "review_dispatched healthcheck_started" ] \
  || fail "(3) dispatch order changed — expected 'review_dispatched healthcheck_started', got '$(event_order)'"
[ "$(comments)" = "0" ] || fail "(3) a proceeding gate must be byte-quiet (no PR comment)"
ok "(3) fresh-base dispatch order is byte-identical"

# ── (4) STALE_DUP_DETECT=off → the stale fixture behaves exactly like the fresh one ───────────
reset_state
export STALE_DUP_DETECT=off
git -C "$REPO" checkout -q feat/stale
action_pass 43 stale-slug "$REPO" "$STALE_SHA" feat/stale || fail "(4) gate off must PROCEED"
[ "$(events stale_dup_hold)" = "0" ] || fail "(4) gate off must not hold"
[ "$(event_order)" = "review_dispatched healthcheck_started" ] \
  || fail "(4) gate off must be byte-identical to today: got '$(event_order)'"
unset STALE_DUP_DETECT
ok "(4) STALE_DUP_DETECT=off is byte-identical"

# ── (5) DRY-RUN → the gate is a strict no-op (never posts a comment) ──────────────────────────
reset_state
DRYRUN=1
_stale_dup_gate_step 44 stale-slug "$REPO" "$STALE_SHA" feat/stale 0 || fail "(5) dry-run must PROCEED"
[ "$(comments)" = "0" ]              || fail "(5) dry-run must never post a PR comment"
[ "$(events stale_dup_hold)" = "0" ] || fail "(5) dry-run must never journal a hold"
DRYRUN=""
ok "(5) dry-run gate is inert"

# ── (6) FAIL-SOFT: an evaluation error (nonzero, no kind) falls back to today's order ─────────
reset_state
_real_check="$(declare -f stale_dup_check)"
stale_dup_check() { _STALE_DUP_KIND=""; _STALE_DUP_REASON=""; return 1; }   # "error", not a proof
action_pass 45 fresh-slug "$REPO" "$FRESH_SHA" feat/fresh || fail "(6) an evaluation error must never HOLD"
[ "$(events stale_dup_hold)" = "0" ] || fail "(6) an evaluation error must not journal a hold"
[ "$(event_order)" = "review_dispatched healthcheck_started" ] \
  || fail "(6) fail-soft must fall back to today's dispatch order: got '$(event_order)'"
eval "$_real_check"
ok "(6) evaluation errors fail soft to the pre-HERD-227 order"

echo "ALL PASS ($pass checks) — gate order: stale-dup decides first (HERD-227)"
