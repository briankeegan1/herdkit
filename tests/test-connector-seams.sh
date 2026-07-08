#!/usr/bin/env bash
# test-connector-seams.sh — hermetic, ZERO-NETWORK proof for the HERD-170 connector seams
# (edges-only). Drives the REAL templates (templates/connector-fetch.sh, templates/connector-post.sh)
# and the REAL post-merge seam of scripts/herd/steps.sh — no mirrors, no network. Covers:
#   (1) worked flow FETCH → SCREEN → POST: a stubbed fetch lands a file, a screen pass filters it,
#       and the POST edge — run through steps.sh's post-merge seam — delivers it to a stubbed sink.
#   (2) ship-dormant: no URL ⇒ each edge is a byte-identical no-op (writes nothing, exits 0).
#   (3) fail-soft: a failing fetch keeps any prior output (stale-ok) and exits 0; a failing post
#       under on_fail=warn does not block the seam.
# Run:  bash tests/test-connector-seams.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
FETCH="$ROOT/templates/connector-fetch.sh"
POST="$ROOT/templates/connector-post.sh"
STEPS="$ROOT/scripts/herd/steps.sh"

for f in "$FETCH" "$POST" "$STEPS"; do
  [ -f "$f" ] || { echo "FAIL: missing $f" >&2; exit 1; }
done

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
NOCFG="$T/.no-config"      # a path that does NOT exist ⇒ herd-config.sh won't walk into a real repo

pass=0; fail=0
ok()    { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()   { fail=$((fail+1)); printf '  FAIL %s\n' "$1" >&2; }
check() { if eval "$2"; then ok "$1"; else bad "$1 — ($2)"; fi; }

# ══════════════════════════════════════════════════════════════════════════════════════════════════
echo "── (1) worked flow: FETCH → SCREEN → POST (stubbed endpoints, zero network) ────────────────────"
# A local fixture stands in for the remote API — the FETCH stub just cats it (no network).
FIX="$T/api.tsv"
printf 'KEEP\tone\nDRAFT\thidden\nKEEP\ttwo\n' > "$FIX"
OUT="$T/inbox/items.tsv"

# FETCH edge: stub the fetch mechanism at the fixture, and screen out DRAFT rows on the way in.
env CONNECTOR_FETCH_URL="https://api.example.test/items" \
    CONNECTOR_FETCH_OUT="$OUT" \
    CONNECTOR_FETCH_CMD="cat '$FIX'" \
    CONNECTOR_FETCH_SCREEN='grep "^KEEP"' \
    bash "$FETCH"
frc=$?
check "fetch exits 0"                         "[ '$frc' -eq 0 ]"
check "fetch wrote the OUT file"              "[ -f '$OUT' ]"
check "screen kept the KEEP rows"            "grep -q 'KEEP.*one' '$OUT' && grep -q 'KEEP.*two' '$OUT'"
check "screen dropped the DRAFT row"          "! grep -q DRAFT '$OUT'"

# POST edge, driven through the REAL steps.sh post-merge seam. A throwaway git repo gives a real HEAD
# sha; a steps.tsv row wires connector-post.sh as a post-merge step; the POST is stubbed to a local sink.
REPO="$T/repo"; TREES="$T/trees"; mkdir -p "$REPO" "$TREES"
git -C "$REPO" init -q
git -C "$REPO" config user.email t@herd.test
git -C "$REPO" config user.name  herd-test
git -C "$REPO" config commit.gpgsign false
printf 'x\n' > "$REPO/f.txt"; git -C "$REPO" add f.txt; git -C "$REPO" commit -qm one

SINK="$T/sink.log"
STEPS_FILE="$T/steps.tsv"
# The documented POST-MERGE row: connector-post, post-merge, on_fail=warn (fail-soft), hold=none.
printf 'connector-post\tpost-merge\tbash %s\twarn\tnone\n' "$POST" > "$STEPS_FILE"

# The POST stub sink writes the payload to a local file instead of hitting an endpoint (zero network).
prc=0
env HERD_CONFIG_FILE="$NOCFG" PROJECT_ROOT="$REPO" WORKTREES_DIR="$TREES" \
    HERD_STEPS_FILE="$STEPS_FILE" JOURNAL_FILE="$T/journal.jsonl" NO_COLOR=1 HERD_DRIVER=headless \
    CONNECTOR_POST_URL="https://hooks.example.test/notify" \
    CONNECTOR_POST_PAYLOAD="$OUT" \
    CONNECTOR_POST_CMD='cat "$CONNECTOR_PAYLOAD" >> '"$SINK" \
    bash "$STEPS" run post-merge --slug conn --dir "$REPO" >/dev/null 2>&1 || prc=$?
check "post-merge seam exits 0"               "[ '$prc' -eq 0 ]"
check "the POST edge delivered the payload to the stubbed sink" "[ -f '$SINK' ] && diff -q '$OUT' '$SINK' >/dev/null"
check "a step_run pass was journaled for connector-post" \
  "grep -q '\"name\":\"connector-post\".*\"outcome\":\"pass\"' '$T/journal.jsonl'"

# ══════════════════════════════════════════════════════════════════════════════════════════════════
echo "── (2) ship-dormant: no URL ⇒ byte-identical no-op ─────────────────────────────────────────────"
DORM="$T/dormant-out"
drc=0; env CONNECTOR_FETCH_OUT="$DORM" bash "$FETCH" || drc=$?      # URL unset ⇒ dormant
check "dormant fetch exits 0"                 "[ '$drc' -eq 0 ]"
check "dormant fetch wrote NOTHING"           "[ ! -e '$DORM' ]"

SINK2="$T/sink2.log"
drc2=0; env CONNECTOR_POST_PAYLOAD="$OUT" CONNECTOR_POST_CMD='cat "$CONNECTOR_PAYLOAD" >> '"$SINK2" \
    bash "$POST" || drc2=$?                                          # URL unset ⇒ dormant
check "dormant post exits 0"                  "[ '$drc2' -eq 0 ]"
check "dormant post delivered NOTHING"        "[ ! -e '$SINK2' ]"

# ══════════════════════════════════════════════════════════════════════════════════════════════════
echo "── (3) fail-soft: a failing fetch keeps the prior output and never wedges ───────────────────────"
STALE="$T/stale.tsv"; printf 'previous\n' > "$STALE"
src=0; env CONNECTOR_FETCH_URL="https://api.example.test/items" \
           CONNECTOR_FETCH_OUT="$STALE" \
           CONNECTOR_FETCH_CMD='exit 7' \
           bash "$FETCH" || src=$?
check "failing fetch is fail-soft (exits 0)"  "[ '$src' -eq 0 ]"
check "failing fetch kept the prior output"   "grep -q previous '$STALE'"

# STRICT flips the same failure hard.
hrc=0; env CONNECTOR_FETCH_URL="https://api.example.test/items" \
           CONNECTOR_FETCH_OUT="$T/strict.out" \
           CONNECTOR_FETCH_CMD='exit 7' \
           CONNECTOR_FETCH_STRICT=1 \
           bash "$FETCH" || hrc=$?
check "STRICT fetch fails hard (non-zero)"    "[ '$hrc' -ne 0 ]"

# ══════════════════════════════════════════════════════════════════════════════════════════════════
echo
if [ "$fail" -eq 0 ]; then
  echo "✅ test-connector-seams: ALL PASS ($pass checks)."
  exit 0
else
  echo "❌ test-connector-seams: $fail failed, $pass passed." >&2
  exit 1
fi
