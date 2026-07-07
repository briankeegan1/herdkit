#!/usr/bin/env bash
# test-planned-work-visibility.sh — HERD-52 cross-operator planned-work visibility.
#
# Two hermetic, network-free layers:
#   A) RENDER — `herd render` emits the coordinator skill with the planned-work section intact, its
#      queue/unqueue/queued commands present, the ADVISORY-after-24h rule stated, and every {{token}}
#      substituted (a surviving {{...}} in the new prose would ship a broken skill).
#   B) CLI e2e — on a file-backend project in a local git repo, `herd backlog queue|queued|unqueue`
#      publishes, lists (with an age/ADVISORY annotation), and clears a 📌 planned marker end-to-end.
# No herdr, no gh, no claude, no network.
# Run:  bash tests/test-planned-work-visibility.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
HERD="$ROOT/bin/herd"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass(){ PASS=$((PASS+1)); }

# ── A. Render the coordinator skill and assert the planned-work section survives + resolves ───────
P1="$T/proj-render"
mkdir -p "$P1/.herd"
git -C "$P1" init -q; git -C "$P1" config user.email t@t.t; git -C "$P1" config user.name t
( cd "$P1" && git commit -q --allow-empty -m init )
cat > "$P1/.herd/config" <<EOF
HERD_VERSION=1
WORKSPACE_NAME="herdkit"
PROJECT_ROOT="$P1"
DEFAULT_BRANCH="origin/main"
BACKLOG_FILE="BACKLOG.md"
SCRIBE_BACKEND="file"
HERD_REPO="acme/widgets"
COORDINATOR_CMD="/coordinator"
EOF
( cd "$P1" && bash "$HERD" render ) >/dev/null || fail "herd render exited non-zero"
SKILL="$P1/.claude/commands/coordinator.md"
[ -f "$SKILL" ] || fail "herd render did not write the coordinator skill"

grep -q "Planned-work visibility" "$SKILL" || fail "rendered skill is missing the Planned-work visibility section"
grep -q "herd backlog queue <#id> --after <blocker>" "$SKILL" || fail "rendered skill missing the 'queue' command"
grep -q "herd backlog queued" "$SKILL" || fail "rendered skill missing the 'queued' list command"
grep -q "herd backlog unqueue <#id>" "$SKILL" || fail "rendered skill missing the 'unqueue' command"
grep -q "ADVISORY: >24h" "$SKILL" || fail "rendered skill did not state the 24h-advisory rule"
# The section references {{BACKLOG_FILE}} — it must have been substituted to the concrete filename.
grep -q "committed onto" "$SKILL" || fail "rendered skill missing the file-backend marker description"
grep -A2 "committed onto" "$SKILL" | grep -q "BACKLOG.md" \
  || fail "{{BACKLOG_FILE}} was not substituted to the concrete filename in the planned-work section"
if grep -n "{{[A-Z_]*}}" "$SKILL" | grep -q . ; then
  fail "rendered skill left an unsubstituted {{token}}: $(grep -n '{{[A-Z_]*}}' "$SKILL" | head -1)"
fi
pass

# ── B. CLI e2e over the file backend: queue → queued → unqueue ────────────────────────────────────
P2="$T/proj-cli"
mkdir -p "$P2/.herd"
git -C "$P2" init -q; git -C "$P2" config user.email t@t.t; git -C "$P2" config user.name t
cat > "$P2/.herd/config" <<EOF
PROJECT_ROOT="$P2"
SCRIBE_BACKEND="file"
BACKLOG_FILE="BACKLOG.md"
DEFAULT_BRANCH="origin/main"
WATCHER_OWNER="alice"
EOF
cat > "$P2/BACKLOG.md" <<'EOF'
# proj — backlog
## Next
- 🔜 card-csv-importer — import cards from CSV
- 🔜 dark-mode-toggle — theme switch
EOF
( cd "$P2" && git add . && git commit -q -m seed )

# queue: publish a marker on card-csv-importer, sequenced after dark-mode-toggle.
out="$( cd "$P2" && bash "$HERD" backlog queue card-csv-importer --after dark-mode-toggle 2>&1 )" \
  || fail "herd backlog queue exited non-zero ($out)"
echo "$out" | grep -q "📌 queued card-csv-importer as 'alice'" || fail "queue did not confirm the marker for the resolved operator ($out)"
grep -qE '📌 queued by alice: sequenced after dark-mode-toggle \[[0-9]+\]' "$P2/BACKLOG.md" \
  || fail "queue did not commit the 📌 annotation onto the item line"

# queued: list shows the marker with a fresh (non-advisory) age annotation.
lst="$( cd "$P2" && bash "$HERD" backlog queued 2>&1 )" || fail "herd backlog queued exited non-zero"
echo "$lst" | grep -q "queued by alice: sequenced after dark-mode-toggle" || fail "queued did not list the marker ($lst)"
echo "$lst" | grep -q "ADVISORY" && fail "a just-written marker must NOT be flagged advisory ($lst)"

# The marker also shows inline in plain `herd backlog` (it's on the item's line).
inline="$( cd "$P2" && bash "$HERD" backlog 2>&1 )" || fail "herd backlog exited non-zero"
echo "$inline" | grep -q "📌 queued by alice" || fail "the file-backend marker should show inline in 'herd backlog'"

# unqueue: clears it.
uq="$( cd "$P2" && bash "$HERD" backlog unqueue card-csv-importer 2>&1 )" || fail "herd backlog unqueue exited non-zero ($uq)"
echo "$uq" | grep -q "cleared the planned marker" || fail "unqueue did not confirm the clear ($uq)"
grep -q '📌' "$P2/BACKLOG.md" && fail "unqueue left a 📌 marker behind"
lst2="$( cd "$P2" && bash "$HERD" backlog queued 2>&1 )" || fail "herd backlog queued (post-clear) exited non-zero"
[ -z "$lst2" ] || fail "queued should be empty after unqueue ($lst2)"
pass

# ── C. A backend without the op fails soft (advisory feature, never a hard error) ─────────────────
# The changelog backend defines no planned-marker ops. queue/unqueue print a soft note and exit 0;
# queued prints nothing.
P3="$T/proj-changelog"
mkdir -p "$P3/.herd"
cat > "$P3/.herd/config" <<EOF
PROJECT_ROOT="$P3"
SCRIBE_BACKEND="changelog"
BACKLOG_FILE="CHANGELOG.md"
EOF
printf '# Changelog\n' > "$P3/CHANGELOG.md"
softq="$( cd "$P3" && bash "$HERD" backlog queue anything --after x 2>&1 )" || fail "queue on an unsupported backend should exit 0 (fail-soft)"
echo "$softq" | grep -qi "no planned-marker op" || fail "queue on an unsupported backend should print a soft skip note ($softq)"
softl="$( cd "$P3" && bash "$HERD" backlog queued 2>&1 )" || fail "queued on an unsupported backend should exit 0"
[ -z "$softl" ] || fail "queued on an unsupported backend should print nothing ($softl)"
pass

echo "ALL PASS ($PASS checks)"
