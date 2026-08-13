#!/usr/bin/env bash
# test-gardener.sh — hermetic test for the MAINTENANCE GARDENER (HERD-673, tuned HERD-730,
# scripts/herd/gardener.sh). No herdr, no network, no real scribe drainer: a synthetic git repo stands
# in for PROJECT_ROOT (real commits, real shas, real `git diff-tree`/`git show`), a synthetic journal
# carries fabricated `merge` events, and HERD_GARDENER_SCRIBE stubs the filing call so the sim can
# assert exactly what would have been filed — the same stub-injection pattern test-triggers.sh uses for
# HERD_TRIGGERS_SPAWN_CMD.
#
# Run:  bash tests/test-gardener.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
GARD="$ROOT/scripts/herd/gardener.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass(){ PASS=$((PASS+1)); }

# ── fixture repo: real commits, real shas, so _gardener_files_for_sha's `git diff-tree` (and the
#    header-only-change detector's `git show`/`git diff-tree -p`) are exercised for real rather than
#    stubbed — only the JOURNAL's merge events are synthetic. ───────────────────────────────────────
PROJ="$T/proj"; mkdir -p "$PROJ"
git -C "$PROJ" init -q
git -C "$PROJ" config user.email "gardener-test@example.invalid"
git -C "$PROJ" config user.name  "gardener-test"
mkdir -p "$PROJ/scripts/herd" "$PROJ/scripts/herd/backends" "$PROJ/docs" "$PROJ/templates"
printf 'seed\n' > "$PROJ/README.md"
printf 'path\tkind\tdesc\n' > "$PROJ/templates/capabilities.tsv"
git -C "$PROJ" add -A && git -C "$PROJ" commit -q -m "seed"

mkcommit() { # mkcommit <relpath>... — write+commit a trivial change to each path, return the sha
  local f
  for f in "$@"; do
    mkdir -p "$PROJ/$(dirname "$f")"
    printf 'change %s\n' "$RANDOM" >> "$PROJ/$f"
  done
  git -C "$PROJ" add -A >/dev/null
  git -C "$PROJ" commit -q -m "commit touching $*" >/dev/null
  git -C "$PROJ" rev-parse HEAD
}

SHA_A="$(mkcommit scripts/herd/newthing.sh)"                       # surface only → candidate
SHA_B="$(mkcommit README.md)"                                      # doc only → never a candidate
SHA_C="$(mkcommit scripts/herd/other.sh README.md)"                # surface + doc same merge → not a candidate
SHA_D="$(mkcommit scripts/herd/backends/second.sh)"                 # a 2nd subsystem, same run as A → rollup groups both
SHA_CAPS="$(mkcommit scripts/herd/capsthing.sh templates/capabilities.tsv)"  # surface + capabilities.tsv → counts as docs, not a candidate
SHA_CAPS_ONLY="$(mkcommit templates/capabilities.tsv)"              # capabilities.tsv alone → self-documenting, not a candidate
SHA_CODEMAP="$(mkcommit scripts/herd/codemapthing.sh docs/codemap.md)"      # surface + GENERATED doc only → still a candidate
SHA_SYMIDX="$(mkcommit scripts/herd/symidxthing.sh docs/symbol-index.md)"   # surface + GENERATED doc only → still a candidate

# ── header-only fixture: a script with a real leading `#`-comment header block, then two follow-up
#    commits — one editing ONLY the header prose, one editing the body — to exercise the self-documenting
#    minor-diff rule in both directions. ────────────────────────────────────────────────────────────
cat > "$PROJ/scripts/herd/headerthing.sh" <<'EOF'
#!/usr/bin/env bash
# headerthing.sh — a fixture script with a real header comment block.
# second header line.
echo "body line 1"
echo "body line 2"
EOF
git -C "$PROJ" add -A && git -C "$PROJ" commit -q -m "add headerthing.sh" >/dev/null
cat > "$PROJ/scripts/herd/headerthing.sh" <<'EOF'
#!/usr/bin/env bash
# headerthing.sh — a fixture script with a real header comment block.
# second header line, edited for clarity.
echo "body line 1"
echo "body line 2"
EOF
git -C "$PROJ" add -A && git -C "$PROJ" commit -q -m "tweak header prose only" >/dev/null
SHA_HEADER_ONLY="$(git -C "$PROJ" rev-parse HEAD)"
cat > "$PROJ/scripts/herd/headerthing.sh" <<'EOF'
#!/usr/bin/env bash
# headerthing.sh — a fixture script with a real header comment block.
# second header line, edited for clarity.
echo "body line 1, CHANGED"
echo "body line 2"
EOF
git -C "$PROJ" add -A && git -C "$PROJ" commit -q -m "change body" >/dev/null
SHA_BODY_CHANGE="$(git -C "$PROJ" rev-parse HEAD)"

SHA_E="$(mkcommit scripts/herd/newthing.sh)"                       # same file as A → cooldown probe (recurs while armed)
SHA_F="$(mkcommit scripts/herd/newthing.sh)"                       # same file, after cooldown expiry

# ── cap-probe fixtures: three MORE distinct undocumented files, filed under a run with a tiny cap ────
SHA_CAP1="$(mkcommit scripts/herd/cap1.sh)"
SHA_CAP2="$(mkcommit scripts/herd/cap2.sh)"
SHA_CAP3="$(mkcommit scripts/herd/cap3.sh)"

# ── hermetic env: pinned journal, a scribe STUB that logs calls instead of spawning a real drainer ──
# HERD_CONFIG_FILE — NOT plain `export PROJECT_ROOT=…` — is required here: herd-config.sh's config
# resolution walks UP FROM $PWD for a .herd/config when HERD_CONFIG_FILE is unset (test-triggers.sh
# hits the identical trap, see its own HERD-223 comment), and $PWD is this checkout, so an unpointed
# run would silently source herdkit's OWN committed .herd/config and clobber PROJECT_ROOT/WORKTREES_DIR
# right back to the real machine paths — a real git repo but the WRONG one for `git diff-tree`.
TREES="$T/trees"; mkdir -p "$TREES"
cat > "$T/config" <<EOF
PROJECT_ROOT="$PROJ"
WORKSPACE_NAME="gardenertest"
SCRIBE_BACKEND="file"
BACKLOG_FILE="BACKLOG.md"
WORKTREES_DIR="$TREES"
EOF
export HERD_CONFIG_FILE="$T/config"
export JOURNAL_FILE="$TREES/journal.jsonl"
: > "$JOURNAL_FILE"

SCRIBELOG="$T/scribe.log"; : > "$SCRIBELOG"
SCRIBE_STUB="$T/scribe-stub.sh"
cat > "$SCRIBE_STUB" <<'STUB'
#!/usr/bin/env bash
printf '=== call ===\n%s\n' "$1" >> "$SCRIBELOG"
exit 0
STUB
chmod +x "$SCRIBE_STUB"
export SCRIBELOG
export HERD_GARDENER_SCRIBE="$SCRIBE_STUB"
export HERD_GARDENER_COOLDOWN_SECS=100
export MAINTENANCE_GARDENER=on

NOW=2000000000
export HERD_GARDENER_NOW="$NOW"

journal_merge() { # journal_merge <pr> <sha> — append a synthetic `merge` event (git-pr.sh's own shape)
  printf '{"ts":"2026-01-01T00:00:00Z","event":"merge","pr":%s,"sha":"%s","slug":"x-%s","method":"squash","reason":"gates_passed"}\n' \
    "$1" "$2" "$1" >> "$JOURNAL_FILE"
}
journal_noise() { # a NON-merge event, to prove the scan ignores everything else
  printf '{"ts":"2026-01-01T00:00:00Z","event":"retire_ok","slug":"noise"}\n' >> "$JOURNAL_FILE"
}

run(){ bash "$GARD" "$@"; }
scribe_calls(){ grep -c '^=== call ===$' "$SCRIBELOG" 2>/dev/null; }
last_call(){ tail -n +"$(grep -n '^=== call ===$' "$SCRIBELOG" | tail -1 | cut -d: -f1)" "$SCRIBELOG"; }

# ── Case 0: OFF gate — MAINTENANCE_GARDENER unset/off is a hard, byte-inert no-op ─────────────────────
journal_merge 100 "$SHA_A"
out0="$(MAINTENANCE_GARDENER=off run run 2>&1)"; rc0=$?
[ "$rc0" -eq 0 ] || fail "(0) an off-gate run must still exit 0"
grep -q "MAINTENANCE_GARDENER is off" <<< "$out0" || fail "(0) an off-gate run must say so ($out0)"
[ ! -d "$TREES/.herd/gardener" ] || fail "(0) an off-gate run must touch NO state dir"
[ "$(scribe_calls)" -eq 0 ] || fail "(0) an off-gate run must never call scribe"
pass
echo "PASS (0) MAINTENANCE_GARDENER=off: disabled notice, exit 0, no state dir, no scribe call"

# ── Case 1: FIRST RUN pins the cursor at the CURRENT journal EOF — it never replays pre-existing history
out1="$(run run 2>&1)"
grep -q "FIRST RUN" <<< "$out1" || fail "(1) the very first run must announce FIRST RUN ($out1)"
[ -f "$TREES/.herd/gardener/cursor" ] || fail "(1) the first run must persist a cursor file"
[ "$(scribe_calls)" -eq 0 ] || fail "(1) the first run must NOT replay the pre-existing SHA_A merge into a filing"
pass
echo "PASS (1) first run: pins the cursor at EOF, never replays journal history, zero scribe calls"

# ── Case 2: rollup — a mixed window of drifted, doc-touched, capabilities.tsv-documented, generated-doc,
#    and header-only-edited merges collapses into exactly ONE scribe call covering only the genuine
#    drift, grouped by subsystem, quoting every merged PR#. ───────────────────────────────────────────
journal_noise
journal_merge 101 "$SHA_B"           # doc only — never a candidate
journal_merge 102 "$SHA_C"           # surface + doc same merge — never a candidate
journal_merge 103 "$SHA_A"           # scripts/herd — real drift
journal_merge 104 "$SHA_D"           # scripts/herd/backends — real drift, 2nd subsystem
journal_merge 105 "$SHA_CAPS"        # surface + capabilities.tsv — capabilities.tsv counts as docs
journal_merge 106 "$SHA_CAPS_ONLY"   # capabilities.tsv alone — self-documenting
journal_merge 107 "$SHA_CODEMAP"     # surface + docs/codemap.md (GENERATED) — codemap.md is not doc evidence, still drift
journal_merge 108 "$SHA_SYMIDX"      # surface + docs/symbol-index.md (GENERATED) — same, still drift
journal_merge 109 "$SHA_HEADER_ONLY" # header-comment-only script edit — self-documenting, never drift
out2="$(run run 2>&1)"
grep -q "filed a rollup drift finding covering 4 file(s) across 2 subsystem(s)" <<< "$out2" \
  || fail "(2) must file ONE rollup covering exactly the 4 genuinely-drifted files across 2 subsystems ($out2)"
[ "$(scribe_calls)" -eq 1 ] || fail "(2) a mixed window must collapse into exactly ONE scribe call (got $(scribe_calls))"
call2="$(last_call)"
grep -q "scripts/herd/newthing.sh" <<< "$call2" || fail "(2) rollup body must list newthing.sh ($call2)"
grep -q "scripts/herd/backends/second.sh" <<< "$call2" || fail "(2) rollup body must list backends/second.sh ($call2)"
grep -q "scripts/herd/codemapthing.sh" <<< "$call2" || fail "(2) codemapthing.sh (surface + GENERATED docs/codemap.md only) must still be flagged ($call2)"
grep -q "scripts/herd/symidxthing.sh" <<< "$call2" || fail "(2) symidxthing.sh (surface + GENERATED docs/symbol-index.md only) must still be flagged ($call2)"
grep -q "other.sh" <<< "$call2" && fail "(2) other.sh (surface+doc in the same merge) must NEVER be flagged"
grep -q "capsthing.sh" <<< "$call2" && fail "(2) capsthing.sh (surface + templates/capabilities.tsv same merge) must NEVER be flagged"
grep -q "capabilities.tsv" <<< "$call2" && fail "(2) capabilities.tsv itself must NEVER be flagged (it counts as its own docs)"
grep -q "headerthing.sh" <<< "$call2" && fail "(2) headerthing.sh (header-comment-only edit) must NEVER be flagged"
grep -q "^## scripts/herd$" <<< "$call2" || fail "(2) rollup body must have a '## scripts/herd' subsystem section ($call2)"
grep -q "^## scripts/herd/backends$" <<< "$call2" || fail "(2) rollup body must have a '## scripts/herd/backends' subsystem section ($call2)"
grep -q "^## docs$" <<< "$call2" && fail "(2) there is no drifted file under docs/ — no such section should appear"
grep -q "103" <<< "$call2" || fail "(2) the filed evidence must quote PR 103 ($call2)"
grep -q "104" <<< "$call2" || fail "(2) the filed evidence must quote PR 104 ($call2)"
[ -n "$(ls "$TREES/.herd/gardener/cooldown"/*.stamp 2>/dev/null)" ] || fail "(2) a filed rollup must stamp cooldown for each included file"
pass
echo "PASS (2) rollup: one scribe call per run covering ALL genuine drift grouped by subsystem; doc/capabilities.tsv/generated-doc/header-only exclusions all hold"

# ── Case 3: zero findings — nothing new since the last cursor ────────────────────────────────────────
out3="$(run run 2>&1)"
grep -q "zero findings" <<< "$out3" || fail "(3) a run with no new merges must report zero findings ($out3)"
[ "$(scribe_calls)" -eq 1 ] || fail "(3) a zero-finding run must not call scribe again (got $(scribe_calls))"
pass
echo "PASS (3) zero-finding path: no new merges → 'zero findings', cursor advances, no scribe call"

# ── Case 4: cooldown — the SAME file drifts again while its cooldown is still armed → detected, SKIPPED,
#    and excluded from rollup MEMBERSHIP (no scribe call at all if it's the only candidate) ────────────
journal_merge 110 "$SHA_E"
out4="$(run run 2>&1)"
grep -q "in its filing cooldown" <<< "$out4" || fail "(4) a recurring drift still under cooldown must say so ($out4)"
[ "$(scribe_calls)" -eq 1 ] || fail "(4) a cooldown-skipped finding must NOT trigger a scribe call (got $(scribe_calls))"
pass
echo "PASS (4) cooldown: the same file drifting again inside its cooldown window is detected but not re-filed, and does not trigger an otherwise-empty rollup"

# ── Case 5: cooldown expiry — advance past the window, the SAME file drifts a third time → re-filed via
#    a fresh (single-file) rollup ──────────────────────────────────────────────────────────────────────
export HERD_GARDENER_NOW="$((NOW + 200))"
journal_merge 111 "$SHA_F"
out5="$(run run 2>&1)"
grep -q "filed a rollup drift finding covering 1 file(s)" <<< "$out5" || fail "(5) once the cooldown expires, a recurring drift must be re-filed via a fresh rollup ($out5)"
[ "$(scribe_calls)" -eq 2 ] || fail "(5) cooldown expiry must produce a SECOND scribe call (got $(scribe_calls))"
pass
echo "PASS (5) cooldown expiry: once the window elapses, a standing drift is re-filed"

# ── Case 6: --dry-run previews without filing, stamping cooldown, or advancing the cursor ────────────
SHA_G="$(mkcommit scripts/herd/thirdthing.sh)"
journal_merge 112 "$SHA_G"
cursor_before="$(cat "$TREES/.herd/gardener/cursor")"
out6="$(run run --dry-run 2>&1)"
grep -q '\[dry-run\] would file' <<< "$out6" || fail "(6) --dry-run must preview the new thirdthing.sh drift ($out6)"
[ "$(scribe_calls)" -eq 2 ] || fail "(6) --dry-run must NEVER call scribe (got $(scribe_calls))"
[ "$(cat "$TREES/.herd/gardener/cursor")" = "$cursor_before" ] || fail "(6) --dry-run must NOT advance the cursor"
# A REAL run right after must still see (and now actually file) the SAME delta --dry-run only previewed.
out6b="$(run run 2>&1)"
grep -q "filed a rollup drift finding covering 1 file(s)" <<< "$out6b" || fail "(6) the real run after --dry-run must still file the previewed finding ($out6b)"
grep -q "thirdthing.sh" <<< "$(last_call)" || fail "(6) the real run's rollup must name thirdthing.sh ($(last_call))"
[ "$(scribe_calls)" -eq 3 ] || fail "(6) the real run after --dry-run must call scribe (got $(scribe_calls))"
pass
echo "PASS (6) --dry-run: previews without filing/cooldown/cursor side effects; the delta is still there for the next real run"

# ── Case 7: per-run cap — three NEW distinct drifted files, cap=2 → only 2 filed in this run's rollup,
#    the body says so LOUDLY, the 3rd is neither filed nor cooldown-stamped, and the cursor is HELD BACK
#    so the very next run (even at the same cap) sees the whole window again — already-filed files skip
#    via cooldown, the previously-truncated one gets filed fresh. ──────────────────────────────────────
journal_merge 113 "$SHA_CAP1"
journal_merge 114 "$SHA_CAP2"
journal_merge 115 "$SHA_CAP3"
cursor_before7="$(cat "$TREES/.herd/gardener/cursor")"
out7="$(HERD_GARDENER_MAX_FINDINGS=2 run run 2>&1)"
grep -q "filed a rollup drift finding covering 2 file(s)" <<< "$out7" || fail "(7) a capped run must still file the in-cap findings ($out7)"
grep -q "1 more truncated by the per-run cap" <<< "$out7" || fail "(7) a capped run must say how many were truncated ($out7)"
grep -q "cursor NOT advanced" <<< "$out7" || fail "(7) a capped run must hold the cursor back ($out7)"
[ "$(cat "$TREES/.herd/gardener/cursor")" = "$cursor_before7" ] || fail "(7) a capped run's cursor must be UNCHANGED, not just unequal to size"
[ "$(scribe_calls)" -eq 4 ] || fail "(7) a capped run must still make exactly one scribe call (got $(scribe_calls))"
call7="$(last_call)"
grep -q "TRUNCATED" <<< "$call7" || fail "(7) the filed rollup body must say TRUNCATED, never a silent drop ($call7)"
filed_count7=0
grep -q "cap1.sh" <<< "$call7" && filed_count7=$((filed_count7+1))
grep -q "cap2.sh" <<< "$call7" && filed_count7=$((filed_count7+1))
grep -q "cap3.sh" <<< "$call7" && filed_count7=$((filed_count7+1))
[ "$filed_count7" -eq 2 ] || fail "(7) exactly 2 of the 3 candidates must appear in the capped rollup body (got $filed_count7): $call7"
out7b="$(HERD_GARDENER_MAX_FINDINGS=2 run run 2>&1)"
grep -q "in its filing cooldown" <<< "$out7b" || fail "(7b) the rescan must skip the already-filed 2 via cooldown ($out7b)"
grep -q "filed a rollup drift finding covering 1 file(s)" <<< "$out7b" || fail "(7b) the rescan must file the previously-truncated file fresh ($out7b)"
[ "$(scribe_calls)" -eq 5 ] || fail "(7b) the rescan must make exactly one more scribe call (got $(scribe_calls))"
pass
echo "PASS (7) per-run cap: truncation is loud and honest, the cursor holds back, and a rescan finishes the job without re-filing already-handled findings"

# ── Case 8: cursor re-baseline — a corrupt or rotated/oversized stored cursor NEVER triggers a full
#    history replay ("archaeology"); it re-baselines at the CURRENT journal EOF exactly like an absent
#    cursor. Fully independent config/state dir/journal — HERD_CONFIG_FILE's WORKTREES_DIR= line is a
#    plain assignment, sourced unconditionally by herd-config.sh, so a bare `WORKTREES_DIR=... run run`
#    env override would be clobbered right back to $TREES; a dedicated config file is required. ───────
T8="$T/state8"; TREES8="$T8/trees"; mkdir -p "$TREES8"
JOURNAL8="$TREES8/journal.jsonl"
cat > "$T8/config" <<EOF
PROJECT_ROOT="$PROJ"
WORKSPACE_NAME="gardenertest8"
SCRIBE_BACKEND="file"
BACKLOG_FILE="BACKLOG.md"
WORKTREES_DIR="$TREES8"
EOF
run8(){ HERD_CONFIG_FILE="$T8/config" JOURNAL_FILE="$JOURNAL8" bash "$GARD" "$@"; }
printf '{"ts":"x","event":"merge","pr":900,"sha":"%s","slug":"pre-existing","method":"squash","reason":"gates_passed"}\n' "$SHA_A" > "$JOURNAL8"
mkdir -p "$TREES8/.herd/gardener"
echo "not-a-number" > "$TREES8/.herd/gardener/cursor"
size8a_pre="$(wc -c < "$JOURNAL8" | tr -cd '0-9')"   # snapshot BEFORE the run — the run's own
                                                       # journal_append(gardener_run) grows the journal
out8a="$(run8 run 2>&1)"
grep -q "FIRST RUN" <<< "$out8a" || fail "(8a) a CORRUPT cursor must re-baseline like a first run, never replay ($out8a)"
[ "$(cat "$TREES8/.herd/gardener/cursor")" = "$size8a_pre" ] \
  || fail "(8a) a corrupt cursor must re-baseline at the journal EOF as of the run's START, not archaeology from 0 (got $(cat "$TREES8/.herd/gardener/cursor"), expected $size8a_pre)"

printf '999999\n' > "$TREES8/.herd/gardener/cursor"
printf '{"ts":"x","event":"merge","pr":901,"sha":"%s","slug":"another","method":"squash","reason":"gates_passed"}\n' "$SHA_D" >> "$JOURNAL8"
size8b_pre="$(wc -c < "$JOURNAL8" | tr -cd '0-9')"
out8b="$(run8 run 2>&1)"
grep -q "FIRST RUN" <<< "$out8b" || fail "(8b) a ROTATED/oversized cursor (larger than the journal) must re-baseline, never replay from 0 ($out8b)"
[ "$(cat "$TREES8/.herd/gardener/cursor")" = "$size8b_pre" ] \
  || fail "(8b) a rotated cursor must re-baseline at the journal EOF as of the run's START, not offset 0 (got $(cat "$TREES8/.herd/gardener/cursor"), expected $size8b_pre)"
pass
echo "PASS (8) cursor re-baseline: a corrupt or rotated/oversized cursor always pins at the current EOF, never replaying history as archaeology"

echo
echo "ALL PASS ($PASS checks) — maintenance gardener: off-gate, first-run baseline, one-rollup-per-run with full exclusion set (doc/capabilities.tsv/generated-docs/header-only), zero-finding path, cooldown + expiry, dry-run, honest per-run cap with cursor hold-back, corrupt/rotated cursor re-baseline."
