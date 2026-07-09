#!/usr/bin/env bash
# test-changelog.sh — hermetic tests for journal-driven CHANGELOG + release-tag helper
# (scripts/herd/changelog.sh / `herd changelog`, HERD-256). Covers:
#   (1) generate from a synthetic journal of merge events emits the expected Keep-a-Changelog
#       bullets under ## [Unreleased], grouped by conventional-commit type — DETERMINISTIC
#   (2) subjects come from HERD_CHANGELOG_SUBJECTS (test seam) and/or journal title/subject fields
#   (3) generate is idempotent (second run is a no-op / byte-identical)
#   (4) --since YYYY-MM-DD excludes older merges
#   (5) tag --no-tag promotes [Unreleased] → [ver] - date and leaves a fresh empty Unreleased
#   (6) duplicate merge events for the same PR are deduped (first chronologically wins)
#   (7) `herd changelog` CLI dispatches to the same script
#
# Fully hermetic: writes only under a mktemp dir (fixture project + journal + subject map).
# Never touches the live watcher, real HOME journal, or network.
# Run:  bash tests/test-changelog.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
CL_SH="$REPO/scripts/herd/changelog.sh"
HERD_BIN="$REPO/bin/herd"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { printf 'FAIL: '; printf "$@" >&2; echo >&2; exit 1; }
ok()   { pass=$((pass+1)); }

[ -f "$CL_SH" ]    || fail "changelog.sh not found at $CL_SH"
[ -f "$HERD_BIN" ] || fail "herd not found at $HERD_BIN"
command -v python3 >/dev/null 2>&1 || fail "python3 required"
command -v git >/dev/null 2>&1 || fail "git required"

# ── fixture project ──
PROJ="$T/proj"; TREES="$T/trees"
mkdir -p "$PROJ/.herd" "$TREES/.herd"
# A real git repo so `git tag` / subject lookup paths are valid (subjects come from the map).
git -C "$PROJ" init -q
git -C "$PROJ" config user.email t@t.t
git -C "$PROJ" config user.name t
( cd "$PROJ" && git commit -q --allow-empty -m init )

cat > "$PROJ/.herd/config" <<CFG
PROJECT_ROOT="$PROJ"
WORKTREES_DIR="$TREES"
WORKSPACE_NAME="cltest"
CFG

# Synthetic journal: 3 merges (feat, fix, docs) + a duplicate merge for PR 42 + one old merge
# that --since should drop. Also a non-merge event that must be ignored.
cat > "$TREES/.herd/journal.jsonl" <<'JNL'
{"ts":"2026-06-01T10:00:00Z","event":"merge","pr":10,"slug":"ancient","sha":"aaa","method":"--squash","reason":"gates_passed"}
{"ts":"2026-07-02T10:00:00Z","event":"merge","pr":42,"slug":"add-widget","sha":"abc123","method":"--squash","reason":"gates_passed"}
{"ts":"2026-07-02T10:00:01Z","event":"verdict_recorded","pr":42,"value":"APPROVE","source":"reviewer"}
{"ts":"2026-07-02T11:00:00Z","event":"merge","pr":43,"slug":"fix-npe","sha":"def456","method":"--squash","reason":"gates_passed"}
{"ts":"2026-07-02T12:00:00Z","event":"merge","pr":44,"slug":"docs-readme","sha":"ghi789","method":"--squash","reason":"gates_passed","title":"docs: document the widget (#44)"}
{"ts":"2026-07-02T13:00:00Z","event":"merge","pr":42,"slug":"add-widget","sha":"abc123","method":"--squash","reason":"gates_passed"}
JNL

# Subject map for PRs without a journal title (test seam — no network, no git object needed).
MAP="$T/subjects.tsv"
cat > "$MAP" <<'MAP'
10	chore: ancient pre-window work
42	feat: add the widget
43	fix: null-pointer on empty input
MAP
export HERD_CHANGELOG_SUBJECTS="$MAP"
export HERMETIC_TEST=1
export JOURNAL_FILE="$TREES/.herd/journal.jsonl"
export HERD_CHANGELOG_ROOT="$PROJ"
export PROJECT_ROOT="$PROJ"
export WORKTREES_DIR="$TREES"

CL_OUT="$PROJ/CHANGELOG.md"

run_cl() {
  # shellcheck disable=SC2086
  ( cd "$PROJ" && \
      HERD_CHANGELOG_ROOT="$PROJ" \
      PROJECT_ROOT="$PROJ" \
      WORKTREES_DIR="$TREES" \
      JOURNAL_FILE="$JOURNAL_FILE" \
      HERD_CHANGELOG_SUBJECTS="$MAP" \
      HERMETIC_TEST=1 \
      bash "$CL_SH" "$@" )
}

# ── (1) generate emits expected entries deterministically ──
out="$(run_cl generate --file "$CL_OUT" --since 2026-07-01 2>&1)" || fail "generate failed: %s" "$out"
[ -f "$CL_OUT" ] || fail "generate did not write %s" "$CL_OUT"
ok

body="$(cat "$CL_OUT")"
printf '%s\n' "$body" | grep -qE '^# Changelog'              || fail "(1) missing H1\n%s" "$body"
printf '%s\n' "$body" | grep -qE '^## \[Unreleased\]'        || fail "(1) missing [Unreleased]\n%s" "$body"
printf '%s\n' "$body" | grep -qE '^### Features'             || fail "(1) missing Features section\n%s" "$body"
printf '%s\n' "$body" | grep -qE '^- feat: add the widget \(#42\)' \
  || fail "(1) missing feat bullet for #42\n%s" "$body"
printf '%s\n' "$body" | grep -qE '^### Fixes'                || fail "(1) missing Fixes section\n%s" "$body"
printf '%s\n' "$body" | grep -qE '^- fix: null-pointer on empty input \(#43\)' \
  || fail "(1) missing fix bullet for #43\n%s" "$body"
printf '%s\n' "$body" | grep -qE '^### Documentation'        || fail "(1) missing Documentation section\n%s" "$body"
printf '%s\n' "$body" | grep -qE '^- docs: document the widget \(#44\)' \
  || fail "(1) missing docs bullet for #44 (journal title)\n%s" "$body"
# Ancient PR 10 must be excluded by --since 2026-07-01
printf '%s\n' "$body" | grep -qE '#10' && fail "(1) PR #10 should be excluded by --since\n%s" "$body" || true
ok

# ── (2) determinism: stdout body is byte-stable across two runs ──
a="$(run_cl generate --stdout --since 2026-07-01 2>/dev/null)"
b="$(run_cl generate --stdout --since 2026-07-01 2>/dev/null)"
[ "$a" = "$b" ] || fail "(2) generate --stdout not deterministic\n---a---\n%s\n---b---\n%s" "$a" "$b"
ok

# ── (3) idempotent file write ──
cp "$CL_OUT" "$T/before.md"
out="$(run_cl generate --file "$CL_OUT" --since 2026-07-01 2>&1)" || fail "second generate failed: %s" "$out"
diff -q "$T/before.md" "$CL_OUT" >/dev/null || fail "(3) second generate rewrote CHANGELOG (not idempotent)"
printf '%s\n' "$out" | grep -qiE 'up to date|wrote' || fail "(3) unexpected second-run message: %s" "$out"
ok

# ── (4) --since future date → empty Unreleased placeholder ──
out="$(run_cl generate --stdout --since 2099-01-01 2>/dev/null)"
printf '%s\n' "$out" | grep -qE 'No merges in scope' || fail "(4) expected empty-scope note\n%s" "$out"
printf '%s\n' "$out" | grep -qE '^- feat:' && fail "(4) future --since should have no bullets\n%s" "$out" || true
ok

# ── (5) tag --no-tag promotes Unreleased ──
# Re-seed a known Unreleased first.
run_cl generate --file "$CL_OUT" --since 2026-07-01 >/dev/null
out="$(run_cl tag 0.2.0 --file "$CL_OUT" --date 2026-07-09 --no-tag 2>&1)" || fail "tag failed: %s" "$out"
body="$(cat "$CL_OUT")"
printf '%s\n' "$body" | grep -qE '^## \[0\.2\.0\] - 2026-07-09' \
  || fail "(5) missing versioned heading\n%s" "$body"
# Fresh Unreleased present and above the versioned section
python3 - "$CL_OUT" <<'PY' || fail "(5) Unreleased must precede versioned section"
import sys
text = open(sys.argv[1], encoding="utf-8").read().splitlines()
u = next(i for i,l in enumerate(text) if l.startswith("## [Unreleased]"))
v = next(i for i,l in enumerate(text) if l.startswith("## [0.2.0]"))
assert u < v, (u, v)
# versioned section should still carry the feat bullet
assert any("feat: add the widget (#42)" in l for l in text[v:]), text[v:v+20]
# fresh Unreleased should NOT still list the feat as unreleased content above the version heading
assert not any("feat: add the widget (#42)" in l for l in text[u:v]), text[u:v]
PY
ok

# ── (6) dedupe: PR 42 appears exactly once in a full generate (no --since → includes #10) ──
# Wipe and regenerate all merges.
rm -f "$CL_OUT"
run_cl generate --file "$CL_OUT" --since 2026-01-01 >/dev/null
n42="$(grep -cE '\(#42\)' "$CL_OUT" || true)"
[ "$n42" = "1" ] || fail "(6) PR #42 should appear exactly once, got %s\n%s" "$n42" "$(cat "$CL_OUT")"
printf '%s\n' "$(cat "$CL_OUT")" | grep -qE 'ancient pre-window work \(#10\)' \
  || fail "(6) PR #10 should be present with full window\n%s" "$(cat "$CL_OUT")"
ok

# ── (7) CLI dispatch: herd changelog generate --stdout ──
cli_out="$(
  cd "$PROJ" && \
    HERD_CHANGELOG_ROOT="$PROJ" \
    PROJECT_ROOT="$PROJ" \
    WORKTREES_DIR="$TREES" \
    JOURNAL_FILE="$JOURNAL_FILE" \
    HERD_CHANGELOG_SUBJECTS="$MAP" \
    HERMETIC_TEST=1 \
    HERD_NONINTERACTIVE=1 \
    bash "$HERD_BIN" changelog generate --stdout --since 2026-07-01 2>/dev/null
)" || fail "(7) herd changelog CLI failed"
printf '%s\n' "$cli_out" | grep -qE 'feat: add the widget \(#42\)' \
  || fail "(7) CLI output missing expected bullet\n%s" "$cli_out"
ok

echo "ALL PASS ($pass assertions)"
