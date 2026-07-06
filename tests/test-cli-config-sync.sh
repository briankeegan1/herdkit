#!/usr/bin/env bash
# test-cli-config-sync.sh — hermetic tests for the `herd config sync` CLI subcommand (HERD-38).
#
# `herd config sync` is STRICTLY READ-ONLY: it diffs the manifest's kind==config key set against the
# keys assigned in .herd/config and reports each MISSING key with its default value (from the defaults
# template) + its when-to-surface guidance (manifest column 4). It NEVER writes .herd/config — values
# are only ever applied by the operator via the validated `herd config set`.
#
# Design (mirrors test-cli-config.sh):
#   • HERD_CAPABILITIES_FILE points at a STUB manifest so the key set + when-to-surface metadata are
#     hermetic and independent of the shipped templates/capabilities.tsv.
#   • HERD_CONFIG_EXAMPLE_FILE points at a STUB defaults template so the reported default values are
#     hermetic and independent of the shipped templates/config.example.
#   • No herdr, no gh, no network, no model — local temp only.
#
# Run:  bash tests/test-cli-config-sync.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
HERD="$HERE/../bin/herd"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass=0; ok(){ pass=$((pass+1)); }

# ── Stub capabilities manifest (5-column: name kind description when_to_surface requires) ────────────
# A mix of config rows (the key set under test) plus a non-config row that must be IGNORED.
CAPS="$T/capabilities.tsv"
{
  printf 'name\tkind\tdescription\twhen_to_surface\trequires\n'
  printf 'WORKSPACE_NAME\tconfig\tProject label\tAlways required\twatcher\n'
  printf 'SCRIBE_BACKEND\tconfig\tWork-tracker backend\tSet for a tracker\t\n'
  printf 'TOKEN_MODE\tconfig\tToken-budget mode: standard | eco\tOpt in to cut engine token cost\twatcher\n'
  printf 'MERGE_POLICY\tconfig\tPost-gate action: auto | approve | observe\tSet to hold or observe instead of auto-merge\t\n'
  printf 'SHARE_LINKS\tconfig\tGitignored dirs symlinked into each worktree\tWhen worktrees need shared dirs\t\n'
  printf 'HEALTH_CONCURRENCY\tconfig\tMax healthcheck suites at once\tRaise cautiously; suites share one git store\twatcher\n'
  printf 'herd init\tcommand\tStand up herdkit\tOnboarding\t\n'
} > "$CAPS"
export HERD_CAPABILITIES_FILE="$CAPS"

# ── Stub defaults template — active KEY=value AND a commented `# KEY=value` default line ─────────────
# SHARE_LINKS has an empty default (""); TOKEN_MODE is documented as a COMMENTED default (the form
# config.example uses for optional keys) to prove the parser reads commented defaults too.
EXAMPLE="$T/config.example"
{
  printf 'WORKSPACE_NAME="myproject"        # herdr workspace label\n'
  printf 'SCRIBE_BACKEND="file"             # file (default) | changelog\n'
  printf '# TOKEN_MODE="standard"           # standard (default) | eco\n'
  printf 'MERGE_POLICY="auto"               # auto | approve | observe\n'
  printf 'SHARE_LINKS=""                    # gitignored dirs symlinked into each worktree\n'
} > "$EXAMPLE"
export HERD_CONFIG_EXAMPLE_FILE="$EXAMPLE"

# ── _make_project ROOT [extra config lines…] ────────────────────────────────────────────────────────
_make_project() {
  local r="$1"; shift
  mkdir -p "$r/.herd"
  {
    printf '# .herd/config — test fixture (comment preserved on purpose)\n'
    printf 'HERD_VERSION=1\n'
    printf 'WORKSPACE_NAME="demo"\n'
    printf 'SCRIBE_BACKEND="file"\n'
    local line; for line in "$@"; do printf '%s\n' "$line"; done
  } > "$r/.herd/config"
}

run_sync() { ( cd "$1" && "$HERD" config sync ) 2>&1; }

# ── 1. MISSING keys → detected, named with default + when-to-surface, non-zero exit ─────────────────
P1="$T/p1"; _make_project "$P1"          # assigns WORKSPACE_NAME + SCRIBE_BACKEND only
out="$(run_sync "$P1")"; rc=$?
[ "$rc" -ne 0 ] || fail "(1) sync must exit NON-ZERO when keys are missing (got rc=$rc)"
grep -q "TOKEN_MODE"   <<<"$out" || fail "(1) missing key TOKEN_MODE not reported:\n$out"
grep -q "MERGE_POLICY" <<<"$out" || fail "(1) missing key MERGE_POLICY not reported:\n$out"
grep -q "SHARE_LINKS"  <<<"$out" || fail "(1) missing key SHARE_LINKS not reported:\n$out"
grep -q 'WORKSPACE_NAME' <<<"$out" && fail "(1) assigned key WORKSPACE_NAME must NOT be reported missing:\n$out"
grep -q 'herd init' <<<"$out" && fail "(1) non-config manifest row leaked into the report:\n$out"
ok
echo "PASS (1) missing keys detected + non-zero exit; assigned + non-config rows excluded"

# ── 2. Default VALUE + when-to-surface guidance are shown (default from the template, incl. commented) ─
grep -Eq 'MERGE_POLICY .*default="auto"'  <<<"$out" || fail "(2) MERGE_POLICY default 'auto' not shown:\n$out"
grep -Eq 'TOKEN_MODE .*default="standard"' <<<"$out" || fail "(2) commented-default TOKEN_MODE 'standard' not parsed:\n$out"
grep -Eq 'SHARE_LINKS .*default=""'       <<<"$out" || fail "(2) empty default for SHARE_LINKS not shown as \"\":\n$out"
grep -Eq 'HEALTH_CONCURRENCY .*default=.*engine built-in' <<<"$out" || fail "(2) key absent from defaults template must render '(engine built-in)', not default=\"\":\n$out"
grep -q 'Set to hold or observe instead of auto-merge' <<<"$out" || fail "(2) MERGE_POLICY when-to-surface not shown:\n$out"
grep -q 'Opt in to cut engine token cost'             <<<"$out" || fail "(2) TOKEN_MODE when-to-surface not shown:\n$out"
ok
echo "PASS (2) each missing key shows its default value (active + commented) and when-to-surface guidance"

# ── 3. CLEAN config → quiet, exit 0 ─────────────────────────────────────────────────────────────────
P2="$T/p2"; _make_project "$P2" 'TOKEN_MODE="eco"' 'MERGE_POLICY="approve"' 'SHARE_LINKS="node_modules"' 'HEALTH_CONCURRENCY="1"'
out2="$(run_sync "$P2")"; rc2=$?
[ "$rc2" -eq 0 ] || fail "(3) sync must exit 0 when every manifest config key is assigned (got rc=$rc2):\n$out2"
grep -q 'in sync' <<<"$out2" || fail "(3) clean config should confirm 'in sync':\n$out2"
grep -Eq 'missing|MISSING' <<<"$out2" && fail "(3) clean config must not report any missing key:\n$out2"
ok
echo "PASS (3) fully-assigned config is quiet-clean and exits 0"

# ── 4. READ-ONLY guarantee — .herd/config is BYTE-IDENTICAL after sync (missing AND clean cases) ─────
before1="$(cat "$P1/.herd/config")"; run_sync "$P1" >/dev/null 2>&1 || true
[ "$before1" = "$(cat "$P1/.herd/config")" ] || fail "(4) sync MUTATED .herd/config in the missing-keys case"
before2="$(cat "$P2/.herd/config")"; run_sync "$P2" >/dev/null 2>&1 || true
[ "$before2" = "$(cat "$P2/.herd/config")" ] || fail "(4) sync MUTATED .herd/config in the clean case"
ok
echo "PASS (4) read-only guarantee: .herd/config byte-identical after sync (both cases)"

# ── 5. No .herd/config → clear error, non-zero (guards a stray-directory run) ────────────────────────
P3="$T/p3"; mkdir -p "$P3"
out3="$( ( cd "$P3" && "$HERD" config sync ) 2>&1 )"; rc3=$?
[ "$rc3" -ne 0 ] || fail "(5) sync must fail when there is no .herd/config (got rc=$rc3)"
grep -q "no .herd/config" <<<"$out3" || fail "(5) expected a 'no .herd/config' error:\n$out3"
ok
echo "PASS (5) missing .herd/config → clear error + non-zero exit"

echo "OK — $pass checks passed"
