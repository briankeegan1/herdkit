#!/usr/bin/env bash
# test-runtime-conformance.sh — proof for scripts/herd/runtime-conformance.sh (HERD-763, epic
# HERD-754 step 6): the RUNTIME CONFORMANCE probes and their VERSION-KEYED result cache.
#
# The three things the task this shipped from asks to be proved, and where:
#   (a) a probe that genuinely PASSES against the real installed codex → case 12 (LIVE; skips, never
#       fails, when `codex` is not on PATH — the same skip-if-absent discipline
#       tests/test-codex-exec-adapter.sh and tests/test-codex-agent-roster-live.sh already use).
#   (b) a probe correctly marked DEFERRED → cases 1, 7, 8: exact-session resume / steering /
#       interruption are declared deferred, are PRINTED on every report as "not yet probeable", and
#       can never be reported as verified even when the cache claims otherwise.
#   (c) the VERSION-INVALIDATION behavior itself → cases 4, 5, 12: a result recorded against one
#       version is NOT trusted once the installed version differs — the report says STALE, names both
#       versions, and demands a fresh probe.
#
# Cases 1-11 are HERMETIC: temp roster/pool/PROJECT_ROOT, no runtime binary invoked, no network.
# Run:  bash tests/test-runtime-conformance.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
RTCONF_SH="$ROOT/scripts/herd/runtime-conformance.sh"
AGENTS_SH="$ROOT/scripts/herd/agents.sh"
DRIVER_SH="$ROOT/scripts/herd/driver.sh"
ADAPTER_SH="$ROOT/scripts/herd/codex-exec-adapter.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { PASS=$((PASS+1)); }

for f in "$RTCONF_SH" "$AGENTS_SH" "$DRIVER_SH" "$ADAPTER_SH"; do
  [ -f "$f" ] || fail "missing required file: $f"
done

mkdir -p "$T/proj" "$T/pool"

# rtconf_sh <code> — run <code> with the four modules sourced and BOTH ledger roots pinned into the
# temp tree, so a case can never read or write this machine's real worktree pool (the HERD-436
# real-ledger-leak class). Each case gets its own subshell: no env leaks between cases.
rtconf_sh() {
  env -u HERD_RTCONF_VERSION -u HERD_RTCONF_DRIVER -u HERD_AGENT \
      PROJECT_ROOT="$T/proj" WORKTREES_DIR="$T/pool" \
      ${_RT_ENV[@]+"${_RT_ENV[@]}"} \
      bash -c 'set -uo pipefail; . "$1"; . "$2"; . "$3"; . "$4"; shift 4; eval "$@"' \
      _ "$DRIVER_SH" "$AGENTS_SH" "$ADAPTER_SH" "$RTCONF_SH" -- "$1"
}
_RT_ENV=()

# ── 1. the probe table: three LIVE probes (the capabilities steps 1-5 actually built) and three
#    DEFERRED ones, each naming step 7 as the reason. A deferred row is a first-class declaration,
#    not an omission — that is the whole point of (b). ──────────────────────────────────────────────
table="$(rtconf_sh 'herd_rtconf_probes')"
for id in specialist-definition structured-exec-events project-agent-discovery; do
  [ "$(rtconf_sh "herd_rtconf_probe_field $id 2")" = "live" ] || fail "(1) $id should be a live probe"
done
for id in session-resume-exact steering interruption; do
  [ "$(rtconf_sh "herd_rtconf_probe_field $id 2")" = "deferred" ] || fail "(1) $id must be declared DEFERRED, not omitted"
  case "$(rtconf_sh "herd_rtconf_probe_field $id 4")" in
    *"step 7"*) : ;;
    *) fail "(1) $id's deferred reason must name HERD-754 step 7 (the unbuilt durable coordination)" ;;
  esac
done
[ "$(printf '%s\n' "$table" | grep -c .)" -eq 6 ] || fail "(1) expected exactly 6 declared probes, got: $table"
pass; echo "PASS (1) probe table declares 3 live probes + 3 explicitly deferred ones (each naming step 7)"

# ── 2. version resolution: the override seam wins, and an ABSENT runtime yields an EMPTY version —
#    the "nothing can be asserted here" state, distinct from a failure. ─────────────────────────────
_RT_ENV=(HERD_RTCONF_VERSION="fake 9.9.9")
[ "$(rtconf_sh 'herd_rtconf_version')" = "fake 9.9.9" ] || fail "(2) HERD_RTCONF_VERSION override not honored"
_RT_ENV=(HERD_RTCONF_DRIVER=herd-no-such-runtime-xyz)
[ -z "$(rtconf_sh 'herd_rtconf_version')" ] || fail "(2) an absent runtime binary must yield an EMPTY version"
[ "$(rtconf_sh 'herd_rtconf_runtime')" = "herd-no-such-runtime-xyz" ] || fail "(2) runtime resolution fell back wrong"
_RT_ENV=()
pass; echo "PASS (2) version resolves from the binary (override seam honored); an absent binary yields an empty version"

# ── 3. cache round trip: an outcome recorded against a version is readable back at THAT version. ───
_RT_ENV=()
out="$(rtconf_sh '
  herd_rtconf_cache_put codex "codex-cli 1.0.0" structured-exec-events pass "real stream parsed"
  herd_rtconf_cache_get codex "codex-cli 1.0.0" structured-exec-events')"
[ "$(printf '%s' "$out" | cut -f1)" = "pass" ] || fail "(3) round-trip outcome wrong: $out"
[ "$(printf '%s' "$out" | cut -f3)" = "real stream parsed" ] || fail "(3) round-trip note wrong: $out"
[ -f "$T/pool/.herd-runtime-conformance" ] || fail "(3) cache must live in the worktree pool, not the repo"
pass; echo "PASS (3) an outcome recorded against a version reads back at that version, from the pinned pool"

# ── 4. VERSION INVALIDATION, the core contract (c): the SAME probe, recorded against 1.0.0, is not
#    returned for 1.0.1 — and herd_rtconf_trusted, the one place that judgment is made, refuses it.
#    cache_last still NAMES the stale row (so the report can say what it was) without trusting it. ──
[ -z "$(rtconf_sh 'herd_rtconf_cache_get codex "codex-cli 1.0.1" structured-exec-events')" ] \
  || fail "(4) a row recorded against 1.0.0 must NOT be returned for 1.0.1"
rtconf_sh 'herd_rtconf_trusted codex "codex-cli 1.0.0" structured-exec-events' \
  || fail "(4) the exact recorded version must be trusted"
rtconf_sh 'herd_rtconf_trusted codex "codex-cli 1.0.1" structured-exec-events' \
  && fail "(4) a BUMPED version must NOT be trusted — that is the whole invalidation contract"
rtconf_sh 'herd_rtconf_trusted codex "" structured-exec-events' \
  && fail "(4) an EMPTY installed version (absent binary) must never be trusted"
last="$(rtconf_sh 'herd_rtconf_cache_last codex structured-exec-events')"
[ "$(printf '%s' "$last" | cut -f3)" = "codex-cli 1.0.0" ] \
  || fail "(4) cache_last must still NAME the stale row's version (for the report), got: $last"
pass; echo "PASS (4) a bumped runtime version invalidates the recorded result outright (trusted=no), while the stale row stays nameable"

# ── 5. the REPORT under a bumped version: STALE, both versions named, a fresh probe demanded — and
#    emphatically NOT a ✓ pass row. A silent downgrade would be the exact blind-rail bug this
#    feature exists to prevent. ─────────────────────────────────────────────────────────────────────
_RT_ENV=(HERD_RTCONF_VERSION="codex-cli 1.0.1")
rep="$(rtconf_sh 'herd_rtconf_report')"
case "$rep" in *"structured-exec-events"*"STALE"*) : ;; *) fail "(5) report did not mark the off-version row STALE: $rep" ;; esac
case "$rep" in *"codex-cli 1.0.0"*) : ;; *) fail "(5) report must name the version the stale result was recorded against" ;; esac
case "$rep" in *"codex-cli 1.0.1"*) : ;; *) fail "(5) report must name the INSTALLED version" ;; esac
case "$rep" in *"--runtime-conformance --probe"*) : ;; *) fail "(5) report must tell the operator how to re-probe" ;; esac
grep -q '✓ structured-exec-events' <<< "$rep" \
  && fail "(5) a stale result must never render as a ✓ pass row"
pass; echo "PASS (5) the report renders an off-version result as STALE, names both versions, and demands a fresh probe"

# ── 6. the report at the RECORDED version: a ✓ pass row carrying its note, timestamp and version. ──
_RT_ENV=(HERD_RTCONF_VERSION="codex-cli 1.0.0")
rep="$(rtconf_sh 'herd_rtconf_report')"
grep -q '✓ structured-exec-events' <<< "$rep" || fail "(6) an in-version pass must render as ✓: $rep"
case "$rep" in *"real stream parsed"*) : ;; *) fail "(6) the pass row must carry its recorded note" ;; esac
pass; echo "PASS (6) a result recorded against the INSTALLED version renders as a ✓ pass row with its note"

# ── 7. DEFERRED rows are printed on EVERY report — and can never be reported as verified, even when
#    a row in the cache claims they passed. (b): explicit degradation, with no back door. ───────────
rtconf_sh 'herd_rtconf_cache_put codex "codex-cli 1.0.0" steering pass "a lie the report must ignore"' >/dev/null
rep="$(rtconf_sh 'herd_rtconf_report')"
for id in session-resume-exact steering interruption; do
  grep -q "$id.*not yet probeable" <<< "$rep" || fail "(7) deferred row $id missing from the report: $rep"
done
grep -q '✓ steering' <<< "$rep" \
  && fail "(7) a DEFERRED capability must never render as verified, even with a cache row claiming pass"
case "$rep" in *"step 7"*) : ;; *) fail "(7) the report must say WHY a deferred row is not probeable (step 7)" ;; esac
pass; echo "PASS (7) deferred capabilities always print as 'not yet probeable (step 7)' and can never render as verified"

# ── 8. runtime ABSENT: every live row degrades to a labelled `unavailable` line, deferred rows still
#    print, and the report still exits 0 (advisory, never a gate). ─────────────────────────────────
_RT_ENV=(HERD_RTCONF_DRIVER=herd-no-such-runtime-xyz)
rep="$(rtconf_sh 'herd_rtconf_report'; echo "rc=$?")"
case "$rep" in *"unavailable"*"not installed"*) : ;; *) fail "(8) absent runtime must render as unavailable: $rep" ;; esac
case "$rep" in *"not yet probeable"*) : ;; *) fail "(8) deferred rows must print even when the runtime is absent" ;; esac
case "$rep" in *"rc=0"*) : ;; *) fail "(8) the report must always exit 0 — it is advisory, never a gate" ;; esac
run="$(rtconf_sh 'herd_rtconf_run'; echo "rc=$?")"
case "$run" in *"is not installed"*"rc=0"*) : ;; *) fail "(8) herd_rtconf_run with no runtime must degrade cleanly, got: $run" ;; esac
_RT_ENV=()
pass; echo "PASS (8) an absent runtime degrades to labelled 'unavailable' rows; report and run both stay exit-0 advisory"

# ── 9. SOURCE-TIME INERTNESS: sourcing the module prints nothing and writes no cache — the contract
#    that lets bin/herd source it inside a doctor branch without side effects. ─────────────────────
rm -rf "$T/pool2"; mkdir -p "$T/pool2"
srcout="$(env PROJECT_ROOT="$T/proj" WORKTREES_DIR="$T/pool2" \
  bash -c 'set -uo pipefail; . "$1"; . "$2"; . "$3"; . "$4"' _ "$DRIVER_SH" "$AGENTS_SH" "$ADAPTER_SH" "$RTCONF_SH" 2>&1)"
[ -z "$srcout" ] || fail "(9) sourcing must be silent, got: $srcout"
[ -e "$T/pool2/.herd-runtime-conformance" ] && fail "(9) sourcing must not create the cache file"
pass; echo "PASS (9) sourcing the module is silent and side-effect-free"

# ── 10. OPT-IN WIRING: the new leg is reachable ONLY through `herd doctor --runtime-conformance`.
#     cmd_doctor's pre-existing branches never touch it, so `herd doctor` / `herd doctor --probe`
#     are byte-identical to before this feature existed. ────────────────────────────────────────────
doctor_body="$(awk '/^cmd_doctor\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$ROOT/bin/herd")"
[ -n "$doctor_body" ] || fail "(10) could not extract cmd_doctor from bin/herd"
grep -q -- '--runtime-conformance)' <<< "$doctor_body" \
  || fail "(10) cmd_doctor has no --runtime-conformance branch"
# every runtime-conformance.sh reference must sit AFTER the branch label — i.e. inside that branch.
branch_line="$(grep -n -- '--runtime-conformance)' <<< "$doctor_body" | awk -F: 'NR==1{print $1}')"
first_ref="$(grep -n 'runtime-conformance\.sh' <<< "$doctor_body" | awk -F: 'NR==1{print $1}')"
[ -n "$first_ref" ] || fail "(10) cmd_doctor never sources runtime-conformance.sh"
[ "$first_ref" -gt "$branch_line" ] \
  || fail "(10) runtime-conformance.sh is sourced OUTSIDE the opt-in branch — the plain doctor is no longer byte-identical"
grep -q 'herd_rtconf_report' <<< "$doctor_body" || fail "(10) the branch does not call the report"
grep -q -- 'herd doctor --runtime-conformance' "$ROOT/bin/herd" || fail "(10) the new mode is undocumented in herd's help"
pass; echo "PASS (10) the runtime-conformance leg is reachable only via its own opt-in flag; plain 'herd doctor' is untouched"

# ── 11. an UNKNOWN probe id degrades to a typed `unavailable` verdict, never a crash. ─────────────
d="$(rtconf_sh '_herd_rtconf_dispatch no-such-probe /tmp; echo "rc=$?"')"
case "$d" in *"unavailable"*"rc=0"*) : ;; *) fail "(11) unknown probe id must degrade to unavailable, got: $d" ;; esac
pass; echo "PASS (11) an unknown probe id yields a typed 'unavailable' verdict rather than a crash"

# ── 12. LIVE (a): one REAL bounded probe against the installed codex. Asserts the probe passes, that
#     its recorded row is keyed to the binary's OWN reported version, and that the invalidation
#     contract holds for a REAL recorded result — not just a synthetic one. Skips when codex is
#     absent (the hermetic cases above already prove the framework). ────────────────────────────────
if ! command -v codex >/dev/null 2>&1; then
  echo "SKIP (12) codex not on PATH — the live probe needs the real binary (cases 1-11 prove the framework)"
else
  rm -rf "$T/live"; mkdir -p "$T/live"
  live="$(env -u HERD_RTCONF_VERSION -u HERD_RTCONF_DRIVER \
    PROJECT_ROOT="$ROOT" WORKTREES_DIR="$T/live" \
    bash -c 'set -uo pipefail; . "$1"; . "$2"; . "$3"; . "$4"; herd_rtconf_run structured-exec-events' \
    _ "$DRIVER_SH" "$AGENTS_SH" "$ADAPTER_SH" "$RTCONF_SH" 2>&1)"
  case "$live" in
    *"✓ structured-exec-events   pass"*) : ;;
    *) fail "(12) the live structured-exec-events probe did not pass against the installed codex: $live" ;;
  esac
  ver="$(codex --version 2>/dev/null || true)"; ver="${ver%%$'\n'*}"
  ver="$(printf '%s' "$ver" | sed -e 's/  */ /g' -e 's/^ //' -e 's/ $//')"
  [ -n "$ver" ] || fail "(12) could not read the installed codex version"
  grep -qF "	$ver	structured-exec-events	pass	" "$T/live/.herd-runtime-conformance" \
    || fail "(12) the live result was not recorded keyed to the installed version ($ver)"
  env PROJECT_ROOT="$ROOT" WORKTREES_DIR="$T/live" \
    bash -c 'set -uo pipefail; . "$1"; . "$2"; . "$3"; . "$4"; herd_rtconf_trusted codex "$5" structured-exec-events' \
    _ "$DRIVER_SH" "$AGENTS_SH" "$ADAPTER_SH" "$RTCONF_SH" "$ver" \
    || fail "(12) a freshly probed result must be trusted at the installed version"
  env PROJECT_ROOT="$ROOT" WORKTREES_DIR="$T/live" \
    bash -c 'set -uo pipefail; . "$1"; . "$2"; . "$3"; . "$4"; herd_rtconf_trusted codex "$5-bumped" structured-exec-events' \
    _ "$DRIVER_SH" "$AGENTS_SH" "$ADAPTER_SH" "$RTCONF_SH" "$ver" \
    && fail "(12) the SAME real result must stop being trusted the moment the installed version differs"
  pass; echo "PASS (12) LIVE: the structured-exec-events probe genuinely passes against the installed codex, recorded keyed to its real version — and stops being trusted on a version bump"
fi

# ── 13. HERD-767 (epic HERD-754 step 8) grok probe table: an explicit HERD_RTCONF_DRIVER=grok override
#     returns ONE honest, explicit deferred row — never codex's codex-shaped probe ids, and never an
#     empty table (silence is exactly what this step exists to avoid). ────────────────────────────────
_RT_ENV=(HERD_RTCONF_DRIVER=grok)
gtable="$(rtconf_sh 'herd_rtconf_probes')"
[ "$(printf '%s\n' "$gtable" | grep -c .)" -eq 1 ] || fail "(13) grok probe table should declare exactly 1 row, got: $gtable"
case "$gtable" in *"grok-runtime"*"deferred"*) : ;; *) fail "(13) grok probe table missing its deferred grok-runtime row: $gtable" ;; esac
[ "$(rtconf_sh 'herd_rtconf_probe_field grok-runtime 2')" = "deferred" ] || fail "(13) grok-runtime must be mode=deferred"
case "$(rtconf_sh 'herd_rtconf_probe_field grok-runtime 4')" in
  *"HERD-754 step 8"*) : ;;
  *) fail "(13) grok-runtime's deferred reason must name epic HERD-754 step 8" ;;
esac
case "$gtable" in *"specialist-definition"*) fail "(13) grok probe table must NOT carry codex's probe ids" ;; esac
_RT_ENV=()
pass; echo "PASS (13) HERD_RTCONF_DRIVER=grok declares exactly one explicit deferred row, never codex's live probe ids"

# ── 14. ACTIVE-DRIVER auto-detection: with NO explicit HERD_RTCONF_DRIVER override, herd_rtconf_driver
#     targets grok when the PROJECT's active driver (HERD_DRIVER, read by herd_driver_name) is grok —
#     the hook point that stops a grok seat from silently getting codex's report — while every other
#     active driver (unset, codex, herdr-claude) keeps today's hardcoded codex default untouched. ─────
_RT_ENV=(HERD_DRIVER=grok)
[ "$(rtconf_sh 'herd_rtconf_driver')" = "grok" ] || fail "(14) an active grok driver must auto-target grok with no explicit override"
_RT_ENV=(HERD_DRIVER=codex)
[ "$(rtconf_sh 'herd_rtconf_driver')" = "codex" ] || fail "(14) an active codex driver must resolve codex (unchanged)"
_RT_ENV=(HERD_DRIVER=herdr-claude)
[ "$(rtconf_sh 'herd_rtconf_driver')" = "codex" ] || fail "(14) a normal claude seat must still default to codex (byte-identical to before HERD-767)"
_RT_ENV=()
[ "$(rtconf_sh 'herd_rtconf_driver')" = "codex" ] || fail "(14) no active driver set at all must still default to codex"
pass; echo "PASS (14) herd_rtconf_driver auto-targets grok ONLY when the project's active driver is grok; every other seat is unchanged"

# ── 15. grok is not installed on this dev machine (true of every machine this audit has run on) — run
#     and report must both degrade HONESTLY: no crash, no guessed pass, and the explicit deferred row
#     still prints. Mirrors case (8)'s codex-absent proof but for the grok hook point specifically. ────
_RT_ENV=(HERD_RTCONF_DRIVER=grok)
grun="$(rtconf_sh 'herd_rtconf_run'; echo "rc=$?")"
case "$grun" in *"grok is not installed"*"rc=0"*) : ;; *) fail "(15) herd_rtconf_run for grok must degrade cleanly and honestly, got: $grun" ;; esac
grpt="$(rtconf_sh 'herd_rtconf_report')"
case "$grpt" in *"driver grok"*"runtime grok"*) : ;; *) fail "(15) report header must name driver+runtime grok: $grpt" ;; esac
case "$grpt" in *"<not installed>"*) : ;; *) fail "(15) report header must say grok is not installed: $grpt" ;; esac
case "$grpt" in *"grok-runtime"*"not yet probeable"*) : ;; *) fail "(15) report must print the grok-runtime deferred row: $grpt" ;; esac
_RT_ENV=()
pass; echo "PASS (15) grok (absent on this machine) degrades honestly through both herd_rtconf_run and herd_rtconf_report — never a crash, never a guessed result"

echo "─────────────────────────────────────────────"
echo "runtime-conformance.sh: $PASS checks passed"
