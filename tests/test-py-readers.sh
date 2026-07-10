#!/usr/bin/env bash
# test-py-readers.sh — GOLDEN PARITY tests for the P1 Python engine port (HERD-302, EPIC HERD-300).
#
# The read-only journal readers `herd why` / `log` / `cost` now route through the stdlib `herd`
# package (pysrc/herd/*.py, invoked `python3 -m herd.<cmd>`), with a FAIL-SOFT fallback to the
# byte-identical inline `python3 -c` program each command keeps in bin/herd. This test proves the
# contract the port must hold: on identical journal fixtures, the PYTHON path (HERD_ENGINE_PY=1,
# default) is BYTE-FOR-BYTE identical to the BUILTIN path (HERD_ENGINE_PY=0) across every output
# mode — herd why <pr>, herd log / --pr N, herd cost / --pr N — and that a broken/absent package
# silently falls back to the builtin (never a red).
#
# Fully hermetic: a mktemp project with a fixture .herd/config + a fixture journal (live journal +
# one rotated archive). Drives the REAL bin/herd both ways and diffs. No real journal, watcher,
# panes, gh or HOME is touched. --tail is a live `tail -f` follow and is out of scope for a golden
# (its formatter is the same module, exercised by the log modes here).
# Run:  bash tests/test-py-readers.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
HERD_BIN="$REPO/bin/herd"

command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 required" >&2; exit 1; }
[ -x "$HERD_BIN" ] || { echo "FAIL: bin/herd not executable at $HERD_BIN" >&2; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

# ── fixture project: .herd/config pins WORKTREES_DIR so the journal path is deterministic ──
PROJ="$T/proj"; TREES="$T/proj-trees"
mkdir -p "$PROJ/.herd" "$TREES/.herd"
cat > "$PROJ/.herd/config" <<CFG
PROJECT_ROOT=$PROJ
WORKTREES_DIR=$TREES
WORKSPACE_NAME=fixtureproj
DEFAULT_BRANCH=origin/main
SCRIBE_BACKEND=file
CFG

# A rotated archive (older) + the live journal (newer). `herd why` aggregates across the boundary,
# so PR #42 has events in BOTH files — exercising the multi-file reader path.
cat > "$TREES/.herd/journal-20260709.jsonl" <<'JNL'
{"ts":"2026-07-09T23:59:58Z","event":"review_dispatched","pr":"42","sha":"0011223344556677","model":"opus","pid":"900"}
{"ts":"2026-07-09T23:59:59Z","event":"healthcheck_attempted","pr":"42","attempt":"1","result":"clean"}
JNL
cat > "$TREES/.herd/journal.jsonl" <<'JNL'
{"ts":"2026-07-10T00:00:01Z","event":"verdict_recorded","pr":"42","value":"PASS","source":"panel","sha":"0011223344556677"}
{"ts":"2026-07-10T00:00:02Z","event":"hold_applied","pr":"42","kind":"approve","sha":"0011223344556677"}
{"ts":"2026-07-10T00:00:03Z","event":"cost","pr":"42","component":"builder","model":"claude-opus-4-8","usd":"1.2345","in":"100","out":"200","cache_read":"5","cache_write":"6","msgs":"12"}
{"ts":"2026-07-10T00:00:04Z","event":"merge","pr":"42","sha":"0011223344556677","method":"squash","reason":"gate-green"}
{"ts":"2026-07-10T00:00:05Z","event":"cost","pr":"43","component":"review","model":"claude-sonnet-5","usd":"0.5000","in":"10","out":"20","cache_read":"0","cache_write":"0","msgs":"3"}
{"ts":"2026-07-10T00:00:06Z","event":"cost","pr":"43","component":"builder","model":"foreign-model?","usd":"0","in":"1","out":"2","cache_read":"0","cache_write":"0","msgs":"1","unpriced":"1"}
{"ts":"2026-07-10T00:00:07Z","event":"some_novel_event","pr":"42","alpha":"one","beta":"two"}
{"ts":"2026-07-10T00:00:08Z","event":"infra_event","pr":"","component":"watcher","exit_code":"0","stderr_tail":""}
JNL

# run_herd <engine-py 0|1> -- args...  → runs the real CLI in the fixture project, stdout+exit only.
run_herd() {
  local eng="$1"; shift
  ( cd "$PROJ" && HERD_ENGINE_PY="$eng" HERD_NONINTERACTIVE=1 NO_COLOR=1 \
      HERD_CONFIG_FILE="$PROJ/.herd/config" bash "$HERD_BIN" "$@" 2>/dev/null )
}

# assert_parity <label> -- args...  : python path (1) must byte-equal builtin path (0), same exit.
assert_parity() {
  local label="$1"; shift
  local out_py out_bash rc_py rc_bash
  out_py="$(run_herd 1 "$@")";  rc_py=$?
  out_bash="$(run_herd 0 "$@")"; rc_bash=$?
  [ "$rc_py" = "$rc_bash" ] || fail "$label: exit differs (py=$rc_py bash=$rc_bash)"
  [ "$out_py" = "$out_bash" ] || {
    echo "---- python ($label) ----" >&2; printf '%s\n' "$out_py" >&2
    echo "---- builtin ($label) ----" >&2; printf '%s\n' "$out_bash" >&2
    fail "$label: output differs between python and builtin readers"
  }
  ok
}

# ── (1) herd why <pr> — aggregates across the archive + live journal, chronological ──
assert_parity "why 42" why 42
[[ "$(run_herd 1 why 42)" == *"gate history (7 events)"* ]] || fail "why 42: unexpected event count"
assert_parity "why 43" why 43
assert_parity "why 999 (no events)" why 999

# ── (2) herd log — full stream, and --pr filter ──
assert_parity "log (all)"     log
assert_parity "log --pr 42"   log --pr 42
assert_parity "log --pr 43"   log --pr 43
assert_parity "log --pr 999"  log --pr 999   # filters to empty → both emit nothing, identically

# ── (3) herd cost — full rollup, and --pr drill-down ──
assert_parity "cost (rollup)" cost
[[ "$(run_herd 1 cost)" == *"unpriced"* ]] || fail "cost rollup: expected the unpriced flag line"
assert_parity "cost --pr 42"  cost --pr 42
assert_parity "cost --pr 43"  cost --pr 43
assert_parity "cost --pr 77"  cost --pr 77   # no cost events for this PR → friendly line, identical

# ── (4) FAIL-SOFT: a broken/absent package must silently fall back to the builtin (never a red) ──
# Point HERD_PYSRC at an empty tree (no `herd` package) so `import herd` fails → builtin path.
BROKEN="$T/broken"; mkdir -p "$BROKEN"
broke_out="$( cd "$PROJ" && HERD_ENGINE_PY=1 HERD_PYSRC="$BROKEN" NO_COLOR=1 \
    HERD_CONFIG_FILE="$PROJ/.herd/config" bash "$HERD_BIN" why 42 2>/dev/null )"
broke_rc=$?
[ "$broke_rc" = 0 ] || fail "fail-soft: broken package should still exit 0 (got $broke_rc)"
[ "$broke_out" = "$(run_herd 0 why 42)" ] || fail "fail-soft: broken-package output must equal the builtin"
ok

# A genuinely broken MODULE (imports as a package, but the submodule raises) must ALSO fall back — and
# emit the one-line stderr notice — while stdout stays byte-identical to the builtin.
BROKEN2="$T/broken2"; mkdir -p "$BROKEN2/herd"
: > "$BROKEN2/herd/__init__.py"
printf 'raise RuntimeError("boom")\n' > "$BROKEN2/herd/why.py"
b2_out="$( cd "$PROJ" && HERD_ENGINE_PY=1 HERD_PYSRC="$BROKEN2" NO_COLOR=1 \
    HERD_CONFIG_FILE="$PROJ/.herd/config" bash "$HERD_BIN" why 42 2>/dev/null )"
b2_err="$( cd "$PROJ" && HERD_ENGINE_PY=1 HERD_PYSRC="$BROKEN2" NO_COLOR=1 \
    HERD_CONFIG_FILE="$PROJ/.herd/config" bash "$HERD_BIN" why 42 2>&1 1>/dev/null )"
[ "$b2_out" = "$(run_herd 0 why 42)" ] || fail "fail-soft: broken-module output must equal the builtin"
[[ "$b2_err" == *"builtin fallback"* ]] || fail "fail-soft: expected a one-line stderr fallback notice"
ok

# ── (5) RAW BYTES: command substitution strips trailing newlines symmetrically, so also compare the
# unstripped byte streams on disk (cmp) for a representative mode of each reader — catches any
# trailing-newline drift the $(...) parity checks above would mask. ──
for mode in "why 42" "log --pr 42" "cost" "cost --pr 42"; do
  # shellcheck disable=SC2086
  run_herd 1 $mode > "$T/py.out"
  # shellcheck disable=SC2086
  run_herd 0 $mode > "$T/bash.out"
  cmp -s "$T/py.out" "$T/bash.out" || fail "raw bytes differ for '$mode' (trailing-newline drift?)"
  ok
done

echo "ALL PASS ($pass checks)"
