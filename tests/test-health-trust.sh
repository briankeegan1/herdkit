#!/usr/bin/env bash
# test-health-trust.sh — hermetic tests for SHA-MATCHED BUILDER-LOCAL HEALTH TRUST (HERD-531).
#
# suite-deps: scripts/herd/health-trust.sh scripts/herd/healthcheck.sh scripts/herd/agent-watch.sh
#
# The health gate is the pipeline's dominant cost (~350 hermetic tests, 20-60 min per suite) and it is
# paid TWICE for the same commit: once by the builder's pre-PR heavy run, once by the watcher. This
# proves the trust seam that removes the second payment WITHOUT ever weakening the gate:
#
#   (1)  LEVER OFF (the HEALTH_TRUST_BUILDER=off default) is a HARD no-op on BOTH sides — no record is
#        written into the shared pool, and no record is read. An unrecognized value reads OFF.
#   (2)  LEVER ON, a CLEAN heavy record for the EXACT sha from a CLEAN tree at that worktree → TRUSTED
#        (and the printed token is the record's provenance).
#   (3)  STALE SHA — a record for a DIFFERENT commit never trusts the current one.
#   (4)  NON-CLEAN OUTCOME (CODEERROR, and the tolerated-but-noted DATAENV) → not trusted.
#   (5)  NON-HEAVY PROFILE — a light record proves nothing about the full suite.
#   (6)  provenance=watcher → not trusted: trust must always trace back to a real builder-local heavy
#        suite, never to another trusted (light) run. This is what stops trust compounding on itself.
#   (7)  DIRTY TREE at record time → not trusted (the sha alone does not describe what actually ran).
#   (8)  WORKTREE MISMATCH → not trusted.
#   (9)  RECORD OLDER THAN THE COMMIT (the "record older than the sha's push" case) and an
#        UNRESOLVABLE commit → not trusted.
#   (10) MALFORMED / TRUNCATED record → not trusted.
#   (11) WRITER: the real scripts/herd/healthcheck.sh heavy profile authors a builder-local record on a
#        clean run, records CODEERROR on a red one, records NOTHING under --oneline or --light (neither
#        may ever author evidence a heavy re-run could be skipped on), and honors
#        HERD_HEALTH_PROVENANCE=watcher — the stamp agent-watch.sh puts on its OWN runs.
#   (12) BYTE-IDENTICAL OFF end-to-end: the same healthcheck.sh run with the lever off produces
#        byte-for-byte identical output and exit status, and leaves the shared pool untouched.
#   (13) WATCHER PASSTHROUGH: agent-watch.sh's _health_worker forwards its optional <profile> argument
#        to healthcheck.sh (so a trusted dispatch really runs --light) and stamps every run
#        HERD_HEALTH_PROVENANCE=watcher; with no profile the argv is byte-identical to before.
#   (14) THE GATE DECISION: _healthcheck_gate itself dispatches a trusted candidate as a light smoke —
#        journaling health_trusted provenance=builder-local, labelling the console row honestly, and
#        really passing --light through to healthcheck.sh — while a candidate with NO record produces
#        the byte-identical pre-change dispatch (unprofiled argv, no health_trusted line).
#
# Fully hermetic: throwaway git fixtures + temp dirs, a STUB project health command, NO herdr, gh,
# network or model. Run:  bash tests/test-health-trust.sh
# No `set -e`: several checks assert non-zero returns explicitly.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LIB="$ROOT/scripts/herd/health-trust.sh"
HC="$ROOT/scripts/herd/healthcheck.sh"
WATCH="$ROOT/scripts/herd/agent-watch.sh"

for f in "$LIB" "$HC" "$WATCH"; do
  [ -f "$f" ] || { echo "FAIL: missing required file: $f" >&2; exit 1; }
done
command -v git >/dev/null 2>&1 || { echo "FAIL: git required" >&2; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ PASS=$((PASS+1)); echo "PASS $1"; }

# shellcheck source=/dev/null
. "$LIB"

TREES="$T/trees"; mkdir -p "$TREES"

# ── a throwaway git worktree the records describe ─────────────────────────────────────────────────
WT="$T/wt"; mkdir -p "$WT"
git -C "$WT" init -q
printf 'v1\n' > "$WT/file.txt"
git -C "$WT" add -A >/dev/null 2>&1
git -C "$WT" -c user.email=t@t -c user.name=t commit -qm one >/dev/null 2>&1
SHA="$(git -C "$WT" rev-parse HEAD)"
[ -n "$SHA" ] || fail "fixture worktree has no HEAD sha"
# The physical path — the library normalizes both sides through `pwd -P`, so the record it writes
# carries this form (on macOS a /tmp fixture resolves under /private/tmp).
WTP="$(cd "$WT" && pwd -P)"

rec_file() { printf '%s' "$TREES/.health-provenance-$1"; }
# plant <sha> <worktree> <profile> <outcome> <duration> <provenance> <tree_state> <epoch>
plant() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" > "$(rec_file "$1")"
}
NOW="$(date +%s)"

# ── (1) LEVER OFF is a hard no-op on both sides ────────────────────────────────────────────────────
unset HEALTH_TRUST_BUILDER
herd_health_trust_on && fail "(1) HEALTH_TRUST_BUILDER must default to OFF (ship-dormant)"
herd_health_trust_write "$TREES" "$SHA" "$WT" heavy CLEAN 42 builder-local
[ ! -e "$(rec_file "$SHA")" ] || fail "(1) lever off wrote a provenance record into the shared pool"
herd_health_trust_check "$TREES" "$SHA" "$WT" >/dev/null && fail "(1) lever off must never trust"
[ "$HERD_HEALTH_TRUST_REASON" = "lever off" ] || fail "(1) off must say why: got '$HERD_HEALTH_TRUST_REASON'"
# An unrecognized value reads OFF — a typo can never arm a path that skips the authoritative suite.
HEALTH_TRUST_BUILDER=maybe herd_health_trust_on && fail "(1) an unknown HEALTH_TRUST_BUILDER must read off"
HEALTH_TRUST_BUILDER=ON  herd_health_trust_on || fail "(1) 'ON' (any case) must read on"
ok "(1) lever off is a hard no-op (no record written, nothing trusted); a typo reads off"

export HEALTH_TRUST_BUILDER=on

# ── (2) the happy path: a clean heavy record for the exact sha, clean tree, same worktree ──────────
herd_health_trust_write "$TREES" "$SHA" "$WT" heavy CLEAN 1234 builder-local
[ -f "$(rec_file "$SHA")" ] || fail "(2) lever on did not write the provenance record"
IFS=$'\t' read -r R_SHA R_WT R_PROF R_OUT R_DUR R_PROV R_STATE R_EPOCH < "$(rec_file "$SHA")"
[ "$R_SHA"   = "$SHA" ]          || fail "(2) record sha wrong: $R_SHA"
[ "$R_WT"    = "$WTP" ]          || fail "(2) record worktree wrong: $R_WT (want $WTP)"
[ "$R_PROF"  = "heavy" ]         || fail "(2) record profile wrong: $R_PROF"
[ "$R_OUT"   = "CLEAN" ]         || fail "(2) record outcome wrong: $R_OUT"
[ "$R_DUR"   = "1234" ]          || fail "(2) record duration wrong: $R_DUR"
[ "$R_PROV"  = "builder-local" ] || fail "(2) record provenance wrong: $R_PROV"
[ "$R_STATE" = "clean" ]         || fail "(2) a committed, unmodified tree must record tree_state=clean"
case "$R_EPOCH" in ''|*[!0-9]*) fail "(2) record epoch must be numeric: '$R_EPOCH'" ;; esac
GOT="$(herd_health_trust_check "$TREES" "$SHA" "$WT")" \
  || fail "(2) a clean heavy record for this exact sha must be TRUSTED ($HERD_HEALTH_TRUST_REASON)"
[ "$GOT" = "builder-local" ] || fail "(2) check must print the record's provenance, got '$GOT'"
ok "(2) a CLEAN heavy record for the exact sha from a clean tree at this worktree is TRUSTED"

# ── (3) stale sha: a record for another commit never trusts the current one ────────────────────────
printf 'v2\n' > "$WT/file.txt"
git -C "$WT" add -A >/dev/null 2>&1
git -C "$WT" -c user.email=t@t -c user.name=t commit -qm two >/dev/null 2>&1
SHA2="$(git -C "$WT" rev-parse HEAD)"
[ "$SHA2" != "$SHA" ] || fail "(3) fixture did not advance the head sha"
herd_health_trust_check "$TREES" "$SHA2" "$WT" >/dev/null \
  && fail "(3) a record for the PREVIOUS sha must never trust the new head"
[ "$HERD_HEALTH_TRUST_REASON" = "no record for sha" ] \
  || fail "(3) unexpected reason: '$HERD_HEALTH_TRUST_REASON'"
# …and a record whose BODY names a different sha than its own filename is corrupt, not merely stale.
plant "$SHA2" "$WTP" heavy CLEAN 10 builder-local clean "$NOW"
sed -i.bak "s/^$SHA2/deadbeef/" "$(rec_file "$SHA2")" && rm -f "$(rec_file "$SHA2").bak"
herd_health_trust_check "$TREES" "$SHA2" "$WT" >/dev/null \
  && fail "(3) a record whose body sha disagrees with its filename must be refused"
[ "$HERD_HEALTH_TRUST_REASON" = "stale sha in record" ] \
  || fail "(3) unexpected reason: '$HERD_HEALTH_TRUST_REASON'"
ok "(3) a stale sha (no record, or a record naming another commit) forces the full re-run"

# ── (4)-(10) every other disqualifier is a full re-run ─────────────────────────────────────────────
# Each row plants ONE record differing in exactly one field from the trusted shape of (2).
#   label | profile | outcome | provenance | tree_state | epoch-offset | worktree | expected reason
try_reject() {
  local label="$1" prof="$2" out="$3" prov="$4" state="$5" epoch="$6" wt="$7" want="$8"
  plant "$SHA2" "$wt" "$prof" "$out" 7 "$prov" "$state" "$epoch"
  if herd_health_trust_check "$TREES" "$SHA2" "$WT" >/dev/null; then
    fail "($label) must NOT be trusted"
  fi
  case "$HERD_HEALTH_TRUST_REASON" in
    *"$want"*) : ;;
    *) fail "($label) wrong reason: '$HERD_HEALTH_TRUST_REASON' (want *$want*)" ;;
  esac
}
try_reject 4a heavy CODEERROR builder-local clean "$NOW" "$WTP" "outcome=CODEERROR"
try_reject 4b heavy DATAENV   builder-local clean "$NOW" "$WTP" "outcome=DATAENV"
ok "(4) a non-CLEAN outcome (CODEERROR, and the tolerated DATAENV) is never trusted"

try_reject 5 light CLEAN builder-local clean "$NOW" "$WTP" "profile=light"
ok "(5) a LIGHT record proves nothing about the full suite and is never trusted"

try_reject 6 heavy CLEAN watcher clean "$NOW" "$WTP" "provenance=watcher"
ok "(6) a record the WATCHER authored is never trusted (trust cannot compound on itself)"

try_reject 7 heavy CLEAN builder-local dirty "$NOW" "$WTP" "tree_state=dirty"
ok "(7) a record written from a DIRTY tree is never trusted"

try_reject 8 heavy CLEAN builder-local clean "$NOW" "$WTP/elsewhere" "record worktree"
ok "(8) a record from a DIFFERENT worktree is never trusted"

# (9) a record written BEFORE the commit existed cannot have tested it.
COMMIT_TS="$(git -C "$WT" show -s --format=%ct "$SHA2")"
try_reject 9a heavy CLEAN builder-local clean "$((COMMIT_TS - 60))" "$WTP" "predates the commit"
# …and a commit this worktree cannot resolve at all is refused rather than guessed at.
plant "$SHA2" "$WTP" heavy CLEAN 7 builder-local clean "$NOW"
NOGIT="$T/not-a-repo"; mkdir -p "$NOGIT"
herd_health_trust_check "$TREES" "$SHA2" "$NOGIT" >/dev/null \
  && fail "(9b) an unresolvable commit must not be trusted"
ok "(9) a record older than its commit — or a commit that cannot be dated — forces the full re-run"

# (10) a truncated/garbled record proves nothing.
printf 'only\ttwo\n' > "$(rec_file "$SHA2")"
herd_health_trust_check "$TREES" "$SHA2" "$WT" >/dev/null && fail "(10) a truncated record must be refused"
[ "$HERD_HEALTH_TRUST_REASON" = "malformed record" ] \
  || fail "(10) unexpected reason: '$HERD_HEALTH_TRUST_REASON'"
: > "$(rec_file "$SHA2")"
herd_health_trust_check "$TREES" "$SHA2" "$WT" >/dev/null && fail "(10) an EMPTY record must be refused"
ok "(10) a truncated / empty / garbled record is refused, never guessed at"

# ── (11) the WRITER: the real healthcheck.sh heavy profile ────────────────────────────────────────
rm -f "$TREES"/.health-provenance-* 2>/dev/null || true
# Stub project health command: prints the fixture's canned output, exits its canned rc.
STUB="$T/hc-stub.sh"
cat > "$STUB" <<'STUB'
#!/usr/bin/env bash
d="$1"
[ -f "$d/.out" ] && cat "$d/.out"
exit "$(cat "$d/.rc" 2>/dev/null || echo 0)"
STUB
chmod +x "$STUB"
printf '✅ stub clean\n' > "$WT/.out"
printf '0\n' > "$WT/.rc"

run_hc() {   # run_hc <trust> [extra healthcheck args…] — sets OUT + RC
  local trust="$1"; shift
  OUT="$(env HERD_CONFIG_FILE="$T/no-such-config" \
             HEALTHCHECK_CMD="$STUB" \
             HEALTHCHECK_HEAVY_GLOB="" \
             DEFAULT_BRANCH="no-such-ref-for-tests" \
             BASELINE_AWARE_GATE=off \
             WORKTREES_DIR="$TREES" \
             HEALTH_TRUST_BUILDER="$trust" \
             "$@" bash "$HC" "$WT" --heavy 2>&1)"; RC=$?
}

run_hc on
[ "$RC" -eq 0 ] || fail "(11) the stub-clean heavy run should exit 0, got $RC — $OUT"
REC="$(rec_file "$SHA2")"
[ -f "$REC" ] || fail "(11) a clean heavy run must author a provenance record"
IFS=$'\t' read -r R_SHA R_WT R_PROF R_OUT R_DUR R_PROV R_STATE R_EPOCH < "$REC"
[ "$R_SHA"  = "$SHA2" ]        || fail "(11) record sha should be the worktree HEAD, got $R_SHA"
[ "$R_PROF" = "heavy" ]        || fail "(11) record profile should be heavy, got $R_PROF"
[ "$R_OUT"  = "CLEAN" ]        || fail "(11) record outcome should be CLEAN, got $R_OUT"
[ "$R_PROV" = "builder-local" ] || fail "(11) an unstamped run must record provenance=builder-local, got $R_PROV"
case "$R_DUR" in ''|*[!0-9]*) fail "(11) duration must be numeric, got '$R_DUR'" ;; esac
# The fixture carries uncommitted .out/.rc scratch files, so the tree is legitimately DIRTY here —
# which is exactly the state the reader must refuse. Proving the WRITER records it honestly is the
# point: a builder that ran the suite over uncommitted edits never earns a skip.
[ "$R_STATE" = "dirty" ] || fail "(11) a tree with uncommitted files must record tree_state=dirty, got $R_STATE"
herd_health_trust_check "$TREES" "$SHA2" "$WT" >/dev/null \
  && fail "(11) a dirty-tree record must not be trusted end-to-end"

# HERD_HEALTH_PROVENANCE=watcher — the stamp agent-watch.sh puts on its own runs.
rm -f "$REC"
run_hc on HERD_HEALTH_PROVENANCE=watcher
IFS=$'\t' read -r R_SHA R_WT R_PROF R_OUT R_DUR R_PROV R_STATE R_EPOCH < "$REC"
[ "$R_PROV" = "watcher" ] || fail "(11) HERD_HEALTH_PROVENANCE must be honored, got $R_PROV"

# A RED heavy run records CODEERROR (and so can never justify a skip).
rm -f "$REC"
printf 'not ok 1 boom\n' > "$WT/.out"; printf '1\n' > "$WT/.rc"
run_hc on
[ "$RC" -eq 1 ] || fail "(11) a stub code error should exit 1, got $RC"
IFS=$'\t' read -r R_SHA R_WT R_PROF R_OUT R_DUR R_PROV R_STATE R_EPOCH < "$REC"
[ "$R_OUT" = "CODEERROR" ] || fail "(11) a red heavy run must record CODEERROR, got $R_OUT"
printf '✅ stub clean\n' > "$WT/.out"; printf '0\n' > "$WT/.rc"

# --oneline (the status pane) and --light never author a record: neither may attest a heavy run.
rm -f "$TREES"/.health-provenance-* 2>/dev/null || true
env HERD_CONFIG_FILE="$T/no-such-config" HEALTHCHECK_CMD="$STUB" HEALTHCHECK_HEAVY_GLOB="" \
    DEFAULT_BRANCH="no-such-ref-for-tests" BASELINE_AWARE_GATE=off WORKTREES_DIR="$TREES" \
    HEALTH_TRUST_BUILDER=on bash "$HC" "$WT" --heavy --oneline >/dev/null 2>&1
[ -z "$(find "$TREES" -name '.health-provenance-*' 2>/dev/null)" ] \
  || fail "(11) --oneline must never author a provenance record"
env HERD_CONFIG_FILE="$T/no-such-config" HEALTHCHECK_CMD="$STUB" HEALTHCHECK_HEAVY_GLOB="" \
    DEFAULT_BRANCH="no-such-ref-for-tests" BASELINE_AWARE_GATE=off WORKTREES_DIR="$TREES" \
    HEALTH_TRUST_BUILDER=on bash "$HC" "$WT" --light >/dev/null 2>&1
[ -z "$(find "$TREES" -name '.health-provenance-*' 2>/dev/null)" ] \
  || fail "(11) the LIGHT profile must never author a provenance record"
ok "(11) healthcheck.sh authors an honest heavy record (sha/profile/outcome/duration/provenance/tree_state); --oneline and --light author none"

# ── (12) BYTE-IDENTICAL when off ───────────────────────────────────────────────────────────────────
rm -f "$TREES"/.health-provenance-* 2>/dev/null || true
run_hc off; OFF_OUT="$OUT"; OFF_RC="$RC"
[ -z "$(find "$TREES" -name '.health-provenance-*' 2>/dev/null)" ] \
  || fail "(12) lever off wrote into the shared worktree pool"
run_hc on;  ON_OUT="$OUT";  ON_RC="$RC"
[ "$OFF_RC" -eq "$ON_RC" ] || fail "(12) exit status differs off ($OFF_RC) vs on ($ON_RC)"
[ "$OFF_OUT" = "$ON_OUT" ] || fail "(12) healthcheck OUTPUT differs with the lever on:
--- off ---
$OFF_OUT
--- on ---
$ON_OUT"
ok "(12) with the lever off the gate output + exit are byte-identical and the shared pool is untouched"

# ── (13) WATCHER PASSTHROUGH: _health_worker forwards <profile> and stamps provenance=watcher ──────
# Source agent-watch.sh in lib mode and drive _health_worker against a healthcheck STUB that records
# its argv + the provenance stamp it was handed. This is what makes a TRUSTED dispatch actually run
# the light profile rather than merely journaling that it did.
ARGV_LOG="$T/argv.log"; : > "$ARGV_LOG"
HCSTUB="$T/hc-argv.sh"
cat > "$HCSTUB" <<'STUB'
#!/usr/bin/env bash
printf 'prov=%s argv=%s\n' "${HERD_HEALTH_PROVENANCE:-unset}" "$*" >> "$ARGV_LOG"
echo "✅ HEALTHCHECK CLEAN"
exit 0
STUB
chmod +x "$HCSTUB"
export ARGV_LOG

(
  export AGENT_WATCH_LIB=1
  export WORKTREES_DIR="$TREES"
  export JOURNAL_FILE="$T/journal.jsonl"; : > "$JOURNAL_FILE"
  export HERD_CONFIG_FILE="$T/no-such-config"
  # shellcheck source=/dev/null
  . "$WATCH" || { echo "SOURCE_FAILED"; exit 1; }
  TREES="$WORKTREES_DIR"; MAIN="$T/main"; mkdir -p "$MAIN"
  HERD_HEALTHCHECK_BIN="$HCSTUB"
  type _health_worker >/dev/null 2>&1 || { echo "NO_HEALTH_WORKER"; exit 1; }
  _health_worker "$WT" "$T/disp-full" "$T/log-full"
  _health_worker "$WT" "$T/disp-light" "$T/log-light" --light
) > "$T/lib.out" 2>&1 || fail "(13) lib-mode _health_worker drive failed: $(cat "$T/lib.out")"

grep -q "SOURCE_FAILED\|NO_HEALTH_WORKER" "$T/lib.out" \
  && fail "(13) agent-watch.sh lib mode did not expose _health_worker: $(cat "$T/lib.out")"
[ -f "$T/disp-full" ]  || fail "(13) the no-profile worker wrote no verdict"
[ -f "$T/disp-light" ] || fail "(13) the --light worker wrote no verdict"
grep -q '^CLEAN' "$T/disp-full"  || fail "(13) expected a CLEAN verdict from the stub"
grep -q '^CLEAN' "$T/disp-light" || fail "(13) expected a CLEAN verdict from the light stub"
# argv line 1 = the unprofiled dispatch (byte-identical to before this change: the worktree alone).
FIRST="$(sed -n '1p' "$ARGV_LOG")"
SECOND="$(sed -n '2p' "$ARGV_LOG")"
[ "$FIRST" = "prov=watcher argv=$WT" ] \
  || fail "(13) an unprofiled dispatch must pass ONLY the worktree and stamp provenance=watcher: '$FIRST'"
[ "$SECOND" = "prov=watcher argv=$WT --light" ] \
  || fail "(13) a trusted dispatch must forward --light to healthcheck.sh: '$SECOND'"
ok "(13) _health_worker forwards <profile> to healthcheck.sh and stamps every run provenance=watcher"

# ── (14) THE GATE DECISION: _healthcheck_gate dispatches a trusted candidate as a LIGHT smoke ──────
# (13) proved the worker forwards a profile; this proves the GATE actually chooses it — the journal
# line, the honest console row, and the real --light argv reaching healthcheck.sh — and that with NO
# record the same call is byte-identical to before (unprofiled argv, no health_trusted line).
GATE_OUT="$T/gate.out"
GBIN="$T/gbin"; mkdir -p "$GBIN"
printf '#!/usr/bin/env bash\nexit 0\n'            > "$GBIN/gh";    chmod +x "$GBIN/gh"
printf '#!/usr/bin/env bash\necho "{}"\nexit 0\n' > "$GBIN/herdr"; chmod +x "$GBIN/herdr"
GARGV="$T/gate-argv"; : > "$GARGV"
GSTUB="$T/gate-hc.sh"
cat > "$GSTUB" <<'STUB'
#!/usr/bin/env bash
printf 'argv=%s\n' "$*" >> "$GARGV"
echo "✅ HEALTHCHECK CLEAN"
exit 0
STUB
chmod +x "$GSTUB"
export GARGV

run_gate_probe() {   # run_gate_probe <sha> <expect-trusted 0|1> — drives one _healthcheck_gate dispatch
  ( export PATH="$GBIN:$PATH"
    export AGENT_WATCH_LIB=1
    export WORKTREES_DIR="$TREES"
    export JOURNAL_FILE="$T/gate-journal.jsonl"
    export HERD_CONFIG_FILE="$T/no-such-config"
    # shellcheck source=/dev/null
    . "$WATCH" || { echo "SOURCE_FAILED"; exit 1; }
    TREES="$WORKTREES_DIR"; MAIN="$T/gate-main"; mkdir -p "$MAIN"
    HERD_HEALTHCHECK_BIN="$GSTUB"
    declare -a DISPLAY; DISPLAY[0]=""
    _HC_RESULT=""
    _healthcheck_gate 77 slug77 "$WT" 0 "$1" >/dev/null 2>&1
    printf 'RESULT=%s\nROW=%s\n' "$_HC_RESULT" "${DISPLAY[0]}"
  ) > "$GATE_OUT" 2>&1
  local n=0
  while [ "$n" -lt 100 ] && [ ! -s "$GARGV" ]; do sleep 0.2; n=$((n + 1)); done
}

# 14a — a CLEAN builder-local record for this exact sha → light smoke + health_trusted.
rm -f "$TREES"/.health-provenance-* "$TREES"/.health-* 2>/dev/null || true
: > "$T/gate-journal.jsonl"
git -C "$WT" checkout -q -- . 2>/dev/null || true
rm -f "$WT/.out" "$WT/.rc"                                  # make the fixture tree genuinely clean
herd_health_trust_write "$TREES" "$SHA2" "$WT" heavy CLEAN 99 builder-local
herd_health_trust_check "$TREES" "$SHA2" "$WT" >/dev/null \
  || fail "(14a) fixture precondition: the record should be trusted ($HERD_HEALTH_TRUST_REASON)"
run_gate_probe "$SHA2"
grep -q 'RESULT=RUNNING' "$GATE_OUT" || fail "(14a) the gate should have dispatched a suite: $(cat "$GATE_OUT")"
grep -q 'light smoke' "$GATE_OUT" \
  || fail "(14a) the console row must name the trusted smoke honestly: $(cat "$GATE_OUT")"
grep -q '"event":"health_trusted"' "$T/gate-journal.jsonl" \
  || fail "(14a) a trusted dispatch must journal health_trusted"
grep -q '"provenance":"builder-local"' "$T/gate-journal.jsonl" \
  || fail "(14a) health_trusted must carry provenance=builder-local"
grep -q -- '--light' "$GARGV" \
  || fail "(14a) a trusted dispatch must actually run healthcheck.sh --light, got: $(cat "$GARGV")"

# 14b — no record → the pre-change behavior exactly: unprofiled argv, no health_trusted line.
rm -f "$TREES"/.health-provenance-* "$TREES"/.health-* 2>/dev/null || true
: > "$T/gate-journal.jsonl"; : > "$GARGV"
run_gate_probe "$SHA2"
grep -q '"event":"health_trusted"' "$T/gate-journal.jsonl" \
  && fail "(14b) an untrusted dispatch must NOT journal health_trusted"
grep -q -- '--light' "$GARGV" && fail "(14b) an untrusted dispatch must not run the light profile"
[ "$(cat "$GARGV")" = "argv=$WT" ] \
  || fail "(14b) an untrusted dispatch argv must be byte-identical to before: '$(cat "$GARGV")'"
ok "(14) the gate dispatches a trusted candidate as a --light smoke (journaled + labelled), and is byte-identical with no record"

echo
echo "ALL PASS ($PASS checks) — HERD-531 sha-matched builder-local trust: off is a hard no-op, only a"
echo "CLEAN heavy builder-local record of the EXACT sha from a CLEAN tree at the SAME worktree earns a"
echo "light smoke, and every other case falls back to the full re-run."
