#!/usr/bin/env bash
# test-main-health-spawn-chain.sh — HERD-485: mutation-proof that MAIN_HEALTH_AUTOFIX=spawn's builder
# is real, bypass-enabled, and DISCOVERABLE — not just that the intent gets ENQUEUED.
#
# THE GAP THIS CLOSES: tests/test-main-health-invariant.sh proves _main_health_autofix_spawn enqueues
# a correct intent into the durable spawn queue (slug/lane/ref), but says so explicitly — "draining it
# into an actual herdr tab/agent is _drain_spawn_queue's job, never invoked here, so this stays fully
# hermetic". tests/test-spawn-queue-drain.sh proves _drain_spawn_queue's OWN mechanics (consume-only-
# on-observed-spawn, defer/fail/launch), but against FAKE herd-quick.sh/herd-feature.sh stubs that
# never touch a real lane, a real driver-composed argv, or a real worktree. Neither half proves the
# CHAIN: that draining a MAIN_HEALTH_AUTOFIX=spawn intent ends in a REAL herd-quick.sh run that (a)
# launches with the permission-bypass flag (not a hand-rolled, unflagged claude invocation — the
# 4-hour "⏸ manual mode on" stall this item is named for), and (b) leaves the builder DISCOVERABLE —
# a real git worktree the watcher's next tick's FEATS walk would find (HERD's watcher gates worktrees,
# not open PRs — see docs/codemap.md / AGENTS.md), so a stuck builder is caught by finish-stall
# detection instead of sitting invisible for hours.
#
# Covers, driving the REAL functions end to end (no fake lane scripts):
#   (u) a red reproduced under MAIN_HEALTH_AUTOFIX=spawn enqueues via the shared spawn.sh seam, exactly
#       as test-main-health-invariant.sh (o) proves — the setup precondition for what follows.
#   (v) draining that SAME intent through the REAL _drain_spawn_queue invokes the REAL
#       scripts/herd/herd-quick.sh (not a stub lane) end to end: it creates a REAL git worktree off
#       origin/main, threads HERD_ITEM_REF into the externalized task spec's 'Refs:' line, and the
#       resulting herdr 'agent start' argv carries the permission-bypass flag
#       (--dangerously-skip-permissions) the live incident's builder was missing.
#   (w) the builder tab is registered in .herd-tabs (the tab-leak-guard / teardown allowlist) AND the
#       worktree is real on disk under $WORKTREES_DIR/<slug> — the two independent surfaces
#       finish-stall / dead-builder detection and the sweep walk actually consult — so a spawn-tier
#       launch this item mandates is provably NOT invisible to the watcher's next tick.
#   (x) the queue intent is fully drained (no .req left) and journaled spawn_launched — the durability
#       contract (PR #151) holds for an autofix-originated intent same as any coordinator-originated one.
#
# Fully hermetic: a throwaway origin+clone stand in for the project, a stub herdr/gh/claude on PATH.
# NO real herdr, NO real claude, NO network, NO model calls.
# Run:  bash tests/test-main-health-spawn-chain.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WATCH="$ROOT/scripts/herd/agent-watch.sh"

if [ -f "$ROOT/scripts/herd/hermetic-env-scrub.sh" ]; then
  # shellcheck source=/dev/null
  . "$ROOT/scripts/herd/hermetic-env-scrub.sh"
  herd_hermetic_env_scrub "$ROOT/scripts/herd/herd-config.sh"
fi

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ pass=$((pass+1)); printf 'ok — %s\n' "$1"; }

[ -f "$WATCH" ] || fail "agent-watch.sh not found at $WATCH"
command -v git     >/dev/null 2>&1 || fail "git required"
command -v python3 >/dev/null 2>&1 || fail "python3 required"

# ── fixture: origin + a working clone that plays BOTH $MAIN (health reproduction target) AND the
# project new-feature.sh clones worktrees FROM — exactly how the real system uses one PROJECT_ROOT
# for both. ──────────────────────────────────────────────────────────────────────────────────────
ORIGIN="$T/origin.git"; REPO="$T/repo"; TREES_DIR="$T/trees"
mkdir -p "$TREES_DIR"
git init -q --bare "$ORIGIN"
git clone -q "$ORIGIN" "$REPO"
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name  tester
git -C "$REPO" checkout -q -b main
printf 'seed\n' > "$REPO/seed.txt"
git -C "$REPO" add -A && git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m "Merge pull request #77 from someone/branch"
git -C "$REPO" push -q -u origin main

HC="$T/hc.sh"
cat > "$HC" <<'HCSTUB'
#!/usr/bin/env bash
case "$(cat "$HC_MODE" 2>/dev/null)" in
  green) echo "✅ clean — all tests pass"; exit 0 ;;
  red-file) echo "❌ code error — app/greet.test.sh → greet.test FAIL"; exit 1 ;;
  *) echo "✅ clean"; exit 0 ;;
esac
HCSTUB
chmod +x "$HC"
export HC_MODE="$T/hc-mode"; printf 'green\n' > "$HC_MODE"

# ── stub binaries: gh (main-health CI leg, unused here but sourced), herdr (LOGS FULL ARGV so the
# eventual claude launch line is inspectable), claude (never really invoked — herdr is the mux). ───
BIN="$T/bin"; mkdir -p "$BIN"
cat > "$BIN/gh" <<'GHSTUB'
#!/usr/bin/env bash
exit 0
GHSTUB
chmod +x "$BIN/gh"

HERDR_LOG="$T/herdr.log"; : > "$HERDR_LOG"
CREATED_TAB="tQuick1"
cat > "$BIN/herdr" <<STUB
#!/usr/bin/env bash
{ printf 'ARGV'; for a in "\$@"; do printf '\t[%s]' "\$a"; done; printf '\n'; } >> "$HERDR_LOG"
case "\$1 \$2" in
  "workspace list") printf '{"result":{"workspaces":[{"workspace_id":"wTest","label":"%s"}]}}\n' "\${WORKSPACE_NAME:-herdkit}" ;;
  "tab list")       printf '{"result":{"tabs":[{"tab_id":"$CREATED_TAB","label":"%s","workspace_id":"wTest"}]}}\n' "\$SLUG_UNDER_TEST" ;;
  "tab create")     printf '{"result":{"tab":{"tab_id":"$CREATED_TAB"},"root_pane":{"pane_id":"rQuick1"}}}\n' ;;
  "agent start")    printf '{"result":{"agent":{"pane_id":"aQuick1"}}}\n' ;;
  "pane rename")    : ;;
  "pane run")       : ;;
  *) : ;;
esac
exit 0
STUB
chmod +x "$BIN/herdr"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/claude"; chmod +x "$BIN/claude"
export PATH="$BIN:$PATH"

# ── hermetic project config, shared by BOTH the lib-sourced agent-watch.sh AND the REAL herd-quick.sh
# subprocess _drain_spawn_queue will exec — one config, exactly like the live system's one project. ──
CFG="$T/config"
cat > "$CFG" <<EOF
PROJECT_ROOT="$REPO"
WORKTREES_DIR="$TREES_DIR"
DEFAULT_BRANCH="origin/main"
WORKSPACE_NAME="herdkit"
APP_PREVIEW_CMD=""
MODEL_QUICK="test-quick-model"
MODEL_FEATURE="test-feature-model"
BACKLOG_FILE="BACKLOG.md"
SCRIBE_BACKEND="file"
EOF
export HERD_CONFIG_FILE="$CFG"
export HOME="$T"                # herd_pretrust_worktree writes $HOME/.claude.json — keep it sandboxed
export HERD_SKIP_PREFLIGHT=1    # no real herdr contract to probe
export WORKSPACE_NAME="herdkit"

export AGENT_WATCH_LIB=1 NO_COLOR=1 HERD_DRIVER=herdr-claude
export PROJECT_ROOT="$REPO" WORKTREES_DIR="$TREES_DIR"
export JOURNAL_FILE="$T/journal.jsonl"
export HERD_HEALTHCHECK_BIN="$HC"
export DEFAULT_BRANCH=origin/main
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"
for fn in reconcile_main_health _main_health_autofix _main_health_autofix_spawn \
          _slug_builder_tab_ids _spawn_inflight_bg _lane_spawn_inflight; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined after sourcing"
done
# _drain_spawn_queue / _drain_lane_worker are defined AFTER agent-watch.sh's own
# `[ "$AGENT_WATCH_LIB" = 1 ] && return 0` early-out (they belong to the resident-watcher tick loop,
# never needed by the lib-mode unit tests that predate spawn-queue draining) — extract them the same
# way tests/test-spawn-queue-drain.sh does, verbatim from the committed source, so this test still
# drives the REAL implementation rather than a hand-copied one.
for fn in _drain_lane_worker _drain_spawn_queue; do
  _extracted="$(sed -n "/^${fn}()/,/^}/p" "$WATCH")"
  [ -n "$_extracted" ] || fail "could not extract $fn from agent-watch.sh"
  eval "$_extracted"
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined after extraction"
done
case "$(_journal_file)" in "$T"/*) : ;; *) fail "journal path escapes the sandbox" ;; esac

SCRIBE_LOG="$T/scribe.log"; : > "$SCRIBE_LOG"
NOTIFY_LOG="$T/notify.log"; : > "$NOTIFY_LOG"
herd_driver_notify() { printf '%s\n' "$1" >> "$NOTIFY_LOG"; }
_main_health_scribe() { printf '%s\n' "$1" >> "$SCRIBE_LOG"; }

head_sha() { git -C "$REPO" rev-parse HEAD; }
settle() {
  local n=0
  while [ "$n" -lt 400 ]; do
    ls "$TREES_DIR"/.health-dispatch-main-* >/dev/null 2>&1 && break
    ls "$TREES_DIR"/.health-inflight-main-* >/dev/null 2>&1 || break
    sleep 0.05; n=$((n + 1))
  done
  _collect_main_health
}
jcount() { local n; n="$(grep -c "$1" "$JOURNAL_FILE" 2>/dev/null)" || n=0; printf '%s' "${n:-0}"; }
# new_sha — advance $MAIN's HEAD AND push it to origin, so the SAME commit new-feature.sh's
# `git worktree add … origin/main` later branches from is the one main-health reproduced red on —
# mirrors how one project's default branch is both the health target and the worktree source.
new_sha() {
  printf '%s\n' "$RANDOM$RANDOM" >> "$REPO/seed.txt"
  git -C "$REPO" add -A && git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m "$1"
  git -C "$REPO" push -q origin main
}

MAIN_HEALTH_TICK=on
MAIN_HEALTH_RECHECK_MINS=0
MAIN_HEALTH_AUTOFIX=spawn
MAIN_HEALTH_CI_GATE=off
REVIEW_CONCURRENCY=2
SPAWN_AHEAD=1
DRYRUN=""

SPAWN_Q="$TREES_DIR/spawn-queue"
spawn_reqs() { ls "$SPAWN_Q"/*.req 2>/dev/null | wc -l | tr -d ' '; }
latest_req() { ls -t "$SPAWN_Q"/*.req 2>/dev/null | sed -n '1p'; }

# ── (u) a red under MAIN_HEALTH_AUTOFIX=spawn files the scribe item AND enqueues a tracked intent ──
printf 'red-file\n' > "$HC_MODE"
new_sha "feat: reds main with autofix=spawn (chain test)"
SHASPAWN="$(head_sha)"
reconcile_main_health; settle
[ "$(jcount '"event":"main_health_autofix".*"result":"enqueued"')" -eq 1 ] || fail "(u) autofix=spawn did not file the scribe item"
[ "$(jcount '"event":"main_health_autofix_spawn".*"result":"enqueued"')" -eq 1 ] || fail "(u) autofix=spawn did not journal a spawn enqueue"
[ "$(spawn_reqs)" -eq 1 ] || fail "(u) spawn.sh did not enqueue exactly one intent: $(ls "$SPAWN_Q" 2>/dev/null)"
REQ_U="$(latest_req)"
SLUG="$(sed -n '1p' "$REQ_U")"
[ -n "$SLUG" ] || fail "(u) could not read the spawned slug from $REQ_U"
case "$SLUG" in main-red-"${SHASPAWN:0:8}"-*) : ;; *) fail "(u) spawned slug does not embed the red sha: $SLUG" ;; esac
export SLUG_UNDER_TEST="$SLUG"   # so the herdr 'tab list' stub can echo this exact slug back
ok "(u) MAIN_HEALTH_AUTOFIX=spawn files the scribe item and enqueues a tracked+claimed quick-lane intent"

# ── (v)/(w)/(x) drain the SAME intent through the REAL _drain_spawn_queue → REAL herd-quick.sh ─────
FEATS=()
_drain_spawn_queue
wait

[ "$(spawn_reqs)" -eq 0 ] || fail "(v) the intent was not drained — still queued: $(ls "$SPAWN_Q" 2>/dev/null)"
[ "$(jcount "\"event\":\"spawn_launched\".*\"slug\":\"$SLUG\"")" -eq 1 ] || fail "(v) draining did not journal spawn_launched for $SLUG — journal: $(cat "$JOURNAL_FILE")"
ok "(v) the autofix-originated intent drains through the durable queue exactly like any other spawn (PR #151 contract holds)"

# The REAL herd-quick.sh ran: a REAL worktree exists on disk, off origin/main — this is what makes
# the builder DISCOVERABLE next tick (the watcher walks `git worktree list`, not open PRs).
WT="$TREES_DIR/$SLUG"
[ -e "$WT/.git" ] || fail "(w) herd-quick.sh did not create a real worktree at $WT"
WTLIST="$(git -C "$REPO" worktree list)"
grep -qF "$WT" <<<"$WTLIST" || fail "(w) the new worktree is not registered on the project's worktree list — invisible to the watcher's FEATS walk: $WTLIST"
ok "(w) the drained spawn produced a REAL worktree the watcher's FEATS walk (git worktree list) discovers"

# HERD-613: under the file backend (no synchronous create available to this tick), the spawn carries
# NO ref at all — the raw failing identity ("app/greet.test.sh") is NOT a tracker id, and threading it
# as HERD_ITEM_REF is exactly the bug that left PRs 712/719 with an unresolvable-forever ESCALATED
# tracker-heal row. The externalized task spec must therefore carry NO 'Refs:' line, and NO
# .herd-ref-$SLUG marker — an untracked spawn, byte-identical to any other ref-less spawn, proven all
# the way to the file the builder actually reads.
SPEC="$TREES_DIR/$SLUG.task.md"
[ -s "$SPEC" ] || fail "(w) no externalized task spec written at $SPEC"
grep -qF "Refs:" "$SPEC" && fail "(w) HERD-613: the task spec carries a 'Refs:' line despite no real tracker id being available — the raw failing identity leaked through: $(cat "$SPEC")"
[ -e "$TREES_DIR/.herd-ref-$SLUG" ] && fail "(w) HERD-613: .herd-ref-$SLUG exists despite no real tracker id being available: $(cat "$TREES_DIR/.herd-ref-$SLUG" 2>/dev/null)"
ok "(w) with no real tracker id available, the spawn is untracked end to end — never the raw failing identity as a ref (HERD-613)"

# The builder tab registers in .herd-tabs (the tab-leak-guard / sweep allowlist) — the OTHER surface
# that must know this pane is engine-created, not a stray tab a human opened.
grep -qE "^${SLUG} .* builder\$" "$TREES_DIR/.herd-tabs" || fail "(w) the builder tab did not register in .herd-tabs: $(cat "$TREES_DIR/.herd-tabs" 2>/dev/null)"
ok "(w) the builder tab is registered in .herd-tabs, discoverable by the tab-leak-guard / sweep"

# THE MUTATION-PROOF (x): the actual herdr 'agent start' argv — the ONE line that determines whether
# the builder can act unattended or stalls at a permission prompt — carries the bypass flag. Grepping
# the herdr call log (not herd-quick.sh's source) proves the flag reached the REAL launch command,
# not merely that the source code SAYS it should.
grep -qF '[agent]	[start]' "$HERDR_LOG" || fail "(x) no 'herdr agent start' call was made at all — the builder never launched: $(cat "$HERDR_LOG")"
AGENT_LINE="$(grep -F '[agent]	[start]' "$HERDR_LOG" | tail -1)"
case "$AGENT_LINE" in *'[--dangerously-skip-permissions]'*) : ;; *) fail "(x) the real agent-start argv is MISSING the permission-bypass flag — this IS the live 'manual mode on' stall this item fixes: $AGENT_LINE" ;; esac
case "$AGENT_LINE" in *'[claude]'*) : ;; *) fail "(x) the real agent-start argv did not launch claude at all: $AGENT_LINE" ;; esac
ok "(x) the REAL herdr agent-start argv carries --dangerously-skip-permissions — a spawn-tier launch produces a pane with bypass ON, mutation-proved end to end"

echo "ALL PASS ($pass checks)"
