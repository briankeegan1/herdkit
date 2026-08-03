#!/usr/bin/env bash
# test-main-health-contam-reconcile.sh — hermetic test for HERD-500: reconciling
# $TREES/.agent-watch-main-health-contam against LIVE git status every tick.
#
# _main_health_contaminated (HERD-452) stamps this file the instant a main-health dispatch is withheld
# because $MAIN failed _main_checkout_sound — but historically nothing ever looked at it again. Dispatch
# itself already self-heals (_main_checkout_sound is read fresh on every _main_health_dispatch call), so
# a healed checkout silently resumed verdicts — but the marker just sat there, unexamined, and no row
# named that main-health had gone dark while it stood. Live: a dirty-tree flag stayed set for 24h+ after
# the tree was provably clean again, with main-health quietly not running the whole time and nothing on
# the console saying why.
#
# Asserted here, driving the REAL functions from scripts/herd/agent-watch.sh (AGENT_WATCH_LIB=1):
#   (a) STANDING — while $MAIN stays dirty, the contam marker survives a reconcile tick (no
#       contam_cleared journal) and build_main_health_contam paints a visible
#       'main-health suppressed · checkout contaminated <sha>' row.
#   (b) HEALED — the moment $MAIN is clean again, _main_health_contam_recheck clears the marker,
#       journals contam_cleared exactly once, and the row disappears.
#   (c) RENDER SELF-HEALS TOO — build_main_health_contam clears a stale marker on its own even when the
#       tick-level recheck was skipped (mirrors build_main_freshness's HERD-455 belt-and-suspenders).
#   (d) VERDICTS RESUME — reconcile_main_health dispatches and collects a real verdict for the healed
#       sha, proving the suppression was never a SECOND gate, only visibility.
#   (e) LEVER OFF — MAIN_HEALTH_TICK=off is byte-inert: no clear, no journal, no row.
#
# Hermetic: a throwaway git fixture stands in for $MAIN; no network, no model, no herdr.
# Run:  bash tests/test-main-health-contam-reconcile.sh
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

REPO="$T/main"; TREES_DIR="$T/trees"; mkdir -p "$REPO" "$TREES_DIR"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name  tester
printf 'seed\n' > "$REPO/seed.txt"
git -C "$REPO" add -A && git -C "$REPO" commit -q -m "Merge pull request #77 from someone/branch"

HC="$T/hc.sh"
cat > "$HC" <<'HCSTUB'
#!/usr/bin/env bash
echo "✅ clean"; exit 0
HCSTUB
chmod +x "$HC"

BIN="$T/bin"; mkdir -p "$BIN"
cat > "$BIN/gh" <<'GHSTUB'
#!/usr/bin/env bash
case "$1 $2" in
  "run list") printf '\n'; exit 0 ;;
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
for fn in _main_health_contam_recheck build_main_health_contam _main_health_contam_clear _main_checkout_sound; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined after sourcing"
done

herd_driver_notify() { :; }
_main_health_scribe() { :; }

jcount() { local n; n="$(grep -c "$1" "$JOURNAL_FILE" 2>/dev/null)" || n=0; printf '%s' "${n:-0}"; }
settle() {
  local n=0
  while [ "$n" -lt 400 ]; do
    ls "$TREES_DIR"/.health-dispatch-main-* >/dev/null 2>&1 && break
    ls "$TREES_DIR"/.health-inflight-main-* >/dev/null 2>&1 || break
    sleep 0.05; n=$((n + 1))
  done
  _collect_main_health
}

MAIN_HEALTH_TICK=on
MAIN_HEALTH_RECHECK_MINS=0
MAIN_HEALTH_AUTOFIX=off

_SHA0="$(git -C "$REPO" rev-parse HEAD)"
_STALE_SIG="${_SHA0}|dirty"

# ── (a) STANDING: a stale marker survives a reconcile tick while $MAIN is genuinely dirty ─────────────
: > "$JOURNAL_FILE"
printf '%s\n' "$_STALE_SIG" > "$TREES_DIR/.agent-watch-main-health-contam"
printf 'uncommitted change\n' >> "$REPO/seed.txt"          # tracked-modified, not staged — a real offender
_main_checkout_sound >/dev/null 2>&1 && fail "(a) precondition: \$MAIN must read dirty right now"
_main_health_contam_recheck
[ -s "$TREES_DIR/.agent-watch-main-health-contam" ] \
  || fail "(a) a marker for a genuinely-dirty checkout must NOT be cleared"
[ "$(jcount '"result":"contam_cleared"')" -eq 0 ] || fail "(a) no contam_cleared journal while still dirty"
build_main_health_contam
[ -n "${MAIN_HEALTH_SUPPRESSED:-}" ] || fail "(a) build_main_health_contam must paint a row while contaminated"
case "$MAIN_HEALTH_SUPPRESSED" in
  *"main-health suppressed"*"checkout contaminated"*"${_SHA0:0:7}"*) : ;;
  *) fail "(a) suppression row missing expected text: $MAIN_HEALTH_SUPPRESSED" ;;
esac
ok "(a) a standing contamination keeps the marker AND paints a visible suppression row"

# ── (b) HEALED: cleaning the tree clears the marker and journals contam_cleared exactly once ──────────
git -C "$REPO" checkout -q -- seed.txt                      # heal the tree
_main_checkout_sound >/dev/null 2>&1 || fail "(b) precondition: \$MAIN must read sound now"
_main_health_contam_recheck
[ ! -e "$TREES_DIR/.agent-watch-main-health-contam" ] || fail "(b) a healed checkout must clear the marker"
[ "$(jcount '"result":"contam_cleared".*"reason":"dirty"')" -eq 1 ] \
  || fail "(b) exactly one contam_cleared(reason=dirty) journal expected — journal: $(cat "$JOURNAL_FILE")"
build_main_health_contam
[ -z "${MAIN_HEALTH_SUPPRESSED:-}" ] || fail "(b) the suppression row must disappear once healed"
# A second recheck on an already-clear marker is a silent no-op — no re-journal.
_main_health_contam_recheck
[ "$(jcount '"result":"contam_cleared"')" -eq 1 ] || fail "(b2) a cleared marker must never re-journal"
ok "(b) a healed checkout clears the marker, journals contam_cleared ONCE, and drops the row"

# ── (c) RENDER SELF-HEALS: build_main_health_contam clears a stale marker even without a prior recheck ─
: > "$JOURNAL_FILE"
printf '%s\n' "$_STALE_SIG" > "$TREES_DIR/.agent-watch-main-health-contam"   # $MAIN is ALREADY clean here
build_main_health_contam
[ -z "${MAIN_HEALTH_SUPPRESSED:-}" ] || fail "(c) build_main_health_contam must not paint a disproved row"
[ ! -e "$TREES_DIR/.agent-watch-main-health-contam" ] || fail "(c) build_main_health_contam must clear a disproved marker"
[ "$(jcount '"result":"contam_cleared"')" -eq 1 ] || fail "(c) the render-path clear must still journal once"
ok "(c) the render itself self-heals a stale marker, never painting a row the live tree has disproved"

# ── (d) VERDICTS RESUME: reconcile_main_health dispatches + collects a real verdict for the healed sha ─
reconcile_main_health || fail "(d) reconcile_main_health returned non-zero"
settle
[ "$(jcount '"result":"green"')" -eq 1 ] || fail "(d) the healed sha should reach a green main-health verdict"
ok "(d) main-health verdicts resume on their own once the checkout is sound — the marker only gated visibility"

# ── (e) LEVER OFF: MAIN_HEALTH_TICK=off is byte-inert ──────────────────────────────────────────────────
: > "$JOURNAL_FILE"
printf '%s\n' "$_STALE_SIG" > "$TREES_DIR/.agent-watch-main-health-contam"
MAIN_HEALTH_TICK=off
_main_health_contam_recheck
build_main_health_contam
[ -s "$TREES_DIR/.agent-watch-main-health-contam" ] || fail "(e) lever off must leave the marker untouched"
[ -z "${MAIN_HEALTH_SUPPRESSED:-}" ] || fail "(e) lever off must never paint the row"
[ "$(jcount '"result":"contam_cleared"')" -eq 0 ] || fail "(e) lever off must never journal"
MAIN_HEALTH_TICK=on
ok "(e) MAIN_HEALTH_TICK=off is fully byte-inert for the contam reconcile"

echo
echo "ALL PASS ($pass checks) — the withheld-verdict marker is reconciled against LIVE git status every tick, and never suppresses invisibly."
