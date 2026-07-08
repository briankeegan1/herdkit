#!/usr/bin/env bash
# .herd/healthcheck.project.sh — herdkit's OWN health command (the dogfood gate).
# Called by scripts/herd/healthcheck.sh for the heavy profile:
#     .herd/healthcheck.project.sh <worktree-dir> [--oneline]
#
# herdkit has no app — health = the scripts are syntactically sound and the tests pass:
#   1) bash -n over every engine + CLI script               (always available; the hard gate)
#   2) shellcheck over them IF installed                    (best-effort lint)
#   3) the hermetic test suite (tests/*.sh) + bats IF present
#
# CONTRACT: exit 0 = clean · 1 = code error · 2 = data/env (tolerated). herdkit's only data/env axis
# is one KNOWN env-only bats failure (HERD-187): the project-mode codemap test failing because the real
# repo can't be resolved as the ENGINE tree (a mis-pointed .herd/config PROJECT_ROOT) → exit 2. Every
# other outcome is 0 or 1; a genuine code error is NEVER downgraded to 2.
set -u
DIR="${1:?usage: healthcheck.project.sh <worktree-dir> [--oneline]}"
ONELINE=""; [ "${2:-}" = "--oneline" ] && ONELINE=1
cd "$DIR" 2>/dev/null || { echo "no such dir: $DIR"; exit 1; }

# Resolve python3 ONCE (mirrors scripts/herd/healthcheck.sh) instead of calling bare `python3` in the
# leak-guard helpers below: on Git Bash python3 is a Windows AppData install that a bare name may not
# resolve, so pin the absolute interpreter. The leak-guard only runs when herdr is present anyway.
PY="$(command -v python3 || true)"

errs=""

# 1. bash -n over all shell scripts (engine + CLI + tests + templates).
while IFS= read -r f; do
  [ -n "$f" ] || continue
  e="$(bash -n "$f" 2>&1)" || errs="${errs}bash -n $f → $(printf '%s' "$e" | tail -1)"$'\n'
done < <(
  { find scripts bin templates tests -type f -name '*.sh' 2>/dev/null
    [ -f bin/herd ] && echo bin/herd; } | sort -u
)

if [ -n "$errs" ]; then
  [ -n "$ONELINE" ] && echo "syntax: $(printf '%s' "$errs" | head -1)" || { echo "SYNTAX ERROR"; printf '%s' "$errs"; }
  exit 1
fi

# 2. shellcheck (best-effort lint — only fail on errors, not style).
sc_note="shellcheck: skipped (not installed)"
if command -v shellcheck >/dev/null 2>&1; then
  if sc="$(shellcheck -S error scripts/herd/*.sh scripts/herd/backends/*.sh bin/herd 2>&1)"; then
    sc_note="shellcheck: clean"
  else
    [ -n "$ONELINE" ] && echo "shellcheck: $(printf '%s' "$sc" | head -1)" || { echo "SHELLCHECK ERRORS"; printf '%s\n' "$sc"; }
    exit 1
  fi
fi

# 3. Tests — bats if present, else run the hermetic *.sh tests directly.
#
# HERMETICITY LEAK-GUARD: a hermetic test must NEVER create a real tab/pane in the user's LIVE
# herdr workspace. We snapshot the live inventory before and after the suite and FAIL LOUDLY if
# the suite leaves a new ORPHAN tab behind. This is exactly the class of bug that let a stray
# 'review·<slug>' tab (with an orphaned 'tail -f') leak from test-review-pane-v2.sh scenario 4
# and perpetually reappear on every full-suite run. Skipped when herdr is not installed.
#
# WHY ORPHANS, not "any tab delta": this workspace is SHARED with real running agents. During the
# tens of seconds the suite runs, the live coordinator/watcher legitimately spawns and reaps real
# lane tabs (scribe-*, coordinator-*, feature slugs) and close+recreates tabs on gate cycles — a
# raw before/after tab diff false-fails on that churn. But every real lane tab is AGENT-BACKED:
# its agent_status is 'idle' or 'working'. A tab leaked by a hermetic test that escaped its stubs
# is an ORPHAN — herd-review.sh's standalone fallback creates a bare tab running 'tail -f' with NO
# controlling agent, so its agent_status is 'unknown' (or missing). So we count only ORPHAN tabs
# (status not idle/working) and their panes, and fail only on a NET INCREASE. Watcher recreates of
# an existing orphan net to zero; real lane churn never touches the orphan count. This is immune to
# concurrent activity while still catching the exact leak this PR fixes. SCOPING (issue #78): the scan
# is restricted to THIS project's OWN herdr workspace (WORKSPACE_NAME → workspace_id) so an orphan in a
# SIBLING project's workspace — or any other workspace entirely — never trips this guard; only a tab
# leaked into OUR workspace counts. ENGINE WHITELIST (HERD-51): status idle/working is necessary but
# not sufficient — a concurrent engine tab (resolve·*, scribe-*, research*, herd-watch*/backlog*/
# coordinator*) spawned by unrelated activity can be caught mid-spawn in 'unknown'/'blocked' and, by
# status alone, look like a net-new orphan (three real false-reds, incl. PR #162's resolve·codemap-
# freshness). _hk_orphans() therefore also drops any tab whose LABEL matches that known-engine
# whitelist from the orphan set, symmetrically in both snapshots.
#
# DEFLAKE (HERD-93): two further mitigations kill the last recurring false-red — the guard reddening
# on normal control-room churn (builder/review/scribe tabs flipping state mid-suite is EXPECTED on a
# busy day), which cost a wasted full-suite run + retry on most busy-day PRs:
#   (a) .herd-tabs REGISTRATION WHITELIST — every engine-minted tab (builder/review·/resolve·) is
#       recorded by tab_id in $WORKTREES_DIR/.herd-tabs when the engine spawns it. _hk_orphans() drops
#       any tab whose tab_id is registered there, so a legit watcher-spawned review·<slug> tab (the
#       LABEL whitelist above does NOT cover 'review·') no longer trips the guard. This is an EXACT
#       tab_id match, read fresh at each snapshot, so it never masks a hermetic test's escaped tab: a
#       leaked tab is created outside the engine and is NOT in the registry, so it still reds.
#   (b) SETTLE-RETRY — a leak detected on the first post-suite snapshot may be transient churn (a tab
#       caught mid-spawn/mid-reap or a state flip). Before reddening we sleep a short settle window
#       (HERD_LEAKGUARD_SETTLE_SECS, default 4s) and re-snapshot; we red ONLY if the leak is STILL
#       present. Transient churn clears; a genuinely leaked, agent-less tab persists and re-trips.
#   (c) WORKTREE-SLUG WHITELIST (HERD-115) — the .herd-tabs registration whitelist (a) covers the
#       IN-TAB run, but the WATCHER invokes this suite against a live builder worktree where that
#       registry is not always resolvable at snapshot time, so an in-flight builder's OWN tab — whose
#       LABEL is its worktree slug (the slug keys worktrees, agent names AND tab labels alike) — flips
#       out of idle/working mid-suite and is counted as a net-new orphan. Every watcher-side
#       healthcheck for PRs #217/#218/#219 hit exactly this ("new: <the PR's own builder tab>"),
#       reddening attempt=1 then settling FLAKY. We therefore derive an additional whitelist from the
#       LIVE worktree slugs ('git worktree list', basename of each) at suite start — INVOCATION-ORIGIN
#       INDEPENDENT, since every worktree shares one .git and lists them all — and drop any tab whose
#       LABEL matches a live slug. A FOREIGN leaked tab carries no live-worktree label, so it still reds.
# All three preserve no-false-green: a real leak is neither engine-registered, transient, nor labelled
# with a live worktree slug, so it reds.
_hk_workspace_id() {
  # Resolve THIS project's herdr workspace id (WORKSPACE_NAME → workspace_id via 'herdr workspace
  # list'). Prints the id (no trailing newline) on success; empty when herdr is absent, the list
  # call fails, or WORKSPACE_NAME is unset/unmatched (e.g. coordinator has not created the workspace
  # yet). Used to SCOPE the orphan scan below to our OWN workspace only (issue #78).
  command -v herdr >/dev/null 2>&1 || return 0
  local _ws=""
  [ -f .herd/config ] && _ws="$(. .herd/config 2>/dev/null && printf '%s' "${WORKSPACE_NAME:-}")"
  [ -n "$_ws" ] || return 0
  herdr workspace list 2>/dev/null | LABEL="$_ws" "$PY" -c '
import sys, json, os
try:
    wss = (json.load(sys.stdin).get("result") or {}).get("workspaces") or []
    print(next((str(w.get("workspace_id", "")) for w in wss
                if str(w.get("label", "")) == os.environ["LABEL"]), ""), end="")
except Exception:
    pass
' 2>/dev/null || true
}

_hk_regtabs() {
  # Emit the tab_ids the engine has REGISTERED in $WORKTREES_DIR/.herd-tabs, one per line — the
  # builder/review·/resolve· tabs it minted and owns (field 2 of each '<label> <tab_id> <kind>' row).
  # These are engine-created expected churn, so _hk_orphans() drops them from the orphan set (HERD-93
  # registration whitelist). Read FRESH at each snapshot so a review·<slug> tab the watcher registers
  # mid-suite is honored. Empty when WORKTREES_DIR is unset or the registry does not exist yet.
  local _tree=""
  [ -f .herd/config ] && _tree="$(. .herd/config 2>/dev/null && printf '%s' "${WORKTREES_DIR:-}")"
  [ -n "$_tree" ] && [ -f "$_tree/.herd-tabs" ] || return 0
  awk 'NF>=2 {print $2}' "$_tree/.herd-tabs" 2>/dev/null || true
}

_hk_worktree_slugs() {
  # HERD-115 worktree-slug whitelist: emit the LIVE feature-worktree slugs, one per line — the
  # basename of every 'git worktree list' path. An in-flight builder's OWN tab carries its worktree
  # slug as its LABEL, so a tab whose label matches a live slug is that builder's own tab, NOT a suite
  # leak — _hk_orphans() drops it from the orphan set. Unlike the .herd-tabs registry (a), this is
  # INVOCATION-ORIGIN INDEPENDENT: every worktree shares one .git, so 'git worktree list' enumerates
  # them all whether the suite runs in-tab or via the watcher against a builder worktree. Empty when
  # git is absent or this is not a git checkout (fail-soft → falls back to the (a)/(b) mitigations).
  command -v git >/dev/null 2>&1 || return 0
  git worktree list --porcelain 2>/dev/null | "$PY" -c '
import sys, os
for line in sys.stdin:
    if line.startswith("worktree "):
        p = line[len("worktree "):].strip()
        if p:
            print(os.path.basename(p))
' 2>/dev/null || true
}

_hk_orphans() {
  # Emits 'orphan-tabs:<N>' and 'orphan-panes:<M>' — N = live tabs with no controlling agent
  # (agent_status not in idle/working), M = their combined pane_count. Empty when herdr absent.
  # SCOPED to $1 (this project's workspace id) when non-empty, so orphans in a SIBLING project's
  # workspace are never counted (issue #78); falls back to ALL workspaces when $1 is empty (herdr
  # present but our workspace unresolved — no worse than the pre-#78 behaviour). Read-only; never
  # mutates the workspace.
  #
  # ENGINE-LABEL WHITELIST (HERD-51): a legitimate engine tab spawned CONCURRENTLY by unrelated
  # activity during the suite window — a resolve·<slug> conflict-resolver, a scribe-* drainer, a
  # research/researcher drainer, or a control-room pane (herd-watch*/backlog*/coordinator*) — can be
  # caught mid-spawn in an 'unknown'/'blocked' state and, by the raw status test alone, would count
  # as a net-new orphan and false-red the guard (three real false-reds to date, incl. PR #162's
  # "resolve·codemap-freshness"). We EXCLUDE tabs whose label matches this whitelist from the orphan
  # set — symmetrically, in BOTH the before and after snapshots, since this one function computes
  # both — so concurrent engine churn never skews the diff. A genuinely suite-leaked, agent-less tab
  # (label NOT matching the whitelist, e.g. herd-review's standalone review·<slug> running tail -f)
  # is still an orphan and still reds.
  command -v herdr >/dev/null 2>&1 || return 0
  herdr tab list 2>/dev/null | WSID="${1:-}" REGTABS="$(_hk_regtabs)" WLSLUGS="${2:-}" "$PY" -c '
import sys, json, os, re
# Known engine tab/agent label prefixes. The character after "resolve" is a literal middot
# U+00B7 (the label is "resolve·<slug>"), matching the engine that mints those tabs. "research"
# also covers "researcher"/"research·*".
_ENGINE = re.compile(r"^(scribe-|resolve·|research|herd-watch|backlog|coordinator)")
# HERD-93 registration whitelist: tab_ids the engine recorded in .herd-tabs (builder/review·/resolve·)
# are engine-owned expected churn — drop them from the orphan set. EXACT match, so a hermetic test'"'"'s
# escaped tab (never engine-registered) still counts as an orphan and still reds.
_REGTABS = set(filter(None, (os.environ.get("REGTABS", "") or "").split()))
# HERD-115 worktree-slug whitelist: labels matching a LIVE worktree slug are in-flight builders own
# tabs — drop them so a builder tab flipped out of idle/working mid-suite is never counted as a leak
# in the watcher path. A FOREIGN leaked tab has no live-worktree label, so it still reds (no false-
# green). Newline-separated, EXACT match on the full label.
_WLSLUGS = set(filter(None, (os.environ.get("WLSLUGS", "") or "").splitlines()))
try:
    tabs = (json.load(sys.stdin).get("result") or {}).get("tabs") or []
    wsid = os.environ.get("WSID", "")
    if wsid:
        # Scope to THIS project workspace — ignore tabs owned by any other workspace.
        tabs = [t for t in tabs if str(t.get("workspace_id", "")) == wsid]
    orphans = [t for t in tabs
               if str(t.get("agent_status", "")) not in ("idle", "working")
               and not _ENGINE.match(str(t.get("label", "")))
               and str(t.get("tab_id", "")) not in _REGTABS
               and str(t.get("label", "")) not in _WLSLUGS]
    print("orphan-tabs:%d" % len(orphans))
    print("orphan-panes:%d" % sum(int(t.get("pane_count", 0) or 0) for t in orphans))
    # Emit the orphan labels too so a real leak can be named in the failure message.
    for lbl in sorted(str(t.get("label", "")) for t in orphans):
        print("orphan-label:" + lbl)
except Exception:
    pass
' 2>/dev/null || true
}

_hk_leak_delta() {
  # Print a non-empty leak description IFF the AFTER snapshot ($2) shows MORE orphan tabs or panes
  # than the BEFORE snapshot ($1); empty (clean) otherwise. Shared by the initial check and the
  # settle-retry re-check so both use identical delta semantics.
  BEF="$1" AFT="$2" "$PY" -c '
import os
def parse(s):
    tabs = panes = 0
    labels = []
    for line in s.splitlines():
        if line.startswith("orphan-tabs:"):  tabs  = int(line.split(":",1)[1] or 0)
        elif line.startswith("orphan-panes:"): panes = int(line.split(":",1)[1] or 0)
        elif line.startswith("orphan-label:"): labels.append(line.split(":",1)[1])
    return tabs, panes, labels
bt, bp, bl = parse(os.environ["BEF"])
at, ap, al = parse(os.environ["AFT"])
if at > bt or ap > bp:
    # Name the orphan label(s) present after but not before, best-effort.
    from collections import Counter
    new = list((Counter(al) - Counter(bl)).elements())
    print("orphan tabs %d->%d, orphan panes %d->%d%s" % (
        bt, at, bp, ap, (" — new: " + ", ".join(sorted(new))) if new else ""))
' 2>/dev/null || true
}
# Resolve our workspace ONCE and reuse it for both the before and after snapshots, so the two are
# scoped identically (issue #78 — the scan must never count another workspace's or sibling project's
# tab, in either snapshot).
_hk_wsid="$(_hk_workspace_id)"
# HERD-115: derive the live worktree-slug whitelist ONCE at suite start and reuse it for both the
# before and after snapshots, so an in-flight builder's own tab is dropped identically in both.
_hk_wtslugs="$(_hk_worktree_slugs)"
_hk_orphans_before="$(_hk_orphans "$_hk_wsid" "$_hk_wtslugs")"

# ── ENV-vs-CODE bats classification (HERD-187) ────────────────────────────────────────────────
# A failing bats run is a CODE error (exit 1) by default — EXCEPT one KNOWN data/env condition that
# must be TOLERATED (exit 2) instead of blocking merges: the project-mode codemap test failing because
# the REAL repo can't be resolved as the herdkit ENGINE tree (e.g. .herd/config PROJECT_ROOT points at
# a path that is NOT this engine checkout, so codemap.sh maps it as a PROJECT). That is an ENV
# misconfiguration of the box, not a code bug — today it returned CODEERROR(1) and blocked merges.
# We NEVER downgrade a genuine code error: the tolerance applies ONLY when (a) the codemap test is the
# SOLE failing test AND (b) re-running it confirms the failure is the real-repo/ENGINE (env-dependent)
# assertion — NOT a hermetic-fixture assertion, which would be a real codemap.sh regression and stays
# exit 1. When there is no env-only failure, behaviour is byte-identical to before.
_HK_ENV_TEST="hermetic project-mode codemap test passes"

_hk_bats_notok() {
  # Emit the description of every failing test in bats TAP output ($1) — the text after 'not ok N '.
  printf '%s\n' "$1" | sed -n 's/^not ok [0-9][0-9]* //p'
}

_hk_bats_notok_line() {
  # Emit the FULL 'not ok N <desc>' line whose description contains $2 — the REAL failing line to quote
  # in the detail, NOT the adjacent diagnostic comment / next 'ok' that a bare `tail -1` used to grab.
  printf '%s\n' "$1" | grep -E "^not ok [0-9]+ .*$2" | head -1
}

_hk_codemap_failure_is_env() {
  # Confirm the codemap test's failure is the ENV-dependent real-repo/ENGINE assertion (tolerable),
  # NOT a hermetic-fixture regression (a genuine codemap.sh code bug). Re-run the test directly:
  #   • it now PASSES          → the bats failure was not this / transient → treat as genuine (return 1)
  #   • fails with a real-repo/ENGINE message (all hermetic assertions passed first, since fail() exits
  #     at the first failure)  → env-dependent (return 0)
  #   • fails on anything else → genuine codemap regression → return 1 (never downgrade a code error)
  local t="tests/test-codemap-project.sh" o
  [ -f "$t" ] || return 1
  o="$(bash "$t" 2>&1)" && return 1
  printf '%s\n' "$o" | grep -qiE 'FAIL:.*real.?repo'
}

_hk_bats_env_only() {
  # Return 0 IFF the bats failure ($1) is EXACTLY the tolerated env condition: the codemap test is the
  # ONLY failing test AND its failure is confirmed env-dependent. Any other failing test, or an
  # absent/unparseable failure, is genuine (return 1) — we never downgrade a real code error.
  local to="$1" descs saw_env=0 other=0 f
  descs="$(_hk_bats_notok "$to")"
  [ -n "$descs" ] || return 1
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if [ "$f" = "$_HK_ENV_TEST" ]; then saw_env=1; else other=1; fi
  done <<EOF
$descs
EOF
  [ "$saw_env" -eq 1 ] && [ "$other" -eq 0 ] || return 1
  _hk_codemap_failure_is_env
}

# ── HERD-189 DAEMON-HERMETICITY SANDBOX ──────────────────────────────────────────────────────────
# No test may launch a real watcher/daemon/agent against the live control room. We run the WHOLE suite
# with the live agent-spawn surface (herdr/claude/codex) shadowed by benign tripwire stubs that RECORD
# (never break) any reach, and with HERD_HERMETIC_GUARD armed so any watcher a test spawns records the
# leak and EXITS at agent-watch.sh's choke point instead of running a real daemon. A non-empty log ⇒ a
# test touched the live workspace or spawned a real daemon. The stubs shadow ONLY the suite subshell
# (inline env on the run command), so the tab-leak snapshots above/below still use the REAL herdr.
# Kept IN LOCKSTEP with tests/test-daemon-hermeticity.sh (which self-tests this guard). INERT if a tmp
# dir can't be made (falls back to the pre-HERD-189 unsandboxed run).
_hk_dh_dir="$(mktemp -d 2>/dev/null || echo '')"
_hk_dh_log=""; _hk_dh_pp=""
if [ -n "$_hk_dh_dir" ]; then
  _hk_dh_log="$_hk_dh_dir/leaks.log"; mkdir -p "$_hk_dh_dir/bin"; : > "$_hk_dh_log"
  for _dhc in herdr claude codex; do
    { printf '#!/usr/bin/env bash\n'
      printf 'printf '\''%%s\\t%%s\\t%%s\\n'\'' "${HERMETIC_TEST:-suite}" "%s" "$*" >> "%s"\n' "$_dhc" "$_hk_dh_log"
      case "$_dhc" in herdr) printf 'echo '\''{}'\''\n' ;; claude) printf 'echo '\''claude 0.0.0'\''\n' ;; esac
      printf 'exit 0\n'; } > "$_hk_dh_dir/bin/$_dhc"
    chmod +x "$_hk_dh_dir/bin/$_dhc"
  done
  _hk_dh_pp="$_hk_dh_dir/bin:"
fi
dh_note="daemon-hermeticity: clean"

_hk_dh_verdict() {
  # A non-empty leak log ⇒ a test reached the live control room or spawned a real daemon. This is a
  # HARD code error (exit 1), NEVER downgraded to the HERD-187 env-only tolerance — so it is checked
  # BEFORE the env classification. Cleans up the sandbox dir on the way out (leak or clean).
  if [ -n "$_hk_dh_log" ] && [ -s "$_hk_dh_log" ]; then
    if [ -n "$ONELINE" ]; then
      echo "daemon-hermeticity: a test touched the live control room / spawned a real daemon — $(sort -u "$_hk_dh_log" | head -1)"
    else
      echo "DAEMON-HERMETICITY: a test reached the LIVE control room or spawned a real watcher/daemon"
      echo "  (a hermetic test must stub herdr/claude and never launch agent-watch.sh against real state)"
      sort -u "$_hk_dh_log" | sed 's/^/  leak: /'
    fi
    rm -rf "$_hk_dh_dir"
    exit 1
  fi
  [ -n "$_hk_dh_dir" ] && rm -rf "$_hk_dh_dir"
}

# ── HERD-192 PER-TEST TIMEOUT + NO-TTY STDIN ─────────────────────────────────────────────────────
# A single test that hangs must become a FAST, NAMED failure — never a silent multi-hour hang that
# leaks watchers (the 'hermetic cli backend-switch' test once read /dev/tty in a backgrounded suite
# and hung 63 min before it was killed by hand). Two defenses, applied to EVERY bats/suite run below:
#   (1) BATS_TEST_TIMEOUT — bats-core (≥1.5, here 1.13) natively kills any single test exceeding this
#       many seconds and reports THAT test's name, so a hang turns into one fast named failure. The
#       slowest legit test measured ~5.5s, so 60s is generous headroom yet still bounds a true hang
#       to a minute. Overridable: export BATS_TEST_TIMEOUT=<n> to raise/lower it.
#   (2) stdin from /dev/null — a backgrounded gate has no controlling terminal, so a test that reads
#       /dev/tty would block forever; /dev/null gives it immediate EOF instead. Also wraps the
#       hermetic *.sh suite (which bats itself is unavailable) in `timeout` for the same per-test bound.
# Byte-identical for a normal fast suite: nothing changes unless a test would otherwise hang.
export BATS_TEST_TIMEOUT="${BATS_TEST_TIMEOUT:-60}"
_hk_suite_timeout=""
command -v timeout >/dev/null 2>&1 && _hk_suite_timeout="timeout ${BATS_TEST_TIMEOUT}"

t_note="tests: none"
if command -v bats >/dev/null 2>&1 && ls tests/*.bats >/dev/null 2>&1; then
  to="$(PATH="${_hk_dh_pp}$PATH" HERD_HERMETIC_GUARD="$_hk_dh_log" BATS_TEST_TIMEOUT="$BATS_TEST_TIMEOUT" bats tests/*.bats </dev/null 2>&1)" && _hk_bats_rc=0 || _hk_bats_rc=$?
  _hk_dh_verdict   # HERD-189: a daemon leak fails HARD, before the HERD-187 env-only tolerance below
  if [ "$_hk_bats_rc" -eq 0 ]; then
    t_note="tests: bats pass"
  elif _hk_bats_env_only "$to"; then
    # KNOWN data/env condition (HERD-187): tolerated → exit 2, quoting the REAL failing 'not ok' line.
    _hk_notok="$(_hk_bats_notok_line "$to" "$_HK_ENV_TEST")"
    if [ -n "$ONELINE" ]; then
      echo "bats: env-only data/env (not a code bug) — $_hk_notok"
    else
      echo "BATS: DATA/ENV FAILURE (tolerated, not a code bug)"
      echo "  $_hk_notok"
      echo "  ($_HK_ENV_TEST — the real repo did not resolve as the herdkit ENGINE tree"
      echo "   (e.g. .herd/config PROJECT_ROOT is not this engine checkout); env, not code.)"
      printf '%s\n' "$to"
    fi
    exit 2
  else
    # Genuine code error — original behaviour (byte-identical when there is no env-only failure).
    [ -n "$ONELINE" ] && echo "bats: $(printf '%s' "$to" | tail -1)" || { echo "BATS FAILED"; printf '%s\n' "$to"; }
    exit 1
  fi
elif ls tests/test-*.sh >/dev/null 2>&1; then
  fails=0
  for t in tests/test-*.sh; do PATH="${_hk_dh_pp}$PATH" HERD_HERMETIC_GUARD="$_hk_dh_log" HERMETIC_TEST="$(basename "$t")" $_hk_suite_timeout bash "$t" </dev/null >/dev/null 2>&1 || fails=$((fails+1)); done
  _hk_dh_verdict
  if [ "$fails" -eq 0 ]; then t_note="tests: hermetic suite pass"; else
    [ -n "$ONELINE" ] && echo "tests: $fails failed" || echo "TESTS FAILED: $fails"
    exit 1
  fi
else
  _hk_dh_verdict
fi

# Leak-guard verdict: fail LOUDLY on a NET INCREASE in orphan tabs or orphan panes.
leak_note="tab-leak-guard: clean"
if command -v herdr >/dev/null 2>&1; then
  _hk_orphans_after="$(_hk_orphans "$_hk_wsid" "$_hk_wtslugs")"
  _hk_leak="$(_hk_leak_delta "$_hk_orphans_before" "$_hk_orphans_after")"
  if [ -n "$_hk_leak" ]; then
    # SETTLE-RETRY (HERD-93): a leak on the FIRST post-suite snapshot may be transient control-room
    # churn (a tab caught mid-spawn/mid-reap or a state flip) rather than a real suite leak. Sleep a
    # short settle window and re-snapshot; keep the red ONLY if the leak is STILL present. Transient
    # churn clears within the window; a genuinely leaked, agent-less tab persists and re-trips. The
    # settle delay is HERD_LEAKGUARD_SETTLE_SECS (default 4s; set 0 in hermetic tests to skip the wait).
    _hk_settle="${HERD_LEAKGUARD_SETTLE_SECS:-4}"
    case "$_hk_settle" in ''|*[!0-9]*) _hk_settle=4 ;; esac
    [ "$_hk_settle" -gt 0 ] && sleep "$_hk_settle"
    _hk_orphans_after="$(_hk_orphans "$_hk_wsid" "$_hk_wtslugs")"
    _hk_leak="$(_hk_leak_delta "$_hk_orphans_before" "$_hk_orphans_after")"
  fi
  if [ -n "$_hk_leak" ]; then
    if [ -n "$ONELINE" ]; then
      echo "tab-leak-guard: suite leaked an orphan tab into the live workspace — $_hk_leak"
    else
      echo "TAB-LEAK-GUARD: the test suite left an orphan tab/pane in the live workspace"
      echo "  (a hermetic test escaped its stubs and created a real, agent-less herdr tab)"
      echo "  $_hk_leak"
    fi
    exit 1
  fi
else
  leak_note="tab-leak-guard: skipped (herdr not installed)"
fi

# 4. leak-guard — no single-consumer (Northstar) literal may leak into the generic engine.
# The pattern list lives HERE in .herd/ (outside the scanned surface: scripts/herd + bin/herd +
# templates), so this guard never matches itself. The documented generic placeholder
# "$HOME/source/myproject" in templates/config.example is allowed; everything else under
# $HOME/source/ is a hardcoded leak.
lg_note="leak-guard: clean"
leak_pat='northstar|/Users/macbookpro|\$HOME/source/|streamlit|app/dashboard\.py'
leak_files=()
while IFS= read -r f; do [ -n "$f" ] && leak_files+=("$f"); done < <(
  { find scripts/herd -type f 2>/dev/null
    [ -f bin/herd ] && echo bin/herd
    find templates -type f 2>/dev/null; } | sort -u
)
if [ "${#leak_files[@]}" -gt 0 ]; then
  if hits="$(grep -HinE "$leak_pat" "${leak_files[@]}" 2>/dev/null | grep -vE '\$HOME/source/myproject')"; then
    [ -n "$ONELINE" ] && echo "leak-guard: $(printf '%s' "$hits" | head -1)" \
      || { echo "LEAK-GUARD: single-consumer literal in generic engine"; printf '%s\n' "$hits"; }
    exit 1
  fi
fi

# 5. caps-sync guard — a PR adding a cmd_* subcommand to bin/herd, a new config key to
# herd-config.sh, or a new lane script under scripts/herd/ without also touching
# templates/capabilities.tsv is a CODE error (the manifest must stay in sync).
caps_note="caps-sync: clean"
_hc_branch="origin/main"
if [ -f .herd/config ]; then
  _hc_branch="$(. .herd/config 2>/dev/null && printf '%s' "${DEFAULT_BRANCH:-origin/main}")" \
    || _hc_branch="origin/main"
fi
if _hc_changed="$(git diff --name-only "$_hc_branch" 2>/dev/null)"; then
  _hc_manifest_touched=0
  case "$_hc_changed" in *"templates/capabilities.tsv"*) _hc_manifest_touched=1 ;; esac
  _hc_sync_errs=""

  if printf '%s\n' "$_hc_changed" | grep -qxE 'bin/herd'; then
    _hc_new_cmds="$(git diff "$_hc_branch" -- bin/herd 2>/dev/null \
      | grep -E '^\+[[:space:]]*cmd_[a-z_]+\(\)' || true)"
    if [ -n "$_hc_new_cmds" ] && [ "$_hc_manifest_touched" -eq 0 ]; then
      _hc_sync_errs="${_hc_sync_errs}bin/herd adds cmd_*: also update templates/capabilities.tsv"$'\n'
    fi
  fi

  if printf '%s\n' "$_hc_changed" | grep -qxE 'scripts/herd/herd-config\.sh'; then
    _hc_new_keys="$(git diff "$_hc_branch" -- scripts/herd/herd-config.sh 2>/dev/null \
      | grep -E '^\+[[:space:]]*:[[:space:]]+"?\$\{[A-Z_]+:=' || true)"
    if [ -n "$_hc_new_keys" ] && [ "$_hc_manifest_touched" -eq 0 ]; then
      _hc_sync_errs="${_hc_sync_errs}herd-config.sh adds config keys: also update templates/capabilities.tsv"$'\n'
    fi
  fi

  _hc_added_lanes="$(git diff --diff-filter=A --name-only "$_hc_branch" 2>/dev/null \
    | grep -Ex 'scripts/herd/[^/]+\.sh' | grep -vxE 'scripts/herd/herd-config\.sh' || true)"
  if [ -n "$_hc_added_lanes" ] && [ "$_hc_manifest_touched" -eq 0 ]; then
    _hc_sync_errs="${_hc_sync_errs}new lane script added: also update templates/capabilities.tsv"$'\n'
  fi

  if [ -n "$_hc_sync_errs" ]; then
    caps_note="caps-sync: VIOLATION"
    if [ -n "$ONELINE" ]; then
      echo "caps-sync: $(printf '%s' "$_hc_sync_errs" | head -1)"
    else
      echo "CAPS-SYNC: capabilities manifest not updated alongside engine change"
      printf '%s' "$_hc_sync_errs"
    fi
    exit 1
  fi
else
  caps_note="caps-sync: skipped (no diff against $_hc_branch)"
fi

[ -n "$ONELINE" ] && echo "clean — bash -n ok; $sc_note; $t_note; $dh_note; $leak_note; $lg_note; $caps_note" || { echo "HEALTHCHECK CLEAN"; echo "  $sc_note"; echo "  $t_note"; echo "  $dh_note"; echo "  $leak_note"; echo "  $lg_note"; echo "  $caps_note"; }
exit 0
