#!/usr/bin/env bash
# backends/changelog.sh — SCRIBE_BACKEND=changelog implementation (zero-secret).
#
# An append-only work tracker: new items accrue under an "## [Unreleased]" heading in
# $BACKLOG_FILE (point BACKLOG_FILE at CHANGELOG.md). Unlike the file backend it does NOT
# reap shipped items in place — a changelog is append-only by design — so mark-shipped is a
# no-op and "open" means "everything currently under [Unreleased]".
#
# Sourced from scribe-step.sh after herd-config.sh (so $BACKLOG_FILE, $DEFAULT_BRANCH,
# $HERD_REMOTE, $HERD_BRANCH_NAME are in scope) with $REPO as CWD. Implements the same
# three-op contract as backends/file.sh.

_changelog_ensure_unreleased() {
    # Make sure an "## [Unreleased]" section exists so add-item has somewhere to append.
    [ -f "$BACKLOG_FILE" ] || printf '# Changelog\n\n## [Unreleased]\n' > "$BACKLOG_FILE"
    grep -qE '^## \[Unreleased\]' "$BACKLOG_FILE" 2>/dev/null || \
        printf '\n## [Unreleased]\n' >> "$BACKLOG_FILE"
}

_backend_add_item() {
    # $1 = claimed queue file path (REQ_ID, unused here); $2 = item text / summary.
    # Append "- <text>" under [Unreleased], commit, and push. Sets _BACKEND_RESULT=DONE.
    local sum="$2"
    _changelog_ensure_unreleased
    # Insert the new bullet immediately after the [Unreleased] heading.
    awk -v line="- $sum" '
        { print }
        /^## \[Unreleased\]/ && !done { print line; done=1 }
    ' "$BACKLOG_FILE" > "$BACKLOG_FILE.tmp" && mv "$BACKLOG_FILE.tmp" "$BACKLOG_FILE"
    git add "$BACKLOG_FILE"
    if git diff --cached --quiet; then
        _BACKEND_RESULT="NOCHANGE"
    else
        git commit -q -m "Changelog: $sum"
        _BACKEND_RESULT="DONE"
    fi
    if [ -n "$(git rev-list "$DEFAULT_BRANCH..HEAD" 2>/dev/null)" ]; then
        if ! git push -q "$HERD_REMOTE" "$HERD_BRANCH_NAME" 2>/dev/null; then
            if ! git pull --rebase --quiet "$HERD_REMOTE" "$HERD_BRANCH_NAME"; then
                git rebase --abort >/dev/null 2>&1 || true
                echo "PUSHFAIL rebase failed — changelog entry committed locally but NOT pushed" >&2
                exit 1
            fi
            git push -q "$HERD_REMOTE" "$HERD_BRANCH_NAME" || {
                echo "PUSHFAIL push still rejected after rebase — changelog entry committed but NOT pushed" >&2
                exit 1
            }
        fi
    fi
}

_backend_mark_shipped() {
    # Append-only tracker: nothing to reap in place. A release process moves [Unreleased]
    # to a versioned heading out of band. No-op so the contract is honored.
    :
}

_backend_update_state() {
    # Append-only tracker: entries move from [Unreleased] to a versioned heading out of band at
    # release time, so there is no in-place state transition to perform. Honor the intent-dispatch
    # contract (gh #139) as an explicit NOCHANGE no-op — crucially, never a fallback that files a new
    # entry for a "mark done" request. $1 = ref, $2 = state (both unused).
    _BACKEND_RESULT="NOCHANGE"
}

_backend_list_open() {
    # Everything under [Unreleased] (until the next "## " heading) is "open".
    awk '
        /^## \[Unreleased\]/ { inblk=1; next }
        /^## / { inblk=0 }
        inblk && /^[*-] / { print }
    ' "$BACKLOG_FILE" 2>/dev/null || true
}

_backend_item_state() {
    # $1 = <link-name>#<id> or a text slug.  BACKLOG_FILE is already set.
    # Slug found under [Unreleased] → open; absent (released or never added) → closed.
    # Sets ITEM_STATE=open|closed.  (changelog backend has no in-progress concept.)
    local ref="$1" slug
    slug="${ref#*#}"
    if awk '
        /^## \[Unreleased\]/ { inblk=1; next }
        /^## / { inblk=0 }
        inblk { print }
    ' "$BACKLOG_FILE" 2>/dev/null | grep -qF "$slug" 2>/dev/null; then
        ITEM_STATE="open"
    else
        ITEM_STATE="closed"
    fi
}

# _backend_claim_item REF WHO — atomic-ish pre-spawn claim (HERD-50). An append-only changelog has
# NO per-item state or assignee to flip (entries only move from [Unreleased] to a versioned heading at
# release time, out of band), so there is nothing to claim atomically. Honor the op contract as an
# explicit FAIL-SOFT no-op: report UNREACHABLE so herd-claim.sh proceeds as unclaimed (the async
# scribe path is unchanged) rather than ever hard-blocking a spawn on a backend that cannot claim.
_backend_claim_item() {
    _CLAIM_RESULT="UNREACHABLE"; _CLAIM_OWNER=""
}
