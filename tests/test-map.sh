#!/usr/bin/env bash
# test-map.sh — hermetic test for the `herd map` subcommand (bin/herd → cmd_map).
#
# `herd map` RENDERS the committed operator-facing docs/control-room-map.md (glow if available,
# else cat; fail-soft). It is deliberately DISTINCT from `herd codemap`, which regenerates a
# scanned artifact. This asserts the contract from HERD-148:
#   • the subcommand runs (exit 0) and prints the doc's content
#   • the printed map covers the pipeline stages (coordinator → lanes → gates → verdict → merge →
#     reconcile) plus bug routing, the async lanes, and the safety rails
#   • it fails soft when glow is absent (a forced no-glow PATH still renders via cat, exit 0)
#   • it is READ-ONLY — rendering the doc never modifies it
#   • a missing doc dies cleanly (non-zero) rather than printing nothing silently
#
# Run:  bash tests/test-map.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
HERD="$HERE/../bin/herd"
DOC="$HERE/../docs/control-room-map.md"

fail(){ echo "FAIL: $1" >&2; exit 1; }
pass=0; ok(){ pass=$((pass+1)); }

[ -f "$HERD" ] || fail "bin/herd not found at $HERD"
[ -f "$DOC" ]  || fail "docs/control-room-map.md not found at $DOC"

# All scratch dirs cleaned by one trap (a second `trap … EXIT` would clobber the first).
STUB="$(mktemp -d)"; TMPROOT="$(mktemp -d)"
trap 'rm -rf "$STUB" "$TMPROOT"' EXIT

# grep helper that tolerates glow's ANSI wrapping: strip escape sequences before matching, so the
# assertions hold whether the render went through glow or the plain cat fallback.
plain(){ sed 's/\x1b\[[0-9;]*m//g'; }

# ── 1. The subcommand runs and prints the doc ────────────────────────────────────────────────────
out="$(bash "$HERD" map </dev/null 2>/dev/null)" || fail "herd map exited non-zero"
[ -n "$out" ]                                     || fail "herd map printed nothing"
printf '%s' "$out" | plain | grep -q 'control-room map' || fail "output missing the doc title"
ok

# ── 2. Covers the pipeline stages + routing + async lanes + rails ────────────────────────────────
clean="$(printf '%s' "$out" | plain)"
for needle in coordinator builder worktree healthcheck review "merge policy" reconcile \
              "APP" "HERD-ENGINE" scribe research "safety rail"; do
  printf '%s' "$clean" | grep -qi -- "$needle" || fail "map does not cover: $needle"
done
# the PASS/BLOCK/refix verdict branches are the heart of the decision graph
printf '%s' "$clean" | grep -q 'PASS'  || fail "map missing the PASS verdict branch"
printf '%s' "$clean" | grep -q 'BLOCK' || fail "map missing the BLOCK verdict branch"
ok

# ── 3. Fail-soft: a broken glow degrades to cat (exit 0), never a crash ───────────────────────────
# Shadow glow with a stub that ALWAYS fails (simulating a terminal-capability probe blowing up),
# prepended to the real PATH so every OTHER tool the CLI needs still resolves. cmd_map must catch
# the failure, warn, and fall back to cat — still exit 0, still print the doc.
printf '#!/usr/bin/env bash\nexit 1\n' > "$STUB/glow"; chmod +x "$STUB/glow"
out_nogl="$(PATH="$STUB:$PATH" bash "$HERD" map </dev/null 2>/dev/null)" \
  || fail "herd map failed when glow errored — not fail-soft"
printf '%s' "$out_nogl" | plain | grep -q 'control-room map' || fail "cat fallback did not print the doc"
ok

# ── 4. Read-only: rendering never mutates the doc ────────────────────────────────────────────────
before="$(cksum < "$DOC")"
bash "$HERD" map </dev/null >/dev/null 2>&1 || fail "second herd map run failed"
after="$(cksum < "$DOC")"
[ "$before" = "$after" ] || fail "herd map modified docs/control-room-map.md — must be read-only"
ok

# ── 5. Missing doc dies cleanly (non-zero), never silent ─────────────────────────────────────────
# Point HERDKIT_HOME at a home with no docs/control-room-map.md by copying bin/ into a temp root.
mkdir -p "$TMPROOT/bin" "$TMPROOT/scripts"
cp "$HERD" "$TMPROOT/bin/herd"
cp -r "$HERE/../scripts/herd" "$TMPROOT/scripts/herd"
if "$TMPROOT/bin/herd" map </dev/null >/dev/null 2>&1; then
  fail "herd map should exit non-zero when the doc is missing"
fi
ok

echo "PASS: test-map.sh ($pass assertions)"
