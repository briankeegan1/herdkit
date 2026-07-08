#!/usr/bin/env bash
# ledger.sh — the COORDINATOR PROGRESS LEDGER (HERD-103): durable, cross-session coordinator state so
# a coordinator (or a second operator) can RESUME with an accurate picture instead of re-deriving it
# from herdr/gh/backlog every session. It records, per tracked work item (keyed by tracker id), the
# coordinator-side facts that are otherwise only in the coordinator's head: what was spawned, its
# slug/worktree/PR, sequencing decisions, and planned-but-not-yet-spawned markers.
#
# This is COORDINATOR-SIDE state — NOT a watcher gate. The watcher never reads it; nothing merges on
# it. It complements the engine journal (scripts/herd/journal.sh): the journal is the append-only
# forensic record of GATE events (dispatch/verdict/merge), the ledger is the coordinator's editable
# working memory of PLAN + PROGRESS per item. Where the journal answers "what happened to PR #N",
# the ledger answers "what did I decide about HERD-X, and where did it land".
#
# STORAGE — one JSONL file at $WORKTREES_DIR/.herd/ledger.jsonl (a test seam, LEDGER_FILE, overrides
# the path outright). It lives in the sibling worktree pool exactly like the journal, so it is LOCAL,
# per-machine state that is NEVER committed (covered by the repo's *-trees/ gitignore, and named
# explicitly in .gitignore for projects that keep .herd inside the tree). It is ZERO-SECRET by
# contract — callers must never write credentials into it.
#
# APPEND-OR-UPDATE — every `set`/`rm` APPENDS one JSON line (an atomic, sub-PIPE_BUF O_APPEND write,
# so concurrent writers interleave whole lines — same discipline as the journal, no lockfile). A read
# (`get`/`list`) FOLDS all lines for an id in file order: later fields override earlier ones (field-
# level merge), so an update is just another line. `rm` appends a tombstone that folds the id out;
# a later `set` revives it. `compact` optionally rewrites the file to one folded line per live id.
#
# FAIL-SOFT / DEFAULT-DORMANT — with the feature UNUSED no file exists and nothing here runs, so
# existing behavior is byte-identical. `get`/`list`/`path` on an absent ledger succeed quietly
# (get of a missing id → exit 1, no output). A write that genuinely cannot land warns to stderr and
# returns non-zero, but is wrapped so it can never partially corrupt the file.
#
# Subcommands:
#   set <id> [key value]...   Append an update for <id>. Reserved keys (id, ts) are managed here;
#                             every other key/value is stored verbatim. Integer-looking values become
#                             JSON numbers, everything else a string (mirrors the journal). With no
#                             key/value pairs it stamps the id's existence (an empty update + ts).
#                             Typical keys: slug worktree pr lane status seq planned note.
#   get <id> [--json]         Print <id>'s folded current state. Default: `key=value` lines (id + ts
#                             first, then keys sorted). --json prints the merged JSON object. Exit 0
#                             if present, 1 if the id is absent or tombstoned.
#   list [--json] [--planned] Print every live id. Default: one `id<TAB>k=v k=v ...` line per id,
#                             ids sorted. --json prints a JSON array of the folded objects. --planned
#                             restricts to items whose folded `planned` field is truthy.
#   rm <id>                   Append a tombstone so <id> folds out of get/list (history is retained).
#   compact                   Rewrite the ledger to one folded line per LIVE id (drops superseded
#                             history + tombstones). Atomic temp-file + rename. Run when quiescent.
#   path                      Print the resolved ledger file path (create nothing).
#
# Run:  bash scripts/herd/ledger.sh <sub> [args...]   (or `herd ledger <sub> ...`)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/herd-config.sh"

# _ledger_file — resolve the ledger path. LEDGER_FILE (test seam) wins; else derive from WORKTREES_DIR.
# Empty output ⇒ no destination (WORKTREES_DIR unset) ⇒ callers degrade gracefully.
_ledger_file() {
  if [ -n "${LEDGER_FILE:-}" ]; then printf '%s' "$LEDGER_FILE"; return 0; fi
  [ -n "${WORKTREES_DIR:-}" ] || return 1
  printf '%s' "$WORKTREES_DIR/.herd/ledger.jsonl"
}

# _die_usage — print usage to stderr and exit 2 (a usage error, distinct from a not-found exit 1).
_die_usage() {
  printf 'usage: ledger.sh set <id> [key value]... | get <id> [--json] | list [--json] [--planned] | rm <id> | compact | path\n' >&2
  exit 2
}

# _require_id <id> — a tracker id must be a non-empty token with no whitespace (it is the fold key and
# must round-trip through JSON + a `list` line cleanly). Rejects the empty string and embedded spaces/
# tabs/newlines loudly rather than silently keying state under a malformed id.
_require_id() {
  local id="${1:-}"
  [ -n "$id" ] || { printf 'ledger.sh: an <id> is required\n' >&2; exit 2; }
  case "$id" in
    *[[:space:]]*) printf 'ledger.sh: <id> must not contain whitespace (got %q)\n' "$id" >&2; exit 2 ;;
  esac
}

# _append <id> <deleted:0|1> [key value]... — encode one JSON line via python3 (correct escaping of
# arbitrary values) and atomically append it. Best-effort but HONEST: unlike the journal it returns
# non-zero (and warns) when the write cannot land, so a caller that cares can detect it — but it can
# never write a torn or partial line. Reserved keys (id/ts/_deleted) are managed here; a caller that
# passes them as k/v is ignored for those names so state can't be corrupted through the public API.
_append() {
  local id="$1" deleted="$2"; shift 2
  local lf; lf="$(_ledger_file)" || { printf 'ledger.sh: no WORKTREES_DIR — cannot resolve ledger path\n' >&2; return 1; }
  [ -n "$lf" ] || { printf 'ledger.sh: empty ledger path — cannot write\n' >&2; return 1; }
  local dir="${lf%/*}"
  [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null || { printf 'ledger.sh: cannot create %s\n' "$dir" >&2; return 1; }
  command -v python3 >/dev/null 2>&1 || { printf 'ledger.sh: python3 required to write the ledger\n' >&2; return 1; }

  local ts line
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" || ts=""
  line="$(HERD_L_ID="$id" HERD_L_TS="$ts" HERD_L_DEL="$deleted" python3 -c '
import sys, json, os
obj = {"id": os.environ["HERD_L_ID"], "ts": os.environ["HERD_L_TS"]}
if os.environ.get("HERD_L_DEL") == "1":
    obj["_deleted"] = True
a = sys.argv[1:]
for i in range(0, len(a) - 1, 2):
    k, v = a[i], a[i + 1]
    if k in ("id", "ts", "_deleted"):   # reserved — managed above, never overridable via k/v
        continue
    if v and v.lstrip("-").isdigit():   # clean integers → JSON numbers (pr, attempt); else strings
        try:
            obj[k] = int(v); continue
        except ValueError:
            pass
    obj[k] = v
sys.stdout.write(json.dumps(obj, separators=(",", ":"), ensure_ascii=False))
' "$@" 2>/dev/null)" || { printf 'ledger.sh: failed to encode the update\n' >&2; return 1; }
  [ -n "$line" ] || { printf 'ledger.sh: empty encoded line — refusing to write\n' >&2; return 1; }

  # Single O_APPEND write of a sub-PIPE_BUF line ⇒ concurrent-writer safe (whole-line interleave).
  printf '%s\n' "$line" >> "$lf" 2>/dev/null || { printf 'ledger.sh: cannot append to %s\n' "$lf" >&2; return 1; }
  return 0
}

# _fold — read a ledger file on stdin and print, on stdout, one JSON object per LIVE id (tombstoned or
# never-set ids excluded), folding all lines for each id in file order with later fields overriding
# earlier ones. Reads $HERD_L_MODE to shape the output (see readers below). Pure/read-only.
_FOLD_PY='
import sys, json, os
mode = os.environ.get("HERD_L_MODE", "list")     # list | list-json | get | get-json
want = os.environ.get("HERD_L_WANT", "")          # id filter for get modes
planned_only = os.environ.get("HERD_L_PLANNED", "") == "1"

order = []          # first-seen id order (stable, then sorted for output)
state = {}          # id -> folded dict (with "_deleted" flag tracking)
for raw in sys.stdin:
    raw = raw.strip()
    if not raw:
        continue
    try:
        o = json.loads(raw)
    except Exception:
        continue                                  # skip a torn/foreign line rather than abort
    if not isinstance(o, dict):
        continue
    _id = o.get("id")
    if not isinstance(_id, str) or not _id:
        continue
    if _id not in state:
        order.append(_id); state[_id] = {}
    cur = state[_id]
    if o.get("_deleted") is True:
        cur.clear(); cur["__deleted__"] = True    # tombstone: reset, mark removed (a later set revives)
        continue
    cur.pop("__deleted__", None)                   # any non-tombstone line revives the id
    for k, v in o.items():
        if k == "_deleted":
            continue
        cur[k] = v                                 # later value wins (field-level merge = update)

def truthy(v):
    if isinstance(v, bool): return v
    if isinstance(v, (int, float)): return v != 0
    if isinstance(v, str): return v.strip().lower() not in ("", "0", "false", "no", "off")
    return v is not None

def is_live(d):
    return not d.get("__deleted__", False)

def clean(d):
    return {k: v for k, v in d.items() if k != "__deleted__"}

def render_kv(d):
    # id + ts first, then remaining keys sorted — a stable, greppable one-item view.
    keys = [k for k in ("id", "ts") if k in d] + sorted(k for k in d if k not in ("id", "ts"))
    return " ".join("%s=%s" % (k, d[k]) for k in keys)

if mode in ("get", "get-json"):
    d = state.get(want)
    if d is None or not is_live(d):
        sys.exit(1)                                # absent or tombstoned → not found
    d = clean(d)
    if mode == "get-json":
        sys.stdout.write(json.dumps(d, separators=(",", ":"), ensure_ascii=False, sort_keys=True))
    else:
        sys.stdout.write(render_kv(d))
    sys.exit(0)

# list / list-json
live = []
for _id in sorted(order):
    d = state[_id]
    if not is_live(d):
        continue
    d = clean(d)
    if planned_only and not truthy(d.get("planned")):
        continue
    live.append(d)

if mode == "list-json":
    sys.stdout.write(json.dumps(live, separators=(",", ":"), ensure_ascii=False, sort_keys=True))
    sys.stdout.write("\n")
else:
    for d in live:
        # id<TAB>rest, where rest is the sorted k=v view WITHOUT the id (it is already the first column).
        rest = {k: v for k, v in d.items() if k != "id"}
        keys = [k for k in ("ts",) if k in rest] + sorted(k for k in rest if k != "ts")
        line = " ".join("%s=%s" % (k, rest[k]) for k in keys)
        sys.stdout.write("%s\t%s\n" % (d["id"], line))
'

# _read <mode> [id] — run the fold over the current ledger file in the requested mode. Returns the
# python exit status (get modes return 1 when the id is absent). A missing file folds to "empty".
_read() {
  local mode="$1" want="${2:-}"
  local lf; lf="$(_ledger_file)" || return 0
  [ -n "$lf" ] && [ -f "$lf" ] || {
    # Absent ledger: list modes emit nothing (exit 0); get modes are "not found" (exit 1).
    case "$mode" in get|get-json) return 1 ;; *) return 0 ;; esac
  }
  command -v python3 >/dev/null 2>&1 || { printf 'ledger.sh: python3 required to read the ledger\n' >&2; return 1; }
  HERD_L_MODE="$mode" HERD_L_WANT="$want" HERD_L_PLANNED="${HERD_L_PLANNED:-}" python3 -c "$_FOLD_PY" < "$lf"
}

cmd="${1:-}"; shift 2>/dev/null || true
case "$cmd" in
  set)
    id="${1:-}"; _require_id "$id"; shift
    # Remaining args are key/value pairs; an odd trailing arg (key with no value) is a usage error.
    [ $(( $# % 2 )) -eq 0 ] || { printf 'ledger.sh set: key/value args must be paired (odd arg count)\n' >&2; exit 2; }
    _append "$id" 0 "$@" || exit 1
    ;;
  rm)
    id="${1:-}"; _require_id "$id"
    _append "$id" 1 || exit 1
    ;;
  get)
    id="${1:-}"; _require_id "$id"; shift
    mode="get"
    case "${1:-}" in
      --json) mode="get-json" ;;
      "") ;;
      *) _die_usage ;;
    esac
    _read "$mode" "$id" || exit 1
    printf '\n'
    ;;
  list)
    mode="list"; export HERD_L_PLANNED=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --json)    mode="list-json" ;;
        --planned) HERD_L_PLANNED=1 ;;
        *) _die_usage ;;
      esac
      shift
    done
    _read "$mode" || exit 1
    ;;
  compact)
    lf="$(_ledger_file)" || { printf 'ledger.sh: no WORKTREES_DIR — cannot resolve ledger path\n' >&2; exit 1; }
    [ -n "$lf" ] && [ -f "$lf" ] || exit 0    # nothing to compact (dormant) — success, no-op
    command -v python3 >/dev/null 2>&1 || { printf 'ledger.sh: python3 required to compact\n' >&2; exit 1; }
    dir="${lf%/*}"
    # Fold to one JSON line per live id, write to a sibling temp, then atomically rename over the file.
    tmp="$(HERD_L_LF="$lf" python3 -c '
import sys, json, os, tempfile
lf = os.environ["HERD_L_LF"]
order, state = [], {}
with open(lf, encoding="utf-8") as f:
    for raw in f:
        raw = raw.strip()
        if not raw:
            continue
        try:
            o = json.loads(raw)
        except Exception:
            continue
        if not isinstance(o, dict):
            continue
        _id = o.get("id")
        if not isinstance(_id, str) or not _id:
            continue
        if _id not in state:
            order.append(_id); state[_id] = {}
        cur = state[_id]
        if o.get("_deleted") is True:
            cur.clear(); cur["__deleted__"] = True; continue
        cur.pop("__deleted__", None)
        for k, v in o.items():
            if k == "_deleted":
                continue
            cur[k] = v
d = os.path.dirname(lf) or "."
fd, tmp = tempfile.mkstemp(dir=d, prefix=".ledger.", suffix=".tmp")
with os.fdopen(fd, "w", encoding="utf-8") as out:
    for _id in sorted(order):
        cur = state[_id]
        if cur.get("__deleted__"):
            continue
        obj = {k: v for k, v in cur.items() if k != "__deleted__"}
        out.write(json.dumps(obj, separators=(",", ":"), ensure_ascii=False) + "\n")
sys.stdout.write(tmp)
' 2>/dev/null)" || { printf 'ledger.sh: compaction failed\n' >&2; exit 1; }
    [ -n "$tmp" ] && [ -f "$tmp" ] || { printf 'ledger.sh: compaction produced no output\n' >&2; exit 1; }
    if ! mv -f "$tmp" "$lf" 2>/dev/null; then
      rm -f "$tmp" 2>/dev/null || true
      printf 'ledger.sh: could not replace %s\n' "$lf" >&2; exit 1
    fi
    ;;
  path)
    lf="$(_ledger_file)" || { printf 'ledger.sh: no WORKTREES_DIR — cannot resolve ledger path\n' >&2; exit 1; }
    printf '%s\n' "$lf"
    ;;
  ""|-h|--help|help) _die_usage ;;
  *) printf 'ledger.sh: unknown subcommand %q\n' "$cmd" >&2; _die_usage ;;
esac
