#!/usr/bin/env bash
# test-adopt-remote-prs.sh — hermetic unit tests for auto-ADOPT of ungated remote PRs (HERD-369):
# the ADOPT_REMOTE_PRS=on|off lever, built ON TOP of the HERD-330 orphan diff, and the invariants the
# feature MUST hold:
#   • OFF (default) is byte-inert: no ledger, no journal event, no git fetch/worktree-add call.
#   • ON: an open, NON-DRAFT orphan PR whose branch is checked out nowhere is adopted within one scan
#     (git fetch + git worktree add) and journals exactly one pr_adopted event.
#   • A DRAFT PR is never adopted, even when it is otherwise an orphan.
#   • A branch already checked out ANYWHERE (main checkout or another worktree) is never touched.
#   • Sha-keyed once-guard: a second scan of the same (pr,sha) never re-runs fetch/worktree-add.
#   • Fail-soft: a fetch failure or a worktree-add failure journals adopt_failed and records the
#     outcome — never a red row, never a crash.
#
# Sources agent-watch.sh in lib mode (AGENT_WATCH_LIB=1 — helpers only, no polling loop, no console,
# no real network), pointing config discovery at a nonexistent file so herd-config.sh falls back to its
# generic defaults (ADOPT_REMOTE_PRS defaults off). A scripted `git` stub on PATH stands in for fetch/
# worktree-add so the test never touches the real network or filesystem outside $T.
# Run:  bash tests/test-adopt-remote-prs.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../scripts/herd/agent-watch.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass(){ PASS=$((PASS+1)); }

[ -f "$WATCH" ] || fail "agent-watch.sh not found at $WATCH"
command -v python3 >/dev/null 2>&1 || fail "python3 required"

# ── Stub binaries on PATH ────────────────────────────────────────────────────────────────────────
BIN="$T/bin"; mkdir -p "$BIN"
export GIT_CALL_LOG="$T/git-calls.log"; : > "$GIT_CALL_LOG"
# git: log every invocation; emulate `fetch` and `worktree add` deterministically off the branch name
# (a branch containing "fail-fetch"/"fail-worktree" fails that step), everything else succeeds so
# sourcing never breaks. A successful `worktree add` mkdir's the target dir, mirroring the real command.
cat > "$BIN/git" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GIT_CALL_LOG" 2>/dev/null || true
if [ "$1" = "-C" ] && [ "$3" = "fetch" ]; then
  branch="$6"
  case "$branch" in *fail-fetch*) exit 1 ;; esac
  exit 0
fi
if [ "$1" = "-C" ] && [ "$3" = "worktree" ] && [ "$4" = "add" ]; then
  dir="$5"; branch="$6"
  case "$branch" in *fail-worktree*) exit 1 ;; esac
  mkdir -p "$dir" 2>/dev/null
  exit 0
fi
exit 0
STUB
chmod +x "$BIN/git"
printf '#!/usr/bin/env bash\necho SENTINEL-NETWORK-LEAK\nexit 0\n' > "$BIN/gh";  chmod +x "$BIN/gh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/herdr"; chmod +x "$BIN/herdr"
export PATH="$BIN:$PATH"

# ── Source the watcher's helpers WITHOUT its live loop (lib mode), colors blanked (NO_COLOR) ────────
export AGENT_WATCH_LIB=1
export HERD_CONFIG_FILE="$T/no-such-config"
export WORKTREES_DIR="$T/trees"; mkdir -p "$WORKTREES_DIR"
export PROJECT_ROOT="$T/main"; mkdir -p "$PROJECT_ROOT/.herd"
export WORKSPACE_NAME="adopttest"
export WATCHER_OWNER="me-operator"
export NO_COLOR=1
export JOURNAL_FILE="$T/journal.jsonl"
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"
for fn in _adopt_remote_prs_enabled _adopt_pr_recorded _adopt_pr_mark_adopted _adopt_branch_checked_out \
          _adopt_failed_journaled _adopt_journal_failed _adopt_remote_pr _adopt_remote_prs_scan \
          _watcher_tick_fields; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined after sourcing"
done
pass

reset_state() {
  : > "$GIT_CALL_LOG"
  : > "$JOURNAL_FILE"
  rm -f "$ADOPT_PR_LEDGER" "$ADOPT_FAILED_SEEN_LEDGER"
  rm -rf "${WORKTREES_DIR:?}"/* 2>/dev/null || true
}

# ── 1. _adopt_remote_prs_enabled: default OFF; on|true|1|yes|enable enable it; anything else is OFF ─
unset ADOPT_REMOTE_PRS
_adopt_remote_prs_enabled && fail "must be OFF by default (unset)"; pass
for v in on ON true 1 yes enable enabled; do
  ADOPT_REMOTE_PRS="$v" _adopt_remote_prs_enabled || fail "should be ON for '$v'"
done; pass
for v in off "" 0 no garbage; do
  ADOPT_REMOTE_PRS="$v" _adopt_remote_prs_enabled && fail "should be OFF for '$v'"
done; pass

# A two-PR open roster: 201 adoptable, 202 already claimed by a discovered worktree.
PRS='[
  {"number":201,"title":"add gizmo","headRefName":"feat/gizmo","headRefOid":"sha201","isDraft":false},
  {"number":202,"title":"fix leak","headRefName":"feat/leak","headRefOid":"sha202","isDraft":false}
]'

# ── 2. OFF is byte-inert: no ledger, no journal event, no git fetch/worktree-add call ───────────────
reset_state
ADOPT_REMOTE_PRS=off PRS_LOOKUP_OK=1 _adopt_remote_prs_scan "$PRS" "202" ""
[ ! -e "$ADOPT_PR_LEDGER" ] || fail "OFF must not write the adopt ledger"
[ ! -s "$JOURNAL_FILE" ] || fail "OFF must not journal anything"
[ ! -s "$GIT_CALL_LOG" ] || fail "OFF must never invoke git fetch/worktree add: $(cat "$GIT_CALL_LOG")"
pass

# _watcher_tick_fields must stay byte-identical (no isDraft) when the feature is off.
case ",$(ADOPT_REMOTE_PRS=off _watcher_tick_fields)," in
  *,isDraft,*) fail "OFF must not add isDraft to the gh --json field list" ;;
esac
case ",$(ADOPT_REMOTE_PRS=on _watcher_tick_fields)," in
  *,isDraft,*) : ;;
  *) fail "ON must add isDraft to the gh --json field list" ;;
esac
pass

# ── 3. ON: PR 201 (unclaimed, non-draft, branch free) is adopted; PR 202 (claimed) is left alone ────
reset_state
ADOPT_REMOTE_PRS=on PRS_LOOKUP_OK=1 _adopt_remote_prs_scan "$PRS" "202" ""
grep -q -- "-C $PROJECT_ROOT fetch -q origin feat/gizmo" "$GIT_CALL_LOG" || fail "expected a fetch of feat/gizmo: $(cat "$GIT_CALL_LOG")"
grep -q -- "-C $PROJECT_ROOT worktree add $WORKTREES_DIR/feat-gizmo feat/gizmo" "$GIT_CALL_LOG" \
  || fail "expected a worktree add of feat/gizmo: $(cat "$GIT_CALL_LOG")"
grep -q "leak" "$GIT_CALL_LOG" && fail "claimed PR 202 must never be touched: $(cat "$GIT_CALL_LOG")"
[ -d "$WORKTREES_DIR/feat-gizmo" ] || fail "adopted worktree dir was not created"
grep -q '"event":"pr_adopted"' "$JOURNAL_FILE" || fail "pr_adopted not journaled: $(cat "$JOURNAL_FILE")"
grep -q '"pr":201' "$JOURNAL_FILE" || fail "pr_adopted missing pr:201: $(cat "$JOURNAL_FILE")"
grep -q -- "$(printf '201\tsha201\tadopted')" "$ADOPT_PR_LEDGER" || fail "ledger missing adopted row: $(cat "$ADOPT_PR_LEDGER" 2>/dev/null)"
pass

# ── 4. A DRAFT orphan PR is never adopted, even though it is otherwise eligible ──────────────────────
reset_state
DRAFT_PRS='[{"number":301,"title":"wip thing","headRefName":"feat/wip","headRefOid":"sha301","isDraft":true}]'
ADOPT_REMOTE_PRS=on PRS_LOOKUP_OK=1 _adopt_remote_prs_scan "$DRAFT_PRS" "" ""
[ ! -s "$GIT_CALL_LOG" ] || fail "a draft PR must never trigger fetch/worktree add: $(cat "$GIT_CALL_LOG")"
[ ! -s "$JOURNAL_FILE" ] || fail "a draft PR must never journal anything: $(cat "$JOURNAL_FILE")"
[ ! -e "$WORKTREES_DIR/feat-wip" ] || fail "a draft PR must never get a worktree"
pass

# ── 5. A branch already checked out ANYWHERE (main checkout or a stray worktree) is never touched ──
reset_state
WT_TEXT="worktree $PROJECT_ROOT
HEAD deadbeef
branch refs/heads/feat/gizmo

"
_adopt_branch_checked_out "feat/gizmo" "$WT_TEXT" || fail "_adopt_branch_checked_out must detect a checked-out branch"
_adopt_branch_checked_out "feat/nowhere" "$WT_TEXT" && fail "_adopt_branch_checked_out false-positived on an unrelated branch"
ADOPT_REMOTE_PRS=on PRS_LOOKUP_OK=1 _adopt_remote_prs_scan "$PRS" "202" "$WT_TEXT"
[ ! -s "$GIT_CALL_LOG" ] || fail "a branch checked out elsewhere must never be fetched/added: $(cat "$GIT_CALL_LOG")"
pass

# ── 6. Sha-keyed once-guard: a second scan of the SAME (pr,sha) never re-runs fetch/worktree-add ────
reset_state
ADOPT_REMOTE_PRS=on PRS_LOOKUP_OK=1 _adopt_remote_prs_scan "$PRS" "202" ""
first_calls="$(wc -l < "$GIT_CALL_LOG" | tr -cd '0-9')"
ADOPT_REMOTE_PRS=on PRS_LOOKUP_OK=1 _adopt_remote_prs_scan "$PRS" "202" ""
second_calls="$(wc -l < "$GIT_CALL_LOG" | tr -cd '0-9')"
[ "$first_calls" = "$second_calls" ] || fail "once-guard failed: git was invoked again on re-tick ($first_calls -> $second_calls)"
adopted_rows="$(grep -c "^$(printf '201\tsha201\tadopted')\$" "$ADOPT_PR_LEDGER" 2>/dev/null || true)"
[ "${adopted_rows:-0}" = "1" ] || fail "ledger must record PR 201 exactly once, got ${adopted_rows:-0}"
pass

# ── 7. Fail-soft: a fetch failure journals adopt_failed, never a crash, and is NEVER once-guarded —
#      a still-broken branch RETRIES the attempt every scan, but the journal EVENT is deduped so a
#      permanently-broken branch does not spam adopt_failed once per tick forever ──────────────────
reset_state
FAIL_FETCH_PRS='[{"number":401,"title":"x","headRefName":"feat/fail-fetch","headRefOid":"sha401","isDraft":false}]'
ADOPT_REMOTE_PRS=on PRS_LOOKUP_OK=1 _adopt_remote_prs_scan "$FAIL_FETCH_PRS" "" || fail "a fetch failure must not abort the scan"
grep -q '"event":"adopt_failed"' "$JOURNAL_FILE" || fail "adopt_failed not journaled on fetch failure: $(cat "$JOURNAL_FILE")"
grep -q '"pr":401' "$JOURNAL_FILE" || fail "adopt_failed missing pr:401"
[ ! -e "$ADOPT_PR_LEDGER" ] || fail "a failure must never write the SUCCESS once-guard ledger: $(cat "$ADOPT_PR_LEDGER")"
[ ! -d "$WORKTREES_DIR/feat-fail-fetch" ] || fail "a failed fetch must never leave a worktree dir"
first_fetch_calls="$(wc -l < "$GIT_CALL_LOG" | tr -cd '0-9')"
first_journal_lines="$(wc -l < "$JOURNAL_FILE" | tr -cd '0-9')"
# A SECOND scan of the SAME still-failing (pr,sha): the attempt retries (git called again)...
ADOPT_REMOTE_PRS=on PRS_LOOKUP_OK=1 _adopt_remote_prs_scan "$FAIL_FETCH_PRS" ""
second_fetch_calls="$(wc -l < "$GIT_CALL_LOG" | tr -cd '0-9')"
[ "$second_fetch_calls" -gt "$first_fetch_calls" ] || fail "a failed (pr,sha) must be RETRIED on the next scan, not once-guarded"
# ...but the journal event for this exact (pr,sha) is deduped, not doubled.
second_journal_lines="$(wc -l < "$JOURNAL_FILE" | tr -cd '0-9')"
[ "$second_journal_lines" = "$first_journal_lines" ] || fail "adopt_failed must be deduped per (pr,sha), not re-journaled every scan"
pass

# ── 8. Fail-soft: a worktree-add failure journals adopt_failed too (fetch succeeded, add did not) ──
reset_state
FAIL_ADD_PRS='[{"number":402,"title":"x","headRefName":"feat/fail-worktree","headRefOid":"sha402","isDraft":false}]'
ADOPT_REMOTE_PRS=on PRS_LOOKUP_OK=1 _adopt_remote_prs_scan "$FAIL_ADD_PRS" "" || fail "a worktree-add failure must not abort the scan"
grep -q '"event":"adopt_failed"' "$JOURNAL_FILE" || fail "adopt_failed not journaled on worktree-add failure"
grep -q '"pr":402' "$JOURNAL_FILE" || fail "adopt_failed missing pr:402"
pass

# ── 9. A FAILED open-PR fetch (PRS_LOOKUP_OK=0) never fabricates an adopt attempt ───────────────────
reset_state
ADOPT_REMOTE_PRS=on PRS_LOOKUP_OK=0 _adopt_remote_prs_scan "$PRS" ""
[ ! -s "$GIT_CALL_LOG" ] || fail "PRS_LOOKUP_OK=0 must never attempt an adopt: $(cat "$GIT_CALL_LOG")"
pass

# ── 10. Malformed roster is fail-soft: no ledger write, never a crash ────────────────────────────────
reset_state
ADOPT_REMOTE_PRS=on PRS_LOOKUP_OK=1 _adopt_remote_prs_scan 'not json' "" || fail "malformed roster must not error"
[ ! -s "$GIT_CALL_LOG" ] || fail "malformed roster must never attempt an adopt"
pass

echo "ok — $PASS adopt-remote-PRs assertions passed"
