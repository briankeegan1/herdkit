#!/usr/bin/env bash
# test-hermetic-env-scrub.sh — hermetic tests for the HERD-458 hermetic-env scrub
# (scripts/herd/hermetic-env-scrub.sh): the harness-side fix for a CONFIGURED project's
# herd-config.sh-exported values (MERGE_POLICY, HEALTH_CONCURRENCY, MAIN_HEALTH_TICK, …) leaking past
# the harness process into a hermetic test that asserts the shell DEFAULT.
#
# Proves:
#   (1) The REAL tree's derived key set matches herd-config.sh's actual export surface (spot-checked
#       members from every export block, both single-line and continuation-joined).
#   (2) MUTATION-PROVE (add): a new `export`ed name added to a temp copy of herd-config.sh appears in
#       the derived set with NO edit to this test or the library — proves it is DERIVED, never a
#       hand-maintained list that could drift.
#   (3) MUTATION-PROVE (drop): removing ONE name from a multi-name export line drops ONLY that name
#       from the derived set — the sibling on the same line is untouched.
#   (4) FALSE-POSITIVE GUARD: a comment merely using the English word "export" (this file's prose does
#       it constantly — "must be exported", "a bare `export KEY` is a no-op") never contributes a
#       bogus key — only a REAL export statement in command position counts.
#   (5) A guarded conditional export (`cond && export NAME`) is still recognized.
#   (6) herd_hermetic_env_scrub actually UNSETS an exported key in the current shell — not just
#       reports it.
#   (7) END-TO-END regression proof: with HEALTH_CONCURRENCY exported ambient (simulating a CONFIGURED
#       project, exactly HERD-458's reproduction), the scrub against the REAL herd-config.sh clears it.
#   (8) FAIL-SOFT: a missing herd-config.sh path is a silent no-op (empty set, exit 0), never a crash.
#
# Network-free: temp dirs + fixtures only. Run:  bash tests/test-hermetic-env-scrub.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LIB="$ROOT/scripts/herd/hermetic-env-scrub.sh"

[ -f "$LIB" ] || { echo "FAIL: missing lib: $LIB" >&2; exit 1; }
# shellcheck source=/dev/null
. "$LIB"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { PASS=$((PASS+1)); }

# ── 1. Real tree: spot-check known members from every export shape in herd-config.sh ────────────────
real_out="$(herd_hermetic_scrub_keys "$ROOT/scripts/herd/herd-config.sh")"
for k in HEALTH_CONCURRENCY REVIEW_CONCURRENCY MERGE_POLICY WATCHER_AUTOMERGE HUMAN_VERIFY_POLICY \
         MAIN_HEALTH_TICK MODEL_REVIEW WORKTREES_DIR PROJECT_ROOT STORE_BACKEND \
         REFIX_COMPLETE_MIN WORK_UNIT_KIND MERGE_RESULT_GATE MERGE_QUEUE GATE_STATUS MERGE_FAIRNESS \
         DELETE_BRANCH_ON_MERGE WATCHER_SCOPE WATCHER_VIEW_DEPS_LABEL WATCHER_OWNER \
         INFRA_BREAKER_MAX INFRA_BREAKER_COOLDOWN; do
  grep -qxF "$k" <<< "$real_out" || fail "(1) expected '$k' in the derived export set (got: $(printf '%s' "$real_out" | tr '\n' ' '))"
done
pass
echo "PASS (1) real tree: derived key set covers every known export shape (plain, multi-name, continuation)"

# make_cfg <dir> — a minimal herd-config.sh-shaped fixture (never sourced by the lib — pure text scan)
make_cfg() {
  cat > "$1" <<'CFGEOF'
#!/usr/bin/env bash
# a bare `export KEY` on an unset var is a no-op — this comment MUST NOT be read as a real export
: "${HEALTH_CONCURRENCY:="1"}"
: "${REVIEW_CONCURRENCY:="1"}"
export HEALTH_CONCURRENCY REVIEW_CONCURRENCY   # the two keys THIS item's bug report named
export MERGE_POLICY WATCHER_AUTOMERGE HUMAN_VERIFY_POLICY \
       REFIX_COMPLETE_MIN WORK_UNIT_KIND
: "${ANTHROPIC_BASE_URL:=}"
[ -n "${ANTHROPIC_BASE_URL}" ] && export ANTHROPIC_BASE_URL
CFGEOF
}

# ── 2. Mutation-prove (add): a brand-new export appears with zero edits here ────────────────────────
TA="$T/added.sh"; make_cfg "$TA"
printf '\nexport HERD_458_TOTALLY_NEW_TEST_KEY\n' >> "$TA"
out="$(herd_hermetic_scrub_keys "$TA")"
grep -qxF "HERD_458_TOTALLY_NEW_TEST_KEY" <<< "$out" \
  || fail "(2) a newly export'ed name must appear in the derived set (got: $(printf '%s' "$out" | tr '\n' ' '))"
pass
echo "PASS (2) mutation-prove (add): a new export line is picked up with no hand-maintained list to edit"

# ── 3. Mutation-prove (drop): removing one name from a multi-name line drops only that name ─────────
TD="$T/dropped.sh"; make_cfg "$TD"
sed -i.bak 's/^export HEALTH_CONCURRENCY REVIEW_CONCURRENCY.*/export REVIEW_CONCURRENCY/' "$TD"
rm -f "$TD.bak"
out="$(herd_hermetic_scrub_keys "$TD")"
grep -qxF "HEALTH_CONCURRENCY" <<< "$out" && fail "(3) HEALTH_CONCURRENCY still derived after its export was dropped (got: $(printf '%s' "$out" | tr '\n' ' '))"
grep -qxF "REVIEW_CONCURRENCY" <<< "$out" || fail "(3) sibling REVIEW_CONCURRENCY should still be derived (got: $(printf '%s' "$out" | tr '\n' ' '))"
pass
echo "PASS (3) mutation-prove (drop): removing one name from a shared export line drops only that name"

# ── 4. False-positive guard: prose using the word "export" never contributes a bogus key ────────────
TC="$T/comment-only.sh"
cat > "$TC" <<'CFGEOF'
#!/usr/bin/env bash
# Exported so child processes inherit it. must be exported. a bare export FOO on an unset var is a no-op.
# — a fake "export BAR" mid-comment must never be read as code.
: "${QUUX:="1"}"
export QUUX
CFGEOF
out="$(herd_hermetic_scrub_keys "$TC")"
[ "$out" = "QUUX" ] || fail "(4) comment prose mentioning 'export' leaked a bogus key (got: $(printf '%s' "$out" | tr '\n' ' '))"
pass
echo "PASS (4) prose mentioning 'export' (this file does it constantly) never contributes a bogus key"

# ── 5. Guarded conditional export is recognized ──────────────────────────────────────────────────────
TG="$T/guarded.sh"; make_cfg "$TG"
out="$(herd_hermetic_scrub_keys "$TG")"
grep -qxF "ANTHROPIC_BASE_URL" <<< "$out" || fail "(5) a guarded 'cond && export NAME' must still be recognized (got: $(printf '%s' "$out" | tr '\n' ' '))"
pass
echo "PASS (5) a guarded conditional export ('cond && export NAME') is recognized"

# ── 6. herd_hermetic_env_scrub actually UNSETS, not just reports ────────────────────────────────────
TS="$T/scrub-live.sh"
printf 'export HERD_458_LIVE_UNSET_TEST\n' > "$TS"
export HERD_458_LIVE_UNSET_TEST="leaked-value"
[ "${HERD_458_LIVE_UNSET_TEST+set}" = "set" ] || fail "(6) test setup broken — the var should be set before the scrub runs"
herd_hermetic_env_scrub "$TS"
[ "${HERD_458_LIVE_UNSET_TEST+set}" != "set" ] || fail "(6) herd_hermetic_env_scrub must UNSET the key, not merely report it (still set to '${HERD_458_LIVE_UNSET_TEST:-}')"
pass
echo "PASS (6) herd_hermetic_env_scrub unsets a live-exported key in the current shell"

# ── 7. END-TO-END regression proof — the exact HERD-458 reproduction shape ──────────────────────────
(
  export HEALTH_CONCURRENCY="2"   # simulates this repo's CONFIGURED .herd/config value
  # shellcheck source=/dev/null
  . "$LIB"
  herd_hermetic_env_scrub "$ROOT/scripts/herd/herd-config.sh"
  [ "${HEALTH_CONCURRENCY+set}" != "set" ] \
    || { echo "FAIL: (7) HEALTH_CONCURRENCY still leaked past the scrub against the REAL herd-config.sh" >&2; exit 1; }
) || exit 1
pass
echo "PASS (7) end-to-end: a CONFIGURED HEALTH_CONCURRENCY is cleared by the scrub against the real herd-config.sh"

# ── 8. Fail-soft: a missing herd-config.sh path is a silent no-op ───────────────────────────────────
out="$(herd_hermetic_scrub_keys "$T/does-not-exist.sh")"; rc=$?
[ "$rc" -eq 0 ] || fail "(8) a missing config path must exit 0, not error (got rc=$rc)"
[ -z "$out" ] || fail "(8) a missing config path must derive an empty set (got: $out)"
pass
echo "PASS (8) a missing herd-config.sh path is a silent no-op — never a crash, never a false key"

echo
echo "ALL PASS ($PASS checks) — the hermetic-env scrub is derived from herd-config.sh's own export surface, mutation-proven both ways."
