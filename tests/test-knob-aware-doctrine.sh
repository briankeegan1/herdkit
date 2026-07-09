#!/usr/bin/env bash
# test-knob-aware-doctrine.sh — hermetic proof of HERD-216: knob-aware autonomous-operating
# doctrine rendered into the coordinator skill (templates/coordinator.md.tmpl via render_skill).
#
# HARD INVARIANT: under COORDINATOR_AUTONOMY=human (default) the rendered skill is byte-identical
# to a render that never saw the doctrine token — the section is ADDITIVE and appears ONLY under
# the autonomy knobs (gated|full).
#
# Three render shapes asserted:
#   (1) human          → no "## Operating posture" section (byte-identical to pre-doctrine)
#   (2) full+autofix   → full doctrine section (core rails + engine-owned autofix suite)
#   (3) partial knobs  → core doctrine + per-knob MANUAL-duty lines for each off autofix key
#
# Fully hermetic: local temp git repos only. NO herdr, NO gh, NO claude, NO network, NO model.
# Run:  bash tests/test-knob-aware-doctrine.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
HERD="$ROOT/bin/herd"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ pass=$((pass+1)); }

[ -f "$HERD" ] || fail "missing bin/herd"
[ -f "$ROOT/templates/coordinator.md.tmpl" ] || fail "missing coordinator.md.tmpl"
grep -q '{{OPERATING_POSTURE}}' "$ROOT/templates/coordinator.md.tmpl" \
  || fail "template missing {{OPERATING_POSTURE}} token"

# seed_repo <dir> [extra .herd/config lines]
seed_repo() {
  local d="$1" extra="${2:-}"
  git -C "$d" init -q
  git -C "$d" config user.email t@t.t; git -C "$d" config user.name t
  ( cd "$d" && git commit -q --allow-empty -m init )
  mkdir -p "$d/.herd"
  cat > "$d/.herd/config" <<EOF
HERD_VERSION=1
WORKSPACE_NAME="herdkit"
PROJECT_ROOT="$d"
DEFAULT_BRANCH="origin/main"
BACKLOG_FILE="BACKLOG.md"
SCRIBE_BACKEND="file"
HERD_REPO="briankeegan1/herdkit"
COORDINATOR_CMD="/coordinator"
$extra
EOF
}
render(){ local d="$1"; ( cd "$d" && bash "$HERD" render ) >/dev/null; }
skill(){ printf '%s' "$1/.claude/commands/coordinator.md"; }

# ── (1) human (default / explicit): doctrine ABSENT; no leftover token ───────────────────────────
H="$T/human"; mkdir -p "$H"
seed_repo "$H" 'COORDINATOR_AUTONOMY="human"'
render "$H" || fail "(1) human render failed"
HS="$(skill "$H")"
[ -f "$HS" ] || fail "(1) human render produced no skill"
grep -qE '\{\{' "$HS" && fail "(1) human skill left an unsubstituted {{token}}" || true
grep -q '## Operating posture' "$HS" && fail "(1) human must NOT render Operating posture" || true
grep -q 'Autonomous operating doctrine' "$HS" && fail "(1) human must NOT render doctrine body" || true
grep -q 'Duties that stay MANUAL' "$HS" && fail "(1) human must NOT render manual-duty lines" || true
# Unset autonomy defaults to human and must also omit the section.
H2="$T/human-unset"; mkdir -p "$H2"
seed_repo "$H2"   # no COORDINATOR_AUTONOMY line
render "$H2" || fail "(1b) unset-autonomy render failed"
grep -q '## Operating posture' "$(skill "$H2")" && fail "(1b) unset autonomy must omit Operating posture" || true
# Byte-identity of the human path: explicit human == unset (normalize PROJECT_ROOT only).
sed "s#$H#PROOT#g" "$HS" > "$T/h-a"
sed "s#$H2#PROOT#g" "$(skill "$H2")" > "$T/h-b"
diff -q "$T/h-a" "$T/h-b" >/dev/null \
  || { echo "--- human vs unset differ ---"; diff "$T/h-a" "$T/h-b" | head -20; fail "(1c) explicit human not byte-identical to unset default"; }
ok; echo "PASS (1) COORDINATOR_AUTONOMY=human → no Operating posture (byte-identical default)"

# ── (2) full + autofix suite on → FULL doctrine ──────────────────────────────────────────────────
F="$T/full"; mkdir -p "$F"
seed_repo "$F" 'COORDINATOR_AUTONOMY="full"
REVIEW_AUTOFIX="true"
HEALTHCHECK_AUTOFIX="true"
STALE_BASE_AUTOFIX="on"
SWEEP_AUTO="auto"'
render "$F" || fail "(2) full+autofix render failed"
FS="$(skill "$F")"
grep -q '## Operating posture' "$FS" || fail "(2) full+autofix missing Operating posture section"
grep -q 'Autonomous operating doctrine' "$FS" || fail "(2) full+autofix missing doctrine header"
grep -q 'End-to-end pipelines' "$FS" || fail "(2) missing doctrine point 1 (end-to-end)"
grep -q 'File-then-spawn' "$FS" || fail "(2) missing doctrine point 2 (file-then-spawn)"
grep -q 'REVIEW_CONCURRENCY' "$FS" || fail "(2) missing doctrine point 3 (review bandwidth)"
grep -q 'Let the GATE merge' "$FS" || fail "(2) missing doctrine point 4 (gate merges)"
grep -q 'Reconcile the tracker on every merge' "$FS" || fail "(2) missing doctrine point 5 (reconcile)"
grep -q 'Sweep debris' "$FS" || fail "(2) missing doctrine point 6 (sweep)"
grep -q 'Autofix suite (engine-owned)' "$FS" || fail "(2) full+autofix missing engine-owned suite block"
grep -q 'STALE_BASE_AUTOFIX=on' "$FS" || fail "(2) full doctrine should state stale-base engine-owned"
grep -q 'HEALTHCHECK_AUTOFIX=true' "$FS" || fail "(2) full doctrine should state health autofix engine-owned"
grep -q 'SWEEP_AUTO=auto' "$FS" || fail "(2) full doctrine should state sweep auto"
grep -q 'Duties that stay MANUAL' "$FS" && fail "(2) full+autofix must NOT list manual duties" || true
grep -qE '\{\{' "$FS" && fail "(2) full skill left an unsubstituted {{token}}" || true
ok; echo "PASS (2) COORDINATOR_AUTONOMY=full + autofix suite → full doctrine, no manual duties"

# ── (3) partial config → per-knob MANUAL-duty lines ──────────────────────────────────────────────
P="$T/partial"; mkdir -p "$P"
seed_repo "$P" 'COORDINATOR_AUTONOMY="full"
REVIEW_AUTOFIX="false"
HEALTHCHECK_AUTOFIX="false"
STALE_BASE_AUTOFIX="off"
SWEEP_AUTO="off"'
render "$P" || fail "(3) partial render failed"
PS="$(skill "$P")"
grep -q '## Operating posture' "$PS" || fail "(3) partial missing Operating posture section"
grep -q 'Autonomous operating doctrine' "$PS" || fail "(3) partial missing core doctrine"
grep -q 'Duties that stay MANUAL under this config' "$PS" || fail "(3) partial missing MANUAL duties header"
grep -qF '`STALE_BASE_AUTOFIX=off`: stale-base holds are yours to bounce' "$PS" \
  || fail "(3) partial missing STALE_BASE_AUTOFIX manual line"
grep -qF '`HEALTHCHECK_AUTOFIX=false`: red healthchecks are yours' "$PS" \
  || fail "(3) partial missing HEALTHCHECK_AUTOFIX manual line"
grep -qF '`SWEEP_AUTO=off`: run `herd sweep` when housekeeping advises' "$PS" \
  || fail "(3) partial missing SWEEP_AUTO=off manual line"
grep -qF '`REVIEW_AUTOFIX=false`: BLOCK reviews are yours to re-task' "$PS" \
  || fail "(3) partial missing REVIEW_AUTOFIX manual line"
grep -q 'Autofix suite (engine-owned)' "$PS" && fail "(3) partial must NOT claim engine-owned suite" || true
grep -qE '\{\{' "$PS" && fail "(3) partial skill left an unsubstituted {{token}}" || true
ok; echo "PASS (3) partial knobs → correct per-knob manual-duty lines"

# ── (4) mixed partial: only some knobs off → only those lines ────────────────────────────────────
M="$T/mixed"; mkdir -p "$M"
seed_repo "$M" 'COORDINATOR_AUTONOMY="gated"
REVIEW_AUTOFIX="true"
HEALTHCHECK_AUTOFIX="true"
STALE_BASE_AUTOFIX="off"
SWEEP_AUTO="advise"'
render "$M" || fail "(4) mixed render failed"
MS="$(skill "$M")"
grep -q '## Operating posture' "$MS" || fail "(4) gated must still render Operating posture"
# Scope negative checks to the Operating posture section — the CAPABILITIES index also
# mentions default values for these keys and would false-trip a whole-file grep.
_op_sec="$(awk '/^## Operating posture$/{p=1;next} p&&/^## /{exit} p' "$MS")"
[ -n "$_op_sec" ] || fail "(4) could not extract Operating posture section"
printf '%s\n' "$_op_sec" | grep -qF '`STALE_BASE_AUTOFIX=off`: stale-base holds are yours to bounce' \
  || fail "(4) mixed missing STALE_BASE manual line"
printf '%s\n' "$_op_sec" | grep -qF '`SWEEP_AUTO=advise`: run `herd sweep` when the console recommends' \
  || fail "(4) mixed missing SWEEP_AUTO=advise manual line"
printf '%s\n' "$_op_sec" | grep -qF '`HEALTHCHECK_AUTOFIX=false`' \
  && fail "(4) health on must not list a false manual line" || true
printf '%s\n' "$_op_sec" | grep -qF '`REVIEW_AUTOFIX=false`' \
  && fail "(4) review on must not list a false manual line" || true
printf '%s\n' "$_op_sec" | grep -q 'Autofix suite (engine-owned)' \
  && fail "(4) gated+partial must not claim full suite" || true
ok; echo "PASS (4) mixed partial (gated + some knobs off) → only those manual lines"

echo "ALL PASS ($pass checks) — knob-aware operating doctrine (HERD-216)"
