#!/usr/bin/env bash
# test-doctor-point-of-need.sh — hermetic proof for HERD-45: wire the doctor's dependency knowledge
# to the point of need. Three connective fixes, each locked here:
#
#   1. SELF-DIAGNOSING degraded render — backlog-view.sh's no-glow fallback prints ONE dim
#      informational line pointing at `herd doctor`, so a user staring at a raw-markdown backlog pane
#      is told the fix at the exact moment they hit the degradation. Dim, never red.
#   2. PROACTIVE soft-dep surfacing — _herd_soft_dep_startup_notice (herd-preflight.sh) is a no-op
#      (byte-identical) unless the opt-in DOCTOR_STARTUP_HINT=on, and when on prints one dim line per
#      MISSING soft dep + a `herd doctor` pointer. Never red, always returns 0.
#   (The coordinator troubleshooting playbook is a static template addition; covered by grep here.)
#
# Fully hermetic: local temp only, NO herdr, NO gh, NO network, NO model, NO real glow needed. The
# render case forces the no-glow path by running the viewer under a PATH that excludes glow; the
# notice cases pin soft-dep presence by controlling PATH (the function uses only shell builtins).
# Run:  bash tests/test-doctor-point-of-need.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
VIEW="$ROOT/scripts/herd/backlog-view.sh"
PREFLIGHT="$ROOT/scripts/herd/herd-preflight.sh"
CAPS="$ROOT/templates/capabilities.tsv"
CFG_EXAMPLE="$ROOT/templates/config.example"
TMPL="$ROOT/templates/coordinator.md.tmpl"
HCFG="$ROOT/scripts/herd/herd-config.sh"

for f in "$VIEW" "$PREFLIGHT" "$CAPS" "$CFG_EXAMPLE" "$TMPL" "$HCFG"; do
  [ -f "$f" ] || { echo "FAIL: missing required file: $f" >&2; exit 1; }
done
command -v bash >/dev/null 2>&1 || { echo "FAIL: bash required" >&2; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass(){ PASS=$((PASS+1)); }

HINT='glow not found — showing raw markdown; run herd doctor for the install command'

# ── Fixtures: a stub `herd backlog` on a glow-less PATH ──────────────────────────────────────────
BIN="$T/bin"; mkdir -p "$BIN"
cat > "$BIN/herd" <<'FAKE'
#!/usr/bin/env bash
[ "${1:-}" = "backlog" ] || exit 0
printf '%s\n' "#ABC-1 alpha render item"
FAKE
chmod +x "$BIN/herd"

P="$T/proj"; mkdir -p "$P/.herd"
cat > "$P/.herd/config" <<EOF
PROJECT_ROOT="$P"
WORKSPACE_NAME="testws"
BACKLOG_FILE="BACKLOG.md"
SCRIBE_BACKEND="linear"
EOF

# ── Case 1: no-glow degraded render prints the self-diagnosing doctor hint ────────────────────────
# PATH deliberately EXCLUDES any glow dir, so render_backend_frame takes the raw-list fallback. One
# poll (BACKLOG_VIEW_MAX_POLLS=1), non-tty (BACKLOG_VIEW_TTY=/dev/null) so the loop never wedges.
out1="$(env -i HOME="$HOME" PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin" TERM=xterm \
  HERD_CONFIG_FILE="$P/.herd/config" HERD_ALLOW_FOREIGN_CWD=1 BACKLOG_VIEW_TTY=/dev/null \
  BACKLOG_VIEW_MAX_POLLS=1 BACKLOG_VIEW_POLL_SECS=0 \
  bash "$VIEW" 2>/dev/null </dev/null)"
grep -q "alpha render item" <<<"$out1" || fail "no-glow render did not print the backlog list ($out1)"
grep -qF "$HINT" <<<"$out1"            || fail "no-glow render missing the self-diagnosing doctor hint ($out1)"
# Dim, NEVER red: the hint line must carry the dim SGR (\033[2m) and NO red foreground (31/91).
hintline="$(grep -F "$HINT" <<<"$out1" | head -1)"
grep -q $'\033\[2m' <<<"$hintline" || fail "hint line is not dim (missing \\033[2m): $(printf %q "$hintline")"
grep -qE $'\033\[[0-9;]*(31|91)[;m]' <<<"$hintline" && fail "hint line is RED — violates the no-false-red rule"
pass

# ── Case 2: startup notice — sourceable + side-effect-free, SILENT unless opted in ────────────────
# Source herd-preflight.sh (defines the function; no side effects on source) and drive the notice
# with a controlled PATH so soft-dep presence is deterministic. The function uses only builtins.
# shellcheck source=/dev/null
. "$PREFLIGHT"
command -v _herd_soft_dep_startup_notice >/dev/null 2>&1 \
  || fail "sourcing herd-preflight.sh did not define _herd_soft_dep_startup_notice"

EMPTYBIN="$T/emptybin"; mkdir -p "$EMPTYBIN"   # no glow/shellcheck/bats reachable here

# unset → default off → byte-identical (no output)
o_unset="$( unset DOCTOR_STARTUP_HINT; PATH="$EMPTYBIN" _herd_soft_dep_startup_notice )"
[ -z "$o_unset" ] || fail "notice must be silent when DOCTOR_STARTUP_HINT is unset (got: $o_unset)"
# explicit off → silent
o_off="$( DOCTOR_STARTUP_HINT=off PATH="$EMPTYBIN" _herd_soft_dep_startup_notice )"
[ -z "$o_off" ] || fail "notice must be silent when DOCTOR_STARTUP_HINT=off (got: $o_off)"
# a bogus value is treated as off (only 'on' enables)
o_bogus="$( DOCTOR_STARTUP_HINT=yes PATH="$EMPTYBIN" _herd_soft_dep_startup_notice )"
[ -z "$o_bogus" ] || fail "notice must treat any non-'on' value as off (got: $o_bogus)"
pass

# ── Case 3: opt-in ON surfaces each MISSING soft dep + a single doctor pointer, dim never red ─────
o_on="$( DOCTOR_STARTUP_HINT=on PATH="$EMPTYBIN" _herd_soft_dep_startup_notice )"
grep -q "glow not found"       <<<"$o_on" || fail "notice(on) must surface missing glow ($o_on)"
grep -q "shellcheck not found" <<<"$o_on" || fail "notice(on) must surface missing shellcheck ($o_on)"
grep -q "bats not found"       <<<"$o_on" || fail "notice(on) must surface missing bats ($o_on)"
grep -q "run herd doctor"      <<<"$o_on" || fail "notice(on) must point at 'herd doctor' ($o_on)"
[ "$(grep -c "run herd doctor" <<<"$o_on")" -eq 1 ] || fail "notice(on) must print the doctor pointer exactly once ($o_on)"
grep -q $'\033\[2m' <<<"$o_on" || fail "notice(on) output is not dim (missing \\033[2m)"
grep -qE $'\033\[[0-9;]*(31|91)[;m]' <<<"$o_on" && fail "notice(on) output is RED — violates the no-false-red rule"
# return status is always 0 (a reminder must never fail the launch it rides on)
( DOCTOR_STARTUP_HINT=on PATH="$EMPTYBIN" _herd_soft_dep_startup_notice >/dev/null ) || fail "notice must return 0 even with missing deps"
pass

# ── Case 4: opt-in ON with every soft dep PRESENT prints nothing (no spurious noise) ──────────────
FULLBIN="$T/fullbin"; mkdir -p "$FULLBIN"
for t in glow shellcheck bats; do printf '#!/bin/sh\n:\n' > "$FULLBIN/$t"; chmod +x "$FULLBIN/$t"; done
o_full="$( DOCTOR_STARTUP_HINT=on PATH="$FULLBIN:/usr/bin:/bin" _herd_soft_dep_startup_notice )"
[ -z "$o_full" ] || fail "notice(on) must be silent when all soft deps are present (got: $o_full)"
pass

# ── Case 5: the new config key + template playbook are actually documented ────────────────────────
grep -qE '^DOCTOR_STARTUP_HINT	config	' "$CAPS" \
  || fail "DOCTOR_STARTUP_HINT missing (or wrong kind) in capabilities.tsv"
grep -q 'DOCTOR_STARTUP_HINT' "$CFG_EXAMPLE" \
  || fail "DOCTOR_STARTUP_HINT not documented in config.example"
grep -q 'DOCTOR_STARTUP_HINT' "$HCFG" \
  || fail "DOCTOR_STARTUP_HINT has no default in herd-config.sh"
grep -qi 'herd doctor' "$TMPL" \
  || fail "coordinator template has no 'herd doctor' troubleshooting guidance"
grep -qi 'soft dep' "$TMPL" \
  || fail "coordinator template troubleshooting playbook does not mention soft deps"
pass

echo "PASS ($PASS cases): HERD-45 doctor-to-point-of-need wiring"
