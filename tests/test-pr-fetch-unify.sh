#!/usr/bin/env bash
# test-pr-fetch-unify.sh — hermetic tests for HERD-675: unify the per-tick PR-list fetch.
#
# Before this task, the bash render leg's `_prs_fetch_tick` (`gh pr list --json ...`, git-pr.sh) and
# pysrc/herd/live_runtime.py's `discover_via_graphql` (`gh api graphql`) each independently fetched the
# open-PR roster every tick. This proves the unification's bash-side half, per AGENTS.md's "prove your
# lever both ways":
#   • PR_FETCH_UNIFY off (default/unset) — byte-identical: `_prs_fetch_tick` ALWAYS calls `gh pr list`,
#     even with a fresh, valid unified cache sitting right there on disk.
#   • on + a fresh cache — `_prs_fetch_tick` consumes the cache and calls `gh pr list` ZERO times.
#   • on + a missing/stale/malformed cache — falls straight back to `gh pr list`, exactly like off.
#   • the cache-read projection is FIELD-PARITY-CORRECT: it returns exactly (and only) the fields
#     `_watcher_tick_fields()` would have requested from a live `gh pr list` call, with the SAME
#     object shapes (`author`/`assignees`/`labels` as `gh` itself returns them) real downstream
#     consumers (`login()`/`has_label()` in agent-watch.sh) already read.
#   • the cache path is seat-stamped — two seats never share a cache file.
#
# Fully hermetic: stubbed `gh` on PATH (network-free), no live worktree pool needed beyond a plain dir.
# Run:  bash tests/test-pr-fetch-unify.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../scripts/herd/agent-watch.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

[ -f "$WATCH" ] || fail "missing $WATCH"
command -v python3 >/dev/null 2>&1 || fail "python3 required"

# ── stub gh on PATH: `pr list` counts its own invocations to $GH_PR_LIST_CALLS ────────────────────
BIN="$T/bin"; mkdir -p "$BIN"
CALLS="$T/gh-pr-list-calls"
: > "$CALLS"
cat > "$BIN/gh" << STUB
#!/usr/bin/env bash
case "\$*" in
  *"pr list"*)
    printf 'x' >> "$CALLS"
    cat "\${GH_PR_LIST_JSON:-/dev/null}" 2>/dev/null || true
    exit "\${GH_PR_LIST_RC:-0}"
    ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$BIN/gh"
for cmd in git herdr; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$cmd"; chmod +x "$BIN/$cmd"
done
export PATH="$BIN:$PATH"
gh_calls() { wc -c < "$CALLS" | tr -d ' '; }

export AGENT_WATCH_LIB=1
export WORKTREES_DIR="$T/trees"; mkdir -p "$WORKTREES_DIR"
export HERD_CONFIG_FILE="$T/no-such-config"
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"
TREES="$WORKTREES_DIR"

for fn in _pr_fetch_unify_enabled _pr_fetch_cache_seat _pr_fetch_cache_path \
          _pr_fetch_cache_max_age_secs _pr_fetch_cache_read _prs_fetch_tick; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined after sourcing agent-watch.sh"
done

export GH_PR_LIST_RC=0
export GH_PR_LIST_JSON="$T/live.json"
printf '[{"number":900,"title":"live-fetch","headRefName":"feat/live","headRefOid":"livesha","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}]' \
  > "$GH_PR_LIST_JSON"

write_cache() {
  # write_cache <written_at_epoch>
  python3 -c '
import json, sys
epoch = int(sys.argv[1])
doc = {
    "written_at": epoch,
    "seat": "test-seat",
    "prs": [{
        "number": 42, "title": "cached-pr", "headRefName": "feat/cached",
        "headRefOid": "cachedsha", "mergeable": "CONFLICTING", "mergeStateStatus": "DIRTY",
        "baseRefName": "main", "reviewDecision": "REVIEW_REQUIRED", "isDraft": False,
        "body": "hello from cache",
        "author": {"login": "alice"},
        "assignees": [{"login": "bob"}],
        "labels": [{"name": "bug"}],
    }],
}
json.dump(doc, open(sys.argv[2], "w"))
' "$1" "$2"
}

# ── (1) OFF (unset): always calls gh, even with a fresh valid cache sitting right there ────────────
unset PR_FETCH_UNIFY
CACHE="$(_pr_fetch_cache_path)" || fail "(1) _pr_fetch_cache_path should resolve with TREES set"
write_cache "$(date +%s)" "$CACHE"
: > "$CALLS"
unset PRS_JSON PRS_LOOKUP_OK
_prs_fetch_tick
[ "$(gh_calls)" = "1" ] || fail "(1) PR_FETCH_UNIFY off must still call gh pr list, calls=$(gh_calls)"
printf '%s' "$PRS_JSON" | python3 -c 'import sys,json; d=json.load(sys.stdin); assert any(p.get("number")==900 for p in d), d' \
  || fail "(1) off must yield the LIVE fetch's PR, got: $PRS_JSON"
ok

# explicit off spellings behave the same
for v in off OFF "" 0 no garbage; do
  PR_FETCH_UNIFY="$v"
  _pr_fetch_unify_enabled && fail "(1b) PR_FETCH_UNIFY=$v must read as off"
done
unset PR_FETCH_UNIFY
ok

# ── (2) ON + fresh cache: _prs_fetch_tick consumes it, gh pr list is called ZERO times ─────────────
for v in on ON true 1 yes; do
  PR_FETCH_UNIFY="$v"
  _pr_fetch_unify_enabled || fail "(2) PR_FETCH_UNIFY=$v must read as on"
done
PR_FETCH_UNIFY=on
write_cache "$(date +%s)" "$CACHE"
: > "$CALLS"
unset PRS_JSON PRS_LOOKUP_OK
_prs_fetch_tick
[ "$(gh_calls)" = "0" ] || fail "(2) a fresh cache must skip the gh pr list round-trip entirely, calls=$(gh_calls)"
[ "${PRS_LOOKUP_OK:-}" = "1" ] || fail "(2) cache-served tick must set PRS_LOOKUP_OK=1, got ${PRS_LOOKUP_OK:-unset}"
printf '%s' "$PRS_JSON" | python3 -c 'import sys,json; d=json.load(sys.stdin); assert any(p.get("number")==42 for p in d), d' \
  || fail "(2) on+fresh-cache must yield the CACHED PR, got: $PRS_JSON"
ok

# ── (3) ON + stale cache: falls back to gh pr list exactly like off ────────────────────────────────
write_cache "$(( $(date +%s) - 3600 ))" "$CACHE"
: > "$CALLS"
unset PRS_JSON PRS_LOOKUP_OK
_prs_fetch_tick
[ "$(gh_calls)" = "1" ] || fail "(3) a stale cache must fall back to gh pr list, calls=$(gh_calls)"
printf '%s' "$PRS_JSON" | python3 -c 'import sys,json; d=json.load(sys.stdin); assert any(p.get("number")==900 for p in d), d' \
  || fail "(3) stale-cache fallback must yield the LIVE fetch's PR, got: $PRS_JSON"
ok

# ── (4) ON + missing cache: falls back ──────────────────────────────────────────────────────────────
rm -f "$CACHE"
: > "$CALLS"
unset PRS_JSON PRS_LOOKUP_OK
_prs_fetch_tick
[ "$(gh_calls)" = "1" ] || fail "(4) a missing cache must fall back to gh pr list, calls=$(gh_calls)"
ok

# ── (5) ON + malformed cache (invalid JSON): falls back, never crashes the tick ────────────────────
printf 'not-json{{{' > "$CACHE"
: > "$CALLS"
unset PRS_JSON PRS_LOOKUP_OK
_prs_fetch_tick
[ "$(gh_calls)" = "1" ] || fail "(5) a malformed cache must fall back to gh pr list, calls=$(gh_calls)"
[ "${PRS_LOOKUP_OK:-}" = "1" ] || fail "(5) fallback path must still resolve PRS_LOOKUP_OK, got ${PRS_LOOKUP_OK:-unset}"
ok

unset PR_FETCH_UNIFY

# ── (6) field-parity projection: exactly the requested fields, in gh's own object shapes ──────────
PR_FETCH_UNIFY=on
write_cache "$(date +%s)" "$CACHE"
base_fields="number,title,headRefName,headRefOid,mergeable,mergeStateStatus"
raw="$(_pr_fetch_cache_read "$base_fields")" || fail "(6) cache read should succeed with a fresh cache"
printf '%s' "$raw" | python3 -c '
import sys, json
prs = json.load(sys.stdin)
assert len(prs) == 1, prs
p = prs[0]
expected_keys = {"number","title","headRefName","headRefOid","mergeable","mergeStateStatus"}
assert set(p.keys()) == expected_keys, (set(p.keys()), expected_keys)
assert p["number"] == 42, p
assert p["title"] == "cached-pr", p
assert p["headRefName"] == "feat/cached", p
assert p["headRefOid"] == "cachedsha", p
assert p["mergeable"] == "CONFLICTING", p
assert p["mergeStateStatus"] == "DIRTY", p
' || fail "(6) base-field projection did not match expected keys/values, got: $raw"
ok

# extended fields (author/assignees/labels/reviewDecision/isDraft) — same gh-json shapes as a live fetch
ext_fields="number,author,assignees,labels,reviewDecision,isDraft"
raw="$(_pr_fetch_cache_read "$ext_fields")" || fail "(6b) cache read should succeed for extended fields"
printf '%s' "$raw" | python3 -c '
import sys, json
p = json.load(sys.stdin)[0]
assert p["author"] == {"login": "alice"}, p
assert p["assignees"] == [{"login": "bob"}], p
assert p["labels"] == [{"name": "bug"}], p
assert p["reviewDecision"] == "REVIEW_REQUIRED", p
assert p["isDraft"] is False, p
' || fail "(6b) extended-field projection (author/assignees/labels shapes) mismatch, got: $raw"
ok

unset PR_FETCH_UNIFY

# ── (7) seat isolation: distinct HERD_ENGINE_SEAT_ID values resolve to distinct cache paths ───────
HERD_ENGINE_SEAT_ID="seat-one"
p1="$(_pr_fetch_cache_path)" || fail "(7) cache path should resolve for seat-one"
HERD_ENGINE_SEAT_ID="seat-two"
p2="$(_pr_fetch_cache_path)" || fail "(7) cache path should resolve for seat-two"
[ "$p1" != "$p2" ] || fail "(7) two distinct seats must not resolve to the same cache path"
case "$p1" in "$TREES"/.pr-list-cache-*) ;; *) fail "(7) cache path must live under \$TREES, got $p1" ;; esac
unset HERD_ENGINE_SEAT_ID
ok

# ── (8) _pr_fetch_cache_path fails soft (rc 1, no output) with no pool configured ──────────────────
( unset TREES WORKTREES_DIR; _pr_fetch_cache_path >/dev/null ) \
  && fail "(8) cache path must fail (rc!=0) with no pool configured"
ok

echo "ALL PASS ($pass checks)"
