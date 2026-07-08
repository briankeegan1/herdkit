#!/usr/bin/env bash
# test-scribe-auto-marker.sh — hermetic tests for the MECHANICAL planned-marker (HERD-183). When the
# scribe drainer files an Add whose body carries an EXPLICIT, ANCHORED sequencing clause
# ("hard-after HERD-<n>", "sequenced after HERD-<n>", "after HERD-<n> merges", "blocked on HERD-<n>"),
# scribe-step.sh must ALSO auto-run `herd backlog queue <new-id> --after <blocker>` so the prose
# sequencing becomes a machine-readable 📌 marker. An Add with NO such clause must be byte-identical to
# before — nothing queued.
#
# The test drives scribe-step.sh against a FAKE backend whose _backend_add_item surfaces a stable
# identifier, and stubs the `herd` CLI (via the HERD_CLI seam) to RECORD each `backlog queue …`
# invocation. It asserts the auto-marker decision directly — no network, no real backend, no real
# `herd`, no repo writes outside a temp dir. Run:
#     bash tests/test-scribe-auto-marker.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
STEP="$HERE/../scripts/herd/scribe-step.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ pass=$((pass+1)); }

# ── Stub herdr on PATH so no real notification/tab is ever touched ────────────
BIN="$T/bin"; mkdir -p "$BIN"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/herdr"; chmod +x "$BIN/herdr"
export PATH="$BIN:$PATH"

# ── A stub `herd` CLI that logs every `backlog queue …` call to $QUEUELOG ──────
# Records "<ref>\t<blocker>" so the test can assert the exact (new-id, blocker) the auto-marker chose.
QUEUELOG="$T/queue.log"
HERD_CLI="$T/herd-stub"
cat > "$HERD_CLI" <<HERDEOF
#!/usr/bin/env bash
if [ "\$1" = "backlog" ] && [ "\$2" = "queue" ]; then
  ref="\$3"; blocker=""
  [ "\$4" = "--after" ] && blocker="\$5"
  printf 'QUEUE\t%s\t%s\n' "\$ref" "\$blocker" >> "$QUEUELOG"
fi
exit 0
HERDEOF
chmod +x "$HERD_CLI"
export HERD_CLI

# ── A temp git repo + a .herd/config the step script sources ──────────────────
REPO="$T/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email t@t.t; git -C "$REPO" config user.name t
git -C "$REPO" commit -q --allow-empty -m init
TREES="$T/trees"; Q="$TREES/backlog-queue"; INBOX="$TREES/.scribe-reports"; mkdir -p "$Q"

# ── A FAKE backend whose add surfaces a stable identifier (the "new id") ───────
FAKEDIR="$T/fakebackends"; mkdir -p "$FAKEDIR"
DISPATCH="$T/dispatch.log"
cat > "$FAKEDIR/fake.sh" <<FAKEEOF
#!/usr/bin/env bash
_backend_add_item() { printf 'ADD\t%s\n' "\$2" >> "$DISPATCH"; printf 'HERD-900\n'; _BACKEND_RESULT="DONE"; }
_backend_mark_shipped() { :; }
_backend_list_open() { :; }
_backend_item_state() { ITEM_STATE="open"; }
FAKEEOF

CFG="$T/config"
cat > "$CFG" <<CFGEOF
HERD_VERSION=1
PROJECT_ROOT="$REPO"
WORKTREES_DIR="$TREES"
DEFAULT_BRANCH="origin/main"
WORKSPACE_NAME="markertest"
HERD_REMOTE="origin"
HERD_BRANCH_NAME="main"
BACKLOG_FILE="BACKLOG.md"
SCRIBE_BACKEND="fake"
CFGEOF

# step add-item <path> <text> — run scribe-step from inside $REPO against the fake backend + herd stub.
step() {
  set +e
  OUT="$( cd "$REPO" && HERD_CONFIG_FILE="$CFG" SCRIBE_BACKEND_DIR="$FAKEDIR" SCRIBE_POLL=0 \
            bash "$STEP" "$@" 2>&1 )"
  RC=$?
  set -e
}
mkreq() { local p="$Q/$1.req.mine"; printf '%s\n' "$2" > "$p"; printf '%s' "$p"; }

: > "$DISPATCH"; : > "$QUEUELOG"

# ══ 1. An Add WITH an explicit clause auto-queues the NEW id after the blocker ════════════════════
p="$(mkreq 100 "Refactor the drainer. hard-after HERD-52 so the seam lands first.")"
step add-item "$p" "Refactor the drainer. hard-after HERD-52 so the seam lands first."
[ "$RC" -eq 0 ]                                       || fail "1: add-item exited $RC ($OUT)"
grep -qE $'^ADD\t' "$DISPATCH"                        || fail "1: the item was not filed ($(cat "$DISPATCH"))"
grep -qE $'^QUEUE\tHERD-900\tHERD-52$' "$QUEUELOG"    || fail "1: did not auto-queue HERD-900 after HERD-52 ($(cat "$QUEUELOG"))"
printf '%s\n' "$OUT" | grep -q '📌 sequenced HERD-900 after HERD-52' || fail "1: no auto-marker confirmation in output ($OUT)"
[ ! -e "$p" ]                                         || fail "1: claimed file not cleaned up"
ok

# ══ 2. An Add with NO sequencing clause queues NOTHING (byte-identical add path) ══════════════════
: > "$DISPATCH"; : > "$QUEUELOG"
p="$(mkreq 200 "Add a dark-mode toggle to the settings pane")"
step add-item "$p" "Add a dark-mode toggle to the settings pane"
[ "$RC" -eq 0 ]                                       || fail "2: add-item exited $RC ($OUT)"
grep -qE $'^ADD\t' "$DISPATCH"                        || fail "2: the item was not filed"
[ ! -s "$QUEUELOG" ]                                  || fail "2: a clause-free Add wrongly queued a marker ($(cat "$QUEUELOG"))"
ok

# ══ 3. Every anchored clause form resolves the right blocker id ═══════════════════════════════════
check_clause() {  # <n> <blocker> <body>
  : > "$QUEUELOG"
  local p; p="$(mkreq "$1" "$3")"
  step add-item "$p" "$3"
  grep -qE $'^QUEUE\tHERD-900\t'"$2"'$' "$QUEUELOG" || fail "3: '$3' → expected blocker $2 ($(cat "$QUEUELOG"))"
}
check_clause 301 HERD-11 "New indexer. sequenced after HERD-11."
check_clause 302 HERD-12 "New indexer. sequence after HERD-12."
check_clause 303 HERD-13 "Land the migration after HERD-13 merges, please."
check_clause 304 HERD-14 "Blocked on HERD-14 — needs its schema first."
check_clause 305 HERD-15 "hard-after HERD-15"
ok

# ══ 4. Case-insensitive keyword; the id is normalized to canonical upper-case HERD-<n> ════════════
: > "$QUEUELOG"
p="$(mkreq 400 "cleanup. BLOCKED ON herd-77 before this ships.")"
step add-item "$p" "cleanup. BLOCKED ON herd-77 before this ships."
grep -qE $'^QUEUE\tHERD-900\tHERD-77$' "$QUEUELOG"    || fail "4: case-insensitive clause not normalized ($(cat "$QUEUELOG"))"
ok

# ══ 5. Near-miss / fuzzy prose does NOT publish (conservative, anchored-only) ═════════════════════
nomatch() {  # <n> <body>
  : > "$QUEUELOG"
  local p; p="$(mkreq "$1" "$2")"
  step add-item "$p" "$2"
  [ ! -s "$QUEUELOG" ] || fail "5: fuzzy prose wrongly published a marker: '$2' ($(cat "$QUEUELOG"))"
}
nomatch 501 "Do this after HERD-5 (no 'merges' anchor — just a bare mention)."
nomatch 502 "This is unblocked on HERD-5 now, go ahead."          # word-boundary: 'blocked' is inside 'unblocked'
nomatch 503 "Should probably come after the auth work sometime."   # no HERD-id at all
nomatch 504 "See HERD-9 for context; not a dependency."            # bare id reference, no sequencing keyword
ok

# ══ 6. First anchored clause in reading order wins when several are present ════════════════════════
: > "$QUEUELOG"
p="$(mkreq 600 "Big change. blocked on HERD-40, and also sequenced after HERD-41.")"
step add-item "$p" "Big change. blocked on HERD-40, and also sequenced after HERD-41."
grep -qE $'^QUEUE\tHERD-900\tHERD-40$' "$QUEUELOG"    || fail "6: first-in-reading-order blocker not chosen ($(cat "$QUEUELOG"))"
ok

# ══ 7. FAIL-SOFT: a backend that surfaces no id for the new item queues nothing, still filing ══════
# Point at a fake backend whose add prints no identifier — the auto-marker must skip (soft note),
# NEVER hard-fail, and the item is still reported as filed.
: > "$DISPATCH"; : > "$QUEUELOG"
NOIDDIR="$T/noidbackends"; mkdir -p "$NOIDDIR"
cat > "$NOIDDIR/fake.sh" <<'NOIDEOF'
#!/usr/bin/env bash
_backend_add_item() { _BACKEND_RESULT="DONE"; }   # DONE but no id on stdout
_backend_mark_shipped() { :; }
_backend_list_open() { :; }
_backend_item_state() { ITEM_STATE="open"; }
NOIDEOF
p="$(mkreq 700 "New thing. hard-after HERD-99.")"
set +e
OUT="$( cd "$REPO" && HERD_CONFIG_FILE="$CFG" SCRIBE_BACKEND_DIR="$NOIDDIR" SCRIBE_POLL=0 \
          bash "$STEP" add-item "$p" "New thing. hard-after HERD-99." 2>&1 )"
RC=$?
set -e
[ "$RC" -eq 0 ]                                       || fail "7: no-id add-item hard-failed ($OUT)"
[ ! -s "$QUEUELOG" ]                                  || fail "7: queued despite no surfaced id ($(cat "$QUEUELOG"))"
printf '%s\n' "$OUT" | grep -q 'surfaced no id'      || fail "7: no soft note about the missing id ($OUT)"
ok

echo "ALL PASS ($pass checks)"
