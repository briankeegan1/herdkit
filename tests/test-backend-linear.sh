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
# HERD-85: a stub journal_append lets us assert the tracker_write attribution event WITHOUT sourcing
# the real journal.sh — mirroring how _linear_gql is stubbed. Each call logs its raw args (one line),
# so a test can grep the event name, ref, requested state, component, result, and pr.
JLOG="$T/journal.log"

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
    # Stub journal_append (HERD-85): record each tracker_write call's args so the attribution shape is
    # assertable. Defined here so the backend's `command -v journal_append` guard sees it and fires.
    journal_append() { printf '%s\n' "$*" >> "$JLOG"; }
    _linear_gql() {
      printf 'QUERY<<%s>>VARS<<%s>>\n' "$1" "${2:-}" >> "$GQLLOG"
      case "$1" in
        *issueCreate*)      echo '{"data":{"issueCreate":{"success":true,"issue":{"id":"iss_1","identifier":"ENG-42","url":"https://linear.app/acme/issue/ENG-42"}}}}' ;;
        *commentCreate*)    echo '{"data":{"commentCreate":{"success":true}}}' ;;
        *issueUpdate*)      echo "{\"data\":{\"issueUpdate\":{\"success\":${ISSUEUPDATE_SUCCESS:-true}}}}" ;;
        *"states(filter"*)  echo "{\"data\":{\"issues\":{\"nodes\":[{\"id\":\"iss_7\",\"identifier\":\"ENG-7\",\"title\":\"first open issue\",\"team\":{\"states\":{\"nodes\":${STATES_NODES:-$DEFAULT_STATE_NODES}}}}]}}}" ;;
        # HERD-52/HERD-244 planned markers MUST precede the bare `"state { type }"` item_state shape:
        # unqueue now also selects `state { type }` (to protect a claim's assignee), so the more
        # specific comments-shape has to win first.
        *"id comments { nodes { id body } }"*) echo '{"data":{"issues":{"nodes":[{"id":"iss_7","comments":{"nodes":[{"id":"cmt_mark","body":"📌 queued by alice: sequenced after ENG-9 [1700000000]"},{"id":"cmt_other","body":"an unrelated comment"}]},"assignee":{"id":"me_viewer"},"state":{"type":"unstarted"}}]}}}' ;;
        *"comments { nodes { body } }"*) echo '{"data":{"issues":{"nodes":[{"identifier":"ENG-7","comments":{"nodes":[{"body":"📌 queued by alice: sequenced after ENG-9 [1700000000]"}]}},{"identifier":"ENG-9","comments":{"nodes":[{"body":"just a regular note"}]}}]}}}' ;;
        *commentDelete*)    echo '{"data":{"commentDelete":{"success":true}}}' ;;
        *"state { type }"*) echo '{"data":{"issues":{"nodes":[{"state":{"type":"completed"}}]}}}' ;;
        *updatedAt*)        echo '{"data":{"issues":{"nodes":[{"identifier":"ENG-7","title":"first open issue","description":"first open issue\nFull spec body here.","url":"https://linear.app/acme/issue/ENG-7","updatedAt":"2026-07-06T01:02:03.000Z","state":{"name":"In Progress","type":"started"}}]}}}' ;;
        *"state { name type }"*) echo '{"data":{"issues":{"nodes":[{"identifier":"ENG-7","title":"first open issue","description":"first open issue\nDetails for seven.","url":"https://linear.app/acme/issue/ENG-7","state":{"name":"Todo","type":"unstarted"},"assignee":null},{"identifier":"ENG-9","title":"second open issue","description":null,"url":"https://linear.app/acme/issue/ENG-9","state":{"name":"In Progress","type":"started"},"assignee":{"displayName":"Chase"}}]}}}' ;;
        # HERD-184 operator-inbox reader: viewer id + per-issue comments with author + id. Must precede
        # the generic issues( fallthrough. The comment set mixes a cross-operator comment, the viewer's
        # OWN comment (must be excluded), and a 📌 planned marker (must be skipped).
        # Also used by HERD-244 plan-time assignee set/clear (viewer = API identity).
        *"viewer { id }"*)  echo '{"data":{"viewer":{"id":"me_viewer"}}}' ;;
        *"comments(first: 50)"*) echo '{"data":{"issues":{"nodes":[{"identifier":"ENG-7","comments":{"nodes":[{"id":"cin_1","body":"please rebase before we merge","user":{"id":"other_op","name":"Dana"}},{"id":"cin_self","body":"my own note","user":{"id":"me_viewer","name":"Me"}},{"id":"cin_mark","body":"📌 queued by alice: sequenced after ENG-9 [1700000000]","user":{"id":"other_op","name":"Dana"}}]}}]}}}' ;;
        # queue resolves id+identifier+assignee (unassigned so set-assignee runs).
        *"id identifier"*)  echo '{"data":{"issues":{"nodes":[{"id":"iss_7","identifier":"ENG-7","assignee":null}]}}}' ;;
        # HERD-490: list_closed's `in: ["completed", "canceled"]` filter is the mirror of list_open's
        # `nin` — must precede the generic issues( fallthrough (which serves list_open's shape) so the
        # two are distinguishable in the test.
        *"type: { in: [\"completed"*) echo '{"data":{"issues":{"nodes":[{"identifier":"ENG-3","title":"first closed issue"},{"identifier":"ENG-5","title":"second closed issue"}]}}}' ;;
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
grep -q "RESULT=DONE" <<< "$out" || fail "add_item did not report DONE ($out)"
grep -q "https://linear.app/acme/issue/ENG-42" <<< "$out" || fail "add_item did not surface the created issue URL"
grep -q "issueCreate" "$GQLLOG" || fail "add_item did not issue an 'issueCreate' mutation"
grep -q "add a dark-mode toggle" "$GQLLOG" || fail "add_item did not pass the request text as the issue title/body"
grep -q "team_xyz" "$GQLLOG" || fail "add_item did not target the configured team (teamId)"
pass

# 1b. HERD-77 (short titles): a long single-line add must yield a SHORT title (<=100 chars) but keep
#     the FULL text as the description — never the old "first-line-as-essay" where a one-paragraph
#     request became a giant title duplicated in the body (user complaint 2026-07-07; 7 hand-renames).
#     Build a 500+char single line, run add_item, then parse the issueCreate VARS out of the log and
#     assert BOTH halves.
: > "$GQLLOG"
BIG="$(python3 -c 'print("Add a really important feature " + "x"*470)')"   # 501 chars, no newline
out="$(run _backend_add_item REQ2 "$BIG")"
grep -q "RESULT=DONE" <<< "$out" || fail "add_item (long) did not report DONE ($out)"
python3 - "$GQLLOG" <<'PY' || fail "add_item (long) title/description lengths wrong"
import sys, json, re
log = open(sys.argv[1]).read()           # one issueCreate round-trip; QUERY text is multi-line
m = re.findall(r"VARS<<(.*?)>>", log, re.S)
assert m, "no issueCreate VARS logged"
v = json.loads(m[-1])
title, desc = v["title"], v["description"]
assert len(title) <= 100, "title too long: %d chars" % len(title)
assert len(desc) >= 500, "description not full-length: %d chars" % len(desc)
assert len(desc) > len(title), "description must be the FULL text, not the truncated title"
PY
pass

# 1c. HERD-77: a long first line with a clause boundary derives the title from the FIRST clause
#     (split on ' — '), not a blind mid-word cut — the title reads as a real summary.
: > "$GQLLOG"
CLAUSE="Backends derive a short title — $(python3 -c 'print("y"*300)')"
run _backend_add_item REQ3 "$CLAUSE" >/dev/null
python3 - "$GQLLOG" <<'PY' || fail "add_item clause-split title wrong"
import sys, json, re
m = re.findall(r"VARS<<(.*?)>>", open(sys.argv[1]).read(), re.S)
assert m, "no issueCreate VARS logged"
t = json.loads(m[-1])["title"]
assert t.startswith("Backends derive a short title"), "clause not used as title: %r" % t
assert len(t) <= 100, "clause title too long: %d chars" % len(t)
PY
pass

# 1d. HERD-783: real newlines stay real across the add seam: the first line is the short title and
#     the complete multiline text is the description. A literal backslash-n is NOT decoded — it is
#     ordinary intentional title/body text unless the transport contains an actual newline.
: > "$GQLLOG"
MULTILINE=$'Preserve multiline scribe arguments\n\nThe body stays separate from the title.\n- prove Codex\n- prove Claude'
run _backend_add_item REQ4 "$MULTILINE" >/dev/null
LITERAL='Keep literal \n text when intended'
run _backend_add_item REQ5 "$LITERAL" >/dev/null
python3 - "$GQLLOG" "$MULTILINE" "$LITERAL" <<'PY' || fail "HERD-783 newline/literal transport changed Linear variables"
import json, re, sys
rows = [json.loads(x) for x in re.findall(r"VARS<<(.*?)>>", open(sys.argv[1]).read(), re.S)]
assert len(rows) == 2, rows
assert rows[0]["title"] == "Preserve multiline scribe arguments", rows[0]
assert rows[0]["description"] == sys.argv[2], rows[0]
assert rows[1]["title"] == sys.argv[3], rows[1]
assert rows[1]["description"] == sys.argv[3], rows[1]
assert "\\n" in rows[1]["title"], rows[1]
PY
pass

# 2. list_open (team scoped ON) → an issues() query filtered to the configured team, parsed to
#    "#<identifier> <title>" lines. Privacy: the team filter MUST be present so other teams' issues
#    can't leak in.
: > "$GQLLOG"
open="$(run _backend_list_open)"
grep -q "issues(" "$GQLLOG" || fail "list_open did not issue an 'issues' query"
grep -q 'team: { id: { eq: $team }' "$GQLLOG" || fail "list_open (team set) did not scope the query to the team"
grep -q "team_xyz" "$GQLLOG" || fail "list_open (team set) did not pass the team id in variables"
grep -q "^#ENG-7 first open issue$" <<< "$open" || fail "list_open missing '#ENG-7 first open issue' ($open)"
grep -q "^#ENG-9 second open issue$" <<< "$open" || fail "list_open missing '#ENG-9 second open issue'"
pass

# 2b. list_open (team scoped OFF) → no team filter, so it spans every team the key can see.
: > "$GQLLOG"
open2="$( unset LINEAR_TEAM_ID; run _backend_list_open)"
grep -q "issues(" "$GQLLOG" || fail "list_open (no team) did not issue an 'issues' query"
grep -q 'team: { id:' "$GQLLOG" && fail "list_open (no team) must NOT scope by team — it leaked a team filter"
grep -q "^#ENG-7 first open issue$" <<< "$open2" || fail "list_open (no team) missing '#ENG-7 first open issue' ($open2)"
pass

# 2c. HERD-490: list_closed (team scoped ON) → an issues() query filtered to completed/canceled,
#     scoped to the team, parsed to "#<identifier> <title>" lines — the mirror of list_open, giving a
#     caller a way to see items list_open structurally excludes (a manually-closed duplicate that a
#     "does this already exist?" search over the open list alone would never find).
: > "$GQLLOG"
closed="$(run _backend_list_closed)"
grep -q "issues(" "$GQLLOG" || fail "list_closed did not issue an 'issues' query"
grep -q 'type: { in: \["completed", "canceled"\] }' "$GQLLOG" || fail "list_closed did not filter to completed/canceled state types"
grep -q 'team: { id: { eq: $team }' "$GQLLOG" || fail "list_closed (team set) did not scope the query to the team"
grep -q "team_xyz" "$GQLLOG" || fail "list_closed (team set) did not pass the team id in variables"
grep -q "^#ENG-3 first closed issue$" <<< "$closed" || fail "list_closed missing '#ENG-3 first closed issue' ($closed)"
grep -q "^#ENG-5 second closed issue$" <<< "$closed" || fail "list_closed missing '#ENG-5 second closed issue'"
pass

# 2d. list_closed (team scoped OFF) → no team filter, spans every team the key can see.
: > "$GQLLOG"
closed2="$( unset LINEAR_TEAM_ID; run _backend_list_closed)"
grep -q 'type: { in: \["completed", "canceled"\] }' "$GQLLOG" || fail "list_closed (no team) did not filter to completed/canceled"
grep -q 'team: { id:' "$GQLLOG" && fail "list_closed (no team) must NOT scope by team — it leaked a team filter"
grep -q "^#ENG-3 first closed issue$" <<< "$closed2" || fail "list_closed (no team) missing '#ENG-3 first closed issue' ($closed2)"
pass

# 2c. list_open_rich → same open filter as list_open but also requests state {name type} +
#     description + url + assignee {displayName}, emits TSV
#     ("#<id>\t<state-type>\t<state-name>\t<title>\t<desc>\t<assignee>\t<url>"), sorts
#     started-first, and flattens description whitespace (a raw newline would corrupt the TSV). The
#     trailing <url> (HERD-49) feeds backlog-view.sh's OSC 8 chip hyperlink.
TAB="$(printf '\t')"
: > "$GQLLOG"
rich="$(run _backend_list_open_rich)"
grep -q "description url state { name type }" "$GQLLOG" || fail "list_open_rich did not request description + url + state name/type"
grep -q "assignee { displayName }" "$GQLLOG" || fail "list_open_rich did not request assignee displayName"
grep -q 'team: { id: { eq: $team }' "$GQLLOG" || fail "list_open_rich (team set) did not scope the query to the team"
grep -q "^#ENG-9" <<< "$(grep '^#' <<< "$rich" | sed -n 1p)" \
  || fail "list_open_rich did not sort the started (in-progress) issue first ($rich)"
grep -q "^#ENG-9${TAB}started${TAB}In Progress${TAB}second open issue${TAB}${TAB}Chase${TAB}https://linear.app/acme/issue/ENG-9$" <<< "$rich" \
  || fail "list_open_rich TSV shape wrong for ENG-9 (assignee Chase 6th field, url 7th field) ($rich)"
grep -q "^#ENG-7${TAB}unstarted${TAB}Todo${TAB}first open issue${TAB}first open issue Details for seven.${TAB}${TAB}https://linear.app/acme/issue/ENG-7$" <<< "$rich" \
  || fail "list_open_rich did not flatten desc / place empty assignee then url; ENG-7 shape wrong ($rich)"
pass

# ── HERD-652 review finding: list_open/list_open_rich must disambiguate a real outage from a ──────
# genuinely empty backlog, not collapse both into "exit 0, no output" via `| python3 ... || true`.
#
# 2e. Transport failure (curl-level, simulated by _linear_gql itself returning non-zero) → list_open
#     must exit NON-ZERO with no output — never the false "empty success" the old code produced.
set +e
lo_fail_out="$( cd "$T" && . "$BACKEND"; _linear_gql() { return 7; }; _backend_list_open )"
lo_fail_rc=$?
set -e
[ "$lo_fail_rc" -ne 0 ] || fail "list_open must exit non-zero on a transport failure (rc=$lo_fail_rc)"
[ -z "$lo_fail_out" ] || fail "list_open must print nothing on a transport failure, got: $lo_fail_out"
pass

# 2f. GraphQL-level failure — curl succeeds, but Linear answers with a top-level "errors" body (no
#     usable data). Must ALSO exit non-zero, not print an empty-but-successful list.
set +e
lo_err_out="$( cd "$T" && . "$BACKEND"; _linear_gql() { echo '{"errors":[{"message":"rate limited"}]}'; }; _backend_list_open )"
lo_err_rc=$?
set -e
[ "$lo_err_rc" -ne 0 ] || fail "list_open must exit non-zero on a GraphQL errors response (rc=$lo_err_rc)"
[ -z "$lo_err_out" ] || fail "list_open must print nothing on a GraphQL errors response, got: $lo_err_out"
pass

# 2g. Genuinely empty result — curl succeeds, valid JSON, zero nodes. This IS a success: exit 0,
#     empty output. The fix must preserve this (the whole point of HERD-652).
set +e
lo_empty_out="$( cd "$T" && . "$BACKEND"; _linear_gql() { echo '{"data":{"issues":{"nodes":[]}}}'; }; _backend_list_open )"
lo_empty_rc=$?
set -e
[ "$lo_empty_rc" -eq 0 ] || fail "list_open must exit 0 on a genuinely empty result, got rc=$lo_empty_rc"
[ -z "$lo_empty_out" ] || fail "list_open must print nothing for a genuinely empty result, got: $lo_empty_out"
pass

# 2h. list_open_rich shares the same _linear_gql_or_fail seam — a transport failure must exit
#     non-zero there too, not silently degrade to an empty-but-successful rich list.
set +e
lor_fail_out="$( cd "$T" && . "$BACKEND"; _linear_gql() { return 7; }; _backend_list_open_rich )"
lor_fail_rc=$?
set -e
[ "$lor_fail_rc" -ne 0 ] || fail "list_open_rich must exit non-zero on a transport failure (rc=$lor_fail_rc)"
[ -z "$lor_fail_out" ] || fail "list_open_rich must print nothing on a transport failure, got: $lor_fail_out"
pass

# 2d. show_item → single-issue detail via issues(filter:) (never issueSearch): identifier + live
#     state on line 1, then title, the UNtruncated description, and url + updated date.
: > "$GQLLOG"
det="$(run _backend_show_item "#ENG-7")"
grep -q "issueSearch" "$GQLLOG" && fail "show_item must NOT use the deprecated issueSearch endpoint"
grep -q '"n": 7' "$GQLLOG" || fail "show_item did not resolve by the parsed issue number"
grep -q "^#ENG-7 · In Progress (started)$" <<< "$det" || fail "show_item missing the id · state header ($det)"
grep -q "Full spec body here." <<< "$det" || fail "show_item did not print the full description body"
grep -q "linear.app/acme/issue/ENG-7 · updated 2026-07-06" <<< "$det" || fail "show_item missing url + updated date"
pass

# 2e. show_item on an unparseable ref → loud stderr, no network round-trip. (Exit code is not
#     asserted: `run` wraps the op in a subshell that always appends its RESULT/ITEM_STATE report.)
: > "$GQLLOG"
err="$(run _backend_show_item "nodashhere" 2>&1 >/dev/null || true)"
grep -q "not a TEAMKEY-NUMBER" <<< "$err" || fail "show_item on an unparseable ref should say so on stderr ($err)"
grep -q "issues(" "$GQLLOG" && fail "show_item on an unparseable ref should not issue any query"
pass

# 3. mark_shipped → resolves the issue via issues(filter:) (NOT the deprecated issueSearch),
#    comments the PR link, then moves it to the resolved Done state.
: > "$GQLLOG"
ship="$(run _backend_mark_shipped ENG-7 https://github.com/acme/widgets/pull/3)"
grep -q "RESULT=DONE" <<< "$ship" || fail "mark_shipped did not report DONE ($ship)"
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
grep -q "RESULT=NOCHANGE" <<< "$ship2" || fail "mark_shipped on an unparseable slug should be NOCHANGE ($ship2)"
grep -q "issues(" "$GQLLOG" && fail "mark_shipped on an unparseable slug should not issue any query"
pass

# 4. item_state → resolves via issues(filter:) reading state.type; maps completed → closed.
: > "$GQLLOG"
out="$(run _backend_item_state "provider-lib#ENG-7")"
grep -q "ITEM_STATE=closed" <<< "$out" || fail "_backend_item_state did not return ITEM_STATE=closed ($out)"
grep -q "issues(filter" "$GQLLOG" || fail "_backend_item_state did not resolve via issues(filter:)"
grep -q "issueSearch" "$GQLLOG"   && fail "_backend_item_state must NOT use the deprecated issueSearch endpoint"
grep -q "state { type }" "$GQLLOG" || fail "_backend_item_state did not request the issue state.type"
grep -q 'team: { key: { eq: $key }' "$GQLLOG" || fail "_backend_item_state did not resolve by the identifier's team key"
grep -q '"key": "ENG"' "$GQLLOG"  || fail "_backend_item_state did not scope resolution to team ENG from the ENG-7 slug"
grep -q 'team_xyz' "$GQLLOG"      && fail "_backend_item_state must NOT scope resolution by the configured LINEAR_TEAM_ID"
pass

# 4a. HERD-117 claim-guard PRECONDITION — the adapter's state read is exactly what the pre-spawn claim
#     guard (herd-claim.sh) consults to refuse a stale (Done/Canceled) pick before it can reopen a
#     shipped issue. With the state read MOCKED, assert a completed AND a canceled issue both map to
#     closed, that the query requests updatedAt, and that the last-updated day is surfaced as
#     ITEM_UPDATED evidence (a refusal that cannot name the state/last-updated is a worse abort message).
: > "$GQLLOG"
guard_state() {   # env G_TYPE/G_UPD drive the mocked state.type + updatedAt; prints ITEM_STATE/ITEM_UPDATED.
  ( cd "$T" && . "$BACKEND"
    _linear_gql() {
      printf 'QUERY<<%s>>VARS<<%s>>\n' "$1" "${2:-}" >> "$GQLLOG"
      printf '{"data":{"issues":{"nodes":[{"state":{"type":"%s"},"updatedAt":"%s"}]}}}' "$G_TYPE" "$G_UPD"
    }
    ITEM_STATE=""; ITEM_UPDATED=""
    _backend_item_state "provider-lib#ENG-7"
    printf 'ITEM_STATE=%s\nITEM_UPDATED=%s\n' "${ITEM_STATE:-}" "${ITEM_UPDATED:-}" )
}
out="$(G_TYPE=completed G_UPD="2026-07-08T21:51:00.000Z" guard_state)"
grep -q "ITEM_STATE=closed" <<< "$out" || fail "guard precondition: completed issue must read closed ($out)"
grep -q "ITEM_UPDATED=2026-07-08" <<< "$out" || fail "guard precondition: last-updated (day) evidence not surfaced ($out)"
grep -q "updatedAt" "$GQLLOG"                   || fail "guard precondition: state read did not request updatedAt evidence"
out="$(G_TYPE=canceled G_UPD="2026-07-01T00:00:00.000Z" guard_state)"
grep -q "ITEM_STATE=closed" <<< "$out" || fail "guard precondition: canceled issue must also read closed ($out)"
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

# 4b2. HERD-502 mutation-prove: a ref that resolves via NEITHER the identifier path (not a
#      TEAMKEY-NUMBER shape) NOR the conservative title fallback (zero matches) must report
#      ITEM_STATE UNSET and a non-zero return — NOT silently "open". This is the live
#      'full-auto'/#606 incident reproduced: a malformed `Refs:` token that is not a real tracker
#      identifier. Reverting the HERD-502 fix (dropping the `len(nodes) != 1` requirement back to a
#      bare identifier-parse check) makes this fail — the old code defaulted ITEM_STATE=open the
#      moment the identifier parse failed, without ever requiring the title fallback to find a match.
unresolvable_item_state() {
  ( cd "$T" && . "$BACKEND"
    _linear_gql() { echo '{"data":{"issues":{"nodes":[]}}}'; }   # NOTHING resolves, identifier or title
    ITEM_STATE="PRESET"
    if _backend_item_state "full-auto"; then rc=0; else rc=1; fi
    printf 'RC=%s\nITEM_STATE=%s\n' "$rc" "${ITEM_STATE:-}" )
}
outu="$(unresolvable_item_state)"
grep -q "^RC=1$" <<< "$outu" || fail "HERD-502 mutation-prove: an unresolvable ref must return non-zero from _backend_item_state ($outu)"
grep -q "^ITEM_STATE=$" <<< "$outu" || fail "HERD-502 mutation-prove: an unresolvable ref must leave ITEM_STATE unset, not default to open ($outu)"
pass

# 4c. update_state (done) → resolves the issue by the identifier's OWN team key via issues(filter:)
#     (never the deprecated issueSearch, never LINEAR_TEAM_ID), requests a workflow state of the
#     MAPPED type (done→completed), then issueUpdate moves it there. It must NOT issueCreate — a
#     state change is not a new item (the gh #139 junk-issue bug this closes).
: > "$GQLLOG"
us="$(run _backend_update_state ENG-7 done)"
grep -q "RESULT=DONE" <<< "$us" || fail "update_state did not report DONE ($us)"
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
grep -q "RESULT=NOCHANGE" <<< "$us2" || fail "update_state on an unknown state should be NOCHANGE ($us2)"
grep -q "issues(" "$GQLLOG" && fail "update_state on an unknown state should issue no query"
pass

# 4f. update_state falls back to a CONSERVATIVE title match (containsIgnoreCase) when the ref carries
#     no identifier — so a reconcile request that names an item by title still transitions it.
: > "$GQLLOG"
us3="$(run _backend_update_state "first open issue" done)"
grep -q "containsIgnoreCase" "$GQLLOG" || fail "update_state (no identifier) did not fall back to a title match"
grep -q "RESULT=DONE" <<< "$us3" || fail "update_state title match did not transition the unique match ($us3)"
pass

# 4g. gh #169: a workspace with MULTIPLE started-type states must resolve 'in-progress' to the state
#     NAMED 'In Progress', never whichever started state the API returns first. STATES_NODES feeds the
#     stub BOTH started states with 'In Review' listed first AND at a higher position — name wins.
: > "$GQLLOG"
us4="$( STATES_NODES='[{"id":"st_review","name":"In Review","position":2},{"id":"st_progress","name":"In Progress","position":1}]' \
        run _backend_update_state ENG-7 in-progress)"
grep -q "RESULT=DONE" <<< "$us4" || fail "update_state (multi started) did not report DONE ($us4)"
grep -q "issueUpdate" "$GQLLOG" || fail "update_state (multi started) did not move the issue"
grep -q "st_progress" "$GQLLOG" || fail "update_state (multi started) did not pick the 'In Progress' state by NAME (gh #169)"
grep -q "st_review"  "$GQLLOG" && fail "update_state (multi started) picked 'In Review' — the exact gh #169 regression"
pass

# 4h. gh #169 fallback: when NO started state is named 'In Progress', pick the one with the LOWEST
#     position (Linear's canonical order = the earliest started state), still never 'In Review'.
: > "$GQLLOG"
us5="$( STATES_NODES='[{"id":"st_review","name":"In Review","position":2},{"id":"st_doing","name":"Doing","position":1}]' \
        run _backend_update_state ENG-7 in-progress)"
grep -q "RESULT=DONE" <<< "$us5" || fail "update_state (position fallback) did not report DONE ($us5)"
grep -q "st_doing" "$GQLLOG" || fail "update_state (position fallback) did not pick the LOWEST-position started state (gh #169)"
grep -q "st_review" "$GQLLOG" && fail "update_state (position fallback) picked the higher-position 'In Review' — gh #169 regression"
pass

# 4i. gh #169 for DONE too: with several completed-type states, prefer the one named 'Done', else the
#     lowest-position one — never an arbitrary completed state (e.g. 'Duplicate').
: > "$GQLLOG"
us6="$( STATES_NODES='[{"id":"st_dup","name":"Duplicate","position":2},{"id":"st_done","name":"Done","position":1}]' \
        run _backend_update_state ENG-7 done)"
grep -q "RESULT=DONE" <<< "$us6" || fail "update_state (multi completed) did not report DONE ($us6)"
grep -q "st_done" "$GQLLOG" || fail "update_state (multi completed) did not pick the 'Done' state by NAME (gh #169)"
grep -q "st_dup"  "$GQLLOG" && fail "update_state (multi completed) picked 'Duplicate' — gh #169 regression"
pass

# 4j. VERIFIED MUTATION (HERD-70): update_state reports DONE only when the final issueUpdate CONFIRMS
#     success:true. A transiently-FAILED mutation (stub returns success:false) must be NOCHANGE — NOT an
#     optimistic DONE — so agent-watch's _reconcile_via_ref returns non-zero and falls back to the fuzzy
#     scribe retry instead of journaling a false verified transition (the PR #187/HERD-67 incident).
: > "$GQLLOG"
usf="$( ISSUEUPDATE_SUCCESS=false run _backend_update_state ENG-7 done 2>/dev/null)"
grep -q "RESULT=NOCHANGE" <<< "$usf" || fail "update_state must return NOCHANGE when issueUpdate is not confirmed ($usf)"
grep -q "issueUpdate" "$GQLLOG" || fail "update_state (failed mutation) should still ATTEMPT the issueUpdate before reporting NOCHANGE"
grep -q "issueCreate" "$GQLLOG" && fail "update_state (failed mutation) must NOT fall back to filing a new issue"
pass

# 4k. HERD-70: the same verification guards mark_shipped — a failed Done-move issueUpdate is NOCHANGE,
#     never a false 'shipped', even though the PR-link comment already posted.
: > "$GQLLOG"
shipf="$( ISSUEUPDATE_SUCCESS=false run _backend_mark_shipped ENG-7 https://github.com/acme/widgets/pull/5 2>/dev/null)"
grep -q "RESULT=NOCHANGE" <<< "$shipf" || fail "mark_shipped must return NOCHANGE when the Done-move issueUpdate is not confirmed ($shipf)"
grep -q "commentCreate" "$GQLLOG" || fail "mark_shipped (failed mutation) should still post the PR-link comment"
grep -q "issueUpdate" "$GQLLOG" || fail "mark_shipped (failed mutation) should still ATTEMPT the Done-move issueUpdate"
pass

# 7. HERD-85 attribution — a state write journals ONE tracker_write event carrying the ref, the
#    requested state, the component (from HERD_COMPONENT), the result, and the backend. update_state
#    under HERD_COMPONENT=reconcile with a PR in $HERD_TW_PR must record all of it.
: > "$GQLLOG"; : > "$JLOG"
HERD_COMPONENT=reconcile HERD_TW_PR=42 run _backend_update_state ENG-7 done >/dev/null
[ "$(grep -c '^tracker_write ' "$JLOG")" = "1" ] || fail "update_state must journal EXACTLY ONE tracker_write event ($(cat "$JLOG"))"
tw="$(grep '^tracker_write ' "$JLOG")"
grep -q "ref ENG-7" <<< "$tw" || fail "tracker_write missing 'ref ENG-7' ($tw)"
grep -q "requested done" <<< "$tw" || fail "tracker_write missing 'requested done' ($tw)"
grep -q "component reconcile" <<< "$tw" || fail "tracker_write did not attribute the component from HERD_COMPONENT ($tw)"
grep -q "result DONE" <<< "$tw" || fail "tracker_write did not record the verified result ($tw)"
grep -q "backend linear" <<< "$tw" || fail "tracker_write missing the backend field ($tw)"
grep -q "pr 42" <<< "$tw" || fail "tracker_write did not carry the PR from HERD_TW_PR ($tw)"
pass

# 7b. Attribution defaults to 'manual' when no HERD_COMPONENT is set (a hand-run backend op), and
#     omits the pr field when neither a pr arg nor $HERD_TW_PR is present.
: > "$JLOG"
( unset HERD_COMPONENT HERD_TW_PR; run _backend_update_state ENG-7 in-progress ) >/dev/null
tw="$(grep '^tracker_write ' "$JLOG")"
grep -q "component manual" <<< "$tw" || fail "tracker_write did not default the component to 'manual' ($tw)"
grep -q "requested in-progress" <<< "$tw" || fail "tracker_write did not record the requested in-progress state ($tw)"
grep -q " pr " <<< "$tw" && fail "tracker_write must omit the pr field when no PR is known ($tw)"
pass

# 7c. A NON-confirmed write (issueUpdate success:false) still journals — with result NOCHANGE — so a
#     failed transition is attributable, not silent (the HERD-67 In-Progress-after-merge diagnosis gap).
: > "$JLOG"
HERD_COMPONENT=scribe ISSUEUPDATE_SUCCESS=false run _backend_update_state ENG-7 done >/dev/null 2>&1
tw="$(grep '^tracker_write ' "$JLOG")"
grep -q "component scribe" <<< "$tw" || fail "tracker_write did not attribute the scribe component ($tw)"
grep -q "result NOCHANGE" <<< "$tw" || fail "an unconfirmed write must journal result NOCHANGE ($tw)"
pass

# 7d. mark_shipped journals a tracker_write with the PR link and requested 'shipped'.
: > "$JLOG"
HERD_COMPONENT=reconcile run _backend_mark_shipped ENG-7 https://github.com/acme/widgets/pull/3 >/dev/null
tw="$(grep '^tracker_write ' "$JLOG")"
grep -q "requested shipped" <<< "$tw" || fail "mark_shipped tracker_write missing 'requested shipped' ($tw)"
grep -q "pr https://github.com/acme/widgets/pull/3" <<< "$tw" || fail "mark_shipped tracker_write did not carry the PR ($tw)"
grep -q "component reconcile" <<< "$tw" || fail "mark_shipped did not attribute the component ($tw)"
pass

# 7e. FAIL-SOFT: when journal_append is UNDEFINED (journal.sh never sourced), the write still succeeds
#     and nothing is journaled — a journal problem never blocks or alters the state write. Source the
#     backend WITHOUT a journal_append stub so the backend's `command -v journal_append` guard finds none.
: > "$JLOG"
out="$(
  cd "$T" && . "$BACKEND"
  _linear_gql() {
    if [ "${1#*states\(filter}" != "$1" ]; then
      echo "{\"data\":{\"issues\":{\"nodes\":[{\"id\":\"iss_7\",\"team\":{\"states\":{\"nodes\":$DEFAULT_STATE_NODES}}}]}}}"
    else
      echo '{"data":{"issueUpdate":{"success":true}}}'
    fi
  }
  _BACKEND_RESULT=""
  _backend_update_state ENG-7 done
  printf 'RESULT=%s\n' "${_BACKEND_RESULT:-}"
)"
grep -q "RESULT=DONE" <<< "$out" || fail "update_state must still succeed with journal_append undefined ($out)"
[ ! -s "$JLOG" ] || fail "no tracker_write should be written when journal_append is undefined ($(cat "$JLOG"))"
pass

# 8. HERD-52 queue_item → resolves the issue id, then commentCreate's a 📌 planned marker carrying
#    who + "sequenced after <blocker>" + a [<epoch>] timestamp. Reports DONE.
#    HERD-244: ALSO issueUpdate's assigneeId to the viewer (API identity) so the plan is visible as
#    a first-class Linear assignee in every client, not only via `herd backlog queued`.
: > "$GQLLOG"
q="$(run _backend_queue_item ENG-7 alice ENG-9)"
grep -q "RESULT=DONE" <<< "$q" || fail "queue_item did not report DONE ($q)"
grep -q "commentCreate" "$GQLLOG" || fail "queue_item did not post the marker via commentCreate"
grep -q "queued by alice" "$GQLLOG" || fail "queue_item marker did not name the operator (who)"
grep -q "sequenced after ENG-9" "$GQLLOG" || fail "queue_item marker did not record the blocker"
grep -qE '\[[0-9]+\]' "$GQLLOG" || fail "queue_item marker did not embed a [<epoch>] timestamp"
grep -q "viewer { id }" "$GQLLOG" || fail "queue_item (HERD-244) did not resolve the viewer for assignee"
grep -q "issueUpdate" "$GQLLOG" || fail "queue_item (HERD-244) did not issueUpdate the assignee"
grep -q "assigneeId" "$GQLLOG" || fail "queue_item (HERD-244) issueUpdate did not set assigneeId"
grep -q "me_viewer" "$GQLLOG" || fail "queue_item (HERD-244) did not assign the viewer id (me_viewer)"
pass

# 8a. queue_item with NO blocker → marker says "sequenced next", still DONE.
: > "$GQLLOG"
qn="$(run _backend_queue_item ENG-7 alice "")"
grep -q "RESULT=DONE" <<< "$qn" || fail "queue_item (no blocker) did not report DONE ($qn)"
grep -q "sequenced next" "$GQLLOG" || fail "queue_item (no blocker) did not fall back to 'sequenced next'"
pass

# 8b. queue_item on an unparseable ref → NOCHANGE, no commentCreate (nothing to mark).
: > "$GQLLOG"
qbad="$(run _backend_queue_item nodashhere alice ENG-9 2>/dev/null)"
grep -q "RESULT=NOCHANGE" <<< "$qbad" || fail "queue_item on an unparseable ref should be NOCHANGE ($qbad)"
grep -q "commentCreate" "$GQLLOG" && fail "queue_item on an unparseable ref should post no comment"
pass

# 8c. list_queued → reads each open issue's comments and prints ONE TSV line per 📌 marker
#     ("#<id>\t<who>\t<detail>\t<epoch>"); a non-marker comment (ENG-9's) is ignored.
: > "$GQLLOG"
lq="$(run _backend_list_queued)"
grep -q "comments { nodes { body } }" "$GQLLOG" || fail "list_queued did not request per-issue comment bodies"
grep -q "^#ENG-7${TAB}alice${TAB}sequenced after ENG-9${TAB}1700000000$" <<< "$lq" \
  || fail "list_queued did not emit the parsed marker TSV for ENG-7 ($lq)"
grep -q "^#ENG-9" <<< "$lq" && fail "list_queued surfaced ENG-9 which carries no 📌 marker ($lq)"
pass

# 8d. unqueue_item → resolves the issue's comments and commentDelete's ONLY the 📌 marker (cmt_mark),
#     never the unrelated comment (cmt_other). Reports DONE.
#     HERD-244: ALSO clears the plan-time assignee (issueUpdate assigneeId: null) when the issue is
#     still assigned to the viewer on a non-started state (plan dropped before claim).
: > "$GQLLOG"
uq="$(run _backend_unqueue_item ENG-7 alice)"
grep -q "RESULT=DONE" <<< "$uq" || fail "unqueue_item did not report DONE ($uq)"
grep -q "commentDelete" "$GQLLOG" || fail "unqueue_item did not delete the marker via commentDelete"
grep -q '"id": "cmt_mark"' "$GQLLOG" || fail "unqueue_item did not target the 📌 marker comment (cmt_mark)"
grep -q '"id": "cmt_other"' "$GQLLOG" && fail "unqueue_item deleted a non-marker comment (cmt_other)"
grep -q "viewer { id }" "$GQLLOG" || fail "unqueue_item (HERD-244) did not resolve the viewer to clear assignee"
# The clear mutation must pass a null assignee (Python json.dumps None → null).
python3 - "$GQLLOG" <<'PY' || fail "unqueue_item (HERD-244) did not issueUpdate assigneeId to null"
import sys, re, json
log = open(sys.argv[1]).read()
assert "issueUpdate" in log, "no issueUpdate in log"
# Find PlanUnassign / any issueUpdate VARS carrying assignee: null
found = False
for m in re.finditer(r"VARS<<(.*?)>>", log, re.S):
    try: v = json.loads(m.group(1))
    except Exception: continue
    if "assignee" in v and v["assignee"] is None and v.get("id") == "iss_7":
        found = True
        break
assert found, "no issueUpdate VARS with assignee=null for iss_7"
PY
pass

# 8d-started. HERD-244: unqueue on a STARTED issue (claim has taken over) must NOT clear assignee —
#     the claim owns assignee+started; unqueue only removes the 📌 noise.
: > "$GQLLOG"
uq_started="$(
  cd "$T" && . "$BACKEND"
  journal_append() { :; }
  _linear_gql() {
    printf 'QUERY<<%s>>VARS<<%s>>\n' "$1" "${2:-}" >> "$GQLLOG"
    # Every pattern below carries a leading open-paren. bash 3.2, the macOS system bash, mis-parses a
    # bare case pattern inside a command substitution: it reads the pattern-closing paren as the end
    # of the substitution itself. The balanced form parses on bash 3.2 and 5 alike.
    case "$1" in
      (*"id comments { nodes { id body } }"*) echo '{"data":{"issues":{"nodes":[{"id":"iss_7","comments":{"nodes":[{"id":"cmt_mark","body":"📌 queued by alice: sequenced after ENG-9 [1700000000]"}]},"assignee":{"id":"me_viewer"},"state":{"type":"started"}}]}}}' ;;
      (*commentDelete*) echo '{"data":{"commentDelete":{"success":true}}}' ;;
      (*"viewer { id }"*) echo '{"data":{"viewer":{"id":"me_viewer"}}}' ;;
      (*issueUpdate*) echo '{"data":{"issueUpdate":{"success":true}}}' ;;
      (*) echo '{"data":{}}' ;;
    esac
  }
  _BACKEND_RESULT=""
  _backend_unqueue_item ENG-7 alice
  printf 'RESULT=%s\n' "${_BACKEND_RESULT:-}"
)"
grep -q "RESULT=DONE" <<< "$uq_started" || fail "unqueue on started issue should still clear the 📌 ($uq_started)"
grep -q "commentDelete" "$GQLLOG" || fail "unqueue on started issue should still commentDelete"
grep -q "issueUpdate" "$GQLLOG" && fail "unqueue on started issue must NOT clear the claim assignee via issueUpdate"
pass

# 8d-inbox. HERD-184 list_inbox_comments → reads comments on issues assigned to the viewer (isMe) and
#     prints ONE TSV line ("#<id>\t<author>\t<comment-id>\t<snippet>") per comment by ANOTHER operator,
#     excluding the viewer's OWN comment (cin_self) and the 📌 planned marker (cin_mark).
: > "$GQLLOG"
ic="$(run _backend_list_inbox_comments)"
grep -q 'assignee: { isMe: { eq: true }' "$GQLLOG" || fail "list_inbox_comments did not scope to the viewer's own assigned items"
grep -q "comments(first: 50)" "$GQLLOG" || fail "list_inbox_comments did not request per-issue comments with author + id"
grep -q "^#ENG-7${TAB}Dana${TAB}cin_1${TAB}please rebase before we merge$" <<< "$ic" \
  || fail "list_inbox_comments did not emit the cross-operator comment TSV ($ic)"
grep -q "cin_self" <<< "$ic" && fail "list_inbox_comments surfaced the viewer's OWN comment ($ic)"
grep -q "cin_mark" <<< "$ic" && fail "list_inbox_comments surfaced a 📌 planned marker ($ic)"
pass

# 8e. HERD-85 attribution — a queue write journals ONE tracker_write with requested 'queued' and the
#     component from HERD_COMPONENT (the CLI sets it to 'plan').
: > "$JLOG"
HERD_COMPONENT=plan run _backend_queue_item ENG-7 alice ENG-9 >/dev/null
tw="$(grep '^tracker_write ' "$JLOG")"
grep -q "requested queued" <<< "$tw" || fail "queue_item tracker_write missing 'requested queued' ($tw)"
grep -q "component plan" <<< "$tw" || fail "queue_item did not attribute the 'plan' component ($tw)"
grep -q "result DONE" <<< "$tw" || fail "queue_item did not record the result ($tw)"
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

# 7. HERD-504: the curl round-trip is time-bounded, so a black-holed connection cannot hang forever.
: > "$CURLLOG"
( cd "$T" && . "$BACKEND"; _linear_gql 'query { __typename }' '{}' >/dev/null )
grep -q -- "--max-time 10" "$CURLLOG" || fail "_linear_gql's curl call is missing --max-time (HERD-504 timeout hardening)"
pass

# HERD-504 fork-pressure hardening: a fake python3 that logs every invocation to PYLOG and, when
# LINEAR_PY_FAIL=1, exits 1 without ever running (simulating a fork that fails under load) instead of
# building the request payload. Delegates to the REAL python3 (captured before $T/bin joins PATH) so
# the happy-path call still gets a correctly-built payload.
REAL_PYTHON3="$(command -v python3)"
PYLOG="$T/python3.log"
cat > "$T/bin/python3" <<EOF
#!/usr/bin/env bash
echo call >> "$PYLOG"
[ "\${LINEAR_PY_FAIL:-0}" = "1" ] && exit 1
exec "$REAL_PYTHON3" "\$@"
EOF
chmod +x "$T/bin/python3"
hash -r   # earlier direct `python3 -c` calls above hashed the real path; force a fresh PATH lookup

# 8. HERD-504 happy path stays byte-identical: a successful payload build costs exactly ONE python3
#    call (no wasted retry) and the request/response are unchanged.
: > "$PYLOG"; : > "$CURLLOG"
out8="$( cd "$T" && . "$BACKEND"; _linear_gql 'query { __typename }' '{}' )"
[ "$(wc -l < "$PYLOG" | tr -d ' ')" = "1" ] || fail "happy path should build the payload in ONE python3 call, not retry ($(cat "$PYLOG"))"
grep -q "api.linear.app/graphql" "$CURLLOG" || fail "happy path curl round-trip regressed"
grep -q '"__typename":"Query"' <<<"$out8" || fail "happy path response body changed ($out8)"
pass

# 9. HERD-504 mutation-prove: a python3 that FAILS EVERY TIME (fork pressure that never clears) is
#    retried exactly ONCE before _linear_gql gives up — and it gives up LOCALLY: curl is never
#    invoked (never blames Linear for our own fork pressure), the return code is the distinct 3 (not
#    the generic 1 every other failure path uses), and stderr says this is a local exec failure.
: > "$PYLOG"; : > "$CURLLOG"
set +e
err9="$( cd "$T" && . "$BACKEND"; export LINEAR_PY_FAIL=1; _linear_gql 'query { __typename }' '{}' 2>&1 >/dev/null )"
rc9=$?
set -e
[ "$rc9" = "3" ] || fail "a persistent local payload-build failure should return the distinct code 3, got $rc9 ($err9)"
[ "$(wc -l < "$PYLOG" | tr -d ' ')" = "2" ] || fail "a persistent local failure should retry the payload build exactly once ($(cat "$PYLOG"))"
grep -q "local exec failed under load" <<<"$err9" || fail "local exec failure message missing ($err9)"
[ -s "$CURLLOG" ] && fail "a local payload-build failure must never reach curl — that would blame Linear for our own fork pressure"
pass

# ── HERD-552 / GH #682: verify-after-write + retry-once-via-explicit-id ────────────────────────────
# emberglen-godot saw issueUpdate report success:true on an in-progress→done transition (EMG-126/162/
# 165, all claimed then merged) while the issue's OWN state never actually moved off 'started' — a
# silent no-op only a post-write READBACK exposes. These stubs simulate exactly that: the first
# (type-filtered/name-preferred) pick resolves a DECOY stateId that issueUpdate accepts but never
# actually applies; a readback taken right after still shows 'started'. Each stub is bespoke (not the
# shared `run()` harness) because the readback response must vary BY CALL, which the harness's static
# case dispatch cannot express.

# 10a. no-op on attempt 1 → journaled LOUDLY once with the observed state, retried ONCE via a state id
#      resolved by its own literal name (never the type-filtered pick) → that retry sticks → DONE.
: > "$GQLLOG"; : > "$JLOG"
IUCOUNT="$T/iucount"; RBCOUNT="$T/rbcount"; : > "$IUCOUNT"; : > "$RBCOUNT"
noop_then_heal="$(
  cd "$T" && . "$BACKEND"
  journal_append() { printf '%s\n' "$*" >> "$JLOG"; }
  _linear_gql() {
    printf 'QUERY<<%s>>VARS<<%s>>\n' "$1" "${2:-}" >> "$GQLLOG"
    case "$1" in
      (*issueUpdate*)
        echo x >> "$IUCOUNT"
        echo '{"data":{"issueUpdate":{"success":true}}}' ;;
      (*'name: { eq: "Done" }'*)
        echo '{"data":{"issues":{"nodes":[{"id":"iss_7","identifier":"ENG-7","title":"t","team":{"states":{"nodes":[{"id":"state_explicit","name":"Done"}]}}}]}}}' ;;
      (*"states(filter"*)
        echo '{"data":{"issues":{"nodes":[{"id":"iss_7","identifier":"ENG-7","title":"t","team":{"states":{"nodes":[{"id":"state_decoy","name":"Done","position":1}]}}}]}}}' ;;
      (*"issue(id:"*)
        echo x >> "$RBCOUNT"
        if [ "$(wc -l < "$RBCOUNT" | tr -d ' ')" = "1" ]; then
          echo '{"data":{"issue":{"state":{"type":"started"}}}}'
        else
          echo '{"data":{"issue":{"state":{"type":"completed"}}}}'
        fi ;;
      (*) echo '{"data":{}}' ;;
    esac
  }
  _BACKEND_RESULT=""
  HERD_COMPONENT=reconcile HERD_TW_PR=99 _backend_update_state ENG-7 done
  printf 'RESULT=%s\n' "${_BACKEND_RESULT:-}"
)"
grep -q "RESULT=DONE" <<< "$noop_then_heal" || fail "HERD-552: no-op-then-heal did not eventually report DONE ($noop_then_heal)"
grep -q "state_decoy" "$GQLLOG" || fail "HERD-552: attempt 1 did not use the type-filtered/decoy state id"
grep -q "state_explicit" "$GQLLOG" || fail "HERD-552: retry did not use the explicit-name state id"
grep -q 'name: { eq: "Done" }' "$GQLLOG" || fail "HERD-552: retry did not resolve via a literal-name states filter"
[ "$(wc -l < "$IUCOUNT" | tr -d ' ')" = "2" ] || fail "HERD-552: expected exactly 2 issueUpdate calls (attempt + one retry), got $(cat "$IUCOUNT" | wc -l)"
[ "$(grep -c '^reconcile_transition_failed ' "$JLOG")" = "1" ] || fail "HERD-552: expected exactly one reconcile_transition_failed journal event ($(cat "$JLOG"))"
rtf="$(grep '^reconcile_transition_failed ' "$JLOG")"
grep -q "ref ENG-7" <<< "$rtf" || fail "reconcile_transition_failed missing 'ref ENG-7' ($rtf)"
grep -q "pr 99" <<< "$rtf" || fail "reconcile_transition_failed missing 'pr 99' ($rtf)"
grep -q "observed started" <<< "$rtf" || fail "reconcile_transition_failed missing the observed (non-terminal) state ($rtf)"
pass

# 10b. no-op on attempt 1 AND the retry — bounded per-pass: exactly one retry attempt (never a loop),
#      exactly one journal event (the retry's own failure is not separately journaled), NOCHANGE so
#      the caller's fuzzy-scribe fallback / the periodic tracker-state-sweep can pick it up later.
: > "$GQLLOG"; : > "$JLOG"; : > "$IUCOUNT"
still_stuck="$(
  cd "$T" && . "$BACKEND"
  journal_append() { printf '%s\n' "$*" >> "$JLOG"; }
  _linear_gql() {
    printf 'QUERY<<%s>>VARS<<%s>>\n' "$1" "${2:-}" >> "$GQLLOG"
    case "$1" in
      (*issueUpdate*)
        echo x >> "$IUCOUNT"
        echo '{"data":{"issueUpdate":{"success":true}}}' ;;
      (*'name: { eq: "Done" }'*)
        echo '{"data":{"issues":{"nodes":[{"id":"iss_7","identifier":"ENG-7","title":"t","team":{"states":{"nodes":[{"id":"state_explicit","name":"Done"}]}}}]}}}' ;;
      (*"states(filter"*)
        echo '{"data":{"issues":{"nodes":[{"id":"iss_7","identifier":"ENG-7","title":"t","team":{"states":{"nodes":[{"id":"state_decoy","name":"Done","position":1}]}}}]}}}' ;;
      (*"issue(id:"*) echo '{"data":{"issue":{"state":{"type":"started"}}}}' ;;   # ALWAYS non-terminal
      (*) echo '{"data":{}}' ;;
    esac
  }
  _BACKEND_RESULT=""
  HERD_COMPONENT=reconcile HERD_TW_PR=100 _backend_update_state ENG-7 done
  printf 'RESULT=%s\n' "${_BACKEND_RESULT:-}"
)"
grep -q "RESULT=NOCHANGE" <<< "$still_stuck" || fail "HERD-552: a readback that never confirms should stay NOCHANGE, not falsely report DONE ($still_stuck)"
[ "$(wc -l < "$IUCOUNT" | tr -d ' ')" = "2" ] || fail "HERD-552: a persistently-stuck ref must retry EXACTLY once, not loop ($(cat "$IUCOUNT" | wc -l) issueUpdate calls)"
[ "$(grep -c '^reconcile_transition_failed ' "$JLOG")" = "1" ] || fail "HERD-552: a failed retry must not journal a SECOND reconcile_transition_failed event ($(cat "$JLOG"))"
pass

# 10c. HAPPY PATH stays unchanged: a readback that confirms the terminal type on the FIRST attempt
#      needs no retry at all — one issueUpdate, no reconcile_transition_failed journal, DONE.
: > "$GQLLOG"; : > "$JLOG"; : > "$IUCOUNT"
happy="$(
  cd "$T" && . "$BACKEND"
  journal_append() { printf '%s\n' "$*" >> "$JLOG"; }
  _linear_gql() {
    printf 'QUERY<<%s>>VARS<<%s>>\n' "$1" "${2:-}" >> "$GQLLOG"
    case "$1" in
      (*issueUpdate*)
        echo x >> "$IUCOUNT"
        echo '{"data":{"issueUpdate":{"success":true}}}' ;;
      (*"states(filter"*)
        echo '{"data":{"issues":{"nodes":[{"id":"iss_7","identifier":"ENG-7","title":"t","team":{"states":{"nodes":[{"id":"state_done","name":"Done","position":1}]}}}]}}}' ;;
      (*"issue(id:"*) echo '{"data":{"issue":{"state":{"type":"completed"}}}}' ;;
      (*) echo '{"data":{}}' ;;
    esac
  }
  _BACKEND_RESULT=""
  _backend_update_state ENG-7 done
  printf 'RESULT=%s\n' "${_BACKEND_RESULT:-}"
)"
grep -q "RESULT=DONE" <<< "$happy" || fail "HERD-552: a confirmed-terminal readback on attempt 1 should still report DONE ($happy)"
[ "$(wc -l < "$IUCOUNT" | tr -d ' ')" = "1" ] || fail "HERD-552: a clean transition must NOT retry ($(cat "$IUCOUNT" | wc -l) issueUpdate calls)"
grep -q "^reconcile_transition_failed " "$JLOG" && fail "HERD-552: a clean transition must not journal reconcile_transition_failed ($(cat "$JLOG"))"
pass

echo "ALL PASS ($PASS checks)"
