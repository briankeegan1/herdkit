#!/usr/bin/env bash
# backends/file.sh — SCRIBE_BACKEND=file implementation (the default; zero-secret).
#
# The agent edits $BACKLOG_FILE directly in prose; these functions handle the git
# mechanics that follow. Sourced from scribe-step.sh after herd-config.sh has loaded
# (so $BACKLOG_FILE, $DEFAULT_BRANCH, $HERD_REMOTE, $HERD_BRANCH_NAME are in scope) and
# with $REPO as CWD. Every backend implements the same three operations:
#   _backend_add_item REQ_ID TEXT     — create/commit a new item
#   _backend_mark_shipped SLUG PR_URL — reap/stamp a shipped item
#   _backend_list_open                — print open items

_backend_add_item() {
    # $1 = claimed queue file path (REQ_ID); $2 = short commit summary.
    # The agent has already edited $BACKLOG_FILE. Stage it, commit, and push.
    # Sets _BACKEND_RESULT=DONE|NOCHANGE.
    local mine="$1" sum="$2"
    git add "$BACKLOG_FILE"
    if git diff --cached --quiet; then
        _BACKEND_RESULT="NOCHANGE"
    else
        git commit -q -m "Backlog: $sum"
        _BACKEND_RESULT="DONE"
    fi
    # Push any local commit(s) not yet on origin. This covers both a fresh commit and a
    # retry after an earlier push failure left the change committed-but-unpushed (in that
    # case the diff above is empty / NOCHANGE but HEAD is still ahead of origin).
    if [ -n "$(git rev-list "$DEFAULT_BRANCH..HEAD" 2>/dev/null)" ]; then
        if ! git push -q "$HERD_REMOTE" "$HERD_BRANCH_NAME" 2>/dev/null; then
            # Rejected — almost always another scribe pushed first. Rebase onto their work,
            # then retry. FAIL LOUD if either step fails so the commit is never silently lost.
            if ! git pull --rebase --quiet "$HERD_REMOTE" "$HERD_BRANCH_NAME"; then
                git rebase --abort >/dev/null 2>&1 || true
                echo "PUSHFAIL rebase failed (real conflict) — backlog change committed locally but NOT pushed" >&2
                exit 1
            fi
            if ! git push -q "$HERD_REMOTE" "$HERD_BRANCH_NAME"; then
                echo "PUSHFAIL push still rejected after rebase — backlog change committed locally but NOT pushed" >&2
                exit 1
            fi
        fi
    fi
}

_backend_mark_shipped() {
    # $1 = item slug; $2 = PR URL.
    # For the file backend, mark-shipped requests arrive through the normal scribe queue:
    # the agent edits $BACKLOG_FILE and calls scribe-step.sh commit — no separate dispatch
    # needed here. An API backend would call its API instead.
    :
}

_backend_list_open() {
    # Print open backlog items (🔜 queued or 🚧 in-progress).
    grep -E '🔜|🚧' "$BACKLOG_FILE" 2>/dev/null || true
}
