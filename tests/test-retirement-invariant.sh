#!/usr/bin/env bash
# test-retirement-invariant.sh — hermetic tests for RETIREMENT AS A RECONCILED INVARIANT (HERD-164).
#
# Retirement is not an event handler; it is a property the watcher re-establishes every tick: a slug
# whose PR is MERGED or CLOSED (or whose worktree is gone) owns no worktree, tab, agent, branch, or
# ledger row. These tests pin the two halves that make that safe and legible:
#
#   CLASSIFIER (the safety contract — a pure function of the world)
#     (1)  open PR                                   → active   (never touched)
#     (2)  gh silent / unreachable                   → active   (no anchor ⇒ no action, ever)
#     (3)  reused slug: MERGED PR, different sha     → active   (the anchor is the COMMIT, not the name)
#     (4)  MERGED + clean                            → retiring
#     (5)  MERGED + regenerable dirt (.DS_Store …)   → retiring (droppings any checkout regenerates)
#     (6)  MERGED + real dirt (tracked file changed) → held     + the evidence names the file
#     (7)  CLOSED + zero unique commits + clean      → retiring (abandoned; nothing to lose)
#     (8)  CLOSED + commits that exist only here     → held     + the evidence counts them
#     (9)  CLOSED + unresolvable base ref            → held     (unprovable ⇒ never deleted)
#     (10) worktree already gone                     → retiring (whatever is left is pure debris)
#
#   RECONCILER (convergence, escalation, vocabulary)
#     (11) a retiring slug converges: worktree, branch, and per-slug ledgers all gone; state cleared
#     (12) a HELD slug is never touched — worktree, dirt, and branch all survive, and it says so once
#     (13) the escalation counter turns a stuck teardown red only after _RETIRE_STUCK_TICKS ticks
#     (14) restart-proof: the escalation state is derivable debris, not a prerequisite — delete it and
#          a fresh tick still converges
#     (15) VOCABULARY: 'retiring…' while converging; 'needs-you · retirement stuck: <blocker>' when it
#          will not converge; 'needs-you · <evidence>' when held. Never 'idle', never 'awaiting task'.
#     (16) the sha/pr-suffixed ledger globs cannot eat a SIBLING slug's files (foo vs foo-bar)
#
# Uses a REAL git repo + real worktrees (the dirt / unique-commit proofs are git's, and stubbing them
# would test the stub). `gh` is stubbed on PATH; herdr is absent, so no tab/pane is ever touched.
# NETWORK-FREE. Run:  bash tests/test-retirement-invariant.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../scripts/herd/agent-watch.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

[ -f "$WATCH" ] || fail "agent-watch.sh not found at $WATCH"
command -v python3 >/dev/null 2>&1 || fail "python3 required to run this test"
command -v git >/dev/null 2>&1 || fail "git required to run this test"

# ── stub gh on PATH: `gh pr view <branch> …` → the stored "STATE\toid\tnumber" line, or nothing ──
BIN="$T/bin"; mkdir -p "$BIN"
export GH_DIR="$T/gh"; mkdir -p "$GH_DIR"
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "view" ]; then
  [ -f "$GH_DIR/${3:-}" ] && cat "$GH_DIR/${3:-}"
fi
exit 0
STUB
chmod +x "$BIN/gh"
# herdr must NOT exist for these tests (no tabs, no panes). Shadow any real one with a failing name
# lookup by putting our BIN first and never creating a `herdr` there — `command -v herdr` still finds a
# system herdr, so neutralize it explicitly.
export PATH="$BIN:$PATH"
herdr() { return 127; }   # any accidental call is a hard, visible failure, never a live tab close

# ── a REAL repo: main checkout + a $TREES to hang worktrees off ───────────────────────────────────
REPO="$T/main"; mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email t@t.t; git -C "$REPO" config user.name t
echo base > "$REPO/file.txt"; git -C "$REPO" add -A; git -C "$REPO" commit -qm base
WTREES="$T/trees"; mkdir -p "$WTREES"

# ── source the SHIPPED watcher in lib mode (functions only, no loop / no config / no network) ─────
export AGENT_WATCH_LIB=1
export HERD_CONFIG_FILE="$T/no-such-config"
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"
# Repoint the engine's roots at the fixture AFTER sourcing (the module-level values came from config).
MAIN="$REPO"; TREES="$WTREES"; SELF_WT="$T/self"; STATE="$TREES/.agent-watch-merged"
DEFAULT_BRANCH="main"; DRYRUN=""
# Most checks below assert that a landed branch is reaped, which is only the operator's wish when
# DELETE_BRANCH_ON_MERGE says so. Check (17) covers the default (false) policy explicitly.
DELETE_BRANCH_ON_MERGE="true"
command -v retire_classify >/dev/null 2>&1 || fail "retirement.sh helpers not in scope after sourcing"
ok

# mkwt <slug> [file-content] — a real feature worktree on branch feat/<slug> with one unique commit.
# Echoes its HEAD sha.
mkwt() {
  local slug="$1" body="${2:-work}"
  git -C "$REPO" worktree add -q -b "feat/$slug" "$WTREES/$slug" main 2>/dev/null
  echo "$body" > "$WTREES/$slug/file.txt"
  git -C "$WTREES/$slug" add -A
  git -C "$WTREES/$slug" -c user.email=t@t.t -c user.name=t commit -qm "$slug"
  git -C "$WTREES/$slug" rev-parse HEAD
}
# gh_says <branch> <STATE> <oid> <num>
gh_says() { mkdir -p "$GH_DIR/$(dirname "$1")"; printf '%s\t%s\t%s\n' "$2" "$3" "$4" > "$GH_DIR/$1"; }
# state_of <slug> <dir> <branch> <open> — the classifier's first field.
state_of() { retire_classify "$1" "$2" "$3" "$4" | cut -f1; }
detail_of() { retire_classify "$1" "$2" "$3" "$4" | cut -f4; }
# Every classification below must start from a cold cache, or a memo from a previous case leaks in.
cold() { rm -f "$TREES"/.retire-anchor-* "$TREES"/.retire-probe-* 2>/dev/null; }

# ── (1) an open PR is never a retirement candidate ────────────────────────────────────────────────
sha_a="$(mkwt open-pr)"
gh_says "feat/open-pr" MERGED "$sha_a" 11   # even a MERGED gh answer loses to the open-PR fact
cold; [ "$(state_of open-pr "$WTREES/open-pr" feat/open-pr 1)" = active ] \
  || fail "(1) a slug with an OPEN PR must classify active"
ok

# ── (2) gh silent / unreachable → no anchor → active ─────────────────────────────────────────────
sha_b="$(mkwt no-pr)"
cold; [ "$(state_of no-pr "$WTREES/no-pr" feat/no-pr 0)" = active ] \
  || fail "(2) an unanchorable slug (gh silent) must classify active"
ok

# ── (3) THE SAFETY INVARIANT: a reused slug whose MERGED PR names a DIFFERENT sha is untouchable ──
gh_says "feat/no-pr" MERGED "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" 12
cold; [ "$(state_of no-pr "$WTREES/no-pr" feat/no-pr 0)" = active ] \
  || fail "(3) a MERGED PR whose headRefOid != worktree HEAD must NEVER anchor a teardown"
[ "$sha_b" != "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" ] || fail "(3) fixture sha collision"
ok

# ── (4) MERGED + clean → retiring ────────────────────────────────────────────────────────────────
sha_c="$(mkwt merged-clean)"
gh_says "feat/merged-clean" MERGED "$sha_c" 13
cold; [ "$(state_of merged-clean "$WTREES/merged-clean" feat/merged-clean 0)" = retiring ] \
  || fail "(4) MERGED + clean must classify retiring"
ok

# ── (5) MERGED + regenerable dirt → still retiring (droppings, not work) ─────────────────────────
sha_d="$(mkwt merged-dropping)"
gh_says "feat/merged-dropping" MERGED "$sha_d" 14
: > "$WTREES/merged-dropping/.DS_Store"
mkdir -p "$WTREES/merged-dropping/__pycache__"; : > "$WTREES/merged-dropping/__pycache__/x.pyc"
cold; [ "$(state_of merged-dropping "$WTREES/merged-dropping" feat/merged-dropping 0)" = retiring ] \
  || fail "(5) regenerable untracked droppings must not block a merged reap"
ok

# ── (6) MERGED + REAL dirt → held, with evidence naming the file ─────────────────────────────────
sha_e="$(mkwt merged-dirty)"
gh_says "feat/merged-dirty" MERGED "$sha_e" 15
echo "uncommitted work" >> "$WTREES/merged-dirty/file.txt"      # a TRACKED file, modified
cold
[ "$(state_of merged-dirty "$WTREES/merged-dirty" feat/merged-dirty 0)" = held ] \
  || fail "(6) MERGED + a modified tracked file must be HELD, never reaped"
cold; d="$(detail_of merged-dirty "$WTREES/merged-dirty" feat/merged-dirty 0)"
case "$d" in *file.txt*) : ;; *) fail "(6) hold detail must name the dirty path, got: $d" ;; esac
ok

# ── (7) CLOSED + zero unique commits + clean → retiring ──────────────────────────────────────────
git -C "$REPO" worktree add -q -b feat/closed-empty "$WTREES/closed-empty" main
sha_f="$(git -C "$WTREES/closed-empty" rev-parse HEAD)"     # no commits beyond main
gh_says "feat/closed-empty" CLOSED "$sha_f" 16
cold; [ "$(state_of closed-empty "$WTREES/closed-empty" feat/closed-empty 0)" = retiring ] \
  || fail "(7) CLOSED + 0 unique commits + clean must classify retiring"
ok

# ── (8) CLOSED + commits that exist ONLY here → held (never destroy unpushed work) ───────────────
sha_g="$(mkwt closed-work)"
gh_says "feat/closed-work" CLOSED "$sha_g" 17
cold
[ "$(state_of closed-work "$WTREES/closed-work" feat/closed-work 0)" = held ] \
  || fail "(8) a CLOSED branch carrying unique commits must be HELD"
cold; d="$(detail_of closed-work "$WTREES/closed-work" feat/closed-work 0)"
case "$d" in *"exist only here"*) : ;; *) fail "(8) hold detail must count the unique commits, got: $d" ;; esac
ok

# ── (9) CLOSED + an unresolvable base ref → held (unprovable is never deleted) ───────────────────
cold; d="$(DEFAULT_BRANCH="origin/nope" retire_classify closed-empty "$WTREES/closed-empty" feat/closed-empty 0)"
[ "$(printf '%s' "$d" | cut -f1)" = held ] \
  || fail "(9) an unresolvable base ref must HOLD, not reap: $d"
ok

# ── (10) worktree already gone ───────────────────────────────────────────────────────────────────
# The tab/agent/ledger left behind are pure debris; the BRANCH is the only thing that can carry work,
# so it gets its own proof. This is the path a watcher killed mid-teardown lands on.
cold; [ "$(state_of vanished "$T/definitely-not-here" "" 0)" = retiring ] \
  || fail "(10) a slug with no worktree and no branch must classify retiring"
cold; [ "$(state_of vanished "" "" 1)" = active ] \
  || fail "(10) …unless it still has an open PR"

# 10a: worktree gone, branch's PR MERGED → retiring (GitHub has every commit).
sha_k="$(mkwt gone-merged)"
gh_says "feat/gone-merged" MERGED "$sha_k" 21
git -C "$REPO" worktree remove --force "$WTREES/gone-merged"
cold; [ "$(state_of gone-merged "$WTREES/gone-merged" "" 0)" = retiring ] \
  || fail "(10a) worktree gone + MERGED PR must classify retiring"

# 10b: worktree gone, NO PR anywhere, branch carries commits that exist only here → HELD. Deleting
# that branch is the one irreversible thing on this path, so it must never happen on a guess.
sha_l="$(mkwt gone-orphan)"
git -C "$REPO" worktree remove --force "$WTREES/gone-orphan"
cold; d="$(retire_classify gone-orphan "$WTREES/gone-orphan" "" 0)"
[ "$(printf '%s' "$d" | cut -f1)" = held ] \
  || fail "(10b) an unmerged branch with unique commits must be HELD, not deleted: $d"
case "$(printf '%s' "$d" | cut -f4)" in *"exist only on branch"*) : ;;
  *) fail "(10b) the hold must name the branch and count its commits: $d" ;; esac
git -C "$REPO" show-ref --verify --quiet refs/heads/feat/gone-orphan \
  || fail "(10b) classification must not have side effects"

# 10c: worktree gone, no PR, branch adds nothing to the default branch → retiring (nothing to lose).
git -C "$REPO" branch -q feat/gone-empty main
cold; [ "$(state_of gone-empty "$WTREES/gone-empty" "" 0)" = retiring ] \
  || fail "(10c) a branch with zero unique commits must classify retiring"

# 10d: the ledger fallback — GitHub deleted the head branch at merge, so the branch name resolves no
# PR, but the reap ledger's PR number does, and it says MERGED.
sha_m="$(mkwt gone-ledger)"
git -C "$REPO" worktree remove --force "$WTREES/gone-ledger"
printf '%s 22 gone-ledger\n' "$(date +%s)" > "$STATE"
gh_says "22" MERGED "$sha_m" 22
cold; [ "$(state_of gone-ledger "$WTREES/gone-ledger" "" 0)" = retiring ] \
  || fail "(10d) the ledger's MERGED PR must anchor a branch whose name resolves no PR"
# …but a ledger row whose PR is NOT merged proves nothing: the branch's unique commits still hold.
gh_says "22" OPEN "$sha_m" 22
cold; [ "$(state_of gone-ledger "$WTREES/gone-ledger" "" 0)" = held ] \
  || fail "(10d) a stale ledger row must never anchor a delete on its own"
: > "$STATE"
ok

# ── (16) the ledger globs cannot eat a SIBLING slug's files ──────────────────────────────────────
# `.health-result-foo-*` also matches slug `foo-bar`'s files. The tail guard rejects any tail that is
# not a lone hex sha / PR number, which is what a sibling slug's name always is.
_retire_tail_ok "0123456789abcdef0123456789abcdef01234567" || fail "(16) a full sha must be a valid tail"
_retire_tail_ok "42"        || fail "(16) a PR number must be a valid tail"
_retire_tail_ok "bar"       && fail "(16) a sibling slug segment must NOT be a valid tail"
_retire_tail_ok "bar-abc"   && fail "(16) a multi-segment sibling tail must NOT be valid"
_retire_tail_ok "beef"      && fail "(16) a short hex-looking sibling segment must NOT be valid"
: > "$TREES/.health-result-sib-0123456789abcdef0123456789abcdef01234567"
: > "$TREES/.health-result-sib-bling-0123456789abcdef0123456789abcdef01234567"
files="$(_retire_ledger_files sib)"
case "$files" in *sib-bling*) fail "(16) slug 'sib' must not own slug 'sib-bling' ledger files" ;; esac
printf '%s' "$files" | grep -q 'health-result-sib-0123' || fail "(16) slug 'sib' must own its own ledger file"
rm -f "$TREES/.health-result-sib-"*
ok

# ── (11) a retiring slug CONVERGES: worktree, branch, ledgers all gone; state cleared ────────────
sha_h="$(mkwt conv)"
gh_says "feat/conv" MERGED "$sha_h" 18
: > "$(_slug_ref_file conv)"                       # a tracker-ref ledger row to be reaped
: > "$TREES/.health-cachehit-conv"                 # a health ledger row to be reaped
cold
AGENTS_JSON='{"result":{"agents":[]}}' _retire_step conv "$WTREES/conv" feat/conv 0
[ -d "$WTREES/conv" ] && fail "(11) a converged slug must not keep its worktree"
git -C "$REPO" show-ref --verify --quiet refs/heads/feat/conv && fail "(11) …nor its local branch"
[ -e "$(_slug_ref_file conv)" ] && fail "(11) …nor its tracker-ref marker"
[ -e "$TREES/.health-cachehit-conv" ] && fail "(11) …nor its health ledger row"
[ -e "$(_retire_state_file conv)" ] && fail "(11) …nor any escalation state"
[ "$(_retire_state_of conv)" = active ] && ok || fail "(11) a converged slug must render no row"

# ── (12) a HELD slug is NEVER touched, and says so exactly once ──────────────────────────────────
AGENTS_JSON='{"result":{"agents":[]}}' _retire_step merged-dirty "$WTREES/merged-dirty" feat/merged-dirty 0
[ -d "$WTREES/merged-dirty" ] || fail "(12) a held worktree must survive"
grep -q 'uncommitted work' "$WTREES/merged-dirty/file.txt" || fail "(12) held dirt must survive verbatim"
git -C "$REPO" show-ref --verify --quiet refs/heads/feat/merged-dirty \
  || fail "(12) a held slug's branch must survive"
[ "$(_retire_state_of merged-dirty)" = held ] || fail "(12) a held slug must render a held row"
[ -e "$TREES/.retire-noted-merged-dirty-hold" ] || fail "(12) a hold must be journaled once"
ok

# ── (13) escalation: a teardown that cannot converge goes red only after N ticks ─────────────────
# Simulate a teardown that never finishes by making the agent roster refuse to let the slug go.
sha_i="$(mkwt stuck)"
gh_says "feat/stuck" MERGED "$sha_i" 19
cold
export HERD_RETIRE_STUCK_TICKS=3; _RETIRE_STUCK_TICKS=3
tick_stuck() { AGENTS_JSON='{"result":{"agents":[{"name":"stuck","agent_status":"idle"}]}}' \
                 retirement_tick_one stuck "$WTREES/stuck" feat/stuck; }
retirement_tick_one() { RETIRE_SLUG=(); RETIRE_STATE=(); RETIRE_DETAIL=(); RETIRE_DIR=(); _retire_step "$1" "$2" "$3" 0; }
tick_stuck; [ "$(_retire_state_of stuck)" = retiring ] || fail "(13) tick 1 must be calm 'retiring'"
tick_stuck; [ "$(_retire_state_of stuck)" = retiring ] || fail "(13) tick 2 must still be calm"
tick_stuck; [ "$(_retire_state_of stuck)" = stuck ]    || fail "(13) tick 3 must escalate to red 'stuck'"
[ "$(_retire_detail_of stuck)" = agent ] || fail "(13) the red row must NAME the blocker (agent), got: $(_retire_detail_of stuck)"
[ -d "$WTREES/stuck" ] && fail "(13) the worktree still reaps — only the agent is the blocker"
ok

# ── (14) restart-proof: the escalation file is debris, not a prerequisite ────────────────────────
# Blow away everything the reconciler remembers; a fresh tick against the same world still converges.
rm -f "$TREES"/.retire-* 2>/dev/null
sha_j="$(mkwt restart)"
gh_says "feat/restart" MERGED "$sha_j" 20
cold
AGENTS_JSON='{"result":{"agents":[]}}' _retire_step restart "$WTREES/restart" feat/restart 0
[ -d "$WTREES/restart" ] && fail "(14) a fresh reconciler with zero memory must still converge"
[ -z "$(AGENTS_JSON='{"result":{"agents":[]}}' retire_leftovers restart "$WTREES/restart" feat/restart)" ] \
  || fail "(14) …to ZERO leftovers"
ok

# ── (15) the closed vocabulary ───────────────────────────────────────────────────────────────────
SLUGW=20; C_DIM=""; C_RED=""; C_BOLD=""; C_RESET=""
row_r="$(_row_retirement "conv " conv retiring "tab,agent")"
case "$row_r" in *"retiring…"*) : ;; *) fail "(15) a converging slug must read 'retiring…', got: $row_r" ;; esac
case "$row_r" in *"tab,agent"*) : ;; *) fail "(15) …and name what is left, got: $row_r" ;; esac
printf '%s' "$row_r" | grep -qw idle && fail "(15) retiring row leaked the banned 'idle' word"
case "$row_r" in *"awaiting task"*) fail "(15) a merged builder must never read 'awaiting task'" ;; esac

row_s="$(_row_retirement "stuck " stuck stuck agent)"
case "$row_s" in *"needs-you · retirement stuck: agent"*) : ;;
  *) fail "(15) a stuck teardown must be a needs-you row naming the blocker, got: $row_s" ;; esac
case "$row_s" in *"herd sweep"*) : ;; *) fail "(15) …and carry a remedy, got: $row_s" ;; esac

row_h="$(_row_retirement "dirty " merged-dirty held "uncommitted work: 1 path(s): file.txt")"
case "$row_h" in *"needs-you · uncommitted work"*) : ;;
  *) fail "(15) a held slug must be a needs-you row carrying the evidence, got: $row_h" ;; esac
case "$row_h" in *file.txt*) : ;; *) fail "(15) …naming the file, got: $row_h" ;; esac
ok

# ── (17) DELETE_BRANCH_ON_MERGE=false: the branch is RETAINED ON PURPOSE ─────────────────────────
# It must therefore be neither deleted nor counted as a leftover — a red 'stuck: branch' row over a
# branch the operator asked to keep would be a false alarm that never clears.
sha_n="$(mkwt keepbranch)"
gh_says "feat/keepbranch" MERGED "$sha_n" 23
cold
DELETE_BRANCH_ON_MERGE="false" AGENTS_JSON='{"result":{"agents":[]}}' \
  _retire_step keepbranch "$WTREES/keepbranch" feat/keepbranch 0
[ -d "$WTREES/keepbranch" ] && fail "(17) the worktree must still be reaped"
git -C "$REPO" show-ref --verify --quiet refs/heads/feat/keepbranch \
  || fail "(17) DELETE_BRANCH_ON_MERGE=false must RETAIN the local branch"
left="$(DELETE_BRANCH_ON_MERGE="false" AGENTS_JSON='{"result":{"agents":[]}}' \
        retire_leftovers keepbranch "$WTREES/keepbranch" feat/keepbranch)"
[ -z "$left" ] || fail "(17) a retained branch must not count as a leftover, got: $left"
[ "$(_retire_state_of keepbranch)" = active ] || fail "(17) …so the slug converges and renders no row"
# …and an ORPHANED slug under the same policy retires its debris without judging the branch.
cold; [ "$(DELETE_BRANCH_ON_MERGE=false state_of gone-orphan "$WTREES/gone-orphan" "" 0)" = retiring ] \
  || fail "(17) a retained branch must not turn an orphan slug into a hold"
git -C "$REPO" show-ref --verify --quiet refs/heads/feat/gone-orphan \
  || fail "(17) …and its commits are still there"
ok

echo "ALL PASS ($pass checks)"
