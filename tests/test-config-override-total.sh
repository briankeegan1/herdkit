#!/usr/bin/env bash
# test-config-override-total.sh — HERD-558: an operator's `herd config set --local` in the MAIN
# checkout must reach WORKTREE-context resolution too, not just main-checkout-context runs.
#
# Live failure this guards: `herd config set --local HEALTHCHECK_CMD=true` in the MAIN checkout only
# muted main-checkout-context runs. healthcheck.sh resolves config from the TARGET WORKTREE's .herd/,
# and `git worktree add` never copies the main checkout's gitignored config.local into a linked
# worktree, so a worktree's own overlay block found nothing and 137 suite processes kept running
# post-"release". Fixed in the overlay leg of scripts/herd/herd-config.sh: a worktree's resolution now
# ALSO layers the MAIN checkout's config.local on top, for POLICY-class keys only (anything NOT
# scope=machine in templates/capabilities.tsv) — machine-scoped keys keep worktree-local wins.
#
# Covers:
#   (1) no config.local anywhere ⇒ effective config byte-identical to the committed baseline; the
#       committed file itself is never mutated.
#   (2) MAIN checkout's config.local sets a POLICY key (HEALTHCHECK_CMD) ⇒ a worktree with NO overlay
#       of its own sees it; a MACHINE key (MODEL_QUICK) set alongside it does NOT reach the worktree.
#   (3) the worktree gets its OWN config.local ⇒ for the MACHINE key, worktree-local wins over both the
#       baseline and the main checkout's overlay; for the POLICY key, the MAIN checkout's overlay is
#       the OUTERMOST layer and wins even over the worktree's own.
#   (4) the git-common-dir fallback (no committed PROJECT_ROOT at all) resolves the main checkout the
#       same way — never by string-guessing the worktree's path.
#   (5) running the loader FROM the main checkout itself is unaffected (its own overlay block already
#       covers it; the new cross-worktree layer is a no-op there).
#
# Fully hermetic: real (temp) git repos + `git worktree add`, no herdr/gh/network/model.
# Run:  bash tests/test-config-override-total.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LOADER="$ROOT/scripts/herd/herd-config.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { PASS=$((PASS+1)); }

# dump <config-file> — source the loader (under `set -euo pipefail`, matching healthcheck.sh's real
# invocation) with HERD_CONFIG_FILE=<config-file> and print the two probed keys.
dump() {
  local cfg="$1"
  ( HERD_CONFIG_FILE="$cfg" bash -c '
      set -euo pipefail
      cd "'"$T"'"
      . "'"$LOADER"'"
      echo "HEALTHCHECK_CMD=$HEALTHCHECK_CMD"
      echo "MODEL_QUICK=$MODEL_QUICK"
    ' )
}

_mk_main() {
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" config user.email t@t.t
  git -C "$dir" config user.name t
}

# ══════════════════════════════════════════════════════════════════════════════
# Fixture A — a worktree pool with PROJECT_ROOT committed (the common case).
# ══════════════════════════════════════════════════════════════════════════════
MAIN="$T/proj"; _mk_main "$MAIN"
MAIN_REAL="$(cd "$MAIN" && pwd -P)"
mkdir -p "$MAIN/.herd"
cat > "$MAIN/.herd/config" <<CFG
PROJECT_ROOT="$MAIN_REAL"
WORKTREES_DIR="$MAIN_REAL-trees"
HEALTHCHECK_CMD=""
MODEL_QUICK="claude-baseline"
CFG
( cd "$MAIN" && git add .herd/config && git commit -q -m init )
BASELINE_CKSUM="$(cksum "$MAIN/.herd/config")"

WT="$MAIN_REAL-trees/slug1"
mkdir -p "$(dirname "$WT")"
git -C "$MAIN" worktree add -q "$WT" -b feat/slug1 >/dev/null 2>&1 \
  || fail "setup: could not create fixture worktree"
[ ! -f "$WT/.herd/config.local" ] || fail "setup: fixture worktree unexpectedly has its own config.local"

# (1) No config.local anywhere ⇒ byte-identical to the committed baseline; baseline untouched.
out1="$(dump "$WT/.herd/config")"
grep -qx 'HEALTHCHECK_CMD=' <<< "$out1"                || fail "(1) baseline HEALTHCHECK_CMD not effective ($out1)"
grep -qx 'MODEL_QUICK=claude-baseline' <<< "$out1"     || fail "(1) baseline MODEL_QUICK not effective ($out1)"
[ "$(cksum "$MAIN/.herd/config")" = "$BASELINE_CKSUM" ] || fail "(1) committed config was mutated"
pass

# (2) MAIN checkout's config.local sets a POLICY key + a MACHINE key; worktree has no overlay of its
# own ⇒ the policy key reaches the worktree, the machine key does NOT.
cat > "$MAIN/.herd/config.local" <<CFG
HEALTHCHECK_CMD="true"
MODEL_QUICK="claude-main-machine"
CFG
out2="$(dump "$WT/.herd/config")"
grep -qx 'HEALTHCHECK_CMD=true' <<< "$out2" \
  || fail "(2) policy key from the MAIN checkout's config.local did not reach the worktree ($out2)"
grep -qx 'MODEL_QUICK=claude-baseline' <<< "$out2" \
  || fail "(2) machine key leaked from the MAIN checkout's config.local into the worktree ($out2)"
pass

# (3) The worktree now gets its OWN config.local, setting BOTH keys differently again.
#     Machine key: worktree-local wins over baseline AND the main checkout's overlay.
#     Policy key:  the MAIN checkout's overlay is the OUTERMOST layer — it wins even over the
#                  worktree's own.
mkdir -p "$WT/.herd"
cat > "$WT/.herd/config.local" <<CFG
MODEL_QUICK="claude-worktree-own"
HEALTHCHECK_CMD="false"
CFG
out3="$(dump "$WT/.herd/config")"
grep -qx 'MODEL_QUICK=claude-worktree-own' <<< "$out3" \
  || fail "(3) worktree-local machine key did not win over the main checkout's overlay ($out3)"
grep -qx 'HEALTHCHECK_CMD=true' <<< "$out3" \
  || fail "(3) MAIN checkout's config.local did not win over the worktree's own for a policy key ($out3)"
pass

[ "$(cksum "$MAIN/.herd/config")" = "$BASELINE_CKSUM" ] || fail "committed config mutated by (2)/(3)"

# ══════════════════════════════════════════════════════════════════════════════
# Fixture B — no committed PROJECT_ROOT: the main checkout must resolve via git's own worktree list
# (git-common-dir), never by string-guessing the worktree's path.
# ══════════════════════════════════════════════════════════════════════════════
MAIN2="$T/proj2"; _mk_main "$MAIN2"
mkdir -p "$MAIN2/.herd"
cat > "$MAIN2/.herd/config" <<CFG
HEALTHCHECK_CMD=""
CFG
( cd "$MAIN2" && git add .herd/config && git commit -q -m init )
WT2="$T/proj2-trees/slug2"
mkdir -p "$(dirname "$WT2")"
git -C "$MAIN2" worktree add -q "$WT2" -b feat/slug2 >/dev/null 2>&1 \
  || fail "setup: could not create fixture-B worktree"
cat > "$MAIN2/.herd/config.local" <<CFG
HEALTHCHECK_CMD="true"
CFG
out4="$(dump "$WT2/.herd/config")"
grep -qx 'HEALTHCHECK_CMD=true' <<< "$out4" \
  || fail "(4) git-common-dir fallback (no committed PROJECT_ROOT) did not resolve the main checkout ($out4)"
pass

# ══════════════════════════════════════════════════════════════════════════════
# (5) A run FROM the main checkout itself is unaffected — its own overlay block above already applies
# config.local; the new cross-worktree layer must be a no-op there (byte-identical, no double-apply).
# ══════════════════════════════════════════════════════════════════════════════
out5="$(dump "$MAIN/.herd/config")"
grep -qx 'HEALTHCHECK_CMD=true' <<< "$out5" \
  || fail "(5) main-checkout run lost its own config.local effect ($out5)"
pass

echo "ALL PASS ($PASS checks)"
