#!/usr/bin/env bash
# test-refresh-serialize-reattach.sh — hermetic tests for HERD-336: the post-merge codemap/symbol-index
# refresh leg must SERIALIZE per shared checkout and must NEVER commit onto a detached HEAD.
#
# GROUNDED incident: two merges ~30s apart ran two concurrent refresh legs; the second started
# mid-rebase of the first, committed two refresh commits onto a DETACHED HEAD, and left the shared
# coordinator checkout detached until a later `git pull` failed with `not on a branch`.
#
#   (1) SERIALIZE: two concurrent refresh_codemap invocations against ONE checkout → exactly one commit,
#       the loser journals `skipped reason locked`, HEAD stays attached, tree clean, origin == HEAD.
#   (2) REFUSE-ON-DETACHED (refresh leg): a refresh whose $MAIN is on a detached HEAD does NOT commit —
#       it journals main_detached detected + reattached and codemap_refresh skipped detached-head, and
#       leaves $MAIN reattached to the default branch.
#   (3) REATTACH (tick reconcile): reconcile_main_freshness heals a detached shared checkout carrying a
#       generated-only commit — journals main_detached detected + reattached and returns HEAD to main.
#
# Sources agent-watch.sh in lib mode and drives the real functions against a REAL local git repo wired
# to a bare origin (no network). journal_append is overridden to a log; codemap.sh is stubbed via $HERE.
# Run:  bash tests/test-refresh-serialize-reattach.sh
set -uo pipefail
HERE_T="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE_T/../scripts/herd/agent-watch.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

[ -f "$WATCH" ] || fail "agent-watch.sh not found at $WATCH"
command -v git >/dev/null 2>&1 || fail "git required to run this test"

# ── Stub gh / herdr on PATH (network-free); git stays REAL ────────────────────────────────────────
BIN="$T/bin"; mkdir -p "$BIN"
for cmd in gh herdr; do printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$cmd"; chmod +x "$BIN/$cmd"; done
export PATH="$BIN:$PATH"

# ── Source agent-watch.sh in lib mode ─────────────────────────────────────────────────────────────
export AGENT_WATCH_LIB=1
export WORKTREES_DIR="$T/trees"; mkdir -p "$T/trees"
export HERD_CONFIG_FILE="$T/no-such-config"
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"
for fn in refresh_codemap reconcile_main_freshness _refresh_run_locked _refresh_lock_file \
          _main_head_attached _reattach_default_branch _refresh_guard_attached \
          _main_reattach_if_detached; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined after sourcing agent-watch.sh"
done

JLOG="$T/journal.log"; : > "$JLOG"
journal_append() { printf '%s\n' "$*" >> "$JLOG"; }
jhas()   { grep -q "$1" "$JLOG"; }
jcount() { grep -c "$1" "$JLOG" 2>/dev/null || printf '0'; }

# Stub dir: codemap.sh writes STUB_MAP (optionally after a delay, so the SERIALIZE winner holds the
# lock long enough for the loser to contend deterministically).
STUBHERD="$T/herd-stub"; mkdir -p "$STUBHERD"
cat > "$STUBHERD/codemap.sh" <<'STUB'
#!/usr/bin/env bash
[ -n "${STUB_REGEN_SLEEP:-}" ] && sleep "$STUB_REGEN_SLEEP"
printf '%s\n' "${STUB_MAP:-MAP v1}" > "$HERD_CODEMAP_OUT"
STUB
chmod +x "$STUBHERD/codemap.sh"
HERE="$STUBHERD"
export STUB_MAP STUB_REGEN_SLEEP

# ── Fresh real repo wired to a bare origin ────────────────────────────────────────────────────────
new_repo() {
  ORIGIN="$T/origin-$1.git"; git init -q --bare "$ORIGIN"
  MAIN="$T/main-$1"; git clone -q "$ORIGIN" "$MAIN" 2>/dev/null
  git -C "$MAIN" checkout -q -B main
  git -C "$MAIN" config user.email t@t.test; git -C "$MAIN" config user.name tester
  mkdir -p "$MAIN/docs"; printf 'MAP v1\n' > "$MAIN/docs/codemap.md"
  git -C "$MAIN" add docs/codemap.md; git -C "$MAIN" commit -q -m init
  git -C "$MAIN" push -q origin main
  HERD_REMOTE=origin; HERD_BRANCH_NAME=main; DEFAULT_BRANCH=origin/main
}
attached() { [ "$(git -C "$MAIN" symbolic-ref --quiet --short HEAD 2>/dev/null || true)" = "main" ]; }
commits()  { git -C "$MAIN" rev-list --count HEAD; }
head_sha() { git -C "$MAIN" rev-parse HEAD; }
orig_sha() { git -C "$MAIN" rev-parse origin/main; }

# ── (1) SERIALIZE: two concurrent refresh legs → one winner, one locked-skip, no detachment ───────
new_repo one
: > "$JLOG"; STUB_MAP="MAP v2"; STUB_REGEN_SLEEP="2"; c0="$(commits)"
CODEMAP_AUTOREFRESH=true refresh_codemap 1 &
CODEMAP_AUTOREFRESH=true refresh_codemap 2 &
wait
STUB_REGEN_SLEEP=""
[ "$(commits)" = "$((c0 + 1))" ]         || fail "(1) SERIALIZE did not produce exactly one commit (got $(commits) from $c0)"
attached                                 || fail "(1) SERIALIZE left \$MAIN on a detached HEAD"
[ -z "$(git -C "$MAIN" status --porcelain)" ] || fail "(1) SERIALIZE left the tree dirty"
[ "$(head_sha)" = "$(orig_sha)" ]        || fail "(1) SERIALIZE did not push the winner ff-safe"
[ "$(jcount 'result committed pushed yes')" = "1" ] || fail "(1) expected exactly 1 committed leg, got $(jcount 'result committed pushed yes'): $(cat "$JLOG")"
jhas 'result skipped reason locked'      || fail "(1) the loser did not journal skipped/locked: $(cat "$JLOG")"
jhas 'main_detached'                     && fail "(1) SERIALIZE journaled a detachment — the lock must prevent it: $(cat "$JLOG")"
ok

# ── (2) REFUSE-ON-DETACHED (refresh leg) → no commit, reattach, journal loudly ─────────────────────
new_repo two
: > "$JLOG"; STUB_MAP="MAP v2"; c0="$(commits)"
git -C "$MAIN" checkout -q --detach HEAD           # simulate the refresh-race detached corpse
attached                                 && fail "(2) fixture bug: \$MAIN is not detached"
CODEMAP_AUTOREFRESH=true refresh_codemap 3
[ "$(commits)" = "$c0" ]                 || fail "(2) DETACHED refresh created a commit — must refuse"
attached                                 || fail "(2) DETACHED refresh did not reattach \$MAIN to main"
[ -z "$(git -C "$MAIN" status --porcelain)" ] || fail "(2) DETACHED refresh left the tree dirty"
jhas 'codemap_refresh pr 3 result skipped reason detached-head' \
                                         || fail "(2) did not journal skipped/detached-head: $(cat "$JLOG")"
jhas 'main_detached head .* result detected'   || fail "(2) did not journal main_detached detected: $(cat "$JLOG")"
jhas 'main_detached head .* result reattached' || fail "(2) did not journal main_detached reattached: $(cat "$JLOG")"
ok

# ── (3) REATTACH via tick reconcile: a detached, generated-only-ahead checkout is healed ───────────
new_repo three
: > "$JLOG"
git -C "$MAIN" checkout -q --detach HEAD
printf 'MAP v2 (detached corpse)\n' > "$MAIN/docs/codemap.md"
git -C "$MAIN" commit -q -m "chore: refresh codemap (reconcile)" -- docs/codemap.md   # commit on detached HEAD
attached                                 && fail "(3) fixture bug: \$MAIN is not detached"
reconcile_main_freshness
attached                                 || fail "(3) reconcile did not reattach the detached checkout"
[ "$(head_sha)" = "$(orig_sha)" ]        || fail "(3) reconcile did not align HEAD to origin/main after reattach"
jhas 'main_detached head .* result detected'   || fail "(3) reconcile did not journal main_detached detected: $(cat "$JLOG")"
jhas 'main_detached head .* result reattached' || fail "(3) reconcile did not journal main_detached reattached: $(cat "$JLOG")"
ok

# ── (4) EXIT INVARIANT (HERD-364): a body that DETACHES $MAIN mid-leg is reattached on exit ─────────
# The refresh leg has paths (the push-rejected `reset --hard HEAD~1` rollback, a rebase-pull racing a
# concurrent seat) that can leave $MAIN detached AFTER the body's own happy-path guards. _refresh_run_
# locked must make "attached to the default branch" the leg's guaranteed post-condition — a finally-style
# reattach past EVERY body path, not a happy-path call. Drive a body that detaches and returns; assert
# the leg comes back attached and journaled the heal. Without the exit invariant $MAIN stays detached.
new_repo four
: > "$JLOG"
_detaching_body() {                    # models a leg whose git churn ended on a detached HEAD
  git -C "$MAIN" checkout -q --detach HEAD
  return 0
}
_refresh_run_locked _detaching_body
attached                                 || fail "(4) EXIT INVARIANT: a leg that detached mid-body was left detached — reattach must run on every exit path"
[ -z "$(git -C "$MAIN" status --porcelain)" ] || fail "(4) EXIT INVARIANT left the tree dirty"
[ "$(head_sha)" = "$(orig_sha)" ]        || fail "(4) EXIT INVARIANT did not align HEAD to origin after reattach"
jhas 'main_detached head .* result detected'   || fail "(4) EXIT INVARIANT did not journal main_detached detected: $(cat "$JLOG")"
jhas 'main_detached head .* result reattached' || fail "(4) EXIT INVARIANT did not journal main_detached reattached: $(cat "$JLOG")"
ok

# ── (5) EXIT INVARIANT byte-inert on the happy path: an ATTACHED body journals NO detachment ────────
# The finally guard must be silent when the leg already ended attached (the common case), or every merge
# would spam main_detached. Drive a body that stays on main; assert zero detachment journal lines.
new_repo five
: > "$JLOG"
_attached_body() { return 0; }
_refresh_run_locked _attached_body
attached                                 || fail "(5) fixture: an attached body must stay attached"
jhas 'main_detached'                     && fail "(5) the exit invariant journaled a detachment on the happy path — it must be byte-inert when attached: $(cat "$JLOG")"
ok

# ── (6) TWO-MERGES-SECONDS-APART window: a competing merge lands before our push → rebase, end attached ─
# Reproduces the HERD-364 trigger: a second merge landed on origin seconds after ours, so the refresh
# leg's push is rejected and it must pull --rebase + retry. Assert the leg ends ATTACHED, tree clean,
# HEAD == origin, and the refresh commit landed — never a lingering detached corpse.
new_repo six
: > "$JLOG"; STUB_MAP="MAP v2"; c0="$(commits)"
# A competing seat merges to origin between our regen and our push (advance origin/main out-of-band).
COMPETITOR="$T/competitor-six"; git clone -q "$ORIGIN" "$COMPETITOR" 2>/dev/null
git -C "$COMPETITOR" config user.email c@c.test; git -C "$COMPETITOR" config user.name competitor
printf 'competing change\n' > "$COMPETITOR/other.txt"
git -C "$COMPETITOR" add other.txt; git -C "$COMPETITOR" commit -q -m "feat: a competing merge"
git -C "$COMPETITOR" push -q origin main
# Our refresh leg now regenerates, commits locally, gets its push REJECTED (origin advanced), pulls
# --rebase onto the competitor, and retries — the reset-HEAD~1 contention window.
CODEMAP_AUTOREFRESH=true refresh_codemap 6
attached                                 || fail "(6) TWO-MERGES window left \$MAIN detached"
[ -z "$(git -C "$MAIN" status --porcelain)" ] || fail "(6) TWO-MERGES window left the tree dirty"
[ "$(head_sha)" = "$(orig_sha)" ]        || fail "(6) TWO-MERGES window did not converge HEAD to origin/main"
_six_log="$(git -C "$MAIN" log --oneline)"
case "$_six_log" in *"refresh codemap"*) : ;; *) fail "(6) the refresh commit did not survive the rebase-retry: $_six_log" ;; esac
jhas 'main_detached'                     && fail "(6) the rebase-retry path journaled a detachment — it must end cleanly attached: $(cat "$JLOG")"
ok

echo "PASS: test-refresh-serialize-reattach.sh ($pass checks)"
