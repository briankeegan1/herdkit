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
#   • _status_note_age          — compact age token, empty for anything unparseable (HERD-492)
#   • _status_notes_summary     — count + newest slug/age of the builder notes still awaiting an ack,
#                                  read through the SAME console-section.sh reader `herd notes` uses
# plus ONE end-to-end gather assertion (HERD-492) that drives _status_gather itself against a real
# notes ledger, with git/gh stubbed on PATH, so deleting the read from gather goes red here.
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
          _status_pr_attention _status_backlog_counts _status_watcher_pids \
          _status_note_age _status_notes_summary; do
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

# ── _status_note_age: compact age token, empty for anything unparseable (HERD-492) ────────────────
[ "$(_status_note_age 0)"     = "0s" ]  || fail "age 0 → 0s"
[ "$(_status_note_age 42)"    = "42s" ] || fail "age 42 → 42s"
[ "$(_status_note_age 60)"    = "1m" ]  || fail "age 60 → 1m"
[ "$(_status_note_age 3599)"  = "59m" ] || fail "age 3599 → 59m"
[ "$(_status_note_age 3600)"  = "1h" ]  || fail "age 3600 → 1h"
[ "$(_status_note_age 86399)" = "23h" ] || fail "age 86399 → 23h"
[ "$(_status_note_age 86400)" = "1d" ]  || fail "age 86400 → 1d"
# Fail-soft: a clock that ran backwards or an unparseable epoch yields NO age (the caller then prints
# the slug alone) — never a negative/garbage token on the operator's console.
[ -z "$(_status_note_age -5)" ]   || fail "negative age → empty"
[ -z "$(_status_note_age abc)" ]  || fail "non-numeric age → empty"
[ -z "$(_status_note_age '')" ]   || fail "empty age → empty"
ok

# ── _status_notes_summary: the unacked-builder-note count behind `herd status`'s NOTES line ───────
# Ledger shape is the watcher's: "<epoch>\t<slug>\t<text>\t<ts>", appended oldest-first. The shared
# console-section.sh reader hands them back NEWEST FIRST, drops acked rows, and ages rows out after
# CONSOLE_ROW_RETENTION (2h) — this asserts `herd status` inherits ALL THREE decisions unchanged.
NOW=1700000000
NL="$T/.agent-watch-builder-notes"
NA="$T/.agent-watch-builder-notes-acked"

# ZERO is the byte-identical case: no ledger, and an empty ledger, must both produce NOTHING (no
# record ⇒ no line). This is the assertion that keeps `herd status` silent on a drained control room.
[ -z "$(HERD_FAKE_NOW="$NOW" _status_notes_summary "$T/no-such-ledger" "$NA")" ] \
  || fail "missing notes ledger → no summary"
: > "$NL"
[ -z "$(HERD_FAKE_NOW="$NOW" _status_notes_summary "$NL" "$NA")" ] || fail "empty notes ledger → no summary"

OLD_NOTE="$(( NOW - 720 ))"$'\tfeat-old\tthe older finding\t09:48'
NEW_NOTE="$(( NOW - 300 ))"$'\tfeat-new\tthe newest finding\t09:55'
printf '%s\n%s\n' "$OLD_NOTE" "$NEW_NOTE" > "$NL"
: > "$NA"
sum="$(HERD_FAKE_NOW="$NOW" _status_notes_summary "$NL" "$NA")"
[ "$sum" = $'2\tfeat-new\t5m' ] || fail "two unacked notes → '2 feat-new 5m', got '$(printf '%s' "$sum" | tr '\t' ' ')'"
ok

# ACK-AWARE: acking the newest drops it from the count AND re-points 'newest' at the survivor — the
# same verbatim-line ack sidecar `herd notes ack` writes, so the two surfaces cannot disagree.
printf '%s\n' "$NEW_NOTE" > "$NA"
sum="$(HERD_FAKE_NOW="$NOW" _status_notes_summary "$NL" "$NA")"
[ "$sum" = $'1\tfeat-old\t12m' ] || fail "newest acked → '1 feat-old 12m', got '$(printf '%s' "$sum" | tr '\t' ' ')'"
printf '%s\n%s\n' "$OLD_NOTE" "$NEW_NOTE" > "$NA"
[ -z "$(HERD_FAKE_NOW="$NOW" _status_notes_summary "$NL" "$NA")" ] || fail "every note acked → no summary (silent)"
ok

# AGED OUT: a note past CONSOLE_ROW_RETENTION (2h) has already left the console — status must not
# resurrect it. A note just inside the window still counts.
: > "$NA"
printf '%s\t%s\t%s\t%s\n' "$(( NOW - 7201 ))" feat-stale "an aged-out finding" 07:56 > "$NL"
[ -z "$(HERD_FAKE_NOW="$NOW" _status_notes_summary "$NL" "$NA")" ] || fail "aged-out note → no summary"
printf '%s\t%s\t%s\t%s\n' "$(( NOW - 7199 ))" feat-fresh "a just-inside finding" 07:56 > "$NL"
sum="$(HERD_FAKE_NOW="$NOW" _status_notes_summary "$NL" "$NA")"
[ "$sum" = $'1\tfeat-fresh\t1h' ] || fail "note inside retention → '1 feat-fresh 1h', got '$(printf '%s' "$sum" | tr '\t' ' ')'"
ok

# FAIL-SOFT on a malformed epoch: console-section.sh SHOWS a row it cannot classify (a surface never
# silently swallows a note), so the count includes it — with an EMPTY age rather than a garbage one.
printf '%s\t%s\t%s\t%s\n' "notanepoch" feat-weird "a malformed finding" 09:55 > "$NL"
sum="$(HERD_FAKE_NOW="$NOW" _status_notes_summary "$NL" "$NA")"
[ "$sum" = $'1\tfeat-weird\t' ] || fail "malformed epoch → counted with empty age, got '$(printf '%s' "$sum" | tr '\t' ' ')'"
ok

# ── _status_gather emits the NOTES record (HERD-492) ──────────────────────────────────────────────
# The helpers above prove the READ; this proves gather actually CALLS it — delete the read from
# _status_gather and this assertion goes red (a pure-helper test alone would stay green).
# Hermetic: git/gh are stubbed on PATH so no live probe runs, and the bogus argv0 marker keeps the
# watcher probe empty. Also asserts the silent-at-zero contract at the SNAPSHOT layer.
GB="$T/stubbin"; mkdir -p "$GB"
printf '#!/bin/sh\nexit 0\n'     > "$GB/git"; chmod +x "$GB/git"
printf '#!/bin/sh\nprintf "[]"\n' > "$GB/gh";  chmod +x "$GB/gh"
GROOT="$T/proj"; GTREES="$T/gtrees"; mkdir -p "$GROOT" "$GTREES"
gather_snap() {
  ( PATH="$GB:$PATH" PROJECT_ROOT="$GROOT" WORKTREES_DIR="$GTREES" SCRIBE_BACKEND=file \
      BACKLOG_FILE="$GROOT/BACKLOG.md" HERD_FAKE_NOW="$NOW" \
      HERD_WATCH_ARGV0="herd-watch-nope-$$-does-not-exist" \
      _status_gather 2>/dev/null )
}
snap="$(gather_snap)"
[ -n "$snap" ] || fail "gather produced no snapshot at all"
grep -q '^NOTES' <<< "$snap" && fail "gather must emit NO NOTES record when no note waits"
printf '%s\t%s\t%s\t%s\n' "$(( NOW - 90 ))" feat-gathered "a waiting finding" 09:58 \
  > "$GTREES/.agent-watch-builder-notes"
snap="$(gather_snap)"
nrec="$(grep '^NOTES' <<< "$snap" | tr $'\037' ' ')"
[ "$nrec" = "NOTES 1 feat-gathered 1m" ] || fail "gather NOTES record wrong: '$nrec'"
ok

echo "ALL PASS ($pass checks)"
