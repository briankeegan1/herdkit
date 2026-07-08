#!/usr/bin/env bash
# test-ledger.sh — hermetic tests for the coordinator progress ledger (scripts/herd/ledger.sh) and
# its `herd ledger` CLI surface (HERD-103). This is the named TEST SURFACE for the ledger read/write/
# update path. Covers:
#   (1) set → creates the file, writes one valid JSON line; get folds to the item's state; int/string
#       typing matches the journal (pr becomes a JSON number, slug stays a string)
#   (2) UPDATE — a second set for the same id field-merges (later value wins, new keys add); get shows
#       the merged current state, not duplicates
#   (3) list — every live id, sorted; --planned filters to items whose `planned` folds truthy; --json
#       emits a valid JSON array
#   (4) rm tombstones an id out of get (exit 1) and list; a later set REVIVES it
#   (5) compact folds superseded history + tombstones to one line per LIVE id WITHOUT losing current
#       state, and is atomic (the file is always readable)
#   (6) DEFAULT-DORMANT — with no writes there is NO file: get→exit 1, list→empty exit 0, path prints
#       the path but creates nothing
#   (7) concurrent set integrity — N racing writers → N whole parseable lines, fold is correct
#   (8) FAIL-SOFT — an unwritable ledger makes set return non-zero WITHOUT crashing a set -e caller and
#       without a torn line; reserved keys (id/ts/_deleted) can't be overridden through set
#   (9) id validation — empty / whitespace ids are refused (exit 2)
#  (10) the `herd ledger` CLI dispatch drives the same surface end-to-end against a hermetic project
#
# Fully hermetic: writes only under a mktemp dir via the LEDGER_FILE seam (and a temp .herd/config for
# the CLI leg); never touches the live watcher/panes/real HOME. NO herdr, NO gh, NO network, NO model.
# Run:  bash tests/test-ledger.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
LEDGER_SH="$REPO/scripts/herd/ledger.sh"
HERD_BIN="$REPO/bin/herd"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

[ -f "$LEDGER_SH" ] || fail "ledger.sh not found at $LEDGER_SH"
command -v python3 >/dev/null 2>&1 || fail "python3 required to run this test"

# L <args...> — invoke the ledger script with the current LEDGER_FILE seam exported.
L() { bash "$LEDGER_SH" "$@"; }

# _all_valid_json <file> — print the count of lines, failing if any non-empty line is not a JSON object.
_all_valid_json() {
  python3 -c '
import sys, json
n = 0
with open(sys.argv[1]) as f:
    for line in f:
        line = line.strip()
        if not line: continue
        o = json.loads(line)          # raises on a torn/partial line
        assert isinstance(o, dict)
        n += 1
print(n)
' "$1"
}

# ── (1) set creates the file + one valid line; get folds; int/string typing ──
export LEDGER_FILE="$T/l1/ledger.jsonl"
[ -e "$LEDGER_FILE" ] && fail "(1) ledger file should not exist before first write"
ok
L set HERD-10 slug feat-x worktree /trees/feat-x pr 42 lane feature status spawned >/dev/null \
  || fail "(1) set exited non-zero"
ok
[ -f "$LEDGER_FILE" ] || fail "(1) set must create the ledger file"
ok
[ "$(_all_valid_json "$LEDGER_FILE")" = "1" ] || fail "(1) first set should yield exactly 1 JSON line"
ok
get10="$(L get HERD-10)" || fail "(1) get of a present id should exit 0"
printf '%s\n' "$get10" | grep -q "id=HERD-10"      || fail "(1) get should show id"
printf '%s\n' "$get10" | grep -q "slug=feat-x"      || fail "(1) get should show slug"
printf '%s\n' "$get10" | grep -q "pr=42"            || fail "(1) get should show pr"
printf '%s\n' "$get10" | grep -q "status=spawned"   || fail "(1) get should show status"
ok
# pr is a JSON number, slug a string (mirrors journal int-coercion).
python3 -c '
import json,sys
o=json.loads(open(sys.argv[1]).read().strip().splitlines()[0])
assert isinstance(o["pr"], int), "pr should be a JSON number"
assert isinstance(o["slug"], str), "slug should be a JSON string"
' "$LEDGER_FILE" || fail "(1) int/string typing wrong"
ok

# ── (2) UPDATE: a second set field-merges (later wins, new keys add) ──
L set HERD-10 status in-review pr 42 reviewer opus >/dev/null || fail "(2) update set failed"
[ "$(_all_valid_json "$LEDGER_FILE")" = "2" ] || fail "(2) update should APPEND a second line"
ok
get10b="$(L get HERD-10)"
printf '%s\n' "$get10b" | grep -q "status=in-review" || fail "(2) later status must win"
printf '%s\n' "$get10b" | grep -q "slug=feat-x"       || fail "(2) unmentioned field must persist"
printf '%s\n' "$get10b" | grep -q "reviewer=opus"     || fail "(2) new field must be added"
# exactly one status token in the folded view (not duplicated).
[ "$(printf '%s\n' "$get10b" | grep -o 'status=[^ ]*' | wc -l | tr -d ' ')" = "1" ] \
  || fail "(2) folded view must not duplicate a field"
ok
# --json emits a single valid object with the merged state.
json10="$(L get HERD-10 --json)"
printf '%s' "$json10" | python3 -c '
import json,sys
o=json.load(sys.stdin)
assert o["status"]=="in-review" and o["slug"]=="feat-x" and o["reviewer"]=="opus"
' || fail "(2) get --json merged object wrong"
ok

# ── (3) list: multiple ids sorted; --planned filter; --json array ──
L set HERD-20 slug feat-y planned true note "queued behind HERD-10" >/dev/null || fail "(3) set HERD-20 failed"
L set HERD-05 slug feat-z planned false >/dev/null || fail "(3) set HERD-05 failed"
list_ids="$(L list | cut -f1)"
[ "$(printf '%s\n' "$list_ids")" = "$(printf 'HERD-05\nHERD-10\nHERD-20')" ] \
  || fail "(3) list should print live ids sorted (got: $list_ids)"
ok
planned_ids="$(L list --planned | cut -f1)"
[ "$planned_ids" = "HERD-20" ] || fail "(3) --planned should list only truthy-planned items (got: $planned_ids)"
ok
L list --json | python3 -c '
import json,sys
arr=json.load(sys.stdin)
ids=sorted(o["id"] for o in arr)
assert ids==["HERD-05","HERD-10","HERD-20"], ids
assert isinstance(arr,list)
' || fail "(3) list --json array wrong"
ok

# ── (4) rm tombstones out of get/list; a later set revives ──
L rm HERD-20 >/dev/null || fail "(4) rm failed"
if L get HERD-20 >/dev/null 2>&1; then fail "(4) get of a tombstoned id must exit non-zero"; fi
ok
L list | cut -f1 | grep -qx HERD-20 && fail "(4) tombstoned id must not appear in list"
ok
L set HERD-20 slug feat-y status respawned >/dev/null || fail "(4) revive set failed"
rev="$(L get HERD-20)" || fail "(4) revived id should be gettable"
printf '%s\n' "$rev" | grep -q "status=respawned" || fail "(4) revived id should carry the new field"
# revive starts fresh after a tombstone: the pre-rm `planned`/`note` must NOT resurrect.
printf '%s\n' "$rev" | grep -q "note=" && fail "(4) tombstone must clear prior fields (note leaked)"
ok

# ── (5) compact: fold history to one line per live id, lossless for current state, atomic ──
before_state="$(L get HERD-10)"
L compact || fail "(5) compact exited non-zero"
after_state="$(L get HERD-10)"
[ "$before_state" = "$after_state" ] || fail "(5) compact must preserve current state exactly"
ok
# One line per live id (HERD-05, HERD-10, HERD-20) → 3 lines; superseded history + no tombstone lines.
[ "$(_all_valid_json "$LEDGER_FILE")" = "3" ] || fail "(5) compact should leave exactly 3 lines (one per live id)"
ok
L list | cut -f1 | grep -qx HERD-20 || fail "(5) a revived id must survive compaction"
ok

# ── (6) DEFAULT-DORMANT: no file → get exit 1, list empty exit 0, path creates nothing ──
export LEDGER_FILE="$T/dormant/ledger.jsonl"
if L get HERD-99 >/dev/null 2>&1; then fail "(6) get on an absent ledger must exit non-zero"; fi
ok
out="$(L list)"; rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] || fail "(6) list on an absent ledger must be empty + exit 0"
ok
p="$(L path)" || fail "(6) path must succeed even with no file"
[ "$p" = "$LEDGER_FILE" ] || fail "(6) path should print the resolved LEDGER_FILE (got: $p)"
[ -e "$LEDGER_FILE" ] && fail "(6) path must NOT create the file"
ok

# ── (7) concurrent set integrity: N racing writers → N whole lines, correct fold ──
export LEDGER_FILE="$T/l7/ledger.jsonl"
mkdir -p "$T/l7"
N=30
for i in $(seq 1 "$N"); do
  ( L set "HERD-$i" slug "s-$i" note "item $i with spaces" pr "$i" >/dev/null 2>&1 ) &
done
wait
got="$(_all_valid_json "$LEDGER_FILE")" || fail "(7) concurrent set produced a torn JSON line"
[ "$got" = "$N" ] || fail "(7) concurrent set: expected $N whole lines, got $got"
ok
[ "$(L list | wc -l | tr -d ' ')" = "$N" ] || fail "(7) fold should show $N distinct live ids"
ok

# ── (8) FAIL-SOFT: unwritable ledger → set non-zero, no crash under set -e; reserved keys protected ──
: > "$T/blocker"    # a FILE where a dir is needed → mkdir of the ledger dir cannot succeed
out="$(bash -c '
  set -euo pipefail
  export LEDGER_FILE="'"$T"'/blocker/sub/ledger.jsonl"
  if bash "'"$LEDGER_SH"'" set HERD-1 slug x >/dev/null 2>&1; then echo UNEXPECTED_OK; else echo HANDLED; fi
  echo SURVIVED
')"
printf '%s\n' "$out" | grep -qx SURVIVED || fail "(8) a failed write must not abort a set -e caller"
printf '%s\n' "$out" | grep -qx HANDLED  || fail "(8) an unwritable set should report failure (non-zero)"
ok
# Reserved keys can't be overridden through the k/v API (id/ts/_deleted stay engine-managed).
export LEDGER_FILE="$T/l8/ledger.jsonl"
L set HERD-1 id HACKED ts NOPE _deleted true slug real >/dev/null || fail "(8) reserved-key set failed"
python3 -c '
import json,sys
o=json.loads(open(sys.argv[1]).read().strip().splitlines()[0])
assert o["id"]=="HERD-1", "id must not be overridable via k/v"
assert o["ts"]!="NOPE", "ts must not be overridable via k/v"
assert "_deleted" not in o, "_deleted must not be settable via k/v (rm owns tombstones)"
assert o["slug"]=="real"
' "$LEDGER_FILE" || fail "(8) reserved keys leaked through set"
# The item is still LIVE (the bogus _deleted k/v was ignored, so `get` finds it).
L get HERD-1 >/dev/null || fail "(8) item wrongly tombstoned by a k/v _deleted"
ok

# ── (9) id validation: empty / whitespace ids refused ──
export LEDGER_FILE="$T/l9/ledger.jsonl"
if L set "" slug x >/dev/null 2>&1;      then fail "(9) an empty id must be refused"; fi
if L set "HERD 1" slug x >/dev/null 2>&1; then fail "(9) an id with whitespace must be refused"; fi
ok

# ── (10) `herd ledger` CLI dispatch drives the surface against a hermetic project ──
PROJ="$T/proj"; TREES="$T/trees"
mkdir -p "$PROJ/.herd" "$TREES/.herd"
cat > "$PROJ/.herd/config" <<CFG
PROJECT_ROOT="$PROJ"
WORKTREES_DIR="$TREES"
WORKSPACE_NAME="ledgertest"
CFG
unset LEDGER_FILE   # let the CLI resolve the path from the project's WORKTREES_DIR
( cd "$PROJ" && bash "$HERD_BIN" ledger set HERD-77 slug cli-feat pr 7 status spawned ) >/dev/null \
  || fail "(10) herd ledger set failed"
[ -f "$TREES/.herd/ledger.jsonl" ] || fail "(10) CLI should write to WORKTREES_DIR/.herd/ledger.jsonl"
ok
cli_get="$(cd "$PROJ" && bash "$HERD_BIN" ledger get HERD-77)" || fail "(10) herd ledger get failed"
printf '%s\n' "$cli_get" | grep -q "slug=cli-feat" || fail "(10) CLI get should fold the item"
printf '%s\n' "$cli_get" | grep -q "pr=7"           || fail "(10) CLI get should show pr"
ok
cli_path="$(cd "$PROJ" && bash "$HERD_BIN" ledger path)"
[ "$cli_path" = "$TREES/.herd/ledger.jsonl" ] || fail "(10) herd ledger path wrong (got: $cli_path)"
ok

echo "ALL PASS ($pass checks)"
