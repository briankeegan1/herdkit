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

_backend_amend() {
    # $1 = item ref (a #id or a title/slug phrase); $2 = the note to append.
    # HERD-128 AMEND: attach a clarification/comment to an EXISTING item by appending an indented,
    # dated "↳ <note>" line directly beneath the item's $BACKLOG_FILE entry — first-class, no creative
    # drainer edit needed. NEVER touches the item's 🔜/🚧/✅ state or its title. Conservative by design:
    # the ref must resolve to EXACTLY ONE item line (📌-marker aware, like every other file-backend
    # lookup). Zero or multiple matches → NOCHANGE + a LOUD reason on stderr (skip-over-guess), so
    # scribe-step records a SKIP and NOTHING is written. Serialization/atomicity is git push, exactly
    # like the file-backend claim/marker ops. Sets _BACKEND_RESULT=DONE (note appended + pushed) |
    # NOCHANGE (no unique match / no file).
    local ref="$1" note="$2" slug day rc
    _BACKEND_RESULT="NOCHANGE"
    slug="${ref#*#}"
    if [ ! -f "$BACKLOG_FILE" ]; then
        echo "file backend: no $BACKLOG_FILE — cannot amend '$ref' (skipping, nothing written)" >&2
        _backend_tw_journal "$ref" amend "$_BACKEND_RESULT"
        return 0
    fi
    day="$(date +%Y-%m-%d 2>/dev/null || echo '')"
    # Sync to the remote tip first so the amend lands beneath the item's CURRENT line (another scribe
    # may have edited it). Fail-soft: an offline/failed pull just amends against local state.
    git pull --rebase --quiet "$HERD_REMOTE" "$HERD_BRANCH_NAME" 2>/dev/null || true
    if BACKLOG_FILE="$BACKLOG_FILE" SLUG="$slug" NOTE="$note" DAY="$day" MARK_RE="$_FILE_MARK_RE" python3 - <<'PY'
import os, re, sys
backlog = os.environ["BACKLOG_FILE"]; slug = os.environ["SLUG"]
note = os.environ["NOTE"]; day = os.environ["DAY"]
mark = re.compile(os.environ["MARK_RE"])
with open(backlog, encoding="utf-8") as f:
    lines = f.readlines()
# Match on the DESCRIPTOR (📌 marker stripped) so a blocker slug embedded in a SIBLING item's marker
# is never a false match surface (HERD-52 CLAIM-poisoning fix). Require EXACTLY ONE match — an
# ambiguous ref must SKIP, never guess which item the operator meant.
idxs = [i for i, l in enumerate(lines) if slug in mark.sub("", l)]
if len(idxs) != 1:
    sys.exit(2 if len(idxs) > 1 else 1)   # 2 = ambiguous, 1 = not found
idx = idxs[0]
# Insert AFTER the item line and after any indented child lines already beneath it (prior ↳ notes or
# continuations) so successive amends stack in chronological order under the SAME item.
j = idx + 1
while j < len(lines) and (lines[j].startswith(" ") or lines[j].startswith("\t")):
    j += 1
stamp = ("[%s] " % day) if day else ""
lines.insert(j, "  ↳ %s%s\n" % (stamp, note))
with open(backlog, "w", encoding="utf-8") as f:
    f.writelines(lines)
PY
    then
        _file_marker_commit "Amend: note on $slug" && _BACKEND_RESULT="DONE"
    else
        rc=$?
        if [ "$rc" -eq 2 ]; then
            echo "file backend: '$ref' matches MORE THAN ONE backlog item — skipping (ambiguous ref; not guessing which to amend)" >&2
        else
            echo "file backend: no backlog item matching '$ref' — nothing to amend (skipping, nothing written)" >&2
        fi
    fi
    # HERD-85: journal the amend attempt (result = the verified outcome) so attribution is a one-line
    # `herd log` lookup. Fail-soft; never affects the result.
    _backend_tw_journal "$ref" amend "$_BACKEND_RESULT"
}

_backend_list_open() {
    # Print open backlog items (🔜 queued or 🚧 in-progress).
    grep -E '🔜|🚧' "$BACKLOG_FILE" 2>/dev/null || true
}

# _FILE_MARK_RE — the 📌 planned-marker region on a backlog line (HERD-52). It is the FIRST thing that
# writes ANOTHER item's slug (…sequenced after <blocker>…) verbatim onto an item's line, so it MUST be
# stripped before any `slug in line` substring test — otherwise a blocker slug embedded in one item's
# marker is a false match surface for that blocker's own claim/state lookup, silently flipping the
# wrong item (the file-backend CLAIM-poisoning bug). Non-greedy up to the marker's own [<epoch>] so a
# trailing "(claimed by …)" is preserved. A Python-`re` pattern (used both inline and via $MARK_RE env).
_FILE_MARK_RE='\s*\U0001f4cc queued by .*?\[\d+\]'

# _file_line_for_slug SLUG — print the FIRST $BACKLOG_FILE line whose DESCRIPTOR (📌 marker stripped)
# contains SLUG, returning the ORIGINAL line (marker intact). Empty when no match / no file. Uses
# python (UTF-8 safe), NOT `grep -F`, so a marker that names another item is never a false match
# surface — the shared, marker-aware replacement for the old first-substring-hit grep.
_file_line_for_slug() {
    BACKLOG_FILE="$BACKLOG_FILE" SLUG="$1" MARK_RE="$_FILE_MARK_RE" python3 - <<'PY' 2>/dev/null || true
import os, re, sys
try:
    with open(os.environ["BACKLOG_FILE"], encoding="utf-8") as f:
        lines = f.readlines()
except OSError:
    raise SystemExit
slug = os.environ["SLUG"]; mark = re.compile(os.environ["MARK_RE"])
for l in lines:
    if slug in mark.sub("", l):
        sys.stdout.write(l); break
PY
}

_backend_item_state() {
    # $1 = <link-name>#<id> or a title slug.  BACKLOG_FILE is already set.
    # Finds the slug's line (📌-marker-aware) in BACKLOG_FILE; checks for 🔜/🚧/✅ emoji → maps to
    # open/in-progress/closed. Sets ITEM_STATE=open|closed|in-progress.  Missing slug → open (safe default).
    local ref="$1" slug line
    slug="${ref#*#}"
    line="$(_file_line_for_slug "$slug")"
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
    parsed="$(BACKLOG_FILE="$BACKLOG_FILE" SLUG="$slug" WHO="$who" MARK_RE="$_FILE_MARK_RE" python3 - <<'PY'
import os, re
backlog = os.environ["BACKLOG_FILE"]; slug = os.environ["SLUG"]; who = os.environ["WHO"]
mark = re.compile(os.environ["MARK_RE"])
with open(backlog, encoding="utf-8") as f:
    lines = f.readlines()
# Match on the DESCRIPTOR (marker stripped) so a blocker slug inside a SIBLING item marker is never a
# false match surface for this claim (HERD-52 CLAIM-poisoning fix). (No apostrophes in this heredoc:
# bash 3.2 mis-parses a quote inside a heredoc nested in $() — the whole block lives in parsed="$(...)".)
idx = next((i for i, l in enumerate(lines) if slug in mark.sub("", l)), None)
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
    line="$(_file_line_for_slug "$slug")"
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

# _file_remote_configured — success iff $HERD_REMOTE is a real configured remote. A solo operator with
# no remote keeps their backlog LOCALLY; there, the commit IS the durable write and there is nothing to
# push. Everywhere else a write that never reached the remote is a write that never happened.
_file_remote_configured() { git remote get-url "$HERD_REMOTE" >/dev/null 2>&1; }

# _file_release_abort <pre-release-head> — undo our release commit so a failed release leaves the main
# checkout EXACTLY as it found it: not dirty, not ahead, no `Release:` commit waiting for the next
# `git pull --rebase` + push to carry it onto whatever another operator has since landed on that line.
# Prefer the remote tip when it resolves (the claim path's rule); fall back to the sha we started at,
# which is what an unreachable/absent remote leaves us with.
_file_release_abort() {
    git rebase --abort >/dev/null 2>&1 || true
    if git rev-parse --verify -q "$HERD_REMOTE/$HERD_BRANCH_NAME" >/dev/null 2>&1; then
        git reset --hard "$HERD_REMOTE/$HERD_BRANCH_NAME" >/dev/null 2>&1 || true
    else
        git reset --hard "${1:-HEAD}" >/dev/null 2>&1 || true
    fi
}

# _backend_release_item REF WHO — release OUR OWN claim (HERD-162 F12), the inverse of the flip above:
# strip the "(claimed by WHO)" stamp and put the line back to 🔜 so the item is re-pickable. It is a
# CLAIM release, not a state reopen: a ✅ shipped line is never touched, and the 🔜 the claim flipped
# FROM is the only state we restore. Refuses to release a stamp bearing another identity — a release
# that could steal an in-flight operator's claim is worse than the wedge it fixes. Sets:
#   _RELEASE_RESULT = RELEASED (our stamp is gone, and it LANDED where other operators read it) |
#                     NOTOURS (someone else's claim, or none) |
#                     UNREACHABLE (no backlog, item not found, or the write did not land → the caller
#                                  fails soft to "still held — re-queue it")
#   _RELEASE_OWNER  = the blocking identity, when the refusal was NOTOURS
#
# THE WRITE MUST LAND OR SAY IT DID NOT. This is the whole point of the feature: a release the remote
# never saw leaves the item wedged against every other seat — behind a `claim_released` journal event
# and a "re-pickable" notification, which is strictly worse than the wedge it was meant to fix. So the
# commit is checked, the push is checked, and the result is VERIFIED by re-reading the synced line (the
# same discipline _backend_claim_item's claim-verify and linear.sh's release-verify use). A rejected
# push means another operator moved the line under us: we discard our commit rather than force it on
# top of theirs, and report UNREACHABLE. Never destructive, never a false success.
_backend_release_item() {
    local ref="$1" who="$2" slug parsed status owner head0 line
    _RELEASE_RESULT=""; _RELEASE_OWNER=""
    slug="${ref#*#}"
    [ -n "$who" ] || who="unknown-operator"
    [ -f "$BACKLOG_FILE" ] || { _RELEASE_RESULT="UNREACHABLE"; return 0; }

    git pull --rebase --quiet "$HERD_REMOTE" "$HERD_BRANCH_NAME" 2>/dev/null || true
    head0="$(git rev-parse HEAD 2>/dev/null)" || { _RELEASE_RESULT="UNREACHABLE"; return 0; }

    parsed="$(BACKLOG_FILE="$BACKLOG_FILE" SLUG="$slug" WHO="$who" MARK_RE="$_FILE_MARK_RE" python3 - <<'PY'
import os, re
backlog = os.environ["BACKLOG_FILE"]; slug = os.environ["SLUG"]; who = os.environ["WHO"]
mark = re.compile(os.environ["MARK_RE"])
with open(backlog, encoding="utf-8") as f:
    lines = f.readlines()
idx = next((i for i, l in enumerate(lines) if slug in mark.sub("", l)), None)
if idx is None:
    print("MISSING\t"); raise SystemExit
line = lines[idx]
if "✅" in line:                  # a shipped item holds no claim to release
    print("NOTOURS\ta completed item"); raise SystemExit
m = re.search(r" ?\(claimed by ([^)]*)\)", line)
if not m:
    print("NOTOURS\t"); raise SystemExit  # 🚧 with no stamp, or an unclaimed line — not ours to clear
owner = m.group(1).strip()
if owner != who:
    print("NOTOURS\t" + owner); raise SystemExit
new = line[:m.start()] + line[m.end():]                                    # drop the claim stamp
new = new.replace("\U0001f6a7", "\U0001f51c", 1) if "\U0001f6a7" in new else new  # 🚧 → 🔜
lines[idx] = new
with open(backlog, "w", encoding="utf-8") as f:
    f.writelines(lines)
print("CLEARED\t" + who)
PY
)"
    status="${parsed%%	*}"; owner="${parsed#*	}"
    case "$status" in
        MISSING) _RELEASE_RESULT="UNREACHABLE"; return 0 ;;
        NOTOURS) _RELEASE_RESULT="NOTOURS"; _RELEASE_OWNER="$owner"; return 0 ;;
        CLEARED) : ;;
        *)       _RELEASE_RESULT="UNREACHABLE"; return 0 ;;
    esac

    # ── COMMIT: a commit that does not land (hook, index.lock, unset identity) is not a release ──────
    git add "$BACKLOG_FILE" 2>/dev/null || true
    if git diff --cached --quiet; then
        # Our edit vanished between the write and the stage — nothing to commit, nothing was released.
        _RELEASE_RESULT="UNREACHABLE"; return 0
    fi
    if ! git commit -q -m "Release: $slug → unclaimed ($who)" 2>/dev/null; then
        # Never leave the operator's main checkout dirty with a half-applied release.
        git reset -q HEAD -- "$BACKLOG_FILE" >/dev/null 2>&1 || true
        git checkout -q -- "$BACKLOG_FILE" >/dev/null 2>&1 || true
        _RELEASE_RESULT="UNREACHABLE"; return 0
    fi

    # ── PUSH: with a remote configured, the remote is where every other operator reads the claim ─────
    # Deliberately NOT gated on `rev-list $DEFAULT_BRANCH..HEAD` being non-empty: when the remote-tracking
    # ref is missing or stale that test is silently empty, and we would skip the push and call it a
    # release. Pushing an already-current branch is a cheap no-op that still exits 0.
    if _file_remote_configured; then
        if ! git push -q "$HERD_REMOTE" "$HERD_BRANCH_NAME" 2>/dev/null; then
            # Rejected: someone landed on this branch first. Rebase onto their tip and retry ONCE — a
            # release that touches a line nobody else moved still lands. Anything else (a conflict on
            # our own line, an unreachable remote) discards our commit and reports the honest failure.
            git fetch -q "$HERD_REMOTE" "$HERD_BRANCH_NAME" 2>/dev/null || true
            if ! { git rebase -q "$HERD_REMOTE/$HERD_BRANCH_NAME" 2>/dev/null \
                   && git push -q "$HERD_REMOTE" "$HERD_BRANCH_NAME" 2>/dev/null; }; then
                _file_release_abort "$head0"
                _RELEASE_RESULT="UNREACHABLE"; return 0
            fi
        fi
    fi

    # ── RELEASE-VERIFY: re-read the (now-synced) line. Whatever it says is the truth other operators
    # will read. A stamp that survived means the release did not take — report it, never claim success.
    line="$(_file_line_for_slug "$slug")"
    case "$line" in
        *"claimed by"*) _RELEASE_RESULT="UNREACHABLE"; return 0 ;;
        "")             _RELEASE_RESULT="UNREACHABLE"; return 0 ;;
    esac
    _RELEASE_RESULT="RELEASED"; _RELEASE_OWNER="$who"
    _backend_tw_journal "$ref" open RELEASED
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
    if BACKLOG_FILE="$BACKLOG_FILE" SLUG="$slug" WHO="$who" DETAIL="$detail" TS="$ts" MARK_RE="$_FILE_MARK_RE" python3 - <<'PY'
import os, re, sys
backlog = os.environ["BACKLOG_FILE"]; slug = os.environ["SLUG"]; who = os.environ["WHO"]
detail = os.environ["DETAIL"]; ts = os.environ["TS"]
mark = re.compile(os.environ["MARK_RE"])
marker = "\U0001f4cc queued by %s: %s [%s]" % (who, detail, ts)
with open(backlog, encoding="utf-8") as f:
    lines = f.readlines()
# Match on the DESCRIPTOR (📌 marker stripped) so another item's marker naming THIS slug as its blocker
# can't be a false match surface (HERD-52 CLAIM-poisoning fix).
idx = next((i for i, l in enumerate(lines) if slug in mark.sub("", l)), None)
if idx is None:
    sys.exit(1)                                   # item not found → NOCHANGE
line = lines[idx].rstrip("\n")
# Strip any pre-existing 📌 marker (refresh in place), then append the fresh one.
line = mark.sub("", line).rstrip()
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
    if BACKLOG_FILE="$BACKLOG_FILE" SLUG="$slug" MARK_RE="$_FILE_MARK_RE" python3 - <<'PY'
import os, re, sys
backlog = os.environ["BACKLOG_FILE"]; slug = os.environ["SLUG"]
mark = re.compile(os.environ["MARK_RE"])
with open(backlog, encoding="utf-8") as f:
    lines = f.readlines()
# Match on the DESCRIPTOR (📌 marker stripped) — see the CLAIM-poisoning note in queue_item.
idx = next((i for i, l in enumerate(lines) if slug in mark.sub("", l)), None)
if idx is None:
    sys.exit(1)
line = lines[idx]
new = mark.sub("", line.rstrip("\n")).rstrip() + "\n"
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
