#!/usr/bin/env bash
# create-retry.sh — the DURABLE RETRY QUEUE for failed tracker-item CREATES (HERD-267).
#
# THE INCIDENT. Linear's free-tier ISSUE CAP started rejecting `issueCreate` with a 400. The scribe
# drainer's add path read that as `_BACKEND_RESULT=NOCHANGE`, ran its ordinary report-and-cleanup
# tail, and DELETED the claimed request file. Six coordinator filings evaporated over two hours with
# an EMPTY queue and no trace — and the one PR that noticed (#377) mislabeled the cap as an "API
# flake", so nothing upstream learned that every subsequent create was doomed too.
#
# Two failures, two fixes, both here:
#   1. THE REQUEST TEXT WAS LOST. A failed create now lands in a durable, on-disk entry that survives
#      the drainer, the watcher, and a reboot. NEVER LOSING THE ORIGINAL TEXT is the whole point of
#      this file; every other property is negotiable.
#   2. THE REASON WAS NOT SURFACED. `create_retry_class` separates a PERMANENT failure (the issue cap,
#      a bad API key) from a TRANSIENT one (a 5xx, a timeout). A permanent failure is announced LOUDLY
#      and STOPS RETRYING — it must never spin, because retrying a cap is guaranteed to fail and the
#      spin is what hides the real reason. That is the no-false-red doctrine applied to its mirror
#      image: don't cry flake at a wall.
#
# STORAGE. One entry per DISTINCT request text, under $WORKTREES_DIR/.create-retry/:
#     <hash>.text   the request text, byte-for-byte as the requester wrote it
#     <hash>.meta   attempts / first_seen / next_attempt / state / last_class / last_error
# Keying by a content hash is what COALESCES repeated failures of the same request into ONE entry
# carrying a retry count, instead of one row per attempt (a stacking console is an unreadable one).
#
# THE RETRY LOOP is deliberately not a daemon. `create_retry_reinject` copies every DUE entry back
# into the scribe queue as an ordinary `.req` file, and scribe-step.sh's `next` verb calls it before
# it polls. So a retry rides the drainer that is already running (or the next one a `herd scribe`
# spawns) — no new process, no new supervision surface, and a retry is applied by exactly the same
# code path as a first attempt. An entry is removed only by `create_retry_resolve`, on a CONFIRMED
# create.
#
# Sourced (never executed) after herd-config.sh, which provides WORKTREES_DIR. A tiny CLI tail is
# provided for `herd` and for operators: list | rows | due | reinject <queue-dir> | path.
#
# FAIL-SOFT + BYTE-IDENTICAL WHEN EMPTY, by the same contract as journal.sh: every function returns 0
# on an unwritable directory, a missing python3, or a malformed entry, and an EMPTY retry directory
# makes every function a silent no-op. A tracker-retry problem must never break the caller that was
# only trying to file an item.

# CREATE_SELFHEAL gates the whole feature. Read with ${VAR:-} at each call site rather than captured
# once, so a test (and a mid-session config flip) sees the current value.
create_retry_enabled() {
    case "$(printf '%s' "${CREATE_SELFHEAL:-on}" | tr '[:upper:]' '[:lower:]')" in
        off|0|false|no) return 1 ;;
        *)              return 0 ;;
    esac
}

# create_retry_dir — the durable entry directory. Prints nothing (and fails) with no WORKTREES_DIR,
# so every caller degrades to a no-op rather than scattering entries into $PWD.
create_retry_dir() {
    [ -n "${WORKTREES_DIR:-}" ] || return 1
    printf '%s' "$WORKTREES_DIR/.create-retry"
}

# _create_retry_now — epoch seconds. HERD_CREATE_RETRY_NOW is the test seam that freezes the clock
# (HERD_-namespaced, so the config-manifest ghost-key scan does not read it as a knob).
_create_retry_now() {
    if [ -n "${HERD_CREATE_RETRY_NOW-}" ]; then printf '%s' "$HERD_CREATE_RETRY_NOW"; return 0; fi
    date +%s 2>/dev/null || printf '0'
}

# _create_retry_hash <text> — a short, stable content hash. Tries the two shipped digests, then
# python3 (a hard engine dep). Empty output ⇒ the caller skips durable storage rather than colliding
# every request onto one entry.
_create_retry_hash() {
    if command -v shasum >/dev/null 2>&1; then
        printf '%s' "$1" | shasum -a 1 2>/dev/null | cut -c1-16
    elif command -v sha1sum >/dev/null 2>&1; then
        printf '%s' "$1" | sha1sum 2>/dev/null | cut -c1-16
    else
        TEXT="$1" python3 -c 'import os, hashlib
print(hashlib.sha1(os.environ["TEXT"].encode()).hexdigest()[:16])' 2>/dev/null
    fi
}

# create_retry_class <error-text> — classify a failed create so the operator learns WHY, and so the
# engine knows whether retrying can possibly help. The distinction is the whole lesson of the
# incident: a 400 USAGE_LIMIT_EXCEEDED is not a flake, and treating it as one both wastes the retries
# and buries the one fact that predicted every later failure.
#
#   cap        the tracker refused because a plan/quota limit is reached (Linear's free-tier issue
#              cap). PERMANENT — a human must raise the cap or archive issues.
#   auth       the credential is missing, expired, or unauthorized. PERMANENT — a human must fix it.
#   transient  a 5xx, a timeout, a RATE LIMIT, a dropped connection. RETRYABLE.
#   unknown    anything else, including an empty error (a backend that reports no reason). RETRYABLE,
#              because refusing to retry an unclassified failure is how a recoverable request dies.
#
# ORDER IS LOAD-BEARING, and both directions are traps:
#
#   • A cap read as a flake wastes every retry and buries the one fact that predicted the rest of the
#     incident. So the UNAMBIGUOUS cap keys and phrases are tested first.
#   • A THROTTLE read as a wall is the same mistake in a mirror, and it is the easier one to make.
#     Linear reports throttling as extensions.code=RATELIMITED, message="Rate limit exceeded", and
#     _linear_error_text feeds this classifier exactly "<code> <message>". A generic `*limit exceeded*`
#     alternative sitting in the cap arm therefore swallows every rate limit, marks it permanent on
#     attempt 1, and tells the operator to go raise a cap they never hit. So the rate-limit patterns
#     are tested BEFORE the generic limit-exceeded ones, which only catch what is left over.
#
# The unambiguous cap keys (`usage_limit_exceeded`, `usage limit`, `issue cap`, a quota/plan phrase)
# already win against any rate-limit wording, so nothing is lost by demoting the generic alternatives.
create_retry_class() {
    local e; e="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
    case "$e" in
        # 1. UNAMBIGUOUS cap — a named quota/plan/issue limit. Nothing here can read as throttling.
        *usage_limit_exceeded*|*usage\ limit*|*issue\ cap*|*quota*|*plan\ limit*|*upgrade\ your*)
            printf 'cap' ;;
        # 2. THROTTLING — before any generic "limit exceeded". Linear's key is RATELIMITED; other
        #    trackers spell it rate_limit / rate-limit / "rate limit". A rate limit CLEARS ON ITS OWN,
        #    which is precisely what the retry queue is for.
        *ratelimit*|*rate_limit*|*rate-limit*|*rate\ limit*)
            printf 'transient' ;;
        # 3. AUTH — a credential a human must fix. The bare status codes are ANCHORED to an http-status
        #    context (or a whole-string status), the same treatment the 5xx test gets below: an issue
        #    identifier like PROJ-401, or a message mentioning "401 items", is not an auth failure.
        *authentication*|*unauthenticated*|*unauthorized*|*forbidden*|*invalid\ api\ key*|*api\ key*|*http\ 40[13]*|*status\ 40[13]*|40[13])
            printf 'auth' ;;
        # 4. A generic "limit exceeded" that survived arms 1–3 is a cap by elimination.
        *limit_exceeded*|*limit\ exceeded*|*exceeded\ the\ limit*)
            printf 'cap' ;;
        # 5. The remaining transients. The 5xx test is ANCHORED to an http-status context (or a bare
        #    status code) rather than a loose 3-digit run, so "Issue 501 not found" is not a 5xx.
        *timeout*|*timed\ out*|*temporarily*|*try\ again*|*connection*|*network*|*internal\ server*|*bad\ gateway*|*service\ unavailable*|*http\ 5[0-9][0-9]*|*status\ 5[0-9][0-9]*|5[0-9][0-9])
            printf 'transient' ;;
        *)  printf 'unknown' ;;
    esac
}

# create_retry_permanent_class <class> — 0 when retrying this class can never succeed on its own.
create_retry_permanent_class() {
    case "$1" in cap|auth) return 0 ;; *) return 1 ;; esac
}

# create_retry_label <class> — the console/stderr prefix. Each class reads DISTINCTLY (no-false-red
# doctrine): a wall, a lock, and a hiccup must never look like the same red.
create_retry_label() {
    case "$1" in
        cap)       printf '🚫 tracker ISSUE CAP' ;;
        auth)      printf '🔒 tracker AUTH failure' ;;
        transient) printf '⏳ tracker API transient' ;;
        *)         printf '⚠️ tracker create failed' ;;
    esac
}

# _create_retry_meta_get <meta-file> <key> — read one header value; empty when absent/unreadable.
_create_retry_meta_get() {
    [ -f "$1" ] || return 0
    sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n1
}

# _create_retry_backoff <attempts> — seconds until the next attempt: BASE * 2^(attempts-1), capped at
# an hour so a long-lived transient outage settles into hourly probes rather than a busy loop.
_create_retry_backoff() {
    local attempts="${1:-1}" base="${HERD_CREATE_RETRY_BASE-60}" delay=0 i=1
    case "$base" in ''|*[!0-9]*) base=60 ;; esac
    delay="$base"
    while [ "$i" -lt "$attempts" ] && [ "$delay" -lt 3600 ]; do
        delay=$(( delay * 2 )); i=$(( i + 1 ))
    done
    [ "$delay" -gt 3600 ] && delay=3600
    printf '%s' "$delay"
}

# _create_retry_write_failed <why> — the durable write could not be made. Shout, journal, and let the
# caller's non-zero return keep the ONLY surviving copy of the request. Never swallowed: this is the
# failure that, silent, reproduces the incident exactly.
_create_retry_write_failed() {
    printf 'create-retry: DURABLE WRITE FAILED (%s) — the request text is NOT saved. The caller must keep its claim; do not drop the request. [HERD-267]\n' "$1" >&2
    if command -v journal_append >/dev/null 2>&1; then
        journal_append create_retry_write_failed reason "$1"
    fi
}

# _create_retry_hash_file <path> — the same short hash, taken over a file's exact BYTES.
_create_retry_hash_file() {
    [ -f "$1" ] || return 1
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 1 < "$1" 2>/dev/null | cut -c1-16
    elif command -v sha1sum >/dev/null 2>&1; then
        sha1sum < "$1" 2>/dev/null | cut -c1-16
    else
        python3 -c 'import sys, hashlib
print(hashlib.sha1(open(sys.argv[1], "rb").read()).hexdigest()[:16])' "$1" 2>/dev/null
    fi
}

# create_retry_key <text> [entry-hash] [src-file] — the entry key for a request. Identity is taken
# from the most faithful source available, in this order:
#
#   1. <entry-hash>, the hash carried by a RE-INJECTED request's own filename, when its entry still
#      exists. A retried request goes back through the scribe drainer — an LLM — which may hand
#      `add-item` a text differing from the stored one by a stripped trailing newline or a re-wrapped
#      line. Hashing THAT text would (a) fail to resolve the original entry on success, leaving it to
#      re-inject and file a duplicate forever, and (b) fork a SECOND entry on failure, defeating the
#      coalescing. The filename the engine itself minted keeps the LLM out of the identity path.
#   2. <src-file>, the CLAIMED `.req` still on disk: the requester's bytes, exactly as written.
#   3. <text>, the string the caller passed. The last resort.
create_retry_key() {
    local text="$1" override="${2:-}" src="${3:-}" dir h
    if [ -n "$override" ]; then
        dir="$(create_retry_dir 2>/dev/null)" || dir=""
        if [ -n "$dir" ] && [ -f "$dir/$override.text" ]; then printf '%s' "$override"; return 0; fi
    fi
    if [ -n "$src" ] && [ -f "$src" ]; then
        h="$(_create_retry_hash_file "$src")"
        if [ -n "$h" ]; then printf '%s' "$h"; return 0; fi
    fi
    _create_retry_hash "$text"
}

# create_retry_path_key <queue-file> — recover the entry hash the drainer was handed, from a claimed
# queue path of the shape `<epoch>-retry-<hash>.req[.mine]` (the name create_retry_reinject writes).
# Empty for an ordinary first-attempt request. Pure string work; no disk access.
create_retry_path_key() {
    local base; base="$(basename "${1:-}")"
    case "$base" in
        *-retry-*.req|*-retry-*.req.mine)
            base="${base%.mine}"; base="${base%.req}"; printf '%s' "${base##*-retry-}" ;;
        *) : ;;
    esac
}

# create_retry_enqueue <text> <class> <error> [entry-hash] [src-file] — record (or COALESCE onto) a
# durable entry for a create that failed, and print the entry's hash. This is the function that makes
# the incident unrepeatable: after it returns, the request text exists on disk regardless of what
# happens next. <src-file> is the claimed `.req`, and when present its bytes — not <text> — are what
# gets stored and hashed.
#
# An existing entry for the same request has its attempt count bumped and its next-attempt pushed out
# by the exponential backoff. The entry becomes PERMANENT — never re-injected again — when the class
# is permanent (a cap/auth wall) or the attempts reach CREATE_RETRY_MAX. Permanent means "stop
# spinning and shout", not "give up": the text is still on disk, the row still renders, and a
# `herd scribe` once the human raises the cap re-files it.
#
# Journals scribe_add_failed (every attempt) and create_retry_permanent (on the transition), so the
# console is not the only place a cap can be learned.
#
# RETURN VALUE IS A PROMISE, and the caller must honor it. 0 = the request text is durably on disk (or
# the feature is off / there was no text to save). NON-ZERO = the durable write FAILED, and the caller
# still holds the ONLY copy — it must NOT delete the claimed request file. This is the one function in
# the engine whose failure mode is the incident itself, so it does not get to fail silently.
create_retry_enqueue() {
    local text="$1" class="${2:-unknown}" err="${3:-}" key="${4:-}" src="${5:-}" dir hash meta attempts first now next state max
    create_retry_enabled || return 0
    [ -n "$text" ] || [ -f "$src" ] || return 0
    dir="$(create_retry_dir)" || { _create_retry_write_failed "no WORKTREES_DIR — cannot locate the retry queue"; return 1; }
    mkdir -p "$dir" 2>/dev/null || { _create_retry_write_failed "cannot create $dir"; return 1; }
    hash="$(create_retry_key "$text" "$key" "$src")"
    [ -n "$hash" ] || { _create_retry_write_failed "no digest tool (shasum/sha1sum/python3) — cannot key the entry"; return 1; }
    meta="$dir/$hash.meta"
    now="$(_create_retry_now)"

    attempts="$(_create_retry_meta_get "$meta" attempts)"
    case "$attempts" in ''|*[!0-9]*) attempts=0 ;; esac
    attempts=$(( attempts + 1 ))
    first="$(_create_retry_meta_get "$meta" first_seen)"
    case "$first" in ''|*[!0-9]*) first="$now" ;; esac

    max="${CREATE_RETRY_MAX:-5}"
    case "$max" in ''|*[!0-9]*) max=5 ;; esac

    state=pending
    if create_retry_permanent_class "$class" || [ "$attempts" -ge "$max" ]; then state=permanent; fi
    next=$(( now + $(_create_retry_backoff "$attempts") ))

    # The text is written FIRST and only then the meta: a crash between the two leaves an orphan
    # .text (harmless, and recoverable by hand) rather than a meta row pointing at nothing. An entry
    # that ALREADY holds text is never overwritten — on a retry the caller's $text has passed through
    # the drainer's LLM, and the copy on disk is the ORIGINAL. Keeping the original is the point.
    #
    # The claimed `.req` ($src), when we have it, is COPIED verbatim: it is the requester's own bytes,
    # while $text is whatever the drainer chose to pass along. The file header promises byte-for-byte,
    # and a `printf '%s' "$text"` cannot keep that promise (command substitution alone eats trailing
    # newlines). Fall back to $text only when the claimed file is gone.
    if [ ! -f "$dir/$hash.text" ]; then
        if [ -n "$src" ] && [ -f "$src" ]; then
            cp "$src" "$dir/$hash.text" 2>/dev/null \
              || { _create_retry_write_failed "cannot copy $src to $dir/$hash.text"; return 1; }
        else
            printf '%s' "$text" > "$dir/$hash.text" 2>/dev/null \
              || { _create_retry_write_failed "cannot write $dir/$hash.text"; return 1; }
        fi
    fi
    # A missing meta means the entry is never due and never renders — the text would sit on disk
    # unseen. That is a failed durable write too, so say so and keep the caller's copy alive.
    {
        printf 'attempts=%s\n' "$attempts"
        printf 'first_seen=%s\n' "$first"
        printf 'next_attempt=%s\n' "$next"
        printf 'state=%s\n' "$state"
        printf 'last_class=%s\n' "$class"
        printf 'last_error=%s\n' "$(printf '%s' "$err" | tr '\t\n' '  ' | cut -c1-300)"
    } > "$meta" 2>/dev/null || { _create_retry_write_failed "cannot write $meta"; return 1; }

    if command -v journal_append >/dev/null 2>&1; then
        journal_append scribe_add_failed reason "$class" attempts "$attempts" \
            state "$state" hash "$hash" error "$(printf '%s' "$err" | tr '\t\n' '  ' | cut -c1-200)"
        if [ "$state" = permanent ]; then
            journal_append create_retry_permanent reason "$class" attempts "$attempts" hash "$hash"
        fi
    fi

    # LOUD, and honest about which kind of red this is. A permanent failure names the human action.
    if [ "$state" = permanent ]; then
        printf 'create-retry: %s — the request is SAVED (not lost) and will NOT be retried automatically after %d attempt(s). Reason: %s. Fix the cause, then re-drain with `herd scribe` / `herd sweep`. [HERD-267]\n' \
            "$(create_retry_label "$class")" "$attempts" "${err:-no reason reported by the backend}" >&2
    else
        printf 'create-retry: %s — the request is SAVED (not lost) and queued for retry (attempt %d of %s, next in %ds). Reason: %s. [HERD-267]\n' \
            "$(create_retry_label "$class")" "$attempts" "$max" "$(( next - now ))" "${err:-no reason reported by the backend}" >&2
    fi
    printf '%s' "$hash"
}

# create_retry_resolve <text> [entry-hash] — this request reached a TERMINAL outcome (the create
# landed, or the drainer routed it to a verb that files nothing): drop its durable entry so it stops
# being re-injected. A first-time success calls this too and removes nothing (no entry exists), which
# is what keeps the happy path byte-identical.
#
# Any one argument is enough: `<text>` for an ordinary request, `"" <entry-hash>` for a terminal verb
# (skip / amend / update-state) that never sees the item text but was handed a re-injected
# `*-retry-<hash>.req`, or `<src-file>` for the claimed `.req` itself. Without the second form such an
# entry would re-inject on every backoff expiry forever, never advancing its attempt count toward
# CREATE_RETRY_MAX. The key is resolved by create_retry_key, so resolve and enqueue always agree on
# identity — including the byte-for-byte `.req` hash. Returns 0 always.
create_retry_resolve() {
    local dir hash
    create_retry_enabled || return 0
    [ -n "${1:-}" ] || [ -n "${2:-}" ] || [ -f "${3:-}" ] || return 0
    dir="$(create_retry_dir)" || return 0
    [ -d "$dir" ] || return 0
    hash="$(create_retry_key "${1:-}" "${2:-}" "${3:-}")"
    [ -n "$hash" ] || return 0
    [ -f "$dir/$hash.meta" ] || [ -f "$dir/$hash.text" ] || return 0
    rm -f "$dir/$hash.meta" "$dir/$hash.text" 2>/dev/null || true
    if command -v journal_append >/dev/null 2>&1; then
        journal_append create_retry_resolved hash "$hash"
    fi
    return 0
}

# create_retry_due — print the hash of every entry that is pending AND whose next_attempt has passed.
# Permanent entries are never due: that is the "surfaces loudly without spinning" contract.
create_retry_due() {
    local dir meta hash now state next
    create_retry_enabled || return 0
    dir="$(create_retry_dir)" || return 0
    [ -d "$dir" ] || return 0
    now="$(_create_retry_now)"
    for meta in "$dir"/*.meta; do
        [ -f "$meta" ] || continue
        hash="$(basename "$meta" .meta)"
        [ -f "$dir/$hash.text" ] || continue
        state="$(_create_retry_meta_get "$meta" state)"
        [ "$state" = pending ] || continue
        next="$(_create_retry_meta_get "$meta" next_attempt)"
        case "$next" in ''|*[!0-9]*) next=0 ;; esac
        [ "$now" -ge "$next" ] || continue
        printf '%s\n' "$hash"
    done
}

# create_retry_reinject <queue-dir> — copy every DUE entry's text back into the scribe queue as an
# ordinary .req file and push its next_attempt out by one backoff step. Prints the number re-injected.
#
# The entry is NOT removed here. If the drainer files it, `create_retry_resolve` removes it; if the
# drainer dies mid-flight, the entry is still on disk and comes due again — which is precisely the
# durability the incident lacked. A duplicate .req for an entry already in the queue is possible but
# harmless: the second drain finds the item already filed, or files a coalescing duplicate the
# coordinator can close. Losing the text is the only unrecoverable outcome, so the design errs there.
create_retry_reinject() {
    local q="${1:-}" dir hash n=0 meta attempts next now
    create_retry_enabled || { printf '0'; return 0; }
    [ -n "$q" ] && [ -d "$q" ] || { printf '0'; return 0; }
    dir="$(create_retry_dir)" || { printf '0'; return 0; }
    [ -d "$dir" ] || { printf '0'; return 0; }
    now="$(_create_retry_now)"
    while IFS= read -r hash; do
        [ -n "$hash" ] || continue
        meta="$dir/$hash.meta"
        # Already sitting in the queue (claimed or not) from an earlier re-injection whose drainer has
        # not reached it yet — re-injecting again would file the same item twice.
        if compgen -G "$q/*-retry-$hash.req" >/dev/null 2>&1 || compgen -G "$q/*-retry-$hash.req.mine" >/dev/null 2>&1; then
            continue
        fi
        cp "$dir/$hash.text" "$q/.tmp.retry.$hash" 2>/dev/null || continue
        mv "$q/.tmp.retry.$hash" "$q/${now}-retry-${hash}.req" 2>/dev/null || { rm -f "$q/.tmp.retry.$hash"; continue; }
        attempts="$(_create_retry_meta_get "$meta" attempts)"
        case "$attempts" in ''|*[!0-9]*) attempts=1 ;; esac
        next=$(( now + $(_create_retry_backoff $(( attempts + 1 )) ) ))
        # Push the deadline out BEFORE the drainer touches it, so a drainer that dies mid-drain does
        # not leave an entry that re-injects on every single poll.
        sed "s/^next_attempt=.*/next_attempt=$next/" "$meta" > "$meta.tmp" 2>/dev/null \
            && mv -f "$meta.tmp" "$meta" 2>/dev/null || rm -f "$meta.tmp" 2>/dev/null
        n=$(( n + 1 ))
    done <<< "$(create_retry_due)"
    if [ "$n" -gt 0 ] && command -v journal_append >/dev/null 2>&1; then
        journal_append create_retry_reinjected count "$n"
    fi
    printf '%s' "$n"
}

# create_retry_rows — ONE line per durable entry, newest failure last:
#     <state>\t<class>\t<attempts>\t<first-line of the request>
# Coalesced by construction (one entry per distinct request text), so a request that has failed nine
# times renders as one row reading attempts=9 — not nine stacked rows. Consumed by the sweep's
# narration and by an operator running `herd` tooling; empty output when nothing has failed.
create_retry_rows() {
    local dir meta hash state class attempts title
    create_retry_enabled || return 0
    dir="$(create_retry_dir)" || return 0
    [ -d "$dir" ] || return 0
    for meta in "$dir"/*.meta; do
        [ -f "$meta" ] || continue
        hash="$(basename "$meta" .meta)"
        [ -f "$dir/$hash.text" ] || continue
        state="$(_create_retry_meta_get "$meta" state)"
        class="$(_create_retry_meta_get "$meta" last_class)"
        attempts="$(_create_retry_meta_get "$meta" attempts)"
        title="$(head -n1 "$dir/$hash.text" 2>/dev/null | cut -c1-70)"
        printf '%s\t%s\t%s\t%s\n' "${state:-pending}" "${class:-unknown}" "${attempts:-1}" "$title"
    done
}

# Library mode: every engine caller sources this file. The CLI tail below only runs on direct
# execution, so `bash create-retry.sh rows` is an operator affordance, not a second code path.
case "${BASH_SOURCE[0]}" in
  "$0")
    _cr_here="$(cd "$(dirname "$0")" && pwd)"
    # shellcheck source=/dev/null
    . "$_cr_here/herd-config.sh"
    # shellcheck source=/dev/null
    . "$_cr_here/journal.sh"
    case "${1:-rows}" in
      rows)     create_retry_rows ;;
      due)      create_retry_due ;;
      list)     create_retry_rows ;;
      reinject) create_retry_reinject "${2:?usage: create-retry.sh reinject <queue-dir>}"; printf '\n' ;;
      path)     create_retry_dir; printf '\n' ;;
      *) printf 'usage: create-retry.sh rows | due | reinject <queue-dir> | path\n' >&2; exit 2 ;;
    esac
    ;;
esac
