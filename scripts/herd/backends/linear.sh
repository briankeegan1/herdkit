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
# plus _backend_item_state REF for the link-state watcher.
#
# Credentials: LINEAR_API_KEY is read from .herd/secrets (gitignored) — NEVER from .herd/config.
# Loud error + exit 1 if it is absent. An optional LINEAR_TEAM_ID (also from .herd/secrets) names
# the team new issues are filed under and, critically, scopes the open-issue list — so a second
# private team's issues never leak into 'herd backlog'. It deliberately does NOT scope issue
# resolution (mark_shipped / item_state); that is keyed off the identifier's own team (see below).
# When unset, the first team the key can see files new issues and the open list spans every team the
# key can see (legacy all-teams behavior).
#
# Issue resolution uses issues(filter: { number, team }) — Linear DEPRECATED and removed the
# issueSearch endpoint (2026-07: every call returns errors[0].message='deprecated', HTTP 400), so
# mark_shipped/item_state parse BOTH the number and the team key out of the identifier slug (e.g.
# HERD-5 -> number 5, team key HERD) and look it up by number scoped to that team key. Issue numbers
# are unique only within a team, so resolving by the identifier's own team (not LINEAR_TEAM_ID) is
# what keeps a cross-team reference from matching the wrong same-numbered local issue.
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

_linear_issue_query() {
    # Build the issues(filter:) lookup that replaces the deprecated issueSearch. $1 = issue slug
    # (identifier, e.g. HERD-5 — a leading '#' is tolerated); $2 = the GraphQL sub-selection to
    # request inside `nodes { ... }`. On success sets globals _LQ_QUERY and _LQ_VARS ready for
    # _linear_gql and returns 0; returns 1 (setting neither) when the slug is not a TEAMKEY-NUMBER
    # identifier.
    #
    # Resolution is keyed off the identifier ITSELF — team key from the prefix + number — and MUST
    # NOT be scoped by LINEAR_TEAM_ID. A Linear issue number is unique only within its own team, and
    # the identifier already names that team (ENG-7 == team ENG, issue 7). Scoping by a configured
    # LINEAR_TEAM_ID would, for any cross-team reference (e.g. a dep 'blocked-on: lib#ENG-7' while
    # LINEAR_TEAM_ID is a different team), resolve the local same-numbered issue and mislabel state —
    # silently unblocking a dep whose real upstream is still open. LINEAR_TEAM_ID only scopes the ops
    # that carry no identifier (list_open / add_item).
    local slug="${1#\#}" fields="$2" num key
    case "$slug" in *-*) ;; *) return 1 ;; esac
    num="${slug##*-}"
    key="${slug%-*}"
    case "$num" in ''|*[!0-9]*) return 1 ;; esac
    [ -n "$key" ] || return 1
    _LQ_QUERY="$(printf 'query R($n: Float!, $key: String!) {
  issues(filter: { number: { eq: $n }, team: { key: { eq: $key } } }, first: 1) {
    nodes { %s }
  }
}' "$fields")"
    _LQ_VARS="$(N="$num" KEY="$key" python3 -c 'import os, json
print(json.dumps({"n": float(os.environ["N"]), "key": os.environ["KEY"]}))')"
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
    # $1 = item slug (Linear issue identifier, e.g. ENG-42); $2 = PR URL.
    # Resolve the issue to its id + its team's Done (completed) workflow state via issues(filter:)
    # — issueSearch was deprecated/removed by Linear (2026-07) — comment the PR link, then move it
    # into that state. Mirrors how the github backend comments-then-closes. Sets
    # _BACKEND_RESULT=DONE|NOCHANGE.
    local slug="$1" pr="$2" resp issue_id state_id
    _linear_require_key
    if ! _linear_issue_query "$slug" 'id identifier title team { states(filter: { type: { eq: "completed" } }, first: 1) { nodes { id } } }'; then
        echo "linear backend: no issue matching '$slug' — nothing to ship" >&2
        _BACKEND_RESULT="NOCHANGE"
        return 0
    fi
    resp="$(_linear_gql "$_LQ_QUERY" "$_LQ_VARS")"
    read -r issue_id state_id <<EOF
$(printf '%s' "$resp" | python3 -c 'import sys, json
try: d = json.load(sys.stdin)
except Exception: d = {}
nodes = (((d.get("data") or {}).get("issues") or {}).get("nodes")) or []
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

_linear_state_type_for() {
    # Map a requested scribe state to a Linear workflow-state TYPE. Linear groups every workflow
    # state under a type; we move the issue to the FIRST state of the mapped type for its own team.
    # A few common synonyms are tolerated so the drainer's phrasing does not have to be exact.
    # Prints the type (empty for an unmappable request — the caller then SKIPs, never files).
    case "$1" in
        done|complete|completed|shipped|merged|closed|resolved) printf 'completed' ;;
        in-progress|inprogress|in_progress|started|doing|wip|active) printf 'started' ;;
        cancel|canceled|cancelled|wontfix|"won't fix"|declined|dropped|obsolete) printf 'canceled' ;;
        *) printf '' ;;
    esac
}

_linear_resolve_by_title() {
    # Fallback resolution when the request names no identifier: match OPEN-ish issues by a title
    # substring (case-insensitive). $1 = title text; $2 = target state type (inlined into the states
    # sub-filter, exactly as the identifier path builds it). Prints the same
    # {"data":{"issues":{"nodes":[…]}}} shape as the identifier query so ONE parser handles both.
    # Deliberately CONSERVATIVE: first:2 so the caller can require a UNIQUE match and never mislabel
    # the wrong issue when a phrase is ambiguous.
    local title="$1" stype="$2" q v
    q="$(printf 'query T($t: String!) {
  issues(filter: { title: { containsIgnoreCase: $t } }, first: 2) {
    nodes { id identifier title team { states(filter: { type: { eq: "%s" } }, first: 1) { nodes { id } } } }
  }
}' "$stype")"
    v="$(T="$title" python3 -c 'import os, json
print(json.dumps({"t": os.environ["T"]}))')"
    _linear_gql "$q" "$v"
}

_backend_update_state() {
    # $1 = item ref (Linear identifier e.g. HERD-22, a leading '#' tolerated — or a title phrase when
    # no identifier is present); $2 = target state (done|in-progress|canceled + synonyms).
    # Resolve the issue + a workflow state of the mapped type for its OWN team, then issueUpdate it
    # into that state — reusing the same issues(filter:) + issueUpdate machinery as _backend_mark_shipped
    # (issueSearch was deprecated/removed by Linear 2026-07). Sets _BACKEND_RESULT=DONE|NOCHANGE.
    # This is the intent-dispatch path (gh #139): a "mark HERD-22 done" request transitions the EXISTING
    # issue instead of filing a brand-new one. NOCHANGE (no unique match / no such state) files nothing.
    local ref="$1" want="$2" stype fields resp issue_id state_id
    _linear_require_key
    stype="$(_linear_state_type_for "$want")"
    if [ -z "$stype" ]; then
        echo "linear backend: unknown target state '$want' — expected done|in-progress|canceled (skipping, not filing)" >&2
        _BACKEND_RESULT="NOCHANGE"
        return 0
    fi
    fields="$(printf 'id identifier title team { states(filter: { type: { eq: "%s" } }, first: 1) { nodes { id } } }' "$stype")"
    if _linear_issue_query "$ref" "$fields"; then
        resp="$(_linear_gql "$_LQ_QUERY" "$_LQ_VARS")"          # identifier path (HERD-22 → number+team)
    else
        resp="$(_linear_resolve_by_title "$ref" "$stype")"      # conservative title match
    fi
    # ONE parser for both shapes: require EXACTLY ONE matching node (uniqueness = conservatism), then
    # read its id + the first workflow-state id of the mapped type.
    read -r issue_id state_id <<EOF
$(printf '%s' "$resp" | python3 -c 'import sys, json
try: d = json.load(sys.stdin)
except Exception: d = {}
nodes = (((d.get("data") or {}).get("issues") or {}).get("nodes")) or []
if len(nodes) != 1:
    print("\t")
else:
    n = nodes[0]
    states = (((n.get("team") or {}).get("states") or {}).get("nodes")) or []
    print("%s\t%s" % (n.get("id", ""), states[0]["id"] if states else ""))' 2>/dev/null)
EOF
    if [ -z "$issue_id" ]; then
        echo "linear backend: no unique issue matching '$ref' — state unchanged (skipping, not filing)" >&2
        _BACKEND_RESULT="NOCHANGE"
        return 0
    fi
    if [ -z "$state_id" ]; then
        echo "linear backend: issue '$ref' has no '$stype' workflow state — cannot mark it '$want'" >&2
        _BACKEND_RESULT="NOCHANGE"
        return 0
    fi
    _linear_gql 'mutation Move($id: String!, $stateId: String!) {
  issueUpdate(id: $id, input: { stateId: $stateId }) { success }
}' "$(ID="$issue_id" SID="$state_id" python3 -c 'import os, json
print(json.dumps({"id": os.environ["ID"], "stateId": os.environ["SID"]}))')" >/dev/null 2>&1 || true
    _BACKEND_RESULT="DONE"
}

_backend_list_open() {
    # Print open issues (any state whose type is not completed/canceled) as one
    # "#<identifier> <title>" line each — the same shape the file/github backends emit.
    # When LINEAR_TEAM_ID is set the query is scoped to that team so a second private team's issues
    # never leak into 'herd backlog'; unset lists every team the key can see.
    _linear_require_key
    local query vars
    if [ -n "${LINEAR_TEAM_ID:-}" ]; then
        query='query L($team: ID!) {
  issues(filter: { state: { type: { nin: ["completed", "canceled"] } }, team: { id: { eq: $team } } }, first: 250) {
    nodes { identifier title }
  }
}'
        vars="$(TEAM="$LINEAR_TEAM_ID" python3 -c 'import os, json
print(json.dumps({"team": os.environ["TEAM"]}))')"
    else
        query='query {
  issues(filter: { state: { type: { nin: ["completed", "canceled"] } } }, first: 250) {
    nodes { identifier title }
  }
}'
        vars=""
    fi
    _linear_gql "$query" "$vars" | python3 -c 'import sys, json
try: d = json.load(sys.stdin)
except Exception: d = {}
nodes = (((d.get("data") or {}).get("issues") or {}).get("nodes")) or []
for n in nodes:
    print("#%s %s" % (n.get("identifier", ""), n.get("title", "")))' 2>/dev/null || true
}

_backend_list_open_rich() {
    # OPTIONAL rich variant of _backend_list_open (the plain op above stays the cross-backend
    # contract and is byte-identical). Emits one TAB-separated line per open issue:
    #   #<identifier> \t <state-type> \t <state-name> \t <title> \t <desc-snippet>
    # state-type is Linear's workflow-state TYPE (started|unstarted|backlog|triage) — the machine
    # key a viewer groups on; state-name is the human label ("In Progress", "In Review", …). The
    # description snippet is whitespace-flattened (tabs/newlines → spaces, so the TSV shape can
    # never be corrupted by field content) and capped at 280 chars. Lines are sorted started-first
    # (in-progress work surfaces at the top), then unstarted, backlog, triage — stable within each
    # group (API order preserved). Consumed by `herd backlog --rich` → backlog-view.sh's rich
    # renderer; callers that don't know this op exists keep using _backend_list_open unchanged.
    _linear_require_key
    local query vars
    if [ -n "${LINEAR_TEAM_ID:-}" ]; then
        query='query L($team: ID!) {
  issues(filter: { state: { type: { nin: ["completed", "canceled"] } }, team: { id: { eq: $team } } }, first: 250) {
    nodes { identifier title description state { name type } assignee { displayName } }
  }
}'
        vars="$(TEAM="$LINEAR_TEAM_ID" python3 -c 'import os, json
print(json.dumps({"team": os.environ["TEAM"]}))')"
    else
        query='query {
  issues(filter: { state: { type: { nin: ["completed", "canceled"] } } }, first: 250) {
    nodes { identifier title description state { name type } assignee { displayName } }
  }
}'
        vars=""
    fi
    _linear_gql "$query" "$vars" | python3 -c 'import sys, json
try: d = json.load(sys.stdin)
except Exception: d = {}
nodes = (((d.get("data") or {}).get("issues") or {}).get("nodes")) or []
rank = {"started": 0, "unstarted": 1, "backlog": 2, "triage": 3}
def flat(s):
    return " ".join((s or "").split())
rows = []
for i, n in enumerate(nodes):
    st = n.get("state") or {}
    rows.append((rank.get(st.get("type") or "", 4), i, n, st))
rows.sort(key=lambda r: (r[0], r[1]))
for _, _, n, st in rows:
    desc = flat(n.get("description"))
    if len(desc) > 280:
        desc = desc[:279].rstrip() + "…"
    assignee = flat((n.get("assignee") or {}).get("displayName") or "")
    print("#%s\t%s\t%s\t%s\t%s\t%s" % (n.get("identifier", ""), st.get("type") or "",
                                        flat(st.get("name")), flat(n.get("title")), desc, assignee))' 2>/dev/null || true
}

_backend_show_item() {
    # OPTIONAL single-item detail op: $1 = issue identifier (HERD-8; a leading '#' is tolerated).
    # Prints a plain-text detail block — identifier + live state on the first line, then title,
    # full (untruncated) description, and the issue URL — for `herd backlog show <id>` and the
    # fzf preview pane of `herd backlog browse`. Plain text on purpose: the preview pane and a
    # bare terminal render it identically, no glow required. Non-zero + stderr when the ref
    # doesn't parse or the issue can't be found (callers print their own soft fallback).
    local ref="$1" resp
    _linear_require_key
    if ! _linear_issue_query "$ref" 'identifier title description url updatedAt state { name type } assignee { displayName }'; then
        echo "linear backend: '$ref' is not a TEAMKEY-NUMBER identifier" >&2
        return 1
    fi
    resp="$(_linear_gql "$_LQ_QUERY" "$_LQ_VARS")"
    printf '%s' "$resp" | python3 -c 'import sys, json
try: d = json.load(sys.stdin)
except Exception: d = {}
nodes = (((d.get("data") or {}).get("issues") or {}).get("nodes")) or []
if not nodes:
    sys.exit(1)
n = nodes[0]
st = n.get("state") or {}
aname = ((n.get("assignee") or {}).get("displayName") or "").strip()
header = "#%s · %s (%s)" % (n.get("identifier", ""), st.get("name") or "?", st.get("type") or "?")
if aname:
    header += " · " + aname
print(header)
print()
print(n.get("title") or "(untitled)")
desc = (n.get("description") or "").strip()
if desc:
    print()
    print(desc)
print()
meta = n.get("url") or ""
upd = (n.get("updatedAt") or "")[:10]
if upd:
    meta = ("%s · updated %s" % (meta, upd)) if meta else ("updated %s" % upd)
if meta:
    print(meta)' 2>/dev/null || {
        echo "linear backend: no unique issue matching '$ref'" >&2
        return 1
    }
}

_backend_item_state() {
    # $1 = <link-name>#<id> — caller has resolved the link; LINEAR_API_KEY is in env.
    # Resolves the issue via issues(filter:) (issueSearch was deprecated/removed by Linear 2026-07)
    # and reads state.type, setting ITEM_STATE=open|closed|in-progress.
    # Linear state types: completed/canceled → closed; started → in-progress; all others → open.
    local ref="$1" slug resp stype
    _linear_require_key
    slug="${ref#*#}"
    if ! _linear_issue_query "$slug" 'state { type }'; then
        ITEM_STATE="open"
        return 0
    fi
    resp="$(_linear_gql "$_LQ_QUERY" "$_LQ_VARS")"
    stype="$(printf '%s' "$resp" | python3 -c '
import sys, json
try:    d = json.load(sys.stdin)
except Exception: d = {}
nodes = (((d.get("data") or {}).get("issues") or {}).get("nodes")) or []
print(nodes[0].get("state", {}).get("type", "") if nodes else "")
' 2>/dev/null || printf '')"
    case "$stype" in
        completed|canceled|cancelled) ITEM_STATE="closed"      ;;
        started)                      ITEM_STATE="in-progress" ;;
        *)                            ITEM_STATE="open"         ;;
    esac
}

# _backend_claim_item REF WHO — atomic-ish pre-spawn claim (HERD-50). On Linear the claim marker is
# the issue ASSIGNEE plus a move into a 'started' workflow state. The claimant identity is the API
# key's OWN user (viewer{}), not WHO — WHO is informational only, since Linear identifies actors by
# their user id, not a login string. Read state.type + assignee SYNCHRONOUSLY; abort if the issue is
# completed/canceled (shipped) or already assigned to a DIFFERENT user; else set assignee=viewer +
# move to a started state and RE-READ to verify. Linear has no compare-and-swap, so claim-verify
# narrows (not eliminates) the race to a couple of round-trips (seconds). Sets:
#   _CLAIM_RESULT = CLAIMED | SELF (already ours) | ALREADY (closed / another assignee) |
#                   UNREACHABLE (unresolvable ref / no started state → caller fails soft)
#   _CLAIM_OWNER  = the blocking assignee's name (for the abort message)
_backend_claim_item() {
    local ref="$1" who="$2" me me_id resp issue_id assignee_id assignee_name stype state_id
    _CLAIM_RESULT=""; _CLAIM_OWNER=""
    _linear_require_key
    # viewer = the API key's user — the Linear-side claimant identity.
    me="$(_linear_gql 'query { viewer { id name } }' | python3 -c 'import sys, json
try: d = json.load(sys.stdin)
except Exception: d = {}
v = (d.get("data") or {}).get("viewer") or {}
print("%s\t%s" % (v.get("id", ""), v.get("name", "")))' 2>/dev/null)"
    me_id="${me%%	*}"
    if [ -z "$me_id" ]; then _CLAIM_RESULT="UNREACHABLE"; return 0; fi

    if ! _linear_issue_query "$ref" 'id identifier assignee { id name } state { type } team { states(filter: { type: { eq: "started" } }, first: 1) { nodes { id } } }'; then
        _CLAIM_RESULT="UNREACHABLE"; return 0
    fi
    resp="$(_linear_gql "$_LQ_QUERY" "$_LQ_VARS")"
    # "<issue_id>\t<assignee_id>\t<assignee_name>\t<state_type>\t<started_state_id>" — split on TAB
    # only, so an assignee display name containing spaces (e.g. "Other Op") stays one field.
    IFS=$'\t' read -r issue_id assignee_id assignee_name stype state_id <<EOF
$(printf '%s' "$resp" | python3 -c 'import sys, json
try: d = json.load(sys.stdin)
except Exception: d = {}
nodes = (((d.get("data") or {}).get("issues") or {}).get("nodes")) or []
if not nodes:
    print("\t\t\t\t")
else:
    n = nodes[0]
    a = n.get("assignee") or {}
    st = n.get("state") or {}
    states = (((n.get("team") or {}).get("states") or {}).get("nodes")) or []
    print("%s\t%s\t%s\t%s\t%s" % (n.get("id", ""), a.get("id", ""), (a.get("name") or "").replace("\t"," "),
                                  st.get("type", ""), states[0]["id"] if states else ""))' 2>/dev/null)
EOF
    if [ -z "$issue_id" ]; then _CLAIM_RESULT="UNREACHABLE"; return 0; fi
    case "$stype" in
        completed|canceled|cancelled) _CLAIM_RESULT="ALREADY"; _CLAIM_OWNER="${assignee_name:-a completed issue}"; return 0 ;;
    esac
    if [ -n "$assignee_id" ] && [ "$assignee_id" != "$me_id" ]; then
        _CLAIM_RESULT="ALREADY"; _CLAIM_OWNER="${assignee_name:-another operator}"; return 0
    fi
    if [ "$assignee_id" = "$me_id" ] && [ "$stype" = "started" ]; then
        _CLAIM_RESULT="SELF"; _CLAIM_OWNER="${assignee_name:-$who}"; return 0
    fi
    # Unassigned/ours-but-not-started → claim: assign viewer + move to a started state (when the team
    # has one; assignment alone still claims it if not).
    _linear_gql 'mutation Claim($id: String!, $assignee: String!) {
  issueUpdate(id: $id, input: { assigneeId: $assignee }) { success }
}' "$(ID="$issue_id" A="$me_id" python3 -c 'import os, json
print(json.dumps({"id": os.environ["ID"], "assignee": os.environ["A"]}))')" >/dev/null 2>&1 || true
    if [ -n "$state_id" ]; then
        _linear_gql 'mutation Start($id: String!, $stateId: String!) {
  issueUpdate(id: $id, input: { stateId: $stateId }) { success }
}' "$(ID="$issue_id" SID="$state_id" python3 -c 'import os, json
print(json.dumps({"id": os.environ["ID"], "stateId": os.environ["SID"]}))')" >/dev/null 2>&1 || true
    fi
    # CLAIM-VERIFY: re-read the assignee and confirm the claim landed on us (not a racer).
    if ! _linear_issue_query "$ref" 'assignee { id name }'; then _CLAIM_RESULT="CLAIMED"; _CLAIM_OWNER="${me#*	}"; return 0; fi
    resp="$(_linear_gql "$_LQ_QUERY" "$_LQ_VARS")"
    IFS=$'\t' read -r assignee_id assignee_name <<EOF
$(printf '%s' "$resp" | python3 -c 'import sys, json
try: d = json.load(sys.stdin)
except Exception: d = {}
nodes = (((d.get("data") or {}).get("issues") or {}).get("nodes")) or []
a = (nodes[0].get("assignee") or {}) if nodes else {}
print("%s\t%s" % (a.get("id", ""), (a.get("name") or "").replace("\t"," ")))' 2>/dev/null)
EOF
    if [ -n "$assignee_id" ] && [ "$assignee_id" != "$me_id" ]; then
        _CLAIM_RESULT="ALREADY"; _CLAIM_OWNER="${assignee_name:-another operator}"
    else
        _CLAIM_RESULT="CLAIMED"; _CLAIM_OWNER="${me#*	}"
    fi
}
