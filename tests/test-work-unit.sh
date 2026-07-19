#!/usr/bin/env bash
# test-work-unit.sh — hermetic proof of scripts/herd/work-unit.sh, the Phase 1 work-unit facade
# (HERD-395/HERD-396, spike: docs/spikes/work-unit-abstraction.md).
#
# Covers:
#   (1) DELEGATION — each of the 7 wunit_* wrappers reaches EXACTLY the underlying git-pr function/gh
#       invocation the spike's 2.3 table names, with argv passed straight through and the delegate's
#       return value/exit code propagated unchanged:
#         wunit_open/list_open/inspect → gh pr create/list/view (argv passthrough, stub gh on PATH)
#         wunit_gate                   → _cand_gates_ready (pass→"pass" rc0, not-ready→"wait" rc1)
#         wunit_apply                  → do_merge (full argv, rc propagated)
#         wunit_reconcile              → reconcile_backlog (full argv, rc propagated)
#         wunit_teardown               → _reap_slug (full argv, rc propagated)
#       Proven with FIXTURE STUBS standing in for the real functions (the delegation contract, not a
#       re-test of do_merge/reconcile_backlog/_reap_slug/_cand_gates_ready — those already have their
#       own coverage).
#   (2) AUTO-SOURCE — sourcing work-unit.sh STANDALONE (nothing pre-defines do_merge) pulls in the
#       real git-pr adapter body via agent-watch.sh's AGENT_WATCH_LIB=1 seam, so all 7 wunit_* AND
#       their delegates end up defined — the production path, not just the test seam.
#   (3) NO-DOUBLE-SOURCE — when the delegates are ALREADY in scope (a caller, or this test's own
#       stubs), sourcing work-unit.sh does not re-source agent-watch.sh (would be slow and, in a real
#       caller, would re-run agent-watch.sh's top-level config resolution a second time).
#
# Fully hermetic: no network, no model, no real gh. Run:  bash tests/test-work-unit.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/../scripts/herd/work-unit.sh"
WATCH="$HERE/../scripts/herd/agent-watch.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

[ -f "$LIB" ]   || fail "work-unit.sh not found at $LIB"
[ -f "$WATCH" ] || fail "agent-watch.sh not found at $WATCH"

# ── (2)+(3) AUTO-SOURCE: a real fixture repo, nothing pre-defined, standalone source ────────────────
(
  set -uo pipefail
  MAINDIR="$T/proj"; TREESDIR="$T/proj-trees"
  mkdir -p "$MAINDIR" "$TREESDIR"
  git init -q -b main "$MAINDIR"
  git -C "$MAINDIR" config user.email t@t.local; git -C "$MAINDIR" config user.name t
  echo base > "$MAINDIR/f.txt"; git -C "$MAINDIR" add -A; git -C "$MAINDIR" commit -qm base
  git -C "$MAINDIR" update-ref refs/remotes/origin/main HEAD

  export HERD_DRIVER=headless
  export PROJECT_ROOT="$MAINDIR" WORKTREES_DIR="$TREESDIR" WORKSPACE_NAME=wunitws
  export DEFAULT_BRANCH="origin/main"
  export HERD_CONFIG_FILE="$T/no-such-config"
  export JOURNAL_FILE="$T/journal.jsonl"; : > "$JOURNAL_FILE"

  command -v do_merge >/dev/null 2>&1 && { echo "FAIL: (2) do_merge already defined before sourcing work-unit.sh — fixture leaked"; exit 1; }
  # shellcheck source=/dev/null
  . "$LIB" || { echo "FAIL: (2) sourcing work-unit.sh standalone failed"; exit 1; }
  for fn in wunit_open wunit_list_open wunit_inspect wunit_gate wunit_apply wunit_reconcile wunit_teardown \
            do_merge reconcile_backlog _reap_slug _cand_gates_ready; do
    command -v "$fn" >/dev/null 2>&1 || { echo "FAIL: (2) $fn not defined after standalone source"; exit 1; }
  done
  echo AUTOSOURCE-OK
) > "$T/autosource.out" 2>&1 || { cat "$T/autosource.out" >&2; fail "(2) auto-source of agent-watch.sh's git-pr adapter body failed"; }
grep -q AUTOSOURCE-OK "$T/autosource.out" || { cat "$T/autosource.out" >&2; fail "(2) auto-source did not complete"; }
ok; echo "PASS (2) sourcing work-unit.sh standalone auto-sources the real git-pr adapter body"

# ── (1)+(3) DELEGATION, in a fresh subshell with fixture stubs pre-defined ───────────────────────────
(
  set -uo pipefail
  CALLS="$T/calls.log"; : > "$CALLS"

  # Stub `gh` on PATH — logs argv, exits with $GH_RC (default 0).
  BIN="$T/bin"; mkdir -p "$BIN"
  cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >> "$CALLS"
exit "${GH_RC:-0}"
EOF
  chmod +x "$BIN/gh"
  export PATH="$BIN:$PATH" CALLS

  # Fixture stubs standing in for the real agent-watch.sh functions — each logs its own name + argv,
  # so the wrapper test asserts DELEGATION, not the real functions' internal behavior.
  do_merge() { printf 'do_merge %s\n' "$*" >> "$CALLS"; return "${DO_MERGE_RC:-0}"; }
  reconcile_backlog() { printf 'reconcile_backlog %s\n' "$*" >> "$CALLS"; return "${RECONCILE_RC:-0}"; }
  _reap_slug() { printf '_reap_slug %s\n' "$*" >> "$CALLS"; return "${REAP_RC:-0}"; }
  _cand_gates_ready() { printf '_cand_gates_ready %s\n' "$*" >> "$CALLS"; return "${GATES_RC:-0}"; }
  export -f do_merge reconcile_backlog _reap_slug _cand_gates_ready

  # No do_merge in THIS subshell's exported-function sense would still read as "defined" via
  # command -v, so work-unit.sh's guard must see it and skip sourcing agent-watch.sh.
  # shellcheck source=/dev/null
  . "$LIB" || { echo "FAIL: (1) sourcing work-unit.sh with stubs in scope failed"; exit 1; }

  # (1a) wunit_open passes argv straight to `gh pr create`
  wunit_open --title "T" --body "B" >/dev/null
  grep -qx "gh pr create --title T --body B" "$CALLS" || { echo "FAIL: (1a) wunit_open did not delegate argv to gh pr create"; exit 1; }

  # (1b) wunit_list_open passes argv straight to `gh pr list`
  wunit_list_open --json number,headRefName >/dev/null
  grep -qx "gh pr list --json number,headRefName" "$CALLS" || { echo "FAIL: (1b) wunit_list_open did not delegate argv to gh pr list"; exit 1; }

  # (1c) wunit_inspect passes argv straight to `gh pr view`
  wunit_inspect 42 --json body >/dev/null
  grep -qx "gh pr view 42 --json body" "$CALLS" || { echo "FAIL: (1c) wunit_inspect did not delegate argv to gh pr view"; exit 1; }

  # (1c-rc) gh's exit code propagates unchanged through every gh-backed wrapper
  GH_RC=7 wunit_inspect 42; rc=$?
  [ "$rc" -eq 7 ] || { echo "FAIL: (1c-rc) wunit_inspect did not propagate gh's exit code (got $rc)"; exit 1; }

  # (1d) wunit_gate ready → delegates to _cand_gates_ready, prints pass, rc 0
  : > "$CALLS"
  GATES_RC=0 out="$(wunit_gate 42 deadbeef)"; rc=$?
  grep -qx "_cand_gates_ready 42 deadbeef" "$CALLS" || { echo "FAIL: (1d) wunit_gate did not delegate to _cand_gates_ready"; exit 1; }
  [ "$out" = "pass" ] && [ "$rc" -eq 0 ] || { echo "FAIL: (1d) ready gate must print pass and return 0 (got '$out' rc=$rc)"; exit 1; }

  # (1e) wunit_gate not-ready → wait, rc 1 — same delegate, opposite verdict
  : > "$CALLS"
  out="$(GATES_RC=1 wunit_gate 42 deadbeef)"; rc=$?
  [ "$out" = "wait" ] && [ "$rc" -eq 1 ] || { echo "FAIL: (1e) not-ready gate must print wait and return 1 (got '$out' rc=$rc)"; exit 1; }

  # (1f) wunit_apply passes its full argv straight to do_merge, rc propagated
  : > "$CALLS"
  DO_MERGE_RC=3 wunit_apply myslug 42 /path/to/wt deadbeef; rc=$?
  grep -qx "do_merge myslug 42 /path/to/wt deadbeef" "$CALLS" || { echo "FAIL: (1f) wunit_apply did not delegate full argv to do_merge"; exit 1; }
  [ "$rc" -eq 3 ] || { echo "FAIL: (1f) wunit_apply did not propagate do_merge's exit code (got $rc)"; exit 1; }

  # (1g) wunit_reconcile passes its full argv straight to reconcile_backlog, rc propagated
  : > "$CALLS"
  RECONCILE_RC=2 wunit_reconcile 42 myslug deadbeef; rc=$?
  grep -qx "reconcile_backlog 42 myslug deadbeef" "$CALLS" || { echo "FAIL: (1g) wunit_reconcile did not delegate full argv to reconcile_backlog"; exit 1; }
  [ "$rc" -eq 2 ] || { echo "FAIL: (1g) wunit_reconcile did not propagate reconcile_backlog's exit code (got $rc)"; exit 1; }

  # (1h) wunit_teardown passes its full argv straight to _reap_slug, rc propagated
  : > "$CALLS"
  REAP_RC=5 wunit_teardown myslug /path/to/wt 42 deadbeef merged; rc=$?
  grep -qx "_reap_slug myslug /path/to/wt 42 deadbeef merged" "$CALLS" || { echo "FAIL: (1h) wunit_teardown did not delegate full argv to _reap_slug"; exit 1; }
  [ "$rc" -eq 5 ] || { echo "FAIL: (1h) wunit_teardown did not propagate _reap_slug's exit code (got $rc)"; exit 1; }

  # (1i) wunit_ref composes a namespaced ref, via journal.sh's journal_unit_ref — borrowed by
  # work-unit.sh's own guard even though only do_merge/reconcile_backlog/_reap_slug/_cand_gates_ready
  # were stubbed here (journal.sh was never sourced by this subshell) — HERD-397 review: this used to
  # be an unasserted "already in scope by convention" dependency.
  out="$(wunit_ref git-pr 42)"
  [ "$out" = "git-pr:42" ] || { echo "FAIL: (1i) wunit_ref git-pr 42 = '$out', expected git-pr:42"; exit 1; }

  echo DELEGATION-OK
) > "$T/delegation.out" 2>&1 || { cat "$T/delegation.out" >&2; fail "(1) delegation subshell failed"; }
grep -q DELEGATION-OK "$T/delegation.out" || { cat "$T/delegation.out" >&2; fail "(1) delegation checks did not complete"; }
ok; echo "PASS (1)+(3) every wunit_* wrapper delegates argv+rc to its named underlying function, no re-source when already in scope"

# ── (4) journal_unit_ref already in scope -> work-unit.sh must NOT override it with journal.sh's ──
(
  set -uo pipefail
  do_merge() { :; }; reconcile_backlog() { :; }; _reap_slug() { :; }; _cand_gates_ready() { :; }
  journal_unit_ref() { printf 'STUBBED\n'; }
  export -f do_merge reconcile_backlog _reap_slug _cand_gates_ready journal_unit_ref
  # shellcheck source=/dev/null
  . "$LIB" || { echo "FAIL: (4) sourcing work-unit.sh with journal_unit_ref pre-stubbed failed"; exit 1; }
  out="$(wunit_ref git-pr 42)"
  [ "$out" = "STUBBED" ] || { echo "FAIL: (4) work-unit.sh overrode an already-in-scope journal_unit_ref (got '$out')"; exit 1; }
  echo NO_REBORROW_OK
) > "$T/noreborrow.out" 2>&1 || { cat "$T/noreborrow.out" >&2; fail "(4) journal_unit_ref no-reborrow subshell failed"; }
grep -q NO_REBORROW_OK "$T/noreborrow.out" || { cat "$T/noreborrow.out" >&2; fail "(4) journal_unit_ref no-reborrow check did not complete"; }
ok; echo "PASS (4) an already-in-scope journal_unit_ref is never re-sourced/overridden"

echo
echo "ALL PASS ($pass checks)"
