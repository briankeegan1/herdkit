#!/usr/bin/env bash
# connector-fetch.sh (TEMPLATE) — the FETCH edge of the herdkit connector seams (HERD-170).
#
# A small, reusable PRE-RUN converter: pull from a URL/API and land the bytes in a FILE that
# your workflow/pipeline then reads. This is the ONE network touch — it runs BEFORE the run,
# writes a plain file, and the workflow only ever reads that file. No per-service code, no
# in-workflow API calls, no catalog: just an edge that turns "a URL" into "a file on disk".
#
# Copy this to your project (e.g. .herd/connector-fetch.sh) and wire it as the first thing your
# pipeline/skill/command runs, OR call it by hand before a run. It is deliberately generic; the
# project supplies the URL, the destination, and (optionally) how to fetch + how to screen.
#
# ── Conventions (HERD-170) ─────────────────────────────────────────────────────────────────────
#   • DEFAULT-OFF / SHIP-DORMANT: with no CONNECTOR_FETCH_URL set, this does NOTHING, touches
#     NOTHING, and exits 0. Dropping the file into a project is byte-identical to not having it
#     until an operator opts in by setting the URL.
#   • FAIL-SOFT: a fetch/screen error never wedges the run. By default it warns, keeps any
#     PRIOR output file (stale-ok), and exits 0. Set CONNECTOR_FETCH_STRICT=1 to make errors hard.
#   • ATOMIC: bytes are fetched to a temp file and moved into place only on success, so a reader
#     never sees a half-written file, and a failed fetch never clobbers a good previous copy.
#
# ── Knobs (all via env; a project sets these in .herd/config, a wrapper, or the caller's env) ───
#   CONNECTOR_FETCH_URL      source URL/API. EMPTY ⇒ dormant no-op (the ship-dormant switch).
#   CONNECTOR_FETCH_OUT      destination file the workflow reads. Required once URL is set.
#   CONNECTOR_FETCH_CMD      OVERRIDE the fetch mechanism — a shell command run with $CONNECTOR_URL
#                            in its env, expected to write the payload to STDOUT. This is the STUB
#                            SEAM: tests point it at a local fixture for a ZERO-NETWORK run
#                            (e.g. CONNECTOR_FETCH_CMD='cat fixtures/api.json'). Default: curl, else wget.
#   CONNECTOR_FETCH_SCREEN   OPTIONAL transform/filter applied to the fetched bytes (a "screen"
#                            pass). Reads the payload on STDIN, writes the screened payload to
#                            STDOUT (e.g. 'grep -v DRAFT' or a jq projection). Also fail-soft.
#   CONNECTOR_FETCH_STRICT   0 (default) fail-soft · 1 fail-hard (a fetch/screen error exits non-zero).
#
# Exit codes: 0 = wrote the file, OR dormant, OR fail-soft skip · non-zero only under STRICT=1.
set -uo pipefail

URL="${CONNECTOR_FETCH_URL:-}"
OUT="${CONNECTOR_FETCH_OUT:-}"
FETCH_CMD="${CONNECTOR_FETCH_CMD:-}"
SCREEN_CMD="${CONNECTOR_FETCH_SCREEN:-}"
STRICT="${CONNECTOR_FETCH_STRICT:-0}"

log() { printf 'connector-fetch: %s\n' "$*" >&2; }
# soft <rc> — honor fail-soft/strict: under STRICT exit <rc>, otherwise swallow it and exit 0.
soft() { [ "$STRICT" = "1" ] && exit "${1:-1}"; exit 0; }

# DORMANT: no URL ⇒ do nothing at all. Byte-identical to the converter not being wired in.
[ -n "$URL" ] || exit 0

if [ -z "$OUT" ]; then
  log "CONNECTOR_FETCH_URL is set but CONNECTOR_FETCH_OUT is empty — nowhere to write."
  soft 2
fi

# Fetch into a TEMP file so a reader never sees a partial write and a failure can't clobber OUT.
tmp="$(mktemp "${TMPDIR:-/tmp}/connector-fetch.XXXXXX" 2>/dev/null)" || { log "mktemp failed"; soft 1; }
trap 'rm -f "$tmp" "$tmp.screen" 2>/dev/null' EXIT

rc=0
if [ -n "$FETCH_CMD" ]; then
  # The stub seam: run the operator/test-supplied command with $CONNECTOR_URL in env, capture stdout.
  CONNECTOR_URL="$URL" bash -c "$FETCH_CMD" > "$tmp" 2>/dev/null || rc=$?
elif command -v curl >/dev/null 2>&1; then
  curl -fsSL "$URL" > "$tmp" 2>/dev/null || rc=$?
elif command -v wget >/dev/null 2>&1; then
  wget -qO- "$URL" > "$tmp" 2>/dev/null || rc=$?
else
  log "no fetch mechanism available (set CONNECTOR_FETCH_CMD, or install curl/wget)"
  rc=127
fi

if [ "$rc" -ne 0 ]; then
  log "fetch failed (rc=$rc) from: $URL"
  [ -f "$OUT" ] && log "keeping existing $OUT (stale-ok)"
  soft "$rc"
fi

# OPTIONAL screen/transform pass. Fail-soft on its own account.
if [ -n "$SCREEN_CMD" ]; then
  if CONNECTOR_URL="$URL" bash -c "$SCREEN_CMD" < "$tmp" > "$tmp.screen" 2>/dev/null; then
    mv -f "$tmp.screen" "$tmp" 2>/dev/null || { log "could not stage screened payload"; soft 1; }
  else
    log "screen step failed: $SCREEN_CMD"
    [ -f "$OUT" ] && log "keeping existing $OUT (stale-ok)"
    soft 1
  fi
fi

# Atomic publish: create the parent dir if needed, then move the finished payload into place.
mkdir -p "$(dirname "$OUT")" 2>/dev/null || true
if mv -f "$tmp" "$OUT" 2>/dev/null; then
  trap - EXIT
  log "wrote $OUT ($(wc -c < "$OUT" 2>/dev/null | tr -d ' ') bytes) from: $URL"
  exit 0
fi
log "could not write $OUT"
soft 1
