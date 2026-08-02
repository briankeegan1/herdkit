#!/usr/bin/env bash
# test-block-verdict-reason.sh — hermetic proof that a BLOCK verdict records a MACHINE-READABLE reason
# and that the operator surfaces render it (HERD-473, mirror of GH #576).
#
# The incident: a PR was blocked by the review gate and the reason was discoverable NOWHERE. The
# journal recorded `verdict_recorded … value=BLOCK` and nothing else; the documented tool for exactly
# this question — `herd approve why <pr#>` — printed the verdict and then THE LATEST PR COMMENT, which
# happened to be an approving one. A coordinator was left with a blocked PR, no stated objection to
# evaluate, and only a blind `herd approve override` as a way forward.
#
# What this locks in:
#   (1) _compose_block_reason parses herd-review.sh's structured BLOCK line into ONE canonical line,
#       in lockstep with live_runtime.py's parse_block_reason (the two cores must agree or an operator
#       reads different text depending on which one recorded the verdict).
#   (2) record_review writes that reason as the ledger row's TRAILING field AND as a `reason` key on
#       verdict_recorded — the five positional fields every other reader parses are untouched.
#   (3) BYTE-IDENTICAL with no reason: a PASS, and any reason-less verdict, write exactly the row and
#       the event they wrote before this field existed.
#   (4) `herd approve why` prints the reason, and when there is NONE it says so explicitly and labels
#       the PR comment as context — it never lets other text read as the gate's objection.
#   (5) The journal is a DURABLE fallback for `why`: a purged/reason-less ledger still answers.
#
# Fully hermetic: agent-watch.sh sourced in LIB mode (AGENT_WATCH_LIB=1 → helpers only, no loop), and
# herd-approve.sh run against a temp WORKTREES_DIR with `gh` shadowed so no network is reachable.
# NO herdr, NO gh, NO model. python3 is a herd hard dep (for journal.sh).
# Run:  bash tests/test-block-verdict-reason.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WATCH="$ROOT/scripts/herd/agent-watch.sh"
APPROVE="$ROOT/scripts/herd/herd-approve.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ PASS=$((PASS+1)); echo "PASS $1"; }

[ -f "$WATCH" ]   || fail "missing agent-watch.sh at $WATCH"
[ -f "$APPROVE" ] || fail "missing herd-approve.sh at $APPROVE"

# `gh` must never be reached: every assertion here is about LOCALLY recorded state. A regression that
# starts asking the network for the reason fails loudly instead of hanging.
mkdir -p "$T/bin"
printf '#!/bin/sh\necho "gh was invoked" >&2\nexit 127\n' > "$T/bin/gh"; chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH" NO_COLOR=1

BLOCK_LINE='REVIEW: BLOCK — rule: unchecked nil deref | why: cand.sha may be empty on an adopted PR | location: live_runtime.py:3120'
BLOCK_REASON='rule: unchecked nil deref | why: cand.sha may be empty on an adopted PR | location: live_runtime.py:3120'

source_watcher() {
  export AGENT_WATCH_LIB=1
  export HERD_CONFIG_FILE="$T/no-such-config"
  export WORKTREES_DIR="$1"
  export TREES="$1"
  export JOURNAL_FILE="$1/journal.jsonl"
  mkdir -p "$1" 2>/dev/null || true
  # shellcheck source=/dev/null
  . "$WATCH" || { echo "__SOURCE_FAILED__"; exit 1; }
}

# ── (1) the parse: structured, legacy-freeform, partial, and garbage ─────────────────────────────
(
  source_watcher "$T/parse"
  got="$(_compose_block_reason "$BLOCK_LINE")"
  [ "$got" = "$BLOCK_REASON" ] || { echo "structured: got '$got'"; exit 1; }
  got="$(_compose_block_reason 'REVIEW: BLOCK — the merge loses the last commit')"
  [ "$got" = "why: the merge loses the last commit" ] || { echo "legacy: got '$got'"; exit 1; }
  got="$(_compose_block_reason 'REVIEW: BLOCK — why: wrong sign | location: a.sh:3')"
  [ "$got" = "why: wrong sign | location: a.sh:3" ] || { echo "partial: got '$got'"; exit 1; }
  # canonical ORDER, not the reviewer's emission order — one shape for the operator to read.
  got="$(_compose_block_reason 'REVIEW: BLOCK — location: a.sh:3 | rule: R | why: W')"
  [ "$got" = "rule: R | why: W | location: a.sh:3" ] || { echo "order: got '$got'"; exit 1; }
  # nothing parseable ⇒ empty, never a partial or a crash
  [ -z "$(_compose_block_reason 'REVIEW: BLOCK')" ] || { echo "bare BLOCK produced a reason"; exit 1; }
  [ -z "$(_compose_block_reason '')" ] || { echo "empty line produced a reason"; exit 1; }
  _compose_block_reason 'REVIEW: BLOCK — | | |' >/dev/null || { echo "garbage raised"; exit 1; }
  exit 0
) || fail "(1) _compose_block_reason did not parse the BLOCK contract"
ok "(1) _compose_block_reason: structured, legacy-freeform, partial, canonical order, garbage-safe"

# (1b) CROSS-CORE LOCKSTEP: the bash twin and live_runtime.py's parse_block_reason must agree, or an
#      operator reads different text depending on which core recorded the verdict.
(
  source_watcher "$T/lockstep"
  for line in \
    "$BLOCK_LINE" \
    'REVIEW: BLOCK — the merge loses the last commit' \
    'REVIEW: BLOCK — why: wrong sign | location: a.sh:3' \
    'REVIEW: BLOCK — location: a.sh:3 | rule: R | why: W' \
    'REVIEW: BLOCK' \
    'REVIEW: PASS — advisory: rename this'
  do
    b="$(_compose_block_reason "$line")"
    p="$(HERD_LINE="$line" PYTHONPATH="$ROOT/pysrc" python3 -c '
import os, sys
from herd.live_runtime import parse_block_reason
sys.stdout.write(parse_block_reason(os.environ["HERD_LINE"]))' 2>/dev/null)" \
      || { echo "python twin failed on: $line"; exit 1; }
    [ "$b" = "$p" ] || { echo "DIVERGED on '$line': bash='$b' python='$p'"; exit 1; }
  done
  exit 0
) || fail "(1b) the bash and python BLOCK-reason parsers diverged"
ok "(1b) _compose_block_reason and live_runtime.parse_block_reason agree on every shape"

# ── (2) record_review persists the reason to the ledger row AND the journal event ─────────────────
(
  WT="$T/record"; source_watcher "$WT"
  record_review 30 a5243cc5 BLOCK reviewer "$BLOCK_REASON"
  row="$(cat "$WT/.agent-watch-reviewed")"
  # the FIVE positional fields every other reader parses are untouched…
  [ "$(printf '%s' "$row" | awk '{print $2" "$3" "$4" "$5}')" = "30 a5243cc5 BLOCK reviewer" ] \
    || { echo "positional fields disturbed: $row"; exit 1; }
  # …and the reason is the TRAILING field
  [ "$(printf '%s' "$row" | awk '{r=""; for(i=6;i<=NF;i++) r=(r==""?$i:r" "$i); print r}')" = "$BLOCK_REASON" ] \
    || { echo "trailing reason wrong: $row"; exit 1; }
  # the shipped readers still answer correctly over a row that now has a 6th+ field
  [ "$(review_verdict 30 a5243cc5)" = "BLOCK" ] || { echo "review_verdict broke on a reason row"; exit 1; }
  [ "$(review_verdict_source 30 a5243cc5)" = "reviewer" ] || { echo "review_verdict_source broke"; exit 1; }
  grep -q '"event":"verdict_recorded"' "$WT/journal.jsonl" || { echo "no verdict_recorded"; exit 1; }
  grep -q '"reason":"rule: unchecked nil deref | why: cand.sha may be empty on an adopted PR | location: live_runtime.py:3120"' \
    "$WT/journal.jsonl" || { echo "journal missing the reason: $(cat "$WT/journal.jsonl")"; exit 1; }
  exit 0
) || fail "(2) record_review did not persist the reason to the ledger + journal"
ok "(2) record_review: reason rides the ledger row's trailing field + verdict_recorded.reason"

# ── (3) BYTE-IDENTICAL when there is no reason ───────────────────────────────────────────────────
(
  WT="$T/inert"; source_watcher "$WT"
  record_review 31 deadbeef PASS reviewer                      # the pre-HERD-473 call shape
  record_review 32 cafebabe BLOCK reviewer ""                  # an explicitly empty reason
  while read -r _e _p _s _v _src _rest; do
    [ -z "${_rest:-}" ] || { echo "a reason-less row grew a field: $_e $_p $_s $_v $_src $_rest"; exit 1; }
  done < "$WT/.agent-watch-reviewed"
  [ "$(wc -l < "$WT/.agent-watch-reviewed" | tr -d ' ')" = "2" ] || { echo "row count wrong"; exit 1; }
  grep -q '"reason"' "$WT/journal.jsonl" && { echo "a reason-less verdict journaled a reason key"; exit 1; }
  exit 0
) || fail "(3) a reason-less verdict was not byte-identical to the pre-HERD-473 shape"
ok "(3) no reason ⇒ the ledger row and verdict_recorded are byte-identical to before the field existed"

# ── (3b) THE WIRING: the SHIPPED review gate carries the reason from the reviewer's result file ──
# (2)/(3) prove record_review; this proves the collect site actually CALLS it with the parsed reason,
# so the whole path from the reviewer's verdict line to the operator's surface is covered end to end.
(
  WT="$T/gate"; source_watcher "$WT"
  plant() {   # <pr> <sha> <verdict-line> → run the SHIPPED review gate over a planted result file
    local pr="$1" sha="$2" line="$3" rf; rf="$(_review_result_file "$pr" "$sha")"
    printf '%s\n' "$line" > "$rf.tmp.$$"; mv "$rf.tmp.$$" "$rf"
    _review_gate_step "$pr" "slug-$pr" "$sha"
  }
  [ "$(plant 60 s60 "$BLOCK_LINE")" = "BLOCK" ] || { echo "planted BLOCK not collected"; exit 1; }
  got="$(awk '$2==60 {r=""; for(i=6;i<=NF;i++) r=(r==""?$i:r" "$i); print r}' "$WT/.agent-watch-reviewed")"
  [ "$got" = "$BLOCK_REASON" ] || { echo "gate did not record the reason: '$got'"; exit 1; }
  grep -q '"pr":60' "$WT/journal.jsonl" && grep -q '"reason":"rule: unchecked nil deref' "$WT/journal.jsonl" \
    || { echo "gate did not journal the reason"; exit 1; }
  # A PASS through the same gate records none — the advisory tail is not an objection.
  [ "$(plant 61 s61 'REVIEW: PASS — advisory: rename this')" = "PASS" ] || { echo "planted PASS not collected"; exit 1; }
  got="$(awk '$2==61 {print NF}' "$WT/.agent-watch-reviewed")"
  [ "$got" = "5" ] || { echo "a PASS row grew fields: NF=$got"; exit 1; }
  exit 0
) || fail "(3b) the shipped review gate did not carry the reason from the result file to the ledger"
ok "(3b) _review_gate_step carries the reviewer's reason from the result file into ledger + journal"

# ── (4) `herd approve why` renders the reason ────────────────────────────────────────────────────
WT="$T/why"; mkdir -p "$WT"
printf '1720000000 30 a5243cc5 BLOCK reviewer %s\n' "$BLOCK_REASON" > "$WT/.agent-watch-reviewed"
out="$(HERD_CONFIG_FILE="$T/no-such-config" WORKTREES_DIR="$WT" bash "$APPROVE" why 30 2>&1)"
grep -q 'verdict:BLOCK' <<<"$out" || fail "(4) why did not print the verdict: $out"
grep -qF "$BLOCK_REASON" <<<"$out" || fail "(4) why did not print the recorded reason: $out"
grep -q 'Reason (recorded with the verdict)' <<<"$out" || fail "(4) why did not label the reason: $out"
ok "(4) herd approve why prints the reviewer's recorded reason"

# (4b) with NO reason recorded it SAYS so — and never lets the latest PR comment read as the objection.
WT="$T/why-none"; mkdir -p "$WT"
printf '1720000000 30 a5243cc5 BLOCK reviewer\n' > "$WT/.agent-watch-reviewed"
out="$(HERD_CONFIG_FILE="$T/no-such-config" WORKTREES_DIR="$WT" bash "$APPROVE" why 30 2>&1)"
grep -q 'Reason: none recorded' <<<"$out" || fail "(4b) why did not state the reason is missing: $out"
grep -q 'context only — NOT the review verdict' <<<"$out" \
  || fail "(4b) the PR-comment section is not labelled as context: $out"
ok "(4b) no reason recorded ⇒ herd approve why says so and labels the PR comment as context"

# ── (5) the JOURNAL is the durable fallback — a reason-less ledger row still answers ──────────────
WT="$T/why-journal"; mkdir -p "$WT/.herd"
printf '1720000000 30 a5243cc5 BLOCK reviewer\n' > "$WT/.agent-watch-reviewed"
printf '{"ts":"2026-07-10T00:00:00Z","event":"verdict_recorded","pr":30,"sha":"a5243cc5","value":"BLOCK","source":"reviewer","reason":"%s"}\n' \
  "$BLOCK_REASON" > "$WT/.herd/journal.jsonl"
out="$(HERD_CONFIG_FILE="$T/no-such-config" WORKTREES_DIR="$WT" bash "$APPROVE" why 30 2>&1)"
grep -qF "$BLOCK_REASON" <<<"$out" || fail "(5) why did not fall back to the journal: $out"
ok "(5) herd approve why falls back to the durable journal when the ledger row carries no reason"

# (5b) a journal row for a DIFFERENT sha must never be attributed to this verdict.
WT="$T/why-wrong-sha"; mkdir -p "$WT/.herd"
printf '1720000000 30 a5243cc5 BLOCK reviewer\n' > "$WT/.agent-watch-reviewed"
printf '{"ts":"2026-07-10T00:00:00Z","event":"verdict_recorded","pr":30,"sha":"0000ffff","value":"BLOCK","source":"reviewer","reason":"why: some OTHER commit"}\n' \
  > "$WT/.herd/journal.jsonl"
out="$(HERD_CONFIG_FILE="$T/no-such-config" WORKTREES_DIR="$WT" bash "$APPROVE" why 30 2>&1)"
grep -q 'some OTHER commit' <<<"$out" && fail "(5b) why attributed another sha's reason to this verdict: $out"
grep -q 'Reason: none recorded' <<<"$out" || fail "(5b) why did not report the reason as missing: $out"
ok "(5b) a reason journaled for a different sha is never attributed to this verdict"

echo "ALL PASS ($PASS)"
