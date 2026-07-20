#!/usr/bin/env bash
# test-work-unit-kind.sh — hermetic proof of WORK_UNIT_KIND adapter resolution (HERD-398, Phase 3 of
# docs/spikes/work-unit-abstraction.md).
#
# Covers:
#   (1) DEFAULT — herd-config.sh declares WORK_UNIT_KIND="git-pr" when unset (the only kind that ships).
#   (2) ADAPTER LOADED — sourcing agent-watch.sh (lib mode) transitively sources
#       scripts/herd/work-units/git-pr.sh and defines every moved git-pr function under its ORIGINAL
#       name (do_merge, reconcile_backlog, already_merged, _classify_review_tier, _merge_method_flag,
#       _delete_branch_flag, _reconcile_pr_ref, _watcher_tick_fields, _prs_fetch_tick) — proving the
#       Phase 3 extraction is a pure relocation, not a behavior change.
#   (3) RESOLUTION — work-unit.sh's wunit_resolve_adapter: "git-pr" (explicit, via WORK_UNIT_KIND, or
#       the bare default) resolves and prints "git-pr" (rc 0); any OTHER kind is a HARD refusal — a
#       loud not-yet-supported message on stderr and rc 1, never a silent fallback.
#   (4) BOOT-TIME ADVISORY — agent-watch.sh's own WORK_UNIT_KIND validation (distinct posture from (3):
#       the watcher itself must keep running through a config typo) journals work_unit_kind_invalid and
#       prints a red line on an unsupported value, mirroring the MERGE_POLICY-typo handling
#       (test-gate-keys-strict.sh (2c)) — source-checked the same way, since re-sourcing agent-watch.sh
#       OUTSIDE lib mode needs a full project config.
#
# Fully hermetic: stubs gh/git/herdr; no network; no live watcher loop.
# Run:  bash tests/test-work-unit-kind.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CONFIG="$ROOT/scripts/herd/herd-config.sh"
WATCH="$ROOT/scripts/herd/agent-watch.sh"
WUNIT="$ROOT/scripts/herd/work-unit.sh"
GITPR="$ROOT/scripts/herd/work-units/git-pr.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); echo "  ok: $1"; }

for f in "$CONFIG" "$WATCH" "$WUNIT" "$GITPR"; do
  [ -f "$f" ] || fail "missing required file: $f"
done

# Stub gh/git/herdr on PATH so sourcing never touches the network.
BIN="$T/bin"; mkdir -p "$BIN"
for cmd in gh herdr; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$cmd"; chmod +x "$BIN/$cmd"
done
export PATH="$BIN:$PATH"
export HERD_CONFIG_FILE="$T/no-such-config"
export WORKTREES_DIR="$T/trees"; mkdir -p "$T/trees"

# ══════════════════════════════════════════════════════════════════════════════
# (1) DEFAULT — WORK_UNIT_KIND resolves to git-pr when unset
# ══════════════════════════════════════════════════════════════════════════════
(
  unset WORK_UNIT_KIND 2>/dev/null || true
  # shellcheck source=/dev/null
  . "$CONFIG"
  [ "$WORK_UNIT_KIND" = "git-pr" ] || { echo "FAIL: (1) default WORK_UNIT_KIND='$WORK_UNIT_KIND', want git-pr" >&2; exit 1; }
) || fail "(1) herd-config.sh must default WORK_UNIT_KIND to git-pr"
ok "(1) WORK_UNIT_KIND defaults to git-pr"

# ══════════════════════════════════════════════════════════════════════════════
# (2) ADAPTER LOADED — agent-watch.sh (lib mode) transitively defines the moved git-pr functions
# ══════════════════════════════════════════════════════════════════════════════
(
  set -uo pipefail
  MAINDIR="$T/proj"; TREESDIR="$T/proj-trees"
  mkdir -p "$MAINDIR" "$TREESDIR"
  git init -q -b main "$MAINDIR"
  git -C "$MAINDIR" config user.email t@t.local; git -C "$MAINDIR" config user.name t
  echo base > "$MAINDIR/f.txt"; git -C "$MAINDIR" add -A; git -C "$MAINDIR" commit -qm base
  git -C "$MAINDIR" update-ref refs/remotes/origin/main HEAD

  export HERD_DRIVER=headless
  export PROJECT_ROOT="$MAINDIR" WORKTREES_DIR="$TREESDIR" WORKSPACE_NAME=wukindws
  export DEFAULT_BRANCH="origin/main"
  export HERD_CONFIG_FILE="$T/no-such-config"
  export JOURNAL_FILE="$T/journal.jsonl"; : > "$JOURNAL_FILE"
  export AGENT_WATCH_LIB=1
  # shellcheck source=/dev/null
  . "$WATCH" || { echo "FAIL: (2) sourcing agent-watch.sh (lib mode) failed"; exit 1; }
  for fn in do_merge reconcile_backlog already_merged _classify_review_tier _merge_method_flag \
            _delete_branch_flag _reconcile_pr_ref _watcher_tick_fields _prs_fetch_tick; do
    command -v "$fn" >/dev/null 2>&1 || { echo "FAIL: (2) $fn not defined after sourcing agent-watch.sh"; exit 1; }
  done
  echo ADAPTER-LOADED-OK
) > "$T/adapter.out" 2>&1 || { cat "$T/adapter.out" >&2; fail "(2) git-pr adapter functions must be defined after sourcing agent-watch.sh"; }
grep -q ADAPTER-LOADED-OK "$T/adapter.out" || { cat "$T/adapter.out" >&2; fail "(2) adapter-loaded check did not complete"; }
ok "(2) sourcing agent-watch.sh transitively loads every moved git-pr function under its original name"

# ══════════════════════════════════════════════════════════════════════════════
# (3) RESOLUTION — wunit_resolve_adapter: git-pr resolves, any other kind is a HARD refusal
# ══════════════════════════════════════════════════════════════════════════════
(
  set -uo pipefail
  do_merge() { :; }; reconcile_backlog() { :; }; _reap_slug() { :; }; _cand_gates_ready() { :; }
  export -f do_merge reconcile_backlog _reap_slug _cand_gates_ready
  # shellcheck source=/dev/null
  . "$WUNIT" || { echo "FAIL: (3) sourcing work-unit.sh failed"; exit 1; }
  type wunit_resolve_adapter >/dev/null 2>&1 || { echo "FAIL: (3) wunit_resolve_adapter not defined"; exit 1; }

  out="$(wunit_resolve_adapter git-pr)"; rc=$?
  [ "$out" = "git-pr" ] && [ "$rc" -eq 0 ] || { echo "FAIL: (3a) explicit git-pr must resolve (out='$out' rc=$rc)"; exit 1; }

  out="$(unset WORK_UNIT_KIND 2>/dev/null; wunit_resolve_adapter)"; rc=$?
  [ "$out" = "git-pr" ] && [ "$rc" -eq 0 ] || { echo "FAIL: (3b) no-arg default must resolve git-pr (out='$out' rc=$rc)"; exit 1; }

  out="$(WORK_UNIT_KIND=git-pr wunit_resolve_adapter)"; rc=$?
  [ "$out" = "git-pr" ] && [ "$rc" -eq 0 ] || { echo "FAIL: (3c) WORK_UNIT_KIND=git-pr env must resolve (out='$out' rc=$rc)"; exit 1; }

  err="$(wunit_resolve_adapter doc-apply 2>&1 1>/dev/null)"; rc=$?
  [ "$rc" -eq 1 ] || { echo "FAIL: (3d) unsupported kind must return rc 1 (got rc=$rc)"; exit 1; }
  printf '%s' "$err" | grep -qi 'not supported' || { echo "FAIL: (3d) refusal must be LOUD (stderr), got: $err"; exit 1; }
  out="$(wunit_resolve_adapter doc-apply 2>/dev/null)"
  [ -z "$out" ] || { echo "FAIL: (3e) unsupported kind must print NOTHING on stdout (a silent fallback), got: '$out'"; exit 1; }

  echo RESOLVE-OK
) > "$T/resolve.out" 2>&1 || { cat "$T/resolve.out" >&2; fail "(3) wunit_resolve_adapter checks failed"; }
grep -q RESOLVE-OK "$T/resolve.out" || { cat "$T/resolve.out" >&2; fail "(3) resolution checks did not complete"; }
ok "(3) wunit_resolve_adapter resolves git-pr and hard-refuses any other kind"

# ══════════════════════════════════════════════════════════════════════════════
# (4) BOOT-TIME ADVISORY — agent-watch.sh journals + warns (never crashes) on an unsupported kind
# ══════════════════════════════════════════════════════════════════════════════
grep -q 'work_unit_kind_invalid' "$WATCH" \
  || fail "(4a) agent-watch.sh must journal work_unit_kind_invalid on an unsupported WORK_UNIT_KIND"
grep -qi 'is not supported' "$WATCH" \
  || fail "(4b) agent-watch.sh must print a not-supported console line on an unsupported WORK_UNIT_KIND"
grep -q 'WORK_UNIT_KIND:-git-pr' "$WATCH" \
  || fail "(4c) agent-watch.sh's boot check must fail STRICT to the git-pr default"
ok "(4) agent-watch.sh boot-time WORK_UNIT_KIND check journals + warns, never crashes"

echo
echo "ALL PASS ($pass checks)"
