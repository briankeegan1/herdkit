#!/usr/bin/env bash
# test-config-dedup-lint.sh — hermetic tests for the .herd/config DUPLICATE-KEY lint (issue #115).
#
# .herd/config is shell-sourced, so a KEY assigned twice silently LAST-WINS with no warning — a
# stale/empty duplicate landing AFTER a good value silently flips engine behavior (real incident:
# a stale INTERACTION_TEST_CMD="" placeholder silently DISABLED the widget-interaction
# gate). These tests exercise the four surfaces the fix adds without changing value resolution:
#   1. _herd_config_dup_keys scanner (scripts/herd/herd-config.sh) — detects dups, ignores comments/
#      blanks, handles both `KEY=` and `export KEY=`; and last-wins value resolution is UNCHANGED.
#   2. the source-time WARNING fires at most ONCE per process (dup → warns once even across two
#      sources; clean config → silent).
#   3. `herd config lint` — lists dups + exits NON-ZERO; clean config → exits 0.
#   4. `herd doctor` flags the dup in its Config section.
#   5. `herd config set` twice on one key does NOT create a duplicate.
#
# Run:  bash tests/test-config-dedup-lint.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
LOADER="$REPO/scripts/herd/herd-config.sh"
PREFLIGHT="$REPO/scripts/herd/herd-preflight.sh"
HERD="$REPO/bin/herd"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass=0; okc(){ pass=$((pass+1)); }

# ── A config WITH duplicates: mixed `export`/plain forms, a commented-out line that must be ignored,
#    and the real-incident INTERACTION_TEST_CMD stale-empty-after-good case. ────────────────────────
DUP="$T/dup.config"
cat > "$DUP" <<'EOF'
# a comment line — ignored
HERD_VERSION=1
FOO=1
   # FOO=99 — a commented dup must NOT count
BAZ=only-once
export BAR=a
FOO=2
BAR=b
INTERACTION_TEST_CMD=.herd/_interaction.sh
INTERACTION_TEST_CMD=""
EOF

# ── A CLEAN config: every key assigned exactly once. ──────────────────────────────────────────────
CLEAN="$T/clean.config"
cat > "$CLEAN" <<'EOF'
HERD_VERSION=1
FOO=1
BAR=a
export BAZ=z
INTERACTION_TEST_CMD=.herd/_interaction.sh
EOF

# ════════════════════════════════════════════════════════════════════════════════════════════════
# 1. Scanner — detects each duplicated key once, ignores comments/blanks, handles export forms.
dupes="$(bash -c '. "$1"; _herd_config_dup_keys "$2"' _ "$LOADER" "$DUP")"
echo "$dupes" | grep -qx "FOO"                 || fail "1a: scanner missed dup FOO ($dupes)"
echo "$dupes" | grep -qx "BAR"                 || fail "1b: scanner missed dup BAR (export+plain forms) ($dupes)"
echo "$dupes" | grep -qx "INTERACTION_TEST_CMD"|| fail "1c: scanner missed dup INTERACTION_TEST_CMD ($dupes)"
echo "$dupes" | grep -qx "BAZ"                 && fail "1d: scanner wrongly reported single-assignment BAZ"
[ "$(echo "$dupes" | grep -c .)" -eq 3 ]       || fail "1e: expected exactly 3 duplicated keys, got: $dupes"
okc

# Scanner is silent for a clean config.
[ -z "$(bash -c '. "$1"; _herd_config_dup_keys "$2"' _ "$LOADER" "$CLEAN")" ] \
  || fail "1f: scanner reported a dup for a clean config"
okc

# Value resolution is UNCHANGED — the config still sources with shell LAST-WINS (the fix only
# surfaces the dup; it must not alter which value wins). Last INTERACTION_TEST_CMD="" wins, FOO=2.
vals="$(_HERD_CONFIG_DUP_WARNED=1 HERD_CONFIG_FILE="$DUP" bash -c '. "$1"; echo "FOO=$FOO"; echo "ITC=[$INTERACTION_TEST_CMD]"' _ "$LOADER")"
echo "$vals" | grep -qxF "FOO=2"    || fail "2a: last-wins changed — FOO should resolve to 2 ($vals)"
echo "$vals" | grep -qxF "ITC=[]"   || fail "2b: last-wins changed — empty INTERACTION_TEST_CMD should win ($vals)"
okc

# ════════════════════════════════════════════════════════════════════════════════════════════════
# 2. Source-time WARNING fires at most once per process (across two sources), and only on dups.
warns="$(HERD_CONFIG_FILE="$DUP" bash -c '. "$1"; . "$1"' _ "$LOADER" 2>&1 1>/dev/null | grep -c 'shell last-wins SILENTLY' || true)"
[ "$warns" -eq 1 ] || fail "2c: expected exactly ONE source-time warning across two sources, got $warns"
okc

clean_warns="$(HERD_CONFIG_FILE="$CLEAN" bash -c '. "$1"' _ "$LOADER" 2>&1 1>/dev/null | grep -c 'shell last-wins SILENTLY' || true)"
[ "$clean_warns" -eq 0 ] || fail "2d: clean config emitted a source-time dup warning ($clean_warns)"
okc

# ════════════════════════════════════════════════════════════════════════════════════════════════
# 3. `herd doctor` Config section flags the dup (grep output; exit code depends on git/gh, not us).
docout="$(_HERD_CONFIG_DUP_WARNED=1 HERD_CONFIG_FILE="$DUP" bash -c '. "$1"; . "$2"; herd_doctor 2>&1' _ "$LOADER" "$PREFLIGHT" || true)"
echo "$docout" | grep -q 'Config (.herd/config):'          || fail "3a: doctor printed no Config section"
echo "$docout" | grep -qi 'duplicate key'                  || fail "3b: doctor did not flag the dup"
echo "$docout" | grep -q 'INTERACTION_TEST_CMD'            || fail "3c: doctor did not name the duplicated key"
okc

# doctor is CLEAN-quiet: a clean config gets the ✓ line, not a ⚠.
docclean="$(_HERD_CONFIG_DUP_WARNED=1 HERD_CONFIG_FILE="$CLEAN" bash -c '. "$1"; . "$2"; herd_doctor 2>&1' _ "$LOADER" "$PREFLIGHT" || true)"
echo "$docclean" | grep -q 'no duplicate keys'             || fail "3d: doctor did not report a clean config as OK"
echo "$docclean" | grep -qi 'duplicate key(s)'             && fail "3e: doctor flagged a dup on a clean config"
okc

# ════════════════════════════════════════════════════════════════════════════════════════════════
# 4. `herd config lint` — lists dups + exits NON-ZERO; a clean config exits 0.
PROJ="$T/proj"; mkdir -p "$PROJ/.herd"
cp "$DUP" "$PROJ/.herd/config"
set +e
lintout="$(cd "$PROJ" && "$HERD" config lint 2>&1)"; lintrc=$?
set -e
[ "$lintrc" -ne 0 ]                                        || fail "4a: 'herd config lint' exited 0 despite duplicates"
echo "$lintout" | grep -q 'INTERACTION_TEST_CMD'          || fail "4b: 'herd config lint' did not list the dup key ($lintout)"
echo "$lintout" | grep -qi 'last-wins'                    || fail "4c: 'herd config lint' did not explain last-wins"
okc

cp "$CLEAN" "$PROJ/.herd/config"
set +e
cleanout="$(cd "$PROJ" && "$HERD" config lint 2>&1)"; cleanrc=$?
set -e
[ "$cleanrc" -eq 0 ]                                       || fail "4d: 'herd config lint' exited non-zero on a clean config ($cleanout)"
echo "$cleanout" | grep -qi 'no duplicate keys'           || fail "4e: 'herd config lint' clean message missing ($cleanout)"
okc

# ════════════════════════════════════════════════════════════════════════════════════════════════
# 5. `herd config set` twice on one key does NOT create a duplicate (it edits in place).
# Stub a capabilities manifest so key validation is hermetic; SCRIBE_BACKEND requires nothing (no
# watcher restart / skill re-render), keeping the set path free of herdr/reload machinery.
CAPS="$T/capabilities.tsv"
{
  printf 'name\tkind\tdescription\twhen_to_surface\trequires\n'
  printf 'SCRIBE_BACKEND\tconfig\tWork-tracker backend adapter\tSet for a tracker\t\n'
} > "$CAPS"
export HERD_CAPABILITIES_FILE="$CAPS"

SETPROJ="$T/setproj"; mkdir -p "$SETPROJ/.herd"
cat > "$SETPROJ/.herd/config" <<'EOF'
HERD_VERSION=1
WORKSPACE_NAME=setproj
SCRIBE_BACKEND=file
EOF

( cd "$SETPROJ" && "$HERD" config set SCRIBE_BACKEND changelog >/dev/null 2>&1 ) || fail "5a: first 'config set' failed"
( cd "$SETPROJ" && "$HERD" config set SCRIBE_BACKEND github    >/dev/null 2>&1 ) || fail "5b: second 'config set' failed"

occ="$(grep -cE '^[[:space:]]*SCRIBE_BACKEND=' "$SETPROJ/.herd/config")"
[ "$occ" -eq 1 ] || fail "5c: 'config set' created a duplicate SCRIBE_BACKEND line (count=$occ)"
[ -z "$(bash -c '. "$1"; _herd_config_dup_keys "$2"' _ "$LOADER" "$SETPROJ/.herd/config")" ] \
  || fail "5d: scanner found a dup after two 'config set' calls"
# And the final value is the last set (last-wins, in place).
finalval="$(HERD_CONFIG_FILE="$SETPROJ/.herd/config" bash -c '. "$1"; echo "$SCRIBE_BACKEND"' _ "$LOADER")"
[ "$finalval" = "github" ] || fail "5e: 'config set' did not update in place (got $finalval)"
okc

echo "PASS ($pass checks) — test-config-dedup-lint.sh"
