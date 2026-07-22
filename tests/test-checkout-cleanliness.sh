#!/usr/bin/env bash
# test-checkout-cleanliness.sh — hermetic tests for HERD-361: the shared-checkout cleanliness invariant
# AND the sandboxed baseline leg that root-causes the staged-diff writer.
#
# GROUNDED incident: on 2026-07-13 the shared main checkout ($MAIN) was found with PR #466's ENTIRE diff
# STAGED (byte-identical to the builder's commit) and a previously-dirty derived doc vanished — the
# fingerprint of a suite test that ran `git add`/`git stash` in $PWD while the pre-merge healthcheck's
# BASELINE leg ran the full suite INSIDE the live shared checkout (HERD_BASELINE_DIR=$MAIN).
#
# Two deliverables, proven here:
#   PART A — the INVARIANT (reconcile_checkout_cleanliness in agent-watch.sh): every tick the shared
#            checkout must be ATTACHED to the default branch with NO staged/tracked contamination other
#            than the derived docs a refresh commit absorbs. A violation → a loud row (build_checkout_
#            cleanliness) + one `checkout_unclean` journal event naming the offending paths, and is NEVER
#            auto-discarded (evidence preservation). Clean → byte-quiet.
#   PART B — the FIX (scripts/herd/healthcheck.sh baseline leg): the base suite is ALWAYS run in a
#            DISPOSABLE worktree, never the live shared checkout — so a suite test that stages in $PWD
#            leaves $MAIN byte-identical (git status clean before == after).
#
# Fully hermetic: real local git repos under a mktemp dir, no herdr/gh/network/model.
# Run:  bash tests/test-checkout-cleanliness.sh
set -uo pipefail
HERE_T="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE_T/../scripts/herd/agent-watch.sh"
HC="$HERE_T/../scripts/herd/healthcheck.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

[ -f "$WATCH" ] || fail "agent-watch.sh not found at $WATCH"
[ -f "$HC" ]    || fail "healthcheck.sh not found at $HC"
command -v git >/dev/null 2>&1 || fail "git required to run this test"

# ── Stub gh / herdr on PATH (network-free); git stays REAL ────────────────────────────────────────
BIN="$T/bin"; mkdir -p "$BIN"
for cmd in gh herdr; do printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$cmd"; chmod +x "$BIN/$cmd"; done
export PATH="$BIN:$PATH"

# ════════════════════════════════════════════════════════════════════════════════════════════════
# PART A — the tick invariant (agent-watch.sh lib mode)
# ════════════════════════════════════════════════════════════════════════════════════════════════
export AGENT_WATCH_LIB=1
export WORKTREES_DIR="$T/trees"; mkdir -p "$T/trees"
export HERD_CONFIG_FILE="$T/no-such-config"
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"
for fn in reconcile_checkout_cleanliness _checkout_offenders _checkout_exempt_backlog build_checkout_cleanliness herd_strip_derived; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined after sourcing agent-watch.sh"
done

JLOG="$T/journal.log"; : > "$JLOG"
journal_append() { printf '%s\n' "$*" >> "$JLOG"; }
jcount() { local n; n="$(grep -c "$1" "$JLOG" 2>/dev/null)" || n=0; printf '%s' "${n:-0}"; }

# TREES/CHECKOUT_CLEAN_STATE are fixed to $WORKTREES_DIR at source time; MAIN is overridden per repo.
TREES="$WORKTREES_DIR"
CHECKOUT_CLEAN_STATE="$TREES/.agent-watch-checkout-clean"
CHECKOUT_CLEAN_PENDING="$TREES/.agent-watch-checkout-clean.pending"
HERD_REMOTE=origin; HERD_BRANCH_NAME=main
SCRIBE_BACKEND=file; BACKLOG_FILE=BACKLOG.md

new_main() {           # a clean committed repo on 'main' with a derived + a normal tracked file
  MAIN="$T/main-$1"; mkdir -p "$MAIN/docs"
  git -C "$MAIN" init -q
  git -C "$MAIN" checkout -q -B main
  git -C "$MAIN" config user.email t@t.test; git -C "$MAIN" config user.name tester
  printf 'MAP v1\n' > "$MAIN/docs/codemap.md"
  printf 'code v1\n' > "$MAIN/lib.sh"
  printf 'backlog v1\n' > "$MAIN/BACKLOG.md"
  git -C "$MAIN" add -A; git -C "$MAIN" commit -q -m init
  rm -f "$CHECKOUT_CLEAN_STATE" "$CHECKOUT_CLEAN_PENDING"; : > "$JLOG"
}

# tick <n> — call reconcile_checkout_cleanliness <n> times in a row (models <n> consecutive watcher
# ticks sampling the SAME git state); HERD-414's debounce needs 2 identical ticks before it raises.
tick() { local _n="${1:-1}"; while [ "$_n" -gt 0 ]; do reconcile_checkout_cleanliness; _n=$((_n - 1)); done; }

# ── (A1) a CLEAN, attached checkout → byte-quiet: no state file, no journal, no row ────────────────
new_main a1
reconcile_checkout_cleanliness
[ ! -e "$CHECKOUT_CLEAN_STATE" ]        || fail "(A1) clean checkout must leave NO state file"
[ "$(jcount checkout_unclean)" = "0" ]  || fail "(A1) clean checkout must journal NOTHING"
build_checkout_cleanliness
[ -z "${CHECKOUT_CLEAN:-}" ]            || fail "(A1) clean checkout must render an EMPTY row"
ok

# ── (A2) STAGED contamination, persisting 2 ticks → violation: state file, journal, LOUD row ──────
# HERD-414 debounce: tick 1 only PARKS the signature (pending) — no state file, no journal yet.
new_main a2
printf 'code v2 (contaminated)\n' > "$MAIN/lib.sh"       # modify a tracked file
printf 'brand new staged file\n'  > "$MAIN/newfile.txt"  # brand-new file
git -C "$MAIN" add -A                                     # STAGE both (the contamination fingerprint)
reconcile_checkout_cleanliness
[ ! -e "$CHECKOUT_CLEAN_STATE" ]                          || fail "(A2) tick 1 of a fresh signature must NOT raise yet (debounce)"
[ "$(jcount checkout_unclean)" = "0" ]                   || fail "(A2) tick 1 must journal NOTHING: $(cat "$JLOG")"
# tick 2, same still-staged state → the signature repeats → NOW it raises.
reconcile_checkout_cleanliness
[ -s "$CHECKOUT_CLEAN_STATE" ]                            || fail "(A2) contamination persisting 2 ticks must write the state file"
[ "$(jcount 'checkout_unclean')" = "1" ]                 || fail "(A2) expected 1 checkout_unclean event, got $(jcount checkout_unclean): $(cat "$JLOG")"
grep -q 'lib.sh' "$JLOG"                                 || fail "(A2) journal must name the offending path lib.sh: $(cat "$JLOG")"
grep -q 'newfile.txt' "$JLOG"                            || fail "(A2) journal must name the offending path newfile.txt: $(cat "$JLOG")"
grep -q 'result violation' "$JLOG"                       || fail "(A2) journal must mark result=violation: $(cat "$JLOG")"
build_checkout_cleanliness
case "${CHECKOUT_CLEAN:-}" in *"CHECKOUT UNCLEAN"*) : ;; *) fail "(A2) row must read CHECKOUT UNCLEAN, got: [${CHECKOUT_CLEAN:-}]" ;; esac
case "${CHECKOUT_CLEAN:-}" in *lib.sh*) : ;; *) fail "(A2) row must name an offending path, got: [${CHECKOUT_CLEAN:-}]" ;; esac
# EVIDENCE PRESERVATION: the staged files are UNTOUCHED (never discarded).
[ -n "$(git -C "$MAIN" diff --cached --name-only)" ]     || fail "(A2) the staged contamination must be PRESERVED, never auto-discarded"
[ -f "$MAIN/newfile.txt" ]                               || fail "(A2) the offending file must still exist (no auto-clean)"
ok

# ── (A3) IDEMPOTENT: a re-tick on the SAME (already-promoted) violation does not re-journal ───────
reconcile_checkout_cleanliness
[ "$(jcount 'checkout_unclean')" = "1" ]                 || fail "(A3) a standing violation must journal ONCE, got $(jcount checkout_unclean)"
ok

# ── (A4) a staged DERIVED map (docs/codemap.md) is EXCUSED → no violation, byte-quiet ─────────────
new_main a4
printf 'MAP v2 (regen awaiting refresh commit)\n' > "$MAIN/docs/codemap.md"
git -C "$MAIN" add docs/codemap.md
tick 2
[ ! -e "$CHECKOUT_CLEAN_STATE" ]        || fail "(A4) a staged derived map must NOT be a violation (state file present)"
[ "$(jcount checkout_unclean)" = "0" ]  || fail "(A4) a staged derived map must journal NOTHING: $(cat "$JLOG")"
ok

# ── (A5) a DETACHED shared checkout, persisting 2 ticks, is a cleanliness violation (never discarded) ─
new_main a5
git -C "$MAIN" checkout -q --detach HEAD
reconcile_checkout_cleanliness
[ ! -e "$CHECKOUT_CLEAN_STATE" ]        || fail "(A5) tick 1 of a fresh detached signature must NOT raise yet (debounce)"
reconcile_checkout_cleanliness
[ -s "$CHECKOUT_CLEAN_STATE" ]          || fail "(A5) a detached checkout persisting 2 ticks must record a violation"
grep -q 'detached detached' "$JLOG"     || fail "(A5) journal must flag detached=detached: $(cat "$JLOG")"
build_checkout_cleanliness
case "${CHECKOUT_CLEAN:-}" in *"DETACHED"*) : ;; *) fail "(A5) row must mention DETACHED, got: [${CHECKOUT_CLEAN:-}]" ;; esac
ok

# ── (A6) RECOVERY: once the checkout is clean again the row/state clears on the next tick ─────────
new_main a6
printf 'oops\n' > "$MAIN/lib.sh"; git -C "$MAIN" add -A
tick 2
[ -s "$CHECKOUT_CLEAN_STATE" ]          || fail "(A6) fixture: violation must be recorded first"
git -C "$MAIN" reset -q --hard HEAD     # human resolves it
reconcile_checkout_cleanliness
[ ! -e "$CHECKOUT_CLEAN_STATE" ]        || fail "(A6) a recovered checkout must CLEAR its state file"
[ ! -e "$CHECKOUT_CLEAN_PENDING" ]      || fail "(A6) a recovered checkout must CLEAR its pending debounce file"
build_checkout_cleanliness
[ -z "${CHECKOUT_CLEAN:-}" ]           || fail "(A6) a recovered checkout must render an EMPTY row"
ok

# ════════════════════════════════════════════════════════════════════════════════════════════════
# HERD-414 — the scribe's sanctioned $BACKLOG_FILE write window must never false-red
# ════════════════════════════════════════════════════════════════════════════════════════════════

# ── (A7) SCRIBE_BACKEND=file: a sampled mid-write BACKLOG.md raises NOTHING, even across many ticks ─
new_main a7
printf 'queued item #1\n' > "$MAIN/BACKLOG.md"; git -C "$MAIN" add -A   # models the scribe's write-to-commit window
( SCRIBE_BACKEND=file BACKLOG_FILE=BACKLOG.md tick 5 )
[ ! -e "$CHECKOUT_CLEAN_STATE" ]         || fail "(A7) an exempted BACKLOG_FILE must never write the state file"
[ "$(jcount checkout_unclean)" = "0" ]   || fail "(A7) an exempted BACKLOG_FILE must never journal: $(cat "$JLOG")"
build_checkout_cleanliness
[ -z "${CHECKOUT_CLEAN:-}" ]             || fail "(A7) an exempted BACKLOG_FILE must render an EMPTY row, got: [${CHECKOUT_CLEAN:-}]"
git -C "$MAIN" reset -q --hard HEAD; : > "$JLOG"
ok

# ── (A8) SCRIBE_BACKEND!=file: the SAME dirty BACKLOG.md persisting 2+ ticks still reds ───────────
new_main a8
printf 'queued item #1\n' > "$MAIN/BACKLOG.md"; git -C "$MAIN" add -A
( SCRIBE_BACKEND=linear BACKLOG_FILE=BACKLOG.md tick 1 )
[ ! -e "$CHECKOUT_CLEAN_STATE" ]         || fail "(A8) tick 1 must still debounce (no raise yet) even when not exempt"
( SCRIBE_BACKEND=linear BACKLOG_FILE=BACKLOG.md tick 1 )
[ -s "$CHECKOUT_CLEAN_STATE" ]           || fail "(A8) a dirty BACKLOG.md under a NON-file backend must red after 2 ticks"
grep -q 'BACKLOG.md' "$JLOG"             || fail "(A8) journal must name BACKLOG.md: $(cat "$JLOG")"
ok

# ── (A9) any OTHER dirty path is unaffected by the exemption — still reds once it persists ────────
new_main a9
printf 'code v2\n' > "$MAIN/lib.sh"; git -C "$MAIN" add -A
( SCRIBE_BACKEND=file BACKLOG_FILE=BACKLOG.md tick 2 )
[ -s "$CHECKOUT_CLEAN_STATE" ]           || fail "(A9) a foreign dirty path (lib.sh) must still red under SCRIBE_BACKEND=file"
grep -q 'lib.sh' "$JLOG"                 || fail "(A9) journal must name lib.sh: $(cat "$JLOG")"
ok

# ── (A10) the exemption is EXACT: a different path is never swept in by a loose match ─────────────
new_main a10
mkdir -p "$MAIN/sub"; printf 'x\n' > "$MAIN/sub/BACKLOG.md"; git -C "$MAIN" add -A
( SCRIBE_BACKEND=file BACKLOG_FILE=BACKLOG.md tick 2 )
[ -s "$CHECKOUT_CLEAN_STATE" ]           || fail "(A10) sub/BACKLOG.md must NOT be swept into the exact-path exemption"
grep -q 'sub/BACKLOG.md' "$JLOG"         || fail "(A10) journal must name sub/BACKLOG.md: $(cat "$JLOG")"
ok

# ════════════════════════════════════════════════════════════════════════════════════════════════
# PART B — the sandboxed baseline leg leaves the shared checkout byte-identical (the ROOT-CAUSE fix)
# ════════════════════════════════════════════════════════════════════════════════════════════════
# A STUB project health command that models the contamination writer: it stages its whole $PWD (git
# add -A) and drops a new file, then fails with a TAP 'not ok'. Pre-fix, the baseline leg ran this
# INSIDE the live shared checkout ($MAIN) — staging its tree exactly like the incident. Post-fix, the
# base suite is sandboxed, so $MAIN is byte-identical before == after.
STUB="$T/hc-contaminate.sh"
cat > "$STUB" <<'STUB'
#!/usr/bin/env bash
# Runs with cwd = the dir under test. Mimics a suite test that mutates $PWD.
printf 'staged by a rogue suite test\n' > contaminant.txt 2>/dev/null || true
git add -A >/dev/null 2>&1 || true
printf '1..1\nnot ok 1 deliberate-fail\n'
exit 1
STUB
chmod +x "$STUB"

# A shared checkout ($BMAIN) + a PR worktree of the SAME repo (so they share the object store, as $MAIN
# and a builder worktree do in production).
BMAIN="$T/bmain"; mkdir -p "$BMAIN"
git -C "$BMAIN" init -q
git -C "$BMAIN" checkout -q -B main
git -C "$BMAIN" config user.email t@t.test; git -C "$BMAIN" config user.name tester
printf 'code v1\n' > "$BMAIN/lib.sh"
git -C "$BMAIN" add -A; git -C "$BMAIN" commit -q -m init
PRWT="$T/prwt"
git -C "$BMAIN" worktree add -q -b pr "$PRWT" >/dev/null 2>&1 || fail "(B) could not create PR worktree"
printf 'code v2\n' > "$PRWT/lib.sh"; git -C "$PRWT" add -A; git -C "$PRWT" commit -q -m "pr change"

BCACHE="$T/bcache"; mkdir -p "$BCACHE"
MAIN_STATUS_BEFORE="$(git -C "$BMAIN" status --porcelain)"
MAIN_HEAD_BEFORE="$(git -C "$BMAIN" rev-parse HEAD)"
[ -z "$MAIN_STATUS_BEFORE" ] || fail "(B) fixture: shared checkout must start clean"

# Run the REAL healthcheck heavy gate with the watcher's baseline seam pointed at the shared checkout.
OUT="$(env \
  HERD_CONFIG_FILE="$T/no-such-config" \
  HEALTHCHECK_CMD="bash $STUB" \
  DEFAULT_BRANCH="main" \
  HERD_BASELINE_DIR="$BMAIN" \
  HERD_BASELINE_CACHE="$BCACHE" \
  BASELINE_AWARE_GATE=on \
  bash "$HC" "$PRWT" --heavy 2>&1)"; BRC=$?

MAIN_STATUS_AFTER="$(git -C "$BMAIN" status --porcelain)"
MAIN_HEAD_AFTER="$(git -C "$BMAIN" rev-parse HEAD)"

# ── (B1) the shared checkout is BYTE-IDENTICAL: clean before == clean after, HEAD unmoved ─────────
[ -z "$MAIN_STATUS_AFTER" ] || fail "(B1) baseline leg CONTAMINATED the shared checkout — git status now: [$MAIN_STATUS_AFTER] — $OUT"
[ "$MAIN_HEAD_BEFORE" = "$MAIN_HEAD_AFTER" ] || fail "(B1) baseline leg moved the shared checkout HEAD ($MAIN_HEAD_BEFORE → $MAIN_HEAD_AFTER)"
[ ! -e "$BMAIN/contaminant.txt" ] || fail "(B1) baseline leg wrote a file into the shared checkout (contaminant.txt)"
ok

# ── (B2) the baseline leg actually RAN (inherited-failure downgrade), proving the sandbox executed ─
#         the suite — otherwise (B1) would pass vacuously by never touching the base at all.
printf '%s\n' "$OUT" | grep -q "INHERITED BASE FAILURE" \
  || fail "(B2) the sandboxed base suite must have run and downgraded the inherited failure — $OUT"
[ "$BRC" -eq 0 ] || fail "(B2) an inherited-only failure must PASS the gate (exit 0), got $BRC — $OUT"
# And no sandbox worktree was leaked into the shared checkout's registry.
git -C "$BMAIN" worktree list 2>/dev/null | grep -q '/base' \
  && fail "(B2) the disposable base worktree was not cleaned up — $(git -C "$BMAIN" worktree list)"
ok

echo "ALL PASS: test-checkout-cleanliness.sh ($pass checks)"
