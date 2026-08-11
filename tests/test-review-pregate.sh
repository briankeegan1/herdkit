#!/usr/bin/env bash
# test-review-pregate.sh — hermetic tests for the REVIEW FAST PATH (HERD-559): the mechanical-red
# PRE-GATE (REVIEW_PREGATE), the small-mechanical-diff FLOOR (REVIEW_MECH_FLOOR), and the review
# LATENCY telemetry (REVIEW_LATENCY).
#
# The three legs and what each assertion pins:
#
#   (1) PRE-GATE — scripts/herd/review-pregate.sh runs the EXISTING shared lint set against the diff
#       before a reviewer is dispatched.
#         (1a) a caps-sync-violating tree is RED, and the finding names the lint
#         (1b) a clean tree is CLEAN
#         (1c) BASELINE SUBTRACTION: a lint red that ALSO exists at the merge base is NOT this diff's
#              and must not be reported — the property that stops a builder being bounced onto a red
#              it cannot fix inside its own item (the merge suite is diff-scoped, so a standing red on
#              the default branch is a real, observed state, not a hypothetical)
#         (1d) an uncomputable baseline SKIPS (rc 2), never reports an unsubtracted red
#
#   (2) DISPATCH LEG — agent-watch.sh:_review_gate_step, sourced in lib mode with a stub reviewer:
#         (2a) a caps-sync-violating fixture diff BOUNCES pre-review: the step echoes BLOCK, NO
#              reviewer is spawned, NO inflight marker is written, and NO review_dispatched is
#              journaled — while review_pregate_red IS
#         (2b) the verdict is recorded sha-keyed with provenance source=pregate (never `reviewer`)
#         (2c) a CLEAN diff reviews exactly as today (RUNNING + a spawned reviewer), and with
#              REVIEW_PREGATE off (the default) even the dirty diff reviews exactly as today —
#              the byte-identical-when-off half
#
#   (3) FLOOR — herd_review_mech_floor:
#         (3a) a pure TSV-row diff is mechanical; (3b) a pure rename is; (3c) a version bump is
#         (3d) a real code edit is NOT; (3e) an over-size diff is NOT
#         (3f) REVIEW_ESCALATE_GLOB is an absolute veto
#         (3g) the floor routes the tier to REVIEW_MODEL_CHEAP in _review_gate_step, and is inert
#              with REVIEW_MECH_FLOOR off
#
#   (4) LATENCY — a collected verdict journals review_latency with the dispatch→verdict seconds, and
#       REVIEW_LATENCY=off is a hard no-op.
#
# Fully hermetic: local temp only; stubs gh/herdr (PATH) and the reviewer (HERD_REVIEW_BIN). No
# network, no model, no real PRs. REAL git is required and used (the floor reasons about real
# rename/similarity detection, which no stub can honestly fake).
# Run:  bash tests/test-review-pregate.sh
# No `set -e`: several checks assert non-zero returns explicitly.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WATCH="$ROOT/scripts/herd/agent-watch.sh"
PREGATE="$ROOT/scripts/herd/review-pregate.sh"
# shellcheck source=tests/lib/await-file-contains.sh
. "$HERE/lib/await-file-contains.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

[ -f "$WATCH" ]   || fail "agent-watch.sh not found at $WATCH"
[ -f "$PREGATE" ] || fail "review-pregate.sh not found at $PREGATE"
command -v git >/dev/null 2>&1 || fail "git required to run this test"

# ── stubs on PATH (git deliberately NOT stubbed) ─────────────────────────────────────────────────
BIN="$T/bin"; mkdir -p "$BIN"
for cmd in gh herdr; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$cmd"; chmod +x "$BIN/$cmd"
done
export PATH="$BIN:$PATH"

STUB_REVIEW="$T/stub-review.sh"
cat > "$STUB_REVIEW" <<'STUB'
#!/usr/bin/env bash
pr="$1"; slug="$2"
[ -n "${STUB_SPAWN_LOG:-}" ] && printf '%s %s\n' "$pr" "$slug" >> "$STUB_SPAWN_LOG"
[ -n "${STUB_MODEL_LOG:-}" ] && printf '%s\n' "${HERD_REVIEW_MODEL:-}" >> "$STUB_MODEL_LOG"
if [ -n "${HERD_REVIEW_RESULT_FILE:-}" ]; then
  printf '%s\n' "${STUB_VERDICT:-REVIEW: PASS}" > "$HERD_REVIEW_RESULT_FILE.tmp.$$"
  mv "$HERD_REVIEW_RESULT_FILE.tmp.$$" "$HERD_REVIEW_RESULT_FILE"
fi
printf '%s\n' "${STUB_VERDICT:-REVIEW: PASS}"
STUB
chmod +x "$STUB_REVIEW"

# ── git fixture helpers ──────────────────────────────────────────────────────────────────────────
gc() { git -C "$1" "${@:2}"; }
# A minimal tree carrying just enough herdkit surface for the lints to have something to look at:
# a capabilities manifest and one engine script. `main` is the base branch; work happens on `feat`.
init_fixture() {
  local d="$1"
  mkdir -p "$d/scripts/herd" "$d/templates"
  git init -q "$d"
  gc "$d" config user.email a@b.c
  gc "$d" config user.name  a
  gc "$d" config commit.gpgsign false
  printf 'name\tkind\tdescription\twhen_to_surface\trequires\tscope\tgovernance\tvalue_shape\tenv_coupling\n' \
    > "$d/templates/capabilities.tsv"
  printf '#!/usr/bin/env bash\n# an engine script\necho hi\n' > "$d/scripts/herd/thing.sh"
  printf 'v1.0.0\n' > "$d/VERSION"
  printf 'a\nb\nc\n' > "$d/notes.txt"
  gc "$d" add -A; gc "$d" commit -qm base
  gc "$d" branch -M main
  gc "$d" checkout -q -b feat
}
# Add a NEW scripts/herd/*.sh without touching templates/capabilities.tsv — the caps-sync violation.
add_caps_violation() {
  printf '#!/usr/bin/env bash\necho new\n' > "$1/scripts/herd/brand-new.sh"
  gc "$1" add -A; gc "$1" commit -qm 'add a new engine script, no manifest row'
}

# ══ (1) the pre-gate itself ══════════════════════════════════════════════════════════════════════

# (1a) a caps-sync-violating tree is RED and names the lint.
D="$T/f1"; init_fixture "$D"; add_caps_violation "$D"
out="$(bash "$PREGATE" lint "$D" main 2>/dev/null)"; rc=$?
[ "$rc" -eq 1 ] || fail "(1a) a caps-sync violation must be a pre-gate RED (rc=$rc)"
grep -q '^PREGATE caps-sync:' <<< "$out" || fail "(1a) the finding must name the caps-sync lint: $out"
ok

# (1b) a clean tree is CLEAN — a commit that touches nothing the lint set cares about.
D="$T/f2"; init_fixture "$D"
printf 'a\nb\nc\nd\n' > "$D/notes.txt"; gc "$D" add -A; gc "$D" commit -qm 'edit a plain text file'
bash "$PREGATE" lint "$D" main >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] || fail "(1b) a clean diff must be pre-gate CLEAN (rc=$rc)"
ok

# (1c) BASELINE SUBTRACTION. Uses a TREE-SCOPED lint (pipe-safety), which is where the property
# actually bites: caps-sync reasons about the diff and so is self-limiting, but pipe-safety, git-scope,
# doc-drift and the config-manifest scan all report every violation PRESENT in the tree, including one
# that has been sitting on the default branch. The violation is committed on MAIN (so it is in the
# merge base) and the feature branch merely edits an unrelated file: the tree scan still fires, and the
# pre-gate must nonetheless report CLEAN, because this diff introduced nothing.
D="$T/f3"; init_fixture "$D"
gc "$D" checkout -q main
printf '#!/usr/bin/env bash\ncat notes.txt | grep -q hi\n' > "$D/scripts/herd/already-red.sh"  # pipe-ok: FIXTURE TEXT, not a pipeline — this line WRITES the anti-pattern into a throwaway repo so the pipe-safety lint has something to find
gc "$D" add -A; gc "$D" commit -qm 'a standing pipe-safety red on the default branch'
gc "$D" checkout -q feat
gc "$D" merge -q --no-edit main
printf 'a\nb\nc\nd\n' > "$D/notes.txt"; gc "$D" add -A; gc "$D" commit -qm 'unrelated edit'
# Sanity: the tree-scoped lint really does still see the standing red (else this proves nothing).
( cd "$D" && . "$ROOT/scripts/herd/pipe-safety-lint.sh" && herd_pipe_safety_lint . >/dev/null 2>&1 )
[ $? -eq 1 ] || fail "(1c) setup: the standing red must still be visible to a tree-scoped pipe-safety run"
out="$(bash "$PREGATE" lint "$D" main 2>/dev/null)"; rc=$?
[ "$rc" -eq 0 ] || fail "(1c) a red present at the MERGE BASE must be subtracted, not reported (rc=$rc): $out"
ok

# (1c') …and the SAME lint, when the violation is introduced by THIS diff, is still reported. Without
# this the subtraction above could pass vacuously by never reporting anything at all.
D="$T/f3b"; init_fixture "$D"
printf '#!/usr/bin/env bash\ncat notes.txt | grep -q hi\n' > "$D/scripts/herd/mine.sh"  # pipe-ok: FIXTURE TEXT, not a pipeline — this line WRITES the anti-pattern into a throwaway repo so the pipe-safety lint has something to find
gc "$D" add -A; gc "$D" commit -qm 'introduce a pipe-safety red on the branch'
out="$(bash "$PREGATE" lint "$D" main 2>/dev/null)"; rc=$?
[ "$rc" -eq 1 ] || fail "(1c') a red this diff INTRODUCED must still be reported (rc=$rc)"
grep -q '^PREGATE pipe-safety:' <<< "$out" || fail "(1c') the finding must name the pipe-safety lint: $out"
ok

# (1d) an uncomputable baseline SKIPS rather than reporting an UNSUBTRACTED red. A tree-scoped lint
# is red here, so the pre-gate has a finding in hand and the only question is what it does when it
# cannot prove the finding is new — and the answer must be "nothing", never "bounce the builder".
D="$T/f4"; init_fixture "$D"
printf '#!/usr/bin/env bash\ncat notes.txt | grep -q hi\n' > "$D/scripts/herd/mine.sh"  # pipe-ok: FIXTURE TEXT, not a pipeline — this line WRITES the anti-pattern into a throwaway repo so the pipe-safety lint has something to find
gc "$D" add -A; gc "$D" commit -qm 'introduce a pipe-safety red'
bash "$PREGATE" lint "$D" main >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] || fail "(1d) setup: this tree must be red against a resolvable base (rc=$rc)"
bash "$PREGATE" lint "$D" no-such-base-ref >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] || fail "(1d) an unresolvable base must SKIP (rc=2), never report a red (rc=$rc)"
ok

# ══ (3) the mechanical floor (before the watcher legs — the classifier is a pure function) ════════
mech() { bash "$PREGATE" floor "$1" main >/dev/null 2>&1; }

# (3a) a pure TSV-row diff is mechanical.
D="$T/m1"; init_fixture "$D"
printf 'FOO\tconfig\tdesc\twhen\t\t\t\tfree\t\n' >> "$D/templates/capabilities.tsv"
gc "$D" add -A; gc "$D" commit -qm 'add a manifest row'
mech "$D" || fail "(3a) a pure TSV-row diff must be mechanical"
ok

# (3b) a pure rename (100% similarity) is mechanical.
D="$T/m2"; init_fixture "$D"
gc "$D" mv notes.txt notes-renamed.txt; gc "$D" commit -qm 'rename only'
mech "$D" || fail "(3b) a pure rename must be mechanical"
ok

# (3c) a version bump is mechanical.
D="$T/m3"; init_fixture "$D"
printf 'v1.0.1\n' > "$D/VERSION"; gc "$D" add -A; gc "$D" commit -qm 'bump version'
mech "$D" || fail "(3c) a version bump must be mechanical"
ok

# (3d) a real code edit is NOT mechanical — the floor must never downgrade a diff with logic in it.
D="$T/m4"; init_fixture "$D"
printf '#!/usr/bin/env bash\n# an engine script\nif [ -n "$1" ]; then echo hi; fi\n' > "$D/scripts/herd/thing.sh"
gc "$D" add -A; gc "$D" commit -qm 'change behavior'
mech "$D" && fail "(3d) a real code edit must NOT be mechanical"
ok

# (3e) an over-size diff is NOT mechanical whatever its shape — many TSV rows are still many rows.
D="$T/m5"; init_fixture "$D"
for i in $(seq 1 60); do printf 'K%s\tconfig\td\tw\t\t\t\tfree\t\n' "$i" >> "$D/templates/capabilities.tsv"; done
gc "$D" add -A; gc "$D" commit -qm 'sixty manifest rows'
mech "$D" && fail "(3e) a diff over REVIEW_MECH_FLOOR_MAXLINES must NOT be mechanical"
ok

# (3f) REVIEW_ESCALATE_GLOB is an absolute veto over the floor.
D="$T/m6"; init_fixture "$D"
printf 'FOO\tconfig\tdesc\twhen\t\t\t\tfree\t\n' >> "$D/templates/capabilities.tsv"
gc "$D" add -A; gc "$D" commit -qm 'add a manifest row'
mech "$D" || fail "(3f) setup: the row edit must be mechanical without the glob"
REVIEW_ESCALATE_GLOB='^templates/' bash "$PREGATE" floor "$D" main >/dev/null 2>&1 \
  && fail "(3f) a REVIEW_ESCALATE_GLOB match must veto the floor"
ok

# ══ (2)+(3g)+(4) the watcher's review dispatch leg ════════════════════════════════════════════════
export AGENT_WATCH_LIB=1
export WORKTREES_DIR="$T/trees"; mkdir -p "$WORKTREES_DIR"
export HERD_CONFIG_FILE="$T/no-such-config"
export HERD_REVIEW_BIN="$STUB_REVIEW"
export JOURNAL_FILE="$T/journal.jsonl"; : > "$JOURNAL_FILE"
export REVIEW_CONCURRENCY=2
export DEFAULT_BRANCH=main
export DRYRUN=""
export REVIEW_MODEL_CHEAP="cheap-model"
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"

for fn in _review_pregate_step _record_pregate_block _review_mech_floor_applies _review_gate_step; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined after sourcing agent-watch.sh"
done
ok

export STUB_SPAWN_LOG="$T/spawns.log"
export STUB_MODEL_LOG="$T/models.log"
# journal_grep <event> — count matching journal events for this run.
# journal_grep <event> — how many of this event the journal holds. `grep -c` prints 0 AND exits 1 on
# no match, so the count must be captured before the || fallback fires — a bare
# `grep -c … || printf 0` emits "0\n0" for the no-match case and every comparison against it lies.
journal_grep() {
  local _jg_n
  _jg_n="$(grep -c "\"event\":\"$1\"" "$JOURNAL_FILE" 2>/dev/null)" || _jg_n=0
  printf '%s' "${_jg_n:-0}"
}

# (2a)+(2b) a caps-sync-violating diff BOUNCES pre-review.
SLUG=dirty; D="$WORKTREES_DIR/$SLUG"; init_fixture "$D"; add_caps_violation "$D"
SHA="$(gc "$D" rev-parse HEAD)"
: > "$STUB_SPAWN_LOG"; : > "$JOURNAL_FILE"
step="$(REVIEW_PREGATE=on _review_gate_step 501 "$SLUG" "$SHA")"
[ "$step" = "BLOCK" ] || fail "(2a) a mechanical red must BLOCK pre-review (got '$step')"
[ ! -s "$STUB_SPAWN_LOG" ] || fail "(2a) a pre-gate red must dispatch NO reviewer"
[ ! -f "$(_review_inflight_file 501 "$SHA")" ] || fail "(2a) a pre-gate red must write no inflight marker"
[ "$(journal_grep review_dispatched)" = "0" ] || fail "(2a) a pre-gate red must journal NO review_dispatched"
[ "$(journal_grep review_pregate_red)" != "0" ] || fail "(2a) a pre-gate red must journal review_pregate_red"
[ "$(review_verdict 501 "$SHA")" = "BLOCK" ] || fail "(2b) the pre-gate red must record a sha-keyed BLOCK"
[ "$(review_verdict_source 501 "$SHA")" = "pregate" ] || fail "(2b) provenance must be 'pregate', never 'reviewer'"
ok

# (2b') the lint output survives for the bounce. It is read by _handle_block_verdict on a LATER tick,
# and every per-(pr,sha) review artifact is swept by _discard_stale_reviews, which decides staleness
# from the LAST dash-segment of the filename — so a name whose sha is not last is deleted on the very
# next tick, silently degrading every mechanical bounce to the generic "read the full review" prompt
# for a review that was never written. Pin both halves: the file exists, and a same-sha sweep keeps it.
[ -s "$(_review_lint_file 501 "$SHA")" ] || fail "(2b') the pre-gate must persist its lint output for the bounce"
_discard_stale_reviews 501 "$SHA"
[ -s "$(_review_lint_file 501 "$SHA")" ] || fail "(2b') a same-sha sweep must KEEP the lint output"
grep -q 'PREGATE caps-sync' "$(_review_lint_file 501 "$SHA")" || fail "(2b') the persisted output must be the findings"
_discard_stale_reviews 501 "some-other-sha"
[ -e "$(_review_lint_file 501 "$SHA")" ] && fail "(2b') a NEW head sha must sweep the stale lint output"
ok

# (2b'') the ledger REASON names the lint that actually fired. `herd approve why` and the PR comment
# both read this string, and a generic "mechanical" would tell an operator nothing about which rule
# refused the diff — the same silent degradation the findings-through-a-subshell bug produced.
ledger_reason() { awk -v p="$1" -v s="$2" '$2==p && $3==s{r=""; for(i=6;i<=NF;i++) r=r $i " "} END{print r}' "$REVIEW_STATE" 2>/dev/null; }
grep -q 'caps-sync' <<< "$(ledger_reason 501 "$SHA")" \
  || fail "(2b'') the ledger reason must name the lint that fired: $(ledger_reason 501 "$SHA")"
ok

# (2b''') the auto-refix PROVENANCE gate accepts `pregate`. That gate exists to stop a verdict with no
# actionable finding from waking a builder; a pre-gate red carries the literal lint output, so it must
# pass. Asserted through the row it would otherwise paint ("blocked without a reviewer finding"), with
# no agent present — so the call ends in the ordinary no-pane escalation, never the provenance refusal.
DISPLAY=()
REVIEW_AUTOFIX=true _handle_block_verdict 501 dirty "$SHA" 0
grep -q 'without a reviewer finding' <<< "${DISPLAY[0]:-}" \
  && fail "(2b''') a pregate BLOCK must clear the provenance gate (got: ${DISPLAY[0]:-})"
ok

# (2c-off) with REVIEW_PREGATE off (the DEFAULT), the SAME dirty diff reviews exactly as today.
SLUG=dirtyoff; D="$WORKTREES_DIR/$SLUG"; init_fixture "$D"; add_caps_violation "$D"
SHA="$(gc "$D" rev-parse HEAD)"
: > "$STUB_SPAWN_LOG"; : > "$JOURNAL_FILE"
step="$(_review_gate_step 502 "$SLUG" "$SHA")"
[ "$step" = "RUNNING" ] || fail "(2c-off) with the lever off a mechanical red must still review (got '$step')"
# The dispatch is BACKGROUNDED (_bg_new_session): the step above returns as soon as the fork is
# recorded, before the child has necessarily run. Sampling the child's log immediately races fork+exec
# latency (HERD-630/HERD-635) — await it instead of reading it cold.
await_file_contains "$STUB_SPAWN_LOG" '.' || fail "(2c-off) with the lever off the reviewer must be dispatched"
[ "$(journal_grep review_pregate_red)" = "0" ] || fail "(2c-off) the lever off must journal no pre-gate event"
ok

# (2c-clean) a mechanically-CLEAN diff reviews exactly as today even with the lever ON.
SLUG=clean; D="$WORKTREES_DIR/$SLUG"; init_fixture "$D"
printf 'a\nb\nc\nd\n' > "$D/notes.txt"; gc "$D" add -A; gc "$D" commit -qm 'plain text edit'
SHA="$(gc "$D" rev-parse HEAD)"
: > "$STUB_SPAWN_LOG"; : > "$JOURNAL_FILE"
step="$(REVIEW_PREGATE=on _review_gate_step 503 "$SLUG" "$SHA")"
[ "$step" = "RUNNING" ] || fail "(2c-clean) a clean diff must review as today (got '$step')"
# See (2c-off): the dispatch is backgrounded, so the child's log must be awaited, not read cold.
await_file_contains "$STUB_SPAWN_LOG" '.' || fail "(2c-clean) a clean diff must dispatch the reviewer"
[ "$(journal_grep review_dispatched)" != "0" ] || fail "(2c-clean) a clean diff must journal review_dispatched"
ok

# (4) LATENCY — collect the verdict the stub already wrote; the step must journal review_latency.
: > "$JOURNAL_FILE"
# The COLLECT call below reads the child's result file (_review_gate_step: `[ -f "$result" ]`); if the
# child has not written it yet the step just re-echoes RUNNING instead of collecting PASS — the same
# fork-latency race, on the result file instead of the spawn log. Await the artifact the collect step
# itself will read before making the collect call.
await_file_contains "$(_review_result_file 503 "$SHA")" '^REVIEW: ' \
  || fail "(4) the stub reviewer never wrote a result file"
step="$(REVIEW_PREGATE=on _review_gate_step 503 "$SLUG" "$SHA")"
[ "$step" = "PASS" ] || fail "(4) the stub's verdict must collect as PASS (got '$step')"
[ "$(journal_grep review_latency)" != "0" ] || fail "(4) a collected verdict must journal review_latency"
grep -q '"verdict":"PASS"' "$JOURNAL_FILE" || fail "(4) review_latency must carry the verdict that produced it"
ok

# (4-off) REVIEW_LATENCY=off is a hard no-op.
SLUG=lat; D="$WORKTREES_DIR/$SLUG"; init_fixture "$D"
printf 'z\n' >> "$D/notes.txt"; gc "$D" add -A; gc "$D" commit -qm 'edit'
SHA="$(gc "$D" rev-parse HEAD)"
: > "$JOURNAL_FILE"
_review_gate_step 504 "$SLUG" "$SHA" >/dev/null            # dispatch
REVIEW_LATENCY=off _review_gate_step 504 "$SLUG" "$SHA" >/dev/null   # collect
[ "$(journal_grep review_latency)" = "0" ] || fail "(4-off) REVIEW_LATENCY=off must journal no latency event"
ok

# (3g) the FLOOR routes a mechanical diff to REVIEW_MODEL_CHEAP, and is inert when off.
SLUG=floor; D="$WORKTREES_DIR/$SLUG"; init_fixture "$D"
printf 'FOO\tconfig\tdesc\twhen\t\t\t\tfree\t\n' >> "$D/templates/capabilities.tsv"
gc "$D" add -A; gc "$D" commit -qm 'add a manifest row'
SHA="$(gc "$D" rev-parse HEAD)"
: > "$STUB_MODEL_LOG"; : > "$JOURNAL_FILE"
step="$(REVIEW_MECH_FLOOR=on _review_gate_step 505 "$SLUG" "$SHA")"
[ "$step" = "RUNNING" ] || fail "(3g) the floor must still dispatch a (cheap) reviewer (got '$step')"
# Backgrounded dispatch again (see (2c-off)): await the child's model-log line instead of reading cold.
await_file_contains "$STUB_MODEL_LOG" '^cheap-model$' \
  || fail "(3g) the floor must dispatch on REVIEW_MODEL_CHEAP: $(cat "$STUB_MODEL_LOG")"
[ "$(journal_grep review_tier_floor)" != "0" ] || fail "(3g) the floor must journal review_tier_floor"
ok

SLUG=flooroff; D="$WORKTREES_DIR/$SLUG"; init_fixture "$D"
printf 'FOO\tconfig\tdesc\twhen\t\t\t\tfree\t\n' >> "$D/templates/capabilities.tsv"
gc "$D" add -A; gc "$D" commit -qm 'add a manifest row'
SHA="$(gc "$D" rev-parse HEAD)"
: > "$STUB_MODEL_LOG"; : > "$JOURNAL_FILE"
step="$(_review_gate_step 506 "$SLUG" "$SHA")"
[ "$step" = "RUNNING" ] || fail "(3g-off) the default path must dispatch as today (got '$step')"
# The stub logs an (empty) HERD_REVIEW_MODEL line unconditionally — still a child-written artifact, so
# await its arrival rather than reading the (possibly still-empty-because-unwritten) file cold.
await_file_contains "$STUB_MODEL_LOG" '^$' \
  || fail "(3g-off) with the floor off no tier model may be forced: $(cat "$STUB_MODEL_LOG")"
[ "$(journal_grep review_tier_floor)" = "0" ] || fail "(3g-off) the floor off must journal nothing"
ok

echo "PASS: test-review-pregate.sh ($pass checks)"
