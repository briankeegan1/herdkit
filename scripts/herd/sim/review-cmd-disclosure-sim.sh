#!/usr/bin/env bash
# review-cmd-disclosure-sim.sh — the REVIEW/GATE simulation for REVIEW_CMD_DISCLOSURE (HERD-810).
#
# Replays the PR #863 incident end to end through the SHIPPED code, under both lever settings, and
# asserts the gate can no longer mistake an unexecuted reviewer check for evidence:
#
#   stage 1  the real scripts/herd/herd-review.sh runs headless against a stub reviewer that replays
#            the RETAINED #863 stream — the Codex router refusing the reviewer's rm -rf-bearing
#            temporary-checkout test replay — and then prints the same BLOCK the live reviewer printed;
#   stage 2  the sha-keyed result file that gate wrote is COLLECTED by the live Python engine core
#            (pysrc/herd/live_runtime.py LiveGates.review — the watcher's actual collect path), which
#            must record the verdict to the review ledger and PARSE the disclosure lines — without
#            re-emitting the gate's review_cmd_unexecuted event into the shared journal (single writer);
#   stage 3  the retained review log is read back the way a human / `herd why` would.
#
# Invariants proven:
#   • OFF (default): result file, stdout and retained-log tail are byte-identical to the pre-HERD-810
#     shape — verdict only, no disclosure, no review_cmd_unexecuted event from either side;
#   • ON + BLOCK: the BLOCK verdict is PRESERVED verbatim and recorded as BLOCK (an independently
#     supported block is still a block), while the result file, the retained log and the shared
#     journal carry the refused command — EXACTLY ONCE (the gate writes it; the core never re-appends);
#   • ON + PASS: the PASS is recorded as PASS but the verdict line now carries the advisory naming
#     the refused command — the merge proceeds, labelled as a diff-read-only PASS;
#   • FAIL-CLOSED provenance: a reviewer whose stream vanished discloses `UNEXECUTED: unknown`.
#
# Fully hermetic: stub gh/git/herdr/claude on PATH, a mktemp sandbox, no network, no pane. Ships
# DORMANT (nothing in the engine invokes it).  Run:  bash scripts/herd/sim/review-cmd-disclosure-sim.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
REVIEW="$REPO/scripts/herd/herd-review.sh"
FIX="$REPO/tests/fixtures/review-cmd-disclosure/codex-rejected-863.txt"

fail() { echo "SIM FAIL: $1" >&2; exit 1; }
[ -f "$REVIEW" ] || fail "herd-review.sh not found at $REVIEW"
[ -f "$FIX" ]    || fail "fixture log not found at $FIX"
command -v python3 >/dev/null 2>&1 || fail "python3 required"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
# herd-review.sh allocates its retained log as mktemp "${TMPDIR:-/tmp}/herd-review-<pr>-XXXXXX". These
# runs reuse REAL PR numbers, so a shared TMPDIR would drop fixture-replay logs beside the live gate's
# own retained logs for that PR (it did: a stale #863 verdict leaked into #864's review trail). Keep
# every log this run creates inside the sandbox.
export TMPDIR="$T"
BIN="$T/bin"; mkdir -p "$BIN"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/git";   chmod +x "$BIN/git"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/herdr"; chmod +x "$BIN/herdr"
GH_LOG="$T/gh.log"
printf '#!/usr/bin/env bash\n[ -n "${GH_LOG:-}" ] && printf "%%s\\n" "$*" >> "$GH_LOG"\nexit 0\n' > "$BIN/gh"; chmod +x "$BIN/gh"
cat > "$BIN/claude" <<'STUB'
#!/usr/bin/env bash
[ -n "${STUB_STREAM:-}" ] && [ -f "$STUB_STREAM" ] && cat "$STUB_STREAM"
printf '{"type":"result","subtype":"success","result":"%s"}\n' "${STUB_VERDICT:-REVIEW: PASS}"
exit 0
STUB
chmod +x "$BIN/claude"
export PATH="$BIN:$PATH" HOME="$T" HERD_SKIP_PREFLIGHT=1 HERD_CONFIG_FILE="$T/no-such-config"
export WORKTREES_DIR="$T/trees"; mkdir -p "$WORKTREES_DIR"
export JOURNAL_FILE="$T/gate-journal.jsonl"; : > "$JOURNAL_FILE"

grep -v '^REVIEW: \|^─── \|^Next: ' "$FIX" > "$T/stream-863.txt"
REJECTED_CMD="$(sed -n '/exec_command failed for `/{s/.*exec_command failed for `\(.*\)`: CreateProcess.*/\1/p;q;}' "$FIX")"
BLOCK_LINE='REVIEW: BLOCK — rule: silently wrong watcher/audit state | why: optional telemetry suppresses the sole INFRA collection terminal | location: scripts/herd/journal-audit-replay.sh:172'

echo "── review command-disclosure sim (HERD-810) ─────────────────────────────"
echo "incident : PR #863 — Codex refused the reviewer's rm -rf-bearing checkout replay; verdict never said so"
echo "refused  : ${REJECTED_CMD:0:96}…"
echo

# gate <pr> <slug> <verdict> [ENV=val…] — stage 1: the real gate, headless. Sets RES/OUT/RC/LOG.
gate() {
  local pr="$1" slug="$2" verdict="$3"; shift 3
  RES="$T/result-$pr-$slug"; rm -f "$RES"; : > "$GH_LOG"
  OUT="$(HERD_NO_PANE=1 HERD_REVIEW_RESULT_FILE="$RES" HERD_REVIEW_SHA="sha-$slug" STUB_STREAM="$T/stream-863.txt" \
         STUB_VERDICT="$verdict" GH_LOG="$GH_LOG" env "$@" bash "$REVIEW" "$pr" "$slug" 2>/dev/null)"
  RC=$?
  LOG="$(tail -1 "$WORKTREES_DIR/.review-log-$slug" 2>/dev/null || true)"
  [ -f "$RES" ] || fail "$slug: gate wrote no result file"
  [ -n "$LOG" ] && [ -f "$LOG" ] || fail "$slug: retained log not tracked"
}

# collect <pr> <slug> <result-file> — stage 2: the live Python core collects the result file exactly as
# the watcher does, writing the SAME shared journal the gate wrote (production: one journal per
# workspace). Prints "<recorded-verdict>\t<parsed disclosure json>\t<sha-keyed review_cmd_unexecuted
# rows in the shared journal>". SINGLE-WRITER regression (PR #864 review): the gate is the only
# producer of review_cmd_unexecuted — the core collect must leave that count untouched.
collect() {
  PYTHONPATH="$REPO/pysrc" PR="$1" SLUG="$2" RESULT="$3" JOURNAL="$JOURNAL_FILE" TREES="$T/core-$2" python3 - <<'PY'
import json, os, shutil
from herd.live_runtime import LiveState, LiveJournal, LiveGates, LiveCandidate
trees = os.environ["TREES"]; os.makedirs(trees, exist_ok=True)
st = LiveState(trees); jn = LiveJournal(os.environ["JOURNAL"])
c = LiveCandidate(pr=int(os.environ["PR"]), sha="sha-" + os.environ["SLUG"], slug=os.environ["SLUG"])
shutil.copyfile(os.environ["RESULT"], st.review_result_file(c))
class G(LiveGates):
    def _dispatch_review(self, cand, tier_model=""): raise AssertionError("must not re-dispatch")
    def _dispatch_health(self, cand, profile=""): raise AssertionError("must not dispatch health")
g = G("/home", st, jn)
v = g.review(c)
rows = []
if os.path.exists(jn.path):
    for line in open(jn.path, encoding="utf-8"):
        line = line.strip()
        if not line: continue
        e = json.loads(line)
        if e.get("event") == "review_cmd_unexecuted" and e.get("sha") == c.sha: rows.append(e)
assert st.recorded_review(c.pr, c.sha) == v, "ledger row must match the collected verdict"
print("%s\t%s\t%s" % (v, json.dumps(g.unexecuted_cmds), json.dumps(rows)))
PY
}
gate_events() { grep -c '"review_cmd_unexecuted"' "$JOURNAL_FILE" 2>/dev/null || true; }

# ── A. OFF (default) — the pre-HERD-810 shape, byte for byte ───────────────────────────────────────
gate 863 off "$BLOCK_LINE"
[ "$RC" -eq 1 ] && [ "$OUT" = "$BLOCK_LINE" ] || fail "A: OFF gate should print exactly the BLOCK (rc=$RC): $OUT"
[ "$(cat "$RES")" = "$BLOCK_LINE" ] || fail "A: OFF result file must be the verdict alone"
grep -q 'exec_command failed for' "$LOG" || fail "A: the raw refusal is in the retained log (it always was — buried)"
grep -q 'UNEXECUTED' "$LOG" && fail "A: OFF must add no disclosure block"
[ "$(gate_events)" = "0" ] || fail "A: OFF must journal no review_cmd_unexecuted"
IFS=$'\t' read -r v parsed rows <<< "$(collect 863 off "$RES")"
[ "$v" = "BLOCK" ] || fail "A: core should record BLOCK, got $v"
[ "$parsed" = "[]" ] && [ "$rows" = "[]" ] || fail "A: nothing disclosed, nothing journaled (parsed=$parsed rows=$rows)"
[ "$(gate_events)" = "0" ] || fail "A: the shared journal must still hold 0 events after the core collect"
OFF_RES="$(cat "$RES")"; OFF_TAIL="$(tail -3 "$LOG")"
printf '%-28s %s\n' "A. OFF + BLOCK" "verdict BLOCK recorded · result file = verdict only · refusal buried in log · 0 events   ✓"

# ── B. ON + BLOCK — verdict preserved; refusal durable in result file, log, gate + core journals ───
gate 863 on-block "$BLOCK_LINE" REVIEW_CMD_DISCLOSURE=on
[ "$RC" -eq 1 ] && [ "$OUT" = "$BLOCK_LINE" ] || fail "B: ON must emit the BLOCK verbatim (rc=$RC): $OUT"
[ "$(tail -1 "$RES")" = "$BLOCK_LINE" ] || fail "B: verdict must remain the last result-file line"
[ "$(head -1 "$RES")" = "UNEXECUTED: rejected | $REJECTED_CMD" ] || fail "B: result file must carry the refused command: $(head -1 "$RES")"
grep -q 'reviewer verification NOT EXECUTED (1)' "$LOG" || fail "B: retained log must carry the disclosure block"
d="$(awk '/reviewer verification NOT EXECUTED/ {print NR; exit}' "$LOG")"; b="$(awk '/review complete: ⛔/ {print NR; exit}' "$LOG")"
[ "$d" -lt "$b" ] 2>/dev/null || fail "B: disclosure block must precede the completion banner"
[ "$(gate_events)" = "1" ] || fail "B: gate must journal exactly one review_cmd_unexecuted"
grep -E '"review_cmd_unexecuted".*"sha": *"sha-on-block"' "$JOURNAL_FILE" >/dev/null || fail "B: gate event must be sha-keyed"
grep -q 'Reviewer verification NOT executed' "$GH_LOG" || fail "B: a qualifying PR comment must be posted"
IFS=$'\t' read -r v parsed rows <<< "$(collect 863 on-block "$RES")"
[ "$v" = "BLOCK" ] || fail "B: core must still record BLOCK (disclosure never changes a verdict), got $v"
PARSED="$parsed" ROWS="$rows" python3 - <<'PY' || fail "B: single-writer regression — the core re-journaled (or mis-parsed) the disclosure"
import json, os
parsed = json.loads(os.environ["PARSED"]); rows = json.loads(os.environ["ROWS"])
assert len(parsed) == 1 and parsed[0]["kind"] == "rejected" and "rm -rf" in parsed[0]["cmd"], parsed
assert len(rows) == 1, "expected exactly ONE sha-keyed review_cmd_unexecuted row (the gate's), got %d" % len(rows)
r = rows[0]
assert str(r["count"]) == "1" and r["kinds"] == "rejected" and "rm -rf" in r["first_cmd"], r
assert "log" in r, "the surviving row must be the GATE's (it carries the retained-log path): %r" % r
assert json.loads(r["commands"]) == parsed, "the gate row must carry EVERY command as JSON, matching the core's parse: %r" % r
PY
[ "$(gate_events)" = "1" ] || fail "B: the shared journal must hold exactly 1 event after the core collect (single writer), got $(gate_events)"
printf '%-28s %s\n' "B. ON + BLOCK" "verdict BLOCK preserved · UNEXECUTED in result+log+comment · ONE journal row (gate) ✓"

# ── C. ON + PASS — merge proceeds, but labelled as not test-backed ────────────────────────────────
gate 864 on-pass "REVIEW: PASS" REVIEW_CMD_DISCLOSURE=on
[ "$RC" -eq 0 ] || fail "C: a PASS stays exit 0, got $RC"
grep -q '^REVIEW: PASS — advisory: reviewer verification command rejected — NOT executed' <<< "$OUT" || fail "C: PASS must carry the advisory: $OUT"
IFS=$'\t' read -r v parsed rows <<< "$(collect 864 on-pass "$RES")"
[ "$v" = "PASS" ] || fail "C: core must record PASS, got $v"
[ "$parsed" != "[]" ] || fail "C: core must parse the disclosure alongside the PASS"
[ "$(gate_events)" = "2" ] || fail "C: exactly one new event (the gate's) — got $(gate_events)"
printf '%-28s %s\n' "C. ON + PASS" "verdict PASS recorded · advisory names the refused command · ONE journal row (gate) ✓"

# ── D. ON + clean stream — byte-identical to OFF ──────────────────────────────────────────────────
: > "$T/stream-863.txt"
gate 863 clean-on "$BLOCK_LINE" REVIEW_CMD_DISCLOSURE=on
[ "$(cat "$RES")" = "$OFF_RES" ] || fail "D: ON with nothing refused must produce the OFF result file"
[ "$(tail -3 "$LOG")" = "$OFF_TAIL" ] || fail "D: ON with nothing refused must produce the OFF log tail"
[ "$(gate_events)" = "2" ] || fail "D: no new gate event for a clean stream"
printf '%-28s %s\n' "D. ON + nothing refused" "result file + log tail byte-identical to OFF · no event                          ✓"

# ── F. MULTI-COMMAND refusal — every command survives in the ONE durable journal row ──────────────
cat > "$T/stream-863.txt" <<'MULTI'
ERROR codex_core::tools::router: error=exec_command failed for `rm -rf /tmp/scratch-a`: CreateProcess { message: "Rejected(\"rm -f style commands are not permitted\")" }
ERROR codex_core::tools::router: error=exec_command failed for `bash tests/x.sh`: CreateProcess { message: "spawn failed" }
ERROR codex_core::tools::router: error=exec_command failed for `git push origin main`: CreateProcess { message: "Rejected(\"no\")" }
MULTI
gate 863 multi "$BLOCK_LINE" REVIEW_CMD_DISCLOSURE=on
[ "$(grep -c '^UNEXECUTED: ' "$RES")" -eq 3 ] || fail "F: result file should carry 3 disclosure lines"
IFS=$'\t' read -r v parsed rows <<< "$(collect 863 multi "$RES")"
PARSED="$parsed" ROWS="$rows" python3 - <<'PY' || fail "F: a multi-command refusal must be fully reconstructible from the single journal row"
import json, os
parsed = json.loads(os.environ["PARSED"]); rows = json.loads(os.environ["ROWS"])
assert [p["cmd"] for p in parsed] == ["rm -rf /tmp/scratch-a", "bash tests/x.sh", "git push origin main"], parsed
assert len(rows) == 1 and str(rows[0]["count"]) == "3" and rows[0]["kinds"] == "failed,rejected", rows
assert json.loads(rows[0]["commands"]) == parsed, rows[0]
PY
[ "$(gate_events)" = "3" ] || fail "F: exactly one new event for the multi-command review (3 total), got $(gate_events)"
printf '%-28s %s\n' "F. ON + 3 refused commands" "ONE journal row carries all 3 (count/kinds/commands JSON) · core parse agrees        ✓"

# ── E. FAIL-CLOSED provenance — the resolver over a vanished stream ───────────────────────────────
line="$(bash "$REPO/scripts/herd/review-cmd-disclosure.sh" "$T/vanished-stream")"
grep -q '^UNEXECUTED: unknown | ' <<< "$line" || fail "E: an unreadable stream must disclose 'unknown', got: $line"
printf '%-28s %s\n' "E. unreadable stream" "UNEXECUTED: unknown — provenance never silently assumed                            ✓"

echo
echo "SIM PASS — an unexecuted reviewer check is durable in the result file, the retained log, the PR and the journal (once); BLOCK stays BLOCK; OFF stays byte-identical."
