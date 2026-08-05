#!/usr/bin/env bash
# test-main-health-autofix-claim-dedup.sh — HERD-543: MAIN_HEALTH_AUTOFIX=spawn must follow
# file-then-claim like every other spawn.
#
# Live evidence 2026-08-05: the engine auto-enqueued repair main-red-2f86b7f4-test-cli-config-sh
# while the coordinator had ALREADY claimed+spawned the same repair (HERD-538) through its own
# pick-and-spawn flow — invisible to this engine, because the spawn leg threaded the raw failing-test
# STRING as HERD_ITEM_REF instead of ever resolving/claiming the real tracker id, so herd-quick.sh's
# own later herd-claim.sh call could never see the collision. Unattended, that is a double build.
#
# Asserted here, driving the REAL functions from scripts/herd/agent-watch.sh (AGENT_WATCH_LIB=1)
# against the REAL file backend (scripts/herd/backends/file.sh) and the REAL herd-claim.sh dispatch —
# no stubbed claim/list-open, only the healthcheck binary and the two side-effecting notify/scribe
# edges are spied on, exactly as the sibling main-health tests do:
#   (a) an OPEN item ALREADY claimed by someone else, loosely matching the failing identity, is found
#       and the claim attempt comes back ALREADY — journals main_health_autofix result=dedup_claimed,
#       files NO redundant scribe item, enqueues NO builder.
#   (b) no matching OPEN item at all — byte-identical to pre-HERD-543: files the scribe item, journals
#       result=enqueued, enqueues one builder, threading the raw failing identity as its ref.
#   (c) an OPEN item loosely matching but UNCLAIMED — claimed synchronously and REUSED (no redundant
#       scribe filing), threading the newly-claimed item's own ref (not the raw identity) into the
#       spawn intent.
#   (d) CLAIM_REQUIRED=off — byte-identical: the lookup+claim never runs, even against an existing
#       claimed match, so an off project sees exactly today's behavior (AGENTS.md's
#       byte-identical-when-off invariant, proven both ways).
#
# Hermetic: a throwaway git fixture stands in for both $MAIN and the file-backend BACKLOG, the
# healthcheck binary is a stub on disk, and the notify + scribe edges are spied on (no herdr, no
# drainer, no network, no model).
# Run:  bash tests/test-main-health-autofix-claim-dedup.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../scripts/herd/agent-watch.sh"

if [ -f "$HERE/../scripts/herd/hermetic-env-scrub.sh" ]; then
  # shellcheck source=/dev/null
  . "$HERE/../scripts/herd/hermetic-env-scrub.sh"
  herd_hermetic_env_scrub "$HERE/../scripts/herd/herd-config.sh"
fi

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ pass=$((pass+1)); printf 'ok — %s\n' "$1"; }

[ -f "$WATCH" ] || fail "agent-watch.sh not found at $WATCH"
command -v git >/dev/null 2>&1 || fail "git required"

# ── fixture: a throwaway repo that plays BOTH $MAIN (health reproduction target) AND the file
# backend's BACKLOG.md (claim target) — exactly how the real system uses one PROJECT_ROOT for both. ──
REPO="$T/main"; TREES_DIR="$T/trees"; mkdir -p "$REPO" "$TREES_DIR"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name  tester
git -C "$REPO" config commit.gpgsign false
printf 'seed\n' > "$REPO/seed.txt"
printf '## Backlog\n\n' > "$REPO/BACKLOG.md"
git -C "$REPO" add -A && git -C "$REPO" commit -q -m "Merge pull request #77 from someone/branch"

HC="$T/hc.sh"
cat > "$HC" <<'HCSTUB'
#!/usr/bin/env bash
case "$(cat "$HC_MODE" 2>/dev/null)" in
  green) echo "✅ clean — all tests pass"; exit 0 ;;
  red-file) echo "❌ code error — app/greet.test.sh → greet.test FAIL"; exit 1 ;;
  *) echo "✅ clean"; exit 0 ;;
esac
HCSTUB
chmod +x "$HC"
export HC_MODE="$T/hc-mode"; printf 'green\n' > "$HC_MODE"

# ── source the real engine in lib mode, with every state path pinned into the sandbox ────────────────
export AGENT_WATCH_LIB=1 NO_COLOR=1 HERD_DRIVER=headless
export HERD_CONFIG_FILE="$T/no-such-config"
export PROJECT_ROOT="$REPO" WORKTREES_DIR="$TREES_DIR"
export JOURNAL_FILE="$T/journal.jsonl"
export HERD_HEALTHCHECK_BIN="$HC"
export DEFAULT_BRANCH=origin/main
export SCRIBE_BACKEND=file
export BACKLOG_FILE=BACKLOG.md
export HERD_REMOTE=origin
export WATCHER_OWNER=test-operator
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"
for fn in reconcile_main_health _main_health_autofix _main_health_autofix_spawn \
          _main_health_open_ref_for_identity _main_health_dedup_ref _main_health_claim_required_on; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined after sourcing"
done
case "$(_journal_file)" in "$T"/*) : ;; *) fail "journal path escapes the sandbox" ;; esac

# Spy on the two side-effecting edges — real seams the shipped code calls; replacing them keeps the
# test off the desktop and out of the scribe drainer while still proving they were (or were not)
# reached. The claim/list-open path below is DELIBERATELY left real (file.sh + herd-claim.sh) — that
# is the exact mechanism HERD-543 fixes.
NOTIFY_LOG="$T/notify.log"; : > "$NOTIFY_LOG"
SCRIBE_LOG="$T/scribe.log"; : > "$SCRIBE_LOG"
herd_driver_notify() { printf '%s\n' "$1" >> "$NOTIFY_LOG"; }
_main_health_scribe() { printf '%s\n' "$1" >> "$SCRIBE_LOG"; }

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
reset_state() {
  rm -rf "$TREES_DIR"; mkdir -p "$TREES_DIR"
  : > "$JOURNAL_FILE"; : > "$NOTIFY_LOG"; : > "$SCRIBE_LOG"
}
new_sha() {
  printf '%s\n' "$RANDOM$RANDOM" >> "$REPO/seed.txt"
  git -C "$REPO" add -A && git -C "$REPO" commit -q -m "$1"
}
seed_backlog() {
  printf '%s' "$1" > "$REPO/BACKLOG.md"
  git -C "$REPO" add -A && git -C "$REPO" commit -q -m "Backlog: $2"
}

SPAWN_Q="$TREES_DIR/spawn-queue"
spawn_reqs() { ls "$SPAWN_Q"/*.req 2>/dev/null | wc -l | tr -d ' '; }
latest_req() { ls -t "$SPAWN_Q"/*.req 2>/dev/null | sed -n '1p'; }

MAIN_HEALTH_TICK=on
MAIN_HEALTH_RECHECK_MINS=0
MAIN_HEALTH_CI_GATE=off
MAIN_HEALTH_AUTOFIX=spawn
export CLAIM_REQUIRED=on

# ── (a) an OPEN item ALREADY claimed by another operator, loosely matching the failing identity ─────
# _main_health_slug_identity("app/greet.test.sh") derives the basename token "greet.test.sh" — the
# SAME token both the slug/branch derivation and this lookup share (HERD-482's shared chokepoint).
reset_state
seed_backlog '## Backlog

🚧 Fix greet.test.sh flake (claimed by another-operator)
' "seed an already-claimed matching item"
printf 'red-file\n' > "$HC_MODE"
new_sha "feat: reds main with an already-claimed matching item"
reconcile_main_health; settle
[ "$(jcount '"event":"main_health_autofix".*"result":"dedup_claimed"')" -eq 1 ] \
  || fail "(a) an existing claimed matching item was not journaled as dedup_claimed: $(cat "$JOURNAL_FILE")"
[ "$(spawn_reqs)" -eq 0 ] || fail "(a) a builder was enqueued despite an existing claim: $(ls "$SPAWN_Q" 2>/dev/null)"
[ ! -s "$SCRIBE_LOG" ] || fail "(a) a redundant scribe item was filed despite an existing claim: $(cat "$SCRIBE_LOG")"
ok "(a) an OPEN item already claimed by another operator dedups — no scribe file, no spawn (HERD-543 double-build fix)"

# ── (b) no matching OPEN item at all — byte-identical to pre-HERD-543 ────────────────────────────────
reset_state
seed_backlog '## Backlog
' "no matching item"
printf 'red-file\n' > "$HC_MODE"
new_sha "feat: reds main with no existing matching item"
reconcile_main_health; settle
[ "$(jcount '"event":"main_health_autofix".*"result":"enqueued"')" -eq 1 ] || fail "(b) no matching item did not still file+enqueue"
[ "$(spawn_reqs)" -eq 1 ] || fail "(b) no matching item did not still spawn a builder: $(ls "$SPAWN_Q" 2>/dev/null)"
[ -s "$SCRIBE_LOG" ] || fail "(b) no matching item skipped filing the scribe item"
REQ_B="$(latest_req)"
[ "$(cat "${REQ_B%.req}.ref" 2>/dev/null)" = "app/greet.test.sh" ] \
  || fail "(b) with no existing item the spawn's ref should still be the raw failing identity: $(cat "${REQ_B%.req}.ref" 2>/dev/null)"
ok "(b) with no matching OPEN item, the spawn leg files+enqueues exactly as before HERD-543"

# ── (c) an OPEN item loosely matching but UNCLAIMED — claim it and reuse it (no duplicate filing) ───
reset_state
seed_backlog '## Backlog

🔜 Fix greet.test.sh flake (HERD-538)
' "seed an open unclaimed item"
printf 'red-file\n' > "$HC_MODE"
new_sha "feat: reds main with an open unclaimed matching item"
reconcile_main_health; settle
[ "$(jcount '"event":"main_health_autofix".*"result":"enqueued"')" -eq 1 ] || fail "(c) an existing OPEN item did not still enqueue"
[ "$(spawn_reqs)" -eq 1 ] || fail "(c) an existing OPEN item did not still spawn a builder"
[ ! -s "$SCRIBE_LOG" ] || fail "(c) a redundant scribe item was filed even though an OPEN item already matched: $(cat "$SCRIBE_LOG")"
grep -q "🚧 Fix greet.test.sh flake (HERD-538) (claimed by test-operator)" "$REPO/BACKLOG.md" \
  || fail "(c) the matched item was not claimed (flipped to in-progress, stamped): $(cat "$REPO/BACKLOG.md")"
REQ_C="$(latest_req)"
[ "$(cat "${REQ_C%.req}.ref" 2>/dev/null)" = "greet.test.sh" ] \
  || fail "(c) the spawn's ref should be the claimed item's own ref, not the raw identity: $(cat "${REQ_C%.req}.ref" 2>/dev/null)"
ok "(c) an OPEN unclaimed item loosely matching is claimed and reused — no duplicate filing, real ref threaded"

# ── (d) CLAIM_REQUIRED=off — byte-identical: the lookup+claim never runs, even against a claimed match
reset_state
export CLAIM_REQUIRED=off
seed_backlog '## Backlog

🚧 Fix greet.test.sh flake (claimed by another-operator)
' "seed a claimed item (CLAIM_REQUIRED off)"
printf 'red-file\n' > "$HC_MODE"
new_sha "feat: reds main with CLAIM_REQUIRED off"
reconcile_main_health; settle
[ "$(jcount '"event":"main_health_autofix".*"result":"enqueued"')" -eq 1 ] || fail "(d) CLAIM_REQUIRED=off did not still file+enqueue"
[ "$(spawn_reqs)" -eq 1 ] || fail "(d) CLAIM_REQUIRED=off did not still spawn a builder"
[ "$(jcount dedup_claimed)" -eq 0 ] || fail "(d) CLAIM_REQUIRED=off ran the dedup lookup anyway: $(cat "$JOURNAL_FILE")"
export CLAIM_REQUIRED=on
ok "(d) CLAIM_REQUIRED=off is byte-identical: no lookup, no claim, today's exact pre-HERD-543 behavior"

echo "ALL PASS ($pass checks)"
