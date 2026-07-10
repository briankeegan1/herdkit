#!/usr/bin/env bash
# test-context-guard-panes.sh — hermetic proof of the PANE/TAB-MUTATION invocation-context guard
# (HERD-310): a builder worktree may never close the operator's LIVE herdr panes/tabs.
#
# THE INCIDENT (2026-07-10). A direct (non-bats) run of the watcher-* tests from INSIDE a live builder
# tab drove the tab-teardown path against the operator's LIVE herdr socket and closed REAL tabs —
# severing an in-flight review (the review·<slug> tab close) and killing the builder agent (the
# <slug> tab close). The pane-close IDENTITY guard (HERD-134) refused the PANE close but the TAB close
# bypassed it. herd_context_pane_guard (scripts/herd/context-guard.sh) closes that gap at the ONE
# shared seam every test reaches by SOURCING the engine.
#
# This asserts the guard's decision table and its wiring into the close primitives:
#   (A) refuse from a builder worktree + live socket + a REAL (non-disposable) workspace, journaled
#   (B) allow from the CONTROL ROOM (main checkout — never a worktree): output byte-identical
#   (C) allow against a DISPOSABLE sandbox-* sim workspace (the sandbox-real-panes convention)
#   (D) allow with HERD_DISPOSABLE_WORKSPACE=1 (explicit override for a non-sandbox fixture)
#   (E) allow with NO herdr / NO server (headless CI, the hermetic no-socket path): byte-identical
#   (F) allow under HERD_DRIVER=headless (panes-as-a-view — the engine spawns no real panes)
#   (G) HERD_ALLOW_REAL_PANE_MUTATION=1 bypasses LOUDLY + journals control_pane_mutation_bypass
#   (H) INTEGRATION: herd_teardown_slug closes ZERO tabs from a worktree (the incident) but closes
#       normally from the control room (byte-identical merge/retirement teardown)
#   (I) WIRING: the ONE shared guard is called at every close seam — no per-test / per-caller copies
#
# Hermetic: a FILE-LOGGING stub `herdr` (no real panes, no server), local only, NETWORK-FREE.
# Run:  bash tests/test-context-guard-panes.sh
# No `set -e`: several checks deliberately assert a non-zero (refuse) return.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { PASS=$((PASS+1)); }
command -v python3 >/dev/null 2>&1 || fail "python3 required"

# ── a stub `herdr` that MODELS a live control surface with two real tabs, and LOGS every close ──────
# `workspace list` answers (so _herd_context_socket_live sees a live socket); `tab list` reports a
# builder tab + a review tab in workspace wA; `tab close`/`pane close` append to $CLOSELOG so a test
# can prove EXACTLY which tabs/panes a code path closed (or that it closed NONE).
BIN="$T/bin"; mkdir -p "$BIN"
CLOSELOG="$T/close.log"; : > "$CLOSELOG"
cat > "$BIN/herdr" <<EOF
#!/usr/bin/env bash
case "\$1 \$2" in
  "workspace list")
    printf '{"result":{"workspaces":[{"workspace_id":"wA","label":"%s"}]}}\n' "\${WORKSPACE_NAME:-operator}" ;;
  "tab list")
    printf '{"result":{"tabs":[{"tab_id":"t1","label":"my-slug","workspace_id":"wA"},{"tab_id":"t2","label":"review·my-slug","workspace_id":"wA"}]}}\n' ;;
  "tab close")  printf 'tab close %s\n'  "\$3" >> "$CLOSELOG" ;;
  "pane close") printf 'pane close %s\n' "\$3" >> "$CLOSELOG" ;;
esac
exit 0
EOF
chmod +x "$BIN/herdr"
export PATH="$BIN:$PATH"
export JOURNAL_FILE="$T/journal.jsonl"; : > "$JOURNAL_FILE"

# The engine as the tests source it: journal.sh (so refusals journal) then herd-config.sh (which
# sources context-guard.sh AND defines herd_teardown_slug — the exact scope a watcher test inherits).
# shellcheck source=/dev/null
. "$REPO/scripts/herd/journal.sh"
# shellcheck source=/dev/null
. "$REPO/scripts/herd/herd-config.sh"

command -v herd_context_pane_guard >/dev/null 2>&1 || fail "context-guard.sh must define herd_context_pane_guard (sourced via herd-config.sh)"
command -v herd_teardown_slug      >/dev/null 2>&1 || fail "herd-config.sh must define herd_teardown_slug"

# A builder WORKTREE (clause B: cwd inside WORKTREES_DIR) and a CONTROL ROOM (a plain dir that is
# neither a linked git worktree nor inside WORKTREES_DIR — _herd_context_is_worktree is false there).
export WORKTREES_DIR="$T/trees"
WT="$T/trees/wt"; mkdir -p "$WT"
ROOM="$T/main";   mkdir -p "$ROOM"

reset_log() { : > "$CLOSELOG"; }
n_closes()  { awk 'END{print NR}' "$CLOSELOG" 2>/dev/null || echo 0; }
journal_has() { grep -q "\"event\":\"$1\"" "$JOURNAL_FILE" 2>/dev/null; }

# ── (A) worktree + live socket + REAL workspace → REFUSE (rc 1) + journaled ─────────────────────────
: > "$JOURNAL_FILE"
( cd "$WT"; WORKSPACE_NAME=operator herd_context_pane_guard "probe A" ) >/dev/null 2>&1 \
  && fail "(A) guard must REFUSE (rc!=0) from a builder worktree against a real workspace"
ok
journal_has control_pane_mutation_refused || fail "(A) a refusal must journal control_pane_mutation_refused"
ok

# ── (B) control room (not a worktree) → ALLOW (rc 0), nothing journaled ─────────────────────────────
: > "$JOURNAL_FILE"
( cd "$ROOM"; WORKSPACE_NAME=operator herd_context_pane_guard "probe B" ) >/dev/null 2>&1 \
  || fail "(B) guard must ALLOW from the control room (main checkout)"
ok
journal_has control_pane_mutation_refused && fail "(B) the control-room path must NOT journal a refusal (byte-identical)"
ok

# ── (C) worktree + DISPOSABLE sandbox-* sim workspace → ALLOW ───────────────────────────────────────
( cd "$WT"; WORKSPACE_NAME=sandbox-realpanes-sim-4242 herd_context_pane_guard "probe C" ) >/dev/null 2>&1 \
  || fail "(C) guard must ALLOW against a disposable sandbox-* sim workspace"
ok

# ── (D) worktree + explicit HERD_DISPOSABLE_WORKSPACE=1 → ALLOW ─────────────────────────────────────
( cd "$WT"; WORKSPACE_NAME=operator HERD_DISPOSABLE_WORKSPACE=1 herd_context_pane_guard "probe D" ) >/dev/null 2>&1 \
  || fail "(D) guard must ALLOW with HERD_DISPOSABLE_WORKSPACE=1"
ok

# ── (E) NO herdr on PATH (no live socket) → ALLOW (fail-soft, byte-identical) ───────────────────────
( cd "$WT"; PATH="/usr/bin:/bin"; WORKSPACE_NAME=operator herd_context_pane_guard "probe E" ) >/dev/null 2>&1 \
  || fail "(E) guard must ALLOW (skip-soft) when there is no herdr socket"
ok

# ── (F) HERD_DRIVER=headless (panes-as-a-view: no real panes) → ALLOW ───────────────────────────────
( cd "$WT"; WORKSPACE_NAME=operator HERD_DRIVER=headless herd_context_pane_guard "probe F" ) >/dev/null 2>&1 \
  || fail "(F) guard must ALLOW under headless (no real panes to protect)"
ok

# ── (G) HERD_ALLOW_REAL_PANE_MUTATION=1 → ALLOW (rc 0) + journaled BYPASS ───────────────────────────
: > "$JOURNAL_FILE"
( cd "$WT"; WORKSPACE_NAME=operator HERD_ALLOW_REAL_PANE_MUTATION=1 herd_context_pane_guard "probe G" ) >/dev/null 2>&1 \
  || fail "(G) the escape hatch must ALLOW the mutation"
ok
journal_has control_pane_mutation_bypass || fail "(G) the bypass must journal control_pane_mutation_bypass"
ok

# ── (H) INTEGRATION: herd_teardown_slug — the exact incident path ──────────────────────────────────
# From a builder worktree against the REAL workspace: it must close ZERO tabs (t1/t2 survive).
reset_log
( cd "$WT"; WORKSPACE_NAME=operator herd_teardown_slug "my-slug" ) >/dev/null 2>&1
[ "$(n_closes)" -eq 0 ] || fail "(H) herd_teardown_slug from a worktree must close ZERO real tabs (closed: $(cat "$CLOSELOG"))"
ok
# From the control room: the teardown closes the builder + review tabs exactly as before.
reset_log
( cd "$ROOM"; WORKSPACE_NAME=operator herd_teardown_slug "my-slug" ) >/dev/null 2>&1
grep -qx "tab close t1" "$CLOSELOG" || fail "(H) control-room teardown must close the builder tab t1"
ok
grep -qx "tab close t2" "$CLOSELOG" || fail "(H) control-room teardown must close the review tab t2"
ok

# ── (I) WIRING: ONE shared guard, called at every close seam (no per-caller copies) ─────────────────
# The guard is DEFINED once in context-guard.sh and CALLED (never re-implemented) at each seam.
[ "$(grep -c 'herd_context_pane_guard()' "$REPO/scripts/herd/context-guard.sh")" -eq 1 ] \
  || fail "(I) herd_context_pane_guard must be defined exactly once (in context-guard.sh)"
ok
for seam in \
  "scripts/herd/herd-config.sh" \
  "scripts/herd/driver.sh" \
  "scripts/herd/agent-watch.sh"; do
  grep -q 'herd_context_pane_guard' "$REPO/$seam" \
    || fail "(I) close seam $seam must route through herd_context_pane_guard"
done
ok
# agent-watch.sh must guard BOTH the orphan and the stale-resolve tab sweeps.
[ "$(grep -c 'herd_context_pane_guard' "$REPO/scripts/herd/agent-watch.sh")" -ge 2 ] \
  || fail "(I) agent-watch.sh must guard both tab-close sweeps"
ok

echo "ALL PASS ($PASS checks) — test-context-guard-panes.sh"
