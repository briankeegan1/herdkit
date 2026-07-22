#!/usr/bin/env bash
# test-init-archetypes.sh — hermetic tests for HERD-409: the PROJECT ARCHETYPE axis (code /
# research-lab / docs) alongside the governance postures in templates/postures.tsv.
#
# Grounding: a non-code project ran `herd init`; scout correctly reported language=unknown, but
# init still seeded the Python-test-suite EXAMPLE healthcheck and the interview assumed a
# test/lint/app-preview shape. This axis lets an operator say "this project has no test suite" and
# get a markdown/link/template-conformance lint (healthcheck.docs.sh) instead — chosen by ARCHETYPE,
# not by scout's (often unknown) language guess.
#
# Asserts:
#   (1) unit — archetype-lib.sh: archetype_names/_exists/_healthcheck_template/_intent read
#       templates/archetypes.tsv correctly.
#   (2) unit — _healthcheck_template_for <lang> <archetype>: docs/research-lab OVERRIDE lang
#       (fixed healthcheck.docs.sh regardless of detected stack); archetype=code (or an OMITTED
#       2nd arg — backward compat with the pre-HERD-409 1-arg call) defers to the lang switch,
#       byte-identical to before.
#   (3) NON-INTERACTIVE init: PROJECT_ARCHETYPE="code" written, healthcheck seeded from scout's
#       detected lang (unchanged), no archetype-interview text printed — byte-identical seed.
#   (4) INTERACTIVE, numeric selection, UNKNOWN-lang fixture (no stack marker — the exact grounding
#       scenario): picking "2" (research-lab) seeds healthcheck.docs.sh, writes
#       PROJECT_ARCHETYPE="research-lab", skips the APP_PREVIEW_CMD question.
#   (5) INTERACTIVE, named selection, PYTHON-marked fixture: picking "docs" seeds healthcheck.docs.sh
#       even though scout detects lang=python — proving the archetype axis, not the language guess,
#       decides the seeded healthcheck.
#   (6) INTERACTIVE, explicit "code" on a Go-marked fixture: byte-identical to the non-interactive
#       default (healthcheck.go.sh, PROJECT_ARCHETYPE="code").
#   (7) seeding NEVER clobbers a consumer's existing healthcheck, even under archetype=docs.
#   (8) `herd config set PROJECT_ARCHETYPE <value>` — the validated-key write path (HERD-159):
#       a canonical value persists; an unknown value is REFUSED with an invalid-value message and
#       nothing is written.
#   (9) COMBINED (issue #520): archetype=docs + the docs-lab POSTURE together in one init — the
#       docs-lab bundle (MERGE_POLICY, DOCS_ONLY_GLOB, REVIEW_MODEL_DOCS, MODEL_FEATURE,
#       MODEL_REVIEW) lands as single, non-duplicated config lines alongside PROJECT_ARCHETYPE and
#       the seeded healthcheck.docs.sh.
#
# NO network, NO gh, NO herdr, NO claude: HERD_SKIP_DOCTOR=1 HERD_SKIP_GH_DETECT=1. Interactive
# archetype selection is driven via HERD_ARCHETYPE_ASSUME_TTY + scripted stdin — its OWN test seam,
# so it never consumes the posture/grounding interviews' scripted stdin (they stay non-interactive
# here, since HERD_POSTURE_ASSUME_TTY / HERD_GROUND_ASSUME_TTY are unset and stdin is not a real tty).
# Check (9) is the one exception: it sets BOTH assume-tty seams to compose the archetype AND posture
# interviews in a single scripted init (two stdin lines, one per interview, in prompt order).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
HERD="$REPO/bin/herd"
export HERD REPO

command -v git >/dev/null 2>&1 || { echo "FAIL: git required" >&2; exit 1; }
REAL_BASH="$(command -v bash)"
[ -f "$REPO/templates/archetypes.tsv" ] || { echo "FAIL: archetypes.tsv missing" >&2; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }
plain() { printf '%s' "$1" | sed $'s/\x1b\\[[0-9;]*m//g'; }

# mkproj <dir> [marker-file] — a throwaway git repo, optionally with a stack marker file at its root.
mkproj() {
  local d="$1" marker="${2:-}"
  rm -rf "$d"; mkdir -p "$d"
  git -C "$d" init -q
  git -C "$d" config user.email t@t.t; git -C "$d" config user.name t
  [ -n "$marker" ] && : > "$d/$marker"
  git -C "$d" add -A 2>/dev/null || true
  git -C "$d" commit -q --allow-empty -m init
  git -C "$d" branch -M main
}

# ── (1) unit: archetype-lib.sh reads templates/archetypes.tsv ────────────────────────────────────
alib() { "$REAL_BASH" -c '. "$REPO/scripts/herd/sim/archetype-lib.sh"; "$@"' _ "$@"; }
names="$(alib archetype_names)"
printf '%s\n' "$names" | grep -qx code          || fail "(1) archetype_names missing 'code': $names"
printf '%s\n' "$names" | grep -qx research-lab  || fail "(1) archetype_names missing 'research-lab': $names"
printf '%s\n' "$names" | grep -qx docs          || fail "(1) archetype_names missing 'docs': $names"
alib archetype_exists code            || fail "(1) archetype_exists code should be true"
alib archetype_exists nope            && fail "(1) archetype_exists nope should be false"
[ "$(alib archetype_healthcheck_template code)" = "auto" ]                      || fail "(1) code template should be 'auto'"
[ "$(alib archetype_healthcheck_template research-lab)" = "healthcheck.docs.sh" ] || fail "(1) research-lab template wrong"
[ "$(alib archetype_healthcheck_template docs)" = "healthcheck.docs.sh" ]         || fail "(1) docs template wrong"
[ -n "$(alib archetype_intent docs)" ]  || fail "(1) docs intent should be non-empty"
ok

# ── (2) unit: _healthcheck_template_for <lang> [<archetype>] ─────────────────────────────────────
tmpl_for() { "$REAL_BASH" -c '. "$HERD" help >/dev/null 2>&1; _healthcheck_template_for "$1" "${2:-}"' _ "$1" "${2:-}"; }
[ "$(tmpl_for go)"                     = "healthcheck.go.sh" ]      || fail "(2) 1-arg go (backward compat) → $(tmpl_for go)"
[ "$(tmpl_for python)"                 = "healthcheck.project.sh" ] || fail "(2) 1-arg python (backward compat) → $(tmpl_for python)"
[ "$(tmpl_for go code)"                = "healthcheck.go.sh" ]      || fail "(2) go+code should defer to lang → $(tmpl_for go code)"
[ "$(tmpl_for python docs)"            = "healthcheck.docs.sh" ]    || fail "(2) python+docs should override → $(tmpl_for python docs)"
[ "$(tmpl_for unknown research-lab)"   = "healthcheck.docs.sh" ]    || fail "(2) unknown+research-lab should override → $(tmpl_for unknown research-lab)"
[ "$(tmpl_for node research-lab)"      = "healthcheck.docs.sh" ]    || fail "(2) node+research-lab should override → $(tmpl_for node research-lab)"
ok

# ── (3) NON-INTERACTIVE init: byte-identical seeded default (archetype=code) ─────────────────────
proj="$T/noninteractive"; mkproj "$proj" "go.mod"
out="$( cd "$proj" && HERD_NONINTERACTIVE=1 HERD_SKIP_DOCTOR=1 HERD_SKIP_GH_DETECT=1 \
        "$REAL_BASH" "$HERD" init 2>&1 )" || fail "(3) init failed: $out"
pout="$(plain "$out")"
echo "$pout" | grep -q "Project archetype" && fail "(3) non-interactive must NOT run the archetype interview: $out"
grep -qE '^PROJECT_ARCHETYPE="code"$' "$proj/.herd/config" || fail "(3) PROJECT_ARCHETYPE should default to code: $(grep PROJECT_ARCHETYPE "$proj/.herd/config")"
cmp -s "$proj/.herd/healthcheck.project.sh" "$REPO/templates/healthcheck.go.sh" \
  || fail "(3) go consumer should still get healthcheck.go.sh"
ok

# ── (4) INTERACTIVE numeric pick, UNKNOWN-lang fixture (the exact grounding scenario) ────────────
proj="$T/unknown-research"; mkproj "$proj"
out="$( cd "$proj" && printf '2\n' \
        | HERD_ARCHETYPE_ASSUME_TTY=1 HERD_SKIP_DOCTOR=1 HERD_SKIP_GH_DETECT=1 \
          "$REAL_BASH" "$HERD" init 2>&1 )" || fail "(4) init failed: $out"
pout="$(plain "$out")"
echo "$pout" | grep -qi "language=unknown"        || fail "(4) scout should report lang=unknown: $out"
echo "$pout" | grep -q "archetype=research-lab"    || fail "(4) should announce the selected archetype: $out"
echo "$pout" | grep -qi "no app to preview"        || fail "(4) should explain the skipped app-preview question: $out"
grep -qE '^PROJECT_ARCHETYPE="research-lab"$' "$proj/.herd/config" || fail "(4) PROJECT_ARCHETYPE not persisted: $(grep PROJECT_ARCHETYPE "$proj/.herd/config")"
grep -qE '^APP_PREVIEW_CMD=""$' "$proj/.herd/config" || fail "(4) APP_PREVIEW_CMD should stay blank: $(grep APP_PREVIEW_CMD "$proj/.herd/config")"
cmp -s "$proj/.herd/healthcheck.project.sh" "$REPO/templates/healthcheck.docs.sh" \
  || fail "(4) research-lab should seed healthcheck.docs.sh, not the Python example"
ok

# ── (5) INTERACTIVE named pick "docs" on a PYTHON-marked fixture — archetype wins over lang ──────
proj="$T/python-docs"; mkproj "$proj" "pyproject.toml"
out="$( cd "$proj" && printf 'docs\n' \
        | HERD_ARCHETYPE_ASSUME_TTY=1 HERD_SKIP_DOCTOR=1 HERD_SKIP_GH_DETECT=1 \
          "$REAL_BASH" "$HERD" init 2>&1 )" || fail "(5) init failed: $out"
pout="$(plain "$out")"
echo "$pout" | grep -qi "language=python" || fail "(5) scout should still detect python: $out"
cmp -s "$proj/.herd/healthcheck.project.sh" "$REPO/templates/healthcheck.docs.sh" \
  || fail "(5) archetype=docs must override the python-detected template"
grep -qE '^PROJECT_ARCHETYPE="docs"$' "$proj/.herd/config" || fail "(5) PROJECT_ARCHETYPE not persisted"
ok

# ── (6) INTERACTIVE explicit "code" on a Go fixture — byte-identical to the default ──────────────
proj="$T/explicit-code"; mkproj "$proj" "go.mod"
out="$( cd "$proj" && printf 'code\n' \
        | HERD_ARCHETYPE_ASSUME_TTY=1 HERD_SKIP_DOCTOR=1 HERD_SKIP_GH_DETECT=1 \
          "$REAL_BASH" "$HERD" init 2>&1 )" || fail "(6) init failed: $out"
grep -qE '^PROJECT_ARCHETYPE="code"$' "$proj/.herd/config" || fail "(6) PROJECT_ARCHETYPE should be code"
cmp -s "$proj/.herd/healthcheck.project.sh" "$REPO/templates/healthcheck.go.sh" \
  || fail "(6) explicit code archetype should still defer to lang (go)"
ok

# ── (7) seeding NEVER clobbers a consumer's existing healthcheck, even under archetype=docs ──────
proj="$T/existing"; mkproj "$proj"
mkdir -p "$proj/.herd"; printf '#!/usr/bin/env bash\n# MINE — do not touch\nexit 0\n' > "$proj/.herd/healthcheck.project.sh"
out="$( cd "$proj" && printf 'docs\n' \
        | HERD_ARCHETYPE_ASSUME_TTY=1 HERD_SKIP_DOCTOR=1 HERD_SKIP_GH_DETECT=1 \
          "$REAL_BASH" "$HERD" init 2>&1 )" || fail "(7) init failed: $out"
grep -q "MINE — do not touch" "$proj/.herd/healthcheck.project.sh" || fail "(7) init clobbered an existing healthcheck"
ok

# ── (8) herd config set PROJECT_ARCHETYPE — validated-key write path (HERD-159) ──────────────────
proj="$T/configset"; mkproj "$proj" "go.mod"
( cd "$proj" && HERD_NONINTERACTIVE=1 HERD_SKIP_DOCTOR=1 HERD_SKIP_GH_DETECT=1 \
    "$REAL_BASH" "$HERD" init >/dev/null 2>&1 ) || fail "(8) init failed"
out="$( cd "$proj" && "$REAL_BASH" "$HERD" config set PROJECT_ARCHETYPE research-lab 2>&1 )"; rc=$?
[ "$rc" -eq 0 ] || fail "(8) valid config set failed: $out"
grep -qE '^PROJECT_ARCHETYPE="research-lab"$' "$proj/.herd/config" || fail "(8) valid value not persisted: $(grep PROJECT_ARCHETYPE "$proj/.herd/config")"
out="$( cd "$proj" && "$REAL_BASH" "$HERD" config set PROJECT_ARCHETYPE webapp 2>&1 )"; rc=$?
[ "$rc" -ne 0 ] || fail "(8) set accepted unknown PROJECT_ARCHETYPE=webapp"
printf '%s\n' "$out" | grep -qi 'invalid value' || fail "(8) unknown value missing invalid-value message: $out"
grep -qE '^PROJECT_ARCHETYPE="webapp"$' "$proj/.herd/config" && fail "(8) invalid value was written"
ok

# ── (9) COMBINED (issue #520): archetype=docs + posture=docs-lab in one init ──────────────────────
proj="$T/combined"; mkproj "$proj"
out="$( cd "$proj" && printf 'docs\ndocs-lab\n' \
        | HERD_ARCHETYPE_ASSUME_TTY=1 HERD_POSTURE_ASSUME_TTY=1 HERD_SKIP_DOCTOR=1 HERD_SKIP_GH_DETECT=1 \
          "$REAL_BASH" "$HERD" init 2>&1 )" || fail "(9) init failed: $out"
cfg="$proj/.herd/config"
grep -qE '^PROJECT_ARCHETYPE="docs"$'            "$cfg" || fail "(9) PROJECT_ARCHETYPE not persisted"
cmp -s "$proj/.herd/healthcheck.project.sh" "$REPO/templates/healthcheck.docs.sh" \
  || fail "(9) archetype=docs should seed healthcheck.docs.sh"
grep -qE '^MERGE_POLICY="auto"$'                 "$cfg" || fail "(9) docs-lab MERGE_POLICY not persisted"
grep -qE '^DOCS_ONLY_GLOB="\\.\(md\|txt\)\$"$'   "$cfg" || fail "(9) docs-lab DOCS_ONLY_GLOB not persisted: $(grep DOCS_ONLY_GLOB "$cfg")"
grep -qE '^REVIEW_MODEL_DOCS="claude-haiku-4-5"$' "$cfg" || fail "(9) docs-lab REVIEW_MODEL_DOCS not persisted"
grep -qE '^MODEL_FEATURE="claude-haiku-4-5"$'    "$cfg" || fail "(9) docs-lab MODEL_FEATURE not persisted"
grep -qE '^MODEL_REVIEW="claude-haiku-4-5"$'     "$cfg" || fail "(9) docs-lab MODEL_REVIEW not persisted"
# No duplicate MODEL_* lines — the bundle must interpolate into the base line, never append a second.
[ "$(grep -cE '^MODEL_FEATURE=' "$cfg")" -eq 1 ] || fail "(9) MODEL_FEATURE duplicated: $(grep MODEL_FEATURE "$cfg")"
[ "$(grep -cE '^MODEL_REVIEW='  "$cfg")" -eq 1 ] || fail "(9) MODEL_REVIEW duplicated: $(grep MODEL_REVIEW "$cfg")"
ok

echo "ALL PASS ($pass checks)"
