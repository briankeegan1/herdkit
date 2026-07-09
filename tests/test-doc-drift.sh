#!/usr/bin/env bash
# test-doc-drift.sh — deterministic, ZERO-LLM guard that README.md + docs/*.md +
# templates/*.tmpl never drift from the machine source of truth,
# templates/capabilities.tsv (HERD-96 README; HERD-168 docs extension; HERD-254 tmpl scan).
#
# README/docs claims are hand-written; capabilities.tsv is the manifest every other surface
# (herd codemap, the coordinator skill, `herd config`) is keyed off. Nothing catches a doc that
# references a `herd <subcommand>` (or a README CONFIG_KEY) that no longer exists — exactly the
# staleness class HERD-82 hand-fixed after the fact. This locks that fix in as a repeatable check
# and the docs-drift analog of the conformance ratchet. HERD-254 extends the same red direction
# to templates/*.tmpl: coordinator.md.tmpl renders into every seat's operating instructions, so
# a phantom command there is MORE damaging than in a design doc.
#
# The check has ONE red direction and ONE advisory direction:
#   • RED  (code-error): every `herd <subcommand>` REFERENCED in README.md + docs/*.md +
#     templates/*.tmpl, and every CONFIG_KEY-shaped token REFERENCED in README.md, must resolve
#     to a row in capabilities.tsv.
#   • WARN (advisory only): capabilities present in the tsv but NOT mentioned in README/docs/
#     templates are listed as an advisory — the docs are curated, not exhaustive, so this NEVER reds.
#
# Extraction is COMMAND-POSITION scoped (see scripts/herd/doc-drift-lint.sh). Fully hermetic:
# local file reads + a temp fixture only. NO herdr, NO gh, NO network, NO model.
# python3 is a herd hard dep (herd doctor verifies it).
# Run:  bash tests/test-doc-drift.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LINT="$ROOT/scripts/herd/doc-drift-lint.sh"
CAPS="$ROOT/templates/capabilities.tsv"
README="$ROOT/README.md"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass(){ PASS=$((PASS+1)); }

[ -f "$LINT" ] || fail "missing shared lint: $LINT"
[ -f "$CAPS" ] || fail "missing required file: $CAPS"
command -v python3 >/dev/null 2>&1 || fail "python3 required"
# shellcheck source=/dev/null
. "$LINT"

# ── 1. The REAL tree is clean: no README/docs/tmpl token drifts from capabilities.tsv ──────────
real_out="$(herd_doc_drift_lint "$ROOT")"; real_rc=$?
if [ "$real_rc" -ne 0 ]; then
  echo "$real_out" | grep '^DRIFT' >&2
  fail "(1) README.md / docs/*.md / templates/*.tmpl drifted from templates/capabilities.tsv (see DRIFT lines above) — fix the reference or add the row to the manifest"
fi
printf '%s\n' "$real_out" | grep -q '^DRIFT' && fail "(1) drift lines present despite clean exit"
pass
echo "PASS (1) README.md + docs/*.md + templates/*.tmpl ↔ capabilities.tsv: every referenced herd command (+ README CONFIG_KEY) resolves (no drift)"

# ── 2. ADVISORY is emitted AND is warn-only ────────────────────────────────────────────────────
printf '%s\n' "$real_out" | grep -q '^ADVISORY:' || fail "(2) advisory summary line missing"
adv_count="$(printf '%s\n' "$real_out" | sed -n 's/^ADVISORY: \([0-9]*\) command.*/\1/p')"
[ -n "$adv_count" ] || fail "(2) could not parse advisory command count"
pass
echo "PASS (2) advisory list is emitted and never reds (real tree exits 0 with capabilities absent from docs)"

# ── 3. DELIBERATE-DRIFT FIXTURE (README): stale command + stale key both caught ─────────────────
FIX_README="$T/README.fixture.md"
cat > "$FIX_README" <<'EOF'
# Fixture README (deliberate drift)

Run `herd status` to check health — a REAL command, must NOT drift.
Set `MERGE_POLICY=approve` in `.herd/config` — a REAL key, must NOT drift.

```bash
$ herd why 123        # real command line — must NOT drift
```

Now the stale references this check must catch:

Run `herd boguscmd` for nothing — a stale command, MUST drift.
Set `TOTALLY_FAKE_KEY=1` somewhere — a stale key, MUST drift.

Prose that must be IGNORED (not command-position): manage several herd projects at once.
EOF

fix_out="$(herd_doc_drift_report "$CAPS" "$FIX_README")"; fix_rc=$?
[ "$fix_rc" -eq 2 ] || fail "(3) README fixture with deliberate drift must exit 2, got $fix_rc"
printf '%s\n' "$fix_out" | grep -q 'DRIFT command:.*`herd boguscmd`' \
  || fail "(3) stale command 'herd boguscmd' not flagged"
printf '%s\n' "$fix_out" | grep -q 'DRIFT config:  README references `TOTALLY_FAKE_KEY`' \
  || fail "(3) stale key 'TOTALLY_FAKE_KEY' not flagged"
printf '%s\n' "$fix_out" | grep -qE 'DRIFT.*(herd status|herd why|MERGE_POLICY|herd projects)' \
  && fail "(3) false positive: a real token or ignored prose was flagged as drift"
pass
echo "PASS (3) README deliberate-drift fixture: stale command + stale key both caught, real tokens + prose untouched"

# ── 4. DELIBERATE-DRIFT FIXTURE (docs/*.md): nonexistent `herd foo` is flagged ──────────────────
# HERD-168 VERIFY: a doc referencing a nonexistent herd command reds; a clean doc passes.
FIX_DOCS="$T/docs"; mkdir -p "$FIX_DOCS"
cat > "$FIX_DOCS/clean.md" <<'EOF'
# Clean doc

Use `herd status` and `herd doctor` — both real. No drift.
EOF
cat > "$FIX_DOCS/stale.md" <<'EOF'
# Stale doc

Operators sometimes invent commands. Run `herd foo` — MUST drift.
A real one stays clean: `herd map`.
EOF

# Clean docs-only surface (no README keys) must pass when every command resolves.
clean_out="$(herd_doc_drift_report "$CAPS" "" "$FIX_DOCS/clean.md")"; clean_rc=$?
[ "$clean_rc" -eq 0 ] || fail "(4a) clean docs fixture must exit 0, got $clean_rc — $clean_out"
printf '%s\n' "$clean_out" | grep -q '^DRIFT' && fail "(4a) clean docs fixture emitted DRIFT lines"
pass
echo "PASS (4a) docs fixture with only real commands passes"

stale_out="$(herd_doc_drift_report "$CAPS" "" "$FIX_DOCS/stale.md")"; stale_rc=$?
[ "$stale_rc" -eq 2 ] || fail "(4b) docs fixture with `herd foo` must exit 2, got $stale_rc"
printf '%s\n' "$stale_out" | grep -q 'DRIFT command:.*`herd foo`' \
  || fail "(4b) stale command 'herd foo' not flagged in docs fixture: $stale_out"
printf '%s\n' "$stale_out" | grep -qE 'DRIFT.*`herd map`' \
  && fail "(4b) false positive: real `herd map` flagged as drift"
pass
echo "PASS (4b) docs deliberate-drift fixture: nonexistent 'herd foo' flagged, real 'herd map' untouched"

# ── 5. Shared lint entrypoint: skip path when no manifest (consuming projects) ─────────────────
# HERD_DOC_DRIFT_SKIP_REASON is set in the function's shell; capture it WITHOUT a subshell so the
# assignment is visible here (command substitution would hide it).
SKIP_ROOT="$T/empty-consumer"; mkdir -p "$SKIP_ROOT"
HERD_DOC_DRIFT_SKIP_REASON=""
herd_doc_drift_lint "$SKIP_ROOT" >/dev/null 2>&1
skip_rc=$?
[ "$skip_rc" -eq 2 ] || fail "(5) no-manifest tree must skip (rc 2), got $skip_rc"
[ -n "${HERD_DOC_DRIFT_SKIP_REASON:-}" ] || fail "(5) HERD_DOC_DRIFT_SKIP_REASON unset on skip"
pass
echo "PASS (5) herd_doc_drift_lint skips (rc 2) when capabilities.tsv is absent — never a false red"

# ── 6. DELIBERATE-DRIFT FIXTURE (templates/*.tmpl): phantom command reds; clean + {{}} pass ────
# HERD-254 VERIFY: a *.tmpl referencing a nonexistent `herd <bogus>` reds; every registered
# command (and template placeholder syntax) passes.
FIX_TMPL="$T/tmpl"; mkdir -p "$FIX_TMPL"
cat > "$FIX_TMPL/clean.md.tmpl" <<'EOF'
# Clean coordinator-style template

You run in `{{PROJECT_ROOT}}` on `{{DEFAULT_BRANCH}}`.
Use `herd status` and `herd backlog` — both real. No drift.
Driver binding stays a placeholder: `{{DRIVER_LIST_AGENTS}}`.
A fenced line with a real command and a placeholder arg must stay clean:

```bash
$ herd config set {{SOME_KEY}} value   # placeholder must not invent a subcommand
```

Inline with a placeholder where a subcommand might have been: `herd {{SUBCOMMAND}}` — must NOT
drift (placeholder stripped; no residual command-position subcommand to check).
EOF
cat > "$FIX_TMPL/stale.md.tmpl" <<'EOF'
# Stale template (would render into seat operating instructions)

Operators sometimes invent commands. Run `herd boguscmd` — MUST drift.
A real one stays clean: `herd notes`.
Also a placeholder that must NOT false-positive: re-render with `herd {{RENDER_CMD}}`.
EOF

clean_tmpl_out="$(herd_doc_drift_report "$CAPS" "" "$FIX_TMPL/clean.md.tmpl")"; clean_tmpl_rc=$?
[ "$clean_tmpl_rc" -eq 0 ] || fail "(6a) clean tmpl fixture must exit 0, got $clean_tmpl_rc — $clean_tmpl_out"
printf '%s\n' "$clean_tmpl_out" | grep -q '^DRIFT' && fail "(6a) clean tmpl fixture emitted DRIFT lines: $clean_tmpl_out"
pass
echo "PASS (6a) templates/*.tmpl fixture with only real commands + {{...}} placeholders passes"

stale_tmpl_out="$(herd_doc_drift_report "$CAPS" "" "$FIX_TMPL/stale.md.tmpl")"; stale_tmpl_rc=$?
[ "$stale_tmpl_rc" -eq 2 ] || fail "(6b) tmpl fixture with `herd boguscmd` must exit 2, got $stale_tmpl_rc"
printf '%s\n' "$stale_tmpl_out" | grep -q 'DRIFT command:.*`herd boguscmd`' \
  || fail "(6b) stale command 'herd boguscmd' not flagged in tmpl fixture: $stale_tmpl_out"
printf '%s\n' "$stale_tmpl_out" | grep -qE 'DRIFT.*`herd notes`' \
  && fail "(6b) false positive: real `herd notes` flagged as drift"
# Placeholder residue must not invent a DRIFT (e.g. empty/partial after strip).
printf '%s\n' "$stale_tmpl_out" | grep -q 'RENDER_CMD' \
  && fail "(6b) false positive from {{...}} placeholder: $stale_tmpl_out"
pass
echo "PASS (6b) templates/*.tmpl deliberate-drift fixture: phantom 'herd boguscmd' flagged; real commands + {{...}} untouched"

# ── 6c. herd_doc_drift_lint discovers templates/*.tmpl under a synthetic tree ──────────────────
# Prove the lint entrypoint (not just the pure report) scans templates/ the same way it scans docs.
LINT_TREE="$T/lint-tree"
mkdir -p "$LINT_TREE/templates" "$LINT_TREE/docs"
cp "$CAPS" "$LINT_TREE/templates/capabilities.tsv"
cat > "$LINT_TREE/templates/coordinator.md.tmpl" <<'EOF'
# synthetic coordinator skill template
Run `herd phantomtmpl` — MUST drift when scanned by herd_doc_drift_lint.
EOF
lint_tmpl_out="$(herd_doc_drift_lint "$LINT_TREE")"; lint_tmpl_rc=$?
[ "$lint_tmpl_rc" -eq 1 ] || fail "(6c) lint entrypoint on tree with phantom tmpl cmd must exit 1 (drift), got $lint_tmpl_rc — $lint_tmpl_out"
printf '%s\n' "$lint_tmpl_out" | grep -q 'DRIFT command:.*`herd phantomtmpl`' \
  || fail "(6c) lint entrypoint did not flag phantom tmpl command: $lint_tmpl_out"
pass
echo "PASS (6c) herd_doc_drift_lint scans templates/*.tmpl under <root> (entrypoint, not just report)"

echo
echo "ALL PASS ($PASS checks) — README + docs/*.md + templates/*.tmpl ↔ capabilities.tsv drift check is live, advisory-safe, and fails on real drift."
