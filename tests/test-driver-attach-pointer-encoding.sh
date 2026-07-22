#!/usr/bin/env bash
# test-driver-attach-pointer-encoding.sh — hermetic proof for issue #516: herdr's attach CLI
# ("agent start <name> --kind <kind> --pane <id> -- <args>", issue #514) cannot shell-encode a
# MULTILINE agent argument. Drainer lanes (scribe.sh, research.sh) hand a multi-KB multiline PROMPT
# as the pointer arg through herd_driver_herdr_attach_agent — the ONE shared bridge every herdr-claude
# spawn site (builder start-agent, the generalized launch-agent, and agent-watch.sh's respawn) routes
# through — so the fix lives there once, not per-lane.
#
# Covers:
#   1. A multiline runtime arg is externalized to a file under WORKTREES_DIR (.pointer-<name>.md)
#      BEFORE it ever reaches herdr; herdr receives a short single-line pointer instead. The stub
#      herdr hard-fails on any arg it receives containing a literal newline, so a false pass here is
#      structurally impossible.
#   2. A single-line runtime arg passes through byte-identical — no pointer file is written (prove
#      the lever both ways, AGENTS.md).
#   3. Defensive path: no arg LOOKED multiline, but herdr still rejects the argv with
#      invalid_agent_argument — the bridge externalizes the trailing (pointer) arg and retries ONCE.
#   4. Fail-soft: an unwritable WORKTREES_DIR makes the externalize helper hand back the arg
#      UNCHANGED (never abort) — the caller falls back to today's behavior (herdr reports the
#      encoding error as before).
#
# Fully hermetic: local temp dirs + a stub herdr on PATH. NO real herdr/claude/gh/network.
# Run:  bash tests/test-driver-attach-pointer-encoding.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
DRIVER_SH="$ROOT/scripts/herd/driver.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ pass=$((pass+1)); }
[ -f "$DRIVER_SH" ] || fail "missing script: $DRIVER_SH"
command -v python3 >/dev/null 2>&1 || fail "python3 required"

# ── stub herdr ───────────────────────────────────────────────────────────────────────────────────
# `agent start <name> --kind <kind> --pane <pane> -- <args…>`:
#   • ANY arg containing a literal newline → hard-fail with invalid_agent_argument (the real herdr's
#     behavior this fix routes around). Proves the driver never lets a multiline arg reach herdr.
#   • a name prefixed `iaa-` fails invalid_agent_argument on its FIRST call only (state file marker),
#     simulating an unsafe-but-not-multiline arg herdr rejects — the defensive retry path.
#   • on success, the received args are dumped NUL-separated to $STUB_STATE/<name>.args for the test
#     to inspect, and the JSON success shape callers parse (result.agent.pane_id) is emitted.
STUB_STATE="$T/state"; mkdir -p "$STUB_STATE"
BIN="$T/bin"; mkdir -p "$BIN"
cat > "$BIN/herdr" <<'STUB'
#!/usr/bin/env bash
STATE="${HERDR_STUB_STATE:?HERDR_STUB_STATE unset}"
sub="${1:-} ${2:-}"
case "$sub" in
  "agent start")
    shift 2
    if [ "${1:-}" = "--help" ]; then
      printf 'usage: herdr agent start <name> --kind <kind> --pane <id> [-- ARGS…]\n'
      exit 0
    fi
    name="$1"; shift
    pane="" kind=""
    args=()
    dd=0
    while [ $# -gt 0 ]; do
      if [ "$dd" = 1 ]; then args+=("$1"); shift; continue; fi
      case "$1" in
        --kind) kind="$2"; shift 2 ;;
        --pane) pane="$2"; shift 2 ;;
        --) dd=1; shift ;;
        *) shift ;;
      esac
    done
    for a in ${args[@]+"${args[@]}"}; do
      case "$a" in
        *$'\n'*)
          printf '{"error":"invalid_agent_argument","detail":"agent arguments cannot be encoded safely for the target shell"}\n' >&2
          exit 1
          ;;
      esac
    done
    case "$name" in
      iaa-*)
        marker="$STATE/$name.tried"
        if [ ! -f "$marker" ]; then
          : > "$marker"
          printf '{"error":"invalid_agent_argument","detail":"agent arguments cannot be encoded safely for the target shell"}\n' >&2
          exit 1
        fi
        ;;
    esac
    : > "$STATE/$name.args"
    for a in ${args[@]+"${args[@]}"}; do printf '%s\0' "$a" >> "$STATE/$name.args"; done
    printf '{"result":{"agent":{"pane_id":"%s"}}}\n' "${pane:-p1}"
    exit 0
    ;;
  "tab create")
    printf '{"result":{"tab":{"tab_id":"tab1"},"root_pane":{"pane_id":"root1"}}}\n'
    exit 0
    ;;
  "pane split")
    printf '{"result":{"pane":{"pane_id":"split1"}}}\n'
    exit 0
    ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$BIN/herdr"

read_args(){ # read_args <name> → NUL-split args of $name's LAST successful herdr call into $REPLY_ARGS
  REPLY_ARGS=()
  local f="$STUB_STATE/$1.args" t
  [ -f "$f" ] || return 1
  while IFS= read -r -d '' t; do REPLY_ARGS+=("$t"); done < "$f"
}

( set +e
  export PATH="$BIN:$PATH" HERD_HERDR_ATTACH_CLI=yes HERDR_STUB_STATE="$STUB_STATE"
  export WORKTREES_DIR="$T/proj"
  mkdir -p "$WORKTREES_DIR"
  # shellcheck source=/dev/null
  . "$DRIVER_SH"

  # ── 1. multiline arg externalized before it ever reaches herdr. ────────────────────────────────
  PROMPT=$'line one\nline two\nline three — issue #516'
  herd_driver_herdr_attach_agent scribe herdr-claude root1 "$T/repo" "" "" \
    -- claude --model opus --dangerously-skip-permissions "$PROMPT" >/dev/null 2>"$T/err1"
  rc=$?
  [ "$rc" -eq 0 ] || { echo "FAIL: multiline attach rc=$rc"; cat "$T/err1"; exit 1; }
  PTR_FILE="$WORKTREES_DIR/.pointer-scribe.md"
  [ -f "$PTR_FILE" ] || { echo "FAIL: pointer file $PTR_FILE not written"; exit 1; }
  diff <(printf '%s\n' "$PROMPT") "$PTR_FILE" >/dev/null || { echo "FAIL: pointer file content mismatch"; cat "$PTR_FILE"; exit 1; }
  read_args scribe || { echo "FAIL: no captured args for scribe"; exit 1; }
  last="${REPLY_ARGS[${#REPLY_ARGS[@]}-1]}"
  case "$last" in
    *$'\n'*) echo "FAIL: multiline prompt reached herdr uncollapsed"; exit 1 ;;
    "Read $PTR_FILE and follow it exactly as your instructions.") ;;
    *) echo "FAIL: unexpected substituted pointer: [$last]"; exit 1 ;;
  esac
  echo "ok 1"

  # ── 2. single-line arg passes through byte-identical; no pointer file. ─────────────────────────
  herd_driver_herdr_attach_agent oneliner herdr-claude root1 "$T/repo" "" "" \
    -- claude --model opus --dangerously-skip-permissions "short one-line prompt" >/dev/null 2>"$T/err2"
  rc=$?
  [ "$rc" -eq 0 ] || { echo "FAIL: single-line attach rc=$rc"; cat "$T/err2"; exit 1; }
  [ -f "$WORKTREES_DIR/.pointer-oneliner.md" ] && { echo "FAIL: pointer file written for a single-line prompt"; exit 1; }
  read_args oneliner || { echo "FAIL: no captured args for oneliner"; exit 1; }
  last="${REPLY_ARGS[${#REPLY_ARGS[@]}-1]}"
  [ "$last" = "short one-line prompt" ] || { echo "FAIL: single-line prompt mutated: [$last]"; exit 1; }
  echo "ok 2"

  # ── 3. defensive invalid_agent_argument retry (no newline, herdr rejects anyway). ──────────────
  herd_driver_herdr_attach_agent iaa-agent herdr-claude root1 "$T/repo" "" "" \
    -- claude --model opus --dangerously-skip-permissions "SOME_UNSAFE_PROMPT" >/dev/null 2>"$T/err3"
  rc=$?
  [ "$rc" -eq 0 ] || { echo "FAIL: defensive-retry attach rc=$rc"; cat "$T/err3"; exit 1; }
  [ -f "$STUB_STATE/iaa-agent.tried" ] || { echo "FAIL: stub never saw a first (rejected) attempt — test invalid"; exit 1; }
  PTR_FILE="$WORKTREES_DIR/.pointer-iaa-agent.md"
  [ -f "$PTR_FILE" ] || { echo "FAIL: defensive path did not externalize a pointer file"; exit 1; }
  grep -qF "SOME_UNSAFE_PROMPT" "$PTR_FILE" || { echo "FAIL: pointer file missing original prompt"; cat "$PTR_FILE"; exit 1; }
  read_args iaa-agent || { echo "FAIL: no captured args for iaa-agent"; exit 1; }
  last="${REPLY_ARGS[${#REPLY_ARGS[@]}-1]}"
  [ "$last" = "Read $PTR_FILE and follow it exactly as your instructions." ] \
    || { echo "FAIL: retried call did not carry the externalized pointer: [$last]"; exit 1; }
  echo "ok 3"

  exit 0
) || fail "attach-CLI checks failed (see FAIL above)"
ok; echo "PASS (1-3) multiline externalize / byte-identical single-line / defensive invalid_agent_argument retry"

# ── 4. fail-soft: an unwritable pointer target hands the arg back UNCHANGED. ──────────────────────
( set +e
  export PATH="$BIN:$PATH" HERD_HERDR_ATTACH_CLI=yes HERDR_STUB_STATE="$STUB_STATE"
  RO="$T/readonly-proj"; mkdir -p "$RO"; chmod 500 "$RO"
  export WORKTREES_DIR="$RO"
  # shellcheck source=/dev/null
  . "$DRIVER_SH"
  got="$(_herd_externalize_pointer_arg failwrite $'multi\nline')"
  chmod 700 "$RO"  # restore so the trap's rm -rf can clean up
  [ "$got" = $'multi\nline' ] || { echo "FAIL: fail-soft externalize mutated the arg: [$got]"; exit 1; }
  [ -e "$RO/.pointer-failwrite.md" ] && { echo "FAIL: a pointer file landed under an unwritable dir"; exit 1; }
  exit 0
) || fail "fail-soft unwritable-target check failed (see FAIL above)"
ok; echo "PASS (4) fail-soft: unwritable WORKTREES_DIR hands the arg back unchanged, never aborts"

echo "ALL PASS ($pass checks)"
