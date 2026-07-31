#!/usr/bin/env bash
# test-resolver-claim.sh — hermetic unit tests for the HERD-423 cross-seat resolver-dispatch claim
# (scripts/herd/resolver-claim.sh, docs/spikes/cross-seat-coordination.md §5 Phase 1).
#
# Covers:
#   • _effective_resolve_claim: the two-part gate (RESOLVE_CLAIM on-value AND WATCHER_SCOPE=all)
#   • _resolve_claim_ttl: default + override + non-numeric fallback
#   • render/parse round-trip of the marker body
#   • _resolve_claim_fields_valid: rejects malformed/untrusted fields one at a time
#   • parser injection safety: a forged value containing a command-substitution payload is never
#     executed (the historical `eval`-on-untrusted-input class of bug)
#   • _resolve_claim_load against a fake `gh`: empty/valid/malformed/outage
#   • _resolve_claim_should_hold: byte-identical-when-off, live foreign claim, terminal foreign
#     claim, stale (different-sha) claim, own-seat claim, TTL steal, outage fail-soft
#   • _resolve_claim_publish_claimed / _resolve_claim_publish_terminal: off ⇒ no gh call; create vs
#     edit-in-place upsert; outage ⇒ best-effort no-op, never blocks
#
# No network, no real gh, no repo writes. Run:  bash tests/test-resolver-claim.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LIB="$ROOT/scripts/herd/resolver-claim.sh"

[ -f "$LIB" ] || { echo "FAIL: resolver-claim.sh not found at $LIB" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq required" >&2; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { PASS=$((PASS+1)); }

# shellcheck source=/dev/null
. "$LIB"

# ── fake gh + comments store ─────────────────────────────────────────────────────────────────────
GHLOG="$T/gh.log"; : > "$GHLOG"
STORE="$T/comments.json"; printf '[]' > "$STORE"
mkdir -p "$T/bin"
GH_OUTAGE_FLAG="$T/gh-outage"
cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >> "$GHLOG"
[ -f "$GH_OUTAGE_FLAG" ] && exit 1
method="GET"; jqexpr=""; body=""; has_body=0; path=""
shift # drop leading "api"
while [ $# -gt 0 ]; do
  case "$1" in
    --paginate) shift ;;
    --jq) shift; jqexpr="$1"; shift ;;
    -X) shift; method="$1"; shift ;;
    -f) shift; case "$1" in body=*) body="${1#body=}"; has_body=1 ;; esac; shift ;;
    *) path="$1"; shift ;;
  esac
done
case "$path" in
  */comments/[0-9]*)
    id="${path##*/}"
    jq --arg id "$id" --arg body "$body" \
      '(map(if (.id|tostring)==$id then .body=$body else . end))' "$STORE" > "$STORE.tmp" && mv "$STORE.tmp" "$STORE"
    exit 0
    ;;
  */comments)
    if [ "$has_body" -eq 1 ]; then
      # CREATE (POST) — a real comment, never gated on --jq (gh only applies --jq to a GET's
      # response; a write's response body is irrelevant here).
      jq --arg body "$body" \
        '. + [{"id": (([.[].id, 0] | max) + 1), "body": $body}]' "$STORE" > "$STORE.tmp" && mv "$STORE.tmp" "$STORE"
      exit 0
    else
      # GET — REVIEW FIX (HERD-423): resolver-claim.sh no longer passes --jq alongside
      # --paginate (real gh applies --jq PER PAGE, not on the aggregated array — verified live
      # against a real multi-page issue). It fetches the raw array and filters with its OWN `jq`
      # call, so this stub must hand back the full aggregated array here, exactly like real gh's
      # --paginate-without---jq behavior. Still honor --jq if a caller ever passes one (back-compat).
      if [ -n "$jqexpr" ]; then
        jq -r "$jqexpr" "$STORE"
      else
        cat "$STORE"
      fi
      exit 0
    fi
    ;;
esac
exit 1
EOF
chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH" GHLOG STORE GH_OUTAGE_FLAG
export HERD_REPO="acme/widgets"

reset_store() { printf '[]' > "$STORE"; : > "$GHLOG"; rm -f "$GH_OUTAGE_FLAG"; }
put_claim() {  # <pr> <sha> <seat> <slug> <epoch> <state>
  jq -n --arg pr "$1" --arg sha "$2" --arg seat "$3" --arg slug "$4" --arg epoch "$5" --arg state "$6" \
    '[{"id": 1, "body": ("<!-- herd:resolve-claim v1\npr: " + $pr + "\nsha: " + $sha + "\nseat: " + $seat + "\nslug: " + $slug + "\nepoch: " + $epoch + "\nstate: " + $state + "\n-->")}]' > "$STORE"
}

# journal_append stub — capture calls so lever-off / outage / steal assertions can inspect them.
JLOG="$T/journal.log"; : > "$JLOG"
journal_append() { printf '%s\n' "$*" >> "$JLOG"; }

now() { date +%s; }

# ══════════════════════════════ 1. _effective_resolve_claim gate ═══════════════════════════════
[ "$(unset RESOLVE_CLAIM WATCHER_SCOPE; _effective_resolve_claim)" = "off" ] || fail "default (both unset) → off"; ok
[ "$(RESOLVE_CLAIM=on  WATCHER_SCOPE=''    _effective_resolve_claim)" = "off" ] || fail "RESOLVE_CLAIM=on, scope unset(mine) → off"; ok
[ "$(RESOLVE_CLAIM=on  WATCHER_SCOPE=mine  _effective_resolve_claim)" = "off" ] || fail "RESOLVE_CLAIM=on, scope=mine → off"; ok
[ "$(RESOLVE_CLAIM=off WATCHER_SCOPE=all   _effective_resolve_claim)" = "off" ] || fail "RESOLVE_CLAIM=off, scope=all → off"; ok
[ "$(unset RESOLVE_CLAIM; WATCHER_SCOPE=all _effective_resolve_claim)" = "off" ] || fail "RESOLVE_CLAIM unset, scope=all → off"; ok
[ "$(RESOLVE_CLAIM=maybe WATCHER_SCOPE=all  _effective_resolve_claim)" = "off" ] || fail "RESOLVE_CLAIM typo, scope=all → off"; ok
[ "$(RESOLVE_CLAIM=on   WATCHER_SCOPE=all   _effective_resolve_claim)" = "on"  ] || fail "RESOLVE_CLAIM=on + scope=all → on"; ok
[ "$(RESOLVE_CLAIM=true WATCHER_SCOPE=all   _effective_resolve_claim)" = "on"  ] || fail "RESOLVE_CLAIM=true + scope=all → on"; ok
[ "$(RESOLVE_CLAIM=yes  WATCHER_SCOPE=all   _effective_resolve_claim)" = "on"  ] || fail "RESOLVE_CLAIM=yes + scope=all → on"; ok
[ "$(RESOLVE_CLAIM=1    WATCHER_SCOPE=all   _effective_resolve_claim)" = "on"  ] || fail "RESOLVE_CLAIM=1 + scope=all → on"; ok

# ══════════════════════════════ 2. _resolve_claim_ttl ═══════════════════════════════════════════
[ "$(unset RESOLVE_CLAIM_TTL; _resolve_claim_ttl)" = "2700" ] || fail "default TTL 2700"; ok
[ "$(RESOLVE_CLAIM_TTL=60  _resolve_claim_ttl)" = "60"   ] || fail "TTL override 60"; ok
[ "$(RESOLVE_CLAIM_TTL=abc _resolve_claim_ttl)" = "2700" ] || fail "non-numeric TTL falls back to 2700"; ok

# ══════════════════════════════ 3. render/parse round-trip ══════════════════════════════════════
body="$(_resolve_claim_render 42 abc123 alice myslug 1700000000 claimed)"
parsed="$(printf '%s' "$body" | _resolve_claim_parse)"
grep -qx "RC_PR=42" <<< "$parsed" || fail "round-trip RC_PR: got: $parsed"; ok
grep -qx "RC_SHA=abc123" <<< "$parsed" || fail "round-trip RC_SHA"; ok
grep -qx "RC_SEAT=alice" <<< "$parsed" || fail "round-trip RC_SEAT"; ok
grep -qx "RC_SLUG=myslug" <<< "$parsed" || fail "round-trip RC_SLUG"; ok
grep -qx "RC_EPOCH=1700000000" <<< "$parsed" || fail "round-trip RC_EPOCH"; ok
grep -qx "RC_STATE=claimed" <<< "$parsed" || fail "round-trip RC_STATE"; ok

# A non-claim comment (no marker) parses to nothing.
[ -z "$(printf 'just a human comment\nno marker here' | _resolve_claim_parse)" ] || fail "non-claim body must parse empty"; ok

# ══════════════════════════════ 4. _resolve_claim_fields_valid ══════════════════════════════════
set_fields() { RC_PR="$1"; RC_SHA="$2"; RC_SEAT="$3"; RC_SLUG="$4"; RC_EPOCH="$5"; RC_STATE="$6"; }

set_fields 42 abc123 alice myslug 1700000000 claimed
_resolve_claim_fields_valid || fail "well-formed fields must validate"; ok
set_fields 42 - alice myslug 1700000000 claimed
_resolve_claim_fields_valid || fail "sha='-' (unknown) must validate"; ok

set_fields "" abc123 alice myslug 1700000000 claimed
! _resolve_claim_fields_valid || fail "empty pr must be rejected"; ok
set_fields notanumber abc123 alice myslug 1700000000 claimed
! _resolve_claim_fields_valid || fail "non-numeric pr must be rejected"; ok
set_fields 42 "not-hex!" alice myslug 1700000000 claimed
! _resolve_claim_fields_valid || fail "non-hex sha must be rejected"; ok
set_fields 42 abc123 "al ice" myslug 1700000000 claimed
! _resolve_claim_fields_valid || fail "seat with a space must be rejected"; ok
set_fields 42 abc123 'alice;rm' myslug 1700000000 claimed
! _resolve_claim_fields_valid || fail "seat with shell metachar must be rejected"; ok
set_fields 42 abc123 alice myslug notanepoch claimed
! _resolve_claim_fields_valid || fail "non-numeric epoch must be rejected"; ok
set_fields 42 abc123 alice myslug 1700000000 bogus-state
! _resolve_claim_fields_valid || fail "unrecognized state must be rejected"; ok

# ══════════════════════════════ 5. injection safety (no eval on untrusted input) ════════════════
PWNED="$T/pwned-marker"
rm -f "$PWNED"
forged="<!-- herd:resolve-claim v1
pr: 42
sha: abc123
seat: alice\$(touch $PWNED)
slug: myslug
epoch: 1700000000
state: claimed
-->"
parsed="$(printf '%s' "$forged" | _resolve_claim_parse)"
# The parser must carry the payload as INERT TEXT — never execute it.
[ ! -f "$PWNED" ] || fail "SECURITY: parsing a forged claim executed a command-substitution payload"
ok
# ...and the field validator must then reject the resulting seat as malformed.
_rcpay="$(echo "$parsed" | awk -F= '/^RC_SEAT=/{print substr($0,9)}')"
RC_SEAT="$_rcpay"; RC_PR=42; RC_SHA=abc123; RC_SLUG=myslug; RC_EPOCH=1700000000; RC_STATE=claimed
! _resolve_claim_fields_valid || fail "forged seat with \$(...) must fail validation"; ok

# ══════════════════════════════ 6. _resolve_claim_load (fake gh) ════════════════════════════════
reset_store
_resolve_claim_load 42 && fail "empty store must return 1 (no claim)"; ok

put_claim 42 deadbeef bob feat-x 1700000000 claimed
_resolve_claim_load 42 || fail "valid claim must load (rc 0)"
[ "$RC_ID" = "1" ] && [ "$RC_SHA" = "deadbeef" ] && [ "$RC_SEAT" = "bob" ] && [ "$RC_STATE" = "claimed" ] || fail "loaded fields mismatch"
ok

# REVIEW FIX regression guard: `gh api --paginate --jq EXPR` applies EXPR PER PAGE and concatenates
# the per-page outputs rather than aggregating pages first (verified live against a real >1-page
# GitHub issue) — a claim comment that isn't on the LAST page fetched could then be missed or
# corrupted. The fix fetches the raw --paginate array with NO --jq and filters it in a SEPARATE,
# single `jq` call. Assert the actual read invocation never combines the two on this repo's `gh`.
_read_line="$(grep -F 'issues/42/comments' "$GHLOG" | grep -v '\-X PATCH' | grep -v -- '-f body=' | tail -1)"
[ -n "$_read_line" ] || fail "expected a GET .../issues/42/comments call in the gh log: $(cat "$GHLOG")"
case "$_read_line" in
  *--paginate*--jq*|*--jq*--paginate*)
    fail "REGRESSION: --paginate combined with --jq on a comments GET — gh applies --jq per-page, not on the aggregated array: $_read_line" ;;
esac
case "$_read_line" in *--paginate*) ;; *) fail "expected --paginate on the comments GET: $_read_line" ;; esac
ok

# Malformed claim on the wire (bad sha) → treated as no claim, never a crash.
put_claim 42 "not-hex" bob feat-x 1700000000 claimed
_resolve_claim_load 42 && fail "malformed claim on the wire must NOT load"; ok

# Outage: gh always fails → fail-soft "no claim", never a crash.
put_claim 42 deadbeef bob feat-x 1700000000 claimed
: > "$GH_OUTAGE_FLAG"
_resolve_claim_load 42 && fail "gh outage must fail-soft to 'no claim'"; ok
rm -f "$GH_OUTAGE_FLAG"

# ══════════════════════════════ 7. _resolve_claim_should_hold ═══════════════════════════════════
# (a) Lever OFF: must proceed (1) AND must make ZERO gh calls, even with a live blocking foreign
#     claim on the wire — the byte-identical-when-off invariant.
reset_store
put_claim 7 cafef00d bob feat-x "$(now)" claimed
( unset RESOLVE_CLAIM; WATCHER_OWNER=alice WATCHER_SCOPE=all _resolve_claim_should_hold 7 cafef00d feat-y ) \
  && fail "lever off must return 1 (proceed)" || true
[ -s "$GHLOG" ] && fail "lever off must make ZERO gh calls (byte-identical-when-off): $(cat "$GHLOG")"
ok

# (b) Lever on, empty store → proceed.
reset_store
( RESOLVE_CLAIM=on WATCHER_SCOPE=all WATCHER_OWNER=alice _resolve_claim_should_hold 7 cafef00d feat-y ) \
  && fail "no claim on the wire must proceed (1)" || true
ok

# (c) Live foreign claim, same sha, state=claimed, fresh epoch → HOLD (rc 0).
reset_store
put_claim 7 cafef00d bob feat-x "$(now)" claimed
( RESOLVE_CLAIM=on WATCHER_SCOPE=all WATCHER_OWNER=alice _resolve_claim_should_hold 7 cafef00d feat-y )
[ $? -eq 0 ] || fail "live foreign claimed row for THIS sha must HOLD"
ok

# (d) Foreign terminal state=done for THIS sha → HOLD (never redo finished work).
reset_store
put_claim 7 cafef00d bob feat-x "$(now)" done
( RESOLVE_CLAIM=on WATCHER_SCOPE=all WATCHER_OWNER=alice _resolve_claim_should_hold 7 cafef00d feat-y )
[ $? -eq 0 ] || fail "foreign state=done for THIS sha must HOLD"
ok

# (e) Foreign terminal state=escalated for THIS sha → HOLD.
reset_store
put_claim 7 cafef00d bob feat-x "$(now)" escalated
( RESOLVE_CLAIM=on WATCHER_SCOPE=all WATCHER_OWNER=alice _resolve_claim_should_hold 7 cafef00d feat-y )
[ $? -eq 0 ] || fail "foreign state=escalated for THIS sha must HOLD"
ok

# (f) Foreign claim for a DIFFERENT sha → stale, must proceed (1) — a new commit reshaped the conflict.
reset_store
put_claim 7 oldsha01 bob feat-x "$(now)" claimed
( RESOLVE_CLAIM=on WATCHER_SCOPE=all WATCHER_OWNER=alice _resolve_claim_should_hold 7 newsha02 feat-y ) \
  && fail "claim for a different sha must proceed (stale)" || true
ok

# (g) Our OWN seat's claim for this sha → proceed (local ledger governs, not a foreign hold).
reset_store
put_claim 7 cafef00d alice feat-y "$(now)" claimed
( RESOLVE_CLAIM=on WATCHER_SCOPE=all WATCHER_OWNER=alice _resolve_claim_should_hold 7 cafef00d feat-y ) \
  && fail "our own seat's claim must proceed, not self-hold" || true
ok

# (h) TTL-expired foreign claim → bounded steal: proceed (1) AND journal resolve_claim_steal.
reset_store
put_claim 7 cafef00d bob feat-x "$(( $(now) - 999999 ))" claimed
: > "$JLOG"
( RESOLVE_CLAIM=on WATCHER_SCOPE=all WATCHER_OWNER=alice RESOLVE_CLAIM_TTL=60 \
    _resolve_claim_should_hold 7 cafef00d feat-y )
rc=$?
[ "$rc" -eq 1 ] || fail "TTL-expired foreign claim must proceed (steal), got rc=$rc"
grep -q "resolve_claim_steal" "$JLOG" || fail "TTL steal must journal resolve_claim_steal: $(cat "$JLOG")"
ok

# (i) Outage while lever is on → fail-soft, must proceed (1), never hold on an unreadable claim.
reset_store
put_claim 7 cafef00d bob feat-x "$(now)" claimed
: > "$GH_OUTAGE_FLAG"
( RESOLVE_CLAIM=on WATCHER_SCOPE=all WATCHER_OWNER=alice _resolve_claim_should_hold 7 cafef00d feat-y ) \
  && fail "gh outage must fail-soft to proceed, never fabricate a hold" || true
rm -f "$GH_OUTAGE_FLAG"
ok

# ══════════════════════════ 8. _resolve_claim_publish_claimed / _publish_terminal ═══════════════
# (a) Lever off → zero gh calls.
reset_store
( unset RESOLVE_CLAIM; WATCHER_SCOPE=all WATCHER_OWNER=alice _resolve_claim_publish_claimed 9 a5000a1 feat-z )
[ -s "$GHLOG" ] && fail "publish_claimed with lever off must make ZERO gh calls: $(cat "$GHLOG")"
ok

# (b) Lever on, no existing claim → CREATE (POST), store gains exactly one row.
reset_store
( RESOLVE_CLAIM=on WATCHER_SCOPE=all WATCHER_OWNER=alice _resolve_claim_publish_claimed 9 a5000a1 feat-z )
n="$(jq 'length' "$STORE")"
[ "$n" = "1" ] || fail "publish_claimed create must leave exactly one comment, got $n"
jq -e '.[0].body | contains("seat: alice") and contains("state: claimed") and contains("sha: a5000a1")' "$STORE" >/dev/null \
  || fail "created claim body missing expected fields: $(cat "$STORE")"
ok
grep -q -- "-X PATCH" "$GHLOG" && fail "first publish must CREATE, not PATCH"
ok

# (c) Publishing again (renew) upserts IN PLACE — still exactly one comment, and a PATCH was used.
( RESOLVE_CLAIM=on WATCHER_SCOPE=all WATCHER_OWNER=alice _resolve_claim_publish_claimed 9 a5000a1 feat-z )
n="$(jq 'length' "$STORE")"
[ "$n" = "1" ] || fail "re-publish must upsert in place, not append (got $n rows)"
grep -q -- "-X PATCH" "$GHLOG" || fail "re-publish must PATCH the existing comment"
ok

# (d) Terminal update (done) rewrites the SAME row's state.
( RESOLVE_CLAIM=on WATCHER_SCOPE=all WATCHER_OWNER=alice _resolve_claim_publish_terminal 9 a5000a1 feat-z done )
n="$(jq 'length' "$STORE")"
[ "$n" = "1" ] || fail "terminal publish must not create a second row (got $n)"
jq -e '.[0].body | contains("state: done")' "$STORE" >/dev/null || fail "terminal publish did not update state to done"
ok

# (e) Outage on publish: best-effort, never blocks (returns 0) and never crashes.
: > "$GH_OUTAGE_FLAG"
( RESOLVE_CLAIM=on WATCHER_SCOPE=all WATCHER_OWNER=alice _resolve_claim_publish_claimed 9 a5000a1 feat-z )
rc=$?
rm -f "$GH_OUTAGE_FLAG"
[ "$rc" -eq 0 ] || fail "publish must return 0 even on a gh outage (best-effort)"
ok

echo "PASS: $PASS resolver-claim checks"
