#!/usr/bin/env bash
# test-review-cmd-disclosure.sh — hermetic proof for REVIEW_CMD_DISCLOSURE (HERD-810) and its resolver
# scripts/herd/review-cmd-disclosure.sh.
#
# WHY: PR #863's retained reviewer log showed a Codex adversarial reviewer whose intended verification
# command (a temporary-checkout test replay carrying an `rm -rf` cleanup trap) was REFUSED by Codex's
# command policy — and the final `REVIEW: BLOCK` line never disclosed that the check never ran. The
# watcher/coordinator read a verdict indistinguishable from a test-backed one. This test proves the
# disclosure lever both ways:
#
#   PART 1 (the resolver, sourced):
#     (1) the exact PR #863 signature → ONE `rejected` row carrying the runtime's own quoted command
#     (2) a non-Rejected exec error → `failed`; a Claude permission-denial line → `rejected`; an
#         identical retry is de-duplicated; a plain non-zero exit of a command is NOT a disclosure
#     (3) FAIL-CLOSED: an unreadable log → rc 2 from the row fn and ONE `UNEXECUTED: unknown` line
#     (4) disclosure lines flatten '|' → '¦' (the result-file / advisory grammars split on ' | ')
#     (5) the advisory rendering: one segment per line, HERD-105 joiner-free
#   PART 2 (herd-review.sh PR headless mode, stub claude replaying the #863 stream):
#     (6) OFF (default): stdout is exactly the verdict, the result file holds ONLY the verdict, the
#         retained log carries no disclosure block, no review_cmd_unexecuted event, no extra gh comment
#     (7) ON + BLOCK: the BLOCK line is emitted VERBATIM (byte-equal to OFF), the result file carries
#         the UNEXECUTED line BEFORE it, the retained log has the block BEFORE the completion banner,
#         the journal holds review_cmd_unexecuted (count/kinds/first_cmd), a qualifying gh comment posted
#     (8) ON + PASS: the PASS gains an ' — advisory:' segment naming the refused command (so the
#         watcher's existing advisory surface journals it), result file carries the UNEXECUTED line
#     (9) ON + a clean stream (nothing refused): byte-identical to OFF — stdout, result file, log tail
#    (10) ON + RUBRIC lines present: result-file order is rubric lines, disclosure line, verdict
#   PART 3 (herd-review.sh --local mode):
#    (11) ON: the builder sees a stderr warning and an advisory-annotated PASS on stdout; OFF: bare PASS
#
# Run:  bash tests/test-review-cmd-disclosure.sh
# Fully hermetic: stubs gh/git/herdr/claude on PATH; no network, no live pane.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
REVIEW="$REPO/scripts/herd/herd-review.sh"
LIB="$REPO/scripts/herd/review-cmd-disclosure.sh"
FIX="$REPO/tests/fixtures/review-cmd-disclosure/codex-rejected-863.txt"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }
command -v python3 >/dev/null 2>&1 || fail "python3 required to run this test"
[ -f "$REVIEW" ] || fail "herd-review.sh not found at $REVIEW"
[ -f "$LIB" ]    || fail "review-cmd-disclosure.sh not found at $LIB"
[ -f "$FIX" ]    || fail "fixture log not found at $FIX"

# The exact command the PR #863 reviewer tried to run (as Codex's router quoted it back).
REJECTED_CMD="$(sed -n '/exec_command failed for `/{s/.*exec_command failed for `\(.*\)`: CreateProcess.*/\1/p;q;}' "$FIX")"
[ -n "$REJECTED_CMD" ] || fail "fixture does not carry the expected exec_command signature"

################################################################################
# PART 1 — the resolver
################################################################################
# shellcheck source=/dev/null
. "$LIB" || fail "sourcing review-cmd-disclosure.sh failed"
for fn in herd_review_unexecuted_cmds herd_review_disclosure_lines herd_review_disclosure_advisory; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined after sourcing"
done

# ── (1) the PR #863 signature → one rejected row with the verbatim command ──────────────────────
rows="$(herd_review_unexecuted_cmds "$FIX")" || fail "(1) resolver returned non-zero on a readable log"
[ "$(printf '%s\n' "$rows" | grep -c .)" -eq 1 ] || fail "(1) expected exactly 1 row, got: $rows"
[ "${rows%%$'\t'*}" = "rejected" ] || fail "(1) kind should be 'rejected', got: ${rows%%$'\t'*}"
[ "${rows#*$'\t'}" = "$REJECTED_CMD" ] || fail "(1) command should be the runtime's verbatim quote; got: ${rows#*$'\t'}"
grep -qF 'rm -rf' <<< "$rows" || fail "(1) the rm -rf-bearing command must survive verbatim (that IS the evidence)"
ok

# ── (2) failed vs rejected vs Claude denial vs dedup vs plain non-zero exit ────────────────────────
cat > "$T/mixed.log" <<'LOG'
  [Bash] bash tests/x.sh
ERROR codex_core::tools::router: error=exec_command failed for `bash tests/x.sh`: CreateProcess { message: "spawn failed: No such file" }
ERROR codex_core::tools::router: error=exec_command failed for `rm -rf /tmp/scratch`: CreateProcess { message: "Rejected(\"rm -f style commands are not permitted\")" }
ERROR codex_core::tools::router: error=exec_command failed for `rm -rf /tmp/scratch`: CreateProcess { message: "Rejected(\"rm -f style commands are not permitted\")" }
Permission denied for tool Bash — this command requires approval · command: git push origin main
  the test exited 1 (exit code 1) — that is a RESULT, not a refusal
REVIEW: PASS
LOG
rows="$(herd_review_unexecuted_cmds "$T/mixed.log")"
printf '%s\n' "$rows" > "$T/mixed.rows"
[ "$(printf '%s\n' "$rows" | grep -c .)" -eq 3 ] || fail "(2) expected 3 de-duplicated rows, got: $rows"
[ "$(sed -n 1p "$T/mixed.rows")" = "failed	bash tests/x.sh" ]     || fail "(2) a non-Rejected exec error should be 'failed'"
[ "$(sed -n 2p "$T/mixed.rows")" = "rejected	rm -rf /tmp/scratch" ] || fail "(2) a Rejected( exec error should be 'rejected'"
[ "$(sed -n 3p "$T/mixed.rows")" = "rejected	git push origin main" ] || fail "(2) a Claude permission denial should be 'rejected'"
grep -q "exit code" <<< "$rows" && fail "(2) a command's own non-zero exit must never be a disclosure"
ok

# ── (3) FAIL-CLOSED: an unreadable log → rc 2 and one 'unknown' disclosure line ────────────────────
herd_review_unexecuted_cmds "$T/does-not-exist" >/dev/null; rc=$?
[ "$rc" -eq 2 ] || fail "(3) unreadable log should return 2 from the row fn, got $rc"
lines="$(herd_review_disclosure_lines "$T/does-not-exist")"
[ "$(printf '%s\n' "$lines" | grep -c .)" -eq 1 ] || fail "(3) expected exactly one fail-closed line, got: $lines"
grep -q '^UNEXECUTED: unknown | .*provenance cannot be established' <<< "$lines" \
  || fail "(3) fail-closed line should be 'UNEXECUTED: unknown | …provenance…', got: $lines"
# A readable log with NO signature → nothing at all (fail-soft, byte-inert).
: > "$T/clean.log"; printf 'REVIEW: PASS\n' > "$T/clean.log"
[ -z "$(herd_review_disclosure_lines "$T/clean.log")" ] || fail "(3) a clean log must disclose nothing"
ok

# ── (4) '|' inside a command is flattened so the ' | '-separated grammars never split on it ────────
printf 'exec_command failed for `cat a | grep b | wc -l`: CreateProcess { message: "Rejected(\\"no\\")" }\n' > "$T/pipe.log"
lines="$(herd_review_disclosure_lines "$T/pipe.log")"
[ "$lines" = "UNEXECUTED: rejected | cat a ¦ grep b ¦ wc -l" ] || fail "(4) pipes should flatten to ¦, got: $lines"
ok

# ── (5) advisory rendering ─────────────────────────────────────────────────────────────────────────
adv="$(herd_review_disclosure_advisory "$(herd_review_disclosure_lines "$FIX")")"
grep -q '^advisory: reviewer verification command rejected — NOT executed, this verdict is not backed by it: /bin/zsh -lc' <<< "$adv" \
  || fail "(5) advisory segment should name the kind and the command, got: $adv"
two="$(herd_review_disclosure_advisory "$(herd_review_disclosure_lines "$T/mixed.log")")"
[ "$(grep -o 'advisory: reviewer verification command' <<< "$two" | wc -l | tr -d ' ')" -eq 3 ] \
  || fail "(5) one advisory segment per disclosure line expected, got: $two"
grep -q ' | advisory: ' <<< "$two" || fail "(5) multiple segments join with ' | ', got: $two"
ok

################################################################################
# PART 2 — herd-review.sh PR headless mode (real script; stub claude/gh/git/herdr)
################################################################################
BIN="$T/bin"; mkdir -p "$BIN"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/git"; chmod +x "$BIN/git"
GH_LOG="$T/gh-args.log"
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
[ -n "${GH_LOG:-}" ] && printf '%s\n' "$*" >> "$GH_LOG"
exit 0
STUB
chmod +x "$BIN/gh"
cat > "$BIN/herdr" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$BIN/herdr"
# The stub reviewer REPLAYS a stream: $STUB_STREAM is a file whose lines are printed raw (the codex
# router line is not JSON, so the formatter passes it through verbatim — exactly as in #863), then
# the verdict is emitted as a claude `result` frame.
cat > "$BIN/claude" <<'STUB'
#!/usr/bin/env bash
[ -n "${STUB_STREAM:-}" ] && [ -f "$STUB_STREAM" ] && cat "$STUB_STREAM"
printf '{"type":"result","subtype":"success","result":"%s"}\n' "${STUB_VERDICT:-REVIEW: PASS}"
exit 0
STUB
chmod +x "$BIN/claude"
export PATH="$BIN:$PATH"
export HOME="$T"
export JOURNAL_FILE="$T/journal.jsonl"; : > "$JOURNAL_FILE"
export WORKTREES_DIR="$T/trees"; mkdir -p "$WORKTREES_DIR"
export HERD_CONFIG_FILE="$T/no-such-config"
export HERD_SKIP_PREFLIGHT=1

# The #863 stream minus its final verdict/banner lines (the stub appends the verdict itself).
grep -v '^REVIEW: \|^─── \|^Next: ' "$FIX" > "$T/stream-863.txt"
: > "$T/stream-clean.txt"

BLOCK_LINE='REVIEW: BLOCK — rule: silently wrong watcher/audit state | why: optional telemetry suppresses the sole INFRA collection terminal | location: scripts/herd/journal-audit-replay.sh:172'

run_review() {  # <pr> <slug> <stream-file> <verdict> [ENV=val ...]; sets REV_OUT / REV_RC / REV_RES / REV_LOG
  local pr="$1" slug="$2" stream="$3" verdict="$4"; shift 4
  REV_RES="$T/res-$pr-$slug"; rm -f "$REV_RES"; : > "$GH_LOG"
  REV_OUT="$(HERD_NO_PANE=1 HERD_REVIEW_RESULT_FILE="$REV_RES" STUB_STREAM="$stream" STUB_VERDICT="$verdict" \
             GH_LOG="$GH_LOG" env "$@" bash "$REVIEW" "$pr" "$slug" 2>/dev/null)"
  REV_RC=$?
  REV_LOG="$(tail -1 "$WORKTREES_DIR/.review-log-$slug" 2>/dev/null || true)"
  [ -n "$REV_LOG" ] && [ -f "$REV_LOG" ] || fail "$slug: retained review log not tracked"
}
journal_count() { grep -c "\"event\": *\"$1\"" "$JOURNAL_FILE" 2>/dev/null || true; }

# ── (6) OFF (default): byte-identical to before the lever existed ──────────────────────────────────
run_review 863 slug-off "$T/stream-863.txt" "$BLOCK_LINE"
[ "$REV_RC" -eq 1 ] || fail "(6) OFF: a BLOCK should exit 1, got $REV_RC"
[ "$REV_OUT" = "$BLOCK_LINE" ] || fail "(6) OFF: stdout must be exactly the verdict line, got: $REV_OUT"
[ "$(cat "$REV_RES")" = "$BLOCK_LINE" ] || fail "(6) OFF: result file must hold ONLY the verdict, got: $(cat "$REV_RES")"
grep -q 'UNEXECUTED' "$REV_LOG" && fail "(6) OFF: retained log must carry no disclosure block"
grep -q 'exec_command failed for' "$REV_LOG" || fail "(6) OFF: the raw rejection line should still be in the retained log (the forensic trail was never missing — it was invisible)"
[ "$(journal_count review_cmd_unexecuted)" = "0" ] || fail "(6) OFF: no review_cmd_unexecuted event"
grep -q 'NOT executed' "$GH_LOG" && fail "(6) OFF: no qualifying gh comment"
OFF_OUT="$REV_OUT"; OFF_RES="$(cat "$REV_RES")"
ok

# ── (7) ON + BLOCK: verdict VERBATIM, disclosure in result file + log + journal + comment ──────────
run_review 863 slug-on-block "$T/stream-863.txt" "$BLOCK_LINE" REVIEW_CMD_DISCLOSURE=on
[ "$REV_RC" -eq 1 ] || fail "(7) ON: a BLOCK should still exit 1, got $REV_RC"
[ "$REV_OUT" = "$OFF_OUT" ] || fail "(7) ON: the BLOCK line must be emitted VERBATIM (byte-equal to OFF), got: $REV_OUT"
[ "$(tail -1 "$REV_RES")" = "$BLOCK_LINE" ] || fail "(7) ON: the verdict must stay the LAST result-file line"
[ "$(head -1 "$REV_RES")" = "UNEXECUTED: rejected | $REJECTED_CMD" ] \
  || fail "(7) ON: the result file must carry the UNEXECUTED line before the verdict, got: $(head -1 "$REV_RES")"
[ "$(wc -l < "$REV_RES" | tr -d ' ')" -eq 2 ] || fail "(7) ON: result file should be exactly 2 lines"
grep -q '^─── reviewer verification NOT EXECUTED (1)' "$REV_LOG" || fail "(7) ON: retained log must carry the disclosure block"
grep -qF "UNEXECUTED: rejected | $REJECTED_CMD" "$REV_LOG" || fail "(7) ON: retained log must carry the UNEXECUTED line"
# Order: disclosure block BEFORE the completion banner — the banner is the last thing in the log.
d_ln="$(awk '/reviewer verification NOT EXECUTED/ {print NR; exit}' "$REV_LOG")"
b_ln="$(awk '/review complete: ⛔ BLOCKED/ {print NR; exit}' "$REV_LOG")"
[ -n "$d_ln" ] && [ -n "$b_ln" ] && [ "$d_ln" -lt "$b_ln" ] || fail "(7) ON: disclosure block ($d_ln) must precede the completion banner ($b_ln)"
[ "$(journal_count review_cmd_unexecuted)" = "1" ] || fail "(7) ON: exactly one review_cmd_unexecuted event expected"
ev="$(grep '"review_cmd_unexecuted"' "$JOURNAL_FILE" | tail -1)"
grep -q '"count": *"1"\|"count": *1' <<< "$ev" || fail "(7) ON: event should carry count=1, got: $ev"
grep -q '"kinds": *"rejected"' <<< "$ev" || fail "(7) ON: event should carry kinds=rejected, got: $ev"
grep -q '"first_cmd": *"/bin/zsh -lc' <<< "$ev" || fail "(7) ON: event should carry the first command, got: $ev"
grep -q '"pr": *"863"\|"pr": *863' <<< "$ev" || fail "(7) ON: event should be keyed to the PR, got: $ev"
grep -q 'pr comment 863 --body' "$GH_LOG" || fail "(7) ON: a qualifying gh comment should be posted"
grep -q 'Reviewer verification NOT executed' "$GH_LOG" || fail "(7) ON: the comment should say the verification was not executed"
ok

# ── (8) ON + PASS: the PASS gains an advisory segment; result file carries the UNEXECUTED line ─────
run_review 864 slug-on-pass "$T/stream-863.txt" "REVIEW: PASS" REVIEW_CMD_DISCLOSURE=on
[ "$REV_RC" -eq 0 ] || fail "(8) ON: a PASS should still exit 0 (the disclosure never changes the verdict), got $REV_RC"
grep -q '^REVIEW: PASS — advisory: reviewer verification command rejected — NOT executed' <<< "$REV_OUT" \
  || fail "(8) ON: PASS should gain the disclosure advisory, got: $REV_OUT"
grep -qF 'rm -rf' <<< "$REV_OUT" || fail "(8) ON: the advisory should name the refused command"
[ "$(head -1 "$REV_RES")" = "UNEXECUTED: rejected | $REJECTED_CMD" ] || fail "(8) ON: result file should carry the UNEXECUTED line"
grep -q '^REVIEW: PASS — advisory:' "$REV_RES" || fail "(8) ON: result file verdict should be the annotated PASS"
# A PASS that ALREADY carries advisories gets the disclosure appended with ' | ' (HERD-105 grammar).
run_review 865 slug-on-pass-adv "$T/stream-863.txt" "REVIEW: PASS — advisory: naming nit" REVIEW_CMD_DISCLOSURE=on
grep -q '^REVIEW: PASS — advisory: naming nit | advisory: reviewer verification command rejected' <<< "$REV_OUT" \
  || fail "(8) ON: an existing advisory tail should be extended with ' | ', got: $REV_OUT"
ok

# ── (9) ON + clean stream: byte-identical to OFF ───────────────────────────────────────────────────
run_review 866 slug-clean-off "$T/stream-clean.txt" "$BLOCK_LINE"
c_off_out="$REV_OUT"; c_off_res="$(cat "$REV_RES")"; c_off_tail="$(tail -3 "$REV_LOG")"
run_review 866 slug-clean-on "$T/stream-clean.txt" "$BLOCK_LINE" REVIEW_CMD_DISCLOSURE=on
[ "$REV_OUT" = "$c_off_out" ] || fail "(9) ON+clean: stdout must be byte-identical to OFF"
[ "$(cat "$REV_RES")" = "$c_off_res" ] || fail "(9) ON+clean: result file must be byte-identical to OFF"
[ "$(tail -3 "$REV_LOG")" = "$c_off_tail" ] || fail "(9) ON+clean: retained log tail must be byte-identical to OFF"
grep -q 'UNEXECUTED' "$REV_LOG" && fail "(9) ON+clean: no disclosure block"
[ "$(journal_count review_cmd_unexecuted)" = "3" ] || fail "(9) ON+clean: no new review_cmd_unexecuted event (still 3 from 7/8)"
run_review 866 slug-clean-pass "$T/stream-clean.txt" "REVIEW: PASS" REVIEW_CMD_DISCLOSURE=on
[ "$REV_OUT" = "REVIEW: PASS" ] || fail "(9) ON+clean: a bare PASS stays a bare PASS, got: $REV_OUT"
ok

# ── (10) ON + RUBRIC lines: result-file order is rubric, disclosure, verdict ───────────────────────
mkdir -p "$T/rubric-root/.herd"
printf 'id\ttext\tweight\tpass_condition\nscoped\tTight diff\trequired\tonly own files\n' > "$T/rubric-root/.herd/rubric.tsv"
{ cat "$T/stream-863.txt"; printf 'RUBRIC: scoped | PASS | tight diff\n'; } > "$T/stream-rubric.txt"
run_review 867 slug-rubric "$T/stream-rubric.txt" "$BLOCK_LINE" REVIEW_CMD_DISCLOSURE=on RUBRIC_FILE=.herd/rubric.tsv PROJECT_ROOT="$T/rubric-root"
[ "$(sed -n 1p "$REV_RES")" = "RUBRIC: scoped | PASS | tight diff" ] || fail "(10) line 1 should be the rubric line, got: $(sed -n 1p "$REV_RES")"
[ "$(sed -n 2p "$REV_RES")" = "UNEXECUTED: rejected | $REJECTED_CMD" ] || fail "(10) line 2 should be the disclosure line, got: $(sed -n 2p "$REV_RES")"
[ "$(sed -n 3p "$REV_RES")" = "$BLOCK_LINE" ] || fail "(10) line 3 should be the verdict"
ok

################################################################################
# PART 3 — herd-review.sh --local mode (a throwaway repo; stub claude as above)
################################################################################
GREPO="$T/repo"
unset -f git 2>/dev/null || true
REALGIT="$(PATH="${PATH#"$BIN":}" command -v git)" || fail "real git required for local mode"
rm -f "$BIN/git"
"$REALGIT" init -q --bare "$T/origin.git"
"$REALGIT" clone -q "$T/origin.git" "$GREPO" 2>/dev/null
"$REALGIT" -C "$GREPO" checkout -q -b main
: > "$GREPO/seed.txt"
"$REALGIT" -C "$GREPO" -c user.email=t@t -c user.name=t add seed.txt
"$REALGIT" -C "$GREPO" -c user.email=t@t -c user.name=t commit -q -m seed
"$REALGIT" -C "$GREPO" push -q -u origin main 2>/dev/null
CFG="$T/config"
cat > "$CFG" <<EOF
PROJECT_ROOT="$GREPO"
WORKTREES_DIR="$WORKTREES_DIR"
DEFAULT_BRANCH="origin/main"
WORKSPACE_NAME="herdkit"
APP_PREVIEW_CMD=""
MODEL_REVIEW="test-review-model"
EOF
run_local() {  # <slug> <stream> <verdict> [ENV=val ...]; sets L_OUT / L_ERR / L_RC
  local slug="$1" stream="$2" verdict="$3"; shift 3
  L_OUT="$(HERD_NO_PANE=1 HERD_CONFIG_FILE="$CFG" STUB_STREAM="$stream" STUB_VERDICT="$verdict" \
           env "$@" bash "$REVIEW" --local "$slug" 2>"$T/local-err")"
  L_RC=$?; L_ERR="$(cat "$T/local-err")"
}
# ── (11) local mode both ways ──────────────────────────────────────────────────────────────────────
run_local slug-local-off "$T/stream-863.txt" "REVIEW: PASS"
[ "$L_RC" -eq 0 ] && [ "$L_OUT" = "REVIEW: PASS" ] || fail "(11) local OFF: bare PASS expected (rc=$L_RC), got: $L_OUT"
grep -q 'NOT EXECUTED' <<< "$L_ERR" && fail "(11) local OFF: no stderr warning"
run_local slug-local-on "$T/stream-863.txt" "REVIEW: PASS" REVIEW_CMD_DISCLOSURE=on
[ "$L_RC" -eq 0 ] || fail "(11) local ON: PASS should still exit 0, got $L_RC"
grep -q '^REVIEW: PASS — advisory: reviewer verification command rejected' <<< "$L_OUT" \
  || fail "(11) local ON: PASS should gain the disclosure advisory, got: $L_OUT"
grep -q 'reviewer verification NOT EXECUTED (1)' <<< "$L_ERR" || fail "(11) local ON: the builder should see the stderr warning"
grep -qF "UNEXECUTED: rejected | $REJECTED_CMD" <<< "$L_ERR" || fail "(11) local ON: stderr should list the refused command"
run_local slug-local-on-block "$T/stream-863.txt" "$BLOCK_LINE" REVIEW_CMD_DISCLOSURE=on
[ "$L_RC" -eq 1 ] && [ "$L_OUT" = "$BLOCK_LINE" ] || fail "(11) local ON: a BLOCK stays verbatim (rc=$L_RC), got: $L_OUT"
ok

echo "ALL PASS ($pass checks)"
