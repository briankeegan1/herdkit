#!/usr/bin/env bash
# test-risk-tiered-review.sh — hermetic tests for RISK-TIERED pre-merge review (REVIEW_ESCALATE_GLOB).
#
# The review gate normally runs EVERY PR through the full $MODEL_REVIEW (Opus). Setting
# REVIEW_ESCALATE_GLOB opts into risk-proportional tiering, classified DETERMINISTICALLY from the
# PR's changed-file paths (gh pr diff <pr> --name-only). This suite proves the four mandated cases:
#   (a) a glob-matching engine-surface diff  → STRONG tier ($MODEL_REVIEW), reviewer dispatched
#   (b) a docs/test-only diff                → review SKIPPED, PASS recorded source=skipped-low-risk,
#                                              NO reviewer spawned
#   (c) a small low-risk diff                → CHEAP tier ($REVIEW_MODEL_CHEAP) reviewer dispatched
#   (d) REVIEW_ESCALATE_GLOB empty           → UNCHANGED: every diff (even docs-only) gets the full
#                                              $MODEL_REVIEW review (regression guard)
# Plus a large-diff guard: a many-file diff escalates to STRONG even without a glob match.
#
# Sources agent-watch.sh in lib mode with HERD_REVIEW_BIN pointed at a stub reviewer that logs the
# model it was dispatched on. Stubs gh (pr diff --name-only)/git/herdr/claude — NETWORK-FREE, never
# spawns a real reviewer.
# Run:  bash tests/test-risk-tiered-review.sh
# No `set -e`: some checks assert non-zero returns explicitly.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../scripts/herd/agent-watch.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

[ -f "$WATCH" ] || fail "agent-watch.sh not found at $WATCH"
command -v python3 >/dev/null 2>&1 || fail "python3 required to run this test"

# wait_for <timeout-s> <test-cmd...> — poll a condition every 0.2 s; fail-friendly (returns 1).
wait_for() {
  local deadline=$(( $(date +%s) + $1 )); shift
  while ! "$@" 2>/dev/null; do
    [ "$(date +%s)" -ge "$deadline" ] && return 1
    sleep 0.2
  done
  return 0
}

# ── Stub binaries on PATH ─────────────────────────────────────────────────────
BIN="$T/bin"; mkdir -p "$BIN"
for cmd in git herdr; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$cmd"; chmod +x "$BIN/$cmd"
done
# gh stub: only `gh pr diff <pr> --name-only` matters here — it emits the newline-separated path
# list from $STUB_DIFF_PATHS (exported per scenario). Everything else is a no-op success.
cat > "$BIN/gh" <<'GH'
#!/usr/bin/env bash
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "diff" ]; then
  [ -n "${STUB_DIFF_PATHS:-}" ] && printf '%s\n' "$STUB_DIFF_PATHS"
  exit 0
fi
exit 0
GH
chmod +x "$BIN/gh"
export PATH="$BIN:$PATH"

# ── Stub reviewer (stands in for herd-review.sh via the HERD_REVIEW_BIN seam) ─
# Logs "<pr> <model>" to $STUB_SPAWN_LOG where <model> is the tier the watcher dispatched it on
# (HERD_REVIEW_MODEL, or DEFAULT when unset — the strong/default path leaves it unset so
# herd-review.sh resolves $MODEL_REVIEW). Writes the verdict atomically as its last act.
STUB_REVIEW="$T/stub-review.sh"
cat > "$STUB_REVIEW" <<'STUB'
#!/usr/bin/env bash
pr="$1"
[ -n "${STUB_SPAWN_LOG:-}" ] && printf '%s %s\n' "$pr" "${HERD_REVIEW_MODEL:-DEFAULT}" >> "$STUB_SPAWN_LOG"
sleep "${STUB_DELAY:-0}"
if [ -n "${HERD_REVIEW_RESULT_FILE:-}" ]; then
  printf '%s\n' "${STUB_VERDICT:-REVIEW: PASS}" > "$HERD_REVIEW_RESULT_FILE.tmp.$$"
  mv "$HERD_REVIEW_RESULT_FILE.tmp.$$" "$HERD_REVIEW_RESULT_FILE"
fi
printf '%s\n' "${STUB_VERDICT:-REVIEW: PASS}"
STUB
chmod +x "$STUB_REVIEW"

# ── Source agent-watch.sh in lib mode ────────────────────────────────────────
export AGENT_WATCH_LIB=1
export WORKTREES_DIR="$T/trees"; mkdir -p "$T/trees"
export HERD_CONFIG_FILE="$T/no-such-config"
export HERD_REVIEW_BIN="$STUB_REVIEW"
export REVIEW_CONCURRENCY=5     # high enough that nothing QUEUEs in these tests
# Shield from inherited config env (HERD-362): the coordinator/watcher exports MODEL_REVIEW
# (HERD-353), and this suite sources herd-config.sh (via agent-watch.sh) in the CURRENT shell,
# then asserts the baseline MODEL_REVIEW default below. A leaked export would keep the machine's
# value and red the assertion — clear the model-resolution inputs so the loader resolves baseline.
unset MODEL_COORDINATOR MODEL_FEATURE MODEL_QUICK MODEL_SCRIBE MODEL_RESEARCH MODEL_RESOLVER MODEL_REVIEW TOKEN_MODE
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"

for fn in _classify_review_tier _review_tier _review_gate_step _dispatch_review _review_tier_file; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined after sourcing"
done
# Defaults resolved from herd-config.sh (no project config present).
[ "$MODEL_REVIEW" = "claude-sonnet-4-6" ]      || fail "MODEL_REVIEW default changed ($MODEL_REVIEW)"  # HERD-161: eco-leaning default
[ "$REVIEW_MODEL_CHEAP" = "claude-sonnet-4-6" ] || fail "REVIEW_MODEL_CHEAP default wrong ($REVIEW_MODEL_CHEAP)"
[ "$REVIEW_ESCALATE_MAXFILES" = "10" ]          || fail "REVIEW_ESCALATE_MAXFILES default wrong"
[ -z "${REVIEW_ESCALATE_GLOB:-}" ]              || fail "REVIEW_ESCALATE_GLOB should default empty"
[ "$REVIEW_MODEL_DOCS" = "claude-haiku-4-5" ]   || fail "REVIEW_MODEL_DOCS default wrong ($REVIEW_MODEL_DOCS)"
[ -z "${DOCS_ONLY_GLOB:-}" ]                     || fail "DOCS_ONLY_GLOB should default empty"
ok

export STUB_SPAWN_LOG="$T/spawns.log"; : > "$STUB_SPAWN_LOG"

# The engine-surface glob mirrors the dogfood one in .herd/config.
GLOB='^bin/|^scripts/herd/agent-watch|herd-review|cmd_reload'

# ── UNIT: _classify_review_tier for each diff shape (glob active) ─────────────
REVIEW_ESCALATE_GLOB="$GLOB"

# (a) engine-surface path matches the glob → STRONG
export STUB_DIFF_PATHS=$'scripts/herd/agent-watch.sh\nREADME.md'
[ "$(_classify_review_tier 100)" = "STRONG" ] || fail "(a) glob-matching engine diff should be STRONG"
ok

# (b) docs/test-only diff (only *.md and tests/) → SKIP
export STUB_DIFF_PATHS=$'README.md\ndocs/flow-audit.md\ntests/test-foo.sh'
[ "$(_classify_review_tier 101)" = "SKIP" ] || fail "(b) docs/test-only diff should be SKIP"
ok
# A single non-doc/test path defeats SKIP.
export STUB_DIFF_PATHS=$'README.md\nscripts/herd/journal.sh'
[ "$(_classify_review_tier 101)" != "SKIP" ] || fail "a non-doc/test path must defeat SKIP"
ok

# (c) small low-risk diff (no glob match, few files) → CHEAP
export STUB_DIFF_PATHS=$'scripts/herd/journal.sh\ntemplates/capabilities.tsv'
[ "$(_classify_review_tier 102)" = "CHEAP" ] || fail "(c) small low-risk diff should be CHEAP"
ok

# large diff (> REVIEW_ESCALATE_MAXFILES files, none matching the glob) → STRONG
big="$(for i in $(seq 1 15); do printf 'scripts/herd/mod%02d.sh\n' "$i"; done)"
export STUB_DIFF_PATHS="$big"
[ "$(_classify_review_tier 103)" = "STRONG" ] || fail "large diff should escalate to STRONG"
ok
# …but the same file COUNT staying under the threshold is still CHEAP.
small="$(for i in $(seq 1 5); do printf 'scripts/herd/mod%02d.sh\n' "$i"; done)"
export STUB_DIFF_PATHS="$small"
[ "$(_classify_review_tier 103)" = "CHEAP" ] || fail "under-threshold low-risk diff should be CHEAP"
ok

# FAIL-SAFE: an empty/unreadable diff (gh returns nothing) → STRONG, never a downgrade.
export STUB_DIFF_PATHS=""
[ "$(_classify_review_tier 104)" = "STRONG" ] || fail "empty diff must fail SAFE to STRONG"
ok

# ── UNIT: DOCS tier (DOCS_ONLY_GLOB, HERD-89) ────────────────────────────────
# A docs pattern the hardcoded *.md/tests SKIP does NOT cover (e.g. *.txt, or a mixed *.md+*.txt diff)
# routes to the DOCS tier when EVERY changed path matches DOCS_ONLY_GLOB. Escalation still wins.
DOCS_GLOB='\.(md|txt)$'
DOCS_ONLY_GLOB="$DOCS_GLOB"

# (e) every path matches the docs glob (a *.txt the SKIP misses) → DOCS
export STUB_DIFF_PATHS=$'CHANGELOG.txt\nnotes.txt'
[ "$(_classify_review_tier 110)" = "DOCS" ] || fail "(e) all-docs .txt diff should be DOCS"
ok
# a MIXED *.md + *.txt diff (SKIP needs all-.md/tests, so it falls through) → DOCS
export STUB_DIFF_PATHS=$'README.md\nnotes.txt'
[ "$(_classify_review_tier 110)" = "DOCS" ] || fail "(e) mixed .md+.txt docs diff should be DOCS"
ok
# a single NON-docs path defeats DOCS → CHEAP (small, low-risk, no glob match)
export STUB_DIFF_PATHS=$'notes.txt\nscripts/herd/journal.sh'
[ "$(_classify_review_tier 110)" = "CHEAP" ] || fail "(e) a non-docs path must defeat DOCS → CHEAP"
ok

# (f) ESCALATION WINS over the docs tier: a docs-glob path (a *.txt, so the *.md/tests SKIP doesn't
# fire) that ALSO matches REVIEW_ESCALATE_GLOB → STRONG, not DOCS.
REVIEW_ESCALATE_GLOB="$GLOB"
export STUB_DIFF_PATHS=$'scripts/herd/agent-watch-notes.txt'
[ "$(_classify_review_tier 111)" = "STRONG" ] || fail "(f) escalate-glob match must beat DOCS → STRONG"
ok
# …and a docs-only diff over REVIEW_ESCALATE_MAXFILES files → STRONG even though every path is docs
bigdocs="$(for i in $(seq 1 15); do printf 'doc%02d.txt\n' "$i"; done)"
export STUB_DIFF_PATHS="$bigdocs"
[ "$(_classify_review_tier 111)" = "STRONG" ] || fail "(f) large docs diff must escalate to STRONG"
ok

# (g) DOCS_ONLY_GLOB activates tiering ON ITS OWN — REVIEW_ESCALATE_GLOB empty must NOT force STRONG
# (an empty escalate glob would make `grep -qE ""` match every path; the -n guard prevents that).
REVIEW_ESCALATE_GLOB=""
export STUB_DIFF_PATHS=$'guide.txt\nhandbook.txt'
[ "$(_classify_review_tier 112)" = "DOCS" ] || fail "(g) DOCS_ONLY_GLOB alone must classify DOCS, not STRONG"
ok

# Restore glob state for the integration section (docs tiering off unless a scenario opts in).
DOCS_ONLY_GLOB=""
REVIEW_ESCALATE_GLOB="$GLOB"

# ── INTEGRATION: _review_gate_step dispatches the right tier / skips ─────────
rm -f "$REVIEW_STATE" "$REVIEW_RETRIES"; : > "$STUB_SPAWN_LOG"
export STUB_DELAY=0 STUB_VERDICT="REVIEW: PASS"

# (a) STRONG: engine-surface diff → reviewer dispatched with the DEFAULT model (unset
# HERD_REVIEW_MODEL → herd-review.sh resolves $MODEL_REVIEW). Byte-identical to today's dispatch.
export STUB_DIFF_PATHS=$'scripts/herd/agent-watch.sh'
s="$(_review_gate_step 200 slug-strong shaS)"
[ "$s" = "RUNNING" ] || fail "(a) STRONG diff should dispatch (got $s)"
wait_for 5 grep -q '^200 ' "$STUB_SPAWN_LOG" || fail "(a) STRONG reviewer never spawned"
[ "$(awk '$1==200{print $2}' "$STUB_SPAWN_LOG")" = "DEFAULT" ] \
  || fail "(a) STRONG must dispatch on the default model, got $(awk '$1==200{print $2}' "$STUB_SPAWN_LOG")"
ok

# (b) SKIP: docs/test-only diff → NO reviewer, PASS recorded with source=skipped-low-risk.
: > "$STUB_SPAWN_LOG"
export STUB_DIFF_PATHS=$'README.md\ntests/test-foo.sh'
s="$(_review_gate_step 201 slug-skip shaK)"
[ "$s" = "PASS" ] || fail "(b) docs/test-only diff should report PASS immediately (got $s)"
[ "$(review_verdict 201 shaK)" = "PASS" ] || fail "(b) SKIP must record a PASS verdict"
[ "$(review_verdict_source 201 shaK)" = "skipped-low-risk" ] \
  || fail "(b) SKIP provenance must be skipped-low-risk (got $(review_verdict_source 201 shaK))"
sleep 0.5
grep -q '^201 ' "$STUB_SPAWN_LOG" && fail "(b) SKIP must NOT spawn a reviewer"
[ ! -f "$(_review_inflight_file 201 shaK)" ] || fail "(b) SKIP must not leave an inflight marker"
ok

# (c) CHEAP: small low-risk diff → reviewer dispatched on $REVIEW_MODEL_CHEAP.
: > "$STUB_SPAWN_LOG"
export STUB_DIFF_PATHS=$'scripts/herd/journal.sh'
s="$(_review_gate_step 202 slug-cheap shaC)"
[ "$s" = "RUNNING" ] || fail "(c) CHEAP diff should dispatch (got $s)"
wait_for 5 grep -q '^202 ' "$STUB_SPAWN_LOG" || fail "(c) CHEAP reviewer never spawned"
[ "$(awk '$1==202{print $2}' "$STUB_SPAWN_LOG")" = "$REVIEW_MODEL_CHEAP" ] \
  || fail "(c) CHEAP must dispatch on $REVIEW_MODEL_CHEAP, got $(awk '$1==202{print $2}' "$STUB_SPAWN_LOG")"
ok

# The tier decision is CACHED sha-keyed (one gh classification per commit).
[ -s "$(_review_tier_file 202 shaC)" ] || fail "tier decision should be cached"
[ "$(cat "$(_review_tier_file 202 shaC)")" = "CHEAP" ] || fail "cached tier should be CHEAP"
ok

# (e-int) DOCS: a pure-docs diff (all paths match DOCS_ONLY_GLOB) → reviewer dispatched on $REVIEW_MODEL_DOCS.
: > "$STUB_SPAWN_LOG"
DOCS_ONLY_GLOB="$DOCS_GLOB"
export STUB_DIFF_PATHS=$'CHANGELOG.txt\nnotes.txt'
s="$(_review_gate_step 203 slug-docs shaX)"
[ "$s" = "RUNNING" ] || fail "(e-int) DOCS diff should dispatch (got $s)"
wait_for 5 grep -q '^203 ' "$STUB_SPAWN_LOG" || fail "(e-int) DOCS reviewer never spawned"
[ "$(awk '$1==203{print $2}' "$STUB_SPAWN_LOG")" = "$REVIEW_MODEL_DOCS" ] \
  || fail "(e-int) DOCS must dispatch on $REVIEW_MODEL_DOCS, got $(awk '$1==203{print $2}' "$STUB_SPAWN_LOG")"
[ "$(cat "$(_review_tier_file 203 shaX)")" = "DOCS" ] || fail "(e-int) cached tier should be DOCS"
DOCS_ONLY_GLOB=""   # docs tiering off again for the regression guard below
ok

# ── (d) REGRESSION GUARD: glob empty → UNCHANGED always-$MODEL_REVIEW behavior ─
# Even a docs-only diff (which WOULD skip under tiering) gets the full default review, and no diff
# classification runs at all (no tier cache written).
rm -f "$REVIEW_STATE"; : > "$STUB_SPAWN_LOG"
REVIEW_ESCALATE_GLOB=""
export STUB_DIFF_PATHS=$'README.md\ndocs/only.md'
s="$(_review_gate_step 300 slug-default shaD)"
[ "$s" = "RUNNING" ] || fail "(d) glob-empty must dispatch a full review even for docs-only (got $s)"
wait_for 5 grep -q '^300 ' "$STUB_SPAWN_LOG" || fail "(d) default reviewer never spawned"
[ "$(awk '$1==300{print $2}' "$STUB_SPAWN_LOG")" = "DEFAULT" ] \
  || fail "(d) glob-empty must dispatch on the default \$MODEL_REVIEW path"
[ ! -f "$(_review_tier_file 300 shaD)" ] || fail "(d) glob-empty must NOT classify/cache a tier"
review_verdict 300 shaD >/dev/null 2>&1 && fail "(d) glob-empty must NOT record a skip PASS"
ok

echo "ALL PASS ($pass checks)"
