#!/usr/bin/env bash
# test-team-presence-live.sh — hermetic unit tests for the HERD-661 (GitHub issue #639 phase 2) live
# builder-state publish/consume channel (scripts/herd/team-presence-live.sh) and its wiring into
# TEAM_PRESENCE=live (scripts/herd/agent-watch.sh).
#
# PART 1 — the library standalone (mirrors tests/test-resolver-claim.sh's harness): render/parse
# round-trip, field validation (parser-injection safety included), load against a fake multi-PR `gh`
# comment store (empty/valid/malformed/outage), and publish's create-vs-edit-in-place upsert.
#
# PART 2 — wired into agent-watch.sh (mirrors tests/test-team-presence.sh's harness, sourcing the
# watcher in AGENT_WATCH_LIB=1 mode): a PUBLISH/CONSUME round trip across TWO SYNTHETIC SEATS (this
# seat's own authored+building PR publishes; an ADOPTED PR authored by someone else never does), and
# the freshness-clause rendering both fresh ("active Ns ago") and stale ("last active … ago (stale?)")
# — plus byte-identical TEAM_PRESENCE=on (the live leg never even runs) and per-row fail-soft when the
# channel is absent for one attributed PR but present for another.
#
# No network, no real gh, no repo writes. Run:  bash tests/test-team-presence-live.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LIB="$ROOT/scripts/herd/team-presence-live.sh"
WATCH="$ROOT/scripts/herd/agent-watch.sh"

[ -f "$LIB" ]   || { echo "FAIL: team-presence-live.sh not found at $LIB" >&2; exit 1; }
[ -f "$WATCH" ] || { echo "FAIL: agent-watch.sh not found at $WATCH" >&2; exit 1; }
command -v jq      >/dev/null 2>&1 || { echo "FAIL: jq required" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 required" >&2; exit 1; }

PASS=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { PASS=$((PASS+1)); }

# ════════════════════════════════ PART 1 — standalone library ═══════════════════════════════════════
(
T1="$(mktemp -d)"; trap 'rm -rf "$T1"' EXIT
# shellcheck source=/dev/null
. "$LIB"

STORE_DIR="$T1/comments"; mkdir -p "$STORE_DIR"
GHLOG="$T1/gh.log"; : > "$GHLOG"
GH_OUTAGE_FLAG="$T1/gh-outage"
mkdir -p "$T1/bin"
cat > "$T1/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >> "$GHLOG"
[ -f "$GH_OUTAGE_FLAG" ] && exit 1
shift # drop leading "api"
method="GET"; body=""; has_body=0; path=""
while [ $# -gt 0 ]; do
  case "$1" in
    --paginate) shift ;;
    -X) shift; method="$1"; shift ;;
    -f) shift; case "$1" in body=*) body="${1#body=}"; has_body=1 ;; esac; shift ;;
    *) path="$1"; shift ;;
  esac
done
case "$path" in
  */comments/[0-9]*)
    id="${path##*/}"
    for f in "$STORE_DIR"/*.json; do
      [ -f "$f" ] || continue
      if jq -e --arg id "$id" 'map(select((.id|tostring)==$id))|length>0' "$f" >/dev/null 2>&1; then
        jq --arg id "$id" --arg body "$body" \
          'map(if (.id|tostring)==$id then .body=$body else . end)' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
        exit 0
      fi
    done
    exit 0
    ;;
  */issues/*/comments)
    pr="$(printf '%s' "$path" | sed -E 's#.*/issues/([0-9]+)/comments#\1#')"
    f="$STORE_DIR/$pr.json"
    [ -f "$f" ] || printf '[]' > "$f"
    if [ "$has_body" -eq 1 ]; then
      jq --arg body "$body" '. + [{"id": (([.[].id, 0] | max) + 1000), "body": $body}]' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
      exit 0
    else
      cat "$f"
      exit 0
    fi
    ;;
esac
exit 1
EOF
chmod +x "$T1/bin/gh"
export PATH="$T1/bin:$PATH" GHLOG STORE_DIR GH_OUTAGE_FLAG
export HERD_REPO="acme/widgets"

put_marker() {  # <pr> <marker-pr> <slug> <seat> <status> <epoch>
  local f="$STORE_DIR/$1.json"
  jq -n --arg pr "$2" --arg slug "$3" --arg seat "$4" --arg status "$5" --arg epoch "$6" \
    '[{"id": 1, "body": ("<!-- herd:team-presence-live v1\npr: " + $pr + "\nslug: " + $slug + "\nseat: " + $seat + "\nstatus: " + $status + "\nepoch: " + $epoch + "\n-->")}]' \
    > "$f"
}

JLOG="$T1/journal.log"; : > "$JLOG"
journal_append() { printf '%s\n' "$*" >> "$JLOG"; }

# ── 1. render/parse round-trip — inspect the parser's TEXT OUTPUT directly, never eval it (that is
#      exactly the anti-pattern the library itself avoids; see section 3) ───────────────────────────
body="$(_team_presence_live_render 42 widget alice working 1700000000)"
grep -qF '<!-- herd:team-presence-live v1' <<< "$body" || fail "render: marker missing"
parsed="$(printf '%s' "$body" | _team_presence_live_parse)"
grep -qx "TPL_PR=42"          <<< "$parsed" || fail "round-trip TPL_PR: got: $parsed"
grep -qx "TPL_SLUG=widget"    <<< "$parsed" || fail "round-trip TPL_SLUG"
grep -qx "TPL_SEAT=alice"     <<< "$parsed" || fail "round-trip TPL_SEAT"
grep -qx "TPL_STATUS=working" <<< "$parsed" || fail "round-trip TPL_STATUS"
grep -qx "TPL_EPOCH=1700000000" <<< "$parsed" || fail "round-trip TPL_EPOCH"
[ -z "$(printf 'just a human comment\nno marker here' | _team_presence_live_parse)" ] \
  || fail "non-marker body must parse empty"
ok

# ── 2. _team_presence_live_fields_valid rejects malformed fields one at a time ───────────────────────
set_fields() { TPL_PR="$1"; TPL_SLUG="$2"; TPL_SEAT="$3"; TPL_STATUS="$4"; TPL_EPOCH="$5"; }
set_fields 42 widget alice working 1700000000
_team_presence_live_fields_valid || fail "a well-formed field set must validate"; ok
set_fields "4x" widget alice working 1700000000
! _team_presence_live_fields_valid || fail "non-numeric pr must be rejected"; ok
set_fields 42 'widget; rm -rf /' alice working 1700000000
! _team_presence_live_fields_valid || fail "shell-metachar slug must be rejected"; ok
set_fields 42 widget '$(whoami)' working 1700000000
! _team_presence_live_fields_valid || fail "command-substitution seat must be rejected"; ok
set_fields 42 widget alice working "soon"
! _team_presence_live_fields_valid || fail "non-numeric epoch must be rejected"; ok
set_fields 42 widget alice '`id`' 1700000000
! _team_presence_live_fields_valid || fail "backtick status must be rejected"; ok

# ── 3. parser injection safety — a forged command-substitution payload is NEVER executed. The parser
#      is plain awk text processing (trivially inert), so the REAL proof is exercising the actual
#      unsafe-input code path: _team_presence_live_load, which reads the parser's output via a plain
#      `read` loop (never eval) exactly like resolver-claim.sh's own _resolve_claim_load ─────────────
CANARY="$T1/canary"; rm -f "$CANARY"
put_marker 700 700 "\$(touch $CANARY)" alice working 1700000000
_team_presence_live_load 700 && fail "a forged slug must fail load's field validation, not silently load"
[ -e "$CANARY" ] && fail "SECURITY: loading a forged marker executed a command-substitution payload"
ok

# ── 4. _team_presence_live_load against the fake store: empty / valid / malformed / outage ──────────
_team_presence_live_load 500 && fail "no comments at all must return 1"
: > "$GHLOG"
[ -s "$GHLOG" ] && fail "sanity: log should be empty here"
printf '[]' > "$STORE_DIR/501.json"
_team_presence_live_load 501 && fail "an empty comment list must return 1"
put_marker 502 502 widget alice working 1700000000
_team_presence_live_load 502 || fail "a valid marker must load"
[ "$TPL_SLUG" = "widget" ] && [ "$TPL_SEAT" = "alice" ] && [ "$TPL_STATUS" = "working" ] \
  || fail "loaded fields wrong: slug=$TPL_SLUG seat=$TPL_SEAT status=$TPL_STATUS"
printf '[{"id":9,"body":"just some other comment, not ours"}]' > "$STORE_DIR/503.json"
_team_presence_live_load 503 && fail "a non-marker comment must not load as a live row"
touch "$GH_OUTAGE_FLAG"
_team_presence_live_load 502 && fail "a gh outage must fail soft to 'no live data', never fabricate"
rm -f "$GH_OUTAGE_FLAG"
ok

# ── 5. _team_presence_live_status_for — the pure CONSUME primitive ──────────────────────────────────
[ "$(_team_presence_live_status_for 502)" = "$(printf 'working\t1700000000')" ] \
  || fail "status_for must print status\\tepoch for a valid marker"
[ -z "$(_team_presence_live_status_for 501)" ] || fail "status_for must be empty for an absent marker"
[ -z "$(_team_presence_live_status_for '')" ] || fail "status_for must be empty for an empty pr arg"
ok

# ── 6. _team_presence_live_publish — CREATE then EDIT-IN-PLACE upsert, never a second comment ───────
printf '[]' > "$STORE_DIR/600.json"
WATCHER_OWNER=alice _team_presence_live_publish 600 widget alice working
[ "$(jq 'length' "$STORE_DIR/600.json")" = "1" ] || fail "first publish must create exactly one comment"
COMMENT_BODY="$(jq -r '.[0].body' "$STORE_DIR/600.json")"
grep -q 'status: working' <<< "$COMMENT_BODY" || fail "created comment missing status"
WATCHER_OWNER=alice _team_presence_live_publish 600 widget alice idle
[ "$(jq 'length' "$STORE_DIR/600.json")" = "1" ] || fail "a second publish must edit in place, not append"
COMMENT_BODY="$(jq -r '.[0].body' "$STORE_DIR/600.json")"
grep -q 'status: idle' <<< "$COMMENT_BODY" || fail "edited comment did not update status"
ok

# ── 7. publish outage — best-effort, never blocks, journals the failure ─────────────────────────────
touch "$GH_OUTAGE_FLAG"
_team_presence_live_publish 601 widget alice working || fail "publish must never error out on an outage"
rm -f "$GH_OUTAGE_FLAG"
grep -q team_presence_live_publish_failed "$JLOG" || fail "publish outage must journal the failure"
ok

echo "ok — team-presence-live.sh standalone: $PASS assertions passed"
) || exit 1

# ═══════════════════════════ PART 2 — wired into agent-watch.sh (TEAM_PRESENCE=live) ════════════════
T2="$(mktemp -d)"; trap 'rm -rf "$T2"' EXIT

BIN="$T2/bin"; mkdir -p "$BIN"
STORE_DIR="$T2/comments"; mkdir -p "$STORE_DIR"
GH_BODIES_FILE="$T2/bodies.json"
cat > "$BIN/gh" <<'GH'
#!/usr/bin/env bash
case "${GH_MODE:-leak}" in
  leak) echo 'SENTINEL-NETWORK-LEAK'; exit 0 ;;
esac
if [ "$1" = "pr" ] && [ "$2" = "list" ]; then
  case "${GH_MODE:-}" in
    fail) echo "gh: transient" >&2; exit 1 ;;
    *)    cat "$GH_BODIES_FILE" ;;
  esac
  exit 0
fi
if [ "$1" = "api" ]; then
  [ "${GH_MODE:-}" = "api-fail" ] && exit 1
  shift
  method="GET"; body=""; has_body=0; path=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --paginate) shift ;;
      -X) shift; method="$1"; shift ;;
      -f) shift; case "$1" in body=*) body="${1#body=}"; has_body=1 ;; esac; shift ;;
      *) path="$1"; shift ;;
    esac
  done
  case "$path" in
    */comments/[0-9]*)
      id="${path##*/}"
      for f in "$STORE_DIR"/*.json; do
        [ -f "$f" ] || continue
        if jq -e --arg id "$id" 'map(select((.id|tostring)==$id))|length>0' "$f" >/dev/null 2>&1; then
          jq --arg id "$id" --arg body "$body" \
            'map(if (.id|tostring)==$id then .body=$body else . end)' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
          exit 0
        fi
      done
      exit 0
      ;;
    */issues/*/comments)
      pr="$(printf '%s' "$path" | sed -E 's#.*/issues/([0-9]+)/comments#\1#')"
      f="$STORE_DIR/$pr.json"
      [ -f "$f" ] || printf '[]' > "$f"
      if [ "$has_body" -eq 1 ]; then
        jq --arg body "$body" '. + [{"id": (([.[].id, 0] | max) + 1000), "body": $body}]' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
        exit 0
      else
        cat "$f"
        exit 0
      fi
      ;;
  esac
  echo '[]'; exit 0
fi
echo 'SENTINEL-NETWORK-LEAK'; exit 0
GH
chmod +x "$BIN/gh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/git";   chmod +x "$BIN/git"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/herdr"; chmod +x "$BIN/herdr"
export PATH="$BIN:$PATH"
export GH_MODE=bodies
export GH_BODIES_FILE STORE_DIR

BACKENDS="$T2/backends"; mkdir -p "$BACKENDS"
cat > "$BACKENDS/fake.sh" <<'BK'
#!/usr/bin/env bash
_backend_list_open_rich() { cat "$ROSTER_FILE"; }
BK
export SCRIBE_BACKEND_DIR="$BACKENDS"
export SCRIBE_BACKEND="fake"
export ROSTER_FILE="$T2/roster.tsv"

export AGENT_WATCH_LIB=1
export HERD_CONFIG_FILE="$T2/no-such-config"
export WORKTREES_DIR="$T2/trees"; mkdir -p "$WORKTREES_DIR"
export PROJECT_ROOT="$T2/main"; mkdir -p "$PROJECT_ROOT/.herd"
export WORKSPACE_NAME="teampresencelivetest"
export WATCHER_OWNER="me-operator"
export NO_COLOR=1
export HERD_FAKE_NOW=1000000000
unset ORPHAN_PR_ROWS ADOPT_REMOTE_PRS TEAM_PRESENCE
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"
for fn in _team_presence_live_enabled _team_presence_live_publish_tick _team_presence_live_augment; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined after sourcing agent-watch.sh"
done
ok

# ── Fixtures: same shape as test-team-presence.sh — PR 101 → HERD-500/Ava Chen, PR 103 → HERD-527/Brian K
UNGATED_ROWS="$(printf '%s\t101\tadd widget\tfeat/widget\n%s\t102\tfix leak\tfeat/herd-52-x\n%s\t103\tteam view\tfeat/herd-527-teammate\n' \
  "$HERD_FAKE_NOW" "$HERD_FAKE_NOW" "$HERD_FAKE_NOW")"
seed_ungated(){ printf '%s\n' "$UNGATED_ROWS" > "$UNGATED_PR_LEDGER"; }
cat > "$GH_BODIES_FILE" <<'JSON'
[
  {"number":101,"body":"## Refs: HERD-500\n\nsome description"},
  {"number":102,"body":"no ref at all here"},
  {"number":103,"body":"Refs: <id>"}
]
JSON
printf '#HERD-500\tstarted\tIn Progress\tadd widget\tdesc\tAva Chen\thttps://x/500\n' > "$ROSTER_FILE"
printf '#HERD-527\tstarted\tIn Progress\tteam view\tdesc\tBrian K\thttps://x/527\n'  >> "$ROSTER_FILE"

# ── 8. _team_presence_live_enabled — the third value only ───────────────────────────────────────────
TEAM_PRESENCE=off  _team_presence_live_enabled && fail "off must not enable the live leg"
TEAM_PRESENCE=on   _team_presence_live_enabled && fail "on (phase 1 only) must not enable the live leg"
TEAM_PRESENCE=live _team_presence_live_enabled || fail "live must enable the live leg"
TEAM_PRESENCE=LIVE _team_presence_live_enabled || fail "live must be case-insensitive"
ok

# ── 9. PUBLISH — two synthetic seats: THIS seat's own authored+building PR publishes; an ADOPTED PR
#      authored by someone else never does ("seat-symmetric": publish only what is actually OURS) ────
export TEAM_PRESENCE=live
SEP=$'\037'
FEATS=(
  "$WORKTREES_DIR/widget${SEP}widget${SEP}feat/widget${SEP}101${SEP}MERGEABLE${SEP}CLEAN${SEP}working${SEP}deadbeef${SEP}me-operator${SEP}branch${SEP}${SEP}0"
  "$WORKTREES_DIR/adopted${SEP}adopted${SEP}feat/other${SEP}999${SEP}MERGEABLE${SEP}CLEAN${SEP}idle${SEP}cafebabe${SEP}someone-else${SEP}branch${SEP}${SEP}0"
)
_team_presence_live_publish_tick
[ -f "$STORE_DIR/101.json" ] || fail "this seat's own building PR (101) must publish a live marker"
[ "$(jq 'length' "$STORE_DIR/101.json" 2>/dev/null || echo 0)" = "1" ] || fail "PR 101 must have exactly one marker comment"
COMMENT_BODY="$(jq -r '.[0].body' "$STORE_DIR/101.json")"
grep -q 'seat: me-operator' <<< "$COMMENT_BODY" || fail "PR 101 marker must carry this seat's identity"
grep -q 'status: working'  <<< "$COMMENT_BODY" || fail "PR 101 marker must carry the live agent_status"
[ -f "$STORE_DIR/999.json" ] && [ "$(jq 'length' "$STORE_DIR/999.json")" != "0" ] \
  && fail "an ADOPTED PR authored by someone else must NEVER be published to"
ok

# ── 10. PUBLISH is byte-inert under TEAM_PRESENCE=on (never live) — no gh call at all ───────────────
rm -rf "$STORE_DIR"; mkdir -p "$STORE_DIR"
OUT="$(TEAM_PRESENCE=on GH_MODE=leak _team_presence_live_publish_tick)"
grep -q "SENTINEL-NETWORK-LEAK" <<< "${OUT:-}" && fail "publish must never touch gh while TEAM_PRESENCE=on"
[ -f "$STORE_DIR/101.json" ] && fail "TEAM_PRESENCE=on must never create a live marker"
ok

# ── 11. CONSUME — fresh marker renders 'active … ago'; stale marker renders '… (stale?)' ────────────
rm -rf "$STORE_DIR"; mkdir -p "$STORE_DIR"
jq -n --arg body "$(printf '<!-- herd:team-presence-live v1\npr: 101\nslug: widget\nseat: me-operator\nstatus: working\nepoch: %s\n-->' "$HERD_FAKE_NOW")" \
  '[{"id":1,"body":$body}]' > "$STORE_DIR/101.json"
STALE_EPOCH=$(( HERD_FAKE_NOW - 20000 ))
jq -n --arg body "$(printf '<!-- herd:team-presence-live v1\npr: 103\nslug: teamview\nseat: brian\nstatus: idle\nepoch: %s\n-->' "$STALE_EPOCH")" \
  '[{"id":1,"body":$body}]' > "$STORE_DIR/103.json"
seed_ungated
GH_MODE=bodies _team_presence_scan
grep -q "^101	HERD-500	Ava Chen	working	${HERD_FAKE_NOW}\$" "$TEAM_PRESENCE_LEDGER" \
  || fail "PR 101's ledger row must carry the live status+epoch: $(cat "$TEAM_PRESENCE_LEDGER")"
grep -q "^103	HERD-527	Brian K	idle	${STALE_EPOCH}\$" "$TEAM_PRESENCE_LEDGER" \
  || fail "PR 103's ledger row must carry the live status+epoch: $(cat "$TEAM_PRESENCE_LEDGER")"
UNGATED_PR_SECTION_ROWS=""
build_ungated_prs
grep -q "🔓 #101 add widget feat/widget · ungated here · Ava Chen building HERD-500 on their machine · active " \
  <<< "$UNGATED_PR_SECTION_ROWS" || fail "row 101 must render the FRESH freshness clause: $UNGATED_PR_SECTION_ROWS"
grep -q "🔓 #103 team view feat/herd-527-teammate · ungated here · Brian K building HERD-527 on their machine · last active " \
  <<< "$UNGATED_PR_SECTION_ROWS" || fail "row 103 must render the STALE freshness clause: $UNGATED_PR_SECTION_ROWS"
grep -q "(stale?)" <<< "$UNGATED_PR_SECTION_ROWS" || fail "row 103 must be flagged (stale?)"
ROW101="$(grep '#101' <<< "$UNGATED_PR_SECTION_ROWS")"
grep -q "stale" <<< "$ROW101" && fail "row 101 (fresh) must NOT be flagged stale: $ROW101"
ok

# ── 12. FAIL-SOFT per row — one attributed PR's channel absent must render EXACTLY the on-style row,
#       independent of the OTHER attributed PR still having a live marker ───────────────────────────
rm -f "$STORE_DIR/103.json"
seed_ungated
GH_MODE=bodies _team_presence_scan
grep -q "^101	HERD-500	Ava Chen	working	${HERD_FAKE_NOW}\$" "$TEAM_PRESENCE_LEDGER" \
  || fail "PR 101 must still carry live fields"
grep -q "^103	HERD-527	Brian K\$" "$TEAM_PRESENCE_LEDGER" \
  || fail "PR 103 with no live marker must fall back to the plain 3-field on-style row: $(cat "$TEAM_PRESENCE_LEDGER")"
UNGATED_PR_SECTION_ROWS=""
build_ungated_prs
grep -q "🔓 #103 team view feat/herd-527-teammate · ungated here · Brian K building HERD-527 on their machine$" \
  <<< "$UNGATED_PR_SECTION_ROWS" || fail "row 103 must render byte-identically to TEAM_PRESENCE=on: $UNGATED_PR_SECTION_ROWS"
ok

# ── 13. Channel entirely unreachable (api-fail) → every row falls back to on-style, never a crash ──
jq -n --arg body "$(printf '<!-- herd:team-presence-live v1\npr: 103\nslug: teamview\nseat: brian\nstatus: idle\nepoch: %s\n-->' "$HERD_FAKE_NOW")" \
  '[{"id":1,"body":$body}]' > "$STORE_DIR/103.json"
seed_ungated
GH_MODE=api-fail _team_presence_scan || fail "an unreachable live channel must not error the scan"
grep -q "^101	HERD-500	Ava Chen\$" "$TEAM_PRESENCE_LEDGER" || fail "channel-down must fall back to plain rows: $(cat "$TEAM_PRESENCE_LEDGER")"
grep -q "	working	" "$TEAM_PRESENCE_LEDGER" && fail "channel-down must never fabricate live fields"
ok

# ── 14. TEAM_PRESENCE=on (not live) never augments — byte-identical to phase 1, even with markers live
export TEAM_PRESENCE=on
seed_ungated
GH_MODE=bodies _team_presence_scan
grep -q "^101	HERD-500	Ava Chen\$" "$TEAM_PRESENCE_LEDGER" \
  || fail "TEAM_PRESENCE=on must produce the plain 3-field row even with a live marker sitting on the PR: $(cat "$TEAM_PRESENCE_LEDGER")"
awk -F'\t' '{ if (NF > 3) exit 1 }' "$TEAM_PRESENCE_LEDGER" || fail "TEAM_PRESENCE=on must never grow ledger rows past 3 fields"
ok

# ── 15. _watcher_tick_fields fetches `author` under TEAM_PRESENCE=live EVEN IN SOLO SCOPE — without
#       this, every solo-scope FEATS record's author reads empty and the publish leg (which requires
#       an exact author==seat match) would silently never fire (git-pr.sh:_watcher_tick_fields) ──────
export WATCHER_SCOPE=mine
FIELDS_OFF="$(TEAM_PRESENCE=off _watcher_tick_fields)"
case ",$FIELDS_OFF," in *,author,*) fail "solo scope + TEAM_PRESENCE=off must NOT fetch author: $FIELDS_OFF" ;; esac
FIELDS_LIVE="$(TEAM_PRESENCE=live _watcher_tick_fields)"
case ",$FIELDS_LIVE," in *,author,*) : ;; *) fail "solo scope + TEAM_PRESENCE=live MUST fetch author (publish leg needs it): $FIELDS_LIVE" ;; esac
unset WATCHER_SCOPE
ok

echo "ok — team-presence-live wired into agent-watch.sh: $PASS assertions passed"
