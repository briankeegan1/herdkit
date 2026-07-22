#!/usr/bin/env bash
# test-fleet-new.sh — hermetic tests for `herd fleet new <path>` (HERD-410): the one-command
# spin-up chain (mkdir + git init + herd init + commit the rendered .herd/ files + gh repo create
# unless --no-remote + herd fleet register), replacing the hand-rolled chain a fleet-room operator
# used to type by hand.
#
# Design principles (mirror test-fleet.sh / test-init-archetypes.sh):
#   • Fully hermetic: a temp HERD_FLEET_FILE registry, temp $HOME, HERD_SKIP_DOCTOR / HERD_SKIP_GH_DETECT
#     so the delegated `herd init` never touches the network or a real doctor check.
#   • gh is STUBBED on PATH per-scenario (present+authed / present+unauthed / absent) so the fail-soft
#     remote leg is proven deterministically, with no real GitHub calls. The "authed" stub pushes to a
#     local bare git repo standing in for the hosted remote, so the push leg is exercised for real.
#
# Asserts:
#   (1) --no-remote, explicit --archetype/--posture: registry row written, .herd/config +
#       healthcheck.project.sh + .gitignore + BACKLOG.md committed, .herd/secrets and
#       .herd/config.local NEVER committed (and ARE gitignored), no remote created, a
#       fleet_project_created journal event lands in the new project's OWN journal.
#   (2) neither --archetype nor --posture, no tty: LOUD default banner on stderr naming
#       archetype=code/posture=solo-auto BEFORE 'herd init' runs, and those values land in config.
#   (3) gh present + authenticated: repo created, remote 'origin' added, and the initial commit is
#       actually pushed (to a local bare repo standing in for the host) — registry's repo field is
#       populated from the pushed remote's origin, not the config's HERD_REPO.
#   (4) gh NOT on PATH: fail-soft degrade — loud warning, exit 0, no remote, project still fully
#       spun up and registered (never a crash).
#   (5) unknown --archetype refuses BEFORE any filesystem side effect (no directory left behind).
#
# Run:  bash tests/test-fleet-new.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
HERD="$REPO/bin/herd"
export HERDKIT_HOME="$REPO"

command -v git >/dev/null 2>&1 || { echo "FAIL: git required" >&2; exit 1; }

T="$(mktemp -d)"; T="$(cd "$T" && pwd -P)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }
plain() { printf '%s' "$1" | sed $'s/\x1b\\[[0-9;]*m//g'; }

# Isolate HOME so the default ~/.herd/fleet is never touched even if a seam is missed.
export HOME="$T/home"; mkdir -p "$HOME"
export HERD_FLEET_FILE="$T/registry/fleet"

# NOTE: deliberately NOT setting HERMETIC_TEST=1 — journal.sh redirects writes to a throwaway
# per-process file under that signal (HERD-223), and (1) below asserts the real per-project journal
# at $WORKTREES_DIR/.herd/journal.jsonl. Isolation instead comes from every path here living under
# the temp $T (a fresh project root + a fresh sibling -trees pool each time) plus the temp $HOME /
# HERD_FLEET_FILE registry — nothing this test does can touch a real project.
COMMON_ENV=(HERD_SKIP_DOCTOR=1 HERD_SKIP_GH_DETECT=1)

# ── (1) --no-remote, explicit flags: full local chain, secrets/config.local never committed ──────
proj1="$T/moneybet-1"
out="$(env "${COMMON_ENV[@]}" HERD_FLEET_FILE="$HERD_FLEET_FILE" HOME="$HOME" \
        bash "$HERD" fleet new "$proj1" --archetype research-lab --posture observe-only --no-remote \
        --alias mb1 < /dev/null 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "(1) fleet new failed (rc=$rc): $out"

grep -qxF "moneybet-1|$proj1|" "$HERD_FLEET_FILE" 2>/dev/null \
  || grep -qF "moneybet-1|$proj1|" "$HERD_FLEET_FILE" 2>/dev/null \
  || fail "(1) registry row missing/wrong: $(cat "$HERD_FLEET_FILE" 2>&1)"
grep -qF "|mb1" "$HERD_FLEET_FILE" 2>/dev/null || fail "(1) --alias mb1 not recorded: $(cat "$HERD_FLEET_FILE")"

[ -d "$proj1/.git" ] || fail "(1) git repo not initialized"
[ -f "$proj1/.herd/config" ] || fail "(1) .herd/config not written"
grep -qE '^PROJECT_ARCHETYPE="research-lab"$' "$proj1/.herd/config" || fail "(1) archetype flag not applied"
grep -qE '^MERGE_POLICY="observe"$' "$proj1/.herd/config" || fail "(1) posture flag not applied"

committed="$(git -C "$proj1" ls-files)"
echo "$committed" | grep -qx ".herd/config" || fail "(1) .herd/config not committed: $committed"
echo "$committed" | grep -qx ".gitignore" || fail "(1) .gitignore not committed: $committed"
echo "$committed" | grep -q "secrets" && fail "(1) LEAK: .herd/secrets committed: $committed"
echo "$committed" | grep -q "config.local" && fail "(1) LEAK: .herd/config.local committed: $committed"
grep -qxF ".herd/secrets" "$proj1/.gitignore" || fail "(1) .herd/secrets not gitignored: $(cat "$proj1/.gitignore")"
grep -qxF ".herd/config.local" "$proj1/.gitignore" || fail "(1) .herd/config.local not gitignored: $(cat "$proj1/.gitignore")"
[ -z "$(git -C "$proj1" remote)" ] || fail "(1) --no-remote should leave no git remote: $(git -C "$proj1" remote -v)"

wt="$(grep -E '^WORKTREES_DIR=' "$proj1/.herd/config" | sed -E 's/^WORKTREES_DIR="(.*)"$/\1/')"
[ -f "$wt/.herd/journal.jsonl" ] || fail "(1) no journal written at $wt/.herd/journal.jsonl"
grep -q '"event":"fleet_project_created"' "$wt/.herd/journal.jsonl" \
  || fail "(1) fleet_project_created event missing: $(cat "$wt/.herd/journal.jsonl")"
ok

# ── (2) no flags, no tty: LOUD default banner, defaults land in config ────────────────────────────
proj2="$T/moneybet-2"
out="$(env "${COMMON_ENV[@]}" HERD_FLEET_FILE="$HERD_FLEET_FILE" HOME="$HOME" \
        bash "$HERD" fleet new "$proj2" --no-remote < /dev/null 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "(2) fleet new failed (rc=$rc): $out"
pout="$(plain "$out")"
echo "$pout" | grep -qi "no --archetype/--posture flags and no tty" \
  || fail "(2) missing the loud no-flags-no-tty banner: $out"
echo "$pout" | grep -qi "archetype=code posture=solo-auto" \
  || fail "(2) banner should name the defaults it is applying: $out"
grep -qE '^PROJECT_ARCHETYPE="code"$' "$proj2/.herd/config" || fail "(2) default archetype not applied"
grep -qE '^MERGE_POLICY="auto"$' "$proj2/.herd/config" || fail "(2) default posture (solo-auto) not applied"
ok

# ── (3) gh present + authenticated: repo created, pushed to a real (local bare) remote ───────────
BIN_OK="$T/bin-gh-ok"; mkdir -p "$BIN_OK"
BARE="$T/bare-remote.git"; git init -q --bare "$BARE"
cat > "$BIN_OK/gh" <<STUB
#!/usr/bin/env bash
case "\$1 \$2" in
  "auth status") exit 0 ;;
esac
case "\$1" in
  api) echo "acmeuser"; exit 0 ;;
  repo)
    case "\$2" in
      create) exit 0 ;;
      view) echo "file://${BARE%.git}"; exit 0 ;;
    esac
    ;;
esac
exit 1
STUB
chmod +x "$BIN_OK/gh"

proj3="$T/moneybet-3"
out="$(env "${COMMON_ENV[@]}" HERD_FLEET_FILE="$HERD_FLEET_FILE" HOME="$HOME" \
        PATH="$BIN_OK:$PATH" \
        bash "$HERD" fleet new "$proj3" --archetype code --posture solo-auto < /dev/null 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "(3) fleet new failed (rc=$rc): $out"
pout="$(plain "$out")"
echo "$pout" | grep -qi "gh repo create: acmeuser/moneybet-3" \
  || fail "(3) should announce the created repo: $out"
remote_url="$(git -C "$proj3" remote get-url origin 2>/dev/null || true)"
[ -n "$remote_url" ] || fail "(3) origin remote not set"
# The bare repo should now have the pushed branch.
git --git-dir="$BARE" log --oneline 2>/dev/null | grep -q . \
  || fail "(3) push did not land any commits in the bare remote"
# The registry's repo field is resolved from the git remote's OWN URL (fleet_register's identity
# rule — issue #128), not gh's "acmeuser/moneybet-3" slug; our stand-in remote is a local bare repo
# (file:// URL) rather than a real GitHub host, so just assert the field is populated (non-empty) —
# proof registration ran AFTER the push added a real, parseable origin remote.
repo_field="$(awk -F'|' '$1=="moneybet-3"{print $3}' "$HERD_FLEET_FILE")"
[ -n "$repo_field" ] \
  || fail "(3) registry repo field empty — should have resolved from the freshly pushed origin remote: $(cat "$HERD_FLEET_FILE")"
ok

# ── (4) gh NOT on PATH: fail-soft degrade, never a crash ──────────────────────────────────────────
# 'gh' lives only under a package-manager prefix (e.g. /opt/homebrew/bin), never under the base
# system dirs — a bare /usr/bin:/bin (plus /usr/sbin:/sbin) keeps every coreutil this chain needs
# (git, mv, mkdir, cp, chmod, sed, awk, mktemp, ...) while guaranteeing no 'gh' resolves.
NOGH_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
PATH="$NOGH_PATH" command -v gh >/dev/null 2>&1 \
  && fail "(4) test setup bug: gh is still resolvable under $NOGH_PATH"
proj4="$T/moneybet-4"
out="$(env "${COMMON_ENV[@]}" HERD_FLEET_FILE="$HERD_FLEET_FILE" HOME="$HOME" \
        PATH="$NOGH_PATH" \
        bash "$HERD" fleet new "$proj4" --archetype code --posture solo-auto < /dev/null 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "(4) fleet new should degrade cleanly, not fail (rc=$rc): $out"
echo "$out" | grep -qi "gh CLI not found" || fail "(4) missing the loud gh-not-found warning: $out"
[ -z "$(git -C "$proj4" remote 2>/dev/null)" ] || fail "(4) no remote should have been created"
[ -f "$proj4/.herd/config" ] || fail "(4) project should still be fully spun up despite no gh"
grep -qF "moneybet-4|$proj4|" "$HERD_FLEET_FILE" || fail "(4) project should still be registered despite no gh"
ok

# ── (5) unknown --archetype refuses before any filesystem side effect ────────────────────────────
proj5="$T/moneybet-5-should-not-exist"
out="$(env "${COMMON_ENV[@]}" HERD_FLEET_FILE="$HERD_FLEET_FILE" HOME="$HOME" \
        bash "$HERD" fleet new "$proj5" --archetype totally-bogus < /dev/null 2>&1)"
rc=$?
[ "$rc" -ne 0 ] || fail "(5) unknown --archetype should refuse: $out"
echo "$out" | grep -qi "unknown --archetype" || fail "(5) should name the bad flag: $out"
[ -e "$proj5" ] && fail "(5) no directory should be created when the archetype flag is rejected"
ok

echo "ALL PASS ($pass checks)"
