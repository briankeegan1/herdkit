#!/usr/bin/env bash
# test-governance-hooks-render.sh — hermetic tests for `herd governance hooks render` (HERD-131):
# emitting SESSION-TIME Claude Code hooks from the governance map's surface==hook rows.
#
# Dual-surface enforcement under test: a governance rule the merge-time watcher gate enforces ALSO
# binds session-time as a PreToolUse hook (block a commit carrying an AI attribution trailer; warn on
# a direct push). PROPOSE-then-write: each hook is shown, the operator accepts per-hook, and accepted
# entries MERGE into .claude/settings.local.json (or --shared → .claude/settings.json) preserving all
# existing entries. Every generated matcher-group carries a "herd-governance" marker key so re-render
# updates ONLY its own entries and is idempotent.
#
# NO network, NO gh, NO herdr, NO claude, NO model. The command reads a FIXTURE map via
# HERD_GOVERNANCE_MAP and drives the per-hook accept prompts hermetically through the
# HERD_GROUND_ASSUME_TTY seam (scripted stdin without a real TTY). Asserts:
#   (1) accept a subset → EXACT merged JSON: user hooks + unrelated keys preserved; one marker group
#       per accepted target under PreToolUse[Bash]; declined target absent; generated command runs the
#       repo's real scripts/herd/governance-hook.sh <target>.
#   (2) re-render with the SAME acceptances → BYTE-IDENTICAL (idempotent).
#   (3) each generated hook COMMAND, pipe-tested against a synthesized Claude Code payload, enforces
#       its rule: the no-ai-coauthor commit blocks (exit 2) on an AI trailer and allows (exit 0) a
#       clean message; the push warn and run-checks hooks allow (exit 0).
#   (4) fail-soft: no map / no hook rows / non-interactive / fresh decline-all → clean no-op, NO file.
#   (5) --shared targets .claude/settings.json (not the local overlay).
#   (6) declining a PREVIOUSLY-accepted hook removes only its marker group, preserving user entries.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
HERD="$REPO/bin/herd"

command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 required" >&2; exit 1; }
REAL_BASH="$(command -v bash)"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

# A fixture map: one (ignored) config-key row plus three hook rows, in a fixed order.
MAP="$T/governance-map.tsv"
{
  printf 'pattern\tsurface\ttarget\tlabel\n'
  printf 'ignored\tconfig-key\tPUSH_GATE=human\tconfig-key rows are not hooks\n'
  printf 'p1\thook\tpre-commit:no-ai-coauthor\tBlock a commit carrying an AI attribution trailer\n'
  printf 'p2\thook\tpre-push:human-gate\tWarn before a direct push (human review first)\n'
  printf 'p3\thook\tpre-action:run-checks\tRun checks before committing or pushing\n'
} > "$MAP"

# run_render <project> <shared|local> <stdin> — invoke the command in <project> with the fixture map.
run_render() {
  local proj="$1" mode="$2" input="$3" flag=""
  [ "$mode" = "shared" ] && flag="--shared"
  ( cd "$proj" && printf '%s' "$input" \
      | HERD_GOVERNANCE_MAP="$MAP" HERD_GROUND_ASSUME_TTY=1 \
        "$REAL_BASH" "$HERD" governance hooks render $flag 2>&1 )
}

# ── (1) accept a subset → exact merged JSON, user entries preserved ────────────────────────────────
proj="$T/accept"; mkdir -p "$proj/.claude"
cat > "$proj/.claude/settings.local.json" <<'JSON'
{
  "permissions": { "allow": ["Bash(ls:*)"] },
  "hooks": {
    "PreToolUse": [
      { "matcher": "Write", "hooks": [ { "type": "command", "command": "echo user-hook" } ] }
    ]
  }
}
JSON
# accept pre-commit, DECLINE pre-push, accept run-checks.
out="$(run_render "$proj" local $'a\nn\na\n')" || fail "(1) render failed: $out"
echo "$out" | grep -q "merged 2 hook(s)" || fail "(1) summary should report 2 merged hooks: $out"
SET="$proj/.claude/settings.local.json" REPO="$REPO" python3 - <<'PY' || fail "(1) merged JSON assertions failed"
import json, os, sys
d = json.load(open(os.environ["SET"]))
scripts = os.path.join(os.environ["REPO"], "scripts", "herd", "governance-hook.sh")
# unrelated keys preserved verbatim
assert d.get("permissions") == {"allow": ["Bash(ls:*)"]}, "permissions clobbered: %r" % d.get("permissions")
groups = d["hooks"]["PreToolUse"]
# user's Write hook preserved
assert any(g.get("matcher") == "Write" and g["hooks"][0]["command"] == "echo user-hook"
           for g in groups), "user Write hook not preserved"
marked = {g["herd-governance"]: g for g in groups if "herd-governance" in g}
# exactly the two ACCEPTED targets present; the declined one absent
assert set(marked) == {"pre-commit:no-ai-coauthor", "pre-action:run-checks"}, "wrong marker set: %r" % set(marked)
assert "pre-push:human-gate" not in marked, "declined hook was written"
for target, g in marked.items():
    assert g["matcher"] == "Bash", "marker group must match Bash: %r" % g
    cmd = g["hooks"][0]["command"]
    assert g["hooks"][0]["type"] == "command"
    assert scripts in cmd and cmd.endswith(target), "command wrong for %s: %r" % (target, cmd)
print("ok")
PY
ok

# ── (2) re-render with the same acceptances → byte-identical (idempotent) ──────────────────────────
cp "$proj/.claude/settings.local.json" "$T/snap-before.json"
out="$(run_render "$proj" local $'a\nn\na\n')" || fail "(2) re-render failed: $out"
diff -q "$T/snap-before.json" "$proj/.claude/settings.local.json" >/dev/null \
  || { echo "--- diff ---"; diff "$T/snap-before.json" "$proj/.claude/settings.local.json"; fail "(2) re-render not idempotent"; }
ok

# ── (3) pipe-test each generated hook command against a synthesized payload ────────────────────────
# Extract the two generated commands from the merged settings.
COMMIT_CMD="$(SET="$proj/.claude/settings.local.json" python3 -c '
import json,os,sys
d=json.load(open(os.environ["SET"]))
for g in d["hooks"]["PreToolUse"]:
    if g.get("herd-governance")=="pre-commit:no-ai-coauthor": print(g["hooks"][0]["command"])')"
CHECKS_CMD="$(SET="$proj/.claude/settings.local.json" python3 -c '
import json,os,sys
d=json.load(open(os.environ["SET"]))
for g in d["hooks"]["PreToolUse"]:
    if g.get("herd-governance")=="pre-action:run-checks": print(g["hooks"][0]["command"])')"
[ -n "$COMMIT_CMD" ] && [ -n "$CHECKS_CMD" ] || fail "(3) could not extract generated commands"

# no-ai-coauthor: a commit whose message carries an AI attribution trailer → BLOCK (exit 2).
payload_ai='{"tool_name":"Bash","tool_input":{"command":"git commit -m msg\n\nCo-Authored-By: Claude <noreply@anthropic.com>"}}'
printf '%s' "$payload_ai" | eval "$COMMIT_CMD" >/dev/null 2>&1 && fail "(3) AI-trailer commit must be blocked (exit 2)"
rc=$?; [ "$rc" -eq 2 ] || fail "(3) AI-trailer commit expected exit 2, got $rc"
# a clean commit → allow (exit 0).
payload_clean='{"tool_name":"Bash","tool_input":{"command":"git commit -m clean-message"}}'
printf '%s' "$payload_clean" | eval "$COMMIT_CMD" >/dev/null 2>&1 || fail "(3) clean commit must be allowed (exit 0)"
# a non-commit command → allow even with a stray trailer-looking token (only git commit is gated).
printf '%s' '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}' | eval "$COMMIT_CMD" >/dev/null 2>&1 \
  || fail "(3) non-commit command must be allowed"
# run-checks: a commit → advisory WARN but ALLOW (exit 0), and the guidance reaches stderr.
warn_out="$(printf '%s' "$payload_clean" | eval "$CHECKS_CMD" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || fail "(3) run-checks must allow (exit 0), got $rc"
printf '%s' "$warn_out" | grep -qi "before committing or pushing" || fail "(3) run-checks should warn on stderr"
ok

# ── (4) fail-soft: no map / no hook rows / non-interactive / fresh decline-all → no file ───────────
p="$T/nomap"; mkdir -p "$p"
run_render "$p" local '' >/dev/null 2>&1 || true
[ -e "$p/.claude" ] && fail "(4a) no-map render must not create .claude"
# override with a real-but-hooks-free map
NOHOOK="$T/nohooks.tsv"; printf 'pattern\tsurface\ttarget\tlabel\nx\tconfig-key\tPUSH_GATE=human\tc\n' > "$NOHOOK"
p="$T/nohooks"; mkdir -p "$p"
( cd "$p" && printf '' | HERD_GOVERNANCE_MAP="$NOHOOK" HERD_GROUND_ASSUME_TTY=1 "$REAL_BASH" "$HERD" governance hooks render >/dev/null 2>&1 ) || true
[ -e "$p/.claude" ] && fail "(4b) no-hook-rows render must not create .claude"
# non-interactive (no TTY seam): even with 'accept' answers piped, nothing is written.
p="$T/noninteractive"; mkdir -p "$p"
( cd "$p" && printf 'a\na\na\n' | HERD_GOVERNANCE_MAP="$MAP" "$REAL_BASH" "$HERD" governance hooks render >/dev/null 2>&1 ) || true
[ -e "$p/.claude" ] && fail "(4c) non-interactive render must not write"
# fresh decline-all: no prior file → nothing created.
p="$T/declineall"; mkdir -p "$p"
run_render "$p" local $'n\nn\nn\n' >/dev/null 2>&1 || true
[ -e "$p/.claude" ] && fail "(4d) fresh decline-all must not create a file"
ok

# ── (5) --shared targets .claude/settings.json (committed baseline), not the local overlay ─────────
p="$T/shared"; mkdir -p "$p"
run_render "$p" shared $'a\nn\nn\n' >/dev/null 2>&1 || fail "(5) --shared render failed"
[ -f "$p/.claude/settings.json" ] || fail "(5) --shared must write .claude/settings.json"
[ -e "$p/.claude/settings.local.json" ] && fail "(5) --shared must NOT write the local overlay"
grep -q '"herd-governance"' "$p/.claude/settings.json" || fail "(5) --shared file missing marker"
ok

# ── (6) declining a previously-accepted hook removes ONLY its marker group; user entries preserved ─
# proj (from 1/2) currently has pre-commit + run-checks marker groups plus the user Write hook.
run_render "$proj" local $'n\nn\nn\n' >/dev/null 2>&1 || fail "(6) revoke render failed"
SET="$proj/.claude/settings.local.json" python3 - <<'PY' || fail "(6) revoke assertions failed"
import json, os
d = json.load(open(os.environ["SET"]))
groups = d["hooks"]["PreToolUse"]
assert not any("herd-governance" in g for g in groups), "marker groups not removed on decline-all"
assert any(g.get("matcher") == "Write" for g in groups), "user hook lost on revoke"
assert d.get("permissions") == {"allow": ["Bash(ls:*)"]}, "permissions lost on revoke"
print("ok")
PY
ok

echo "ALL PASS ($pass checks)"
