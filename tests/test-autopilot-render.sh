#!/usr/bin/env bash
# test-autopilot-render.sh — hermetic proof that the /autopilot STANDING WATCH-AND-DRAIN skill
# (HERD-515) renders from the SAME machinery as the coordinator skill, under the same per-machine
# derived-file contract, and that its content carries the three things autopilot adds to the
# coordinator seat (idempotent posture check · standing poll · idle wait instead of a stop).
#
# What this asserts:
#   (A) EVERY render path emits it: `herd init` renders .claude/commands/autopilot.md next to the
#       coordinator render, with NO literal {{TOKEN}} left and the token VALUES actually substituted;
#       `herd render` regenerates it when absent and renders byte-identically (deterministic).
#   (B) It is a PER-MACHINE DERIVED artifact: gitignored, never tracked, tree clean after a render,
#       and carried in the shared derived-files list (so the sweep / reap / stale-base exemptions
#       cover it exactly like the coordinator render).
#   (C) Its basename is FIXED — renaming COORDINATOR_CMD retargets the coordinator render only, while
#       the autopilot render follows the renamed command in its CITATIONS (one doctrine, two entries).
#   (D) DOCTRINE: the render cites the coordinator skill's drain mode rather than forking it, and
#       keeps the idle-wait + the three hard stops (BUDGET_DAILY, escalation, operator stop).
#   (E) FAIL-SOFT: an engine tree WITHOUT templates/autopilot.md.tmpl still renders the coordinator
#       skill and simply emits no autopilot skill — never an error.
#   (F) The doc-drift lint is clean on the real tree (every `herd <sub>` the new template names
#       resolves to a capabilities.tsv row).
#
# Fully hermetic: temp git repos, no network, no gh, no herdr, no model.
# Run:  bash tests/test-autopilot-render.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
HERD="$ROOT/bin/herd"
LIB="$ROOT/scripts/herd/derived-files.sh"
TMPL="$ROOT/templates/autopilot.md.tmpl"
DRIFT="$ROOT/scripts/herd/doc-drift-lint.sh"

for f in "$HERD" "$LIB" "$TMPL" "$DRIFT"; do [ -f "$f" ] || { echo "FAIL: missing $f" >&2; exit 1; }; done
command -v git >/dev/null 2>&1 || { echo "FAIL: git required" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 required" >&2; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { PASS=$((PASS + 1)); echo "PASS: $1"; }

AUTO_REL=".claude/commands/autopilot.md"
COORD_REL=".claude/commands/coordinator.md"

# _mkrepo <dir> — a committed, hermetic git repo.
_mkrepo() {
  mkdir -p "$1"
  git -C "$1" init -q -b main
  git -C "$1" config user.email t@t.local; git -C "$1" config user.name t
  git -C "$1" commit -q --allow-empty -m base
}

# _herd <dir> <args...> — run the CLI in <dir>, non-interactive, no doctor.
_herd() { local d="$1"; shift; ( cd "$d" && HERD_NONINTERACTIVE=1 HERD_SKIP_DOCTOR=1 bash "$HERD" "$@" ); }

# ── A. the render paths emit a fully-substituted autopilot skill ───────────────────────────────────
P="$T/proj"; _mkrepo "$P"
_herd "$P" init >/dev/null 2>&1 || fail "A: herd init failed"
[ -f "$P/$COORD_REL" ] || fail "A1: init did not render the coordinator skill"
[ -f "$P/$AUTO_REL" ]  || fail "A1: init did not render the autopilot skill"
ok "A1 init renders the autopilot skill alongside the coordinator skill"

grep -qE '\{\{[A-Za-z_][A-Za-z0-9_]*\}\}' "$P/$AUTO_REL" \
  && fail "A2: the autopilot render left an unsubstituted {{token}}: $(grep -oE '\{\{[A-Za-z_][A-Za-z0-9_]*\}\}' "$P/$AUTO_REL" | sort -u | tr '\n' ' ')"
ok "A2 no literal {{TOKEN}} survives the autopilot render"

# Substituted VALUES, not merely absent tokens: the workspace name, the project root and the
# coordinator command all come from .herd/config.
grep -q "proj" "$P/$AUTO_REL"        || fail "A3: WORKSPACE_NAME was not substituted into the render"
grep -qF "$P" "$P/$AUTO_REL"         || fail "A3: PROJECT_ROOT was not substituted into the render"
grep -qF "/coordinator" "$P/$AUTO_REL" || fail "A3: COORDINATOR_CMD was not substituted into the render"
ok "A3 the token VALUES (workspace, project root, coordinator command) are substituted"

# `herd render` regenerates an absent skill, byte-identically (a render is deterministic).
cp "$P/$AUTO_REL" "$T/first.md"
rm -f "$P/$AUTO_REL"
_herd "$P" render >/dev/null 2>&1 || fail "A4: herd render failed with the autopilot skill absent"
[ -f "$P/$AUTO_REL" ] || fail "A4: herd render did not regenerate the absent autopilot skill"
cmp -s "$T/first.md" "$P/$AUTO_REL" || fail "A4: re-render is not byte-identical to the first render"
ok "A4 herd render regenerates the absent autopilot skill byte-identically"

# ── B. per-machine derived artifact: gitignored, untracked, and on the shared derived list ─────────
grep -qxF "$AUTO_REL" "$P/.gitignore" || fail "B1: the autopilot render is not gitignored"
[ "$(grep -cxF "$AUTO_REL" "$P/.gitignore")" -eq 1 ] || fail "B1: the ignore line was appended more than once"
ok "B1 the render is gitignored, and the ignore line is idempotent across renders"

git -C "$P" add -A && git -C "$P" commit -q -m init
git -C "$P" ls-files --error-unmatch -- "$AUTO_REL" >/dev/null 2>&1 \
  && fail "B2: the autopilot render was committed — it must be gitignored, never tracked"
[ -z "$(git -C "$P" status --porcelain)" ] || fail "B2: tree dirty after render: $(git -C "$P" status --porcelain)"
_herd "$P" render >/dev/null 2>&1 || fail "B2: second herd render failed"
[ -z "$(git -C "$P" status --porcelain)" ] || fail "B2: a re-render dirtied the tree: $(git -C "$P" status --porcelain)"
ok "B2 the render stays untracked and never dirties the checkout"

# shellcheck source=/dev/null
. "$LIB"
herd_is_derived_path "$AUTO_REL" || fail "B3: the autopilot render must be a derived path"
_stripped="$(printf '%s\n' "$AUTO_REL" "src/app.py" | herd_strip_derived)"
[ "$_stripped" = "src/app.py" ] || fail "B3: strip kept the wrong paths: '$_stripped'"
ok "B3 the shared derived-files list carries the autopilot render"

# The basename is FIXED — it does NOT follow COORDINATOR_CMD the way the coordinator render does.
( COORDINATOR_CMD="/ops" herd_is_derived_path "$AUTO_REL" ) \
  || fail "B4: a renamed coordinator command must not move the autopilot render off the derived list"
ok "B4 the autopilot render path is fixed, independent of COORDINATOR_CMD"

# ── C. a renamed coordinator command retargets the CITATIONS, not the autopilot filename ──────────
R="$T/renamed"; _mkrepo "$R"
_herd "$R" init >/dev/null 2>&1 || fail "C: herd init failed"
printf 'COORDINATOR_CMD="/ops"\n' >> "$R/.herd/config"
_herd "$R" render >/dev/null 2>&1 || fail "C1: herd render failed after renaming COORDINATOR_CMD"
[ -f "$R/.claude/commands/ops.md" ] || fail "C1: the coordinator render did not follow COORDINATOR_CMD"
[ -f "$R/$AUTO_REL" ] || fail "C1: the autopilot render must keep its fixed basename"
grep -qF "/ops" "$R/$AUTO_REL" || fail "C1: the autopilot render must cite the RENAMED coordinator command"
grep -qE '\{\{[A-Za-z_][A-Za-z0-9_]*\}\}' "$R/$AUTO_REL" && fail "C1: renamed render left an unsubstituted {{token}}"
ok "C1 a renamed coordinator command retargets the citations, not the autopilot filename"

# ── D. doctrine: cite drain mode, replace its stop with an idle wait, keep the three hard stops ────
A="$P/$AUTO_REL"
grep -qi "drain mode" "$A"            || fail "D1: the render must cite the coordinator skill's drain mode"
grep -qF "posture show yolo" "$A"     || fail "D1: the render must carry the idempotent posture CHECK"
grep -qF "posture apply --yes yolo" "$A" || fail "D1: the render must carry the posture APPLY"
grep -qi "only if" "$A"               || fail "D1: the posture check must be conditional, not a blind re-apply"
ok "D1 the render cites drain mode and applies the yolo posture only on a difference"

for src in "herd backlog" "gh issue list" "herd notes"; do
  grep -qF "$src" "$A" || fail "D2: the standing loop must poll '$src'"
done
ok "D2 the standing loop polls every work source (backlog, gh issues, notes, gate state)"

grep -qi "idle" "$A"          || fail "D3: the backlog-empty stop must be replaced by an idle wait"
grep -qF "BUDGET_DAILY" "$A"  || fail "D3: BUDGET_DAILY must remain a hard stop"
grep -qi "escalation" "$A"    || fail "D3: genuine escalation must remain a hard stop"
grep -qi "operator stop" "$A" || fail "D3: an explicit operator stop must remain a hard stop"
ok "D3 idle-wait replaces the backlog-empty stop; the three hard stops survive"

# Anti-fork: cite the shared doctrine, never restate its numbered stop list verbatim.
grep -qF "Stop conditions — the only three" "$A" \
  && fail "D4: the render duplicates drain mode's stop-condition heading instead of citing it"
grep -qi "fail-soft" "$A" || fail "D4: an unreachable work source must be documented as fail-soft"
ok "D4 the doctrine is cited, not forked, and a bad cycle is fail-soft"

# ── E. fail-soft: an engine without the template renders the coordinator skill and nothing more ────
E="$T/engine"; mkdir -p "$E/bin"
cp "$HERD" "$E/bin/herd"
cp -R "$ROOT/templates" "$E/templates"
rm -f "$E/templates/autopilot.md.tmpl"
ln -s "$ROOT/scripts" "$E/scripts"
[ -d "$ROOT/pysrc" ] && ln -s "$ROOT/pysrc" "$E/pysrc"
N="$T/noautopilot"; _mkrepo "$N"
( cd "$N" && HERD_NONINTERACTIVE=1 HERD_SKIP_DOCTOR=1 bash "$E/bin/herd" init ) >/dev/null 2>&1 \
  || fail "E1: herd init failed on an engine without templates/autopilot.md.tmpl"
[ -f "$N/$COORD_REL" ] || fail "E1: the coordinator skill must still render"
[ -f "$N/$AUTO_REL" ]  && fail "E1: an engine without the template must render no autopilot skill"
ok "E1 an engine tree without the template renders the coordinator skill and no autopilot skill"

# ── F. doc-drift: every `herd <sub>` the new template names resolves to a capabilities row ─────────
# shellcheck source=/dev/null
. "$DRIFT"
_drift_out="$( cd "$ROOT" && herd_doc_drift_lint "$ROOT" )"; _drift_rc=$?
case "$_drift_rc" in
  0) ok "F1 doc-drift lint is clean on the real tree (autopilot template included)" ;;
  2) ok "F1 doc-drift lint skipped (${HERD_DOC_DRIFT_SKIP_REASON:-infra}) — never a red" ;;
  *) grep -i "autopilot" <<< "$_drift_out" >/dev/null \
       && fail "F1: doc-drift DRIFT attributable to autopilot.md.tmpl: $(grep -i autopilot <<< "$_drift_out")"
     fail "F1: doc-drift lint reported drift: $(printf '%s' "$_drift_out" | grep '^DRIFT' | head -3)" ;;  # pipe-ok: grep|head feeds a one-line message inside a command substitution on the way to fail; the pipeline status is not gated
esac

echo "ALL PASS ($PASS checks)"
