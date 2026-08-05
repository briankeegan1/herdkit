#!/usr/bin/env bash
# test-read-project-config.sh — the shared foreign-project config reader _herd_read_project_config
# (scripts/herd/herd-config.sh) and fleet.sh's adoption of it (HERD-160 quick win).
#
# The isolated-subshell "source a project's .herd/config + apply the standard fallbacks + emit a TSV
# row" logic lived only in fleet.sh (_fleet_read_config), scattering the direct `. .herd/config` out
# of the config module. It is extracted to _herd_read_project_config in herd-config.sh; fleet.sh now
# adopts it. This test proves the extracted reader (a) emits the full row verbatim, (b) applies the
# same fallbacks the main loader does, (c) fails on a config-less path, and (d) that _fleet_read_config
# is byte-identical to it (the adoption is a pure delegation, no behaviour change).
#
# Hermetic: temp project dirs; no herdr/gh/network. Run:  bash tests/test-read-project-config.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LOADER="$ROOT/scripts/herd/herd-config.sh"
FLEET="$ROOT/scripts/herd/fleet.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
# Neutral config so sourcing the loader neither binds to the engine dogfood config nor errors.
export HERD_CONFIG_FILE="$T/neutral.config"; : > "$HERD_CONFIG_FILE"
PASS=0
fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { PASS=$((PASS+1)); }

# read_one <path> — run _herd_read_project_config against <path> in a fresh loader process.
read_one() { HERD_CONFIG_FILE="$HERD_CONFIG_FILE" bash -c '. "$1"; _herd_read_project_config "$2"' _ "$LOADER" "$1"; }
# read_via_fleet <path> — the same via fleet.sh's adopter (loader first so the seam is defined).
read_via_fleet() { HERD_CONFIG_FILE="$HERD_CONFIG_FILE" bash -c '. "$1"; . "$2"; _fleet_read_config "$3"' _ "$LOADER" "$FLEET" "$1"; }

# ── 1. FULL config → row emitted verbatim (all five fields) ───────────────────────────────────────
P1="$T/alpha"; mkdir -p "$P1/.herd"
cat > "$P1/.herd/config" <<EOF
WORKSPACE_NAME=alpha-ws
PROJECT_ROOT=$P1
WORKTREES_DIR=$T/alpha-pool
DEFAULT_BRANCH=origin/trunk
HERD_REPO=acme/alpha
EOF
row="$(read_one "$P1")"
[ "$row" = "$(printf 'alpha-ws\t%s\t%s\t%s\t%s' "$P1" "$T/alpha-pool" "origin/trunk" "acme/alpha")" ] \
  || fail "(1) full-config row mismatch: $row"
pass

# ── 2. MINIMAL config → the standard fallbacks apply (basename ws, <root>-trees, origin/main, empty repo)
P2="$T/beta"; mkdir -p "$P2/.herd"; : > "$P2/.herd/config"
row="$(read_one "$P2")"
[ "$row" = "$(printf 'beta\t%s\t%s\t%s\t' "$P2" "$P2-trees" "origin/main")" ] \
  || fail "(2) fallback row mismatch: $row"
pass

# ── 3. no .herd/config → non-zero return, no output ───────────────────────────────────────────────
P3="$T/gamma"; mkdir -p "$P3"
set +e; out="$(read_one "$P3")"; rc=$?; set -e
[ "$rc" -ne 0 ] || fail "(3) reader returned 0 for a config-less path"
[ -z "$out" ]   || fail "(3) reader printed a row for a config-less path: $out"
pass

# ── 4. fleet adoption is a pure delegation — identical output on the same paths ───────────────────
for p in "$P1" "$P2"; do
  a="$(read_one "$p")"; b="$(read_via_fleet "$p")"
  [ "$a" = "$b" ] || fail "(4) _fleet_read_config diverged from _herd_read_project_config for $p:
  direct: $a
  fleet:  $b"
done
pass

# ── 6. HERD-518: foreign committed PROJECT_ROOT + a config.local override → resolves to the overlay
# value, byte-identical to a same-machine config (no localization note on stderr).
P4="$T/delta"; mkdir -p "$P4/.herd"
FOREIGN4="$T/no-such-original-machine/delta"
cat > "$P4/.herd/config" <<EOF
WORKSPACE_NAME=delta-ws
PROJECT_ROOT=$FOREIGN4
EOF
cat > "$P4/.herd/config.local" <<EOF
PROJECT_ROOT=$P4
EOF
row="$(read_one "$P4" 2>"$T/stderr4")"
[ "$row" = "$(printf 'delta-ws\t%s\t%s\t%s\t' "$P4" "$P4-trees" "origin/main")" ] \
  || fail "(6) foreign-root + overlay row mismatch: $row"
[ ! -s "$T/stderr4" ] || fail "(6) overlay already resolved a real path but a localization note was printed: $(cat "$T/stderr4")"
pass

# ── 7. HERD-518: foreign committed PROJECT_ROOT, no overlay → resolves to the ARGUMENT path (with a
# one-line stderr note), and a WORKTREES_DIR derived from the foreign root is carried along with it.
P5="$T/epsilon"; mkdir -p "$P5/.herd"
FOREIGN5="$T/no-such-original-machine/epsilon"
cat > "$P5/.herd/config" <<EOF
WORKSPACE_NAME=epsilon-ws
PROJECT_ROOT=$FOREIGN5
WORKTREES_DIR=$FOREIGN5-pool
EOF
row="$(read_one "$P5" 2>"$T/stderr5")"
[ "$row" = "$(printf 'epsilon-ws\t%s\t%s\t%s\t' "$P5" "$P5-pool" "origin/main")" ] \
  || fail "(7) foreign-root-no-overlay row mismatch: $row"
[ -s "$T/stderr5" ] || fail "(7) no localization note printed for an unresolvable foreign PROJECT_ROOT"
grep -q "$FOREIGN5" "$T/stderr5" || fail "(7) localization note missing the foreign path: $(cat "$T/stderr5")"
pass

# ── 8. HERD-518: an EXISTING committed PROJECT_ROOT resolves unchanged — byte-identical to
# today's behaviour even though a config.local overlay is also present (regression guard for (1)/(2)).
row="$(read_one "$P1" 2>"$T/stderr1")"
[ "$row" = "$(printf 'alpha-ws\t%s\t%s\t%s\t%s' "$P1" "$T/alpha-pool" "origin/trunk" "acme/alpha")" ] \
  || fail "(8) existing committed path changed behaviour: $row"
[ ! -s "$T/stderr1" ] || fail "(8) localization note printed for an existing committed path: $(cat "$T/stderr1")"
pass

# ── 5. fleet.sh no longer sources .herd/config directly (routes through the seam) ─────────────────
# Blank comment lines, then look for a `.`/`source` of a .herd/config anchored at a statement boundary
# (the same shape the seam-conformance config-source rule uses).
awk '{ s=$0; sub(/^[ \t]+/,"",s); if (s ~ /^#/) print ""; else print $0 }' "$FLEET" \
  | { /usr/bin/grep -qE '(^|;|[[:space:]])(\.|source)[[:space:]]+"?[^"|;&]*\.herd/config' && exit 1 || exit 0; } \
  || fail "(5) fleet.sh still sources .herd/config directly — it must route through _herd_read_project_config"
pass

echo "ALL PASS ($PASS checks)"
