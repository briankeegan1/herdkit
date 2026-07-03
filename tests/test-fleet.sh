#!/usr/bin/env bash
# test-fleet.sh — hermetic tests for `herd fleet` (P0 deterministic multi-project fan-out).
#
# Design principles (mirror test-cli-update.sh):
#   • Fully hermetic: a temp HERD_FLEET_FILE registry, temp fake projects each with their own
#     .herd/config + .herd journal, and a temp $HOME so the default ~/.herd/fleet is never touched.
#   • gh / pgrep / ps are STUBBED on PATH so status renders deterministically with no network and
#     no dependence on real running watchers.
#   • The upgrade/reload fan-out is pointed at a STUB herd binary (HERD_FLEET_HERD_BIN) that emits
#     deterministic per-project outcomes — so the test exercises the fan-out + outcome collection
#     without running a real engine pull/reload.
#
# Run:  bash tests/test-fleet.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
HERD="$HERE/../bin/herd"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass=0
ok(){ pass=$((pass+1)); }

# ── Stubs on PATH ────────────────────────────────────────────────────────────
BIN="$T/bin"; mkdir -p "$BIN"

# gh stub: `gh pr list --state open --json number --jq 'length'` → a fixed count.
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
echo 2
STUB
chmod +x "$BIN/gh"

# pgrep stub: emit a fake PID only for alpha's watcher marker (so alpha reads 'alive', beta 'down').
cat > "$BIN/pgrep" <<'STUB'
#!/usr/bin/env bash
# invoked as: pgrep -f herd-watch-<slug>
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

# Isolate HOME so the default ~/.herd/fleet path is a temp one even if a subcommand ignores the seam.
export HOME="$T/home"; mkdir -p "$HOME"

# ── Registry seam + a fake 2-project fleet ───────────────────────────────────
export HERD_FLEET_FILE="$T/registry/fleet"

# _make_project <name> [extra-config-lines...] — real git repo + .herd/config + a journal event.
_make_project() {
  local name="$1"; shift
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
  for line in "$@"; do printf '%s\n' "$line" >> "$root/.herd/config"; done
  # Seed one journal event so 'last activity' has something to render.
  printf '{"ts":"2026-07-03T10:00:00Z","event":"merge","pr":7}\n' \
    > "$root_real-trees/.herd/journal.jsonl"
  printf '%s' "$root_real"
}

ALPHA="$(_make_project alpha)"
BETA="$(_make_project beta)"

# ── 1. register + list roundtrip ─────────────────────────────────────────────
bash "$HERD" fleet register "$ALPHA" >/dev/null
bash "$HERD" fleet register "$BETA"  >/dev/null
out="$(bash "$HERD" fleet list)"
printf '%s' "$out" | grep -q "alpha" || fail "list missing registered project alpha"
printf '%s' "$out" | grep -q "beta"  || fail "list missing registered project beta"
printf '%s' "$out" | grep -q "me/alpha" || fail "list missing alpha's repo"
grep -q "^alpha|$ALPHA|me/alpha$" "$HERD_FLEET_FILE" \
  || fail "registry line for alpha not in name|path|repo form"
ok

# ── 2. register is idempotent (re-register does not duplicate) ────────────────
bash "$HERD" fleet register "$ALPHA" >/dev/null
n="$(grep -c "^alpha|" "$HERD_FLEET_FILE" || true)"
[ "$n" = "1" ] || fail "re-registering alpha duplicated its record ($n rows)"
ok

# ── 3. register refuses a non-herd dir ───────────────────────────────────────
mkdir -p "$T/notaproj"
if bash "$HERD" fleet register "$T/notaproj" >/dev/null 2>&1; then
  fail "register should refuse a dir with no .herd/config"
fi
ok

# ── 4. status renders a per-project row for each project ─────────────────────
out="$(bash "$HERD" fleet status)"
printf '%s' "$out" | grep -q "PROJECT" || fail "status missing header row"
printf '%s' "$out" | grep -q "alpha" || fail "status missing alpha row"
printf '%s' "$out" | grep -q "beta"  || fail "status missing beta row"
# branch, PR count, and last journal activity render per project.
printf '%s' "$out" | grep -q "feat/alpha" || fail "status missing alpha's branch"
printf '%s' "$out" | grep -qi "merge" || fail "status missing last journal activity"
ok

# ── 5. watcher liveness: alpha alive (stubbed pgrep/ps), beta down ───────────
alpha_row="$(printf '%s' "$out" | grep '^alpha' || true)"
beta_row="$(printf '%s' "$out" | grep '^beta' || true)"
printf '%s' "$alpha_row" | grep -qi "alive" || fail "alpha's watcher should read alive (stubbed)"
printf '%s' "$beta_row"  | grep -qi "down"  || fail "beta's watcher should read down"
ok

# ── 6. status open-PR count uses gh (stubbed to 2) ───────────────────────────
printf '%s' "$alpha_row" | grep -q "2" || fail "status should show gh's open-PR count (2)"
ok

# ── 7. discover finds projects under a root ──────────────────────────────────
out="$(bash "$HERD" fleet discover "$T/proj")"
printf '%s' "$out" | grep -q "alpha" || fail "discover missed alpha under root"
printf '%s' "$out" | grep -q "beta"  || fail "discover missed beta under root"
printf '%s' "$out" | grep -q "2 project(s) found" || fail "discover count wrong"
ok

# ── 8. discover --register into a fresh registry ─────────────────────────────
HERD_FLEET_FILE="$T/registry2/fleet" bash "$HERD" fleet discover --register "$T/proj" >/dev/null
grep -q "^alpha|" "$T/registry2/fleet" || fail "discover --register did not add alpha"
grep -q "^beta|"  "$T/registry2/fleet" || fail "discover --register did not add beta"
ok

# ── 9. upgrade fan-out collects a per-project outcome (ok + failed) ──────────
STUB="$T/herd-stub"
cat > "$STUB" <<'STUB'
#!/usr/bin/env bash
# Deterministic per-project outcome: alpha succeeds, beta fails (as the dirty-tree guard would).
case "$PWD" in
  *alpha) echo "reload complete"; exit 0 ;;
  *beta)  echo "refusing to pull over a dirty engine checkout"; exit 1 ;;
  *)      echo "ok"; exit 0 ;;
esac
STUB
chmod +x "$STUB"

set +e
out="$(HERD_FLEET_HERD_BIN="$STUB" bash "$HERD" fleet upgrade)"; rc=$?
set -e
printf '%s' "$out" | grep -q "alpha" || fail "upgrade missing alpha outcome"
printf '%s' "$out" | grep -q "beta"  || fail "upgrade missing beta outcome"
printf '%s' "$out" | grep -Eq "alpha.*ok"      || fail "alpha should report ok"
printf '%s' "$out" | grep -Eq "beta.*failed"   || fail "beta should report failed"
printf '%s' "$out" | grep -q "1 ok"     || fail "upgrade summary should tally 1 ok"
printf '%s' "$out" | grep -q "1 failed" || fail "upgrade summary should tally 1 failed"
[ "$rc" -ne 0 ] || fail "upgrade should exit non-zero when a project failed"
ok

# ── 10. a MISSING project is reported (skipped), not fatal ───────────────────
printf 'ghost|%s/proj/ghost|me/ghost\n' "$T" >> "$HERD_FLEET_FILE"
set +e
out="$(HERD_FLEET_HERD_BIN="$STUB" bash "$HERD" fleet upgrade)"; rc=$?
set -e
printf '%s' "$out" | grep -Eq "ghost.*skipped" || fail "missing project should be reported as skipped"
printf '%s' "$out" | grep -q "alpha" || fail "fan-out should continue past a missing project (alpha)"
printf '%s' "$out" | grep -q "1 skipped" || fail "summary should tally the skipped project"
ok

# ── 11. reload fan-out delegates to 'herd reload' too ────────────────────────
# Restore a clean 2-project registry (drop the ghost) so this exercises the happy path.
grep -v '^ghost|' "$HERD_FLEET_FILE" > "$HERD_FLEET_FILE.tmp" && mv "$HERD_FLEET_FILE.tmp" "$HERD_FLEET_FILE"
cat > "$STUB" <<'STUB'
#!/usr/bin/env bash
echo "reloaded ($1) in $PWD"; exit 0
STUB
chmod +x "$STUB"
out="$(HERD_FLEET_HERD_BIN="$STUB" bash "$HERD" fleet reload)"
printf '%s' "$out" | grep -q "reloaded (reload)" || fail "reload should delegate the 'reload' subcommand"
printf '%s' "$out" | grep -q "2 ok" || fail "reload summary should tally 2 ok"
ok

# ── 12. empty registry is a friendly note, not a crash ───────────────────────
out="$(HERD_FLEET_FILE="$T/none/fleet" bash "$HERD" fleet list)"
printf '%s' "$out" | grep -qi "no fleet registry\|register" || fail "empty registry list should hint how to add a project"
out="$(HERD_FLEET_FILE="$T/none/fleet" bash "$HERD" fleet status)"
printf '%s' "$out" | grep -qi "no fleet registry\|PROJECT" || fail "empty registry status should not crash"
ok

# ── 13. unknown subcommand fails loudly ──────────────────────────────────────
if bash "$HERD" fleet bogus >/dev/null 2>&1; then
  fail "unknown fleet subcommand should exit non-zero"
fi
ok

echo "ALL PASS ($pass checks)"
