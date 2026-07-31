#!/usr/bin/env bash
# test-checkout-guard.sh — hermetic tests for HERD-452: guard the shared main checkout ($MAIN) from
# contamination and stop mislabeling MAIN RED.
#
# GROUNDED incident (2026-07-31): $MAIN was found detached at #563's branch head, and the main-health
# suite — which ran the heavy suite DIRECTLY inside the live $MAIN working tree, unlike the sandboxed
# baseline-vs-candidate leg (HERD-361) — reproduced a red off that FEATURE branch's own code and
# labeled it 'MAIN RED', training the operator to ignore a standing alarm that named nothing true about
# the default branch.
#
# Three deliverables, proven here:
#   PART 1 — ROOT CAUSE: _main_health_worker now ALWAYS runs the heavy suite in a DISPOSABLE detached
#            worktree pinned to the dispatched sha, never live inside $MAIN — so nothing the suite does
#            (stage, stash, or `git checkout` something else in $PWD) can mutate the shared checkout.
#   PART 2 — THE ALARM MUST NOT LIE: _main_health_dispatch asserts $MAIN is ATTACHED to the default
#            branch with no foreign contamination BEFORE every dispatch; unsound → the attempt is
#            WITHHELD (no worker, no marker, no verdict — ever) and journaled as result=contaminated.
#   PART 3 — AUTO-HEAL (CHECKOUT_GUARD, default off, on in herdkit's own dogfood config): a
#            detached-AND-CLEAN $MAIN is auto-restored (plain `git checkout <default>`, journaled,
#            CHECKOUT UNCLEAN row cleared); a DIRTY $MAIN is NEVER auto-touched, no matter the lever;
#            with the lever off, behavior is byte-identical to pre-HERD-452.
#
# Fully hermetic: real local git repos under a mktemp dir, gh/herdr stubbed, no network/model.
# Run:  bash tests/test-checkout-guard.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../scripts/herd/agent-watch.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ pass=$((pass+1)); printf 'ok — %s\n' "$1"; }

[ -f "$WATCH" ] || fail "agent-watch.sh not found at $WATCH"
command -v git >/dev/null 2>&1 || fail "git required"

REPO="$T/main"; TREES_DIR="$T/trees"; mkdir -p "$REPO" "$TREES_DIR"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name  tester
printf 'seed\n' > "$REPO/seed.txt"
git -C "$REPO" add -A && git -C "$REPO" commit -q -m "Merge pull request #77 from someone/branch"

BIN="$T/bin"; mkdir -p "$BIN"
cat > "$BIN/gh" <<'GHSTUB'
#!/usr/bin/env bash
case "$1 $2" in
  "run list") printf '%s\n' "${GH_RUNS:-}"; exit 0 ;;
esac
exit 0
GHSTUB
chmod +x "$BIN/gh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/herdr"; chmod +x "$BIN/herdr"
export PATH="$BIN:$PATH"

export AGENT_WATCH_LIB=1 NO_COLOR=1 HERD_DRIVER=headless
export HERD_CONFIG_FILE="$T/no-such-config"
export PROJECT_ROOT="$REPO" WORKTREES_DIR="$TREES_DIR"
export JOURNAL_FILE="$T/journal.jsonl"
export DEFAULT_BRANCH=main
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"
for fn in _main_health_worker _main_health_dispatch _main_checkout_sound _main_health_contaminated \
          reconcile_main_health reconcile_checkout_cleanliness _checkout_guard_enabled _checkout_guard_heal; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined after sourcing agent-watch.sh"
done

herd_driver_notify() { :; }
_main_health_scribe() { :; }

jcount() { local n; n="$(grep -c "$1" "$JOURNAL_FILE" 2>/dev/null)" || n=0; printf '%s' "${n:-0}"; }
head_sha() { git -C "$REPO" rev-parse HEAD; }
settle() {
  local n=0
  while [ "$n" -lt 400 ]; do
    ls "$TREES_DIR"/.health-dispatch-main-* >/dev/null 2>&1 && break
    ls "$TREES_DIR"/.health-inflight-main-* >/dev/null 2>&1 || break
    sleep 0.05; n=$((n + 1))
  done
  _collect_main_health
}
reset_state() {
  rm -rf "$TREES_DIR"; mkdir -p "$TREES_DIR"; : > "$JOURNAL_FILE"
  CHECKOUT_CLEAN_STATE="$TREES_DIR/.agent-watch-checkout-clean"
  CHECKOUT_CLEAN_PENDING="$TREES_DIR/.agent-watch-checkout-clean.pending"
}
HERD_REMOTE=origin; HERD_BRANCH_NAME=main
MAIN="$REPO"
MAIN_HEALTH_TICK=on
MAIN_HEALTH_RECHECK_MINS=0
MAIN_HEALTH_AUTOFIX=off
CHECKOUT_GUARD=off

# ════════════════════════════════════════════════════════════════════════════════════════════════
# PART 1 — the suite runs in a DISPOSABLE worktree, never live inside $MAIN
# ════════════════════════════════════════════════════════════════════════════════════════════════
# A stub healthcheck binary that RECORDS the dir it was invoked with and tries to CONTAMINATE it
# (checks it out detached, stages a new file) — models a suite test with a filesystem/git side-effect
# bug, the #563 incident's shape. Pre-fix this ran with $1 == the live $MAIN; post-fix $1 is a
# throwaway worktree, so the contamination never reaches $MAIN.
HC1="$T/hc-contaminate.sh"
cat > "$HC1" <<'HCSTUB'
#!/usr/bin/env bash
echo "$1" >> "$HC_ARG_LOG"
git -C "$1" checkout -q --detach HEAD >/dev/null 2>&1 || true
printf 'contaminant\n' > "$1/contaminant.txt" 2>/dev/null || true
git -C "$1" add -A >/dev/null 2>&1 || true
echo "✅ clean"; exit 0
HCSTUB
chmod +x "$HC1"
export HC_ARG_LOG="$T/hc-arg.log"; : > "$HC_ARG_LOG"

reset_state
export HERD_HEALTHCHECK_BIN="$HC1"
_MAIN_STATUS_BEFORE="$(git -C "$REPO" status --porcelain)"
_MAIN_HEAD_BEFORE="$(head_sha)"
[ -z "$_MAIN_STATUS_BEFORE" ] || fail "(1) fixture: \$MAIN must start clean"

reconcile_main_health || fail "(1) reconcile_main_health returned non-zero"
settle

_MAIN_STATUS_AFTER="$(git -C "$REPO" status --porcelain)"
_MAIN_HEAD_AFTER="$(head_sha)"

# ── (1a) the suite ACTUALLY ran (proves the sandbox isn't just skipping the run) ──────────────────
[ -s "$HC_ARG_LOG" ] || fail "(1a) the stub healthcheck binary never ran"
_HC_ARG1="$(sed -n '1p' "$HC_ARG_LOG")"
[ -n "$_HC_ARG1" ] || fail "(1a) the stub's \$1 was empty"
ok "(1a) the main-health suite ran"

# ── (1b) the suite was invoked with a DIFFERENT dir than \$MAIN itself ─────────────────────────────
[ "$_HC_ARG1" != "$REPO" ] || fail "(1b) the suite ran with \$1 == \$MAIN — NOT sandboxed"
ok "(1b) the suite was invoked against a disposable dir, not \$MAIN itself"

# ── (1c) \$MAIN is BYTE-IDENTICAL: clean before == clean after, HEAD unmoved, no leaked file ────────
[ -z "$_MAIN_STATUS_AFTER" ] || fail "(1c) \$MAIN was CONTAMINATED — git status now: [$_MAIN_STATUS_AFTER]"
[ "$_MAIN_HEAD_BEFORE" = "$_MAIN_HEAD_AFTER" ] || fail "(1c) \$MAIN HEAD moved ($_MAIN_HEAD_BEFORE -> $_MAIN_HEAD_AFTER)"
[ ! -e "$REPO/contaminant.txt" ] || fail "(1c) the stub's contaminant.txt leaked into \$MAIN"
ok "(1c) \$MAIN stays byte-identical even though the suite tried to contaminate its own working dir"

# ── (1d) the disposable worktree was cleaned up (no leak in \$MAIN's worktree registry or on disk) ─
[ ! -e "$_HC_ARG1" ] || fail "(1d) the disposable worktree dir was not removed: $_HC_ARG1"
_WT_LIST="$(git -C "$REPO" worktree list --porcelain 2>/dev/null | grep -c '^worktree ')"
[ "$_WT_LIST" -eq 1 ] || fail "(1d) \$MAIN's worktree registry leaked an entry (expected 1, got $_WT_LIST)"
ok "(1d) the disposable worktree is fully cleaned up after the run"

# ── (1e) a REPRODUCED red is still reported honestly from the sandboxed run ────────────────────────
HC2="$T/hc-red.sh"
cat > "$HC2" <<'HCSTUB'
#!/usr/bin/env bash
printf '1..1\nnot ok 1 deliberate-fail\n'; exit 1
HCSTUB
chmod +x "$HC2"
reset_state
export HERD_HEALTHCHECK_BIN="$HC2"
reconcile_main_health || fail "(1e) reconcile_main_health returned non-zero"
settle
[ "$(jcount 'result":"red"')" -eq 1 ] || fail "(1e) a reproduced red in the sandboxed worktree must still paint MAIN RED: $(cat "$JOURNAL_FILE")"
[ -s "$MAIN_HEALTH_STATE" ] || fail "(1e) MAIN_HEALTH_STATE must record the sandboxed red"
ok "(1e) a genuine red is still faithfully reported from the sandboxed worktree"

# ════════════════════════════════════════════════════════════════════════════════════════════════
# PART 2 — THE ALARM MUST NOT LIE: no verdict is ever emitted off an unsound checkout
# ════════════════════════════════════════════════════════════════════════════════════════════════
HCG="$T/hc-green.sh"
cat > "$HCG" <<'HCSTUB'
#!/usr/bin/env bash
echo "✅ clean"; exit 0
HCSTUB
chmod +x "$HCG"
export HERD_HEALTHCHECK_BIN="$HCG"

# ── (2a) DETACHED at a foreign (feature-branch) sha → NO verdict, contaminated is journaled ───────
reset_state
git -C "$REPO" checkout -q -b feature-563
printf 'feature work\n' > "$REPO/feature.txt"; git -C "$REPO" add -A
git -C "$REPO" commit -q -m "feature commit (models PR #563)"
_FEATURE_SHA="$(head_sha)"
git -C "$REPO" checkout -q --detach "$_FEATURE_SHA"   # $MAIN detached at the feature head
git -C "$REPO" branch -q -D feature-563 2>/dev/null || true

reconcile_main_health || fail "(2a) reconcile_main_health returned non-zero"
ls "$TREES_DIR"/.health-dispatch-main-* >/dev/null 2>&1 && fail "(2a) a worker was dispatched off a DETACHED checkout"
[ ! -s "$MAIN_HEALTH_STATE" ] || fail "(2a) a verdict was emitted off a DETACHED checkout"
[ "$(jcount '"result":"contaminated".*"reason":"detached"')" -eq 1 ] \
  || fail "(2a) expected one contaminated/detached journal line: $(cat "$JOURNAL_FILE")"
ok "(2a) a checkout detached at a feature-branch sha withholds any main-health verdict"

# ── (2b) a SECOND reconcile on the SAME detached state does not re-journal (dedup) ────────────────
reconcile_main_health || fail "(2b) reconcile_main_health returned non-zero"
[ "$(jcount '"result":"contaminated"')" -eq 1 ] || fail "(2b) the contaminated withhold must journal ONCE while unchanged: $(cat "$JOURNAL_FILE")"
ok "(2b) the withheld-verdict journal is deduped across ticks"

# ── (2c) DIRTY (attached, but a tracked file modified) → NO verdict, reason=dirty ──────────────────
reset_state
git -C "$REPO" checkout -q main
printf 'dirty edit\n' > "$REPO/seed.txt"
reconcile_main_health || fail "(2c) reconcile_main_health returned non-zero"
ls "$TREES_DIR"/.health-dispatch-main-* >/dev/null 2>&1 && fail "(2c) a worker was dispatched off a DIRTY checkout"
[ ! -s "$MAIN_HEALTH_STATE" ] || fail "(2c) a verdict was emitted off a DIRTY checkout"
[ "$(jcount '"result":"contaminated".*"reason":"dirty"')" -eq 1 ] \
  || fail "(2c) expected one contaminated/dirty journal line: $(cat "$JOURNAL_FILE")"
git -C "$REPO" checkout -q -- seed.txt
ok "(2c) a checkout with foreign uncommitted contamination withholds any main-health verdict too"

# ── (2d) SELF-HEALS the moment the checkout is sound again — the very next reconcile dispatches ────
reconcile_main_health || fail "(2d) reconcile_main_health returned non-zero"
settle
[ "$(jcount '"result":"green"')" -eq 1 ] || fail "(2d) a now-sound checkout did not reach a green verdict: $(cat "$JOURNAL_FILE")"
ok "(2d) the moment \$MAIN is attached and clean again, the very next tick dispatches normally"

# ════════════════════════════════════════════════════════════════════════════════════════════════
# PART 3 — CHECKOUT_GUARD auto-heal (default off; on in herdkit's own dogfood .herd/config)
# ════════════════════════════════════════════════════════════════════════════════════════════════
BIN2="$T/bin2"; mkdir -p "$BIN2"
for cmd in gh herdr; do printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN2/$cmd"; chmod +x "$BIN2/$cmd"; done
SCRIBE_BACKEND=file; BACKLOG_FILE=BACKLOG.md

new_ck_main() {   # a clean committed repo on 'main', standing in for a fresh $MAIN fixture
  MAIN="$T/ckmain-$1"; mkdir -p "$MAIN/docs"
  git -C "$MAIN" init -q
  git -C "$MAIN" checkout -q -B main
  git -C "$MAIN" config user.email t@t.test; git -C "$MAIN" config user.name tester
  printf 'code v1\n' > "$MAIN/lib.sh"
  printf 'backlog v1\n' > "$MAIN/BACKLOG.md"
  git -C "$MAIN" add -A; git -C "$MAIN" commit -q -m init
  reset_state
}
tick() { local _n="${1:-1}"; while [ "$_n" -gt 0 ]; do reconcile_checkout_cleanliness; _n=$((_n - 1)); done; }

# ── (3a) guard OFF (default): a detached-and-clean \$MAIN is UNTOUCHED — byte-identical to pre-HERD-452 ─
CHECKOUT_GUARD=off
new_ck_main a
_CK_HEAD_BEFORE="$(git -C "$MAIN" rev-parse HEAD)"
git -C "$MAIN" checkout -q --detach HEAD
tick 2
[ -s "$CHECKOUT_CLEAN_STATE" ] || fail "(3a) guard off: a detached checkout must still raise the ordinary HERD-361 violation"
[ "$(git -C "$MAIN" symbolic-ref --quiet --short HEAD 2>/dev/null || true)" = "" ] \
  || fail "(3a) guard off: \$MAIN must NOT have been reattached"
[ "$(git -C "$MAIN" rev-parse HEAD)" = "$_CK_HEAD_BEFORE" ] || fail "(3a) guard off: \$MAIN's HEAD sha must be unchanged"
[ "$(jcount checkout_guard)" = "0" ] || fail "(3a) guard off: checkout_guard must never journal: $(cat "$JOURNAL_FILE")"
ok "(3a) CHECKOUT_GUARD=off leaves a detached-and-clean \$MAIN untouched (byte-identical)"

# ── (3b) guard ON + detached-and-CLEAN → auto-RESTORED, journaled, row cleared same tick ───────────
CHECKOUT_GUARD=on
new_ck_main b
git -C "$MAIN" checkout -q --detach HEAD
reconcile_checkout_cleanliness
[ "$(git -C "$MAIN" symbolic-ref --quiet --short HEAD 2>/dev/null || true)" = "main" ] \
  || fail "(3b) guard on: a detached-clean \$MAIN must be RESTORED to main on the very first tick"
[ ! -e "$CHECKOUT_CLEAN_STATE" ] && [ ! -e "$CHECKOUT_CLEAN_PENDING" ] \
  || fail "(3b) guard on: the restore must clear (never even paint) the CHECKOUT UNCLEAN row"
[ "$(jcount '"event":"checkout_guard","result":"restored"')" = "1" ] || fail "(3b) guard on: expected one checkout_guard restored line: $(cat "$JOURNAL_FILE")"
build_checkout_cleanliness
[ -z "${CHECKOUT_CLEAN:-}" ] || fail "(3b) guard on: the row must render EMPTY after a successful auto-restore"
ok "(3b) CHECKOUT_GUARD=on auto-restores a detached-and-clean \$MAIN, journals it, and the row never paints"

# ── (3c) guard ON + detached-and-DIRTY → NEVER auto-touched, still surfaced for a human ────────────
new_ck_main c
git -C "$MAIN" checkout -q --detach HEAD
printf 'contaminated\n' > "$MAIN/lib.sh"; git -C "$MAIN" add -A     # tracked contamination
_CK_HEAD_C="$(git -C "$MAIN" rev-parse HEAD)"
tick 2
[ "$(git -C "$MAIN" symbolic-ref --quiet --short HEAD 2>/dev/null || true)" = "" ] \
  || fail "(3c) guard on: a DIRTY checkout must NEVER be auto-reattached"
[ "$(git -C "$MAIN" rev-parse HEAD)" = "$_CK_HEAD_C" ] || fail "(3c) guard on: a DIRTY checkout's HEAD must be untouched"
[ -n "$(git -C "$MAIN" diff --cached --name-only)" ] || fail "(3c) guard on: the staged contamination must be PRESERVED, never discarded"
[ -s "$CHECKOUT_CLEAN_STATE" ] || fail "(3c) guard on: the dirty+detached state must still be surfaced as a violation"
[ "$(jcount checkout_guard)" = "0" ] || fail "(3c) guard on: a dirty checkout must never journal checkout_guard: $(cat "$JOURNAL_FILE")"
ok "(3c) CHECKOUT_GUARD=on NEVER auto-touches a dirty checkout — evidence stays for a human"

# ── (3d) guard ON + already attached and clean → byte-quiet no-op (nothing to heal) ────────────────
new_ck_main d
reconcile_checkout_cleanliness
[ ! -e "$CHECKOUT_CLEAN_STATE" ] || fail "(3d) guard on: a clean attached checkout must render no state file"
[ "$(jcount checkout_guard)" = "0" ] || fail "(3d) guard on: a clean attached checkout must never journal checkout_guard"
ok "(3d) CHECKOUT_GUARD=on is a no-op on an already-sound checkout"

echo
echo "ALL PASS ($pass checks) — main-health sandboxes its suite, never lies about a contaminated checkout, and CHECKOUT_GUARD auto-heals only what is provably safe."
