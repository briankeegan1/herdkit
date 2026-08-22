#!/usr/bin/env bash
# test-health-trust.sh — hermetic tests for SHA-MATCHED BUILDER-LOCAL HEALTH TRUST (HERD-531/560).
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
#   (4)  CODEERROR → not trusted. DATAENV with a companion log → trusted (merge-gate pass).
#   (5)  NON-HEAVY PROFILE — a light record proves nothing about the full suite.
#   (6)  provenance=watcher → not trusted: trust must always trace back to a real builder-local heavy
#        suite, never to another trusted (light) run. This is what stops trust compounding on itself.
#   (7)  DIRTY TREE at record time → not trusted (the sha alone does not describe what actually ran).
#   (8)  WORKTREE MISMATCH → not trusted.
#   (9)  RECORD OLDER THAN THE COMMIT (the "record older than the sha's push" case) and an
#        UNRESOLVABLE commit → not trusted.
#   (10) MALFORMED / TRUNCATED record → not trusted.
#   (11) WRITER: the real scripts/herd/healthcheck.sh heavy profile authors a builder-local FORMAT
#        VERSION 2 record (with a real log_digest + companion log) on a clean run, records CODEERROR
#        (digest "-", no companion log) on a red one, records NOTHING under --oneline or --light
#        (neither may ever author evidence a heavy re-run could be skipped on), and honors
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
#   (15) FORMAT VERSION 2 (HERD-560): a pre-hardening 8-field record — or one naming an unrecognized
#        future version — reads as ABSENT, never an error: a plain full re-run, same as no record.
#   (16) DIGEST (HERD-560): a CLEAN record is re-verified against its companion suite-log file on
#        every check. A tampered or missing log is never trusted, even when every other field matches.
#   (17) BOUNDED AGE (HERD-560): a record older than HEALTH_TRUST_MAX_AGE_SECS is refused regardless
#        of outcome; the 6h default does not false-flag a record written moments ago.
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
log_file() { printf '%s' "$TREES/.health-provenance-log-$1"; }
# plant <sha> <worktree> <profile> <outcome> <duration> <provenance> <tree_state> <epoch> [digest] [notes] [baseline-sha]
# Writes a FORMAT VERSION 2 record directly (bypassing herd_health_trust_write) so a test can shape
# every field independently. digest defaults to "-" (no log claimed) when omitted — the right shape
# for every disqualifier this file proves gets caught BEFORE the digest check ever runs.
plant() {
  if [ -n "${11:-}" ]; then
    printf '2\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "${9:--}" "${10:-}" "${11}" > "$(rec_file "$1")"
  else
    printf '2\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "${9:--}" > "$(rec_file "$1")"
  fi
}
# plant_old <sha> <worktree> <profile> <outcome> <duration> <provenance> <tree_state> <epoch>
# Writes a PRE-HERD-560 (8-field, no version, no digest) record — the exact shape the engine wrote
# before this hardening — to prove it now reads as ABSENT rather than half-parsed into false trust.
plant_old() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" > "$(rec_file "$1")"
}
NOW="$(date +%s)"

# ── (1) LEVER OFF is a hard no-op on both sides ────────────────────────────────────────────────────
unset HEALTH_TRUST_BUILDER
herd_health_trust_on && fail "(1) HEALTH_TRUST_BUILDER must default to OFF (ship-dormant)"
herd_health_trust_write "$TREES" "$SHA" "$WT" heavy CLEAN 42 builder-local "some log"
[ ! -e "$(rec_file "$SHA")" ] || fail "(1) lever off wrote a provenance record into the shared pool"
[ ! -e "$(log_file "$SHA")" ] || fail "(1) lever off wrote a companion suite log into the shared pool"
herd_health_trust_check "$TREES" "$SHA" "$WT" >/dev/null && fail "(1) lever off must never trust"
[ "$HERD_HEALTH_TRUST_REASON" = "lever off" ] || fail "(1) off must say why: got '$HERD_HEALTH_TRUST_REASON'"
# An unrecognized value reads OFF — a typo can never arm a path that skips the authoritative suite.
HEALTH_TRUST_BUILDER=maybe herd_health_trust_on && fail "(1) an unknown HEALTH_TRUST_BUILDER must read off"
HEALTH_TRUST_BUILDER=ON  herd_health_trust_on || fail "(1) 'ON' (any case) must read on"
ok "(1) lever off is a hard no-op (no record written, nothing trusted); a typo reads off"

export HEALTH_TRUST_BUILDER=on

# ── (2) the happy path: a clean heavy record for the exact sha, clean tree, same worktree ──────────
herd_health_trust_write "$TREES" "$SHA" "$WT" heavy CLEAN 1234 builder-local "the real suite log for $SHA"
[ -f "$(rec_file "$SHA")" ] || fail "(2) lever on did not write the provenance record"
[ -f "$(log_file "$SHA")" ] || fail "(2) a CLEAN record must write a companion suite log"
IFS=$'\t' read -r R_VER R_SHA R_WT R_PROF R_OUT R_DUR R_PROV R_STATE R_EPOCH R_DIGEST < "$(rec_file "$SHA")"
[ "$R_VER"   = "2" ]            || fail "(2) record version wrong: $R_VER"
[ "$R_SHA"   = "$SHA" ]          || fail "(2) record sha wrong: $R_SHA"
[ "$R_WT"    = "$WTP" ]          || fail "(2) record worktree wrong: $R_WT (want $WTP)"
[ "$R_PROF"  = "heavy" ]         || fail "(2) record profile wrong: $R_PROF"
[ "$R_OUT"   = "CLEAN" ]         || fail "(2) record outcome wrong: $R_OUT"
[ "$R_DUR"   = "1234" ]          || fail "(2) record duration wrong: $R_DUR"
[ "$R_PROV"  = "builder-local" ] || fail "(2) record provenance wrong: $R_PROV"
[ "$R_STATE" = "clean" ]         || fail "(2) a committed, unmodified tree must record tree_state=clean"
case "$R_EPOCH" in ''|*[!0-9]*) fail "(2) record epoch must be numeric: '$R_EPOCH'" ;; esac
[ -n "$R_DIGEST" ] && [ "$R_DIGEST" != "-" ] || fail "(2) a CLEAN record must carry a real log digest, got '$R_DIGEST'"
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
# Records below model a suite that ran after this commit existed.  Do not reuse NOW
# (captured before the commit): on a slow CI runner it can fall in the previous
# second and make the freshness guard mask the predicate each case is meant to prove.
FRESH_EPOCH="$(git -C "$WT" show -s --format=%ct "$SHA2")"
[ -n "$FRESH_EPOCH" ] || fail "(3) fixture cannot resolve the new commit timestamp"
# The DATAENV trust claim is meaningful only relative to a particular baseline. Keep a separate
# main checkout so this fixture can advance it without changing the candidate SHA/worktree.
BASE="$T/main"; git clone -q "$WT" "$BASE"
BASE_SHA="$(git -C "$BASE" rev-parse HEAD)"
herd_health_trust_check "$TREES" "$SHA2" "$WT" >/dev/null \
  && fail "(3) a record for the PREVIOUS sha must never trust the new head"
[ "$HERD_HEALTH_TRUST_REASON" = "no record for sha" ] \
  || fail "(3) unexpected reason: '$HERD_HEALTH_TRUST_REASON'"
# …and a record whose BODY names a different sha than its own filename is corrupt, not merely stale.
plant "$SHA2" "$WTP" heavy CLEAN 10 builder-local clean "$NOW"
TAB="$(printf '\t')"
sed -i.bak "s/^2${TAB}$SHA2/2${TAB}deadbeef/" "$(rec_file "$SHA2")" && rm -f "$(rec_file "$SHA2").bak"
herd_health_trust_check "$TREES" "$SHA2" "$WT" >/dev/null \
  && fail "(3) a record whose body sha disagrees with its filename must be refused"
[ "$HERD_HEALTH_TRUST_REASON" = "stale sha in record" ] \
  || fail "(3) unexpected reason: '$HERD_HEALTH_TRUST_REASON'"
ok "(3) a stale sha (no record, or a record naming another commit) forces the full re-run"

# ── (4)-(10) every other disqualifier is a full re-run ─────────────────────────────────────────────
# Each row plants ONE record differing in exactly one field from the trusted shape of (2). No digest
# is given (defaults "-") — every one of these is caught well before the digest check ever runs.
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
try_reject 4a heavy CODEERROR builder-local clean "$FRESH_EPOCH" "$WTP" "outcome=CODEERROR"
ok "(4) a CODEERROR outcome is never trusted"

# DATAENV is the merge-gate pass (code clean, tolerated notes). With a companion log it
# earns the same skip as CLEAN. Without a log it is still refused (fail-closed on digest).
rm -f "$TREES"/.health-provenance-* 2>/dev/null || true
herd_health_trust_write "$TREES" "$SHA2" "$WT" heavy DATAENV 12 builder-local \
  "DATAENV"$'\n'"notes: visreg — no baseline for hud_multires_design" \
  "visreg — no baseline for hud_multires_design" "$BASE_SHA"
[ -f "$(log_file "$SHA2")" ] || fail "(4) a DATAENV write must persist a companion suite log"
IFS=$'\t' read -r R_VER R_SHA R_WT R_PROF R_OUT R_DUR R_PROV R_STATE R_EPOCH R_DIGEST R_NOTES R_BASE \
  < "$(rec_file "$SHA2")"
[ "$R_OUT" = "DATAENV" ] || fail "(4) DATAENV write recorded outcome='$R_OUT'"
[ -n "$R_DIGEST" ] && [ "$R_DIGEST" != "-" ] || fail "(4) DATAENV write must hash the companion log"
[ "$R_BASE" = "$BASE_SHA" ] || fail "(4) DATAENV row must bind the baseline sha"
case "$R_NOTES" in
  *hud_multires_design*) ok "(4) DATAENV row records tolerated notes in field 11" ;;
  *) fail "(4) DATAENV notes field missing or empty: '$R_NOTES'" ;;
esac
GOT="$(herd_health_trust_check "$TREES" "$SHA2" "$WT" "$BASE")" \
  && [ "$GOT" = "builder-local" ] \
  && ok "(4) shared reader TRUSTS a DATAENV heavy record with companion log" \
  || fail "(4) DATAENV with companion log refused: $HERD_HEALTH_TRUST_REASON"
# Planted DATAENV with no log (the pre-policy shape) is still refused — on the digest,
# not on the outcome. Fail-closed: a DATAENV claim with nothing behind it is not evidence.
rm -f "$TREES"/.health-provenance-* 2>/dev/null || true
plant "$SHA2" "$WTP" heavy DATAENV 7 builder-local clean "$FRESH_EPOCH" "-" "-" "$BASE_SHA"
herd_health_trust_check "$TREES" "$SHA2" "$WT" "$BASE" >/dev/null && fail "(4b) DATAENV without a log must NOT be trusted"
[ "$HERD_HEALTH_TRUST_REASON" = "no suite log for record" ] \
  || fail "(4b) wrong reason: '$HERD_HEALTH_TRUST_REASON' (want no suite log)"
ok "(4) DATAENV without a companion log is refused (missing companion), not trusted"

# An unchanged baseline preserves a DATAENV trust claim; once main advances, the old inherited
# failure set is no longer evidence. The reader must force a fresh heavy suite before deciding
# whether that same failure is now introduced.
rm -f "$TREES"/.health-provenance-* 2>/dev/null || true
herd_health_trust_write "$TREES" "$SHA2" "$WT" heavy DATAENV 12 builder-local "inherited failure" "" "$BASE_SHA"
herd_health_trust_check "$TREES" "$SHA2" "$WT" "$BASE" >/dev/null \
  || fail "(4c) unchanged baseline must preserve valid DATAENV trust ($HERD_HEALTH_TRUST_REASON)"
git -C "$BASE" -c user.email=t@t -c user.name=t commit --allow-empty -qm baseline-advanced
herd_health_trust_check "$TREES" "$SHA2" "$WT" "$BASE" >/dev/null \
  && fail "(4c) a DATAENV record must not survive an advanced baseline"
[ "$HERD_HEALTH_TRUST_REASON" = "DATAENV baseline advanced" ] \
  || fail "(4c) wrong reason after baseline advance: '$HERD_HEALTH_TRUST_REASON'"
ok "(4) DATAENV trust is baseline-bound: unchanged baseline trusts; an advanced main forces heavy"

try_reject 5 light CLEAN builder-local clean "$FRESH_EPOCH" "$WTP" "profile=light"
ok "(5) a LIGHT record proves nothing about the full suite and is never trusted"

try_reject 6 heavy CLEAN watcher clean "$FRESH_EPOCH" "$WTP" "provenance=watcher"
ok "(6) a record the WATCHER authored is never trusted (trust cannot compound on itself)"

try_reject 7 heavy CLEAN builder-local dirty "$FRESH_EPOCH" "$WTP" "tree_state=dirty"
ok "(7) a record written from a DIRTY tree is never trusted"

try_reject 8 heavy CLEAN builder-local clean "$FRESH_EPOCH" "$WTP/elsewhere" "record worktree"
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
IFS=$'\t' read -r R_VER R_SHA R_WT R_PROF R_OUT R_DUR R_PROV R_STATE R_EPOCH R_DIGEST < "$REC"
[ "$R_VER"  = "2" ]           || fail "(11) record version should be 2, got $R_VER"
[ "$R_SHA"  = "$SHA2" ]        || fail "(11) record sha should be the worktree HEAD, got $R_SHA"
[ "$R_PROF" = "heavy" ]        || fail "(11) record profile should be heavy, got $R_PROF"
[ "$R_OUT"  = "CLEAN" ]        || fail "(11) record outcome should be CLEAN, got $R_OUT"
[ "$R_PROV" = "builder-local" ] || fail "(11) an unstamped run must record provenance=builder-local, got $R_PROV"
case "$R_DUR" in ''|*[!0-9]*) fail "(11) duration must be numeric, got '$R_DUR'" ;; esac
[ -n "$R_DIGEST" ] && [ "$R_DIGEST" != "-" ] || fail "(11) a CLEAN run must record a real log digest, got '$R_DIGEST'"
[ -f "$(log_file "$SHA2")" ] || fail "(11) a CLEAN run must write a companion suite log"
# The fixture carries uncommitted .out/.rc scratch files, so the tree is legitimately DIRTY here —
# which is exactly the state the reader must refuse. Proving the WRITER records it honestly is the
# point: a builder that ran the suite over uncommitted edits never earns a skip.
[ "$R_STATE" = "dirty" ] || fail "(11) a tree with uncommitted files must record tree_state=dirty, got $R_STATE"
herd_health_trust_check "$TREES" "$SHA2" "$WT" >/dev/null \
  && fail "(11) a dirty-tree record must not be trusted end-to-end"

# HERD_HEALTH_PROVENANCE=watcher — the stamp agent-watch.sh puts on its own runs.
rm -f "$REC" "$(log_file "$SHA2")"
run_hc on HERD_HEALTH_PROVENANCE=watcher
IFS=$'\t' read -r R_VER R_SHA R_WT R_PROF R_OUT R_DUR R_PROV R_STATE R_EPOCH R_DIGEST < "$REC"
[ "$R_PROV" = "watcher" ] || fail "(11) HERD_HEALTH_PROVENANCE must be honored, got $R_PROV"

# A RED heavy run records CODEERROR (and so can never justify a skip) — and authors NO companion log
# / a digest of "-": a non-clean outcome is never trusted regardless of digest, so hashing its log
# would prove nothing.
rm -f "$REC" "$(log_file "$SHA2")"
printf 'not ok 1 boom\n' > "$WT/.out"; printf '1\n' > "$WT/.rc"
run_hc on
[ "$RC" -eq 1 ] || fail "(11) a stub code error should exit 1, got $RC"
IFS=$'\t' read -r R_VER R_SHA R_WT R_PROF R_OUT R_DUR R_PROV R_STATE R_EPOCH R_DIGEST < "$REC"
[ "$R_OUT" = "CODEERROR" ] || fail "(11) a red heavy run must record CODEERROR, got $R_OUT"
[ "$R_DIGEST" = "-" ] || fail "(11) a red heavy run must record log_digest=-, got '$R_DIGEST'"
[ ! -f "$(log_file "$SHA2")" ] || fail "(11) a red heavy run must never write a companion suite log"
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
# --heavy with NO project health command DELEGATES to the light gate — it must not stamp a heavy
# record on a run that was only the syntax/lint pass.
env HERD_CONFIG_FILE="$T/no-such-config" HEALTHCHECK_CMD="" HEALTHCHECK_HEAVY_GLOB="" \
    DEFAULT_BRANCH="no-such-ref-for-tests" BASELINE_AWARE_GATE=off WORKTREES_DIR="$TREES" \
    HEALTH_TRUST_BUILDER=on bash "$HC" "$WT" --heavy >/dev/null 2>&1
[ -z "$(find "$TREES" -name '.health-provenance-*' 2>/dev/null)" ] \
  || fail "(11) --heavy with no HEALTHCHECK_CMD (which delegates to light) must author no record"
ok "(11) healthcheck.sh authors an honest VERSION 2 heavy record (sha/profile/outcome/duration/provenance/tree_state/log_digest + companion log on CLEAN); --oneline and --light author none"

# The baseline SHA in a DATAENV record must be the one _baseline_base_set actually compared. This
# stub advances MAIN during that base-suite invocation: resolving MAIN again after the comparison
# would incorrectly stamp the new SHA and let the stale inherited-failure claim through.
AT_BASE="$T/attest-main"; AT_WT="$T/attest-pr"; AT_TREES="$T/attest-trees"; mkdir -p "$AT_TREES"
git clone -q "$WT" "$AT_BASE"; git clone -q "$WT" "$AT_WT"
git -C "$AT_WT" -c user.email=t@t -c user.name=t commit --allow-empty -qm candidate
AT_SHA="$(git -C "$AT_WT" rev-parse HEAD)"
AT_OLD_BASE="$(git -C "$AT_BASE" rev-parse HEAD)"
AT_COUNT="$T/attest-count"
AT_STUB="$T/attest-health.sh"
cat > "$AT_STUB" <<'STUB'
#!/usr/bin/env bash
n="$(cat "$ADVANCE_COUNT" 2>/dev/null || echo 0)"; n=$((n + 1)); printf '%s\n' "$n" > "$ADVANCE_COUNT"
if [ "$n" -eq 2 ]; then
  git -C "$ADVANCE_BASE" -c user.email=t@t -c user.name=t commit --allow-empty -qm base-advanced
fi
printf 'not ok 1 inherited failure\n'
exit 1
STUB
chmod +x "$AT_STUB"
AT_OUT="$(env HERD_CONFIG_FILE="$T/no-such-config" HEALTHCHECK_CMD="$AT_STUB" HEALTHCHECK_HEAVY_GLOB="" \
  DEFAULT_BRANCH=main BASELINE_AWARE_GATE=on WORKTREES_DIR="$AT_TREES" HEALTH_TRUST_BUILDER=on \
  HERD_BASELINE_DIR="$AT_BASE" HERD_BASELINE_CACHE="$AT_TREES" ADVANCE_BASE="$AT_BASE" ADVANCE_COUNT="$AT_COUNT" \
  bash "$HC" "$AT_WT" --heavy 2>&1)"; AT_RC=$?
[ "$AT_RC" -eq 0 ] || fail "(11b) inherited baseline fixture should tolerate the first run: $AT_OUT"
AT_NEW_BASE="$(git -C "$AT_BASE" rev-parse HEAD)"
[ "$AT_NEW_BASE" != "$AT_OLD_BASE" ] || fail "(11b) fixture did not advance main during baseline comparison"
# Read the separate fixture's pool directly, so this timing proof cannot accidentally consume an
# earlier record from the primary fixture.
IFS=$'\t' read -r _ _ _ _ AT_OUTCOME _ _ _ _ _ _ AT_RECORDED_BASE < "$AT_TREES/.health-provenance-$AT_SHA"
[ "$AT_OUTCOME" = "DATAENV" ] || fail "(11b) inherited run must record DATAENV, got '$AT_OUTCOME'"
[ "$AT_RECORDED_BASE" = "$AT_OLD_BASE" ] || fail "(11b) record must attest compared base, got '$AT_RECORDED_BASE'"
herd_health_trust_check "$AT_TREES" "$AT_SHA" "$AT_WT" "$AT_BASE" >/dev/null \
  && fail "(11b) a base that advanced after comparison must refuse DATAENV trust"
[ "$HERD_HEALTH_TRUST_REASON" = "DATAENV baseline advanced" ] \
  || fail "(11b) unexpected post-advance reason: '$HERD_HEALTH_TRUST_REASON'"
ok "(11b) healthcheck attests the compared baseline; a change before record emission forces heavy"

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
herd_health_trust_write "$TREES" "$SHA2" "$WT" heavy CLEAN 99 builder-local "gate happy-path suite log"
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

# ── (15) FORMAT VERSION 2 (HERD-560): old-format / unrecognized-version reads as ABSENT ────────────
rm -f "$TREES"/.health-provenance-* 2>/dev/null || true
plant_old "$SHA2" "$WTP" heavy CLEAN 5 builder-local clean "$NOW"
herd_health_trust_check "$TREES" "$SHA2" "$WT" >/dev/null \
  && fail "(15) a pre-HERD-560 8-field record must never be trusted"
[ "$HERD_HEALTH_TRUST_REASON" = "old-format record (absent)" ] \
  || fail "(15) unexpected reason for an old-format record: '$HERD_HEALTH_TRUST_REASON'"
# …and an unrecognized FUTURE version reads the same way — absent, never an error.
plant "$SHA2" "$WTP" heavy CLEAN 5 builder-local clean "$NOW" "deadbeefdigest"
sed -i.bak "s/^2/99/" "$(rec_file "$SHA2")" && rm -f "$(rec_file "$SHA2").bak"
herd_health_trust_check "$TREES" "$SHA2" "$WT" >/dev/null \
  && fail "(15) an unrecognized record version must never be trusted"
[ "$HERD_HEALTH_TRUST_REASON" = "old-format record (absent)" ] \
  || fail "(15) unexpected reason for an unknown-version record: '$HERD_HEALTH_TRUST_REASON'"
ok "(15) a pre-HERD-560 record (or an unrecognized future version) reads as ABSENT, never an error"

# ── (16) DIGEST (HERD-560): a CLEAN record is re-verified against its companion suite log ──────────
rm -f "$TREES"/.health-provenance-* 2>/dev/null || true
herd_health_trust_write "$TREES" "$SHA2" "$WT" heavy CLEAN 5 builder-local "the real suite log body"
herd_health_trust_check "$TREES" "$SHA2" "$WT" >/dev/null \
  || fail "(16) fixture precondition: a freshly written CLEAN record with its own log must be trusted ($HERD_HEALTH_TRUST_REASON)"
# Corrupt the companion log AFTER the fact (a truncated/tampered file) — same record, same digest
# field, different bytes on disk.
printf 'tampered\n' > "$(log_file "$SHA2")"
herd_health_trust_check "$TREES" "$SHA2" "$WT" >/dev/null \
  && fail "(16) a record whose companion log no longer matches its digest must never be trusted"
[ "$HERD_HEALTH_TRUST_REASON" = "digest mismatch" ] \
  || fail "(16) unexpected reason for a tampered log: '$HERD_HEALTH_TRUST_REASON'"
# …and a record with NO companion log at all (deleted, or authored skipping [log]) is refused too —
# a digest with nothing to verify against proves nothing.
rm -f "$(log_file "$SHA2")"
herd_health_trust_check "$TREES" "$SHA2" "$WT" >/dev/null \
  && fail "(16) a record with a missing companion log must never be trusted"
[ "$HERD_HEALTH_TRUST_REASON" = "no suite log for record" ] \
  || fail "(16) unexpected reason for a missing log: '$HERD_HEALTH_TRUST_REASON'"
ok "(16) a CLEAN record is re-verified against its companion suite log on every check — tampered or missing, never trusted"

# ── (17) BOUNDED AGE (HERD-560): a record older than HEALTH_TRUST_MAX_AGE_SECS is refused ──────────
# A real (short) sleep, not a backdated epoch: the fixture commit was just made THIS test run, so
# backdating the epoch past a few seconds would also trip "predates the commit" (9) — a different
# disqualifier. A couple of real seconds isolates the age dimension cleanly and stays well inside the
# 21600s default, so the "still trusted under default" half of this check is never a coincidence.
rm -f "$TREES"/.health-provenance-* 2>/dev/null || true
herd_health_trust_write "$TREES" "$SHA2" "$WT" heavy CLEAN 5 builder-local "aging suite log body"
herd_health_trust_check "$TREES" "$SHA2" "$WT" >/dev/null \
  || fail "(17) fixture precondition: a fresh record must be trusted ($HERD_HEALTH_TRUST_REASON)"
sleep 2
HEALTH_TRUST_MAX_AGE_SECS=1 herd_health_trust_check "$TREES" "$SHA2" "$WT" >/dev/null \
  && fail "(17) a record older than HEALTH_TRUST_MAX_AGE_SECS must never be trusted"
[ "$HERD_HEALTH_TRUST_REASON" = "record older than 1s (stale by age)" ] \
  || fail "(17) unexpected reason: '$HERD_HEALTH_TRUST_REASON'"
# …and the SAME record, with no override, stays trusted — the 6h default comfortably outlives this
# test's wall-clock span, so the bound is opt-in-tightenable, not a hidden always-on flake source.
herd_health_trust_check "$TREES" "$SHA2" "$WT" >/dev/null \
  || fail "(17) the default 6h age bound must not reject a record written moments ago ($HERD_HEALTH_TRUST_REASON)"
ok "(17) a record older than HEALTH_TRUST_MAX_AGE_SECS is refused regardless of outcome; the 6h default does not false-flag a fresh-enough record"

echo
echo "ALL PASS ($PASS checks) — HERD-531/560 sha-matched builder-local trust: off is a hard no-op, only a"
echo "CLEAN or DATAENV heavy builder-local VERSION 2 record of the EXACT sha from a CLEAN tree at the"
echo "SAME worktree, digest-matched against its companion suite log and within the freshness window;"
echo "DATAENV additionally binds the unchanged baseline sha that made its failure inherited. Every other"
echo "case, including CODEERROR, a pre-hardening or"
echo "unrecognized-version record, falls back to the full re-run."
