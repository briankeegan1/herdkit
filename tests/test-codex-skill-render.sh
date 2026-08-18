#!/usr/bin/env bash
# test-codex-skill-render.sh — hermetic proof for HERD-754 steps 1-2 (Codex/Grok portability epic):
# (step 1) the coordinator skill also renders to Codex's project-scoped repository-skill discovery
# path (.agents/skills/herd-coordinator/SKILL.md), from the SAME template + token machinery as the
# Claude render; (step 2, HERD-758) that shared template names no VENDOR TOOL in its prescriptive
# prose — it carries abstract {{CAP_*}} capability tokens each render target resolves for itself.
# Throughout, the Claude render itself stays byte-identical to before these changes.
#
# What this asserts:
#   (A) EVERY render path emits it: `herd init` renders .agents/skills/herd-coordinator/SKILL.md
#       alongside .claude/commands/coordinator.md, with no unsubstituted {{TOKEN}} and the token
#       VALUES actually substituted; `herd render` regenerates it deterministically when absent.
#   (B) Frontmatter shape: opens with `---`, `name: herd-coordinator` then `description:`, closes
#       with a second `---` — the convention Codex's repository-skill discovery expects.
#   (C) SAME CANONICAL SOURCE: the rendered body (everything past the frontmatter) is BYTE-IDENTICAL
#       to the Claude render's body once the per-target CAPABILITY TOKENS (F, below) are normalized —
#       one template, two rendered surfaces, so a fix to templates/coordinator.md.tmpl can never
#       drift between them (multi-seat doctrine rule 2) and the ONLY permitted divergence is a
#       capability token resolving per runtime.
#   (D) PER-MACHINE DERIVED artifact: gitignored via .git/info/exclude (never the committed
#       .gitignore), untracked after a commit, and carried in the shared derived-files list under a
#       FIXED path (independent of COORDINATOR_CMD, like the /autopilot render).
#   (E) HARD CONSTRAINT: rendering with the bin/herd from BEFORE this change (resolved via
#       `git merge-base HEAD origin/main`) into a fixture, then re-rendering the SAME fixture with
#       this tree's CURRENT bin/herd, produces a BYTE-IDENTICAL .claude/commands/coordinator.md —
#       nothing about today's Claude behavior changed. Skips (never fails) if no such baseline is
#       resolvable in this checkout.
#   (F) HERD-758 (step 2) CAPABILITY TOKENS: templates/coordinator.md.tmpl names no VENDOR TOOL in
#       its prescriptive prose — it carries {{CAP_*}} tokens that each render target resolves. The
#       Claude render resolves {{CAP_ASK_USER}} back to the literal `AskUserQuestion`; the Codex
#       render carries NO Claude tool name at all, only vendor-neutral prose (degrade, never guess an
#       unverified Codex-native tool).
#
# Fully hermetic: temp git repos, no network, no gh, no herdr, no model.
# Run:  bash tests/test-codex-skill-render.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
HERD="$ROOT/bin/herd"
LIB="$ROOT/scripts/herd/derived-files.sh"

for f in "$HERD" "$LIB"; do [ -f "$f" ] || { echo "FAIL: missing $f" >&2; exit 1; }; done
command -v git >/dev/null 2>&1 || { echo "FAIL: git required" >&2; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { PASS=$((PASS + 1)); echo "PASS: $1"; }

COORD_REL=".claude/commands/coordinator.md"
CODEX_REL=".agents/skills/herd-coordinator/SKILL.md"

# _mkrepo <dir> — a committed, hermetic git repo.
_mkrepo() {
  mkdir -p "$1"
  git -C "$1" init -q -b main
  git -C "$1" config user.email t@t.local; git -C "$1" config user.name t
  git -C "$1" commit -q --allow-empty -m base
}

# _herd <dir> <args...> — run the CLI in <dir>, non-interactive, no doctor.
_herd() { local d="$1"; shift; ( cd "$d" && HERD_NONINTERACTIVE=1 HERD_SKIP_DOCTOR=1 bash "$HERD" "$@" ); }

# ── A. every render path emits the Codex skill alongside the Claude render ─────────────────────────
P="$T/proj"; _mkrepo "$P"
_herd "$P" init >/dev/null 2>&1 || fail "A: herd init failed"
[ -f "$P/$COORD_REL" ] || fail "A1: init did not render the Claude coordinator skill"
[ -f "$P/$CODEX_REL" ] || fail "A1: init did not render the Codex coordinator skill"
ok "A1 init renders the Codex skill alongside the Claude coordinator skill"

grep -qE '\{\{[A-Za-z_][A-Za-z0-9_]*\}\}' "$P/$CODEX_REL" \
  && fail "A2: the Codex render left an unsubstituted {{token}}: $(grep -oE '\{\{[A-Za-z_][A-Za-z0-9_]*\}\}' "$P/$CODEX_REL" | sort -u | tr '\n' ' ')"
ok "A2 no literal {{TOKEN}} survives the Codex render"

grep -q "proj" "$P/$CODEX_REL" || fail "A3: WORKSPACE_NAME was not substituted into the Codex render"
grep -qF "$P" "$P/$CODEX_REL"  || fail "A3: PROJECT_ROOT was not substituted into the Codex render"
ok "A3 the token VALUES are substituted into the Codex render"

# `herd render` regenerates an absent skill, byte-identically (a render is deterministic).
cp "$P/$CODEX_REL" "$T/first.md"
rm -f "$P/$CODEX_REL"
_herd "$P" render >/dev/null 2>&1 || fail "A4: herd render failed with the Codex skill absent"
[ -f "$P/$CODEX_REL" ] || fail "A4: herd render did not regenerate the absent Codex skill"
cmp -s "$T/first.md" "$P/$CODEX_REL" || fail "A4: re-render is not byte-identical to the first render"
ok "A4 herd render regenerates the absent Codex skill byte-identically"

# ── B. frontmatter shape: opens ---, name + description, closes --- ────────────────────────────────
# (No `mapfile` — bash 3.2, the macOS system /bin/bash, ships without it.)
_fm_l1="$(sed -n '1p' "$P/$CODEX_REL")"
_fm_l2="$(sed -n '2p' "$P/$CODEX_REL")"
_fm_l3="$(sed -n '3p' "$P/$CODEX_REL")"
[ "$_fm_l1" = "---" ] || fail "B1: frontmatter does not open with ---"
[ "$_fm_l2" = "name: herd-coordinator" ] \
  || fail "B1: frontmatter's second line must be 'name: herd-coordinator', got '$_fm_l2'"
case "$_fm_l3" in
  description:*) : ;;
  *) fail "B1: frontmatter's third line must start with 'description:', got '$_fm_l3'" ;;
esac
_fm_tail="$(sed -n '4,6p' "$P/$CODEX_REL")"
grep -qx -- '---' <<< "$_fm_tail" || fail "B1: frontmatter does not close with a second ---"
ok "B1 the Codex render carries a name + description frontmatter block, opened and closed with ---"

# ── C. same canonical source: the body (past the frontmatter) matches the Claude render's body ─────
# HERD-758: the ONE permitted divergence is a per-target CAPABILITY TOKEN (section F). Normalize the
# Codex render's neutral phrasing back to the Claude literal and the two bodies must still match
# byte-for-byte — anything else means the surfaces have drifted off their one canonical source.
CAP_ASK_USER_CLAUDE="AskUserQuestion"
CAP_ASK_USER_CODEX="a multiple-choice question to the user"
_codex_body="$(awk '/^---$/{n++; next} n>=2' "$P/$CODEX_REL")"
_claude_body="$(awk '/^---$/{n++; next} n>=2' "$P/$COORD_REL")"
[ -n "$_codex_body" ] || fail "C1: the Codex render's body is empty"
_codex_body_norm="$(printf '%s\n' "$_codex_body" | sed "s/$CAP_ASK_USER_CODEX/$CAP_ASK_USER_CLAUDE/g")"
[ "$_codex_body_norm" = "$_claude_body" ] \
  || fail "C1: the Codex render's body diverges from the Claude render's body beyond capability-token resolution — they must share ONE canonical source"
ok "C1 the Codex render's body matches the Claude render's body once capability tokens are normalized (one canonical source)"

# ── D. per-machine derived artifact: gitignored, untracked, on the shared derived list ─────────────
git -C "$P" check-ignore -q "$CODEX_REL" || fail "D1: the Codex render is not ignored"
[ "$(grep -cxF "$CODEX_REL" "$P/.git/info/exclude")" -eq 1 ] \
  || fail "D1: the exclude line is missing or was appended more than once"
{ [ -f "$P/.gitignore" ] && grep -qxF "$CODEX_REL" "$P/.gitignore"; } \
  && fail "D1: the ignore entry was written to the COMMITTED .gitignore"
ok "D1 the Codex render is ignored via .git/info/exclude, idempotently, leaving the committed .gitignore alone"

git -C "$P" add -A && git -C "$P" commit -q -m init
git -C "$P" ls-files --error-unmatch -- "$CODEX_REL" >/dev/null 2>&1 \
  && fail "D2: the Codex render was committed — it must be gitignored, never tracked"
[ -z "$(git -C "$P" status --porcelain)" ] || fail "D2: tree dirty after commit: $(git -C "$P" status --porcelain)"
_herd "$P" render >/dev/null 2>&1 || fail "D2: second herd render failed"
[ -z "$(git -C "$P" status --porcelain)" ] || fail "D2: a re-render dirtied the tree: $(git -C "$P" status --porcelain)"
ok "D2 the Codex render stays untracked and never dirties the checkout"

# shellcheck source=/dev/null
. "$LIB"
herd_is_derived_path "$CODEX_REL" || fail "D3: the Codex render must be a derived path"
_stripped="$(printf '%s\n' "$CODEX_REL" "src/app.py" | herd_strip_derived)"
[ "$_stripped" = "src/app.py" ] || fail "D3: strip kept the wrong paths: '$_stripped'"
ok "D3 the shared derived-files list carries the Codex render"

( COORDINATOR_CMD="/ops" herd_is_derived_path "$CODEX_REL" ) \
  || fail "D4: a renamed coordinator command must not move the Codex render off the derived list"
ok "D4 the Codex render path is fixed, independent of COORDINATOR_CMD"

# ── E. hard constraint: the Claude render stays byte-identical to before this change ────────────────
BASE_REF="$(git -C "$ROOT" merge-base HEAD origin/main 2>/dev/null || true)"
if [ -z "$BASE_REF" ] || ! git -C "$ROOT" cat-file -e "$BASE_REF:bin/herd" 2>/dev/null; then
  ok "E1 SKIPPED — no resolvable pre-change baseline in this checkout (origin/main unreachable)"
else
  # HERD-758: materialize the WHOLE baseline tree (engine + templates + manifest), not just bin/herd
  # with the current templates symlinked in. The Claude render is a function of all three, and this
  # change edits templates/coordinator.md.tmpl as well as bin/herd — a baseline engine rendering the
  # CURRENT template would die on the {{CAP_ASK_USER}} token it cannot bind, and would prove nothing
  # about the before/after byte-identity anyway. Extracting the baseline commit makes this a true
  # "everything before this change" vs "everything after" comparison.
  OLD="$T/old-engine"; mkdir -p "$OLD"
  git -C "$ROOT" archive "$BASE_REF" | tar -x -C "$OLD" \
    || fail "E: could not materialize the baseline tree at $BASE_REF"  # pipe-ok: git archive|tar is the extraction itself; failure surfaces as the missing bin/herd checked next
  [ -f "$OLD/bin/herd" ] || fail "E: the baseline tree carries no bin/herd"
  chmod +x "$OLD/bin/herd"
  # HERD-760: the coordinator skill legitimately renders a live capabilities-index summary (PR #157) —
  # so a PR that adds a NEW capabilities.tsv row (documenting a new engine script, exactly as this
  # test suite's own declare-or-exempt discipline requires) correctly changes the Claude render too.
  # That's a real, wanted behavior change, not a capability-token regression — the two must not be
  # conflated. Sync the CURRENT tree's manifest files onto the baseline copy before rendering it, so
  # the ONLY variable left between before/after is code (capability-token handling), never manifest
  # CONTENT — a true isolation of what this specific change actually claims to leave byte-identical.
  cp "$ROOT/templates/capabilities.tsv" "$OLD/templates/capabilities.tsv"
  cp "$ROOT/templates/conformance.tsv" "$OLD/templates/conformance.tsv"

  E="$T/before-after"; _mkrepo "$E"
  ( cd "$E" && HERD_NONINTERACTIVE=1 HERD_SKIP_DOCTOR=1 bash "$OLD/bin/herd" init ) >/dev/null 2>&1 \
    || fail "E: the baseline bin/herd failed to init"
  [ -f "$E/$COORD_REL" ] || fail "E: the baseline bin/herd did not render the Claude coordinator skill"
  cp "$E/$COORD_REL" "$T/before.md"

  # Same fixture (same PROJECT_ROOT, same .herd/config) — re-render with THIS tree's current
  # bin/herd, so the only variable across the comparison is the code, not the config or the path.
  rm -f "$E/$COORD_REL"
  _herd "$E" render >/dev/null 2>&1 || fail "E: the current bin/herd failed to re-render the fixture"
  [ -f "$E/$COORD_REL" ] || fail "E: the current bin/herd did not regenerate the Claude coordinator skill"

  # Normalize the ONE expected confound before comparing: the baseline bin/herd's HERDKIT_HOME is
  # $OLD (a throwaway copy so its own SCRIPTS_DIR/TEMPLATES_DIR substitute to a temp path), while the
  # current bin/herd's HERDKIT_HOME is $ROOT — an absolute-install-path difference that exists
  # because the baseline copy lives elsewhere on disk, not because of anything this change did. Every
  # OTHER byte must match exactly.
  sed "s#$OLD#<HERDKIT_HOME>#g" "$T/before.md" > "$T/before.norm.md"
  sed "s#$ROOT#<HERDKIT_HOME>#g" "$E/$COORD_REL" > "$T/after.norm.md"
  cmp -s "$T/before.norm.md" "$T/after.norm.md" \
    || fail "E1: the Claude render changed vs. before this change — diff: $(diff "$T/before.norm.md" "$T/after.norm.md" | head -10)"  # pipe-ok: diff|head feeds a bounded failure message inside a command substitution; pipeline status is not gated
  ok "E1 the Claude coordinator render is byte-identical to before this change (module install path aside)"
fi

# ── F. HERD-758 capability tokens: abstract in the template, resolved per render target ────────────
TMPL="$ROOT/templates/coordinator.md.tmpl"
[ -f "$TMPL" ] || fail "F: missing $TMPL"

# F1 the SHARED template names no vendor tool prescriptively — the ratchet that keeps a new
# Claude-only tool name from being hardcoded back into prose both runtimes read.
grep -qF "$CAP_ASK_USER_CLAUDE" "$TMPL" \
  && fail "F1: templates/coordinator.md.tmpl hardcodes the vendor tool name '$CAP_ASK_USER_CLAUDE' — use a {{CAP_*}} capability token so each render target resolves it"
_cap_tokens="$(grep -oE '\{\{CAP_[A-Z0-9_]+\}\}' "$TMPL" | LC_ALL=C sort -u | tr '\n' ' ')"
case "$_cap_tokens" in
  *'{{CAP_ASK_USER}}'*) : ;;
  *) fail "F1: the template carries no {{CAP_ASK_USER}} token (found: ${_cap_tokens:-<none>})" ;;
esac
ok "F1 the shared template names the ABSTRACT capability ({{CAP_*}}), never a vendor tool"

# F2 the Claude render resolves it BACK to the literal tool name, once per token occurrence.
_want="$(grep -c -F '{{CAP_ASK_USER}}' "$TMPL")"
_got="$(grep -c -F "$CAP_ASK_USER_CLAUDE" "$P/$COORD_REL")"
[ "$_want" -gt 0 ] || fail "F2: fixture assumption broken — the template has no {{CAP_ASK_USER}} occurrence to resolve"
[ "$_got" = "$_want" ] \
  || fail "F2: the Claude render resolved {{CAP_ASK_USER}} on $_got line(s), expected $_want — Claude's brief must keep naming its own tool"
ok "F2 the Claude render resolves {{CAP_ASK_USER}} back to the literal '$CAP_ASK_USER_CLAUDE' ($_want occurrences)"

# F3 the Codex render carries NO Claude tool name — not this one, and not any other tool the
# harness prescribes by name. (Prose that merely NAMES the runtime — the driver-seam section's
# "Claude Code" — is the {{DRIVER_*}} seam's business, not a tool instruction, and is not scanned.)
for _tool in "$CAP_ASK_USER_CLAUDE" EnterPlanMode ExitPlanMode TodoWrite NotebookEdit SlashCommand; do
  grep -qF "$_tool" "$P/$CODEX_REL" \
    && fail "F3: the Codex render names the Claude-specific tool '$_tool' — it does not exist on that runtime"
done
ok "F3 the Codex render names no Claude-specific tool"

# F4 …and it says the vendor-NEUTRAL thing instead, on every line the token appears on: degraded
# safely, never a guessed Codex-native tool name (HERD-754's unverified-capability rule).
_got="$(grep -c -F "$CAP_ASK_USER_CODEX" "$P/$CODEX_REL")"
[ "$_got" = "$_want" ] \
  || fail "F4: the Codex render carries the neutral phrasing on $_got line(s), expected $_want"
ok "F4 the Codex render resolves {{CAP_ASK_USER}} to vendor-neutral prose ($_want occurrences)"

echo "ALL PASS ($PASS checks)"
