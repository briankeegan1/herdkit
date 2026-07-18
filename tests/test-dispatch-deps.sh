#!/usr/bin/env bash
# test-dispatch-deps.sh — hermetic, network-free test of the dispatch-vs-dependency intent surface:
#   • herd depend <link>#<id>          — records a blocked-on row dep-watcher.sh's parser accepts
#   • herd report --to <link> --dep    — files the issue AND records the resulting dep
#   • herd report --to <link>          — DEFAULT stays fire-and-forget (records NO dep)
#   • herd deps list / demote / rm     — inspect + edit deps (a dep is editable data, never stuck)
#
# Everything is stubbed: a temp project with a .herd/links registry, and a FAKE `gh` on PATH that
# logs calls and returns canned output (issue create → a URL; issue list → open.json; issue view →
# a state). The blocked-on row format is asserted against dep-watcher.sh's OWN code (sourced in
# DEP_WATCHER_LIB=1 mode) so we prove compatibility, not just a self-consistent shape.
# Run:  bash tests/test-dispatch-deps.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
HERD="$HERE/../bin/herd"
WATCHER="$HERE/../scripts/herd/dep-watcher.sh"

command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 required" >&2; exit 1; }
[ -f "$HERD" ]    || { echo "FAIL: bin/herd not found at $HERD" >&2; exit 1; }
[ -f "$WATCHER" ] || { echo "FAIL: dep-watcher.sh not found at $WATCHER" >&2; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass(){ PASS=$((PASS+1)); }

# ── Temp project: report backend github, one registered peer link "provider-lib". ───────────────
P="$T/proj"
mkdir -p "$P/.herd"
cat > "$P/.herd/config" <<EOF
PROJECT_ROOT="$P"
WORKSPACE_NAME="widgets"
HERD_REPO="acme/widgets"
HERD_REPORT_BACKEND="github"
EOF
cat > "$P/.herd/links" <<'EOF'
# name|owner/repo|backend|target
provider-lib|acme/provider|github|
EOF
DEPS="$P/.herd/deps"

# ── Fake gh: logs args; issue create → URL, issue list → open.json, issue view → open state. ─────
GHLOG="$T/gh.log"
mkdir -p "$T/bin"
echo '[]' > "$T/open.json"
cat > "$T/bin/gh" <<EOF
#!/usr/bin/env bash
echo "gh \$*" >> "$GHLOG"
case "\$1 \$2" in
  "issue create") echo "https://github.com/acme/provider/issues/77" ;;
  "issue list")   cat "$T/open.json" 2>/dev/null || echo '[]' ;;
  "issue view")   echo '{"state":"OPEN"}' ;;
  *) : ;;
esac
EOF
chmod +x "$T/bin/gh"

# herd <args...> under the temp project, non-interactive, fake gh on PATH.
run(){ ( cd "$P" && PATH="$T/bin:$PATH" HERD_CONFIG_FILE="$P/.herd/config" HERD_NONINTERACTIVE=1 \
                    bash "$HERD" "$@" ); }

# watcher_accepts <deps-file> <ref> — TRUE iff dep-watcher.sh's OWN removal code (real engine code,
# sourced in lib mode) can locate + strip the blocked-on row for <ref>. Runs on a throwaway copy in
# a subshell so it never disturbs the live deps file or this shell's env.
watcher_accepts(){
  local src="$1" ref="$2"
  (
    cp "$src" "$T/deps.copy"
    export DEP_WATCHER_LIB=1 HERD_CONFIG_FILE="$T/no-such" WORKTREES_DIR="$T" \
           PROJECT_ROOT="$P" WORKSPACE_NAME="widgets"
    # shellcheck source=/dev/null
    . "$WATCHER" >/dev/null 2>&1 || exit 1
    DEPS_FILE="$T/deps.copy" SINCE_FILE="$T/depwatcher.since"
    grep -q "blocked-on: $ref" "$DEPS_FILE" || exit 1   # our row is present…
    _dw_remove_dep "$ref"                                # …and the watcher's parser removes it.
    grep -q "blocked-on: $ref" "$DEPS_FILE" && exit 1
    exit 0
  )
}

# ── 1. herd depend records a blocked-on row the watcher accepts, stamped with since=. ────────────
out="$(run depend provider-lib#42 2>&1)" || fail "herd depend exited non-zero: $out"
[ -f "$DEPS" ] || fail "herd depend did not create .herd/deps"
grep -q '^blocked-on: provider-lib#42' "$DEPS" || fail "depend did not write a blocked-on row — ($(cat "$DEPS"))"
grep -q 'since=' "$DEPS" || fail "depend did not stamp since= on the row"
watcher_accepts "$DEPS" "provider-lib#42" || fail "dep-watcher.sh's parser does NOT accept the recorded row"
pass

# ── 2. Bad refs / unknown links are rejected loudly (no row written). ────────────────────────────
run depend not-a-ref     >/dev/null 2>&1 && fail "depend accepted a ref with no '#'"
run depend 'has space#1'  >/dev/null 2>&1 && fail "depend accepted a ref containing whitespace"
run depend nosuch-peer#9 >/dev/null 2>&1 && fail "depend accepted a link not in .herd/links"
grep -q 'nosuch-peer' "$DEPS" && fail "depend wrote a row for an unresolved link" || true
pass

# ── 3. herd deps list surfaces the dep + its resolved upstream state. ────────────────────────────
out="$(run deps list 2>&1)" || fail "deps list exited non-zero: $out"
echo "$out" | grep -q 'provider-lib#42' || fail "deps list did not show the recorded dep — ($out)"
echo "$out" | grep -q 'blocked-on'      || fail "deps list did not label the dep kind — ($out)"
echo "$out" | grep -q 'state=open'      || fail "deps list did not resolve upstream state via the backend — ($out)"
pass

# ── 4. demote reclassifies blocked-on → non-blocking watch; the watcher no longer blocks on it. ──
out="$(run deps demote provider-lib#42 2>&1)" || fail "deps demote exited non-zero: $out"
grep -q '^watch: provider-lib#42' "$DEPS"      || fail "demote did not write a watch row — ($(cat "$DEPS"))"
grep -q '^blocked-on: provider-lib#42' "$DEPS" && fail "demote left the blocked-on row in place" || true
grep -q 'since=' "$DEPS" || fail "demote dropped the since= stamp"
watcher_accepts "$DEPS" "provider-lib#42" && fail "watcher still sees a demoted watch as blocked-on" || true
pass

# ── 5. depend on a demoted ref PROMOTES it back to blocked-on (a dep is never stuck). ────────────
out="$(run depend provider-lib#42 2>&1)" || fail "re-depend (promote) exited non-zero: $out"
grep -q '^blocked-on: provider-lib#42' "$DEPS" || fail "re-depend did not promote the watch back to blocked-on"
grep -q '^watch: provider-lib#42' "$DEPS" && fail "re-depend left a stale watch row" || true
pass

# ── 6. rm drops the dep; a second rm is a loud no-op (nothing left to remove). ────────────────────
out="$(run deps rm provider-lib#42 2>&1)" || fail "deps rm exited non-zero: $out"
grep -q 'provider-lib#42' "$DEPS" && fail "deps rm left the row behind — ($(cat "$DEPS"))" || true
run deps rm provider-lib#42 >/dev/null 2>&1 && fail "deps rm of an absent dep should fail loudly"
pass

# ── 7. herd report --to <link> --dep files the issue AND records the resulting dep. ──────────────
rm -f "$DEPS"; : > "$GHLOG"; echo '[]' > "$T/open.json"
out="$(run report --to provider-lib --dep "provider API endpoint missing" 2>&1)" \
  || fail "report --to --dep exited non-zero: $out"
grep -q -- 'issue create -R acme/provider' "$GHLOG" || fail "report --dep did not file on the peer repo — ($out)"
[ -f "$DEPS" ] || fail "report --dep did not record any dep"
grep -q '^blocked-on: provider-lib#77' "$DEPS" \
  || fail "report --dep did not record blocked-on from the filed item id — ($(cat "$DEPS"))"
watcher_accepts "$DEPS" "provider-lib#77" || fail "report --dep wrote a row the watcher rejects"
pass

# ── 8. DEFAULT herd report --to stays fire-and-forget — files, records NO dep. ───────────────────
rm -f "$DEPS"; : > "$GHLOG"; echo '[]' > "$T/open.json"
out="$(run report --to provider-lib "another provider issue" 2>&1)" \
  || fail "default report --to exited non-zero: $out"
grep -q -- 'issue create -R acme/provider' "$GHLOG" || fail "default report --to did not file — ($out)"
if [ -f "$DEPS" ] && grep -q 'blocked-on' "$DEPS"; then
  fail "default report --to recorded a dep (should stay fire-and-forget) — ($(cat "$DEPS"))"
fi
pass

# ── 9. report --dep WITHOUT --to is rejected (a dep must name its target peer). ───────────────────
run report --dep "orphan dep" >/dev/null 2>&1 && fail "report --dep without --to should fail loudly"
pass

# ── 10. Anchored-ref-match (HERD-389): with provider-lib#4 AND provider-lib#42 both recorded,
# rm/demote of #4 must address EXACTLY that row and leave #42 untouched — a substring/prefix ref
# test (the pre-fix bug) would also strip or reclassify #42 when closing #4.
rm -f "$DEPS"; : > "$GHLOG"; echo '[]' > "$T/open.json"
run depend provider-lib#4  >/dev/null 2>&1 || fail "depend provider-lib#4 exited non-zero"
run depend provider-lib#42 >/dev/null 2>&1 || fail "depend provider-lib#42 exited non-zero"
grep -q '^blocked-on: provider-lib#4  ' "$DEPS"  || fail "expected a blocked-on row for #4 — ($(cat "$DEPS"))"
grep -q '^blocked-on: provider-lib#42' "$DEPS"   || fail "expected a blocked-on row for #42 — ($(cat "$DEPS"))"

out="$(run deps rm provider-lib#4 2>&1)" || fail "deps rm provider-lib#4 exited non-zero: $out"
grep -q '^blocked-on: provider-lib#4  ' "$DEPS" \
  && fail "deps rm of #4 left the #4 row in place — ($(cat "$DEPS"))" || true
grep -q '^blocked-on: provider-lib#42' "$DEPS" \
  || fail "deps rm of #4 also stripped #42 — anchored-ref-match regression ($(cat "$DEPS"))"
watcher_accepts "$DEPS" "provider-lib#42" || fail "dep-watcher.sh's parser no longer accepts #42 after rm of #4"
pass

run depend provider-lib#4 >/dev/null 2>&1 || fail "re-depend provider-lib#4 exited non-zero"
out="$(run deps demote provider-lib#4 2>&1)" || fail "deps demote provider-lib#4 exited non-zero: $out"
grep -q '^watch: provider-lib#4  '        "$DEPS" || fail "demote of #4 did not write its watch row — ($(cat "$DEPS"))"
grep -q '^blocked-on: provider-lib#42'    "$DEPS" \
  || fail "demote of #4 also reclassified #42 — anchored-ref-match regression ($(cat "$DEPS"))"
pass

echo "ALL PASS ($PASS checks)"
