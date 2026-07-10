#!/usr/bin/env bash
# retirement.sh — RETIREMENT AS A RECONCILED INVARIANT (HERD-164).
#
# THE BUG THIS FIXES. Teardown used to be EVENT-driven: do_merge reaped the worktree + closed the tabs
# as the last steps of the merge sequence. A watcher killed anywhere inside that sequence landed the
# merge and never reaped — and because the merge is already ledgered, no later tick retried. HERD-91's
# _startup_reap_sweep patched the crash window with a ONE-SHOT sweep at watcher start, but that is
# still an event (a restart). Anything that strands a slug WITHOUT a restart — a herdr hiccup that
# refuses a tab close, a PR closed unmerged by a human, a tab whose worktree was removed by hand —
# lingers forever, and the console renders the corpse as "awaiting task", the vocabulary for a
# genuinely unassigned spare. The operator's question ("why are merged builders still sitting there?")
# has no answer in the console, because the console is describing the wrong thing.
#
# THE INVARIANT. A slug whose PR is MERGED or CLOSED (or whose worktree is gone) has NO right to hold
# an agent, a tab, a worktree, a branch, or a ledger row. That is a property of the world, not of an
# event, so it is RECONCILED on EVERY tick: observe the world, compute what should not exist, drive
# the idempotent teardown one step further, repeat until converged. Restart-proof BY CONSTRUCTION —
# nothing is remembered that has to survive a crash. Kill the watcher at any point in the teardown and
# the next tick of the next watcher recomputes the same leftovers and finishes the job. The only state
# on disk ($TREES/.retire-<slug>) is an ESCALATION counter: how many ticks a teardown has failed to
# converge. Lose it and the invariant still holds; you just get one more quiet tick before the row
# turns red.
#
# THE SAFETY CONTRACT is _startup_reap_sweep's, unchanged, and it is the reason no lever guards this:
#   • The anchor is the COMMIT, never the slug. A worktree is torn down only when its current HEAD sha
#     equals the headRefOid of a PR that GitHub reports MERGED or CLOSED. A reused slug with fresh
#     commits, an in-flight builder with no PR yet, an unreachable `gh` — none of them anchor, so none
#     of them are touched.
#   • REGENERABLE DIRT (.DS_Store, __pycache__, *.log …) is tolerated; a modified/staged/deleted TRACKED
#     file, or ANY commit that exists nowhere but here, is REAL WORK. Real work is never deleted and
#     never silently skipped: it becomes a LOUD needs-you row carrying the evidence (which files, how
#     many commits). The only cure is a human. This is sweep.sh's judgment/safe split, reused verbatim.
#
# THE VOCABULARY (HERD-172's closed set). A merged-but-present slug is the HERD's move while teardown
# converges — 'retiring… · <what is left> · <age>', calm. A teardown that fails to converge tick over
# tick becomes YOUR move — 'needs-you · retirement stuck: <blocker> · <remedy>', red, naming the exact
# thing that would not die. A slug held by real work is 'needs-you · <reason>: <evidence>', red.
# 'awaiting task' is thereby RESERVED for what it always meant: a live spare builder that never got a
# PR. A merged builder can no longer masquerade as one.
#
# COMPOSITION, not reimplementation. Every primitive already exists: _reap_slug (HERD-91's idempotent
# teardown), _sweep_classify_dirt / _sweep_unique_commits / _srs_gh_view (HERD-191's proof helpers),
# herd_teardown_slug, _herd_tabs_drop_row. This file is the reconciler that runs them on a cadence and
# names what it cannot finish.
#
# COST. One `gh pr view` per PR-LESS worktree per tick would be absurd at 4 s. Terminal PR states never
# change, so an anchored MERGED/CLOSED verdict is MEMOIZED per (slug, HEAD sha) in
# $TREES/.retire-anchor-<slug>-<sha>. A tree that has not moved therefore costs one file read. OPEN /
# absent / gh-down verdicts are never cached (they are not terminal), so recovery is automatic.
#
# Sourced (RETIREMENT_LIB=1) by agent-watch.sh AFTER sweep.sh — it needs both files' helpers. Executed
# directly by nothing; there is no CLI. `herd sweep` remains the on-demand, whole-control-room cleanup.

_RETIRE_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Helper substrate: _reap_slug + the sweep proof helpers live in agent-watch.sh / sweep.sh. Source
# agent-watch.sh in LIB mode when (and only when) they are not already in scope — the same two-caller,
# no-recursion pattern sweep.sh uses (agent-watch.sh sources sweep.sh, which is what defines
# _sweep_classify_dirt, so probing for THAT proves both files are loaded).
if ! command -v _sweep_classify_dirt >/dev/null 2>&1; then
  # shellcheck disable=SC2034  # read by agent-watch.sh's lib-mode guard on the next line
  AGENT_WATCH_LIB=1
  # shellcheck source=/dev/null
  . "$_RETIRE_HERE/agent-watch.sh"
  unset AGENT_WATCH_LIB
fi

# ── tunables (deliberate constants + test seams, not config keys) ────────────────────────────────
# How many CONSECUTIVE ticks a teardown may fail to converge before its calm 'retiring…' row turns
# into a red needs-you. 3 ticks ≈ 12 s: long enough that a herdr round-trip lands, short enough that a
# genuinely wedged teardown is on screen before the operator's next glance. A single failed tick is
# never red (no false-red consoles); only a persistent one is.
_RETIRE_STUCK_TICKS="${HERD_RETIRE_STUCK_TICKS:-3}"

# How long a NON-terminal PR probe (open PR, no PR yet, gh unreachable) is trusted before we ask
# GitHub again. A terminal verdict is cached forever (it cannot change); a non-terminal one must not be,
# or a merge would never be noticed. But re-asking every 4 s tick, for every PR-less worktree, is a `gh`
# call per builder per tick — so a negative answer holds for 30 s, keyed by (slug, HEAD sha).
#
# This NEVER delays the case that matters. A slug with an OPEN PR is classified active from $PRS_JSON
# alone and is never probed, so no negative memo exists to go stale when that PR merges: the tick after
# the merge asks `gh` and gets MERGED. The memo only ever caches "this PR-less builder still has no PR",
# which is precisely the answer that is cheap to be 30 s late about.
_RETIRE_PROBE_TTL="${HERD_RETIRE_PROBE_TTL:-30}"

# ── per-slug escalation state ────────────────────────────────────────────────────────────────────
# One file per non-converged slug: "<attempts> <first_epoch>" on line 1, the leftover kinds on line 2.
# Purely an escalation memory — the teardown itself never reads it. Deleted the moment a slug converges
# (or turns out to be active), so a healthy control room carries none.
_retire_state_file() { printf '%s' "$TREES/.retire-$1"; }

# _retire_attempts <slug> — consecutive non-converged ticks recorded so far (0 when unknown/absent).
_retire_attempts() {
  local f n=""; f="$(_retire_state_file "$1")"
  [ -s "$f" ] && read -r n _ < "$f" 2>/dev/null
  case "${n:-}" in ''|*[!0-9]*) printf '0' ;; *) printf '%s' "$n" ;; esac
}

# _retire_first_epoch <slug> — when this slug was FIRST seen non-converged (0 when absent), so the row
# can carry an honest age instead of a tick count.
_retire_first_epoch() {
  local f n e=""; f="$(_retire_state_file "$1")"
  [ -s "$f" ] && read -r n e < "$f" 2>/dev/null
  case "${e:-}" in ''|*[!0-9]*) printf '0' ;; *) printf '%s' "$e" ;; esac
}

# _retire_state_bump <slug> <leftovers-csv> — record one more non-converged tick, preserving the
# first-seen epoch. Fail-soft: an unwritable $TREES simply costs the escalation (never the teardown).
_retire_state_bump() {
  local slug="$1" left="$2" n e
  n="$(_retire_attempts "$slug")"; e="$(_retire_first_epoch "$slug")"
  [ "$e" != "0" ] || e="$(_now_epoch)"
  printf '%s %s\n%s\n' "$(( n + 1 ))" "$e" "$left" > "$(_retire_state_file "$slug")" 2>/dev/null || true
}

# _retire_state_clear <slug> — forget everything this file remembers about <slug>: the escalation
# counter AND the once-per-kind journal markers. Called when a slug converges or turns out to be active
# (a re-spawn on the same kebab name), so a later hold/stuck for the same slug speaks again.
# _retire_last_left <slug> — the leftovers string recorded on the previous non-converged tick (line 2 of
# the state file), or empty. 'held' marks a slug that was carrying real work last tick.
_retire_last_left() {
  local f; f="$(_retire_state_file "$1")"
  [ -s "$f" ] || return 0
  sed -n 2p "$f" 2>/dev/null || true
}

_retire_state_clear() {
  local k
  rm -f "$(_retire_state_file "$1")" 2>/dev/null || true
  # EXACT names, never a `.retire-noted-$1-*` glob: that glob also matches a SIBLING slug's markers
  # (clearing `foo` would delete `foo-bar`'s `.retire-noted-foo-bar-hold`), and since this runs on every
  # `active` classification — i.e. every tick for a healthy `foo` — a held `foo-bar` would re-emit its
  # `retire_hold` journal line forever, defeating the very once-per-(slug,kind) dedupe the marker exists
  # for. The kind is a closed set, so enumerate it; _retire_tail_ok cannot help here (its tails are shas,
  # and `hold`/`stuck` are not hex).
  for k in hold stuck; do
    rm -f "$TREES/.retire-noted-$1-$k" 2>/dev/null || true
  done
}

# ── leftovers: what still exists that has no right to ────────────────────────────────────────────
# _retire_tab_ids <slug> — the engine tabs still open for this slug (builder, review·, resolve·),
# workspace-scoped. Empty without herdr. Mirrors herd_teardown_slug's label set — that function CLOSES
# them, this one ASKS whether they are gone, and the two must agree or a closed tab would read as a
# leftover forever.
_retire_tab_ids() {
  command -v herdr >/dev/null 2>&1 || return 0
  local wsid tabs
  wsid="$(herd_resolve_workspace_id 2>/dev/null || true)"
  tabs="$(herdr tab list 2>/dev/null || true)"
  [ -n "$tabs" ] || return 0
  printf '%s' "$tabs" | SLUG="$1" WS="$wsid" python3 -c '
import sys, json, os
slug = os.environ["SLUG"]; ws = os.environ.get("WS","")
labels = {slug, "review·" + slug, "resolve·" + slug}
try:
    for t in json.load(sys.stdin).get("result",{}).get("tabs",[]):
        if t.get("label") in labels and (not ws or t.get("workspace_id","") == ws):
            print(t["tab_id"])
except Exception:
    pass
' 2>/dev/null || true
}

# _retire_agent_listed <slug> — success iff the driver's roster still carries an agent for this slug.
# Reads the tick's already-fetched $AGENTS_JSON when present (no extra round-trip); falls back to a
# live query for the CLI/test callers. Under herdr an agent dies with its tab; headless lists only LIVE
# pids. So this leftover clears itself once the tab close lands — it is a PROGRESS signal, not a thing
# retirement kills. A roster entry that survives every retry is exactly the "why is this still here"
# the operator wants named.
_retire_agent_listed() {
  local slug="$1" json="${AGENTS_JSON:-}"
  [ -n "$json" ] || json="$(herd_driver_agent_list_json 2>/dev/null || echo '{}')"
  printf '%s' "$json" | SLUG="$slug" python3 -c '
import sys, json, os
slug = os.environ["SLUG"]
try:
    ags = (json.load(sys.stdin).get("result") or {}).get("agents") or []
except Exception:
    raise SystemExit(1)
raise SystemExit(0 if any(a.get("name") == slug for a in ags) else 1)
' 2>/dev/null
}

# _retire_tail_ok <tail> — guard for the sha/pr-suffixed ledger globs. `.health-result-<slug>-<sha>`
# globbed as `.health-result-foo-*` ALSO matches slug `foo-bar`'s files, and purging those would delete
# a LIVE sibling builder's state. The tail is whatever follows `<slug>-`: for our own files that is a
# lone hex sha (≥7 chars) or a PR number; for a sibling it always begins with the rest of that sibling's
# name, so it carries a '-' or a non-hex letter and is rejected. (A sibling named e.g. `foo-beef` would
# yield the tail `beef-<sha>` — still rejected, because the sha follows.)
_retire_tail_ok() {
  local t="${1:-}"
  case "$t" in ''|*[!0-9a-fA-F]*) return 1 ;; esac   # any '-' or non-hex char → a sibling slug
  case "$t" in *[!0-9]*) [ "${#t}" -ge 7 ] ;; *) return 0 ;; esac
}

# _retire_suffixed <prefix> — print every existing path matching "<prefix>*" whose REMAINDER after the
# prefix is a legitimate sha/PR tail. The remainder is taken from the prefix, never from the last dash:
# `.health-result-sib-bling-<sha>` leaves `bling-<sha>` for slug `sib` and is correctly rejected.
_retire_suffixed() {
  local prefix="$1" f
  for f in "$prefix"*; do
    [ -e "$f" ] || continue
    _retire_tail_ok "${f#"$prefix"}" && printf '%s\n' "$f"
  done
  return 0
}

# _retire_drop_probes <slug> — remove THIS slug's probe memos, tail-guarded. A bare
# `.retire-probe-$slug-*` glob also matches a sibling (`foo` eats `foo-bar`'s probes), which would cost
# the sibling one extra `gh pr view`. Bounded, but the guard is one line.
_retire_drop_probes() {
  local f
  while IFS= read -r f; do [ -n "$f" ] && rm -f "$f" 2>/dev/null; done \
    < <(_retire_suffixed "$TREES/.retire-probe-$1-")
  return 0
}

# _retire_ledger_files <slug> — the SLUG-KEYED engine state a retired slug must not leave behind.
#
# THE KEYING RULE, and it is the whole safety story of this function: almost nothing in $TREES is keyed
# by slug. Every gate ledger is keyed by PR NUMBER (or <pr>-<sha>), even where its name reads like a
# slug would fit. Verified against the writers:
#
#   .health-cachehit-<pr>            _health_cachehit_file "$_jc_pr"
#   .health-inflight-<pr>-<sha>      _health_acquire  (also .health-inflight-main-<sha>)
#   .health-dispatch-<pr>-<sha>      _health_dispatch_file
#   .health-log-<pr>-<sha>           _health_log_file
#   .health-result-<pr>-<sha>        record_health_result "$_hg_pr" "$_hg_sha"
#   .review-escalate-<pr>            _review_escalate_file "$_mare_pr"
#   .resolve-result-<pr>-<sha>       _resolve_result_file "$rp" "$rsha"
#   .resolve-registry-<pr>-<sha>     _resolve_registry_file "$rp" "$rsha"   (HERD-280 resolver pane)
#   .agent-watch-refix-dead-<pr>-<sha>          _refix_dead_marker  <pr> <sha>
#   .agent-watch-refix-stuck-<kind>-<pr>-<sha>  _refix_stuck_file   <pr> <sha> <kind>
#
# Globbing any of those by slug matches a LIVE, OPEN PR's state whenever a PR number happens to share
# the prefix — and deleting it is not cosmetic: `.review-escalate-<pr>` is a safety rail (a PR that
# earned a deep review silently gets the cheap one), and `.health-inflight-<pr>-<sha>` is the health
# mutex (removing it frees the slot for a duplicate dispatch while the worker still runs). None of them
# are ours. They belong to _discard_stale_health / _discard_stale_reviews / the gate corpse sweep,
# which own their liveness semantics. Retirement must not touch a single one.
#
# What IS slug-keyed, and therefore ours:
#   .herd-ref-<slug>          the per-worktree tracker-ref marker (_slug_ref_file)
#   .retire-anchor-<slug>-<sha> / .retire-probe-<slug>-<sha>   this file's own memo scratch
# (`.retire-<slug>` and `.retire-noted-<slug>-<kind>` are also ours but are escalation memory, cleared
#  by _retire_state_clear — counting them here would make a slug its own leftover and never converge.)
_retire_ledger_files() {
  local slug="$1" p
  [ -e "$TREES/.herd-ref-$slug" ] && printf '%s\n' "$TREES/.herd-ref-$slug"
  for p in "$TREES/.retire-anchor-$slug-" "$TREES/.retire-probe-$slug-"; do
    _retire_suffixed "$p"
  done
  return 0
}

# _retire_branch_reapable — success iff the operator's merge policy says a landed branch should go
# away. DELETE_BRANCH_ON_MERGE (default false) is that policy, and it governs BOTH halves of the
# invariant: when it is false the local branch is RETAINED ON PURPOSE, so retirement must neither
# delete it nor count it as a leftover — otherwise every retiree would converge to "stuck: branch" and
# the console would go red over a branch the operator explicitly asked to keep.
_retire_branch_reapable() {
  case "${DELETE_BRANCH_ON_MERGE:-false}" in 1|true|yes|on) return 0 ;; *) return 1 ;; esac
}

# _retire_branch_live <branch> — success iff a local branch ref still exists, is reapable by policy, and
# is not the branch the main checkout is standing on (never ours to delete).
_retire_branch_live() {
  local br="${1:-}"; [ -n "$br" ] || return 1
  _retire_branch_reapable || return 1
  [ "$br" = "$(git -C "$MAIN" rev-parse --abbrev-ref HEAD 2>/dev/null || true)" ] && return 1
  git -C "$MAIN" show-ref --verify --quiet "refs/heads/$br" 2>/dev/null
}

# retire_leftovers <slug> <dir> <branch> — the kinds of thing that still exist for this slug, one per
# line, in teardown order: worktree, tab, agent, branch, ledger. EMPTY output ⇒ converged. This is the
# whole convergence test, and it is a pure observation of the world — which is what makes a restart at
# any teardown step harmless.
retire_leftovers() {
  local slug="$1" dir="${2:-}" branch="${3:-}"
  [ -n "$dir" ] && [ -d "$dir" ] && printf 'worktree\n'
  [ -n "$(_retire_tab_ids "$slug")" ] && printf 'tab\n'
  _retire_agent_listed "$slug" && printf 'agent\n'
  _retire_branch_live "$branch" && printf 'branch\n'
  [ -n "$(_retire_ledger_files "$slug")" ] && printf 'ledger\n'
  return 0
}

# ── classification ───────────────────────────────────────────────────────────────────────────────
# _retire_anchor <slug> <branch> <head> — the memoized PR verdict for this exact (slug, HEAD sha):
# "<state>\t<oid>\t<number>", as _srs_gh_view returns it. Only TERMINAL verdicts (MERGED/CLOSED) whose
# oid matches <head> are cached — an OPEN PR, a missing PR, or an unreachable gh must be re-asked next
# tick, because those verdicts change.
_retire_anchor() {
  local slug="$1" branch="$2" head="$3" memo probe line st oid seen
  memo="$TREES/.retire-anchor-$slug-$head"
  if [ -s "$memo" ]; then cat "$memo" 2>/dev/null; return 0; fi
  [ -n "$branch" ] || return 0

  # A fresh NON-terminal probe for this exact (slug, head) means we asked recently and the answer was
  # "nothing terminal here". Skip the round-trip and report no anchor (⇒ active).
  probe="$TREES/.retire-probe-$slug-$head"
  if [ -s "$probe" ]; then
    read -r seen < "$probe" 2>/dev/null || seen=""
    case "${seen:-}" in
      ''|*[!0-9]*) : ;;
      *) [ "$(( $(_now_epoch) - seen ))" -lt "$_RETIRE_PROBE_TTL" ] && return 0 ;;
    esac
  fi

  line="$(_srs_gh_view "$branch")"
  IFS=$'\t' read -r st oid _ <<EOF
${line:-}
EOF
  case "${st:-}" in
    MERGED|CLOSED)
      if [ "${oid:-}" = "$head" ]; then
        printf '%s' "$line" > "$memo" 2>/dev/null || true
        _retire_drop_probes "$slug"
      fi
      ;;
    *)
      # Non-terminal (open / no PR / gh unreachable): remember only that we asked, and drop this slug's
      # probes for any OTHER head — a builder that commits moves its head and would otherwise litter.
      _retire_drop_probes "$slug"
      printf '%s\n' "$(_now_epoch)" > "$probe" 2>/dev/null || true
      ;;
  esac
  printf '%s' "${line:-}"
}

# _retire_branch_for_slug <slug> — the LOCAL branch ref this slug built on, or nothing. Resolved by
# parsing every local head through the active BRANCH_TEMPLATE rather than by rendering the template,
# so a `{ref}`-bearing scheme (feat/HERD-164/retiree) resolves as readily as the default. Needed on the
# orphan path: once the worktree is gone, the branch is the only handle left on the slug's commits.
_retire_branch_for_slug() {
  local slug="$1" ref
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    [ "$(herd_branch_parse "$ref" 2>/dev/null || true)" = "$slug" ] && { printf '%s' "$ref"; return 0; }
  done < <(git -C "$MAIN" for-each-ref --format='%(refname:short)' refs/heads 2>/dev/null || true)
  return 0
}

# _retire_ledger_pr <slug> — the PR number the reap ledger ($STATE, "<ts> <pr> <slug> [ref]") last
# recorded for this slug. The orphan path's fallback anchor when the branch name no longer resolves a
# PR (GitHub deletes the head branch at merge). Mirrors _startup_reap_sweep's fallback — and, exactly
# as there, the PR's own verdict still has to say MERGED; a stale ledger row alone proves nothing.
_retire_ledger_pr() {
  [ -s "$STATE" ] || return 0
  awk -v s="$1" 'NF>=3 && $3==s{p=$2} END{if(p!="")print p}' "$STATE" 2>/dev/null || true
}

# _retire_branch_unique <branch> — commits on this local branch that the default branch does not have.
# '?' when the base ref cannot be resolved. The orphan path's data-safety proof: a branch with unique
# commits and no merged PR is the ONLY copy of that work, and is HELD, never deleted.
_retire_branch_unique() {
  local br="$1" base="${DEFAULT_BRANCH:-origin/main}" n
  git -C "$MAIN" rev-parse --verify --quiet "$base" >/dev/null 2>&1 || { printf '?'; return 0; }
  n="$(git -C "$MAIN" rev-list --count "$base..refs/heads/$br" 2>/dev/null || true)"
  case "$n" in ''|*[!0-9]*) printf '?' ;; *) printf '%s' "$n" ;; esac
}

# _retire_classify_orphan <slug> <provenance> — the classifier for a slug whose WORKTREE IS GONE. Its
# tab, agent, and ledger rows are pure debris either way; the only thing that can carry work is the
# local BRANCH, so that is what must be proven disposable before it is deleted:
# The order below is load-bearing: PROVE terminality from `gh` first, apply the branch-retention POLICY
# only afterwards. A policy is not evidence.
#   branch has an OPEN PR                   → active   (not terminal at all)
#   no PR verdict at all (gh down / no PR)  → active   (unproven is not terminal; never a teardown)
#   no branch                               → retiring (no ref ⇒ no commits ⇒ nothing to lose)
#   terminal, DELETE_BRANCH_ON_MERGE=false  → retiring, with an EMPTY <branch>: the debris retires, the
#                                                       retained ref is never touched and never judged
#   MERGED, tip == headRefOid               → retiring (every commit on this ref is in the merged PR)
#   MERGED, tip != headRefOid               → held     (commits past the merged head live ONLY here)
#   …or the ledger's PR is MERGED           → retiring (only with the SAME tip anchor; the branch-name
#                                                       lookup fails after a delete-at-merge)
#   CLOSED, 0 unique commits                → retiring (the branch adds nothing to the default branch)
#   CLOSED, unique commits                  → held     (this is the only copy — a human decides)
#   base ref unresolvable                   → held     (unprovable is never deleted)
#
# THE SHA ANCHOR, restated for the branch. The worktree path anchors on the tree's HEAD == a terminal
# PR's headRefOid. There is no worktree here, so the anchor becomes the LOCAL BRANCH TIP: `git rev-parse
# refs/heads/<br>` must EQUAL the merged PR's headRefOid. "The PR named by this branch merged" is NOT
# the same claim as "this ref holds nothing but that PR" — a builder that kept committing after the
# merge has commits past the merged head that exist nowhere else, and `branch -D` destroys them
# irrecoverably (recoverable only via `git fsck` inside the gc window). _retire_branch_unique cannot
# substitute: a SQUASH merge rewrites history, so every commit on the branch reads as "unique" against
# the default branch and the check would hold every squash-merged branch forever. Only the tip anchor
# distinguishes "this ref is exactly the thing GitHub merged" from "this ref is that thing plus work".
#
# PROVENANCE is a REQUIRED second gate, on top of the anchor. A slug reaches teardown here only if
# herdkit itself can show it created the thing: an engine tab in its own registry, a residual slug-keyed
# marker it wrote, or a row in the reap ledger. Without that, the answer is `active` — do nothing. So a
# discovery-key bug on any future leg (the class of bug that let PR-keyed ledgers manufacture the
# phantom slug `312`) degrades to a no-op instead of a silent teardown. Fail safe, not fail destructive.
# Echoes the same \x1f-separated "<state> <pr> <sha> <detail> <branch>" tuple as retire_classify.
_retire_classify_orphan() {
  local slug="$1" prov="${2:-}" br st oid num lpr uniq
  case "$prov" in
    # worktree: the tree was under $WORKTREES_DIR when the tick began and vanished under us (a reap
    # earlier in this same tick, or `herd sweep` racing). The strongest provenance there is.
    worktree|registry|residual|ledger) : ;;
    *) printf 'active\x1f\x1f\x1f\x1f'; return 0 ;;
  esac
  # ORDER IS THE WHOLE FIX. The branch-retention POLICY must never gate the TERMINALITY PROOF.
  #
  # This check used to run first: under DELETE_BRANCH_ON_MERGE=false — the shipped default, and this
  # repo's own committed value — every provenanced worktree-gone slug short-circuited straight to
  # `retiring`, whether its PR was merged, closed, OPEN, or `gh` was simply unreachable. The OPEN guard
  # below was dead code. The only thing left standing between a live open PR and a full silent teardown
  # (tabs killed, registry row dropped, .herd-ref deleted, no console row) was retirement_tick's
  # open_slugs FAST PATH — which fails OPEN on a `gh` blip ($PRS_JSON='[]') or a narrowed WATCHER_VIEW.
  #
  # So: prove terminality FIRST, from `gh`, for THIS ref. Only once a slug is proven disposable does the
  # policy decide what happens to the BRANCH — and when the operator asked to retain it, the record is
  # emitted with an EMPTY <branch> so retire_converge's _retire_delete_branch is a no-op on it, while the
  # tab/agent/ledger debris still retires.
  br="$(_retire_branch_for_slug "$slug")"

  # No local ref at all. Nothing here can carry commits: the only assets are tabs and slug markers, which
  # the shipped orphan-tab sweep (_orphan_tab_ids) already reaps on strictly weaker evidence than the
  # provenance gate above. Nothing to prove against, so nothing to prove.
  [ -n "$br" ] || { printf 'retiring\x1f\x1f\x1fworktree gone\x1f'; return 0; }

  IFS=$'\t' read -r st oid num <<EOF
$(_srs_gh_view "$br")
EOF
  # An OPEN PR on this ref is not terminal. retirement_tick's open_slugs filter usually catches this
  # first, but that filter reads a VIEW-FILTERED $PRS_JSON — a fast path, never the proof. retire_classify
  # is a documented, unit-tested entry point and must be safe when called directly.
  [ "${st:-}" = "OPEN" ] && { printf 'active\x1f\x1f\x1f\x1f'; return 0; }

  # Ledger fallback ONLY when the branch name resolves NO PR at all (GitHub deleted the head branch at
  # merge). Never let an old ledger PR's MERGED overwrite a live CLOSED verdict for THIS ref.
  if [ -z "${st:-}" ]; then
    lpr="$(_retire_ledger_pr "$slug")"
    if [ -n "$lpr" ]; then
      # NB: _srs_gh_view's other callers pass a BRANCH NAME; here we pass a PR NUMBER. `gh pr view`
      # accepts either, and the number is the only handle left once GitHub deleted the head branch at
      # merge. Same helper, deliberately both shapes.
      local lst loid lnum
      IFS=$'\t' read -r lst loid lnum <<EOF
$(_srs_gh_view "$lpr")
EOF
      [ "${lst:-}" = "MERGED" ] && { st="MERGED"; num="$lnum"; oid="$loid"; }
    fi
  fi

  # STILL no verdict: `gh` is unreachable, rate-limited, or this ref simply has no PR record. Those are
  # indistinguishable from here, and an unreachable `gh` must never license a teardown — the worktree path
  # makes exactly the same call (no anchor ⇒ active). Unproven is not terminal.
  [ -n "${st:-}" ] || { printf 'active\x1f\x1f\x1f\x1f'; return 0; }

  # POLICY, now that terminality is PROVEN (the PR is MERGED or CLOSED; OPEN and unproven already
  # returned active). The operator asked to retain landed branches, so this ref is not debris and no
  # proof about its commits is owed: retire the tab/agent/ledger debris and emit an EMPTY <branch> so
  # _retire_delete_branch never touches it. Holding a retained branch would be a red row about a
  # deliberate policy; deleting it would defy that policy. Neither.
  _retire_branch_reapable \
    || { printf 'retiring\x1f%s\x1f\x1fworktree gone · branch %s retained by policy\x1f' "${num:-}" "$br"; return 0; }

  if [ "${st:-}" = "MERGED" ]; then
    # THE ANCHOR. Without it, "the PR merged" would license deleting a ref that has moved on since.
    local tip ahead
    tip="$(git -C "$MAIN" rev-parse --verify --quiet "refs/heads/$br" 2>/dev/null || true)"
    if [ -n "${oid:-}" ] && [ -n "$tip" ] && [ "$tip" = "$oid" ]; then
      printf 'retiring\x1f%s\x1f%s\x1fPR #%s merged · worktree gone\x1f%s' "${num:-}" "${oid:-}" "${num:-}" "$br"
    else
      ahead="$(git -C "$MAIN" rev-list --count "${oid:-HEAD}..refs/heads/$br" 2>/dev/null || true)"
      case "$ahead" in ''|*[!0-9]*) ahead="?" ;; esac
      if [ "$ahead" = "0" ]; then
        # 0 unique commits vs the merged head: every bit of work is already in the PR. Auto-clear.
        printf 'retiring\x1f%s\x1f\x1fPR #%s merged · worktree gone · branch tip is ancestor of merged head\x1f%s' \
          "${num:-}" "${num:-}" "$br"
      else
        printf 'held\x1f\x1f\x1fbranch %s has moved past the merged head of PR #%s (%s commit(s) exist only here) · commit or discard\x1f%s' \
          "$br" "${num:-}" "$ahead" "$br"
      fi
    fi
    return 0
  fi

  uniq="$(_retire_branch_unique "$br")"
  if [ "$uniq" = "?" ]; then
    printf 'held\x1f\x1f\x1fcannot resolve %s to prove branch %s carries no unique work\x1f%s' \
      "${DEFAULT_BRANCH:-origin/main}" "$br" "$br"
  elif [ "$uniq" != "0" ]; then
    printf 'held\x1f\x1f\x1f%s commit(s) exist only on branch %s (worktree gone, no merged PR)\x1f%s' \
      "$uniq" "$br" "$br"
  else
    printf 'retiring\x1f%s\x1f\x1fworktree gone · branch %s carries nothing\x1f%s' "${num:-}" "$br" "$br"
  fi
  return 0
}

# retire_classify <slug> <dir> <branch> <has-open-pr> — the CLASSIFIER, the unit-testable heart of this
# file. Echoes "<state> <pr> <sha> <detail> <branch>", \x1f-separated (NEVER tab: tab is IFS whitespace and
# `read` would collapse the empty <pr>/<sha> the orphan path emits), with state in a closed set of three:
#
#   active   — nothing to retire: an open PR, an in-flight builder with no PR yet, no sha anchor, or a
#              `gh` we could not reach. The default for everything unproven; no action, ever.
#   retiring — PROVABLY terminal and PROVABLY disposable: the worktree is already gone, or its HEAD is
#              the head of a MERGED PR (dirt-free or regenerable-only), or of a CLOSED PR that carries
#              zero unique commits and no real dirt. Drive teardown.
#   held     — PROVABLY terminal but carrying REAL WORK: uncommitted tracked changes, or commits that
#              exist nowhere else, or a base ref we cannot resolve to prove otherwise. NEVER touched;
#              <detail> is the evidence a human needs, verbatim.
retire_classify() {
  local slug="$1" dir="${2:-}" branch="${3:-}" open_pr="${4:-0}" prov="${5:-}"
  local head st oid num dirt evidence uniq

  [ "$open_pr" = "1" ] && { printf 'active\x1f\x1f\x1f\x1f'; return 0; }

  # Worktree already gone (removed by hand, by `herd sweep`, or by a half-finished reap): the tab,
  # agent, and ledger rows are pure debris; only the branch can still carry work.
  if [ -z "$dir" ] || [ ! -d "$dir" ]; then
    _retire_classify_orphan "$slug" "$prov"
    return 0
  fi

  [ -n "$branch" ] || { printf 'active\x1f\x1f\x1f\x1f'; return 0; }
  head="$(git -C "$dir" rev-parse HEAD 2>/dev/null || true)"
  [ -n "$head" ] || { printf 'active\x1f\x1f\x1f\x1f'; return 0; }

  IFS=$'\t' read -r st oid num <<EOF
$(_retire_anchor "$slug" "$branch" "$head")
EOF
  # No sha anchor → not provably terminal → untouchable. This single line is what makes a reused slug,
  # a fresh commit, and a gh outage all safe.
  [ -n "${oid:-}" ] && [ "$oid" = "$head" ] || { printf 'active\x1f\x1f\x1f\x1f'; return 0; }

  dirt="$(_sweep_classify_dirt "$dir")"
  evidence="${dirt#*$'\t'}"; [ "$evidence" = "$dirt" ] && evidence=""
  dirt="${dirt%%$'\t'*}"

  case "${st:-}" in
    MERGED)
      if [ "$dirt" = "dirty" ]; then
        printf 'held\x1f%s\x1f%s\x1funcommitted work: %s (PR #%s merged; commit or discard)\x1f%s' \
          "$num" "$head" "$evidence" "$num" "$branch"
      else
        printf 'retiring\x1f%s\x1f%s\x1fPR #%s merged\x1f%s' "$num" "$head" "$num" "$branch"
      fi
      ;;
    CLOSED)
      uniq="$(_sweep_unique_commits "$dir")"
      if [ "$uniq" = "?" ]; then
        printf 'held\x1f%s\x1f%s\x1fcannot resolve %s to prove no unique work (PR #%s closed)\x1f%s' \
          "$num" "$head" "${DEFAULT_BRANCH:-origin/main}" "$num" "$branch"
      elif [ "$uniq" != "0" ]; then
        printf 'held\x1f%s\x1f%s\x1f%s commit(s) exist only here (PR #%s closed unmerged)\x1f%s' \
          "$num" "$head" "$uniq" "$num" "$branch"
      elif [ "$dirt" = "dirty" ]; then
        printf 'held\x1f%s\x1f%s\x1funcommitted work: %s (PR #%s closed)\x1f%s' "$num" "$head" "$evidence" "$num" "$branch"
      else
        printf 'retiring\x1f%s\x1f%s\x1fPR #%s closed\x1f%s' "$num" "$head" "$num" "$branch"
      fi
      ;;
    *) printf 'active\x1f\x1f\x1f\x1f' ;;
  esac
  return 0
}

# ── convergence: drive the teardown one step further, idempotently ───────────────────────────────
# _retire_drop_registry_rows <slug> — prune this slug's rows from the $TREES/.herd-tabs registry after
# its tabs are closed, so the registry (itself a ledger) converges too. Byte-safe: every other row is
# left untouched.
_retire_drop_registry_rows() {
  local reg="$TREES/.herd-tabs"
  [ -f "$reg" ] || return 0
  SLUG="$1" REG="$reg" python3 -c '
import os
reg = os.environ["REG"]; slug = os.environ["SLUG"]
drop = {slug, "review·" + slug, "resolve·" + slug}
try:
    with open(reg, encoding="utf-8") as f: lines = f.readlines()
    with open(reg, "w", encoding="utf-8") as f:
        for line in lines:
            if line.strip().split(" ", 1)[0] not in drop:
                f.write(line)
except Exception:
    pass
' 2>/dev/null || true
}

# _retire_delete_branch <branch> — drop the local branch ref of an ANCHORED terminal PR. Safe by the
# anchor, not by `git branch -d`'s ancestry test: a SQUASH merge leaves the branch's commits
# unreachable from main, so `-d` would refuse forever and the row would be permanently "stuck". The
# caller has already proven every commit here is in a merged PR (or that a closed branch carries zero
# unique commits), so `-D` destroys nothing. Never called on the held or worktree-gone paths.
_retire_delete_branch() {
  local br="${1:-}"
  _retire_branch_live "$br" || return 0
  git -C "$MAIN" branch -D "$br" >/dev/null 2>&1 || true
}

# retire_converge <slug> <dir> <pr> <sha> <branch> <reason> — one idempotent teardown pass. Every step
# no-ops when its target is already gone, so this is safe to call on a slug that is fully retired, and
# safe to interrupt anywhere: the next call resumes from wherever the world actually is.
#
#   1. worktree + tabs + tracker-ref marker + step-holds  → _reap_slug (HERD-91's shared primitive)
#      (no worktree ⇒ close the tabs directly; _reap_slug's git remove would be a no-op anyway, but
#       calling herd_teardown_slug keeps the orphan path free of a pointless git round-trip)
#   2. registry rows for the closed tabs
#   3. the local branch ref — ONLY ever reached on the `retiring` verdict, which is exactly the verdict
#      that proved these commits exist elsewhere (merged PR head, or zero unique commits). A `held`
#      slug never calls this function at all.
#   4. the per-slug ledgers, plus the line-oriented dead/limit/sendkeys records
#   5. the PR-keyed approval + CI-check ledgers, when a PR number is known
#
# ORDERING NOTE (learned the hard way — the sim kills the watcher between every pair of these steps):
# each step must be recoverable WITHOUT the steps before it. Teardown deletes its own discovery keys —
# the worktree, then the registry row — so a crash in the middle leaves a slug that neither leg A nor
# leg B can see. That is what leg C (residual-ledger discovery) is for. Reordering to "delete the keys
# last" would only move the hole; the fix is that EVERY residue is independently discoverable.
retire_converge() {
  local slug="$1" dir="${2:-}" pr="${3:-}" sha="${4:-}" branch="${5:-}" reason="${6:-retire}"
  [ -z "${DRYRUN:-}" ] || return 0

  if [ -n "$dir" ] && [ -d "$dir" ]; then
    _reap_slug "$slug" "$dir" "$pr" "$sha" "$reason"
  else
    herd_teardown_slug "$slug"
  fi
  _retire_drop_registry_rows "$slug"
  _retire_delete_branch "$branch"

  local f
  while IFS= read -r f; do [ -n "$f" ] && rm -f "$f" 2>/dev/null; done < <(_retire_ledger_files "$slug")
  clear_dead "$slug" 2>/dev/null || true
  clear_limit "$slug" "$dir" 2>/dev/null || true
  clear_sendkeys "$slug" 2>/dev/null || true
  [ -n "$pr" ] && { purge_pr_approvals "$pr" 2>/dev/null || true; purge_pr_ci_checks "$pr" 2>/dev/null || true; }
  return 0
}

# ── candidate discovery ──────────────────────────────────────────────────────────────────────────
# _retire_open_pr_branches — the head branches of the open PRs this tick already fetched ($PRS_JSON).
# A worktree on one of these is ACTIVE, full stop; no gh call, no anchor lookup.
_retire_open_pr_branches() {
  printf '%s' "${PRS_JSON:-[]}" | python3 -c '
import sys, json
try:
    for p in json.load(sys.stdin):
        b = p.get("headRefName") or ""
        if b: print(b)
except Exception:
    pass
' 2>/dev/null || true
}

# _retire_open_pr_slugs — the SLUGS behind the open PRs, parsed out of each head branch through the
# active BRANCH_TEMPLATE (herd_branch_parse). The orphan leg needs these because a slug can have an
# open PR with NO local worktree — a collaborator's PR, or one built in the main checkout. Its tab is
# not debris and must never be closed. (Leg A needs no such parse: it matches on the branch itself.)
_retire_open_pr_slugs() {
  local b s
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    s="$(herd_branch_parse "$b" 2>/dev/null || true)"
    [ -n "$s" ] && printf '%s\n' "$s"
  done < <(_retire_open_pr_branches)
  return 0
}

# _retire_registry_slugs — slugs the engine's own tab registry ($TREES/.herd-tabs) still records. The
# ALLOWLIST for the orphan leg: a tab herdkit never created is never a retirement candidate, whatever
# its label (the same model _orphan_tab_ids uses). The watcher's own tab is excluded by id.
_retire_registry_slugs() {
  local reg="$TREES/.herd-tabs"
  [ -f "$reg" ] || return 0
  SELF_TAB="${HERD_WATCHER_TAB_ID:-}" REG="$reg" python3 -c '
import os
reg = os.environ["REG"]; self_tab = os.environ.get("SELF_TAB","")
MID = "·"
out = []
try:
    with open(reg, encoding="utf-8") as f:
        for line in f:
            parts = line.strip().split(" ", 2)
            if len(parts) < 2: continue
            label, tab_id = parts[0], parts[1]
            if self_tab and tab_id == self_tab: continue
            for pre in ("review" + MID, "resolve" + MID):
                if label.startswith(pre):
                    label = label[len(pre):]; break
            if label: out.append(label)
except Exception:
    pass
for s in sorted(set(out)): print(s)
' 2>/dev/null || true
}

# _retire_real <path> — the symlink-resolved path. `git worktree list` canonicalizes (on macOS every
# /var/… path comes back as /private/var/…), so a raw string compare against $WORKTREES_DIR / $SELF_WT
# silently drops every worktree out of scope. _discover_feature_worktrees realpaths for the same reason.
_retire_real() {
  local p="${1:-}"
  [ -n "$p" ] || return 0
  ( cd "$p" 2>/dev/null && pwd -P ) || printf '%s' "$p"
}

# _retire_worktrees_enumerable — success iff `git worktree list` actually enumerated something. A git
# repo always reports at least its own main checkout, so zero `worktree ` lines means the listing FAILED
# (bad cwd, unreadable .git, a git that errored), not that there are no worktrees. Legs B–D key "orphan"
# off the absence of a worktree, so a failed enumeration would make every registered slug an orphan at
# once. This is the guard that turns that amplifier into a no-op tick.
_retire_worktrees_enumerable() {
  git -C "$MAIN" worktree list --porcelain 2>/dev/null | grep -q '^worktree '  # pipe-ok: bounded command output, under a pipe buffer
}

# _retire_residual_slugs — slugs whose only remaining trace is a SLUG-KEYED file. This is the leg that
# makes the invariant hold across a crash INSIDE teardown: by the time the worktree and the registry row
# are gone, nothing else names the slug.
#
# ONLY genuinely slug-keyed names may be discovery keys, and this is load-bearing, not tidiness. The
# gate ledgers (.health-*, .review-escalate-*, .resolve-result-*, .agent-watch-refix-*) are keyed by PR
# NUMBER — see _retire_ledger_files. Reading them here manufactures phantom "slugs" like `312`,
# `312-<sha>`, or `main-<sha>` from a LIVE open PR's state. None of those match a worktree or an
# open-PR slug, so nothing guards them: they classify as orphans and get torn down on the spot.
#
# Three keys, all ours:
#   .herd-ref-<slug>                     the tracker-ref marker (survives until _reap_slug runs)
#   .retire-<slug>                       our escalation state (written for retiring AND held slugs, so a
#                                        held orphan whose tab and ref are gone stays discoverable)
#   .retire-anchor-<slug>-<sha> / .retire-probe-<slug>-<sha>
#                                        our memo scratch; the trailing -<sha> is stripped, and a tail
#                                        that is not a lone sha (i.e. a sibling slug's name) is skipped
_retire_residual_slugs() {
  local f base p tail
  for p in .herd-ref- .retire-; do
    for f in "$TREES/$p"*; do
      [ -e "$f" ] || continue
      base="${f##*/}"; base="${base#"$p"}"
      # `.retire-anchor-…` / `.retire-probe-…` / `.retire-noted-…` are scratch, handled below/not at all.
      case "$p$base" in .retire-anchor-*|.retire-probe-*|.retire-noted-*) continue ;; esac
      [ -n "$base" ] && printf '%s\n' "$base"
    done
  done
  # The memo scratch: `<slug>-<sha>`. Strip the sha tail; reject anything whose tail is not one, so a
  # dashed slug can never be mistaken for a sibling.
  for p in .retire-anchor- .retire-probe-; do
    for f in "$TREES/$p"*; do
      [ -e "$f" ] || continue
      base="${f##*/}"; base="${base#"$p"}"
      tail="${base##*-}"; _retire_tail_ok "$tail" || continue
      base="${base%-*}"
      [ -n "$base" ] && printf '%s\n' "$base"
    done
  done
  return 0
}

# _retire_ledger_slugs — slugs the reap ledger ($STATE) records as merged. Append-only and never
# pruned, so it is the one durable answer to "did herdkit build this?" — which is exactly the question
# leg D must answer before it touches a branch.
_retire_ledger_slugs() {
  [ -s "$STATE" ] || return 0
  awk 'NF>=3{print $3}' "$STATE" 2>/dev/null | sort -u
}

# _retire_merged_branch_slug <slug> — success iff this slug still owns a local branch that a MERGED PR
# provably contains (by branch name, or by the ledger's PR number when GitHub deleted the head branch
# at merge). The gate for leg D, and deliberately narrower than the orphan classifier: a branch alone
# holds no uncommitted work and no tab, so an UNPROVABLE one is simply left where it is — silently, and
# without a red row. `gh` being down must never turn a squash-merged branch into an alarm.
_retire_merged_branch_slug() {
  local slug="$1" br tip st oid num lpr lst loid
  _retire_branch_reapable || return 1
  br="$(_retire_branch_for_slug "$slug")"
  [ -n "$br" ] || return 1
  _retire_branch_live "$br" || return 1
  tip="$(git -C "$MAIN" rev-parse --verify --quiet "refs/heads/$br" 2>/dev/null || true)"
  [ -n "$tip" ] || return 1

  # THE SAME ANCHOR the orphan classifier enforces, and for the same reason: "the PR merged" does not
  # mean "this ref is exactly what merged". Anchored on the branch TIP, so a branch that gained commits
  # after its PR merged is never handed to teardown. _retire_anchor memoizes a terminal verdict for this
  # exact (slug, tip) forever and TTL-caches a non-terminal one — which is also the BACKOFF: leg D walks
  # the append-only reap ledger every tick, so an unreachable `gh` or a branch whose delete keeps failing
  # would otherwise re-probe the network once per slug per 4 s tick, unbounded.
  IFS=$'\t' read -r st oid num <<EOF
$(_retire_anchor "$slug" "$br" "$tip")
EOF
  [ "${st:-}" = "MERGED" ] && [ -n "${oid:-}" ] && [ "$oid" = "$tip" ] && return 0

  # Head branch deleted at merge ⇒ the branch name resolves no PR. Fall back to the ledger's PR NUMBER,
  # but keep the anchor: its headRefOid must still equal this ref's tip.
  [ -z "${st:-}" ] || return 1
  lpr="$(_retire_ledger_pr "$slug")"
  [ -n "$lpr" ] || return 1
  IFS=$'\t' read -r lst loid _ <<EOF
$(_srs_gh_view "$lpr")
EOF
  [ "${lst:-}" = "MERGED" ] && [ -n "${loid:-}" ] && [ "$loid" = "$tip" ]
}

# ── the invariant tick ───────────────────────────────────────────────────────────────────────────
# Parallel arrays, read by agent-watch.sh's row builders. Rebuilt from scratch every tick — there is no
# cross-tick memory here beyond the escalation counter on disk.
RETIRE_SLUG=(); RETIRE_STATE=(); RETIRE_DETAIL=(); RETIRE_DIR=()
RETIRE_REAPED=0     # worktrees actually removed this tick (the caller re-reads `git worktree list`)

# _retire_record <slug> <state> <detail> <dir> — append one row to the tick's retirement view.
_retire_record() {
  RETIRE_SLUG+=("$1"); RETIRE_STATE+=("$2"); RETIRE_DETAIL+=("$3"); RETIRE_DIR+=("${4:-}")
}

# _retire_state_of <slug> — the state this tick classified for <slug>: retiring | stuck | held, or
# 'active' when the slug is not a retirement candidate at all. The tick loop's row classifier calls
# this BEFORE it reaches the 'awaiting task' branch, which is how a merged builder stops masquerading
# as an unassigned spare.
_retire_state_of() {
  local i=0
  for i in "${!RETIRE_SLUG[@]}"; do
    [ "${RETIRE_SLUG[i]}" = "$1" ] && { printf '%s' "${RETIRE_STATE[i]}"; return 0; }
  done
  printf 'active'
}

# _retire_detail_of <slug> — the evidence/blocker string for the row (empty for an active slug).
_retire_detail_of() {
  local i=0
  for i in "${!RETIRE_SLUG[@]}"; do
    [ "${RETIRE_SLUG[i]}" = "$1" ] && { printf '%s' "${RETIRE_DETAIL[i]}"; return 0; }
  done
  return 0
}

# _retire_age <slug> — how long this slug has been failing to converge, formatted. '0s' when unknown.
_retire_age() {
  local e; e="$(_retire_first_epoch "$1")"
  [ "$e" != "0" ] || { printf '0s'; return 0; }
  _fmt_age "$(( $(_now_epoch) - e ))"
}

# _retire_note_once <slug> <kind> <detail> — journal a hold/stuck ONCE per (slug, kind), not once per
# tick: a red row that re-journals every 4 s drowns the journal it is trying to explain. The marker is
# a ledger file, so it is purged when the slug finally converges.
_retire_note_once() {
  local slug="$1" kind="$2" detail="${3:-}" marker
  marker="$TREES/.retire-noted-$slug-$kind"
  [ -e "$marker" ] && return 0
  : > "$marker" 2>/dev/null || true
  journal_append "retire_$kind" slug "$slug" detail "$detail"
}

# retirement_tick — THE INVARIANT. Called every tick, after $PRS_JSON / $AGENTS_JSON / $WT are fetched
# and BEFORE the console rows are classified.
#
# For every candidate slug — a feature worktree with no open PR, or a registry tab whose worktree is
# gone — classify, then:
#   active   → forget it (drop any escalation state; it may be a re-spawn on the same slug)
#   held     → do NOTHING but say so, loudly, with the evidence. Real work is never destroyed.
#   retiring → drive one teardown pass, then re-observe. Zero leftovers ⇒ converged: journal it, clear
#              the state, and the row simply disappears. Leftovers ⇒ bump the escalation counter; the
#              row reads 'retiring…' until _RETIRE_STUCK_TICKS consecutive failures turn it red, naming
#              the first thing that would not die.
#
# Skipped entirely in dry-run. Fully fail-soft. A clean control room does zero work beyond the
# classification (which, thanks to the anchor memo, is a handful of file reads).
retirement_tick() {
  RETIRE_SLUG=(); RETIRE_STATE=(); RETIRE_DETAIL=(); RETIRE_DIR=(); RETIRE_REAPED=0
  [ -z "${DRYRUN:-}" ] || return 0

  local open_branches; open_branches="$(_retire_open_pr_branches)"
  local trees_real self_real; trees_real="$(_retire_real "$TREES")"; self_real="$(_retire_real "$SELF_WT")"
  local wt_slugs="" dir slug branch det open real

  # ── leg A: feature worktrees with no OPEN PR ──
  # Scoped exactly like _discover_feature_worktrees (HERD-182): under $WORKTREES_DIR, on a branch. A
  # detached scratch tree is `herd sweep`'s judgment call, never an automatic one.
  #
  # EVERY worktree slug — in scope or not, detached or not — is recorded in $wt_slugs, because leg B
  # uses that set to decide what is an ORPHAN. A tree we decline to retire here is still a LIVE tree,
  # and its tabs are not debris. Conflating "out of my scope" with "gone" would close the tabs of a
  # perfectly healthy builder.
  while IFS=$'\x1f' read -r dir slug branch det; do
    [ -n "${slug:-}" ] || continue
    wt_slugs="${wt_slugs}${slug}"$'\n'
    [ "$det" = "1" ] && continue
    real="$(_retire_real "$dir")"
    [ "$real" = "$self_real" ] && continue          # never retire the checkout we are running from
    [ -n "$trees_real" ] && case "$real/" in "$trees_real"/*) ;; *) continue ;; esac
    open=0
    [ -n "$branch" ] && printf '%s\n' "$open_branches" | grep -qxF "$branch" && open=1  # pipe-ok: bounded membership list, under a pipe buffer
    _retire_step "$slug" "$dir" "$branch" "$open" worktree
  done < <(_sweep_worktree_rows)

  # FAIL-CLOSED on enumeration failure. Legs B–D define an orphan as "a slug with no worktree", derived
  # from $wt_slugs. If `git worktree list` fails, times out, or the repo is momentarily unreadable, that
  # set is EMPTY and every registered slug — including live builders — looks orphaned, so one tick could
  # tear down the entire control room. A healthy repo ALWAYS enumerates at least the main checkout, so an
  # empty porcelain listing is never a legitimate "no worktrees"; it is a failure to observe. And an
  # invariant that cannot observe the world must not act on it.
  if ! _retire_worktrees_enumerable; then
    journal_append retire_skip reason worktree-enumeration-failed
    return 0
  fi

  # ── legs B + C: slugs with NO worktree that nonetheless left something behind ──
  # B: an engine tab in the registry (the "merged builder lingers" corpse the operator kept seeing).
  # C: a residual per-slug LEDGER file. Load-bearing for restart-proofing, not a nicety: teardown
  #    removes the worktree and the registry row, so a watcher killed after those two steps leaves a
  #    slug that leg A and leg B are both blind to. Its ledger files are the last handle on it.
  # Both legs feed the same reconciler; a slug discovered twice is stepped once.
  local open_slugs seen="" prov; open_slugs="$(_retire_open_pr_slugs)"
  while read -r prov slug; do
    [ -n "${slug:-}" ] || continue
    printf '%s' "$wt_slugs" | grep -qxF "$slug" && continue    # a live tree → leg A owns it  # pipe-ok: bounded membership list, under a pipe buffer
    printf '%s' "$open_slugs" | grep -qxF "$slug" && continue  # open PR, no local tree → not debris  # pipe-ok: bounded membership list, under a pipe buffer
    printf '%s' "$seen" | grep -qxF "$slug" && continue        # already stepped via the other leg  # pipe-ok: bounded membership list, under a pipe buffer
    seen="${seen}${slug}"$'\n'
    # Provenance: this slug came from the engine's OWN tab registry or its OWN slug-keyed marker.
    _retire_step "$slug" "" "" 0 "$prov"
  done < <(_retire_registry_slugs | sed 's/^/registry /'; _retire_residual_slugs | sed 's/^/residual /')

  # ── leg D: a landed slug whose only residue is its local BRANCH ──
  # A teardown that got as far as removing the worktree, the tabs, AND the ledgers (HERD-91's one-shot
  # startup sweep does exactly that) leaves nothing for legs A–C to see, yet the branch is still there.
  # The reap ledger remembers every slug herdkit merged, so it is the discovery key of last resort.
  # Scoped hard: only ledger slugs, only under DELETE_BRANCH_ON_MERGE, and only when a MERGED PR
  # provably contains the branch. An operator's own `feat/…` branch is not in the ledger and is never
  # considered; an unprovable one is left alone in silence, never held, never red.
  _retire_branch_reapable || return 0
  while IFS= read -r slug; do
    [ -n "${slug:-}" ] || continue
    printf '%s' "$wt_slugs" | grep -qxF "$slug" && continue  # pipe-ok: bounded membership list, under a pipe buffer
    printf '%s' "$open_slugs" | grep -qxF "$slug" && continue  # pipe-ok: bounded membership list, under a pipe buffer
    printf '%s' "$seen" | grep -qxF "$slug" && continue  # pipe-ok: bounded membership list, under a pipe buffer
    _retire_merged_branch_slug "$slug" || continue
    seen="${seen}${slug}"$'\n'
    _retire_step "$slug" "" "" 0 ledger
  done < <(_retire_ledger_slugs)
  return 0
}

# _retire_step <slug> <dir> <branch> <open-pr> [provenance] — reconcile ONE slug. Split out of
# retirement_tick so every leg shares it verbatim and the unit tests can drive a single slug.
# <provenance> names WHICH leg found it (worktree|registry|residual|ledger); the worktree-gone classifier
# refuses to act without one, so an orphan can never be torn down on a slug nobody can show we created.
_retire_step() {
  local slug="$1" dir="${2:-}" branch="${3:-}" open="${4:-0}" prov="${5:-}"
  local state pr sha detail left blocker

  # The classifier may DISCOVER the branch (the orphan path, where the caller has none), so read it
  # back: it is what the teardown deletes and what `retire_leftovers` then re-checks.
  #
  # The record separator is \x1f, NOT a tab. Tab is an IFS WHITESPACE character, so `IFS=$'\t' read`
  # collapses a RUN of consecutive tabs into one delimiter and strips leading/trailing ones — which
  # shifts every field left on exactly the records the orphan path emits (empty <pr>/<sha>). That put
  # prose into $pr, emptied $detail (a red needs-you row carrying no evidence), and left $branch empty
  # so the branch was never reaped even as the slug reported "converged". \x1f is not IFS whitespace,
  # so empty fields survive. Same separator _sweep_worktree_rows already uses for the same reason.
  IFS=$'\x1f' read -r state pr sha detail branch <<EOF
$(retire_classify "$slug" "$dir" "$branch" "$open" "$prov")
EOF
  # Defense in depth: only a NUMERIC pr ever reaches the PR-keyed ledgers or the journal. If a record
  # shape ever shifts again, this refuses to purge another PR's state on a parse artifact.
  case "${pr:-}" in ''|*[!0-9]*) pr="" ;; esac

  case "$state" in
    active)
      _retire_state_clear "$slug"
      return 0 ;;
    held)
      # Persist the escalation state even though nothing is torn down. It is what keeps a HELD ORPHAN
      # discoverable: its worktree, tab, and .herd-ref are already gone, so `.retire-<slug>` is the last
      # key leg C has. Without it the red row renders once and then goes silent forever while the branch
      # it is protecting sits there unnoticed.
      _retire_state_bump "$slug" held
      _retire_note_once "$slug" hold "$detail"
      _retire_record "$slug" held "$detail" "$dir"
      return 0 ;;
  esac

  # HELD → RETIRING is a FRESH teardown, not a continuation of a stuck one. A held slug bumps the
  # escalation counter every tick it is held (that is what keeps it discoverable), so a human who cures
  # the hold by DISCARDING dirt — HEAD stays at the merged sha, the tree goes clean — would otherwise
  # land on a counter already past _RETIRE_STUCK_TICKS and see a red 'retirement stuck' row on the very
  # first converging tick. That contradicts this file's own contract ("a single failed tick is never
  # red") and the no-false-red-consoles rule. Reset the counter on the transition and restore the grace.
  # (Curing by COMMIT needs no such care: HEAD moves, the anchor fails, the slug goes active.)
  [ "$(_retire_last_left "$slug")" = held ] && _retire_state_clear "$slug"

  # retiring: drive teardown, then re-observe the world. Both halves are idempotent.
  local had_wt=0; [ -n "$dir" ] && [ -d "$dir" ] && had_wt=1
  retire_converge "$slug" "$dir" "$pr" "$sha" "$branch" "retire-${detail:-terminal}"
  [ "$had_wt" = "1" ] && [ ! -d "$dir" ] && RETIRE_REAPED=$(( RETIRE_REAPED + 1 ))

  left="$(retire_leftovers "$slug" "$dir" "$branch" | tr '\n' ',' | sed 's/,$//')"
  if [ -z "$left" ]; then
    # Converged. The slug's row vanishes; nothing is remembered. Journal it ALWAYS, not only when the
    # slug had previously failed to converge — a teardown that runs and completes on its first tick is
    # exactly the event a post-mortem of an unexpected reap needs to find.
    journal_append retire_converged slug "$slug" pr "$pr" reason "$detail"
    _retire_state_clear "$slug"
    return 0
  fi

  _retire_state_bump "$slug" "$left"
  blocker="${left%%,*}"
  if [ "$(_retire_attempts "$slug")" -ge "$_RETIRE_STUCK_TICKS" ]; then
    _retire_note_once "$slug" stuck "$blocker"
    _retire_record "$slug" stuck "$blocker" "$dir"
  else
    _retire_record "$slug" retiring "$left" "$dir"
  fi
  return 0
}
