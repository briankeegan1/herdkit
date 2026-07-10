#!/usr/bin/env bash
# test-tracked-spawns.sh — hermetic test of TRACKED_SPAWNS enforcement (HERD-64): tracker-routed
# spawns as a PROJECT POLICY instead of an operator convention. Drives the shared gate
# herd_tracked_spawn_or_abort (scripts/herd/herd-config.sh) directly, and the enqueue-time gate +
# ref-threading sidecar end-to-end through scripts/herd/spawn.sh + spawn-step.sh.
#
# Fully hermetic: local temp only — NO herdr, NO gh, NO claude, NO network, NO worktrees. The lane
# and the durable spawn queue are exercised without spawning a single agent.
#
# Covers:
#   • off (default) → no gate, byte-identical to today (with OR without a ref)
#   • required + ref (HERD_ITEM_REF or HERD_CLAIM_ID) → proceed
#   • required + NO ref + not forced → REFUSE (rc 1) with a loud reason
#   • required + NO ref + HERD_FORCE_SPAWN=1 (or a lane --force arg) → proceed + JOURNAL the bypass
#   • unknown TRACKED_SPAWNS value → treated as off (safe default)
#   • spawn.sh refuses a ref-less intent under required (nothing enters the queue)
#   • spawn.sh threads the ref through the $INTENT_ID.ref sidecar; spawn-step.sh emits it on line 3
#     and removes it on `done`; an untracked intent drains with an empty ref line
#   • the key is a documented config row in capabilities.tsv (scope=project) and in config.example
# Run:  bash tests/test-tracked-spawns.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CONFIG_SH="$ROOT/scripts/herd/herd-config.sh"
SPAWN_SH="$ROOT/scripts/herd/spawn.sh"
STEP_SH="$ROOT/scripts/herd/spawn-step.sh"
CAPS="$ROOT/templates/capabilities.tsv"
CFG_EXAMPLE="$ROOT/templates/config.example"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass(){ PASS=$((PASS+1)); }

for f in "$CONFIG_SH" "$SPAWN_SH" "$STEP_SH" "$CAPS" "$CFG_EXAMPLE"; do
  [ -f "$f" ] || fail "missing required file: $f"
done
command -v python3 >/dev/null 2>&1 || fail "python3 required"

mkdir -p "$T/proj" "$T/trees"

# ============================ the shared gate: herd_tracked_spawn_or_abort ============================
# run_gate <slug> <forced> — source herd-config.sh (defaults; env vars survive its ':=' assigns) +
# journal.sh in a fresh subshell, then call the gate. Merges stderr so the loud reason is captured.
# Callers set TRACKED_SPAWNS / HERD_ITEM_REF / HERD_CLAIM_ID / HERD_FORCE_SPAWN as env prefixes.
run_gate() {
  local slug="$1" forced="${2:-}"
  ( exec 2>&1
    export HERD_CONFIG_FILE="$T/no-such-config" PROJECT_ROOT="$T/proj" WORKTREES_DIR="$T/trees"
    export JOURNAL_FILE="$T/journal.jsonl"
    # shellcheck source=/dev/null
    . "$CONFIG_SH" >/dev/null 2>&1
    # shellcheck source=/dev/null
    . "$ROOT/scripts/herd/journal.sh" >/dev/null 2>&1
    if herd_tracked_spawn_or_abort "$slug" "$forced"; then echo "RC=0"; else echo "RC=$?"; fi )
}

# ── 1. off (default) + no ref → no gate, proceed silently ────────────────────────────────────────────
out="$(run_gate s1 "")"
echo "$out" | grep -q "RC=0" || fail "(1) off default must proceed (rc 0), got '$out'"
echo "$out" | grep -qiE "refus|TRACKED_SPAWNS" && fail "(1) off default must print nothing, got '$out'"
pass; echo "PASS (1) TRACKED_SPAWNS unset (off) → gate is a silent no-op"

# ── 2. off explicitly + no ref → still proceed (byte-identical to today) ──────────────────────────────
out="$(TRACKED_SPAWNS=off run_gate s2 "")"
echo "$out" | grep -q "RC=0" || fail "(2) explicit off must proceed, got '$out'"
pass; echo "PASS (2) TRACKED_SPAWNS=off + no ref → proceed"

# ── 3. required + HERD_ITEM_REF present → proceed ─────────────────────────────────────────────────────
out="$(TRACKED_SPAWNS=required HERD_ITEM_REF=HERD-64 run_gate s3 "")"
echo "$out" | grep -q "RC=0" || fail "(3) required + HERD_ITEM_REF must proceed, got '$out'"
echo "$out" | grep -qi "refus" && fail "(3) required + ref must not print a refusal, got '$out'"
pass; echo "PASS (3) required + HERD_ITEM_REF → proceed"

# ── 4. required + HERD_CLAIM_ID present → proceed (same ref set as herd-claim.sh) ─────────────────────
out="$(TRACKED_SPAWNS=required HERD_CLAIM_ID=repo#item-a run_gate s4 "")"
echo "$out" | grep -q "RC=0" || fail "(4) required + HERD_CLAIM_ID must proceed, got '$out'"
pass; echo "PASS (4) required + HERD_CLAIM_ID → proceed"

# ── 5. required + NO ref + not forced → REFUSE (rc 1) with a loud one-line reason ─────────────────────
out="$(TRACKED_SPAWNS=required run_gate s5 "")"
echo "$out" | grep -q "RC=1" || fail "(5) required + no ref must abort (rc 1), got '$out'"
echo "$out" | grep -q "refusing to spawn 's5'" || fail "(5) missing loud refusal reason, got '$out'"
echo "$out" | grep -q "HERD_FORCE_SPAWN=1" || fail "(5) refusal must name the escape hatch, got '$out'"
[ -f "$T/journal.jsonl" ] && grep -q tracked_spawn_bypassed "$T/journal.jsonl" \
  && fail "(5) a REFUSED spawn must NOT journal a bypass"
pass; echo "PASS (5) required + no ref + no force → refuse (rc 1) + loud reason, no bypass journaled"

# ── 6. required + NO ref + HERD_FORCE_SPAWN=1 → proceed + JOURNAL the bypass ──────────────────────────
rm -f "$T/journal.jsonl"
out="$(TRACKED_SPAWNS=required HERD_FORCE_SPAWN=1 run_gate s6 "")"
echo "$out" | grep -q "RC=0" || fail "(6) forced bypass must proceed (rc 0), got '$out'"
echo "$out" | grep -q "spawning anyway" || fail "(6) forced bypass must print a loud notice, got '$out'"
[ -f "$T/journal.jsonl" ] || fail "(6) forced bypass must write a journal event"
grep -q '"event":"tracked_spawn_bypassed"' "$T/journal.jsonl" || fail "(6) bypass event not journaled ($(cat "$T/journal.jsonl"))"
grep -q '"slug":"s6"' "$T/journal.jsonl" || fail "(6) bypass journal missing slug"
pass; echo "PASS (6) required + no ref + HERD_FORCE_SPAWN=1 → proceed + tracked_spawn_bypassed journaled"

# ── 7. required + NO ref + lane --force arg (arg2) → proceed (the lanes pass their FORCE_SPAWN) ───────
rm -f "$T/journal.jsonl"
out="$(TRACKED_SPAWNS=required run_gate s7 "1")"
echo "$out" | grep -q "RC=0" || fail "(7) lane --force arg must bypass (rc 0), got '$out'"
grep -q tracked_spawn_bypassed "$T/journal.jsonl" 2>/dev/null || fail "(7) lane --force bypass must also journal"
pass; echo "PASS (7) required + no ref + lane --force (arg2) → proceed + journaled"

# ── 8. unknown TRACKED_SPAWNS value → treated as off (safe default) ──────────────────────────────────
out="$(TRACKED_SPAWNS=banana run_gate s8 "")"
echo "$out" | grep -q "RC=0" || fail "(8) unknown value must fall back to off (proceed), got '$out'"
pass; echo "PASS (8) unknown TRACKED_SPAWNS value → treated as off"

# ============================ enqueue gate + ref threading: spawn.sh ==================================
# A temp config binds the queue to $T/trees; env vars (TRACKED_SPAWNS / HERD_ITEM_REF) drive each case.
cat > "$T/config" <<EOF
PROJECT_ROOT="$T/proj"
WORKTREES_DIR="$T/trees"
WORKSPACE_NAME="tks-test"
EOF
Q="$T/trees/spawn-queue"
run_spawn() { ( exec 2>&1; export HERD_CONFIG_FILE="$T/config"; bash "$SPAWN_SH" "$@"; echo "SPAWN_RC=$?" ); }
run_step()  { ( export HERD_CONFIG_FILE="$T/config"; bash "$STEP_SH" "$@" ); }
reset_q()   { rm -rf "$Q"; }

# ── 9. required + NO ref → spawn.sh refuses; nothing enters the queue ─────────────────────────────────
reset_q
out="$(TRACKED_SPAWNS=required run_spawn reject-me quick "do a thing")"
echo "$out" | grep -q "SPAWN_RC=1" || fail "(9) spawn.sh under required + no ref must exit 1, got '$out'"
echo "$out" | grep -q "refusing to spawn 'reject-me'" || fail "(9) spawn.sh must print the loud refusal, got '$out'"
[ -d "$Q" ] && ls "$Q"/*.req >/dev/null 2>&1 && fail "(9) a refused spawn must NOT enqueue an intent"
pass; echo "PASS (9) spawn.sh refuses a ref-less intent under required — queue stays empty"

# ── 10. required + HERD_ITEM_REF → enqueued + .ref sidecar written with the ref ──────────────────────
reset_q
out="$(TRACKED_SPAWNS=required HERD_ITEM_REF=HERD-64 run_spawn build-it quick "build the thing")"
echo "$out" | grep -q "SPAWN_RC=0" || fail "(10) tracked spawn.sh must exit 0, got '$out'"
req="$(ls "$Q"/*.req 2>/dev/null | head -1)"; [ -n "$req" ] || fail "(10) tracked intent was not enqueued"
ref="${req%.req}.ref"
[ -f "$ref" ] || fail "(10) ref sidecar not written next to the intent"
[ "$(cat "$ref")" = "HERD-64" ] || fail "(10) ref sidecar content wrong: '$(cat "$ref")'"
pass; echo "PASS (10) spawn.sh enqueues a tracked intent + writes the HERD-64 ref sidecar"

# ── 11. spawn-step.sh next emits the ref on line 3; done removes intent + sidecar ────────────────────
# Parse via the SAME positional read block the watcher's _drain_spawn_queue uses (portable — no
# mapfile, which macOS bash 3.2 lacks): marker, slug, lane, ref, after (HERD-94; empty when the intent
# carries no dependency), then the task as the remainder. Read every fixed line the producer emits —
# an unread line silently prefixes the remainder and the task assertion fails on a phantom newline.
c0=""; c1=""; c2=""; c3=""; c4=""; c5=""
{ IFS= read -r c0; IFS= read -r c1; IFS= read -r c2; IFS= read -r c3; IFS= read -r c4; c5="$(cat)"; } < <(run_step next)
[ "${c0#CLAIMED }" != "$c0" ] || fail "(11) spawn-step next did not CLAIM (got '$c0')"
[ "$c1" = "build-it" ] || fail "(11) slug line wrong: '$c1'"
[ "$c2" = "quick" ]    || fail "(11) lane line wrong: '$c2'"
[ "$c3" = "HERD-64" ]  || fail "(11) ref line must be the threaded HERD-64, got '$c3'"
[ -z "$c4" ]           || fail "(11) intent with no after= must drain an EMPTY after line, got '$c4'"
[ "$c5" = "build the thing" ] || fail "(11) task remainder wrong: '$c5'"
claimed="${c0#CLAIMED }"
run_step done "$claimed" >/dev/null 2>&1
[ -e "$claimed" ] && fail "(11) done did not remove the claimed intent"
[ -e "${claimed%.req.mine}.ref" ] && fail "(11) done did not remove the ref sidecar"
pass; echo "PASS (11) spawn-step threads the ref on line 3 and done reaps both intent + sidecar"

# ── 12. off + no ref → spawn.sh enqueues normally, NO sidecar, ref line drains EMPTY ─────────────────
reset_q
out="$(TRACKED_SPAWNS=off run_spawn plain-item quick "plain task")"
echo "$out" | grep -q "SPAWN_RC=0" || fail "(12) off + no ref must enqueue (rc 0), got '$out'"
req="$(ls "$Q"/*.req 2>/dev/null | head -1)"; [ -n "$req" ] || fail "(12) intent not enqueued under off"
[ -f "${req%.req}.ref" ] && fail "(12) an untracked spawn must NOT write a ref sidecar"
c0=""; c1=""; c2=""; c3=""; c4=""; c5=""
{ IFS= read -r c0; IFS= read -r c1; IFS= read -r c2; IFS= read -r c3; IFS= read -r c4; c5="$(cat)"; } < <(run_step next)
[ "$c1" = "plain-item" ] || fail "(12) slug wrong: '$c1'"
[ "$c2" = "quick" ]      || fail "(12) lane wrong: '$c2'"
[ -z "$c3" ]             || fail "(12) untracked intent must drain an EMPTY ref line, got '$c3'"
[ -z "$c4" ]             || fail "(12) untracked intent must drain an EMPTY after line, got '$c4'"
[ "$c5" = "plain task" ] || fail "(12) task wrong: '$c5'"
pass; echo "PASS (12) off + no ref → normal enqueue, empty ref line (positional parse preserved)"

# ============================ documentation: capabilities.tsv + config.example =======================
# ── 13. TRACKED_SPAWNS is a documented config row (scope=project) and appears in config.example ──────
awk -F'\t' '$1=="TRACKED_SPAWNS" && $2=="config"{f=1} END{exit f?0:1}' "$CAPS" \
  || fail "(13) TRACKED_SPAWNS missing a 'config' row in capabilities.tsv"
awk -F'\t' '$1=="TRACKED_SPAWNS"{exit ($6=="project")?0:1}' "$CAPS" \
  || fail "(13) TRACKED_SPAWNS row must carry scope=project"
grep -q "TRACKED_SPAWNS" "$CFG_EXAMPLE" || fail "(13) TRACKED_SPAWNS not documented in config.example"
pass; echo "PASS (13) TRACKED_SPAWNS documented (capabilities.tsv config row scope=project + config.example)"

# ── 14. default matches the herd-config.sh inline fallback (drift guard) ──────────────────────────────
grep -Eq ': "\$\{TRACKED_SPAWNS:="off"\}"' "$CONFIG_SH" \
  || fail "(14) herd-config.sh inline default for TRACKED_SPAWNS changed from off"
pass; echo "PASS (14) herd-config.sh default TRACKED_SPAWNS=off (drift guard)"

echo
echo "ALL PASS ($PASS checks) — TRACKED_SPAWNS gate, ref threading, and docs verified."
