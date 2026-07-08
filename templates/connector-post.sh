#!/usr/bin/env bash
# connector-post.sh (TEMPLATE) — the POST edge of the herdkit connector seams (HERD-170).
#
# The POST edge reuses an EXISTING seam rather than adding a new one: the pipeline-steps runner
# (HERD-132, scripts/herd/steps.sh) already lets an operator plug a shell command in at the
# post-merge seam. This template is that command — a generic "take a file, POST it to an
# endpoint" step you wire into .herd/steps.tsv. There is no new engine code; the connector is
# just a documented + templated use of steps.tsv's post-merge-command seam.
#
# ── Wire it as a POST-MERGE step in .herd/steps.tsv (one TAB-separated row) ─────────────────────
#     connector-post<TAB>post-merge<TAB>bash .herd/connector-post.sh<TAB>warn<TAB>none
#   • at=post-merge  ⇒ runs in the WATCHER's merge sequence AFTER the merge lands (shell step).
#   • on_fail=warn   ⇒ FAIL-SOFT: a dead endpoint journals a warn + continues; it never blocks a
#                      merge or wedges the lane. (Use on_fail=block only if the post is a gate.)
#   • hold=none      ⇒ no human hold.
#   An ABSENT/empty steps.tsv row ⇒ this never runs ⇒ byte-identical pipeline (ship-dormant).
#
# ── Conventions (HERD-170) ─────────────────────────────────────────────────────────────────────
#   • DEFAULT-OFF / SHIP-DORMANT: with no CONNECTOR_POST_URL set, this does NOTHING and exits 0
#     (and it only ever runs at all if an operator adds the steps.tsv row above).
#   • FAIL-SOFT: an unreachable endpoint warns and exits 0 by default (pair with on_fail=warn so
#     the seam is soft end to end). Set CONNECTOR_POST_STRICT=1 to make a failed POST hard.
#
# ── Knobs (all via env; set in .herd/config, a wrapper, or the watcher's env) ───────────────────
#   CONNECTOR_POST_URL       destination endpoint. EMPTY ⇒ dormant no-op (the ship-dormant switch).
#   CONNECTOR_POST_PAYLOAD   OPTIONAL file to POST as the body (e.g. the screened fetch output).
#   CONNECTOR_POST_CMD       OVERRIDE the POST mechanism — a shell command run with $CONNECTOR_URL
#                            and $CONNECTOR_PAYLOAD in its env. This is the STUB SEAM: tests point
#                            it at a local sink for a ZERO-NETWORK run (e.g. append to a file).
#                            Default: curl -X POST (--data-binary @PAYLOAD when a payload is given).
#   CONNECTOR_POST_STRICT    0 (default) fail-soft · 1 fail-hard (a failed POST exits non-zero).
#
# Exit codes: 0 = posted, OR dormant, OR fail-soft skip · non-zero only under STRICT=1.
set -uo pipefail

URL="${CONNECTOR_POST_URL:-}"
PAYLOAD="${CONNECTOR_POST_PAYLOAD:-}"
POST_CMD="${CONNECTOR_POST_CMD:-}"
STRICT="${CONNECTOR_POST_STRICT:-0}"

log() { printf 'connector-post: %s\n' "$*" >&2; }
soft() { [ "$STRICT" = "1" ] && exit "${1:-1}"; exit 0; }

# DORMANT: no endpoint ⇒ do nothing. Byte-identical to the connector not being wired in.
[ -n "$URL" ] || exit 0

# A named-but-missing payload is a soft skip (nothing to send), never a wedge.
if [ -n "$PAYLOAD" ] && [ ! -f "$PAYLOAD" ]; then
  log "payload file not found: $PAYLOAD"
  soft 2
fi

rc=0
if [ -n "$POST_CMD" ]; then
  # The stub seam: run the operator/test-supplied command with the URL + payload path in env.
  CONNECTOR_URL="$URL" CONNECTOR_PAYLOAD="$PAYLOAD" bash -c "$POST_CMD" || rc=$?
elif command -v curl >/dev/null 2>&1; then
  if [ -n "$PAYLOAD" ]; then
    curl -fsS -X POST --data-binary @"$PAYLOAD" "$URL" >/dev/null 2>&1 || rc=$?
  else
    curl -fsS -X POST "$URL" >/dev/null 2>&1 || rc=$?
  fi
else
  log "no POST mechanism available (set CONNECTOR_POST_CMD, or install curl)"
  rc=127
fi

if [ "$rc" -ne 0 ]; then
  log "POST failed (rc=$rc) to: $URL"
  soft "$rc"
fi
log "posted${PAYLOAD:+ $PAYLOAD} to: $URL"
exit 0
