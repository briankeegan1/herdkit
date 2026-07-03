#!/usr/bin/env bash
# test-backlog-reconcile.sh — hermetic test of the backlog-reconcile pass
# (scripts/herd/backlog-reconcile.sh). When a PR moves/renames the things backlog items point at,
# affected entries dangle. This exercises the three seams against a REAL local git repo (no network,
# no gh, no herdr, no scribe agent):
#   • surface — file rename, file delete, function rename, section-header rename → TSV surface
#   • scan    — surface matched against a fixture BACKLOG.md → DANGLING report; NONE when clean
#   • run     — enqueues ONE scribe request (captured via the HERD_RECONCILE_SCRIBE seam) only when
#               something dangles; a clean no-op otherwise
# Run:  bash tests/test-backlog-reconcile.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../scripts/herd/backlog-reconcile.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass(){ PASS=$((PASS+1)); }
command -v git >/dev/null 2>&1 || fail "git required"
command -v python3 >/dev/null 2>&1 || fail "python3 required"

REPO="$T/repo"
mkdir -p "$REPO/.herd" "$REPO/scripts/herd" "$T/trees"
export HERD_CONFIG_FILE="$REPO/.herd/config"
cat > "$REPO/.herd/config" <<EOF
PROJECT_ROOT="$REPO"
WORKTREES_DIR="$T/trees"
DEFAULT_BRANCH="main"
BACKLOG_FILE="BACKLOG.md"
EOF

git -C "$REPO" init -q
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name  tester

# ── base commit: a script with a function, a doc with a header, a to-be-deleted file, a backlog ──
cat > "$REPO/scripts/herd/agent-watch.sh" <<'S'
#!/usr/bin/env bash
# the watcher — a file with enough shared content that a move stays above git's rename threshold
poll_prs() { echo poll; }
do_old_thing() { echo old; }
common_line_1=1
common_line_2=2
common_line_3=3
S
mkdir -p "$REPO/docs"
cat > "$REPO/docs/guide.md" <<'M'
## Old Section Heading

Some prose under the heading.
M
cat > "$REPO/legacy.sh" <<'S'
#!/usr/bin/env bash
echo legacy
S
cat > "$REPO/BACKLOG.md" <<'B'
# project backlog

## Planned
- 🔜 **Harden the watcher** — extend scripts/herd/agent-watch.sh so do_old_thing retries transients
- 🔜 **Docs polish** — rewrite the "Old Section Heading" section in docs/guide.md
- 🔜 **Drop legacy** — remove legacy.sh once nothing imports it
- 🔜 **Unrelated feature** — a CSV importer, references nothing that moves

## Recently shipped
- ✅ **Prior work** — historically lived in agent-watch.sh
B
git -C "$REPO" add -A
git -C "$REPO" commit -qm base

# ── rename commit: move the script (rename), rename the function + header, delete legacy.sh ──
git -C "$REPO" mv scripts/herd/agent-watch.sh scripts/herd/watcher.sh
cat > "$REPO/scripts/herd/watcher.sh" <<'S'
#!/usr/bin/env bash
# the watcher — a file with enough shared content that a move stays above git's rename threshold
poll_prs() { echo poll; }
do_new_thing() { echo new; }
common_line_1=1
common_line_2=2
common_line_3=3
S
cat > "$REPO/docs/guide.md" <<'M'
## New Section Heading

Some prose under the heading.
M
git -C "$REPO" rm -q legacy.sh
git -C "$REPO" add -A
git -C "$REPO" commit -qm rename-surface

RANGE="HEAD~1..HEAD"

# ── (1) surface: rename + delete + symbol(func) + symbol(header) all present ───
surface="$(bash "$SCRIPT" surface "$RANGE")" || fail "surface exited non-zero"
printf '%s\n' "$surface" | grep -q $'^rename\tscripts/herd/agent-watch.sh\tscripts/herd/watcher.sh$' \
  || fail "surface missing the file rename ($surface)"
printf '%s\n' "$surface" | grep -q $'^delete\tlegacy.sh\t$' \
  || fail "surface missing the file delete ($surface)"
printf '%s\n' "$surface" | grep -q $'^symbol\tdo_old_thing\t$' \
  || fail "surface missing the renamed function ($surface)"
printf '%s\n' "$surface" | grep -q $'^symbol\tOld Section Heading\t$' \
  || fail "surface missing the renamed section header ($surface)"
# A symbol that survived the PR (poll_prs, still defined) must NOT appear.
printf '%s\n' "$surface" | grep -q 'poll_prs' && fail "surface flagged a symbol that still exists"
# do_new_thing / New Section Heading are the NEW names — never surfaced as moved-away.
printf '%s\n' "$surface" | grep -q 'do_new_thing'     && fail "surface flagged the new symbol name"
printf '%s\n' "$surface" | grep -q 'New Section Heading' && fail "surface flagged the new header name"
pass

# ── (2) scan: dangling entries reported; unrelated + new names excluded ────────
report="$(bash "$SCRIPT" scan "$RANGE")" || fail "scan exited non-zero"
[ "$report" != "NONE" ] || fail "scan reported NONE despite dangling references"
printf '%s\n' "$report" | grep -q 'Harden the watcher'  || fail "scan missed the agent-watch.sh reference"
printf '%s\n' "$report" | grep -q 'Docs polish'         || fail "scan missed the section-header reference"
printf '%s\n' "$report" | grep -q 'Drop legacy'         || fail "scan missed the legacy.sh delete reference"
# The unrelated item must NOT be flagged.
printf '%s\n' "$report" | grep -q 'Unrelated feature'   && fail "scan false-flagged an unrelated entry"
# Line numbers must be REAL (a bare '<file>:<n>' shape), never empty/misaligned.
printf '%s\n' "$report" | grep -qE $'^rename\tscripts/herd/agent-watch.sh\tscripts/herd/watcher.sh\t[0-9]+\t' \
  || fail "scan rename row is missing its line number ($report)"
pass

# ── (3) run: enqueues ONE scribe request via the seam; request is well-formed ──
REQ="$T/captured-request.txt"
cat > "$T/fake-scribe.sh" <<FS
#!/usr/bin/env bash
printf '%s\n' "\$1" > "$REQ"
FS
chmod +x "$T/fake-scribe.sh"
out="$(HERD_RECONCILE_SCRIBE="$T/fake-scribe.sh" bash "$SCRIPT" run "$RANGE")" \
  || fail "run exited non-zero"
printf '%s\n' "$out" | grep -q 'enqueued a scribe request' || fail "run did not report an enqueue ($out)"
[ -f "$REQ" ] || fail "run did not invoke the scribe seam"
grep -q 'Edit ONLY BACKLOG.md' "$REQ"                      || fail "request lacks the edit-only guard"
grep -q 'agent-watch.sh → scripts/herd/watcher.sh' "$REQ"  || fail "request lacks the file rename mapping"
grep -q 'do_old_thing'  "$REQ"                             || fail "request lacks the renamed symbol"
grep -q 'dangling ref'  "$REQ"                             || fail "request lacks the update-or-flag rule"
pass

# ── (4) run no-op: a rename-free range enqueues NOTHING ────────────────────────
git -C "$REPO" commit -q --allow-empty -m no-op-change
rm -f "$REQ"
out="$(HERD_RECONCILE_SCRIBE="$T/fake-scribe.sh" bash "$SCRIPT" run "HEAD~1..HEAD")" \
  || fail "run (no-op) exited non-zero"
printf '%s\n' "$out" | grep -q 'nothing to enqueue' || fail "run (no-op) should report nothing to enqueue ($out)"
[ -f "$REQ" ] && fail "run (no-op) must NOT invoke the scribe seam"
pass

# ── (5) scan no-op on a clean range → NONE ────────────────────────────────────
[ "$(bash "$SCRIPT" scan HEAD~1..HEAD)" = "NONE" ] || fail "scan of a rename-free range should be NONE"
pass

# ── (6) a rename whose old path is referenced by NO backlog entry → NONE ───────
git -C "$REPO" mv docs/guide.md docs/manual.md 2>/dev/null
# guide.md is not referenced by any entry (only its heading was); rename alone yields no path hit.
printf '# unrelated\n- 🔜 **x** — nothing\n' > "$REPO/BACKLOG.md"
git -C "$REPO" add -A
git -C "$REPO" commit -qm move-unreferenced
[ "$(bash "$SCRIPT" scan HEAD~1..HEAD)" = "NONE" ] || fail "scan should be NONE when no entry references the moved path"
pass

echo "ALL PASS ($PASS checks)"
