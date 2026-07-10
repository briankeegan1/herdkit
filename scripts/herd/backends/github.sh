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
# plus OPTIONAL planned-work markers (HERD-52 / HERD-244): _backend_queue_item /
# _backend_unqueue_item / _backend_list_queued — a 📌 comment naming who sequenced the item after
# what, and (HERD-244) setting/clearing the issue ASSIGNEE so the plan is visible in every GitHub
# client, not only via `herd backlog queued`.
#
# Repo selection: $HERD_REPO (<owner>/<repo>) when configured, else gh falls back to the current
# repo's default. Requires the GitHub CLI (`gh`); degrades with a clear error if it is absent.

_github_require_gh() {
    command -v gh >/dev/null 2>&1 || {
        echo "github backend: 'gh' CLI not found — install GitHub CLI (or switch SCRIBE_BACKEND)" >&2
        exit 1
    }
}

# _backend_tw_journal — HERD-85 tracker-write attribution (mirror of the linear backend's). Emit ONE
# journal event per tracker STATE WRITE so `herd log | grep tracker_write` answers "which component
# moved <ref> to <state> on <pr>" in one line — the record missing when HERD-67/HERD-69 showed In
# Progress after merge. Attribution is the caller's HERD_COMPONENT (claim|scribe|reconcile), 'manual'
# by default. FAIL-SOFT: journal_append is best-effort and this is a silent no-op when journal.sh was
# never sourced — a journal problem must never block or alter the state write.
# Args: <ref> <requested-state> <result> [pr]   (pr falls back to $HERD_TW_PR when the arg is omitted).
_backend_tw_journal() {
    command -v journal_append >/dev/null 2>&1 || return 0
    local ref="$1" requested="$2" result="$3" pr="${4:-${HERD_TW_PR:-}}"
    if [ -n "$pr" ]; then
        journal_append tracker_write ref "$ref" requested "$requested" \
            component "${HERD_COMPONENT:-manual}" backend github result "$result" pr "$pr"
    else
        journal_append tracker_write ref "$ref" requested "$requested" \
            component "${HERD_COMPONENT:-manual}" backend github result "$result"
    fi
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

_github_short_title() {
    # Derive a SHORT issue title from the full request text (HERD-77). The title SUMMARIZES the
    # request; it NEVER replaces the body (the caller still stores the full text). A first line that
    # is already short (<=100 chars) is the title verbatim. A long first line — the
    # "first-line-as-essay" complaint (2026-07-07): a one-paragraph request became a giant title
    # duplicated in the body — is reduced to its first sentence/clause (split on ' — ', ': ', or
    # '. ') and hard-capped at 100 chars with an ellipsis. $1 = full text; prints the derived title.
    TEXT="$1" python3 -c 'import os
MAX = 100
first = os.environ["TEXT"].split("\n", 1)[0].strip()
if len(first) <= MAX:
    print(first)
else:
    cut = len(first)
    for d in (" — ", ": ", ". "):
        i = first.find(d)
        if i != -1:
            cut = min(cut, i)
    clause = first[:cut].strip()
    if not clause or len(clause) > MAX - 1:
        clause = first[:MAX - 1].rstrip()
    print(clause + "…")'
}

_backend_add_item() {
    # $1 = claimed queue file path (REQ_ID, unused here); $2 = item text / summary.
    # Title = a SHORT summary derived from the request (HERD-77 — never the whole first line as an
    # essay); body = the FULL text. Sets _BACKEND_RESULT=DONE on a created issue, NOCHANGE if gh
    # declines (so the scribe receipt still reports honestly).
    local text="$2" title body url
    _github_require_gh
    title="$(_github_short_title "$text")"
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
    _backend_tw_journal "$slug" shipped "$_BACKEND_RESULT" "$pr"   # HERD-85 attribution
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
    _backend_tw_journal "$ref" "$want" "$_BACKEND_RESULT"   # HERD-85 attribution
}

_backend_amend() {
    # $1 = item ref (issue number, "#42", or a title to search); $2 = the note to post.
    # HERD-128 AMEND: attach a clarification/comment to an EXISTING issue via `gh issue comment` —
    # first-class, WITHOUT touching the issue's state (open/closed) or its title. Conservative: no
    # matching issue → NOCHANGE + a LOUD reason (skip-over-guess), nothing posted. Sets
    # _BACKEND_RESULT=DONE|NOCHANGE.
    local ref="$1" note="$2" num
    _BACKEND_RESULT="NOCHANGE"
    _github_require_gh
    num="$(_github_resolve_issue "$ref")"
    if [ -z "$num" ]; then
        echo "github backend: no open issue matching '$ref' — nothing to amend (skipping, not posting)" >&2
        _backend_tw_journal "$ref" amend "$_BACKEND_RESULT"   # HERD-85 attribution (records the attempt)
        return 0
    fi
    if _gh issue comment "$num" --body "$note" >/dev/null 2>&1; then
        _BACKEND_RESULT="DONE"
    fi
    _backend_tw_journal "$ref" amend "$_BACKEND_RESULT"   # HERD-85 attribution
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
    info="$(_gh issue view "$num" --json state,assignees 2>/dev/null)" || { _CLAIM_RESULT="CLAIMED"; _CLAIM_OWNER="$who"; _backend_tw_journal "$ref" in-progress CLAIMED; return 0; }
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
        _backend_tw_journal "$ref" in-progress CLAIMED   # HERD-85: a claim writes in-progress
    fi
}

# _backend_release_item REF WHO — release OUR OWN claim (HERD-162 F12) by removing WHO from the issue's
# assignees, the same marker _backend_claim_item added. The issue's OPEN/CLOSED state is never touched:
# this un-claims, it does not reopen. Refuses when the assignee we would clear is not ours — a release
# must never steal a live operator's claim. Sets:
#   _RELEASE_RESULT = RELEASED | NOTOURS (unassigned, closed, or assigned to someone else) |
#                     UNREACHABLE (no matching issue / gh read failed → caller fails soft)
#   _RELEASE_OWNER  = the blocking login, when the refusal was NOTOURS
_backend_release_item() {
    local ref="$1" who="$2" num info parsed state other mine
    _RELEASE_RESULT=""; _RELEASE_OWNER=""
    _github_require_gh
    [ -n "$who" ] || who="$(gh api user -q .login 2>/dev/null || true)"
    [ -n "$who" ] || who="@me"
    num="$(_github_resolve_issue "$ref")"
    if [ -z "$num" ]; then _RELEASE_RESULT="UNREACHABLE"; return 0; fi

    info="$(_gh issue view "$num" --json state,assignees 2>/dev/null)" || { _RELEASE_RESULT="UNREACHABLE"; return 0; }
    [ -n "$info" ] || { _RELEASE_RESULT="UNREACHABLE"; return 0; }
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

    if [ "$state" = "CLOSED" ]; then _RELEASE_RESULT="NOTOURS"; _RELEASE_OWNER="a closed issue"; return 0; fi
    if [ "$mine" != "1" ];     then _RELEASE_RESULT="NOTOURS"; _RELEASE_OWNER="${other:-nobody}";  return 0; fi

    if ! _gh issue edit "$num" --remove-assignee "$who" >/dev/null 2>&1; then
        _RELEASE_RESULT="UNREACHABLE"; return 0
    fi
    _RELEASE_RESULT="RELEASED"; _RELEASE_OWNER="$who"
    _backend_tw_journal "$ref" open RELEASED   # HERD-85: a release is a tracker write
}

# ── Planned-work markers (HERD-52 / HERD-244) — cross-operator plan-time visibility ──────────────
# A 📌 comment of the shared shape "📌 queued by <who>: sequenced after <blocker> [<epoch>]" plus
# (HERD-244) setting the issue ASSIGNEE so a second operator sees the plan in every GitHub client
# view, not only via `herd backlog queued`. Fail-soft + backend-optional: transport hiccups and
# assignee permission errors no-op that half; the comment remains the backward-compat signal.
_GITHUB_QUEUE_MARK_RE='📌 queued by (.*?): (.*?) \[(\d+)\]'

# _github_plan_set_assignee NUM WHO — fail-soft: add WHO as assignee when the issue is unassigned (or
# already includes WHO). Never steals another operator's assignee.
_github_plan_set_assignee() {
    local num="$1" who="$2" info other mine
    [ -n "$num" ] && [ -n "$who" ] || return 0
    info="$(_gh issue view "$num" --json assignees 2>/dev/null)" || return 0
    other="$(printf '%s' "$info" | WHO="$who" python3 -c 'import sys, json, os
who = os.environ["WHO"]
try: d = json.load(sys.stdin)
except Exception: d = {}
asg = [a.get("login", "") for a in (d.get("assignees") or [])]
print(next((a for a in asg if a and a != who), ""))' 2>/dev/null)"
    [ -z "$other" ] || return 0
    mine="$(printf '%s' "$info" | WHO="$who" python3 -c 'import sys, json, os
who = os.environ["WHO"]
try: d = json.load(sys.stdin)
except Exception: d = {}
asg = [a.get("login", "") for a in (d.get("assignees") or [])]
print("1" if who in asg else "0")' 2>/dev/null)"
    [ "$mine" = "1" ] && return 0   # already ours — no-op
    _gh issue edit "$num" --add-assignee "$who" >/dev/null 2>&1 || true
}

# _github_plan_clear_assignee NUM WHO — fail-soft: remove WHO when still assigned and no competing
# assignee. Only called after a 📌 marker was actually deleted (the queue set the plan).
_github_plan_clear_assignee() {
    local num="$1" who="$2" info mine
    [ -n "$num" ] && [ -n "$who" ] || return 0
    info="$(_gh issue view "$num" --json assignees 2>/dev/null)" || return 0
    mine="$(printf '%s' "$info" | WHO="$who" python3 -c 'import sys, json, os
who = os.environ["WHO"]
try: d = json.load(sys.stdin)
except Exception: d = {}
asg = [a.get("login", "") for a in (d.get("assignees") or [])]
print("1" if who in asg else "0")' 2>/dev/null)"
    [ "$mine" = "1" ] || return 0
    _gh issue edit "$num" --remove-assignee "$who" >/dev/null 2>&1 || true
}

# _backend_queue_item REF WHO BLOCKER — publish a 📌 planned marker comment and set assignee to WHO
# (API identity / WATCHER_OWNER). BLOCKER may be empty → "sequenced next". Sets
# _BACKEND_RESULT=DONE|NOCHANGE off the comment write; assignee is fail-soft.
_backend_queue_item() {
    local ref="$1" who="$2" blocker="$3" num ts detail body
    _BACKEND_RESULT="NOCHANGE"
    _github_require_gh
    [ -n "$who" ] || who="$(gh api user -q .login 2>/dev/null || true)"
    [ -n "$who" ] || who="unknown-operator"
    ts="$(date +%s 2>/dev/null || echo 0)"
    if [ -n "$blocker" ]; then detail="sequenced after $blocker"; else detail="sequenced next"; fi
    num="$(_github_resolve_issue "$ref")"
    if [ -z "$num" ]; then
        echo "github backend: no open issue matching '$ref' — cannot publish a queued marker" >&2
        return 0
    fi
    body="$(printf '📌 queued by %s: %s [%s]' "$who" "$detail" "$ts")"
    if _gh issue comment "$num" --body "$body" >/dev/null 2>&1; then
        _BACKEND_RESULT="DONE"
    fi
    # HERD-244: first-class assignee so the plan shows in every GitHub list/view (fail-soft).
    _github_plan_set_assignee "$num" "$who"
    _backend_tw_journal "$ref" queued "$_BACKEND_RESULT"
}

# _backend_unqueue_item REF WHO — delete every 📌-marker comment on the issue; when ≥1 was removed
# and WHO is still assigned, also clear that assignee (HERD-244: clear only what the queue set).
# Sets _BACKEND_RESULT=DONE|NOCHANGE.
_backend_unqueue_item() {
    local ref="$1" who="$2" num resp ids id deleted=0
    _BACKEND_RESULT="NOCHANGE"
    _github_require_gh
    [ -n "$who" ] || who="$(gh api user -q .login 2>/dev/null || true)"
    [ -n "$who" ] || who="unknown-operator"
    num="$(_github_resolve_issue "$ref")"
    if [ -z "$num" ]; then return 0; fi
    # Comments via REST so we get stable numeric ids for DELETE. Fail-soft on any transport miss.
    if [ -n "${HERD_REPO:-}" ]; then
        resp="$(gh api "repos/$HERD_REPO/issues/$num/comments" 2>/dev/null)" || resp="[]"
    else
        resp="$(gh api "repos/{owner}/{repo}/issues/$num/comments" 2>/dev/null)" || resp="[]"
    fi
    ids="$(printf '%s' "$resp" | RE="$_GITHUB_QUEUE_MARK_RE" python3 -c 'import sys, json, os, re
rx = re.compile(os.environ["RE"])
try: d = json.load(sys.stdin)
except Exception: d = []
if not isinstance(d, list): d = []
for c in d:
    if rx.search(c.get("body") or ""):
        print(c.get("id", ""))' 2>/dev/null)"
    for id in $ids; do
        [ -n "$id" ] || continue
        if [ -n "${HERD_REPO:-}" ]; then
            if gh api -X DELETE "repos/$HERD_REPO/issues/comments/$id" >/dev/null 2>&1; then
                deleted=$((deleted + 1))
            fi
        else
            if gh api -X DELETE "repos/{owner}/{repo}/issues/comments/$id" >/dev/null 2>&1; then
                deleted=$((deleted + 1))
            fi
        fi
    done
    if [ "$deleted" -gt 0 ]; then
        _BACKEND_RESULT="DONE"
        _github_plan_clear_assignee "$num" "$who"
    fi
    _backend_tw_journal "$ref" unqueued "$_BACKEND_RESULT"
}

# _backend_list_queued — print every live planned marker across open issues, one TSV line each:
# "#<number>\t<who>\t<detail>\t<epoch>". Fail-soft: any miss prints nothing.
_backend_list_queued() {
    _github_require_gh
    local nums n resp
    nums="$(_gh issue list --state open --json number 2>/dev/null \
      | python3 -c 'import sys, json
try: d = json.load(sys.stdin)
except Exception: d = []
for it in d:
    n = it.get("number")
    if n is not None: print(n)' 2>/dev/null)" || return 0
    for n in $nums; do
        [ -n "$n" ] || continue
        if [ -n "${HERD_REPO:-}" ]; then
            resp="$(gh api "repos/$HERD_REPO/issues/$n/comments" 2>/dev/null)" || resp="[]"
        else
            resp="$(gh api "repos/{owner}/{repo}/issues/$n/comments" 2>/dev/null)" || resp="[]"
        fi
        printf '%s' "$resp" | RE="$_GITHUB_QUEUE_MARK_RE" NUM="$n" python3 -c 'import sys, json, os, re
rx = re.compile(os.environ["RE"]); num = os.environ.get("NUM", "")
try: d = json.load(sys.stdin)
except Exception: d = []
if not isinstance(d, list): d = []
for c in d:
    m = rx.search(c.get("body") or "")
    if m:
        print("#%s\t%s\t%s\t%s" % (num, m.group(1).strip(), m.group(2).strip(), m.group(3)))' 2>/dev/null || true
    done
}
