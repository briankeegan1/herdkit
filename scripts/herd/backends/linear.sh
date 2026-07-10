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
# plus _backend_item_state REF for the link-state watcher, and the OPTIONAL planned-work markers
# (HERD-52 / HERD-244): _backend_queue_item / _backend_unqueue_item / _backend_list_queued for
# cross-operator plan-time visibility (a 📌 comment naming who sequenced the item after what and
# when, plus HERD-244 setting/clearing the issue ASSIGNEE to the API identity so the plan is visible
# in every Linear client view).
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

# _backend_tw_journal — HERD-85 tracker-write attribution. Emit ONE journal event per tracker STATE
# WRITE so `herd log | grep tracker_write` answers "which component moved <ref> to <state> on <pr>" in
# one line — the record that did NOT exist when HERD-67/HERD-69 showed In Progress after their PRs
# merged and diagnosing it needed Linear-history + transcript archaeology. Attribution is the
# HERD_COMPONENT the caller set (claim|scribe|reconcile), defaulting to 'manual' for a hand-run backend
# op. FAIL-SOFT by contract: journal_append is itself best-effort, and when journal.sh was never
# sourced into this context (so journal_append is undefined) this is a silent no-op — a journal problem
# must NEVER block or alter the state write (ZERO gate behavior change).
# Args: <ref> <requested-state> <result> [pr]   (pr falls back to $HERD_TW_PR when the arg is omitted).
_backend_tw_journal() {
    command -v journal_append >/dev/null 2>&1 || return 0
    local ref="$1" requested="$2" result="$3" pr="${4:-${HERD_TW_PR:-}}"
    if [ -n "$pr" ]; then
        journal_append tracker_write ref "$ref" requested "$requested" \
            component "${HERD_COMPONENT:-manual}" backend linear result "$result" pr "$pr"
    else
        journal_append tracker_write ref "$ref" requested "$requested" \
            component "${HERD_COMPONENT:-manual}" backend linear result "$result"
    fi
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

_linear_short_title() {
    # Derive a SHORT tracker title from the full request text (HERD-77). The title SUMMARIZES the
    # request; it NEVER replaces the description (the caller still stores the full text). A first line
    # that is already short (<=100 chars) is the title verbatim. A long first line — the
    # "first-line-as-essay" complaint (2026-07-07): a one-paragraph request became a giant title
    # duplicated in the description, and seven issues had to be hand-renamed — is reduced to its first
    # sentence/clause (split on ' — ', ': ', or '. ') and hard-capped at 100 chars with an ellipsis.
    # $1 = full text; prints the derived title.
    TEXT="$1" python3 -c 'import os
MAX = 100
first = os.environ["TEXT"].split("\n", 1)[0].strip()
if len(first) <= MAX:
    print(first)
else:
    cut = len(first)
    for d in (" — ", ": ", ". "):
        i = first.find(d)
        if i != -1:
            cut = min(cut, i)
    clause = first[:cut].strip()
    if not clause or len(clause) > MAX - 1:
        clause = first[:MAX - 1].rstrip()
    print(clause + "…")'
}

# _linear_error_text — read a GraphQL response on stdin and print the REASON Linear refused, as
# "<code> <message>" (either half may be empty). HERD-267: the add path used to discard the response
# body entirely, so a 400 USAGE_LIMIT_EXCEEDED (the free-tier ISSUE CAP) was indistinguishable from a
# transient flake — the whole reason six coordinator filings vanished silently over two hours while
# PR #377 blamed an "API flake". The code comes from errors[].extensions.code (Linear's machine key,
# e.g. USAGE_LIMIT_EXCEEDED / AUTHENTICATION_ERROR); it is printed FIRST so create_retry_class matches
# on the unambiguous key before falling back to prose. Empty output when the response carries no
# errors array (a plain success:false), which classifies as 'unknown' and stays retryable.
_linear_error_text() {
    python3 -c 'import sys, json
try: d = json.load(sys.stdin)
except Exception: d = {}
errs = d.get("errors") or []
if not errs:
    sys.exit(0)
e = errs[0] if isinstance(errs[0], dict) else {}
ext = e.get("extensions") or {}
code = ext.get("code") or ext.get("type") or ""
msg = e.get("message") or ""
print(" ".join(x for x in (str(code), str(msg)) if x).replace("\n", " ").strip())' 2>/dev/null || true
}

_backend_add_item() {
    # $1 = claimed queue file path (REQ_ID, unused here); $2 = item text / summary.
    # Title = a SHORT summary derived from the request (HERD-77 — never the whole first line as an
    # essay); description = the FULL text. Sets _BACKEND_RESULT=DONE on a created issue (and surfaces
    # its URL), NOCHANGE if Linear declines or no team is available.
    # HERD-267: on NOCHANGE it ALSO sets _BACKEND_ERROR to the reason Linear gave, so the caller's
    # durable retry queue can tell a permanent wall (issue cap, bad key) from a retryable hiccup.
    local text="$2" title team mut vars resp parsed ok ident url
    _BACKEND_ERROR=""
    _linear_require_key
    title="$(_linear_short_title "$text")"
    team="$(_linear_team_id)"
    if [ -z "$team" ]; then
        echo "linear backend: no team available to create the issue in (set LINEAR_TEAM_ID in .herd/secrets)" >&2
        _BACKEND_RESULT="NOCHANGE"
        _BACKEND_ERROR="no team available (set LINEAR_TEAM_ID in .herd/secrets)"
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
        # Surface WHY (HERD-267). Loud on stderr as well as in _BACKEND_ERROR: the drainer's report
        # tail is not the only place an operator reads, and a silently-consumed cap is the incident.
        _BACKEND_ERROR="$(printf '%s' "$resp" | _linear_error_text)"
        if [ -n "$_BACKEND_ERROR" ]; then
            echo "linear backend: issueCreate refused — $_BACKEND_ERROR" >&2
        fi
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
    if ! _linear_issue_query "$slug" "id identifier title team { $(_linear_states_field completed) }"; then
        echo "linear backend: no issue matching '$slug' — nothing to ship" >&2
        _BACKEND_RESULT="NOCHANGE"
        return 0
    fi
    resp="$(_linear_gql "$_LQ_QUERY" "$_LQ_VARS")"
    read -r issue_id state_id <<EOF
$(printf '%s' "$resp" | PREF="$(_linear_preferred_state_name completed)" python3 -c "$_LINEAR_PICK_STATE_PY"'
import sys, json, os
try: d = json.load(sys.stdin)
except Exception: d = {}
nodes = (((d.get("data") or {}).get("issues") or {}).get("nodes")) or []
if not nodes:
    print("\t")
else:
    n = nodes[0]
    states = (((n.get("team") or {}).get("states") or {}).get("nodes")) or []
    print("%s\t%s" % (n.get("id", ""), _pick_state(states, os.environ.get("PREF", ""))))' 2>/dev/null)
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
    # Move to the Done state — reporting DONE only on a CONFIRMED success:true. A transiently-failed
    # (or errored) issueUpdate returns NOCHANGE so the watcher's fuzzy-scribe retry path re-attempts,
    # rather than the old optimistic DONE that mislabeled a failed write as a verified ship
    # (PR #187/HERD-67 stayed In Progress after merge, 2026-07-07). When no completed state resolved
    # there is no move to verify, so behavior is unchanged (the PR-link comment already posted).
    if [ -n "$state_id" ]; then
        if _linear_issue_update_state_verified "$issue_id" "$state_id"; then
            _BACKEND_RESULT="DONE"
        else
            echo "linear backend: issueUpdate shipping '$slug' to Done was not confirmed (success≠true) — leaving it for retry (skipping, not filing)" >&2
            _BACKEND_RESULT="NOCHANGE"
        fi
    else
        _BACKEND_RESULT="DONE"
    fi
    # HERD-85: journal the ship as a tracker_write (requested 'shipped', with the PR link) so the
    # component that closed the item is attributable in one `herd log` line. Fail-soft.
    _backend_tw_journal "$slug" shipped "$_BACKEND_RESULT" "$pr"
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

_linear_preferred_state_name() {
    # Given a resolved workflow-state TYPE, print the human state NAME the resolver should PREFER when
    # a team has MORE THAN ONE state of that type. Linear groups states under a type, and a workspace
    # can legitimately have several 'started' states ('In Progress' AND 'In Review') — the original
    # 'first state of the type' logic then picked whichever the API returned first, landing work in
    # 'In Review' (gh #169). We name the canonical target so it wins regardless of API order; an empty
    # name means "no preference — fall back to the lowest-position state of the type".
    case "$1" in
        completed) printf 'Done' ;;
        started)   printf 'In Progress' ;;
        canceled)  printf 'Canceled' ;;
        *)         printf '' ;;
    esac
}

_linear_states_field() {
    # GraphQL sub-selection for a team's workflow states of TYPE $1. Deliberately NOT first:1 — the
    # name-first-then-position picker (gh #169) must see EVERY state of the type, plus each one's name
    # and position, to avoid Linear handing back 'In Review' ahead of 'In Progress'.
    printf 'states(filter: { type: { eq: "%s" } }) { nodes { id name position } }' "$1"
}

# Shared Python helper (a function def) prepended to every parser that must choose ONE workflow state
# of a resolved type. Given that type's states (each {id,name,position}) and the preferred human name
# (via $PREF in the env), _pick_state returns the id of the state whose name equals PREF
# case-insensitively; failing that, the state with the LOWEST position — Linear's canonical ordering,
# so the earliest started state ('In Progress') wins and 'In Review' is never silently chosen. This is
# the gh #169 fix for a workspace with several started-type (or completed/canceled-type) states.
_LINEAR_PICK_STATE_PY='
def _pick_state(states, preferred):
    states = states or []
    if not states:
        return ""
    if preferred:
        p = preferred.strip().lower()
        for s in states:
            if (s.get("name") or "").strip().lower() == p:
                return s.get("id") or ""
    def _pos(s):
        v = s.get("position")
        return v if isinstance(v, (int, float)) else float("inf")
    return min(states, key=_pos).get("id") or ""
'

_linear_resolve_by_title() {
    # Fallback resolution when the request names no identifier: match OPEN-ish issues by a title
    # substring (case-insensitive). $1 = title text; $2 = target state type (inlined into the states
    # sub-filter, exactly as the identifier path builds it). Prints the same
    # {"data":{"issues":{"nodes":[…]}}} shape as the identifier query so ONE parser handles both.
    # Deliberately CONSERVATIVE: first:2 so the caller can require a UNIQUE match and never mislabel
    # the wrong issue when a phrase is ambiguous.
    local title="$1" stype="$2" q v
    q="query T(\$t: String!) {
  issues(filter: { title: { containsIgnoreCase: \$t } }, first: 2) {
    nodes { id identifier title team { $(_linear_states_field "$stype") } }
  }
}"
    v="$(T="$title" python3 -c 'import os, json
print(json.dumps({"t": os.environ["T"]}))')"
    _linear_gql "$q" "$v"
}

_linear_issue_update_state_verified() {
    # Fire the issueUpdate(stateId:) transition and VERIFY it actually landed before a caller may
    # report DONE. $1 = issue id; $2 = target workflow-state id. Returns 0 ONLY when the response
    # parses data.issueUpdate.success == true; returns 1 on any transport failure, GraphQL error, or
    # success:false. Callers translate a non-zero return into _BACKEND_RESULT=NOCHANGE so agent-watch's
    # fuzzy-scribe retry path re-attempts — instead of the old optimistic ">/dev/null 2>&1 || true"
    # followed by an unconditional DONE, which reported a transiently-failed write as a verified
    # transition and made _reconcile_via_ref journal resolution=explicit-ref and SKIP the retry
    # (real incident: PR #187/HERD-67 stayed In Progress after merge, 2026-07-07).
    local id="$1" state_id="$2" resp ok
    resp="$(_linear_gql 'mutation Move($id: String!, $stateId: String!) {
  issueUpdate(id: $id, input: { stateId: $stateId }) { success }
}' "$(ID="$id" SID="$state_id" python3 -c 'import os, json
print(json.dumps({"id": os.environ["ID"], "stateId": os.environ["SID"]}))')" 2>/dev/null)" || return 1
    ok="$(printf '%s' "$resp" | python3 -c 'import sys, json
try: d = json.load(sys.stdin)
except Exception: d = {}
print("1" if (((d.get("data") or {}).get("issueUpdate") or {}).get("success")) else "0")' 2>/dev/null)"
    [ "$ok" = "1" ]
}

_backend_update_state() {
    # $1 = item ref (Linear identifier e.g. HERD-22, a leading '#' tolerated — or a title phrase when
    # no identifier is present); $2 = target state (done|in-progress|canceled + synonyms).
    # Resolve the issue + a workflow state of the mapped type for its OWN team, then issueUpdate it
    # into that state — reusing the same issues(filter:) + issueUpdate machinery as _backend_mark_shipped
    # (issueSearch was deprecated/removed by Linear 2026-07). Sets _BACKEND_RESULT=DONE|NOCHANGE.
    # This is the intent-dispatch path (gh #139): a "mark HERD-22 done" request transitions the EXISTING
    # issue instead of filing a brand-new one. NOCHANGE (no unique match / no such state) files nothing.
    local ref="$1" want="$2" stype pref fields resp issue_id state_id
    _linear_require_key
    stype="$(_linear_state_type_for "$want")"
    if [ -z "$stype" ]; then
        echo "linear backend: unknown target state '$want' — expected done|in-progress|canceled (skipping, not filing)" >&2
        _BACKEND_RESULT="NOCHANGE"
        return 0
    fi
    pref="$(_linear_preferred_state_name "$stype")"
    fields="id identifier title team { $(_linear_states_field "$stype") }"
    if _linear_issue_query "$ref" "$fields"; then
        resp="$(_linear_gql "$_LQ_QUERY" "$_LQ_VARS")"          # identifier path (HERD-22 → number+team)
    else
        resp="$(_linear_resolve_by_title "$ref" "$stype")"      # conservative title match
    fi
    # ONE parser for both shapes: require EXACTLY ONE matching node (uniqueness = conservatism), then
    # read its id + the mapped-type state id chosen name-first-then-lowest-position (gh #169), so a
    # workspace with both 'In Progress' and 'In Review' started states resolves to 'In Progress'.
    read -r issue_id state_id <<EOF
$(printf '%s' "$resp" | PREF="$pref" python3 -c "$_LINEAR_PICK_STATE_PY"'
import sys, json, os
try: d = json.load(sys.stdin)
except Exception: d = {}
nodes = (((d.get("data") or {}).get("issues") or {}).get("nodes")) or []
if len(nodes) != 1:
    print("\t")
else:
    n = nodes[0]
    states = (((n.get("team") or {}).get("states") or {}).get("nodes")) or []
    print("%s\t%s" % (n.get("id", ""), _pick_state(states, os.environ.get("PREF", ""))))' 2>/dev/null)
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
    # Transition the issue — reporting DONE only when the issueUpdate is CONFIRMED (success:true). A
    # transiently-failed mutation returns NOCHANGE so agent-watch's _reconcile_via_ref does NOT journal
    # resolution=explicit-ref and skip the fuzzy-scribe fallback that would retry — the exact failure
    # behind PR #187/HERD-67 staying In Progress after merge (2026-07-07).
    if _linear_issue_update_state_verified "$issue_id" "$state_id"; then
        _BACKEND_RESULT="DONE"
    else
        echo "linear backend: issueUpdate for '$ref' → '$want' was not confirmed (success≠true) — state left unresolved for retry (skipping, not filing)" >&2
        _BACKEND_RESULT="NOCHANGE"
    fi
    # HERD-85: journal the write we just attempted (result = the verified outcome) so attribution is a
    # one-line `herd log` lookup instead of transcript archaeology. Fail-soft; never affects the result.
    _backend_tw_journal "$ref" "$want" "$_BACKEND_RESULT"
}

_backend_amend() {
    # $1 = item ref (Linear identifier e.g. HERD-22, a leading '#' tolerated — or a title phrase when
    # no identifier is present); $2 = the note to post.
    # HERD-128 AMEND: attach a clarification/comment to an EXISTING issue via commentCreate — first-
    # class, WITHOUT touching its workflow state or title. Reuses the same issues(filter:) resolution
    # as _backend_update_state (issueSearch was deprecated/removed by Linear 2026-07). Conservative:
    # resolve to EXACTLY ONE issue (identifier, or a UNIQUE title match) — zero/ambiguous → NOCHANGE +
    # a LOUD reason (skip-over-guess), nothing posted. Sets _BACKEND_RESULT=DONE|NOCHANGE.
    local ref="$1" note="$2" resp issue_id ok
    _BACKEND_RESULT="NOCHANGE"
    _linear_require_key
    if _linear_issue_query "$ref" "id identifier"; then
        resp="$(_linear_gql "$_LQ_QUERY" "$_LQ_VARS")"          # identifier path (HERD-22 → number+team)
    else
        resp="$(_linear_resolve_by_title "$ref" started)"       # conservative title match (first:2 → unique-only)
    fi
    # Require EXACTLY ONE matching node — uniqueness IS the conservatism, mirroring _backend_update_state.
    issue_id="$(printf '%s' "$resp" | python3 -c 'import sys, json
try: d = json.load(sys.stdin)
except Exception: d = {}
nodes = (((d.get("data") or {}).get("issues") or {}).get("nodes")) or []
print(nodes[0].get("id", "") if len(nodes) == 1 else "")' 2>/dev/null)"
    if [ -z "$issue_id" ]; then
        echo "linear backend: no unique issue matching '$ref' — nothing to amend (skipping, not posting)" >&2
        _backend_tw_journal "$ref" amend "$_BACKEND_RESULT"   # HERD-85 attribution (records the attempt)
        return 0
    fi
    ok="$(_linear_gql 'mutation Amend($issueId: String!, $body: String!) {
  commentCreate(input: { issueId: $issueId, body: $body }) { success }
}' "$(ID="$issue_id" BODY="$note" python3 -c 'import os, json
print(json.dumps({"issueId": os.environ["ID"], "body": os.environ["BODY"]}))')" 2>/dev/null \
      | python3 -c 'import sys, json
try: d = json.load(sys.stdin)
except Exception: d = {}
print("1" if (((d.get("data") or {}).get("commentCreate") or {}).get("success")) else "0")' 2>/dev/null)"
    [ "$ok" = "1" ] && _BACKEND_RESULT="DONE"
    _backend_tw_journal "$ref" amend "$_BACKEND_RESULT"   # HERD-85 attribution
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
    #   #<identifier> \t <state-type> \t <state-name> \t <title> \t <desc-snippet> \t <assignee> \t <url>
    # state-type is Linear's workflow-state TYPE (started|unstarted|backlog|triage) — the machine
    # key a viewer groups on; state-name is the human label ("In Progress", "In Review", …). The
    # description snippet is whitespace-flattened (tabs/newlines → spaces, so the TSV shape can
    # never be corrupted by field content) and capped at 280 chars. The trailing <url> is the issue's
    # canonical Linear URL (whitespace-flattened, so it can never carry a TAB) — backlog-view.sh wraps
    # the id chip in an OSC 8 hyperlink to it (HERD-49); older consumers that read only the first six
    # fields ignore it. Lines are sorted started-first
    # (in-progress work surfaces at the top), then unstarted, backlog, triage — stable within each
    # group (API order preserved). Consumed by `herd backlog --rich` → backlog-view.sh's rich
    # renderer; callers that don't know this op exists keep using _backend_list_open unchanged.
    _linear_require_key
    local query vars
    if [ -n "${LINEAR_TEAM_ID:-}" ]; then
        query='query L($team: ID!) {
  issues(filter: { state: { type: { nin: ["completed", "canceled"] } }, team: { id: { eq: $team } } }, first: 250) {
    nodes { identifier title description url state { name type } assignee { displayName } }
  }
}'
        vars="$(TEAM="$LINEAR_TEAM_ID" python3 -c 'import os, json
print(json.dumps({"team": os.environ["TEAM"]}))')"
    else
        query='query {
  issues(filter: { state: { type: { nin: ["completed", "canceled"] } } }, first: 250) {
    nodes { identifier title description url state { name type } assignee { displayName } }
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
    url = flat(n.get("url") or "")
    print("#%s\t%s\t%s\t%s\t%s\t%s\t%s" % (n.get("identifier", ""), st.get("type") or "",
                                            flat(st.get("name")), flat(n.get("title")), desc, assignee, url))' 2>/dev/null || true
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

# _backend_ref_is_identifier <ref> — OPTIONAL. Does <ref> have the shape of an identifier THIS tracker
# mints? Linear issues are TEAMKEY-NUMBER (HERD-267; a leading '#' is tolerated). Exit 0 = yes, 1 = no.
#
# This op exists so the SHAPE of a tracker's ids lives with the tracker, never in generic engine code.
# The sweep's retroactive-linkage leg needs to know that `Refs: some-branch-slug` on a Linear project
# is proof no id was ever minted — but that inference is FALSE for the default `file` backend, whose
# item ref IS a title slug, and meaningless for `changelog`, which has no ids at all. A backend that
# does not define this op tells the leg "I cannot judge a ref by its shape", and the leg stands down.
_backend_ref_is_identifier() {
    local slug="${1#\#}" num key
    case "$slug" in *-*) ;; *) return 1 ;; esac
    num="${slug##*-}"
    key="${slug%-*}"
    [ -n "$key" ] || return 1
    case "$num" in ''|*[!0-9]*) return 1 ;; esac
    return 0
}

# _backend_item_missing <ref> — OPTIONAL, TRI-STATE existence probe. The ONLY safe basis for an
# automated "this tracker item was never created" verdict (HERD-267).
#
#   exit 0  PROVABLY MISSING — the API answered, cleanly, with zero matching issues.
#   exit 1  EXISTS          — the API answered and resolved the ref.
#   exit 2  UNPROVEN        — no key, no curl, an unparseable ref, a transport failure, an HTTP/GraphQL
#                             error body (auth, rate limit, 5xx), or anything else that means WE DO NOT
#                             KNOW. The caller must treat this exactly like EXISTS: say nothing, do nothing.
#
# Why this exists rather than reusing _backend_show_item: that op collapses not-found, transport
# failure, auth error, rate limit and every GraphQL error body into ONE non-zero return. A caller that
# reads non-zero as "missing" cannot tell a tracker that never minted the item from a tracker that is
# DOWN or REFUSING — so a Linear outage (or an expired key) would read as "every merged PR's item is
# missing" and drive a burst of duplicate filings. Worse, an expired key produces that misreading at
# exactly the moment create_retry_class is correctly marking creates auth/permanent. The distinction
# between "no answer" and "answered: nothing there" is the whole safety property, so it gets its own op.
#
# `errors` is checked before `data`: Linear returns HTTP 200 with a populated `errors` array (and a
# null/empty `data`) for auth and rate-limit refusals, which the nodes parser alone would read as zero
# matches. curl's exit status is checked too — an unreachable host yields an empty body, not an error body.
_backend_item_missing() {
    local ref="$1" resp
    [ -n "${LINEAR_API_KEY:-}" ] || return 2
    command -v curl >/dev/null 2>&1 || return 2
    _linear_issue_query "$ref" 'identifier' || return 2   # not a TEAMKEY-NUMBER identifier → we cannot ask
    resp="$(_linear_gql "$_LQ_QUERY" "$_LQ_VARS" 2>/dev/null)" || return 2
    [ -n "$resp" ] || return 2
    printf '%s' "$resp" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(2)                       # unparseable body — the API did not answer us
if not isinstance(d, dict) or d.get("errors"):
    sys.exit(2)                       # auth / rate limit / 5xx / any GraphQL error → UNPROVEN
data = d.get("data")
if not isinstance(data, dict) or "issues" not in data:
    sys.exit(2)                       # no data envelope at all → UNPROVEN
nodes = ((data.get("issues") or {}).get("nodes"))
if nodes is None:
    sys.exit(2)
sys.exit(0 if len(nodes) == 0 else 1)  # a clean answer: 0 matches = provably missing
' 2>/dev/null
    return $?
}

_backend_item_state() {
    # $1 = <link-name>#<id> — caller has resolved the link; LINEAR_API_KEY is in env.
    # Resolves the issue via issues(filter:) (issueSearch was deprecated/removed by Linear 2026-07)
    # and reads state.type, setting ITEM_STATE=open|closed|in-progress. Also sets ITEM_UPDATED to the
    # issue's last-updated day (YYYY-MM-DD, best-effort — empty if absent), used by the HERD-117 claim
    # guard as evidence when it refuses a stale (Done/Canceled) pick.
    # Linear state types: completed/canceled → closed; started → in-progress; all others → open.
    local ref="$1" slug resp parsed stype
    _linear_require_key
    slug="${ref#*#}"
    ITEM_UPDATED=""
    if ! _linear_issue_query "$slug" 'state { type } updatedAt'; then
        ITEM_STATE="open"
        return 0
    fi
    resp="$(_linear_gql "$_LQ_QUERY" "$_LQ_VARS")"
    # Emit "<type>\t<updated-day>" so a single parse yields both the state class and the evidence stamp.
    parsed="$(printf '%s' "$resp" | python3 -c '
import sys, json
try:    d = json.load(sys.stdin)
except Exception: d = {}
nodes = (((d.get("data") or {}).get("issues") or {}).get("nodes")) or []
n = nodes[0] if nodes else {}
print("%s\t%s" % ((n.get("state") or {}).get("type", ""), (n.get("updatedAt") or "")[:10]))
' 2>/dev/null || printf '\t')"
    stype="${parsed%%$'\t'*}"
    ITEM_UPDATED="${parsed#*$'\t'}"
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

    if ! _linear_issue_query "$ref" "id identifier assignee { id name } state { type } team { $(_linear_states_field started) }"; then
        _CLAIM_RESULT="UNREACHABLE"; return 0
    fi
    resp="$(_linear_gql "$_LQ_QUERY" "$_LQ_VARS")"
    # "<issue_id>|<assignee_id>|<assignee_name>|<state_type>|<started_state_id>" — split on the ASCII
    # unit separator (\x1f), NOT a tab: tab is IFS-whitespace, so `read` would COLLAPSE the empty
    # fields of an unassigned issue (assignee null → id/name empty) and shift every column left,
    # misreading a claimable issue as already-taken. \x1f never appears in a display name and is not
    # whitespace, so empty fields are preserved. The started state is chosen name-first-then-lowest-
    # position (gh #169): a workspace with both 'In Progress' and 'In Review' started states claims
    # into 'In Progress', never 'In Review'.
    IFS=$'\x1f' read -r issue_id assignee_id assignee_name stype state_id <<EOF
$(printf '%s' "$resp" | PREF="$(_linear_preferred_state_name started)" python3 -c "$_LINEAR_PICK_STATE_PY"'
import sys, json, os
SEP = "\x1f"
try: d = json.load(sys.stdin)
except Exception: d = {}
nodes = (((d.get("data") or {}).get("issues") or {}).get("nodes")) or []
if not nodes:
    print(SEP * 4)
else:
    n = nodes[0]
    a = n.get("assignee") or {}
    st = n.get("state") or {}
    states = (((n.get("team") or {}).get("states") or {}).get("nodes")) or []
    print(SEP.join([n.get("id", ""), a.get("id", ""), (a.get("name") or "").replace(SEP, " "),
                    st.get("type", ""), _pick_state(states, os.environ.get("PREF", ""))]))' 2>/dev/null)
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
    if ! _linear_issue_query "$ref" 'assignee { id name }'; then _CLAIM_RESULT="CLAIMED"; _CLAIM_OWNER="${me#*	}"; _backend_tw_journal "$ref" in-progress CLAIMED; return 0; fi
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
        # HERD-85: a claim moves the issue into a started (in-progress) state — journal that write.
        _backend_tw_journal "$ref" in-progress CLAIMED
    fi
}

# _backend_release_item REF WHO — release OUR OWN claim (HERD-162 F12) by clearing the issue ASSIGNEE,
# the marker _backend_claim_item set. Like the claim, the claimant identity is the API key's own user
# (viewer{}), not WHO — WHO is informational. The workflow STATE is deliberately left as it stands: a
# claim moves the issue to `started`, and moving it BACK is a re-queue, which is a coordinator act, not
# a watcher's. An unassigned issue in a started state is exactly what the claim path treats as
# re-pickable, so clearing the assignee alone un-wedges the other operator. Refuses to clear an
# assignee that is not ours (never steal a live claim) and never touches a completed/canceled issue.
#   _RELEASE_RESULT = RELEASED | NOTOURS (unassigned / another assignee / shipped) |
#                     UNREACHABLE (unresolvable ref, no viewer → caller fails soft)
#   _RELEASE_OWNER  = the blocking assignee's name, when the refusal was NOTOURS
_backend_release_item() {
    local ref="$1" who="$2" me_id resp issue_id assignee_id assignee_name stype
    _RELEASE_RESULT=""; _RELEASE_OWNER=""
    _linear_require_key
    me_id="$(_linear_viewer_id)"
    if [ -z "$me_id" ]; then _RELEASE_RESULT="UNREACHABLE"; return 0; fi

    if ! _linear_issue_query "$ref" "id identifier assignee { id name } state { type }"; then
        _RELEASE_RESULT="UNREACHABLE"; return 0
    fi
    resp="$(_linear_gql "$_LQ_QUERY" "$_LQ_VARS")"
    # Split on the ASCII unit separator, NOT a tab — an unassigned issue's empty fields must survive
    # `read` intact (the same collapse hazard _backend_claim_item documents at length).
    IFS=$'\x1f' read -r issue_id assignee_id assignee_name stype <<EOF
$(printf '%s' "$resp" | python3 -c 'import sys, json
SEP = "\x1f"
try: d = json.load(sys.stdin)
except Exception: d = {}
nodes = (((d.get("data") or {}).get("issues") or {}).get("nodes")) or []
if not nodes:
    print(SEP * 3)
else:
    n = nodes[0]
    a = n.get("assignee") or {}
    st = n.get("state") or {}
    print(SEP.join([n.get("id", ""), a.get("id", "") or "",
                    (a.get("name") or "").replace(SEP, " "), st.get("type", "")]))' 2>/dev/null)
EOF
    if [ -z "$issue_id" ]; then _RELEASE_RESULT="UNREACHABLE"; return 0; fi
    case "$stype" in
        completed|canceled|cancelled) _RELEASE_RESULT="NOTOURS"; _RELEASE_OWNER="a completed issue"; return 0 ;;
    esac
    if [ -z "$assignee_id" ] || [ "$assignee_id" != "$me_id" ]; then
        _RELEASE_RESULT="NOTOURS"; _RELEASE_OWNER="${assignee_name:-nobody}"; return 0
    fi

    _linear_gql 'mutation Release($id: String!, $assignee: String) {
  issueUpdate(id: $id, input: { assigneeId: $assignee }) { success }
}' "$(ID="$issue_id" python3 -c 'import os, json
print(json.dumps({"id": os.environ["ID"], "assignee": None}))')" >/dev/null 2>&1 || true

    # RELEASE-VERIFY: re-read the assignee and confirm the claim marker is actually gone. A mutation
    # that silently failed must not be reported as a release — the item would stay wedged in silence.
    if ! _linear_issue_query "$ref" 'assignee { id }'; then _RELEASE_RESULT="UNREACHABLE"; return 0; fi
    resp="$(_linear_gql "$_LQ_QUERY" "$_LQ_VARS")"
    assignee_id="$(printf '%s' "$resp" | python3 -c 'import sys, json
try: d = json.load(sys.stdin)
except Exception: d = {}
nodes = (((d.get("data") or {}).get("issues") or {}).get("nodes")) or []
a = (nodes[0].get("assignee") or {}) if nodes else {}
print(a.get("id", "") or "")' 2>/dev/null)"
    if [ -n "$assignee_id" ]; then
        _RELEASE_RESULT="UNREACHABLE"; return 0     # the unassign did not stick — say nothing happened
    fi
    _RELEASE_RESULT="RELEASED"; _RELEASE_OWNER="${who:-viewer}"
    _backend_tw_journal "$ref" open RELEASED        # HERD-85: a release is a tracker write
}

# ── Planned-work markers (HERD-52) — cross-operator plan-time visibility ─────────────────────────
# A coordinator that has SEQUENCED an item to spawn NEXT (but not yet spawned it) publishes a
# lightweight PLANNED marker so a second operator sees it and doesn't grab the same item. This
# complements the pre-spawn CLAIM (_backend_claim_item, HERD-50, which covers spawn-time): the marker
# covers PLAN-time, the window between "I've decided to build this next" and the claim. On Linear the
# marker is a COMMENT of the shared shape "📌 queued by <who>: sequenced after <blocker> [<epoch>]"
# (an ISO-ish unix timestamp so a reader can age it out). HERD-244: queue ALSO sets the issue
# ASSIGNEE to the API key's viewer (a first-class field every Linear client surfaces) and unqueue
# clears that assignee when the plan is dropped — only if we still own it and a claim has not moved
# the issue into a started state. The 📌 comment is kept for backward-compat. All ops are
# BACKEND-OPTIONAL and FAIL-SOFT: an unresolvable ref, a missing key, a transport hiccup, or an
# assignee write the backend rejects is NOCHANGE/empty for that part, never a hard error — a plan
# marker is advisory, never a gate.
_LINEAR_QUEUE_MARK_RE='📌 queued by (.*?): (.*?) \[(\d+)\]'

# _linear_viewer_id — API-key identity used as the plan-time assignee (same as claim). Empty on fail.
_linear_viewer_id() {
    _linear_gql 'query { viewer { id } }' | python3 -c 'import sys, json
try: d = json.load(sys.stdin)
except Exception: d = {}
print(((d.get("data") or {}).get("viewer") or {}).get("id") or "")' 2>/dev/null
}

# _linear_plan_set_assignee ISSUE_ID CUR_ASSIGNEE_ID — HERD-244 fail-soft: assign the viewer when the
# issue is unassigned (or already ours). Never steals another operator's assignee. Returns 0 always.
_linear_plan_set_assignee() {
    local issue_id="$1" cur_assignee="${2:-}" me_id
    [ -n "$issue_id" ] || return 0
    me_id="$(_linear_viewer_id)"
    [ -n "$me_id" ] || return 0
    if [ -n "$cur_assignee" ] && [ "$cur_assignee" != "$me_id" ]; then
        return 0   # another operator already owns it — do not overwrite
    fi
    _linear_gql 'mutation PlanAssign($id: String!, $assignee: String!) {
  issueUpdate(id: $id, input: { assigneeId: $assignee }) { success }
}' "$(ID="$issue_id" A="$me_id" python3 -c 'import os, json
print(json.dumps({"id": os.environ["ID"], "assignee": os.environ["A"]}))')" >/dev/null 2>&1 || true
}

# _linear_plan_clear_assignee ISSUE_ID CUR_ASSIGNEE_ID STATE_TYPE — HERD-244 fail-soft: unassign when
# (a) the issue is still assigned to the viewer AND (b) state is not started (a claim owns started +
# assignee — unqueue after claim must not undo the claim). assigneeId: null is Linear's unassign.
_linear_plan_clear_assignee() {
    local issue_id="$1" cur_assignee="${2:-}" stype="${3:-}" me_id
    [ -n "$issue_id" ] || return 0
    [ -n "$cur_assignee" ] || return 0
    case "$stype" in started) return 0 ;; esac   # claim supersedes the plan-time assignee
    me_id="$(_linear_viewer_id)"
    [ -n "$me_id" ] || return 0
    [ "$cur_assignee" = "$me_id" ] || return 0
    _linear_gql 'mutation PlanUnassign($id: String!, $assignee: String) {
  issueUpdate(id: $id, input: { assigneeId: $assignee }) { success }
}' "$(ID="$issue_id" python3 -c 'import os, json
print(json.dumps({"id": os.environ["ID"], "assignee": None}))')" >/dev/null 2>&1 || true
}

# _backend_queue_item REF WHO BLOCKER — publish a planned marker comment on the issue. BLOCKER is the
# item this one is sequenced after (may be empty → "sequenced next"). Also sets assignee to the API
# identity (viewer) when free (HERD-244). Sets _BACKEND_RESULT=DONE|NOCHANGE off the comment write;
# assignee is fail-soft and never flips DONE→NOCHANGE.
_backend_queue_item() {
    local ref="$1" who="$2" blocker="$3" resp issue_id cur_assignee ok ts detail body
    _linear_require_key
    [ -n "$who" ] || who="unknown-operator"
    ts="$(date +%s 2>/dev/null || echo 0)"
    if [ -n "$blocker" ]; then detail="sequenced after $blocker"; else detail="sequenced next"; fi
    if ! _linear_issue_query "$ref" "id identifier assignee { id }"; then
        echo "linear backend: '$ref' is not a resolvable identifier — cannot publish a queued marker" >&2
        _BACKEND_RESULT="NOCHANGE"; return 0
    fi
    resp="$(_linear_gql "$_LQ_QUERY" "$_LQ_VARS")"
    # issue_id \x1f assignee_id — unit separator so an unassigned issue's empty field is preserved.
    IFS=$'\x1f' read -r issue_id cur_assignee <<EOF
$(printf '%s' "$resp" | python3 -c 'import sys, json
SEP = "\x1f"
try: d = json.load(sys.stdin)
except Exception: d = {}
nodes = (((d.get("data") or {}).get("issues") or {}).get("nodes")) or []
if not nodes:
    print(SEP)
else:
    n = nodes[0]
    a = n.get("assignee") or {}
    print(SEP.join([n.get("id", ""), a.get("id", "") or ""]))' 2>/dev/null)
EOF
    if [ -z "$issue_id" ]; then
        echo "linear backend: no issue matching '$ref' — nothing to queue" >&2
        _BACKEND_RESULT="NOCHANGE"; return 0
    fi
    body="$(printf '📌 queued by %s: %s [%s]' "$who" "$detail" "$ts")"
    ok="$(_linear_gql 'mutation Q($issueId: String!, $body: String!) {
  commentCreate(input: { issueId: $issueId, body: $body }) { success }
}' "$(ID="$issue_id" BODY="$body" python3 -c 'import os, json
print(json.dumps({"issueId": os.environ["ID"], "body": os.environ["BODY"]}))')" 2>/dev/null \
      | python3 -c 'import sys, json
try: d = json.load(sys.stdin)
except Exception: d = {}
print("1" if (((d.get("data") or {}).get("commentCreate") or {}).get("success")) else "0")' 2>/dev/null)"
    if [ "$ok" = "1" ]; then _BACKEND_RESULT="DONE"; else _BACKEND_RESULT="NOCHANGE"; fi
    # HERD-244: surface plan-time intent on the first-class assignee field too (fail-soft).
    _linear_plan_set_assignee "$issue_id" "$cur_assignee"
    # HERD-85: journal the plan-time write (component=plan set by the caller). Fail-soft.
    _backend_tw_journal "$ref" queued "$_BACKEND_RESULT"
}

# _backend_unqueue_item REF WHO — clear the planned marker(s) on the issue (plan dropped, or the item
# was spawned and the claim now supersedes it). WHO is informational. Deletes every 📌-marker comment
# on the issue via commentDelete. When markers were cleared and the plan-time assignee is still the
# viewer on a non-started issue, also unassigns (HERD-244). Sets _BACKEND_RESULT=DONE (≥1 deleted) |
# NOCHANGE (none present).
_backend_unqueue_item() {
    local ref="$1" who="$2" resp ids id deleted=0 issue_id cur_assignee stype
    _linear_require_key
    if ! _linear_issue_query "$ref" "id comments { nodes { id body } } assignee { id } state { type }"; then
        _BACKEND_RESULT="NOCHANGE"; return 0
    fi
    resp="$(_linear_gql "$_LQ_QUERY" "$_LQ_VARS")"
    IFS=$'\x1f' read -r issue_id cur_assignee stype <<EOF
$(printf '%s' "$resp" | python3 -c 'import sys, json
SEP = "\x1f"
try: d = json.load(sys.stdin)
except Exception: d = {}
nodes = (((d.get("data") or {}).get("issues") or {}).get("nodes")) or []
if not nodes:
    print(SEP * 2)
else:
    n = nodes[0]
    a = n.get("assignee") or {}
    st = n.get("state") or {}
    print(SEP.join([n.get("id", ""), a.get("id", "") or "", st.get("type", "") or ""]))' 2>/dev/null)
EOF
    ids="$(printf '%s' "$resp" | RE="$_LINEAR_QUEUE_MARK_RE" python3 -c 'import sys, json, os, re
rx = re.compile(os.environ["RE"])
try: d = json.load(sys.stdin)
except Exception: d = {}
nodes = (((d.get("data") or {}).get("issues") or {}).get("nodes")) or []
if nodes:
    for c in (((nodes[0].get("comments") or {}).get("nodes")) or []):
        if rx.search(c.get("body") or ""):
            print(c.get("id", ""))' 2>/dev/null)"
    for id in $ids; do
        [ -n "$id" ] || continue
        if _linear_gql 'mutation D($id: String!) { commentDelete(id: $id) { success } }' \
             "$(ID="$id" python3 -c 'import os, json
print(json.dumps({"id": os.environ["ID"]}))')" 2>/dev/null \
           | python3 -c 'import sys, json
try: d = json.load(sys.stdin)
except Exception: d = {}
sys.exit(0 if (((d.get("data") or {}).get("commentDelete") or {}).get("success")) else 1)' 2>/dev/null; then
            deleted=$((deleted+1))
        fi
    done
    if [ "$deleted" -gt 0 ]; then
        _BACKEND_RESULT="DONE"
        # HERD-244: clear the plan-time assignee only when the queue set it and a claim has not
        # already taken over (started state + assignee is the claim signal).
        _linear_plan_clear_assignee "$issue_id" "$cur_assignee" "$stype"
    else
        _BACKEND_RESULT="NOCHANGE"
    fi
    _backend_tw_journal "$ref" unqueued "$_BACKEND_RESULT"
}

# _backend_list_queued — print every live planned marker across the open issue set, one TAB-separated
# line each: "#<identifier>\t<who>\t<detail>\t<epoch>". The reader (the coordinator / `herd backlog
# queued`) applies the 24h-advisory convention off <epoch>. Team-scoped exactly like _backend_list_open
# so a second private team's markers never leak in.
_backend_list_queued() {
    _linear_require_key
    local query vars
    if [ -n "${LINEAR_TEAM_ID:-}" ]; then
        query='query L($team: ID!) {
  issues(filter: { state: { type: { nin: ["completed", "canceled"] } }, team: { id: { eq: $team } } }, first: 250) {
    nodes { identifier comments { nodes { body } } }
  }
}'
        vars="$(TEAM="$LINEAR_TEAM_ID" python3 -c 'import os, json
print(json.dumps({"team": os.environ["TEAM"]}))')"
    else
        query='query {
  issues(filter: { state: { type: { nin: ["completed", "canceled"] } } }, first: 250) {
    nodes { identifier comments { nodes { body } } }
  }
}'
        vars=""
    fi
    _linear_gql "$query" "$vars" | RE="$_LINEAR_QUEUE_MARK_RE" python3 -c 'import sys, json, os, re
rx = re.compile(os.environ["RE"])
try: d = json.load(sys.stdin)
except Exception: d = {}
nodes = (((d.get("data") or {}).get("issues") or {}).get("nodes")) or []
for n in nodes:
    ident = n.get("identifier", "")
    for c in (((n.get("comments") or {}).get("nodes")) or []):
        m = rx.search(c.get("body") or "")
        if m:
            print("#%s\t%s\t%s\t%s" % (ident, m.group(1).strip(), m.group(2).strip(), m.group(3)))' 2>/dev/null || true
}

# ── Operator-inbox comment reader (HERD-184) — OPTIONAL, cross-backend contract addition ─────────────
# _backend_list_inbox_comments — print every comment left by ANOTHER operator on an issue THIS seat
# claimed (assigned to the API key's own viewer), one TAB-separated line each:
#   #<identifier>\t<author>\t<comment-id>\t<snippet>
# The TRACKER half of the operator inbox: an autonomous coordinator polls this each inbox tick and
# surfaces new comments (deduped by <comment-id>) as inbox entries — the cross-seat "reply on my item"
# channel the engine never read before. This is BACKEND-OPTIONAL: only linear implements it; file/
# github/jira have no such op, so the watcher's `command -v _backend_list_inbox_comments` probe finds
# nothing and the tracker feed is simply EMPTY (fail-soft, never an error).
#
# Scope + filtering, all done so the reader never has to know Linear's shape:
#   • issues assigned to the viewer (assignee.isMe) that are not completed/canceled — "items I claimed",
#     the same not-done set _backend_list_open uses; LINEAR_TEAM_ID narrows it exactly like list_open.
#   • comments whose author is NOT the viewer (my own replies are not inbound mail).
#   • the 📌 planned-work markers (_LINEAR_QUEUE_MARK_RE) are skipped — they are plan-time bookkeeping,
#     not a human message, and already have their own surface (herd backlog queued).
# The snippet is whitespace-flattened (tabs/newlines → spaces so the TSV shape can never be corrupted)
# and capped at 200 chars. Author names are flattened the same way. Fail-soft: any transport/parse
# error prints nothing and returns 0.
_backend_list_inbox_comments() {
    _linear_require_key
    local viewer_id query vars
    viewer_id="$(_linear_gql 'query { viewer { id } }' | python3 -c 'import sys, json
try: d = json.load(sys.stdin)
except Exception: d = {}
print(((d.get("data") or {}).get("viewer") or {}).get("id") or "")' 2>/dev/null)"
    if [ -n "${LINEAR_TEAM_ID:-}" ]; then
        query='query L($team: ID!) {
  issues(filter: { assignee: { isMe: { eq: true } }, state: { type: { nin: ["completed", "canceled"] } }, team: { id: { eq: $team } } }, first: 100) {
    nodes { identifier comments(first: 50) { nodes { id body user { id name } } } }
  }
}'
        vars="$(TEAM="$LINEAR_TEAM_ID" python3 -c 'import os, json
print(json.dumps({"team": os.environ["TEAM"]}))')"
    else
        query='query {
  issues(filter: { assignee: { isMe: { eq: true } }, state: { type: { nin: ["completed", "canceled"] } } }, first: 100) {
    nodes { identifier comments(first: 50) { nodes { id body user { id name } } } }
  }
}'
        vars=""
    fi
    _linear_gql "$query" "$vars" | VIEWER="$viewer_id" RE="$_LINEAR_QUEUE_MARK_RE" python3 -c 'import sys, json, os, re
rx = re.compile(os.environ.get("RE") or r"(?!)")
viewer = os.environ.get("VIEWER") or ""
def flat(s):
    return " ".join((s or "").split())
try: d = json.load(sys.stdin)
except Exception: d = {}
nodes = (((d.get("data") or {}).get("issues") or {}).get("nodes")) or []
for n in nodes:
    ident = n.get("identifier", "")
    for c in (((n.get("comments") or {}).get("nodes")) or []):
        body = c.get("body") or ""
        if rx.search(body):
            continue
        u = c.get("user") or {}
        if viewer and (u.get("id") or "") == viewer:
            continue
        cid = c.get("id") or ""
        if not cid:
            continue
        snip = flat(body)
        if len(snip) > 200:
            snip = snip[:199].rstrip() + "…"
        print("#%s\t%s\t%s\t%s" % (ident, flat(u.get("name") or "operator"), cid, snip))' 2>/dev/null || true
}
