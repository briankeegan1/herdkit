#!/usr/bin/env bash
# test-backend-github.sh — hermetic test of the GitHub-Issues work-tracker backend's 3-op
# contract using a FAKE `gh` on PATH. No network, no real gh, no repo writes. The stub logs every
# invocation and returns canned output, so the test asserts CALL SHAPE (not GitHub behavior).
#
# HERD-534 / GH #651+#652: this backend now targets TRACKER_REPO exclusively — NEVER HERD_REPO
# (reserved for herd report / oss-triage cross-repo escalation). Cases 0/0b are the regression guard
# for the original contamination bug (a project with HERD_REPO configured had its OWN tracker ops
# silently target that OTHER repo). Case 8 covers the new rich TSV op (LEG B, GH #652).
# Run:  bash tests/test-backend-github.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BACKEND="$HERE/../scripts/herd/backends/github.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass(){ PASS=$((PASS+1)); }

# Fake gh: logs its args to $T/gh.log and emits canned output keyed on "<noun> <verb>".
# HERD-244: issue view returns assignees (empty by default so plan-set-assignee runs); `api` covers
# issue comments list/delete for unqueue/list_queued.
GHLOG="$T/gh.log"
mkdir -p "$T/bin"
cat > "$T/bin/gh" <<EOF
#!/usr/bin/env bash
echo "gh \$*" >> "$GHLOG"
# \`api\` is a single-token verb (path is \$2 or later) — handle it before "\$1 \$2" noun/verb pairs.
if [ "\$1" = "api" ]; then
  if [ "\$2" = "user" ]; then echo "alice"; exit 0; fi
  args="\$*"
  case "\$args" in
    *"issues/comments/"*) exit 0 ;;   # DELETE — succeed silently
    *"/issues/7/comments"*)
      printf '%s' '[{"id":701,"body":"📌 queued by alice: sequenced after 9 [1700000000]"},{"id":702,"body":"unrelated note"}]'
      ;;
    *"issues/"*"/comments"*) printf '[]' ;;
    *) : ;;
  esac
  exit 0
fi
case "\$1 \$2" in
  "issue create")  echo "https://github.com/acme/widgets/issues/42" ;;
  "issue list")    printf '%s' '[{"number":7,"title":"first open issue"},{"number":9,"title":"second open issue"}]' ;;
  "issue comment") : ;;
  "issue close")   : ;;
  "issue edit")    : ;;
  "issue view")
    _vnum=""
    for _va in "\$@"; do
      [ -z "\${_va##*[!0-9]*}" ] || { _vnum="\$_va"; break; }
    done
    case "\$_vnum" in
      7)  printf '{"state":"OPEN","number":7,"assignees":[]}\n'   ;;
      42) printf '{"state":"CLOSED","number":42,"assignees":[]}\n' ;;
      *)  printf '{"state":"OPEN","number":0,"assignees":[]}\n'    ;;
    esac
    ;;
  *) : ;;
esac
EOF
chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH"

# The backend reads $TRACKER_REPO from config; set it so every op should target this repo.
export TRACKER_REPO="acme/widgets"

run() {
  ( cd "$T" && . "$BACKEND"
    _BACKEND_RESULT=""
    ITEM_STATE=""
    "$@"
    printf 'RESULT=%s\n' "${_BACKEND_RESULT:-}"
    printf 'ITEM_STATE=%s\n' "${ITEM_STATE:-}" )
}

# 0. HERD-534 / GH #651 (LEG A) regression guard: HERD_REPO set to a DIFFERENT repo than
#    TRACKER_REPO must NEVER leak into a tracker op's -R flag — the exact cross-project
#    contamination bug (a project's OWN backlog silently filed onto its escalation target).
: > "$GHLOG"
out0="$( ( cd "$T" && HERD_REPO="briankeegan1/herdkit" . "$BACKEND"
  _BACKEND_RESULT=""
  _backend_add_item REQ0 "add item while HERD_REPO points elsewhere" >/dev/null
  printf 'RESULT=%s\n' "${_BACKEND_RESULT:-}" ) )"
grep -q "RESULT=DONE" <<< "$out0" || fail "add_item under a foreign HERD_REPO did not report DONE ($out0)"
grep -q -- "-R acme/widgets" "$GHLOG" || fail "add_item did not target TRACKER_REPO (-R acme/widgets) ($GHLOG: $(cat "$GHLOG"))"
grep -q -- "-R briankeegan1/herdkit" "$GHLOG" && fail "add_item leaked HERD_REPO (-R briankeegan1/herdkit) into a tracker op — the HERD-534 contamination bug"
pass

# 0b. TRACKER_REPO unset entirely → no -R flag at all, so `gh` resolves the repo itself from the
#     CWD's origin remote — a project whose origin IS its tracker stays byte-identical. HERD_REPO
#     being set must not change this either (the backend never reads it).
: > "$GHLOG"
outu0="$( ( cd "$T" && unset TRACKER_REPO; HERD_REPO="briankeegan1/herdkit"; . "$BACKEND"
  _BACKEND_RESULT=""
  _backend_list_open >/dev/null
  printf 'RESULT=%s\n' "${_BACKEND_RESULT:-}" ) )"
grep -q -- "-R " "$GHLOG" && fail "list_open with TRACKER_REPO unset must pass NO -R flag ($GHLOG: $(cat "$GHLOG"))"
grep -q "^gh issue list --state open" "$GHLOG" || fail "list_open with TRACKER_REPO unset did not run a bare 'gh issue list --state open' ($(cat "$GHLOG"))"
pass

# 1. add_item → gh issue create with the configured repo, title, and body; returns DONE + URL.
: > "$GHLOG"
out="$(run _backend_add_item REQ1 "add a dark-mode toggle")"
grep -q "RESULT=DONE" <<< "$out" || fail "add_item did not report DONE ($out)"
grep -q "https://github.com/acme/widgets/issues/42" <<< "$out" || fail "add_item did not surface the created issue URL"
grep -q "issue create" "$GHLOG" || fail "add_item did not invoke 'gh issue create'"
grep -q -- "-R acme/widgets" "$GHLOG" || fail "add_item did not target TRACKER_REPO (-R acme/widgets)"
grep -q -- "--title add a dark-mode toggle" "$GHLOG" || fail "add_item did not pass the request as --title"
grep -q -- "--body add a dark-mode toggle" "$GHLOG" || fail "add_item did not pass the request as --body"
pass

# 2. list_open → parses the canned `gh issue list` JSON to "#<number> <title>" lines.
open="$(run _backend_list_open)"
grep -q -- "issue list -R acme/widgets --state open" "$GHLOG" || fail "list_open did not invoke 'gh issue list --state open' on TRACKER_REPO"
grep -q "^#7 first open issue$" <<< "$open" || fail "list_open missing '#7 first open issue' ($open)"
grep -q "^#9 second open issue$" <<< "$open" || fail "list_open missing '#9 second open issue'"
pass

# 3. mark_shipped → comments the PR link then closes the matching issue (numeric slug = number).
: > "$GHLOG"   # reset log so we assert only this op's calls
ship="$(run _backend_mark_shipped 7 https://github.com/acme/widgets/pull/3)"
grep -q "RESULT=DONE" <<< "$ship" || fail "mark_shipped did not report DONE ($ship)"
grep -q -- "issue comment -R acme/widgets 7" "$GHLOG" || fail "mark_shipped did not comment on issue 7"
grep -q -- "--body Shipped via https://github.com/acme/widgets/pull/3" "$GHLOG" \
  || fail "mark_shipped did not link the PR in the comment body"
grep -q -- "issue close -R acme/widgets 7" "$GHLOG" || fail "mark_shipped did not close issue 7"
pass

# 4. item_state → CLOSED issue returns ITEM_STATE=closed.
: > "$GHLOG"
out="$(run _backend_item_state "provider-lib#42")"
grep -q "ITEM_STATE=closed" <<< "$out" || fail "_backend_item_state CLOSED did not return ITEM_STATE=closed ($out)"
grep -q -- "issue view -R acme/widgets 42" "$GHLOG" || fail "_backend_item_state did not call 'gh issue view'"
pass

# 5. item_state → OPEN issue returns ITEM_STATE=open.
out="$(run _backend_item_state "provider-lib#7")"
grep -q "ITEM_STATE=open" <<< "$out" || fail "_backend_item_state OPEN did not return ITEM_STATE=open ($out)"
pass

# 5a. HERD-502 mutation-prove: a ref that matches NO open issue at all (identifier or title search)
#     must return non-zero from _backend_item_state with ITEM_STATE left UNSET — NOT silently
#     "open". Before this fix, item_state bypassed _github_resolve_issue entirely (a bare
#     `${ref#*#}` fed straight into `gh issue view`) and defaulted to OPEN on ANY failure — the live
#     'full-auto'/#606-shaped incident: a non-numeric, unresolvable slug read as a confirmed-open
#     item forever instead of surfacing as unknown. Reverting the fix makes this fail.
cp "$T/bin/gh" "$T/bin/gh.saved"
cat > "$T/bin/gh" <<'EOF2'
#!/usr/bin/env bash
case "$1 $2" in
  "issue list") printf '[]' ;;   # nothing matches ANY title search — proves the total-failure path
  *) : ;;
esac
EOF2
chmod +x "$T/bin/gh"
outu="$( ( cd "$T" && . "$BACKEND"
  ITEM_STATE="PRESET"
  if _backend_item_state "full-auto"; then rc=0; else rc=1; fi
  printf 'RC=%s\nITEM_STATE=%s\n' "$rc" "${ITEM_STATE:-}" ) )"
grep -q "^RC=1$" <<< "$outu" || fail "HERD-502 mutation-prove: an unresolvable ref must return non-zero from _backend_item_state ($outu)"
grep -q "^ITEM_STATE=$" <<< "$outu" || fail "HERD-502 mutation-prove: an unresolvable ref must leave ITEM_STATE unset, not default to open ($outu)"
cp "$T/bin/gh.saved" "$T/bin/gh"
pass

# 5b. update_state (done) → closes the resolved issue with reason "completed"; never creates one.
#     (Intent dispatch, gh #139: a state change transitions the EXISTING issue, not a new one.)
: > "$GHLOG"
us="$(run _backend_update_state 7 done)"
grep -q "RESULT=DONE" <<< "$us" || fail "update_state did not report DONE ($us)"
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
grep -q "RESULT=NOCHANGE" <<< "$us2" || fail "update_state on an unknown state should be NOCHANGE ($us2)"
grep -q -- "issue close"  "$GHLOG" && fail "update_state on an unknown state should not close the issue"
grep -q -- "issue reopen" "$GHLOG" && fail "update_state on an unknown state should not reopen the issue"
pass

# 6. absent gh degrades loudly (no silent success).
if ( cd "$T"; export PATH="/nonexistent"; . "$BACKEND"; _backend_list_open ) >/dev/null 2>&1; then
  fail "list_open should fail when gh is absent"
fi
pass

# 7. HERD-52/HERD-244 queue_item → posts a 📌 comment AND --add-assignee the operator (first-class
#    GitHub field). Reports DONE off the comment write.
: > "$GHLOG"
q="$(run _backend_queue_item 7 alice 9)"
grep -q "RESULT=DONE" <<< "$q" || fail "queue_item did not report DONE ($q)"
grep -q -- "issue comment -R acme/widgets 7" "$GHLOG" || fail "queue_item did not post a comment on issue 7"
grep -q "queued by alice" "$GHLOG" || fail "queue_item marker did not name the operator"
grep -q "sequenced after 9" "$GHLOG" || fail "queue_item marker did not record the blocker"
grep -q -- "issue edit -R acme/widgets 7 --add-assignee alice" "$GHLOG" \
  || fail "queue_item (HERD-244) did not --add-assignee the operator ($(cat "$GHLOG"))"
pass

# 7a. unqueue_item → DELETE's only the 📌 comment (id 701), never the unrelated one (702), and
#     --remove-assignee when the plan-time assignee is still us.
: > "$GHLOG"
# Seed assignees so clear-assignee sees us as currently assigned.
cat > "$T/bin/gh" <<EOF
#!/usr/bin/env bash
echo "gh \$*" >> "$GHLOG"
if [ "\$1" = "api" ]; then
  args="\$*"
  case "\$args" in
    *"issues/comments/"*) exit 0 ;;
    *"/issues/7/comments"*)
      printf '%s' '[{"id":701,"body":"📌 queued by alice: sequenced after 9 [1700000000]"},{"id":702,"body":"unrelated note"}]' ;;
    *) : ;;
  esac
  exit 0
fi
case "\$1 \$2" in
  "issue view") printf '{"state":"OPEN","number":7,"assignees":[{"login":"alice"}]}\n' ;;
  "issue edit") : ;;
  *) : ;;
esac
EOF
chmod +x "$T/bin/gh"
uq="$(run _backend_unqueue_item 7 alice)"
grep -q "RESULT=DONE" <<< "$uq" || fail "unqueue_item did not report DONE ($uq)"
grep -q -- "issues/comments/701" "$GHLOG" || fail "unqueue_item did not DELETE the 📌 comment (701)"
grep -q -- "issues/comments/702" "$GHLOG" && fail "unqueue_item deleted a non-marker comment (702)"
grep -q -- "--remove-assignee alice" "$GHLOG" \
  || fail "unqueue_item (HERD-244) did not --remove-assignee the operator ($(cat "$GHLOG"))"
pass

# 7b. list_queued → one TSV line per 📌 marker across open issues.
: > "$GHLOG"
cat > "$T/bin/gh" <<EOF
#!/usr/bin/env bash
echo "gh \$*" >> "$GHLOG"
if [ "\$1" = "api" ]; then
  args="\$*"
  case "\$args" in
    *"/issues/7/comments"*)
      printf '%s' '[{"id":701,"body":"📌 queued by alice: sequenced after 9 [1700000000]"}]' ;;
    *) printf '[]' ;;
  esac
  exit 0
fi
case "\$1 \$2" in
  "issue list") printf '%s' '[{"number":7,"title":"first open issue"},{"number":9,"title":"second open issue"}]' ;;
  *) : ;;
esac
EOF
chmod +x "$T/bin/gh"
TAB="$(printf '\t')"
lq="$(run _backend_list_queued)"
grep -q "^#7${TAB}alice${TAB}sequenced after 9${TAB}1700000000$" <<< "$lq" \
  || fail "list_queued did not emit the parsed marker TSV for #7 ($lq)"
grep -q "^#9" <<< "$lq" && fail "list_queued surfaced #9 which carries no 📌 marker ($lq)"
pass

# 8. LEG B (GH #652) — _backend_list_open_rich matches backends/linear.sh's TSV shape:
#    "#<id>\t<state-type>\t<state-name>\t<title>\t<desc>\t<assignee>\t<url>". The issue body is
#    fetched in the SAME gh issue list --json call (no extra round-trip), flattened, and truncated
#    to ~180 chars (shorter than linear's 280 cap).
: > "$GHLOG"
LONGBODY="$(python3 -c 'print("word " * 60, end="")')"
cat > "$T/bin/gh" <<EOF
#!/usr/bin/env bash
echo "gh \$*" >> "$GHLOG"
case "\$1 \$2" in
  "issue list")
    printf '%s' '[{"number":7,"title":"first open issue","body":"line one\nline two with\ttabs","assignees":[{"login":"alice"}],"url":"https://github.com/acme/widgets/issues/7"},{"number":9,"title":"second open issue","body":"$LONGBODY","assignees":[],"url":"https://github.com/acme/widgets/issues/9"}]'
    ;;
  *) : ;;
esac
EOF
chmod +x "$T/bin/gh"
rich="$(run _backend_list_open_rich)"
grep -q -- "issue list -R acme/widgets --state open" "$GHLOG" \
  || fail "list_open_rich did not invoke 'gh issue list --state open' on TRACKER_REPO"
grep -q -- "number,title,body,assignees,url" "$GHLOG" \
  || fail "list_open_rich did not fetch the body in the SAME --json call ($(cat "$GHLOG"))"
line7="$(printf '%s\n' "$rich" | grep '^#7')"
[ -n "$line7" ] || fail "list_open_rich missing a row for #7 ($rich)"
grep -qF -- "$(printf '#7\t\t\tfirst open issue\tline one line two with tabs\talice\thttps://github.com/acme/widgets/issues/7')" <<< "$line7" \
  || fail "list_open_rich #7 row did not match the linear TSV shape (id/state-type/state-name/title/desc/assignee/url): $line7"
line9="$(printf '%s\n' "$rich" | grep '^#9')"
[ -n "$line9" ] || fail "list_open_rich missing a row for #9 ($rich)"
desc9="$(printf '%s' "$line9" | cut -f5)"
[ "${#desc9}" -le 180 ] || fail "list_open_rich did not cap the description at ~180 chars (got ${#desc9})"
case "$desc9" in *…) ;; *) fail "list_open_rich truncated description missing the ellipsis marker ($desc9)" ;; esac
pass

echo "ALL PASS ($PASS checks)"
