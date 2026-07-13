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
# The classifier's record separator is \x1f (never a tab — see _retire_step). Extract with the SAME
# separator the engine reads with, or these helpers would paper over the very bug they must catch.
RS=$'\x1f'
state_of()  { retire_classify "$1" "$2" "$3" "$4" "${5:-residual}" | cut -d"$RS" -f1; }
detail_of() { retire_classify "$1" "$2" "$3" "$4" "${5:-residual}" | cut -d"$RS" -f4; }
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

# ── (4b) HERD-356: MERGED + clean but a builder is still WORKING → deferred; IDLE still reaps ──────
# The reap legs used to treat ANY resident agent pane as builder-liveness, stranding a merged worktree
# whose builder went idle. The split: only a POSITIVE "working" read defers; idle is done → reap.
WORKING_JSON='{"result":{"agents":[{"name":"merged-clean","agent_status":"working"}]}}'
IDLE_JSON='{"result":{"agents":[{"name":"merged-clean","agent_status":"idle"}]}}'
cold; [ "$(AGENTS_JSON="$WORKING_JSON" retire_classify merged-clean "$WTREES/merged-clean" feat/merged-clean 0 | cut -d"$RS" -f1)" = deferred ] \
  || fail "(4b) MERGED + clean + a WORKING builder must DEFER the reap"
cold; d="$(AGENTS_JSON="$WORKING_JSON" retire_classify merged-clean "$WTREES/merged-clean" feat/merged-clean 0 | cut -d"$RS" -f4)"
case "$d" in *"still working"*) : ;; *) fail "(4b) the deferred detail must say why (still working), got: $d" ;; esac
cold; [ "$(AGENTS_JSON="$IDLE_JSON" retire_classify merged-clean "$WTREES/merged-clean" feat/merged-clean 0 | cut -d"$RS" -f1)" = retiring ] \
  || fail "(4b) MERGED + clean + an IDLE builder must still REAP (idle is done, not working)"
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
[ "$(printf '%s' "$d" | cut -d"$RS" -f1)" = held ] \
  || fail "(9) an unresolvable base ref must HOLD, not reap: $d"
ok

# ── (10) worktree already gone ───────────────────────────────────────────────────────────────────
# The tab/agent/ledger left behind are pure debris; the BRANCH is the only thing that can carry work,
# so it gets its own proof. This is the path a watcher killed mid-teardown lands on.
cold; [ "$(state_of vanished "$T/definitely-not-here" "" 0)" = retiring ] \
  || fail "(10) a slug with no worktree and no branch must classify retiring"
cold; [ "$(state_of vanished "" "" 1)" = active ] \
  || fail "(10) …unless it still has an open PR"

# 10a: worktree gone, branch's PR MERGED at this ref's tip → retiring (the ref IS what merged).
sha_k="$(mkwt gone-merged)"
gh_says "feat/gone-merged" MERGED "$sha_k" 21
git -C "$REPO" worktree remove --force "$WTREES/gone-merged"
cold; [ "$(state_of gone-merged "$WTREES/gone-merged" "" 0)" = retiring ] \
  || fail "(10a) worktree gone + MERGED PR anchored at the branch tip must classify retiring"

# 10b: worktree gone, PR CLOSED unmerged, branch carries commits that exist only here → HELD. Deleting
# that branch is the one irreversible thing on this path, so it must never happen on a guess.
sha_l="$(mkwt gone-orphan)"
gh_says "feat/gone-orphan" CLOSED "$sha_l" 28
cold; d="$(retire_classify gone-orphan "$WTREES/gone-orphan" "" 0 residual)"
git -C "$REPO" worktree remove --force "$WTREES/gone-orphan"
cold; d="$(retire_classify gone-orphan "$WTREES/gone-orphan" "" 0 residual)"
[ "$(printf '%s' "$d" | cut -d"$RS" -f1)" = held ] \
  || fail "(10b) a CLOSED branch with unique commits must be HELD, not deleted: $d"
case "$(printf '%s' "$d" | cut -d"$RS" -f4)" in *"exist only on branch"*) : ;;
  *) fail "(10b) the hold must name the branch and count its commits: $d" ;; esac
git -C "$REPO" show-ref --verify --quiet refs/heads/feat/gone-orphan \
  || fail "(10b) classification must not have side effects"

# 10c: worktree gone, PR CLOSED, branch adds nothing to the default branch → retiring (nothing to lose).
git -C "$REPO" branch -q feat/gone-empty main
gh_says "feat/gone-empty" CLOSED "$(git -C "$REPO" rev-parse main)" 29
cold; [ "$(state_of gone-empty "$WTREES/gone-empty" "" 0)" = retiring ] \
  || fail "(10c) a CLOSED branch with zero unique commits must classify retiring"
# …but with NO verdict at all (gh down / no PR record) it is UNPROVEN, and unproven is never terminal.
git -C "$REPO" branch -q feat/gone-empty2 main
cold; [ "$(state_of gone-empty2 "$WTREES/gone-empty2" "" 0)" = active ] \
  || fail "(10c) an orphan with no gh verdict must classify active, whatever its commits"

# 10d: the ledger fallback — GitHub deleted the head branch at merge, so the branch name resolves no
# PR, but the reap ledger's PR number does, and it says MERGED.
sha_m="$(mkwt gone-ledger)"
git -C "$REPO" worktree remove --force "$WTREES/gone-ledger"
printf '%s 22 gone-ledger\n' "$(date +%s)" > "$STATE"
gh_says "22" MERGED "$sha_m" 22
cold; [ "$(state_of gone-ledger "$WTREES/gone-ledger" "" 0)" = retiring ] \
  || fail "(10d) the ledger's MERGED PR must anchor a branch whose name resolves no PR"
# …but a ledger row whose PR is NOT merged proves nothing. With no terminal verdict from either the
# branch name or the ledger PR, the slug is UNPROVEN → active. Never a delete on a stale ledger row.
gh_says "22" OPEN "$sha_m" 22
cold; [ "$(state_of gone-ledger "$WTREES/gone-ledger" "" 0)" = active ] \
  || fail "(10d) a stale ledger row must never anchor a delete on its own"
git -C "$REPO" show-ref --verify --quiet refs/heads/feat/gone-ledger \
  || fail "(10d) …and the branch must survive"
: > "$STATE"
ok

# ── (16) the ledger globs cannot eat a SIBLING slug's files ──────────────────────────────────────
# `.retire-anchor-foo-*` also matches slug `foo-bar`'s files. The tail guard rejects any tail that is
# not a lone hex sha / PR number, which is what a sibling slug's name always is.
_retire_tail_ok "0123456789abcdef0123456789abcdef01234567" || fail "(16) a full sha must be a valid tail"
_retire_tail_ok "42"        || fail "(16) a PR number must be a valid tail"
_retire_tail_ok "bar"       && fail "(16) a sibling slug segment must NOT be a valid tail"
_retire_tail_ok "bar-abc"   && fail "(16) a multi-segment sibling tail must NOT be valid"
_retire_tail_ok "beef"      && fail "(16) a short hex-looking sibling segment must NOT be valid"
: > "$TREES/.retire-anchor-sib-0123456789abcdef0123456789abcdef01234567"
: > "$TREES/.retire-anchor-sib-bling-0123456789abcdef0123456789abcdef01234567"
files="$(_retire_ledger_files sib)"
case "$files" in *sib-bling*) fail "(16) slug 'sib' must not own slug 'sib-bling' ledger files" ;; esac
printf '%s' "$files" | grep -q 'retire-anchor-sib-0123' || fail "(16) slug 'sib' must own its own ledger file"
rm -f "$TREES/.retire-anchor-sib-"*
ok

# ── (11) a retiring slug CONVERGES: worktree, branch, ledgers all gone; state cleared ────────────
sha_h="$(mkwt conv)"
gh_says "feat/conv" MERGED "$sha_h" 18
: > "$(_slug_ref_file conv)"                       # a tracker-ref ledger row to be reaped
: > "$TREES/.retire-anchor-conv-$sha_h"           # our own memo scratch, to be reaped
cold
AGENTS_JSON='{"result":{"agents":[]}}' _retire_step conv "$WTREES/conv" feat/conv 0 worktree
[ -d "$WTREES/conv" ] && fail "(11) a converged slug must not keep its worktree"
git -C "$REPO" show-ref --verify --quiet refs/heads/feat/conv && fail "(11) …nor its local branch"
[ -e "$(_slug_ref_file conv)" ] && fail "(11) …nor its tracker-ref marker"
[ -e "$TREES/.retire-anchor-conv-$sha_h" ] && fail "(11) …nor its anchor memo"
[ -e "$(_retire_state_file conv)" ] && fail "(11) …nor any escalation state"
[ "$(_retire_state_of conv)" = active ] && ok || fail "(11) a converged slug must render no row"

# ── (12) a HELD slug is NEVER touched, and says so exactly once ──────────────────────────────────
AGENTS_JSON='{"result":{"agents":[]}}' _retire_step merged-dirty "$WTREES/merged-dirty" feat/merged-dirty 0 worktree
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
retirement_tick_one() { RETIRE_SLUG=(); RETIRE_STATE=(); RETIRE_DETAIL=(); RETIRE_DIR=(); _retire_step "$1" "$2" "$3" 0 worktree; }
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
AGENTS_JSON='{"result":{"agents":[]}}' _retire_step restart "$WTREES/restart" feat/restart 0 worktree
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
  _retire_step keepbranch "$WTREES/keepbranch" feat/keepbranch 0 worktree
[ -d "$WTREES/keepbranch" ] && fail "(17) the worktree must still be reaped"
git -C "$REPO" show-ref --verify --quiet refs/heads/feat/keepbranch \
  || fail "(17) DELETE_BRANCH_ON_MERGE=false must RETAIN the local branch"
left="$(DELETE_BRANCH_ON_MERGE="false" AGENTS_JSON='{"result":{"agents":[]}}' \
        retire_leftovers keepbranch "$WTREES/keepbranch" feat/keepbranch)"
[ -z "$left" ] || fail "(17) a retained branch must not count as a leftover, got: $left"
[ "$(_retire_state_of keepbranch)" = active ] || fail "(17) …so the slug converges and renders no row"
# …and an ORPHANED slug under the same policy retires its DEBRIS without judging or touching the branch —
# but ONLY once terminality is proven. The policy is not evidence: it must never stand in for the proof.
#
#   gone-orphan   has a branch with unique commits and NO PR verdict at all (gh silent) → unproven →
#                 active. A `gh` blip must never license a teardown, whatever the branch policy says.
sha_u="$(mkwt gone-nogh)"          # no gh_says → no PR verdict at all
git -C "$REPO" worktree remove --force "$WTREES/gone-nogh"
cold; [ "$(DELETE_BRANCH_ON_MERGE=false state_of gone-nogh "$WTREES/gone-nogh" "" 0)" = active ] \
  || fail "(17) an UNPROVEN orphan must be active under any branch policy — the policy is not the proof"
cold; [ "$(DELETE_BRANCH_ON_MERGE=true state_of gone-nogh "$WTREES/gone-nogh" "" 0)" = active ] \
  || fail "(17) …and under the reaping policy too"
git -C "$REPO" show-ref --verify --quiet refs/heads/feat/gone-nogh \
  || fail "(17) …and its commits are still there"

#   gone-merged   is provably MERGED at its tip → the debris retires, the branch is retained, and the
#                 record carries an EMPTY <branch> so _retire_delete_branch cannot fire on it.
cold; d="$(DELETE_BRANCH_ON_MERGE=false retire_classify gone-merged "$WTREES/gone-merged" "" 0 registry)"
[ "$(printf '%s' "$d" | cut -d"$RS" -f1)" = retiring ] \
  || fail "(17) a proven-terminal orphan must still retire its debris under a retain policy: $d"
[ -z "$(printf '%s' "$d" | cut -d"$RS" -f5)" ] \
  || fail "(17) a retained branch must be emitted as an EMPTY <branch> field, got: $d"
case "$(printf '%s' "$d" | cut -d"$RS" -f4)" in *"retained by policy"*) : ;;
  *) fail "(17) …and say so: $d" ;; esac
cold; RETIRE_SLUG=(); RETIRE_STATE=(); RETIRE_DETAIL=(); RETIRE_DIR=()
DELETE_BRANCH_ON_MERGE=false AGENTS_JSON='{"result":{"agents":[]}}' \
  _retire_step gone-merged "$WTREES/gone-merged" "" 0 registry
git -C "$REPO" show-ref --verify --quiet refs/heads/feat/gone-merged \
  || fail "(17) a real teardown pass must not delete a retained branch"
ok

# ── (18) REGRESSION: the orphan path through _retire_step (the \x1f field-parse bug) ─────────────
# Nothing used to drive an orphan (worktree-gone) record through _retire_step — the classifier's empty
# <pr>/<sha> fields collapsed under `IFS=$'\t' read`, so `pr` got prose, `detail` (the evidence) went
# empty, and `branch` went empty so it was never reaped though the slug reported "converged".
sha_o="$(mkwt orphan-held)"
gh_says "feat/orphan-held" CLOSED "$sha_o" 30   # terminal, unmerged: the branch is the only copy
git -C "$REPO" worktree remove --force "$WTREES/orphan-held"
cold
RETIRE_SLUG=(); RETIRE_STATE=(); RETIRE_DETAIL=(); RETIRE_DIR=()
AGENTS_JSON='{"result":{"agents":[]}}' _retire_step orphan-held "$WTREES/orphan-held" "" 0 residual
[ "$(_retire_state_of orphan-held)" = held ] || fail "(18) an orphan branch with unique commits must be HELD"
d="$(_retire_detail_of orphan-held)"
[ -n "$d" ] || fail "(18) the held row must carry its EVIDENCE, not an empty needs-you"
case "$d" in *"exist only on branch"*) : ;; *) fail "(18) evidence must name the branch + commit count, got: $d" ;; esac
git -C "$REPO" show-ref --verify --quiet refs/heads/feat/orphan-held \
  || fail "(18) a held orphan's branch must survive"
# …and the hold stays DISCOVERABLE: `.retire-<slug>` is the last key leg C has once the ref is gone.
printf '%s\n' "$(_retire_residual_slugs)" | grep -qxF orphan-held \
  || fail "(18) a held orphan must remain discoverable by leg C, or its red row goes silent forever"

# A retiring orphan whose branch adds nothing must REAP that branch. This record carries an empty <pr>
# AND an empty <sha> — three consecutive separators — so it is the exact shape that collapsed, leaving
# <branch> empty: the branch survived while the slug reported "converged".
git -C "$REPO" branch -q feat/orphan-empty main
gh_says "feat/orphan-empty" CLOSED "$(git -C "$REPO" rev-parse main)" 31
cold
RETIRE_SLUG=(); RETIRE_STATE=(); RETIRE_DETAIL=(); RETIRE_DIR=()
AGENTS_JSON='{"result":{"agents":[]}}' _retire_step orphan-empty "$WTREES/orphan-empty" "" 0 registry
git -C "$REPO" show-ref --verify --quiet refs/heads/feat/orphan-empty \
  && fail "(18) a retiring orphan must reap a branch that carries nothing (branch lost to field-parse)"
[ "$(_retire_state_of orphan-empty)" = active ] || fail "(18) …and then converge, rendering no row"

# And under the DEFAULT policy the record is `retiring | "" | "" | worktree gone | ""`. The collapse put
# the prose "worktree gone" into <pr>, which then reached the JOURNAL and the PR-keyed purge helpers as
# if it were a PR number. Assert on the journal, because that is where the garbage actually landed —
# `cut` never collapses, so only a real _retire_step parse can prove this.
cold
JOURNAL_FILE="$T/journal.jsonl"; : > "$JOURNAL_FILE"
RETIRE_SLUG=(); RETIRE_STATE=(); RETIRE_DETAIL=(); RETIRE_DIR=()
DELETE_BRANCH_ON_MERGE=false AGENTS_JSON='{"result":{"agents":[]}}' \
  _retire_step journal-orphan "$T/nope" "" 0 registry   # no local branch ⇒ no ref, no commits, no proof owed
grep -q '"event":"retire_converged"' "$JOURNAL_FILE" \
  || fail "(18) a first-tick teardown must journal retire_converged (post-mortem observability)"
grep -q 'worktree gone' "$JOURNAL_FILE" && grep -q '"pr":"worktree gone"' "$JOURNAL_FILE" \
  && fail "(18) prose leaked into the journal's pr field"
grep -q '"pr":"[^"]*[a-z ][^"]*"' "$JOURNAL_FILE" \
  && fail "(18) the journal's pr field must be a number or empty, never prose"
ok

# ── (19) REGRESSION: a live OPEN PR's PR-keyed gate ledgers survive a tick, untouched ────────────
# Almost nothing in $TREES is slug-keyed: the health/review/resolve/refix ledgers are keyed by PR
# NUMBER. Globbing them by slug deleted a live PR's health mutex, its cached verdict, and its
# review-ESCALATION arm (a safety rail: the PR silently drops back to the cheap review tier).
pr_files=(
  "$TREES/.health-cachehit-312"                                             # _health_cachehit_file <pr>
  "$TREES/.review-escalate-312"                                             # _review_escalate_file <pr>
  "$TREES/.health-result-312-abc1234def5678"                                # record_health_result <pr> <sha>
  "$TREES/.health-inflight-312-abc1234def5678"                              # _health_acquire (the mutex)
  "$TREES/.health-inflight-main-abc1234def5678"                             # the main-health run
  "$TREES/.resolve-result-312-abc1234def5678"                               # _resolve_result_file <pr> <sha>
  "$TREES/.agent-watch-refix-dead-312-abc1234def5678"                       # _refix_dead_marker <pr> <sha>
  "$TREES/.agent-watch-refix-stuck-health-312-abc1234def5678"               # _refix_stuck_file <pr> <sha> <kind>
)
for f in "${pr_files[@]}"; do : > "$f"; done
# None of them may be claimed as slug '312' state…
[ -z "$(_retire_ledger_files 312)" ] || fail "(19) PR-keyed gate ledgers must never be claimed as slug state"
# …nor may they manufacture a phantom slug for leg C to tear down.
res="$(_retire_residual_slugs)"
for phantom in 312 312-abc1234def5678 main-abc1234def5678; do
  printf '%s\n' "$res" | grep -qxF "$phantom" \
    && fail "(19) leg C manufactured the phantom slug '$phantom' from a live PR's ledger"
done
# …and a full tick leaves every one of them on disk.
PRS_JSON='[]' AGENTS_JSON='{"result":{"agents":[]}}' retirement_tick
for f in "${pr_files[@]}"; do
  [ -e "$f" ] || fail "(19) retirement_tick DELETED a live open PR's gate ledger: ${f##*/}"
done
for f in "${pr_files[@]}"; do rm -f "$f"; done
ok

# ── (20) an orphan with NO provenance is never torn down ─────────────────────────────────────────
# The orphan path has no sha anchor to lean on, so provenance is the gate: a slug nobody can show the
# engine created is `active`. A future discovery-key bug then degrades to a no-op, not a silent reap.
cold; [ "$(retire_classify whoknows "$T/nope" "" 0 "" | cut -d"$RS" -f1)" = active ] \
  || fail "(20) an orphan with no provenance must classify active, never retiring"
cold; [ "$(retire_classify whoknows "$T/nope" "" 0 registry | cut -d"$RS" -f1)" = retiring ] \
  || fail "(20) …but a registry-provenanced orphan retires normally"
ok

# ── (21) THE ORPHAN-PATH SHA ANCHOR: a merged PR does NOT license deleting a moved branch ────────
# The worktree path anchors on HEAD == headRefOid (check 3). The worktree-GONE path must anchor on the
# local branch TIP == headRefOid. Without it, a builder that kept committing after its PR merged has
# those commits destroyed by `branch -D` — recoverable only via `git fsck` inside the gc window.
# _retire_branch_unique is NOT a substitute: a SQUASH merge makes every commit read as unique.
sha_q="$(mkwt anchor-moved)"                       # this commit is what the PR merged
gh_says "feat/anchor-moved" MERGED "$sha_q" 25
echo extra1 > "$WTREES/anchor-moved/e1"
git -C "$WTREES/anchor-moved" add -A
git -C "$WTREES/anchor-moved" -c user.email=t@t.t -c user.name=t commit -qm "kept working after the merge"
tip_q="$(git -C "$WTREES/anchor-moved" rev-parse HEAD)"
[ "$tip_q" != "$sha_q" ] || fail "(21) fixture: branch tip must differ from the merged head"
git -C "$REPO" worktree remove --force "$WTREES/anchor-moved"

cold; d="$(retire_classify anchor-moved "$WTREES/anchor-moved" "" 0 residual)"
[ "$(printf '%s' "$d" | cut -d"$RS" -f1)" = held ] \
  || fail "(21) a MERGED PR whose headRefOid != the local branch TIP must be HELD, got: $d"
case "$(printf '%s' "$d" | cut -d"$RS" -f4)" in *"moved past the merged head"*) : ;;
  *) fail "(21) the hold must name the drift and count the commits: $d" ;; esac

# …and a real teardown pass must NOT delete it.
cold; RETIRE_SLUG=(); RETIRE_STATE=(); RETIRE_DETAIL=(); RETIRE_DIR=()
AGENTS_JSON='{"result":{"agents":[]}}' _retire_step anchor-moved "$WTREES/anchor-moved" "" 0 residual
git -C "$REPO" show-ref --verify --quiet refs/heads/feat/anchor-moved \
  || fail "(21) a branch carrying commits past the merged head was DELETED — work lost"
[ "$(_retire_state_of anchor-moved)" = held ] || fail "(21) …and the row must be a red hold"

# Leg D carries the identical anchor: it must refuse this slug, and accept it once the ref is reset to
# exactly the merged head.
printf '%s 25 anchor-moved\n' "$(date +%s)" > "$STATE"
cold; _retire_merged_branch_slug anchor-moved \
  && fail "(21) leg D must refuse a branch whose tip is past the merged head"
git -C "$REPO" branch -f feat/anchor-moved "$sha_q"
cold; _retire_merged_branch_slug anchor-moved \
  || fail "(21) leg D must accept a branch whose tip IS the merged head"
# Anchored → the teardown proceeds and the branch goes.
cold; RETIRE_SLUG=(); RETIRE_STATE=(); RETIRE_DETAIL=(); RETIRE_DIR=()
AGENTS_JSON='{"result":{"agents":[]}}' _retire_step anchor-moved "$WTREES/anchor-moved" "" 0 ledger
git -C "$REPO" show-ref --verify --quiet refs/heads/feat/anchor-moved \
  && fail "(21) an anchored merged branch must still be reaped"
: > "$STATE"

# An OPEN PR on an orphaned ref is not terminal at all — retire_classify must say so on its own, without
# leaning on retirement_tick's (view-filtered) open-PR fast path.
sha_r="$(mkwt anchor-open)"
gh_says "feat/anchor-open" OPEN "$sha_r" 26
git -C "$REPO" worktree remove --force "$WTREES/anchor-open"
cold; [ "$(state_of anchor-open "$WTREES/anchor-open" "" 0)" = active ] \
  || fail "(21) an orphaned ref with an OPEN PR must classify active"
git -C "$REPO" show-ref --verify --quiet refs/heads/feat/anchor-open \
  || fail "(21) …and its branch must survive"

# THE SAME, under the SHIPPED DEFAULT policy. This is the case the branch-retention short-circuit used
# to swallow: with DELETE_BRANCH_ON_MERGE=false every provenanced orphan returned `retiring` before the
# OPEN check could run, so a live PR's tabs, registry row, and .herd-ref were silently torn down. The
# open_slugs fast path cannot save it — it reads a view-filtered $PRS_JSON and fails open on a gh blip.
cold; [ "$(DELETE_BRANCH_ON_MERGE=false state_of anchor-open "$WTREES/anchor-open" "" 0)" = active ] \
  || fail "(21) an OPEN PR must classify active under the DEFAULT branch policy too"
cold; RETIRE_SLUG=(); RETIRE_STATE=(); RETIRE_DETAIL=(); RETIRE_DIR=()
: > "$TREES/.herd-ref-anchor-open"
DELETE_BRANCH_ON_MERGE=false AGENTS_JSON='{"result":{"agents":[]}}' \
  _retire_step anchor-open "$WTREES/anchor-open" "" 0 registry
[ -e "$TREES/.herd-ref-anchor-open" ] \
  || fail "(21) an OPEN PR's slug markers must survive a tick under the default policy"
[ "$(_retire_state_of anchor-open)" = active ] || fail "(21) …and it must render no row"
rm -f "$TREES/.herd-ref-anchor-open"

# An unreachable gh is likewise unproven → active, under either policy.
sha_v="$(mkwt anchor-nogh)"; git -C "$REPO" worktree remove --force "$WTREES/anchor-nogh"
cold; [ "$(DELETE_BRANCH_ON_MERGE=false state_of anchor-nogh "$WTREES/anchor-nogh" "" 0)" = active ] \
  || fail "(21) an orphan with no gh verdict must be active (unproven is never terminal)"
ok

# ── (22) the noted-marker clear must not cross slug boundaries ───────────────────────────────────
# _retire_state_clear runs on EVERY active classification (every tick for a healthy slug). A
# `.retire-noted-foo-*` glob would delete sibling `foo-bar`'s hold marker each tick, so `foo-bar` would
# re-journal retire_hold forever — defeating the once-per-(slug,kind) dedupe the marker exists for.
: > "$TREES/.retire-noted-sib-hold"
: > "$TREES/.retire-noted-sib-bling-hold"
_retire_state_clear sib
[ -e "$TREES/.retire-noted-sib-hold" ] && fail "(22) a slug must clear its OWN notice marker"
[ -e "$TREES/.retire-noted-sib-bling-hold" ] \
  || fail "(22) clearing 'sib' must not delete sibling 'sib-bling' notice markers"
rm -f "$TREES/.retire-noted-sib-bling-hold"
ok

# ── (23) held → retiring resets the escalation grace (no false-red first tick) ───────────────────
# A held slug bumps the counter every tick (that is what keeps it discoverable). Curing the hold by
# DISCARDING dirt leaves HEAD at the merged sha, so the slug flips to retiring — and must NOT inherit a
# counter already past _RETIRE_STUCK_TICKS, or the first converging tick renders a red 'retirement
# stuck' row for a teardown that is proceeding normally.
sha_s="$(mkwt cure-hold)"
gh_says "feat/cure-hold" MERGED "$sha_s" 27
echo "uncommitted" >> "$WTREES/cure-hold/file.txt"          # real dirt → held
export HERD_RETIRE_STUCK_TICKS=3; _RETIRE_STUCK_TICKS=3
for _ in 1 2 3 4; do
  cold; RETIRE_SLUG=(); RETIRE_STATE=(); RETIRE_DETAIL=(); RETIRE_DIR=()
  AGENTS_JSON='{"result":{"agents":[{"name":"cure-hold","agent_status":"idle"}]}}' \
    _retire_step cure-hold "$WTREES/cure-hold" feat/cure-hold 0 worktree
done
[ "$(_retire_state_of cure-hold)" = held ] || fail "(23) fixture: the slug should be held"
[ "$(_retire_attempts cure-hold)" -ge 3 ] || fail "(23) fixture: the held counter should have climbed"

git -C "$WTREES/cure-hold" checkout -- file.txt                # the human discards the dirt
cold; RETIRE_SLUG=(); RETIRE_STATE=(); RETIRE_DETAIL=(); RETIRE_DIR=()
AGENTS_JSON='{"result":{"agents":[{"name":"cure-hold","agent_status":"idle"}]}}' \
  _retire_step cure-hold "$WTREES/cure-hold" feat/cure-hold 0 worktree
[ "$(_retire_state_of cure-hold)" = retiring ] \
  || fail "(23) the first tick after a cured hold must be calm 'retiring', got: $(_retire_state_of cure-hold)"
ok

echo "ALL PASS ($pass checks)"
