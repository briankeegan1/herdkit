#!/usr/bin/env bash
# test-reap-slug-ledgers.sh — hermetic proof of the SLUG-LEDGER LIFECYCLE (HERD-162 F7).
#
# The four line-oriented, slug-keyed ledgers ($DEAD_STATE, $DEAD_RESPAWN_STATE, $LIMIT_STATE,
# $SENDKEYS_STATE) were opened at spawn-time and closed by NOTHING. Slugs are reused by design, so a
# row that outlived its builder was inherited by the reincarnation. This test pins the fix and, just
# as importantly, the two things the purge must NOT do.
#
# What it asserts:
#   1. _reap_slug closes ALL FOUR of the reaped slug's ledger rows (dead, respawn budget, limit,
#      sendkeys) plus the limit sentinel inside the worktree, and journals ONE slug_ledgers_purged
#      event naming exactly the ledgers that carried a row.
#   2. A LIVE SIBLING slug whose name shares the reaped slug's PREFIX keeps every row — the purge is
#      row-exact, not a prefix sweep. (`grep -v "^slug "` is what makes that true; this is the test
#      that would catch a `grep -v "$slug"` regression.)
#   3. A reap over a slug with NO ledger rows journals NOTHING (a silent reap stays silent) and a
#      SECOND reap of the same slug is a clean no-op — the purge is idempotent.
#   4. The respawn BUDGET survives clear_dead. Its whole job is to outlive a clearing dead-record
#      within one builder's life (that is what makes "died AGAIN" detectable); only the slug's death,
#      i.e. the reap, may clear it. A purge that ran on every liveness blip would silently grant an
#      unbounded respawn loop.
#   5. The reincarnation rail, end to end: after a reap, a fresh builder on the SAME slug sees a clean
#      world — no stale limit target to inject `claude --continue` into it, no dead anchor to 💀 it on
#      tick one, and a full at-most-once respawn budget.
#
# Hermetic: a throwaway git repo, a no-op `herdr` stub on PATH, the journal pinned to a temp file.
# NO network, NO model, NO real tab. Run:  bash tests/test-reap-slug-ledgers.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../scripts/herd/agent-watch.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ PASS=$((PASS+1)); }

[ -f "$WATCH" ] || fail "agent-watch.sh not found at $WATCH"
for b in git python3; do command -v "$b" >/dev/null 2>&1 || fail "$b required"; done

# A `herdr` that answers nothing: herd_teardown_slug reads an empty tab list and no-ops, so the reap
# under test never touches a real control room.
BIN="$T/bin"; mkdir -p "$BIN"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/herdr"; chmod +x "$BIN/herdr"
export PATH="$BIN:$PATH"

export JOURNAL_FILE="$T/journal.jsonl"; : > "$JOURNAL_FILE"
export HERD_JOURNAL_HERMETIC=1
export AGENT_WATCH_LIB=1
export HERD_CONFIG_FILE="$T/no-such-config"
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"
for fn in _reap_slug _purge_slug_ledgers clear_respawn clear_dead clear_limit clear_sendkeys \
          record_dead_seen record_respawn record_limit record_sendkeys respawn_recorded; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined"
done

# Redirect every stateful path into the temp dir (plain globals; safe to reassign post-source).
MAIN="$T/main"; TREES="$T/trees"; mkdir -p "$TREES"
DEAD_STATE="$TREES/.agent-watch-dead"
DEAD_RESPAWN_STATE="$TREES/.agent-watch-respawn"
LIMIT_STATE="$TREES/.agent-watch-limit"
SENDKEYS_STATE="$TREES/.agent-watch-limit-sendkeys"
DEFAULT_BRANCH="main"

git -c init.defaultBranch=main init -q "$MAIN"
git -C "$MAIN" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base

# seed_ledgers <slug> — every ledger row a live builder accumulates, plus its in-worktree sentinel.
seed_ledgers() {
  local s="$1"
  record_dead_seen  "$s" 1000
  record_respawn    "$s" 1000 respawned
  record_limit      "$s" 1000 2000 scheduled
  record_sendkeys   "$s" 1000 cleared
  mkdir -p "$TREES/$s"
  : > "$(_limit_sentinel_file "$TREES/$s")"
}

# rows <slug> — the ledgers that still carry a row for <slug>, space-joined. Empty ⇒ fully purged.
rows() {
  local s="$1" out=""
  [ -n "$(dead_first_seen "$s")" ]  && out="${out}dead "
  respawn_recorded "$s"             && out="${out}respawn "
  [ -n "$(limit_state "$s")" ]      && out="${out}limit "
  [ -n "$(sendkeys_state "$s")" ]   && out="${out}sendkeys "
  printf '%s' "$out"
}

# ── 1. a reap closes every ledger row the slug opened ─────────────────────────────────────────────
SLUG=reaped
seed_ledgers "$SLUG"
seed_ledgers "$SLUG-sibling"          # a LIVE builder whose slug shares the reaped slug's prefix
[ "$(rows "$SLUG")" = "dead respawn limit sendkeys " ] || fail "(1) fixture did not seed all four ledgers"

_reap_slug "$SLUG" "$TREES/$SLUG" 77 deadbeef merged

[ -z "$(rows "$SLUG")" ] && ok || fail "(1) reap left ledger rows behind: $(rows "$SLUG")"
[ ! -e "$TREES/$SLUG/.herd-limit-sentinel" ] && ok || fail "(1) the limit sentinel survived the reap"

# ── 2. the purge is row-exact: a prefix sibling keeps everything ──────────────────────────────────
[ "$(rows "$SLUG-sibling")" = "dead respawn limit sendkeys " ] && ok \
  || fail "(2) reaping '$SLUG' ate the live sibling's rows (got: '$(rows "$SLUG-sibling")')"
[ -e "$(_limit_sentinel_file "$TREES/$SLUG-sibling")" ] && ok \
  || fail "(2) reaping '$SLUG' deleted the sibling's limit sentinel"

# ── 3. the purge journals what it closed — once, and only when it closed something ────────────────
purged="$(grep -c '"event":"slug_ledgers_purged"' "$JOURNAL_FILE" 2>/dev/null || printf '0')"
[ "$purged" = "1" ] && ok || fail "(3) expected exactly 1 slug_ledgers_purged event, got $purged"
grep '"event":"slug_ledgers_purged"' "$JOURNAL_FILE" | grep -q '"ledgers":"dead,respawn,limit,sendkeys"' && ok \
  || fail "(3) the purge event does not name the four ledgers: $(grep slug_ledgers_purged "$JOURNAL_FILE")"

# A second reap of the same (already-purged) slug: idempotent, and silent.
_reap_slug "$SLUG" "$TREES/$SLUG" 77 deadbeef merged
purged="$(grep -c '"event":"slug_ledgers_purged"' "$JOURNAL_FILE" 2>/dev/null || printf '0')"
[ "$purged" = "1" ] && ok || fail "(3) a re-reap of a purged slug journaled again (count=$purged)"

# A reap of a slug that never opened a ledger row says nothing at all.
_reap_slug never-lived "$TREES/never-lived" "" "" startup-sweep
purged="$(grep -c '"event":"slug_ledgers_purged"' "$JOURNAL_FILE" 2>/dev/null || printf '0')"
[ "$purged" = "1" ] && ok || fail "(3) a reap that purged nothing still journaled (count=$purged)"

# ── 4. clear_dead must NOT spend or clear the respawn budget ──────────────────────────────────────
# The budget outlives a clearing dead-record within one builder's life — that is what makes a SECOND
# death detectable as "died again" instead of silently earning a second respawn.
BUDGET=budget-slug
record_dead_seen "$BUDGET" 1000
record_respawn   "$BUDGET" 1000 respawned
clear_dead "$BUDGET"
[ -z "$(dead_first_seen "$BUDGET")" ] && ok || fail "(4) clear_dead did not clear the dead record"
respawn_recorded "$BUDGET" && ok || fail "(4) clear_dead wrongly cleared the at-most-once respawn budget"
# Only the reap may clear it.
clear_respawn "$BUDGET"
respawn_recorded "$BUDGET" && fail "(4) clear_respawn did not clear the budget" || ok

# ── 5. the reincarnation rail: a reused slug is born clean ────────────────────────────────────────
# Re-seed the reaped slug's world as a FRESH builder would find it, and assert the three inheritances
# the item names are all gone: no stale limit target, no stale dead anchor, a full respawn budget.
[ "$(limit_target_epoch "$SLUG")" = "0" ] && ok \
  || fail "(5) a reincarnated slug inherited a stale limit target ($(limit_target_epoch "$SLUG")) — would inject --continue"
[ -z "$(limit_state "$SLUG")" ] && ok || fail "(5) a reincarnated slug inherited a stale limit state"
dead_notified "$SLUG" && fail "(5) a reincarnated slug is 💀 on its first tick (stale dead anchor)" || ok
respawn_recorded "$SLUG" && fail "(5) a reincarnated slug is born with its respawn budget spent" || ok

echo "ALL PASS ($PASS checks) — slug ledgers are opened at spawn and closed by the reap (HERD-162 F7)"
