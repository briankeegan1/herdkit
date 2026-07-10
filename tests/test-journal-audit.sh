#!/usr/bin/env bash
# test-journal-audit.sh — hermetic proof of the journal-driven self-audit / gap-finder (HERD-238).
#
# Drives the REAL scripts/herd/journal-audit.sh against synthetic journals through the documented
# seams (JOURNAL_FILE, JOURNAL_AUDIT, HERD_JOURNAL_AUDIT_*, TTL/grace env overrides). Asserts:
#   (1) SHIP-DORMANT: JOURNAL_AUDIT=off (default) writes nothing even when the journal is full of
#       violations.
#   (2) Each violation class produces exactly one journal_audit finding (component=audit) and one
#       operator-inbox row when present alone past its TTL/grace:
#         (a) merge without reap
#         (b) *_dispatched with no terminal past family TTL
#         (c) refix_bounce with no refix_wake_result
#         (d) main_health red older than TTL
#         (e) pushed=no never followed by pushed=yes
#         (f) known-fixture slug
#         (g) a MERGED PR that declared HUMAN-VERIFY steps but carries no sha-keyed approval (HERD-272)
#   (3) A CLEAN journal (every invariant satisfied) emits ZERO journal_audit events and ZERO inbox
#       rows — byte-quiet.
#   (4) IDEMPOTENT: a second run against the same dirty journal does not re-emit (seen-ledger).
#   (5) FAIL-SOFT: empty/missing journal exits 0 with no writes.
#   (7) The HERD-272 human-verify rule end-to-end: approved ⇒ clean; no record ⇒ finding; no block ⇒
#       clean; unreadable body ⇒ an `unknown` finding, never a crash; hv-informed ⇒ still a finding;
#       and a settled-clean PR's body is probed exactly once across ticks.
#
# Fully hermetic: writes only under a mktemp dir, never touches the live watcher/panes/real journal.
# Run:  bash tests/test-journal-audit.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
SCRIPT="$REPO/scripts/herd/journal-audit.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { PASS=$((PASS + 1)); }
command -v python3 >/dev/null 2>&1 || fail "python3 required"
[ -f "$SCRIPT" ] || fail "journal-audit.sh not found at $SCRIPT"

REPO_FIX="$T/repo"
mkdir -p "$REPO_FIX/.herd" "$T/trees/.herd"
export HERD_CONFIG_FILE="$REPO_FIX/.herd/config"
cat > "$REPO_FIX/.herd/config" <<EOF
PROJECT_ROOT="$REPO_FIX"
WORKTREES_DIR="$T/trees"
DEFAULT_BRANCH="main"
EOF

# Pin every surface the audit writes so nothing escapes the temp dir.
export JOURNAL_FILE="$T/trees/.herd/journal.jsonl"
export HERD_JOURNAL_AUDIT_INBOX="$T/trees/.agent-watch-inbox"
export HERD_JOURNAL_AUDIT_SEEN="$T/trees/.agent-watch-journal-audit-seen"
# HERD-272 check (g) reads two live surfaces — the PR body and the approval ledger. Pin BOTH: the
# body behind a fixture command (so no `gh` call can escape to the network or to this repo's real
# PRs), the ledger under the temp dir. Every test below therefore has a body source; a PR with no
# fixture file has an empty body, i.e. declares no HUMAN-VERIFY block.
export HERD_APPROVALS_FILE="$T/trees/.agent-watch-approvals"
export HERD_JOURNAL_AUDIT_PR_BODY_CMD="bash $T/pr-body.sh"
BODIES="$T/bodies"; mkdir -p "$BODIES"
PROBES="$T/pr-body-probes"      # one line per body fetch — proves the memo suppresses re-probes
cat > "$T/pr-body.sh" <<'FIXTURE'
#!/usr/bin/env bash
# Stands in for `gh pr view <pr#> --json body -q .body`: prints the fixture body for <pr#>, exits
# non-zero when the PR is marked unreadable, and prints an empty body for an unknown PR.
pr="$1"
printf '%s\n' "$pr" >> "$PROBES"
[ -f "$BODIES/$pr.fail" ] && exit 7
[ -f "$BODIES/$pr.md" ] && exec cat "$BODIES/$pr.md"
exit 0
FIXTURE
export BODIES PROBES
# "now" pinned so TTLs are deterministic regardless of wall clock.
export HERD_JOURNAL_AUDIT_NOW="2026-07-09T16:00:00Z"
# Short windows so fixture events a few hours back are "past TTL".
export JOURNAL_AUDIT_WINDOW_SECS=86400
export JOURNAL_AUDIT_DISPATCH_TTL=600      # 10 min
export JOURNAL_AUDIT_REFIX_TTL=120         # 2 min
export JOURNAL_AUDIT_RED_TTL=600           # 10 min
export JOURNAL_AUDIT_MERGE_GRACE=60        # 1 min
export JOURNAL_AUDIT_PUSHED_GRACE=120      # 2 min

# Helpers ─────────────────────────────────────────────────────────────────────
reset_surfaces() {
  : > "$JOURNAL_FILE"
  : > "$HERD_JOURNAL_AUDIT_INBOX"
  rm -f "$HERD_JOURNAL_AUDIT_SEEN"
  rm -f "$HERD_APPROVALS_FILE" "$PROBES"
  rm -f "$BODIES"/*.md "$BODIES"/*.fail 2>/dev/null || true
}
# approve <pr> <sha> — drive the REAL herd-approve.sh: it writes the sha-keyed ledger row AND journals
# the durable `approval_recorded` event. Hand-writing the row instead would encode a ledger state that
# cannot exist at audit time, since the merge purges it (see purge_merged_pr below).
approve() {
  printf '%s awaiting %s %s\n' "$(date +%s)" "$1" "$2" >> "$HERD_APPROVALS_FILE"
  bash "$REPO/scripts/herd/herd-approve.sh" approve "$1" >/dev/null 2>&1 \
    || fail "herd-approve.sh approve $1 failed"
}
# purge_merged_pr <pr> — drive the REAL purge_pr_approvals do_merge runs nine lines after journaling a
# merge (agent-watch.sh, HERD-90). It drops EVERY ledger row for the PR — awaiting, approved and
# hv-informed alike — so any post-merge assertion below sees exactly what the auditor sees in production.
purge_merged_pr() {
  AGENT_WATCH_LIB=1 bash -c '. "$1"; purge_pr_approvals "$2"' _ "$REPO/scripts/herd/agent-watch.sh" "$1" \
    || fail "purge_pr_approvals $1 failed"
}
# hv_informed <pr> <sha> — the two records HUMAN_VERIFY_POLICY=auto leaves behind: the ledger row
# (record_hv_informed) and the journal event (agent-watch.sh journals it right after).
hv_informed() {
  printf '%s hv-informed %s %s\n' "$(date +%s)" "$1" "$2" >> "$HERD_APPROVALS_FILE"
  jline "2026-07-09T11:59:00Z" "\"event\":\"human_verify_policy\",\"pr\":$1,\"sha\":\"$2\",\"slug\":\"hv-$1\",\"policy\":\"auto\",\"action\":\"merged-with-declared-steps\""
}
# hv_body <pr> — give <pr> a body declaring one HUMAN-VERIFY step.
hv_body() { printf 'Some PR body.\n\nHUMAN-VERIFY:\n- reload the control room and confirm the panes refresh\n' > "$BODIES/$1.md"; }
probe_count() { [ -s "$PROBES" ] || { echo 0; return; }; wc -l < "$PROBES" | tr -cd '0-9'; }
# approval_state_of <pr> <sha> — the shared reader, driven exactly as journal-audit.sh drives it.
approval_state_of() { ( . "$REPO/scripts/herd/approvals.sh"; approval_state "$1" "$2" ); }
# jline <iso-ts> <json-object-without-ts> — append one JSONL event with the given ts.
# Arg2 is a python-literal dict body (without braces), e.g. '"event":"merge","pr":1,"slug":"x"'
jline() {
  local ts="$1" body="$2"
  python3 -c '
import json, sys
ts, body = sys.argv[1], sys.argv[2]
# body is a JSON object fragment: we wrap it
o = json.loads("{" + body + "}")
o["ts"] = ts
print(json.dumps(o, separators=(",", ":"), ensure_ascii=False))
' "$ts" "$body" >> "$JOURNAL_FILE"
}
run_audit() {
  JOURNAL_AUDIT="${1:-on}" bash "$SCRIPT" 2>&1
}
# Count journal_audit events of a given kind (or all if kind empty).
count_audit() {
  local kind="${1:-}"
  python3 -c '
import json, sys
kind = sys.argv[1]
n = 0
try:
    with open(sys.argv[2]) as f:
        for line in f:
            line = line.strip()
            if not line: continue
            try: o = json.loads(line)
            except Exception: continue
            if o.get("event") != "journal_audit": continue
            if kind and o.get("kind") != kind: continue
            n += 1
except OSError:
    pass
print(n)
' "$kind" "$JOURNAL_FILE"
}
# Count inbox rows whose source column is "audit".
count_inbox() {
  [ -s "$HERD_JOURNAL_AUDIT_INBOX" ] || { echo 0; return; }
  awk -F'\t' '$2=="audit"{n++} END{print n+0}' "$HERD_JOURNAL_AUDIT_INBOX"
}
# Drop only journal_audit lines from JOURNAL_FILE (keep the synthetic substrate for re-runs).
strip_audit_events() {
  python3 -c '
import json, sys
path = sys.argv[1]
keep = []
with open(path) as f:
    for line in f:
        line = line.rstrip("\n")
        if not line.strip():
            continue
        try: o = json.loads(line)
        except Exception:
            keep.append(line); continue
        if o.get("event") == "journal_audit":
            continue
        keep.append(line)
with open(path, "w") as f:
    f.write("\n".join(keep) + ("\n" if keep else ""))
' "$JOURNAL_FILE"
}

# ── (1) SHIP-DORMANT: off → no writes even on a dirty journal ────────────────
reset_surfaces
jline "2026-07-09T12:00:00Z" '"event":"merge","pr":10,"slug":"orphan-slug","sha":"aaa"'
out="$(run_audit off)" || fail "(1) off mode exited non-zero: $out"
[ "$(count_audit)" = "0" ] || fail "(1) off must emit zero journal_audit events"
[ "$(count_inbox)" = "0" ] || fail "(1) off must write zero inbox rows"
[ -z "$out" ] || fail "(1) off must be silent on stdout, got: [$out]"
pass
echo "PASS (1) ship-dormant: JOURNAL_AUDIT=off is byte-inert"

# ── (2a) merge without reap ──────────────────────────────────────────────────
reset_surfaces
jline "2026-07-09T12:00:00Z" '"event":"merge","pr":42,"slug":"feat-x","sha":"deadbeef"'
# no reap follows; merge is > MERGE_GRACE old relative to pinned now
out="$(run_audit on)" || fail "(2a) audit exited non-zero: $out"
[ "$(count_audit merge_without_reap)" = "1" ] || fail "(2a) expected exactly 1 merge_without_reap, got $(count_audit merge_without_reap); journal=$(cat "$JOURNAL_FILE")"
[ "$(count_inbox)" = "1" ] || fail "(2a) expected 1 inbox row, got $(count_inbox)"
grep -q '"component":"audit"' "$JOURNAL_FILE" || fail "(2a) journal_audit must carry component=audit"
pass
echo "PASS (2a) merge without reap → journal_audit + inbox"

# ── (2b) *_dispatched with no terminal past TTL ─────────────────────────────
reset_surfaces
jline "2026-07-09T12:00:00Z" '"event":"review_dispatched","pr":7,"sha":"abc123","pid":99,"model":"opus"'
# no verdict_recorded; age >> DISPATCH_TTL
out="$(run_audit on)" || fail "(2b) audit exited non-zero: $out"
[ "$(count_audit dispatch_no_outcome)" = "1" ] || fail "(2b) expected 1 dispatch_no_outcome, got $(count_audit dispatch_no_outcome); $(cat "$JOURNAL_FILE")"
pass
echo "PASS (2b) review_dispatched with no terminal → finding"

# ── (2c) refix_bounce without refix_wake_result ──────────────────────────────
reset_surfaces
jline "2026-07-09T12:00:00Z" '"event":"refix_bounce","pr":8,"sha":"bbb","slug":"s","round":1'
out="$(run_audit on)" || fail "(2c) audit exited non-zero: $out"
[ "$(count_audit refix_bounce_no_wake)" = "1" ] || fail "(2c) expected 1 refix_bounce_no_wake, got $(count_audit refix_bounce_no_wake)"
pass
echo "PASS (2c) refix_bounce with no wake_result → finding"

# ── (2d) red state older than TTL ────────────────────────────────────────────
reset_surfaces
jline "2026-07-09T12:00:00Z" '"event":"main_health","pr":1,"sha":"mainsha","result":"red","failed":"test-foo.sh","since":"12:00"'
out="$(run_audit on)" || fail "(2d) audit exited non-zero: $out"
[ "$(count_audit red_state_stale)" = "1" ] || fail "(2d) expected 1 red_state_stale, got $(count_audit red_state_stale)"
pass
echo "PASS (2d) MAIN RED older than TTL → finding"

# ── (2e) pushed=no never followed by pushed=yes ──────────────────────────────
reset_surfaces
jline "2026-07-09T12:00:00Z" '"event":"symbol_index_refresh","pr":0,"result":"committed","pushed":"no"'
out="$(run_audit on)" || fail "(2e) audit exited non-zero: $out"
[ "$(count_audit pushed_no_unresolved)" = "1" ] || fail "(2e) expected 1 pushed_no_unresolved, got $(count_audit pushed_no_unresolved)"
pass
echo "PASS (2e) pushed=no without later yes → finding"

# ── (2f) known-fixture slug ──────────────────────────────────────────────────
reset_surfaces
jline "2026-07-09T15:00:00Z" '"event":"reap","pr":77,"slug":"retiree","sha":"fff","reason":"merged"'
out="$(run_audit on)" || fail "(2f) audit exited non-zero: $out"
[ "$(count_audit fixture_slug)" = "1" ] || fail "(2f) expected 1 fixture_slug, got $(count_audit fixture_slug); $(cat "$JOURNAL_FILE")"
pass
echo "PASS (2f) known-fixture slug → finding"

# ── (2g) ALL six violations in one synthetic journal → exactly those six ─────
reset_surfaces
jline "2026-07-09T12:00:00Z" '"event":"merge","pr":100,"slug":"lonely","sha":"m1"'
jline "2026-07-09T12:05:00Z" '"event":"review_dispatched","pr":101,"sha":"d1","pid":1'
jline "2026-07-09T12:10:00Z" '"event":"refix_bounce","pr":102,"sha":"r1","slug":"rb","round":2'
jline "2026-07-09T12:15:00Z" '"event":"main_health","pr":1,"sha":"red1","result":"red","failed":"x"'
jline "2026-07-09T12:20:00Z" '"event":"codemap_refresh","pr":0,"result":"committed","pushed":"no"'
jline "2026-07-09T12:25:00Z" '"event":"retire_converged","pr":18,"slug":"conv"'
out="$(run_audit on)" || fail "(2g) audit exited non-zero: $out"
[ "$(count_audit)" = "6" ] || fail "(2g) expected exactly 6 journal_audit findings, got $(count_audit); $(grep journal_audit "$JOURNAL_FILE" || true)"
for k in merge_without_reap dispatch_no_outcome refix_bounce_no_wake red_state_stale pushed_no_unresolved fixture_slug; do
  [ "$(count_audit "$k")" = "1" ] || fail "(2g) expected exactly 1 $k, got $(count_audit "$k")"
done
[ "$(count_inbox)" = "6" ] || fail "(2g) expected 6 inbox rows, got $(count_inbox)"
pass
echo "PASS (2g) full dirty journal → exactly the six finding kinds"

# ── (3) CLEAN journal emits none ─────────────────────────────────────────────
reset_surfaces
# merge + matching reap
jline "2026-07-09T12:00:00Z" '"event":"merge","pr":50,"slug":"ok-slug","sha":"s1"'
jline "2026-07-09T12:01:00Z" '"event":"reap","pr":50,"slug":"ok-slug","sha":"s1","reason":"merged"'
# review_dispatched + verdict
jline "2026-07-09T12:10:00Z" '"event":"review_dispatched","pr":51,"sha":"s2","pid":2'
jline "2026-07-09T12:20:00Z" '"event":"verdict_recorded","pr":51,"sha":"s2","value":"PASS","source":"reviewer"'
# refix_bounce + wake
jline "2026-07-09T12:30:00Z" '"event":"refix_bounce","pr":52,"sha":"s3","slug":"ok","round":1'
jline "2026-07-09T12:31:00Z" '"event":"refix_wake_result","pr":52,"sha":"s3","slug":"ok","round":1,"woke":1'
# red then green
jline "2026-07-09T12:40:00Z" '"event":"main_health","pr":1,"sha":"old","result":"red","failed":"t"'
jline "2026-07-09T13:00:00Z" '"event":"main_health","pr":2,"sha":"new","result":"green"'
# pushed=no then pushed=yes
jline "2026-07-09T13:10:00Z" '"event":"symbol_index_refresh","result":"committed","pushed":"no"'
jline "2026-07-09T13:15:00Z" '"event":"symbol_index_refresh","result":"committed","pushed":"yes"'
# real (non-fixture) slug only
jline "2026-07-09T14:00:00Z" '"event":"reap","pr":60,"slug":"real-feature","sha":"zz","reason":"merged"'
out="$(run_audit on)" || fail "(3) clean audit exited non-zero: $out"
[ "$(count_audit)" = "0" ] || fail "(3) clean journal must emit ZERO journal_audit, got $(count_audit); $(cat "$JOURNAL_FILE")"
[ "$(count_inbox)" = "0" ] || fail "(3) clean journal must write ZERO inbox rows, got $(count_inbox)"
[ -z "$out" ] || fail "(3) clean journal must be silent, got: [$out]"
pass
echo "PASS (3) clean journal → zero findings, silent"

# ── (4) IDEMPOTENT: second run does not re-flood ─────────────────────────────
reset_surfaces
jline "2026-07-09T12:00:00Z" '"event":"merge","pr":70,"slug":"once","sha":"o1"'
out1="$(run_audit on)" || fail "(4) first run non-zero: $out1"
n1="$(count_audit)"
[ "$n1" = "1" ] || fail "(4) first run should emit 1, got $n1"
# Keep the substrate; strip only prior journal_audit so we can re-count cleanly? Actually the
# seen-ledger is what prevents re-emit — leave journal_audit lines in place and assert count stays 1.
out2="$(run_audit on)" || fail "(4) second run non-zero: $out2"
n2="$(count_audit)"
[ "$n2" = "1" ] || fail "(4) second run must NOT re-emit (still 1 event), got $n2"
[ "$(count_inbox)" = "1" ] || fail "(4) second run must not add inbox rows, got $(count_inbox)"
pass
echo "PASS (4) idempotent via seen-ledger"

# ── (5) FAIL-SOFT: empty / missing journal ───────────────────────────────────
reset_surfaces
: > "$JOURNAL_FILE"   # empty
out="$(run_audit on)" || fail "(5a) empty journal must exit 0: $out"
[ -z "$out" ] || fail "(5a) empty journal must be silent"
[ "$(count_audit)" = "0" ] || fail "(5a) empty journal must not invent findings"
rm -f "$JOURNAL_FILE"
out="$(run_audit on)" || fail "(5b) missing journal must exit 0: $out"
[ -z "$out" ] || fail "(5b) missing journal must be silent"
pass
echo "PASS (5) fail-soft on empty/missing journal"

# ── (6) recent (in-grace) violations are NOT flagged yet ─────────────────────
reset_surfaces
# merge only 30s before "now" — inside MERGE_GRACE=60
jline "2026-07-09T15:59:30Z" '"event":"merge","pr":80,"slug":"fresh","sha":"f1"'
# dispatch only 2 min ago — inside DISPATCH_TTL=600
jline "2026-07-09T15:58:00Z" '"event":"review_dispatched","pr":81,"sha":"f2","pid":3'
out="$(run_audit on)" || fail "(6) audit exited non-zero: $out"
[ "$(count_audit)" = "0" ] || fail "(6) in-grace events must not be findings yet, got $(count_audit)"
pass
echo "PASS (6) in-grace / under-TTL events are not findings"

# ── (7) HERD-272: merged PR + HUMAN-VERIFY block must carry a sha-keyed approval ─────────────
# Every case below pairs a `merge` journal event with a matching reap, so the ONLY finding a case can
# produce is the human-verify one — the counts are unambiguous.
merged_pr() {   # merged_pr <pr> <sha> — a merge and its reap, both well past MERGE_GRACE
  jline "2026-07-09T12:00:00Z" "\"event\":\"merge\",\"pr\":$1,\"slug\":\"hv-$1\",\"sha\":\"$2\""
  jline "2026-07-09T12:01:00Z" "\"event\":\"reap\",\"pr\":$1,\"slug\":\"hv-$1\",\"sha\":\"$2\",\"reason\":\"merged\""
}

# (7a) merged + HUMAN-VERIFY + sha-keyed approval → clean, EVEN THOUGH the merge purged the ledger.
# This is the case a ledger-only auditor gets wrong: purge_pr_approvals wipes the approved row, so the
# only surviving evidence is the journal event herd-approve.sh writes.
reset_surfaces
merged_pr 200 "cafe1234"
hv_body 200
approve 200 "cafe1234"
purge_merged_pr 200
[ ! -s "$HERD_APPROVALS_FILE" ] || fail "(7a) fixture bug: the real purge left rows behind: $(cat "$HERD_APPROVALS_FILE")"
[ "$(approval_state_of 200 cafe1234)" = "none" ] || fail "(7a) fixture bug: the purged ledger must read 'none'"
out="$(run_audit on)" || fail "(7a) audit exited non-zero: $out"
[ "$(count_audit)" = "0" ] || fail "(7a) an approved human-verify merge must be clean, got $(count_audit): $(grep journal_audit "$JOURNAL_FILE" || true)"
[ -z "$out" ] || fail "(7a) approved human-verify merge must be silent, got: [$out]"
pass
echo "PASS (7a) merged + HUMAN-VERIFY + approval → no finding"

# (7b) merged + HUMAN-VERIFY + NO approval record → exactly one finding (the fail-open class)
reset_surfaces
merged_pr 201 "beef5678"
hv_body 201
out="$(run_audit on)" || fail "(7b) audit exited non-zero: $out"
[ "$(count_audit merged_hv_no_approval)" = "1" ] || fail "(7b) expected 1 merged_hv_no_approval, got $(count_audit merged_hv_no_approval); $(cat "$JOURNAL_FILE")"
[ "$(count_audit)" = "1" ] || fail "(7b) expected exactly 1 finding total, got $(count_audit)"
[ "$(count_inbox)" = "1" ] || fail "(7b) expected 1 inbox row, got $(count_inbox)"
grep -q '"component":"audit"' "$JOURNAL_FILE" || fail "(7b) finding must carry component=audit"
pass
echo "PASS (7b) merged + HUMAN-VERIFY + no approval → finding"

# (7b') the approval is SHA-KEYED: an approval of a DIFFERENT commit does not clear the merged sha
reset_surfaces
merged_pr 202 "beef5678"
hv_body 202
approve 202 "0000dead"
purge_merged_pr 202
out="$(run_audit on)" || fail "(7b') audit exited non-zero: $out"
[ "$(count_audit merged_hv_no_approval)" = "1" ] || fail "(7b') an approval of another sha must not clear the merge, got $(count_audit merged_hv_no_approval)"
pass
echo "PASS (7b') approval of a different sha does not clear the merged sha"

# (7c) merged WITHOUT a HUMAN-VERIFY block → clean (no approval was ever owed)
reset_surfaces
merged_pr 203 "1234abcd"
printf 'A perfectly ordinary PR body with no manual steps.\n' > "$BODIES/203.md"
out="$(run_audit on)" || fail "(7c) audit exited non-zero: $out"
[ "$(count_audit)" = "0" ] || fail "(7c) a merge with no HUMAN-VERIFY block must be clean, got $(count_audit)"
[ -z "$out" ] || fail "(7c) must be silent, got: [$out]"
pass
echo "PASS (7c) merged without HUMAN-VERIFY → no finding"

# (7d) FAIL-SOFT: an unreadable PR body is reported as UNKNOWN, and the auditor still exits 0
reset_surfaces
merged_pr 204 "aaaabbbb"
: > "$BODIES/204.fail"
out="$(run_audit on)" || fail "(7d) an unreadable body must not crash the auditor: $out"
[ "$(count_audit merged_hv_unknown)" = "1" ] || fail "(7d) expected 1 merged_hv_unknown, got $(count_audit merged_hv_unknown)"
[ "$(count_audit merged_hv_no_approval)" = "0" ] || fail "(7d) an unreadable body must never be reported as a missing approval"
pass
echo "PASS (7d) unreadable PR body → unknown finding, auditor survives"

# (7e) an `hv-informed` record (HUMAN_VERIFY_POLICY=auto) is a record, not an approval → still a
# finding, and the posture survives the purge: the journal's human_verify_policy event carries it.
reset_surfaces
merged_pr 205 "feed0001"
hv_body 205
hv_informed 205 "feed0001"
purge_merged_pr 205
out="$(run_audit on)" || fail "(7e) audit exited non-zero: $out"
[ "$(count_audit merged_hv_no_approval)" = "1" ] || fail "(7e) hv-informed must not clear the finding, got $(count_audit merged_hv_no_approval)"
grep -q 'hv-informed only' "$JOURNAL_FILE" || fail "(7e) the summary must name the hv-informed posture"
pass
echo "PASS (7e) hv-informed only → finding that names the posture"

# (7f) a settled-clean merged PR is probed ONCE across ticks (the seen-ledger memoizes the verdict),
#      and the finding itself stays idempotent on re-run.
reset_surfaces
merged_pr 206 "0badc0de"      # clean: HUMAN-VERIFY + approval
hv_body 206
approve 206 "0badc0de"
purge_merged_pr 206
merged_pr 207 "0badf00d"      # dirty: HUMAN-VERIFY, no approval
hv_body 207
run_audit on >/dev/null || fail "(7f) first tick non-zero"
n_probe1="$(probe_count)"
[ "$n_probe1" = "2" ] || fail "(7f) first tick should probe both merged PRs once, got $n_probe1"
[ "$(count_audit merged_hv_no_approval)" = "1" ] || fail "(7f) first tick should find exactly the unapproved merge"
run_audit on >/dev/null || fail "(7f) second tick non-zero"
[ "$(probe_count)" = "3" ] || fail "(7f) second tick must re-probe ONLY the unsettled PR (expected 3 probes total, got $(probe_count))"
[ "$(count_audit merged_hv_no_approval)" = "1" ] || fail "(7f) second tick must not re-emit the finding, got $(count_audit merged_hv_no_approval)"
pass
echo "PASS (7f) clean merged PRs are probed once; the finding stays idempotent"

# (7g) SHIP-DORMANT still holds for check (g): off touches neither the PR body nor the ledger
reset_surfaces
merged_pr 208 "deadbeef"
hv_body 208
out="$(run_audit off)" || fail "(7g) off mode exited non-zero: $out"
[ "$(probe_count)" = "0" ] || fail "(7g) JOURNAL_AUDIT=off must never fetch a PR body, got $(probe_count) probes"
[ "$(count_audit)" = "0" ] || fail "(7g) off must emit zero findings"
pass
echo "PASS (7g) JOURNAL_AUDIT=off never probes a PR body"

# (7h) evidence is the UNION: a live LEDGER row still clears the merge when the journal has no
#      approval event (a purge that failed, or a merge journaled without one).
reset_surfaces
merged_pr 209 "c0ffee11"
hv_body 209
printf '%s approved 209 c0ffee11\n' "$(date +%s)" > "$HERD_APPROVALS_FILE"   # row only, no journal event
out="$(run_audit on)" || fail "(7h) audit exited non-zero: $out"
[ "$(count_audit)" = "0" ] || fail "(7h) a surviving ledger approval must clear the merge, got $(count_audit)"
pass
echo "PASS (7h) a surviving ledger row still clears the merge (evidence is the union)"

# ── (8) approvals.sh — the shared reader, exercised directly ──────────────────────────────────
# conformance.tsv maps approvals.sh to this file, so its matcher gets its own asserts rather than
# riding on check (g)'s happy path.
reset_surfaces
st() { approval_state_of "$@"; }
[ "$(st 300 abc)" = "none" ] || fail "(8) a MISSING ledger must fold to none"
: > "$HERD_APPROVALS_FILE"
[ "$(st 300 abc)" = "none" ] || fail "(8) an EMPTY ledger must fold to none"
printf '1 awaiting 300 abcdef1234\n' >> "$HERD_APPROVALS_FILE"
[ "$(st 300 abcdef1234)" = "none" ] || fail "(8) an awaiting row is not an approval"
printf '2 approved 300 abcdef1234\n' >> "$HERD_APPROVALS_FILE"
[ "$(st 300 abcdef1234)" = "approved" ] || fail "(8) exact sha must match"
[ "$(st 300 abcdef)"     = "approved" ] || fail "(8) a SHORT query sha must prefix-match the full oid"
[ "$(st 300 "")"         = "approved" ] || fail "(8) an EMPTY query sha must match any row for the PR"
[ "$(st 300 abcdef9999)" = "none" ]     || fail "(8) a diverging sha must NOT match"
[ "$(st 301 abcdef1234)" = "none" ]     || fail "(8) another PR's row must never match"
[ "$(st 30 abcdef1234)"  = "none" ]     || fail "(8) a PR number that is a prefix of another must not match"
: > "$HERD_APPROVALS_FILE"
printf '1 approved 302 abcdef\n' >> "$HERD_APPROVALS_FILE"   # ledger holds the SHORT sha
[ "$(st 302 abcdef1234)" = "approved" ] || fail "(8) prefix matching must work in the other direction"
: > "$HERD_APPROVALS_FILE"
printf '1 hv-informed 303 aaa\n2 approved 303 aaa\n' >> "$HERD_APPROVALS_FILE"
[ "$(st 303 aaa)" = "approved" ] || fail "(8) approved must outrank hv-informed regardless of row order"
: > "$HERD_APPROVALS_FILE"
printf '1 hv-informed 304 aaa\n' >> "$HERD_APPROVALS_FILE"
[ "$(st 304 aaa)" = "hv-informed" ] || fail "(8) an hv-informed row must report as hv-informed, not approved"
pass
echo "PASS (8) approvals.sh: sha-prefix matching, state precedence, fail-soft on a missing ledger"

echo "ALL PASS ($PASS checks) — journal-audit self-audit (HERD-238 + HERD-272 human-verify rule)."
