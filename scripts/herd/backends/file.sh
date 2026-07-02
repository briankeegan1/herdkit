#!/usr/bin/env bash
# backends/file.sh — SCRIBE_BACKEND=file implementation (the default; zero-secret).
#
# The agent edits $BACKLOG_FILE directly in prose; these functions handle the git
# mechanics that follow. Sourced from scribe-step.sh after herd-config.sh has loaded
# (so $BACKLOG_FILE, $DEFAULT_BRANCH, $HERD_REMOTE, $HERD_BRANCH_NAME are in scope) and
# with $REPO as CWD. Every backend implements the same four-op contract:
#   _backend_add_item REQ_ID TEXT     — create/commit a new item
#   _backend_mark_shipped SLUG PR_URL — reap/stamp a shipped item
#   _backend_list_open                — print open items
#   _backend_item_state REF           — sets ITEM_STATE=open|closed|in-progress

# _backend_archive_shipped — keep BACKLOG.md lean by rotating shipped (✅) entries out of the
# "## Recently shipped" section once it grows past the most recent SHIPPED_KEEP (default 10).
# Overflow entries move to <BACKLOG_FILE stem>.archive.md (e.g. BACKLOG.archive.md) — a committed
# file the coordinator and builders NEVER read, so the per-turn BACKLOG.md read the coordinator pays
# every turn stays bounded. Purely mechanical + idempotent: a no-op when the section has ≤ the cap,
# so it runs safely on every scribe commit regardless of what the request was. Newest entries stay
# in BACKLOG.md (they are prepended under the heading); the oldest overflow is what rotates out.
_backend_archive_shipped() {
    local keep="${SHIPPED_KEEP:-10}"
    local archive="${BACKLOG_FILE%.md}.archive.md"
    [ -f "$BACKLOG_FILE" ] || return 0
    BACKLOG_FILE="$BACKLOG_FILE" ARCHIVE_FILE="$archive" SHIPPED_KEEP="$keep" \
      ARCHIVE_HEADER="# herdkit — backlog archive (shipped ✅ items rotated out of $BACKLOG_FILE to keep it lean; the coordinator and builders never read this file)" \
      python3 - <<'PY'
import os, sys

backlog = os.environ["BACKLOG_FILE"]
archive = os.environ["ARCHIVE_FILE"]
keep    = int(os.environ.get("SHIPPED_KEEP", "10") or "10")
header  = os.environ["ARCHIVE_HEADER"]

with open(backlog, encoding="utf-8") as f:
    lines = f.readlines()

# Locate the "## Recently shipped" heading. Absent → nothing to archive.
hdr = next((i for i, ln in enumerate(lines) if ln.strip() == "## Recently shipped"), None)
if hdr is None:
    sys.exit(0)

# Section body runs from just after the heading to the next "## " heading (or EOF).
end = len(lines)
for j in range(hdr + 1, len(lines)):
    if lines[j].startswith("## "):
        end = j
        break

def is_entry(ln):
    return ln.lstrip().startswith("- ✅")   # a shipped list item ("- ✅ …")

kept, overflow, seen = [], [], 0
for ln in lines[hdr + 1:end]:
    if is_entry(ln):
        seen += 1
        if seen > keep:
            overflow.append(ln)
            continue
    kept.append(ln)

if not overflow:
    sys.exit(0)   # at or under the cap — leave both files untouched

# Rewrite BACKLOG.md with the overflow entries removed (format otherwise byte-preserved).
with open(backlog, "w", encoding="utf-8") as f:
    f.writelines(lines[:hdr + 1] + kept + lines[end:])

# Append the overflow (document order: oldest-kept-first) to the archive, creating it with a
# one-line header on first use. Never read by the engine — append-only chronological record.
content = ""
if os.path.exists(archive):
    with open(archive, encoding="utf-8") as f:
        content = f.read()
if not content.strip():
    content = header.rstrip("\n") + "\n\n"
if not content.endswith("\n"):
    content += "\n"
for ln in overflow:
    content += ln if ln.endswith("\n") else ln + "\n"
with open(archive, "w", encoding="utf-8") as f:
    f.write(content)
PY
}

_backend_add_item() {
    # $1 = claimed queue file path (REQ_ID); $2 = short commit summary.
    # The agent has already edited $BACKLOG_FILE. Rotate stale shipped items into the archive,
    # then stage both files, commit, and push. Sets _BACKEND_RESULT=DONE|NOCHANGE.
    local mine="$1" sum="$2"
    _backend_archive_shipped
    git add "$BACKLOG_FILE"
    # The archive file only exists once something has rotated out; stage it when present so the
    # rotation lands in the SAME commit as the backlog edit (never a dangling untracked file).
    [ -f "${BACKLOG_FILE%.md}.archive.md" ] && git add "${BACKLOG_FILE%.md}.archive.md"
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

_backend_item_state() {
    # $1 = <link-name>#<id> or a title slug.  BACKLOG_FILE is already set.
    # Greps the slug from BACKLOG_FILE; checks for 🔜/🚧/✅ emoji → maps to open/in-progress/closed.
    # Sets ITEM_STATE=open|closed|in-progress.  Missing slug → open (safe default).
    local ref="$1" slug line
    slug="${ref#*#}"
    line="$(grep -m1 -F "$slug" "$BACKLOG_FILE" 2>/dev/null || true)"
    if [ -z "$line" ]; then
        ITEM_STATE="open"
        return 0
    fi
    case "$line" in
        *✅*) ITEM_STATE="closed"      ;;
        *🚧*) ITEM_STATE="in-progress" ;;
        *)    ITEM_STATE="open"         ;;
    esac
}
