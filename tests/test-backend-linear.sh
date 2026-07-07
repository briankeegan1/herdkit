#!/usr/bin/env bash
# test-backend-linear.sh — hermetic test of the Linear GraphQL work-tracker backend's contract with
# the network stubbed. No real network, no real key, no repo writes. Two stubbing layers:
#   • Behavior tests OVERRIDE _linear_gql itself — it logs every (query, vars) round-trip to
#     $GQLLOG and returns canned JSON keyed on the GraphQL op in the query text. This lets the test
#     assert CALL SHAPE (which queries/mutations get issued, with which variables) and the parsed
#     output — not Linear behavior. It also cleanly disambiguates the three issues(filter:) reads
#     (list_open / mark_shipped resolve / item_state) that would otherwise collide.
#   • One transport test keeps a FAKE `curl` on PATH so the REAL _linear_gql still gets exercised
#     end-to-end (endpoint + auth header), with no real network.
# Run:  bash tests/test-backend-linear.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BACKEND="$HERE/../scripts/herd/backends/linear.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass(){ PASS=$((PASS+1)); }

GQLLOG="$T/gql.log"

# Default workflow-state nodes the states(filter:) stub returns. A test can override it by setting
# STATES_NODES in the environment (used to script a workspace with MULTIPLE started/completed states).
# Kept in its own variable, NOT inlined into ${STATES_NODES:-...}, because the '}' in the JSON would
# prematurely close the parameter expansion.
DEFAULT_STATE_NODES='[{"id":"state_done"}]'

# Fake curl for the transport test only: logs its args and emits a trivial response.
CURLLOG="$T/curl.log"
mkdir -p "$T/bin"
cat > "$T/bin/curl" <<EOF
#!/usr/bin/env bash
echo "curl \$*" >> "$CURLLOG"
echo '{"data":{"__typename":"Query"}}'
EOF
chmod +x "$T/bin/curl"
export PATH="$T/bin:$PATH"

# The backend reads its key (and optional team) from .herd/secrets, i.e. the environment by the
# time it is sourced. Set them so add_item skips the team-lookup round-trip and targets this team,
# and so resolution + list_open are team-scoped by default.
export LINEAR_API_KEY="lin_test_key"
export LINEAR_TEAM_ID="team_xyz"

# run: source the backend, override _linear_gql to log (query, vars) and return canned JSON keyed on
# the query text, then invoke the requested op and echo its result contract. Ordering in the case
# matters: mark_shipped's resolve query contains `states(filter` and item_state's contains
# `state { type }`; both also contain `issues(` (as does list_open), so the specific shapes are
# matched BEFORE the generic issues( fallthrough.
run() {
  ( cd "$T" && . "$BACKEND"
    _linear_gql() {
      printf 'QUERY<<%s>>VARS<<%s>>\n' "$1" "${2:-}" >> "$GQLLOG"
      case "$1" in
        *issueCreate*)      echo '{"data":{"issueCreate":{"success":true,"issue":{"id":"iss_1","identifier":"ENG-42","url":"https://linear.app/acme/issue/ENG-42"}}}}' ;;
        *commentCreate*)    echo '{"data":{"commentCreate":{"success":true}}}' ;;
        *issueUpdate*)      echo '{"data":{"issueUpdate":{"success":true}}}' ;;
        *"states(filter"*)  echo "{\"data\":{\"issues\":{\"nodes\":[{\"id\":\"iss_7\",\"identifier\":\"ENG-7\",\"title\":\"first open issue\",\"team\":{\"states\":{\"nodes\":${STATES_NODES:-$DEFAULT_STATE_NODES}}}}]}}}" ;;
        *"state { type }"*) echo '{"data":{"issues":{"nodes":[{"state":{"type":"completed"}}]}}}' ;;
        *updatedAt*)        echo '{"data":{"issues":{"nodes":[{"identifier":"ENG-7","title":"first open issue","description":"first open issue\nFull spec body here.","url":"https://linear.app/acme/issue/ENG-7","updatedAt":"2026-07-06T01:02:03.000Z","state":{"name":"In Progress","type":"started"}}]}}}' ;;
        *"state { name type }"*) echo '{"data":{"issues":{"nodes":[{"identifier":"ENG-7","title":"first open issue","description":"first open issue\nDetails for seven.","state":{"name":"Todo","type":"unstarted"},"assignee":null},{"identifier":"ENG-9","title":"second open issue","description":null,"state":{"name":"In Progress","type":"started"},"assignee":{"displayName":"Chase"}}]}}}' ;;
        *"issues("*)        echo '{"data":{"issues":{"nodes":[{"identifier":"ENG-7","title":"first open issue"},{"identifier":"ENG-9","title":"second open issue"}]}}}' ;;
        *)                  echo '{"data":{}}' ;;
      esac
    }
    _BACKEND_RESULT=""
    ITEM_STATE=""
    "$@"
    printf 'RESULT=%s\n' "${_BACKEND_RESULT:-}"
    printf 'ITEM_STATE=%s\n' "${ITEM_STATE:-}" )
}

# 1. add_item → issueCreate mutation carrying the title/body/teamId; returns DONE + the issue URL.
: > "$GQLLOG"
out="$(run _backend_add_item REQ1 "add a dark-mode toggle")"
echo "$out" | grep -q "RESULT=DONE" || fail "add_item did not report DONE ($out)"
echo "$out" | grep -q "https://linear.app/acme/issue/ENG-42" || fail "add_item did not surface the created issue URL"
grep -q "issueCreate" "$GQLLOG" || fail "add_item did not issue an 'issueCreate' mutation"
grep -q "add a dark-mode toggle" "$GQLLOG" || fail "add_item did not pass the request text as the issue title/body"
grep -q "team_xyz" "$GQLLOG" || fail "add_item did not target the configured team (teamId)"
pass

# 2. list_open (team scoped ON) → an issues() query filtered to the configured team, parsed to
#    "#<identifier> <title>" lines. Privacy: the team filter MUST be present so other teams' issues
#    can't leak in.
: > "$GQLLOG"
open="$(run _backend_list_open)"
grep -q "issues(" "$GQLLOG" || fail "list_open did not issue an 'issues' query"
grep -q 'team: { id: { eq: $team }' "$GQLLOG" || fail "list_open (team set) did not scope the query to the team"
grep -q "team_xyz" "$GQLLOG" || fail "list_open (team set) did not pass the team id in variables"
echo "$open" | grep -q "^#ENG-7 first open issue$"  || fail "list_open missing '#ENG-7 first open issue' ($open)"
echo "$open" | grep -q "^#ENG-9 second open issue$" || fail "list_open missing '#ENG-9 second open issue'"
pass

# 2b. list_open (team scoped OFF) → no team filter, so it spans every team the key can see.
: > "$GQLLOG"
open2="$( unset LINEAR_TEAM_ID; run _backend_list_open )"
grep -q "issues(" "$GQLLOG" || fail "list_open (no team) did not issue an 'issues' query"
grep -q 'team: { id:' "$GQLLOG" && fail "list_open (no team) must NOT scope by team — it leaked a team filter"
echo "$open2" | grep -q "^#ENG-7 first open issue$" || fail "list_open (no team) missing '#ENG-7 first open issue' ($open2)"
pass

# 2c. list_open_rich → same open filter as list_open but also requests state {name type} +
#     description + assignee {displayName}, emits TSV
#     ("#<id>\t<state-type>\t<state-name>\t<title>\t<desc>\t<assignee>"), sorts
#     started-first, and flattens description whitespace (a raw newline would corrupt the TSV).
TAB="$(printf '\t')"
: > "$GQLLOG"
rich="$(run _backend_list_open_rich)"
grep -q "description state { name type }" "$GQLLOG" || fail "list_open_rich did not request description + state name/type"
grep -q "assignee { displayName }" "$GQLLOG" || fail "list_open_rich did not request assignee displayName"
grep -q 'team: { id: { eq: $team }' "$GQLLOG" || fail "list_open_rich (team set) did not scope the query to the team"
echo "$rich" | grep '^#' | head -n1 | grep -q "^#ENG-9" \
  || fail "list_open_rich did not sort the started (in-progress) issue first ($rich)"
echo "$rich" | grep -q "^#ENG-9${TAB}started${TAB}In Progress${TAB}second open issue${TAB}${TAB}Chase$" \
  || fail "list_open_rich TSV shape wrong for ENG-9 (should have assignee Chase as 6th field) ($rich)"
echo "$rich" | grep -q "^#ENG-7${TAB}unstarted${TAB}Todo${TAB}first open issue${TAB}first open issue Details for seven.${TAB}$" \
  || fail "list_open_rich did not flatten the multi-line description; unassigned item must have empty trailing field ($rich)"
pass

# 2d. show_item → single-issue detail via issues(filter:) (never issueSearch): identifier + live
#     state on line 1, then title, the UNtruncated description, and url + updated date.
: > "$GQLLOG"
det="$(run _backend_show_item "#ENG-7")"
grep -q "issueSearch" "$GQLLOG" && fail "show_item must NOT use the deprecated issueSearch endpoint"
grep -q '"n": 7' "$GQLLOG" || fail "show_item did not resolve by the parsed issue number"
echo "$det" | grep -q "^#ENG-7 · In Progress (started)$" || fail "show_item missing the id · state header ($det)"
echo "$det" | grep -q "Full spec body here." || fail "show_item did not print the full description body"
echo "$det" | grep -q "linear.app/acme/issue/ENG-7 · updated 2026-07-06" || fail "show_item missing url + updated date"
pass

# 2e. show_item on an unparseable ref → loud stderr, no network round-trip. (Exit code is not
#     asserted: `run` wraps the op in a subshell that always appends its RESULT/ITEM_STATE report.)
: > "$GQLLOG"
err="$(run _backend_show_item "nodashhere" 2>&1 >/dev/null || true)"
echo "$err" | grep -q "not a TEAMKEY-NUMBER" || fail "show_item on an unparseable ref should say so on stderr ($err)"
grep -q "issues(" "$GQLLOG" && fail "show_item on an unparseable ref should not issue any query"
pass

# 3. mark_shipped → resolves the issue via issues(filter:) (NOT the deprecated issueSearch),
#    comments the PR link, then moves it to the resolved Done state.
: > "$GQLLOG"
ship="$(run _backend_mark_shipped ENG-7 https://github.com/acme/widgets/pull/3)"
echo "$ship" | grep -q "RESULT=DONE" || fail "mark_shipped did not report DONE ($ship)"
grep -q "issues(filter" "$GQLLOG"  || fail "mark_shipped did not resolve the issue via issues(filter:)"
grep -q "issueSearch" "$GQLLOG"    && fail "mark_shipped must NOT use the deprecated issueSearch endpoint"
grep -q 'number: { eq: $n }' "$GQLLOG" || fail "mark_shipped did not look the issue up by parsed number"
grep -q '"n": 7' "$GQLLOG"         || fail "mark_shipped did not parse the number (7) out of the ENG-7 slug"
grep -q 'team: { key: { eq: $key }' "$GQLLOG" || fail "mark_shipped did not resolve by the identifier's team key"
grep -q '"key": "ENG"' "$GQLLOG"   || fail "mark_shipped did not scope resolution to team ENG parsed from the ENG-7 slug"
grep -q 'team: { id:' "$GQLLOG"    && fail "mark_shipped must resolve by the identifier's team key, not by team id"
grep -q 'team_xyz' "$GQLLOG"       && fail "mark_shipped must NOT scope resolution by the configured LINEAR_TEAM_ID (cross-team collision)"
grep -q "commentCreate" "$GQLLOG"  || fail "mark_shipped did not comment the PR link (commentCreate)"
grep -q "Shipped via https://github.com/acme/widgets/pull/3" "$GQLLOG" \
  || fail "mark_shipped did not link the PR in the comment body"
grep -q "issueUpdate" "$GQLLOG"    || fail "mark_shipped did not move the issue to Done (issueUpdate)"
grep -q "state_done" "$GQLLOG"     || fail "mark_shipped did not set the resolved Done stateId"
pass

# 3b. mark_shipped with an unparseable slug (no number) → NOCHANGE, no resolve round-trip.
: > "$GQLLOG"
ship2="$(run _backend_mark_shipped nodashhere https://github.com/acme/widgets/pull/9 2>/dev/null)"
echo "$ship2" | grep -q "RESULT=NOCHANGE" || fail "mark_shipped on an unparseable slug should be NOCHANGE ($ship2)"
grep -q "issues(" "$GQLLOG" && fail "mark_shipped on an unparseable slug should not issue any query"
pass

# 4. item_state → resolves via issues(filter:) reading state.type; maps completed → closed.
: > "$GQLLOG"
out="$(run _backend_item_state "provider-lib#ENG-7")"
echo "$out" | grep -q "ITEM_STATE=closed" || fail "_backend_item_state did not return ITEM_STATE=closed ($out)"
grep -q "issues(filter" "$GQLLOG" || fail "_backend_item_state did not resolve via issues(filter:)"
grep -q "issueSearch" "$GQLLOG"   && fail "_backend_item_state must NOT use the deprecated issueSearch endpoint"
grep -q "state { type }" "$GQLLOG" || fail "_backend_item_state did not request the issue state.type"
grep -q 'team: { key: { eq: $key }' "$GQLLOG" || fail "_backend_item_state did not resolve by the identifier's team key"
grep -q '"key": "ENG"' "$GQLLOG"  || fail "_backend_item_state did not scope resolution to team ENG from the ENG-7 slug"
grep -q 'team_xyz' "$GQLLOG"      && fail "_backend_item_state must NOT scope resolution by the configured LINEAR_TEAM_ID"
pass

# 4b. CROSS-TEAM (the dep-watcher case): with LINEAR_TEAM_ID set, an identifier from a DIFFERENT team
#     must resolve against ITS OWN team key — never the configured team, whose same-numbered issue
#     would otherwise be silently mislabeled (premature unblock). This is the exact divergence the
#     ENG-7-under-team_xyz cases above now also cover, made explicit with a distinct team + number.
: > "$GQLLOG"
out="$(run _backend_item_state "provider-lib#PROV-42")"
grep -q '"key": "PROV"' "$GQLLOG" || fail "cross-team item_state did not resolve against the identifier's own team key (PROV)"
grep -q '"n": 42' "$GQLLOG"       || fail "cross-team item_state did not look the issue up by its own number (42)"
grep -q 'team_xyz' "$GQLLOG"      && fail "cross-team item_state leaked the configured LINEAR_TEAM_ID into resolution"
grep -q 'team: { id:' "$GQLLOG"   && fail "cross-team item_state must resolve by team key, not team id"
pass

# 4c. update_state (done) → resolves the issue by the identifier's OWN team key via issues(filter:)
#     (never the deprecated issueSearch, never LINEAR_TEAM_ID), requests a workflow state of the
#     MAPPED type (done→completed), then issueUpdate moves it there. It must NOT issueCreate — a
#     state change is not a new item (the gh #139 junk-issue bug this closes).
: > "$GQLLOG"
us="$(run _backend_update_state ENG-7 done)"
echo "$us" | grep -q "RESULT=DONE" || fail "update_state did not report DONE ($us)"
grep -q "issues(filter" "$GQLLOG"          || fail "update_state did not resolve via issues(filter:)"
grep -q "issueSearch" "$GQLLOG"            && fail "update_state must NOT use the deprecated issueSearch endpoint"
grep -q 'type: { eq: "completed" }' "$GQLLOG" || fail "update_state (done) did not map to the completed workflow-state type"
grep -q '"key": "ENG"' "$GQLLOG"           || fail "update_state did not resolve by the identifier's team key (ENG)"
grep -q 'team_xyz' "$GQLLOG"               && fail "update_state must NOT scope resolution by the configured LINEAR_TEAM_ID"
grep -q "issueUpdate" "$GQLLOG"            || fail "update_state did not move the issue (issueUpdate)"
grep -q "state_done" "$GQLLOG"             || fail "update_state did not set the resolved target stateId"
grep -q "issueCreate" "$GQLLOG"           && fail "update_state must NOT file a new issue (the #139 junk-issue bug)"
pass

# 4d. update_state maps in-progress→started and canceled→canceled (the workflow-state TYPE filter).
: > "$GQLLOG"; run _backend_update_state ENG-7 in-progress >/dev/null
grep -q 'type: { eq: "started" }' "$GQLLOG"  || fail "update_state (in-progress) did not map to the started type"
: > "$GQLLOG"; run _backend_update_state ENG-7 canceled >/dev/null
grep -q 'type: { eq: "canceled" }' "$GQLLOG" || fail "update_state (canceled) did not map to the canceled type"
pass

# 4e. update_state with an UNKNOWN target state → NOCHANGE, and no round-trip at all (files nothing).
: > "$GQLLOG"
us2="$(run _backend_update_state ENG-7 frobnicate 2>/dev/null)"
echo "$us2" | grep -q "RESULT=NOCHANGE" || fail "update_state on an unknown state should be NOCHANGE ($us2)"
grep -q "issues(" "$GQLLOG" && fail "update_state on an unknown state should issue no query"
pass

# 4f. update_state falls back to a CONSERVATIVE title match (containsIgnoreCase) when the ref carries
#     no identifier — so a reconcile request that names an item by title still transitions it.
: > "$GQLLOG"
us3="$(run _backend_update_state "first open issue" done)"
grep -q "containsIgnoreCase" "$GQLLOG" || fail "update_state (no identifier) did not fall back to a title match"
echo "$us3" | grep -q "RESULT=DONE"    || fail "update_state title match did not transition the unique match ($us3)"
pass

# 4g. gh #169: a workspace with MULTIPLE started-type states must resolve 'in-progress' to the state
#     NAMED 'In Progress', never whichever started state the API returns first. STATES_NODES feeds the
#     stub BOTH started states with 'In Review' listed first AND at a higher position — name wins.
: > "$GQLLOG"
us4="$( STATES_NODES='[{"id":"st_review","name":"In Review","position":2},{"id":"st_progress","name":"In Progress","position":1}]' \
        run _backend_update_state ENG-7 in-progress )"
echo "$us4" | grep -q "RESULT=DONE" || fail "update_state (multi started) did not report DONE ($us4)"
grep -q "issueUpdate" "$GQLLOG" || fail "update_state (multi started) did not move the issue"
grep -q "st_progress" "$GQLLOG" || fail "update_state (multi started) did not pick the 'In Progress' state by NAME (gh #169)"
grep -q "st_review"  "$GQLLOG" && fail "update_state (multi started) picked 'In Review' — the exact gh #169 regression"
pass

# 4h. gh #169 fallback: when NO started state is named 'In Progress', pick the one with the LOWEST
#     position (Linear's canonical order = the earliest started state), still never 'In Review'.
: > "$GQLLOG"
us5="$( STATES_NODES='[{"id":"st_review","name":"In Review","position":2},{"id":"st_doing","name":"Doing","position":1}]' \
        run _backend_update_state ENG-7 in-progress )"
echo "$us5" | grep -q "RESULT=DONE" || fail "update_state (position fallback) did not report DONE ($us5)"
grep -q "st_doing" "$GQLLOG" || fail "update_state (position fallback) did not pick the LOWEST-position started state (gh #169)"
grep -q "st_review" "$GQLLOG" && fail "update_state (position fallback) picked the higher-position 'In Review' — gh #169 regression"
pass

# 4i. gh #169 for DONE too: with several completed-type states, prefer the one named 'Done', else the
#     lowest-position one — never an arbitrary completed state (e.g. 'Duplicate').
: > "$GQLLOG"
us6="$( STATES_NODES='[{"id":"st_dup","name":"Duplicate","position":2},{"id":"st_done","name":"Done","position":1}]' \
        run _backend_update_state ENG-7 done )"
echo "$us6" | grep -q "RESULT=DONE" || fail "update_state (multi completed) did not report DONE ($us6)"
grep -q "st_done" "$GQLLOG" || fail "update_state (multi completed) did not pick the 'Done' state by NAME (gh #169)"
grep -q "st_dup"  "$GQLLOG" && fail "update_state (multi completed) picked 'Duplicate' — gh #169 regression"
pass

# 5. absent key degrades loudly (no silent success), even with a fake curl available.
if ( cd "$T"; unset LINEAR_API_KEY; . "$BACKEND"; _backend_list_open ) >/dev/null 2>&1; then
  fail "list_open should fail when LINEAR_API_KEY is absent"
fi
pass

# 6. transport: the REAL _linear_gql POSTs to the Linear endpoint with the key in the auth header
#    (exercised through the fake curl — still no real network).
: > "$CURLLOG"
( cd "$T" && . "$BACKEND"; _linear_gql 'query { __typename }' '{}' >/dev/null )
grep -q "api.linear.app/graphql" "$CURLLOG" || fail "_linear_gql did not POST to the Linear GraphQL endpoint"
grep -q "Authorization: lin_test_key" "$CURLLOG" || fail "_linear_gql did not send the API key from secrets in the auth header"
pass

echo "ALL PASS ($PASS checks)"
