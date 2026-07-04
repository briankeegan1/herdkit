#!/usr/bin/env bash
# scribe-step.sh — queue/git/report mechanics for the backlog drainer. The scribe Claude
# calls these so it only does the creative edit. Subcommands:
#   next                   reclaim stale claims (>5 min); wait up to $SCRIBE_POLL s for a
#                          request; atomically claim the oldest; git pull; print
#                          "CLAIMED <path>" + the request text, or "EMPTY".
#   commit <path> "<sum>"  file backend: add/commit/push $BACKLOG_FILE (pull-rebase retry on
#                          reject), write the live-view receipt, append to the inbox, fire a
#                          herdr notification, remove the claimed file.
#   add-item <path> "<t>"  API/changelog backend: dispatch the item to the backend (no file
#                          edit by the agent), then the same receipt/inbox/notify/cleanup.
#   finish                 race-safe stop: if the queue is now empty, close the scribe tab
#                          ($SCRIBE_TAB) and print STOP; else print MORE (keep draining).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/herd-config.sh"
# API backends read credentials from .herd/secrets (gitignored). The file/changelog backends
# never touch it — sourcing is best-effort and absent-file-safe so the zero-secret case is clean.
_SECRETS="$PROJECT_ROOT/.herd/secrets"
# shellcheck source=/dev/null
[ -f "$_SECRETS" ] && . "$_SECRETS"
unset _SECRETS
# Source the pluggable backend implementation keyed on SCRIBE_BACKEND (default: file).
_BACKEND_FILE="$HERE/backends/${SCRIBE_BACKEND}.sh"
[ -f "$_BACKEND_FILE" ] || { echo "scribe-step: unknown SCRIBE_BACKEND '${SCRIBE_BACKEND}' — no backends/${SCRIBE_BACKEND}.sh" >&2; exit 1; }
# shellcheck source=backends/file.sh
. "$_BACKEND_FILE"
unset _BACKEND_FILE
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
      [ "$waited" -ge "$POLL" ] && { echo "EMPTY"; exit 0; }
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
  finish)
    if ls "$Q"/*.req >/dev/null 2>&1; then echo "MORE"; exit 0; fi
    [ -n "${SCRIBE_TAB:-}" ] && herdr tab close "$SCRIBE_TAB" >/dev/null 2>&1 || true
    echo "STOP"
    ;;
  *) echo "usage: scribe-step.sh next | commit <path> <sum> | add-item <path> <text> | finish" >&2; exit 2 ;;
esac
