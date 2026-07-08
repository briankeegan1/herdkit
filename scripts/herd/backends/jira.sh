#!/usr/bin/env bash
# backends/jira.sh — SCRIBE_BACKEND=jira implementation (Jira Cloud REST v3 work tracker).
#
# Opt-in API backend: work items live as Jira issues instead of a tracked file in the repo. New
# items become open issues, "shipped" transitions the matching issue into a Done-category status
# with a comment linking the PR, and "open" is the live set of issues whose statusCategory is not
# Done. Like the github/linear/changelog backends the agent does NOT edit any file — scribe-step.sh
# dispatches the request text here via the add-item path.
#
# Sourced from scribe-step.sh AFTER .herd/secrets and herd-config.sh have loaded, with $REPO as
# CWD. Implements the same contract the file/github/linear adapters do:
#   _backend_add_item REQ_ID TEXT     — POST /issue; sets _BACKEND_RESULT=DONE|NOCHANGE
#   _backend_mark_shipped SLUG PR_URL — comment PR link + transition into a Done-category status
#   _backend_list_open                — open issues, one "#<key> <summary>" line each
# plus _backend_update_state / _backend_amend / _backend_item_state / _backend_claim_item and the
# rich/show ops the linear adapter exposes (_backend_list_open_rich / _backend_show_item) and the
# OPTIONAL planned-work markers (HERD-52): _backend_queue_item / _backend_unqueue_item /
# _backend_list_queued for cross-operator plan-time visibility (a 📌 comment naming who sequenced
# the item after what, and when).
#
# Credentials (from .herd/secrets, gitignored — NEVER .herd/config): JIRA_BASE_URL (e.g.
# https://acme.atlassian.net), JIRA_EMAIL, and JIRA_API_TOKEN — basic auth against the Cloud REST
# API. Loud error + exit 1 if any is absent. An optional JIRA_PROJECT_KEY (also from .herd/secrets)
# names the project new issues are filed under and, critically, scopes the open-issue list — so a
# second project's issues never leak into 'herd backlog'. When unset, the first project the token
# can see files new issues and the open list spans every project the token can see. JIRA_ISSUE_TYPE
# (default "Task") is the issue type new items are created as.
#
# Issue resolution is by the Jira issue KEY (e.g. PROJ-42) directly — Jira keys are globally unique
# within a site, so (unlike Linear's number-scoped-by-team) a bare GET /issue/<key> resolves the
# right issue regardless of JIRA_PROJECT_KEY. JIRA_PROJECT_KEY only scopes the ops that carry no
# identifier (list_open / add_item), never resolution — so a cross-project reference is never
# mislabeled by the configured project.
#
# State model: Jira groups every workflow status under a statusCategory — "new" (To Do),
# "indeterminate" (In Progress), or "done" (Done / Won't Do / Cancelled). Open = statusCategory not
# Done. A state change is a workflow TRANSITION: we read the issue's available transitions, pick one
# landing in the target category (preferring a canonically-named one so a workspace with several
# done/in-progress statuses lands in the right place), fire it, and report DONE only when the POST is
# not rejected — mirroring the linear adapter's verified-mutation discipline.
#
# Every HTTP round-trip is funneled through the single internal _jira_api so a test can stub the
# network by overriding _jira_api or by putting a fake `curl` on PATH.

_jira_require_key() {
    local missing=""
    [ -n "${JIRA_BASE_URL:-}" ]  || missing="JIRA_BASE_URL"
    [ -n "${JIRA_EMAIL:-}" ]     || missing="${missing:+$missing, }JIRA_EMAIL"
    [ -n "${JIRA_API_TOKEN:-}" ] || missing="${missing:+$missing, }JIRA_API_TOKEN"
    if [ -n "$missing" ]; then
        echo "jira backend: $missing not set — add to .herd/secrets (gitignored), NOT .herd/config (or switch SCRIBE_BACKEND)" >&2
        exit 1
    fi
}

_jira_require_curl() {
    command -v curl >/dev/null 2>&1 || {
        echo "jira backend: 'curl' not found — required to reach the Jira Cloud REST API" >&2
        exit 1
    }
}

# _backend_tw_journal — HERD-85 tracker-write attribution (mirror of the linear/github backends').
# Emit ONE journal event per tracker STATE WRITE so `herd log | grep tracker_write` answers "which
# component moved <ref> to <state> on <pr>" in one line. Attribution is the caller's HERD_COMPONENT
# (claim|scribe|reconcile), 'manual' by default. FAIL-SOFT: journal_append is best-effort and this is
# a silent no-op when journal.sh was never sourced — a journal problem must never block or alter the
# state write (ZERO gate behavior change).
# Args: <ref> <requested-state> <result> [pr]   (pr falls back to $HERD_TW_PR when the arg is omitted).
_backend_tw_journal() {
    command -v journal_append >/dev/null 2>&1 || return 0
    local ref="$1" requested="$2" result="$3" pr="${4:-${HERD_TW_PR:-}}"
    if [ -n "$pr" ]; then
        journal_append tracker_write ref "$ref" requested "$requested" \
            component "${HERD_COMPONENT:-manual}" backend jira result "$result" pr "$pr"
    else
        journal_append tracker_write ref "$ref" requested "$requested" \
            component "${HERD_COMPONENT:-manual}" backend jira result "$result"
    fi
}

_jira_api() {
    # The one HTTP entry point. $1 = METHOD (GET/POST/PUT/DELETE); $2 = PATH (leading '/', appended
    # to JIRA_BASE_URL); $3 = JSON request body (optional). Basic-auths with the email + API token
    # from secrets and prints the raw JSON response on stdout (empty for a 204 mutation). Tests stub
    # this whole function or the `curl` it calls.
    local method="$1" path="$2" body="${3:-}" url
    _jira_require_curl
    url="${JIRA_BASE_URL%/}$path"
    if [ -n "$body" ]; then
        curl -sS -X "$method" "$url" \
            -u "${JIRA_EMAIL}:${JIRA_API_TOKEN}" \
            -H "Content-Type: application/json" \
            -H "Accept: application/json" \
            --data "$body"
    else
        curl -sS -X "$method" "$url" \
            -u "${JIRA_EMAIL}:${JIRA_API_TOKEN}" \
            -H "Accept: application/json"
    fi
}

# Shared Python helper (a function def) prepended to every parser that reads a Jira description or
# comment body. Jira Cloud v3 returns rich text as Atlassian Document Format (ADF) — a nested
# {type,content,text} tree — so a plain-text reader must WALK it collecting text nodes. Tolerates a
# bare string (older/plain payloads) and None. Block nodes (paragraph/heading) get a trailing newline
# so multi-paragraph descriptions don't run together.
_JIRA_ADF_PY='
def _adf_text(node):
    if node is None:
        return ""
    if isinstance(node, str):
        return node
    if isinstance(node, list):
        return "".join(_adf_text(n) for n in node)
    if isinstance(node, dict):
        t = node.get("type")
        s = node.get("text", "") if t == "text" else ""
        s += _adf_text(node.get("content"))
        if t in ("paragraph", "heading"):
            s += "\n"
        return s
    return ""
'

# Shared Python helper prepended to every parser that must choose ONE workflow TRANSITION landing in
# a target statusCategory. Given the issue's available transitions (each {id,name,to:{name,
# statusCategory:{key}}}), the target category, and a preferred human status name (via $PREF/$CAT in
# env), _pick_transition returns the id of a transition whose destination category matches, PREFERRING
# one whose transition-name or destination-status-name equals the preferred name case-insensitively;
# failing that, the first category match in API order. Empty when the issue has no transition into the
# target category. This is the analogue of the linear adapter's name-first state picker (gh #169): a
# workspace with both a 'Done' and a 'Cancelled' status (both done-category), or several in-progress
# statuses, lands on the canonically-named one rather than whichever the API returned first.
_JIRA_PICK_TRANSITION_PY='
def _pick_transition(transitions, category, preferred):
    cands = []
    for t in (transitions or []):
        cat = (((t.get("to") or {}).get("statusCategory") or {}).get("key") or "")
        if cat == category:
            cands.append(t)
    if not cands:
        return ""
    if preferred:
        p = preferred.strip().lower()
        for t in cands:
            names = [(t.get("name") or "").strip().lower(),
                     ((t.get("to") or {}).get("name") or "").strip().lower()]
            if p in names:
                return t.get("id") or ""
    return cands[0].get("id") or ""
'

_jira_issue_key() {
    # Validate + normalize an issue reference to a Jira key (PROJ-123). $1 = ref (a leading '#' is
    # tolerated). Prints the clean key and returns 0 when it is a KEY-NUMBER identifier; returns 1
    # (printing nothing) otherwise. Resolution is by key directly — Jira keys are site-unique, so this
    # is never scoped by JIRA_PROJECT_KEY (a cross-project ref resolves against its own project).
    local slug="${1#\#}" num proj
    case "$slug" in *-*) ;; *) return 1 ;; esac
    num="${slug##*-}"
    proj="${slug%-*}"
    case "$num" in ''|*[!0-9]*) return 1 ;; esac
    [ -n "$proj" ] || return 1
    printf '%s' "$slug"
}

_jira_project_key() {
    # Resolve the project new issues are created under: the configured JIRA_PROJECT_KEY if present,
    # else the first project this token can see. Prints the key (empty if none).
    if [ -n "${JIRA_PROJECT_KEY:-}" ]; then printf '%s' "$JIRA_PROJECT_KEY"; return 0; fi
    _jira_api GET "/rest/api/3/project/search?maxResults=1" \
      | python3 -c 'import sys, json
try: d = json.load(sys.stdin)
except Exception: d = {}
vals = (d.get("values")) or []
print(vals[0].get("key", "") if vals else "")' 2>/dev/null
}

_jira_short_title() {
    # Derive a SHORT tracker title from the full request text (HERD-77). The title SUMMARIZES the
    # request; it NEVER replaces the description (the caller still stores the full text). A first line
    # that is already short (<=100 chars) is the title verbatim; a long first line is reduced to its
    # first sentence/clause (split on ' — ', ': ', or '. ') and hard-capped at 100 chars with an
    # ellipsis — never the old "first-line-as-essay" (user complaint 2026-07-07). $1 = full text.
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

_jira_state_category_for() {
    # Map a requested scribe state to a Jira statusCategory key. A few common synonyms are tolerated
    # so the drainer's phrasing need not be exact. Jira folds "cancelled/won't do" statuses into the
    # DONE category, so 'canceled' also maps to done (disambiguated by the preferred name below).
    # Prints the category (empty for an unmappable request — the caller then SKIPs, never files).
    case "$1" in
        done|complete|completed|shipped|merged|closed|resolved)                printf 'done' ;;
        in-progress|inprogress|in_progress|started|doing|wip|active)           printf 'indeterminate' ;;
        cancel|canceled|cancelled|wontfix|"won't fix"|declined|dropped|obsolete) printf 'done' ;;
        *)                                                                      printf '' ;;
    esac
}

_jira_preferred_status_name() {
    # Given a requested state, print the human status NAME to PREFER when a project has MORE THAN ONE
    # status of the mapped category (e.g. both 'In Progress' and 'In Review' in the indeterminate
    # category, or both 'Done' and 'Cancelled' in the done category). The name wins over API order so
    # work lands in the canonical status; empty means "no preference — take the first category match".
    case "$1" in
        done|complete|completed|shipped|merged|closed|resolved)                printf 'Done' ;;
        in-progress|inprogress|in_progress|started|doing|wip|active)           printf 'In Progress' ;;
        cancel|canceled|cancelled|wontfix|"won't fix"|declined|dropped|obsolete) printf 'Cancelled' ;;
        *)                                                                      printf '' ;;
    esac
}

_jira_pick_transition_id() {
    # $1 = issue key; $2 = target statusCategory; $3 = preferred status name. Reads the issue's
    # available transitions and prints the id of the one landing in the target category (name-first,
    # then first-in-order). Empty when the issue has no transition into that category.
    local key="$1" cat="$2" pref="$3" resp
    resp="$(_jira_api GET "/rest/api/3/issue/$key/transitions")"
    printf '%s' "$resp" | CAT="$cat" PREF="$pref" python3 -c "$_JIRA_PICK_TRANSITION_PY"'
import sys, json, os
try: d = json.load(sys.stdin)
except Exception: d = {}
print(_pick_transition(d.get("transitions") or [], os.environ.get("CAT", ""), os.environ.get("PREF", "")))' 2>/dev/null
}

_jira_do_transition_verified() {
    # Fire a workflow transition and VERIFY the API accepted it before a caller may report DONE. $1 =
    # issue key; $2 = transition id. Jira returns 204 (empty body) on success and a JSON error
    # envelope ({errorMessages}/{errors}) on failure, so success = the response carries NO error.
    # Returns 0 only on an accepted transition; callers translate non-zero into _BACKEND_RESULT=
    # NOCHANGE so agent-watch's fuzzy-scribe retry path re-attempts — the linear adapter's HERD-70
    # verified-mutation discipline (a transiently-failed write must never be reported as a verified
    # transition; PR #187/HERD-67 stayed In Progress after merge).
    local key="$1" tid="$2" body resp
    body="$(TID="$tid" python3 -c 'import os, json
print(json.dumps({"transition": {"id": os.environ["TID"]}}))')"
    resp="$(_jira_api POST "/rest/api/3/issue/$key/transitions" "$body" 2>/dev/null)" || return 1
    printf '%s' "$resp" | python3 -c 'import sys, json
raw = sys.stdin.read().strip()
if not raw:
    sys.exit(0)                       # 204 empty body = accepted
try: d = json.loads(raw)
except Exception: sys.exit(0)         # non-JSON, non-empty → treat as accepted
errs = list(d.get("errorMessages") or [])
e = d.get("errors")
if isinstance(e, dict):
    errs += [v for v in e.values() if v]
sys.exit(1 if errs else 0)' 2>/dev/null
}

_jira_resolve_by_title() {
    # Fallback resolution when the request names no key: match issues by a summary substring via JQL
    # `summary ~ "<text>"`, capped at 2 so the caller can require a UNIQUE match and never mislabel the
    # wrong issue when a phrase is ambiguous. Prints the single matching key (empty for 0 or >1).
    local text="$1" body
    body="$(T="$text" python3 -c 'import os, json
jql = "summary ~ " + json.dumps(os.environ["T"])
print(json.dumps({"jql": jql, "maxResults": 2, "fields": ["summary"]}))')"
    _jira_api POST /rest/api/3/search/jql "$body" | python3 -c 'import sys, json
try: d = json.load(sys.stdin)
except Exception: d = {}
issues = d.get("issues") or []
print(issues[0].get("key", "") if len(issues) == 1 else "")' 2>/dev/null
}

_backend_add_item() {
    # $1 = claimed queue file path (REQ_ID, unused here); $2 = item text / summary.
    # Summary = a SHORT title derived from the request (HERD-77 — never the whole first line as an
    # essay); description = the FULL text as an ADF paragraph. Sets _BACKEND_RESULT=DONE on a created
    # issue (and surfaces its browse URL), NOCHANGE if Jira declines or no project is available.
    local text="$2" title project issuetype body resp parsed ok key url
    _jira_require_key
    title="$(_jira_short_title "$text")"
    project="$(_jira_project_key)"
    if [ -z "$project" ]; then
        echo "jira backend: no project available to create the issue in (set JIRA_PROJECT_KEY in .herd/secrets)" >&2
        _BACKEND_RESULT="NOCHANGE"
        return 0
    fi
    issuetype="${JIRA_ISSUE_TYPE:-Task}"
    body="$(TITLE="$title" DESC="$text" PROJ="$project" ITYPE="$issuetype" python3 -c 'import os, json
adf = {"type": "doc", "version": 1,
       "content": [{"type": "paragraph", "content": [{"type": "text", "text": os.environ["DESC"]}]}]}
print(json.dumps({"fields": {"project": {"key": os.environ["PROJ"]},
                             "summary": os.environ["TITLE"],
                             "description": adf,
                             "issuetype": {"name": os.environ["ITYPE"]}}}))')"
    resp="$(_jira_api POST /rest/api/3/issue "$body")"
    parsed="$(printf '%s' "$resp" | python3 -c 'import sys, json
try: d = json.load(sys.stdin)
except Exception: d = {}
print("%s\t%s" % ("1" if d.get("key") else "0", d.get("key", "")))' 2>/dev/null)"
    ok="${parsed%%	*}"; key="${parsed#*	}"
    if [ "$ok" = "1" ]; then
        _BACKEND_RESULT="DONE"
        url="${JIRA_BASE_URL%/}/browse/$key"
        printf '%s\n' "$url"
    else
        _BACKEND_RESULT="NOCHANGE"
    fi
}

_backend_mark_shipped() {
    # $1 = item slug (Jira issue key, e.g. PROJ-42); $2 = PR URL.
    # Comment the PR link, then transition the issue into a Done-category status (preferring 'Done').
    # Mirrors how the github backend comments-then-closes. Sets _BACKEND_RESULT=DONE|NOCHANGE — DONE
    # only on an accepted transition (or when there is no Done transition to make, matching linear's
    # "no completed state resolved → nothing to verify").
    local slug="$1" pr="$2" key tid body
    _jira_require_key
    if ! key="$(_jira_issue_key "$slug")"; then
        echo "jira backend: '$slug' is not a PROJ-NUMBER key — nothing to ship" >&2
        _BACKEND_RESULT="NOCHANGE"
        return 0
    fi
    # Comment the PR link (best-effort; a failed comment must not block the ship transition).
    body="$(BODY="Shipped via ${pr}" python3 -c 'import os, json
adf = {"type": "doc", "version": 1,
       "content": [{"type": "paragraph", "content": [{"type": "text", "text": os.environ["BODY"]}]}]}
print(json.dumps({"body": adf}))')"
    _jira_api POST "/rest/api/3/issue/$key/comment" "$body" >/dev/null 2>&1 || true
    # Transition to Done — DONE only on a CONFIRMED, accepted transition (HERD-70).
    tid="$(_jira_pick_transition_id "$key" done "$(_jira_preferred_status_name done)")"
    if [ -n "$tid" ]; then
        if _jira_do_transition_verified "$key" "$tid"; then
            _BACKEND_RESULT="DONE"
        else
            echo "jira backend: transitioning '$slug' to Done was not accepted — leaving it for retry (skipping, not filing)" >&2
            _BACKEND_RESULT="NOCHANGE"
        fi
    else
        # No Done transition available from the current status — the PR-link comment already posted,
        # so behavior is unchanged (mirrors the linear no-completed-state path).
        _BACKEND_RESULT="DONE"
    fi
    _backend_tw_journal "$slug" shipped "$_BACKEND_RESULT" "$pr"
}

_backend_update_state() {
    # $1 = item ref (Jira key e.g. PROJ-22, a leading '#' tolerated — or a summary phrase when no key
    # is present); $2 = target state (done|in-progress|canceled + synonyms).
    # Resolve the issue, pick a transition into the mapped statusCategory (name-first), then fire it —
    # reporting DONE only on an accepted transition (HERD-70). This is the intent-dispatch path (gh
    # #139): a "mark PROJ-22 done" request transitions the EXISTING issue instead of filing a new one.
    # NOCHANGE (no unique match / no such transition / rejected) files nothing.
    local ref="$1" want="$2" cat pref key tid
    _jira_require_key
    cat="$(_jira_state_category_for "$want")"
    if [ -z "$cat" ]; then
        echo "jira backend: unknown target state '$want' — expected done|in-progress|canceled (skipping, not filing)" >&2
        _BACKEND_RESULT="NOCHANGE"
        return 0
    fi
    pref="$(_jira_preferred_status_name "$want")"
    if ! key="$(_jira_issue_key "$ref")"; then
        key="$(_jira_resolve_by_title "$ref")"                   # conservative summary match (unique-only)
    fi
    if [ -z "$key" ]; then
        echo "jira backend: no unique issue matching '$ref' — state unchanged (skipping, not filing)" >&2
        _BACKEND_RESULT="NOCHANGE"
        return 0
    fi
    tid="$(_jira_pick_transition_id "$key" "$cat" "$pref")"
    if [ -z "$tid" ]; then
        echo "jira backend: issue '$ref' has no transition into a '$want' status — cannot mark it (skipping, not filing)" >&2
        _BACKEND_RESULT="NOCHANGE"
        return 0
    fi
    if _jira_do_transition_verified "$key" "$tid"; then
        _BACKEND_RESULT="DONE"
    else
        echo "jira backend: transition for '$ref' → '$want' was not accepted — state left unresolved for retry (skipping, not filing)" >&2
        _BACKEND_RESULT="NOCHANGE"
    fi
    _backend_tw_journal "$ref" "$want" "$_BACKEND_RESULT"
}

_backend_amend() {
    # $1 = item ref (Jira key e.g. PROJ-22, a leading '#' tolerated — or a summary phrase when no key
    # is present); $2 = the note to post.
    # HERD-128 AMEND: attach a clarification comment to an EXISTING issue WITHOUT touching its status
    # or summary. Conservative: resolve to EXACTLY ONE issue (key, or a UNIQUE summary match) — zero/
    # ambiguous → NOCHANGE + a LOUD reason, nothing posted. Sets _BACKEND_RESULT=DONE|NOCHANGE.
    local ref="$1" note="$2" key body ok
    _BACKEND_RESULT="NOCHANGE"
    _jira_require_key
    if ! key="$(_jira_issue_key "$ref")"; then
        key="$(_jira_resolve_by_title "$ref")"
    fi
    if [ -z "$key" ]; then
        echo "jira backend: no unique issue matching '$ref' — nothing to amend (skipping, not posting)" >&2
        _backend_tw_journal "$ref" amend "$_BACKEND_RESULT"
        return 0
    fi
    body="$(BODY="$note" python3 -c 'import os, json
adf = {"type": "doc", "version": 1,
       "content": [{"type": "paragraph", "content": [{"type": "text", "text": os.environ["BODY"]}]}]}
print(json.dumps({"body": adf}))')"
    ok="$(_jira_api POST "/rest/api/3/issue/$key/comment" "$body" 2>/dev/null | python3 -c 'import sys, json
try: d = json.load(sys.stdin)
except Exception: d = {}
print("1" if d.get("id") else "0")' 2>/dev/null)"
    [ "$ok" = "1" ] && _BACKEND_RESULT="DONE"
    _backend_tw_journal "$ref" amend "$_BACKEND_RESULT"
}

# _jira_open_jql — the shared JQL for the open work set (statusCategory not Done), scoped to
# JIRA_PROJECT_KEY when set so a second project's issues never leak into 'herd backlog'. $1 = an
# optional trailing ORDER BY clause. Prints the JQL string.
_jira_open_jql() {
    local order="${1:-}" jql
    if [ -n "${JIRA_PROJECT_KEY:-}" ]; then
        jql="project = \"$JIRA_PROJECT_KEY\" AND statusCategory != Done"
    else
        jql="statusCategory != Done"
    fi
    [ -n "$order" ] && jql="$jql $order"
    printf '%s' "$jql"
}

_backend_list_open() {
    # Print open issues (statusCategory not Done) as one "#<key> <summary>" line each — the same shape
    # the file/github/linear backends emit. Scoped to JIRA_PROJECT_KEY when set (privacy).
    _jira_require_key
    local jql body
    jql="$(_jira_open_jql 'ORDER BY created ASC')"
    body="$(JQL="$jql" python3 -c 'import os, json
print(json.dumps({"jql": os.environ["JQL"], "maxResults": 250, "fields": ["summary"]}))')"
    _jira_api POST /rest/api/3/search/jql "$body" | python3 -c 'import sys, json
try: d = json.load(sys.stdin)
except Exception: d = {}
for n in (d.get("issues") or []):
    f = n.get("fields") or {}
    print("#%s %s" % (n.get("key", ""), f.get("summary", "")))' 2>/dev/null || true
}

_backend_list_open_rich() {
    # OPTIONAL rich variant of _backend_list_open (the plain op above stays the cross-backend contract
    # and is byte-identical). Emits one TAB-separated line per open issue:
    #   #<key> \t <status-category> \t <status-name> \t <summary> \t <desc-snippet> \t <assignee> \t <url>
    # status-category is Jira's statusCategory key (new|indeterminate) — the machine key a viewer
    # groups on; status-name is the human label ("In Progress", "To Do", …). The description snippet is
    # ADF-flattened, whitespace-collapsed (so the TSV shape can never be corrupted by field content)
    # and capped at 280 chars. The trailing <url> is the issue's browse URL (whitespace-flattened) —
    # backlog-view.sh wraps the id chip in an OSC 8 hyperlink to it (HERD-49); older consumers that read
    # only the first six fields ignore it. Lines are sorted in-progress (indeterminate) first, then
    # new — stable within each group (API order preserved). Callers that don't know this op exists keep
    # using _backend_list_open unchanged.
    _jira_require_key
    local jql body base
    jql="$(_jira_open_jql)"
    body="$(JQL="$jql" python3 -c 'import os, json
print(json.dumps({"jql": os.environ["JQL"], "maxResults": 250,
                  "fields": ["summary", "status", "assignee", "description"]}))')"
    base="${JIRA_BASE_URL%/}"
    _jira_api POST /rest/api/3/search/jql "$body" | BASE="$base" python3 -c "$_JIRA_ADF_PY"'
import sys, json, os
try: d = json.load(sys.stdin)
except Exception: d = {}
base = os.environ.get("BASE", "")
rank = {"indeterminate": 0, "new": 1}
def flat(s):
    return " ".join((s or "").split())
rows = []
for i, n in enumerate(d.get("issues") or []):
    f = n.get("fields") or {}
    st = f.get("status") or {}
    cat = ((st.get("statusCategory") or {}).get("key") or "")
    rows.append((rank.get(cat, 2), i, n, f, st, cat))
rows.sort(key=lambda r: (r[0], r[1]))
for _, _, n, f, st, cat in rows:
    key = n.get("key", "")
    desc = flat(_adf_text(f.get("description")))
    if len(desc) > 280:
        desc = desc[:279].rstrip() + "…"
    assignee = flat((f.get("assignee") or {}).get("displayName") or "")
    url = flat(("%s/browse/%s" % (base, key)) if key else "")
    print("#%s\t%s\t%s\t%s\t%s\t%s\t%s" % (key, cat, flat(st.get("name")),
                                           flat(f.get("summary")), desc, assignee, url))' 2>/dev/null || true
}

_backend_show_item() {
    # OPTIONAL single-item detail op: $1 = issue key (PROJ-8; a leading '#' is tolerated). Prints a
    # plain-text detail block — key + live status on the first line, then summary, the full
    # (untruncated) description, and the browse URL + updated date — for `herd backlog show <id>` and
    # the fzf preview pane of `herd backlog browse`. Non-zero + stderr when the ref doesn't parse or the
    # issue can't be found (callers print their own soft fallback).
    local ref="$1" key resp base
    _jira_require_key
    if ! key="$(_jira_issue_key "$ref")"; then
        echo "jira backend: '$ref' is not a PROJ-NUMBER key" >&2
        return 1
    fi
    resp="$(_jira_api GET "/rest/api/3/issue/$key?fields=summary,status,assignee,description,updated")"
    base="${JIRA_BASE_URL%/}"
    printf '%s' "$resp" | BASE="$base" python3 -c "$_JIRA_ADF_PY"'
import sys, json, os
try: d = json.load(sys.stdin)
except Exception: d = {}
key = d.get("key", "")
if not key:
    sys.exit(1)
f = d.get("fields") or {}
st = f.get("status") or {}
cat = (st.get("statusCategory") or {}).get("key") or "?"
aname = ((f.get("assignee") or {}).get("displayName") or "").strip()
header = "#%s · %s (%s)" % (key, st.get("name") or "?", cat)
if aname:
    header += " · " + aname
print(header)
print()
print(f.get("summary") or "(untitled)")
desc = _adf_text(f.get("description")).strip()
if desc:
    print()
    print(desc)
print()
meta = ("%s/browse/%s" % (os.environ.get("BASE", ""), key)) if key else ""
upd = (f.get("updated") or "")[:10]
if upd:
    meta = ("%s · updated %s" % (meta, upd)) if meta else ("updated %s" % upd)
if meta:
    print(meta)' 2>/dev/null || {
        echo "jira backend: no issue matching '$ref'" >&2
        return 1
    }
}

_backend_item_state() {
    # $1 = <link-name>#<id> — caller has resolved the link; the JIRA_* creds are in env.
    # Resolves the issue via GET /issue and reads its statusCategory, setting ITEM_STATE=
    # open|closed|in-progress. Also sets ITEM_UPDATED to the issue's last-updated day (YYYY-MM-DD,
    # best-effort — empty if absent), used by the HERD-117 claim guard as evidence when it refuses a
    # stale (Done) pick. Category map: done → closed; indeterminate → in-progress; new/other → open.
    local ref="$1" slug key resp parsed cat
    _jira_require_key
    slug="${ref#*#}"
    ITEM_UPDATED=""
    if ! key="$(_jira_issue_key "$slug")"; then
        ITEM_STATE="open"
        return 0
    fi
    resp="$(_jira_api GET "/rest/api/3/issue/$key?fields=status,updated")"
    parsed="$(printf '%s' "$resp" | python3 -c 'import sys, json
try: d = json.load(sys.stdin)
except Exception: d = {}
f = d.get("fields") or {}
st = f.get("status") or {}
cat = (st.get("statusCategory") or {}).get("key") or ""
print("%s\t%s" % (cat, (f.get("updated") or "")[:10]))' 2>/dev/null || printf '\t')"
    cat="${parsed%%	*}"
    ITEM_UPDATED="${parsed#*	}"
    case "$cat" in
        done)          ITEM_STATE="closed"      ;;
        indeterminate) ITEM_STATE="in-progress" ;;
        *)             ITEM_STATE="open"         ;;
    esac
}

# _backend_claim_item REF WHO — atomic-ish pre-spawn claim (HERD-50). On Jira the claim marker is the
# issue ASSIGNEE (set to the token's OWN user) plus a transition into an in-progress (indeterminate)
# status. The claimant identity is the API token's own user (GET /myself), not WHO — WHO is
# informational only, since Jira identifies actors by accountId, not a login string. Read status +
# assignee SYNCHRONOUSLY; abort if the issue is done (shipped) or already assigned to a DIFFERENT
# user; else assign self + transition and RE-READ to verify. Jira has no compare-and-swap, so
# claim-verify narrows (not eliminates) the race to a couple of round-trips. Sets:
#   _CLAIM_RESULT = CLAIMED | SELF (already ours) | ALREADY (done / another assignee) |
#                   UNREACHABLE (unresolvable ref / no myself → caller fails soft)
#   _CLAIM_OWNER  = the blocking assignee's name (for the abort message)
_backend_claim_item() {
    local ref="$1" who="$2" me me_id me_name key resp parsed assignee_id assignee_name cat tid
    _CLAIM_RESULT=""; _CLAIM_OWNER=""
    _jira_require_key
    # myself = the API token's user — the Jira-side claimant identity.
    me="$(_jira_api GET /rest/api/3/myself | python3 -c 'import sys, json
try: d = json.load(sys.stdin)
except Exception: d = {}
print("%s\t%s" % (d.get("accountId", ""), d.get("displayName", "")))' 2>/dev/null)"
    me_id="${me%%	*}"; me_name="${me#*	}"
    if [ -z "$me_id" ]; then _CLAIM_RESULT="UNREACHABLE"; return 0; fi
    if ! key="$(_jira_issue_key "$ref")"; then _CLAIM_RESULT="UNREACHABLE"; return 0; fi

    resp="$(_jira_api GET "/rest/api/3/issue/$key?fields=assignee,status")"
    # "<assignee_id>\x1f<assignee_name>\x1f<status_category>" — split on the ASCII unit separator
    # (\x1f), NOT a tab: an unassigned issue has empty assignee fields, and `read` on IFS-whitespace
    # would COLLAPSE them and shift columns, misreading a claimable issue as already-taken. \x1f never
    # appears in a display name and is not whitespace, so empty fields are preserved.
    parsed="$(printf '%s' "$resp" | python3 -c 'import sys, json
SEP = "\x1f"
try: d = json.load(sys.stdin)
except Exception: d = {}
if not d.get("key"):
    print(SEP * 2)
else:
    f = d.get("fields") or {}
    a = f.get("assignee") or {}
    st = f.get("status") or {}
    cat = (st.get("statusCategory") or {}).get("key") or ""
    print(SEP.join([a.get("accountId", "") or "", (a.get("displayName") or "").replace(SEP, " "), cat]))' 2>/dev/null)"
    if [ -z "$parsed" ]; then _CLAIM_RESULT="UNREACHABLE"; return 0; fi
    IFS=$'\x1f' read -r assignee_id assignee_name cat <<EOF
$parsed
EOF
    # An issue that did not resolve (no status category at all) is unreachable.
    if [ -z "$cat" ]; then _CLAIM_RESULT="UNREACHABLE"; return 0; fi
    if [ "$cat" = "done" ]; then
        _CLAIM_RESULT="ALREADY"; _CLAIM_OWNER="${assignee_name:-a completed issue}"; return 0
    fi
    if [ -n "$assignee_id" ] && [ "$assignee_id" != "$me_id" ]; then
        _CLAIM_RESULT="ALREADY"; _CLAIM_OWNER="${assignee_name:-another operator}"; return 0
    fi
    if [ "$assignee_id" = "$me_id" ] && [ "$cat" = "indeterminate" ]; then
        _CLAIM_RESULT="SELF"; _CLAIM_OWNER="${assignee_name:-$who}"; return 0
    fi
    # Unassigned/ours-but-not-started → claim: assign self, then transition to an in-progress status
    # (when the project offers one; assignment alone still claims it if not).
    _jira_api PUT "/rest/api/3/issue/$key/assignee" \
      "$(A="$me_id" python3 -c 'import os, json
print(json.dumps({"accountId": os.environ["A"]}))')" >/dev/null 2>&1 || true
    tid="$(_jira_pick_transition_id "$key" indeterminate "$(_jira_preferred_status_name in-progress)")"
    [ -n "$tid" ] && _jira_do_transition_verified "$key" "$tid" >/dev/null 2>&1 || true
    # CLAIM-VERIFY: re-read the assignee and confirm the claim landed on us (not a racer).
    resp="$(_jira_api GET "/rest/api/3/issue/$key?fields=assignee")"
    assignee_id="$(printf '%s' "$resp" | python3 -c 'import sys, json
try: d = json.load(sys.stdin)
except Exception: d = {}
print(((d.get("fields") or {}).get("assignee") or {}).get("accountId", "") or "")' 2>/dev/null)"
    if [ -n "$assignee_id" ] && [ "$assignee_id" != "$me_id" ]; then
        _CLAIM_RESULT="ALREADY"; _CLAIM_OWNER="another operator"
    else
        _CLAIM_RESULT="CLAIMED"; _CLAIM_OWNER="$me_name"
        # HERD-85: a claim moves the issue into an in-progress status — journal that write. Fail-soft.
        _backend_tw_journal "$ref" in-progress CLAIMED
    fi
}

# ── Planned-work markers (HERD-52) — cross-operator plan-time visibility ─────────────────────────
# A coordinator that has SEQUENCED an item to spawn NEXT (but not yet spawned it) publishes a
# lightweight PLANNED marker so a second operator sees it and doesn't grab the same item. This
# complements the pre-spawn CLAIM (_backend_claim_item, HERD-50): the marker covers PLAN-time, the
# window between "I've decided to build this next" and the claim. On Jira the marker is a COMMENT of
# the shared shape "📌 queued by <who>: sequenced after <blocker> [<epoch>]". All three ops are
# BACKEND-OPTIONAL and FAIL-SOFT: an unresolvable ref, a missing key, or a transport hiccup is
# NOCHANGE/empty, never a hard error — a plan marker is advisory, never a gate.
_JIRA_QUEUE_MARK_RE='📌 queued by (.*?): (.*?) \[(\d+)\]'

# _backend_queue_item REF WHO BLOCKER — publish a planned marker comment on the issue. BLOCKER is the
# item this one is sequenced after (may be empty → "sequenced next"). Sets _BACKEND_RESULT=DONE|NOCHANGE.
_backend_queue_item() {
    local ref="$1" who="$2" blocker="$3" key ts detail body ok
    _jira_require_key
    [ -n "$who" ] || who="unknown-operator"
    ts="$(date +%s 2>/dev/null || echo 0)"
    if [ -n "$blocker" ]; then detail="sequenced after $blocker"; else detail="sequenced next"; fi
    if ! key="$(_jira_issue_key "$ref")"; then
        echo "jira backend: '$ref' is not a resolvable key — cannot publish a queued marker" >&2
        _BACKEND_RESULT="NOCHANGE"; return 0
    fi
    body="$(MARK="$(printf '📌 queued by %s: %s [%s]' "$who" "$detail" "$ts")" python3 -c 'import os, json
adf = {"type": "doc", "version": 1,
       "content": [{"type": "paragraph", "content": [{"type": "text", "text": os.environ["MARK"]}]}]}
print(json.dumps({"body": adf}))')"
    ok="$(_jira_api POST "/rest/api/3/issue/$key/comment" "$body" 2>/dev/null | python3 -c 'import sys, json
try: d = json.load(sys.stdin)
except Exception: d = {}
print("1" if d.get("id") else "0")' 2>/dev/null)"
    if [ "$ok" = "1" ]; then _BACKEND_RESULT="DONE"; else _BACKEND_RESULT="NOCHANGE"; fi
    _backend_tw_journal "$ref" queued "$_BACKEND_RESULT"
}

# _backend_unqueue_item REF WHO — clear the planned marker(s) on the issue (plan dropped, or the item
# was spawned and the claim now supersedes it). WHO is informational. Deletes every 📌-marker comment
# on the issue via DELETE /comment/<id>. Sets _BACKEND_RESULT=DONE (≥1 deleted) | NOCHANGE (none).
_backend_unqueue_item() {
    local ref="$1" who="$2" key resp ids id deleted=0
    _jira_require_key
    if ! key="$(_jira_issue_key "$ref")"; then
        _BACKEND_RESULT="NOCHANGE"; return 0
    fi
    resp="$(_jira_api GET "/rest/api/3/issue/$key/comment")"
    ids="$(printf '%s' "$resp" | RE="$_JIRA_QUEUE_MARK_RE" python3 -c "$_JIRA_ADF_PY"'
import sys, json, os, re
rx = re.compile(os.environ["RE"])
try: d = json.load(sys.stdin)
except Exception: d = {}
for c in (d.get("comments") or []):
    if rx.search(_adf_text(c.get("body"))):
        print(c.get("id", ""))' 2>/dev/null)"
    for id in $ids; do
        [ -n "$id" ] || continue
        if _jira_api DELETE "/rest/api/3/issue/$key/comment/$id" >/dev/null 2>&1; then
            deleted=$((deleted + 1))
        fi
    done
    if [ "$deleted" -gt 0 ]; then _BACKEND_RESULT="DONE"; else _BACKEND_RESULT="NOCHANGE"; fi
    _backend_tw_journal "$ref" unqueued "$_BACKEND_RESULT"
}

# _backend_list_queued — print every live planned marker across the open issue set, one TAB-separated
# line each: "#<key>\t<who>\t<detail>\t<epoch>". The reader (the coordinator / `herd backlog queued`)
# applies the 24h-advisory convention off <epoch>. Project-scoped exactly like _backend_list_open so a
# second project's markers never leak in. Requests the "comment" field in the search so each issue's
# comments come back inline.
_backend_list_queued() {
    _jira_require_key
    local jql body
    jql="$(_jira_open_jql)"
    body="$(JQL="$jql" python3 -c 'import os, json
print(json.dumps({"jql": os.environ["JQL"], "maxResults": 250, "fields": ["comment"]}))')"
    _jira_api POST /rest/api/3/search/jql "$body" | RE="$_JIRA_QUEUE_MARK_RE" python3 -c "$_JIRA_ADF_PY"'
import sys, json, os, re
rx = re.compile(os.environ["RE"])
try: d = json.load(sys.stdin)
except Exception: d = {}
for n in (d.get("issues") or []):
    key = n.get("key", "")
    comments = (((n.get("fields") or {}).get("comment") or {}).get("comments")) or []
    for c in comments:
        m = rx.search(_adf_text(c.get("body")))
        if m:
            print("#%s\t%s\t%s\t%s" % (key, m.group(1).strip(), m.group(2).strip(), m.group(3)))' 2>/dev/null || true
}
