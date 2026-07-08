#!/usr/bin/env bash
# test-backend-jira.sh — hermetic test of the Jira Cloud REST v3 work-tracker backend's contract with
# the network stubbed. No real network, no real creds, no repo writes. Two stubbing layers (mirroring
# test-backend-linear.sh):
#   • Behavior tests OVERRIDE _jira_api itself — it logs every (METHOD, PATH, BODY) round-trip to
#     $APILOG and returns canned JSON keyed on the METHOD+PATH. This lets the test assert CALL SHAPE
#     (which endpoints get hit, with which bodies) and the parsed output — not Jira behavior.
#   • One transport test keeps a FAKE `curl` on PATH so the REAL _jira_api still gets exercised
#     end-to-end (endpoint + basic-auth), with no real network.
# Run:  bash tests/test-backend-jira.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BACKEND="$HERE/../scripts/herd/backends/jira.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass(){ PASS=$((PASS+1)); }

APILOG="$T/api.log"
# HERD-85: a stub journal_append lets us assert the tracker_write attribution event WITHOUT sourcing
# the real journal.sh — mirroring how _jira_api is stubbed.
JLOG="$T/journal.log"

# Fake curl for the transport test only: logs its args and emits a trivial response.
CURLLOG="$T/curl.log"
mkdir -p "$T/bin"
cat > "$T/bin/curl" <<EOF
#!/usr/bin/env bash
echo "curl \$*" >> "$CURLLOG"
echo '{"accountId":"acc_self"}'
EOF
chmod +x "$T/bin/curl"
export PATH="$T/bin:$PATH"

# The backend reads its creds (and optional project) from .herd/secrets, i.e. the environment by the
# time it is sourced. Set them so add_item skips the project-lookup round-trip and targets this
# project, and so list_open is project-scoped by default.
export JIRA_BASE_URL="https://acme.atlassian.net"
export JIRA_EMAIL="bot@acme.io"
export JIRA_API_TOKEN="jira_test_token"
export JIRA_PROJECT_KEY="ENG"

# Default transitions the GET .../transitions stub returns. A test can override with TRANSITIONS to
# script a project with several statuses of one category. Kept in its own variable so the '}' in the
# JSON never prematurely closes a ${VAR:-...} expansion.
# Self-assignee JSON kept in its own variable, NOT inlined into ${VERIFY_ASSIGNEE:-...}, because the
# '}' in the JSON would prematurely close the parameter expansion.
SELF_ASSIGNEE='{"accountId":"acc_self"}'
DEFAULT_TRANSITIONS='[{"id":"11","name":"To Do","to":{"name":"To Do","statusCategory":{"key":"new"}}},{"id":"21","name":"Start Progress","to":{"name":"In Progress","statusCategory":{"key":"indeterminate"}}},{"id":"31","name":"Done","to":{"name":"Done","statusCategory":{"key":"done"}}},{"id":"41","name":"Cancel","to":{"name":"Cancelled","statusCategory":{"key":"done"}}}]'

# run: source the backend, override _jira_api to log (METHOD, PATH, BODY) and return canned JSON keyed
# on the METHOD+PATH, then invoke the requested op and echo its result contract. Ordering in the case
# matters — the more specific PATH shapes (…/transitions, …/comment, …/assignee, single-issue GET,
# /search/jql) are matched BEFORE the generic /issue fallthrough.
run() {
  ( cd "$T" && . "$BACKEND"
    journal_append() { printf '%s\n' "$*" >> "$JLOG"; }
    _jira_api() {
      printf 'M<<%s>>P<<%s>>B<<%s>>\n' "$1" "$2" "${3:-}" >> "$APILOG"
      local method="$1" path="$2"
      case "$method $path" in
        "POST /rest/api/3/issue")
          echo '{"id":"10042","key":"ENG-42","self":"https://acme.atlassian.net/rest/api/3/issue/10042"}' ;;
        "GET "*"/transitions")
          echo "{\"transitions\":${TRANSITIONS:-$DEFAULT_TRANSITIONS}}" ;;
        "POST "*"/transitions")
          # 204-empty on success; a JSON error envelope when TRANSITION_FAILS is set.
          if [ -n "${TRANSITION_FAILS:-}" ]; then echo '{"errorMessages":["Transition rejected"]}'; else printf ''; fi ;;
        "POST "*"/comment")
          echo '{"id":"cmt_new","body":{}}' ;;
        "GET "*"/comment")
          echo '{"comments":[{"id":"cmt_mark","body":{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"📌 queued by alice: sequenced after ENG-9 [1700000000]"}]}]}},{"id":"cmt_other","body":{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"an unrelated comment"}]}]}}]}' ;;
        "DELETE "*"/comment/"*)
          printf '' ;;
        "PUT "*"/assignee")
          printf '' ;;
        "GET /rest/api/3/myself")
          echo '{"accountId":"acc_self","displayName":"Herd Bot"}' ;;
        "GET /rest/api/3/project/search"*)
          echo '{"values":[{"key":"ENG"}]}' ;;
        "POST /rest/api/3/search/jql")
          # list_open / list_open_rich / list_queued / title-resolve all POST here. Disambiguate on
          # the requested fields carried in the BODY.
          case "${3:-}" in
            *'"comment"'*)
              echo '{"issues":[{"key":"ENG-7","fields":{"comment":{"comments":[{"body":{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"📌 queued by alice: sequenced after ENG-9 [1700000000]"}]}]}}]}}},{"key":"ENG-9","fields":{"comment":{"comments":[{"body":{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"just a regular note"}]}]}}]}}}]}' ;;
            *'"status"'*)
              echo '{"issues":[{"key":"ENG-7","fields":{"summary":"first open issue","status":{"name":"To Do","statusCategory":{"key":"new"}},"assignee":null,"description":{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"Details for seven."}]}]}}},{"key":"ENG-9","fields":{"summary":"second open issue","status":{"name":"In Progress","statusCategory":{"key":"indeterminate"}},"assignee":{"displayName":"Chase"},"description":null}}]}' ;;
            *'summary ~'*)
              echo '{"issues":[{"key":"ENG-7","fields":{"summary":"first open issue"}}]}' ;;
            *)
              echo '{"issues":[{"key":"ENG-7","fields":{"summary":"first open issue"}},{"key":"ENG-9","fields":{"summary":"second open issue"}}]}' ;;
          esac ;;
        "GET /rest/api/3/issue/"*)
          # single-issue GET (show/item_state/claim). Field set is in the query string.
          case "$path" in
            *"fields=summary,status,assignee,description,updated"*)
              echo '{"key":"ENG-7","fields":{"summary":"first open issue","status":{"name":"In Progress","statusCategory":{"key":"indeterminate"}},"assignee":{"displayName":"Chase"},"description":{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"Full spec body here."}]}]},"updated":"2026-07-06T01:02:03.000Z"}}' ;;
            *"fields=status,updated"*)
              echo "{\"key\":\"ENG-7\",\"fields\":{\"status\":{\"name\":\"Done\",\"statusCategory\":{\"key\":\"${ITEM_CAT:-done}\"}},\"updated\":\"${ITEM_UPD:-2026-07-06T01:02:03.000Z}\"}}" ;;
            *"fields=assignee,status"*)
              echo "{\"key\":\"ENG-7\",\"fields\":{\"assignee\":${CLAIM_ASSIGNEE:-null},\"status\":{\"name\":\"To Do\",\"statusCategory\":{\"key\":\"${CLAIM_CAT:-new}\"}}}}" ;;
            *"fields=assignee"*)
              echo "{\"key\":\"ENG-7\",\"fields\":{\"assignee\":${VERIFY_ASSIGNEE:-$SELF_ASSIGNEE}}}" ;;
            *)
              echo '{"key":"ENG-7","fields":{}}' ;;
          esac ;;
        *)
          echo '{}' ;;
      esac
    }
    _BACKEND_RESULT=""
    ITEM_STATE=""
    "$@"
    printf 'RESULT=%s\n' "${_BACKEND_RESULT:-}"
    printf 'ITEM_STATE=%s\n' "${ITEM_STATE:-}" )
}

# 1. add_item → POST /issue carrying summary/description(ADF)/project/issuetype; returns DONE + the
#    browse URL.
: > "$APILOG"
out="$(run _backend_add_item REQ1 "add a dark-mode toggle")"
echo "$out" | grep -q "RESULT=DONE" || fail "add_item did not report DONE ($out)"
echo "$out" | grep -q "https://acme.atlassian.net/browse/ENG-42" || fail "add_item did not surface the created issue browse URL ($out)"
grep -q 'M<<POST>>P<<\/rest\/api\/3\/issue>>' "$APILOG" || fail "add_item did not POST to /rest/api/3/issue"
grep -q "add a dark-mode toggle" "$APILOG" || fail "add_item did not pass the request text as the description"
grep -q '"key": "ENG"' "$APILOG" || fail "add_item did not target the configured project (project key)"
grep -q '"issuetype"' "$APILOG" || fail "add_item did not set an issuetype"
pass

# 1b. HERD-77 (short titles): a long single-line add must yield a SHORT summary (<=100 chars) but keep
#     the FULL text as the description.
: > "$APILOG"
BIG="$(python3 -c 'print("Add a really important feature " + "x"*470)')"   # 501 chars, no newline
out="$(run _backend_add_item REQ2 "$BIG")"
echo "$out" | grep -q "RESULT=DONE" || fail "add_item (long) did not report DONE ($out)"
python3 - "$APILOG" <<'PY' || fail "add_item (long) summary/description lengths wrong"
import sys, json, re
log = open(sys.argv[1]).read()
m = re.findall(r"B<<(.*?)>>\n", log, re.S)
create = [b for b in m if '"summary"' in b]
assert create, "no issue-create body logged"
v = json.loads(create[-1])["fields"]
summary = v["summary"]
# flatten the ADF description text
desc = "".join(c["content"][0]["text"] for c in v["description"]["content"])
assert len(summary) <= 100, "summary too long: %d chars" % len(summary)
assert len(desc) >= 500, "description not full-length: %d chars" % len(desc)
assert len(desc) > len(summary), "description must be the FULL text, not the truncated summary"
PY
pass

# 2. list_open (project scoped ON) → a /search/jql POST whose JQL scopes to the project and excludes
#    Done, parsed to "#<key> <summary>" lines.
: > "$APILOG"
open="$(run _backend_list_open)"
grep -q 'P<<\/rest\/api\/3\/search\/jql>>' "$APILOG" || fail "list_open did not POST to /search/jql"
grep -q 'project = ' "$APILOG" || fail "list_open (project set) did not scope the JQL to a project"
grep -q 'statusCategory != Done' "$APILOG" || fail "list_open did not exclude Done-category issues"
echo "$open" | grep -q "^#ENG-7 first open issue$"  || fail "list_open missing '#ENG-7 first open issue' ($open)"
echo "$open" | grep -q "^#ENG-9 second open issue$" || fail "list_open missing '#ENG-9 second open issue'"
pass

# 2b. list_open (project scoped OFF) → no project clause, so it spans every project the token can see.
: > "$APILOG"
open2="$( unset JIRA_PROJECT_KEY; run _backend_list_open )"
grep -q 'statusCategory != Done' "$APILOG" || fail "list_open (no project) did not issue the open JQL"
grep -q 'project = ' "$APILOG" && fail "list_open (no project) must NOT scope by project — it leaked a project clause"
echo "$open2" | grep -q "^#ENG-7 first open issue$" || fail "list_open (no project) missing '#ENG-7 first open issue' ($open2)"
pass

# 2c. list_open_rich → same open filter but requests status + assignee + description, emits TSV
#     ("#<key>\t<category>\t<status-name>\t<summary>\t<desc>\t<assignee>\t<url>"), sorts in-progress
#     first, and flattens the ADF description (a raw newline would corrupt the TSV). The trailing url
#     feeds backlog-view.sh's OSC 8 chip.
TAB="$(printf '\t')"
: > "$APILOG"
rich="$(run _backend_list_open_rich)"
grep -q '"status"' "$APILOG" || fail "list_open_rich did not request the status field"
grep -q '"assignee"' "$APILOG" || fail "list_open_rich did not request the assignee field"
grep -q '"description"' "$APILOG" || fail "list_open_rich did not request the description field"
echo "$rich" | grep '^#' | head -n1 | grep -q "^#ENG-9" \
  || fail "list_open_rich did not sort the in-progress issue first ($rich)"
echo "$rich" | grep -q "^#ENG-9${TAB}indeterminate${TAB}In Progress${TAB}second open issue${TAB}${TAB}Chase${TAB}https://acme.atlassian.net/browse/ENG-9$" \
  || fail "list_open_rich TSV shape wrong for ENG-9 (assignee Chase 6th, url 7th) ($rich)"
echo "$rich" | grep -q "^#ENG-7${TAB}new${TAB}To Do${TAB}first open issue${TAB}Details for seven.${TAB}${TAB}https://acme.atlassian.net/browse/ENG-7$" \
  || fail "list_open_rich did not flatten desc / place empty assignee then url; ENG-7 shape wrong ($rich)"
pass

# 2d. show_item → single-issue detail via GET /issue: key + live status on line 1, then summary, the
#     UNtruncated description, and url + updated date.
: > "$APILOG"
det="$(run _backend_show_item "#ENG-7")"
grep -q 'P<<\/rest\/api\/3\/issue\/ENG-7?' "$APILOG" || fail "show_item did not GET the issue by key"
echo "$det" | grep -q "^#ENG-7 · In Progress (indeterminate) · Chase$" || fail "show_item missing the key · status · assignee header ($det)"
echo "$det" | grep -q "Full spec body here." || fail "show_item did not print the full description body ($det)"
echo "$det" | grep -q "browse/ENG-7 · updated 2026-07-06" || fail "show_item missing url + updated date ($det)"
pass

# 2e. show_item on an unparseable ref → loud stderr, no round-trip.
: > "$APILOG"
err="$(run _backend_show_item "nodashhere" 2>&1 >/dev/null || true)"
echo "$err" | grep -q "not a PROJ-NUMBER" || fail "show_item on an unparseable ref should say so on stderr ($err)"
grep -q 'P<<\/rest\/api\/3\/issue\/' "$APILOG" && fail "show_item on an unparseable ref should not issue any request"
pass

# 3. mark_shipped → comments the PR link, then transitions the issue to a Done-category status.
: > "$APILOG"
ship="$(run _backend_mark_shipped ENG-7 https://github.com/acme/widgets/pull/3)"
echo "$ship" | grep -q "RESULT=DONE" || fail "mark_shipped did not report DONE ($ship)"
grep -q 'P<<\/rest\/api\/3\/issue\/ENG-7\/comment>>' "$APILOG" || fail "mark_shipped did not comment the PR link"
grep -q "Shipped via https://github.com/acme/widgets/pull/3" "$APILOG" || fail "mark_shipped did not link the PR in the comment body"
grep -q 'P<<\/rest\/api\/3\/issue\/ENG-7\/transitions>>' "$APILOG" || fail "mark_shipped did not move the issue via a transition"
grep -q '"id": "31"' "$APILOG" || fail "mark_shipped did not fire the Done transition (id 31)"
pass

# 3b. mark_shipped with an unparseable slug → NOCHANGE, no round-trip.
: > "$APILOG"
ship2="$(run _backend_mark_shipped nodashhere https://github.com/acme/widgets/pull/9 2>/dev/null)"
echo "$ship2" | grep -q "RESULT=NOCHANGE" || fail "mark_shipped on an unparseable slug should be NOCHANGE ($ship2)"
grep -q 'transitions' "$APILOG" && fail "mark_shipped on an unparseable slug should issue no transition"
pass

# 4. item_state → resolves via GET /issue reading statusCategory; maps done → closed + surfaces the
#    last-updated day as ITEM_UPDATED evidence (HERD-117 claim-guard precondition).
: > "$APILOG"
out="$(ITEM_CAT=done ITEM_UPD="2026-07-08T21:51:00.000Z" run _backend_item_state "provider-lib#ENG-7")"
echo "$out" | grep -q "ITEM_STATE=closed" || fail "_backend_item_state did not return ITEM_STATE=closed ($out)"
grep -q 'fields=status,updated' "$APILOG" || fail "_backend_item_state did not request status + updated"
: > "$APILOG"
outp="$(ITEM_CAT=indeterminate run _backend_item_state "provider-lib#ENG-7")"
echo "$outp" | grep -q "ITEM_STATE=in-progress" || fail "_backend_item_state did not map indeterminate → in-progress ($outp)"
pass

# 4a. item_state precondition — a Done issue reads closed AND surfaces its last-updated day so a
#     stale-pick refusal can name it.
outg="$(cd "$T" && . "$BACKEND"
  _jira_api(){ printf '{"key":"ENG-7","fields":{"status":{"statusCategory":{"key":"done"}},"updated":"2026-07-08T21:51:00.000Z"}}'; }
  ITEM_STATE=""; ITEM_UPDATED=""
  _backend_item_state "provider-lib#ENG-7"
  printf 'ITEM_STATE=%s\nITEM_UPDATED=%s\n' "$ITEM_STATE" "$ITEM_UPDATED")"
echo "$outg" | grep -q "ITEM_STATE=closed"       || fail "guard precondition: Done issue must read closed ($outg)"
echo "$outg" | grep -q "ITEM_UPDATED=2026-07-08"  || fail "guard precondition: last-updated day not surfaced ($outg)"
pass

# 4c. update_state (done) → resolves by key via GET /issue transitions, then POSTs a Done-category
#     transition. It must NOT POST /issue (a state change is not a new item — the gh #139 junk bug).
: > "$APILOG"
us="$(run _backend_update_state ENG-7 done)"
echo "$us" | grep -q "RESULT=DONE" || fail "update_state did not report DONE ($us)"
grep -q 'P<<\/rest\/api\/3\/issue\/ENG-7\/transitions>>' "$APILOG" || fail "update_state did not move the issue via a transition"
grep -q '"id": "31"' "$APILOG" || fail "update_state (done) did not fire the Done transition"
grep -q 'M<<POST>>P<<\/rest\/api\/3\/issue>>' "$APILOG" && fail "update_state must NOT file a new issue (the #139 junk bug)"
pass

# 4d. update_state maps in-progress → an indeterminate transition and canceled → a done-category
#     'Cancelled' transition (the statusCategory + preferred-name pick).
: > "$APILOG"; run _backend_update_state ENG-7 in-progress >/dev/null
grep -q '"id": "21"' "$APILOG" || fail "update_state (in-progress) did not fire the indeterminate transition (21)"
: > "$APILOG"; run _backend_update_state ENG-7 canceled >/dev/null
grep -q '"id": "41"' "$APILOG" || fail "update_state (canceled) did not fire the Cancelled transition (41)"
pass

# 4e. update_state with an UNKNOWN target state → NOCHANGE, no round-trip.
: > "$APILOG"
us2="$(run _backend_update_state ENG-7 frobnicate 2>/dev/null)"
echo "$us2" | grep -q "RESULT=NOCHANGE" || fail "update_state on an unknown state should be NOCHANGE ($us2)"
grep -q 'transitions' "$APILOG" && fail "update_state on an unknown state should issue no request"
pass

# 4f. update_state falls back to a CONSERVATIVE summary match (JQL summary ~) when the ref carries no
#     key — so a reconcile request that names an item by title still transitions it.
: > "$APILOG"
us3="$(run _backend_update_state "first open issue" done)"
grep -q 'summary ~' "$APILOG" || fail "update_state (no key) did not fall back to a summary match"
echo "$us3" | grep -q "RESULT=DONE"    || fail "update_state summary match did not transition the unique match ($us3)"
pass

# 4g. name-first pick: a project with BOTH a 'Done' and a 'Cancelled' transition in the done category
#     must resolve 'done' to the transition NAMED 'Done', never whichever done-category one is first.
: > "$APILOG"
us4="$( TRANSITIONS='[{"id":"41","name":"Cancel","to":{"name":"Cancelled","statusCategory":{"key":"done"}}},{"id":"31","name":"Done","to":{"name":"Done","statusCategory":{"key":"done"}}}]' \
        run _backend_update_state ENG-7 done )"
echo "$us4" | grep -q "RESULT=DONE" || fail "update_state (multi done) did not report DONE ($us4)"
grep -q '"id": "31"' "$APILOG" || fail "update_state (multi done) did not pick the 'Done' transition by NAME"
pass

# 4h. VERIFIED MUTATION (HERD-70): update_state reports DONE only when the transition POST is accepted.
#     A rejected transition (error envelope) must be NOCHANGE — not an optimistic DONE — so agent-watch
#     falls back to the fuzzy scribe retry instead of journaling a false verified transition.
: > "$APILOG"
usf="$( TRANSITION_FAILS=1 run _backend_update_state ENG-7 done 2>/dev/null )"
echo "$usf" | grep -q "RESULT=NOCHANGE" || fail "update_state must be NOCHANGE when the transition is rejected ($usf)"
grep -q 'transitions' "$APILOG" || fail "update_state (rejected) should still ATTEMPT the transition"
grep -q 'M<<POST>>P<<\/rest\/api\/3\/issue>>' "$APILOG" && fail "update_state (rejected) must NOT fall back to filing a new issue"
pass

# 4i. HERD-70: the same verification guards mark_shipped — a rejected Done transition is NOCHANGE, even
#     though the PR-link comment already posted.
: > "$APILOG"
shipf="$( TRANSITION_FAILS=1 run _backend_mark_shipped ENG-7 https://github.com/acme/widgets/pull/5 2>/dev/null )"
echo "$shipf" | grep -q "RESULT=NOCHANGE" || fail "mark_shipped must be NOCHANGE when the Done transition is rejected ($shipf)"
grep -q '/comment' "$APILOG" || fail "mark_shipped (rejected) should still post the PR-link comment"
pass

# 5. amend → posts a comment to an EXISTING issue via /comment, DONE; unresolvable ref → NOCHANGE.
: > "$APILOG"
am="$(run _backend_amend ENG-7 "a clarifying note")"
echo "$am" | grep -q "RESULT=DONE" || fail "amend did not report DONE ($am)"
grep -q 'P<<\/rest\/api\/3\/issue\/ENG-7\/comment>>' "$APILOG" || fail "amend did not post a comment"
grep -q "a clarifying note" "$APILOG" || fail "amend did not carry the note text"
pass

# 6. HERD-85 attribution — a state write journals ONE tracker_write carrying ref/requested/component/
#    result/backend, and the pr when present.
: > "$JLOG"
HERD_COMPONENT=reconcile HERD_TW_PR=42 run _backend_update_state ENG-7 done >/dev/null
[ "$(grep -c '^tracker_write ' "$JLOG")" = "1" ] || fail "update_state must journal EXACTLY ONE tracker_write ($(cat "$JLOG"))"
tw="$(grep '^tracker_write ' "$JLOG")"
echo "$tw" | grep -q "ref ENG-7"            || fail "tracker_write missing 'ref ENG-7' ($tw)"
echo "$tw" | grep -q "requested done"       || fail "tracker_write missing 'requested done' ($tw)"
echo "$tw" | grep -q "component reconcile"  || fail "tracker_write did not attribute the component ($tw)"
echo "$tw" | grep -q "result DONE"          || fail "tracker_write did not record the result ($tw)"
echo "$tw" | grep -q "backend jira"         || fail "tracker_write missing the backend field ($tw)"
echo "$tw" | grep -q "pr 42"                || fail "tracker_write did not carry the PR ($tw)"
pass

# 6b. FAIL-SOFT: with journal_append UNDEFINED, the write still succeeds and nothing is journaled.
: > "$JLOG"
out="$(
  cd "$T" && . "$BACKEND"
  _jira_api() {
    case "$1 $2" in
      ("GET "*"/transitions") echo "{\"transitions\":$DEFAULT_TRANSITIONS}" ;;
      (*) printf '' ;;
    esac
  }
  _BACKEND_RESULT=""
  _backend_update_state ENG-7 done
  printf 'RESULT=%s\n' "${_BACKEND_RESULT:-}"
)"
echo "$out" | grep -q "RESULT=DONE" || fail "update_state must still succeed with journal_append undefined ($out)"
[ ! -s "$JLOG" ] || fail "no tracker_write should be written when journal_append is undefined ($(cat "$JLOG"))"
pass

# 7. claim_item → reads myself + the issue's assignee/status, assigns self, transitions to in-progress,
#    re-reads to verify → CLAIMED. Unassigned + not-done issue in the default mock.
: > "$APILOG"
cl="$(run _backend_claim_item ENG-7 briankeegan)"
echo "$cl" >/dev/null   # RESULT unused; assert via _CLAIM_RESULT below through a dedicated harness
claim() {   # prints _CLAIM_RESULT / _CLAIM_OWNER for the given env-scripted issue state
  ( cd "$T" && . "$BACKEND"
    _jira_api() {
      printf 'M<<%s>>P<<%s>>B<<%s>>\n' "$1" "$2" "${3:-}" >> "$APILOG"
      case "$1 $2" in
        "GET /rest/api/3/myself") echo '{"accountId":"acc_self","displayName":"Herd Bot"}' ;;
        "GET "*"fields=assignee,status") echo "{\"key\":\"ENG-7\",\"fields\":{\"assignee\":${CLAIM_ASSIGNEE:-null},\"status\":{\"statusCategory\":{\"key\":\"${CLAIM_CAT:-new}\"}}}}" ;;
        "GET "*"/transitions") echo "{\"transitions\":$DEFAULT_TRANSITIONS}" ;;
        "PUT "*"/assignee") printf '' ;;
        "POST "*"/transitions") printf '' ;;
        "GET "*"fields=assignee") echo "{\"key\":\"ENG-7\",\"fields\":{\"assignee\":${VERIFY_ASSIGNEE:-$SELF_ASSIGNEE}}}" ;;
        *) echo '{}' ;;
      esac
    }
    _CLAIM_RESULT=""; _CLAIM_OWNER=""
    _backend_claim_item "$@"
    printf 'CLAIM=%s\nOWNER=%s\n' "$_CLAIM_RESULT" "$_CLAIM_OWNER" )
}
: > "$APILOG"
c1="$(claim ENG-7 brian)"
echo "$c1" | grep -q "CLAIM=CLAIMED" || fail "claim of an unassigned issue should be CLAIMED ($c1)"
grep -q 'P<<\/rest\/api\/3\/issue\/ENG-7\/assignee>>' "$APILOG" || fail "claim did not assign the issue"
grep -q '"accountId": "acc_self"' "$APILOG" || fail "claim did not assign to the token's own accountId"
pass

# 7b. claim of an issue already assigned to ANOTHER user → ALREADY, naming the owner; no assignment.
: > "$APILOG"
c2="$(CLAIM_ASSIGNEE='{"accountId":"acc_other","displayName":"Someone Else"}' claim ENG-7 brian)"
echo "$c2" | grep -q "CLAIM=ALREADY" || fail "claim of an other-assigned issue should be ALREADY ($c2)"
echo "$c2" | grep -q "OWNER=Someone Else" || fail "claim ALREADY should name the blocking assignee ($c2)"
grep -q '/assignee' "$APILOG" && fail "claim of an other-assigned issue must not re-assign it"
pass

# 7c. claim of a Done issue → ALREADY (shipped), no assignment.
c3="$(CLAIM_CAT=done claim ENG-7 brian)"
echo "$c3" | grep -q "CLAIM=ALREADY" || fail "claim of a Done issue should be ALREADY ($c3)"
pass

# 7d. claim already ours + in-progress → SELF.
c4="$(CLAIM_ASSIGNEE='{"accountId":"acc_self","displayName":"Herd Bot"}' CLAIM_CAT=indeterminate claim ENG-7 brian)"
echo "$c4" | grep -q "CLAIM=SELF" || fail "claim of our own in-progress issue should be SELF ($c4)"
pass

# 7e. claim-verify catches a racer: the re-read assignee is someone else → ALREADY, not CLAIMED.
c5="$(VERIFY_ASSIGNEE='{"accountId":"acc_racer"}' claim ENG-7 brian)"
echo "$c5" | grep -q "CLAIM=ALREADY" || fail "claim-verify should flip to ALREADY when a racer won ($c5)"
pass

# 8. HERD-52 queue_item → resolves the key, then posts a 📌 planned marker comment (who + 'sequenced
#    after <blocker>' + [<epoch>]). DONE.
: > "$APILOG"
q="$(run _backend_queue_item ENG-7 alice ENG-9)"
echo "$q" | grep -q "RESULT=DONE" || fail "queue_item did not report DONE ($q)"
grep -q 'P<<\/rest\/api\/3\/issue\/ENG-7\/comment>>' "$APILOG" || fail "queue_item did not post the marker via a comment"
grep -q "queued by alice" "$APILOG" || fail "queue_item marker did not name the operator"
grep -q "sequenced after ENG-9" "$APILOG" || fail "queue_item marker did not record the blocker"
grep -qE '\[[0-9]+\]' "$APILOG" || fail "queue_item marker did not embed a [<epoch>] timestamp"
pass

# 8a. queue_item with NO blocker → 'sequenced next', still DONE.
: > "$APILOG"
qn="$(run _backend_queue_item ENG-7 alice "")"
echo "$qn" | grep -q "RESULT=DONE" || fail "queue_item (no blocker) did not report DONE ($qn)"
grep -q "sequenced next" "$APILOG" || fail "queue_item (no blocker) did not fall back to 'sequenced next'"
pass

# 8b. queue_item on an unparseable ref → NOCHANGE, no comment.
: > "$APILOG"
qbad="$(run _backend_queue_item nodashhere alice ENG-9 2>/dev/null)"
echo "$qbad" | grep -q "RESULT=NOCHANGE" || fail "queue_item on an unparseable ref should be NOCHANGE ($qbad)"
grep -q '/comment' "$APILOG" && fail "queue_item on an unparseable ref should post no comment"
pass

# 8c. list_queued → reads each open issue's inline comments and prints ONE TSV line per 📌 marker; a
#     non-marker comment (ENG-9's) is ignored.
: > "$APILOG"
lq="$(run _backend_list_queued)"
grep -q '"comment"' "$APILOG" || fail "list_queued did not request the inline comment field"
echo "$lq" | grep -q "^#ENG-7${TAB}alice${TAB}sequenced after ENG-9${TAB}1700000000$" \
  || fail "list_queued did not emit the parsed marker TSV for ENG-7 ($lq)"
echo "$lq" | grep -q "^#ENG-9" && fail "list_queued surfaced ENG-9 which carries no 📌 marker ($lq)"
pass

# 8d. unqueue_item → reads the issue's comments and DELETEs ONLY the 📌 marker (cmt_mark), never the
#     unrelated comment (cmt_other). DONE.
: > "$APILOG"
uq="$(run _backend_unqueue_item ENG-7 alice)"
echo "$uq" | grep -q "RESULT=DONE" || fail "unqueue_item did not report DONE ($uq)"
grep -q 'M<<DELETE>>P<<\/rest\/api\/3\/issue\/ENG-7\/comment\/cmt_mark>>' "$APILOG" || fail "unqueue_item did not delete the marker comment (cmt_mark)"
grep -q 'cmt_other' "$APILOG" && fail "unqueue_item deleted a non-marker comment (cmt_other)"
pass

# 9. absent creds degrade loudly (no silent success), even with a fake curl available.
if ( cd "$T"; unset JIRA_API_TOKEN; . "$BACKEND"; _backend_list_open ) >/dev/null 2>&1; then
  fail "list_open should fail when JIRA_API_TOKEN is absent"
fi
pass

# 10. transport: the REAL _jira_api POSTs to the Jira endpoint with basic-auth from secrets (exercised
#     through the fake curl — still no real network).
: > "$CURLLOG"
( cd "$T" && . "$BACKEND"; _jira_api GET /rest/api/3/myself >/dev/null )
grep -q "acme.atlassian.net/rest/api/3/myself" "$CURLLOG" || fail "_jira_api did not hit the Jira REST endpoint"
grep -q "bot@acme.io:jira_test_token" "$CURLLOG" || fail "_jira_api did not basic-auth with the email:token from secrets"
pass

echo "ALL PASS ($PASS checks)"
