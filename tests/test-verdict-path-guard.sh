#!/usr/bin/env bash
# test-verdict-path-guard.sh — HERD-360: a reviewer VERDICT string must never flow into a filesystem
# call. A severed review prints 'REVIEW: INFRA-FAIL — review severed (SIGTERM/SIGPIPE) before a verdict'
# to stdout; a caller that once captured that stdout into a path-typed variable (JOURNAL_FILE /
# WORKTREES_DIR) sent it straight into journal.sh's `mkdir -p`, growing a stray dir tree in the shared
# checkout (split at the 'SIGTERM/SIGPIPE' slash, with a TMPDIR-shaped suffix appended). This proves the
# SHARED path-use seam now REFUSES a verdict-shaped path on BOTH engine seats (bash journal.sh + python
# LiveJournal) — no filesystem path is ever created from the verdict text — and that a real severed
# herd-review.sh run still yields INFRA-FAIL (retry semantics) while creating no such debris.
#
# Asserts:
#   (A) bash journal.sh: a verdict-shaped JOURNAL_FILE (the exact severed verdict, mkdir-debris shape,
#       and an embedded-newline variant) creates NO directory from the verdict text; the leak is
#       recorded as ONE loud infra_event at a safe fallback; a CLEAN path is byte-identical (unchanged).
#   (B) python LiveJournal: a verdict-shaped path is refused at resolve + append (no os.makedirs), the
#       reject infra_event lands at a safe fallback, and a clean override is honoured unchanged.
#   (C) end-to-end: a real herd-review.sh SEVERED mid-flight (SIGTERM) emits REVIEW: INFRA-FAIL and
#       leaves NO verdict-shaped directory behind. Skipped where the env cannot background+signal.
#
# Fully hermetic: temp dirs only, no network/model/panes.
# Run:  bash tests/test-verdict-path-guard.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
JOURNAL_SH="$ROOT/scripts/herd/journal.sh"
REVIEW="$ROOT/scripts/herd/herd-review.sh"
PYSRC="$ROOT/pysrc"

T="$(mktemp -d)"; trap 'rm -rf "$T"; kill "${REV_PID:-}" 2>/dev/null || true' EXIT
pass=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ pass=$((pass+1)); }

[ -f "$JOURNAL_SH" ] || fail "journal.sh not found at $JOURNAL_SH"
command -v python3 >/dev/null 2>&1 || fail "python3 required"

# The exact string _severed -> _emit_verdict prints (scripts/herd/herd-review.sh).
VERDICT='REVIEW: INFRA-FAIL — review severed (SIGTERM/SIGPIPE) before a verdict'

################################################################################
# (A) bash journal.sh — the path-use seam refuses a verdict-shaped path.
################################################################################
# Reject file is keyed to THIS process's pid (deterministic across the append subshells).
REJECT="${TMPDIR:-/tmp}/herd-journal-verdict-reject-$$.jsonl"
rm -f "$REJECT" 2>/dev/null || true

# shellcheck source=/dev/null
. "$JOURNAL_SH" || fail "sourcing journal.sh failed"

for fn in _journal_path_is_verdict _journal_reject_verdict_path _journal_file journal_append; do
  type "$fn" >/dev/null 2>&1 || fail "(A) $fn not defined after sourcing journal.sh"
done

# The predicate itself: verdict prefix and embedded newline are rejected; a real path is not.
_journal_path_is_verdict "$VERDICT"                 || fail "(A) verdict prefix must be flagged"
_journal_path_is_verdict "$VERDICT/x/y"             || fail "(A) verdict-prefixed path must be flagged"
_journal_path_is_verdict "$(printf 'a\nb')"         || fail "(A) embedded-newline path must be flagged"
_journal_path_is_verdict "$T/.herd/journal.jsonl"   && fail "(A) a real journal path must NOT be flagged"
ok

# The mkdir-debris shape: <verdict><mktemp-d>/j-<pr>, run from a clean CWD so any stray tree is visible.
CWD="$T/cwd"; mkdir -p "$CWD"
TMPD="$(mktemp -d)"                       # the absolute TMPDIR-shaped suffix the leak concatenated
BAD_PATH="${VERDICT}${TMPD}/j-312"        # exactly the 2026-07-11 debris shape (relative → lands at CWD)
( cd "$CWD" && JOURNAL_FILE="$BAD_PATH" journal_append review_dispatched pr 312 sha deadbeef )
# NO directory may have been created from the verdict text anywhere under the clean CWD.
[ -z "$(find "$CWD" -depth 1 -name 'REVIEW:*' 2>/dev/null)" ] \
  || fail "(A) a verdict-shaped JOURNAL_FILE created a stray dir tree: $(find "$CWD" -name 'REVIEW:*')"
[ ! -e "${VERDICT}" ] || fail "(A) verdict dir created at repo/CWD root"
# The leak must be recorded LOUDLY at the safe fallback, never dropped silently.
[ -s "$REJECT" ] || fail "(A) no reject infra_event was journaled to the safe fallback ($REJECT)"
grep -q '"event":"infra_event"' "$REJECT"                          || fail "(A) reject row is not an infra_event"
grep -q '"component":"journal"' "$REJECT"                          || fail "(A) reject row missing component=journal"
grep -q 'verdict-shaped journal path rejected' "$REJECT"           || fail "(A) reject row missing the reason"
ok

# Embedded-newline variant → same protection (no path created, still redirected safely).
NL_PATH="$(printf '%s/leg\nnope' "$TMPD")"
( cd "$CWD" && JOURNAL_FILE="$NL_PATH" journal_append review_dispatched pr 313 sha cafe )
[ -z "$(find "$CWD" -mindepth 1 2>/dev/null)" ] || fail "(A) embedded-newline path created a stray entry under CWD"
ok

# BYTE-IDENTICAL WHEN CLEAN: a normal JOURNAL_FILE journals exactly as before, no reject, no debris.
CLEAN="$T/clean.jsonl"
JOURNAL_FILE="$CLEAN" journal_append review_dispatched pr 400 sha feed01
[ -s "$CLEAN" ] || fail "(A) a clean JOURNAL_FILE must journal the event"
grep -q '"pr":400' "$CLEAN" || fail "(A) clean journal missing the event payload"
grep -q 'verdict-shaped journal path rejected' "$CLEAN" && fail "(A) a clean path must NOT emit a reject row"
ok
echo "PASS (A) bash journal.sh refuses a verdict-shaped path; clean path byte-identical"

################################################################################
# (B) python LiveJournal — mirror the guard on the python seat.
################################################################################
PYCWD="$T/pycwd"; mkdir -p "$PYCWD"
PY_OUT="$(cd "$PYCWD" && VERDICT="$VERDICT" PYSRC="$PYSRC" PYTMP="$T/pytmp" python3 - <<'PY'
import os, sys
sys.path.insert(0, os.environ["PYSRC"])
os.environ["TMPDIR"] = os.environ["PYTMP"]
os.makedirs(os.environ["PYTMP"], exist_ok=True)
from herd.live_runtime import LiveJournal, _is_verdict_shaped_path

verdict = os.environ["VERDICT"]
bad = verdict + "/var/folders/x/T/tmp.AAAA/j-312"

assert _is_verdict_shaped_path(verdict), "verdict prefix must be flagged"
assert _is_verdict_shaped_path("a\nb"), "embedded newline must be flagged"
assert not _is_verdict_shaped_path("/tmp/.herd/journal.jsonl"), "real path must not be flagged"

# resolve_live_path DROPS a verdict-shaped override (falls through to the derived path).
os.environ["JOURNAL_FILE"] = bad
os.environ["WORKTREES_DIR"] = os.path.join(os.environ["PYTMP"], "trees")
resolved = LiveJournal.resolve_live_path()
assert resolved and not _is_verdict_shaped_path(resolved), "resolve must not return a verdict-shaped path: %r" % resolved

# append REFUSES a verdict-shaped path directly — no os.makedirs of the verdict tree.
LiveJournal(bad).append("review_dispatched", "pr", "312")
# Nothing created under the clean CWD from the verdict text.
stray = [n for n in os.listdir(".") if n.startswith("REVIEW:")]
assert not stray, "python append created a stray dir: %r" % stray

# The reject infra_event landed at the safe fallback.
rej = os.path.join(os.environ["PYTMP"], "herd-journal-verdict-reject-%d.jsonl" % os.getpid())
assert os.path.exists(rej), "no python reject fallback written"
body = open(rej).read()
assert '"event":"infra_event"' in body and '"component":"journal"' in body, "python reject row malformed: %s" % body

# A CLEAN override is honoured unchanged.
clean = os.path.join(os.environ["PYTMP"], "clean.jsonl")
os.environ["JOURNAL_FILE"] = clean
assert LiveJournal.resolve_live_path() == clean, "clean override must pass through"
LiveJournal(clean).append("review_dispatched", "pr", "400")
assert '"pr":400' in open(clean).read(), "clean python journal missing payload"
print("OK")
PY
)" || fail "(B) python guard assertions raised: $PY_OUT"
[ "$PY_OUT" = "OK" ] || fail "(B) python guard did not report OK: $PY_OUT"
[ -z "$(find "$PYCWD" -name 'REVIEW:*' 2>/dev/null)" ] || fail "(B) python left a stray verdict dir under CWD"
ok
echo "PASS (B) python LiveJournal refuses a verdict-shaped path; clean override byte-identical"

################################################################################
# (C) end-to-end: a real SEVERED herd-review.sh → INFRA-FAIL, no verdict-shaped debris.
################################################################################
if [ ! -f "$REVIEW" ]; then
  echo "SKIP (C) herd-review.sh not present"
else
  SBIN="$T/bin"; mkdir -p "$SBIN"
  # A reviewer runtime that BLOCKS (sleeps) so the gate is mid-flight when we sever it.
  cat > "$SBIN/claude" <<'STUB'
#!/usr/bin/env bash
sleep 60
STUB
  chmod +x "$SBIN/claude"
  for c in gh git herdr; do printf '#!/usr/bin/env bash\nexit 0\n' > "$SBIN/$c"; chmod +x "$SBIN/$c"; done

  ECWD="$T/ecwd"; mkdir -p "$ECWD"
  RES="$T/review-result-500"
  rm -f "$RES"
  (
    cd "$ECWD" || exit 1
    exec env PATH="$SBIN:$PATH" HERD_NO_PANE=1 HERD_DRIVER=headless \
      WORKTREES_DIR="$T/trees" HERD_CONFIG_FILE="$T/no-such-config" \
      JOURNAL_FILE="$T/e2e-journal.jsonl" HERD_REVIEW_MODEL="fallback-model" \
      HERD_REVIEW_RESULT_FILE="$RES" \
      bash "$REVIEW" 500 slug-500
  ) >/dev/null 2>&1 &
  REV_PID=$!

  # Wait until the gate is actually running its (sleeping) reviewer, then sever it with SIGTERM.
  severed=0
  for _i in $(seq 1 50); do
    kill -0 "$REV_PID" 2>/dev/null || break
    if pgrep -P "$REV_PID" >/dev/null 2>&1 || pgrep -f 'herd-review-gate-500' >/dev/null 2>&1; then
      sleep 0.5
      # Signal the whole gate chain (the re-exec'd argv0 + the sleeping child).
      pkill -TERM -f 'herd-review-gate-500' 2>/dev/null || true
      kill -TERM "$REV_PID" 2>/dev/null || true
      severed=1
      break
    fi
    sleep 0.2
  done

  if [ "$severed" = "0" ]; then
    kill -TERM "$REV_PID" 2>/dev/null || true
    echo "SKIP (C) env could not observe the reviewer mid-flight"
  else
    # Collect the INFRA-FAIL the _severed trap must write to the result file.
    got=""
    for _i in $(seq 1 40); do
      [ -f "$RES" ] && { got="$(cat "$RES" 2>/dev/null)"; [ -n "$got" ] && break; }
      sleep 0.25
    done
    { wait "$REV_PID"; } 2>/dev/null || true; REV_PID=""
    if [ -z "$got" ]; then
      echo "SKIP (C) severed gate wrote no result file in this env"
    else
      printf '%s' "$got" | grep -q '^REVIEW: INFRA-FAIL' \
        || fail "(C) severed review must emit INFRA-FAIL, got: '$got'"
      # And critically: NO verdict-shaped directory anywhere the gate ran.
      [ -z "$(find "$ECWD" -name 'REVIEW:*' 2>/dev/null)" ] \
        || fail "(C) severed gate left a verdict-shaped dir: $(find "$ECWD" -name 'REVIEW:*')"
      ok
      echo "PASS (C) severed herd-review.sh → INFRA-FAIL, no verdict-shaped debris"
    fi
  fi
fi

echo "ALL PASS ($pass checks) — test-verdict-path-guard.sh"
