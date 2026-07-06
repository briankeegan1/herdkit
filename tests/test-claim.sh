#!/usr/bin/env bash
# test-claim.sh — hermetic test of atomic work-item claiming (HERD-50): the lane-facing orchestrator
# scripts/herd/herd-claim.sh (herd_claim_or_abort) and the file backend's _backend_claim_item op,
# driven against REAL local bare-remote git repos (no network, no herdr, no claude, no worktrees).
#
# Covers the four required scenarios plus the lane return-code contract:
#   • claim-wins            — an open item is claimed (state flips 🔜→🚧, stamped + pushed) → CLAIMED
#   • claim-loses-abort     — an item already claimed by another operator → ALREADY (lane aborts)
#   • no-id passthrough     — no HERD_CLAIM_ID/HERD_ITEM_REF → claim skipped, lane proceeds (rc 0)
#   • backend-down passthrough — backend unreachable/no-claim-op → fail soft, lane proceeds (rc 0)
# Run:  bash tests/test-claim.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CLAIM_SH="$ROOT/scripts/herd/herd-claim.sh"
FILE_BACKEND="$ROOT/scripts/herd/backends/file.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass(){ PASS=$((PASS+1)); }

# Isolate git from any ambient user config so commits succeed deterministically.
export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_SYSTEM=/dev/null
git config --file "$T/gitconfig" user.email "test@herd.local"
git config --file "$T/gitconfig" user.name  "herd test"
git config --file "$T/gitconfig" init.defaultBranch main
git config --file "$T/gitconfig" commit.gpgsign false

# A bare "origin" (id $1) seeded with a BACKLOG holding two open (🔜) items. Idempotent per id, so a
# claim that pushes to one origin never bleeds into another scenario's items.
seed_origin() {
  local id="$1"
  local og="$T/$id.git"
  [ -d "$og" ] && return 0
  git init -q --bare "$og"
  git clone -q "$og" "$T/seed-$id"
  ( cd "$T/seed-$id"
    git checkout -q -b main
    printf '## Backlog\n\n🔜 item-a — the item under test\n🔜 item-b — a second queued item\n' > BACKLOG.md
    git add BACKLOG.md && git commit -q -m "seed backlog"
    git push -q -u origin main )
  rm -rf "$T/seed-$id"
}
clone_from() { git clone -q "$T/$1.git" "$2"; }   # $1 = origin id, $2 = dest working dir

# Run the file backend's claim op inside a clone, printing "RESULT<TAB>OWNER".
run_file_claim() {
  local dir="$1" ref="$2" who="$3"
  ( cd "$dir"
    export BACKLOG_FILE="BACKLOG.md" DEFAULT_BRANCH="origin/main" HERD_REMOTE="origin" HERD_BRANCH_NAME="main"
    . "$FILE_BACKEND"
    _CLAIM_RESULT=""; _CLAIM_OWNER=""
    _backend_claim_item "$ref" "$who"
    printf '%s\t%s\n' "${_CLAIM_RESULT:-}" "${_CLAIM_OWNER:-}" )
}

# ── 1. claim-wins: a fresh clone claims the open item ───────────────────────────────────────────────
seed_origin win; clone_from win "$T/alice"
out="$(run_file_claim "$T/alice" "repo#item-a" alice)"
echo "$out" | grep -q "^CLAIMED	alice$" || fail "claim-wins: expected 'CLAIMED alice', got '$out'"
grep -q "🚧 item-a.*(claimed by alice)" "$T/alice/BACKLOG.md" || fail "claim-wins: line not flipped to 🚧 + stamped ($(grep item-a "$T/alice/BACKLOG.md"))"
grep -q "🔜 item-a" "$T/alice/BACKLOG.md" && fail "claim-wins: item still shows 🔜 (not flipped)"
[ "$(cd "$T/alice" && git rev-parse main)" = "$(cd "$T/alice" && git rev-parse origin/main)" ] \
  || fail "claim-wins: claim commit was not pushed to origin"
pass

# The OTHER open item is untouched (a claim flips exactly one line).
grep -q "🔜 item-b" "$T/alice/BACKLOG.md" || fail "claim-wins: unrelated open item should remain 🔜"
pass

# ── 2. self-claim: re-claiming our OWN in-progress item is a no-op proceed (SELF) ────────────────────
out="$(run_file_claim "$T/alice" "repo#item-a" alice)"
echo "$out" | grep -q "^SELF	alice$" || fail "self-claim: alice re-claiming her own item should be SELF, got '$out'"
pass

# ── 3. missing item → UNREACHABLE (fail soft; nothing to claim) ──────────────────────────────────────
out="$(run_file_claim "$T/alice" "repo#no-such-slug" alice)"
echo "$out" | grep -q "^UNREACHABLE" || fail "missing item should be UNREACHABLE, got '$out'"
pass

# ── 4. claim-loses-abort (real remote race): bob's claim landed first; alice must back off ──────────
# Both clone the SAME origin at the same tip; bob claims + pushes, then alice's backend sync-pull
# surfaces the competing claim and she resolves ALREADY without stamping her own identity.
seed_origin race; clone_from race "$T/race_alice"; clone_from race "$T/race_bob"
run_file_claim "$T/race_bob" "repo#item-a" bob >/dev/null
out="$(run_file_claim "$T/race_alice" "repo#item-a" alice)"
echo "$out" | grep -q "^ALREADY	bob$" || fail "claim-loses (race): alice should see ALREADY owned by bob, got '$out'"
grep -q "(claimed by alice)" "$T/race_alice/BACKLOG.md" && fail "claim-loses (race): alice must NOT stamp her own claim over bob's"
pass

# ── 5. claim-loses-abort (already in-progress): a pre-claimed 🚧 line is never re-flipped ────────────
seed_origin pre; clone_from pre "$T/prestamped"
( cd "$T/prestamped"
  python3 - <<'PY'
p="BACKLOG.md"
s=open(p,encoding="utf-8").read()
s=s.replace("🔜 item-a — the item under test",
            "🚧 item-a — the item under test (claimed by carol)")
open(p,"w",encoding="utf-8").write(s)
PY
  git commit -qam "carol claims"
  git push -q origin main )
out="$(run_file_claim "$T/prestamped" "repo#item-a" dave)"
echo "$out" | grep -q "^ALREADY	carol$" || fail "pre-claimed: dave should see ALREADY owned by carol, got '$out'"
grep -q "(claimed by dave)" "$T/prestamped/BACKLOG.md" && fail "pre-claimed: dave must NOT overwrite carol's claim"
pass

# ============================ lane orchestrator: herd_claim_or_abort ==================================
# Drive the file backend through the real lane entry point via SCRIBE_BACKEND_DIR pointing at the
# engine backends; PROJECT_ROOT is a fresh clone so the claim commits/pushes there.
lane_claim() {
  local dir="$1"
  ( exec 2>&1                       # capture the loud abort/warn (stderr) alongside announcements
    cd "$dir"
    export SCRIBE_BACKEND="file" SCRIBE_BACKEND_DIR="$ROOT/scripts/herd/backends"
    export PROJECT_ROOT="$dir" BACKLOG_FILE="BACKLOG.md"
    export DEFAULT_BRANCH="origin/main" HERD_REMOTE="origin" HERD_BRANCH_NAME="main"
    . "$CLAIM_SH"
    if herd_claim_or_abort "some-slug"; then echo "RC=0"; else echo "RC=$?"; fi )
}

# ── 6. CLAIM_REQUIRED on + open item + WATCHER_OWNER identity → CLAIMED, proceed (rc 0) ──────────────
seed_origin lane; clone_from lane "$T/lane_win"
out="$(CLAIM_REQUIRED=on HERD_CLAIM_ID="repo#item-a" WATCHER_OWNER=erin lane_claim "$T/lane_win")"
echo "$out" | grep -q "RC=0" || fail "lane claim-wins: expected rc 0, got '$out'"
echo "$out" | grep -q "🔒 claimed repo#item-a as 'erin'" || fail "lane claim-wins: missing claim announcement ($out)"
grep -q "🚧 item-a.*(claimed by erin)" "$T/lane_win/BACKLOG.md" || fail "lane claim-wins: item not flipped/stamped"
pass

# ── 7. ALREADY → lane ABORTS (rc non-zero), creating nothing ─────────────────────────────────────────
out="$(CLAIM_REQUIRED=on HERD_CLAIM_ID="repo#item-a" WATCHER_OWNER=frank lane_claim "$T/lane_win")"
echo "$out" | grep -q "RC=1" || fail "lane already-claimed: expected rc 1 (abort), got '$out'"
echo "$out" | grep -q "already claimed by 'erin' — backing off" || fail "lane already-claimed: missing loud abort ($out)"
pass

# ── 8. no-id passthrough: CLAIM_REQUIRED on but NO id → skip claim, proceed (rc 0), backend untouched ─
seed_origin noid; clone_from noid "$T/lane_noid"
out="$(CLAIM_REQUIRED=on WATCHER_OWNER=gail lane_claim "$T/lane_noid")"   # no HERD_CLAIM_ID / HERD_ITEM_REF
echo "$out" | grep -q "RC=0" || fail "no-id passthrough: expected rc 0, got '$out'"
echo "$out" | grep -q "claimed" && fail "no-id passthrough: should NOT attempt a claim ($out)"
grep -q "🔜 item-a" "$T/lane_noid/BACKLOG.md" || fail "no-id passthrough: backend must be untouched (still 🔜)"
pass

# ── 9. CLAIM_REQUIRED off passthrough: even WITH an id, off → today's behavior (rc 0, no claim) ───────
seed_origin off; clone_from off "$T/lane_off"
out="$(CLAIM_REQUIRED=off HERD_CLAIM_ID="repo#item-a" WATCHER_OWNER=hank lane_claim "$T/lane_off")"
echo "$out" | grep -q "RC=0" || fail "off passthrough: expected rc 0, got '$out'"
grep -q "🔜 item-a" "$T/lane_off/BACKLOG.md" || fail "off passthrough: backend must be untouched (still 🔜)"
pass

# ── 10. backend-down passthrough: id present, on, but backend has NO claim op → fail soft (rc 0) ──────
mkdir -p "$T/emptybackends"
printf '#!/usr/bin/env bash\n_backend_list_open(){ :; }\n' > "$T/emptybackends/file.sh"
out="$( exec 2>&1; cd "$T/lane_off"
  export SCRIBE_BACKEND="file" SCRIBE_BACKEND_DIR="$T/emptybackends" PROJECT_ROOT="$T/lane_off"
  export DEFAULT_BRANCH="origin/main" HERD_REMOTE="origin" HERD_BRANCH_NAME="main"
  . "$CLAIM_SH"
  if CLAIM_REQUIRED=on HERD_CLAIM_ID="repo#item-a" WATCHER_OWNER=iris herd_claim_or_abort s; then echo "RC=0"; else echo "RC=$?"; fi )"
echo "$out" | grep -q "RC=0" || fail "backend-down passthrough: expected rc 0 (fail soft), got '$out'"
echo "$out" | grep -q "could not verify a claim" || fail "backend-down passthrough: missing fail-soft warning ($out)"
pass

# ── 11. HERD_ITEM_REF is honored when HERD_CLAIM_ID is unset (reuse of the threaded tracker id) ──────
seed_origin ref; clone_from ref "$T/lane_ref"
out="$(CLAIM_REQUIRED=on HERD_ITEM_REF="repo#item-a" WATCHER_OWNER=jill lane_claim "$T/lane_ref")"
echo "$out" | grep -q "RC=0" || fail "HERD_ITEM_REF path: expected rc 0, got '$out'"
grep -q "🚧 item-a.*(claimed by jill)" "$T/lane_ref/BACKLOG.md" || fail "HERD_ITEM_REF path: item not claimed via threaded ref"
pass

echo "ALL PASS ($PASS checks)"
