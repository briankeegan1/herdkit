#!/usr/bin/env bash
# test-cost.sh — hermetic tests for the token/cost summer (scripts/herd/cost.sh) and its reader
# (`herd cost`). Covers:
#   (1) the summer sums a stubbed transcript's assistant usage, DEDUPED by message id, and prices
#       it correctly under a STUBBED price table (HERD_COST_PRICE_FILE)
#   (2) builder vs in-worktree review sessions in the SAME dir are split by the reviewer fingerprint
#   (3) an unknown (unpriced) model is flagged (model=<id>?) and contributes $0, not a guess
#   (4) cost_emit_merge journals `cost` events with the right fields (component/pr/tokens/usd),
#       resolving the transcript dir via the exact munging agent-watch.sh uses
#   (5) `herd cost` aggregates multiple journal events → correct per-PR totals, by-component /
#       by-model rollups, total spend, and cost-per-merged-PR
#   (6) `herd cost --pr N` drills into one PR; empty journal → friendly message, exit 0
#
# Fully hermetic: writes only under a mktemp dir, uses fixture transcripts + a fixture journal, and
# NEVER reads a real transcript or touches the live watcher/panes/real HOME.
# Run:  bash tests/test-cost.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
COST_SH="$REPO/scripts/herd/cost.sh"
JOURNAL_SH="$REPO/scripts/herd/journal.sh"
HERD_BIN="$REPO/bin/herd"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

[ -f "$COST_SH" ]    || fail "cost.sh not found at $COST_SH"
[ -f "$JOURNAL_SH" ] || fail "journal.sh not found at $JOURNAL_SH"
command -v python3 >/dev/null 2>&1 || fail "python3 required to run this test"

# A stubbed price table with round numbers so expected USD is exact and obvious.
#   opus-4-8: $10 / 1M input, $100 / 1M output.  (deliberately NOT the real prices)
PRICES="$T/prices.json"
cat > "$PRICES" <<'JSON'
{ "claude-opus-4-8": { "in": 10.0, "out": 100.0 } }
JSON
export HERD_COST_PRICE_FILE="$PRICES"

# ── fixture transcript dir: one builder session + one review session in the SAME dir ──
# (mirrors reality: herd-review.sh runs `claude --cwd <worktree>`, so the reviewer transcript lands
# in the same munged project dir as the builder's.)
DIR="$T/transcript"; mkdir -p "$DIR"

# Builder session: 2 UNIQUE assistant messages (a1: pure input, b2: pure output) plus a DUPLICATE
# of a1 (same message id) that MUST be deduped — else output/input over-counts.
cat > "$DIR/builder.jsonl" <<'JNL'
{"type":"user","message":{"role":"user","content":"build the thing"}}
{"type":"assistant","message":{"role":"assistant","id":"a1","model":"claude-opus-4-8","usage":{"input_tokens":1000000,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
{"type":"assistant","message":{"role":"assistant","id":"b2","model":"claude-opus-4-8","usage":{"input_tokens":0,"output_tokens":1000000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
{"type":"assistant","message":{"role":"assistant","id":"a1","model":"claude-opus-4-8","usage":{"input_tokens":1000000,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
JNL

# Review session in the SAME dir: user message carries the stable reviewer fingerprint.
cat > "$DIR/review.jsonl" <<'JNL'
{"type":"user","message":{"role":"user","content":"You are an ADVERSARIAL PRE-MERGE CORRECTNESS REVIEWER for the project 'herdkit', where a SILENTLY WRONG result is the worst outcome. THIS REVIEW: the pull request under review is PR #42 (branch slug 'slug1')."}}
{"type":"assistant","message":{"role":"assistant","id":"r1","model":"claude-opus-4-8","usage":{"input_tokens":0,"output_tokens":500000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
JNL

# shellcheck source=/dev/null
. "$JOURNAL_SH" || fail "sourcing journal.sh failed"
# shellcheck source=/dev/null
. "$COST_SH" || fail "sourcing cost.sh failed"
type cost_report_dir >/dev/null 2>&1 || fail "cost_report_dir not defined after sourcing"
type cost_emit_merge >/dev/null 2>&1 || fail "cost_emit_merge not defined after sourcing"
ok

# ── (1)+(2) summer: builder line correct (deduped), review split out, USD priced ──
report="$(cost_report_dir "$DIR" all)"
builder_line="$(printf '%s\n' "$report" | grep 'component=builder')"
review_line="$(printf '%s\n' "$report" | grep 'component=review')"
[ -n "$builder_line" ] || fail "summer: expected a builder component line, got: $report"
[ -n "$review_line" ]  || fail "summer: expected a review component line, got: $report"
ok

# Builder: in 1000000, out 1000000 (a1 counted once despite the duplicate), 2 unique msgs,
# usd = (1000000*10 + 1000000*100)/1e6 = 110.000000
case "$builder_line" in
  *"in=1000000 out=1000000 "*) ok ;;
  *) fail "summer: builder tokens wrong (dedup?): $builder_line" ;;
esac
case "$builder_line" in *"msgs=2"*) ok ;; *) fail "summer: builder msgs should be 2 (deduped): $builder_line" ;; esac
case "$builder_line" in *"usd=110.000000"*) ok ;; *) fail "summer: builder usd should be 110.000000: $builder_line" ;; esac
case "$builder_line" in *"model=claude-opus-4-8"*) ok ;; *) fail "summer: builder model wrong: $builder_line" ;; esac

# Review: out 500000, usd = 500000*100/1e6 = 50.000000, 1 msg
case "$review_line" in *"in=0 out=500000 "*) ok ;; *) fail "summer: review tokens wrong: $review_line" ;; esac
case "$review_line" in *"usd=50.000000"*) ok ;; *) fail "summer: review usd should be 50.000000: $review_line" ;; esac
case "$review_line" in *"msgs=1"*) ok ;; *) fail "summer: review msgs should be 1: $review_line" ;; esac

# Component filter: asking for just builder must not emit a review line.
only_builder="$(cost_report_dir "$DIR" builder)"
printf '%s\n' "$only_builder" | grep -q 'component=review' && fail "summer: 'builder' filter leaked a review line"
printf '%s\n' "$only_builder" | grep -q 'component=builder' || fail "summer: 'builder' filter dropped the builder line"
ok

# ── (3) unknown model is flagged and contributes $0 (never guessed) ──
UDIR="$T/unknown"; mkdir -p "$UDIR"
cat > "$UDIR/b.jsonl" <<'JNL'
{"type":"assistant","message":{"role":"assistant","id":"u1","model":"claude-mystery-9","usage":{"input_tokens":1000000,"output_tokens":1000000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
JNL
u_line="$(cost_report_dir "$UDIR" builder)"
case "$u_line" in *"model=claude-mystery-9?"*) ok ;; *) fail "summer: unknown model should be flagged with '?': $u_line" ;; esac
case "$u_line" in *"usd=0.000000"*) ok ;; *) fail "summer: unknown model must price at 0, not guess: $u_line" ;; esac

# ── (4) cost_emit_merge journals `cost` events, resolving the dir via agent-watch munging ──
# Fake worktree path → munged (tr '/.' '-') dir under a stubbed transcript root.
ROOT="$T/root"; WT="/fake/wt/slug1"
MUNGED="$(printf '%s' "$WT" | tr '/.' '-')"        # -fake-wt-slug1
mkdir -p "$ROOT/$MUNGED"
cp "$DIR/builder.jsonl" "$DIR/review.jsonl" "$ROOT/$MUNGED/"
export HERD_TRANSCRIPT_ROOT="$ROOT"
export JOURNAL_FILE="$T/jmerge/journal.jsonl"
cost_emit_merge 42 slug1 "$WT"
[ -f "$JOURNAL_FILE" ] || fail "cost_emit_merge: no journal written"
ok
# Assert the builder cost event has the right typed fields.
python3 - "$JOURNAL_FILE" <<'PY' || fail "cost_emit_merge: builder cost event fields wrong"
import sys, json
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
cost = [o for o in rows if o.get("event") == "cost"]
b = [o for o in cost if o.get("component") == "builder"]
r = [o for o in cost if o.get("component") == "review"]
assert len(b) == 1, "expected exactly 1 builder cost event, got %d" % len(b)
assert len(r) == 1, "expected exactly 1 review cost event, got %d" % len(r)
b = b[0]
assert b["pr"] == 42 and isinstance(b["pr"], int), "pr should be JSON int 42: %r" % b.get("pr")
assert b["slug"] == "slug1", b.get("slug")
assert b["in"] == 1000000 and b["out"] == 1000000, (b.get("in"), b.get("out"))
assert isinstance(b["in"], int), "tokens should be JSON numbers"
assert b["model"] == "claude-opus-4-8", b.get("model")
assert str(b["usd"]) == "110.000000", b.get("usd")   # stored as a string (has a dot)
assert r[0]["usd"] == "50.000000" and r[0]["out"] == 500000, r[0]
print("ok")
PY
ok
unset JOURNAL_FILE HERD_TRANSCRIPT_ROOT HERD_COST_PRICE_FILE

# ── (5)+(6) `herd cost` reader: aggregate a fixture journal ──
PROJ="$T/proj"; TREES="$T/trees"
mkdir -p "$PROJ/.herd" "$TREES/.herd"
cat > "$PROJ/.herd/config" <<CFG
PROJECT_ROOT="$PROJ"
WORKTREES_DIR="$TREES"
WORKSPACE_NAME="ctest"
CFG
# PR 42: builder \$110 + review \$50 = \$160.  PR 43: builder \$30, no review.
# Total \$190; merged PRs (with a builder event) = 2 → cost-per-merged-PR \$95.
cat > "$TREES/.herd/journal.jsonl" <<'JNL'
{"ts":"2026-07-02T10:00:00Z","event":"cost","component":"builder","pr":42,"slug":"slug1","model":"claude-opus-4-8","in":1000000,"out":1000000,"cache_read":0,"cache_write":0,"usd":"110.000000","msgs":2}
{"ts":"2026-07-02T10:00:01Z","event":"cost","component":"review","pr":42,"slug":"slug1","model":"claude-opus-4-8","in":0,"out":500000,"cache_read":0,"cache_write":0,"usd":"50.000000","msgs":1}
{"ts":"2026-07-02T11:00:00Z","event":"cost","component":"builder","pr":43,"slug":"slug2","model":"claude-sonnet-4-6","in":600000,"out":0,"cache_read":0,"cache_write":0,"usd":"30.000000","msgs":1}
{"ts":"2026-07-02T11:00:02Z","event":"merge","pr":43,"slug":"slug2","sha":"deadbeef","method":"--merge","reason":"gates_passed"}
JNL

cost_out="$(cd "$PROJ" && HERD_NONINTERACTIVE=1 bash "$HERD_BIN" cost 2>&1)"
printf '%s\n' "$cost_out" | grep -qE 'PR #42 +\$ *160\.0000' || fail "herd cost: PR #42 total should be 160.0000\n$cost_out"
ok
printf '%s\n' "$cost_out" | grep -qE 'PR #43 +\$ *30\.0000' || fail "herd cost: PR #43 total should be 30.0000\n$cost_out"
ok
printf '%s\n' "$cost_out" | grep -qE 'Cost per merged PR: +\$95\.0000' || fail "herd cost: cost-per-merged-PR should be 95.0000\n$cost_out"
ok
printf '%s\n' "$cost_out" | grep -qE 'Merged PRs \(billed\): +2' || fail "herd cost: should count 2 merged PRs\n$cost_out"
ok
printf '%s\n' "$cost_out" | grep -qE 'Total spend recorded: +\$190\.0000' || fail "herd cost: total spend should be 190.0000\n$cost_out"
ok
# By-component rollup: builder = 110+30 = 140, review = 50.
printf '%s\n' "$cost_out" | grep -qE 'builder +\$ *140\.0000' || fail "herd cost: builder component total should be 140.0000\n$cost_out"
ok
printf '%s\n' "$cost_out" | grep -qE 'review +\$ *50\.0000' || fail "herd cost: review component total should be 50.0000\n$cost_out"
ok
# By-model rollup names both models.
printf '%s\n' "$cost_out" | grep -q 'claude-opus-4-8' || fail "herd cost: by-model should list opus\n$cost_out"
printf '%s\n' "$cost_out" | grep -q 'claude-sonnet-4-6' || fail "herd cost: by-model should list sonnet\n$cost_out"
ok

# --pr drills into one PR: shows both components + a TOTAL, excludes PR 43.
pr_out="$(cd "$PROJ" && HERD_NONINTERACTIVE=1 bash "$HERD_BIN" cost --pr 42 2>&1)"
printf '%s\n' "$pr_out" | grep -q 'PR #42 — cost breakdown' || fail "herd cost --pr 42: header wrong\n$pr_out"
printf '%s\n' "$pr_out" | grep -q 'builder' || fail "herd cost --pr 42: should list builder\n$pr_out"
printf '%s\n' "$pr_out" | grep -q 'review'  || fail "herd cost --pr 42: should list review\n$pr_out"
printf '%s\n' "$pr_out" | grep -qE 'TOTAL +\$ *160\.0000' || fail "herd cost --pr 42: TOTAL should be 160.0000\n$pr_out"
printf '%s\n' "$pr_out" | grep -q 'slug2' && fail "herd cost --pr 42: must not include PR 43's slug2\n$pr_out"
ok

# empty journal → friendly message, exit 0.
EMPTYP="$T/emptyp"; mkdir -p "$EMPTYP/.herd"
cat > "$EMPTYP/.herd/config" <<CFG
PROJECT_ROOT="$EMPTYP"
WORKTREES_DIR="$T/emptytrees"
WORKSPACE_NAME="ctest2"
CFG
empty_out="$(cd "$EMPTYP" && HERD_NONINTERACTIVE=1 bash "$HERD_BIN" cost 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || fail "herd cost with no journal should exit 0"
printf '%s\n' "$empty_out" | grep -q 'no engine journal yet' || fail "herd cost: empty case should say so\n$empty_out"
ok

# ── (7) `herd cost --full` ALSO scans the live coordinator/scribe/researcher transcripts ──
# The coordinator, scribe, and researcher all run with --cwd $PROJECT_ROOT, so their sessions share
# MAIN's munged transcript dir (unlike builders/reviews, which run from worktrees). --full scans that
# dir, classifies each session by its first user message, and appends the session-agent spend + a
# complete session total — WITHOUT changing the default (merge-gated) view. Round prices again so the
# scanned USD is exact.
export HERD_COST_PRICE_FILE="$PRICES"                 # opus: $10/1M in, $100/1M out
FPROJ="$T/fproj"; FTREES="$T/ftrees"
mkdir -p "$FPROJ/.herd" "$FTREES/.herd"
cat > "$FPROJ/.herd/config" <<CFG
PROJECT_ROOT="$FPROJ"
WORKTREES_DIR="$FTREES"
WORKSPACE_NAME="ctest3"
CFG
# One merge-recorded builder cost ($110) so the default rollup is non-empty and comparable.
cat > "$FTREES/.herd/journal.jsonl" <<'JNL'
{"ts":"2026-07-04T09:00:00Z","event":"cost","component":"builder","pr":50,"slug":"slug50","model":"claude-opus-4-8","in":1000000,"out":1000000,"cache_read":0,"cache_write":0,"usd":"110.000000","msgs":2}
JNL
# MAIN transcript dir = HERD_TRANSCRIPT_ROOT/<munged PROJECT_ROOT>, matching _cost_transcript_dir.
FROOT="$T/froot"; FMUNGED="$(printf '%s' "$FPROJ" | tr '/.' '-')"; FMDIR="$FROOT/$FMUNGED"
mkdir -p "$FMDIR"
# Coordinator: slash-command first message; out 200000 → $20.
cat > "$FMDIR/coord.jsonl" <<'JNL'
{"type":"user","message":{"role":"user","content":"<command-message>coordinator</command-message> <command-name>/coordinator</command-name>"}}
{"type":"assistant","message":{"role":"assistant","id":"c1","model":"claude-opus-4-8","usage":{"input_tokens":0,"output_tokens":200000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
JNL
# Scribe: drainer first message; out 100000 → $10.
cat > "$FMDIR/scribe.jsonl" <<'JNL'
{"type":"user","message":{"role":"user","content":"You are the BACKLOG SCRIBE (queue drainer). Drain the backlog queue, one request at a time."}}
{"type":"assistant","message":{"role":"assistant","id":"sc1","model":"claude-opus-4-8","usage":{"input_tokens":0,"output_tokens":100000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
JNL
# A review that fell back to MAIN, and an unrelated manual session — BOTH must be SKIPPED (each has a
# huge output that, if miscounted, would blow the session total far past $140).
cat > "$FMDIR/rev.jsonl" <<'JNL'
{"type":"user","message":{"role":"user","content":"You are an ADVERSARIAL PRE-MERGE CORRECTNESS REVIEWER for the project 'herdkit'."}}
{"type":"assistant","message":{"role":"assistant","id":"rv1","model":"claude-opus-4-8","usage":{"input_tokens":0,"output_tokens":9000000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
JNL
cat > "$FMDIR/manual.jsonl" <<'JNL'
{"type":"user","message":{"role":"user","content":"hey claude, fix this random thing for me"}}
{"type":"assistant","message":{"role":"assistant","id":"mn1","model":"claude-opus-4-8","usage":{"input_tokens":0,"output_tokens":9000000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
JNL
export HERD_TRANSCRIPT_ROOT="$FROOT"

# 7a. cost_report_full (the pure reader) emits coordinator + scribe, skips review + manual.
full_report="$(cost_report_full "$FMDIR")"
printf '%s\n' "$full_report" | grep -qE 'component=coordinator .*out=200000 .*usd=20\.000000' || fail "cost_report_full: coordinator line wrong: $full_report"
printf '%s\n' "$full_report" | grep -qE 'component=scribe .*out=100000 .*usd=10\.000000' || fail "cost_report_full: scribe line wrong: $full_report"
printf '%s\n' "$full_report" | grep -q 'component=review' && fail "cost_report_full: must skip the fallback review: $full_report"
printf '%s\n' "$full_report" | grep -qE 'out=9000000' && fail "cost_report_full: leaked a skipped session's tokens: $full_report"
ok

# 7b. `herd cost --full` appends the session agents + a complete session total (110+20+10 = 140).
full_out="$(cd "$FPROJ" && HERD_NONINTERACTIVE=1 bash "$HERD_BIN" cost --full 2>&1)"
printf '%s\n' "$full_out" | grep -q 'Live session agents' || fail "herd cost --full: missing session-agents section\n$full_out"
printf '%s\n' "$full_out" | grep -qE 'coordinator +claude-opus-4-8 +\$ *20\.0000' || fail "herd cost --full: coordinator \$20 missing\n$full_out"
printf '%s\n' "$full_out" | grep -qE 'scribe +claude-opus-4-8 +\$ *10\.0000' || fail "herd cost --full: scribe \$10 missing\n$full_out"
printf '%s\n' "$full_out" | grep -qE 'Session total .*: +\$140\.0000' || fail "herd cost --full: session total should be 140.0000\n$full_out"
ok
# The merge-gated rollup is still present and correct within --full (builder \$110 unchanged).
printf '%s\n' "$full_out" | grep -qE 'Total spend recorded: +\$110\.0000' || fail "herd cost --full: merge-recorded total should stay 110.0000\n$full_out"
ok

# 7c. DEFAULT `herd cost` is UNCHANGED — no session section, no session total, no coordinator/scribe.
def_out="$(cd "$FPROJ" && HERD_NONINTERACTIVE=1 bash "$HERD_BIN" cost 2>&1)"
printf '%s\n' "$def_out" | grep -q 'Live session agents' && fail "herd cost (default) must NOT scan live transcripts\n$def_out"
printf '%s\n' "$def_out" | grep -q 'Session total' && fail "herd cost (default) must NOT print a session total\n$def_out"
printf '%s\n' "$def_out" | grep -qiE 'coordinator|scribe' && fail "herd cost (default) must NOT mention session agents\n$def_out"
printf '%s\n' "$def_out" | grep -qE 'Total spend recorded: +\$110\.0000' || fail "herd cost (default): total should be 110.0000\n$def_out"
ok

# 7d. --full with NO transcript dir → a graceful note, still exits 0, still shows the rollup.
NODIRP="$T/nodir"; mkdir -p "$NODIRP/.herd"
cat > "$NODIRP/.herd/config" <<CFG
PROJECT_ROOT="$NODIRP"
WORKTREES_DIR="$FTREES"
WORKSPACE_NAME="ctest4"
CFG
nod_out="$(cd "$NODIRP" && HERD_NONINTERACTIVE=1 bash "$HERD_BIN" cost --full 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || fail "herd cost --full with no transcript dir should exit 0\n$nod_out"
printf '%s\n' "$nod_out" | grep -q 'Live session agents' || fail "herd cost --full: section should appear even with no dir\n$nod_out"
printf '%s\n' "$nod_out" | grep -qiE 'no transcript dir|nothing to add' || fail "herd cost --full: should note the missing/empty scan\n$nod_out"
printf '%s\n' "$nod_out" | grep -qE 'Session total .*: +\$110\.0000' || fail "herd cost --full: with no agents, session total == merge total\n$nod_out"
ok
unset HERD_COST_PRICE_FILE HERD_TRANSCRIPT_ROOT

echo "PASS test-cost.sh ($pass checks)"
