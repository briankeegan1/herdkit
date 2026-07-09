#!/usr/bin/env bash
# test-merge-policy.sh — hermetic tests for MERGE_POLICY / MERGE_METHOD / approval gate.
#
# Sources agent-watch.sh in lib mode (AGENT_WATCH_LIB=1) with stubbed gh/git/herdr binaries
# to test:
#   • _effective_merge_policy: MERGE_POLICY key, back-compat with WATCHER_AUTOMERGE, precedence
#   • _merge_method_flag: merge | squash | rebase, default
#   • approval helpers: approval_awaiting_noted, approval_is_approved, observe_noted
# Run:  bash tests/test-merge-policy.sh
# No `set -e`: some checks assert non-zero returns explicitly.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../scripts/herd/agent-watch.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

[ -f "$WATCH" ] || fail "agent-watch.sh not found at $WATCH"
command -v python3 >/dev/null 2>&1 || fail "python3 required"

# Stub binaries on PATH — no network, no filesystem side-effects beyond $T.
BIN="$T/bin"; mkdir -p "$BIN"
cat > "$BIN/gh" << 'STUB'
#!/usr/bin/env bash
# Log the FULL merge argv (not just the PR#) so a test can assert the --match-head-commit sha pin
# (PR #269 / HERD-156). Fail-soft on an unset log so non-merge-driving cases never abort the stub.
case "$1 $2" in
  "pr merge")  printf '%s\n' "$*" >> "${GH_MERGE_LOG:-/dev/null}"; exit 0 ;;
  "pr comment") exit 0 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$BIN/gh"
for cmd in git herdr; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$cmd"; chmod +x "$BIN/$cmd"
done
export PATH="$BIN:$PATH"

export AGENT_WATCH_LIB=1
export WORKTREES_DIR="$T/trees"; mkdir -p "$T/trees"
export HERD_CONFIG_FILE="$T/no-such-config"
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"
# $APPROVALS and $REVIEW_STATE are now set from the sourced file.

# ── _effective_merge_policy ──────────────────────────────────────────────────

type _effective_merge_policy >/dev/null 2>&1 || fail "_effective_merge_policy not defined"

[ "$(MERGE_POLICY=auto    _effective_merge_policy)" = "auto"    ] || fail "MERGE_POLICY=auto → auto"
ok
[ "$(MERGE_POLICY=approve _effective_merge_policy)" = "approve" ] || fail "MERGE_POLICY=approve → approve"
ok
[ "$(MERGE_POLICY=observe _effective_merge_policy)" = "observe" ] || fail "MERGE_POLICY=observe → observe"
ok

# Back-compat: no MERGE_POLICY set, WATCHER_AUTOMERGE drives resolution.
[ "$(MERGE_POLICY='' WATCHER_AUTOMERGE=true  _effective_merge_policy)" = "auto"    ] || fail "WATCHER_AUTOMERGE=true  → auto"
ok
[ "$(MERGE_POLICY='' WATCHER_AUTOMERGE=false _effective_merge_policy)" = "approve" ] || fail "WATCHER_AUTOMERGE=false → approve"
ok
[ "$(MERGE_POLICY='' WATCHER_AUTOMERGE=no    _effective_merge_policy)" = "approve" ] || fail "WATCHER_AUTOMERGE=no    → approve"
ok
[ "$(MERGE_POLICY='' WATCHER_AUTOMERGE=off   _effective_merge_policy)" = "approve" ] || fail "WATCHER_AUTOMERGE=off   → approve"
ok
[ "$(MERGE_POLICY='' WATCHER_AUTOMERGE=0     _effective_merge_policy)" = "approve" ] || fail "WATCHER_AUTOMERGE=0     → approve"
ok

# MERGE_POLICY always wins over WATCHER_AUTOMERGE.
[ "$(MERGE_POLICY=auto WATCHER_AUTOMERGE=false _effective_merge_policy)" = "auto"    ] || fail "MERGE_POLICY overrides WATCHER_AUTOMERGE (auto wins)"
ok
[ "$(MERGE_POLICY=observe WATCHER_AUTOMERGE=true _effective_merge_policy)" = "observe" ] || fail "MERGE_POLICY overrides WATCHER_AUTOMERGE (observe wins)"
ok

# HERD-159: a TYPO'd non-empty MERGE_POLICY fails STRICT to observe (never merge) — it must NOT
# fall through to the legacy WATCHER_AUTOMERGE derivation (which defaults true → auto and would
# silently turn an approval-gated repo into an auto-merging one). Empty alone is the legacy trigger.
[ "$(MERGE_POLICY=aprove  WATCHER_AUTOMERGE=true  _effective_merge_policy)" = "observe" ] \
  || fail "typo MERGE_POLICY=aprove must fail strict → observe (not auto via WATCHER_AUTOMERGE)"
ok
[ "$(MERGE_POLICY=held    WATCHER_AUTOMERGE=false _effective_merge_policy)" = "observe" ] \
  || fail "typo MERGE_POLICY=held must fail strict → observe (not approve via WATCHER_AUTOMERGE)"
ok
[ "$(MERGE_POLICY=AUTO    _effective_merge_policy)" = "observe" ] \
  || fail "case-sensitive: MERGE_POLICY=AUTO is unrecognized → observe"
ok

# ── single-resolver drift guard (HERD-210) ───────────────────────────────────
# The strict-fallback contract is only worth as much as its LEAST strict copy: cmd_reload once
# carried its own `case "${MERGE_POLICY:-}"` whose catch-all derived from WATCHER_AUTOMERGE, so
# `herd reload` reported "auto" for a typo the watcher observed. Every consumer now sources
# scripts/herd/merge-policy.sh — this guard fails if a new inline copy appears anywhere else.
# Derived from $WATCH, not $HERE: sourcing agent-watch.sh above reassigns HERE to its own directory.
ROOT="$(cd "$(dirname "$WATCH")/../.." && pwd)"
[ -f "$ROOT/scripts/herd/merge-policy.sh" ] || fail "shared resolver scripts/herd/merge-policy.sh missing"
copies="$(grep -rlE 'case[[:space:]]+"\$\{(MERGE_POLICY:-|WATCHER_AUTOMERGE:-true)\}"' "$ROOT/bin" "$ROOT/scripts" 2>/dev/null \
  | grep -v '/merge-policy\.sh$' || true)"
[ -z "$copies" ] \
  || fail "inline MERGE_POLICY resolution outside the shared resolver: $copies"
ok
for consumer in scripts/herd/agent-watch.sh scripts/herd/posture-lint.sh bin/herd; do
  grep -q 'merge-policy\.sh' "$ROOT/$consumer" \
    || fail "$consumer does not source the shared merge-policy resolver"
  ok
done

# ── _merge_method_flag ───────────────────────────────────────────────────────

type _merge_method_flag >/dev/null 2>&1 || fail "_merge_method_flag not defined"

[ "$(MERGE_METHOD=merge  _merge_method_flag)" = "--merge"  ] || fail "merge  → --merge"
ok
[ "$(MERGE_METHOD=squash _merge_method_flag)" = "--squash" ] || fail "squash → --squash"
ok
[ "$(MERGE_METHOD=rebase _merge_method_flag)" = "--rebase" ] || fail "rebase → --rebase"
ok
[ "$(MERGE_METHOD=''     _merge_method_flag)" = "--merge"  ] || fail "empty  → --merge (default)"
ok
# Unknown value falls through to default.
[ "$(MERGE_METHOD=weird  _merge_method_flag)" = "--merge"  ] || fail "unknown → --merge (default)"
ok

# ── Approval helpers ─────────────────────────────────────────────────────────

type approval_is_approved    >/dev/null 2>&1 || fail "approval_is_approved not defined"
type approval_awaiting_noted >/dev/null 2>&1 || fail "approval_awaiting_noted not defined"
type record_approval_awaiting >/dev/null 2>&1 || fail "record_approval_awaiting not defined"
type observe_noted           >/dev/null 2>&1 || fail "observe_noted not defined"
type record_observe_noted    >/dev/null 2>&1 || fail "record_observe_noted not defined"

# Empty / absent ledger → nothing is noted or approved.
rm -f "$APPROVALS"
! approval_is_approved    "1" "aaa" || fail "is_approved: empty ledger should return false"
ok
! approval_awaiting_noted "1" "aaa" || fail "awaiting_noted: empty ledger should return false"
ok
! observe_noted           "1" "aaa" || fail "observe_noted: empty ledger should return false"
ok

# After an 'awaiting' record: noted but not approved.
printf '1000 awaiting 1 aaa\n' > "$APPROVALS"
  approval_awaiting_noted "1" "aaa" || fail "awaiting record should be detected"
ok
! approval_is_approved    "1" "aaa" || fail "awaiting ≠ approved"
ok
! observe_noted           "1" "aaa" || fail "awaiting record is not an observed record"
ok

# After an 'approved' record: approved; wrong sha / wrong PR are not approved.
printf '1001 approved 1 aaa\n' >> "$APPROVALS"
  approval_is_approved "1" "aaa"    || fail "approved record should be detected"
ok
! approval_is_approved "1" "bbb"    || fail "wrong sha should not match approved"
ok
! approval_is_approved "2" "aaa"    || fail "wrong PR should not match approved"
ok

# An 'observed' record is visible only to observe_noted.
printf '1002 observed 2 bbb\n' >> "$APPROVALS"
  observe_noted "2" "bbb"           || fail "observed record should be detected"
ok
! observe_noted "2" "aaa"           || fail "observed: wrong sha should not match"
ok
! observe_noted "1" "bbb"           || fail "observed: wrong PR should not match"
ok
! approval_is_approved    "2" "bbb" || fail "observed record should not satisfy is_approved"
ok
! approval_awaiting_noted "2" "bbb" || fail "observed record should not satisfy awaiting_noted"
ok

# record_approval_awaiting and record_observe_noted write to $APPROVALS.
rm -f "$APPROVALS"
record_approval_awaiting "5" "sha5"
  approval_awaiting_noted "5" "sha5" || fail "record_approval_awaiting did not write correctly"
ok
! approval_is_approved    "5" "sha5" || fail "awaiting record written by record_approval_awaiting should not satisfy is_approved"
ok

record_observe_noted "6" "sha6"
  observe_noted "6" "sha6"           || fail "record_observe_noted did not write correctly"
ok

# ── Action-pass merge/hold DISPATCH — the real selector + the sha-pinned merge (F1) ──────────────
# The helper tests above never DROVE a merge, so the gh 'pr merge' stub was dead and the
# --match-head-commit sha pin (PR #269 / HERD-156) had NO coverage. Here we drive the REAL dispatch:
#   • _hold_decision <mode> <hv_hold> <approved> <hv_policy> → the pure MERGE|HOLD|OBSERVE selector.
#   • on MERGE the REAL do_merge fires, whose gh call PINS the merge to the gate-verified sha with
#     --match-head-commit — so a commit that landed after the gates passed can never merge unreviewed.
# We neuter ONLY do_merge's fail-soft POST-merge tail (reconcile/codemap/symbol-index/main-health/
# cost/reap) and the pre/post steps seam so the test stays hermetic + fast; the merge DECISION and the
# sha-pinned gh invocation are exercised for real, across auto/approve/observe × approved/unapproved.
type _hold_decision >/dev/null 2>&1 || fail "_hold_decision not defined"
type do_merge       >/dev/null 2>&1 || fail "do_merge not defined"
for _fn in reconcile_backlog refresh_codemap refresh_symbol_index main_health_tick cost_emit_merge \
           _reap_slug purge_pr_approvals; do
  eval "$_fn() { :; }"
done
steps_run_at() { return 0; }   # byte-inert pre/post-merge seam — the steps gate is tested elsewhere
export CODEMAP_AUTOREFRESH=off WATCHER_FLAIR=off DRYRUN=""
export JOURNAL_FILE="$T/journal.jsonl"
export GH_MERGE_LOG="$T/gh-merge.log"; : > "$GH_MERGE_LOG"
MERGE_SHA="deadbeefcafe1234"

# dispatch <mode> <hv_hold> <approved> — reset the log, run the REAL selector, and on MERGE fire the
# REAL do_merge (pinned to $MERGE_SHA). Echoes the decision token; the log side-effect persists.
dispatch() {
  : > "$GH_MERGE_LOG"
  local d; d="$(_hold_decision "$1" "$2" "$3" hold)"
  [ "$d" = "MERGE" ] && do_merge "slug-$1" 7 "$T/wt-$1" "$MERGE_SHA" >/dev/null 2>&1
  printf '%s' "$d"
}
# merged_with_sha — the last merge argv pinned $MERGE_SHA (the exact HERD-156 guarantee).
merged_with_sha() { grep -q -- "pr merge 7 --merge --match-head-commit $MERGE_SHA" "$GH_MERGE_LOG"; }
no_merge()        { [ ! -s "$GH_MERGE_LOG" ]; }

# observe: ALL gates run but NEVER merge — regardless of an approval record.
[ "$(dispatch observe '' '')" = "OBSERVE" ] || fail "observe/unapproved → OBSERVE"
no_merge || fail "observe/unapproved must NOT merge (log: $(cat "$GH_MERGE_LOG"))"
ok
[ "$(dispatch observe '' 1)"  = "OBSERVE" ] || fail "observe/approved → OBSERVE"
no_merge || fail "observe/approved must NOT merge (log: $(cat "$GH_MERGE_LOG"))"
ok

# approve: HOLD until a sha-keyed approval exists, then MERGE — pinned to the gate-verified sha.
[ "$(dispatch approve '' '')" = "HOLD" ] || fail "approve/unapproved → HOLD"
no_merge || fail "approve/unapproved must NOT merge (held)"
ok
[ "$(dispatch approve '' 1)"  = "MERGE" ] || fail "approve/approved → MERGE"
merged_with_sha || fail "approve/approved merge must fire pinned to the sha (log: $(cat "$GH_MERGE_LOG"))"
ok

# auto (no human-verify hold): MERGE either way — and STILL pinned to the sha every time.
[ "$(dispatch auto '' '')" = "MERGE" ] || fail "auto/unapproved → MERGE"
merged_with_sha || fail "auto/unapproved merge must pin the sha (log: $(cat "$GH_MERGE_LOG"))"
ok
[ "$(dispatch auto '' 1)"  = "MERGE" ] || fail "auto/approved → MERGE"
merged_with_sha || fail "auto/approved merge must pin the sha (log: $(cat "$GH_MERGE_LOG"))"
ok

echo "ALL PASS ($pass checks)"
