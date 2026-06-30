#!/usr/bin/env bash
# test-backend-linear.sh — hermetic test of the Linear GraphQL work-tracker backend's 3-op
# contract using a FAKE `curl` on PATH. No network, no real key, no repo writes. The stub logs
# every POST and returns canned JSON keyed on the GraphQL op in the request body, so the test
# asserts CALL SHAPE (which GraphQL mutations/queries get issued) and the parsed output — not
# Linear behavior. Run:  bash tests/test-backend-linear.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BACKEND="$HERE/../scripts/herd/backends/linear.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass(){ PASS=$((PASS+1)); }

# Fake curl: logs its args (which include the JSON {"query","variables"} payload and the auth
# header) to $T/curl.log and emits canned JSON keyed on the GraphQL op present in the payload.
CURLLOG="$T/curl.log"
mkdir -p "$T/bin"
cat > "$T/bin/curl" <<EOF
#!/usr/bin/env bash
echo "curl \$*" >> "$CURLLOG"
args="\$*"
case "\$args" in
  *issueCreate*)   echo '{"data":{"issueCreate":{"success":true,"issue":{"id":"iss_1","identifier":"ENG-42","url":"https://linear.app/acme/issue/ENG-42"}}}}' ;;
  *issueSearch*)   echo '{"data":{"issueSearch":{"nodes":[{"id":"iss_7","team":{"states":{"nodes":[{"id":"state_done"}]}}}]}}}' ;;
  *issueUpdate*)   echo '{"data":{"issueUpdate":{"success":true}}}' ;;
  *commentCreate*) echo '{"data":{"commentCreate":{"success":true}}}' ;;
  *"issues("*)     echo '{"data":{"issues":{"nodes":[{"identifier":"ENG-7","title":"first open issue"},{"identifier":"ENG-9","title":"second open issue"}]}}}' ;;
  *) echo '{"data":{}}' ;;
esac
EOF
chmod +x "$T/bin/curl"
export PATH="$T/bin:$PATH"

# The backend reads its key (and optional team) from .herd/secrets, i.e. the environment by the
# time it is sourced. Set them so add_item skips the team-lookup round-trip and targets this team.
export LINEAR_API_KEY="lin_test_key"
export LINEAR_TEAM_ID="team_xyz"

run() {
  ( cd "$T" && . "$BACKEND"
    _BACKEND_RESULT=""
    "$@"
    printf 'RESULT=%s\n' "${_BACKEND_RESULT:-}" )
}

# 1. add_item → issueCreate mutation carrying the title/body/teamId; returns DONE + the issue URL.
out="$(run _backend_add_item REQ1 "add a dark-mode toggle")"
echo "$out" | grep -q "RESULT=DONE" || fail "add_item did not report DONE ($out)"
echo "$out" | grep -q "https://linear.app/acme/issue/ENG-42" || fail "add_item did not surface the created issue URL"
grep -q "api.linear.app/graphql" "$CURLLOG" || fail "add_item did not POST to the Linear GraphQL endpoint"
grep -q "Authorization: lin_test_key" "$CURLLOG" || fail "add_item did not send the API key from secrets in the auth header"
grep -q "issueCreate" "$CURLLOG" || fail "add_item did not issue an 'issueCreate' mutation"
grep -q "add a dark-mode toggle" "$CURLLOG" || fail "add_item did not pass the request text as the issue title/body"
grep -q "team_xyz" "$CURLLOG" || fail "add_item did not target the configured team (teamId)"
pass

# 2. list_open → an 'issues' query, parsed to "#<identifier> <title>" lines.
: > "$CURLLOG"
open="$(run _backend_list_open)"
grep -q "issues(" "$CURLLOG" || fail "list_open did not issue an 'issues' query"
echo "$open" | grep -q "^#ENG-7 first open issue$"  || fail "list_open missing '#ENG-7 first open issue' ($open)"
echo "$open" | grep -q "^#ENG-9 second open issue$" || fail "list_open missing '#ENG-9 second open issue'"
pass

# 3. mark_shipped → resolves the issue, comments the PR link, then moves it to the Done state.
: > "$CURLLOG"
ship="$(run _backend_mark_shipped ENG-7 https://github.com/acme/widgets/pull/3)"
echo "$ship" | grep -q "RESULT=DONE" || fail "mark_shipped did not report DONE ($ship)"
grep -q "issueSearch" "$CURLLOG"   || fail "mark_shipped did not resolve the issue via issueSearch"
grep -q "commentCreate" "$CURLLOG" || fail "mark_shipped did not comment the PR link (commentCreate)"
grep -q "Shipped via https://github.com/acme/widgets/pull/3" "$CURLLOG" \
  || fail "mark_shipped did not link the PR in the comment body"
grep -q "issueUpdate" "$CURLLOG"   || fail "mark_shipped did not move the issue to Done (issueUpdate)"
grep -q "state_done" "$CURLLOG"     || fail "mark_shipped did not set the resolved Done stateId"
pass

# 4. absent key degrades loudly (no silent success), even with a fake curl available.
if ( cd "$T"; unset LINEAR_API_KEY; . "$BACKEND"; _backend_list_open ) >/dev/null 2>&1; then
  fail "list_open should fail when LINEAR_API_KEY is absent"
fi
pass

echo "ALL PASS ($PASS checks)"
