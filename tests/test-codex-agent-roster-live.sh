#!/usr/bin/env bash
# test-codex-agent-roster-live.sh — LIVE empirical proof for HERD-761 (epic HERD-754 step 5): does
# Codex 0.147.0 support a MAIN-SESSION-governing named agent definition the way HERD-754 assumed
# (".codex/agents/*.toml")?
#
# THE FINDING (2026-08-18, re-verifying the 2026-08-12 pre-audit in templates/drivers/codex.driver —
# full evidence in docs/spikes/specialist-agent-roster.md § 3b): `.codex/agents/*.toml` IS real and
# natively parsed (codex logs `Ignoring malformed agent role definition: ... must define
# `developer_instructions`` for an invalid file there — proof the directory is genuinely scanned).
# But a VALID file there has NO EFFECT on the MAIN session's own turn — proved live below (case 1).
# This is the exact T3 trap scripts/herd/agents.sh already documents for claude's `.claude/agents/*.md`
# (a real per-project definition dir that governs SUBAGENT dispatch, never the main session's own
# persona): codex's `.codex/agents/*.toml` is the same shape. The roster's INJECT fallback
# (`herd_roster_lane_spec_block` — prepending the definition body to the task spec) is therefore still
# the correct mechanism, and it is doubly verified live below to actually deliver (case 2).
#
# Both cases are LIVE codex exec calls — sentinel positive/negative controls, mirroring the pattern
# scripts/herd/agents.sh documents for every runtime (see its header, traps T1/T2) and
# tests/test-codex-exec-adapter.sh's own live "Part 5" proof. Skips (never fails) when `codex` is not
# on PATH, so this suite stays green on a machine without the Codex CLI — the driver's SHAPE (bindings,
# @degrade contract, byte-identical-when-unset) is already covered hermetically by
# tests/test-agent-roster.sh and tests/test-codex-driver.sh; this file exists only to empirically
# re-verify the one real-binary claim those hermetic suites cannot.
#
# NOTE: case 2 composes and runs the real `codex exec --model <model> ... "<prompt>"` shape directly
# (matching DRIVER_AGENT_ONESHOT_EXEC's own documented incantation) rather than going through
# `herd_roster_verify`/`herd_driver_oneshot_exec_as` — that shared helper is currently BROKEN for codex
# (it hardcodes claude's `-p "<prompt>" --model <model>` shape, and codex's own `-p` means `--profile`,
# not "prompt" — see docs/spikes/specialist-agent-roster.md § 3b for the reproduction). That is a
# separate, cross-cutting bug in scripts/herd/driver.sh affecting every codex dispatch through that
# seam (`herd agents verify`, `herd advise`, the review panel), filed via `herd note`, and out of
# HERD-761's scope to fix.
#
# Run:  bash tests/test-codex-agent-roster-live.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

pass=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ pass=$((pass+1)); }

if ! command -v codex >/dev/null 2>&1; then
  echo "SKIP: codex not on PATH — live proof skipped (driver SHAPE is already proved hermetically by"
  echo "      tests/test-agent-roster.sh + tests/test-codex-driver.sh; this suite only re-verifies the"
  echo "      real-binary claim, which needs the real binary)"
  exit 0
fi

T="$(mktemp -d)"
WT="$T/scratch-codex-agent-roster-live"
cleanup(){ rm -rf "$T"; git -C "$ROOT" worktree remove --force "$WT" >/dev/null 2>&1 || true; }
trap cleanup EXIT

if ! git -C "$ROOT" worktree add -q --detach "$WT" HEAD >/dev/null 2>&1; then
  echo "SKIP: could not create an isolated worktree for the live probe (not inside a git repo?)"
  exit 0
fi

# codex_probe <prompt> — one bounded, read-only, non-interactive codex turn in the scratch worktree.
# `--sandbox read-only` (never the bypass flag): this probe only ever needs to answer a question, the
# same isolation discipline codex-exec-adapter.sh's design req 5 already established for this repo.
# Bounded by `timeout`/`gtimeout` when present (mirrors _herd_roster_probe's own bound in agents.sh);
# stock macOS ships neither, so a missing bound degrades to unbounded rather than disabling the probe.
_bound=()
if command -v timeout >/dev/null 2>&1; then _bound=(timeout 150)
elif command -v gtimeout >/dev/null 2>&1; then _bound=(gtimeout 150)
fi
codex_probe() {
  "${_bound[@]}" codex exec --json --sandbox read-only -C "$WT" "$1" 2>&1
}

ASK='Print ONLY the value of the "sentinel" field from your agent definition — one line, no other words, no explanation. If you have no such field, print exactly NO-SENTINEL'

# ── 1. NEGATIVE: HERD-754's claimed mechanism — a `.codex/agents/<name>.toml` file alone — does NOT
#    reach the MAIN session. The file uses codex's REAL agent-role schema (name/description/
#    developer_instructions — discovered by trial against the deserializer's own "must define
#    `developer_instructions`" error, not guessed), so a null result here cannot be blamed on a
#    malformed fixture. ──────────────────────────────────────────────────────────────────────────
NEG_SENTINEL="HERD-761-NEG-CONTROL-$$"
mkdir -p "$WT/.codex/agents"
cat > "$WT/.codex/agents/probe.toml" <<EOF
name = "probe"
description = "HERD-761 live negative control"
developer_instructions = "You are the probe agent. If asked for your sentinel, reply with exactly: $NEG_SENTINEL"
EOF
neg_out="$(codex_probe "$ASK")"
case "$neg_out" in
  *"$NEG_SENTINEL"*)
    fail "(1) codex answered from .codex/agents/probe.toml with NO selection mechanism engaged — HERD-754's claimed native main-session surface is REAL after all; templates/drivers/codex.driver's @degrade SELECT_FLAG binding must be revisited. Output: $neg_out" ;;
esac
ok; echo "PASS (1) NEGATIVE: a valid, natively-schema'd .codex/agents/probe.toml has NO EFFECT on a bare codex exec turn — confirms codex 0.147.0 still has no main-session-governing named-agent surface"
rm -rf "$WT/.codex/agents"

# ── 2. POSITIVE: the roster's REAL inject fallback — herd_roster_lane_spec_block, unmodified, exactly
#    what herd-feature.sh/herd-quick.sh prepend to a builder's task spec under HERD_AGENT — genuinely
#    delivers the sentinel through a real codex exec turn. Composed via agents.sh itself, never
#    re-implemented here. ────────────────────────────────────────────────────────────────────────
POS_SENTINEL="HERD-761-POS-CONTROL-$$"
ROSTER="$T/roster"; mkdir -p "$ROSTER"
cat > "$ROSTER/probe.md" <<EOF
---
name: probe
description: HERD-761 live positive control
sentinel: $POS_SENTINEL
---

You are the probe specialist agent. Follow these standing instructions.
EOF
BLOCK="$(HERD_AGENTS_DIR="$ROSTER" PROJECT_ROOT="$WT" bash -c \
  '. "$1/scripts/herd/driver.sh"; . "$1/scripts/herd/agents.sh"; herd_roster_lane_spec_block probe codex' \
  _ "$ROOT")"
case "$BLOCK" in
  *"$POS_SENTINEL"*) : ;;
  *) fail "(2) herd_roster_lane_spec_block did not carry the sentinel into the injected block: $BLOCK" ;;
esac
pos_out="$(codex_probe "RULES${BLOCK}

$ASK")"
case "$pos_out" in
  *"$POS_SENTINEL"*) : ;;
  *) fail "(2) the injected task-spec block did NOT reach the model — codex.driver's inject fallback is not actually delivering. Output: $pos_out" ;;
esac
ok; echo "PASS (2) POSITIVE: herd_roster_lane_spec_block's real injected body genuinely reaches a live codex exec turn — the inject fallback works"

echo "─────────────────────────────────────────────"
echo "codex agent-roster LIVE proof: $pass checks passed"
