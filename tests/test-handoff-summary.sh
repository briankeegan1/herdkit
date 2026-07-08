#!/usr/bin/env bash
# test-handoff-summary.sh — hermetic tests for the BUILDER HANDOFF SUMMARY (HERD-106).
#
# Fully hermetic: stubs gh (pr view/edit) on PATH; touches nothing outside $T; never opens a real PR.
#
# Covers:
#   • handoff.sh parser (sourced) — handoff_extract / handoff_has / handoff_fields / handoff_field:
#     present block, absent block, half-open marker (not a block), version-tag + decoration tolerance
#   • handoff_render — shape-complete block from HANDOFF_* env; empty fields render as em dash;
#     multi-line field values collapse to one line (parse contract preserved)
#   • round-trip: render → parse recovers every field
#   • handoff_upsert_body — append when absent, REPLACE when present (idempotent, never stacks)
#   • CLI: render prints a block; emit upserts into the PR body via the gh stub; show/fields read back
#   • FAIL-SOFT: a body with no block yields empty parse + non-zero handoff_has (byte-identical path)
# Run:  bash tests/test-handoff-summary.sh
# No `set -e`: several checks assert non-zero returns explicitly.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
HANDOFF="$HERE/../scripts/herd/handoff.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

[ -f "$HANDOFF" ] || fail "handoff.sh not found at $HANDOFF"
command -v python3 >/dev/null 2>&1 || fail "python3 required"

# ── gh stub: a per-PR body file under $BODIES, editable via `gh pr edit --body-file` ──────────────
BIN="$T/bin"; mkdir -p "$BIN"
BODIES="$T/bodies"; mkdir -p "$BODIES"
export BODIES
cat > "$BIN/gh" << 'STUB'
#!/usr/bin/env bash
# Minimal gh stub. Recognizes:
#   pr view <n> --json body -q .body   → print $BODIES/<n> (empty if none)
#   pr edit <n> --body-file <f>        → overwrite $BODIES/<n> with <f>
case "$1 $2" in
  "pr view")
    num="$3"
    [ -f "$BODIES/$num" ] && cat "$BODIES/$num" || true
    exit 0 ;;
  "pr edit")
    num="$3"; shift 3
    f=""
    while [ "$#" -gt 0 ]; do case "$1" in --body-file) f="$2"; shift 2 ;; *) shift ;; esac; done
    [ -n "$f" ] && cp "$f" "$BODIES/$num"
    exit 0 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$BIN/gh"
export PATH="$BIN:$PATH"

# ── 1. Source the parser ──────────────────────────────────────────────────────────────────────────
. "$HANDOFF" || fail "sourcing handoff.sh failed"
for fn in handoff_extract handoff_has handoff_fields handoff_field handoff_render handoff_upsert_body; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined after sourcing"
done
ok

# ── 2. Parser on a present block ─────────────────────────────────────────────────────────────────
BLOCK_BODY="$(printf 'Some PR prose above.\n\n<!-- herd-handoff:v1 -->\n### Builder handoff\n- **Changed:** adds the handoff emitter\n- **Files:** scripts/herd/handoff.sh, tests/test-handoff-summary.sh\n- **Decisions:** self-contained script, no preamble edit\n- **Verification:** healthcheck.sh -> PASS\n- **Follow-ups:** none\n<!-- /herd-handoff:v1 -->\n')"
printf '%s' "$BLOCK_BODY" | handoff_has || fail "present block should satisfy handoff_has"
ok
printf '%s' "$BLOCK_BODY" | handoff_extract | grep -q '<!-- herd-handoff:v1 -->' || fail "extract missing begin sentinel"
printf '%s' "$BLOCK_BODY" | handoff_extract | grep -q '<!-- /herd-handoff:v1 -->' || fail "extract missing end sentinel"
ok
# extract must NOT include the surrounding prose
printf '%s' "$BLOCK_BODY" | handoff_extract | grep -q 'Some PR prose above' && fail "extract leaked prose outside the block"
ok
fields="$(printf '%s' "$BLOCK_BODY" | handoff_fields)"
printf '%s' "$fields" | grep -q '^changed=adds the handoff emitter$'   || fail "changed field wrong: $fields"
printf '%s' "$fields" | grep -q '^files=scripts/herd/handoff.sh, tests/test-handoff-summary.sh$' || fail "files field wrong: $fields"
printf '%s' "$fields" | grep -q '^decisions=self-contained script, no preamble edit$' || fail "decisions field wrong: $fields"
printf '%s' "$fields" | grep -q '^verification=healthcheck.sh -> PASS$' || fail "verification field wrong: $fields"
printf '%s' "$fields" | grep -q '^followups=none$' || fail "followups field wrong: $fields"
ok
[ "$(printf '%s' "$BLOCK_BODY" | handoff_field Changed)" = "adds the handoff emitter" ] || fail "handoff_field Changed wrong"
[ "$(printf '%s' "$BLOCK_BODY" | handoff_field verification)" = "healthcheck.sh -> PASS" ] || fail "handoff_field verification wrong"
ok

# ── 3. Absent / half-open → fail-soft (byte-identical no-handoff path) ────────────────────────────
NOMARK="$(printf 'Just a normal PR body.\nRefs: HERD-106\n')"
! printf '%s' "$NOMARK" | handoff_has || fail "absent block must NOT satisfy handoff_has"
[ -z "$(printf '%s' "$NOMARK" | handoff_extract)" ] || fail "absent block must extract to nothing"
[ -z "$(printf '%s' "$NOMARK" | handoff_fields)" ]  || fail "absent block must yield no fields"
ok
HALF="$(printf 'text\n<!-- herd-handoff:v1 -->\n- **Changed:** dangling, no close\n')"
! printf '%s' "$HALF" | handoff_has || fail "half-open marker (no close sentinel) must NOT be a block"
ok
EMPTY=""
! printf '%s' "$EMPTY" | handoff_has || fail "empty body must NOT be a block"
ok

# ── 4. Version-tag + decoration tolerance (unversioned sentinel, mixed decoration) ────────────────
LOOSE="$(printf '<!-- herd-handoff -->\n**Changed**: loose form\n* **Files:** a.sh\n<!-- /herd-handoff -->\n')"
printf '%s' "$LOOSE" | handoff_has || fail "unversioned sentinel should still parse as a block"
[ "$(printf '%s' "$LOOSE" | handoff_field changed)" = "loose form" ] || fail "colon-outside-bold key not parsed"
[ "$(printf '%s' "$LOOSE" | handoff_field files)" = "a.sh" ] || fail "'*'-bulleted field not de-bulleted"
ok

# ── 5. handoff_render — shape-complete, empty→em dash, multiline collapse ─────────────────────────
rendered="$(HANDOFF_CHANGED="did a thing" HANDOFF_FILES="x.sh" handoff_render)"
printf '%s' "$rendered" | grep -q '^<!-- herd-handoff:v1 -->$'  || fail "render missing begin sentinel"
printf '%s' "$rendered" | grep -q '^<!-- /herd-handoff:v1 -->$' || fail "render missing end sentinel"
printf '%s' "$rendered" | grep -q -- '- \*\*Changed:\*\* did a thing' || fail "render missing Changed value"
# unset fields become em dashes so the block is always complete
printf '%s' "$rendered" | grep -q -- '- \*\*Decisions:\*\* —' || fail "empty Decisions should render as em dash"
ok
# multi-line value collapses to one physical line (preserves the one-field-per-line parse contract)
ml="$(HANDOFF_DECISIONS="$(printf 'line one\nline two')" handoff_render)"
[ "$(printf '%s' "$ml" | grep -c 'Decisions')" = "1" ] || fail "multi-line Decisions must collapse to one line"
printf '%s' "$ml" | grep -q -- '- \*\*Decisions:\*\* line one line two' || fail "multi-line collapse text wrong"
ok

# ── 6. Round-trip: render → parse recovers every field ───────────────────────────────────────────
rt="$(HANDOFF_CHANGED="c val" HANDOFF_FILES="f val" HANDOFF_DECISIONS="d val" \
      HANDOFF_VERIFICATION="v val" HANDOFF_FOLLOWUPS="fu val" handoff_render)"
[ "$(printf '%s' "$rt" | handoff_field changed)" = "c val" ]      || fail "round-trip changed"
[ "$(printf '%s' "$rt" | handoff_field files)" = "f val" ]        || fail "round-trip files"
[ "$(printf '%s' "$rt" | handoff_field decisions)" = "d val" ]    || fail "round-trip decisions"
[ "$(printf '%s' "$rt" | handoff_field verification)" = "v val" ] || fail "round-trip verification"
[ "$(printf '%s' "$rt" | handoff_field followups)" = "fu val" ]   || fail "round-trip followups"
ok

# ── 7. handoff_upsert_body — append when absent, REPLACE when present (idempotent) ────────────────
base="$(printf 'Original PR body.\n\nRefs: HERD-106\n')"
once="$(printf '%s' "$base" | HANDOFF_CHANGED="first" handoff_upsert_body)"
printf '%s' "$once" | grep -q 'Original PR body' || fail "upsert dropped the original body"
[ "$(printf '%s' "$once" | grep -c 'herd-handoff:v1' )" = "2" ] || fail "upsert should add exactly one block (2 sentinels)"
[ "$(printf '%s' "$once" | handoff_field changed)" = "first" ] || fail "upsert appended wrong Changed"
ok
# re-emit REPLACES, never stacks — still exactly one block, new value wins
twice="$(printf '%s' "$once" | HANDOFF_CHANGED="second" handoff_upsert_body)"
[ "$(printf '%s' "$twice" | grep -c 'herd-handoff:v1' )" = "2" ] || fail "re-emit must not stack blocks"
[ "$(printf '%s' "$twice" | handoff_field changed)" = "second" ] || fail "re-emit should replace the value"
printf '%s' "$twice" | grep -q 'Original PR body' || fail "re-emit dropped the original body"
ok

# ── 8. CLI: render / emit / show / fields via the gh stub ─────────────────────────────────────────
cli_render="$(bash "$HANDOFF" render --changed "cli change" --files "z.sh")"
printf '%s' "$cli_render" | grep -q -- '- \*\*Changed:\*\* cli change' || fail "CLI render missing value"
printf '%s' "$cli_render" | grep -q -- '- \*\*Files:\*\* z.sh' || fail "CLI render missing files"
ok
# seed a PR body, emit into it, read it back
printf 'Body of PR 42.\nRefs: HERD-106\n' > "$BODIES/42"
bash "$HANDOFF" emit 42 --changed "emitted change" --files "handoff.sh" \
  --decisions "self-contained" --verification "healthcheck -> PASS" --followups "none" >/dev/null \
  || fail "CLI emit returned non-zero"
grep -q 'Body of PR 42' "$BODIES/42" || fail "emit clobbered the original PR body"
[ "$(handoff_field changed < "$BODIES/42")" = "emitted change" ] || fail "emit did not persist the block"
ok
# show prints the block; fields <pr#> reads it back as key=value
bash "$HANDOFF" show 42 | grep -q '<!-- herd-handoff:v1 -->' || fail "CLI show missing block"
bash "$HANDOFF" fields 42 | grep -q '^verification=healthcheck -> PASS$' || fail "CLI fields <pr#> wrong"
ok
# re-emit into the same PR stays single-block (idempotent through the CLI)
bash "$HANDOFF" emit 42 --changed "re-emitted" >/dev/null || fail "CLI re-emit non-zero"
[ "$(grep -c 'herd-handoff:v1' "$BODIES/42")" = "2" ] || fail "CLI re-emit stacked blocks"
[ "$(handoff_field changed < "$BODIES/42")" = "re-emitted" ] || fail "CLI re-emit did not replace"
ok
# emit with a non-numeric pr# is a usage error (exit 2), not a silent success
bash "$HANDOFF" emit not-a-number >/dev/null 2>&1 && fail "emit must reject a non-numeric PR#"
ok

echo "ALL PASS ($pass checks)"
