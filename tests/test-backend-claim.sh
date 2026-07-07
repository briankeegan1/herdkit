#!/usr/bin/env bash
# test-backend-claim.sh — hermetic test of the API-backend _backend_claim_item ops (HERD-50):
#   • github: a FAKE `gh` on PATH scripts the issue state+assignees; asserts the claim/abort verdicts
#     and that a claim ADDS the assignee (never files or closes an issue).
#   • linear: _linear_gql is stubbed to script viewer{}, the issue read, and issueUpdate; asserts the
#     assignee-based claim/abort verdicts.
#   • changelog: an append-only tracker cannot claim → UNREACHABLE (fail-soft no-op).
# No network, no real gh/curl, no repo writes.
# Run:  bash tests/test-backend-claim.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BACKENDS="$HERE/../scripts/herd/backends"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass(){ PASS=$((PASS+1)); }

# ============================== GitHub backend (fake gh) ==============================================
GHLOG="$T/gh.log"
mkdir -p "$T/bin"
# The fake gh keys issue-view JSON on the issue NUMBER so different scenarios return different
# state/assignee shapes; `issue edit --add-assignee` just logs. `api user` returns our login.
cat > "$T/bin/gh" <<EOF
#!/usr/bin/env bash
echo "gh \$*" >> "$GHLOG"
case "\$1 \$2" in
  "api user") echo "me-login" ;;
  "issue view")
    _vnum=""
    for _va in "\$@"; do [ -z "\${_va##*[!0-9]*}" ] || { _vnum="\$_va"; break; }; done
    case "\$_vnum" in
      10) printf '{"state":"OPEN","assignees":[]}\n' ;;                                 # open, unassigned → claimable
      11) printf '{"state":"OPEN","assignees":[{"login":"other-op"}]}\n' ;;             # assigned to another → ALREADY
      12) printf '{"state":"CLOSED","assignees":[]}\n' ;;                               # closed → ALREADY
      13) printf '{"state":"OPEN","assignees":[{"login":"me-login"}]}\n' ;;             # already ours → SELF
      *)  printf '{"state":"OPEN","assignees":[]}\n' ;;
    esac
    ;;
  "issue edit") : ;;
  *) : ;;
esac
EOF
chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH"
export HERD_REPO="acme/widgets"

gh_claim() {  # $1 = ref (issue number), $2 = who
  ( cd "$T" && . "$BACKENDS/github.sh"
    _CLAIM_RESULT=""; _CLAIM_OWNER=""
    _backend_claim_item "$1" "$2"
    printf '%s\t%s\n' "${_CLAIM_RESULT:-}" "${_CLAIM_OWNER:-}" )
}

# 1. open + unassigned → CLAIMED, and gh issue edit --add-assignee was called (no create/close).
: > "$GHLOG"
out="$(gh_claim 10 me-login)"
echo "$out" | grep -q "^CLAIMED	me-login$" || fail "github claim-wins: expected CLAIMED me-login, got '$out'"
grep -q -- "issue edit -R acme/widgets 10 --add-assignee me-login" "$GHLOG" || fail "github claim-wins: did not add the assignee ($(cat "$GHLOG"))"
grep -q -- "issue create" "$GHLOG" && fail "github claim must never file a new issue"
grep -q -- "issue close"  "$GHLOG" && fail "github claim must never close an issue"
pass

# 2. assigned to another login → ALREADY (owner named), NO edit attempted.
: > "$GHLOG"
out="$(gh_claim 11 me-login)"
echo "$out" | grep -q "^ALREADY	other-op$" || fail "github already: expected ALREADY other-op, got '$out'"
grep -q -- "--add-assignee" "$GHLOG" && fail "github already: must NOT try to assign a contested issue"
pass

# 3. closed issue → ALREADY (shipped), no assign.
out="$(gh_claim 12 me-login)"
echo "$out" | grep -q "^ALREADY" || fail "github closed: expected ALREADY, got '$out'"
pass

# 4. already assigned to us → SELF (idempotent re-spawn), no assign.
: > "$GHLOG"
out="$(gh_claim 13 me-login)"
echo "$out" | grep -q "^SELF	me-login$" || fail "github self: expected SELF me-login, got '$out'"
grep -q -- "--add-assignee" "$GHLOG" && fail "github self: must NOT re-assign"
pass

# 5. unresolvable ref (empty search result) → UNREACHABLE (fail soft). A title slug with no match
#    returns "" from _github_resolve_issue's search. Point the stub's issue-list search at [].
cat > "$T/bin/gh" <<EOF
#!/usr/bin/env bash
echo "gh \$*" >> "$GHLOG"
case "\$1 \$2" in
  "api user")   echo "me-login" ;;
  "issue list") printf '[]' ;;
  *) : ;;
esac
EOF
chmod +x "$T/bin/gh"
out="$(gh_claim "no-such-title" me-login)"
echo "$out" | grep -q "^UNREACHABLE" || fail "github unresolvable ref: expected UNREACHABLE, got '$out'"
pass

# ============================== Linear backend (stubbed _linear_gql) ==================================
export LINEAR_API_KEY="lin_test_key"

# lin_claim <ref> <who> <issue-json-node> : source the backend, stub _linear_gql to return viewer,
# the scripted issue node for reads, and success for mutations, then run the claim.
lin_claim() {
  local ref="$1" who="$2" node="$3"
  ( cd "$T" && . "$BACKENDS/linear.sh"
    _linear_gql() {
      # $node is the scripted issue node (dynamic scope — visible from lin_claim's locals).
      case "$1" in
        *viewer*)      echo '{"data":{"viewer":{"id":"me-uid","name":"Me"}}}' ;;
        *issueUpdate*) echo '{"data":{"issueUpdate":{"success":true}}}' ;;
        *assignee*|*"state { type }"*|*issues*) printf '{"data":{"issues":{"nodes":[%s]}}}' "$node" ;;
        *) echo '{"data":{}}' ;;
      esac
    }
    _CLAIM_RESULT=""; _CLAIM_OWNER=""
    _backend_claim_item "$ref" "$who"
    printf '%s\t%s\n' "${_CLAIM_RESULT:-}" "${_CLAIM_OWNER:-}" )
}

# 6. unassigned + started-state available → CLAIMED (re-read shows us as assignee).
node='{"id":"iss1","identifier":"HERD-50","assignee":{"id":"me-uid","name":"Me"},"state":{"type":"unstarted"},"team":{"states":{"nodes":[{"id":"st_started"}]}}}'
out="$(lin_claim "HERD-50" alice "$node")"
echo "$out" | grep -q "^CLAIMED" || fail "linear claim-wins: expected CLAIMED, got '$out'"
pass

# 7. assigned to another user → ALREADY (owner named), never mutates.
node='{"id":"iss1","identifier":"HERD-50","assignee":{"id":"other-uid","name":"Other Op"},"state":{"type":"started"},"team":{"states":{"nodes":[{"id":"st_started"}]}}}'
out="$(lin_claim "HERD-50" alice "$node")"
echo "$out" | grep -q "^ALREADY	Other Op$" || fail "linear already: expected ALREADY 'Other Op', got '$out'"
pass

# 8. completed issue → ALREADY (shipped).
node='{"id":"iss1","identifier":"HERD-50","assignee":null,"state":{"type":"completed"},"team":{"states":{"nodes":[]}}}'
out="$(lin_claim "HERD-50" alice "$node")"
echo "$out" | grep -q "^ALREADY" || fail "linear completed: expected ALREADY, got '$out'"
pass

# 9. already assigned to us AND started → SELF.
node='{"id":"iss1","identifier":"HERD-50","assignee":{"id":"me-uid","name":"Me"},"state":{"type":"started"},"team":{"states":{"nodes":[{"id":"st_started"}]}}}'
out="$(lin_claim "HERD-50" alice "$node")"
echo "$out" | grep -q "^SELF" || fail "linear self: expected SELF, got '$out'"
pass

# ============================== changelog backend (no claim concept) ==================================
out="$( cd "$T" && . "$BACKENDS/changelog.sh"
  _CLAIM_RESULT=""; _CLAIM_OWNER=""
  _backend_claim_item "anything" whoever
  printf '%s\n' "${_CLAIM_RESULT:-}" )"
echo "$out" | grep -q "^UNREACHABLE$" || fail "changelog claim: expected UNREACHABLE (no claim concept), got '$out'"
pass

echo "ALL PASS ($PASS checks)"
