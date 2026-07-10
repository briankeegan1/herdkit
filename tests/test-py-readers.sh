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
# HERD-307 (P1b) extends this to `herd status`, which is a LIVE-ENVIRONMENT snapshot (ps / gh /
# driver-seam / colours / timing dup-detect), not a journal reader — so it is ported via a
# bash-gathers/python-formats split (scripts/herd/status.sh's _status_gather emits ONE <US>-delimited
# snapshot; pysrc/herd/status.py and the bash _status_format_bash render it). Only the pure FORMAT
# stage can be golden-tested; the live-probe GATHER stage deliberately gets no golden. Section (6)
# drives the FORMAT stage BOTH ways on committed snapshot fixtures (tests/fixtures/status/*.snapshot)
# via the HERD_STATUS_SNAPSHOT_FILE seam — which skips gather — and cmp's byte-identical incl. exit
# codes, plus the same fail-soft contract.
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

# ── (6) herd status — bash-gathers/python-formats split (HERD-307, P1b) ──────────────────────────────
# Drive the FORMAT stage both ways on committed snapshot fixtures via the HERD_STATUS_SNAPSHOT_FILE
# seam (which skips every live probe / gather), and assert byte-identical output + exit code. The
# fixtures cover the representative states (healthy, watcher-down, dup-detected) plus handoff and a
# branch-name-overflow case, and one carries a real ANSI palette so the HERD_THEME colour seam is
# proven identical across both formatters. Live-probe (gather) paths get NO golden — that is the split.
STATUS_FIX="$REPO/tests/fixtures/status"
[ -d "$STATUS_FIX" ] || fail "status fixtures dir missing at $STATUS_FIX"

# run_status <engine 0|1> <fixture>  → real CLI, gather skipped by the seam, stdout+exit only. NO_COLOR
# is deliberately NOT set: colours ride the fixture's COLORS record, so both paths read the same bytes.
run_status() {
  local eng="$1" fix="$2"
  ( cd "$PROJ" && HERD_ENGINE_PY="$eng" HERD_NONINTERACTIVE=1 \
      HERD_STATUS_SNAPSHOT_FILE="$STATUS_FIX/$fix.snapshot" \
      HERD_CONFIG_FILE="$PROJ/.herd/config" bash "$HERD_BIN" status 2>/dev/null )
}
assert_status_parity() {
  local fix="$1" out_py out_bash rc_py rc_bash
  out_py="$(run_status 1 "$fix")";   rc_py=$?
  out_bash="$(run_status 0 "$fix")"; rc_bash=$?
  [ "$rc_py" = "$rc_bash" ] || fail "status $fix: exit differs (py=$rc_py bash=$rc_bash)"
  [ "$out_py" = "$out_bash" ] || {
    echo "---- python (status $fix) ----" >&2; printf '%s\n' "$out_py" >&2
    echo "---- builtin (status $fix) ----" >&2; printf '%s\n' "$out_bash" >&2
    fail "status $fix: output differs between python and bash formatters"
  }
  ok
}
for fix in healthy watcher-down dup-detected handoff long-branch; do
  assert_status_parity "$fix"
done

# Exit-code contract: an attention fixture must exit 1 (both paths), a healthy fixture 0.
run_status 1 dup-detected >/dev/null; [ "$?" = 1 ] || fail "status dup-detected: python path must exit 1 (attention)"
run_status 0 dup-detected >/dev/null; [ "$?" = 1 ] || fail "status dup-detected: bash path must exit 1 (attention)"
run_status 1 healthy      >/dev/null; [ "$?" = 0 ] || fail "status healthy: python path must exit 0"
ok

# FAIL-SOFT (absent package): an empty HERD_PYSRC tree → `import herd` fails → silent bash formatter,
# byte-identical to HERD_ENGINE_PY=0, and the attention exit code is preserved.
brokestat_out="$( cd "$PROJ" && HERD_ENGINE_PY=1 HERD_PYSRC="$BROKEN" \
    HERD_STATUS_SNAPSHOT_FILE="$STATUS_FIX/dup-detected.snapshot" \
    HERD_CONFIG_FILE="$PROJ/.herd/config" bash "$HERD_BIN" status 2>/dev/null )"
brokestat_rc=$?
[ "$brokestat_rc" = 1 ] || fail "status fail-soft: attention exit must survive the fallback (got $brokestat_rc)"
[ "$brokestat_out" = "$(run_status 0 dup-detected)" ] || fail "status fail-soft: absent-package output must equal the bash formatter"
ok

# FAIL-SOFT (broken module): the `herd` package imports but herd.status is missing (BROKEN2 has no
# status.py) → the python formatter emits nothing → fall back to bash AND print the one-line stderr
# notice, while stdout stays byte-identical to the bash formatter.
bs_out="$( cd "$PROJ" && HERD_ENGINE_PY=1 HERD_PYSRC="$BROKEN2" \
    HERD_STATUS_SNAPSHOT_FILE="$STATUS_FIX/healthy.snapshot" \
    HERD_CONFIG_FILE="$PROJ/.herd/config" bash "$HERD_BIN" status 2>/dev/null )"
bs_err="$( cd "$PROJ" && HERD_ENGINE_PY=1 HERD_PYSRC="$BROKEN2" \
    HERD_STATUS_SNAPSHOT_FILE="$STATUS_FIX/healthy.snapshot" \
    HERD_CONFIG_FILE="$PROJ/.herd/config" bash "$HERD_BIN" status 2>&1 1>/dev/null )"
[ "$bs_out" = "$(run_status 0 healthy)" ] || fail "status fail-soft: broken-module output must equal the bash formatter"
[[ "$bs_err" == *"builtin fallback"* ]] || fail "status fail-soft: expected a one-line stderr fallback notice"
ok

# RAW BYTES: cmp the unstripped byte streams for one attention + one healthy fixture (catches any
# trailing-newline drift the $(...) parity checks strip symmetrically).
for fix in dup-detected healthy; do
  run_status 1 "$fix" > "$T/py.out"
  run_status 0 "$fix" > "$T/bash.out"
  cmp -s "$T/py.out" "$T/bash.out" || fail "status raw bytes differ for '$fix' (trailing-newline drift?)"
  ok
done

echo "ALL PASS ($pass checks)"
