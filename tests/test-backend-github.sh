#!/usr/bin/env bash
# test-backend-github.sh — hermetic test of the GitHub-Issues work-tracker backend's 3-op
# contract using a FAKE `gh` on PATH. No network, no real gh, no repo writes. The stub logs every
# invocation and returns canned output, so the test asserts CALL SHAPE (not GitHub behavior).
# Run:  bash tests/test-backend-github.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BACKEND="$HERE/../scripts/herd/backends/github.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass(){ PASS=$((PASS+1)); }

# Fake gh: logs its args to $T/gh.log and emits canned output keyed on "<noun> <verb>".
GHLOG="$T/gh.log"
mkdir -p "$T/bin"
cat > "$T/bin/gh" <<EOF
#!/usr/bin/env bash
echo "gh \$*" >> "$GHLOG"
case "\$1 \$2" in
  "issue create")  echo "https://github.com/acme/widgets/issues/42" ;;
  "issue list")    printf '%s' '[{"number":7,"title":"first open issue"},{"number":9,"title":"second open issue"}]' ;;
  "issue comment") : ;;
  "issue close")   : ;;
  "issue view")
    _vnum=""
    for _va in "\$@"; do
      [ -z "\${_va##*[!0-9]*}" ] || { _vnum="\$_va"; break; }
    done
    case "\$_vnum" in
      7)  printf '{"state":"OPEN","number":7}\n'   ;;
      42) printf '{"state":"CLOSED","number":42}\n' ;;
      *)  printf '{"state":"OPEN","number":0}\n'    ;;
    esac
    ;;
  *) : ;;
esac
EOF
chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH"

# The backend reads $HERD_REPO from config; set it so every op should target this repo.
export HERD_REPO="acme/widgets"

run() {
  ( cd "$T" && . "$BACKEND"
    _BACKEND_RESULT=""
    ITEM_STATE=""
    "$@"
    printf 'RESULT=%s\n' "${_BACKEND_RESULT:-}"
    printf 'ITEM_STATE=%s\n' "${ITEM_STATE:-}" )
}

# 1. add_item → gh issue create with the configured repo, title, and body; returns DONE + URL.
out="$(run _backend_add_item REQ1 "add a dark-mode toggle")"
echo "$out" | grep -q "RESULT=DONE" || fail "add_item did not report DONE ($out)"
echo "$out" | grep -q "https://github.com/acme/widgets/issues/42" || fail "add_item did not surface the created issue URL"
grep -q "issue create" "$GHLOG" || fail "add_item did not invoke 'gh issue create'"
grep -q -- "-R acme/widgets" "$GHLOG" || fail "add_item did not target HERD_REPO (-R acme/widgets)"
grep -q -- "--title add a dark-mode toggle" "$GHLOG" || fail "add_item did not pass the request as --title"
grep -q -- "--body add a dark-mode toggle" "$GHLOG" || fail "add_item did not pass the request as --body"
pass

# 2. list_open → parses the canned `gh issue list` JSON to "#<number> <title>" lines.
open="$(run _backend_list_open)"
grep -q -- "issue list -R acme/widgets --state open" "$GHLOG" || fail "list_open did not invoke 'gh issue list --state open' on HERD_REPO"
echo "$open" | grep -q "^#7 first open issue$"  || fail "list_open missing '#7 first open issue' ($open)"
echo "$open" | grep -q "^#9 second open issue$" || fail "list_open missing '#9 second open issue'"
pass

# 3. mark_shipped → comments the PR link then closes the matching issue (numeric slug = number).
: > "$GHLOG"   # reset log so we assert only this op's calls
ship="$(run _backend_mark_shipped 7 https://github.com/acme/widgets/pull/3)"
echo "$ship" | grep -q "RESULT=DONE" || fail "mark_shipped did not report DONE ($ship)"
grep -q -- "issue comment -R acme/widgets 7" "$GHLOG" || fail "mark_shipped did not comment on issue 7"
grep -q -- "--body Shipped via https://github.com/acme/widgets/pull/3" "$GHLOG" \
  || fail "mark_shipped did not link the PR in the comment body"
grep -q -- "issue close -R acme/widgets 7" "$GHLOG" || fail "mark_shipped did not close issue 7"
pass

# 4. item_state → CLOSED issue returns ITEM_STATE=closed.
: > "$GHLOG"
out="$(run _backend_item_state "provider-lib#42")"
echo "$out" | grep -q "ITEM_STATE=closed" || fail "_backend_item_state CLOSED did not return ITEM_STATE=closed ($out)"
grep -q -- "issue view -R acme/widgets 42" "$GHLOG" || fail "_backend_item_state did not call 'gh issue view'"
pass

# 5. item_state → OPEN issue returns ITEM_STATE=open.
out="$(run _backend_item_state "provider-lib#7")"
echo "$out" | grep -q "ITEM_STATE=open" || fail "_backend_item_state OPEN did not return ITEM_STATE=open ($out)"
pass

# 5b. update_state (done) → closes the resolved issue with reason "completed"; never creates one.
#     (Intent dispatch, gh #139: a state change transitions the EXISTING issue, not a new one.)
: > "$GHLOG"
us="$(run _backend_update_state 7 done)"
echo "$us" | grep -q "RESULT=DONE" || fail "update_state did not report DONE ($us)"
grep -q -- "issue close -R acme/widgets 7 --reason completed" "$GHLOG" || fail "update_state (done) did not close issue 7 as completed"
grep -q -- "issue create" "$GHLOG" && fail "update_state must NOT file a new issue (the #139 junk-issue bug)"
pass

# 5c. update_state (canceled) → closes with reason "not planned".
: > "$GHLOG"; run _backend_update_state 7 canceled >/dev/null
grep -q -- "issue close -R acme/widgets 7 --reason not planned" "$GHLOG" || fail "update_state (canceled) did not close as not planned"
pass

# 5d. update_state (in-progress) → GitHub has no in-progress state, so ensure the issue is OPEN
#     (reopen) plus a marker comment; never a close.
: > "$GHLOG"; run _backend_update_state 7 in-progress >/dev/null
grep -q -- "issue reopen -R acme/widgets 7" "$GHLOG"  || fail "update_state (in-progress) did not reopen the issue"
grep -q -- "issue comment -R acme/widgets 7" "$GHLOG" || fail "update_state (in-progress) did not leave a marker comment"
grep -q -- "issue close" "$GHLOG"                     && fail "update_state (in-progress) must not close the issue"
pass

# 5e. update_state with an UNKNOWN target state → NOCHANGE, no close/reopen (files nothing).
: > "$GHLOG"
us2="$(run _backend_update_state 7 frobnicate 2>/dev/null)"
echo "$us2" | grep -q "RESULT=NOCHANGE" || fail "update_state on an unknown state should be NOCHANGE ($us2)"
grep -q -- "issue close"  "$GHLOG" && fail "update_state on an unknown state should not close the issue"
grep -q -- "issue reopen" "$GHLOG" && fail "update_state on an unknown state should not reopen the issue"
pass

# 6. absent gh degrades loudly (no silent success).
if ( cd "$T"; export PATH="/nonexistent"; . "$BACKEND"; _backend_list_open ) >/dev/null 2>&1; then
  fail "list_open should fail when gh is absent"
fi
pass

echo "ALL PASS ($PASS checks)"
