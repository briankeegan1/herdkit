#!/usr/bin/env bash
# test-init-grounding-interview.sh — hermetic tests for the HERD-80 `herd init` GROUNDING INTERVIEW:
# after the scout, init OFFERS builder grounding (codemap + CONTEXT_PROVISION), coordinator tooling
# (graphify + GRAPHIFY_BIN), builder MCP wiring (MCP_PROVISION), and SURFACES the efficiency levers —
# suggest-never-auto-write, applied ONLY on an explicit yes via the validated `herd config set`.
#
# NO network, NO gh, NO herdr, NO claude, NO model call: init runs with HERD_SKIP_DOCTOR=1
# HERD_SKIP_GH_DETECT=1 against throwaway git repos. The interview is driven hermetically via the
# HERD_GROUND_ASSUME_TTY seam (which makes _ground_ask read scripted stdin without a real TTY).
# Asserts:
#   (1) NON-TTY scripted init (HERD_NONINTERACTIVE=1) → ZERO grounding prompts, nothing written.
#   (2) YES path → CONTEXT_PROVISION=codemap + docs/codemap.md written; GRAPHIFY_BIN in the gitignored
#       .herd/config.local (machine-scoped, NOT the committed baseline); MCP_PROVISION set in baseline.
#   (3) NO path (blank/n answers, graphify absent) → prompts shown + install hint, but NOTHING written.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
HERD="$REPO/bin/herd"
export HERD

command -v git >/dev/null 2>&1 || { echo "FAIL: git required" >&2; exit 1; }
REAL_BASH="$(command -v bash)"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

# A fake `graphify` on PATH so the tooling offer's "found" branch is exercised without the real binary.
FAKEBIN="$T/bin"; mkdir -p "$FAKEBIN"
printf '#!/bin/sh\nexit 0\n' > "$FAKEBIN/graphify"; chmod +x "$FAKEBIN/graphify"

# mkproj <dir> <marker> — a throwaway git repo with the given stack marker + a trivial source file.
mkproj() {
  local d="$1" marker="$2"
  rm -rf "$d"; mkdir -p "$d"
  git -C "$d" init -q
  git -C "$d" config user.email t@t.t; git -C "$d" config user.name t
  [ -n "$marker" ] && : > "$d/$marker"
  printf 'export const x = 1\n' > "$d/index.js"
  git -C "$d" add -A 2>/dev/null || true
  git -C "$d" commit -q --allow-empty -m init
}

# ── (1) NON-TTY scripted init: the interview is skipped cleanly — zero prompts, nothing written ────
proj="$T/noninteractive"; mkproj "$proj" "package.json"
out="$( cd "$proj" && HERD_NONINTERACTIVE=1 HERD_SKIP_DOCTOR=1 HERD_SKIP_GH_DETECT=1 \
        "$REAL_BASH" "$HERD" init 2>&1 )" || fail "(1) init failed: $out"
echo "$out" | grep -q "Grounding & tooling"            && fail "(1) non-tty init must print ZERO grounding prompts"
echo "$out" | grep -q "CONTEXT_PROVISION=codemap"      && fail "(1) non-tty init must not offer/set CONTEXT_PROVISION"
grep -qE '^CONTEXT_PROVISION=' "$proj/.herd/config"    && fail "(1) non-tty init must not write CONTEXT_PROVISION"
grep -qE '^MCP_PROVISION=' "$proj/.herd/config"        && fail "(1) non-tty init must not write MCP_PROVISION"
[ -e "$proj/.herd/config.local" ]                      && fail "(1) non-tty init must not create .herd/config.local"
[ -e "$proj/docs/codemap.md" ]                         && fail "(1) non-tty init must not generate a codemap"
ok

# ── (2) YES path: every offer accepted → validated writes land where they belong ──────────────────
proj="$T/yes"; mkproj "$proj" "package.json"
out="$( cd "$proj" && printf 'y\ny\ncontext7\n' \
        | PATH="$FAKEBIN:$PATH" HERD_GROUND_ASSUME_TTY=1 HERD_SKIP_DOCTOR=1 HERD_SKIP_GH_DETECT=1 \
          "$REAL_BASH" "$HERD" init 2>&1 )" || fail "(2) init failed: $out"
echo "$out" | grep -q "Grounding & tooling"                 || fail "(2) grounding interview should run under HERD_GROUND_ASSUME_TTY"
# (a) codemap grounding — map generated + CONTEXT_PROVISION pointed at it, in the COMMITTED baseline.
[ -f "$proj/docs/codemap.md" ]                              || fail "(2) yes → docs/codemap.md must be generated"
grep -qE '^CONTEXT_PROVISION="codemap"$' "$proj/.herd/config" || fail "(2) yes → CONTEXT_PROVISION=codemap in baseline: $(grep CONTEXT_PROVISION "$proj/.herd/config" 2>/dev/null)"
# (b) graphify — GRAPHIFY_BIN is machine-scoped, so it routes to the gitignored overlay, NOT baseline.
[ -f "$proj/.herd/config.local" ]                           || fail "(2) yes → .herd/config.local must be created for the machine-scoped GRAPHIFY_BIN"
grep -qE "^GRAPHIFY_BIN=\"$FAKEBIN/graphify\"$" "$proj/.herd/config.local" || fail "(2) yes → GRAPHIFY_BIN must land in .herd/config.local: $(grep GRAPHIFY_BIN "$proj/.herd/config.local" 2>/dev/null)"
grep -qE '^[[:space:]]*GRAPHIFY_BIN=' "$proj/.herd/config"  && fail "(2) yes → GRAPHIFY_BIN must NOT be written to the committed baseline (machine-scoped)"
grep -qxF '.herd/config.local' "$proj/.gitignore"           || fail "(2) yes → .herd/config.local must be gitignored so the per-machine path never commits"
# (c) MCP — committed baseline.
grep -qE '^MCP_PROVISION="context7"$' "$proj/.herd/config"  || fail "(2) yes → MCP_PROVISION=context7 in baseline: $(grep MCP_PROVISION "$proj/.herd/config" 2>/dev/null)"
# (d) efficiency levers are SURFACED (never written).
echo "$out" | grep -q "Efficiency levers"                   || fail "(2) efficiency levers should be surfaced"
grep -qE '^REVIEW_ESCALATE_GLOB=' "$proj/.herd/config"      && fail "(2) surface-only levers must never be auto-written (REVIEW_ESCALATE_GLOB)"
ok

# ── (3) NO path: prompts shown, graphify absent → install hint; nothing written ───────────────────
SAFE="/usr/bin:/bin:/usr/sbin:/sbin"
proj="$T/no"; mkproj "$proj" "package.json"
out="$( cd "$proj" && printf 'n\n\n' \
        | PATH="$SAFE" HERD_GROUND_ASSUME_TTY=1 HERD_SKIP_DOCTOR=1 HERD_SKIP_GH_DETECT=1 \
          "$REAL_BASH" "$HERD" init 2>&1 )" || fail "(3) init failed: $out"
echo "$out" | grep -q "Grounding & tooling"                 || fail "(3) grounding interview should run (prompts shown)"
echo "$out" | grep -q "pipx install graphifyy"              || fail "(3) graphify absent → PyPI install hint must be printed"
grep -qE '^CONTEXT_PROVISION=' "$proj/.herd/config"         && fail "(3) no → CONTEXT_PROVISION must not be written"
grep -qE '^MCP_PROVISION=' "$proj/.herd/config"             && fail "(3) no → MCP_PROVISION must not be written"
[ -e "$proj/.herd/config.local" ]                           && fail "(3) no → .herd/config.local must not be created"
[ -e "$proj/docs/codemap.md" ]                              && fail "(3) no → codemap must not be generated"
ok

echo "ALL PASS ($pass checks)"
