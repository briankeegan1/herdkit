#!/usr/bin/env bash
# scribe-step.sh — queue/git/report mechanics for the backlog drainer. The scribe Claude
# calls these so it only does the creative edit. Subcommands:
#   next [--linger <secs>] reclaim stale claims (>5 min); wait up to $SCRIBE_POLL s for a
#                          request; atomically claim the oldest; git pull; print
#                          "CLAIMED <path>" + the request text, or "EMPTY". LINGER (HERD-88): when
#                          the base $SCRIBE_POLL wait finds the queue empty, keep polling for
#                          SCRIBE_LINGER_SECS more seconds (overridable via --linger) before
#                          returning EMPTY, so a burst with idle gaps is drained by ONE session
#                          instead of a fresh cold-start per gap. Default 0 → total wait == $SCRIBE_POLL.
#   commit <path> "<sum>"  file backend: add/commit/push $BACKLOG_FILE (pull-rebase retry on
#                          reject), write the live-view receipt, append to the inbox, fire a
#                          herdr notification, remove the claimed file.
#   add-item <path> "<t>"  API/changelog backend: dispatch a NEW item to the backend (no file
#                          edit by the agent), then the same receipt/inbox/notify/cleanup.
#   update-state <path> <ref> <state>
#                          API backend: transition an EXISTING item (done/in-progress/canceled)
#                          via _backend_update_state instead of filing a new issue — the second
#                          half of the intent-dispatch fix (gh #139): a "mark X done" / watcher
#                          "Reconcile: PR #N merged …" request must NOT become a brand-new issue.
#   skip <path> "<why>"    The drainer classified the request as unmappable to any backend verb:
#                          record a LOUD line in the scribe report and drop the claim, filing
#                          NOTHING (never a junk new issue).
#   finish                 race-safe stop: if the queue is now empty, close the scribe tab
#                          ($SCRIBE_TAB) and print STOP; else print MORE (keep draining).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/herd-config.sh"
# journal.sh gives backend state-writes their attribution record (HERD-85): a tracker_write event per
# transition. Best-effort — the sourced journal_append can never break a caller. Attribute every
# backend dispatch from this drainer to the 'scribe' component (the explicit-ref reconcile path in
# agent-watch attributes its own writes 'reconcile' before this ever runs).
. "$HERE/journal.sh"
export HERD_COMPONENT="${HERD_COMPONENT:-scribe}"
# API backends read credentials from .herd/secrets (gitignored). The file/changelog backends
# never touch it — sourcing is best-effort and absent-file-safe so the zero-secret case is clean.
_SECRETS="$PROJECT_ROOT/.herd/secrets"
# shellcheck source=/dev/null
[ -f "$_SECRETS" ] && . "$_SECRETS"
unset _SECRETS
# Source the pluggable backend implementation keyed on SCRIBE_BACKEND (default: file). The backend
# directory is $HERE/backends in production; SCRIBE_BACKEND_DIR overrides it so a hermetic test can
# point at a fake backend that records which _backend_* op fired per request (dispatch-table test).
_BACKEND_DIR="${SCRIBE_BACKEND_DIR:-$HERE/backends}"
_BACKEND_FILE="$_BACKEND_DIR/${SCRIBE_BACKEND}.sh"
[ -f "$_BACKEND_FILE" ] || { echo "scribe-step: unknown SCRIBE_BACKEND '${SCRIBE_BACKEND}' — no ${_BACKEND_DIR}/${SCRIBE_BACKEND}.sh" >&2; exit 1; }
# shellcheck source=backends/file.sh
. "$_BACKEND_FILE"
unset _BACKEND_FILE _BACKEND_DIR
REPO="$PROJECT_ROOT"
TREES="$WORKTREES_DIR"
Q="$TREES/backlog-queue"
INBOX="$TREES/.scribe-reports"
RECEIPT="$TREES/.backlog-last-scribe"
POLL="${SCRIBE_POLL:-25}"
mkdir -p "$Q"
cmd="${1:-}"

# _report_and_cleanup <claimed-path> <summary> <result> — shared post-write tail for both
# commit (file) and add-item (api/changelog): live-view receipt, inbox line, notify, unclaim.
_report_and_cleanup() {
  local mine="$1" sum="$2" out="$3" short
  short=$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo '-------')
  printf '%s · %s\n' "$sum" "$short" > "$RECEIPT"
  printf '[%s] %s · %s\n' "$(date '+%H:%M')" "$sum" "$short" >> "$INBOX"
  herdr notification show "✍️ Backlog scribed" --body "$sum" --sound done >/dev/null 2>&1 || true
  rm -f "$mine"
  echo "$out $short"
}

case "$cmd" in
  next)
    # LINGER window (HERD-88): after the base $POLL wait empties the queue, keep polling for
    # SCRIBE_LINGER_SECS more seconds before returning EMPTY so a burst of requests arriving with
    # idle gaps between them is drained by ONE session instead of paying a fresh MODEL_SCRIBE
    # cold-start per gap. `--linger <secs>` overrides the config default. Default 0 → deadline ==
    # $POLL, byte-identical to today's poll. A request enqueued DURING the linger is claimed by the
    # SAME loop below with no special-casing; the single-drainer mkdir-mutex (in scribe.sh) is untouched.
    linger="${SCRIBE_LINGER_SECS:-0}"
    if [ "${2:-}" = "--linger" ]; then linger="${3:-0}"; fi
    case "$linger" in ''|*[!0-9]*) linger=0 ;; esac
    deadline=$((POLL + linger))
    # reclaim claims abandoned by a dead drainer
    find "$Q" -name '*.mine' -mmin +5 -exec sh -c 'mv -f "$1" "${1%.mine}"' _ {} \; 2>/dev/null || true
    waited=0
    while :; do
      # Atomic claim: walk the queue oldest-first and try to win each candidate via an atomic
      # rename. If the mv fails another scribe already claimed that file — skip to the NEXT
      # candidate instead of processing a file we did not win.
      claimed=""
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        if mv "$f" "$f.mine" 2>/dev/null; then
          claimed="$f.mine"; break
        fi
      done < <(ls -1 "$Q"/*.req 2>/dev/null | sort)
      if [ -n "$claimed" ]; then
        ( cd "$REPO" && git pull --ff-only --quiet "$HERD_REMOTE" "$HERD_BRANCH_NAME" 2>/dev/null ) || true
        # Emit the ACTIVE backend (SCRIBE_BACKEND was sourced fresh THIS invocation, so it reflects
        # any mid-session flip) so the drainer applies each request via the backend live at DRAIN
        # time — not whatever was set when the drainer was spawned (issue #139).
        echo "CLAIMED $claimed"; echo "BACKEND $SCRIBE_BACKEND"; cat "$claimed"; exit 0
      fi
      [ "$waited" -ge "$deadline" ] && { echo "EMPTY"; exit 0; }
      sleep 2; waited=$((waited+2))
    done
    ;;
  commit)
    # File-backend apply: the agent has already edited $BACKLOG_FILE; stage+commit+push it.
    mine="${2:?claimed path}"; sum="${3:?summary}"
    cd "$REPO" || exit 1
    _BACKEND_RESULT=""
    if [ "$SCRIBE_BACKEND" = "file" ]; then
      _backend_add_item "$mine" "$sum"
      _report_and_cleanup "$mine" "$sum" "$_BACKEND_RESULT"
    else
      # STALE-DRAINER GUARD (issue #139): a file-mode 'commit' arrived while the ACTIVE backend is
      # NON-file — a drainer spawned before a mid-session SCRIBE_BACKEND flip is still running with a
      # backend-conditional prompt from the old mode. The old bug filed the short SUMMARY as a backend
      # item (the junk 'no-op:' issues). Instead: discard the drainer's stray $BACKLOG_FILE edit and
      # dispatch the ORIGINAL request text (still in the claimed file) through the ACTIVE backend, so
      # the item lands correctly. Warn LOUDLY so the operator retires the stale drainer.
      echo "scribe-step: SCRIBE_BACKEND='$SCRIBE_BACKEND' but a file-mode 'commit' arrived — a stale file-mode drainer is running (retire it). Discarding its $BACKLOG_FILE edit and dispatching the request via the active backend. [issue #139]" >&2
      git checkout -- "$BACKLOG_FILE" 2>/dev/null || true
      _stale_text="$(cat "$mine" 2>/dev/null)"; [ -n "$_stale_text" ] || _stale_text="$sum"
      _backend_add_item "$mine" "$_stale_text"
      _report_and_cleanup "$mine" "$_stale_text" "$_BACKEND_RESULT"
    fi
    ;;
  add-item)
    # API/changelog path: the agent did NOT edit any file — dispatch the text to the backend.
    mine="${2:?claimed path}"; text="${3:?item text}"
    cd "$REPO" || exit 1
    if [ "$SCRIBE_BACKEND" = "file" ]; then
      # Reverse of the #139 flip: a non-file drainer (spawned before a flip TO 'file') is draining.
      # The file backend needs a creative $BACKLOG_FILE edit this step script cannot synthesize, so a
      # bare dispatch cannot place the item (file's _backend_add_item finds no staged edit → NOCHANGE).
      # Warn LOUDLY (never silent) — retire the stale drainer so a fresh file-mode drainer edits
      # $BACKLOG_FILE for this request. [issue #139]
      echo "scribe-step: SCRIBE_BACKEND='file' but an 'add-item' dispatch arrived — a stale non-file drainer is running (retire it); this request needs a file-mode drainer to edit $BACKLOG_FILE. [issue #139]" >&2
    fi
    _BACKEND_RESULT=""
    _backend_add_item "$mine" "$text"
    _report_and_cleanup "$mine" "$text" "$_BACKEND_RESULT"
    ;;
  update-state)
    # Intent-dispatch path (gh #139, second half): transition an EXISTING item's state instead of
    # filing a new issue. The agent did NOT edit any file — the backend resolves <ref> (an identifier
    # like HERD-22 / #42, or a conservative title match) and moves it to <state> ∈ done|in-progress|
    # canceled. This is what the watcher's "Reconcile: PR #N merged …" and reap requests route to;
    # before this verb existed the drainer's only non-file option was add-item → a junk new issue.
    mine="${2:?claimed path}"; ref="${3:?item ref}"; state="${4:?target state (done|in-progress|canceled)}"
    cd "$REPO" || exit 1
    if [ "$SCRIBE_BACKEND" = "file" ]; then
      # The file backend records state IN the file: a state change is a $BACKLOG_FILE edit + commit,
      # not a dispatch. Reaching here means a stale non-file drainer was routed under the file backend
      # (the #139 mid-session-flip class). Warn LOUDLY and file NOTHING — never a junk issue.
      echo "scribe-step: SCRIBE_BACKEND='file' but an 'update-state' dispatch arrived — the file backend records state by editing $BACKLOG_FILE; retire the stale drainer so a file-mode drainer edits it. [issue #139]" >&2
      _report_and_cleanup "$mine" "⚠️ SKIPPED (not filed): $ref → $state — file backend edits $BACKLOG_FILE" "SKIP"
      exit 0
    fi
    if ! command -v _backend_update_state >/dev/null 2>&1; then
      # A backend with no state-transition op (defensive — every API backend defines one). Never
      # fall through to add-item: skip loudly so a state change is not mis-filed as a new item.
      echo "scribe-step: backend '$SCRIBE_BACKEND' defines no _backend_update_state op — cannot mark '$ref' $state (skipping, not filing)" >&2
      _report_and_cleanup "$mine" "⚠️ SKIPPED (not filed): $ref → $state — backend '$SCRIBE_BACKEND' has no update-state op" "SKIP"
      exit 0
    fi
    _BACKEND_RESULT=""
    _backend_update_state "$ref" "$state"
    sum="$ref → $state"
    [ "$_BACKEND_RESULT" = "DONE" ] || sum="$sum (no matching item — nothing changed)"
    _report_and_cleanup "$mine" "$sum" "${_BACKEND_RESULT:-NOCHANGE}"
    ;;
  skip)
    # The drainer classified the request as unmappable to any backend verb (neither a NEW item nor a
    # state change). Record it LOUDLY in the scribe report and drop the claim — NEVER file it as a new
    # issue. This is the safety valve that closes the junk-issue path for good. [issue #139]
    mine="${2:?claimed path}"; reason="${3:-unmappable request}"
    cd "$REPO" || exit 1
    echo "scribe-step: SKIPPED (not filed) — $reason" >&2
    _report_and_cleanup "$mine" "⚠️ SKIPPED (not filed): $reason" "SKIP"
    ;;
  finish)
    if ls "$Q"/*.req >/dev/null 2>&1; then echo "MORE"; exit 0; fi
    [ -n "${SCRIBE_TAB:-}" ] && herdr tab close "$SCRIBE_TAB" >/dev/null 2>&1 || true
    echo "STOP"
    ;;
  *) echo "usage: scribe-step.sh next | commit <path> <sum> | add-item <path> <text> | update-state <path> <ref> <state> | skip <path> <why> | finish" >&2; exit 2 ;;
esac
