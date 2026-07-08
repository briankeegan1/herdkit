#!/usr/bin/env bash
# test-watcher-claude-hang.sh — hermetic proof for the watcher's CLAUDE EXEC-HANG probe (HERD-108).
#
# On some environments `claude` WEDGES on invocation (every exec hangs before the process finishes
# starting — e.g. the macOS com.apple.quarantine _dyld_start hang). A wedged claude makes every
# review/refix dispatch spawn a corpse, so the watcher's poll loop burns cycles against a hang it cannot
# see. The probe (WATCH_CLAUDE_PROBE_TIMEOUT) runs a trivial `claude --version` under a HARD timeout ONCE
# per tick before dispatch; a timeout HOLDS review/refix for that tick with a loud row + a journal
# infra_event. It complements the HERD-110 breaker (which only reacts AFTER reviewers die).
#
# This locks the load-bearing properties of the shipped probe helpers:
#   (1) BYTE-INERT by default — WATCH_CLAUDE_PROBE_TIMEOUT unset/0/garbage → OK, claude is NEVER exec'd,
#       no state file, no journal (behavior byte-identical to before the feature).
#   (2) A WEDGED claude → HUNG, a state marker is written, and ONE loud infra_event is journaled.
#   (3) A persistent wedge journals the infra_event ONCE per episode (deduped across ticks), not per tick.
#   (4) RECOVERY — a claude that responds again → OK, the marker is cleared, a recovery event is journaled;
#       a later relapse journals a fresh hang (episode re-opens).
#   (5) FAIL-SOFT — a broken (non-zero `--version`) OR an ABSENT claude is NOT a hang (→ OK, no hold,
#       no infra_event): claude may simply be missing / a different fault, never a queue stall.
#
# Fully hermetic: agent-watch.sh sourced in LIB mode (AGENT_WATCH_LIB=1 → helpers only, no loop/re-exec)
# against a temp WORKTREES_DIR and a non-existent config, each case in its own subshell. Real coreutils
# `timeout` on PATH exercises the shipped coreutils path. NO herdr, NO gh, NO network, NO model. python3
# is a herd hard dep (journal.sh). Run:  bash tests/test-watcher-claude-hang.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WATCH="$ROOT/scripts/herd/agent-watch.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ PASS=$((PASS+1)); echo "PASS $1"; }

[ -f "$WATCH" ] || fail "missing agent-watch.sh at $WATCH"
command -v python3 >/dev/null 2>&1 || fail "python3 required (journal.sh)"

# stub_claude <bindir> <kind> [sentinel] — install a claude stub of one kind, and (if <sentinel> given)
# have it `touch` that path on EVERY invocation so a scenario can prove the probe did / did not exec it.
#   hung   → never returns (exec sleep — the pid the timeout kills is the sleep)
#   ok     → responds instantly (exit 0)
#   broken → present but exits non-zero
stub_claude() {
  local d="$1" kind="$2" sentinel="${3:-}"
  mkdir -p "$d"
  { printf '#!/usr/bin/env bash\n'
    [ -n "$sentinel" ] && printf 'touch %q\n' "$sentinel"
    case "$kind" in
      hung)   printf 'exec sleep 30\n' ;;
      ok)     printf 'exit 0\n' ;;
      broken) printf 'exit 3\n' ;;
    esac
  } > "$d/claude"
  chmod +x "$d/claude"
}

# source_watcher <trees> [TIMEOUT] — source the REAL watcher in lib mode with the probe knob in the
# CURRENT shell. Callers run each scenario in its own subshell so state cannot leak.
source_watcher() {
  export AGENT_WATCH_LIB=1
  export HERD_CONFIG_FILE="$T/no-such-config"
  export WORKTREES_DIR="$1"
  export JOURNAL_FILE="$1/journal.jsonl"
  [ -n "${2:-}" ] && export WATCH_CLAUDE_PROBE_TIMEOUT="$2"
  mkdir -p "$1" 2>/dev/null || true
  # shellcheck source=/dev/null
  . "$WATCH" || { echo "__SOURCE_FAILED__"; exit 1; }
}
jcount(){ grep -c "$1" "$2" 2>/dev/null || echo 0; }

# ── (1) BYTE-INERT when disabled (default): claude never exec'd, no state, no journal ─────────────
(
  WT="$T/off"; SENT="$WT/claude-ran"
  STUB="$WT/bin"; stub_claude "$STUB" hung "$SENT"    # a WEDGE that must never be invoked
  export PATH="$STUB:$PATH"
  source_watcher "$WT"                                # WATCH_CLAUDE_PROBE_TIMEOUT unset → default 0 → off
  _claude_probe_secs && { echo "probe enabled when unset"; exit 1; }
  [ "$(_claude_exec_hung)" = "OK" ] || { echo "disabled probe not OK"; exit 1; }
  [ -f "$SENT" ]                     && { echo "disabled probe EXEC'd claude"; exit 1; }
  [ -f "$WT/.agent-watch-claude-hang" ] && { echo "disabled probe wrote a state file"; exit 1; }
  [ -f "$JOURNAL_FILE" ] && grep -q claude-exec-hang "$JOURNAL_FILE" && { echo "disabled probe journaled"; exit 1; }
  # An explicit 0 and a garbage value are also OFF (fail-safe parse).
  export WATCH_CLAUDE_PROBE_TIMEOUT=0;       _claude_probe_secs && { echo "0 enabled"; exit 1; }
  export WATCH_CLAUDE_PROBE_TIMEOUT=garbage; _claude_probe_secs && { echo "garbage enabled"; exit 1; }
  exit 0
) || fail "(1) disabled probe was not byte-inert"
ok "(1) WATCH_CLAUDE_PROBE_TIMEOUT unset/0/garbage → byte-inert: claude never exec'd, no state, no journal"

# ── (2) WEDGED claude → HUNG, marker written, ONE infra_event journaled ───────────────────────────
(
  WT="$T/hung"; STUB="$WT/bin"; stub_claude "$STUB" hung; export PATH="$STUB:$PATH"
  source_watcher "$WT" 2
  [ "$(_claude_exec_hung)" = "HUNG" ] || { echo "wedge not detected as HUNG"; exit 1; }
  [ -s "$WT/.agent-watch-claude-hang" ] || { echo "no hang marker written"; exit 1; }
  grep -q '"reason":"claude-exec-hang"' "$JOURNAL_FILE" || { echo "no claude-exec-hang infra_event"; exit 1; }
  grep -q '"event":"infra_event"'       "$JOURNAL_FILE" || { echo "hang not journaled as infra_event"; exit 1; }
  [ "$(jcount '"reason":"claude-exec-hang"' "$JOURNAL_FILE")" = "1" ] || { echo "hang journaled != once"; exit 1; }
  exit 0
) || fail "(2) a wedged claude was not detected + surfaced"
ok "(2) wedged claude → HUNG; marker written; ONE infra_event (component agent-watch) journaled"

# ── (3) persistent wedge → journaled ONCE per episode, not per tick ───────────────────────────────
(
  WT="$T/persist"; STUB="$WT/bin"; stub_claude "$STUB" hung; export PATH="$STUB:$PATH"
  source_watcher "$WT" 2
  i=0; while [ "$i" -lt 4 ]; do [ "$(_claude_exec_hung)" = "HUNG" ] || { echo "tick $i not HUNG"; exit 1; }; i=$((i+1)); done
  [ "$(jcount '"reason":"claude-exec-hang"' "$JOURNAL_FILE")" = "1" ] \
    || { echo "persistent wedge spammed the journal ($(jcount '"reason":"claude-exec-hang"' "$JOURNAL_FILE")×)"; exit 1; }
  exit 0
) || fail "(3) persistent wedge did not dedupe its journal to once-per-episode"
ok "(3) a persistent wedge journals the hang ONCE per episode (deduped across ticks)"

# ── (4) RECOVERY → OK, marker cleared, recovery journaled; a relapse re-opens a fresh episode ──────
(
  WT="$T/recover"; STUB="$WT/bin"; export PATH="$STUB:$PATH"
  stub_claude "$STUB" hung; source_watcher "$WT" 2
  [ "$(_claude_exec_hung)" = "HUNG" ] || { echo "initial wedge not HUNG"; exit 1; }
  stub_claude "$STUB" ok                                   # claude responds again
  [ "$(_claude_exec_hung)" = "OK" ]   || { echo "recovered claude not OK"; exit 1; }
  [ -f "$WT/.agent-watch-claude-hang" ] && { echo "marker not cleared on recovery"; exit 1; }
  grep -q '"reason":"claude-exec-hang-cleared"' "$JOURNAL_FILE" || { echo "recovery not journaled"; exit 1; }
  # A relapse must journal a FRESH hang (episode #2), not stay silent.
  stub_claude "$STUB" hung
  [ "$(_claude_exec_hung)" = "HUNG" ] || { echo "relapse not HUNG"; exit 1; }
  [ "$(jcount '"reason":"claude-exec-hang"' "$JOURNAL_FILE")" = "2" ] || { echo "relapse did not re-open a fresh episode"; exit 1; }
  exit 0
) || fail "(4) recovery / relapse episode lifecycle wrong"
ok "(4) recovery clears the marker + journals; a later relapse re-opens a fresh hang episode"

# ── (5) FAIL-SOFT: a broken (non-zero) OR absent claude is NOT a hang → OK, no hold, no journal ────
(
  WT="$T/broken"; STUB="$WT/bin"; stub_claude "$STUB" broken; export PATH="$STUB:$PATH"
  source_watcher "$WT" 2
  [ "$(_claude_exec_hung)" = "OK" ] || { echo "broken claude wrongly held (not OK)"; exit 1; }
  [ -f "$WT/.agent-watch-claude-hang" ] && { echo "broken claude wrote a hang marker"; exit 1; }
  grep -q claude-exec-hang "$JOURNAL_FILE" 2>/dev/null && { echo "broken claude journaled a hang"; exit 1; }
  exit 0
) || fail "(5a) a broken claude was mis-treated as a hang"
ok "(5a) a broken (non-zero --version) claude is fail-soft → OK, no hold, no infra_event"
(
  # Absent claude: source the watcher under the REAL PATH (so its sibling `. …` sources resolve), THEN
  # narrow PATH to a coreutils-only dir with NO claude before probing.
  WT="$T/absent"; source_watcher "$WT" 2
  CORE="$T/absent-core"; mkdir -p "$CORE"
  for t in timeout sleep; do ln -sf "$(command -v "$t")" "$CORE/$t" 2>/dev/null || true; done
  PATH="$CORE"
  command -v claude >/dev/null 2>&1 && { echo "claude unexpectedly present in absent scenario"; exit 1; }
  [ "$(_claude_exec_hung)" = "OK" ] || { echo "absent claude wrongly held (not OK)"; exit 1; }
  [ -f "$WT/.agent-watch-claude-hang" ] && { echo "absent claude wrote a hang marker"; exit 1; }
  exit 0
) || fail "(5b) an absent claude was mis-treated as a hang"
ok "(5b) an absent claude is fail-soft → OK, no hold (the doctor reports absence separately)"

echo "ALL PASS ($PASS checks) — test-watcher-claude-hang.sh"
