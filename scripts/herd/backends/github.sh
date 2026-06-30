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
