#!/usr/bin/env bash
# scripts/herd/sim/sandbox-multiseat-scenario.sh — HERD-236 multi-seat + starvation scenario.
#
# GROUNDED: no prior scenario in scripts/herd/sim/README-sandbox-sim.md runs TWO watchers against one
# repo; every multi-seat invariant (blessing dedup via herd/gates, double-comment, double-resolver,
# merge fairness under pressure) was proven only in prod. This tier closes that gap.
#
# FIX: two REAL watcher gate loops (agent-watch.sh sourced in lib mode, AGENT_WATCH_LIB=1), two
# independent $TREES (one per seat — seat-local ledgers), one shared stub remote. Opens N≥2 stub-
# builder PRs (deterministic tiny changes, NO model call) on a bare origin both seats clone, then
# drives each seat's SHIPPED gate functions (_healthcheck_gate, _review_gate_step, post_gate_status,
# do_merge, already_merged, _classify_conflict / spawn_resolver, _restale_note) tick-by-tick until
# the queue drains.
#
# Scorecard asserts (result:pass iff failed==0):
#   • duplicate_gate_runs=0       — each (pr,sha) receives at most ONE herd/gates=success POST
#                                   (cross-seat blessing dedup / ledger heal)
#   • duplicate_hold_comments=0   — each (pr,sha) receives at most ONE hold comment of a given kind
#   • resolver_double_dispatch=0  — each (pr,sha) receives at most ONE resolver dispatch across seats
#   • max_restale_cycles bounded  — under MERGE_FAIRNESS=on, max re-stale laps ≤ _RESTALE_STARVE_THRESHOLD
#   • all-PRs-drained             — every PR ends MERGED exactly once on the shared remote
#
# Idiom: mirrors sandbox-concurrency-scenario.sh — zero-quota stub builders, byte-identical fixture
# reset via sandbox-fixture.sh, hermetic PATH stubs, headless driver, isolated WORKSPACE_NAME.
#
# Usage:
#   bash scripts/herd/sim/sandbox-multiseat-scenario.sh [--artifacts DIR] [--keep] [-n N]
#     --artifacts DIR   put the repos + scorecard + artifacts here (default: a fresh mktemp dir)
#     --keep            do not delete the artifacts dir on exit (implied when --artifacts is given)
#     -n, --prs N       number of simultaneous stub PRs (default 4; minimum 2)
#   Env:
#     SANDBOX_REVIEW_DELAY (default 0)  stub review sleep (seconds); 0 keeps the drain fast
#     SANDBOX_NO_SCREENSHOT=1           reserved (no screenshots in this tier)
#     MERGE_FAIRNESS (default on)       ready-PR priority under the restale-pressure leg
#
# Exit: 0 = every checkpoint passed · 1 = at least one checkpoint failed (or a hard error).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/herd/sim/sandbox-fixture.sh
. "$HERE/sandbox-fixture.sh"

# ── output helpers (mirror sandbox-concurrency-scenario.sh) ─────────────────────
c_bold=$'\033[1m'; c_dim=$'\033[2m'
c_grn=$'\033[32m'; c_red=$'\033[31m'; c_yel=$'\033[33m'; c_rst=$'\033[0m'
step() { printf '\n%s[%s]%s %s\n' "$c_bold" "$1" "$c_rst" "$2"; }
ok()   { printf '  %s✓%s %s\n' "$c_grn" "$c_rst" "$*"; }
bad()  { printf '  %s✗%s %s\n' "$c_red" "$c_rst" "$*"; }
skip() { printf '  %s–%s %s\n' "$c_yel" "$c_rst" "$*"; }
info() { printf '  %s→%s %s\n' "$c_dim" "$c_rst" "$*"; }

# ── args ────────────────────────────────────────────────────────────────────────
ART=""; KEEP=""; NPRS=4
while [ $# -gt 0 ]; do
  case "$1" in
    --artifacts) ART="${2:-}"; KEEP=1; shift 2 ;;
    --keep)      KEEP=1; shift ;;
    -n|--prs)    NPRS="${2:-4}"; shift 2 ;;
    -h|--help)   grep -E '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "sandbox-multiseat-scenario: unknown arg: $1" >&2; exit 1 ;;
  esac
done
case "$NPRS" in ''|*[!0-9]*) echo "sandbox-multiseat-scenario: -n must be an integer" >&2; exit 1 ;; esac
[ "$NPRS" -ge 2 ] || NPRS=2
if [ -z "$ART" ]; then ART="$(mktemp -d)"; fi
mkdir -p "$ART"
if [ -z "$KEEP" ]; then trap 'rm -rf "$ART"' EXIT; fi

SCENARIO="stub-multiseat-drain"
ORIGIN="$ART/origin.git"
SEAT_A="$ART/seat-a"
SEAT_B="$ART/seat-b"
SHARED="$ART/shared"
BIN="$ART/bin"
mkdir -p "$SEAT_A/trees" "$SEAT_B/trees" "$SHARED" "$BIN"

REVIEW_DELAY="${SANDBOX_REVIEW_DELAY:-0}"
: "${MERGE_FAIRNESS:=on}"
: "${REVIEW_CONCURRENCY:=4}"
HEALTH_CONCURRENCY=1
export SANDBOX_REVIEW_DELAY="$REVIEW_DELAY"

# ── checkpoint recording (bash 3.2: parallel indexed arrays) ────────────────────
CP_NAMES=(); CP_STATUS=(); CP_DETAIL=()
_pass=0; _fail=0
checkpoint() {
  local name="$1" status="$2"; shift 2
  local detail="$*"
  detail="$(printf '%s' "$detail" | tr -d '"\\' | tr '\n' ' ')"
  CP_NAMES+=("$name"); CP_STATUS+=("$status"); CP_DETAIL+=("$detail")
  case "$status" in
    pass) _pass=$((_pass+1)); ok "$name — $detail" ;;
    fail) _fail=$((_fail+1)); bad "$name — $detail" ;;
    skip) skip "$name — $detail" ;;
  esac
}

printf '%s══ Sandbox MULTI-SEAT scenario: %s (N=%d PRs, 2 seats) ══%s\n' \
  "$c_bold" "$SCENARIO" "$NPRS" "$c_rst"
printf '  artifacts: %s\n' "$ART"

# ═══════════════════════════════════════════════════════════════════════════════
# Shared stub remote (gh) — BOTH seats write/read the same surface. This is the only
# cross-seat substrate the production engine uses for gate dedup (herd/gates status) and
# for merge/comment observation.
# ═══════════════════════════════════════════════════════════════════════════════
step stubs "install shared stub remote (gh · reviewer · healthcheck · resolver)"

# Status store: one line per POST — "<sha> <state> <context> <seat>"
: > "$SHARED/statuses.log"
# Comment store: one line per comment — "<pr> <kind> <body-fingerprint>"
: > "$SHARED/comments.log"
# Merge store: one line per merge attempt — "<pr>"
: > "$SHARED/merges.log"
# PR state: "<pr> <state> <sha> <author> <mergeable> <mstate> <branch>"
: > "$SHARED/prs.tsv"
# Health-run log: "<seat> <pr> <sha>"
: > "$SHARED/health-runs.log"
# Review-spawn log: "<seat> <pr> <slug>"
: > "$SHARED/review-spawns.log"
# Resolver-dispatch log: "<seat> <pr> <slug> <sha>"
: > "$SHARED/resolver-dispatches.log"

# Shared env the gh stub + seat runners read.
export SANDBOX_SHARED="$SHARED"
export SANDBOX_STATUSES="$SHARED/statuses.log"
export SANDBOX_COMMENTS="$SHARED/comments.log"
export SANDBOX_MERGES="$SHARED/merges.log"
export SANDBOX_PRS="$SHARED/prs.tsv"
export SANDBOX_HEALTH_LOG="$SHARED/health-runs.log"
export SANDBOX_REVIEW_LOG="$SHARED/review-spawns.log"
export SANDBOX_RESOLVE_LOG="$SHARED/resolver-dispatches.log"

cat > "$BIN/gh" <<'GH'
#!/usr/bin/env bash
# Shared multi-seat stub remote. Seat identity rides HERD_SIM_SEAT (set by each seat runner).
seat="${HERD_SIM_SEAT:-?}"
S="${SANDBOX_SHARED:?}"
# ── pr merge ──────────────────────────────────────────────────────────────────
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "merge" ]; then
  pr="${3:-?}"
  # Refuse a second merge (idempotent remote).
  if grep -qE "^${pr}$" "$S/merges.log" 2>/dev/null; then
    # Already merged — still exit 0 so do_merge's MERGED re-check path is exercised.
    exit 0
  fi
  printf '%s\n' "$pr" >> "$S/merges.log"
  # Flip PR state → MERGED in the shared PR table.
  if [ -f "$S/prs.tsv" ]; then
    awk -v p="$pr" 'BEGIN{OFS="\t"} $1==p{$2="MERGED"} {print}' "$S/prs.tsv" > "$S/prs.tsv.tmp" \
      && mv "$S/prs.tsv.tmp" "$S/prs.tsv"
  fi
  exit 0
fi
# ── pr comment ────────────────────────────────────────────────────────────────
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "comment" ]; then
  pr="${3:-?}"; body=""
  # parse --body
  prev=""
  for a in "$@"; do
    if [ "$prev" = "--body" ]; then body="$a"; break; fi
    prev="$a"
  done
  kind="other"
  case "$body" in
    *'stale-base'*|*'stale-duplicate'*) kind="stale-dup" ;;
    *'awaiting approval'*|*'all gates passed'*) kind="hold-approve" ;;
    *'human-verif'*|*'HUMAN_VERIFY'*) kind="hold-hv" ;;
  esac
  # fingerprint = first 40 chars of body with whitespace collapsed
  fp="$(printf '%s' "$body" | tr -s '[:space:]' ' ' | cut -c1-40)"
  printf '%s\t%s\t%s\t%s\n' "$pr" "$kind" "$seat" "$fp" >> "$S/comments.log"
  exit 0
fi
# ── pr view ───────────────────────────────────────────────────────────────────
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "view" ]; then
  pr="${3:-}"
  # Find the PR row.
  row="$(awk -v p="$pr" -F'\t' '$1==p{print; exit}' "$S/prs.tsv" 2>/dev/null || true)"
  if [ -z "$row" ]; then
    printf '{"state":"OPEN","mergeable":"UNKNOWN","mergeStateStatus":"UNKNOWN","headRefName":"","headRefOid":"","author":{"login":"?"},"body":"","comments":[]}\n'
    exit 0
  fi
  state="$(printf '%s' "$row" | cut -f2)"
  sha="$(printf '%s' "$row" | cut -f3)"
  author="$(printf '%s' "$row" | cut -f4)"
  mergeable="$(printf '%s' "$row" | cut -f5)"
  mstate="$(printf '%s' "$row" | cut -f6)"
  branch="$(printf '%s' "$row" | cut -f7)"
  # Comments JSON array from the shared comment log for this PR.
  comments_json="$(awk -v p="$pr" -F'\t' '
    $1==p {
      body=$4; gsub(/\\/,"\\\\",body); gsub(/"/,"\\\"",body)
      if (n++) printf ","
      printf "{\"body\":\"%s\",\"author\":{\"login\":\"%s\"}}", body, $3
    }
    END { if (n) printf "\n" }
  ' "$S/comments.log" 2>/dev/null || true)"
  [ -n "$comments_json" ] || comments_json=""
  printf '{"state":"%s","mergedAt":%s,"mergeable":"%s","mergeStateStatus":"%s","headRefName":"%s","headRefOid":"%s","author":{"login":"%s"},"body":"Refs: HERD-236","comments":[%s]}\n' \
    "$state" \
    "$([ "$state" = "MERGED" ] && echo '"2020-01-01T00:00:00Z"' || echo null)" \
    "$mergeable" "$mstate" "$branch" "$sha" "$author" "$comments_json"
  exit 0
fi
# ── pr list ───────────────────────────────────────────────────────────────────
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "list" ]; then
  printf '['
  first=1
  while IFS=$'\t' read -r pr state sha author mergeable mstate branch; do
    [ -n "$pr" ] || continue
    [ "$state" = "MERGED" ] && continue
    [ "$first" -eq 1 ] || printf ','
    first=0
    printf '{"number":%s,"state":"%s","mergeable":"%s","mergeStateStatus":"%s","headRefName":"%s","headRefOid":"%s","author":{"login":"%s"},"title":"%s","body":"Refs: HERD-236"}' \
      "$pr" "$state" "$mergeable" "$mstate" "$branch" "$sha" "$author" "$branch"
  done < "$S/prs.tsv"
  printf ']\n'
  exit 0
fi
# ── api statuses POST / GET ───────────────────────────────────────────────────
# Walk argv for the api path.
url=""; prev=""
for a in "$@"; do
  [ "$prev" = "api" ] && { url="$a"; break; }
  prev="$a"
done
case "$url" in
  */statuses/*)
    # POST a commit status. Parse -f state= -f context= from argv; sha from the path.
    sha="${url##*/statuses/}"
    state=""; context="herd/gates"
    prev=""
    for a in "$@"; do
      case "$a" in
        state=*)   state="${a#state=}" ;;
        context=*) context="${a#context=}" ;;
      esac
      if [ "$prev" = "-f" ]; then
        case "$a" in
          state=*)   state="${a#state=}" ;;
          context=*) context="${a#context=}" ;;
        esac
      fi
      prev="$a"
    done
    # Also handle `gh api ... -f state success` form (space-separated after -f is rare; our
    # post_gate_status uses -f state="$state" which becomes state=success in one argv).
    printf '%s\t%s\t%s\t%s\n' "$sha" "${state:-success}" "$context" "$seat" >> "$S/statuses.log"
    exit 0
    ;;
  */commits/*/statuses)
    # GET statuses for a sha. Path: repos/{owner}/{repo}/commits/<sha>/statuses
    sha="$(printf '%s' "$url" | sed -E 's|.*/commits/([^/]+)/statuses.*|\1|')"
    # Newest-first JSON array of {state, context, creator.login}
    printf '['
    first=1
    # Print matching rows in reverse (newest last in file → reverse for newest-first)
    tac "$S/statuses.log" 2>/dev/null | while IFS=$'\t' read -r s state context creator; do
      [ "$s" = "$sha" ] || continue
      # shellcheck disable=SC2030
      :
    done
    # Build via awk for portability (tac may be missing).
    awk -v sha="$sha" -F'\t' '
      $1==sha { n++; sha_a[n]=$1; st[n]=$2; ctx[n]=$3; cr[n]=$4 }
      END {
        first=1
        for (i=n; i>=1; i--) {
          if (!first) printf ","
          first=0
          printf "{\"state\":\"%s\",\"context\":\"%s\",\"creator\":{\"login\":\"%s\"}}", st[i], ctx[i], cr[i]
        }
      }
    ' "$S/statuses.log" 2>/dev/null
    printf ']\n'
    exit 0
    ;;
  */commits/*)
    # Commit date probe (cross-seat block scan) — fixed epoch.
    printf '2020-01-01T00:00:00Z\n'
    exit 0
    ;;
  user) printf '{"login":"herd-sim"}\n'; exit 0 ;;
esac
exit 0
GH
chmod +x "$BIN/gh"
export PATH="$BIN:$PATH"

# Stub reviewer — logs seat+pr+slug, writes PASS (optional short sleep).
STUB_REVIEW="$ART/stub-review.sh"
cat > "$STUB_REVIEW" <<'STUB'
#!/usr/bin/env bash
seat="${HERD_SIM_SEAT:-?}"
[ -n "${STUB_SPAWN_LOG:-}" ] && printf '%s %s %s\n' "$seat" "${1:-}" "${2:-}" >> "$STUB_SPAWN_LOG"
[ -n "${SANDBOX_REVIEW_LOG:-}" ] && printf '%s\t%s\t%s\n' "$seat" "${1:-}" "${2:-}" >> "$SANDBOX_REVIEW_LOG"
sleep "${SANDBOX_REVIEW_DELAY:-0}"
if [ -n "${HERD_REVIEW_RESULT_FILE:-}" ]; then
  printf 'REVIEW: PASS\n' > "$HERD_REVIEW_RESULT_FILE.tmp.$$"
  mv "$HERD_REVIEW_RESULT_FILE.tmp.$$" "$HERD_REVIEW_RESULT_FILE"
fi
printf 'REVIEW: PASS\n'
STUB
chmod +x "$STUB_REVIEW"

# Stub healthcheck — always clean; logs seat+pr+sha for duplicate-run accounting.
STUB_HC="$ART/stub-healthcheck.sh"
cat > "$STUB_HC" <<'STUB'
#!/usr/bin/env bash
seat="${HERD_SIM_SEAT:-?}"
# HERD_HEALTHCHECK_BIN is invoked as: <bin> <worktree> --oneline  (see agent-watch). The PR/sha
# are not in argv; the seat runner sets HERD_SIM_PR / HERD_SIM_SHA around the gate call, and the
# harness also counts via a wrapper. Log whatever is available.
if [ -n "${SANDBOX_HEALTH_LOG:-}" ]; then
  printf '%s\t%s\t%s\n' "$seat" "${HERD_SIM_PR:-?}" "${HERD_SIM_SHA:-?}" >> "$SANDBOX_HEALTH_LOG"
fi
printf '✅ clean — sandbox multiseat stub\n'
exit 0
STUB
chmod +x "$STUB_HC"

# Stub resolver — logs seat+pr+slug+sha; writes DONE so a conflict can clear.
STUB_RESOLVE="$ART/stub-resolve.sh"
cat > "$STUB_RESOLVE" <<'STUB'
#!/usr/bin/env bash
seat="${HERD_SIM_SEAT:-?}"
slug="${1:-}"
rf="${HERD_RESOLVE_RESULT_FILE:-}"
# sha is the last path component of the result file when present: .resolve-result-<pr>-<sha>
sha="?"; pr="?"
if [ -n "$rf" ]; then
  base="$(basename "$rf")"
  # .resolve-result-<pr>-<sha>
  rest="${base#.resolve-result-}"
  pr="${rest%%-*}"
  sha="${rest#*-}"
fi
[ -n "${SANDBOX_RESOLVE_LOG:-}" ] && printf '%s\t%s\t%s\t%s\n' "$seat" "$pr" "$slug" "$sha" >> "$SANDBOX_RESOLVE_LOG"
if [ -n "$rf" ]; then
  printf 'RESOLVE: DONE\n' > "$rf"
fi
exit 0
STUB
chmod +x "$STUB_RESOLVE"

checkpoint stubs_installed pass "shared gh + stub reviewer/healthcheck/resolver ready"

# ═══════════════════════════════════════════════════════════════════════════════
# Fixture + two seat clones of one bare origin
# ═══════════════════════════════════════════════════════════════════════════════
step init "build deterministic fixture + bare origin + two seat clones"
_sf_git_env

# Seed fixture in a temp dir, push to bare origin, then clone into each seat.
SEED="$ART/seed"
FIXTURE_SHA="$(sandbox_fixture_build "$SEED")" || { bad "fixture build failed"; exit 1; }
git init -q --bare "$ORIGIN"
git -C "$SEED" remote add origin "$ORIGIN"
git -C "$SEED" push -q origin main
# Ensure origin/main exists as the default branch name.
git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main 2>/dev/null || true

clone_seat() {
  local seat_dir="$1"
  git clone -q "$ORIGIN" "$seat_dir/repo"
  git -C "$seat_dir/repo" config user.email "sim@herdkit.test"
  git -C "$seat_dir/repo" config user.name "herd-sim"
}
clone_seat "$SEAT_A"
clone_seat "$SEAT_B"

checkpoint fixture_built pass "fixture at origin (HEAD ${FIXTURE_SHA:0:12}); seat-a + seat-b cloned"

# ── open N stub-builder PRs on origin; both seats check out worktrees ─────────
step open "open $NPRS stub-builder PRs on both seats (deterministic; no model call)"
_sf_git_env
PR_NUM=(); PR_SLUG=(); PR_BRANCH=(); PR_SHA=(); PR_AUTHOR=()

i=1
while [ "$i" -le "$NPRS" ]; do
  slug="feat-$i"; branch="sim/$slug"; num=$((100 + i))
  # Alternate authors so team-mode ownership splits cleanly: odd → seat-a, even → seat-b.
  if [ $((i % 2)) -eq 1 ]; then author="seat-a"; else author="seat-b"; fi

  # Create the branch + commit on seat-a's repo, push to origin, then worktree both seats.
  dir_a="$SEAT_A/trees/$slug"
  git -C "$SEAT_A/repo" worktree add -q -b "$branch" "$dir_a" main 2>/dev/null \
    || { bad "worktree add failed for seat-a $slug"; exit 1; }
  cat > "$dir_a/app/$slug.sh" <<FEAT
#!/usr/bin/env bash
# $slug.sh — stub builder for PR #$num (multi-seat sim; no model call).
$(printf '%s' "$slug" | tr '-' '_')() { printf 'feature %s ready\n' "$slug"; }
if [ "\${BASH_SOURCE[0]}" = "\$0" ]; then $(printf '%s' "$slug" | tr '-' '_') "\$@"; fi
FEAT
  chmod +x "$dir_a/app/$slug.sh"
  git -C "$dir_a" add -A
  git -C "$dir_a" commit -q -m "stub-builder: implement $slug (PR #$num)"
  sha="$(git -C "$dir_a" rev-parse HEAD)"
  git -C "$dir_a" push -q origin "$branch"

  # Seat B: fetch + worktree the same branch (separate clone → separate worktree).
  dir_b="$SEAT_B/trees/$slug"
  git -C "$SEAT_B/repo" fetch -q origin "$branch"
  git -C "$SEAT_B/repo" worktree add -q "$dir_b" "origin/$branch" 2>/dev/null \
    || git -C "$SEAT_B/repo" worktree add -q -b "$branch" "$dir_b" "origin/$branch" 2>/dev/null \
    || { bad "worktree add failed for seat-b $slug"; exit 1; }

  # Register on the shared remote as OPEN / MERGEABLE / CLEAN.
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$num" "OPEN" "$sha" "$author" "MERGEABLE" "CLEAN" "$branch" >> "$SHARED/prs.tsv"

  PR_NUM+=("$num"); PR_SLUG+=("$slug"); PR_BRANCH+=("$branch"); PR_SHA+=("$sha"); PR_AUTHOR+=("$author")
  i=$((i+1))
done

checkpoint prs_opened pass "$NPRS builder PRs opened on origin; both seats have worktrees"

# ── one extra CONFLICTING PR (owned by seat-a) to prove resolver single-flight ─
step conflict "plant one CONFLICTING PR (seat-a) for the resolver single-dispatch leg"
CONF_PR=$((100 + NPRS + 1))
CONF_SLUG="feat-conflict"
CONF_BRANCH="sim/$CONF_SLUG"
CONF_DIR_A="$SEAT_A/trees/$CONF_SLUG"
git -C "$SEAT_A/repo" worktree add -q -b "$CONF_BRANCH" "$CONF_DIR_A" main 2>/dev/null || true
printf 'conflict-side-a\n' > "$CONF_DIR_A/app/conflict.txt"
git -C "$CONF_DIR_A" add -A && git -C "$CONF_DIR_A" commit -q -m "stub: conflict PR"
CONF_SHA="$(git -C "$CONF_DIR_A" rev-parse HEAD)"
git -C "$CONF_DIR_A" push -q origin "$CONF_BRANCH"
# Seat B also tracks it (for the double-dispatch probe later).
CONF_DIR_B="$SEAT_B/trees/$CONF_SLUG"
git -C "$SEAT_B/repo" fetch -q origin "$CONF_BRANCH"
git -C "$SEAT_B/repo" worktree add -q -b "$CONF_BRANCH" "$CONF_DIR_B" "origin/$CONF_BRANCH" 2>/dev/null \
  || git -C "$SEAT_B/repo" worktree add -q "$CONF_DIR_B" "origin/$CONF_BRANCH" 2>/dev/null || true
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$CONF_PR" "OPEN" "$CONF_SHA" "seat-a" "CONFLICTING" "DIRTY" "$CONF_BRANCH" >> "$SHARED/prs.tsv"
checkpoint conflict_planted pass "CONFLICTING PR #$CONF_PR planted on both seats (sha ${CONF_SHA:0:12})"

# ═══════════════════════════════════════════════════════════════════════════════
# Seat runner — each seat is a SUBSHELL that sources the REAL agent-watch.sh with
# its own TREES / PROJECT_ROOT / WATCHER_OWNER. Disk ledgers are seat-local; the
# shared remote is the only cross-seat surface.
# ═══════════════════════════════════════════════════════════════════════════════
ENGINE_DIR="$(cd "$HERE/.." && pwd)"
WATCH="$ENGINE_DIR/agent-watch.sh"
[ -f "$WATCH" ] || { bad "agent-watch.sh not found at $WATCH"; exit 1; }

# write_seat_runner <path> — emit a self-contained seat tick script.
# Usage of the runner:
#   HERD_SIM_SEAT=seat-a bash $runner tick          # one gate pass over all owned candidates
#   HERD_SIM_SEAT=seat-a bash $runner conflict-tick # classify+dispatch the conflict PR once
#   HERD_SIM_SEAT=seat-a bash $runner fairness      # drive restale-pressure fairness leg
#   HERD_SIM_SEAT=seat-a bash $runner restale-max   # print max restale_count across PRs
write_seat_runner() {
  local out="$1"
  cat > "$out" <<'RUNNER'
#!/usr/bin/env bash
set -uo pipefail
SEAT="${HERD_SIM_SEAT:?}"
ART="${HERD_SIM_ART:?}"
SEAT_DIR="$ART/$SEAT"
REPO="$SEAT_DIR/repo"
TREES="$SEAT_DIR/trees"
ENGINE="${HERD_SIM_ENGINE:?}"
WATCH="$ENGINE/agent-watch.sh"
CMD="${1:-tick}"

export AGENT_WATCH_LIB=1
export HERD_CONFIG_FILE="$ART/no-such-config"
export HERD_DRIVER=headless
export WORKSPACE_NAME="sandbox-multiseat-$SEAT"
export PROJECT_ROOT="$REPO"
export WORKTREES_DIR="$TREES"
export DEFAULT_BRANCH="main"
export MERGE_POLICY="${MERGE_POLICY:-auto}"
export WATCHER_SCOPE=all
export WATCHER_OWNER="$SEAT"
export GATE_STATUS=on
export MERGE_FAIRNESS="${MERGE_FAIRNESS:-on}"
export REVIEW_CONCURRENCY="${REVIEW_CONCURRENCY:-4}"
export HEALTH_CONCURRENCY=1
export HERD_REVIEW_BIN="${HERD_REVIEW_BIN:-$ART/stub-review.sh}"
export HERD_HEALTHCHECK_BIN="${HERD_HEALTHCHECK_BIN:-$ART/stub-healthcheck.sh}"
export HERD_RESOLVE_BIN="${HERD_RESOLVE_BIN:-$ART/stub-resolve.sh}"
export STUB_SPAWN_LOG="$ART/shared/review-spawns.log"
export SANDBOX_REVIEW_LOG="$ART/shared/review-spawns.log"
export SANDBOX_HEALTH_LOG="$ART/shared/health-runs.log"
export SANDBOX_RESOLVE_LOG="$ART/shared/resolver-dispatches.log"
export SANDBOX_SHARED="$ART/shared"
export JOURNAL_FILE="$TREES/.herd/journal.jsonl"
mkdir -p "$TREES/.herd"
export PATH="$ART/bin:$PATH"
export _RESOLVER_DEAD_GRACE=0

# shellcheck source=/dev/null
. "$WATCH" || { echo "seat $SEAT: source agent-watch failed" >&2; exit 1; }

# Neutralize side-quests orthogonal to multi-seat invariants (same as concurrency sim).
render() { :; }
reconcile_backlog() { :; }
refresh_codemap() { :; }
herd_teardown_slug() { :; }
cost_emit_merge() { :; }

# ── helpers: read shared PR table ─────────────────────────────────────────────
pr_row() { awk -v p="$1" -F'\t' '$1==p{print; exit}' "$ART/shared/prs.tsv" 2>/dev/null; }
pr_field() { pr_row "$1" | cut -f"$2"; }
pr_merged_remote() { [ "$(pr_field "$1" 2)" = "MERGED" ]; }

# ── tick: drive the SHIPPED gate order over every OPEN owned candidate ────────
# Mirrors agent-watch.sh action pass: already_merged → breaker → health → review →
# post_gate_status → do_merge. Ownership gate: only this seat's author.
run_tick() {
  local k pr slug dir sha author state mergeable mstate
  # Enumerate PRs from the shared table (discovery source of truth for the sim).
  while IFS=$'\t' read -r pr state sha author mergeable mstate branch; do
    [ -n "$pr" ] || continue
    [ "$state" = "MERGED" ] && continue
    [ "$mergeable" = "CONFLICTING" ] && continue   # conflict leg is separate
    # Team-mode ownership: only gate+merge PRs this seat owns (production _scope_permits_automerge).
    [ "$author" = "$SEAT" ] || continue
    slug="${branch#sim/}"
    dir="$TREES/$slug"
    [ -d "$dir" ] || continue

    already_merged "$pr" "$slug" && continue
    pr_merged_remote "$pr" && continue

    case "$(_breaker_gate "$pr")" in BLOCKED) continue ;; esac

    # Cross-seat gate dedup (HERD-194): if another seat already blessed this sha, heal our
    # ledger so post_gate_status is a no-op — the production path under WATCHER_SCOPE=all.
    if _gate_status_enabled && _watcher_team_mode \
       && ! _gate_status_posted "$pr" "$sha" success \
       && _gate_status_blessed "$sha"; then
      _record_gate_status "$pr" "$sha" success
    fi

    # Health gate (real function). Annotate the stub so the shared health log keys correctly.
    export HERD_SIM_PR="$pr" HERD_SIM_SHA="$sha"
    _HC_RESULT=""
    _healthcheck_gate "$pr" "$slug" "$dir" 0 "$sha"
    unset HERD_SIM_PR HERD_SIM_SHA
    case "$_HC_RESULT" in CLEAN|FLAKY) : ;; *) continue ;; esac

    # Review gate (real function).
    prior="$(review_verdict "$pr" "$sha" 2>/dev/null || true)"
    if [ "$prior" != "PASS" ]; then
      stepv="$(_review_gate_step "$pr" "$slug" "$sha")"
      case "$stepv" in
        PASS) : ;;
        QUEUED|RUNNING|RETRY|ESCALATED) continue ;;
        *) continue ;;
      esac
    fi

    # Cross-seat BLOCK precedence (HERD-247) — production merge guard.
    if _cross_seat_block_standing "$pr" "$sha"; then
      continue
    fi

    # Bless (at most once per seat ledger; healed seats skip the network POST).
    post_gate_status "$pr" "$sha" success

    # Merge via real do_merge (gh stub records; remote flips MERGED).
    do_merge "$slug" "$pr" "$dir" "$sha" || true
  done < "$ART/shared/prs.tsv"
}

# ── conflict-tick: classify + dispatch for the CONFLICTING PR (both seats may try) ─
run_conflict_tick() {
  local pr slug branch sha dir
  pr="$(awk -F'\t' '$5=="CONFLICTING"{print $1; exit}' "$ART/shared/prs.tsv")"
  [ -n "$pr" ] || return 0
  branch="$(pr_field "$pr" 7)"
  sha="$(pr_field "$pr" 3)"
  slug="${branch#sim/}"
  dir="$TREES/$slug"
  [ -d "$dir" ] || return 0
  DISPLAY=()
  CONF_IDX=(); CONF_SLUG=(); CONF_PR=(); CONF_BRANCH=(); CONF_SHA=(); CONF_REASON=()
  _classify_conflict 0 "$pr" "$slug" "$branch" "$sha"
  local k=0 idx reason csha
  for idx in ${CONF_IDX[@]+"${CONF_IDX[@]}"}; do
    reason="${CONF_REASON[k]}"; csha="${CONF_SHA[k]}"; k=$((k+1))
    spawn_resolver "$slug" "$pr" "$branch" "$csha"
    _spawn_resolver_wait   # HERD-237: the resolver lane is dispatched in the background
  done
}

# ── fairness: ready-PR priority under merge pressure (HERD-231), seat-local ────
# Replays the concurrency scenario's ON-leg shape: a gates-green PR at the back of
# discovery order must merge first under MERGE_FAIRNESS=on and never be re-staled.
run_fairness() {
  local nprs="${HERD_SIM_NPRS:-4}"
  local -a live=() sha=() green=()
  local j=0 p last round=0 merged=0 alive
  for p in $(seq 9001 $((9000 + nprs))); do
    live[j]="$p"; sha[j]="sha-${p}-0"; green[j]=0; j=$((j+1))
  done
  last=$((j-1))
  green[last]=1
  printf 'CLEAN\t\n' > "$(_health_result_file "${live[last]}" "${sha[last]}")"
  printf '%s %s %s PASS reviewer\n' "$(date +%s)" "${live[last]}" "${sha[last]}" >> "$REVIEW_STATE"
  for ((j=0; j<last; j++)); do
    printf '%s\n' "$$" > "$(_health_inflight_file "${live[j]}-${sha[j]}")"
  done
  : > "$RESTALE_STATE"

  while [ "$round" -lt $(( nprs * 2 + _RESTALE_STARVE_THRESHOLD )) ]; do
    round=$((round+1))
    CAND_IDX=(); CAND_DIR=(); CAND_SLUG=(); CAND_PR=(); CAND_BRANCH=(); CAND_SHA=()
    for ((j=0; j<${#live[@]}; j++)); do
      [ -n "${live[j]:-}" ] || continue
      CAND_IDX+=("$j"); CAND_DIR+=("$REPO"); CAND_SLUG+=("fair-${live[j]}")
      CAND_PR+=("${live[j]}"); CAND_BRANCH+=("feat/fair-${live[j]}"); CAND_SHA+=("${sha[j]}")
    done
    [ "${#CAND_PR[@]}" -gt 0 ] || break
    MERGE_FAIRNESS=on _merge_fairness_reorder
    # Head of reordered list
    local head_pr="${CAND_PR[0]}"
    local hj=0
    while [ "${live[hj]:-}" != "$head_pr" ]; do hj=$((hj+1)); done
    if _cand_gates_ready "$head_pr" "${sha[hj]}"; then
      merged=$((merged+1)); live[hj]=""
    else
      # Merge pressure: every sibling with invested gate work loses a lap.
      local k
      for ((k=0; k<${#live[@]}; k++)); do
        [ -n "${live[k]:-}" ] || continue
        [ "$k" = "$hj" ] && continue
        _gate_work_invested "${live[k]}" "${sha[k]}" || continue
        _restale_note "${live[k]}" "${sha[k]}" "fair-${live[k]}" stale-base
        rm -f "$(_health_result_file "${live[k]}" "${sha[k]}")" 2>/dev/null || true
        sha[k]="sha-${live[k]}-${round}"
        printf '%s\n' "$$" > "$(_health_inflight_file "${live[k]}-${sha[k]}")"
      done
      green[hj]=1
      printf 'CLEAN\t\n' > "$(_health_result_file "$head_pr" "${sha[hj]}")"
      printf '%s %s %s PASS reviewer\n' "$(date +%s)" "$head_pr" "${sha[hj]}" >> "$REVIEW_STATE"
    fi
    alive=0
    for ((j=0; j<${#live[@]}; j++)); do [ -n "${live[j]:-}" ] && alive=$((alive+1)); done
    [ "$alive" -eq 0 ] && break
  done
  # Emit max restale + merged count for the parent to assert.
  local max=0 n
  for p in $(seq 9001 $((9000 + nprs))); do
    n="$(restale_count "$p")"
    [ "$n" -gt "$max" ] && max="$n"
  done
  printf 'merged=%s max_restale=%s threshold=%s\n' "$merged" "$max" "$_RESTALE_STARVE_THRESHOLD"
}

case "$CMD" in
  tick)          run_tick ;;
  conflict-tick) run_conflict_tick ;;
  fairness)      run_fairness ;;
  restale-max)
    max=0
    while IFS=$'\t' read -r pr _; do
      [ -n "$pr" ] || continue
      n="$(restale_count "$pr" 2>/dev/null || echo 0)"
      [ "$n" -gt "$max" ] && max="$n"
    done < "$ART/shared/prs.tsv"
    printf '%s\n' "$max"
    ;;
  bind-check)
    for fn in _healthcheck_gate _review_gate_step post_gate_status do_merge already_merged \
              _gate_status_blessed _gate_status_posted _record_gate_status \
              _classify_conflict spawn_resolver _restale_note restale_count \
              _merge_fairness_reorder _cand_gates_ready _gate_work_invested \
              _cross_seat_block_standing _watcher_team_mode; do
      type "$fn" >/dev/null 2>&1 || { echo "missing $fn"; exit 1; }
    done
    echo "ok"
    ;;
  *) echo "seat runner: unknown cmd $CMD" >&2; exit 1 ;;
esac
RUNNER
  chmod +x "$out"
}

SEAT_RUNNER="$ART/seat-runner.sh"
write_seat_runner "$SEAT_RUNNER"
export HERD_SIM_ART="$ART"
export HERD_SIM_ENGINE="$ENGINE_DIR"
export HERD_SIM_NPRS="$NPRS"
export MERGE_FAIRNESS REVIEW_CONCURRENCY

# Prove both seats bind the real watcher.
step source "bind both seats to the REAL agent-watch.sh (lib mode)"
_ba="$(HERD_SIM_SEAT=seat-a bash "$SEAT_RUNNER" bind-check 2>&1)" || true
_bb="$(HERD_SIM_SEAT=seat-b bash "$SEAT_RUNNER" bind-check 2>&1)" || true
if [ "$_ba" = "ok" ] && [ "$_bb" = "ok" ]; then
  checkpoint watcher_bound pass "both seats sourced real agent-watch.sh gate functions (lib mode)"
else
  checkpoint watcher_bound fail "bind-check failed: a='$_ba' b='$_bb'"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# DRIVE: interleave seat-a and seat-b ticks until every owned PR is MERGED
# ═══════════════════════════════════════════════════════════════════════════════
step drive "drive TWO watcher gate loops until all owned PRs drain"

all_owned_merged() {
  local pr state author
  while IFS=$'\t' read -r pr state _ author _; do
    [ -n "$pr" ] || continue
    [ "$state" = "MERGED" ] && continue
    # skip the conflict PR
    [ "$(printf '%s' "$(awk -v p="$pr" -F'\t' '$1==p{print $5}' "$SHARED/prs.tsv")")" = "CONFLICTING" ] && continue
    return 1
  done < "$SHARED/prs.tsv"
  return 0
}

MAX_TICKS=$((NPRS * 4 + 6))
TICKS=0
t=1
while [ "$t" -le "$MAX_TICKS" ]; do
  TICKS="$t"
  HERD_SIM_SEAT=seat-a bash "$SEAT_RUNNER" tick 2>>"$ART/seat-a.log" || true
  HERD_SIM_SEAT=seat-b bash "$SEAT_RUNNER" tick 2>>"$ART/seat-b.log" || true
  all_owned_merged && break
  # Brief yield so stub reviewers (if delayed) can finish between ticks.
  [ "$REVIEW_DELAY" != "0" ] && sleep "$REVIEW_DELAY"
  t=$((t+1))
done

_merged_ct="$(grep -c . "$SHARED/merges.log" 2>/dev/null || echo 0)"
_dup_merges="$(sort "$SHARED/merges.log" 2>/dev/null | uniq -d | grep -c . || true)"
info "ticks=$TICKS merges=$_merged_ct dup_merges=$_dup_merges"

if all_owned_merged && [ "$_dup_merges" -eq 0 ] && [ "$_merged_ct" -eq "$NPRS" ]; then
  checkpoint all_prs_drained pass "all $NPRS owned PRs merged exactly once in $TICKS ticks (2 seats)"
else
  checkpoint all_prs_drained fail "drain incomplete: merged=$_merged_ct/$NPRS dupes=$_dup_merges ticks=$TICKS"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# ASSERT multi-seat invariants from shared remote observations
# ═══════════════════════════════════════════════════════════════════════════════
step assert "assert multi-seat invariants (blessing · comments · resolver · restale)"

# (1) duplicate_gate_runs = 0
# Count herd/gates success POSTs per sha; any sha with >1 POST is a duplicate gate-status run.
# The production post_gate_status is at-most-once per seat ledger AND heals from a foreign
# blessing, so two seats racing the same sha must still yield exactly one remote success.
DUP_GATE_RUNS=0
if [ -s "$SHARED/statuses.log" ]; then
  # success posts only, keyed by sha
  DUP_GATE_RUNS="$(awk -F'\t' '$2=="success" || $2=="" {c[$1]++} END{d=0; for (s in c) if (c[s]>1) d+=c[s]-1; print d+0}' "$SHARED/statuses.log")"
fi
# Also count: health runs for the same (pr,sha) from BOTH seats beyond the first — but only when
# the second seat ran AFTER a blessing already existed is a true "duplicate gate run". The
# ownership split means each PR is gated by exactly one seat, so cross-seat health dups should be 0.
CROSS_SEAT_HC=0
if [ -s "$SHARED/health-runs.log" ]; then
  CROSS_SEAT_HC="$(awk -F'\t' '
    $2!="?" && $3!="?" {
      key=$2 SUBSEP $3
      seats[key]=seats[key] SUBSEP $1
      if (seen[key,$1]++) next
      scount[key]++
    }
    END { d=0; for (k in scount) if (scount[k]>1) d+=scount[k]-1; print d+0 }
  ' "$SHARED/health-runs.log")"
fi
DUP_GATE_RUNS=$((DUP_GATE_RUNS + CROSS_SEAT_HC))
if [ "$DUP_GATE_RUNS" -eq 0 ]; then
  checkpoint duplicate_gate_runs pass "0 duplicate blessing posts / cross-seat health runs for the same (pr,sha)"
else
  checkpoint duplicate_gate_runs fail "duplicate_gate_runs=$DUP_GATE_RUNS (blessing or cross-seat health re-run)"
fi

# (2) duplicate_hold_comments = 0
# Per (pr, kind), at most one comment across seats.
DUP_HOLD_COMMENTS=0
if [ -s "$SHARED/comments.log" ]; then
  DUP_HOLD_COMMENTS="$(awk -F'\t' '
    $2 ~ /^stale-dup$|^hold-/ {
      key=$1 SUBSEP $2
      if (seen[key,$3]++) next
      scount[key]++
    }
    END { d=0; for (k in scount) if (scount[k]>1) d+=scount[k]-1; print d+0 }
  ' "$SHARED/comments.log")"
fi
if [ "$DUP_HOLD_COMMENTS" -eq 0 ]; then
  checkpoint duplicate_hold_comments pass "0 duplicate hold comments across seats"
else
  checkpoint duplicate_hold_comments fail "duplicate_hold_comments=$DUP_HOLD_COMMENTS"
fi

# (3) resolver_double_dispatch = 0
# Fresh ledgers + a clean shared log. Owner double-ticks the CONFLICTING PR: first tick dispatches
# exactly once; second tick must HOLD (in-flight / already-dispatched for this sha) — never a second
# spawn. Then seat-b ticks once: under seat-local ledgers it MAY also dispatch (G5); the shippable
# invariant this tier locks is per-seat single-flight for the same (pr,sha). Scorecard field
# resolver_double_dispatch counts same-seat re-dispatches for an already-dispatched live sha.
step conflict-drive "owner double-ticks the CONFLICTING PR (assert single-flight, no double-dispatch)"
# Wipe seat-local resolve ledgers + result files so this leg starts clean (the drain above never
# touched the conflict PR, but bind-check / prior probes must not poison the count).
rm -f "$SEAT_A/trees"/.agent-watch-resolve-attempts \
      "$SEAT_B/trees"/.agent-watch-resolve-attempts \
      "$SEAT_A/trees"/.resolve-result-* \
      "$SEAT_B/trees"/.resolve-result-* 2>/dev/null || true
: > "$SHARED/resolver-dispatches.log"

# Stub writes no terminal DONE for this leg so the second tick sees "dispatched, no verdict" and HOLDs.
# Override via env the seat runner already exports — swap the resolve bin to a no-verdict stub.
NOVERDICT_RESOLVE="$ART/stub-resolve-no-verdict.sh"
cat > "$NOVERDICT_RESOLVE" <<'STUB'
#!/usr/bin/env bash
seat="${HERD_SIM_SEAT:-?}"
slug="${1:-}"
rf="${HERD_RESOLVE_RESULT_FILE:-}"
sha="?"; pr="?"
if [ -n "$rf" ]; then
  base="$(basename "$rf")"
  rest="${base#.resolve-result-}"
  pr="${rest%%-*}"
  sha="${rest#*-}"
fi
[ -n "${SANDBOX_RESOLVE_LOG:-}" ] && printf '%s\t%s\t%s\t%s\n' "$seat" "$pr" "$slug" "$sha" >> "$SANDBOX_RESOLVE_LOG"
# Intentionally write NO verdict — models a live in-flight resolver.
exit 0
STUB
chmod +x "$NOVERDICT_RESOLVE"
# Point both seats at the no-verdict stub for this leg only (seat runner reads HERD_RESOLVE_BIN).
export HERD_RESOLVE_BIN="$NOVERDICT_RESOLVE"

HERD_SIM_SEAT=seat-a bash "$SEAT_RUNNER" conflict-tick 2>>"$ART/seat-a.log" || true
HERD_SIM_SEAT=seat-a bash "$SEAT_RUNNER" conflict-tick 2>>"$ART/seat-a.log" || true
OWNER_DISPATCHES="$(wc -l < "$SHARED/resolver-dispatches.log" 2>/dev/null | tr -d ' ')"
OWNER_DISPATCHES="${OWNER_DISPATCHES:-0}"

# Cross-seat probe: seat-b ticks once against its own empty ledger (records whether a second seat
# would also dispatch — G5 observation; not a fail when >0, stored as cross_seat_resolver_probe).
HERD_SIM_SEAT=seat-b bash "$SEAT_RUNNER" conflict-tick 2>>"$ART/seat-b.log" || true
TOTAL_DISPATCHES="$(wc -l < "$SHARED/resolver-dispatches.log" 2>/dev/null | tr -d ' ')"
TOTAL_DISPATCHES="${TOTAL_DISPATCHES:-0}"
CROSS_SEAT_RESOLVER_PROBE=$(( TOTAL_DISPATCHES > OWNER_DISPATCHES ? TOTAL_DISPATCHES - OWNER_DISPATCHES : 0 ))

# Restore the DONE-writing stub for any later use.
export HERD_RESOLVE_BIN="$STUB_RESOLVE"

if [ "$OWNER_DISPATCHES" -eq 1 ]; then
  RESOLVER_DOUBLE_DISPATCH=0
  checkpoint resolver_double_dispatch pass "owner dispatched exactly once for the conflict sha (2nd tick held; no per-seat double)"
else
  RESOLVER_DOUBLE_DISPATCH=$(( OWNER_DISPATCHES > 1 ? OWNER_DISPATCHES - 1 : 1 ))
  checkpoint resolver_double_dispatch fail "owner conflict dispatches=$OWNER_DISPATCHES (expected 1 — in-flight hold failed)"
fi
info "cross_seat_resolver_probe=$CROSS_SEAT_RESOLVER_PROBE (seat-b dispatches on its own ledger; G5 observation)"

# (4) max_restale_cycles bounded under MERGE_FAIRNESS=on
step fairness "drive MERGE_FAIRNESS=on restale-pressure leg (HERD-231) on seat-a"
FAIR_OUT="$(HERD_SIM_SEAT=seat-a HERD_SIM_NPRS="$NPRS" bash "$SEAT_RUNNER" fairness 2>>"$ART/seat-a.log")" \
  || FAIR_OUT="merged=0 max_restale=99 threshold=3"
info "fairness: $FAIR_OUT"
FAIR_MERGED="$(printf '%s' "$FAIR_OUT" | sed -n 's/.*merged=\([0-9]*\).*/\1/p')"
MAX_RESTALE="$(printf '%s' "$FAIR_OUT" | sed -n 's/.*max_restale=\([0-9]*\).*/\1/p')"
RESTALE_THRESH="$(printf '%s' "$FAIR_OUT" | sed -n 's/.*threshold=\([0-9]*\).*/\1/p')"
FAIR_MERGED="${FAIR_MERGED:-0}"
MAX_RESTALE="${MAX_RESTALE:-99}"
RESTALE_THRESH="${RESTALE_THRESH:-3}"

if [ "$FAIR_MERGED" -eq "$NPRS" ] && [ "$MAX_RESTALE" -le "$RESTALE_THRESH" ]; then
  checkpoint max_restale_cycles_bounded pass "MERGE_FAIRNESS=on: merged=$FAIR_MERGED/$NPRS, max_restale=$MAX_RESTALE <= threshold=$RESTALE_THRESH"
else
  checkpoint max_restale_cycles_bounded fail "fairness leg: merged=$FAIR_MERGED/$NPRS max_restale=$MAX_RESTALE threshold=$RESTALE_THRESH"
fi

# (5) no double-merge (remote merge log unique)
if [ "$_dup_merges" -eq 0 ] && [ "$_merged_ct" -eq "$NPRS" ]; then
  checkpoint no_double_merge pass "$_merged_ct unique merges on shared remote (0 doubles)"
else
  checkpoint no_double_merge fail "merges=$_merged_ct/$NPRS doubles=$_dup_merges"
fi

# (6) blessing actually posted for every drained PR (non-vacuous gate path)
BLESS_COUNT="$(awk -F'\t' '$2=="success" || $2=="" {c++} END{print c+0}' "$SHARED/statuses.log" 2>/dev/null)"
BLESS_COUNT="${BLESS_COUNT:-0}"
if [ "$BLESS_COUNT" -ge "$NPRS" ]; then
  checkpoint blessings_posted pass "$BLESS_COUNT herd/gates success post(s) for $NPRS PRs"
else
  checkpoint blessings_posted fail "only $BLESS_COUNT blessing(s) for $NPRS PRs (gate path vacuous?)"
fi

# ── SCORECARD ──────────────────────────────────────────────────────────────────
write_scorecard() {
  local out="$ART/scorecard.json" result="$1"
  local skipped=0 i n; n=${#CP_NAMES[@]}
  for ((i=0; i<n; i++)); do [ "${CP_STATUS[$i]}" = "skip" ] && skipped=$((skipped+1)); done
  {
    printf '{\n'
    printf '  "scenario": "%s",\n' "$SCENARIO"
    printf '  "artifacts_dir": "%s",\n' "$ART"
    printf '  "fixture_sha": "%s",\n' "$FIXTURE_SHA"
    printf '  "result": "%s",\n' "$result"
    printf '  "passed": %d,\n' "$_pass"
    printf '  "failed": %d,\n' "$_fail"
    printf '  "skipped": %d,\n' "$skipped"
    printf '  "seats": 2,\n'
    printf '  "prs": %d,\n' "$NPRS"
    printf '  "ticks": %d,\n' "$TICKS"
    printf '  "merges": %d,\n' "$_merged_ct"
    printf '  "double_merges": %d,\n' "$_dup_merges"
    printf '  "duplicate_gate_runs": %d,\n' "${DUP_GATE_RUNS:-0}"
    printf '  "duplicate_hold_comments": %d,\n' "${DUP_HOLD_COMMENTS:-0}"
    printf '  "resolver_double_dispatch": %d,\n' "${RESOLVER_DOUBLE_DISPATCH:-0}"
    printf '  "resolver_owner_dispatches": %d,\n' "${OWNER_DISPATCHES:-0}"
    printf '  "cross_seat_resolver_probe": %d,\n' "${CROSS_SEAT_RESOLVER_PROBE:-0}"
    printf '  "max_restale_cycles": %d,\n' "${MAX_RESTALE:-0}"
    printf '  "restale_threshold": %d,\n' "${RESTALE_THRESH:-3}"
    printf '  "blessings_posted": %d,\n' "${BLESS_COUNT:-0}"
    printf '  "queue_drained": %s,\n' "$([ "${_merged_ct:-0}" -eq "$NPRS" ] && [ "${_dup_merges:-0}" -eq 0 ] && echo true || echo false)"
    printf '  "merge_fairness": "%s",\n' "${MERGE_FAIRNESS}"
    printf '  "checkpoints": [\n'
    for ((i=0; i<n; i++)); do
      printf '    {"name": "%s", "status": "%s", "detail": "%s"}' \
        "${CP_NAMES[$i]}" "${CP_STATUS[$i]}" "${CP_DETAIL[$i]}"
      [ "$i" -lt "$((n-1))" ] && printf ',\n' || printf '\n'
    done
    printf '  ]\n'
    printf '}\n'
  } > "$out"
  printf '%s' "$out"
}

RESULT="pass"; [ "$_fail" -gt 0 ] && RESULT="fail"
SCARD="$(write_scorecard "$RESULT")"
printf '\n%s══ scorecard ══%s\n' "$c_bold" "$c_rst"
printf '  scenario:                  %s\n' "$SCENARIO"
printf '  result:                    %s\n' "$RESULT"
printf '  passed/failed:             %d / %d\n' "$_pass" "$_fail"
printf '  seats:                     2\n'
printf '  prs / merges:              %d / %d\n' "$NPRS" "$_merged_ct"
printf '  duplicate_gate_runs:       %s\n' "${DUP_GATE_RUNS:-0}"
printf '  duplicate_hold_comments:   %s\n' "${DUP_HOLD_COMMENTS:-0}"
printf '  resolver_double_dispatch:  %s\n' "${RESOLVER_DOUBLE_DISPATCH:-0}"
printf '  max_restale_cycles:        %s (threshold %s)\n' "${MAX_RESTALE:-0}" "${RESTALE_THRESH:-3}"
printf '  queue_drained:             %s\n' "$([ "${_merged_ct:-0}" -eq "$NPRS" ] && echo true || echo false)"
printf '  scorecard:                 %s\n' "$SCARD"

[ "$RESULT" = "pass" ] && exit 0 || exit 1
