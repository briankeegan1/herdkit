#!/usr/bin/env bats
# test-resolve-autofix.bats — HERD-541 RESOLVE_AUTOFIX proof: a genuine git CONFLICTING PR whose
# builder is idle auto-dispatches the isolated conflict resolver exactly once (sha-keyed), holds on
# a second tick, never yanks a WORKING builder, falls back to needs-you on a resolver ESCALATE
# (terminal for that sha), and is byte-identical to today's needs-you row with the lever off.
#
# Deliberately NOT a tests/test-*.sh: HERD-295 dynamic discovery (tests/herd.bats) auto-globs that
# pattern into the shared bats file — its own header calls it "the #1 stale-base collision point"
# after six same-day PRs touching it starved the resolver. The HERD-541 task spec flags agent-watch.sh
# itself as a live collision surface (journal-audit-acts / adopt-worktree-prep editing other regions
# concurrently), so this proof is committed as a standalone .bats file: real coverage, without adding
# another hand or auto-glob touch to tests/herd.bats while that churn is in flight. Run directly:
#   bats tests/test-resolve-autofix.bats
#
# Sources the REAL agent-watch.sh in lib mode — resolve_autofix_enabled, _dispatch_conflict_autofix,
# _classify_conflict, spawn_resolver, and the sha-keyed resolver ledger (resolver_dispatch_count /
# resolver_dispatched_sha / resolver_escalated_sha) are production code, not a re-implementation.
# HERMETIC: local fixtures + a stubbed HERD_RESOLVE_BIN only — no gh, no herdr, no network, no model
# (mirrors scripts/herd/sim/sandbox-resolver-respawn-scenario.sh's stub-resolver convention).

setup() {
  HERE="$(cd "$BATS_TEST_DIRNAME" && pwd)"
  WATCH="$HERE/../scripts/herd/agent-watch.sh"
  [ -f "$WATCH" ]

  T="$(mktemp -d)"
  BIN="$T/bin"; mkdir -p "$BIN"
  for cmd in gh herdr; do printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$cmd"; chmod +x "$BIN/$cmd"; done
  export PATH="$BIN:$PATH"

  export AGENT_WATCH_LIB=1
  export HERD_DRIVER=headless
  export PROJECT_ROOT="$T/main"; mkdir -p "$PROJECT_ROOT"
  export WORKTREES_DIR="$T/trees"; mkdir -p "$WORKTREES_DIR"
  export HERD_CONFIG_FILE="$T/no-such-config"
  export JOURNAL_FILE="$T/journal.jsonl"; : > "$JOURNAL_FILE"
  export REFIX_MAX_ROUNDS=3
  export DEFAULT_BRANCH=main
  export _RESOLVER_DEAD_GRACE=0
  export DRYRUN=""
  export RESOLVE_AUTOFIX="off"

  # shellcheck source=/dev/null
  . "$WATCH"
  render() { :; }
  TREES="$WORKTREES_DIR"
  RESOLVE_STATE="$T/.agent-watch-resolve-attempts"; : > "$RESOLVE_STATE"

  SLUG="feat-conflict"; PR="777"; BRANCH="feat/conflict"
  SHA1="aaaaaaa1"; SHA2="bbbbbbb2"

  # Stub resolver on the HERD_RESOLVE_BIN seam (sandbox-resolver-respawn-scenario.sh convention):
  # records each dispatch and, per $STUB_RESOLVE_VERDICT, writes the sha-scoped verdict file or
  # writes nothing (the default — "a resolver that will die").
  STUB_RESOLVE="$T/stub-resolve.sh"
  cat > "$STUB_RESOLVE" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "${STUB_RESOLVE_LOG:-/dev/null}"
case "${STUB_RESOLVE_VERDICT:-}" in
  ESCALATE) [ -n "${HERD_RESOLVE_RESULT_FILE:-}" ] && printf 'RESOLVE: ESCALATE\n' > "$HERD_RESOLVE_RESULT_FILE" ;;
  DONE)     [ -n "${HERD_RESOLVE_RESULT_FILE:-}" ] && printf 'RESOLVE: DONE\n'     > "$HERD_RESOLVE_RESULT_FILE" ;;
  *)        : ;;
esac
exit 0
STUB
  chmod +x "$STUB_RESOLVE"
  export HERD_RESOLVE_BIN="$STUB_RESOLVE"
  export STUB_RESOLVE_LOG="$T/dispatches.log"; : > "$STUB_RESOLVE_LOG"
  export STUB_RESOLVE_VERDICT=""

  # Fake the FEATURE BUILDER's own agent status. _agent_status normally shells to `herdr agent
  # list`; override the sourced function directly (hermetic, no stateful herdr stub needed) so each
  # test controls it with one assignment. Default: idle (the auto-dispatch-eligible state).
  BUILDER_STATUS="idle"
  _agent_status() { printf '%s' "$BUILDER_STATUS"; }
  # Resolver-liveness roster (a SEPARATE identity from the builder above) — empty until a test arms
  # a live resolve·<slug> row to simulate an in-flight resolver.
  AGENTS_JSON='{"result":{"agents":[]}}'
}

teardown() {
  rm -rf "$T"
}

# tick <sha> [author] — one CONFLICTING classify + resolve pass, in the SAME order the production
# tick calls them (_classify_conflict, then _dispatch_conflict_autofix), waiting for the backgrounded
# resolver lane (HERD-237) to finish before returning so the stub's synchronous verdict write is
# observable. [author], when given, is HERD-655's AUTOFIX_SCOPE input; omitted (the default for every
# test above) queues the bypass sentinel, so those tests stay exactly as they were pre-HERD-655.
tick() {
  DISPLAY=(); FLAIR_STATE=()
  CONF_IDX=(); CONF_SLUG=(); CONF_PR=(); CONF_BRANCH=(); CONF_SHA=(); CONF_REASON=(); CONF_AUTHOR=()
  if [ "$#" -ge 2 ]; then
    _classify_conflict 0 "$PR" "$SLUG" "$BRANCH" "$1" "$2"
  else
    _classify_conflict 0 "$PR" "$SLUG" "$BRANCH" "$1"
  fi
  _dispatch_conflict_autofix
  _spawn_resolver_wait
}

@test "RESOLVE_AUTOFIX=off: CONF_IDX is computed and dropped — byte-identical needs-you, no dispatch" {
  RESOLVE_AUTOFIX="off"
  tick "$SHA1"
  [ "$(resolver_dispatch_count "$PR")" -eq 0 ]
  [ ! -s "$STUB_RESOLVE_LOG" ]
  [[ "${DISPLAY[0]}" == *"needs you"* ]]
  [[ "${DISPLAY[0]}" == *"conflict"* ]]
}

@test "RESOLVE_AUTOFIX=on + idle builder: auto-dispatches exactly once, sha-keyed" {
  RESOLVE_AUTOFIX="on"
  tick "$SHA1"
  [ "$(resolver_dispatch_count "$PR")" -eq 1 ]
  resolver_dispatched_sha "$PR" "$SHA1"
  [ "$(wc -l < "$STUB_RESOLVE_LOG")" -eq 1 ]
  [[ "${DISPLAY[0]}" == *"resolving · auto"* ]]
  grep -q '"event":"resolve_autodispatch"' "$JOURNAL_FILE"
  grep -q "\"sha\":\"$SHA1\"" "$JOURNAL_FILE"
}

@test "RESOLVE_AUTOFIX=on: a second tick on the same sha is a no-op (live resolver holds)" {
  RESOLVE_AUTOFIX="on"
  tick "$SHA1"
  [ "$(resolver_dispatch_count "$PR")" -eq 1 ]
  # Simulate the dispatched resolver now showing up ALIVE in the roster (still no verdict).
  AGENTS_JSON="$(printf '{"result":{"agents":[{"name":"%s","agent_status":"working"}]}}' \
    "$(herd_agent_name_sanitize "resolve·$SLUG")")"
  tick "$SHA1"
  [ "$(resolver_dispatch_count "$PR")" -eq 1 ]
  [ "$(wc -l < "$STUB_RESOLVE_LOG")" -eq 1 ]
  [[ "${DISPLAY[0]}" == *"resolving conflict"* ]]
}

@test "RESOLVE_AUTOFIX=on: a WORKING builder is never yanked — no dispatch, honest needs-you stands" {
  RESOLVE_AUTOFIX="on"
  BUILDER_STATUS="working"
  tick "$SHA1"
  [ "$(resolver_dispatch_count "$PR")" -eq 0 ]
  [ ! -s "$STUB_RESOLVE_LOG" ]
  [[ "${DISPLAY[0]}" == *"needs you"* ]]
}

@test "RESOLVE_AUTOFIX=on: resolver ESCALATE falls back to needs-you, terminal for that sha (never loops)" {
  RESOLVE_AUTOFIX="on"
  STUB_RESOLVE_VERDICT="ESCALATE"
  tick "$SHA1"
  [ "$(resolver_dispatch_count "$PR")" -eq 1 ]
  # A second tick observes the verdict file and promotes it to the terminal escalated marker.
  tick "$SHA1"
  [[ "${DISPLAY[0]}" == *"needs you"* ]]
  [[ "${DISPLAY[0]}" == *"escalated"* ]]
  resolver_escalated_sha "$PR" "$SHA1"
  # A third tick — lever still on, builder still idle — must NOT re-dispatch a terminal sha.
  tick "$SHA1"
  [ "$(resolver_dispatch_count "$PR")" -eq 1 ]
  [ "$(wc -l < "$STUB_RESOLVE_LOG")" -eq 1 ]
}

@test "RESOLVE_AUTOFIX=on: a NEW commit after an ESCALATE re-arms exactly one more dispatch" {
  RESOLVE_AUTOFIX="on"
  STUB_RESOLVE_VERDICT="ESCALATE"
  tick "$SHA1"
  tick "$SHA1"   # observes + terminal-marks the escalation for SHA1
  resolver_escalated_sha "$PR" "$SHA1"
  STUB_RESOLVE_VERDICT=""
  tick "$SHA2"   # a new head sha reshapes the conflict — one more dispatch is due
  [ "$(resolver_dispatch_count "$PR")" -eq 2 ]
  resolver_dispatched_sha "$PR" "$SHA2"
  [[ "${DISPLAY[0]}" == *"resolving · auto"* ]]
}

# ── AUTOFIX_SCOPE (HERD-655, GitHub issue #771): never auto-resolve another operator's conflict ────
# GROUNDED: this is the exact incident rail -- a seat's RESOLVE_AUTOFIX dispatched a resolver against
# the OTHER operator's conflicting PR. These cases prove _dispatch_conflict_autofix now consults the
# shared _autofix_scope_permits check before it ever calls spawn_resolver.

@test "AUTOFIX_SCOPE=own (default) + foreign author: WITHHELD -- no dispatch, no resolve_autodispatch" {
  RESOLVE_AUTOFIX="on"
  export WATCHER_OWNER="alice"
  tick "$SHA1" "bob"
  [ "$(resolver_dispatch_count "$PR")" -eq 0 ]
  [ ! -s "$STUB_RESOLVE_LOG" ]
  [[ "${DISPLAY[0]}" == *"needs you"* ]]
  [[ "${DISPLAY[0]}" == *"autofix withheld"* ]]
  grep -q '"event":"autofix_scope_withheld"' "$JOURNAL_FILE"
  grep -q '"rail":"resolve"' "$JOURNAL_FILE"
  ! grep -q '"event":"resolve_autodispatch"' "$JOURNAL_FILE"
}

@test "AUTOFIX_SCOPE=own (default) + own author: PERMITTED -- dispatches exactly like before" {
  RESOLVE_AUTOFIX="on"
  export WATCHER_OWNER="alice"
  tick "$SHA1" "alice"
  [ "$(resolver_dispatch_count "$PR")" -eq 1 ]
  [[ "${DISPLAY[0]}" == *"resolving"*"auto"* ]]
  ! grep -q '"event":"autofix_scope_withheld"' "$JOURNAL_FILE"
}

@test "AUTOFIX_SCOPE=all + foreign author: PERMITTED -- explicit opt-in restores today's behavior" {
  RESOLVE_AUTOFIX="on"
  export AUTOFIX_SCOPE="all" WATCHER_OWNER="alice"
  tick "$SHA1" "bob"
  [ "$(resolver_dispatch_count "$PR")" -eq 1 ]
  [[ "${DISPLAY[0]}" == *"resolving"*"auto"* ]]
  ! grep -q '"event":"autofix_scope_withheld"' "$JOURNAL_FILE"
}

@test "AUTOFIX_SCOPE=own + unresolvable operator identity: WITHHELD fail-closed (never fires blind)" {
  RESOLVE_AUTOFIX="on"
  # No WATCHER_OWNER/WATCHER_VIEW_AUTHOR, and the stubbed gh (setup()) answers every call with rc 0
  # and no output -- the identity resolves to empty.
  tick "$SHA1" "alice"
  [ "$(resolver_dispatch_count "$PR")" -eq 0 ]
  [ ! -s "$STUB_RESOLVE_LOG" ]
  grep -q '"event":"autofix_scope_withheld"' "$JOURNAL_FILE"
  grep -q '"reason":"noowner"' "$JOURNAL_FILE"
}

@test "a call site predating AUTOFIX_SCOPE (no author arg) is never scoped -- byte-identical" {
  RESOLVE_AUTOFIX="on"
  # No WATCHER_OWNER, no author passed to tick -- mirrors every test above this section verbatim.
  tick "$SHA1"
  [ "$(resolver_dispatch_count "$PR")" -eq 1 ]
  [[ "${DISPLAY[0]}" == *"resolving"*"auto"* ]]
  ! grep -q '"event":"autofix_scope_withheld"' "$JOURNAL_FILE"
}
