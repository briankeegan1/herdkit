#!/usr/bin/env bash
# test-governance-drift.sh — hermetic tests for the HERD-125 governance-DRIFT sweep
# (scripts/herd/governance-drift-sweep.sh).
#
# BINDING CONSTRAINTS under test:
#   • ADVISORY-ONLY — the sweep re-extracts CLAUDE.md/AGENTS.md (reusing the HERD-119 adoption
#     extraction: scripts/herd/governance.sh + templates/governance-map.tsv) and DIFFS the mapped
#     config-key rules against the effective .herd/config, but NEVER mutates config or any file.
#   • LOUD ON DRIFT — a governance sentence whose mapped value differs from the effective config
#     produces a stdout advisory that NAMES the key + proposed value + the `herd config set` to adopt,
#     and journals ONE governance_drift event per drifted key.
#   • SILENT WHEN IN SYNC OR NO PROSE — byte-identical silence: zero stdout, zero journal.
#   • OPTIONAL PR COMMENT — only with --pr, and only via the (stubbable) gh comment seam.
#
# NO network, NO gh, NO claude, NO model: the sweep runs fully hermetically over the real pattern
# table with throwaway config + CLAUDE.md/AGENTS.md fixtures and captured journal/PR-comment seams.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
SWEEP="$REPO/scripts/herd/governance-drift-sweep.sh"
MAP="$REPO/templates/governance-map.tsv"
export HERD_GOVERNANCE_MAP="$MAP"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

# mkcfg <dir> <config-body> — a throwaway project root with a .herd/config. PROJECT_ROOT is pinned to
# the dir so the sweep's default CLAUDE.md/AGENTS.md source paths resolve inside the fixture.
mkcfg() {
  local d="$1" body="$2"
  rm -rf "$d"; mkdir -p "$d/.herd"
  { printf 'PROJECT_ROOT="%s"\n' "$d"; printf 'WORKSPACE_NAME="fixture"\n'; printf '%s\n' "$body"; } > "$d/.herd/config"
}

# run <dir> [args...] — run the sweep against the fixture with hermetic seams, capturing stdout+stderr.
# Journal lands in <dir>/journal.jsonl (JOURNAL_FILE seam).
run() {
  local d="$1"; shift
  ( cd "$d" && HERD_CONFIG_FILE="$d/.herd/config" JOURNAL_FILE="$d/journal.jsonl" \
      HERD_GOVERNANCE_MAP="$MAP" bash "$SWEEP" "$@" 2>&1 )
}

# ── (1) DRIFT → loud advisory naming key + proposed value, one journal event per key ───────────────
proj="$T/drift"
mkcfg "$proj" 'PUSH_GATE=""
MERGE_METHOD="merge"'
cat > "$proj/CLAUDE.md" <<'MD'
# Project conventions
- All changes must be reviewed by a human before they are pushed to GitHub.
- Use squash merges to keep the history clean.
- This project targets Python 3.11 and ships weekly.
MD
out="$(run "$proj")" || fail "(1) sweep exited non-zero: $out"
echo "$out" | grep -q 'governance-drift-sweep:'                        || fail "(1) drift must print a loud advisory header: $out"
echo "$out" | grep -q 'PUSH_GATE=human'                                || fail "(1) advisory must name the drifted key + proposed value PUSH_GATE=human"
echo "$out" | grep -q 'herd config set PUSH_GATE human'                || fail "(1) advisory must show the exact 'herd config set' to adopt"
echo "$out" | grep -q 'MERGE_METHOD=squash'                            || fail "(1) advisory must also name MERGE_METHOD=squash"
echo "$out" | grep -qF 'reviewed by a human before they are pushed'    || fail "(1) advisory must quote the source sentence as evidence"
echo "$out" | grep -q 'config says: PUSH_GATE=<unset>'                 || fail "(1) advisory must show the current (empty→<unset>) config value"
# journal: one governance_drift event per drifted key, naming key + claude_value + config_value.
[ -f "$proj/journal.jsonl" ]                                           || fail "(1) a governance_drift journal event must be written on drift"
grep -q '"event":"governance_drift"' "$proj/journal.jsonl"             || fail "(1) journal event type must be governance_drift"
grep -q '"key":"PUSH_GATE".*"claude_value":"human"' "$proj/journal.jsonl" || fail "(1) journal must record key + claude_value: $(cat "$proj/journal.jsonl")"
grep -q '"key":"MERGE_METHOD".*"claude_value":"squash"' "$proj/journal.jsonl" || fail "(1) journal must record the MERGE_METHOD drift too"
# ADVISORY-ONLY: the sweep must NOT mutate .herd/config.
grep -q '^PUSH_GATE=""$' "$proj/.herd/config"                          || fail "(1) sweep must NOT auto-apply — .herd/config PUSH_GATE must stay empty"
ok

# ── (2) IN SYNC → byte-identical silence (no stdout, no journal) ───────────────────────────────────
proj="$T/insync"
mkcfg "$proj" 'PUSH_GATE="human"
MERGE_METHOD="squash"'
cat > "$proj/CLAUDE.md" <<'MD'
# Project conventions
- All changes must be reviewed by a human before they are pushed to GitHub.
- Use squash merges to keep the history clean.
MD
out="$(run "$proj")" || fail "(2) sweep exited non-zero: $out"
[ -z "$out" ]                                                          || fail "(2) in-sync config → the sweep must be SILENT, got: $out"
[ ! -f "$proj/journal.jsonl" ]                                         || fail "(2) in-sync config → NO journal event may be written"
ok

# ── (3) NO PROSE → byte-identical silence ─────────────────────────────────────────────────────────
proj="$T/noprose"
mkcfg "$proj" 'PUSH_GATE=""'
# no CLAUDE.md, no AGENTS.md
out="$(run "$proj")" || fail "(3) sweep exited non-zero: $out"
[ -z "$out" ]                                                          || fail "(3) no governance prose → the sweep must be SILENT, got: $out"
[ ! -f "$proj/journal.jsonl" ]                                         || fail "(3) no prose → NO journal event"
ok

# ── (4) AGENTS.md is also a source, and drift lines attribute the right file ───────────────────────
proj="$T/agents"
mkcfg "$proj" 'MERGE_POLICY="auto"'
cat > "$proj/AGENTS.md" <<'MD'
# Agent rules
- Never auto-merge pull requests without explicit approval.
MD
out="$(run "$proj")" || fail "(4) sweep exited non-zero: $out"
echo "$out" | grep -q 'MERGE_POLICY=approve'                           || fail "(4) AGENTS.md rule must be extracted (MERGE_POLICY=approve)"
echo "$out" | grep -q 'AGENTS.md now says'                             || fail "(4) drift line must attribute the source file (AGENTS.md)"
grep -q '"source":"AGENTS.md"' "$proj/journal.jsonl"                   || fail "(4) journal must record source=AGENTS.md"
ok

# ── (5) OPTIONAL PR COMMENT (--pr) posts via the stubbable seam; body names the drift ──────────────
proj="$T/prcomment"
mkcfg "$proj" 'PUSH_GATE=""'
cat > "$proj/CLAUDE.md" <<'MD'
# Conventions
- All changes must be reviewed by a human before they are pushed.
MD
# Stub gh: capture argv (PR number + --body <body>) to a file instead of hitting the network.
stub="$T/ghstub.sh"
cat > "$stub" <<STUB
#!/usr/bin/env bash
{ echo "PR=\$1"; echo "BODY<<"; shift 2; echo "\$1"; } > "$T/comment.out"
STUB
chmod +x "$stub"
out="$(HERD_DRIFT_PR_COMMENT="$stub" run "$proj" --pr 321)" || fail "(5) sweep --pr exited non-zero: $out"
echo "$out" | grep -q 'posted the drift advisory as a comment on PR #321' || fail "(5) --pr must report it posted a comment: $out"
[ -f "$T/comment.out" ]                                                || fail "(5) the PR-comment seam must be invoked"
grep -q 'PR=321' "$T/comment.out"                                      || fail "(5) the comment must target the given PR number"
grep -q 'herd config set PUSH_GATE human' "$T/comment.out"             || fail "(5) the comment body must carry the adopt command"
ok

# ── (6) A drift that is NOT a config-key surface (e.g. a hook/style rule) never reports ────────────
# 'Always run the test suite before committing' maps to a HOOK surface, not an effective-config key,
# so it can never be config drift and must stay silent.
proj="$T/hookonly"
mkcfg "$proj" 'PUSH_GATE="human"
MERGE_METHOD="merge"'
cat > "$proj/CLAUDE.md" <<'MD'
# Conventions
- Always run the test suite before committing.
- Prefer descriptive variable names over abbreviations.
MD
out="$(run "$proj")" || fail "(6) sweep exited non-zero: $out"
[ -z "$out" ]                                                          || fail "(6) hook/style-only prose → no config-key drift, must be SILENT, got: $out"
ok

echo "ALL PASS ($pass checks)"
