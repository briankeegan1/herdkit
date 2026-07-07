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

# _backend_tw_journal — HERD-85 tracker-write attribution (mirror of the linear/github backends'). Emit
# ONE journal event per tracker STATE WRITE so `herd log | grep tracker_write` attributes it in one
# line. Attribution is the caller's HERD_COMPONENT ('manual' by default). FAIL-SOFT: a silent no-op when
# journal.sh was never sourced (journal_append undefined) — a journal problem never blocks the write.
# Args: <ref> <requested-state> <result> [pr]   (pr falls back to $HERD_TW_PR when the arg is omitted).
_backend_tw_journal() {
    command -v journal_append >/dev/null 2>&1 || return 0
    local ref="$1" requested="$2" result="$3" pr="${4:-${HERD_TW_PR:-}}"
    if [ -n "$pr" ]; then
        journal_append tracker_write ref "$ref" requested "$requested" \
            component "${HERD_COMPONENT:-manual}" backend file result "$result" pr "$pr"
    else
        journal_append tracker_write ref "$ref" requested "$requested" \
            component "${HERD_COMPONENT:-manual}" backend file result "$result"
    fi
}

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

# _backend_claim_item REF WHO — atomic-ish pre-spawn claim (HERD-50). The file backend has no API
# assignee field, so the claim is a git-committed STATE FLIP on $BACKLOG_FILE: flip the item's line
# 🔜 → 🚧 and stamp "(claimed by <WHO>)". ATOMICITY comes from git PUSH SERIALIZATION — two operators
# who both flip the same line commit different edits, and only ONE push lands; the loser's push is
# rejected, the rebase CONFLICTS on that line, so the loser discards its edit, re-pulls the winner's
# claim, and RE-READS to find the item 🚧 owned by someone else → ALREADY. Sets:
#   _CLAIM_RESULT = CLAIMED (we own it) | SELF (already ours — a re-spawn) | ALREADY (another owner /
#                   shipped) | UNREACHABLE (no backlog / item not found → caller fails soft)
#   _CLAIM_OWNER  = the winning/blocking identity (for the abort message)
#
# RESIDUAL RACE (documented honestly): two claimers that both pull-then-read BEFORE either pushes will
# both attempt the flip; push serialization then lets exactly one win and forces the other to abort
# here. The window is one push round-trip (seconds), not the async-scribe minutes. This is the file
# backend's compare-and-swap equivalent; Linear/GitHub (no CAS) rely on claim-verify instead.
_backend_claim_item() {
    local ref="$1" who="$2" slug parsed status owner
    _CLAIM_RESULT=""; _CLAIM_OWNER=""
    slug="${ref#*#}"
    [ -n "$who" ] || who="unknown-operator"
    [ -f "$BACKLOG_FILE" ] || { _CLAIM_RESULT="UNREACHABLE"; return 0; }

    # Sync to the remote tip first so a competing claim that already landed is visible BEFORE we read
    # and decide. Fail-soft: an offline/failed pull just means we claim against local state (a solo
    # operator with no remote is never blocked by this).
    git pull --rebase --quiet "$HERD_REMOTE" "$HERD_BRANCH_NAME" 2>/dev/null || true

    # Classify the item's current line and, for an OPEN item, flip it to 🚧 + stamp the claimant IN
    # PLACE. Prints "<status>\t<owner>" with status ∈ FLIP|SELF|ALREADY|MISSING (MISSING = slug not in
    # the backlog; ALREADY covers both a 🚧 line owned by another and a ✅ shipped line).
    parsed="$(BACKLOG_FILE="$BACKLOG_FILE" SLUG="$slug" WHO="$who" python3 - <<'PY'
import os, re
backlog = os.environ["BACKLOG_FILE"]; slug = os.environ["SLUG"]; who = os.environ["WHO"]
with open(backlog, encoding="utf-8") as f:
    lines = f.readlines()
idx = next((i for i, l in enumerate(lines) if slug in l), None)
if idx is None:
    print("MISSING\t"); raise SystemExit
line = lines[idx]
m = re.search(r"\(claimed by ([^)]*)\)", line)
owner = m.group(1).strip() if m else ""
if "✅" in line:                      # ✅ shipped — cannot claim a done item
    print("ALREADY\t" + (owner or "a completed item")); raise SystemExit
if owner:                             # an explicit claim marker already exists (any emoji state)
    print(("SELF\t" + owner) if owner == who else ("ALREADY\t" + owner)); raise SystemExit
if "\U0001f6a7" in line:                   # 🚧 in-progress but no claim marker → owned by someone else
    print("ALREADY\tanother operator"); raise SystemExit
# 🔜 open (or a line with no state emoji) → claim it: flip the queue emoji and stamp the claimant.
new = line.replace("\U0001f51c", "\U0001f6a7", 1) if "\U0001f51c" in line else line  # 🔜 → 🚧
if "(claimed by" not in new:
    new = new.rstrip("\n") + " (claimed by %s)\n" % who
lines[idx] = new
with open(backlog, "w", encoding="utf-8") as f:
    f.writelines(lines)
print("FLIP\t" + who)
PY
)"
    status="${parsed%%	*}"; owner="${parsed#*	}"
    case "$status" in
        MISSING) _CLAIM_RESULT="UNREACHABLE"; return 0 ;;
        SELF)    _CLAIM_RESULT="SELF";    _CLAIM_OWNER="$owner"; return 0 ;;
        ALREADY) _CLAIM_RESULT="ALREADY"; _CLAIM_OWNER="$owner"; return 0 ;;
        FLIP)    : ;;   # our edit is staged in the working tree — commit + push below
        *)       _CLAIM_RESULT="UNREACHABLE"; return 0 ;;
    esac

    # Commit the claim and push. If a competitor's claim landed first, the push is rejected; we rebase
    # onto their tip — a same-line conflict (both flipped it) means we LOST, so abort the rebase and
    # hard-reset to their tip (discarding OUR claim commit; on the default branch the ONLY local-ahead
    # commit is this claim). Then re-read to see who actually owns the 🚧 line.
    git add "$BACKLOG_FILE" 2>/dev/null || true
    git diff --cached --quiet || git commit -q -m "Claim: $slug → in-progress ($who)" 2>/dev/null || true
    if [ -n "$(git rev-list "$DEFAULT_BRANCH..HEAD" 2>/dev/null)" ]; then
        if ! git push -q "$HERD_REMOTE" "$HERD_BRANCH_NAME" 2>/dev/null; then
            git fetch -q "$HERD_REMOTE" "$HERD_BRANCH_NAME" 2>/dev/null || true
            if ! git rebase -q "$HERD_REMOTE/$HERD_BRANCH_NAME" 2>/dev/null; then
                git rebase --abort >/dev/null 2>&1 || true
                git reset --hard "$HERD_REMOTE/$HERD_BRANCH_NAME" >/dev/null 2>&1 || true
            fi
            # Still ahead (rebase succeeded, no conflict) → retry the push; a lost claim was reset away
            # and leaves nothing to push.
            if [ -n "$(git rev-list "$HERD_REMOTE/$HERD_BRANCH_NAME..HEAD" 2>/dev/null)" ]; then
                git push -q "$HERD_REMOTE" "$HERD_BRANCH_NAME" 2>/dev/null || true
            fi
        fi
    fi

    # CLAIM-VERIFY: re-read the (now-synced) backlog. Whoever it names as owner of the 🚧 line is the
    # real winner — this is what turns a lost push into an honest ALREADY.
    _file_claim_verify "$slug" "$who"
}

# _file_claim_verify SLUG WHO — re-read $BACKLOG_FILE and set _CLAIM_RESULT/_CLAIM_OWNER from the
# item's CURRENT owner: 🚧 stamped with WHO (or unstamped, i.e. our own just-made flip) → CLAIMED;
# 🚧 stamped with a different identity → ALREADY. Used as the post-push verification step.
_file_claim_verify() {
    local slug="$1" who="$2" line owner
    line="$(grep -m1 -F "$slug" "$BACKLOG_FILE" 2>/dev/null || true)"
    case "$line" in
        *🚧*)
            owner="$(printf '%s' "$line" | sed -n 's/.*(claimed by \([^)]*\)).*/\1/p')"
            if [ -z "$owner" ] || [ "$owner" = "$who" ]; then
                _CLAIM_RESULT="CLAIMED"; _CLAIM_OWNER="$who"
            else
                _CLAIM_RESULT="ALREADY"; _CLAIM_OWNER="$owner"
            fi ;;
        *) _CLAIM_RESULT="CLAIMED"; _CLAIM_OWNER="$who" ;;
    esac
}

# ── Planned-work markers (HERD-52) — cross-operator plan-time visibility ─────────────────────────
# The plan-time complement to the pre-spawn CLAIM (_backend_claim_item, HERD-50): when a coordinator
# SEQUENCES an item to spawn NEXT but hasn't spawned it yet, it publishes a lightweight PLANNED marker
# so a second operator doesn't grab the same item during that window. For the file backend the marker
# is a git-committed ANNOTATION appended to the item's $BACKLOG_FILE line, of the shared shape
# "📌 queued by <who>: sequenced after <blocker> [<epoch>]" (unix seconds so a reader can age it out at
# 24h). Because the annotation lands ON the item line it also shows up verbatim in `herd backlog`.
# Serialization/atomicity is git push, exactly like the file-backend claim; all ops are FAIL-SOFT (a
# missing backlog / unknown item / offline remote is NOCHANGE, never a hard error — a plan is advisory).
_backend_queue_item() {
    # $1 = item ref (a #id or a title slug), $2 = WHO, $3 = BLOCKER (may be empty). Appends/refreshes
    # the 📌 marker on the item's line and commits+pushes it. Sets _BACKEND_RESULT=DONE|NOCHANGE.
    local ref="$1" who="$2" blocker="$3" slug ts detail
    _BACKEND_RESULT="NOCHANGE"
    slug="${ref#*#}"
    [ -n "$who" ] || who="unknown-operator"
    [ -f "$BACKLOG_FILE" ] || return 0
    ts="$(date +%s 2>/dev/null || echo 0)"
    if [ -n "$blocker" ]; then detail="sequenced after $blocker"; else detail="sequenced next"; fi
    git pull --rebase --quiet "$HERD_REMOTE" "$HERD_BRANCH_NAME" 2>/dev/null || true
    if BACKLOG_FILE="$BACKLOG_FILE" SLUG="$slug" WHO="$who" DETAIL="$detail" TS="$ts" python3 - <<'PY'
import os, re, sys
backlog = os.environ["BACKLOG_FILE"]; slug = os.environ["SLUG"]; who = os.environ["WHO"]
detail = os.environ["DETAIL"]; ts = os.environ["TS"]
marker = "\U0001f4cc queued by %s: %s [%s]" % (who, detail, ts)
with open(backlog, encoding="utf-8") as f:
    lines = f.readlines()
idx = next((i for i, l in enumerate(lines) if slug in l), None)
if idx is None:
    sys.exit(1)                                   # item not found → NOCHANGE
line = lines[idx].rstrip("\n")
# Strip any pre-existing 📌 marker (refresh in place), then append the fresh one.
line = re.sub(r"\s*\U0001f4cc queued by .*?\[\d+\]", "", line).rstrip()
lines[idx] = line + " " + marker + "\n"
with open(backlog, "w", encoding="utf-8") as f:
    f.writelines(lines)
PY
    then
        _file_marker_commit "Queue: $slug planned by $who" && _BACKEND_RESULT="DONE"
    fi
    _backend_tw_journal "$ref" queued "$_BACKEND_RESULT"
}

_backend_unqueue_item() {
    # $1 = item ref, $2 = WHO (informational). Strips the 📌 marker off the item's line and
    # commits+pushes. Sets _BACKEND_RESULT=DONE (a marker was removed) | NOCHANGE (none present).
    local ref="$1" who="$2" slug
    _BACKEND_RESULT="NOCHANGE"
    slug="${ref#*#}"
    [ -f "$BACKLOG_FILE" ] || return 0
    git pull --rebase --quiet "$HERD_REMOTE" "$HERD_BRANCH_NAME" 2>/dev/null || true
    if BACKLOG_FILE="$BACKLOG_FILE" SLUG="$slug" python3 - <<'PY'
import os, re, sys
backlog = os.environ["BACKLOG_FILE"]; slug = os.environ["SLUG"]
with open(backlog, encoding="utf-8") as f:
    lines = f.readlines()
idx = next((i for i, l in enumerate(lines) if slug in l), None)
if idx is None:
    sys.exit(1)
line = lines[idx]
new = re.sub(r"\s*\U0001f4cc queued by .*?\[\d+\]", "", line.rstrip("\n")).rstrip() + "\n"
if new == line:
    sys.exit(1)                                   # no marker to clear → NOCHANGE
lines[idx] = new
with open(backlog, "w", encoding="utf-8") as f:
    f.writelines(lines)
PY
    then
        _file_marker_commit "Unqueue: $slug plan cleared" && _BACKEND_RESULT="DONE"
    fi
    _backend_tw_journal "$ref" unqueued "$_BACKEND_RESULT"
}

# _backend_list_queued — print every live planned marker in $BACKLOG_FILE, one TAB-separated line
# each: "<item-text>\t<who>\t<detail>\t<epoch>". <item-text> is the line's leading descriptor with the
# marker stripped (there is no stable id on the file backend). The reader applies the 24h-advisory rule.
_backend_list_queued() {
    [ -f "$BACKLOG_FILE" ] || return 0
    BACKLOG_FILE="$BACKLOG_FILE" python3 - <<'PY' 2>/dev/null || true
import os, re
backlog = os.environ["BACKLOG_FILE"]
rx = re.compile(r"\U0001f4cc queued by (.*?): (.*?) \[(\d+)\]")
with open(backlog, encoding="utf-8") as f:
    for line in f:
        m = rx.search(line)
        if not m:
            continue
        text = rx.sub("", line).strip().lstrip("-").strip()
        print("%s\t%s\t%s\t%s" % (text, m.group(1).strip(), m.group(2).strip(), m.group(3)))
PY
}

# _file_marker_commit MSG — stage $BACKLOG_FILE, commit MSG (nothing to commit → return 1), and push
# with the same rebase-on-reject discipline as the file-backend claim. Shared by queue/unqueue.
_file_marker_commit() {
    local msg="$1"
    git add "$BACKLOG_FILE" 2>/dev/null || true
    git diff --cached --quiet && return 1
    git commit -q -m "$msg" 2>/dev/null || true
    if [ -n "$(git rev-list "$DEFAULT_BRANCH..HEAD" 2>/dev/null)" ]; then
        if ! git push -q "$HERD_REMOTE" "$HERD_BRANCH_NAME" 2>/dev/null; then
            if git pull --rebase --quiet "$HERD_REMOTE" "$HERD_BRANCH_NAME" 2>/dev/null; then
                git push -q "$HERD_REMOTE" "$HERD_BRANCH_NAME" 2>/dev/null || true
            else
                git rebase --abort >/dev/null 2>&1 || true
            fi
        fi
    fi
    return 0
}
