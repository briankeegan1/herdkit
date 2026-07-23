#!/usr/bin/env bash
# test-main-health-checkout-race.sh — hermetic test for the main-health SHA-STABILITY GUARD (HERD-421).
#
# $MAIN is a SHARED checkout: the post-merge codemap/symbol-index refresh commits and rewrites files
# in it directly, which can race a concurrently-running main-health suite (live case 2026-07-22: a
# shellcheck leg reading a script the symbol-index push was mid-rewrite on, sha 46f9857). A red
# reproduced while $MAIN's HEAD moved out from under the run was never verified against a STABLE tree,
# so _main_health_worker downgrades it (rc 3, "checkout moved") instead of a confirmed red, and
# _collect_main_health journals it as an infra_event (never _main_health_set_red) — reconcile_main_health
# picks up the NEW HEAD as a fresh observed-sha on the next tick, closing the loop.
#
# Covers:
#   (a) RACE: the stub healthcheck binary advances $MAIN's HEAD (simulating a concurrent
#       symbol-index push) and reds on both the run and its retry → infra_event reason=checkout-moved,
#       NOT a MAIN RED, and the (now-stale) sha's marker is written so it is never re-dispatched.
#   (b) STABLE: an ordinary reproduced red — $MAIN's HEAD does NOT move during the run — still paints
#       MAIN RED exactly as before (byte-identical to the pre-HERD-421 guard).
#
# Sources agent-watch.sh in lib mode with HERD_HEALTHCHECK_BIN pointed at a scripted stub, mirroring
# tests/test-main-health-invariant.sh's harness. Network-free (gh stubbed for the branch-CI leg).
# Run:  bash tests/test-main-health-checkout-race.sh
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

# The stub's verdict is switched by a control file. "red-race" additionally COMMITS a new file to
# $REPO on every invocation before reporting red — standing in for a concurrent symbol-index push
# rewriting $MAIN's checkout mid-run. "red-stable" reds without ever touching $REPO.
HC="$T/hc.sh"
cat > "$HC" <<HCSTUB
#!/usr/bin/env bash
case "\$(cat "\$HC_MODE" 2>/dev/null)" in
  red-race)
    printf '%s\n' "race-\$\$-\$RANDOM" >> "$REPO/seed.txt"
    git -C "$REPO" add -A && git -C "$REPO" commit -q -m "chore: concurrent symbol-index push"
    echo "❌ code error — app/greet.test.sh → greet.test FAIL"; exit 1 ;;
  red-stable) echo "❌ code error — app/greet.test.sh → greet.test FAIL"; exit 1 ;;
  *) echo "✅ clean"; exit 0 ;;
esac
HCSTUB
chmod +x "$HC"
export HC_MODE="$T/hc-mode"; printf 'green\n' > "$HC_MODE"

BIN="$T/bin"; mkdir -p "$BIN"
cat > "$BIN/gh" <<'GHSTUB'
#!/usr/bin/env bash
case "$1 $2" in
  "run list") printf '%s\n' "${GH_RUNS:-}"; exit 0 ;;
esac
exit 0
GHSTUB
chmod +x "$BIN/gh"
export PATH="$BIN:$PATH"

export AGENT_WATCH_LIB=1 NO_COLOR=1 HERD_DRIVER=headless
export HERD_CONFIG_FILE="$T/no-such-config"
export PROJECT_ROOT="$REPO" WORKTREES_DIR="$TREES_DIR"
export JOURNAL_FILE="$T/journal.jsonl"
export HERD_HEALTHCHECK_BIN="$HC"
export DEFAULT_BRANCH=main
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"
type reconcile_main_health >/dev/null 2>&1 || fail "reconcile_main_health not defined after sourcing"

herd_driver_notify() { :; }
_main_health_scribe() { :; }

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
jcount() { local n; n="$(grep -c "$1" "$JOURNAL_FILE" 2>/dev/null)" || n=0; printf '%s' "${n:-0}"; }
reset_state() { rm -rf "$TREES_DIR"; mkdir -p "$TREES_DIR"; : > "$JOURNAL_FILE"; }

MAIN_HEALTH_TICK=on
MAIN_HEALTH_RECHECK_MINS=0
MAIN_HEALTH_AUTOFIX=off

# ── (a) RACE: $MAIN moves mid-run → infra_event(checkout-moved), never a MAIN RED ────────────────────
reset_state
_rc_sha0="$(head_sha)"
printf 'red-race\n' > "$HC_MODE"
reconcile_main_health || fail "(a) reconcile_main_health returned non-zero"
settle
[ "$(jcount '"result":"infra_event".*"reason":"checkout-moved"')" -eq 1 ] \
  || fail "(a) expected exactly one checkout-moved infra_event — journal: $(cat "$JOURNAL_FILE")"
[ "$(jcount '"result":"red"')" -eq 0 ] || fail "(a) a race-downgraded red must never paint MAIN RED"
[ ! -s "$MAIN_HEALTH_STATE" ] || fail "(a) MAIN_HEALTH_STATE must stay empty (no red was ever set)"
[ -e "$(_main_health_marker "$_rc_sha0")" ] \
  || fail "(a) the raced (now-stale) sha must still get a run-once marker so it is never re-dispatched"
ok "(a) \$MAIN moving mid-run downgrades a reproduced red to infra_event(checkout-moved), no MAIN RED"

# The NEW HEAD the race committed has no marker of its own — the next reconcile observes it fresh,
# closing the loop (exactly the cross-seat-merge path HERD-222 already guarantees).
printf 'green\n' > "$HC_MODE"
reconcile_main_health || fail "(a2) reconcile_main_health returned non-zero on the post-race HEAD"
settle
[ "$(jcount '"result":"green"')" -eq 1 ] || fail "(a2) the post-race HEAD did not reach a green verdict"
ok "(a2) the post-race HEAD is picked up fresh as a new observed-sha on the next tick"

# ── (b) STABLE: an ordinary reproduced red (HEAD unchanged) still paints MAIN RED, byte-identically ──
reset_state
printf 'red-stable\n' > "$HC_MODE"
reconcile_main_health || fail "(b) reconcile_main_health returned non-zero"
settle
[ "$(jcount '"result":"red"')" -eq 1 ] || fail "(b) a stable reproduced red must still paint MAIN RED"
[ "$(jcount '"reason":"checkout-moved"')" -eq 0 ] || fail "(b) a stable red must never be misrouted as checkout-moved"
[ -s "$MAIN_HEALTH_STATE" ] || fail "(b) MAIN_HEALTH_STATE must record the stable red"
ok "(b) a reproduced red with a STABLE \$MAIN HEAD still paints MAIN RED (byte-identical to pre-HERD-421)"

echo
echo "ALL PASS ($pass checks) — a checkout race downgrades to infra_event, never a false MAIN RED; a stable red is unaffected."
