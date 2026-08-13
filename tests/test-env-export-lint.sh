#!/usr/bin/env bash
# test-env-export-lint.sh — hermetic tests for the shared shell→python EXPORT guard (HERD-449):
# scripts/herd/env-export-lint.sh reds a config knob pysrc/herd/live_runtime.py's _CORE_ENV_KEYS reads
# from os.environ that is SET after herd-config.sh sources but not `export`ed — the exact bug shape
# that stranded HEALTH_CONCURRENCY/REVIEW_CONCURRENCY (three prior items, HERD-353/345/359, each fixed
# this same bug by hand for ONE key).
#
# Proves:
#   (1) The REAL tree is clean: herd-config.sh exports every _CORE_ENV_KEYS member it sets.
#   (2) MUTATION-PROVE: removing ONE `export` line from a temp copy of herd-config.sh reds the lint,
#       naming exactly that key — and ONLY that key.
#   (3) A key with no default anywhere (genuinely unset) never false-reds: os.environ.get() reads the
#       identical None whether or not an unset shell var carries the export attribute.
#   (4) A project override in .herd/config (KEY=val with no `export`) reds too — not just the built-in
#       `: "${KEY:=default}"` line — since it is the exact "set but not exported" shape either way.
#   (5) FAIL-SOFT: a tree missing herd-config.sh / pysrc → skip (exit 2), never a red.
#
# Network-free: temp dirs + fixtures only. Run:  bash tests/test-env-export-lint.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LINT="$ROOT/scripts/herd/env-export-lint.sh"

# HERD-458: pin our own precondition — a CONFIGURED caller can leave an ambient EXPORTED core key
# (e.g. HEALTH_CONCURRENCY=2) already in this process's environment. That ambient export attribute
# survives even a MUTATED herd-config.sh copy that no longer exports the key itself (§2 below), which
# is exactly the false-green the mutation-prove leg exists to catch. The shared harness scrub
# (scripts/herd/hermetic-env-scrub.sh) already does this once per suite run; re-arm it here too so
# this test is self-sufficient run alone.
if [ -f "$ROOT/scripts/herd/hermetic-env-scrub.sh" ]; then
  # shellcheck source=/dev/null
  . "$ROOT/scripts/herd/hermetic-env-scrub.sh"
  herd_hermetic_env_scrub "$ROOT/scripts/herd/herd-config.sh"
fi

[ -f "$LINT" ] || { echo "FAIL: missing lint: $LINT" >&2; exit 1; }
# shellcheck source=/dev/null
. "$LINT"

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not available"; exit 0; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { PASS=$((PASS+1)); }

# make_tree <dir> — a minimal engine-shaped tree: a real copy of herd-config.sh + the FULL pysrc/herd
# package (live_runtime.py imports sibling modules — cost_emit, decisions, shadow_runtime,
# shadow_journal — so a single-file copy fails to import) so the python side introspects the SAME
# _CORE_ENV_KEYS the real engine does.
make_tree() {
  local d="$1"
  rm -rf "$d"
  mkdir -p "$d/scripts/herd" "$d/pysrc" "$d/.herd"
  cp "$ROOT/scripts/herd/herd-config.sh" "$d/scripts/herd/herd-config.sh"
  cp -R "$ROOT/pysrc/herd" "$d/pysrc/herd"
}

# ── 1. Real tree is clean ─────────────────────────────────────────────────────────────────────────
HERD_ENV_EXPORT_SKIP_REASON=""
real_out="$(herd_env_export_lint "$ROOT")"; real_rc=$?
[ "$real_rc" -eq 0 ] || fail "(1) real tree has an unexported core-consumed key: $real_out"
[ -z "$real_out" ] || fail "(1) clean exit must emit zero lines (got: $real_out)"
pass
echo "PASS (1) real tree: every _CORE_ENV_KEYS member herd-config.sh sets is exported"

# ── 2. Mutation-prove: drop ONE export, the lint reds exactly that key ──────────────────────────────
TM="$T/mutated"
make_tree "$TM"
python3 - "$TM/scripts/herd/herd-config.sh" <<'PYEOF'
import re, sys
path = sys.argv[1]
src = open(path, encoding="utf-8").read()
new = src.replace(
    "       WORK_UNIT_KIND MERGE_RESULT_GATE MERGE_QUEUE HEALTH_CONCURRENCY REVIEW_CONCURRENCY \\\n",
    "       WORK_UNIT_KIND MERGE_RESULT_GATE MERGE_QUEUE REVIEW_CONCURRENCY \\\n",
    1,
)
if new == src:
    sys.exit("mutation anchor not found — herd-config.sh's export line changed shape")
open(path, "w", encoding="utf-8").write(new)
PYEOF
[ $? -eq 0 ] || fail "(2) mutation setup failed — see stderr above"
out="$(herd_env_export_lint "$TM")"; rc=$?
[ "$rc" -eq 1 ] || fail "(2) an unexported-but-set core key must red (exit 1, got $rc): $out"
[ "$out" = "HEALTH_CONCURRENCY" ] || fail "(2) expected exactly 'HEALTH_CONCURRENCY' flagged (got: $out)"
pass
echo "PASS (2) mutation-prove: dropping HEALTH_CONCURRENCY's export reds it, and ONLY it"

# …and the untouched sibling key confirms the lint isn't just reporting everything.
grep -qx "REVIEW_CONCURRENCY" <<< "$out" && fail "(2) REVIEW_CONCURRENCY still exported — must not be flagged"
pass
echo "PASS (2b) the sibling key (still exported) is not flagged — a real diff, not a blanket red"

# ── 3. A key with no default anywhere stays clean when genuinely unset ──────────────────────────────
# WATCHER_OWNER (unlike WATCHER_SCOPE post-HERD-653, which now carries a real `mine` default so
# "absent from the child's environment" can only ever mean a genuine wiring gap) still carries no
# `: "${KEY:=default}"` line at all — the still-valid example of a key that stays genuinely unset.
TU="$T/unset-key"
make_tree "$TU"
out="$(herd_env_export_lint "$TU")"; rc=$?
[ "$rc" -eq 0 ] || fail "(3) an untouched tree with WATCHER_OWNER genuinely unset must be clean (exit 0, got $rc): $out"
grep -qx "WATCHER_OWNER" <<< "$out" && fail "(3) WATCHER_OWNER has no default anywhere — must never be flagged when unset (got: $out)"
pass
echo "PASS (3) a core key with no herd-config.sh default (WATCHER_OWNER) is not flagged merely for being unset"

# ── 4. A project .herd/config override with no 'export' also reds ───────────────────────────────────
# WATCHER_SCOPE carries no `: "${KEY:=default}"` line in herd-config.sh — only a bare `export
# WATCHER_SCOPE ...` at the bottom (HERD-449), which is exactly what makes a project's .herd/config
# override safe TODAY. Simulate the PRE-FIX shape (that bare export missing) to prove the lint would
# have caught this exact class too — a project override, not just a built-in default, going unexported.
TP="$T/project-override"
make_tree "$TP"
python3 - "$TP/scripts/herd/herd-config.sh" <<'PYEOF'
import sys
path = sys.argv[1]
src = open(path, encoding="utf-8").read()
new = src.replace(
    "       WATCHER_SCOPE WATCHER_VIEW WATCHER_VIEW_AUTHOR WATCHER_VIEW_ASSIGNEE WATCHER_VIEW_LABEL \\\n",
    "       WATCHER_VIEW WATCHER_VIEW_AUTHOR WATCHER_VIEW_ASSIGNEE WATCHER_VIEW_LABEL \\\n",
    1,
)
if new == src:
    sys.exit("mutation anchor not found — herd-config.sh's WATCHER_* export block changed shape")
open(path, "w", encoding="utf-8").write(new)
PYEOF
[ $? -eq 0 ] || fail "(4) mutation setup failed — see stderr above"
{
  printf 'WATCHER_SCOPE=all\n'   # a plain KEY=val line, exactly how .herd/config is conventionally written
} > "$TP/.herd/config"
out="$(herd_env_export_lint "$TP")"; rc=$?
[ "$rc" -eq 1 ] || fail "(4) a project override set via .herd/config with no 'export' must red (exit 1, got $rc): $out"
grep -qx "WATCHER_SCOPE" <<< "$out" || fail "(4) expected WATCHER_SCOPE flagged (got: $out)"
pass
echo "PASS (4) a .herd/config override with no 'export' line reds too, not just the built-in default"

# ── 5. Fail-soft: a tree with no herd-config.sh / pysrc skips, never reds ───────────────────────────
TNS="$T/nosurface"; mkdir -p "$TNS/somewhere"
HERD_ENV_EXPORT_SKIP_REASON=""
herd_env_export_lint "$TNS" >/dev/null 2>&1; skip_rc=$?
[ "$skip_rc" -eq 2 ] || fail "(5) a tree with no herd-config.sh/pysrc → skip (exit 2, got $skip_rc)"
[ -n "${HERD_ENV_EXPORT_SKIP_REASON:-}" ] || fail "(5) HERD_ENV_EXPORT_SKIP_REASON must be set on skip"
pass
echo "PASS (5) a tree with no herd-config.sh/pysrc → skip (exit 2), never a red"

echo
echo "ALL PASS ($PASS checks) — a core-consumed config key set but not exported is caught pre-PR, mutation-proven."
