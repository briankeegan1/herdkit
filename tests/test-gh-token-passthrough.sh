#!/usr/bin/env bash
# test-gh-token-passthrough.sh — hermetic tests for HERD-671 leg 3: the optional per-project GH_TOKEN
# passthrough in scripts/herd/herd-config.sh. GitHub rate limits are PER USER, not per token, so a
# machine running several watchers under one shared `gh auth login` identity draws every project from
# the SAME bucket; a GH_TOKEN in a project's .herd/secrets (a DIFFERENTLY-OWNED identity — a machine
# account or GitHub App token) partitions that project onto its own bucket. `gh` itself already
# prefers GH_TOKEN/GITHUB_TOKEN over stored `gh auth login` credentials, so exporting it is the whole
# integration on the consumption side — this test only proves the export seam.
#
# Proves the lever both ways, per AGENTS.md, plus the safety properties:
#   • ABSENT .herd/secrets (or no GH_TOKEN line in it) => GH_TOKEN stays unset — byte-identical to
#     before this key existed, `gh` falls back to its already-authenticated identity.
#   • PRESENT (bare or `export`-prefixed, quoted or not) => exported into the sourcing process's env.
#   • An ALREADY-exported GH_TOKEN (the operator's own shell, a CI runner) wins over the file — this
#     lever only fills a gap, never overrides an existing call-site choice.
#   • The value is read via `grep`, NEVER by sourcing .herd/secrets — a value containing shell
#     metacharacters (`$(...)`, backticks) must land LITERALLY in GH_TOKEN, never get interpreted.
#   • No PROJECT_ROOT / unreadable secrets file is a silent no-op, never a crash.
#
# Fully hermetic: local temp only, no gh/network/model. Mirrors the loader-sourcing style of
# tests/test-herd-config.sh.
# Run:  bash tests/test-gh-token-passthrough.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LOADER="$HERE/../scripts/herd/herd-config.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass(){ PASS=$((PASS+1)); }
[ -f "$LOADER" ] || fail "herd-config.sh not found at $LOADER"

# load_gh_token <project_root> [extra env assignments...] — sources the loader in a clean subshell
# from a cwd with no .herd/config above it, and prints GH_TOKEN's resolved value (empty if unset).
# Sourced under `set -euo pipefail` DELIBERATELY: every real caller (new-feature.sh, herd-quick.sh,
# herd-feature.sh) sources herd-config.sh under exactly this strictness, so any pipeline in the
# passthrough that trips `set -e` on the common "no GH_TOKEN line" case would abort the caller
# entirely — a bug the loader-sourcing itself must catch, not just the resolved value.
load_gh_token() {
  local proj="$1"; shift
  ( cd "$T" && env -i PATH="$PATH" HOME="$HOME" PROJECT_ROOT="$proj" HERD_CONFIG_FILE="$proj/.nonexistent-config" "$@" \
      bash -c "set -euo pipefail
unset MODEL_COORDINATOR MODEL_FEATURE MODEL_QUICK MODEL_SCRIBE MODEL_RESEARCH MODEL_RESOLVER MODEL_REVIEW TOKEN_MODE
. '$LOADER' >/dev/null 2>&1
printf '%s' \"\${GH_TOKEN:-}\"" )
}

PROJ="$T/proj"; mkdir -p "$PROJ/.herd"

# ── 0. THE regression this class of bug produces: sourcing under a real caller's `set -e -o
# pipefail` must NEVER abort mid-source on the common "no GH_TOKEN line" case (grep's exit 1 on no
# match propagating through `| tail | sed` under pipefail is exactly the trap). Assert the MARKER
# after the source line is actually reached and the whole invocation exits 0 — not just that the
# resolved value looks empty, which a mid-source abort would also (mis)produce.
printf '# .herd/secrets\nLINEAR_API_KEY=unrelated\n' > "$PROJ/.herd/secrets"
abort_out="$( cd "$T" && env -i PATH="$PATH" HOME="$HOME" PROJECT_ROOT="$PROJ" \
  HERD_CONFIG_FILE="$PROJ/.nonexistent-config" bash -c "set -euo pipefail
unset MODEL_COORDINATOR MODEL_FEATURE MODEL_QUICK MODEL_SCRIBE MODEL_RESEARCH MODEL_RESOLVER MODEL_REVIEW TOKEN_MODE
. '$LOADER' >/dev/null 2>&1
printf 'SOURCED_OK'" 2>&1 )"
abort_rc=$?
[ "$abort_rc" -eq 0 ] || fail "sourcing under set -e -o pipefail must exit 0 with no GH_TOKEN line (rc=$abort_rc, out='$abort_out')"
[ "$abort_out" = "SOURCED_OK" ] || fail "sourcing aborted mid-file under set -e -o pipefail (got '$abort_out') — a real caller (new-feature.sh) would die here"
pass

# ── 1. No .herd/secrets at all: byte-identical, nothing exported ───────────────────────────────────
rm -f "$PROJ/.herd/secrets"
out="$(load_gh_token "$PROJ")"
[ -z "$out" ] || fail "no secrets file: GH_TOKEN should stay unset, got '$out'"
pass

# ── 2. .herd/secrets present but with no GH_TOKEN line: still unset ────────────────────────────────
printf '# .herd/secrets\nLINEAR_API_KEY=unrelated\n' > "$PROJ/.herd/secrets"
out="$(load_gh_token "$PROJ")"
[ -z "$out" ] || fail "no GH_TOKEN line: should stay unset, got '$out'"
pass

# ── 3. Bare GH_TOKEN=value is picked up and exported ────────────────────────────────────────────────
printf 'GH_TOKEN=ghp_machineaccount123\n' > "$PROJ/.herd/secrets"
out="$(load_gh_token "$PROJ")"
[ "$out" = "ghp_machineaccount123" ] || fail "bare GH_TOKEN not picked up, got '$out'"
pass

# ── 4. `export GH_TOKEN=value` form (some operators may hand-edit the file this way) ────────────────
printf 'export GH_TOKEN=ghp_exported456\n' > "$PROJ/.herd/secrets"
out="$(load_gh_token "$PROJ")"
[ "$out" = "ghp_exported456" ] || fail "export-prefixed GH_TOKEN not picked up, got '$out'"
pass

# ── 5. Quoted values (double and single) are unwrapped ──────────────────────────────────────────────
printf 'GH_TOKEN="ghp_double789"\n' > "$PROJ/.herd/secrets"
out="$(load_gh_token "$PROJ")"
[ "$out" = "ghp_double789" ] || fail "double-quoted GH_TOKEN not unwrapped, got '$out'"
printf "GH_TOKEN='ghp_single000'\n" > "$PROJ/.herd/secrets"
out="$(load_gh_token "$PROJ")"
[ "$out" = "ghp_single000" ] || fail "single-quoted GH_TOKEN not unwrapped, got '$out'"
pass

# ── 6. A trailing inline comment is stripped, matching the file's other secret-adjacent readers ─────
printf 'GH_TOKEN=ghp_withcomment  # machine account token\n' > "$PROJ/.herd/secrets"
out="$(load_gh_token "$PROJ")"
[ "$out" = "ghp_withcomment" ] || fail "trailing comment not stripped, got '$out'"
pass

# ── 7. An already-EXPORTED GH_TOKEN wins over the file (layered under, never overriding) ────────────
printf 'GH_TOKEN=ghp_fromfile\n' > "$PROJ/.herd/secrets"
out="$(load_gh_token "$PROJ" GH_TOKEN=ghp_alreadyset)"
[ "$out" = "ghp_alreadyset" ] || fail "an already-exported GH_TOKEN must win over the file, got '$out'"
pass

# ── 8. Never sourced — a value with shell metacharacters lands LITERALLY, never interpreted ─────────
printf 'GH_TOKEN=ghp_$(whoami)_`id`\n' > "$PROJ/.herd/secrets"
out="$(load_gh_token "$PROJ")"
[ "$out" = 'ghp_$(whoami)_`id`' ] || fail "GH_TOKEN value must never be shell-interpreted, got '$out'"
pass

# ── 9. No PROJECT_ROOT set: silent no-op, never a crash ─────────────────────────────────────────────
out="$( ( cd "$T" && env -i PATH="$PATH" HOME="$HOME" HERD_CONFIG_FILE="$T/.nonexistent-config" bash -c "
unset MODEL_COORDINATOR MODEL_FEATURE MODEL_QUICK MODEL_SCRIBE MODEL_RESEARCH MODEL_RESOLVER MODEL_REVIEW TOKEN_MODE
. '$LOADER' >/dev/null 2>&1
printf '%s' \"\${GH_TOKEN:-}\"" ) )" || fail "sourcing with no PROJECT_ROOT must not crash"
[ -z "$out" ] || fail "no PROJECT_ROOT: GH_TOKEN should stay unset, got '$out'"
pass

echo "OK ($PASS assertions) — $0"
