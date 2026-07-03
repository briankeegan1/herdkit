#!/usr/bin/env bash
# test-fleet-governance.sh — hermetic tests for `herd fleet` P4: policy propagation (`fleet set`)
# and the global-concurrency GOVERNANCE view (`fleet governance`).
#
# Design principles (mirror test-fleet.sh):
#   • Fully hermetic: a temp HERD_FLEET_FILE registry, temp fake projects each with their own
#     .herd/config, and a temp $HOME so the default ~/.herd/fleet is never touched.
#   • pgrep/ps are STUBBED on PATH so the governance watcher column renders deterministically with no
#     dependence on real running watchers.
#   • `fleet set` fans out to a STUB herd binary (HERD_FLEET_HERD_BIN) that RECORDS the exact argv it
#     was handed per project and emits a deterministic outcome — so the test proves each project's
#     `herd config set KEY VALUE` was invoked and the outcomes roll up, without a real engine/config.
#   • Governance counts come from real git worktrees (builders) + seeded .review-inflight markers
#     with a LIVE pid (reviews) — exactly the watcher/agent state the view aggregates.
#
# Run:  bash tests/test-fleet-governance.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
HERD="$HERE/../bin/herd"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass=0
ok(){ pass=$((pass+1)); }

# ── Stubs on PATH ────────────────────────────────────────────────────────────
BIN="$T/bin"; mkdir -p "$BIN"

# pgrep stub: emit a fake PID only for alpha's watcher marker (alpha reads 'alive', beta 'down').
cat > "$BIN/pgrep" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in herd-watch-alpha) echo 4242 ;; esac; done
exit 0
STUB
chmod +x "$BIN/pgrep"

# ps stub: `ps -o args= -p 4242` → alpha's argv0 marker; anything else empty.
cat > "$BIN/ps" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in 4242) echo "herd-watch-alpha" ;; esac; done
exit 0
STUB
chmod +x "$BIN/ps"

export PATH="$BIN:$PATH"
export HOME="$T/home"; mkdir -p "$HOME"
export HERD_FLEET_FILE="$T/registry/fleet"

# ── A fake 2-project fleet ───────────────────────────────────────────────────
# _make_project <name> — real git repo + .herd/config; prints the resolved PROJECT_ROOT.
_make_project() {
  local name="$1"
  local root="$T/proj/$name"
  mkdir -p "$root/.herd" "$T/proj/$name-trees/.herd"
  git -C "$root" init -q
  git -C "$root" config user.email t@t.t
  git -C "$root" config user.name t
  ( cd "$root" && git commit -q --allow-empty -m init && git branch -M "feat/$name" )
  local root_real; root_real="$(cd "$root" && pwd -P)"
  cat > "$root/.herd/config" <<CFG
PROJECT_ROOT="$root_real"
WORKTREES_DIR="$root_real-trees"
DEFAULT_BRANCH="origin/main"
WORKSPACE_NAME="$name"
HERD_REPO="me/$name"
CFG
  printf '%s' "$root_real"
}

ALPHA="$(_make_project alpha)"
BETA="$(_make_project beta)"
bash "$HERD" fleet register "$ALPHA" >/dev/null
bash "$HERD" fleet register "$BETA"  >/dev/null

# ── fleet set: a stub herd that records argv + emits a deterministic outcome ──
# alpha succeeds; beta fails (as `herd config set` would on an invalid value / unknown key).
STUB="$T/herd-stub"
cat > "$STUB" <<STUB_EOF
#!/usr/bin/env bash
# Record the exact argv handed to this project's herd (so the test can prove the delegation).
printf '%s\n' "\$*" >> "\$PWD/.herd/fleet-set-argv"
case "\$PWD" in
  *alpha) echo "set \$2 = \\"\$3\\" in .herd/config"; exit 0 ;;
  *beta)  echo "unknown config key '\$2' — see 'herd config list'"; exit 1 ;;
  *)      echo "ok"; exit 0 ;;
esac
STUB_EOF
chmod +x "$STUB"

# ── 1. fleet set delegates 'herd config set KEY VALUE' into every project ─────
set +e
out="$(HERD_FLEET_HERD_BIN="$STUB" bash "$HERD" fleet set MERGE_POLICY approve)"; rc=$?
set -e
printf '%s' "$out" | grep -q "config set" \
  || fail "fleet set header should show the delegated 'herd config set' command"
grep -qx "config set MERGE_POLICY approve" "$ALPHA/.herd/fleet-set-argv" \
  || fail "alpha's herd config set was not invoked with KEY VALUE"
grep -qx "config set MERGE_POLICY approve" "$BETA/.herd/fleet-set-argv" \
  || fail "beta's herd config set was not invoked with KEY VALUE"
ok

# ── 2. fleet set rolls up per-project outcomes (ok + failed) + tallies ────────
printf '%s' "$out" | grep -Eq "alpha.*ok"     || fail "alpha should report ok"
printf '%s' "$out" | grep -Eq "beta.*failed"  || fail "beta should report failed"
printf '%s' "$out" | grep -q "1 ok"     || fail "fleet set summary should tally 1 ok"
printf '%s' "$out" | grep -q "1 failed" || fail "fleet set summary should tally 1 failed"
[ "$rc" -ne 0 ] || fail "fleet set should exit non-zero when a project's set failed"
ok

# ── 3. fleet set: an unreachable project is reported (skipped), not fatal ─────
printf 'ghost|%s/proj/ghost|me/ghost\n' "$T" >> "$HERD_FLEET_FILE"
set +e
out="$(HERD_FLEET_HERD_BIN="$STUB" bash "$HERD" fleet set MERGE_POLICY approve)"; rc=$?
set -e
printf '%s' "$out" | grep -Eq "ghost.*skipped" || fail "unreachable project should be reported skipped"
printf '%s' "$out" | grep -q "alpha" || fail "fan-out should continue past the unreachable project"
printf '%s' "$out" | grep -q "1 skipped" || fail "summary should tally the skipped project"
# Drop the ghost so the governance section runs against the clean 2-project fleet.
grep -v '^ghost|' "$HERD_FLEET_FILE" > "$HERD_FLEET_FILE.tmp" && mv "$HERD_FLEET_FILE.tmp" "$HERD_FLEET_FILE"
ok

# ── 4. fleet set requires KEY and VALUE ──────────────────────────────────────
if HERD_FLEET_HERD_BIN="$STUB" bash "$HERD" fleet set MERGE_POLICY >/dev/null 2>&1; then
  fail "fleet set with no VALUE should exit non-zero"
fi
ok

# ── Governance fixtures: real feature worktrees (builders) + review markers ───
# alpha: 2 builders (2 feature worktrees) + 1 live review.  beta: 1 builder + 0 reviews.
git -C "$ALPHA" worktree add -q -b feat/a1 "$ALPHA-trees/a1" >/dev/null 2>&1
git -C "$ALPHA" worktree add -q -b feat/a2 "$ALPHA-trees/a2" >/dev/null 2>&1
git -C "$BETA"  worktree add -q -b feat/b1 "$BETA-trees/b1"  >/dev/null 2>&1
# A live reviewer pid: this test process is alive for the duration, so kill -0 succeeds.
printf '%s\n' "$$" > "$ALPHA-trees/.review-inflight-11-deadbeef"
# A DEAD reviewer marker must NOT be counted (pid 999999 is not running).
printf '999999\n'   > "$ALPHA-trees/.review-inflight-12-cafef00d"

# ── 5. governance renders a per-project row with builder + review counts ──────
out="$(bash "$HERD" fleet governance)"
printf '%s' "$out" | grep -q "PROJECT"  || fail "governance missing header row"
printf '%s' "$out" | grep -q "BUILDERS" || fail "governance missing BUILDERS column"
printf '%s' "$out" | grep -q "REVIEWS"  || fail "governance missing REVIEWS column"
alpha_row="$(printf '%s' "$out" | grep '^alpha' || true)"
beta_row="$(printf '%s' "$out" | grep '^beta' || true)"
# alpha: 2 builders, 1 live review (the dead marker is excluded), 3 in-flight.
printf '%s' "$alpha_row" | grep -Eq '^alpha +2 +1 +3' \
  || fail "alpha row should read builders=2 reviews=1 in-flight=3 (got: $alpha_row)"
# beta: 1 builder, 0 reviews, 1 in-flight.
printf '%s' "$beta_row" | grep -Eq '^beta +1 +0 +1' \
  || fail "beta row should read builders=1 reviews=0 in-flight=1 (got: $beta_row)"
ok

# ── 6. governance sums the fleet-wide in-flight total ────────────────────────
# 3 builders (2+1) + 1 review = 4 in-flight across 2 projects.
printf '%s' "$out" | grep -q "4 in-flight" || fail "fleet total should be 4 in-flight"
printf '%s' "$out" | grep -q "3 builder"   || fail "fleet total should sum 3 builders"
printf '%s' "$out" | grep -q "1 review"    || fail "fleet total should sum 1 review"
printf '%s' "$out" | grep -q "2 project"   || fail "fleet total should count 2 projects"
ok

# ── 7. governance watcher column: alpha alive (stubbed), beta down ───────────
printf '%s' "$alpha_row" | grep -qi "alive" || fail "alpha's watcher should read alive (stubbed)"
printf '%s' "$beta_row"  | grep -qi "down"  || fail "beta's watcher should read down"
ok

# ── 8. soft cap warning fires when in-flight ≥ cap (warn → stderr) ────────────
# Fleet in-flight is 4; a cap of 3 should trip the account-wide-limit warning.
errout="$(HERD_FLEET_INFLIGHT_SOFTCAP=3 bash "$HERD" fleet governance 2>&1 >/dev/null)"
printf '%s' "$errout" | grep -qi "soft cap\|account-wide" || fail "soft cap should warn when in-flight ≥ cap"
# A high cap must NOT warn.
errout="$(HERD_FLEET_INFLIGHT_SOFTCAP=99 bash "$HERD" fleet governance 2>&1 >/dev/null)"
printf '%s' "$errout" | grep -qi "soft cap" && fail "soft cap should not warn when in-flight < cap"
ok

# ── 9. governance: an unreachable project is reported, not fatal ─────────────
printf 'ghost|%s/proj/ghost|me/ghost\n' "$T" >> "$HERD_FLEET_FILE"
set +e
out="$(bash "$HERD" fleet governance)"; rc=$?
set -e
[ "$rc" -eq 0 ] || fail "governance should not fail on an unreachable project"
printf '%s' "$out" | grep -Eq "ghost.*unreachable" || fail "unreachable project should be reported"
printf '%s' "$out" | grep -q "1 unreachable" || fail "fleet summary should count the unreachable project"
printf '%s' "$out" | grep -q "alpha" || fail "governance should still render reachable projects"
grep -v '^ghost|' "$HERD_FLEET_FILE" > "$HERD_FLEET_FILE.tmp" && mv "$HERD_FLEET_FILE.tmp" "$HERD_FLEET_FILE"
ok

# ── 10. empty registry is a friendly note, not a crash ───────────────────────
out="$(HERD_FLEET_FILE="$T/none/fleet" bash "$HERD" fleet governance)"
printf '%s' "$out" | grep -qi "no fleet registry\|register" \
  || fail "empty-registry governance should hint how to add a project"
ok

# ── 11. governance --help prints usage without touching the registry ─────────
out="$(bash "$HERD" fleet governance --help)"
printf '%s' "$out" | grep -qi "GLOBAL CONCURRENCY\|in-flight" || fail "governance --help should describe the view"
ok

echo "ALL PASS ($pass checks)"
