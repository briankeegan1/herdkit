#!/usr/bin/env bash
# backends/github.sh — SCRIBE_BACKEND=github implementation (GitHub Issues work tracker).
#
# Instead of a tracked file in the repo, work items live as GitHub Issues. New items become
# open issues, "shipped" closes the matching issue (with a comment linking the PR/SHA), and
# "open" is the live `gh issue list --state open`. Like the changelog/API backends the agent
# does NOT edit any file — scribe-step.sh dispatches the request text here via the add-item path.
#
# Sourced from scribe-step.sh after herd-config.sh (so $HERD_REPO is in scope) with $REPO as CWD.
# Implements the same three-op contract as backends/file.sh:
#   _backend_add_item REQ_ID TEXT     — gh issue create; sets _BACKEND_RESULT=DONE|NOCHANGE
#   _backend_mark_shipped SLUG PR_URL — gh issue close + linking comment
#   _backend_list_open                — gh issue list --state open, one "#<n> <title>" line each
#
# Repo selection: $HERD_REPO (<owner>/<repo>) when configured, else gh falls back to the current
# repo's default. Requires the GitHub CLI (`gh`); degrades with a clear error if it is absent.

_github_require_gh() {
    command -v gh >/dev/null 2>&1 || {
        echo "github backend: 'gh' CLI not found — install GitHub CLI (or switch SCRIBE_BACKEND)" >&2
        exit 1
    }
}

_gh() {
    # Run a `gh <noun> <verb> …` command with the configured repo flag injected right after the
    # verb. When $HERD_REPO is empty, gh uses the current repo's default. Keeping the -R injection
    # here means every op targets the same repo without each call repeating the conditional.
    if [ -n "${HERD_REPO:-}" ]; then
        gh "$1" "$2" -R "$HERD_REPO" "${@:3}"
    else
        gh "$@"
    fi
}

_github_resolve_issue() {
    # Map an item slug to an open issue NUMBER. A purely-numeric slug (optionally "#123") is the
    # issue number directly; otherwise search open issue titles and take the first match. Prints
    # the number (empty if none found).
    local slug="$1" n="${1#\#}"
    case "$n" in
        ''|*[!0-9]*) ;;                      # not purely numeric → fall through to search
        *) printf '%s' "$n"; return 0 ;;
    esac
    _gh issue list --state open --search "$slug in:title" --json number 2>/dev/null \
      | python3 -c 'import sys, json
try: d = json.load(sys.stdin)
except Exception: d = []
print(d[0]["number"] if d else "")' 2>/dev/null
}

_backend_add_item() {
    # $1 = claimed queue file path (REQ_ID, unused here); $2 = item text / summary.
    # Title = the first line of the request; body = the full text. Sets _BACKEND_RESULT=DONE on a
    # created issue, NOCHANGE if gh declines (so the scribe receipt still reports honestly).
    local text="$2" title body url
    _github_require_gh
    title="$(printf '%s' "$text" | head -n1)"
    body="$text"
    if url="$(_gh issue create --title "$title" --body "$body" 2>/dev/null)"; then
        _BACKEND_RESULT="DONE"
        [ -n "$url" ] && printf '%s\n' "$url"
    else
        _BACKEND_RESULT="NOCHANGE"
    fi
}

_backend_mark_shipped() {
    # $1 = item slug (issue number or a title to search); $2 = PR URL / SHA.
    # Comment the shipped link onto the issue, then close it as completed. Mirrors how the file
    # backend stamps an item shipped. Sets _BACKEND_RESULT=DONE|NOCHANGE.
    local slug="$1" pr="$2" num
    _github_require_gh
    num="$(_github_resolve_issue "$slug")"
    if [ -z "$num" ]; then
        echo "github backend: no open issue matching '$slug' — nothing to close" >&2
        _BACKEND_RESULT="NOCHANGE"
        return 0
    fi
    _gh issue comment "$num" --body "Shipped via ${pr}" >/dev/null 2>&1 || true
    _gh issue close "$num" --reason completed >/dev/null 2>&1 || true
    _BACKEND_RESULT="DONE"
}

_backend_update_state() {
    # $1 = item ref (issue number, "#42", or a title to search); $2 = target state
    # (done|in-progress|canceled + synonyms). Intent-dispatch path (gh #139): transition an EXISTING
    # issue instead of filing a new one. GitHub issues are open/closed only, so:
    #   done      → close with reason "completed"
    #   canceled  → close with reason "not planned"
    #   in-progress → ensure the issue is OPEN (reopen if closed) + a marker comment; GitHub has no
    #                 native in-progress state, and item_state maps only open/closed.
    # Sets _BACKEND_RESULT=DONE|NOCHANGE; an unknown state or no matching issue files NOTHING.
    local ref="$1" want="$2" num
    _github_require_gh
    num="$(_github_resolve_issue "$ref")"
    if [ -z "$num" ]; then
        echo "github backend: no open issue matching '$ref' — state unchanged (skipping, not filing)" >&2
        _BACKEND_RESULT="NOCHANGE"
        return 0
    fi
    case "$want" in
        done|complete|completed|shipped|merged|closed|resolved)
            _gh issue close "$num" --reason completed >/dev/null 2>&1 || true ;;
        cancel|canceled|cancelled|wontfix|"won't fix"|declined|dropped|obsolete)
            _gh issue close "$num" --reason "not planned" >/dev/null 2>&1 || true ;;
        in-progress|inprogress|in_progress|started|doing|wip|active)
            _gh issue reopen "$num" >/dev/null 2>&1 || true
            _gh issue comment "$num" --body "Marked in-progress" >/dev/null 2>&1 || true ;;
        *)
            echo "github backend: unknown target state '$want' — expected done|in-progress|canceled (skipping, not filing)" >&2
            _BACKEND_RESULT="NOCHANGE"
            return 0 ;;
    esac
    _BACKEND_RESULT="DONE"
}

_backend_list_open() {
    # Print open issues as one "#<number> <title>" line each — the same human-readable one-line
    # shape the file/changelog backends emit, so the coordinator's issue-source reads them alike.
    _github_require_gh
    _gh issue list --state open --json number,title 2>/dev/null \
      | python3 -c 'import sys, json
try: data = json.load(sys.stdin)
except Exception: data = []
for it in data:
    print("#%s %s" % (it.get("number", ""), it.get("title", "")))' 2>/dev/null || true
}

_backend_item_state() {
    # $1 = <link-name>#<id> — caller has resolved the link; HERD_REPO is already set.
    # Queries the issue state and sets ITEM_STATE=open|closed.
    # GitHub issues have no native in-progress state; OPEN maps to open, CLOSED to closed.
    local ref="$1" num raw
    _github_require_gh
    num="${ref#*#}"
    raw="$(_gh issue view "$num" --json state 2>/dev/null \
            | python3 -c 'import sys,json; print(json.load(sys.stdin).get("state","OPEN").upper())' \
              2>/dev/null \
            || printf 'OPEN')"
    case "$raw" in
        CLOSED) ITEM_STATE="closed" ;;
        *)      ITEM_STATE="open"   ;;
    esac
}

# _backend_claim_item REF WHO — atomic-ish pre-spawn claim (HERD-50). The claim marker on GitHub is
# the issue ASSIGNEE. Read state+assignees SYNCHRONOUSLY; abort if the issue is closed (already
# shipped) or already assigned to a DIFFERENT login; else add WHO as an assignee and RE-READ to verify
# the claim stuck. GitHub has no compare-and-swap AND allows multiple assignees, so the re-read is what
# narrows a concurrent-claim race: if a competing assignee appeared in the window we back off. Sets:
#   _CLAIM_RESULT = CLAIMED | SELF (already assigned to us) | ALREADY (closed / another assignee) |
#                   UNREACHABLE (no matching issue / gh read failed → caller fails soft)
#   _CLAIM_OWNER  = the blocking login (for the abort message)
# RESIDUAL RACE (documented honestly): two claimers can both add themselves as assignees between the
# read and the verify; the verify catches the common case (the other landed first) and backs off, but
# a truly simultaneous double-assign can leave both assigned — the window is a couple of API
# round-trips (seconds), not the async-scribe minutes.
_backend_claim_item() {
    local ref="$1" who="$2" num info parsed state other mine
    _CLAIM_RESULT=""; _CLAIM_OWNER=""
    _github_require_gh
    [ -n "$who" ] || who="$(gh api user -q .login 2>/dev/null || true)"
    [ -n "$who" ] || who="@me"
    num="$(_github_resolve_issue "$ref")"
    if [ -z "$num" ]; then _CLAIM_RESULT="UNREACHABLE"; return 0; fi

    info="$(_gh issue view "$num" --json state,assignees 2>/dev/null)" || { _CLAIM_RESULT="UNREACHABLE"; return 0; }
    [ -n "$info" ] || { _CLAIM_RESULT="UNREACHABLE"; return 0; }
    # "<STATE>\t<other-assignee>\t<mine 0|1>": other = first assignee that is NOT us (a competing claim).
    parsed="$(printf '%s' "$info" | WHO="$who" python3 -c 'import sys, json, os
who = os.environ["WHO"]
try: d = json.load(sys.stdin)
except Exception: d = {}
st = (d.get("state") or "OPEN").upper()
asg = [a.get("login", "") for a in (d.get("assignees") or [])]
other = next((a for a in asg if a and a != who), "")
mine = "1" if who in asg else "0"
print("%s\t%s\t%s" % (st, other, mine))' 2>/dev/null)"
    state="${parsed%%	*}"; parsed="${parsed#*	}"
    other="${parsed%%	*}"; mine="${parsed##*	}"

    if [ "$state" = "CLOSED" ]; then _CLAIM_RESULT="ALREADY"; _CLAIM_OWNER="${other:-closed}"; return 0; fi
    if [ -n "$other" ];       then _CLAIM_RESULT="ALREADY"; _CLAIM_OWNER="$other";           return 0; fi
    if [ "$mine" = "1" ];     then _CLAIM_RESULT="SELF";    _CLAIM_OWNER="$who";              return 0; fi

    # Open + unassigned → claim it: assign ourselves.
    if ! _gh issue edit "$num" --add-assignee "$who" >/dev/null 2>&1; then
        _CLAIM_RESULT="UNREACHABLE"; return 0
    fi
    # CLAIM-VERIFY: re-read to confirm no competing assignee slipped in during the window.
    info="$(_gh issue view "$num" --json state,assignees 2>/dev/null)" || { _CLAIM_RESULT="CLAIMED"; _CLAIM_OWNER="$who"; return 0; }
    parsed="$(printf '%s' "$info" | WHO="$who" python3 -c 'import sys, json, os
who = os.environ["WHO"]
try: d = json.load(sys.stdin)
except Exception: d = {}
asg = [a.get("login", "") for a in (d.get("assignees") or [])]
print(next((a for a in asg if a and a != who), ""))' 2>/dev/null)"
    if [ -n "$parsed" ]; then
        _CLAIM_RESULT="ALREADY"; _CLAIM_OWNER="$parsed"
    else
        _CLAIM_RESULT="CLAIMED"; _CLAIM_OWNER="$who"
    fi
}
