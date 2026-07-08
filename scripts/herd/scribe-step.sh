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
#   amend <path> <ref> <note>
#                          HERD-128: append a clarification/comment to an EXISTING item WITHOUT
#                          touching its state or title. file backend appends an indented dated
#                          "↳ note" line under the item's BACKLOG.md entry; linear/github post an
#                          issue comment; a backend with no amend op fails soft (skip, nothing
#                          posted). Ambiguous/unmatched <ref> → loud SKIP (skip-over-guess).
#   skip <path> "<why>"    The drainer classified the request as unmappable to any backend verb:
#                          record a LOUD line in the scribe report and drop the claim, filing
#                          NOTHING (never a junk new issue).
#   finish                 race-safe stop: if the queue is now empty, close the scribe tab
#                          ($SCRIBE_TAB) and print STOP; else print MORE (keep draining).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/herd-config.sh"
# Runtime driver shim: route the "scribed" notification through herd_driver_notify so a headless run
# records it in the durable notifications.log sink instead of firing a real desktop notification.
# shellcheck source=/dev/null
. "$HERE/driver.sh"
# journal.sh gives backend state-writes their attribution record (HERD-85): a tracker_write event per
# transition. Best-effort — the sourced journal_append can never break a caller. Attribute every
# backend dispatch from this drainer to the 'scribe' component (the explicit-ref reconcile path in
# agent-watch attributes its own writes 'reconcile' before this ever runs).
. "$HERE/journal.sh"
# Drainer singleton liveness (HERD-109): heartbeat helpers so a HUNG-but-listed drainer can be
# detected and reclaimed by scribe.sh. Best-effort; never affects this script's stdout.
. "$HERE/drainer-liveness.sh"
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
# Liveness heartbeat file for THIS project's scribe drainer (HERD-109). scribe.sh reads the SAME path
# to tell a hung drainer from a live one. Beat once here so EVERY subcommand (next/commit/finish/…) is
# a progress signal, and again each poll-loop iteration below so a long poll stays fresh.
HEARTBEAT="$TREES/.scribe.heartbeat"
mkdir -p "$Q"
cmd="${1:-}"
herd_drainer_heartbeat "$HEARTBEAT"

# _report_and_cleanup <claimed-path> <summary> <result> — shared post-write tail for both
# commit (file) and add-item (api/changelog): live-view receipt, inbox line, notify, unclaim.
_report_and_cleanup() {
  local mine="$1" sum="$2" out="$3" short
  short=$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo '-------')
  printf '%s · %s\n' "$sum" "$short" > "$RECEIPT"
  printf '[%s] %s · %s\n' "$(date '+%H:%M')" "$sum" "$short" >> "$INBOX"
  herd_driver_notify "✍️ Backlog scribed" "$sum" done
  rm -f "$mine"
  echo "$out $short"
}

# ── HERD-183: MECHANICAL planned-marker from an EXPLICIT sequencing clause ────────────────────────
# When a NEW item's body carries a machine-checkable "sequenced after HERD-<n>" contract, publishing
# the 📌 marker should not depend on the author (or the drainer) also remembering to run
# `herd backlog queue`: markers are the ONLY machine-readable sequencing signal, and a batch filed
# with sequencing in PROSE ONLY once let another operator legitimately pick an item up out of order.
# So after filing an Add, scribe-step parses the body for a CONSERVATIVE, ANCHORED pattern set and,
# if matched, auto-publishes the marker itself. Default-on is safe: it only publishes a plan the
# author already wrote in the body. Fail-soft everywhere; byte-identical when no clause is present.

# _scribe_seq_blocker <body> — echo the blocker's canonical HERD-id when <body> carries an EXPLICIT,
# ANCHORED sequencing clause; else echo nothing. CONSERVATIVE by design: only these HERD-id-anchored
# forms match (never fuzzy prose), each on a leading word boundary so "unblocked on HERD-9" and the
# like never false-fire. A bare "after HERD-<n>" does NOT match — only "after HERD-<n> merges" does.
#     hard-after HERD-<n> | sequence[d] after HERD-<n> | after HERD-<n> merges | blocked on HERD-<n>
# First match in reading order wins; the id is normalized to upper-case HERD-<n>.
_scribe_seq_blocker() {
  printf '%s' "$1" | python3 -c '
import sys, re
body = sys.stdin.read()
pats = [
    r"hard-after\s+HERD-(\d+)",
    r"sequenced?\s+after\s+HERD-(\d+)",
    r"after\s+HERD-(\d+)\s+merges",
    r"blocked\s+on\s+HERD-(\d+)",
]
best = None
for p in pats:
    # (?<![A-Za-z0-9]) = a leading word boundary so a keyword embedded in a longer word never matches.
    for m in re.finditer(r"(?<![A-Za-z0-9])" + p, body, re.IGNORECASE):
        if best is None or m.start() < best[0]:
            best = (m.start(), m.group(1))
if best:
    sys.stdout.write("HERD-" + best[1])
' 2>/dev/null || true
}

# _scribe_new_item_ref <add-stdout-file> — print a queue-able ref for the item a backend just created,
# extracted from that backend's add stdout. Linear/Jira surface an identifier (HERD-184 / PROJ-12) —
# either bare or inside the issue URL; GitHub surfaces an issue URL (…/issues/42 → #42). Nothing
# recognizable (e.g. the file backend, which surfaces no id) → empty, and the caller fails soft.
_scribe_new_item_ref() {
  python3 - "$1" <<'PY' 2>/dev/null || true
import sys, re
try:
    txt = open(sys.argv[1], encoding="utf-8").read()
except OSError:
    sys.exit(0)
m = re.search(r"\b([A-Z][A-Z0-9]*-\d+)\b", txt)   # linear/jira key (also matches inside a URL)
if m:
    sys.stdout.write(m.group(1)); sys.exit(0)
m = re.search(r"/issues/(\d+)\b", txt)            # github issue URL
if m:
    sys.stdout.write("#" + m.group(1))
PY
}

# _scribe_auto_marker <backend> <add-result> <add-stdout-file> <blocker> — after an Add whose body
# carried an anchored sequencing clause, publish the 📌 planned-marker on the NEW item by shelling out
# to the real `herd backlog queue <new-id> --after <blocker>` (the same command a coordinator runs by
# hand). FAIL-SOFT throughout — the item is already filed; the marker is advisory:
#   - only runs when the Add actually created an item (add-result = DONE);
#   - needs a machine id for the new item (from the backend's add stdout); none surfaced → soft note;
#   - a missing herd CLI, a backend with no queue op, or a non-zero queue exit → soft note on stderr.
# HERD_CLI overrides the herd binary (test seam, mirroring SCRIBE_BACKEND_DIR); production resolves the
# engine's own bin/herd (this script lives at scripts/herd/), then falls back to herd on PATH.
_scribe_auto_marker() {
  local backend="$1" result="$2" out_file="$3" blocker="$4" new_id herd_bin
  [ "$result" = "DONE" ] || return 0
  new_id="$(_scribe_new_item_ref "$out_file")"
  if [ -z "$new_id" ]; then
    echo "scribe-step: sequencing clause 'after $blocker' found but backend '$backend' surfaced no id for the new item — 📌 marker not auto-published. [HERD-183]" >&2
    return 0
  fi
  herd_bin="${HERD_CLI:-}"
  [ -n "$herd_bin" ] || herd_bin="$HERE/../../bin/herd"
  [ -x "$herd_bin" ] || herd_bin="$(command -v herd 2>/dev/null || true)"
  if [ -z "$herd_bin" ] || { [ ! -x "$herd_bin" ] && ! command -v "$herd_bin" >/dev/null 2>&1; }; then
    echo "scribe-step: no herd CLI on PATH — cannot auto-publish 📌 marker for $new_id after $blocker. [HERD-183]" >&2
    return 0
  fi
  if "$herd_bin" backlog queue "$new_id" --after "$blocker" >/dev/null 2>&1; then
    echo "📌 sequenced $new_id after $blocker (auto-published from the item's sequencing clause). [HERD-183]"
  else
    echo "scribe-step: auto-marker 'herd backlog queue $new_id --after $blocker' did not publish (queue op absent/unsupported, or item unresolved) — item already filed, skipping. [HERD-183]" >&2
  fi
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
      herd_drainer_heartbeat "$HEARTBEAT"   # keep the beat fresh across a long poll/linger wait
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
    # HERD-183: parse the body FIRST (pure text). With no explicit sequencing clause we take the
    # unchanged path below — byte-identical to before, nothing extra published.
    _seq_blocker="$(_scribe_seq_blocker "$text")"
    if [ -n "$_seq_blocker" ]; then
      # A clause is present: capture the backend's add stdout so we can read the NEW item's id and
      # queue it after the blocker. Redirecting a plain function call keeps _BACKEND_RESULT in THIS
      # shell (a $()/pipe would run _backend_add_item in a subshell and lose it); we replay the
      # captured stdout verbatim so the drainer's output is unchanged.
      _add_out="$TREES/.scribe-add-out.$$"
      _backend_add_item "$mine" "$text" > "$_add_out"
      cat "$_add_out"
      _scribe_auto_marker "$SCRIBE_BACKEND" "$_BACKEND_RESULT" "$_add_out" "$_seq_blocker"
      rm -f "$_add_out"
    else
      _backend_add_item "$mine" "$text"
    fi
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
  amend)
    # First-class AMEND (HERD-128): append a clarification/comment to an EXISTING item WITHOUT
    # changing its state or title. The drainer classified the request as "append this note to item
    # <ref>". Unlike update-state this is supported by EVERY backend that defines the op, INCLUDING
    # file (the append is mechanical + deterministic, so scribe-step owns it rather than the drainer's
    # creative edit): linear/github post an issue comment; the file backend appends an indented dated
    # "↳ note" line under the item's BACKLOG.md entry. An ambiguous or unmatched <ref> is a LOUD SKIP
    # (skip-over-guess) — NOTHING is posted. Every amend journals a tracker_write requested=amend
    # (component=scribe) via the backend's _backend_tw_journal (HERD-85 attribution contract).
    mine="${2:?claimed path}"; ref="${3:?item ref}"; note="${4:?note text}"
    cd "$REPO" || exit 1
    if ! command -v _backend_amend >/dev/null 2>&1; then
      # A backend with no amend op (e.g. changelog — an append-only tracker with no per-item comment
      # surface). FAIL-SOFT: print a soft note and record a skip; never file or post anything.
      echo "scribe-step: backend '$SCRIBE_BACKEND' has no amend op — cannot attach a note to '$ref' (skipping, nothing posted)" >&2
      _report_and_cleanup "$mine" "⚠️ SKIPPED (not filed): amend $ref — backend '$SCRIBE_BACKEND' has no amend op" "SKIP"
      exit 0
    fi
    _BACKEND_RESULT=""
    _backend_amend "$ref" "$note"
    if [ "$_BACKEND_RESULT" = "DONE" ]; then
      _report_and_cleanup "$mine" "↳ amended $ref" "DONE"
    else
      # No unique matching item (ambiguous or not found): the backend already warned loudly on stderr
      # and posted nothing. Record a SKIP so the report is honest — never a silent no-op.
      _report_and_cleanup "$mine" "⚠️ SKIPPED (not posted): amend $ref — no unique matching item (ambiguous or not found)" "SKIP"
    fi
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
  *) echo "usage: scribe-step.sh next | commit <path> <sum> | add-item <path> <text> | update-state <path> <ref> <state> | amend <path> <ref> <note> | skip <path> <why> | finish" >&2; exit 2 ;;
esac
