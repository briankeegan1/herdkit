#!/usr/bin/env bash
# test-fleet-graph.sh — hermetic tests for `herd fleet graph` (HERD-386 relationship-graph rollup).
#
# Design (mirrors test-fleet-digest.sh / test-fleet-inbox.sh):
#   • Fully hermetic: a temp HERD_FLEET_FILE registry + temp fake projects, each with its own
#     .herd/config and (where relevant) .herd/links / .herd/deps; temp $HOME so the default
#     ~/.herd/fleet is never touched. No network, no gh, no git.
#
# What it asserts:
#   • registry projects render as nodes (text + --json), a reachable project with no links/deps
#     prints "(no links or deps)".
#   • .herd/links rows render as "link" edges, .herd/deps "blocked-on:"/"watch:" rows render as
#     their own labeled edge kind, reusing the exact ref format (<link-name>#<id>) herd depend/deps
#     already own.
#   • peer resolution: a repo-identity match against the registry ("registered"), a NAME-fallback
#     match when the link has no repo recorded, a registry row whose project path is gone
#     ("unreachable"), and no match at all ("unregistered").
#   • --json shape: nodes[] (name/path/repo/reachable) and edges[] (from/kind/ref/repo/status/
#     to_project).
#   • fail-soft: an empty/missing registry renders a friendly note (text) / empty nodes+edges (json),
#     never an error; exit is always 0.
#
# Run:  bash tests/test-fleet-graph.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
HERD="$HERE/../bin/herd"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass=0
ok(){ pass=$((pass+1)); }

export HOME="$T/home"; mkdir -p "$HOME"
export HERD_FLEET_FILE="$T/registry/fleet"

# _mkproj <name> <repo> — a fake herd project (no git needed; graph never shells out to git/gh).
_mkproj() {
  local name="$1" repo="$2" root="$T/proj/$1"
  mkdir -p "$root/.herd"
  local rr; rr="$(cd "$root" && pwd -P)"
  cat > "$root/.herd/config" <<CFG
PROJECT_ROOT="$rr"
WORKTREES_DIR="$rr-trees"
DEFAULT_BRANCH="origin/main"
WORKSPACE_NAME="$name"
HERD_REPO="$repo"
CFG
  printf '%s' "$rr"
}

ALPHA="$(_mkproj alpha me/alpha)"
BETA="$(_mkproj beta me/beta)"
GAMMA="$(_mkproj gamma me/gamma)"

# alpha's OWN .herd/links: "beta" resolves by repo identity; "gamma" has NO repo recorded (exercises
# the name-fallback match); "unknownpeer" matches nothing in the registry at all.
cat > "$ALPHA/.herd/links" <<'LINKS'
beta|me/beta|github|
gamma||github|
unknownpeer|me/nowhere|github|
LINKS

# alpha's OWN .herd/deps: a blocking dep on beta (resolved via alpha's OWN links row for "beta") and a
# non-blocking watch on the unregistered peer. Exactly the row shapes herd depend/deps already write.
cat > "$ALPHA/.herd/deps" <<'DEPS'
blocked-on: beta#7  since=100
watch: unknownpeer#3  since=100
DEPS

# gamma links to a registry row whose project path is GONE — exercises the "unreachable" peer status
# (as opposed to "unregistered": ghostproj IS a registry row, just not a reachable one).
cat > "$GAMMA/.herd/links" <<'LINKS'
ghostproj|me/ghostproj|github|
LINKS

# Write the registry directly (not via `herd fleet register`, which derives repo identity from the
# TARGET's live `git remote get-url origin` — these fixtures are plain directories, no git) so the
# repo field is exactly what this test needs to exercise BOTH resolution paths: a repo-identity match
# (beta) and a name-fallback match (gamma, whose link in alpha has no repo recorded).
mkdir -p "$(dirname "$HERD_FLEET_FILE")"
printf 'alpha|%s|me/alpha\n' "$ALPHA"   >  "$HERD_FLEET_FILE"
printf 'beta|%s|me/beta\n' "$BETA"     >> "$HERD_FLEET_FILE"
printf 'gamma|%s|me/gamma\n' "$GAMMA"  >> "$HERD_FLEET_FILE"
# ghostproj: a registry row whose path was never created (mirrors test-fleet-digest.sh's ghost row).
printf 'ghostproj|%s/proj/ghostproj|me/ghostproj\n' "$T" >> "$HERD_FLEET_FILE"

# ── 1. text rollup: nodes + labeled edges ───────────────────────────────────────────────────────────
set +e
out="$(bash "$HERD" fleet graph)"; rc=$?
set -e
[ "$rc" -eq 0 ] || fail "fleet graph should exit 0, got $rc"; ok

alpha_block="$(printf '%s' "$out" | awk '/^alpha/{f=1;next} /^[a-zA-Z]/{f=0} f')"
printf '%s' "$alpha_block" | grep -q 'link' || fail "alpha block should show a link edge: $alpha_block"
printf '%s' "$alpha_block" | grep -q 'beta'          || fail "alpha should link to beta"
printf '%s' "$alpha_block" | grep -Eq 'link.*gamma.*\[registered\]' \
  || fail "alpha's gamma link (no repo recorded) should resolve via name-fallback to registered: $alpha_block"
printf '%s' "$alpha_block" | grep -Eq 'link.*unknownpeer.*\[unregistered\]' \
  || fail "alpha's unknownpeer link should be unregistered: $alpha_block"
printf '%s' "$alpha_block" | grep -Eq 'blocked-on.*beta#7.*\[registered\]' \
  || fail "alpha's blocked-on beta#7 should be registered: $alpha_block"
printf '%s' "$alpha_block" | grep -Eq 'watch.*unknownpeer#3.*\[unregistered\]' \
  || fail "alpha's watch unknownpeer#3 should be unregistered: $alpha_block"
ok

beta_block="$(printf '%s' "$out" | awk '/^beta/{f=1;next} /^[a-zA-Z]/{f=0} f')"
printf '%s' "$beta_block" | grep -qi 'no links or deps' || fail "beta (no links/deps) block: $beta_block"
ok

gamma_block="$(printf '%s' "$out" | awk '/^gamma/{f=1;next} /^[a-zA-Z]/{f=0} f')"
printf '%s' "$gamma_block" | grep -Eq 'link.*ghostproj.*\[unreachable\]' \
  || fail "gamma's ghostproj link should be unreachable (registered row, gone path): $gamma_block"
ok

ghost_block="$(printf '%s' "$out" | awk '/^ghostproj/{f=1;next} /^[a-zA-Z]/{f=0} f')"
printf '%s' "$ghost_block" | grep -qi 'unreachable' || fail "ghostproj itself should render as unreachable: $ghost_block"
ok

# ── 2. --json shape ──────────────────────────────────────────────────────────────────────────────────
J="$T/graph.json"
set +e
bash "$HERD" fleet graph --json > "$J"; rc=$?
set -e
[ "$rc" -eq 0 ] || fail "fleet graph --json should exit 0, got $rc"; ok

if ! python3 - "$J" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
errs = []
def check(cond, msg):
    if not cond:
        errs.append(msg)

check(isinstance(d.get("nodes"), list), "nodes should be a list")
check(isinstance(d.get("edges"), list), "edges should be a list")

names = sorted(n["name"] for n in d["nodes"])
check(names == ["alpha", "beta", "gamma", "ghostproj"],
      "nodes should be alpha,beta,gamma,ghostproj, got %r" % names)

reach = {n["name"]: n["reachable"] for n in d["nodes"]}
for n in ("alpha", "beta", "gamma"):
    check(reach.get(n) is True, "%s should be reachable" % n)
check(reach.get("ghostproj") is False, "ghostproj should be unreachable")

edges = d["edges"]
check(len(edges) == 6, "expected 6 edges total, got %d: %r" % (len(edges), edges))

def find(**kw):
    for e in edges:
        if all(e.get(k) == v for k, v in kw.items()):
            return e
    return None

e = find(**{"from": "alpha", "kind": "link", "ref": "beta"})
check(e is not None and e["status"] == "registered" and e["to_project"] == "beta",
      "alpha link->beta should be registered/beta, got %r" % e)

e = find(**{"from": "alpha", "kind": "link", "ref": "gamma"})
check(e is not None and e["status"] == "registered" and e["to_project"] == "gamma",
      "alpha link->gamma (name-fallback) should be registered/gamma, got %r" % e)

e = find(**{"from": "alpha", "kind": "link", "ref": "unknownpeer"})
check(e is not None and e["status"] == "unregistered" and e["to_project"] is None,
      "alpha link->unknownpeer should be unregistered/None, got %r" % e)

e = find(**{"from": "alpha", "kind": "blocked-on", "ref": "beta#7"})
check(e is not None and e["status"] == "registered" and e["to_project"] == "beta",
      "alpha blocked-on beta#7 should be registered/beta, got %r" % e)

e = find(**{"from": "alpha", "kind": "watch", "ref": "unknownpeer#3"})
check(e is not None and e["status"] == "unregistered",
      "alpha watch unknownpeer#3 should be unregistered, got %r" % e)

e = find(**{"from": "gamma", "kind": "link", "ref": "ghostproj"})
check(e is not None and e["status"] == "unreachable" and e["to_project"] == "ghostproj",
      "gamma link->ghostproj should be unreachable/ghostproj, got %r" % e)

check(find(**{"from": "beta"}) is None, "beta should have no edges")

if errs:
    sys.stderr.write("\n".join(errs) + "\n")
    sys.exit(1)
PY
then
  fail "--json field assertions failed (see stderr above)"
fi
ok

# ── 3. fail-soft: empty / missing registry ──────────────────────────────────────────────────────────
EMPTY_REG="$T/registry2/fleet"
set +e
out="$(HERD_FLEET_FILE="$EMPTY_REG" bash "$HERD" fleet graph)"; rc=$?
set -e
[ "$rc" -eq 0 ] || fail "an absent registry should still exit 0, got $rc"
printf '%s' "$out" | grep -qi 'no fleet registry yet' || fail "absent registry should print a friendly note: $out"
ok

J2="$T/empty.json"
set +e
HERD_FLEET_FILE="$EMPTY_REG" bash "$HERD" fleet graph --json > "$J2"; rc=$?
set -e
[ "$rc" -eq 0 ] || fail "an absent registry --json should still exit 0, got $rc"
python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
assert d["nodes"] == [], "nodes should be empty for an absent registry, got %r" % d["nodes"]
assert d["edges"] == [], "edges should be empty for an absent registry, got %r" % d["edges"]
' "$J2" || fail "empty-registry --json shape assertion failed"
ok

echo "PASS ($pass checks) — test-fleet-graph.sh"
