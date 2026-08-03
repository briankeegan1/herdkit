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
{"ts":"2026-07-10T00:00:09Z","event":"verdict_recorded","pr":"43","value":"BLOCK","source":"reviewer","sha":"aabbccdd","reason":"rule: R | why: W | location: a.py:3"}
{"ts":"2026-07-10T00:00:10Z","event":"verdict_recorded","pr":"44","value":"BLOCK","source":"reviewer","sha":"aabbccdd"}
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

# HERD-473: a BLOCK's recorded reason is RENDERED by `herd why` — by BOTH readers identically (the
# parity assertions above already prove that), and a reason-less row renders exactly as it did before
# the field existed, so a legacy journal reads the same as it always has.
[[ "$(run_herd 1 why 43)" == *"BLOCK (reviewer) · sha aabbccdd · rule: R | why: W | location: a.py:3"* ]] \
  || fail "why 43: the recorded BLOCK reason was not rendered"
assert_parity "why 44 (reason-less BLOCK)" why 44
[[ "$(run_herd 1 why 44)" == *"BLOCK (reviewer) · sha aabbccdd"* ]] \
  || fail "why 44: a reason-less verdict did not render"
[[ "$(run_herd 1 why 44)" == *"sha aabbccdd ·"* ]] \
  && fail "why 44: a reason-less verdict grew a trailing separator"

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
for fix in healthy watcher-down dup-detected handoff long-branch notes-unacked notes-no-age; do
  assert_status_parity "$fix"
done

# HERD-492 — the unacked-builder-notes line. Parity alone cannot prove this: deleting the render from
# BOTH formatters would keep them identical and green. So assert the CONTENT on each path separately
# (that is the mutation proof — drop either render and exactly one of these four fails), and assert
# the SILENT-AT-ZERO contract on a fixture with no NOTES record (a snapshot from before this change).
for eng in 1 0; do
  notes_out="$(run_status "$eng" notes-unacked)"
  [[ "$notes_out" == *"NOTES"*"3 unacked"*"(newest: feat-beta 12m)"* ]] \
    || { printf '%s\n' "$notes_out" >&2; fail "status notes-unacked (engine=$eng): missing the 'N unacked (newest: <slug> <age>)' line"; }
  # Fail-soft age: an uncomputable age renders the slug alone, never a dangling separator.
  noage_out="$(run_status "$eng" notes-no-age)"
  [[ "$noage_out" == *"1 unacked"*"(newest: feat-gamma)"* ]] \
    || { printf '%s\n' "$noage_out" >&2; fail "status notes-no-age (engine=$eng): empty age must render the slug alone"; }
  # Zero notes ⇒ no NOTES record ⇒ NO line at all (byte-identical to before HERD-492).
  [[ "$(run_status "$eng" healthy)" != *"NOTES"* ]] \
    || fail "status healthy (engine=$eng): a snapshot with no NOTES record must print no NOTES line"
done
ok

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

# ── (7) herd why — the ×N block fold on a NOISY journal (HERD-459) ──────────────────────────────────
# GH #573: a PR parked on one cached verdict re-journaled its whole INTAKE→…→BLOCKED chain every ~6s
# tick, so `herd why` was screens of identical three-line blocks. The reader folds a consecutive run of
# identical blocks (timestamps ignored for the comparison, carried in the note) into ONE rendering plus
# a ×N line — which fixes readability for journals ALREADY written this way, before the write-side
# guard existed. Appended AFTER every section above so no assertion there sees these rows.
{
  for t in 33 38 43 48 53; do
    printf '{"ts":"2026-07-31T03:54:%sZ","event":"live_state","pr":"55","sha":"75068de0","trigger":"dispatch_health","state_from":"INTAKE","state_to":"HEALTH"}\n' "$t"
    printf '{"ts":"2026-07-31T03:54:%sZ","event":"live_state","pr":"55","sha":"75068de0","trigger":"health_clean","state_from":"HEALTH","state_to":"REVIEW"}\n' "$t"
    printf '{"ts":"2026-07-31T03:54:%sZ","event":"live_state","pr":"55","sha":"75068de0","trigger":"review_block","state_from":"REVIEW","state_to":"BLOCKED"}\n' "$t"
  done
  # …then a genuinely NEW state (a refix bounce landed): never folded into the run above.
  printf '{"ts":"2026-07-31T03:55:00Z","event":"refix_bounce","pr":"55","sha":"75068de0","round":"1","agent_status_before":"idle","rule":"review","location":""}\n'
} >> "$TREES/.herd/journal.jsonl"

assert_parity "why 55 (noisy)" why 55
noisy="$(run_herd 1 why 55)"
# The header still counts every RAW event — the fold is a rendering, never a lie about the record.
[[ "$noisy" == *"gate history (16 events)"* ]] || fail "why 55: header must count all 16 raw events"
[[ "$noisy" == *"× 5"* || "$noisy" == *"×5  (identical 3-event block repeated, through 2026-07-31T03:54:53Z)"* ]] \
  || { printf '%s\n' "$noisy" >&2; fail "why 55: expected a ×5 3-event-block fold through the last ts"; }
# Exactly 3 live_state lines survive (one block), not 15 — plus the header, the fold note and the bounce.
[ "$(printf '%s\n' "$noisy" | grep -c 'live_state')" = 3 ] \
  || { printf '%s\n' "$noisy" >&2; fail "why 55: expected exactly 3 rendered live_state lines"; }
[ "$(printf '%s\n' "$noisy" | grep -c 'auto-refix bounce')" = 1 ] \
  || fail "why 55: the distinct trailing event must survive the fold"
ok

# NON-VACUOUS: the same reader on a NON-repeating history renders every row and emits NO fold note —
# so the fold cannot be a blanket truncation.
[[ "$(run_herd 1 why 42)" != *"identical"* ]] || fail "why 42: a non-repeating history must never fold"
[ "$(run_herd 1 why 42 | grep -c .)" = 8 ] || fail "why 42: expected the header + 7 unfolded rows"
ok

echo "ALL PASS ($pass checks)"
