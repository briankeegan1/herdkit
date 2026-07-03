#!/usr/bin/env bash
# test-stack-aware-init.sh — hermetic tests for STACK-AWARE `herd init`: scout's detected `lang`
# threaded through to the healthcheck template it seeds and the (blank) heavy/app-surface globs.
# See docs/external-consumer-audit.md (ranked follow-up #3 [P1], leaks D & B).
#
# NO network, NO gh, NO herdr, NO claude, NO model call: init runs with
# HERD_NONINTERACTIVE=1 HERD_SKIP_DOCTOR=1 HERD_SKIP_GH_DETECT=1 against throwaway git repos.
# Asserts:
#   (1) unit — _healthcheck_template_for maps each lang → the right template; scout detects java.
#   (2) Go fixture: init seeds .herd/healthcheck.project.sh byte-identical to templates/healthcheck.go.sh,
#       and writes BLANK heavy/app-surface globs (no leaked '^app/').
#   (3) Rust + Java fixtures: seed their respective templates (go/rust/java support).
#   (4) Python + Node fixtures UNCHANGED: config globs blank + HEALTHCHECK_CMD default, and the
#       seeded template is exactly the Python (healthcheck.project.sh) / Node (healthcheck.node.sh) one.
#   (5) seeding NEVER clobbers a consumer's own .herd/healthcheck.project.sh.
#   (6) regression guard: templates/config.example no longer defaults HEALTHCHECK_HEAVY_GLOB to '^app/'.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
HERD="$REPO/bin/herd"
export HERD

command -v git >/dev/null 2>&1 || { echo "FAIL: git required" >&2; exit 1; }
REAL_BASH="$(command -v bash)"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

# mkproj <dir> <marker-file> — a throwaway git repo with the given stack marker file at its root.
mkproj() {
  local d="$1" marker="$2"
  rm -rf "$d"; mkdir -p "$d"
  git -C "$d" init -q
  git -C "$d" config user.email t@t.t; git -C "$d" config user.name t
  [ -n "$marker" ] && : > "$d/$marker"
  git -C "$d" add -A 2>/dev/null || true
  git -C "$d" commit -q --allow-empty -m init
}

# run_init <dir> — run `herd init` hermetically inside <dir>; echoes plain-text output.
run_init() {
  ( cd "$1" && HERD_NONINTERACTIVE=1 HERD_SKIP_DOCTOR=1 HERD_SKIP_GH_DETECT=1 \
      "$REAL_BASH" "$HERD" init 2>&1 )
}

# ── (1) unit: _healthcheck_template_for mapping + scout java detection ────────────────────────────
tmpl_for() { "$REAL_BASH" -c '. "$HERD" help >/dev/null 2>&1; _healthcheck_template_for "$1"' _ "$1"; }
[ "$(tmpl_for go)"      = "healthcheck.go.sh" ]      || fail "(1) go → $(tmpl_for go)"
[ "$(tmpl_for rust)"    = "healthcheck.rust.sh" ]    || fail "(1) rust → $(tmpl_for rust)"
[ "$(tmpl_for java)"    = "healthcheck.java.sh" ]    || fail "(1) java → $(tmpl_for java)"
[ "$(tmpl_for node)"    = "healthcheck.node.sh" ]    || fail "(1) node → $(tmpl_for node)"
[ "$(tmpl_for python)"  = "healthcheck.project.sh" ] || fail "(1) python → $(tmpl_for python)"
[ "$(tmpl_for unknown)" = "healthcheck.project.sh" ] || fail "(1) unknown → $(tmpl_for unknown)"
scout_lang() { "$REAL_BASH" -c '. "$HERD" help >/dev/null 2>&1; scout_repo "$1"' _ "$1" | sed -n 's/^lang=//p'; }
jproj="$T/scout-java"; mkproj "$jproj" "pom.xml"
[ "$(scout_lang "$jproj")" = "java" ] || fail "(1) scout should detect java from pom.xml (got $(scout_lang "$jproj"))"
ok

# ── (2) Go fixture: seeds the Go template + writes blank globs (no '^app/') ───────────────────────
proj="$T/go"; mkproj "$proj" "go.mod"
out="$(run_init "$proj")" || fail "(2) go init failed: $out"
echo "$out" | grep -qi "language=go"                          || fail "(2) scout should report lang=go: $out"
cmp -s "$proj/.herd/healthcheck.project.sh" "$REPO/templates/healthcheck.go.sh" \
  || fail "(2) seeded healthcheck should equal templates/healthcheck.go.sh"
[ -x "$proj/.herd/healthcheck.project.sh" ]                   || fail "(2) seeded healthcheck should be executable"
grep -qE '^HEALTHCHECK_HEAVY_GLOB=""$' "$proj/.herd/config"   || fail "(2) heavy glob must be blank: $(grep HEALTHCHECK_HEAVY_GLOB "$proj/.herd/config")"
grep -q '\^app/' "$proj/.herd/config"                         && fail "(2) generated config must not leak ^app/"
grep -qE '^HEALTHCHECK_CMD="\.herd/healthcheck\.project\.sh"$' "$proj/.herd/config" || fail "(2) HEALTHCHECK_CMD default missing"
ok

# ── (3) Rust + Java fixtures: seed their respective templates ─────────────────────────────────────
proj="$T/rust"; mkproj "$proj" "Cargo.toml"; out="$(run_init "$proj")" || fail "(3) rust init failed: $out"
cmp -s "$proj/.herd/healthcheck.project.sh" "$REPO/templates/healthcheck.rust.sh" || fail "(3) rust template not seeded"
proj="$T/java"; mkproj "$proj" "pom.xml"; out="$(run_init "$proj")" || fail "(3) java init failed: $out"
cmp -s "$proj/.herd/healthcheck.project.sh" "$REPO/templates/healthcheck.java.sh" || fail "(3) java template not seeded"
ok

# ── (4) Python + Node UNCHANGED: blank globs, default HEALTHCHECK_CMD, and the SAME template each ─
proj="$T/py"; mkproj "$proj" "pyproject.toml"; out="$(run_init "$proj")" || fail "(4) py init failed: $out"
echo "$out" | grep -qi "language=python"                     || fail "(4) scout should report lang=python: $out"
cmp -s "$proj/.herd/healthcheck.project.sh" "$REPO/templates/healthcheck.project.sh" \
  || fail "(4) Python consumer must still get healthcheck.project.sh (unchanged)"
grep -qE '^HEALTHCHECK_HEAVY_GLOB=""$' "$proj/.herd/config"  || fail "(4) python heavy glob must be blank"
grep -q '\^app/' "$proj/.herd/config"                        && fail "(4) python config must not leak ^app/"

proj="$T/node"; mkproj "$proj" "package.json"; out="$(run_init "$proj")" || fail "(4) node init failed: $out"
echo "$out" | grep -qi "language=node"                       || fail "(4) scout should report lang=node: $out"
cmp -s "$proj/.herd/healthcheck.project.sh" "$REPO/templates/healthcheck.node.sh" \
  || fail "(4) Node consumer must get healthcheck.node.sh (unchanged)"
grep -qE '^HEALTHCHECK_HEAVY_GLOB=""$' "$proj/.herd/config"  || fail "(4) node heavy glob must be blank"
ok

# ── (5) seeding NEVER clobbers a consumer's existing healthcheck ──────────────────────────────────
proj="$T/existing"; mkproj "$proj" "go.mod"
mkdir -p "$proj/.herd"; printf '#!/usr/bin/env bash\n# MINE — do not touch\nexit 0\n' > "$proj/.herd/healthcheck.project.sh"
out="$(run_init "$proj")" || fail "(5) init failed: $out"
grep -q "MINE — do not touch" "$proj/.herd/healthcheck.project.sh" || fail "(5) init clobbered an existing healthcheck"
ok

# ── (6) regression guard: config.example no longer defaults the heavy glob to '^app/' ─────────────
grep -qE '^HEALTHCHECK_HEAVY_GLOB=""' "$REPO/templates/config.example" || fail "(6) config.example heavy glob default must be blank"
grep -qE '^HEALTHCHECK_HEAVY_GLOB="\^app/"' "$REPO/templates/config.example" && fail "(6) config.example still leaks ^app/ default"
ok

echo "ALL PASS ($pass checks)"
