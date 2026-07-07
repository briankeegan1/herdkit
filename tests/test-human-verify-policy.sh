#!/usr/bin/env bash
# test-human-verify-policy.sh — hermetic tests for HUMAN_VERIFY_POLICY (HERD-59).
#
# HUMAN_VERIFY_POLICY codifies the standing human-verify authorization as an engine switch. Today a PR
# that declares a HUMAN-VERIFY: block is ALWAYS held for sha-keyed approval under MERGE_POLICY=auto.
# This key changes that, opt-in only:
#   hold        (default) today's EXACT behavior, byte-identical when unset.
#   coordinator keep the hold but notify loudly + flag it coordinator-actionable.
#   auto        treat the declared steps as informational — journal + PR-comment them, merge on green.
#
# Fully hermetic: stubs gh/git/herdr on PATH; touches nothing outside $T; never runs the live watch
# loop (agent-watch.sh is sourced in AGENT_WATCH_LIB=1 mode). Mirrors test-human-verify-hold.sh.
# Run:  bash tests/test-human-verify-policy.sh
# No `set -e`: several checks assert non-zero returns explicitly.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WATCH="$ROOT/scripts/herd/agent-watch.sh"
CONFIG="$ROOT/scripts/herd/herd-config.sh"
APPROVE="$ROOT/scripts/herd/herd-approve.sh"
CAPS="$ROOT/templates/capabilities.tsv"
CFG_EXAMPLE="$ROOT/templates/config.example"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

for f in "$WATCH" "$CONFIG" "$APPROVE" "$CAPS" "$CFG_EXAMPLE"; do
  [ -f "$f" ] || fail "missing required file: $f"
done
command -v python3 >/dev/null 2>&1 || fail "python3 required"

# ── Stub binaries on PATH — no network, no side-effects beyond $T ─────────────────────────────────
BIN="$T/bin"; mkdir -p "$BIN"
BODIES="$T/bodies"; mkdir -p "$BODIES"
export BODIES
cat > "$BIN/gh" << 'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "pr merge")   printf 'merge %s\n' "$3" >> "${GH_MERGE_LOG:-/dev/null}"; exit 0 ;;
  "pr comment") exit 0 ;;
  "pr list")    echo '[]'; exit 0 ;;
  "pr view")
    num="$3"; allargs="$*"
    case "$allargs" in
      *"--json body"*)  [ -f "$BODIES/$num" ] && cat "$BODIES/$num" || true ;;
      *"--json title"*) printf 'title for PR %s' "$num" ;;
      *)                : ;;
    esac
    exit 0 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$BIN/gh"
for cmd in git herdr; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$cmd"; chmod +x "$BIN/$cmd"
done
export PATH="$BIN:$PATH"

export WORKTREES_DIR="$T/trees"; mkdir -p "$WORKTREES_DIR"
export HERD_CONFIG_FILE="$T/no-such-config"

# ── 1. capabilities.tsv: HUMAN_VERIFY_POLICY documented as a watcher-affecting, machine-scoped key ─
row="$(awk -F'\t' '$1=="HUMAN_VERIFY_POLICY" && $2=="config"{print NF"|"$5"|"$6; exit}' "$CAPS")"
[ -n "$row" ] || fail "(1) HUMAN_VERIFY_POLICY missing from capabilities.tsv (kind=config)"
[ "${row%%|*}" = "6" ] || fail "(1) HUMAN_VERIFY_POLICY row should have 6 columns, got: $row"
[ "$(echo "$row" | cut -d'|' -f2)" = "watcher" ] || fail "(1) HUMAN_VERIFY_POLICY requires must be 'watcher', got: $row"
[ "$(echo "$row" | cut -d'|' -f3)" = "machine" ] || fail "(1) HUMAN_VERIFY_POLICY scope must be 'machine' (posture opt-in), got: $row"
ok
# when_to_surface (col 4) present and mentions all three values so the manifest is self-documenting.
wts="$(awk -F'\t' '$1=="HUMAN_VERIFY_POLICY"{print $4; exit}' "$CAPS")"
for v in coordinator auto hold; do
  printf '%s' "$wts" | grep -q "$v" || fail "(1) when_to_surface should mention '$v': $wts"
done
ok

# ── 2. herd-config.sh default = hold (byte-identical behavior when the key is unset) ──────────────
default_hv="$(
  unset HUMAN_VERIFY_POLICY
  HERD_CONFIG_FILE="$T/no-such-config" bash -c '. "$1" >/dev/null 2>&1; printf "%s" "${HUMAN_VERIFY_POLICY:-UNSET}"' _ "$CONFIG"
)"
[ "$default_hv" = "hold" ] || fail "(2) herd-config.sh default HUMAN_VERIFY_POLICY must be 'hold', got: $default_hv"
ok

# ── 3. Source agent-watch.sh in lib mode; new helpers defined ────────────────────────────────────
export AGENT_WATCH_LIB=1
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"
for fn in _effective_human_verify_policy _hold_decision _hold_ready_label \
          hv_informed_noted record_hv_informed pr_human_verify_held pr_human_verify_steps; do
  type "$fn" >/dev/null 2>&1 || fail "(3) $fn not defined"
done
ok

# ── 4. _effective_human_verify_policy — normalization + safe fallback ────────────────────────────
[ "$(HUMAN_VERIFY_POLICY=hold        _effective_human_verify_policy)" = "hold" ]        || fail "(4) hold → hold"
[ "$(HUMAN_VERIFY_POLICY=coordinator _effective_human_verify_policy)" = "coordinator" ] || fail "(4) coordinator → coordinator"
[ "$(HUMAN_VERIFY_POLICY=auto        _effective_human_verify_policy)" = "auto" ]        || fail "(4) auto → auto"
[ "$(HUMAN_VERIFY_POLICY=            _effective_human_verify_policy)" = "hold" ]        || fail "(4) empty → hold"
[ "$(HUMAN_VERIFY_POLICY=cordinator  _effective_human_verify_policy)" = "hold" ]        || fail "(4) typo → hold (fail safe)"
( unset HUMAN_VERIFY_POLICY; [ "$(_effective_human_verify_policy)" = "hold" ] ) || fail "(4) unset → hold"
ok

# ── 5. _hold_decision — the 4th (policy) arg shapes the auto+human-verify path ────────────────────
# hold: today's behavior — HOLD until approved.
[ "$(_hold_decision auto '1' '' hold)"  = "HOLD"  ] || fail "(5) auto/hv/unapproved/hold → HOLD"
[ "$(_hold_decision auto '1' '1' hold)" = "MERGE" ] || fail "(5) auto/hv/approved/hold → MERGE"
# coordinator: STILL holds (only surfacing differs) — never a silent bypass.
[ "$(_hold_decision auto '1' '' coordinator)"  = "HOLD"  ] || fail "(5) auto/hv/unapproved/coordinator → HOLD"
[ "$(_hold_decision auto '1' '1' coordinator)" = "MERGE" ] || fail "(5) auto/hv/approved/coordinator → MERGE"
# auto: informational — a human-verify PR is NOT held, it MERGEs on green even unapproved.
[ "$(_hold_decision auto '1' '' auto)"  = "MERGE" ] || fail "(5) auto/hv/unapproved/auto → MERGE (informational)"
[ "$(_hold_decision auto '1' '1' auto)" = "MERGE" ] || fail "(5) auto/hv/approved/auto → MERGE"
# No human-verify block → MERGE regardless of policy (the lever only touches HV PRs).
[ "$(_hold_decision auto '' '' auto)"  = "MERGE" ]  || fail "(5) auto/no-hv/auto → MERGE"
[ "$(_hold_decision auto '' '' hold)"  = "MERGE" ]  || fail "(5) auto/no-hv/hold → MERGE"
# approve/observe ignore the policy entirely (they already hold / never merge — no double-hold).
[ "$(_hold_decision approve '1' '' auto)"  = "HOLD"    ] || fail "(5) approve ignores hv policy → HOLD"
[ "$(_hold_decision observe '1' '1' auto)" = "OBSERVE" ] || fail "(5) observe ignores hv policy → OBSERVE"
ok
# Backward compatibility: the legacy 3-arg call == 4-arg with hold (byte-identical decision).
[ "$(_hold_decision auto '1' '')"  = "$(_hold_decision auto '1' '' hold)"  ] || fail "(5) 3-arg default must equal hold"
[ "$(_hold_decision auto '1' '1')" = "$(_hold_decision auto '1' '1' hold)" ] || fail "(5) 3-arg default must equal hold (approved)"
ok

# ── 6. hv-informed ledger marker: reuses $APPROVALS, distinct state word, dedups per sha ──────────
rm -f "$APPROVALS"
SHA_A="aaaaaaaaaaaa"; SHA_B="bbbbbbbbbbbb"
! hv_informed_noted 300 "$SHA_A" || fail "(6) no hv-informed record should exist yet"
record_hv_informed 300 "$SHA_A"
hv_informed_noted 300 "$SHA_A" || fail "(6) hv-informed record should now exist"
[ "$APPROVALS" = "$WORKTREES_DIR/.agent-watch-approvals" ] || fail "(6) must reuse .agent-watch-approvals"
grep -q '^[0-9]* hv-informed 300 '"$SHA_A"'$' "$APPROVALS" || fail "(6) hv-informed line not in \$APPROVALS"
# A different sha is NOT yet noted (sha-keyed dedup — a new commit re-notes).
! hv_informed_noted 300 "$SHA_B" || fail "(6) hv-informed must be sha-keyed (SHA_B not noted)"
# No parallel ledger file created.
extra="$(find "$WORKTREES_DIR" -maxdepth 1 -type f \( -name '*informed*' -o -name '*hv-*' \) 2>/dev/null)"
[ -z "$extra" ] || fail "(6) a parallel ledger was created: $extra"
ok

# ── 7. hv-informed lines never surface as pending approvals in herd-approve.sh list ──────────────
# (An informational auto-merge must not masquerade as awaiting sign-off.)
rm -f "$APPROVALS"
printf '%s hv-informed 300 %s\n' "1000" "$SHA_A" > "$APPROVALS"
list_out="$(cd "$WORKTREES_DIR" && WORKTREES_DIR="$WORKTREES_DIR" HERD_CONFIG_FILE="$HERD_CONFIG_FILE" \
  PATH="$PATH" BODIES="$BODIES" bash "$APPROVE" list 2>&1)"
printf '%s' "$list_out" | grep -q 'No PRs awaiting approval' \
  || fail "(7) an hv-informed-only ledger must show no pending approvals. Output:
$list_out"
ok

# ── 8. Console wording — coordinator-actionable label ────────────────────────────────────────────
[ "$(_hold_ready_label '1' 400 coordinator)" = "ready · human-verify (coordinator-actionable) · run steps then herd-approve.sh approve 400" ] \
  || fail "(8) coordinator ready label wrong: $(_hold_ready_label '1' 400 coordinator)"
# hold / default policy keeps the exact legacy wording (byte-identical).
[ "$(_hold_ready_label '1' 400 hold)" = "ready · human-verify pending · herd-approve.sh approve 400" ] \
  || fail "(8) hold ready label must be unchanged: $(_hold_ready_label '1' 400 hold)"
[ "$(_hold_ready_label '1' 400)" = "ready · human-verify pending · herd-approve.sh approve 400" ] \
  || fail "(8) 2-arg ready label must default to hold wording"
ok

# ── 9. Source carries the policy-driven journal + comment surfaces (loop code, not sourced-callable) ─
grep -q 'human_verify_policy coordinator' "$WATCH" || fail "(9) coordinator hold must journal human_verify_policy coordinator"
grep -q 'journal_append human_verify_policy pr .* policy auto action merged-with-declared-steps' "$WATCH" \
  || fail "(9) auto path must journal human_verify_policy=auto merged-with-declared-steps"
grep -q 'coordinator-actionable' "$WATCH" || fail "(9) coordinator hold comment/notify missing"
grep -q 'HUMAN_VERIFY_POLICY=auto' "$WATCH" || fail "(9) auto informational PR comment missing"
grep -q 'human_verify_policy_invalid' "$WATCH" || fail "(9) invalid-value fallback must be journaled"
ok

# ── 10. herd-approve.sh surfaces the coordinator-actionable framing ──────────────────────────────
rm -f "$APPROVALS"
printf 'Adds a live feature.\n\nHUMAN-VERIFY:\n- click through the new tab in the running app\n' > "$BODIES/500"
printf '1000 awaiting 500 %s\n' "$SHA_A" > "$APPROVALS"
coord_out="$(cd "$WORKTREES_DIR" && WORKTREES_DIR="$WORKTREES_DIR" HERD_CONFIG_FILE="$HERD_CONFIG_FILE" \
  HUMAN_VERIFY_POLICY=coordinator PATH="$PATH" BODIES="$BODIES" bash "$APPROVE" list 2>&1)"
printf '%s' "$coord_out" | grep -qi 'coordinator-actionable' \
  || fail "(10) herd-approve.sh list should flag coordinator-actionable under =coordinator. Output:
$coord_out"
printf '%s' "$coord_out" | grep -q 'click through the new tab in the running app' \
  || fail "(10) coordinator list must still surface the steps. Output:
$coord_out"
ok
# Default (hold) policy keeps the legacy wording — byte-identical surface for existing installs.
hold_out="$(cd "$WORKTREES_DIR" && WORKTREES_DIR="$WORKTREES_DIR" HERD_CONFIG_FILE="$HERD_CONFIG_FILE" \
  PATH="$PATH" BODIES="$BODIES" bash "$APPROVE" list 2>&1)"
printf '%s' "$hold_out" | grep -q 'human-verify — run these, then approve:' \
  || fail "(10) hold policy must keep the legacy 'run these, then approve' wording. Output:
$hold_out"
printf '%s' "$hold_out" | grep -qi 'coordinator-actionable' \
  && fail "(10) hold policy must NOT show coordinator-actionable. Output:
$hold_out"
ok

# ── 11. config.example documents the key (for herd config sync / adoption) ───────────────────────
grep -q 'HUMAN_VERIFY_POLICY' "$CFG_EXAMPLE" || fail "(11) config.example must document HUMAN_VERIFY_POLICY"
ok

echo "ALL PASS ($pass checks)"
