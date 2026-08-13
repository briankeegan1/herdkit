#!/usr/bin/env bash
# test-gardener.sh — hermetic test for the MAINTENANCE GARDENER (HERD-673, scripts/herd/gardener.sh).
# No herdr, no network, no real scribe drainer: a synthetic git repo stands in for PROJECT_ROOT (real
# commits, real shas, real `git diff-tree`), a synthetic journal carries fabricated `merge` events, and
# HERD_GARDENER_SCRIBE stubs the filing call so the sim can assert exactly what would have been filed —
# the same stub-injection pattern test-triggers.sh uses for HERD_TRIGGERS_SPAWN_CMD.
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

# ── fixture repo: real commits, real shas, so _gardener_files_for_sha's `git diff-tree` is exercised
#    for real rather than stubbed — only the JOURNAL's merge events are synthetic. ───────────────────
PROJ="$T/proj"; mkdir -p "$PROJ"
git -C "$PROJ" init -q
git -C "$PROJ" config user.email "gardener-test@example.invalid"
git -C "$PROJ" config user.name  "gardener-test"
mkdir -p "$PROJ/scripts/herd" "$PROJ/docs"
printf 'seed\n' > "$PROJ/README.md"
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
SHA_D="$(mkcommit scripts/herd/newthing.sh)"                       # same file as A → groups with it
SHA_E="$(mkcommit scripts/herd/newthing.sh)"                       # same file, later window → cooldown probe
SHA_F="$(mkcommit scripts/herd/newthing.sh)"                       # same file, after cooldown expiry
SHA_G="$(mkcommit scripts/herd/thirdthing.sh)"                     # a THIRD undocumented file, for --dry-run

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

# ── Case 2: real drift, grouped — SHA_A/SHA_D touch the SAME file; SHA_B (doc-only) and SHA_C
#    (surface+doc same merge) must NOT contribute. One run, one grouped finding, ONE scribe call. ─────
journal_noise
journal_merge 101 "$SHA_B"
journal_merge 102 "$SHA_C"
journal_merge 103 "$SHA_A"
journal_merge 104 "$SHA_D"
out2="$(run run 2>&1)"
grep -q "filed a drift finding for 'scripts/herd/newthing.sh'" <<< "$out2" || fail "(2) must file a finding for the drifted file ($out2)"
grep -q "other.sh" <<< "$out2" && fail "(2) other.sh (surface+doc in the same merge) must NEVER be flagged"
[ "$(scribe_calls)" -eq 1 ] || fail "(2) two merges touching the SAME undocumented file in one run must collapse into ONE scribe call (got $(scribe_calls))"
last_call="$(tail -n +"$(grep -n '^=== call ===$' "$SCRIBELOG" | tail -1 | cut -d: -f1)" "$SCRIBELOG")"
grep -q "103" <<< "$last_call" || fail "(2) the filed evidence must quote PR 103 ($last_call)"
grep -q "104" <<< "$last_call" || fail "(2) the filed evidence must quote PR 104 ($last_call)"
[ -n "$(ls "$TREES/.herd/gardener/cooldown"/*.stamp 2>/dev/null)" ] || fail "(2) a filed finding must stamp its cooldown"
pass
echo "PASS (2) dedup: two merges touching the same undocumented file in one run file ONE item quoting both PRs; doc-touching merges never flag"

# ── Case 3: zero findings — nothing new since the last cursor ────────────────────────────────────────
out3="$(run run 2>&1)"
grep -q "zero findings" <<< "$out3" || fail "(3) a run with no new merges must report zero findings ($out3)"
[ "$(scribe_calls)" -eq 1 ] || fail "(3) a zero-finding run must not call scribe again (got $(scribe_calls))"
pass
echo "PASS (3) zero-finding path: no new merges → 'zero findings', cursor advances, no scribe call"

# ── Case 4: cooldown — the SAME file drifts again while its cooldown is still armed → detected, SKIPPED
journal_merge 105 "$SHA_E"
out4="$(run run 2>&1)"
grep -q "in its filing cooldown" <<< "$out4" || fail "(4) a recurring drift still under cooldown must say so ($out4)"
[ "$(scribe_calls)" -eq 1 ] || fail "(4) a cooldown-skipped finding must NOT call scribe again (got $(scribe_calls))"
pass
echo "PASS (4) cooldown: the same file drifting again inside its cooldown window is detected but not re-filed"

# ── Case 5: cooldown expiry — advance past the window, the SAME file drifts a third time → re-filed ──
export HERD_GARDENER_NOW="$((NOW + 200))"
journal_merge 106 "$SHA_F"
out5="$(run run 2>&1)"
grep -q "filed a drift finding" <<< "$out5" || fail "(5) once the cooldown expires, a recurring drift must be re-filed ($out5)"
[ "$(scribe_calls)" -eq 2 ] || fail "(5) cooldown expiry must produce a SECOND scribe call (got $(scribe_calls))"
pass
echo "PASS (5) cooldown expiry: once the window elapses, a standing drift is re-filed"

# ── Case 6: --dry-run previews without filing, stamping cooldown, or advancing the cursor ────────────
journal_merge 107 "$SHA_G"
cursor_before="$(cat "$TREES/.herd/gardener/cursor")"
out6="$(run run --dry-run 2>&1)"
grep -q '\[dry-run\] would file' <<< "$out6" || fail "(6) --dry-run must preview the new thirdthing.sh drift ($out6)"
[ "$(scribe_calls)" -eq 2 ] || fail "(6) --dry-run must NEVER call scribe (got $(scribe_calls))"
[ "$(cat "$TREES/.herd/gardener/cursor")" = "$cursor_before" ] || fail "(6) --dry-run must NOT advance the cursor"
# A REAL run right after must still see (and now actually file) the SAME delta --dry-run only previewed.
out6b="$(run run 2>&1)"
grep -q "filed a drift finding for 'scripts/herd/thirdthing.sh'" <<< "$out6b" || fail "(6) the real run after --dry-run must still file the previewed finding ($out6b)"
[ "$(scribe_calls)" -eq 3 ] || fail "(6) the real run after --dry-run must call scribe (got $(scribe_calls))"
pass
echo "PASS (6) --dry-run: previews without filing/cooldown/cursor side effects; the delta is still there for the next real run"

echo
echo "ALL PASS ($PASS checks) — maintenance gardener: off-gate, first-run baseline, dedup-grouped filing, zero-finding path, cooldown + expiry, dry-run."
