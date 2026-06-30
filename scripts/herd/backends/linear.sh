#!/usr/bin/env bash
# backends/linear.sh — SCRIBE_BACKEND=linear implementation (Linear GraphQL work tracker).
#
# Opt-in API backend: work items live as Linear issues instead of a tracked file in the repo.
# New items become open issues, "shipped" moves the matching issue to a Done (completed) workflow
# state with a comment linking the PR, and "open" is the live set of non-completed/non-canceled
# issues. Like the github/changelog backends the agent does NOT edit any file — scribe-step.sh
# dispatches the request text here via the add-item path.
#
# Sourced from scribe-step.sh AFTER .herd/secrets and herd-config.sh have loaded, with $REPO as
# CWD. Implements the same three-op contract as backends/file.sh:
#   _backend_add_item REQ_ID TEXT     — issueCreate; sets _BACKEND_RESULT=DONE|NOCHANGE
#   _backend_mark_shipped SLUG PR_URL — comment PR link + issueUpdate into the Done state
#   _backend_list_open                — open issues, one "#<identifier> <title>" line each
#
# Credentials: LINEAR_API_KEY is read from .herd/secrets (gitignored) — NEVER from .herd/config.
# Loud error + exit 1 if it is absent. An optional LINEAR_TEAM_ID (also from .herd/secrets) names
# the team new issues are filed under; if unset, the first team the key can see is used.
#
# Every HTTP round-trip is funneled through the single internal _linear_gql so a test can stub the
# network by overriding _linear_gql or by putting a fake `curl` on PATH.

_LINEAR_API_URL="${LINEAR_API_URL:-https://api.linear.app/graphql}"

_linear_require_key() {
    if [ -z "${LINEAR_API_KEY:-}" ]; then
        echo "linear backend: LINEAR_API_KEY not set — add it to .herd/secrets (gitignored), NOT .herd/config (or switch SCRIBE_BACKEND)" >&2
        exit 1
    fi
}

_linear_require_curl() {
    command -v curl >/dev/null 2>&1 || {
        echo "linear backend: 'curl' not found — required to reach the Linear GraphQL API" >&2
        exit 1
    }
}

_linear_gql() {
    # The one HTTP entry point. $1 = GraphQL query/mutation text; $2 = JSON variables (optional).
    # Builds the {"query","variables"} envelope with python3 (so titles/bodies with quotes or
    # newlines are encoded safely) and POSTs it with the API key in the Authorization header.
    # Prints the raw JSON response on stdout. Tests stub this whole function or the `curl` it calls.
    local query="$1" vars="${2:-}" payload
    [ -n "$vars" ] || vars='{}'
    _linear_require_curl
    payload="$(QUERY="$query" VARS="$vars" python3 -c 'import os, json
print(json.dumps({"query": os.environ["QUERY"], "variables": json.loads(os.environ.get("VARS") or "{}")}))')" || return 1
    curl -sS -X POST "$_LINEAR_API_URL" \
        -H "Content-Type: application/json" \
        -H "Authorization: ${LINEAR_API_KEY}" \
        --data "$payload"
}

_linear_team_id() {
    # Resolve the team new issues are created under: the configured LINEAR_TEAM_ID if present,
    # else the first team this key can see. Prints the id (empty if none).
    if [ -n "${LINEAR_TEAM_ID:-}" ]; then printf '%s' "$LINEAR_TEAM_ID"; return 0; fi
    _linear_gql 'query { teams(first: 1) { nodes { id } } }' \
      | python3 -c 'import sys, json
try: d = json.load(sys.stdin)
except Exception: d = {}
nodes = (((d.get("data") or {}).get("teams") or {}).get("nodes")) or []
print(nodes[0]["id"] if nodes else "")' 2>/dev/null
}

_backend_add_item() {
    # $1 = claimed queue file path (REQ_ID, unused here); $2 = item text / summary.
    # Title = the first line of the request; description = the full text. Sets _BACKEND_RESULT=DONE
    # on a created issue (and surfaces its URL), NOCHANGE if Linear declines or no team is available.
    local text="$2" title team mut vars resp parsed ok ident url
    _linear_require_key
    title="$(printf '%s' "$text" | head -n1)"
    team="$(_linear_team_id)"
    if [ -z "$team" ]; then
        echo "linear backend: no team available to create the issue in (set LINEAR_TEAM_ID in .herd/secrets)" >&2
        _BACKEND_RESULT="NOCHANGE"
        return 0
    fi
    mut='mutation Create($title: String!, $description: String, $teamId: String!) {
  issueCreate(input: { title: $title, description: $description, teamId: $teamId }) {
    success
    issue { id identifier url }
  }
}'
    vars="$(TITLE="$title" DESC="$text" TEAM="$team" python3 -c 'import os, json
print(json.dumps({"title": os.environ["TITLE"], "description": os.environ["DESC"], "teamId": os.environ["TEAM"]}))')"
    resp="$(_linear_gql "$mut" "$vars")"
    parsed="$(printf '%s' "$resp" | python3 -c 'import sys, json
try: d = json.load(sys.stdin)
except Exception: d = {}
ic = ((d.get("data") or {}).get("issueCreate")) or {}
iss = ic.get("issue") or {}
print("%s\t%s\t%s" % ("1" if ic.get("success") else "0", iss.get("identifier", ""), iss.get("url", "")))' 2>/dev/null)"
    ok="${parsed%%	*}"; parsed="${parsed#*	}"
    ident="${parsed%%	*}"; url="${parsed#*	}"
    if [ "$ok" = "1" ]; then
        _BACKEND_RESULT="DONE"
        if [ -n "$url" ]; then printf '%s\n' "$url"; elif [ -n "$ident" ]; then printf '%s\n' "$ident"; fi
    else
        _BACKEND_RESULT="NOCHANGE"
    fi
}

_backend_mark_shipped() {
    # $1 = item slug (Linear issue identifier, e.g. ENG-42, or any issueSearch term); $2 = PR URL.
    # Resolve the issue to its id + its team's Done (completed) workflow state, comment the PR link,
    # then move it into that state. Mirrors how the github backend comments-then-closes. Sets
    # _BACKEND_RESULT=DONE|NOCHANGE.
    local slug="$1" pr="$2" resolve resp issue_id state_id
    _linear_require_key
    resolve='query Resolve($q: String!) {
  issueSearch(query: $q, first: 1) {
    nodes {
      id
      team { states(filter: { type: { eq: "completed" } }, first: 1) { nodes { id } } }
    }
  }
}'
    resp="$(_linear_gql "$resolve" "$(SLUG="$slug" python3 -c 'import os, json
print(json.dumps({"q": os.environ["SLUG"]}))')")"
    read -r issue_id state_id <<EOF
$(printf '%s' "$resp" | python3 -c 'import sys, json
try: d = json.load(sys.stdin)
except Exception: d = {}
nodes = (((d.get("data") or {}).get("issueSearch") or {}).get("nodes")) or []
if not nodes:
    print("\t")
else:
    n = nodes[0]
    states = (((n.get("team") or {}).get("states") or {}).get("nodes")) or []
    print("%s\t%s" % (n.get("id", ""), states[0]["id"] if states else ""))' 2>/dev/null)
EOF
    if [ -z "$issue_id" ]; then
        echo "linear backend: no issue matching '$slug' — nothing to ship" >&2
        _BACKEND_RESULT="NOCHANGE"
        return 0
    fi
    # Comment the PR link.
    _linear_gql 'mutation Comment($issueId: String!, $body: String!) {
  commentCreate(input: { issueId: $issueId, body: $body }) { success }
}' "$(ID="$issue_id" BODY="Shipped via ${pr}" python3 -c 'import os, json
print(json.dumps({"issueId": os.environ["ID"], "body": os.environ["BODY"]}))')" >/dev/null 2>&1 || true
    # Move to the Done state.
    if [ -n "$state_id" ]; then
        _linear_gql 'mutation Ship($id: String!, $stateId: String!) {
  issueUpdate(id: $id, input: { stateId: $stateId }) { success }
}' "$(ID="$issue_id" SID="$state_id" python3 -c 'import os, json
print(json.dumps({"id": os.environ["ID"], "stateId": os.environ["SID"]}))')" >/dev/null 2>&1 || true
    fi
    _BACKEND_RESULT="DONE"
}

_backend_list_open() {
    # Print open issues (any state whose type is not completed/canceled) as one
    # "#<identifier> <title>" line each — the same shape the file/github backends emit.
    _linear_require_key
    _linear_gql 'query {
  issues(filter: { state: { type: { nin: ["completed", "canceled"] } } }, first: 250) {
    nodes { identifier title }
  }
}' | python3 -c 'import sys, json
try: d = json.load(sys.stdin)
except Exception: d = {}
nodes = (((d.get("data") or {}).get("issues") or {}).get("nodes")) or []
for n in nodes:
    print("#%s %s" % (n.get("identifier", ""), n.get("title", "")))' 2>/dev/null || true
}
