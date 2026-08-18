#!/usr/bin/env bash
# test-json-output.sh — HERD-759: the coordinator-facing `--json` machine contracts.
#
# `herd status`, `herd backlog`, `herd agents list` and `herd why <pr#>` each grew an ADDITIVE
# `--json` form so a NON-CLAUDE coordinator runtime (or any script) can read engine state without
# scraping console text or pane contents. Two things must hold for every one of them, and this file
# asserts both per command:
#
#   (a) PLAIN TEXT IS UNCHANGED. Without the flag the human output is byte-for-byte what it was —
#       asserted against a committed golden (or, where one line of the render carries a driver
#       version string that legitimately moves with the engine, against exact golden LINES).
#   (b) --json EMITS THE DOCUMENTED CONTRACT. Valid, parseable JSON carrying the documented field
#       NAMES and TYPES for a real scenario, checked field by field — not merely "it parses".
#
# Fully hermetic: a mktemp project with a fixture .herd/config, backlog file, agent roster and
# journal, plus a stub `gh` on PATH for the one case that needs an id-minting backend. No real
# watcher, pane, network, gh or HOME is touched; `herd status` is driven through the
# HERD_STATUS_SNAPSHOT_FILE seam, so no live probe runs either.
# Run:  bash tests/test-json-output.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
HERD="$REPO/bin/herd"

command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 required" >&2; exit 1; }
[ -f "$HERD" ] || { echo "FAIL: bin/herd not found at $HERD" >&2; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ PASS=$((PASS+1)); }

# jq is NOT assumed (the engine never requires it); every assertion reads the JSON through python3,
# which the CLI itself already depends on.
# jget <json-file> <python-expr over `d`> — print one value, or FAIL loudly on unparseable JSON.
jget() {
  JF="$1" EXPR="$2" python3 -c '
import os, sys, json
try:
    d = json.load(open(os.environ["JF"], encoding="utf-8"))
except Exception as e:
    sys.stderr.write("not valid JSON: %s\n" % e); sys.exit(2)
v = eval(os.environ["EXPR"], {}, {"d": d})
if isinstance(v, bool):
    print("true" if v else "false")
elif v is None:
    print("null")
else:
    print(v)
'
}
# jeq <label> <json-file> <expr> <expected>
jeq() {
  local got; got="$(jget "$2" "$3")" || fail "$1: JSON did not parse"
  [ "$got" = "$4" ] || fail "$1: expected '$4', got '$got'  (expr: $3)"
}

# ── fixture project ──────────────────────────────────────────────────────────────────────────────
P="$T/proj"; TREES="$T/proj-trees"
mkdir -p "$P/.herd/agents" "$TREES/.herd"
cat > "$P/.herd/config" <<CFG
PROJECT_ROOT=$P
WORKTREES_DIR=$TREES
WORKSPACE_NAME=fixtureproj
DEFAULT_BRANCH=origin/main
SCRIBE_BACKEND=file
BACKLOG_FILE=BACKLOG.md
HERD_DRIVER=herdr-claude
CFG
cat > "$P/BACKLOG.md" <<'EOF'
# fixtureproj — backlog
## Now
- 🚧 wiring the feedback loop
## Next
- 🔜 add a dark-mode toggle
## Recently shipped
- ✅ already done
EOF
cat > "$P/.herd/agents/gate-rails.md" <<'EOF'
---
name: gate-rails
description: fixture specialist — knows the gate rails.
sentinel: FIXTURE-SENTINEL-1
---
Body.
EOF
# A file in the roster dir that is NOT a definition (HERD-732) — it must land in `skipped`, not in
# `definitions`, on the JSON path exactly as it does on the text path.
cat > "$P/.herd/agents/README.md" <<'EOF'
Not a definition — just docs.
EOF
cat > "$TREES/.herd/journal.jsonl" <<'JNL'
{"ts":"2026-07-10T00:00:01Z","event":"review_dispatched","pr":"77","sha":"0011223344556677","model":"opus","pid":"900"}
{"ts":"2026-07-10T00:00:02Z","event":"healthcheck_outcome","pr":"77","outcome":"clean","detail":""}
{"ts":"2026-07-10T00:00:03Z","event":"verdict_recorded","pr":"77","value":"PASS","source":"panel","sha":"0011223344556677"}
{"ts":"2026-07-10T00:00:04Z","event":"merge","pr":"77","sha":"0011223344556677","method":"squash","reason":"gate-green"}
JNL

# run <args...> → the real CLI in the fixture project; stdout to $T/out, stderr to $T/err, exit in $RC.
RC=0
run() {
  ( cd "$P" && HERD_NONINTERACTIVE=1 HERD_CONFIG_FILE="$P/.herd/config" \
      bash "$HERD" "$@" >"$T/out" 2>"$T/err" )
  RC=$?
}

# ── (1) herd status ──────────────────────────────────────────────────────────────────────────────
# Driven through HERD_STATUS_SNAPSHOT_FILE, which skips gather entirely: the FORMAT stage is the only
# thing --json touches, and a committed snapshot pins the input bytes both formatters see.
HEALTHY="$T/healthy.snapshot"
printf 'WORKSPACE\037fixtureproj\nROOT\037/tmp/p\nWATCHER\037alive\0374242\0371\037\nBCOUNTS\0371\0370\0370\0370\nBUILDER\037building\037feat-alpha\037\nPRCOUNT\0371\nPR\037101\037feat/beta\037MERGEABLE\037CLEAN\037PASS\037clean\037\0370\nBACKLOG\037file\0373\0371\nCODEMAP\0371\0371\nATTENTION\0370\nREASONS\037\n' > "$HEALTHY"
# An attention snapshot: a DEAD builder + a CONFLICTING, review-BLOCKed PR on a tracker backend.
ATTN="$T/attention.snapshot"
printf 'WORKSPACE\037fixtureproj\nROOT\037/tmp/p\nWATCHER\037down\037\0370\037\nBCOUNTS\0370\0370\0370\0371\nBUILDER\037dead\037feat-zombie\037\nPRCOUNT\0371\nPR\037300\037feat/stuck\037CONFLICTING\037DIRTY\037BLOCK\037code-error\037CHANGES_REQUESTED\0371\nBACKLOG\037other\037linear\nNOTES\0372\037feat-zombie\03712m\nCODEMAP\0371\0370\nATTENTION\0371\nREASONS\037 dead-builder:feat-zombie conflicting-pr:#300\n' > "$ATTN"

status_run() { ( cd "$P" && HERD_NONINTERACTIVE=1 HERD_CONFIG_FILE="$P/.herd/config" \
    HERD_STATUS_SNAPSHOT_FILE="$1" bash "$HERD" "${@:2}" >"$T/out" 2>"$T/err" ); RC=$?; }

# (a) plain text — the exact human report, byte for byte (no COLORS record ⇒ no ANSI to normalise).
status_run "$HEALTHY" status
[ "$RC" -eq 0 ] || fail "herd status (plain, healthy) must exit 0, got $RC"
cat > "$T/expect.status" <<'EOF'
🐑 herd status · fixtureproj · /tmp/p

  WATCHER   alive (pid 4242)
  BUILDERS  1 building · 0 done · 0 idle · 0 dead
    🔨 feat-alpha               building
  PRS       1 open
    #101 feat/beta                MERGEABLE · CLEAN · review PASS · health clean
  BACKLOG   3 open · 1 in-progress
  CODEMAP   fresh

✅ healthy
EOF
cmp -s "$T/expect.status" "$T/out" \
  || { diff "$T/expect.status" "$T/out" >&2; fail "herd status plain text drifted from the golden"; }
# The BASH fallback formatter renders the same report; pin it against the same golden so a JSON
# change that reached only one of the two text paths cannot hide behind the default python one.
( cd "$P" && HERD_ENGINE_PY=0 HERD_NONINTERACTIVE=1 HERD_CONFIG_FILE="$P/.herd/config" \
    HERD_STATUS_SNAPSHOT_FILE="$HEALTHY" bash "$HERD" status >"$T/out" 2>/dev/null )
[ "$?" -eq 0 ] || fail "herd status (plain, bash formatter) must exit 0"
cmp -s "$T/expect.status" "$T/out" \
  || { diff "$T/expect.status" "$T/out" >&2; fail "herd status bash-formatter text drifted from the golden"; }
ok

# (b) --json — the documented herd.status/v1 contract, field by field.
status_run "$HEALTHY" status --json
[ "$RC" -eq 0 ] || fail "herd status --json (healthy) must keep the exit contract (0), got $RC"
cp "$T/out" "$T/status.json"
jeq "status --json schema"    "$T/status.json" 'd["schema"]'                 "herd.status/v1"
jeq "status --json workspace" "$T/status.json" 'd["workspace"]'              "fixtureproj"
jeq "status --json root"      "$T/status.json" 'd["root"]'                   "/tmp/p"
jeq "status --json watcher"   "$T/status.json" 'd["watcher"]["state"]'       "alive"
jeq "status --json wpid"      "$T/status.json" 'd["watcher"]["pid"]'         "4242"
jeq "status --json wcount"    "$T/status.json" 'd["watcher"]["count"]'       "1"
jeq "status --json building"  "$T/status.json" 'd["builders"]["building"]'   "1"
jeq "status --json bslug"     "$T/status.json" 'd["builders"]["items"][0]["slug"]'  "feat-alpha"
jeq "status --json bstate"    "$T/status.json" 'd["builders"]["items"][0]["state"]' "building"
# A builder with no PR reports null, never "" or 0 — the contract's "absent means null" rule.
jeq "status --json bpr null"  "$T/status.json" 'd["builders"]["items"][0]["pr"]'    "null"
jeq "status --json prs open"  "$T/status.json" 'd["prs"]["open"]'            "1"
jeq "status --json pr number" "$T/status.json" 'd["prs"]["items"][0]["number"]'     "101"
jeq "status --json pr branch" "$T/status.json" 'd["prs"]["items"][0]["branch"]'     "feat/beta"
jeq "status --json pr merge"  "$T/status.json" 'd["prs"]["items"][0]["mergeable"]'  "MERGEABLE"
jeq "status --json pr mstate" "$T/status.json" 'd["prs"]["items"][0]["merge_state"]' "CLEAN"
jeq "status --json pr review" "$T/status.json" 'd["prs"]["items"][0]["review"]'     "PASS"
jeq "status --json pr health" "$T/status.json" 'd["prs"]["items"][0]["health"]'     "clean"
jeq "status --json pr dec"    "$T/status.json" 'd["prs"]["items"][0]["review_decision"]' "null"
jeq "status --json pr attn"   "$T/status.json" 'd["prs"]["items"][0]["attention"]'  "false"
jeq "status --json bl kind"   "$T/status.json" 'd["backlog"]["kind"]'        "file"
jeq "status --json bl open"   "$T/status.json" 'd["backlog"]["open"]'        "3"
jeq "status --json bl wip"    "$T/status.json" 'd["backlog"]["in_progress"]' "1"
jeq "status --json notes"     "$T/status.json" 'd["notes"]["unacked"]'       "0"
jeq "status --json codemap"   "$T/status.json" 'd["codemap"]["fresh"]'       "true"
jeq "status --json attention" "$T/status.json" 'd["attention"]'              "false"
jeq "status --json reasons"   "$T/status.json" 'len(d["reasons"])'           "0"
# Types, not just values: the key set must be STABLE and the numbers must be numbers.
jeq "status --json types"     "$T/status.json" \
  'isinstance(d["builders"]["building"], int) and isinstance(d["prs"]["open"], int) and isinstance(d["reasons"], list) and isinstance(d["attention"], bool)' \
  "true"
ok

# (c) --json on an attention snapshot: the verdict AND the exit code must both carry it, and a
#     tracker backend must report null counts rather than a fabricated zero.
status_run "$ATTN" status --json
[ "$RC" -eq 1 ] || fail "herd status --json (attention) must exit 1, got $RC"
cp "$T/out" "$T/status-attn.json"
jeq "status --json attn flag"  "$T/status-attn.json" 'd["attention"]'                "true"
jeq "status --json attn why"   "$T/status-attn.json" '",".join(d["reasons"])' \
  "dead-builder:feat-zombie,conflicting-pr:#300"
jeq "status --json down"       "$T/status-attn.json" 'd["watcher"]["state"]'         "down"
jeq "status --json down pid"   "$T/status-attn.json" 'd["watcher"]["pid"]'           "null"
jeq "status --json dead"       "$T/status-attn.json" 'd["builders"]["items"][0]["state"]' "dead"
jeq "status --json pr blocked" "$T/status-attn.json" 'd["prs"]["items"][0]["review"]'     "BLOCK"
jeq "status --json pr cr"      "$T/status-attn.json" 'd["prs"]["items"][0]["review_decision"]' "CHANGES_REQUESTED"
jeq "status --json pr attn1"   "$T/status-attn.json" 'd["prs"]["items"][0]["attention"]'  "true"
# A tracker backend has NO local emoji state to count — the contract says null, never a made-up 0.
jeq "status --json bl other"   "$T/status-attn.json" 'd["backlog"]["kind"]'          "other"
jeq "status --json bl backend" "$T/status-attn.json" 'd["backlog"]["backend"]'       "linear"
jeq "status --json bl null"    "$T/status-attn.json" 'd["backlog"]["open"]'          "null"
jeq "status --json notes n"    "$T/status-attn.json" 'd["notes"]["unacked"]'         "2"
jeq "status --json notes slug" "$T/status-attn.json" 'd["notes"]["newest_slug"]'     "feat-zombie"
jeq "status --json notes age"  "$T/status-attn.json" 'd["notes"]["newest_age"]'      "12m"
ok

# (d) the attention snapshot's TEXT path must still be byte-identical too — the flag is additive on
#     the unhealthy path as much as the healthy one.
status_run "$ATTN" status
[ "$RC" -eq 1 ] || fail "herd status (plain, attention) must exit 1, got $RC"
grep -q '⚠️  attention: dead-builder:feat-zombie conflicting-pr:#300' "$T/out" \
  || { cat "$T/out" >&2; fail "herd status plain (attention) lost its attention line"; }
ok

# ── (2) herd backlog ─────────────────────────────────────────────────────────────────────────────
# (a) plain text — the file backend's raw 🔜/🚧 lines, byte for byte.
run backlog
[ "$RC" -eq 0 ] || fail "herd backlog (plain) exited $RC"
printf -- '- 🚧 wiring the feedback loop\n- 🔜 add a dark-mode toggle\n' > "$T/expect.backlog"
cmp -s "$T/expect.backlog" "$T/out" \
  || { diff "$T/expect.backlog" "$T/out" >&2; fail "herd backlog plain text drifted from the golden"; }
ok

# (b) --json on the FILE backend: the raw line is always present; id/title are null because a
#     markdown bullet carries no id to report (reporting an invented one would be worse).
run backlog --json
[ "$RC" -eq 0 ] || fail "herd backlog --json exited $RC (stderr: $(cat "$T/err"))"
cp "$T/out" "$T/backlog.json"
jeq "backlog --json schema"  "$T/backlog.json" 'd["schema"]'   "herd.backlog/v1"
jeq "backlog --json backend" "$T/backlog.json" 'd["backend"]'  "file"
jeq "backlog --json mode"    "$T/backlog.json" 'd["mode"]'     "open"
jeq "backlog --json count"   "$T/backlog.json" 'd["count"]'    "2"
jeq "backlog --json line"    "$T/backlog.json" 'd["items"][0]["line"]' "- 🚧 wiring the feedback loop"
jeq "backlog --json id null" "$T/backlog.json" 'd["items"][0]["id"]'    "null"
jeq "backlog --json ttl null" "$T/backlog.json" 'd["items"][0]["title"]' "null"
# Lossless: every plain line appears verbatim as an item, in order.
jeq "backlog --json lossless" "$T/backlog.json" \
  '"\n".join(i["line"] for i in d["items"])' "$(cat "$T/expect.backlog")"
ok

# (c) --json on an ID-MINTING backend (github, via a stub gh): the "#<id> <title>" shape every such
#     backend emits must split into real id/title fields. Mirrors tests/test-cli-backlog.sh's stub.
PG="$T/proj-github"; mkdir -p "$PG/.herd" "$T/bin"
cat > "$PG/.herd/config" <<CFG
PROJECT_ROOT=$PG
SCRIBE_BACKEND=github
TRACKER_REPO=acme/widgets
CFG
cat > "$T/bin/gh" <<'GH'
#!/usr/bin/env bash
case "$1 $2" in
  "issue list") printf '%s' '[{"number":7,"title":"first open issue"},{"number":9,"title":"second open issue"}]' ;;
  *) : ;;
esac
GH
chmod +x "$T/bin/gh"
gh_out="$( cd "$PG" && PATH="$T/bin:$PATH" HERD_NONINTERACTIVE=1 bash "$HERD" backlog --json 2>"$T/err" )" \
  || fail "herd backlog --json (github) exited non-zero: $(cat "$T/err")"
printf '%s\n' "$gh_out" > "$T/backlog-gh.json"
jeq "backlog gh backend"  "$T/backlog-gh.json" 'd["backend"]'            "github"
jeq "backlog gh count"    "$T/backlog-gh.json" 'd["count"]'              "2"
jeq "backlog gh id"       "$T/backlog-gh.json" 'd["items"][0]["id"]'     "7"
jeq "backlog gh title"    "$T/backlog-gh.json" 'd["items"][0]["title"]'  "first open issue"
jeq "backlog gh line"     "$T/backlog-gh.json" 'd["items"][0]["line"]'   "#7 first open issue"
jeq "backlog gh id2"      "$T/backlog-gh.json" 'd["items"][1]["id"]'     "9"
ok
# And that backend's PLAIN list is untouched by the flag's existence.
gh_plain="$( cd "$PG" && PATH="$T/bin:$PATH" HERD_NONINTERACTIVE=1 bash "$HERD" backlog 2>/dev/null )"
[ "$gh_plain" = "$(printf '#7 first open issue\n#9 second open issue')" ] \
  || { printf '%s\n' "$gh_plain" >&2; fail "herd backlog plain (github) drifted"; }
ok

# ── (3) herd agents list ─────────────────────────────────────────────────────────────────────────
# (a) plain text — asserted as exact LINES. One line of this render quotes the active driver's
#     @degrade reason, which legitimately moves when the driver data file is updated; pinning the
#     whole block would make an unrelated driver bump red here for no defect.
run agents list
[ "$RC" -eq 0 ] || fail "herd agents list (plain) exited $RC"
grep -qx "roster: $P/.herd/agents" "$T/out" || { cat "$T/out" >&2; fail "agents list lost its roster line"; }
grep -qx "driver: herdr-claude   definition-mode: inject   selection: inject   lookup-path: $P/.claude/agents" "$T/out" \
  || { cat "$T/out" >&2; fail "agents list lost/changed its driver line"; }
grep -qx "NAME                     STATE          DESCRIPTION" "$T/out" \
  || { cat "$T/out" >&2; fail "agents list lost its table header"; }
grep -qx "gate-rails               unverified     fixture specialist — knows the gate rails." "$T/out" \
  || { cat "$T/out" >&2; fail "agents list lost/changed its definition row"; }
grep -qx "  skipped: README.md (no frontmatter)" "$T/out" \
  || { cat "$T/out" >&2; fail "agents list lost its skipped row"; }
ok

# (b) --json — the documented herd.agents/v1 contract.
run agents list --json
[ "$RC" -eq 0 ] || fail "herd agents list --json exited $RC (stderr: $(cat "$T/err"))"
cp "$T/out" "$T/agents.json"
jeq "agents --json schema"  "$T/agents.json" 'd["schema"]'          "herd.agents/v1"
jeq "agents --json dir"     "$T/agents.json" 'd["roster_dir"]'      "$P/.herd/agents"
jeq "agents --json driver"  "$T/agents.json" 'd["driver"]'          "herdr-claude"
jeq "agents --json mode"    "$T/agents.json" 'd["definition_mode"]' "inject"
jeq "agents --json select"  "$T/agents.json" 'd["selection"]'       "inject"
jeq "agents --json lookup"  "$T/agents.json" 'd["lookup_path"]'     "$P/.claude/agents"
jeq "agents --json count"   "$T/agents.json" 'd["count"]'           "1"
jeq "agents --json name"    "$T/agents.json" 'd["definitions"][0]["name"]'  "gate-rails"
# Never verified against this (driver, sha) pair ⇒ the documented "unverified" state, detail null.
jeq "agents --json state"   "$T/agents.json" 'd["definitions"][0]["state"]'  "unverified"
jeq "agents --json detail"  "$T/agents.json" 'd["definitions"][0]["detail"]' "null"
# The table elides a long description at 72 chars; the contract carries it whole.
jeq "agents --json desc"    "$T/agents.json" 'd["definitions"][0]["description"]' \
  "fixture specialist — knows the gate rails."
jeq "agents --json path"    "$T/agents.json" 'd["definitions"][0]["path"]' "$P/.herd/agents/gate-rails.md"
jeq "agents --json sha len" "$T/agents.json" 'len(d["definitions"][0]["sha"])' "64"
# The non-definition file is reported as skipped, never as a phantom roster entry (HERD-732).
jeq "agents --json skipped" "$T/agents.json" 'd["skipped"][0]["name"]'   "README"
jeq "agents --json skipwhy" "$T/agents.json" 'd["skipped"][0]["reason"]' "no frontmatter"
ok

# ── (4) herd why <pr#> ───────────────────────────────────────────────────────────────────────────
# (a) plain text — the chronological gate history, byte for byte.
run why 77
[ "$RC" -eq 0 ] || fail "herd why 77 (plain) exited $RC"
cat > "$T/expect.why" <<'EOF'
PR #77 — gate history (4 events)
  2026-07-10T00:00:01Z  review dispatched    sha 001122334455 · model opus · pid 900
  2026-07-10T00:00:02Z  healthcheck outcome  clean
  2026-07-10T00:00:03Z  verdict recorded     PASS (panel) · sha 001122334455
  2026-07-10T00:00:04Z  MERGED               sha 001122334455 · squash · gate-green
EOF
cmp -s "$T/expect.why" "$T/out" \
  || { diff "$T/expect.why" "$T/out" >&2; fail "herd why plain text drifted from the golden"; }
ok

# (b) --json — the documented herd.why/v1 contract: raw events + the derived gate summary.
run why 77 --json
[ "$RC" -eq 0 ] || fail "herd why 77 --json exited $RC (stderr: $(cat "$T/err"))"
cp "$T/out" "$T/why.json"
jeq "why --json schema"   "$T/why.json" 'd["schema"]'  "herd.why/v1"
jeq "why --json pr"       "$T/why.json" 'd["pr"]'      "77"
jeq "why --json pr int"   "$T/why.json" 'isinstance(d["pr"], int)' "true"
jeq "why --json count"    "$T/why.json" 'd["count"]'   "4"
jeq "why --json verdict"  "$T/why.json" 'd["summary"]["latest_verdict"]["value"]'  "PASS"
jeq "why --json vsource"  "$T/why.json" 'd["summary"]["latest_verdict"]["source"]' "panel"
jeq "why --json vreason"  "$T/why.json" 'd["summary"]["latest_verdict"]["reason"]' "null"
jeq "why --json health"   "$T/why.json" 'd["summary"]["latest_health"]["outcome"]' "clean"
jeq "why --json merged"   "$T/why.json" 'd["summary"]["merged"]'   "true"
jeq "why --json first"    "$T/why.json" 'd["summary"]["first_ts"]' "2026-07-10T00:00:01Z"
jeq "why --json last"     "$T/why.json" 'd["summary"]["last_ts"]'  "2026-07-10T00:00:04Z"
# Events are the RAW journal objects, chronological, with their own fields intact.
jeq "why --json ev order" "$T/why.json" '",".join(e["event"] for e in d["events"])' \
  "review_dispatched,healthcheck_outcome,verdict_recorded,merge"
jeq "why --json ev raw"   "$T/why.json" 'd["events"][0]["model"]'  "opus"
jeq "why --json ev sha"   "$T/why.json" 'd["events"][3]["sha"]'    "0011223344556677"
ok

# (c) a PR with NO recorded events: the contract states that as count 0 / empty events / null
#     summary members — never as prose a machine has to parse, and never a non-zero exit.
run why 999 --json
[ "$RC" -eq 0 ] || fail "herd why 999 --json (no events) must exit 0, got $RC"
cp "$T/out" "$T/why-empty.json"
jeq "why empty pr"      "$T/why-empty.json" 'd["pr"]'      "999"
jeq "why empty count"   "$T/why-empty.json" 'd["count"]'   "0"
jeq "why empty events"  "$T/why-empty.json" 'len(d["events"])' "0"
jeq "why empty verdict" "$T/why-empty.json" 'd["summary"]["latest_verdict"]' "null"
jeq "why empty merged"  "$T/why-empty.json" 'd["summary"]["merged"]' "false"
ok
# ...and its plain-text counterpart is unchanged.
run why 999
[ "$RC" -eq 0 ] || fail "herd why 999 (plain) exited $RC"
[ "$(cat "$T/out")" = "PR #999 — no journal entries found." ] \
  || { cat "$T/out" >&2; fail "herd why plain (unknown PR) drifted"; }
ok

# (d) argument handling still refuses what it always refused, and rejects a bogus flag loudly rather
#     than silently emitting an object the caller would trust.
run why
[ "$RC" -ne 0 ] || fail "herd why with no pr# must fail"
grep -q "usage: herd why <pr#>" "$T/err" || { cat "$T/err" >&2; fail "herd why (no args) lost its usage line"; }
run why abc
[ "$RC" -ne 0 ] || fail "herd why abc must fail"
grep -q "must be a number (got 'abc')" "$T/err" || { cat "$T/err" >&2; fail "herd why abc lost its number check"; }
run why 77 --bogus
[ "$RC" -ne 0 ] || fail "herd why --bogus must fail rather than be ignored"
run status --bogus
[ "$RC" -ne 0 ] || fail "herd status --bogus must fail rather than be ignored"
ok

echo "PASS ($PASS checks) — tests/test-json-output.sh"
