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
  # The TARGET's OWN origin remote — this (not HERD_REPO) is what the registry repo field must record
  # (issue #128). Deliberately DIFFERENT from the config's HERD_REPO below so the test proves the fix
  # resolves the remote, not the config value.
  git -C "$root" remote add origin "git@github.com:acme/$name.git"
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
grep -q "alpha" <<< "$out" || fail "list missing registered project alpha"
grep -q "beta" <<< "$out" || fail "list missing registered project beta"
# The registry repo field is the TARGET's own origin remote (acme/alpha), NOT its config HERD_REPO
# (me/alpha) — issue #128. Assert the remote won and HERD_REPO did NOT leak in.
grep -q "acme/alpha" <<< "$out" || fail "list missing alpha's repo (from its origin remote)"
grep -q "|me/alpha$" "$HERD_FLEET_FILE" && fail "config HERD_REPO leaked into the registry repo field"
grep -q "^alpha|$ALPHA|acme/alpha$" "$HERD_FLEET_FILE" \
  || fail "registry line for alpha not in name|path|repo form with the remote-derived repo"
ok

# ── 1b. register --alias (HERD-387): stored, listed, and preserved across a plain re-register ──
# Isolated registry — this must never perturb the exact 3-field row format the checks above and
# below assert for the shared $HERD_FLEET_FILE registry.
REG_ALIAS="$T/registry-alias/fleet"
HERD_FLEET_FILE="$REG_ALIAS" bash "$HERD" fleet register "$ALPHA" --alias alpha-svc --alias "Alpha Service" >/dev/null
grep -q "^alpha|$ALPHA|acme/alpha|alpha-svc,Alpha Service$" "$REG_ALIAS" \
  || fail "register --alias should append a comma-joined aliases field, got: $(grep '^alpha|' "$REG_ALIAS" || true)"
out="$(HERD_FLEET_FILE="$REG_ALIAS" bash "$HERD" fleet list)"
grep -q "alpha-svc" <<< "$out" || fail "list should surface a registered alias"
# A plain re-register (no --alias) must PRESERVE the existing aliases, not silently wipe them.
HERD_FLEET_FILE="$REG_ALIAS" bash "$HERD" fleet register "$ALPHA" >/dev/null
grep -q "^alpha|$ALPHA|acme/alpha|alpha-svc,Alpha Service$" "$REG_ALIAS" \
  || fail "a plain re-register must preserve alpha's existing aliases"
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
grep -q "PROJECT" <<< "$out" || fail "status missing header row"
grep -q "alpha" <<< "$out" || fail "status missing alpha row"
grep -q "beta" <<< "$out" || fail "status missing beta row"
# branch, PR count, and last journal activity render per project.
grep -q "feat/alpha" <<< "$out" || fail "status missing alpha's branch"
grep -qi "merge" <<< "$out" || fail "status missing last journal activity"
ok

# ── 5. watcher liveness: alpha alive (stubbed pgrep/ps), beta down ───────────
alpha_row="$(printf '%s' "$out" | grep '^alpha' || true)"
beta_row="$(printf '%s' "$out" | grep '^beta' || true)"
grep -qi "alive" <<< "$alpha_row" || fail "alpha's watcher should read alive (stubbed)"
grep -qi "down" <<< "$beta_row" || fail "beta's watcher should read down"
ok

# ── 6. status open-PR count uses gh (stubbed to 2) ───────────────────────────
grep -q "2" <<< "$alpha_row" || fail "status should show gh's open-PR count (2)"
ok

# ── 7. discover finds projects under a root ──────────────────────────────────
out="$(bash "$HERD" fleet discover "$T/proj")"
grep -q "alpha" <<< "$out" || fail "discover missed alpha under root"
grep -q "beta" <<< "$out" || fail "discover missed beta under root"
grep -q "2 project(s) found" <<< "$out" || fail "discover count wrong"
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
grep -q "alpha" <<< "$out" || fail "upgrade missing alpha outcome"
grep -q "beta" <<< "$out" || fail "upgrade missing beta outcome"
grep -Eq "alpha.*ok" <<< "$out" || fail "alpha should report ok"
grep -Eq "beta.*failed" <<< "$out" || fail "beta should report failed"
grep -q "1 ok" <<< "$out" || fail "upgrade summary should tally 1 ok"
grep -q "1 failed" <<< "$out" || fail "upgrade summary should tally 1 failed"
[ "$rc" -ne 0 ] || fail "upgrade should exit non-zero when a project failed"
ok

# ── 10. a MISSING project is reported (skipped), not fatal ───────────────────
printf 'ghost|%s/proj/ghost|me/ghost\n' "$T" >> "$HERD_FLEET_FILE"
set +e
out="$(HERD_FLEET_HERD_BIN="$STUB" bash "$HERD" fleet upgrade)"; rc=$?
set -e
grep -Eq "ghost.*skipped" <<< "$out" || fail "missing project should be reported as skipped"
grep -q "alpha" <<< "$out" || fail "fan-out should continue past a missing project (alpha)"
grep -q "1 skipped" <<< "$out" || fail "summary should tally the skipped project"
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
grep -q "reloaded (reload)" <<< "$out" || fail "reload should delegate the 'reload' subcommand"
grep -q "2 ok" <<< "$out" || fail "reload summary should tally 2 ok"
ok

# ── 12. empty registry is a friendly note, not a crash ───────────────────────
out="$(HERD_FLEET_FILE="$T/none/fleet" bash "$HERD" fleet list)"
grep -qi "no fleet registry\|register" <<< "$out" || fail "empty registry list should hint how to add a project"
out="$(HERD_FLEET_FILE="$T/none/fleet" bash "$HERD" fleet status)"
grep -qi "no fleet registry\|PROJECT" <<< "$out" || fail "empty registry status should not crash"
ok

# ── 13. unknown subcommand fails loudly ──────────────────────────────────────
if bash "$HERD" fleet bogus >/dev/null 2>&1; then
  fail "unknown fleet subcommand should exit non-zero"
fi
ok

# ── 14. issue #128: register resolves the TARGET's remote, not the CALLER's cwd remote ───────────
# Register alpha from INSIDE a different git checkout whose own origin remote is caller/elsewhere.
# The recorded repo must be the TARGET (acme/alpha), never the caller's (caller/elsewhere).
CALLER="$T/caller"
mkdir -p "$CALLER"
git -C "$CALLER" init -q
git -C "$CALLER" config user.email t@t.t
git -C "$CALLER" config user.name t
git -C "$CALLER" remote add origin "https://github.com/caller/elsewhere.git"
( cd "$CALLER" && git commit -q --allow-empty -m init )
REG14="$T/registry14/fleet"
( cd "$CALLER" && HERD_FLEET_FILE="$REG14" bash "$HERD" fleet register "$ALPHA" >/dev/null )
grep -q "^alpha|$ALPHA|acme/alpha$" "$REG14" \
  || fail "register from a foreign cwd must record the TARGET's repo (acme/alpha), got: $(grep '^alpha|' "$REG14" || true)"
grep -q "caller/elsewhere" "$REG14" && fail "caller's cwd remote leaked into the registry (issue #128)"
ok

# ── 14b. issue #128 review: an owner==repo slug (eslint/eslint) must NOT be blanked ──────────────
SAME="$T/proj/samename"
mkdir -p "$SAME/.herd" "$T/proj/samename-trees/.herd"
git -C "$SAME" init -q
git -C "$SAME" config user.email t@t.t
git -C "$SAME" config user.name t
git -C "$SAME" remote add origin "git@github.com:eslint/eslint.git"   # owner and repo names identical
( cd "$SAME" && git commit -q --allow-empty -m init )
same_real="$(cd "$SAME" && pwd -P)"
cat > "$SAME/.herd/config" <<CFG
PROJECT_ROOT="$same_real"
WORKTREES_DIR="$same_real-trees"
DEFAULT_BRANCH="origin/main"
WORKSPACE_NAME="samename"
HERD_REPO="me/samename"
CFG
REG14B="$T/registry14b/fleet"
note14b="$(HERD_FLEET_FILE="$REG14B" bash "$HERD" fleet register "$same_real" 2>&1 >/dev/null)"
grep -q "^samename|$same_real|eslint/eslint$" "$REG14B" \
  || fail "owner==repo slug must record eslint/eslint, got: $(grep '^samename|' "$REG14B" || true)"
grep -qi "no parseable origin remote" <<< "$note14b" \
  && fail "owner==repo slug must NOT emit the 'no parseable origin remote' note, got: $note14b"
ok

# ── 14c. issue #128 review: a bare-SSH self-hosted remote must NOT corrupt the slug with a backslash ─
# git@host:project.git (gitolite/cgit/plain bare repos, no owner namespace). The scp colon→slash
# rewrite must yield host/project cleanly — a literal backslash (host\/project) is silently-wrong data.
BARE="$T/proj/baressh"
mkdir -p "$BARE/.herd" "$T/proj/baressh-trees/.herd"
git -C "$BARE" init -q
git -C "$BARE" config user.email t@t.t
git -C "$BARE" config user.name t
git -C "$BARE" remote add origin "git@myserver:myproject.git"
( cd "$BARE" && git commit -q --allow-empty -m init )
bare_real="$(cd "$BARE" && pwd -P)"
cat > "$BARE/.herd/config" <<CFG
PROJECT_ROOT="$bare_real"
WORKTREES_DIR="$bare_real-trees"
DEFAULT_BRANCH="origin/main"
WORKSPACE_NAME="baressh"
HERD_REPO="me/baressh"
CFG
REG14C="$T/registry14c/fleet"
HERD_FLEET_FILE="$REG14C" bash "$HERD" fleet register "$bare_real" >/dev/null 2>&1
grep -q "^baressh|$bare_real|myserver/myproject$" "$REG14C" \
  || fail "bare-SSH remote must record myserver/myproject cleanly, got: $(grep '^baressh|' "$REG14C" || true)"
grep -q '\\' "$REG14C" && fail "registry contains a backslash — scp colon→slash rewrite corrupted the slug"
ok

# ── 15. a remote-less target records an empty repo field + emits a note ──────────────────────────
NOREMOTE="$T/proj/noremote"
mkdir -p "$NOREMOTE/.herd" "$T/proj/noremote-trees/.herd"
git -C "$NOREMOTE" init -q
git -C "$NOREMOTE" config user.email t@t.t
git -C "$NOREMOTE" config user.name t
( cd "$NOREMOTE" && git commit -q --allow-empty -m init )        # NO origin remote added
noremote_real="$(cd "$NOREMOTE" && pwd -P)"
cat > "$NOREMOTE/.herd/config" <<CFG
PROJECT_ROOT="$noremote_real"
WORKTREES_DIR="$noremote_real-trees"
DEFAULT_BRANCH="origin/main"
WORKSPACE_NAME="noremote"
HERD_REPO="me/noremote"
CFG
REG15="$T/registry15/fleet"
note="$(HERD_FLEET_FILE="$REG15" bash "$HERD" fleet register "$noremote_real" 2>&1 >/dev/null)"
grep -q "^noremote|$noremote_real|$" "$REG15" \
  || fail "remote-less target should record an EMPTY repo field, got: $(grep '^noremote|' "$REG15" || true)"
grep -qi "empty repo\|origin remote" <<< "$note" \
  || fail "remote-less register should emit a note about the empty repo field, got: $note"
ok

echo "ALL PASS ($pass checks)"
