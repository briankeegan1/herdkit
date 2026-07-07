#!/usr/bin/env bash
# test-sandbox-real-remote.sh — hermetic proof of the P2c OPT-IN REAL-REMOTE simulation
# (scripts/herd/sim/sandbox-real-remote-scenario.sh), which — ONLY when SANDBOX_REAL_REMOTE=1 and a
# real authenticated gh is present — provisions a DISPOSABLE private GitHub repo, pushes the fixture,
# and runs `gh pr create` / the watcher's PR polling / `gh pr merge` for REAL, then guarantees the
# repo is deleted on teardown (incl. failure paths).
#
# THE TEST WRAPPER IS GUARDED so the hermetic CI suite NEVER exercises the real tier:
#   (A) DEFAULT (env unset) — byte-identical hermetic STUB path: the self-contained gh stub records
#       create/merge, no repo/network is touched; result "pass", remote "stub".
#   (B) REAL-REQUESTED-BUT-UNAVAILABLE — with SANDBOX_REAL_REMOTE=1 but an UNAUTHENTICATED gh on PATH,
#       the scenario must degrade to a clean SKIP (result "skip", exit 0) and MUST NOT attempt a
#       `gh repo create` (proven by a canary file that stays empty). This is the guard that makes it
#       impossible for CI (or a fat-fingered wrapper) to reach GitHub without real auth.
#   (C) SCORECARD SHAPE — the sandbox-sim fields plus the real-remote fields (remote, real_remote_ran,
#       repo_slug, repo_created, repo_deleted, pr_number, pr_merged).
#   (D) SWEEP HELPER — `--sweep` is a clean no-op without an authenticated gh (never networks here).
#   (E) HERMETIC — neither path leaves a new entry in the real repo tree.
#
# Fully hermetic: local git only, NO real gh, NO network, NO model. This test NEVER sets
# SANDBOX_REAL_REMOTE=1 against a real gh — the live-remote run is a HUMAN-VERIFY step on the PR.
# Run:  bash tests/test-sandbox-real-remote.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCENARIO="$HERE/../scripts/herd/sim/sandbox-real-remote-scenario.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail(){ echo "FAIL: $1" >&2; exit 1; }
command -v git     >/dev/null 2>&1 || fail "git required"
command -v python3 >/dev/null 2>&1 || fail "python3 required"
[ -f "$SCENARIO" ] || fail "missing $SCENARIO"

# Baseline of the real repo's working-tree status BEFORE any scenario runs, so (E) can prove the
# scenario adds NOTHING of its own to the real tree.
REPO_ROOT="$(cd "$HERE/.." && pwd)"
BASELINE_STATUS="$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null | sort || true)"

# jq-free scorecard readers.
sc() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$1" "$2"; }
cp_status() {
  python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
for c in d["checkpoints"]:
    if c["name"]==sys.argv[2]: print(c["status"]); break
' "$1" "$2"
}
cp_count_status() {
  python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
print(sum(1 for c in d["checkpoints"] if c["status"]==sys.argv[2]))
' "$1" "$2"
}

# ── (A) DEFAULT STUB PATH — env unset: byte-identical hermetic behavior, everything passes ────────
ARTS="$T/stub"
bash "$SCENARIO" --artifacts "$ARTS" >"$T/stub.out" 2>&1 \
  || fail "(A) stub path exited non-zero (must exit 0)"$'\n'"$(cat "$T/stub.out")"
SCS="$ARTS/scorecard.json"
[ -f "$SCS" ] || fail "(A) scorecard.json not emitted at $SCS"
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$SCS" || fail "(A) stub scorecard not valid JSON"
[ "$(sc "$SCS" scenario)" = "stub-real-remote-e2e" ] || fail "(A) unexpected scenario name"
[ "$(sc "$SCS" result)" = "pass" ]                   || fail "(A) result should be pass (got $(sc "$SCS" result))"
[ "$(sc "$SCS" failed)" -eq 0 ]                      || fail "(A) stub path must have 0 failures"
[ "$(sc "$SCS" remote)" = "stub" ]                   || fail "(A) remote should be stub (got $(sc "$SCS" remote))"
[ "$(sc "$SCS" real_remote_ran)" = "False" ]         || fail "(A) real_remote_ran must be False in stub mode"
[ "$(sc "$SCS" repo_created)" = "False" ]            || fail "(A) stub mode must not create a repo"
for cpn in fixture_built builder_committed remote_provisioned pr_created pr_polled gate_passed pr_merged teardown_clean; do
  [ "$(cp_status "$SCS" "$cpn")" = "pass" ] || fail "(A) checkpoint $cpn not pass (got $(cp_status "$SCS" "$cpn"))"
done
# The stub gh log must show NO `repo create` (the hermeticity contract).
[ -f "$ARTS/gh-calls.log" ] || fail "(A) expected stub gh-calls.log"
grep -qE '^repo create' "$ARTS/gh-calls.log" && fail "(A) stub tier issued a 'repo create' — NOT hermetic"
grep -qE '^pr create'   "$ARTS/gh-calls.log" || fail "(A) stub tier should have issued 'pr create'"
echo "PASS (A) default stub path: full flow, remote=stub, no repo create, 0 fails"

# ── (B) REAL-REQUESTED-BUT-UNAVAILABLE — the guard that keeps CI off the real tier ────────────────
# A fake gh whose `auth status` FAILS and which records ANY `repo create` to a canary. Even though we
# set SANDBOX_REAL_REMOTE=1, the scenario must SKIP cleanly and NEVER attempt to create a repo.
BIN="$T/bin"; mkdir -p "$BIN"
CANARY="$T/repo-create-canary.log"; : > "$CANARY"
cat > "$BIN/gh" <<EOF
#!/usr/bin/env bash
case "\$1 \$2" in
  "auth status") exit 1 ;;                        # unauthenticated → the scenario must skip
  "repo create") printf '%s\n' "\$*" >> "$CANARY"; exit 0 ;;   # canary: MUST never be hit
esac
exit 0
EOF
chmod +x "$BIN/gh"
ARTB="$T/skip"
PATH="$BIN:$PATH" SANDBOX_REAL_REMOTE=1 \
  bash "$SCENARIO" --artifacts "$ARTB" >"$T/skip.out" 2>&1 \
  || fail "(B) real-requested-but-unauth path exited non-zero (must exit 0 / clean skip)"$'\n'"$(cat "$T/skip.out")"
SCB="$ARTB/scorecard.json"
[ -f "$SCB" ] || fail "(B) scorecard.json not emitted at $SCB"
[ "$(sc "$SCB" result)" = "skip" ]           || fail "(B) result should be skip (got $(sc "$SCB" result))"
[ "$(sc "$SCB" failed)" -eq 0 ]              || fail "(B) skip path must have 0 failures"
[ "$(sc "$SCB" remote)" = "real" ]           || fail "(B) remote should record the requested tier (real)"
[ "$(sc "$SCB" real_remote_ran)" = "False" ] || fail "(B) real_remote_ran must be False when skipped"
[ "$(sc "$SCB" repo_created)" = "False" ]    || fail "(B) no repo may be created on the skip path"
[ "$(cp_status "$SCB" real_remote_available)" = "skip" ] || fail "(B) real_remote_available checkpoint should be skip"
[ "$(cp_count_status "$SCB" fail)" -eq 0 ]   || fail "(B) skip path recorded a FAIL — must never false-red"
[ "$(cp_count_status "$SCB" skip)" -ge 5 ]   || fail "(B) skip path should loudly skip the real-remote checkpoints"
# THE GUARD: no `gh repo create` was ever attempted, so CI can never provision a real repo.
[ ! -s "$CANARY" ] || fail "(B) GUARD BREACH: the scenario attempted 'gh repo create' in a hermetic env:"$'\n'"$(cat "$CANARY")"
echo "PASS (B) real-requested-but-unauth → clean skip, ZERO repo-create attempts (CI guard holds)"

# ── (C) SCORECARD SHAPE — sandbox-sim fields plus the real-remote fields ─────────────────────────
for k in scenario artifacts_dir repo_dir fixture_sha result passed failed skipped \
         remote real_remote_ran repo_slug repo_created repo_deleted pr_number pr_merged checkpoints; do
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert sys.argv[2] in d' "$SCS" "$k" \
    || fail "(C) scorecard missing field: $k"
done
echo "PASS (C) scorecard shape (sandbox-sim + real-remote fields)"

# ── (D) SWEEP HELPER — a clean no-op without an authenticated gh (never networks in the suite) ───
PATH="$BIN:$PATH" bash "$SCENARIO" --sweep >"$T/sweep.out" 2>&1 \
  || fail "(D) --sweep exited non-zero"$'\n'"$(cat "$T/sweep.out")"
grep -qi 'not authenticated\|nothing to do' "$T/sweep.out" \
  || fail "(D) --sweep should be a clean no-op without auth (out: $(cat "$T/sweep.out"))"
[ ! -s "$CANARY" ] || fail "(D) --sweep must not create repos"
echo "PASS (D) --sweep clean no-op without authenticated gh"

# ── (E) HERMETIC — nothing leaked into the real repo tree by any path ────────────────────────────
NOW_STATUS="$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null | sort || true)"
NEW_ENTRIES="$(comm -13 <(printf '%s\n' "$BASELINE_STATUS") <(printf '%s\n' "$NOW_STATUS") | grep -v '^$' || true)"
[ -z "$NEW_ENTRIES" ] || fail "(E) scenario leaked into the real repo tree:"$'\n'"$NEW_ENTRIES"
echo "PASS (E) hermetic — no leak into the real repo"

echo "ALL PASS"
