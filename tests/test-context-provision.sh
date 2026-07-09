#!/usr/bin/env bash
# test-context-provision.sh — hermetic proof for the builder context-provisioning surface (HERD-40).
#
# CONTEXT_PROVISION is a space-separated list of grounding sources injected into the STABLE region of
# every spawned builder's task-spec preamble (herd-quick.sh / herd-feature.sh), so builders start
# grounded instead of re-exploring the repo each session. The FIRST source is `codemap` — a pointer to
# the committed docs/codemap.md.
#
# Asserts, for BOTH lanes:
#   (a) OFF (unset, the default)      → the written task spec is byte-identical to today: NO grounding
#       sentence appears (docs/codemap.md is never mentioned).
#   (b) ON  (CONTEXT_PROVISION=codemap)→ the codemap pointer lands in the STABLE preamble region of the
#       spec file (BEFORE the per-task body, and BEFORE the per-item Refs trailer when present), while
#       the agent-start argv still carries ONLY the short pointer (the multi-KB spec stays externalized).
#   (c) UNKNOWN token (garbage)        → ignored, no injection, no error (forward-compatible).
#   (d) The helper places grounding in the STABLE region: with a tracked item (HERD_ITEM_REF set) the
#       codemap sentence appears BEFORE the unique 'Refs: <id>' trailer, so the shared cache prefix
#       stays maximal.
#
# Fully hermetic: a throwaway git repo (so new-feature.sh's worktree add works) + stubbed herdr/claude
# (NETWORK-FREE, no real tabs/agent). Mirrors tests/test-externalize-task-specs.sh.
# Run:  bash tests/test-context-provision.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
QUICK="$HERE/../scripts/herd/herd-quick.sh"
FEATURE="$HERE/../scripts/herd/herd-feature.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass(){ PASS=$((PASS+1)); }
command -v python3 >/dev/null 2>&1 || fail "python3 required to run this test"
command -v git    >/dev/null 2>&1 || fail "git required to run this test"

BIG_TASK="SENTINEL_TASK_BODY build the context-provisioning thing"$'\n'"line-two SENTINEL_TASK_L2"
# The exact codemap-pointer marker herd_context_provision_preamble injects (a stable substring of it).
CODEMAP_MARK="committed at docs/codemap.md"
# The symbol-index-pointer marker (a stable substring of the symbol-index case's sentence).
SYMIDX_MARK="committed at docs/symbol-index.md"

# ── Stubs (mirror tests/test-externalize-task-specs.sh) ────────────────────────────────
BIN="$T/bin"; mkdir -p "$BIN"
cat > "$BIN/herdr" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${HERDR_CALL_LOG:-/dev/null}" 2>/dev/null || true
case "$1 $2" in
  "workspace list") printf '{"result":{"workspaces":[{"workspace_id":"wTest","label":"%s"}]}}\n' "${WORKSPACE_NAME:-herdkit}" ;;
  "tab list")       printf '{"result":{"tabs":[]}}\n' ;;
  "tab create")     printf '{"result":{"tab":{"tab_id":"tTest"},"root_pane":{"pane_id":"rTest"}}}\n' ;;
  "agent start")    printf '{"result":{"agent":{"pane_id":"aTest"}}}\n' ;;
  "pane split")     printf '{"result":{"pane":{"pane_id":"pTest"}}}\n' ;;
  *) : ;;
esac
exit 0
STUB
chmod +x "$BIN/herdr"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/claude"; chmod +x "$BIN/claude"
export PATH="$BIN:$PATH"

# ── Throwaway git repo so new-feature.sh's `git worktree add … origin/main` succeeds ───────────
REPO="$T/repo"
git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$REPO" 2>/dev/null
git -C "$REPO" checkout -q -b main
: > "$REPO/seed.txt"
git -C "$REPO" -c user.email=t@t -c user.name=t add seed.txt
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m seed
git -C "$REPO" push -q -u origin main 2>/dev/null

# ── Hermetic env ───────────────────────────────────────────────────────────────
export HOME="$T"                  # herd_pretrust_worktree writes $HOME/.claude.json — keep it sandboxed
export WORKSPACE_NAME="herdkit"
export HERD_SKIP_PREFLIGHT=1
TREES="$T/trees"
CFG="$T/config"
export HERD_CONFIG_FILE="$CFG"

write_cfg() {  # write_cfg <CONTEXT_PROVISION value or __UNSET__>
  {
    printf 'PROJECT_ROOT="%s"\n'   "$REPO"
    printf 'WORKTREES_DIR="%s"\n'  "$TREES"
    printf 'DEFAULT_BRANCH="origin/main"\n'
    printf 'WORKSPACE_NAME="herdkit"\n'
    printf 'APP_PREVIEW_CMD=""\n'
    printf 'MODEL_QUICK="test-quick-model"\n'
    printf 'MODEL_FEATURE="test-feature-model"\n'
    [ "$1" = "__UNSET__" ] || printf 'CONTEXT_PROVISION="%s"\n' "$1"
  } > "$CFG"
}

# run_lane <script> <slug> — run a lane with the current $CFG; leaves the spec file + herdr log.
agent_start_line() { grep -E 'agent start .*-- claude' "$T/$1.herdr.log" 2>/dev/null | head -1; }
run_lane() {
  local script="$1" slug="$2"
  export HERDR_CALL_LOG="$T/$slug.herdr.log"; : > "$HERDR_CALL_LOG"
  HERD_NO_APP=1 bash "$script" "$slug" "$BIG_TASK" > "$T/$slug.out" 2>&1 \
    || fail "$(basename "$script") exited non-zero for '$slug'"$'\n'"$(cat "$T/$slug.out")"
}

# ── (a) OFF (default, unset) → no grounding injected, spec unchanged ────────────────────────────────
write_cfg __UNSET__
for pair in "quick $QUICK" "feat $FEATURE"; do
  set -- $pair; slug="cp-off-$1"; script="$2"
  run_lane "$script" "$slug"
  spec="$TREES/$slug.task.md"
  [ -f "$spec" ] || fail "$slug: spec file not written at $spec"
  grep -q "\[workflow rules\]" "$spec" || fail "$slug: spec missing the workflow-rules preamble"
  grep -q "$CODEMAP_MARK"      "$spec" && fail "$slug: OFF but the codemap pointer leaked into the spec"
done
pass; echo "PASS (a) CONTEXT_PROVISION unset → no grounding injected (task spec unchanged)"

# ── (b) ON (codemap) → pointer in the STABLE preamble, argv still just the short pointer ─────────────
write_cfg "codemap"
for pair in "quick $QUICK" "feat $FEATURE"; do
  set -- $pair; slug="cp-on-$1"; script="$2"
  run_lane "$script" "$slug"
  spec="$TREES/$slug.task.md"
  grep -q "$CODEMAP_MARK" "$spec" || fail "$slug: ON but the codemap pointer is missing from the spec"
  # The grounding lives in the STABLE preamble region: it must appear BEFORE the per-task body.
  mark_ln=$(grep -n "$CODEMAP_MARK"    "$spec" | head -1 | cut -d: -f1)
  body_ln=$(grep -n "SENTINEL_TASK_BODY" "$spec" | head -1 | cut -d: -f1)
  [ -n "$mark_ln" ] && [ -n "$body_ln" ] || fail "$slug: could not locate grounding/body lines"
  [ "$mark_ln" -lt "$body_ln" ] || fail "$slug: grounding ($mark_ln) is NOT before the per-task body ($body_ln) — not in the stable preamble"
  # The externalization contract still holds: argv carries ONLY the short pointer, not the spec/grounding.
  line="$(agent_start_line "$slug")"
  case "$line" in *"Read your task spec at $spec"*) : ;; *) fail "$slug: agent-start argv lacks the spec-file pointer"$'\n'"$line" ;; esac
  case "$line" in *"$CODEMAP_MARK"*) fail "$slug: grounding leaked into the agent-start argv (should stay in the spec file)"$'\n'"$line" ;; esac
done
pass; echo "PASS (b) CONTEXT_PROVISION=codemap → pointer in STABLE preamble, argv still externalized"

# ── (c) UNKNOWN token → ignored, no injection, no error ─────────────────────────────────────────────
write_cfg "totally-unknown-source"
run_lane "$QUICK" "cp-unknown"
spec="$TREES/cp-unknown.task.md"
grep -q "$CODEMAP_MARK" "$spec" && fail "cp-unknown: an unknown source injected a codemap pointer"
grep -q "\[workflow rules\]" "$spec" || fail "cp-unknown: spec missing preamble after an unknown source"
pass; echo "PASS (c) unknown grounding source ignored (forward-compatible, no error)"

# ── (d) Grounding sits BEFORE the per-item Refs trailer (STABLE prefix stays maximal) ───────────────
write_cfg "codemap"
export HERD_ITEM_REF="HERD-999"
run_lane "$QUICK" "cp-refs"
unset HERD_ITEM_REF
spec="$TREES/cp-refs.task.md"
mark_ln=$(grep -n "$CODEMAP_MARK"     "$spec" | head -1 | cut -d: -f1)
refs_ln=$(grep -n "Refs: HERD-999"    "$spec" | head -1 | cut -d: -f1)
[ -n "$mark_ln" ] || fail "cp-refs: codemap pointer missing"
[ -n "$refs_ln" ] || fail "cp-refs: Refs trailer missing (HERD_ITEM_REF not threaded?)"
[ "$mark_ln" -le "$refs_ln" ] || fail "cp-refs: grounding ($mark_ln) came AFTER the unique Refs trailer ($refs_ln) — breaks the maximal cache prefix"
pass; echo "PASS (d) grounding precedes the per-item Refs trailer (cache-prefix discipline)"

# ── (e) ON (symbol-index) → its pointer in the STABLE preamble, no codemap leak, argv externalized ──
write_cfg "symbol-index"
for pair in "quick $QUICK" "feat $FEATURE"; do
  set -- $pair; slug="si-on-$1"; script="$2"
  run_lane "$script" "$slug"
  spec="$TREES/$slug.task.md"
  grep -q "$SYMIDX_MARK"  "$spec" || fail "$slug: ON but the symbol-index pointer is missing from the spec"
  grep -q "$CODEMAP_MARK" "$spec" && fail "$slug: symbol-index only, but the codemap pointer leaked in"
  # The grounding lives in the STABLE preamble region: it must appear BEFORE the per-task body.
  mark_ln=$(grep -n "$SYMIDX_MARK"       "$spec" | head -1 | cut -d: -f1)
  body_ln=$(grep -n "SENTINEL_TASK_BODY" "$spec" | head -1 | cut -d: -f1)
  [ -n "$mark_ln" ] && [ -n "$body_ln" ] || fail "$slug: could not locate grounding/body lines"
  [ "$mark_ln" -lt "$body_ln" ] || fail "$slug: grounding ($mark_ln) is NOT before the per-task body ($body_ln) — not in the stable preamble"
  # The externalization contract still holds: argv carries ONLY the short pointer, not the spec/grounding.
  line="$(agent_start_line "$slug")"
  case "$line" in *"Read your task spec at $spec"*) : ;; *) fail "$slug: agent-start argv lacks the spec-file pointer"$'\n'"$line" ;; esac
  case "$line" in *"$SYMIDX_MARK"*) fail "$slug: grounding leaked into the agent-start argv (should stay in the spec file)"$'\n'"$line" ;; esac
done
pass; echo "PASS (e) CONTEXT_PROVISION=symbol-index → pointer in STABLE preamble, argv still externalized"

# ── (f) BOTH sources → each pointer lands, both precede the per-task body (space-separated list) ─────
write_cfg "codemap symbol-index"
run_lane "$QUICK" "si-both"
spec="$TREES/si-both.task.md"
grep -q "$CODEMAP_MARK" "$spec" || fail "si-both: codemap pointer missing when both sources configured"
grep -q "$SYMIDX_MARK"  "$spec" || fail "si-both: symbol-index pointer missing when both sources configured"
cm_ln=$(grep -n "$CODEMAP_MARK"       "$spec" | head -1 | cut -d: -f1)
si_ln=$(grep -n "$SYMIDX_MARK"        "$spec" | head -1 | cut -d: -f1)
body_ln=$(grep -n "SENTINEL_TASK_BODY" "$spec" | head -1 | cut -d: -f1)
[ "$cm_ln" -lt "$body_ln" ] && [ "$si_ln" -lt "$body_ln" ] || fail "si-both: a grounding pointer landed after the per-task body — not in the stable preamble"
pass; echo "PASS (f) both grounding sources inject together, each in the STABLE preamble"

# ── (g) agents-md → the repo-root AGENTS.md CONTENT is INLINED into the STABLE preamble (not a pointer),
#        so a runtime with no CLAUDE.md auto-load still carries the conventions; argv stays externalized ─
AGENTS_MARK="SENTINEL_AGENTS_CONVENTION_QWOP"
printf '# AGENTS.md\n\n%s — builders never edit BACKLOG.md.\n' "$AGENTS_MARK" > "$REPO/AGENTS.md"
git -C "$REPO" -c user.email=t@t -c user.name=t add AGENTS.md
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m agents
write_cfg "agents-md"
for pair in "quick $QUICK" "feat $FEATURE"; do
  set -- $pair; slug="am-on-$1"; script="$2"
  run_lane "$script" "$slug"
  spec="$TREES/$slug.task.md"
  grep -qF "$AGENTS_MARK" "$spec" || fail "$slug: agents-md ON but the AGENTS.md content was not inlined into the spec"
  # It is CONTENT inlining, not a pointer: the literal convention sentence lands in the STABLE preamble.
  mark_ln=$(grep -nF "$AGENTS_MARK"      "$spec" | head -1 | cut -d: -f1)
  body_ln=$(grep -n "SENTINEL_TASK_BODY" "$spec" | head -1 | cut -d: -f1)
  [ -n "$mark_ln" ] && [ -n "$body_ln" ] || fail "$slug: could not locate conventions/body lines"
  [ "$mark_ln" -lt "$body_ln" ] || fail "$slug: inlined conventions ($mark_ln) not before the per-task body ($body_ln)"
  # Externalization still holds: the agent-start argv carries ONLY the short pointer, not the conventions.
  line="$(agent_start_line "$slug")"
  case "$line" in *"$AGENTS_MARK"*) fail "$slug: AGENTS.md content leaked into the agent-start argv"$'\n'"$line" ;; esac
done
pass; echo "PASS (g) CONTEXT_PROVISION=agents-md inlines repo-root AGENTS.md content into the STABLE preamble"

# ── (h) OFF still byte-identical EVEN THOUGH AGENTS.md now exists at the repo root (ship-dormant): the
#        default (unset) spec must NOT inline conventions — proves the inlining is opt-in, not automatic. ─
write_cfg __UNSET__
run_lane "$QUICK" "am-off"
spec="$TREES/am-off.task.md"
grep -qF "$AGENTS_MARK" "$spec" && fail "am-off: AGENTS.md content inlined with CONTEXT_PROVISION unset (not ship-dormant)"
pass; echo "PASS (h) agents-md is opt-in — an existing repo-root AGENTS.md is NOT inlined when unset"

echo "ALL PASS ($PASS groups)"
