#!/usr/bin/env bash
# test-status.sh — hermetic test for `herd status`'s PURE, READ-ONLY helpers (scripts/herd/status.sh).
# Sources status.sh standalone (it defines functions only, no live loop), points every ledger/backlog
# path at a temp dir, and asserts the deterministic classifiers + ledger readers without touching git,
# gh, herdr, or any real ledger:
#   • _status_classify_builder  — building / done / idle / DEAD / agentdead / agentmissing buckets
#                                  (DEAD = no agent + no PR + no commits; agentmissing = no agent but work exists)
#   • _status_latest_review     — latest PASS/BLOCK for a PR+sha from the append-only review ledger
#   • _status_latest_health     — latest healthcheck outcome for a PR from the health ledger
#   • _status_pr_attention      — CONFLICTING / review-BLOCK / CHANGES_REQUESTED ⇒ needs a human
#   • _status_backlog_counts    — 🔜 open / 🚧 in-progress counts from a file-backend backlog
#   • _status_watcher_pids      — self-contained argv0 fallback returns empty for a bogus marker
# Run:  bash tests/test-status.sh
# No `set -e`: some predicates deliberately return non-zero; we assert explicitly.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/../scripts/herd/status.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ pass=$((pass+1)); }

[ -f "$LIB" ] || fail "status.sh not found at $LIB"

# Source the helpers (functions only — no config walk, no live gather).
# shellcheck source=/dev/null
. "$LIB" || fail "sourcing status.sh failed"
for fn in _status_classify_builder _status_latest_review _status_latest_health \
          _status_pr_attention _status_backlog_counts _status_watcher_pids; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined"
done

# ── _status_classify_builder: has_agent · agent_status · has_pr · commits ─────────────────────────
[ "$(_status_classify_builder 0 ''        0 0)" = "dead" ]     || fail "no agent + no PR + no commits → dead"
[ "$(_status_classify_builder 0 ''        0 xx)" = "dead" ]    || fail "non-numeric commits treated as 0 → dead"
[ "$(_status_classify_builder 1 working   0 0)" = "building" ] || fail "working agent → building"
[ "$(_status_classify_builder 1 idle      0 0)" = "idle" ]     || fail "present idle agent, nothing produced → idle"
[ "$(_status_classify_builder 1 done      0 0)" = "done" ]     || fail "agent reports done → done"
# HERD-135: 'done' REQUIRES a live session. A vanished agent (has_agent=0) over real work is NOT
# 'done' — it's 'agent missing' (a refix would hit nobody), so a review bounce is never sent to no one.
[ "$(_status_classify_builder 0 ''        1 0)" = "agentmissing" ] || fail "open PR but NO agent → agent missing (not done)"
[ "$(_status_classify_builder 0 ''        0 3)" = "agentmissing" ] || fail "commits but NO agent → agent missing (not done)"
[ "$(_status_classify_builder 1 idle      0 2)" = "done" ]     || fail "LIVE idle agent with commits → done"
[ "$(_status_classify_builder 1 idle      1 0)" = "done" ]     || fail "LIVE idle agent with a PR → done"
[ "$(_status_classify_builder 1 working   1 5)" = "done" ]     || fail "LIVE agent + PR dominates → done"
# agentmissing never fires over a LIVE agent; agentdead still wins when the process is confirmed gone.
[ "$(_status_classify_builder 1 done      1 0 dead)" = "agentdead" ] || fail "confirmed-dead session with a PR → agentdead"
ok

# ── _status_latest_review: latest verdict per PR+sha from the append-only ledger ──────────────────
RL="$T/.agent-watch-reviewed"
{
  printf '%s\n' "1700000000 42 aaa PASS reviewer"
  printf '%s\n' "1700000100 42 aaa BLOCK reviewer"   # later row wins for pr 42 / sha aaa
  printf '%s\n' "1700000200 42 bbb PASS reviewer"    # different sha
  printf '%s\n' "1700000300 43 ccc PASS gate_default"
} > "$RL"
[ "$(_status_latest_review "$RL" 42 aaa)" = "BLOCK" ] || fail "latest verdict for 42/aaa should be BLOCK"
[ "$(_status_latest_review "$RL" 42 bbb)" = "PASS" ]  || fail "verdict for 42/bbb should be PASS"
[ "$(_status_latest_review "$RL" 43 ccc)" = "PASS" ]  || fail "verdict for 43/ccc should be PASS"
[ -z "$(_status_latest_review "$RL" 42 zzz)" ]        || fail "unknown sha → empty"
[ -z "$(_status_latest_review "$RL" 99 aaa)" ]        || fail "unknown pr → empty"
[ -z "$(_status_latest_review "$T/nope" 42 aaa)" ]    || fail "missing ledger → empty (graceful)"
ok

# ── _status_latest_health: latest outcome per PR from the health ledger ───────────────────────────
HL="$T/.agent-watch-healthchecks"
{
  printf '%s\n' "1700000000 42 slug-a 1 code-error"
  printf '%s\n' "1700000100 42 slug-a 2 flaky-pass"   # later attempt wins
  printf '%s\n' "1700000200 44 slug-b 1 clean"
} > "$HL"
[ "$(_status_latest_health "$HL" 42)" = "flaky-pass" ] || fail "latest health for 42 should be flaky-pass"
[ "$(_status_latest_health "$HL" 44)" = "clean" ]      || fail "health for 44 should be clean"
[ -z "$(_status_latest_health "$HL" 77)" ]             || fail "unknown pr → empty"
[ -z "$(_status_latest_health "$T/nope" 42)" ]         || fail "missing health ledger → empty (graceful)"
ok

# ── _status_pr_attention: what needs a human ──────────────────────────────────────────────────────
[ "$(_status_pr_attention MERGEABLE   PASS  APPROVED)"          = "0" ] || fail "clean PR → no attention"
[ "$(_status_pr_attention MERGEABLE   ''    '')"               = "0" ] || fail "unreviewed clean PR → no attention"
[ "$(_status_pr_attention CONFLICTING ''    '')"               = "1" ] || fail "CONFLICTING → attention"
[ "$(_status_pr_attention MERGEABLE   BLOCK '')"               = "1" ] || fail "review BLOCK → attention"
[ "$(_status_pr_attention MERGEABLE   PASS  CHANGES_REQUESTED)" = "1" ] || fail "CHANGES_REQUESTED → attention"
ok

# ── _status_backlog_counts: 🔜 open / 🚧 in-progress (file backend) ───────────────────────────────
BL="$T/BACKLOG.md"
cat > "$BL" <<'MD'
# Backlog
- 🔜 queued item one
- 🔜 queued item two
- 🚧 in progress item
- ✅ shipped item (not counted)
- 🔜 queued item three
MD
counts="$(_status_backlog_counts "$BL")"
[ "$counts" = "3 1" ] || fail "expected '3 1' (3 open, 1 in-progress), got '$counts'"
[ "$(_status_backlog_counts "$T/no-backlog.md")" = "0 0" ] || fail "missing backlog → '0 0'"
: > "$T/empty.md"
[ "$(_status_backlog_counts "$T/empty.md")" = "0 0" ] || fail "empty backlog → '0 0'"
ok

# ── _status_watcher_pids: standalone argv0 fallback yields nothing for a bogus marker ─────────────
# _list_project_watchers is NOT defined here (only status.sh sourced), so the self-contained pgrep
# fallback runs. A random, certainly-not-running marker must produce no pids — never a crash.
out="$(HERD_WATCH_ARGV0="herd-watch-nope-$$-does-not-exist" _status_watcher_pids)"
[ -z "$out" ] || fail "bogus watcher marker should yield no pids, got '$out'"
ok

echo "ALL PASS ($pass checks)"
