#!/usr/bin/env bash
# test-claim-release.sh — hermetic proof of CLAIM RELEASE (HERD-162 F12), the claim's missing half.
#
# THE WEDGE this closes: herd-claim.sh takes a claim before the worktree exists, and until now nothing
# ever gave it back. A builder that DIED before opening a PR left its tracker item In Progress +
# assigned forever, so the other operator's pre-spawn claim read it as ALREADY and aborted — the item
# was unpickable by anyone but a dead process. The repro below is the wedge itself: claim → the builder
# dies → a SECOND operator's claim aborts. Then the release runs, and the same second claim succeeds.
#
# Three layers, each proven separately:
#   A. the MECHANISM — herd_claim_release + the file backend's _backend_release_item: the mode parse,
#      the byte-inert off path, flag-vs-release, refusing to steal a foreign claim, and the fail-soft
#      degradation when the backend has no release op.
#   B. the WEDGE, end to end — claim, kill, watch the second claim abort; release; watch it succeed.
#   C. the POLICY — the watcher's _maybe_release_claim rails: an untracked slug releases nothing; a
#      dead builder that LEFT WORK is held (never released, because a duplicate build on top of
#      unrecovered work is worse than a wedge); a builder about to be RESPAWNED keeps its claim; and
#      every refusal is journaled AND stated on the 💀 notification rather than passing in silence.
#
# Hermetic: the `file` backend on a throwaway git repo (no remote → push/pull fail soft), a no-op
# `herdr` stub. NO network, NO model, NO tracker API. Run:  bash tests/test-claim-release.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CLAIM="$ROOT/scripts/herd/herd-claim.sh"
WATCH="$ROOT/scripts/herd/agent-watch.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ PASS=$((PASS+1)); }

[ -f "$CLAIM" ] || fail "herd-claim.sh not found"
for b in git python3; do command -v "$b" >/dev/null 2>&1 || fail "$b required"; done

BIN="$T/bin"; mkdir -p "$BIN"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/herdr"; chmod +x "$BIN/herdr"
export PATH="$BIN:$PATH"
export JOURNAL_FILE="$T/journal.jsonl"; : > "$JOURNAL_FILE"
export HERD_JOURNAL_HERMETIC=1

# ── a throwaway project the `file` backend can claim against ──────────────────────────────────────
REPO="$T/repo"; mkdir -p "$REPO"
git -c init.defaultBranch=main init -q "$REPO"
git -C "$REPO" config user.email t@t; git -C "$REPO" config user.name t
export PROJECT_ROOT="$REPO"
export BACKLOG_FILE="$REPO/BACKLOG.md"
export SCRIBE_BACKEND=file
export DEFAULT_BRANCH=main               # no remote: the backend's pull/push fail soft
export HERD_REMOTE=origin HERD_BRANCH_NAME=main
export CLAIM_REQUIRED=on
export HERD_SKIP_ENGINE_HANDSHAKE=1 HERD_ENGINE_SKIP_HANDSHAKE=1

seed_backlog() { printf -- '- 🔜 wedge-item — a thing to build\n' > "$BACKLOG_FILE"
                 git -C "$REPO" add -A >/dev/null 2>&1
                 git -C "$REPO" commit -qm seed >/dev/null 2>&1 || true; }
item_line() { grep 'wedge-item' "$BACKLOG_FILE"; }

# shellcheck source=/dev/null
. "$CLAIM" || fail "sourcing herd-claim.sh failed"
for fn in herd_claim_release herd_claim_release_mode _herd_release_dispatch herd_claim_or_abort; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined"
done

# ══ A. THE MECHANISM ═════════════════════════════════════════════════════════════════════════════

# A1 — the mode parse. Anything unrecognized reads as off: a typo can never start writing the tracker.
[ "$(CLAIM_RELEASE=""        herd_claim_release_mode)" = off ]     || fail "A1 unset must be off"
[ "$(CLAIM_RELEASE=off       herd_claim_release_mode)" = off ]     || fail "A1 off must be off"
[ "$(CLAIM_RELEASE=relese    herd_claim_release_mode)" = off ]     || fail "A1 a typo must fail toward off"
[ "$(CLAIM_RELEASE=flag      herd_claim_release_mode)" = flag ]    || fail "A1 flag"
[ "$(CLAIM_RELEASE=FLAG      herd_claim_release_mode)" = flag ]    || fail "A1 flag is case-insensitive"
[ "$(CLAIM_RELEASE=release   herd_claim_release_mode)" = release ] || fail "A1 release"
[ "$(CLAIM_RELEASE=on        herd_claim_release_mode)" = release ] || fail "A1 on ⇒ release"
ok

# A2 — off is byte-inert: no tracker read, no write, no journal event.
seed_backlog
before="$(item_line)"
out="$(CLAIM_RELEASE=off herd_claim_release wedge-item alice slug dead-builder)"
[ "$out" = off ]                     || fail "A2 off should echo 'off', got '$out'"
[ "$(item_line)" = "$before" ]       || fail "A2 off must not touch the backlog"
[ -s "$JOURNAL_FILE" ]               && fail "A2 off must journal nothing"
ok

# A3 — flag OBSERVES: it journals the wedged ref and writes nothing.
out="$(CLAIM_RELEASE=flag herd_claim_release wedge-item alice slug dead-builder)"
[ "$out" = flagged ]                 || fail "A3 flag should echo 'flagged', got '$out'"
[ "$(item_line)" = "$before" ]       || fail "A3 flag must not touch the backlog"
grep -q '"event":"claim_release_flagged"' "$JOURNAL_FILE" || fail "A3 flag must journal claim_release_flagged"
grep -q '"ref":"wedge-item"'          "$JOURNAL_FILE"     || fail "A3 the flag event must name the wedged ref"
ok

# A4 — release CLEARS our own claim: the (claimed by …) stamp goes, 🚧 goes back to 🔜.
: > "$JOURNAL_FILE"
( cd "$REPO" && HERD_CLAIM_ID=wedge-item WATCHER_OWNER=alice herd_claim_or_abort wedge-item-slug ) >/dev/null 2>&1
item_line | grep -q '🚧' || fail "A4 fixture: the claim did not flip the line to 🚧: $(item_line)"
item_line | grep -q 'claimed by alice' || fail "A4 fixture: the claim did not stamp the owner: $(item_line)"
ok

out="$(cd "$REPO" && CLAIM_RELEASE=release herd_claim_release wedge-item alice wedge-item-slug dead-builder)"
[ "$out" = released ]                     || fail "A4 release should echo 'released', got '$out'"
item_line | grep -q 'claimed by'          && fail "A4 release must strip the claim stamp: $(item_line)"
item_line | grep -q '🔜'                  || fail "A4 release must put the line back to 🔜: $(item_line)"
grep -q '"event":"claim_released"'  "$JOURNAL_FILE" || fail "A4 release must journal claim_released"
grep -q '"result":"RELEASED"'       "$JOURNAL_FILE" || fail "A4 release must journal the tracker_write (HERD-85)"
ok

# A5 — a claim held by ANOTHER identity is never stolen. Releasing one is worse than the wedge it fixes.
: > "$JOURNAL_FILE"
printf -- '- 🚧 wedge-item — a thing to build (claimed by bob)\n' > "$BACKLOG_FILE"
out="$(cd "$REPO" && CLAIM_RELEASE=release herd_claim_release wedge-item alice slug dead-builder)"
[ "$out" = notours ]                      || fail "A5 a foreign claim should echo 'notours', got '$out'"
item_line | grep -q 'claimed by bob'      || fail "A5 bob's claim was stolen: $(item_line)"
grep -q '"reason":"not-ours"' "$JOURNAL_FILE" || fail "A5 the refusal must be journaled"
ok

# A5b — a ✅ shipped item holds no claim to release, and is never edited.
printf -- '- ✅ wedge-item — a thing to build\n' > "$BACKLOG_FILE"
out="$(cd "$REPO" && CLAIM_RELEASE=release herd_claim_release wedge-item alice slug dead-builder)"
[ "$out" = notours ]                      || fail "A5b a shipped item should echo 'notours', got '$out'"
item_line | grep -q '✅'                   || fail "A5b a shipped line was rewritten: $(item_line)"
ok

# A6 — a backend with NO release op degrades to the flag contract: surfaced + journaled, never a red.
: > "$JOURNAL_FILE"
out="$(cd "$REPO" && SCRIBE_BACKEND=changelog CLAIM_RELEASE=release herd_claim_release wedge-item alice slug dead-builder)"
[ "$out" = unsupported ]                  || fail "A6 a release-op-less backend should echo 'unsupported', got '$out'"
grep -q '"event":"claim_release_flagged"' "$JOURNAL_FILE" || fail "A6 the degradation must journal the wedge"
ok

# A7 — an empty ref releases nothing (an untracked spawn claimed nothing).
[ "$(CLAIM_RELEASE=release herd_claim_release "" alice slug dead-builder)" = off ] && ok \
  || fail "A7 an empty ref must be a no-op"

# ══ B. THE WEDGE, END TO END ═════════════════════════════════════════════════════════════════════
# Claim as alice → alice's builder dies → bob's pre-spawn claim ABORTS (this is the wedge, reproduced)
# → release alice's claim → bob's SAME claim now succeeds. Nothing else changes between the two runs.
seed_backlog
: > "$JOURNAL_FILE"
( cd "$REPO" && HERD_CLAIM_ID=wedge-item WATCHER_OWNER=alice herd_claim_or_abort a-slug ) >/dev/null 2>&1 \
  || fail "B alice's claim should succeed on an open item"

if ( cd "$REPO" && HERD_CLAIM_ID=wedge-item WATCHER_OWNER=bob herd_claim_or_abort b-slug ) >/dev/null 2>&1; then
  fail "B the wedge did not reproduce — bob claimed an item alice already holds"
fi
ok   # the wedge, reproduced: with alice's builder dead, bob can never pick this item

( cd "$REPO" && CLAIM_RELEASE=release herd_claim_release wedge-item alice a-slug dead-builder ) >/dev/null
( cd "$REPO" && HERD_CLAIM_ID=wedge-item WATCHER_OWNER=bob herd_claim_or_abort b-slug ) >/dev/null 2>&1 \
  || fail "B after the release, bob's claim STILL aborts — the item is still wedged"
item_line | grep -q 'claimed by bob' || fail "B bob should now own the item: $(item_line)"
ok   # released → the very same claim that aborted now succeeds

# ══ C. THE WATCHER'S POLICY RAILS (_maybe_release_claim) ═════════════════════════════════════════
export AGENT_WATCH_LIB=1
export HERD_CONFIG_FILE="$T/no-such-config"
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"
type _maybe_release_claim >/dev/null 2>&1 || fail "_maybe_release_claim not defined"

TREES="$T/trees"; mkdir -p "$TREES"
DEAD_RESPAWN_STATE="$T/.agent-watch-respawn"; : > "$DEAD_RESPAWN_STATE"
DEFAULT_BRANCH=main

mkwt() {   # mkwt <dir> <clean|commits> — a throwaway worktree, HEAD==main or 1 commit ahead of it
  git -c init.defaultBranch=main init -q "$1"
  git -C "$1" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
  if [ "$2" = commits ]; then
    git -C "$1" checkout -q -b feat
    git -C "$1" -c user.email=t@t -c user.name=t commit -q --allow-empty -m ahead
  fi
  return 0
}
mkwt "$T/wt-clean" clean
mkwt "$T/wt-work"  commits
_worktree_has_work "$T/wt-work"  || fail "C fixture: wt-work must read as having work"
_worktree_has_work "$T/wt-clean" && fail "C fixture: wt-clean must read as clean"

# C1 — off is byte-inert at the watcher seam too: the 💀 notification clause is EMPTY, so the
#      notification string is byte-identical to the pre-HERD-162 engine.
[ -z "$(CLAIM_RELEASE=off _maybe_release_claim any-slug "$T/wt-clean")" ] && ok \
  || fail "C1 CLAIM_RELEASE=off must contribute no notification clause"

# C2 — an UNTRACKED slug (no .herd-ref-<slug> marker) claimed nothing, so it releases nothing.
[ -z "$(CLAIM_RELEASE=release _maybe_release_claim untracked-slug "$T/wt-clean")" ] && ok \
  || fail "C2 a slug with no tracker ref must release nothing"

# From here on the slug carries a ref marker, exactly as the lane writes at spawn.
printf 'HERD-162\n' > "$TREES/.herd-ref-dead-slug"

# C3 — a dead builder that LEFT WORK is HELD, loudly. Releasing it would invite a second operator to
#      build a duplicate on top of work nobody has salvaged yet.
: > "$JOURNAL_FILE"
printf 'HERD-162\n' > "$TREES/.herd-ref-work-slug"
clause="$(CLAIM_RELEASE=release _maybe_release_claim work-slug "$T/wt-work")"
case "$clause" in *"HELD"*) ok ;; *) fail "C3 a dead builder with commits must HOLD its claim, got '$clause'" ;; esac
grep -q '"event":"claim_release_held"' "$JOURNAL_FILE" || fail "C3 the hold must be journaled, never silent"
grep -q '"reason":"has-work"'          "$JOURNAL_FILE" || fail "C3 the hold must name its reason"
ok

# C3b — the has-work rail must hold with DEAD_BUILDER_AUTORESPAWN=on TOO. Regression guard: reading the
#       hold off _classify_respawn is wrong, because that classifier short-circuits to OFF before it
#       looks at has-work — so with autorespawn OFF (the default!) every dead builder that left work
#       would have had its claim released, inviting a duplicate build on unrecovered work.
for flag in on off; do
  clause="$(DEAD_BUILDER_AUTORESPAWN="$flag" CLAIM_RELEASE=release _maybe_release_claim work-slug "$T/wt-work")"
  case "$clause" in *"HELD"*) : ;; *) fail "C3b autorespawn=$flag: a dead builder with work must HOLD, got '$clause'" ;; esac
done
ok

# C4 — a builder about to be RESPAWNED keeps its claim: the fresh agent continues to own the item.
: > "$JOURNAL_FILE"
clause="$(DEAD_BUILDER_AUTORESPAWN=on CLAIM_RELEASE=release _maybe_release_claim dead-slug "$T/wt-clean")"
case "$clause" in *"held (respawning)"*) ok ;; *) fail "C4 a respawning builder must keep its claim, got '$clause'" ;; esac
grep -q '"reason":"respawning"' "$JOURNAL_FILE" || fail "C4 the skip must be journaled"
ok

# C5 — DRYRUN names the intent and writes nothing.
clause="$(DRYRUN=1 CLAIM_RELEASE=release _maybe_release_claim dead-slug "$T/wt-clean")"
case "$clause" in *"would be released (dry-run)"*) ok ;; *) fail "C5 DRYRUN should announce intent, got '$clause'" ;; esac

# C6 — the genuinely abandoned case: dead, clean, not respawning → the claim is released and the 💀
#      notification says so, naming the ref.
: > "$JOURNAL_FILE"
seed_backlog
( cd "$REPO" && HERD_CLAIM_ID=HERD-162 WATCHER_OWNER=alice herd_claim_or_abort dead-slug ) >/dev/null 2>&1 || true
printf -- '- 🚧 HERD-162 — recovery hygiene (claimed by alice)\n' > "$BACKLOG_FILE"
clause="$(cd "$REPO" && CLAIM_RELEASE=release WATCHER_OWNER=alice _maybe_release_claim dead-slug "$T/wt-clean")"
case "$clause" in *"claim HERD-162 released"*) ok ;; *) fail "C6 an abandoned builder's claim must be released, got '$clause'" ;; esac
grep -q 'claimed by' "$BACKLOG_FILE" && fail "C6 the claim stamp survived the release: $(cat "$BACKLOG_FILE")"
ok

# C7 — flag mode at the watcher seam: the notification tells the operator to re-queue, and the tracker
#      is untouched.
: > "$JOURNAL_FILE"
printf -- '- 🚧 HERD-162 — recovery hygiene (claimed by alice)\n' > "$BACKLOG_FILE"
clause="$(cd "$REPO" && CLAIM_RELEASE=flag WATCHER_OWNER=alice _maybe_release_claim dead-slug "$T/wt-clean")"
case "$clause" in *"still held — re-queue it"*) ok ;; *) fail "C7 flag mode should surface the wedge, got '$clause'" ;; esac
grep -q 'claimed by alice' "$BACKLOG_FILE" || fail "C7 flag mode must NOT write the tracker"
grep -q '"event":"claim_release_flagged"' "$JOURNAL_FILE" || fail "C7 flag mode must journal the wedge"
ok

echo "ALL PASS ($PASS checks) — a dead pre-PR builder hands its claim back (HERD-162 F12)"
