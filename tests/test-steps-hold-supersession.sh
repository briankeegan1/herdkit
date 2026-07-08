#!/usr/bin/env bash
# test-steps-hold-supersession.sh — hermetic tests for the HERD-157 steps-hold-ledger fixes, driving
# the REAL scripts/herd/steps.sh + herd-approve.sh (NO mirrors — the audit flagged the mirror-test
# antipattern) against a throwaway git repo + trees dir. Covers the four fixes:
#   (1) latest-sha supersession: a push DURING a live approve-hold must not wedge approval on the dead
#       sha forever — the new sha's hold supersedes the stale one, approve targets the current commit.
#   (2) one-fire-per-(slug,sha,step): a non-approve (pass/notify) step fires ONCE per sha across the
#       watcher's repeated pre-merge re-ticks, and re-fires only when the sha changes.
#   (3) herd-approve.sh approve prints the BOUND sha, and --sha pins/refuses a superseded commit.
#   (4) merged/reaped purge: steps_hold_purge drops a slug's rows + detail files; a dir-gone release
#       REFUSES loudly (never silently bypasses sha-invalidation).
# Run:  bash tests/test-steps-hold-supersession.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ENGINE="$HERE/../scripts/herd"
STEPS="$ENGINE/steps.sh"
APPROVE="$ENGINE/herd-approve.sh"

[ -f "$STEPS" ]   || { echo "FAIL: steps.sh not found at $STEPS" >&2; exit 1; }
[ -f "$APPROVE" ] || { echo "FAIL: herd-approve.sh not found at $APPROVE" >&2; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
REPO="$T/repo"; TREES="$T/trees"; STEPS_FILE="$T/steps.tsv"; JN="$T/journal.jsonl"
NOCFG="$T/.no-config"       # a path that does NOT exist ⇒ herd-config.sh won't walk into herdkit's own
mkdir -p "$REPO" "$TREES"; : > "$JN"

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1" >&2; }
check(){ if eval "$2"; then ok "$1"; else bad "$1 — ($2)"; fi; }

HOLDS="$TREES/.agent-watch-step-holds"

# --- a real git repo so HEAD sha is real and we can create a SECOND commit (simulate a push) ---
git -C "$REPO" init -q
git -C "$REPO" config user.email t@herd.test
git -C "$REPO" config user.name  herd-test
git -C "$REPO" config commit.gpgsign false
printf 'one\n' > "$REPO/f.txt"; git -C "$REPO" add f.txt; git -C "$REPO" commit -qm one
SHA1="$(git -C "$REPO" rev-parse HEAD)"

# run_steps <seam> [extra args…] — drive real steps.sh hermetically; echoes nothing, returns its rc.
run_steps() {
  local seam="$1"; shift
  env HERD_CONFIG_FILE="$NOCFG" PROJECT_ROOT="$REPO" WORKTREES_DIR="$TREES" \
      HERD_STEPS_FILE="$STEPS_FILE" JOURNAL_FILE="$JN" NO_COLOR=1 HERD_DRIVER=headless \
      bash "$STEPS" run "$seam" "$@"
}
run_approve() {   # drive real herd-approve.sh approve; stdout captured by caller
  env HERD_CONFIG_FILE="$NOCFG" PROJECT_ROOT="$REPO" WORKTREES_DIR="$TREES" \
      HERD_STEPS_FILE="$STEPS_FILE" JOURNAL_FILE="$JN" NO_COLOR=1 HERD_DRIVER=headless \
      bash "$APPROVE" approve "$@"
}
run_release() {
  env HERD_CONFIG_FILE="$NOCFG" PROJECT_ROOT="$REPO" WORKTREES_DIR="$TREES" \
      HERD_STEPS_FILE="$STEPS_FILE" JOURNAL_FILE="$JN" NO_COLOR=1 HERD_DRIVER=headless \
      bash "$STEPS" release "$@"
}
run_purge() {
  env HERD_CONFIG_FILE="$NOCFG" PROJECT_ROOT="$REPO" WORKTREES_DIR="$TREES" \
      HERD_STEPS_FILE="$STEPS_FILE" JOURNAL_FILE="$JN" NO_COLOR=1 HERD_DRIVER=headless \
      bash "$STEPS" purge "$@"
}
awaiting_ct() { grep -c "awaiting $1" "$HOLDS" 2>/dev/null || true; }

# ══════════════════════════════════════════════════════════════════════════════════════════════════
echo "── (1) latest-sha supersession: a push during a live approve-hold must not wedge approval ──────"
# A single pre-merge hold=approve step. Hold at SHA1, then commit again (a push during the hold) so
# HEAD moves to SHA2, and re-tick (the watcher runs pre-merge fresh). BEFORE the fix, _steps_live_hold
# returned the EARLIEST awaiting (SHA1); approve targeted SHA1, and release refused (HEAD≠SHA1) FOREVER.
printf 'human-check\tpre-merge\techo human-check ran\tblock\tapprove\n' > "$STEPS_FILE"

rc=0; run_steps pre-merge --slug wedge --dir "$REPO" >/dev/null 2>&1 || rc=$?
check "first pre-merge pass HOLDS on the approve step (rc 20)" "[ '$rc' -eq 20 ]"
check "an awaiting row exists for SHA1"                        "grep -q 'awaiting wedge $SHA1 human-check' '$HOLDS'"

# Simulate a push DURING the hold: a new commit moves HEAD to SHA2.
printf 'two\n' > "$REPO/f.txt"; git -C "$REPO" commit -qam two
SHA2="$(git -C "$REPO" rev-parse HEAD)"
check "SHA moved (SHA1 != SHA2)" "[ '$SHA1' != '$SHA2' ]"

# The watcher re-ticks pre-merge fresh (no --resume-after): the step re-runs at SHA2 and re-holds,
# appending an awaiting row for SHA2. Now BOTH SHA1 and SHA2 awaiting rows are in the ledger.
rc=0; run_steps pre-merge --slug wedge --dir "$REPO" >/dev/null 2>&1 || rc=$?
check "re-tick after the push HOLDS again (rc 20)"        "[ '$rc' -eq 20 ]"
check "an awaiting row now also exists for SHA2"          "grep -q 'awaiting wedge $SHA2 human-check' '$HOLDS'"

# THE FIX: the live hold is the LATEST sha (SHA2), not the stale SHA1. approve prints SHA2 and release
# succeeds (HEAD==SHA2). Before the fix this whole sequence wedged: approve→SHA1, release→refuse.
approve_out="$(run_approve wedge 2>&1)"; arc=$?
check "approve succeeds (rc 0) after the supersession"   "[ '$arc' -eq 0 ]"
check "approve BOUND + PRINTED the CURRENT sha (SHA2)"   "printf '%s' \"\$approve_out\" | grep -q '$SHA2'"
check "approve did NOT bind the stale sha (SHA1)"        "! printf '%s' \"\$approve_out\" | grep -q '$SHA1'"
check "the CURRENT sha (SHA2) is released"               "grep -q 'released wedge $SHA2 human-check' '$HOLDS'"
check "the stale sha (SHA1) was never released/wedged"   "! grep -q 'released wedge $SHA1 human-check' '$HOLDS'"
# After releasing the only step, a fresh re-tick proceeds (rc 0 ⇒ the merge would go through).
rc=0; run_steps pre-merge --slug wedge --dir "$REPO" >/dev/null 2>&1 || rc=$?
check "post-approval re-tick returns 0 (pipeline unwedged)" "[ '$rc' -eq 0 ]"

# ══════════════════════════════════════════════════════════════════════════════════════════════════
echo "── (2) non-approve steps fire ONCE per (slug,sha,step) across repeated pre-merge re-ticks ──────"
JN2="$T/journal2.jsonl"; : > "$JN2"
TREES2="$T/trees2"; mkdir -p "$TREES2"
STEPS2="$T/steps2.tsv"
PASSCT="$T/passct"; NOTIFYCT="$T/notifyct"; : > "$PASSCT"; : > "$NOTIFYCT"
{
  printf 'ping\tpre-merge\tprintf p >> %s\tblock\tnone\n'   "$PASSCT"
  printf 'notify-me\tpre-merge\tprintf n >> %s\twarn\tnotify\n' "$NOTIFYCT"
} > "$STEPS2"
run2() {
  env HERD_CONFIG_FILE="$NOCFG" PROJECT_ROOT="$REPO" WORKTREES_DIR="$TREES2" \
      HERD_STEPS_FILE="$STEPS2" JOURNAL_FILE="$JN2" NO_COLOR=1 HERD_DRIVER=headless \
      bash "$STEPS" run pre-merge --slug memo --dir "$REPO" >/dev/null 2>&1
}
# Three re-ticks at the SAME sha (SHA2). The pass step + notify step must each execute exactly once.
run2; run2; run2
check "pass step executed exactly ONCE across 3 ticks"   "[ \"\$(wc -c < '$PASSCT'   | tr -d ' ')\" = 1 ]"
check "notify step executed exactly ONCE across 3 ticks" "[ \"\$(wc -c < '$NOTIFYCT' | tr -d ' ')\" = 1 ]"
check "exactly ONE step_hold_notify journaled"           "[ \"\$(grep -c 'step_hold_notify' '$JN2')\" = 1 ]"
check "exactly ONE ping step_run pass journaled"         "[ \"\$(grep -c '\"name\":\"ping\".*\"outcome\":\"pass\"' '$JN2')\" = 1 ]"

# A NEW commit (sha changes) legitimately RE-FIRES both steps (memo is per-sha).
printf 'three\n' > "$REPO/f.txt"; git -C "$REPO" commit -qam three
run2
check "pass step re-fires on a new sha (count now 2)"    "[ \"\$(wc -c < '$PASSCT'   | tr -d ' ')\" = 2 ]"
check "notify step re-fires on a new sha (count now 2)"  "[ \"\$(wc -c < '$NOTIFYCT' | tr -d ' ')\" = 2 ]"

# ══════════════════════════════════════════════════════════════════════════════════════════════════
echo "── (3) herd-approve.sh --sha pins the approval; a superseded sha is REFUSED ────────────────────"
# Fresh slug/trees so the ledger is clean; hold at the repo's current HEAD.
JN3="$T/journal3.jsonl"; : > "$JN3"
TREES3="$T/trees3"; mkdir -p "$TREES3"
STEPS3="$T/steps3.tsv"
printf 'human-check\tpre-merge\techo ran\tblock\tapprove\n' > "$STEPS3"
approve3_env() { env HERD_CONFIG_FILE="$NOCFG" PROJECT_ROOT="$REPO" WORKTREES_DIR="$TREES3" \
      HERD_STEPS_FILE="$STEPS3" JOURNAL_FILE="$JN3" NO_COLOR=1 HERD_DRIVER=headless "$@"; }
HOLDS3="$TREES3/.agent-watch-step-holds"
CURSHA="$(git -C "$REPO" rev-parse HEAD)"
rc=0; approve3_env bash "$STEPS" run pre-merge --slug pin --dir "$REPO" >/dev/null 2>&1 || rc=$?
check "pin: pre-merge holds (rc 20)" "[ '$rc' -eq 20 ]"

# Wrong --sha ⇒ refuse, record NOTHING (no approved row).
badsha="0000000000000000000000000000000000000000"
prc=0; pinbad="$(approve3_env bash "$APPROVE" approve pin --sha "$badsha" 2>&1)" || prc=$?
check "--sha mismatch REFUSES (non-zero rc)"        "[ '$prc' -ne 0 ]"
check "--sha mismatch prints a refusal"             "printf '%s' \"\$pinbad\" | grep -qi 'Refusing'"
check "--sha mismatch recorded NO approval"         "! grep -q 'approved pin' '$HOLDS3'"

# Correct full --sha ⇒ approves (consumes the hold) + prints the bound (full) sha.
grc=0; pinok="$(approve3_env bash "$APPROVE" approve pin --sha "$CURSHA" 2>&1)" || grc=$?
check "--sha full match approves (rc 0)"            "[ '$grc' -eq 0 ]"
check "matched approve prints the full bound sha"   "printf '%s' \"\$pinok\" | grep -q '$CURSHA'"
check "matched approve recorded the approval"       "grep -q 'approved pin $CURSHA human-check' '$HOLDS3'"

# A short PREFIX (what `list` shows as sha:XXXXXXXX) is also accepted — fresh slug so the hold is live.
rc=0; approve3_env bash "$STEPS" run pre-merge --slug pin2 --dir "$REPO" >/dev/null 2>&1 || rc=$?
check "pin2: pre-merge holds (rc 20)" "[ '$rc' -eq 20 ]"
SHORT="${CURSHA:0:8}"
prc2=0; approve3_env bash "$APPROVE" approve pin2 --sha "$SHORT" >/dev/null 2>&1 || prc2=$?
check "--sha 8-char PREFIX is accepted (rc 0)"      "[ '$prc2' -eq 0 ]"
check "prefix approve recorded the approval"        "grep -q 'approved pin2 $CURSHA human-check' '$HOLDS3'"

# ══════════════════════════════════════════════════════════════════════════════════════════════════
echo "── (4) merged/reaped purge + dir-gone release refusal ─────────────────────────────────────────"
# 4a: steps_hold_purge drops every ledger row for a slug and removes its per-step detail files.
JN4="$T/journal4.jsonl"; : > "$JN4"
TREES4="$T/trees4"; mkdir -p "$TREES4"
STEPS4="$T/steps4.tsv"
printf 'human-check\tpre-merge\techo ran\tblock\tapprove\n' > "$STEPS4"
purge_env() { env HERD_CONFIG_FILE="$NOCFG" PROJECT_ROOT="$REPO" WORKTREES_DIR="$TREES4" \
      HERD_STEPS_FILE="$STEPS4" JOURNAL_FILE="$JN4" NO_COLOR=1 HERD_DRIVER=headless "$@"; }
HOLDS4="$TREES4/.agent-watch-step-holds"
rc=0; purge_env bash "$STEPS" run pre-merge --slug gone --dir "$REPO" >/dev/null 2>&1 || rc=$?
DETAIL4="$TREES4/.agent-watch-step-hold-gone-human-check"
check "purge setup: hold recorded"          "grep -q 'awaiting gone' '$HOLDS4'"
check "purge setup: detail file exists"      "[ -f '$DETAIL4' ]"
# Also seed a sibling slug that shares a name prefix — it must NOT be clobbered by the purge.
printf '%s awaiting gone-sibling %s sib\n' 111 "$SHA1" >> "$HOLDS4"
: > "$TREES4/.agent-watch-step-hold-gone-sibling-sib"
purge_env bash "$STEPS" purge gone >/dev/null 2>&1
check "purge dropped every 'gone' ledger row"        "! grep -q ' gone ' '$HOLDS4'"
check "purge removed the 'gone' detail file"          "[ ! -f '$DETAIL4' ]"
check "purge kept the sibling slug's ledger row"      "grep -q 'gone-sibling' '$HOLDS4'"
check "purge kept the sibling slug's detail file"     "[ -f '$TREES4/.agent-watch-step-hold-gone-sibling-sib' ]"

# 4b: a dir-gone release must REFUSE loudly, never silently bypass sha-invalidation.
JN5="$T/journal5.jsonl"; : > "$JN5"
TREES5="$T/trees5"; mkdir -p "$TREES5"
STEPS5="$T/steps5.tsv"
printf 'human-check\tpre-merge\techo ran\tblock\tapprove\n' > "$STEPS5"
GONEREPO="$T/gone-repo"
git -C "$T" init -q gone-repo
git -C "$GONEREPO" config user.email t@herd.test; git -C "$GONEREPO" config user.name herd-test
git -C "$GONEREPO" config commit.gpgsign false
printf 'x\n' > "$GONEREPO/f.txt"; git -C "$GONEREPO" add f.txt; git -C "$GONEREPO" commit -qm x
dg_env() { env HERD_CONFIG_FILE="$NOCFG" PROJECT_ROOT="$GONEREPO" WORKTREES_DIR="$TREES5" \
      HERD_STEPS_FILE="$STEPS5" JOURNAL_FILE="$JN5" NO_COLOR=1 HERD_DRIVER=headless "$@"; }
rc=0; dg_env bash "$STEPS" run pre-merge --slug dgone --dir "$GONEREPO" >/dev/null 2>&1 || rc=$?
check "dir-gone setup: held (rc 20)" "[ '$rc' -eq 20 ]"
dg_env bash "$APPROVE" approve dgone >/dev/null 2>&1 || true   # approve is fine; release is where dir is checked
# Now the worktree VANISHES (merged/reaped) and we attempt a release directly.
rm -rf "$GONEREPO"
drc=0; dgout="$(dg_env bash "$STEPS" release dgone 2>&1)" || drc=$?
check "dir-gone release REFUSES (non-zero rc)"   "[ '$drc' -ne 0 ]"
check "dir-gone release says the worktree is gone" "printf '%s' \"\$dgout\" | grep -qi 'gone'"

# ══════════════════════════════════════════════════════════════════════════════════════════════════
echo
if [ "$fail" -eq 0 ]; then
  echo "✅ test-steps-hold-supersession: all $pass checks passed."
  exit 0
else
  echo "❌ test-steps-hold-supersession: $fail failed, $pass passed." >&2
  exit 1
fi
