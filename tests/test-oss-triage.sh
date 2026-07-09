#!/usr/bin/env bash
# test-oss-triage.sh — hermetic tests for OSS auto-triage (scripts/herd/oss-triage.sh /
# `herd triage`, HERD-255 / HERD-168 part 1/3). Covers:
#   (1) OSS_TRIAGE=off (default) is byte-inert: no gh, no research enqueue, no state files
#   (2) OSS_TRIAGE=on with mock `gh issue list` enqueues research per NEW issue
#   (3) stub research results produce a ranked classified shortlist (bug > feature > …)
#   (4) re-run does NOT re-enqueue already-seen issues
#   (5) NEVER calls gh issue comment / close / edit (asserted via gh call log)
#   (6) `herd triage` CLI dispatches to the same script
#
# Fully hermetic: PATH-stubbed gh + research; temp trees only; no network, no model, no real issues.
# Run:  bash tests/test-oss-triage.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
TRIAGE_SH="$REPO/scripts/herd/oss-triage.sh"
HERD_BIN="$REPO/bin/herd"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { printf 'FAIL: '; printf "$@" >&2; echo >&2; exit 1; }
ok()   { pass=$((pass+1)); }

[ -f "$TRIAGE_SH" ] || fail "oss-triage.sh not found at $TRIAGE_SH"
[ -f "$HERD_BIN" ]  || fail "herd not found at $HERD_BIN"
command -v python3 >/dev/null 2>&1 || fail "python3 required"

# ── fixture project ──
PROJ="$T/proj"; TREES="$T/trees"; TRIAGE_DIR="$T/triage"; REPORTS="$T/reports"
mkdir -p "$PROJ/.herd" "$TREES" "$TRIAGE_DIR" "$REPORTS" "$T/bin"

cat > "$PROJ/.herd/config" <<CFG
PROJECT_ROOT="$PROJ"
WORKTREES_DIR="$TREES"
WORKSPACE_NAME="triagetest"
HERD_REPO="owner/demo"
CFG

# ── gh stub: issue list only; records every argv line; refuses comment/close/edit ──
GH_LOG="$T/gh.log"; : > "$GH_LOG"
GH_ISSUES_JSON="$T/issues.json"
cat > "$GH_ISSUES_JSON" <<'JSON'
[
  {
    "number": 10,
    "title": "Crash on empty input",
    "body": "Steps: open app with no file. Stack trace follows.",
    "labels": [{"name": "needs-triage"}],
    "url": "https://github.com/owner/demo/issues/10",
    "createdAt": "2026-07-01T10:00:00Z"
  },
  {
    "number": 11,
    "title": "Add dark mode",
    "body": "Would be nice to have a dark theme.",
    "labels": [],
    "url": "https://github.com/owner/demo/issues/11",
    "createdAt": "2026-07-02T10:00:00Z"
  },
  {
    "number": 12,
    "title": "How do I configure HERD_REPO?",
    "body": "Docs unclear.",
    "labels": [{"name": "question"}],
    "url": "https://github.com/owner/demo/issues/12",
    "createdAt": "2026-07-03T10:00:00Z"
  }
]
JSON

cat > "$T/bin/gh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$GH_LOG"
# Hard fail on any mutating issue verb — the feature MUST never reach these.
case "\$*" in
  *"issue comment"*|*"issue close"*|*"issue edit"*|*"issue create"*|*"api "*)
    echo "FORBIDDEN gh invocation: \$*" >&2
    exit 99
    ;;
esac
if [[ "\$*" == *"issue list"* ]]; then
  cat "$GH_ISSUES_JSON"
  exit 0
fi
# Anything else: empty success (should not be required).
exit 0
STUB
chmod +x "$T/bin/gh"

# ── research stub: print REQ_ID; map issue# → stable id; no real drainer ──
RESEARCH_STUB="$T/bin/research-stub.sh"
cat > "$RESEARCH_STUB" <<'RSTUB'
#!/usr/bin/env bash
# Args: the research question (may be multi-line via "$@").
q="$*"
num="$(printf '%s' "$q" | sed -nE 's/.*issue #([0-9]+).*/\1/p' | head -n1)"
[ -n "$num" ] || num="x"
rid="triage-req-${num}"
printf '🔎 queued: OSS-TRIAGE issue #%s\n' "$num"
printf 'REQ_ID %s\n' "$rid"
printf 'report → /tmp/%s.md\n' "$rid"
# Record enqueue for assertions.
printf '%s\t%s\n' "$num" "$rid" >> "${HERD_OSS_ENQUEUE_LOG:-/dev/null}"
exit 0
RSTUB
chmod +x "$RESEARCH_STUB"
ENQUEUE_LOG="$T/enqueue.log"; : > "$ENQUEUE_LOG"

export PATH="$T/bin:$PATH"
export PROJECT_ROOT="$PROJ"
export WORKTREES_DIR="$TREES"
export HERD_REPO="owner/demo"
export HERD_OSS_TRIAGE_DIR="$TRIAGE_DIR"
export HERD_OSS_RESEARCH_SH="$RESEARCH_STUB"
export HERD_OSS_ENQUEUE_LOG="$ENQUEUE_LOG"
export RESEARCH_REPORTS="$REPORTS"
export HERMETIC_TEST=1
export HERD_NONINTERACTIVE=1
# Point config discovery at the fixture (herd-config walks up from cwd / HERD_CONFIG_FILE).
export HERD_CONFIG_FILE="$PROJ/.herd/config"

run_triage() {
  (
    cd "$PROJ" && \
      OSS_TRIAGE="${OSS_TRIAGE:-on}" \
      PROJECT_ROOT="$PROJ" \
      WORKTREES_DIR="$TREES" \
      HERD_REPO="owner/demo" \
      HERD_OSS_TRIAGE_DIR="$TRIAGE_DIR" \
      HERD_OSS_RESEARCH_SH="$RESEARCH_STUB" \
      HERD_OSS_ENQUEUE_LOG="$ENQUEUE_LOG" \
      RESEARCH_REPORTS="$REPORTS" \
      HERD_CONFIG_FILE="$PROJ/.herd/config" \
      HERMETIC_TEST=1 \
      bash "$TRIAGE_SH" "$@"
  )
}

# ── (1) OFF is byte-inert ──
: > "$GH_LOG"; : > "$ENQUEUE_LOG"
out="$(OSS_TRIAGE=off run_triage run 2>&1)" || fail "(1) off run failed: %s" "$out"
printf '%s\n' "$out" | grep -qi 'byte-inert\|OSS_TRIAGE=off' \
  || fail "(1) expected inert message\n%s" "$out"
[ ! -s "$GH_LOG" ] || fail "(1) gh was called while off:\n%s" "$(cat "$GH_LOG")"
[ ! -s "$ENQUEUE_LOG" ] || fail "(1) research enqueued while off:\n%s" "$(cat "$ENQUEUE_LOG")"
[ ! -f "$TRIAGE_DIR/shortlist.md" ] || fail "(1) shortlist written while off"
ok

# ── (2) ON enqueues research for each NEW issue ──
: > "$GH_LOG"; : > "$ENQUEUE_LOG"
out="$(OSS_TRIAGE=on run_triage run 2>&1)" || fail "(2) on run failed: %s" "$out"
printf '%s\n' "$out" | grep -q 'enqueued 3' \
  || fail "(2) expected 3 enqueues\n%s" "$out"
n_enq="$(wc -l < "$ENQUEUE_LOG" | tr -d ' ')"
[ "$n_enq" = "3" ] || fail "(2) enqueue log has %s lines, want 3\n%s" "$n_enq" "$(cat "$ENQUEUE_LOG")"
grep -q 'issue list' "$GH_LOG" || fail "(2) gh issue list not called\n%s" "$(cat "$GH_LOG")"
[ -f "$TRIAGE_DIR/seen.tsv" ] || fail "(2) seen.tsv missing"
[ -f "$TRIAGE_DIR/shortlist.md" ] || fail "(2) shortlist missing"
# Still pending (no research reports yet).
grep -q 'pending' "$TRIAGE_DIR/shortlist.md" \
  || fail "(2) expected pending shortlist entries\n%s" "$(cat "$TRIAGE_DIR/shortlist.md")"
ok

# ── (3) stub research results → ranked classified shortlist ──
# Write research reports matching the stub REQ_IDs.
cat > "$REPORTS/triage-req-10.md" <<'R'
## Classification: bug
## Confidence: high
## Suggested labels: bug, needs-repro
## Suggested reply:
Thanks for the report — can you share the full stack trace and herdkit version?
## Notes:
Likely a null-input path.
R
cat > "$REPORTS/triage-req-11.md" <<'R'
## Classification: feature
## Confidence: medium
## Suggested labels: enhancement
## Suggested reply:
Thanks for the suggestion — dark mode is on the radar; tracking for a later theme pack.
## Notes:
R
cat > "$REPORTS/triage-req-12.md" <<'R'
## Classification: question
## Confidence: high
## Suggested labels: question
## Suggested reply:
Set HERD_REPO=owner/repo in .herd/config (see herd init / config.example).
## Notes:
R

: > "$GH_LOG"; : > "$ENQUEUE_LOG"
out="$(OSS_TRIAGE=on run_triage run 2>&1)" || fail "(3) collect run failed: %s" "$out"
body="$(cat "$TRIAGE_DIR/shortlist.md")"
printf '%s\n' "$body" | grep -qE '## #10 — bug' \
  || fail "(3) missing bug classification for #10\n%s" "$body"
printf '%s\n' "$body" | grep -qE '## #11 — feature' \
  || fail "(3) missing feature for #11\n%s" "$body"
printf '%s\n' "$body" | grep -qE '## #12 — question' \
  || fail "(3) missing question for #12\n%s" "$body"
printf '%s\n' "$body" | grep -q 'human approval only' \
  || fail "(3) shortlist must declare human-approval-only\n%s" "$body"
printf '%s\n' "$body" | grep -q 'Suggested reply (draft):' \
  || fail "(3) missing draft replies\n%s" "$body"
# Rank order: bug (#10) before feature (#11) before question (#12)
python3 - "$TRIAGE_DIR/shortlist.md" <<'PY' || fail "(3) shortlist not ranked bug>feature>question"
import sys, re
text = open(sys.argv[1], encoding="utf-8").read()
# find positions of issue headings
pos = {}
for m in re.finditer(r'^## #(\d+) — (\w+)', text, re.M):
    pos[m.group(1)] = (m.start(), m.group(2))
assert "10" in pos and "11" in pos and "12" in pos, pos
assert pos["10"][0] < pos["11"][0] < pos["12"][0], pos
assert pos["10"][1] == "bug" and pos["11"][1] == "feature" and pos["12"][1] == "question"
PY
# Inbox pointer file present
[ -f "$TRIAGE_DIR/inbox" ] || fail "(3) inbox file missing"
grep -q '#10' "$TRIAGE_DIR/inbox" || fail "(3) inbox missing #10"
ok

# ── (4) re-run does not re-enqueue seen issues ──
: > "$ENQUEUE_LOG"
out="$(OSS_TRIAGE=on run_triage run 2>&1)" || fail "(4) rerun failed: %s" "$out"
printf '%s\n' "$out" | grep -q 'enqueued 0' \
  || fail "(4) expected 0 new enqueues\n%s" "$out"
[ ! -s "$ENQUEUE_LOG" ] || fail "(4) research re-enqueued:\n%s" "$(cat "$ENQUEUE_LOG")"
ok

# ── (5) NEVER mutates GitHub issues ──
if grep -Eiq 'issue (comment|close|edit|create)|api ' "$GH_LOG" 2>/dev/null; then
  fail "(5) mutating gh call observed:\n%s" "$(cat "$GH_LOG")"
fi
# Also scan the full log history from the whole test (re-read accumulated — we truncated; re-assert on script source).
# Source-level guard: oss-triage.sh must not contain issue comment/close.
if grep -nE 'issue comment|issue close|issue edit|gh api' "$TRIAGE_SH" | grep -vE '^\s*#' | grep -v 'NEVER' | grep -q .; then
  fail "(5) oss-triage.sh appears to call mutating gh:\n%s" "$(grep -nE 'issue comment|issue close|issue edit|gh api' "$TRIAGE_SH")"
fi
ok

# ── (6) CLI dispatch ──
cli_out="$(
  cd "$PROJ" && \
    OSS_TRIAGE=on \
    PROJECT_ROOT="$PROJ" \
    WORKTREES_DIR="$TREES" \
    HERD_REPO="owner/demo" \
    HERD_OSS_TRIAGE_DIR="$TRIAGE_DIR" \
    HERD_OSS_RESEARCH_SH="$RESEARCH_STUB" \
    RESEARCH_REPORTS="$REPORTS" \
    HERD_CONFIG_FILE="$PROJ/.herd/config" \
    HERMETIC_TEST=1 \
    HERD_NONINTERACTIVE=1 \
    bash "$HERD_BIN" triage report 2>/dev/null
)" || fail "(6) herd triage report CLI failed"
printf '%s\n' "$cli_out" | grep -qE '## #10 — bug' \
  || fail "(6) CLI report missing #10 bug\n%s" "$cli_out"
ok

# ── (7) default (unset OSS_TRIAGE) is off ──
out="$(
  cd "$PROJ" && \
    unset OSS_TRIAGE && \
    PROJECT_ROOT="$PROJ" \
    WORKTREES_DIR="$TREES" \
    HERD_CONFIG_FILE="$PROJ/.herd/config" \
    HERD_OSS_TRIAGE_DIR="$T/triage-unset" \
    HERD_OSS_RESEARCH_SH="$RESEARCH_STUB" \
    RESEARCH_REPORTS="$REPORTS" \
    bash "$TRIAGE_SH" run 2>&1
)" || fail "(7) unset run failed: %s" "$out"
printf '%s\n' "$out" | grep -qi 'byte-inert\|OSS_TRIAGE=off' \
  || fail "(7) unset should be inert\n%s" "$out"
[ ! -d "$T/triage-unset" ] || [ ! -f "$T/triage-unset/shortlist.md" ] \
  || fail "(7) wrote shortlist with OSS_TRIAGE unset"
ok

echo "ALL PASS ($pass assertions)"
