#!/usr/bin/env bash
# test-healthcheck-routing.sh — hermetic tests for the AUTO profile ROUTING in healthcheck.sh.
#
# The auto profile picks heavy (the project's full gate) vs light (per-file syntax) from what the
# worktree's diff touches, keyed on HEALTHCHECK_HEAVY_GLOB. This is the gate that decides whether a
# change is thoroughly checked — a routing bug UNDER-gates a real change. Before this test the
# bucketing had NO direct coverage, and an INVALID HEALTHCHECK_HEAVY_GLOB silently routed to LIGHT
# (the `grep -qE <bad-pattern>` erroring ≥2 reads to `-q` as "no match" → light), quietly weakening
# the gate. This proves BOTH directions of the bucketing and the fail-toward-HEAVY on a bad glob.
#
# Observation seam: heavy delegates to $HEALTHCHECK_CMD (a stub that prints a MARKER), light prints
# "LIGHT CHECK CLEAN" and never the marker — so the emitted verdict tells us which profile ran.
#
# Covers:
#   (1) NON-EMPTY glob, a MATCHING change  → heavy (stub ran)
#   (2) NON-EMPTY glob, a NON-matching change → light (stub did NOT run)
#   (3) red-first guard: inverting the heavy/light branch is CAUGHT — the same inputs that route
#       heavy in (1) must NOT emit the light verdict, and vice-versa (asserted as the nega­tive of
#       each direction), so a swapped branch fails this test.
#   (4) INVALID glob → LOUD warning on stderr + routes HEAVY (never a silent light under-gate).
#   (5) empty glob + a cmd → heavy (a project with no "app" axis); no cmd → light.
#
# Fully hermetic: a throwaway git repo (so _changed_files sees a real diff), a stub HEALTHCHECK_CMD,
# NO network, NO model. Mirrors tests/test-healthcheck-light-probes.sh.
# Run:  bash tests/test-healthcheck-routing.sh
# No `set -e`: some checks assert non-zero returns explicitly.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
HC="$HERE/../scripts/herd/healthcheck.sh"
[ -f "$HC" ] || { echo "healthcheck.sh not found at $HC" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "git required to run this test" >&2; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

# ── A worktree that looks like a real repo (committed seed on 'main') ─────────
WT="$T/wt"; mkdir -p "$WT"
git -C "$WT" init -q
git -C "$WT" checkout -q -b main 2>/dev/null || git -C "$WT" checkout -q main
git -C "$WT" config user.email t@t.test
git -C "$WT" config user.name  herd-test
echo seed > "$WT/seed.txt"; git -C "$WT" add seed.txt; git -C "$WT" commit -qm seed

# A stub project health command: prints a UNIQUE marker and exits clean. If it appears in the output,
# the HEAVY profile delegated to it — i.e. auto routed heavy.
HEAVY_MARKER="STUB_HEAVY_CMD_RAN"
STUB_CMD="$T/stub-health.sh"
cat > "$STUB_CMD" <<STUB
#!/usr/bin/env bash
printf '%s\n' "$HEAVY_MARKER"
exit 0
STUB
chmod +x "$STUB_CMD"

# Config: a real HEALTHCHECK_CMD (so heavy is reachable) + a NON-EMPTY heavy glob. Rewritten per case.
CFG="$T/config"
export HERD_CONFIG_FILE="$CFG"
write_cfg() {  # write_cfg <heavy-glob> [with-cmd:1|0]
  local glob="$1" with_cmd="${2:-1}"
  {
    printf 'PROJECT_ROOT="%s"\n'  "$WT"
    printf 'WORKTREES_DIR="%s"\n' "$T/trees"
    printf 'DEFAULT_BRANCH="main"\n'
    printf 'WORKSPACE_NAME="rtest"\n'
    [ "$with_cmd" = "1" ] && printf 'HEALTHCHECK_CMD="bash %s"\n' "$STUB_CMD"
    printf 'HEALTHCHECK_HEAVY_GLOB=%s\n' "$glob"
  } > "$CFG"
}

# The "diff" is represented by an untracked file at a chosen path (git ls-files --others unions it in).
clear_diff() { rm -rf "$WT/app" "$WT/src" 2>/dev/null || true; }
touch_app()  { clear_diff; mkdir -p "$WT/app"; printf 'echo hi\n' > "$WT/app/thing.sh"; }
touch_src()  { clear_diff; mkdir -p "$WT/src"; printf 'echo hi\n' > "$WT/src/thing.sh"; }
run_auto()   { bash "$HC" "$WT" --auto --oneline 2>"$T/stderr"; }   # --auto is the default, explicit here

# ── (1) NON-EMPTY glob + MATCHING change → heavy (stub ran) ───────────────────
write_cfg '"^app/"'
touch_app
out="$(run_auto)"; rc=$?
[ "$rc" -eq 0 ] || fail "(1) heavy stub is clean → exit 0 (got $rc): $out"
printf '%s' "$out" | grep -q "$HEAVY_MARKER" \
  || fail "(1) a change matching '^app/' must route HEAVY (stub marker expected): $out"
printf '%s' "$out" | grep -q 'light clean' \
  && fail "(1) a matching change must NOT route light: $out"
ok

# ── (2) NON-EMPTY glob + NON-matching change → light (stub did NOT run) ───────
write_cfg '"^app/"'
touch_src
out="$(run_auto)"; rc=$?
[ "$rc" -eq 0 ] || fail "(2) light clean → exit 0 (got $rc): $out"
printf '%s' "$out" | grep -q "$HEAVY_MARKER" \
  && fail "(2) a change NOT matching '^app/' must route LIGHT — the heavy stub must NOT run: $out"
printf '%s' "$out" | grep -q 'light clean' \
  || fail "(2) a non-matching change must emit the light verdict: $out"
ok

# ── (3) red-first: the two directions are MUTUALLY EXCLUSIVE — a swapped branch is caught ─────────
# (1) proved match→heavy and NOT-light; (2) proved no-match→light and NOT-heavy. Together they pin
# both edges, so inverting the `elif grep -qE … heavy / else light` branch flips exactly one of these
# assertions red. This check restates that invariant explicitly for the reader.
write_cfg '"^app/"'
touch_app;  m_app="$(run_auto)"
touch_src;  m_src="$(run_auto)"
{ printf '%s' "$m_app" | grep -q "$HEAVY_MARKER" && printf '%s' "$m_src" | grep -q 'light clean'; } \
  || fail "(3) routing not mutually exclusive (app='$m_app' src='$m_src') — a swapped branch would slip through"
ok

# ── (4) INVALID glob → LOUD warning on stderr + routes HEAVY (never a silent light under-gate) ────
# An unbalanced bracket class is a malformed ERE: `grep -qE '[' ` exits ≥2. Pre-fix this silently
# routed to LIGHT; the fix must warn AND fall to the thorough (heavy) side.
write_cfg "'['"
touch_src   # a NON-heavy path: under the bug this would go light; the fix forces heavy anyway
out="$(run_auto)"; rc=$?
[ "$rc" -eq 0 ] || fail "(4) heavy stub is clean → exit 0 (got $rc): $out"
printf '%s' "$out" | grep -q "$HEAVY_MARKER" \
  || fail "(4) an INVALID HEALTHCHECK_HEAVY_GLOB must FAIL TOWARD HEAVY, not silently light: $out"
grep -q 'invalid HEALTHCHECK_HEAVY_GLOB' "$T/stderr" \
  || fail "(4) an invalid glob must emit a LOUD warning to stderr: $(cat "$T/stderr")"
ok

# ── (5) empty glob + a cmd → heavy; no cmd → light ───────────────────────────
write_cfg '""' 1        # empty glob, WITH a health cmd → "no app axis" → always heavy
touch_src
out="$(run_auto)"
printf '%s' "$out" | grep -q "$HEAVY_MARKER" \
  || fail "(5) empty glob + a health cmd must route HEAVY (no app axis): $out"
ok
write_cfg '"^app/"' 0   # NO health cmd → auto is always light (pure syntax gate), glob is moot
touch_app
out="$(run_auto)"
printf '%s' "$out" | grep -q "$HEAVY_MARKER" \
  && fail "(5) with NO HEALTHCHECK_CMD auto must be LIGHT regardless of the glob: $out"
printf '%s' "$out" | grep -q 'light clean' \
  || fail "(5) no health cmd → light verdict expected: $out"
ok

echo "ALL PASS ($pass checks) — auto routing buckets heavy/light both ways and fails toward heavy on a bad glob."
