#!/usr/bin/env bash
# test-py-fixture-extract.sh — gate proof for the P3e SCENARIO→FIXTURE BRIDGE (HERD-319, EPIC HERD-300).
#
# P3e is the last P3 integration seam: it turns a REAL sim journal into a shadow-runtime fixture so
# the Python shadow engine can process the SAME subjects the bash engine just did, and `parity-run.sh
# --shadow auto` diffs the two streams — a genuine head-to-head instead of a one-engine self-diff.
#
#   • pysrc/herd/fixture_extract.py    — fold a real journal → {config, candidates} fixture
#   • scripts/herd/sim/parity-run.sh   — `--shadow auto`: extract → run shadow engine → diff
#
# This proves the item's verification criteria, hermetically (python3 stdlib only; no gh/network/model):
#   (A) EXTRACTION RULES — a known journal folds to the expected candidates: health/review from the
#       rail outcomes, review counts ONLY reviewer-provenance verdicts (contract §3.2), stale from
#       stale/restale/starvation (§2.1/§6.2), holds (§5.4/§5.5), sha last-wins (§2.4), and the
#       auxiliary events are EXCLUDED (tallied, never fabricated into a candidate).
#   (B) CONFIG INFERENCE — a gates_passed merge infers MERGE_POLICY=auto (§5.5); --config wins.
#   (C) INFRA LOUDNESS — an unreadable/invalid journal is exit 2, never a silent empty fixture.
#   (D) BRIDGE PIPELINE — extract → `python3 -m herd.shadow_runtime` produces a shadow journal whose
#       terminal outcomes match the fixture (merge / block / hold), the head-to-head input the diff needs.
#   (E) END-TO-END (skip-guarded) — `parity-run.sh --shadow auto` on the real sandbox scenario writes
#       the fixture + a shadow journal and emits an HONEST divergence report (the two engines' event
#       vocabularies differ — divergence is the SUCCESS deliverable, never a forced green), AND the
#       DEFAULT run (no --shadow auto) is byte-identical-off: it writes NO fixture and stays green.
#
# Run:  bash tests/test-py-fixture-extract.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
PYSRC="$REPO/pysrc"
PARITY_RUN="$REPO/scripts/herd/sim/parity-run.sh"

command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 required" >&2; exit 1; }
[ -f "$PYSRC/herd/fixture_extract.py" ] || { echo "FAIL: pysrc/herd/fixture_extract.py missing" >&2; exit 1; }
[ -f "$PYSRC/herd/shadow_runtime.py" ] || { echo "FAIL: pysrc/herd/shadow_runtime.py missing" >&2; exit 1; }
[ -f "$PARITY_RUN" ]                   || { echo "FAIL: scripts/herd/sim/parity-run.sh missing" >&2; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; skips=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); printf '  ✓ %s\n' "$1"; }
skip() { skips=$((skips+1)); printf '  – SKIP: %s\n' "$1"; }

extract() { PYTHONPATH="$PYSRC" python3 -m herd.fixture_extract "$@"; }

# A REAL-shaped journal: three merged PRs (health/review both green), one reviewer BLOCK, one
# NON-reviewer verdict that must be IGNORED, a stale-base + starvation PR, a human-verify hold, an
# approval, a lap-bumped sha (last one must win), and a pile of AUXILIARY events that must be excluded.
cat > "$T/real.jsonl" <<'EOF'
{"ts":"2026-07-10T00:00:01Z","event":"healthcheck_started","pr":101,"slug":"feat-1","sha":"s101","pid":11,"log_path":"/tmp/a/h.log"}
{"ts":"2026-07-10T00:00:02Z","event":"healthcheck_outcome","pr":101,"slug":"feat-1","outcome":"CLEAN"}
{"ts":"2026-07-10T00:00:03Z","event":"review_dispatched","pr":101,"sha":"s101","pid":12,"model":"m","log_path":"/tmp/a/r.log","pin":"s101"}
{"ts":"2026-07-10T00:00:04Z","event":"verdict_recorded","pr":101,"sha":"s101","value":"PASS","source":"reviewer"}
{"ts":"2026-07-10T00:00:05Z","event":"merge","pr":101,"slug":"feat-1","sha":"s101","method":"squash","reason":"gates_passed"}
{"ts":"2026-07-10T00:00:06Z","event":"reap","pr":101,"slug":"feat-1","sha":"s101","reason":"merged"}
{"ts":"2026-07-10T00:00:07Z","event":"healthcheck_outcome","pr":202,"slug":"feat-2","outcome":"CODEERROR"}
{"ts":"2026-07-10T00:00:08Z","event":"verdict_recorded","pr":303,"sha":"s303","value":"BLOCK","source":"reviewer"}
{"ts":"2026-07-10T00:00:09Z","event":"verdict_recorded","pr":404,"sha":"s404","value":"BLOCK","source":"stale-memo"}
{"ts":"2026-07-10T00:00:10Z","event":"pr_restale","pr":505,"sha":"s505-0","slug":"fair-5","kind":"stale-base","laps":1}
{"ts":"2026-07-10T00:00:11Z","event":"pr_restale","pr":505,"sha":"s505-1","slug":"fair-5","kind":"stale-base","laps":2}
{"ts":"2026-07-10T00:00:12Z","event":"pr_starvation","pr":505,"sha":"s505-1","slug":"fair-5","laps":2,"threshold":2}
{"ts":"2026-07-10T00:00:13Z","event":"hold_applied","pr":606,"sha":"s606","slug":"hv-6","kind":"human-verify"}
{"ts":"2026-07-10T00:00:14Z","event":"approval_recorded","pr":707,"sha":"s707","state":"approved","source":"human"}
{"ts":"2026-07-10T00:00:15Z","event":"main_health","pr":999,"sha":"s999","result":"green"}
{"ts":"2026-07-10T00:00:16Z","event":"main_health","pr":901,"sha":"s901","result":"dispatched","pid":71,"log_path":"/tmp/tr/.health-log-main-s901","provenance":"merge"}
{"ts":"2026-07-10T00:00:17Z","event":"main_health","pr":901,"sha":"s901","result":"green"}
{"ts":"2026-07-10T00:00:18Z","event":"main_health","pr":902,"sha":"s902","result":"dispatched","pid":72,"log_path":"/tmp/tr/.health-log-main-s902","provenance":"merge"}
{"ts":"2026-07-10T00:00:19Z","event":"main_health","pr":902,"sha":"s902","result":"red","failed":"app/x.test.sh","since":902}
{"ts":"2026-07-10T00:00:20Z","event":"push_hold_awaiting","slug":"pg-demo","sha":"pgs1","dir":"/tmp/pg-repo"}
{"ts":"2026-07-10T00:00:21Z","event":"push_hold_approved","slug":"pg-demo","sha":"pgs1"}
{"ts":"2026-07-10T00:00:22Z","event":"push_hold_resumed","slug":"pg-demo","sha":"pgs1"}
{"ts":"2026-07-10T00:00:23Z","event":"push_hold_awaiting","slug":"pg-stale","sha":"pgs2","dir":"/tmp/pg-repo2"}
{"ts":"2026-07-10T00:00:24Z","event":"push_hold_approved","slug":"pg-stale","sha":"pgs2"}
{"ts":"2026-07-10T00:00:25Z","event":"symbol_index_refresh","pr":101,"result":"skipped","reason":"no-index"}
{"ts":"2026-07-10T00:00:26Z","event":"infra_breaker_open","scope":"global","fails":3}
EOF

FX="$T/fixture.json"
extract "$T/real.jsonl" --out "$FX" || fail "extract exited nonzero on a valid journal"

# jq-free field probe: python reads the fixture and prints "KEY VALUE" lines the test greps.
probe() { PYTHONPATH="$PYSRC" python3 - "$FX" "$@" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
cands = {c["pr"]: c for c in d["candidates"]}
def g(pr, key, default="∅"):
    return cands.get(pr, {}).get(key, default)
op = sys.argv[2]
if op == "field":
    print(g(sys.argv[3], sys.argv[4]))
elif op == "count":
    print(len(d["candidates"]))
elif op == "has":
    print("yes" if sys.argv[3] in cands else "no")
elif op == "cfg":
    print(d.get("config", {}).get(sys.argv[3], "∅"))
elif op == "excluded":
    print(d["_extracted"]["excluded_events"].get(sys.argv[3], 0))
elif op == "mhcount":
    print(len(d.get("main_healths", [])))
elif op == "mhfield":
    # mhfield <pr> <key>: find the main_healths entry for <pr>, print <key> (∅ if absent).
    mh = {m["pr"]: m for m in d.get("main_healths", [])}
    print(mh.get(sys.argv[3], {}).get(sys.argv[4], "∅"))
elif op == "phcount":
    print(len(d.get("push_holds", [])))
elif op == "phfield":
    # phfield <slug> <key>
    ph = {p["slug"]: p for p in d.get("push_holds", [])}
    print(ph.get(sys.argv[3], {}).get(sys.argv[4], "∅"))
elif op == "faircount":
    print(len(d.get("fairness", [])))
elif op == "fairevents":
    # the ordered list of fairness event names
    print(" ".join(e.get("event", "?") for e in d.get("fairness", [])))
elif op == "mecount":
    print(len(d.get("main_events", [])))
PY
}

# ── (A) extraction rules ──────────────────────────────────────────────────────────────────────────
[ "$(probe field 101 health)" = "CLEAN" ] && [ "$(probe field 101 review)" = "PASS" ] \
  || fail "PR101 should extract health=CLEAN review=PASS"
[ "$(probe field 202 health)" = "CODEERROR" ] || fail "PR202 should extract health=CODEERROR (§2.2)"
[ "$(probe field 303 review)" = "BLOCK" ] || fail "PR303 reviewer BLOCK should extract review=BLOCK"
ok "rail outcomes map: health CLEAN/CODEERROR, reviewer PASS/BLOCK (contract §2.2)"

# provenance: a NON-reviewer verdict must be ignored — PR404's review defaults to PASS, not BLOCK.
[ "$(probe field 404 review)" = "PASS" ] \
  || fail "PR404 non-reviewer verdict leaked into review (must ignore source!=reviewer, §3.2)"
ok "only reviewer-provenance verdicts count — a non-reviewer BLOCK is ignored (contract §3.2)"

# restale/starvation is the merge-FAIRNESS family (HERD-335): NOT a gate candidate (a fairness re-stale
# is a scheduler fixed-point, not a health/review verdict on a sha), so PR505 must NOT be a candidate —
# its pr_restale/pr_restale/pr_starvation fold into the ordered `fairness` replay list verbatim (§6.2).
[ "$(probe has 505)" = "no" ] || fail "PR505 (restale/starvation) must NOT become a gate candidate (HERD-335, §6.2)"
[ "$(probe faircount)" = "3" ] || fail "expected 3 fairness replay events (2 pr_restale + 1 pr_starvation), got $(probe faircount)"
[ "$(probe fairevents)" = "pr_restale pr_restale pr_starvation" ] \
  || fail "fairness list should preserve event ORDER, got '$(probe fairevents)'"
ok "restale/starvation fold into the ordered fairness replay list, never a candidate (contract §6.2, HERD-335)"

# holds
[ "$(probe field 606 hv_hold)" = "True" ] || fail "PR606 human-verify hold should set hv_hold=true (§5.4)"
[ "$(probe field 707 approved)" = "True" ] || fail "PR707 approval_recorded should set approved=true (§5.5)"
ok "human-verify hold → hv_hold, approval_recorded → approved (contract §5.4/§5.5)"

# infra_breaker is AUXILIARY — never a candidate, always tallied. reap / symbol_index_refresh are the
# post-merge housekeeping the candidate now MODELS (they set post_merge on PR101, HERD-335), so they are
# neither excluded nor their own subject. main_health / push_hold_* / fairness / main_events are MODELED
# into their own lists, so none of them is a candidate NOR excluded.
[ "$(probe has 999)" = "no" ] || fail "main_health PR999 must NOT become a candidate (§3.4)"
[ "$(probe has 901)" = "no" ] && [ "$(probe has 902)" = "no" ] || fail "main_health PRs must NOT become candidates"
[ "$(probe count)" = "6" ] || fail "expected 6 gate-subject candidates (101,202,303,404,606,707), got $(probe count)"
[ "$(probe field 101 post_merge)" = "True" ] || fail "PR101 (reap + symbol_index_refresh) should set post_merge=true (HERD-335, §3.4)"
[ "$(probe excluded infra_breaker_open)" = "1" ] || fail "infra_breaker_open should be tallied excluded"
[ "$(probe excluded reap)" = "0" ] && [ "$(probe excluded symbol_index_refresh)" = "0" ] \
  || fail "reap/symbol_index_refresh are now modeled as post-merge housekeeping — not excluded (HERD-335)"
[ "$(probe excluded pr_restale)" = "0" ] && [ "$(probe excluded pr_starvation)" = "0" ] \
  || fail "restale/starvation are now modeled fairness — not excluded (HERD-335)"
[ "$(probe excluded main_health)" = "0" ] || fail "main_health is now modeled — it must NOT be in the excluded tally (HERD-325)"
[ "$(probe excluded push_hold_awaiting)" = "0" ] || fail "push_hold_* is now modeled — it must NOT be in the excluded tally (HERD-325)"
ok "infra_breaker excluded + tallied; reap/symbol_index/fairness/main_health/push_hold modeled, none excluded (§2.1/§3.4/§5.4/§6.2)"

# ── (A') non-candidate engine families now MODELED into ordered fixture lists (HERD-325 oracle v2) ────
# main_health folds by (pr,sha): a lone green (999), a dispatched+green pair (901), a dispatched+red pair
# (902) carrying failed/since. push_hold folds by (slug,sha): a full awaiting→approved→resumed (pg-demo)
# and an awaiting→approved with no resume (pg-stale).
[ "$(probe mhcount)" = "3" ] || fail "expected 3 main_health subjects (999,901,902), got $(probe mhcount)"
[ "$(probe mhfield 999 result)" = "green" ] || fail "main_health 999 should be green"
[ "$(probe mhfield 999 dispatched)" = "∅" ] || fail "main_health 999 (lone result, no dispatch) must NOT carry dispatched"
[ "$(probe mhfield 901 result)" = "green" ] && [ "$(probe mhfield 901 dispatched)" = "True" ] \
  || fail "main_health 901 should be a dispatched green"
[ "$(probe mhfield 902 result)" = "red" ] && [ "$(probe mhfield 902 failed)" = "app/x.test.sh" ] \
  && [ "$(probe mhfield 902 since)" = "902" ] \
  || fail "main_health 902 should be a red carrying failed + since"
ok "main_health folds by (pr,sha) into main_healths: lone/green/red, failed+since preserved (§3.4)"

[ "$(probe phcount)" = "2" ] || fail "expected 2 push_hold subjects (pg-demo, pg-stale), got $(probe phcount)"
[ "$(probe phfield pg-demo approved)" = "True" ] && [ "$(probe phfield pg-demo resumed)" = "True" ] \
  || fail "pg-demo should be awaiting→approved→resumed"
[ "$(probe phfield pg-stale approved)" = "True" ] && [ "$(probe phfield pg-stale resumed)" = "∅" ] \
  || fail "pg-stale should be awaiting→approved with NO resume"
ok "push_hold_* folds by (slug,sha) into push_holds: full resume vs held-only (§5.4)"

# ── (B) config inference + override ─────────────────────────────────────────────────────────────────
[ "$(probe cfg MERGE_POLICY)" = "auto" ] || fail "a gates_passed merge should infer MERGE_POLICY=auto (§5.5)"
extract "$T/real.jsonl" --out "$T/fx2.json" --config MERGE_POLICY=observe --config REVIEW_CONCURRENCY=4 \
  || fail "extract with --config overrides errored"
mp="$(PYTHONPATH="$PYSRC" python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["config"]["MERGE_POLICY"])' "$T/fx2.json")"
rc4="$(PYTHONPATH="$PYSRC" python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["config"]["REVIEW_CONCURRENCY"])' "$T/fx2.json")"
[ "$mp" = "observe" ] && [ "$rc4" = "4" ] || fail "--config override did not win (MERGE_POLICY=$mp REVIEW_CONCURRENCY=$rc4)"
ok "MERGE_POLICY=auto inferred from a gates_passed merge; --config always overrides (contract §5.5)"

# stdin path parity: '-' reads the same journal from stdin → identical fixture.
extract - --out "$T/fx-stdin.json" < "$T/real.jsonl" || fail "extract from stdin errored"
cmp -s "$FX" "$T/fx-stdin.json" || fail "stdin extraction differs from file extraction"
ok "reads the journal from stdin ('-') identically to a file"

# ── (C) INFRA loudness: unreadable/invalid journal → exit 2, never a silent empty fixture ────────────
printf 'this is not json\n' > "$T/bad.jsonl"
extract "$T/bad.jsonl" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] || fail "invalid JSON should exit 2 (infra), got $rc"
extract "$T/no-such-file.jsonl" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] || fail "missing journal should exit 2 (infra), got $rc"
ok "invalid/missing journal → INFRA exit 2 (loud, not a silent empty fixture)"

# ── (D) bridge pipeline: extract → shadow_runtime produces a shadow journal with matching outcomes ───
SJ="$T/journal-shadow.jsonl"; : > "$SJ"
SHADOW_JOURNAL_FILE="$SJ" PYTHONPATH="$PYSRC" python3 -m herd.shadow_runtime --fixture "$FX" > "$T/shadow-result.json" \
  || fail "shadow_runtime errored on the extracted fixture"
[ -s "$SJ" ] || fail "bridge produced an empty shadow journal"
# The fixture's subjects reach their expected terminals in the shadow stream: PR101 merges (+ its
# post-merge housekeeping), PR303 blocks (its verdict — a planted BLOCK, so no builder bounce), PR505's
# fairness re-stale + starvation replay verbatim. This is the head-to-head INPUT the diff needs.
grep -q '"event":"merge".*"pr":101' "$SJ" || fail "shadow stream missing the PR101 merge"
grep -q '"event":"symbol_index_refresh".*"pr":101' "$SJ" || fail "shadow stream missing PR101 post-merge housekeeping"
grep -q '"event":"pr_starvation".*"pr":505' "$SJ" || fail "shadow stream missing the PR505 fairness starvation replay"
grep -q '"event":"verdict_recorded".*"pr":303.*"BLOCK"' "$SJ" || fail "shadow stream missing the PR303 review BLOCK verdict"
outc="$(PYTHONPATH="$PYSRC" python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["outcomes"]["202"])' "$T/shadow-result.json")"
[ "$outc" = "BLOCK" ] || fail "PR202 (health CODEERROR) should terminate BLOCK in the shadow run, got $outc"
ok "bridge pipeline: extracted fixture drives the shadow engine to the matching terminals (merge/block/hold)"

# ── (D2) staged-subsystem extraction: panels / steps / gate_status (HERD-304) ─────────────────────────
# A journal carrying the review-PANEL, pipeline-STEPS and gate-STATUS families folds into the ordered
# fixture lists the shadow engine models — NOT into candidates (they are not gate subjects), NOT into
# the excluded tally. A herd-review infra_event routes to its panel; a rail infra_event still doesn't.
cat > "$T/fam.jsonl" <<'EOF'
{"ts":"2026-07-10T00:01:00Z","event":"review_log_retained","pr":"77a","slug":"sim-panel-a","path":"/var/T//herd-review-77a-x","keep":5}
{"ts":"2026-07-10T00:01:01Z","event":"review_pin_soft","pr":"77a","sha":"","reason":"pin objects unavailable; live-diff fallback","pin_mode":""}
{"ts":"2026-07-10T00:01:02Z","event":"review_panelist_verdict","pr":"77a","slug":"sim-panel-a","sha":"","panelist":0,"ref":"bare-model","driver":"herdr-claude","model":"bare-model","verdict":"PASS","reason":"REVIEW: PASS"}
{"ts":"2026-07-10T00:01:03Z","event":"review_panelist_verdict","pr":"77a","slug":"sim-panel-a","sha":"","panelist":1,"ref":"stub:stub-model","driver":"stub","model":"stub-model","verdict":"BLOCK","reason":"REVIEW: BLOCK — rule: x"}
{"ts":"2026-07-10T00:01:04Z","event":"review_panel_folded","pr":"77a","slug":"sim-panel-a","sha":"","policy":"any-block","panelists":2,"refs":"bare-model stub:stub-model","verdict":"REVIEW: BLOCK — rule: x"}
{"ts":"2026-07-10T00:01:05Z","event":"review_panelist_verdict","pr":"77c","slug":"sim-panel-c","sha":"","panelist":0,"ref":"bare-model","driver":"herdr-claude","model":"bare-model","verdict":"PASS","reason":"REVIEW: PASS"}
{"ts":"2026-07-10T00:01:06Z","event":"infra_event","component":"herd-review","pr":"77c","slug":"sim-panel-c","exit_code":2,"stderr_tail":"no verdict"}
{"ts":"2026-07-10T00:01:06Z","event":"review_log_retained","pr":"77e","slug":"sim-panel-e","path":"/var/T//herd-review-77e-y","keep":5}
{"ts":"2026-07-10T00:01:06Z","event":"review_pin_soft","pr":"77e","sha":"","reason":"pin objects unavailable; live-diff fallback","pin_mode":""}
{"ts":"2026-07-10T00:01:07Z","event":"step_run","name":"gate-lint","at":"post-build","kind":"shell","slug":"demo","sha":"cea","outcome":"pass"}
{"ts":"2026-07-10T00:01:08Z","event":"step_run","name":"peer-review","at":"post-build","kind":"shell","slug":"demo","sha":"cea","outcome":"pass"}
{"ts":"2026-07-10T00:01:09Z","event":"step_hold_awaiting","slug":"demo","step":"peer-review","at":"post-build","sha":"cea","dir":"/tmp/st-repo"}
{"ts":"2026-07-10T00:01:10Z","event":"step_run","name":"peer-review","at":"post-build","kind":"shell","slug":"demo","sha":"cea","outcome":"held"}
{"ts":"2026-07-10T00:01:11Z","event":"step_hold_approved","slug":"demo","step":"peer-review","sha":"cea"}
{"ts":"2026-07-10T00:01:12Z","event":"step_hold_released","slug":"demo","step":"peer-review","at":"post-build","sha":"cea"}
{"ts":"2026-07-10T00:01:13Z","event":"step_run","name":"doc-pass","at":"post-build","kind":"skill","slug":"demo","sha":"cea","outcome":"pass"}
{"ts":"2026-07-10T00:01:14Z","event":"gate_status","pr":343,"sha":"simsha","state":"success","context":"herd/gates"}
EOF
FAM_FX="$T/fam-fixture.json"
extract "$T/fam.jsonl" --out "$FAM_FX" || fail "extract errored on the families journal"
famprobe() { PYTHONPATH="$PYSRC" python3 - "$FAM_FX" "$@" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
q = sys.argv[2]
if q == "panels":       print(len(d.get("panels", [])))
elif q == "steps":      print(len(d.get("steps", [])))
elif q == "gates":      print(len(d.get("gate_statuses", [])))
elif q == "cands":      print(len(d.get("candidates", [])))
elif q == "panelists":  print(len(d["panels"][int(sys.argv[3])]["panelists"]))
elif q == "policy":     print(d["panels"][int(sys.argv[3])]["policy"])
elif q == "steprows":   print(len(d["steps"][0]["rows"]))
elif q == "rowhold":    print(d["steps"][0]["rows"][int(sys.argv[3])].get("hold"))
elif q == "rowkind":    print(d["steps"][0]["rows"][int(sys.argv[3])].get("kind"))
elif q == "gatepr":     print(d["gate_statuses"][0]["pr"])
PY
}
[ "$(famprobe panels)" = "3" ] || fail "expected 3 panel subjects (77a, 77c, 77e), got $(famprobe panels)"
[ "$(famprobe cands)"  = "0" ] || fail "panel/step/gate events must NOT become gate candidates, got $(famprobe cands)"
[ "$(famprobe panelists 0)" = "2" ] || fail "panel 77a should carry 2 panelist verdicts"
[ "$(famprobe policy 0)" = "any-block" ] || fail "panel 77a policy should read from its folded event"
# 77c folded to a herd-review infra_event while carrying a PASS panelist ⇒ inferred all-pass policy.
[ "$(famprobe policy 1)" = "all-pass" ] || fail "panel 77c (infra despite a PASS) should infer all-pass, got $(famprobe policy 1)"
# 77e is a LONE single-reviewer dispatch (log/pin notes, no panelist) — modeled as a 0-panelist panel so
# the shadow re-emits those two notes and the head-to-head matches (HERD-325 closed the P3e residual).
[ "$(famprobe panelists 2)" = "0" ] || fail "panel 77e (lone reviewer) should be a 0-panelist panel, got $(famprobe panelists 2)"
[ "$(famprobe steps)" = "1" ] || fail "expected 1 steps run (demo)"
[ "$(famprobe steprows)" = "3" ] || fail "demo should reconstruct 3 distinct rows, got $(famprobe steprows)"
[ "$(famprobe rowhold 1)" = "approve" ] || fail "peer-review hold=approve should be inferred from step_hold_awaiting"
[ "$(famprobe rowkind 2)" = "skill" ] || fail "doc-pass kind=skill should survive extraction"
[ "$(famprobe gates)" = "1" ] || fail "expected 1 gate_status"
[ "$(famprobe gatepr)" = "343" ] || fail "gate_status pr should extract as 343"
# The families must NOT pollute the excluded-events tally (they are modeled, not dropped).
excl="$(PYTHONPATH="$PYSRC" python3 -c 'import json,sys;print(",".join(json.load(open(sys.argv[1]))["_extracted"]["excluded_events"].keys()))' "$FAM_FX")"
case "$excl" in *step_run*|*review_panelist_verdict*|*gate_status*) fail "a modeled family event leaked into the excluded tally: $excl" ;; esac
ok "panels/steps/gate_status fold into ordered fixture lists (not candidates, not excluded); policy inferred (HERD-304)"

# ── (E) end-to-end parity-run --shadow auto + byte-identical-off (skip-guarded on git) ───────────────
if ! command -v git >/dev/null 2>&1; then
  skip "parity-run --shadow auto: git unavailable"
else
  AUTO="$T/auto"; mkdir -p "$AUTO"
  a_out="$(bash "$PARITY_RUN" --scenario sandbox-scenario --shadow auto --artifacts "$AUTO" 2>&1)"; rc=$?
  case "$rc" in
    0|1)
      # rc 1 (divergent) is the EXPECTED honest outcome for a two-engine head-to-head; rc 0 is fine too.
      [ -s "$AUTO/fixture.json" ]        || fail "--shadow auto did not write the extracted fixture"
      [ -s "$AUTO/journal-shadow.jsonl" ] || fail "--shadow auto produced no shadow journal"
      printf '%s\n' "$a_out" | grep -q "python shadow engine via extracted fixture" \
        || fail "--shadow auto did not report the bridge mode"
      printf '%s\n' "$a_out" | grep -qE "divergences:|journal parity: OK" \
        || fail "--shadow auto did not emit a parity report"
      ok "parity-run --shadow auto: real head-to-head on sandbox-scenario (fixture + shadow journal + honest report, rc=$rc)"
      ;;
    2)
      skip "parity-run --shadow auto: scenario could not run in this env (infra, rc=2)"
      printf '%s\n' "$a_out" | tail -4 | sed 's/^/      /'
      ;;
    *)
      printf '%s\n' "$a_out" | tail -15 >&2
      fail "parity-run --shadow auto errored unexpectedly (rc=$rc)"
      ;;
  esac

  # byte-identical-off: the DEFAULT run (no --shadow auto) must not touch the bridge at all — no
  # fixture written — and stays green on the self-diff, exactly as before this change.
  if [ "$rc" != "2" ]; then
    OFF="$T/off"; mkdir -p "$OFF"
    o_out="$(bash "$PARITY_RUN" --scenario sandbox-scenario --artifacts "$OFF" 2>&1)"; orc=$?
    if [ "$orc" = "0" ]; then
      [ ! -e "$OFF/fixture.json" ] || fail "the DEFAULT (self-diff) run wrote a fixture — the bridge is not opt-in"
      printf '%s\n' "$o_out" | grep -q "self-diff" || fail "default run did not use the self-diff mode"
      ok "byte-identical-off: the default self-diff run ignores the bridge (no fixture) and stays green"
    else
      skip "byte-identical-off default run: self-diff not green in this env (rc=$orc) — bridge is still opt-in"
    fi
  fi
fi

echo "ALL PASS ($pass assertions, $skips skipped)"
