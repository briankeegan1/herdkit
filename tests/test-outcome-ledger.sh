#!/usr/bin/env bash
# test-outcome-ledger.sh — hermetic tests for the OUTCOME LEDGER MVP (HERD-739,
# scripts/herd/outcome-ledger.sh + its bin/herd wiring). Covers:
#   (1) OUTCOME_LEDGER=off (default) is byte-inert: report/alerts/daily/sweep/intervene all refuse
#       with one dormant line, exit 0 (2 for intervene's own usage errors stay 2), and write NOTHING
#   (2) the deriver JOINS reconcile(pr->ref) + merge + cost + verdict_recorded + *_bounce refix events
#       into one row per ref, with correct spend split, verdict/block counts and refix rounds
#   (3) risk_class classification from a REAL git diff against CORE_SURFACE_GLOB (core-surface / rails
#       / docs / app / unknown)
#   (4) revert detection via `git log --grep` against a real "Revert ... (#N)" commit
#   (5) alerts: missing +24h / +7d evaluation, reverted, value still unknown past +7d — with the
#       HERD_OL_NOW/window test seams controlling "now" deterministically; ol_alerts_text's exit code
#   (6) the sweep leg fills DUE, unrecorded slots mechanically (reverted->harmful, same-risk-class
#       churn within the window->neutral, else->valuable), is IDEMPOTENT (never re-evaluates a filled
#       slot), and its journal events feed back into the next report
#   (7) `herd intervene`: valid taxonomy journals `intervention`; unknown taxonomy / missing args
#       refuse (exit 2) and write nothing
#   (8) the daily markdown report is written idempotently (byte-identical rewrite is a no-op) and
#       honors --file
#   (9) the real `bin/herd ledger-report` / `bin/herd intervene` wiring, on and off
#
# Fully hermetic: writes only under a mktemp dir; JOURNAL_FILE is pinned throughout; the only git repo
# touched is a throwaway fixture repo this test creates itself.
# Run:  bash tests/test-outcome-ledger.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
OL_SH="$REPO/scripts/herd/outcome-ledger.sh"
JOURNAL_SH="$REPO/scripts/herd/journal.sh"
HERD_BIN="$REPO/bin/herd"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

[ -f "$OL_SH" ]      || fail "outcome-ledger.sh not found at $OL_SH"
[ -f "$JOURNAL_SH" ] || fail "journal.sh not found at $JOURNAL_SH"
command -v python3 >/dev/null 2>&1 || fail "python3 required to run this test"
command -v git     >/dev/null 2>&1 || fail "git required to run this test"

# ── epoch helper (portable — avoids GNU/BSD `date -d` divergence) ──
epoch_of() { python3 -c "import sys,datetime; print(int(datetime.datetime.strptime(sys.argv[1], '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=datetime.timezone.utc).timestamp()))" "$1"; }

# ── fixture git repo: a straight-line history so `git diff sha~1 sha` isolates one file per commit ──
GITROOT="$T/gitroot"; mkdir -p "$GITROOT"
git -C "$GITROOT" init -q
git -C "$GITROOT" config user.email test@example.com
git -C "$GITROOT" config user.name "test"
mkdir -p "$GITROOT/scripts/herd" "$GITROOT/docs" "$GITROOT/src"
echo base > "$GITROOT/BASE.md"; git -C "$GITROOT" add -A; git -C "$GITROOT" commit -q -m "base"

echo core1 > "$GITROOT/scripts/herd/agent-watch.sh"
git -C "$GITROOT" add -A; git -C "$GITROOT" commit -q -m "core change"
SHA_CORE="$(git -C "$GITROOT" rev-parse HEAD)"

echo docs1 > "$GITROOT/docs/readme.md"
git -C "$GITROOT" add -A; git -C "$GITROOT" commit -q -m "docs change"
SHA_DOCS="$(git -C "$GITROOT" rev-parse HEAD)"

echo rails1 > "$GITROOT/scripts/herd/other-lane.sh"
git -C "$GITROOT" add -A; git -C "$GITROOT" commit -q -m "rails change"
SHA_RAILS="$(git -C "$GITROOT" rev-parse HEAD)"

echo appc1 > "$GITROOT/src/app.py"
git -C "$GITROOT" add -A; git -C "$GITROOT" commit -q -m "app change C1"
SHA_C1="$(git -C "$GITROOT" rev-parse HEAD)"

echo appc2 >> "$GITROOT/src/app.py"
git -C "$GITROOT" add -A; git -C "$GITROOT" commit -q -m "app change C2"
SHA_C2="$(git -C "$GITROOT" rev-parse HEAD)"

echo other1 > "$GITROOT/src/other.py"
git -C "$GITROOT" add -A; git -C "$GITROOT" commit -q -m "app change to be reverted"
SHA_REVERTED="$(git -C "$GITROOT" rev-parse HEAD)"

echo other2 >> "$GITROOT/src/other.py"
git -C "$GITROOT" add -A; git -C "$GITROOT" commit -q -m 'Revert "app change to be reverted" (#20)'
SHA_REVERT_COMMIT="$(git -C "$GITROOT" rev-parse HEAD)"

export CORE_SURFACE_GLOB='^scripts/herd/agent-watch\.sh$'

# ── source outcome-ledger.sh as a library ──
# shellcheck source=/dev/null
. "$JOURNAL_SH" || fail "sourcing journal.sh failed"
# shellcheck source=/dev/null
. "$OL_SH" || fail "sourcing outcome-ledger.sh failed"
type ol_report_text  >/dev/null 2>&1 || fail "ol_report_text not defined after sourcing"
type ol_alerts_text  >/dev/null 2>&1 || fail "ol_alerts_text not defined after sourcing"
type ol_daily_write  >/dev/null 2>&1 || fail "ol_daily_write not defined after sourcing"
type ol_sweep_evals  >/dev/null 2>&1 || fail "ol_sweep_evals not defined after sourcing"
type ol_intervene    >/dev/null 2>&1 || fail "ol_intervene not defined after sourcing"
ok

export PROJECT_ROOT="$GITROOT"

# ══════════════════════════════════════════════════════════════════════════════════════════════
# (1) OFF (default) is byte-inert
# ══════════════════════════════════════════════════════════════════════════════════════════════
OFFTREES="$T/off-trees"; mkdir -p "$OFFTREES/.herd"
export WORKTREES_DIR="$OFFTREES"
unset JOURNAL_FILE
unset OUTCOME_LEDGER   # unset ⇒ herd-config.sh's `: "${OUTCOME_LEDGER:=off}"` default applies

off_out="$(bash "$OL_SH" report 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || fail "off: report should exit 0, got $rc"
grep -q 'OUTCOME_LEDGER is off' <<< "$off_out" || fail "off: report should print the dormant note: $off_out"
[ ! -f "$OFFTREES/.herd/journal.jsonl" ] || fail "off: report must never create a journal file"
ok

off_alerts="$(bash "$OL_SH" alerts 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || fail "off: alerts should exit 0 (never the alert-fired exit), got $rc"
grep -q 'OUTCOME_LEDGER is off' <<< "$off_alerts" || fail "off: alerts dormant note missing"
ok

off_daily="$(bash "$OL_SH" daily 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || fail "off: daily should exit 0, got $rc"
grep -q 'OUTCOME_LEDGER is off' <<< "$off_daily" || fail "off: daily dormant note missing"
[ ! -d "$OFFTREES/.herd/ledger-reports" ] || fail "off: daily must never write a report dir"
ok

off_sweep="$(bash "$OL_SH" sweep 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || fail "off: sweep should exit 0, got $rc"
[ ! -f "$OFFTREES/.herd/journal.jsonl" ] || fail "off: sweep must never write a journal file"
ok

off_int="$(bash "$OL_SH" intervene REF-1 safety "test note" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || fail "off: intervene should exit 0 (dormant, not a usage error), got $rc"
grep -q 'OUTCOME_LEDGER is off' <<< "$off_int" || fail "off: intervene dormant note missing"
[ ! -f "$OFFTREES/.herd/journal.jsonl" ] || fail "off: intervene must never write a journal file"
ok

# ══════════════════════════════════════════════════════════════════════════════════════════════
# (2)+(3)+(4) ON: the deriver — join + risk_class + revert detection
# ══════════════════════════════════════════════════════════════════════════════════════════════
export OUTCOME_LEDGER=on
TREES="$T/on-trees"; mkdir -p "$TREES/.herd"
export WORKTREES_DIR="$TREES"
JFILE="$TREES/.herd/journal.jsonl"

cat > "$JFILE" <<JNL
{"ts":"2026-01-09T00:00:00Z","event":"reconcile","pr":10,"slug":"slugA","sha":"$SHA_CORE","ref":"REF-CORE","resolution":"explicit-ref"}
{"ts":"2026-01-09T00:00:00Z","event":"merge","pr":10,"slug":"slugA","sha":"$SHA_CORE","method":"--merge","reason":"gates_passed"}
{"ts":"2026-01-08T23:00:00Z","event":"verdict_recorded","pr":10,"sha":"$SHA_CORE","value":"PASS","source":"reviewer"}
{"ts":"2026-01-08T22:00:00Z","event":"verdict_recorded","pr":10,"sha":"deadbeef","value":"BLOCK","source":"reviewer","reason":"needs a fix"}
{"ts":"2026-01-08T22:30:00Z","event":"refix_bounce","pr":10,"sha":"deadbeef","slug":"slugA"}
{"ts":"2026-01-09T00:00:01Z","event":"cost","component":"builder","pr":10,"slug":"slugA","usd":"12.500000"}
{"ts":"2026-01-09T00:00:02Z","event":"cost","component":"review","pr":10,"slug":"slugA","usd":"3.000000"}
{"ts":"2025-12-01T00:00:00Z","event":"reconcile","pr":20,"slug":"slugR","sha":"$SHA_REVERTED","ref":"REF-REVERTED","resolution":"explicit-ref"}
{"ts":"2025-12-01T00:00:00Z","event":"merge","pr":20,"slug":"slugR","sha":"$SHA_REVERTED","method":"--merge","reason":"gates_passed"}
{"ts":"2026-01-09T00:00:00Z","event":"reconcile","pr":30,"slug":"slugD","sha":"$SHA_DOCS","ref":"REF-DOCS","resolution":"explicit-ref"}
{"ts":"2026-01-09T00:00:00Z","event":"merge","pr":30,"slug":"slugD","sha":"$SHA_DOCS","method":"--merge","reason":"gates_passed"}
{"ts":"2026-01-09T00:00:00Z","event":"reconcile","pr":40,"slug":"slugRL","sha":"$SHA_RAILS","ref":"REF-RAILS","resolution":"explicit-ref"}
{"ts":"2026-01-09T00:00:00Z","event":"merge","pr":40,"slug":"slugRL","sha":"$SHA_RAILS","method":"--merge","reason":"gates_passed"}
{"ts":"2026-01-09T00:00:00Z","event":"reconcile","pr":50,"slug":"slugC1","sha":"$SHA_C1","ref":"REF-C1","resolution":"explicit-ref"}
{"ts":"2026-01-09T00:00:00Z","event":"merge","pr":50,"slug":"slugC1","sha":"$SHA_C1","method":"--merge","reason":"gates_passed"}
{"ts":"2026-01-09T12:00:00Z","event":"reconcile","pr":51,"slug":"slugC2","sha":"$SHA_C2","ref":"REF-C2","resolution":"explicit-ref"}
{"ts":"2026-01-09T12:00:00Z","event":"merge","pr":51,"slug":"slugC2","sha":"$SHA_C2","method":"--merge","reason":"gates_passed"}
JNL

model="$(ol_report_text --json)"
printf '%s' "$model" > "$T/model1.json"

python3 - "$T/model1.json" <<'PY' || fail "deriver: base model assertions failed"
import json, sys
m = json.load(open(sys.argv[1]))
rows = {r["ref"]: r for r in m["rows"]}
assert "REF-CORE" in rows, rows.keys()
r = rows["REF-CORE"]
assert r["prs"] == [10], r["prs"]
assert r["spend"]["builder"] == 12.5, r["spend"]
assert r["spend"]["review"] == 3.0, r["spend"]
assert r["spend"]["total"] == 15.5, r["spend"]
assert r["block_count"] == 1, r["block_count"]
assert r["refix_rounds"] == 1, r["refix_rounds"]
assert r["disposition"] == "accepted", r["disposition"]
assert r["risk_class"] == "core-surface", r["risk_class"]
passn = sum(1 for v in r["verdicts"] if v["value"] == "PASS")
assert passn == 1, r["verdicts"]

assert rows["REF-DOCS"]["risk_class"] == "docs", rows["REF-DOCS"]["risk_class"]
assert rows["REF-RAILS"]["risk_class"] == "rails", rows["REF-RAILS"]["risk_class"]
assert rows["REF-C1"]["risk_class"] == "app", rows["REF-C1"]["risk_class"]
assert rows["REF-C2"]["risk_class"] == "app", rows["REF-C2"]["risk_class"]

rr = rows["REF-REVERTED"]
assert rr["disposition"] == "reverted", rr["disposition"]
assert rr["revert_evidence"], "expected a revert sha recorded"
print("ok")
PY
ok

# risk_class="unknown" when the sha cannot be diffed (a made-up sha never reached by git).
cat > "$T/unknown-journal.jsonl" <<'JNL'
{"ts":"2026-01-09T00:00:00Z","event":"reconcile","pr":99,"slug":"slugU","sha":"0000000000000000000000000000000000dead","ref":"REF-UNKNOWN","resolution":"explicit-ref"}
{"ts":"2026-01-09T00:00:00Z","event":"merge","pr":99,"slug":"slugU","sha":"0000000000000000000000000000000000dead","method":"--merge","reason":"gates_passed"}
JNL
u_model="$(JOURNAL_FILE="$T/unknown-journal.jsonl" ol_report_text --json)"
grep -q '"risk_class":"unknown"' <<< "$u_model" || fail "deriver: unresolvable sha should yield risk_class=unknown: $u_model"
ok

# report text (human) includes the ref + a disposition word.
text_report="$(JOURNAL_FILE="$JFILE" ol_report_text)"
grep -q 'REF-CORE' <<< "$text_report" || fail "report text missing REF-CORE: $text_report"
grep -q 'accepted' <<< "$text_report" || fail "report text missing disposition: $text_report"
ok

# ══════════════════════════════════════════════════════════════════════════════════════════════
# (5) alerts — HERD_OL_NOW controls "now" deterministically
# ══════════════════════════════════════════════════════════════════════════════════════════════
NOW="$(epoch_of 2026-01-11T00:00:00Z)"
export HERD_OL_NOW="$NOW"

alerts_out="$(JOURNAL_FILE="$JFILE" ol_alerts_text 2>&1)"; rc=$?
[ "$rc" -eq 1 ] || fail "alerts: should exit 1 when alerts fired, got $rc"
grep -q 'REF-CORE' <<< "$alerts_out" || fail "alerts: REF-CORE (age 2d, past +24h, not +7d) should carry missing_eval_24h: $alerts_out"
grep -q '\[missing_eval_24h\]' <<< "$alerts_out" || fail "alerts: missing_eval_24h kind tag missing: $alerts_out"
grep -q 'REF-REVERTED' <<< "$alerts_out" || fail "alerts: REF-REVERTED should alert as reverted: $alerts_out"
grep -q '\[reverted\]' <<< "$alerts_out" || fail "alerts: reverted kind tag missing: $alerts_out"
# REF-REVERTED merged ~41 days ago — both +24h and +7d are overdue too.
grep -qE 'REF-REVERTED.*\[missing_eval_7d\]' <<< "$alerts_out" || fail "alerts: REF-REVERTED should also carry missing_eval_7d: $alerts_out"
ok

# a clean model (no rows) reports no alerts and exits 0.
clean_alerts="$(JOURNAL_FILE="$T/does-not-exist.jsonl" ol_alerts_text)"; rc=$?
[ "$rc" -eq 0 ] || fail "alerts: empty journal should exit 0 (no alerts), got $rc"
grep -qi 'no alerts' <<< "$clean_alerts" || fail "alerts: empty journal should say 'no alerts': $clean_alerts"
ok

# ══════════════════════════════════════════════════════════════════════════════════════════════
# (6) sweep — fills DUE slots mechanically, is idempotent, churn detection
# ══════════════════════════════════════════════════════════════════════════════════════════════
export JOURNAL_FILE="$JFILE"
sweep1="$(ol_sweep_evals 2>&1)"
grep -qE 'filled [0-9]+ x 24h, [0-9]+ x 7d' <<< "$sweep1" || fail "sweep: unexpected summary line: $sweep1"
ok

model2="$(ol_report_text --json)"
python3 - <<PY || fail "sweep: eval assertions failed"
import json
m = json.loads('''$model2''')
rows = {r["ref"]: r for r in m["rows"]}

# REF-REVERTED: age well past both windows, disposition=reverted -> harmful on both slots.
rr = rows["REF-REVERTED"]
assert rr["eval_24h"] is not None and rr["eval_24h"]["value"] == "harmful", rr.get("eval_24h")
assert rr["eval_7d"]  is not None and rr["eval_7d"]["value"]  == "harmful", rr.get("eval_7d")

# REF-C1 (app, merged 2026-01-09T00:00) has REF-C2 (app, merged 2026-01-09T12:00, 12h later) as a
# same-risk-class peer inside its own +24h window -> churn -> neutral.
c1 = rows["REF-C1"]
assert c1["eval_24h"] is not None, "REF-C1 should have a filled 24h slot (age > 24h by NOW)"
assert c1["eval_24h"]["value"] == "neutral", c1["eval_24h"]
assert "REF-C2" in c1["eval_24h"]["evidence"], c1["eval_24h"]

# REF-C2 has no LATER same-risk-class peer within its own +24h window -> valuable.
c2 = rows["REF-C2"]
assert c2["eval_24h"] is not None, "REF-C2 should have a filled 24h slot too"
assert c2["eval_24h"]["value"] == "valuable", c2["eval_24h"]

# REF-CORE: no revert, no same-risk-class peer -> valuable.
core = rows["REF-CORE"]
assert core["eval_24h"] is not None and core["eval_24h"]["value"] == "valuable", core.get("eval_24h")
print("ok")
PY
ok

before_lines="$(wc -l < "$JFILE" | tr -d ' ')"
sweep2="$(ol_sweep_evals 2>&1)"
grep -q 'nothing due' <<< "$sweep2" || fail "sweep: second run should be idempotent ('nothing due'): $sweep2"
after_lines="$(wc -l < "$JFILE" | tr -d ' ')"
[ "$before_lines" = "$after_lines" ] || fail "sweep: idempotent re-run must not append new journal lines ($before_lines -> $after_lines)"
ok

# after the sweep, REF-CORE (now evaluated) no longer carries a missing_eval_24h alert.
alerts_after="$(ol_alerts_text 2>&1)"; rc=$?
grep -qE 'REF-CORE.*\[missing_eval_24h\]' <<< "$alerts_after" && fail "alerts: REF-CORE should have cleared missing_eval_24h after the sweep: $alerts_after"
ok

unset HERD_OL_NOW

# ══════════════════════════════════════════════════════════════════════════════════════════════
# (7) intervene
# ══════════════════════════════════════════════════════════════════════════════════════════════
IJ="$T/intervene-journal.jsonl"
JOURNAL_FILE="$IJ" ol_intervene REF-CORE safety "operator paused an unsafe rollout" >/dev/null \
  || fail "intervene: valid taxonomy call should succeed"
grep -q '"event":"intervention"' "$IJ" || fail "intervene: no intervention event journaled: $(cat "$IJ")"
python3 - "$IJ" <<'PY' || fail "intervene: event fields wrong"
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
ev = [o for o in rows if o.get("event") == "intervention"][0]
assert ev["ref"] == "REF-CORE", ev
assert ev["taxonomy"] == "safety", ev
assert ev["note"] == "operator paused an unsafe rollout", ev
assert ev.get("operator"), "operator must be recorded"
print("ok")
PY
ok

: > "$T/intervene-bad.jsonl"
JOURNAL_FILE="$T/intervene-bad.jsonl" ol_intervene REF-CORE not-a-real-taxonomy "note" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 2 ] || fail "intervene: unknown taxonomy should refuse with rc=2, got $rc"
[ ! -s "$T/intervene-bad.jsonl" ] || fail "intervene: unknown taxonomy must journal nothing"
ok

JOURNAL_FILE="$T/intervene-bad2.jsonl" ol_intervene REF-CORE safety >/dev/null 2>&1
rc=$?
[ "$rc" -eq 2 ] || fail "intervene: missing note should refuse with rc=2, got $rc"
ok

# the ledger row picks up the intervention count once it has a real (reconcile-anchored) row.
IJ2="$T/intervene-with-row.jsonl"
cat > "$IJ2" <<JNL
{"ts":"2026-01-09T00:00:00Z","event":"reconcile","pr":10,"slug":"slugA","sha":"$SHA_CORE","ref":"REF-CORE","resolution":"explicit-ref"}
{"ts":"2026-01-09T00:00:00Z","event":"merge","pr":10,"slug":"slugA","sha":"$SHA_CORE","method":"--merge","reason":"gates_passed"}
JNL
JOURNAL_FILE="$IJ2" ol_intervene REF-CORE convenience "auto-merged manually to unblock a demo" >/dev/null
model3="$(JOURNAL_FILE="$IJ2" ol_report_text --json)"
grep -q '"interventions":\[{' <<< "$model3" || fail "deriver: intervention did not attach to its row: $model3"
ok

# ══════════════════════════════════════════════════════════════════════════════════════════════
# (8) daily markdown — idempotent write + --file
# ══════════════════════════════════════════════════════════════════════════════════════════════
export JOURNAL_FILE="$JFILE"
# Pin "now" for this section: an alert's rendered detail carries "<N>s overdue", which otherwise
# ticks up every real second and would make even a genuinely no-op rewrite look different.
export HERD_OL_NOW="$NOW"
DAILY_FILE="$T/daily-out/report.md"
out1="$(ol_daily_write "$DAILY_FILE")"
[ "$out1" = "$DAILY_FILE" ] || fail "daily: should print the file path: $out1"
[ -f "$DAILY_FILE" ] || fail "daily: file was not written"
grep -q 'REF-CORE' "$DAILY_FILE" || fail "daily: markdown missing REF-CORE row"
grep -q '^# Outcome ledger' "$DAILY_FILE" || fail "daily: markdown missing header"
ok

mtime1="$(python3 -c "import os,sys; print(os.path.getmtime(sys.argv[1]))" "$DAILY_FILE")"
sleep 1
ol_daily_write "$DAILY_FILE" >/dev/null
mtime2="$(python3 -c "import os,sys; print(os.path.getmtime(sys.argv[1]))" "$DAILY_FILE")"
[ "$mtime1" = "$mtime2" ] || fail "daily: a byte-identical rewrite must skip the write (mtime changed)"
ok

# default path lands under $WORKTREES_DIR/.herd/ledger-reports/<UTC date>.md
default_out="$(ol_daily_write)"
case "$default_out" in "$TREES/.herd/ledger-reports/"*.md) ok ;; *) fail "daily: default path unexpected: $default_out" ;; esac
[ -f "$default_out" ] || fail "daily: default-path file was not written"
ok
unset HERD_OL_NOW

# ══════════════════════════════════════════════════════════════════════════════════════════════
# (9) real bin/herd wiring — `herd ledger-report` / `herd intervene`, on and off
# ══════════════════════════════════════════════════════════════════════════════════════════════
# Unset the JOURNAL_FILE test seam from the sections above — it would otherwise win over the fixture
# project's own WORKTREES_DIR-derived journal path inside the `bin/herd` subprocess (env is inherited).
unset JOURNAL_FILE
PROJ="$T/proj"; PTREES="$T/proj-trees"

# run_herd <args...> — invoke the real bin/herd from $PROJ. The suite runner that drives THIS test
# file (scripts/ci/run-suite.sh) exports HERD_JOURNAL_HERMETIC=1 (+ HERMETIC_TEST=<name>) for its
# whole run, which is journal.sh's OWN safety net against a hermetic test polluting a real project
# journal (_journal_in_test_context) — it wins even with JOURNAL_FILE unset, redirecting any write to
# a throwaway per-process path instead of $PTREES's journal. That guard is correct for a test that
# might resolve WORKTREES_DIR onto something real; THIS section deliberately targets an isolated
# mktemp fixture project, so it is safe to prove the genuine WORKTREES_DIR-derived write path by
# clearing every test-context signal for just this subprocess.
run_herd() {
  ( cd "$PROJ" && unset HERMETIC_TEST HERD_HERMETIC_GUARD HERD_JOURNAL_HERMETIC BATS_TEST_FILENAME BATS_TEST_NAME
    HERD_NONINTERACTIVE=1 bash "$HERD_BIN" "$@" 2>&1 )
}
mkdir -p "$PROJ/.herd" "$PTREES/.herd"
cat > "$PROJ/.herd/config" <<CFG
PROJECT_ROOT="$GITROOT"
WORKTREES_DIR="$PTREES"
WORKSPACE_NAME="oltest"
CORE_SURFACE_GLOB='^scripts/herd/agent-watch\.sh\$'
OUTCOME_LEDGER="off"
CFG
cp "$JFILE" "$PTREES/.herd/journal.jsonl"

off_bin="$(run_herd ledger-report)"; rc=$?
[ "$rc" -eq 0 ] || fail "herd ledger-report (off): should exit 0, got $rc"
grep -q 'OUTCOME_LEDGER is off' <<< "$off_bin" || fail "herd ledger-report (off): dormant note missing: $off_bin"
ok

off_bin_int="$(run_herd intervene REF-CORE safety "note")"; rc=$?
[ "$rc" -eq 0 ] || fail "herd intervene (off): should exit 0, got $rc"
grep -q 'OUTCOME_LEDGER is off' <<< "$off_bin_int" || fail "herd intervene (off): dormant note missing: $off_bin_int"
ok

sed -i.bak 's/OUTCOME_LEDGER="off"/OUTCOME_LEDGER="on"/' "$PROJ/.herd/config"; rm -f "$PROJ/.herd/config.bak"
on_bin="$(run_herd ledger-report)"; rc=$?
[ "$rc" -eq 0 ] || fail "herd ledger-report (on): should exit 0, got $rc: $on_bin"
grep -q 'REF-CORE' <<< "$on_bin" || fail "herd ledger-report (on): missing REF-CORE row: $on_bin"
ok

on_bin_json="$(run_herd ledger-report --json)"
grep -q '"ref":"REF-CORE"' <<< "$on_bin_json" || fail "herd ledger-report --json (on): missing REF-CORE: $on_bin_json"
ok

on_bin_int="$(run_herd intervene REF-CORE product "a genuine judgment call")"; rc=$?
[ "$rc" -eq 0 ] || fail "herd intervene (on): should succeed, got $rc: $on_bin_int"
grep -q 'intervened' <<< "$on_bin_int" || fail "herd intervene (on): missing confirmation: $on_bin_int"
grep -q '"event":"intervention"' "$PTREES/.herd/journal.jsonl" || fail "herd intervene (on): no journal event written"
ok

bad_taxonomy="$(run_herd intervene REF-CORE bogus "note")"; rc=$?
[ "$rc" -eq 2 ] || fail "herd intervene (on, bad taxonomy): should refuse with rc=2, got $rc"
ok

echo "PASS test-outcome-ledger.sh ($pass checks)"
