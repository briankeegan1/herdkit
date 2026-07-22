#!/usr/bin/env bash
# test-cli-config.sh — hermetic tests for the `herd config list|get|set` CLI subcommand.
#
# NOTE: the SEPARATE test-herd-config.sh covers the herd-config.sh *loader* (defaults/override
# derivation). THIS file covers the `herd config` command added to bin/herd.
#
# Design (mirrors test-cli-reload.sh):
#   • pgrep is STUBBED on PATH → returns only $FAKE_STRAY_PIDS (empty here), so a watcher-key
#     set's `herd reload` path never sees a real agent-watch.sh in another workspace.
#   • herdr is STUBBED (exits 1) → forces the reload background-fallback path with no real herdr.
#   • HERD_RELOAD_SKIP_LAUNCH=1 → the reload never spawns a real watcher.
#   • HERD_CAPABILITIES_FILE points at a STUB manifest so key validation + the requires metadata
#     are hermetic and independent of the shipped templates/capabilities.tsv.
#
# Run:  bash tests/test-cli-config.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
HERD="$HERE/../bin/herd"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass=0; ok(){ pass=$((pass+1)); }

# ── Stub pgrep + herdr on PATH ───────────────────────────────────────────────
BIN="$T/bin"; mkdir -p "$BIN"
cat > "$BIN/pgrep" <<'STUB'
#!/usr/bin/env bash
IFS=':' read -ra pids <<< "${FAKE_STRAY_PIDS:-}"
for p in "${pids[@]}"; do [ -n "$p" ] && printf '%s\n' "$p"; done
exit 0
STUB
chmod +x "$BIN/pgrep"
printf '#!/usr/bin/env bash\nexit 1\n' > "$BIN/herdr"; chmod +x "$BIN/herdr"
export PATH="$BIN:$PATH"

# ── Stub capabilities manifest (HERD-159: + value_shape column) ─
# WORKSPACE_NAME/BACKLOG_FILE are tagged `watcher`: the live watcher consumes them (lockfile slug,
# reap greps, PR target), so a set must restart it — re-rendering alone would silently partial-apply.
# HERD_REPO is genuinely render-only (skill token, no watcher consumer).
# REVIEW_CONCURRENCY is numeric; MERGE_POLICY is an enum — exercise write-time value validation.
CAPS="$T/capabilities.tsv"
{
  printf 'name\tkind\tdescription\twhen_to_surface\trequires\tscope\tgovernance\tvalue_shape\n'
  printf 'WORKSPACE_NAME\tconfig\tProject label (lockfile slug + skill)\tAlways required\twatcher\t\t\tfree\n'
  printf 'BACKLOG_FILE\tconfig\tBacklog path consumed by the watcher reap step\tUsed by file backend\twatcher\t\t\tfree\n'
  printf 'REVIEW_CONCURRENCY\tconfig\tMax parallel pre-merge reviews\tRaise for throughput\twatcher\t\t\tnumeric\n'
  printf 'MERGE_POLICY\tconfig\tMerge gate policy\tPrimary merge lever\twatcher\t\tgovernance\tauto|approve|observe\n'
  printf 'HERD_REPO\tconfig\tGitHub repo engine bugs escalate to (skill token only)\tFor herd report\trender\t\t\tfree\n'
  printf 'SCRIBE_BACKEND\tconfig\tWork-tracker backend adapter\tSet for a tracker\t\t\t\tfree\n'
  printf 'DENY_PATHS\tconfig\tNever-committed paths\tFor secrets\trender\t\t\tfree\n'
  printf 'TEST_PATH_GLOB\tconfig\tStub egrep-pattern key (HERD-413)\tExercise glob charset validation\t\t\t\tglob\n'
} > "$CAPS"
export HERD_CAPABILITIES_FILE="$CAPS"

# ── _make_project ROOT ───────────────────────────────────────────────────────
_make_project() {
  local r="$1"; local r_real; r_real="$(cd "$r" && pwd -P)"
  git -C "$r" init -q
  git -C "$r" config user.email t@t.t; git -C "$r" config user.name t
  ( cd "$r" && git commit -q --allow-empty -m init )
  mkdir -p "$r/.herd" "$r/trees"
  cat > "$r/.herd/config" <<CFG
# .herd/config — test fixture (comment preserved on purpose)
HERD_VERSION=1
PROJECT_ROOT="$r_real"
WORKTREES_DIR="$r_real/trees"
DEFAULT_BRANCH="origin/main"
WORKSPACE_NAME="cfgtest"
BACKLOG_FILE="BACKLOG.md"
SCRIBE_BACKEND="file"
# secret-shaped stray line to exercise masking
GH_TOKEN="supersecret-value"
REVIEW_CONCURRENCY="2"
CFG
}

# run <ROOT> <args...> → runs `herd <args>` in ROOT, capturing combined output into $OUT and the
# exit code into $RC (never aborts the harness).
run() {
  local r="$1"; shift
  set +e
  OUT="$( cd "$r" && HERD_RELOAD_SKIP_LAUNCH=1 HERD_RELOAD_SIGTERM_POLLS=3 FAKE_STRAY_PIDS="" \
           bash "$HERD" "$@" 2>&1 )"
  RC=$?
  set -e
}

# ══ 1. list prints keys+values and masks the secret-shaped key ════════════════
P="$T/p1"; mkdir "$P"; _make_project "$P"
run "$P" config list
[ "$RC" -eq 0 ]                                   || fail "list exited $RC ($OUT)"
printf '%s\n' "$OUT" | grep -qE 'WORKSPACE_NAME[[:space:]]+cfgtest'   || fail "list missing WORKSPACE_NAME ($OUT)"
printf '%s\n' "$OUT" | grep -qE 'REVIEW_CONCURRENCY[[:space:]]+2'     || fail "list missing REVIEW_CONCURRENCY"
printf '%s\n' "$OUT" | grep -q 'supersecret-value'                   && fail "list leaked a secret value"
printf '%s\n' "$OUT" | grep -qE 'GH_TOKEN[[:space:]]+\*+'            || fail "list did not mask GH_TOKEN ($OUT)"
ok

# ══ 2. get prints one validated value; unknown key rejected ═══════════════════
run "$P" config get WORKSPACE_NAME
{ [ "$RC" -eq 0 ] && [ "$OUT" = "cfgtest" ]; }    || fail "get WORKSPACE_NAME wrong (rc=$RC out=$OUT)"
run "$P" config get NOT_A_REAL_KEY
[ "$RC" -ne 0 ]                                   || fail "get accepted an unknown key"
printf '%s\n' "$OUT" | grep -qi 'unknown config key' || fail "get unknown-key message wrong ($OUT)"
ok

# ══ 3. set roundtrip + targeted edit preserves comments/other keys ════════════
run "$P" config set WORKSPACE_NAME renamed
[ "$RC" -eq 0 ]                                   || fail "set WORKSPACE_NAME failed ($OUT)"
run "$P" config get WORKSPACE_NAME
[ "$OUT" = "renamed" ]                            || fail "set→get roundtrip failed (got '$OUT')"
grep -q '# .herd/config — test fixture' "$P/.herd/config"       || fail "set clobbered the leading comment"
grep -q '# secret-shaped stray line'  "$P/.herd/config"         || fail "set clobbered an inline comment"
grep -qE '^SCRIBE_BACKEND="file"'     "$P/.herd/config"         || fail "set clobbered an unrelated key"
grep -qE '^WORKSPACE_NAME="renamed"'  "$P/.herd/config"         || fail "set did not write the new value"
[ "$(grep -cE '^WORKSPACE_NAME=' "$P/.herd/config")" -eq 1 ]    || fail "set duplicated WORKSPACE_NAME"
ok

# ══ 4. set of a NEW (absent) key appends it ═══════════════════════════════════
run "$P" config set SCRIBE_BACKEND github
[ "$RC" -eq 0 ]                                   || fail "set SCRIBE_BACKEND failed ($OUT)"
run "$P" config get SCRIBE_BACKEND
[ "$OUT" = "github" ]                             || fail "set SCRIBE_BACKEND roundtrip failed ($OUT)"
ok

# ══ 5. idempotent no-op set (value unchanged) ═════════════════════════════════
run "$P" config set SCRIBE_BACKEND github
{ [ "$RC" -eq 0 ] && printf '%s\n' "$OUT" | grep -qi 'no change'; } || fail "repeat set not reported as no-op ($OUT)"
printf '%s\n' "$OUT" | grep -qi 'herd reload'     && fail "no-op set still triggered a restart"
ok

# ══ 6. unknown key rejected on set ════════════════════════════════════════════
run "$P" config set BOGUS_SETTING x
[ "$RC" -ne 0 ]                                   || fail "set accepted an unknown key"
printf '%s\n' "$OUT" | grep -qi 'unknown config key' || fail "set unknown-key message wrong ($OUT)"
grep -qE '^BOGUS_SETTING=' "$P/.herd/config"     && fail "rejected key still written to config"
ok

# ══ 7. safety: DENY_PATHS and secret-shaped keys are refused by set ═══════════
run "$P" config set DENY_PATHS /etc
{ [ "$RC" -ne 0 ] && printf '%s\n' "$OUT" | grep -qi 'refusing to set DENY_PATHS'; } || fail "DENY_PATHS set not refused ($OUT)"
grep -qE '^DENY_PATHS=' "$P/.herd/config"        && fail "DENY_PATHS was written despite refusal"
run "$P" config set MY_SECRET_TOKEN hunter2
{ [ "$RC" -ne 0 ] && printf '%s\n' "$OUT" | grep -qi 'secret-shaped'; } || fail "secret-shaped key set not refused ($OUT)"
ok

# ══ 8. a WATCHER key set triggers the restart path (herd reload) ══════════════
# pgrep stub returns no watcher + HERD_RELOAD_SKIP_LAUNCH=1 ⇒ the reload runs hermetically.
run "$P" config set REVIEW_CONCURRENCY 4
[ "$RC" -eq 0 ]                                   || fail "watcher-key set failed ($OUT)"
printf '%s\n' "$OUT" | grep -qi 'herd reload'     || fail "watcher-key set did NOT run the reload/restart path ($OUT)"
printf '%s\n' "$OUT" | grep -qi 'watcher restarted' || fail "watcher-key set missing the restart summary ($OUT)"
run "$P" config get REVIEW_CONCURRENCY
[ "$OUT" = "4" ]                                  || fail "watcher-key value not persisted ($OUT)"
ok

# ══ 9. a genuinely render-only key (HERD_REPO) re-renders the skill, NOT a restart ═
P2="$T/p2"; mkdir "$P2"; _make_project "$P2"
run "$P2" config set HERD_REPO owner/enginerepo
[ "$RC" -eq 0 ]                                   || fail "render-key set failed ($OUT)"
printf '%s\n' "$OUT" | grep -qi 're-rendered coordinator skill' || fail "render-key set did NOT re-render the skill ($OUT)"
printf '%s\n' "$OUT" | grep -qi 'herd reload'     && fail "render-key set wrongly triggered a watcher restart ($OUT)"
[ -f "$P2/.claude/commands/coordinator.md" ]      || fail "render-key set produced no skill file"
grep -q 'owner/enginerepo' "$P2/.claude/commands/coordinator.md" || fail "re-rendered skill missing the new value"
ok

# ══ 10. a no-op-requires key set neither restarts nor re-renders ══════════════
P3="$T/p3"; mkdir "$P3"; _make_project "$P3"
run "$P3" config set SCRIBE_BACKEND changelog
[ "$RC" -eq 0 ]                                   || fail "no-op-requires set failed ($OUT)"
printf '%s\n' "$OUT" | grep -qi 'herd reload'     && fail "no-op-requires set triggered a restart"
printf '%s\n' "$OUT" | grep -qi 're-rendered'     && fail "no-op-requires set triggered a re-render"
[ -f "$P3/.claude/commands/coordinator.md" ]      && fail "no-op-requires set unexpectedly rendered a skill"
ok

# ══ 11. a watcher-CONSUMED key (BACKLOG_FILE) restarts the watcher, not just re-render ═
# Regression guard for the partial-apply finding: BACKLOG_FILE feeds the live watcher (reap step),
# so a set must go through the restart path — re-rendering the skill alone would leave the running
# watcher on the old value.
P4="$T/p4"; mkdir "$P4"; _make_project "$P4"
run "$P4" config set BACKLOG_FILE TODO.md
[ "$RC" -eq 0 ]                                   || fail "watcher-consumed BACKLOG_FILE set failed ($OUT)"
printf '%s\n' "$OUT" | grep -qi 'herd reload'     || fail "BACKLOG_FILE set did NOT restart the watcher ($OUT)"
printf '%s\n' "$OUT" | grep -qi 'watcher restarted' || fail "BACKLOG_FILE set missing restart summary ($OUT)"
ok

# ══ 12. shell-safety: values with shell-active chars are rejected; get == shell-sourced ═
# .herd/config is sourced as shell but get reads it with awk. A value like 'a$(id)' must never be
# stored (it would execute at source time and diverge from what get reports).
P5="$T/p5"; mkdir "$P5"; _make_project "$P5"
run "$P5" config get WORKSPACE_NAME; before="$OUT"
for bad in 'a$(id)' 'x`id`' 'a$HOME' 'b\c' 'q"r'; do
  run "$P5" config set WORKSPACE_NAME "$bad"
  [ "$RC" -ne 0 ]                                 || fail "accepted shell-active value: [$bad]"
  printf '%s\n' "$OUT" | grep -qiE 'shell-active|newline|double-quote' || fail "wrong rejection message for [$bad] ($OUT)"
  grep -qF "$bad" "$P5/.herd/config"              && fail "rejected shell-active value [$bad] was written to config"
done
# a rejected set must not mutate the stored value.
run "$P5" config get WORKSPACE_NAME
[ "$OUT" = "$before" ]                            || fail "a rejected set mutated the stored value ($OUT != $before)"
# a benign value roundtrips AND get (awk) equals the shell-sourced value — no divergence, no exec.
run "$P5" config set WORKSPACE_NAME "plain-value_123"
[ "$RC" -eq 0 ]                                   || fail "benign set failed ($OUT)"
run "$P5" config get WORKSPACE_NAME; got="$OUT"
sourced="$( cd "$P5" && ( set +u +e; . ./.herd/config >/dev/null 2>&1; printf '%s' "${WORKSPACE_NAME:-}" ) )"
[ "$got" = "plain-value_123" ]                    || fail "benign roundtrip wrong ($got)"
[ "$got" = "$sourced" ]                           || fail "get ($got) != shell-sourced value ($sourced)"
ok

# ══ 13. HERD-159: write-time value_shape validation (enum + numeric) ══════════
# A typo'd MERGE_POLICY or non-numeric REVIEW_CONCURRENCY must be REFUSED before it lands in
# .herd/config — runtime fail-strict is the backstop, write-time is the front door.
P6="$T/p6"; mkdir "$P6"; _make_project "$P6"
run "$P6" config set MERGE_POLICY aprove
[ "$RC" -ne 0 ]                                   || fail "set accepted typo MERGE_POLICY=aprove"
printf '%s\n' "$OUT" | grep -qi 'invalid value'   || fail "typo MERGE_POLICY missing invalid-value message ($OUT)"
grep -qE '^MERGE_POLICY=' "$P6/.herd/config"     && fail "typo MERGE_POLICY was written despite refusal"
run "$P6" config set MERGE_POLICY observe
[ "$RC" -eq 0 ]                                   || fail "set valid MERGE_POLICY=observe failed ($OUT)"
run "$P6" config get MERGE_POLICY
[ "$OUT" = "observe" ]                            || fail "valid MERGE_POLICY not persisted ($OUT)"
run "$P6" config set REVIEW_CONCURRENCY two
[ "$RC" -ne 0 ]                                   || fail "set accepted non-numeric REVIEW_CONCURRENCY=two"
printf '%s\n' "$OUT" | grep -qi 'invalid value\|non-negative integer' \
                                                  || fail "non-numeric concurrency missing message ($OUT)"
grep -qE '^REVIEW_CONCURRENCY="two"' "$P6/.herd/config" && fail "non-numeric concurrency was written"
run "$P6" config set REVIEW_CONCURRENCY 3
[ "$RC" -eq 0 ]                                   || fail "set valid REVIEW_CONCURRENCY=3 failed ($OUT)"
ok

# ══ 14. HERD-413: value_shape=glob keys get a vetted charset (word chars + . * + ? [ ] ( ) { } | ^ $ \ / , -)
# instead of the blanket shell-active blacklist, so an anchored egrep pattern is expressible.
P7="$T/p7"; mkdir "$P7"; _make_project "$P7"
anchored='^docs/.*[.]md$'
run "$P7" config set TEST_PATH_GLOB "$anchored"
[ "$RC" -eq 0 ]                                   || fail "glob key rejected an anchored pattern ($OUT)"
run "$P7" config get TEST_PATH_GLOB
[ "$OUT" = "$anchored" ]                          || fail "glob key set→get roundtrip not byte-identical (got '$OUT')"
# the stored value works as a real grep -E pattern (proves it round-tripped uncorrupted, not just as text).
printf 'docs/readme.md\n' | grep -qE "$OUT"        || fail "roundtripped glob value does not behave as a grep -E pattern"
printf 'src/main.go\n'   | grep -qE "$OUT"         && fail "roundtripped glob value matched a path it should not"
ok

# a glob key still refuses a newline (breaks the KEY="VALUE" line format regardless of shape).
run "$P7" config set TEST_PATH_GLOB "$(printf 'a\nb')"
[ "$RC" -ne 0 ]                                   || fail "glob key accepted a newline value"
printf '%s\n' "$OUT" | grep -qi 'newline'         || fail "glob newline rejection missing message ($OUT)"
ok

# a glob key still refuses characters outside the vetted set (backtick, double-quote, space) — this is
# a WHITELIST, not merely a narrower blacklist.
for bad in 'x`id`' 'q"r' 'has space'; do
  run "$P7" config set TEST_PATH_GLOB "$bad"
  [ "$RC" -ne 0 ]                                 || fail "glob key accepted out-of-charset value: [$bad]"
  printf '%s\n' "$OUT" | grep -qi 'invalid value'  || fail "glob rejection message wrong for [$bad] ($OUT)"
done
ok

# non-glob keys keep the EXACT prior strict charset (byte-identical behavior) — $ and \ still refused.
run "$P7" config set WORKSPACE_NAME 'a$(id)'
[ "$RC" -ne 0 ]                                   || fail "non-glob key wrongly widened: accepted a shell-active value"
printf '%s\n' "$OUT" | grep -qi 'shell-active'    || fail "non-glob rejection message regressed ($OUT)"
ok

echo "ALL PASS ($pass tests)"
