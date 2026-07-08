#!/usr/bin/env bash
# research-step.sh — queue/report mechanics for the READ-ONLY research drainer. The researcher
# Claude calls these so it only does the creative work (fan-out + synthesis). Subcommands:
#   next                          reclaim stale claims (>5 min); wait up to $RESEARCH_POLL s for a
#                                 request; atomically claim the oldest; print "CLAIMED <path>" then
#                                 the REQ_ID then the question text, or "EMPTY". Read-only: it does
#                                 NOT git pull or touch the main checkout.
#   report <path> <findings>      move the findings file to research-reports/<REQ_ID>.md (id derived
#                                 from the claimed filename), append a line to the .research-reports
#                                 inbox, fire a herdr notification, remove the claimed file.
#   finish                        race-safe stop: if the queue is now empty, close the researcher
#                                 tab ($RESEARCH_TAB) and print STOP; else print MORE (keep draining).
#
# Paths honor env overrides (RESEARCH_TREES / RESEARCH_QUEUE / RESEARCH_REPORTS / RESEARCH_INBOX)
# so the queue mechanics can be exercised hermetically against a temp dir without touching $HOME.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/herd-config.sh"
# Runtime driver shim: route the "research ready" notification through herd_driver_notify so a headless
# run records it in the durable notifications.log sink instead of firing a real desktop notification.
# shellcheck source=/dev/null
. "$HERE/driver.sh"
# Drainer singleton liveness (HERD-109): heartbeat helpers so a HUNG-but-listed researcher drainer can
# be detected and reclaimed by research.sh. Best-effort; never affects this script's stdout.
. "$HERE/drainer-liveness.sh"
TREES="${RESEARCH_TREES:-$WORKTREES_DIR}"
Q="${RESEARCH_QUEUE:-$TREES/research-queue}"
REPORTS="${RESEARCH_REPORTS:-$TREES/research-reports}"
INBOX="${RESEARCH_INBOX:-$TREES/.research-reports}"
POLL="${RESEARCH_POLL:-25}"
# Liveness heartbeat file for THIS project's researcher drainer (HERD-109). research.sh reads the SAME
# path to tell a hung drainer from a live one. Beat once here so EVERY subcommand is a progress signal,
# and again each poll-loop iteration below so a long poll stays fresh.
HEARTBEAT="${RESEARCH_HEARTBEAT:-$TREES/.research.heartbeat}"
mkdir -p "$Q"
cmd="${1:-}"
herd_drainer_heartbeat "$HEARTBEAT"

case "$cmd" in
  next)
    # reclaim claims abandoned by a dead drainer
    find "$Q" -name '*.mine' -mmin +5 -exec sh -c 'mv -f "$1" "${1%.mine}"' _ {} \; 2>/dev/null || true
    waited=0
    while :; do
      # Atomic claim: walk the queue oldest-first and try to win each candidate via an atomic
      # rename. If the mv fails another drainer already claimed that file — skip to the NEXT
      # candidate instead of processing a file we did not win.
      claimed=""
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        if mv "$f" "$f.mine" 2>/dev/null; then
          claimed="$f.mine"; break
        fi
      done < <(ls -1 "$Q"/*.req 2>/dev/null | sort)
      if [ -n "$claimed" ]; then
        # Read-only lane: do NOT git pull / mutate the main checkout. Derive the id from the
        # filename so the drainer can echo it straight to the coordinator.
        id="$(basename "$claimed")"; id="${id%.req.mine}"
        echo "CLAIMED $claimed"; echo "$id"; cat "$claimed"; exit 0
      fi
      [ "$waited" -ge "$POLL" ] && { echo "EMPTY"; exit 0; }
      sleep 2; waited=$((waited+2))
      herd_drainer_heartbeat "$HEARTBEAT"   # keep the beat fresh across a long poll wait
    done
    ;;
  report)
    mine="${2:?claimed path}"; findings="${3:?findings file}"
    [ -f "$findings" ] || { echo "REPORTFAIL no such findings file: $findings" >&2; exit 1; }
    id="$(basename "$mine")"; id="${id%.req.mine}"
    question="$(cat "$mine" 2>/dev/null || true)"
    mkdir -p "$REPORTS"
    mv -f "$findings" "$REPORTS/$id.md"
    printf '[%s] %s · %s\n' "$(date '+%H:%M')" "$id" "$question" >> "$INBOX"
    herd_driver_notify "🔎 Research ready" "$id: $question" done
    rm -f "$mine"
    echo "DONE $id → $REPORTS/$id.md"
    ;;
  finish)
    if ls "$Q"/*.req >/dev/null 2>&1; then echo "MORE"; exit 0; fi
    [ -n "${RESEARCH_TAB:-}" ] && herdr tab close "$RESEARCH_TAB" >/dev/null 2>&1 || true
    echo "STOP"
    ;;
  *) echo "usage: research-step.sh next | report <path> <findings> | finish" >&2; exit 2 ;;
esac
