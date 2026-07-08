#!/usr/bin/env bash
# test-config-local-dup-lint.sh — `herd config lint` and `herd doctor` also scan the per-user overlay
# .herd/config.local for duplicate keys (HERD-160 quick win, extending issue #115 / HERD-47).
#
# .herd/config.local is shell-sourced with the SAME last-wins semantics as the baseline, so a duplicate
# key WITHIN the overlay silently overrides an earlier assignment and can disable a gate — yet the lint
# and doctor previously scanned only the baseline and merely NOTED the overlay's presence. This test
# proves both surfaces now flag an overlay-internal duplicate, and that a key set in BOTH files (an
# intentional override) is NOT reported as a duplicate.
#
# Run:  bash tests/test-config-local-dup-lint.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
LOADER="$REPO/scripts/herd/herd-config.sh"
PREFLIGHT="$REPO/scripts/herd/herd-preflight.sh"
HERD="$REPO/bin/herd"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass=0; okc(){ pass=$((pass+1)); }

# HERMETIC STUB: `herd doctor` probes `claude --version` and touches the LIVE herdr when both are on
# PATH. Shadow them with benign no-ops so the overlay dup-lint/doctor assertions are unchanged and
# nothing reaches the real control room.
BIN="$T/bin"; mkdir -p "$BIN"
printf '#!/usr/bin/env bash\necho '"'"'{}'"'"'\nexit 0\n'      > "$BIN/herdr";  chmod +x "$BIN/herdr"
printf '#!/usr/bin/env bash\necho '"'"'claude 0.0.0'"'"'\nexit 0\n' > "$BIN/claude"; chmod +x "$BIN/claude"
export PATH="$BIN:$PATH"

# ── 1. `herd config lint` flags a duplicate INSIDE config.local (baseline clean) ──────────────────
PROJ="$T/proj"; mkdir -p "$PROJ/.herd"
cat > "$PROJ/.herd/config" <<'EOF'
HERD_VERSION=1
WORKSPACE_NAME=proj
EOF
cat > "$PROJ/.herd/config.local" <<'EOF'
MODEL_QUICK=claude-haiku-4-5
MODEL_QUICK=claude-sonnet-4-6
EOF
set +e
lintout="$(cd "$PROJ" && "$HERD" config lint 2>&1)"; lintrc=$?
set -e
[ "$lintrc" -ne 0 ]                              || fail "1a: 'config lint' exited 0 despite a config.local dup ($lintout)"
echo "$lintout" | grep -q 'config.local'         || fail "1b: 'config lint' did not name config.local ($lintout)"
echo "$lintout" | grep -q 'MODEL_QUICK'          || fail "1c: 'config lint' did not list the overlay dup key ($lintout)"
okc

# ── 2. `herd config lint` is clean when neither file has an INTERNAL duplicate, even if a key is set
#       in BOTH (that is an intentional override, not a duplicate) ─────────────────────────────────
cat > "$PROJ/.herd/config.local" <<'EOF'
WORKSPACE_NAME=proj-local-override
MODEL_QUICK=claude-sonnet-4-6
EOF
set +e
cleanout="$(cd "$PROJ" && "$HERD" config lint 2>&1)"; cleanrc=$?
set -e
[ "$cleanrc" -eq 0 ]                             || fail "2a: 'config lint' failed on a clean overlay w/ cross-file override ($cleanout)"
echo "$cleanout" | grep -qi 'no duplicate keys in .herd/config.local' \
                                                 || fail "2b: 'config lint' did not confirm the overlay clean ($cleanout)"
okc

# ── 3. `herd doctor` Config section flags the overlay duplicate ───────────────────────────────────
# doctor derives the overlay as the SIBLING config.local next to the resolved baseline, so lay them
# out as real siblings in a .herd dir (HERD_CONFIG_FILE points at the baseline).
DPROJ="$T/dproj"; mkdir -p "$DPROJ/.herd"
DUP="$DPROJ/.herd/config"; LOCAL="$DPROJ/.herd/config.local"
cat > "$DUP" <<'EOF'
HERD_VERSION=1
EOF
cat > "$LOCAL" <<'EOF'
REVIEW_CONCURRENCY=2
REVIEW_CONCURRENCY=4
EOF
docout="$(_HERD_CONFIG_DUP_WARNED=1 HERD_CONFIG_FILE="$DUP" bash -c '. "$1"; . "$2"; herd_doctor 2>&1' _ "$LOADER" "$PREFLIGHT" || true)"
echo "$docout" | grep -q 'Config (.herd/config):'    || fail "3a: doctor printed no Config section"
echo "$docout" | grep -qi 'config.local'             || fail "3b: doctor did not mention config.local ($docout)"
echo "$docout" | grep -q 'REVIEW_CONCURRENCY'        || fail "3c: doctor did not name the overlay dup key ($docout)"
okc

# ── 4. doctor is clean-quiet for a duplicate-free overlay ─────────────────────────────────────────
cat > "$LOCAL" <<'EOF'
REVIEW_CONCURRENCY=4
EOF
docclean="$(_HERD_CONFIG_DUP_WARNED=1 HERD_CONFIG_FILE="$DUP" bash -c '. "$1"; . "$2"; herd_doctor 2>&1' _ "$LOADER" "$PREFLIGHT" || true)"
echo "$docclean" | grep -qi 'config.local overlay present, no duplicate keys' \
                                                     || fail "4a: doctor did not report the clean overlay ($docclean)"
okc

echo "PASS ($pass checks) — test-config-local-dup-lint.sh"
