#!/usr/bin/env bash
# journal-audit.sh — journal-driven self-audit / gap-finder (HERD-238 / N12).
#
# The problem: every incident in the 2026-07-09 gating-hardening audit was VISIBLE in the engine
# journal before a human noticed (stale MAIN RED 19h; pushed=no at 13:54Z; fixture events; a review
# dispatched with no verdict) — but NOTHING was reading the journal for invariant violations. This
# is the reconcile layer: a cadenced, ADVISORY auditor that replays a BOUNDED journal window and
# surfaces the known gap classes.
#
# Checks (the N12 set, plus the HERD-272 human-verify rule):
#   (a) merge without a later reap for the same pr (or slug)
#   (b) a *_dispatched event with no terminal outcome past a family TTL (heartbeat dispatches with
#       neither a pr nor a slug — e.g. engine_live_dispatched — are exempt; see HERD-607)
#   (c) a refix_bounce with no matching refix_wake_result (same pr + sha + round)
#   (d) a red state (main_health result=red) older than a TTL with no later green
#   (e) pushed=no never followed by a later pushed=yes (codemap/symbol_index refresh)
#   (i) a DETACHED shared checkout (HERD-336): a main_detached result=detected not cleared by a later
#       result=reattached — the coordinator checkout sat on a detached HEAD (the refresh-race corpse)
#   (f) known-fixture slugs (retiree / conv / stuck / hd — the HERD-223 pollution set)
#   (g) a MERGED PR whose body declares a HUMAN-VERIFY block but which carries NO sha-keyed approval
#       record. Such a PR merged with its declared manual steps never run. This is not hypothetical:
#       agent-watch.sh's `_pr_body` used to swallow gh's exit status, so any 5xx blip made an
#       unreadable body indistinguishable from "declares no block" — and an absent block means MERGE
#       (fixed in 65fe660 by making the rc three-valued). Every merge that predates that fix is
#       therefore unproven. Because the audit replays a journal WINDOW, one check serves both readings:
#       ONGOING, it re-examines each tick's fresh merges; RETROACTIVELY, a one-shot run with a widened
#       JOURNAL_AUDIT_WINDOW_SECS sweeps as far back as the journal reaches.
#
#       WHERE THE EVIDENCE LIVES. Not in the approval ledger: do_merge calls purge_pr_approvals the
#       instant a PR merges, dropping every row for it (HERD-90), so by the time this check sees a
#       merge the ledger says `none` for approved and fail-open merges alike — zero discriminating
#       power. The durable evidence is in this very journal, which nothing purges:
#         `approval_recorded pr=<pr> sha=<sha> state=approved`  — a human signed that sha off
#         `human_verify_policy pr=<pr> sha=<sha> policy=auto`   — HUMAN_VERIFY_POLICY=auto merged the
#                                                                 steps as informational, unsigned
#       The ledger is still consulted through approvals.sh (the seam herd-approve.sh writes), because a
#       purge that failed, or a merge journaled without a later purge, leaves a real row worth reading.
#       Evidence is the UNION; approval wins over hv-informed. A merge whose approval predates the
#       `approval_recorded` event (i.e. history older than this check) has no evidence anywhere and is
#       reported unproven — which is precisely what the retroactive sweep exists to surface.
#
# FINDINGS BECOME ACTIONS (HERD-544, JOURNAL_AUDIT_ACT — off by default):
#   Detection alone leaves the engine stuck in the seam between rails: every stall class that DOES
#   auto-resolve has an owner (refix, stale-base, wedge, dead-builder, limit-park, resurrect), but a
#   finding here has none — it renders and waits for a human. With JOURNAL_AUDIT_ACT=on each class is
#   routed to exactly ONE of three policies (the shipped mapping, `_ja_act_mapped` / `_ja_act_no_action_reason`
#   in the ACT section below — a class never falls through to a default):
#     MAPPED    → ONE bounded action via the rail in scripts/herd/journal-act.sh.
#     NO-ACTION → a deliberate, journaled no-op (HERD-562/HERD-563, extended HERD-600/HERD-606): a class
#                 whose finding is real but not itself actionable work — `fixture_slug` (evidence of
#                 test/fixture pollution reaching a live journal, not a gap to file a tracker item
#                 against), `merged_hv_unknown` (a transient PR-body-fetch failure; the next sweep
#                 re-probes on its own), `merged_hv_no_approval` (a merge whose declared HUMAN-VERIFY
#                 steps carry no approval record — real signal, but the PR is already merged, so no
#                 rail can retroactively verify or undo it), `watcher_restart_blocked` (an orphaned
#                 lock holder is a signal for a human to look at — auto-killing an unidentified pid
#                 risks killing a live builder, so no rail may act on it), and `checkout_unclean`
#                 (reconcile_checkout_cleanliness deliberately LEAVES the contamination in place as
#                 evidence for a human; a rail that auto-discarded it would destroy the very evidence
#                 the check exists to preserve).
#                 Journals `audit_acted result=no_action reason=…` exactly once and NEVER files,
#                 escalates, or re-fires for that FINDING KEY. RECURRENCE ESCALATION (HERD-597):
#                 a class that keeps being found under distinct keys (a new slug, a new pr) is itself a
#                 signal nothing has looked at the root cause, so occurrences are additionally counted
#                 PER CLASS (HERD_JOURNAL_AUDIT_NOACTION_COUNT); at HERD_JOURNAL_AUDIT_NOACTION_RECUR_MAX
#                 (default 3) or more, ONE recurring-flagged item is filed for the whole class — dedup
#                 on the CLASS, never per key — and the class then goes quiet forever. HIGH-WATER MARK
#                 (HERD-606): only a genuinely NEW occurrence advances that per-class counter. Each
#                 no-action finding carries the underlying journal event's own timestamp; a persisted
#                 per-class high-water mark in the shared pool (`herd.store --noaction-hwm-advance`)
#                 only ever moves forward, so a BOUNDED-WINDOW REPLAY that resurfaces an
#                 already-counted event — the same journal line still inside the lookback window on a
#                 later sweep, or a once-guard whose claim was lost (the seen-ledger fallback is
#                 tail-trimmed) — can never recount it. This is a backstop ON TOP of the per-key
#                 once-guard below, not a replacement for it.
#     UNMAPPED  → any other class auto-files ONE dedup-keyed tracker item via the scribe. Dedup is keyed
#                 on the CLASS (HERD-602 fix), not the per-finding key: a class that keeps producing NEW
#                 keys (a new pr, a new slug, a new ts) still files exactly once, ever — a gap becomes
#                 WORK instead of a flood of duplicate reports of the same gap.
#   Each MAPPED action fires at most ONCE per finding key across every seat (shared-pool once-guard).
#   ACT-THEN-CLEAR (HERD-564/HERD-573): a mapped action is tracked (HERD_JOURNAL_AUDIT_PENDING) until
#   its finding is resolved one way or the other — every sweep re-checks each tracked key against the
#   FRESH replay: absent ⇒ the action worked, journal `audit_finding_cleared`, stop tracking; still
#   present ⇒ one more re-observation, and past JOURNAL_AUDIT_ESCALATE_AFTER rounds (default 2) escalate
#   loudly exactly once (journal + inbox row + filed item) and stop tracking either way. An action never
#   just goes silent: it always resolves to `audit_finding_cleared` or an `escalated` `audit_acted`.
#   Every action is journaled `audit_acted class=… result=…`.
#
# BINDING CONSTRAINTS:
#   • ADVISORY BY DEFAULT — with JOURNAL_AUDIT_ACT off (the default) this auditor never gates a merge,
#     never mutates git/PRs/tracker/BACKLOG and never auto-heals. Findings are journaled as
#     `journal_audit` events (component=audit) and appended as operator-inbox ledger rows so a human
#     can see them; nothing is fixed. Turning the ACT lever on adds heals — never a merge gate.
#   • SHIP-DORMANT — JOURNAL_AUDIT=off (default) is byte-inert: no journal read, no write, no inbox.
#     JOURNAL_AUDIT_ACT=off (default) is byte-inert on top of that: findings report exactly as before.
#   • FAIL-SOFT — missing/empty/short journal, no python3, unreadable path: silent exit 0.
#   • BOUNDED WINDOW — only the last JOURNAL_AUDIT_WINDOW_SECS of events are considered (default 24h).
#   • IDEMPOTENT — a seen-ledger keys each finding so re-runs do not re-flood the inbox/journal.
#
# Usage:
#   journal-audit.sh
#     Replays the journal window; for each NEW finding journals one journal_audit event and appends
#     one operator-inbox row. Prints a one-line summary when findings fire; silent when clean/off.
#
# Hermetic seams (default to the live surfaces; the unit test overrides them):
#   JOURNAL_FILE                  journal to read (journal.sh seam; also where journal_audit lands).
#   JOURNAL_AUDIT                 on|off (default off). off → immediate silent exit 0.
#   HERD_JOURNAL_AUDIT_INBOX      operator-inbox ledger path (default $WORKTREES_DIR/.agent-watch-inbox).
#   HERD_JOURNAL_AUDIT_SEEN       dedup ledger path (default $WORKTREES_DIR/.agent-watch-journal-audit-seen).
#   HERD_JOURNAL_AUDIT_NOW        ISO-8601 UTC "now" override for TTL math (tests pin this).
#   JOURNAL_AUDIT_WINDOW_SECS     lookback window (default 86400).
#   JOURNAL_AUDIT_DISPATCH_TTL    seconds a *_dispatched event may sit without a terminal (default 2700).
#   JOURNAL_AUDIT_REFIX_TTL       seconds a refix_bounce may sit without wake_result (default 300).
#   JOURNAL_AUDIT_RED_TTL         seconds a main_health red may sit without green (default 7200).
#   JOURNAL_AUDIT_MERGE_GRACE     seconds after merge before missing-reap is a finding (default 600).
#   JOURNAL_AUDIT_PUSHED_GRACE    seconds after pushed=no before missing yes is a finding (default 1800).
#   HERD_JOURNAL_AUDIT_FIXTURE_SLUGS  space-separated known-fixture slug list (default: retiree conv stuck hd).
#   HERD_APPROVALS_FILE           approval-ledger path (approvals.sh seam; tests pin it).
#   HERD_JOURNAL_AUDIT_PR_BODY_CMD  command invoked as `<cmd> <pr#>` printing the PR body on stdout and
#                                 a MEANINGFUL exit status (non-zero ⇒ unreadable). Defaults to
#                                 `gh pr view <pr#> --json body -q .body`. With no override and no gh,
#                                 check (g) skips silently — a missing optional tool is never a finding.
#   JOURNAL_AUDIT_ACT             on|off (default off). off → findings stay advisory, byte-identically.
#   HERD_JOURNAL_AUDIT_ACT_CMD    the ACTION-RAIL seam, invoked as `<cmd> <class> <key> <k=v…>` and
#                                 printing ONE result token on stdout. Defaults to
#                                 `bash journal-act.sh` (the live rails). Tests pin a stub here so no
#                                 action ever reaches a real control room.
#   HERD_JOURNAL_AUDIT_SCRIBE_CMD the TRACKER-FILING seam for an unmapped/escalated finding, invoked
#                                 as `<cmd> "<request>"`. Defaults to `bash scribe.sh`.
#   HERD_JOURNAL_AUDIT_PENDING    ACT-THEN-CLEAR ledger path (HERD-564/573) — one row per finding key
#                                 this seat has acted on and is still watching for clearance-or-escalate.
#                                 Default $WORKTREES_DIR/.agent-watch-journal-audit-pending.
#   JOURNAL_AUDIT_ESCALATE_AFTER  re-observations a mapped-class finding may survive, still standing,
#                                 before escalating (default 2). 1 reproduces the pre-HERD-564 behavior
#                                 (escalate on the very next sighting).
#   HERD_JOURNAL_AUDIT_NOACTION_COUNT  RECURRENCE-ESCALATION ledger path (HERD-597) — one row per
#                                 deliberate no-action CLASS, counting distinct occurrences across
#                                 sweeps. Default $WORKTREES_DIR/.agent-watch-journal-audit-noaction-count.
#   HERD_JOURNAL_AUDIT_NOACTION_RECUR_MAX  distinct occurrences of a no-action class before it files ONE
#                                 recurring-flagged item (default 3). A test seam, not an operator knob
#                                 (mirrors HERD_JOURNAL_AUDIT_ACT_MAX).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/herd-config.sh"
# shellcheck source=/dev/null
. "$HERE/journal.sh"
# HUMAN-VERIFY block parser (presence only) + the approval-ledger seam herd-approve.sh writes. Both
# only define functions; check (g) below is their sole consumer here.
# shellcheck source=/dev/null
. "$HERE/human-verify.sh"
# shellcheck source=/dev/null
. "$HERE/approvals.sh"
# AGING-PR alarm (HERD-334) — THE shared TTL helper. Sourced so this auditor reads AGING_PR_TTL through
# the SAME _aging_pr_ttl_secs getter the watcher render pass uses: the gates_passed_no_merge finding
# below and the render row can never disagree on the threshold. Defines functions only; no side effects.
# shellcheck source=/dev/null
. "$HERE/aging-pr.sh"

# ── ship-dormant gate ────────────────────────────────────────────────────────
_ja_enabled() {
  case "$(printf '%s' "${JOURNAL_AUDIT:-off}" | tr '[:upper:]' '[:lower:]')" in
    1|true|on|yes|enable|enabled) return 0 ;;
    *) return 1 ;;
  esac
}
_ja_enabled || exit 0

# ── resolve paths + tunables ─────────────────────────────────────────────────
_jf=""
if [ -n "${JOURNAL_FILE:-}" ]; then
  _jf="$JOURNAL_FILE"
elif [ -n "${WORKTREES_DIR:-}" ]; then
  _jf="$WORKTREES_DIR/.herd/journal.jsonl"
fi
# Empty / missing / unreadable journal → fail-soft silence (bounded window of nothing).
[ -n "$_jf" ] && [ -f "$_jf" ] && [ -s "$_jf" ] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

INBOX="${HERD_JOURNAL_AUDIT_INBOX:-${WORKTREES_DIR:-/tmp}/.agent-watch-inbox}"
SEEN="${HERD_JOURNAL_AUDIT_SEEN:-${WORKTREES_DIR:-/tmp}/.agent-watch-journal-audit-seen}"
# ACT-THEN-CLEAR ledger (HERD-564/573) — see the ACT section below. Only ever written when
# JOURNAL_AUDIT_ACT=on; empty/absent is the byte-inert default state.
PENDING="${HERD_JOURNAL_AUDIT_PENDING:-${WORKTREES_DIR:-/tmp}/.agent-watch-journal-audit-pending}"
# RECURRENCE-ESCALATION ledger (HERD-597) — one row per DELIBERATE no-action class (fixture_slug,
# merged_hv_unknown), counting distinct occurrences across sweeps. See _ja_noaction_recur below. Only
# ever written when JOURNAL_AUDIT_ACT=on; empty/absent is the byte-inert default state.
NOACTION_COUNT="${HERD_JOURNAL_AUDIT_NOACTION_COUNT:-${WORKTREES_DIR:-/tmp}/.agent-watch-journal-audit-noaction-count}"
# Ensure parent dirs exist so inbox/seen/pending/noaction-count writes never fail the advisory path.
mkdir -p "$(dirname "$INBOX")" "$(dirname "$SEEN")" "$(dirname "$PENDING")" "$(dirname "$NOACTION_COUNT")" 2>/dev/null || true

_num_or() {
  case "${1:-}" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac
}
WINDOW_SECS="$(_num_or "${JOURNAL_AUDIT_WINDOW_SECS:-}" 86400)"
DISPATCH_TTL="$(_num_or "${JOURNAL_AUDIT_DISPATCH_TTL:-}" 2700)"
REFIX_TTL="$(_num_or "${JOURNAL_AUDIT_REFIX_TTL:-}" 300)"
RED_TTL="$(_num_or "${JOURNAL_AUDIT_RED_TTL:-}" 7200)"
MERGE_GRACE="$(_num_or "${JOURNAL_AUDIT_MERGE_GRACE:-}" 600)"
PUSHED_GRACE="$(_num_or "${JOURNAL_AUDIT_PUSHED_GRACE:-}" 1800)"
FIXTURE_SLUGS="${HERD_JOURNAL_AUDIT_FIXTURE_SLUGS:-retiree conv stuck hd}"
# AGING-PR TTL in seconds via the SHARED getter (HERD-334): the ONE source of the threshold, sanitized
# (non-numeric → default 3600). 0 disables the gates_passed_no_merge finding (leg c goes byte-inert).
AGING_PR_TTL_SECS="$(_aging_pr_ttl_secs)"

# ── replay: pure python scanner → one finding line per violation ─────────────
# Each stdout line:  kind\tkey\tsummary\tctx
# kind ∈ merge_without_reap | dispatch_no_outcome | refix_bounce_no_wake |
#        red_state_stale | pushed_no_unresolved | main_detached | fixture_slug | watcher_restart_blocked |
#        checkout_unclean | gates_passed_no_merge
# key is a stable dedup token; summary is a short human phrase for the inbox row; ctx is the finding's
# ACTION CONTEXT (HERD-544) — a space-separated `k=v` list (pr=, sha=, slug=, round=) taken from the
# very event that violated the invariant, so the action pass can drive the matching rail without
# re-deriving anything. ctx is a FOURTH field, never folded into the summary: the journal_audit event
# and the inbox row read from fields 1-3 exactly as before, so a run with JOURNAL_AUDIT_ACT off is
# byte-identical to the pre-HERD-544 auditor.
# shellcheck disable=SC2016
FINDINGS="$(
  JOURNAL_FILE="$_jf" \
  HERD_JOURNAL_AUDIT_NOW="${HERD_JOURNAL_AUDIT_NOW:-}" \
  WINDOW_SECS="$WINDOW_SECS" \
  DISPATCH_TTL="$DISPATCH_TTL" \
  REFIX_TTL="$REFIX_TTL" \
  RED_TTL="$RED_TTL" \
  MERGE_GRACE="$MERGE_GRACE" \
  PUSHED_GRACE="$PUSHED_GRACE" \
  FIXTURE_SLUGS="$FIXTURE_SLUGS" \
  AGING_PR_TTL="$AGING_PR_TTL_SECS" \
  python3 - <<'PY'
import json, os, re, sys
from datetime import datetime, timezone

def parse_ts(s):
    if not s:
        return None
    s = str(s).strip()
    # Accept ISO-8601 Z and common variants.
    for fmt in ("%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%dT%H:%M:%S.%fZ", "%Y-%m-%d %H:%M:%SZ"):
        try:
            return datetime.strptime(s, fmt).replace(tzinfo=timezone.utc)
        except ValueError:
            pass
    # epoch seconds
    try:
        return datetime.fromtimestamp(int(s), tz=timezone.utc)
    except Exception:
        return None

def now_dt():
    override = os.environ.get("HERD_JOURNAL_AUDIT_NOW") or ""
    if override:
        dt = parse_ts(override)
        if dt is not None:
            return dt
    return datetime.now(timezone.utc)

def age_secs(now, ts):
    if ts is None:
        return 0
    return max(0, int((now - ts).total_seconds()))

jf = os.environ.get("JOURNAL_FILE") or ""
window = int(os.environ.get("WINDOW_SECS") or 86400)
dispatch_ttl = int(os.environ.get("DISPATCH_TTL") or 2700)
refix_ttl = int(os.environ.get("REFIX_TTL") or 300)
red_ttl = int(os.environ.get("RED_TTL") or 7200)
merge_grace = int(os.environ.get("MERGE_GRACE") or 600)
pushed_grace = int(os.environ.get("PUSHED_GRACE") or 1800)
aging_pr_ttl = int(os.environ.get("AGING_PR_TTL") or 3600)
fixtures = set((os.environ.get("FIXTURE_SLUGS") or "retiree conv stuck hd").split())

now = now_dt()
cutoff = now.timestamp() - window

events = []
try:
    with open(jf, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                o = json.loads(line)
            except Exception:
                continue
            if not isinstance(o, dict):
                continue
            ts = parse_ts(o.get("ts"))
            if ts is None:
                continue
            if ts.timestamp() < cutoff:
                continue
            o["_ts"] = ts
            events.append(o)
except OSError:
    sys.exit(0)

# Sort chronologically (window may span rotations only if live file is contiguous — fine).
events.sort(key=lambda o: o["_ts"])

findings = []  # (kind, key, summary, ctx)

def ctx(**kw):
    """ACTION CONTEXT (HERD-544): this finding's own facts as a space-separated `k=v` list, taken
    from the violating event itself. Empty/None fields are DROPPED rather than emitted as `k=`, so a
    rail can test `[ -n "$slug" ]` and mean it. Values are whitespace-flattened: ctx is the fourth
    TAB-separated field and is word-split into argv by the action pass, so an embedded space or tab
    would silently become an extra argument."""
    return " ".join("%s=%s" % (k, " ".join(str(v).split()))
                    for k, v in kw.items() if v not in (None, ""))

# ── (a) merge without reap ──────────────────────────────────────────────────
# For each merge, require a later reap with same pr (preferred) or same slug.
merges = [e for e in events if e.get("event") == "merge"]
reaps = [e for e in events if e.get("event") == "reap"]
for m in merges:
    if age_secs(now, m["_ts"]) < merge_grace:
        continue  # still inside the post-merge grace window
    pr = m.get("pr")
    slug = str(m.get("slug") or "")
    mts = m["_ts"]
    ok = False
    for r in reaps:
        if r["_ts"] < mts:
            continue
        if pr is not None and r.get("pr") is not None and str(r.get("pr")) == str(pr):
            ok = True
            break
        if slug and str(r.get("slug") or "") == slug:
            ok = True
            break
    if not ok:
        key = "merge_without_reap|pr=%s|slug=%s" % (pr if pr is not None else "", slug)
        summary = "merge without reap · pr=%s slug=%s" % (pr if pr is not None else "?", slug or "?")
        findings.append(("merge_without_reap", key, summary, ctx(pr=pr, sha=m.get("sha"), slug=slug)))

# ── (b) *_dispatched with no terminal past family TTL ───────────────────────
# Terminal map: review_dispatched → verdict_recorded (same pr + sha when present).
# Any event whose name ends with _dispatched is considered; unknown families use a
# generic "any later same-pr event other than dispatch" is NOT enough — only known terminals.
def is_dispatched(name):
    return bool(name) and str(name).endswith("_dispatched")

# HERD-607: a dispatch finding needs work identity (a pr or a slug); a heartbeat like
# engine_live_dispatched has neither and never gets a terminal event by design.
def has_work_identity(ev):
    return bool(ev.get("pr")) or bool(ev.get("slug"))

TERMINALS = {
    "review_dispatched": {"verdict_recorded", "review_skipped", "review_carried_forward"},
}

dispatches = [e for e in events if is_dispatched(e.get("event")) and has_work_identity(e)]
for d in dispatches:
    if age_secs(now, d["_ts"]) < dispatch_ttl:
        continue
    ev = str(d.get("event") or "")
    pr = d.get("pr")
    sha = str(d.get("sha") or "")
    terminals = TERMINALS.get(ev, set())
    # Unknown *_dispatched family: treat any later event with same pr+event-prefix as non-terminal only;
    # without a known terminal set, require a later event with event ending in a known outcome token.
    if not terminals:
        terminals = {"verdict_recorded", "outcome", "completed", "done"}
    ok = False
    for e in events:
        if e["_ts"] <= d["_ts"]:
            continue
        en = str(e.get("event") or "")
        if en in terminals or any(en.endswith("_" + t) or en == t for t in terminals):
            if pr is not None and e.get("pr") is not None and str(e.get("pr")) != str(pr):
                continue
            if sha and e.get("sha") and str(e.get("sha")) != sha:
                continue
            ok = True
            break
        # Also accept healthcheck_outcome-style for non-review families
        if en.endswith("_outcome") or en.endswith("_result"):
            if pr is not None and e.get("pr") is not None and str(e.get("pr")) != str(pr):
                continue
            ok = True
            break
    if not ok:
        key = "dispatch_no_outcome|%s|pr=%s|sha=%s" % (ev, pr if pr is not None else "", sha)
        summary = "%s with no terminal · pr=%s sha=%s" % (ev, pr if pr is not None else "?", (sha[:8] if sha else "?"))
        findings.append(("dispatch_no_outcome", key, summary, ctx(pr=pr, sha=sha, slug=d.get("slug"), event=ev)))

# ── (c) refix_bounce without refix_wake_result ──────────────────────────────
bounces = [e for e in events if e.get("event") == "refix_bounce"]
wakes = [e for e in events if e.get("event") == "refix_wake_result"]
for b in bounces:
    if age_secs(now, b["_ts"]) < refix_ttl:
        continue
    pr = b.get("pr")
    sha = str(b.get("sha") or "")
    round_ = b.get("round")
    ok = False
    for w in wakes:
        if w["_ts"] < b["_ts"]:
            continue
        if pr is not None and w.get("pr") is not None and str(w.get("pr")) != str(pr):
            continue
        if sha and w.get("sha") and str(w.get("sha")) != sha:
            continue
        if round_ is not None and w.get("round") is not None and str(w.get("round")) != str(round_):
            continue
        ok = True
        break
    if not ok:
        key = "refix_bounce_no_wake|pr=%s|sha=%s|round=%s" % (
            pr if pr is not None else "", sha, round_ if round_ is not None else "")
        summary = "refix_bounce with no wake_result · pr=%s round=%s" % (
            pr if pr is not None else "?", round_ if round_ is not None else "?")
        findings.append(("refix_bounce_no_wake", key, summary, ctx(pr=pr, sha=sha, slug=b.get("slug"), round=round_)))

# ── (d) red state older than TTL ────────────────────────────────────────────
# main_health result=red without a later main_health result=green (any sha clears). ONE FINDING PER
# SHA (HERD-597), not per red EVENT: reconcile_main_health re-confirms a standing red on its own
# cadence, so a chronically-red main journals a FRESH `main_health result=red` every tick. The old key
# folded the event's own ts into the dedup token, so each re-confirmation was a BRAND NEW finding with
# a brand new PENDING row — none of them ever converged (cleared or escalated), because the once-guard
# never saw the same key twice. Two such orphaned rows sat in the live PENDING ledger, all count=1,
# same sha, different ts, none reaching JOURNAL_AUDIT_ESCALATE_AFTER. Keying on sha alone (using the
# EARLIEST red event for that sha, chronologically) collapses every re-confirmation of one ongoing
# incident into the SAME finding, so the lifecycle pass can actually clear it (a green lands) or
# escalate it (still standing past the grace window) — bounded, like every other mapped class.
reds = [e for e in events if e.get("event") == "main_health" and str(e.get("result") or "") == "red"]
greens = [e for e in events if e.get("event") == "main_health" and str(e.get("result") or "") == "green"]
seen_red_sha = set()
for r in reds:  # events (and this filtered view) are already chronological — see events.sort() above
    sha = str(r.get("sha") or "")
    # An event with no sha at all can't be deduped against its siblings without risking merging two
    # UNRELATED incidents, so it keeps the old per-event identity (ts-suffixed) rather than collapsing.
    dedup = sha if sha else ("noshasentinel:" + r["_ts"].strftime("%Y%m%dT%H%M%SZ"))
    if dedup in seen_red_sha:
        continue
    seen_red_sha.add(dedup)
    if age_secs(now, r["_ts"]) < red_ttl:
        continue
    # Cleared if any green lands after this (the earliest) red for this sha.
    ok = any(g["_ts"] > r["_ts"] for g in greens)
    if not ok:
        key = "red_state_stale|sha=%s" % (sha or "unknown")
        summary = "MAIN RED older than TTL · sha=%s failed=%s" % (
            (sha[:8] if sha else "?"), str(r.get("failed") or r.get("detail") or "")[:60])
        findings.append(("red_state_stale", key, summary, ctx(pr=r.get("pr"), sha=sha)))

# ── (k) gates passed but no merge older than TTL (HERD-334) ──────────────────
# A `gate_status` (state=success, context=herd/gates) event is the engine's marker for "all gates
# passed / herd/gates=success" — journaled by bash post_gate_status and the python actuator on the
# successful commit-status API write. The python engine core additionally journals event=blessing,
# state=success, context=herd/gates — once per pr+sha the instant a PR reaches BLESSED, BEFORE the
# hold/merge decision and regardless of GATE_STATUS. Both markers are accepted below — no other
# event marks gates-passed. The context guard tolerates an absent field but excludes any future
# non-gates status context; herd/gates mirrors GATE_STATUS_CONTEXT, a deliberate constant in
# agent-watch.sh that is not a config key, so naming it here cannot drift.
# When branch protection then keeps blocking the merge on a required CI check, the PR sits
# engine-approved-but-unmerged with nothing progressing — the exact silent state PRs #440/#441 sat in
# for 7h. A later `merge` for the same pr clears it (any sha — a merge merges the PR). Past AGING_PR_TTL
# with no such merge → a gates_passed_no_merge finding. Shares the render pass's AGING_PR_TTL threshold
# (aging-pr.sh); 0 disables this leg. Advisory only — the auditor never merges or clears anything.
if aging_pr_ttl > 0:
    blessings = [e for e in events
                 if e.get("event") in ("gate_status", "blessing")
                 and str(e.get("state") or "") == "success"
                 and str(e.get("context") or "herd/gates") == "herd/gates"]
    for b in blessings:
        if age_secs(now, b["_ts"]) < aging_pr_ttl:
            continue
        pr = b.get("pr")
        # Cleared by a later merge for the same pr (a blessing is per-(pr,sha), but the merge that
        # clears it may land on a newer sha — so match on pr, not sha).
        if pr is not None and any(m.get("pr") is not None and str(m.get("pr")) == str(pr)
                                  and m["_ts"] >= b["_ts"] for m in merges):
            continue
        sha = str(b.get("sha") or "")
        key = "gates_passed_no_merge|pr=%s|sha=%s" % (pr if pr is not None else "", sha)
        summary = "engine-approved but unmerged past TTL · pr=%s sha=%s — blocked on a required check?" % (
            pr if pr is not None else "?", (sha[:8] if sha else "?"))
        findings.append(("gates_passed_no_merge", key, summary, ctx(pr=pr, sha=sha, slug=b.get("slug"))))

# ── (e) pushed=no never followed by pushed=yes ──────────────────────────────
# Match codemap_refresh / symbol_index_refresh (and any event carrying pushed=no).
pushed_no = [e for e in events if str(e.get("pushed") or "") == "no"]
pushed_yes = [e for e in events if str(e.get("pushed") or "") in ("yes", "yes-after-rebase")]
for p in pushed_no:
    if age_secs(now, p["_ts"]) < pushed_grace:
        continue
    ev = str(p.get("event") or "")
    # A later yes for the SAME event family clears it.
    ok = False
    for y in pushed_yes:
        if y["_ts"] <= p["_ts"]:
            continue
        if ev and str(y.get("event") or "") != ev:
            continue
        ok = True
        break
    if not ok:
        key = "pushed_no_unresolved|event=%s|ts=%s" % (ev, p["_ts"].strftime("%Y%m%dT%H%M%SZ"))
        summary = "pushed=no never followed by pushed=yes · %s" % (ev or "event")
        findings.append(("pushed_no_unresolved", key, summary, ctx(event=ev)))

# ── (i) detached shared checkout (HERD-336) ─────────────────────────────────
# main_detached result=detected not cleared by a later result=reattached (same head, or an empty head
# on either side) → the shared coordinator checkout sat on a detached HEAD (the refresh-race corpse
# that once sat detached until a human `git pull` failed). Surfaces even when auto-healed only after
# sitting unresolved for a window; a detected immediately followed by a reattached is clean.
det = [e for e in events if e.get("event") == "main_detached" and str(e.get("result") or "") == "detected"]
reatt = [e for e in events if e.get("event") == "main_detached" and str(e.get("result") or "") == "reattached"]
for d in det:
    head = str(d.get("head") or "")
    # A reattach lands the branch on a DIFFERENT sha than the detached commit, so pair chronologically
    # (any later reattached clears a detection) rather than by head — like pushed=no ↔ pushed=yes.
    ok = any(r["_ts"] >= d["_ts"] for r in reatt)
    if not ok:
        key = "main_detached|sha=%s|ts=%s" % (head, d["_ts"].strftime("%Y%m%dT%H%M%SZ"))
        summary = "shared checkout DETACHED (never reattached) · head=%s branch=%s" % (
            (head[:8] if head else "?"), str(d.get("branch") or "?"))
        findings.append(("main_detached", key, summary, ctx(sha=head)))

# ── (f) known-fixture slugs ─────────────────────────────────────────────────
seen_fixture = set()
for e in events:
    slug = str(e.get("slug") or "").strip()
    if not slug or slug in seen_fixture:
        continue
    # Exact match against the known-fixture set (the HERD-223 pollution slugs).
    if slug in fixtures:
        seen_fixture.add(slug)
        key = "fixture_slug|%s" % slug
        summary = "known-fixture slug in journal · slug=%s event=%s" % (slug, e.get("event") or "?")
        findings.append(("fixture_slug", key, summary, ctx(slug=slug, ts=int(e["_ts"].timestamp()))))

# ── (h) watcher_restart_blocked events (HERD-342) ──────────────────────────
# A blocked restart is a direct signal that an orphaned lock holder is preventing engine recovery.
# Any event in the window is a finding — the operator needs to know about it.
for e in events:
    if e.get("event") != "watcher_restart_blocked":
        continue
    holder = str(e.get("holder_pid") or "unknown")
    workspace = str(e.get("workspace") or "")
    key = "watcher_restart_blocked|workspace=%s|holder=%s" % (workspace, holder)
    summary = "watcher restart blocked · holder_pid=%s%s" % (
        holder,
        (" workspace=%s" % workspace) if workspace else "",
    )
    findings.append(("watcher_restart_blocked", key, summary,
                     ctx(holder_pid=holder, workspace=workspace, ts=int(e["_ts"].timestamp()))))

# ── (j) unclean shared checkout (HERD-361) ──────────────────────────────────
# reconcile_checkout_cleanliness journals `checkout_unclean result=detected/violation` when the shared
# coordinator checkout carries staged/tracked contamination (the fingerprint of a suite test that staged
# in $PWD) or sits detached. It is a per-tick invariant already deduped by the watcher, so ANY occurrence
# in the window is worth an inbox row — the operator needs to know evidence is sitting in $MAIN awaiting
# a human (the watcher never auto-discards it).
for e in events:
    if e.get("event") != "checkout_unclean":
        continue
    if str(e.get("result") or "") not in ("violation", "detected"):
        continue
    head = str(e.get("head") or "")
    paths = str(e.get("paths") or "")
    detached = str(e.get("detached") or "no")
    key = "checkout_unclean|sha=%s|files=%s" % (head, paths)
    summary = "shared checkout UNCLEAN (evidence preserved) · head=%s detached=%s paths=%s" % (
        (head[:8] if head else "?"), detached, (paths[:80] if paths else "?"))
    findings.append(("checkout_unclean", key, summary, ctx(sha=head, ts=int(e["_ts"].timestamp()))))

for kind, key, summary, fctx in findings:
    # TAB-separated; summary flattened (no tabs/newlines).
    summary = " ".join(summary.split())
    key = " ".join(key.split())
    print("%s\t%s\t%s\t%s" % (kind, key, summary, fctx))
PY
)" || FINDINGS=""

# ── seen-ledger: the idempotence substrate (also memoizes check (g)'s PR-body probes) ─────────
_seen_has() {
  [ -s "$SEEN" ] || return 1
  grep -qxF -- "$1" "$SEEN" 2>/dev/null
}
_seen_mark() {
  printf '%s\n' "$1" >> "$SEEN" 2>/dev/null || true
  # Bound the seen ledger (tail-keep) so it never grows unbounded.
  local n; n="$(wc -l < "$SEEN" 2>/dev/null | tr -cd '0-9')"
  if [ "${n:-0}" -gt 500 ]; then
    local keep; keep="$(mktemp "${SEEN}.XXXXXX" 2>/dev/null || true)"
    [ -n "$keep" ] || return 0
    tail -n 400 "$SEEN" > "$keep" 2>/dev/null && mv -f "$keep" "$SEEN" 2>/dev/null || rm -f "$keep" 2>/dev/null
  fi
}

# ── (g) merged PR with a HUMAN-VERIFY block but no sha-keyed approval ────────
# Three read-only sources meet here: the journal names every merge (pr + head sha), the PR body says
# whether manual steps were ever declared, and approvals.sh says whether that exact sha was signed off.
# A merge that satisfies the first two and not the third shipped its declared steps unrun.

# _ja_pr_body <pr#> — the PR body on stdout, the fetch's EXIT STATUS preserved. The status is the whole
# point (same lesson as agent-watch.sh's _pr_body): a swallowed failure makes an unreadable body look
# exactly like a PR that declares no block, and "declares no block" is the answer that clears the PR.
_ja_pr_body() {
  if [ -n "${HERD_JOURNAL_AUDIT_PR_BODY_CMD:-}" ]; then
    # Word-split deliberately: the seam is a command LINE, not a single argv[0].
    # shellcheck disable=SC2086
    $HERD_JOURNAL_AUDIT_PR_BODY_CMD "$1"
    return $?
  fi
  # Bound the fetch where coreutils' timeout exists — a hung gh must never stall the watcher sweep.
  if command -v timeout >/dev/null 2>&1; then
    timeout 15 gh pr view "$1" --json body -q '.body' 2>/dev/null
  else
    gh pr view "$1" --json body -q '.body' 2>/dev/null
  fi
}

# _ja_hv_add <kind> <key> <summary> [ctx] — accumulate one finding line in the same TSV shape python
# emits (kind, key, summary, ctx) — ctx defaults to empty, same as a python finding with no facts.
HV_FINDINGS=""
_ja_hv_add() {
  local _row
  _row="$(printf '%s\t%s\t%s\t%s' "$1" "$2" "$3" "${4:-}")"
  if [ -n "$HV_FINDINGS" ]; then
    HV_FINDINGS="$(printf '%s\n%s' "$HV_FINDINGS" "$_row")"
  else
    HV_FINDINGS="$_row"
  fi
}

# No body source at all (no seam, no gh) → the check cannot run. A missing OPTIONAL tool skips
# SILENTLY; it is never a finding, and never a red row.
if [ -n "${HERD_JOURNAL_AUDIT_PR_BODY_CMD:-}" ] || command -v gh >/dev/null 2>&1; then
  # Distinct merges in the window, oldest first: "<pr>\t<sha>\t<evidence>", where evidence is what the
  # JOURNAL still knows about that pr+sha after the approval ledger was purged:
  #   approved | hv-informed | none
  # A merge with no pr is unauditable.
  # shellcheck disable=SC2016
  MERGES="$(
    JOURNAL_FILE="$_jf" \
    HERD_JOURNAL_AUDIT_NOW="${HERD_JOURNAL_AUDIT_NOW:-}" \
    WINDOW_SECS="$WINDOW_SECS" \
    python3 - <<'PY'
import json, os, sys
from datetime import datetime, timezone

def parse_ts(s):
    if not s:
        return None
    s = str(s).strip()
    for fmt in ("%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%dT%H:%M:%S.%fZ", "%Y-%m-%d %H:%M:%SZ"):
        try:
            return datetime.strptime(s, fmt).replace(tzinfo=timezone.utc)
        except ValueError:
            pass
    try:
        return datetime.fromtimestamp(int(s), tz=timezone.utc)
    except Exception:
        return None

override = parse_ts(os.environ.get("HERD_JOURNAL_AUDIT_NOW") or "")
now = override if override is not None else datetime.now(timezone.utc)
cutoff = now.timestamp() - int(os.environ.get("WINDOW_SECS") or 86400)

rows = []          # merges: (ts, pr, sha)
approved = []      # (pr, sha) a human signed off — approval_recorded
informed = []      # (pr, sha) merged as informational under HUMAN_VERIFY_POLICY=auto
try:
    with open(os.environ.get("JOURNAL_FILE") or "", "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                o = json.loads(line)
            except Exception:
                continue
            if not isinstance(o, dict):
                continue
            ev = o.get("event")
            if ev not in ("merge", "approval_recorded", "human_verify_policy"):
                continue
            ts = parse_ts(o.get("ts"))
            if ts is None or ts.timestamp() < cutoff:
                continue
            pr = o.get("pr")
            if pr is None or str(pr).strip() in ("", "0"):
                continue
            pr = str(pr).strip()
            sha = str(o.get("sha") or "").strip()
            if ev == "merge":
                rows.append((ts, pr, sha))
            elif ev == "approval_recorded":
                if str(o.get("state") or "approved") == "approved":
                    approved.append((pr, sha))
            elif str(o.get("policy") or "") == "auto":
                informed.append((pr, sha))
except OSError:
    sys.exit(0)

def sha_match(a, b):
    """Anchored, bidirectional prefix match — `list` shows a short sha, the watcher records the full
    oid. An EMPTY sha on either side matches any sha for that PR (a record that never carried one)."""
    if not a or not b:
        return True
    return a == b or a.startswith(b) or b.startswith(a)

def evidence(pr, sha):
    if any(p == pr and sha_match(s, sha) for p, s in approved):
        return "approved"
    if any(p == pr and sha_match(s, sha) for p, s in informed):
        return "hv-informed"
    return "none"

rows.sort(key=lambda r: r[0])
seen = set()
for _ts, pr, sha in rows:
    if (pr, sha) in seen:
        continue
    seen.add((pr, sha))
    print("%s\t%s\t%s\t%s" % (pr, sha, evidence(pr, sha), int(_ts.timestamp())))
PY
  )" || MERGES=""

  while IFS=$'\t' read -r _hv_pr _hv_sha _hv_evidence _hv_ts; do
    [ -n "$_hv_pr" ] || continue
    # A merged PR is settled: once a tick has proven it clean (no block, or block + approval), that
    # verdict can never change, so memoize it in the seen-ledger. Without this, every tick re-fetches
    # every body in the window. An UNKNOWN is never memoized — a transient fetch failure must heal.
    _hv_memo="hv_clean|pr=${_hv_pr}|sha=${_hv_sha}"
    _seen_has "$_hv_memo" && continue
    _hv_rc=0
    # </dev/null: this loop's stdin is the merge list. A body command that read stdin would eat it.
    _hv_body="$(_ja_pr_body "$_hv_pr" </dev/null)" || _hv_rc=$?
    if [ "$_hv_rc" -ne 0 ]; then
      # UNKNOWN, not clean and not guilty: we could not read the body, so we cannot say whether steps
      # were declared. Reported once (the seen-ledger keys it) so a human can look; never a crash.
      _ja_hv_add "merged_hv_unknown" \
        "merged_hv_unknown|pr=${_hv_pr}|sha=${_hv_sha}" \
        "merged PR body unreadable — human-verify approval unverifiable · pr=${_hv_pr} sha=${_hv_sha:-?}" \
        "pr=${_hv_pr} sha=${_hv_sha} ts=${_hv_ts}"
      continue
    fi
    if ! printf '%s' "$_hv_body" | human_verify_has; then
      _seen_mark "$_hv_memo"; continue                       # no block declared → nothing to approve
    fi
    # Evidence is the UNION of the journal (durable, survives purge_pr_approvals) and the live ledger
    # (authoritative only before the merge purges it, but a purge that failed leaves a real row).
    _hv_state="$_hv_evidence"
    _hv_ledger="$(approval_state "$_hv_pr" "$_hv_sha")"
    case "$_hv_ledger" in
      approved)    _hv_state="approved" ;;
      hv-informed) [ "$_hv_state" = "approved" ] || _hv_state="hv-informed" ;;
    esac
    if [ "$_hv_state" = "approved" ]; then
      _seen_mark "$_hv_memo"; continue
    fi
    # `hv-informed` means HUMAN_VERIFY_POLICY=auto merged it as informational: the steps were journaled
    # and commented, never signed off. That is a weaker record than an approval, so it still surfaces —
    # the summary names it so an operator can tell a deliberate posture from a fail-open merge.
    _hv_why="no approval record"
    [ "$_hv_state" = "hv-informed" ] && _hv_why="hv-informed only (never signed off)"
    _ja_hv_add "merged_hv_no_approval" \
      "merged_hv_no_approval|pr=${_hv_pr}|sha=${_hv_sha}" \
      "merged with HUMAN-VERIFY steps, ${_hv_why} · pr=${_hv_pr} sha=${_hv_sha:-?}" \
      "pr=${_hv_pr} sha=${_hv_sha} ts=${_hv_ts}"
  done <<EOF
$MERGES
EOF
fi

if [ -n "$HV_FINDINGS" ]; then
  if [ -n "$FINDINGS" ]; then
    FINDINGS="$(printf '%s\n%s' "$FINDINGS" "$HV_FINDINGS")"
  else
    FINDINGS="$HV_FINDINGS"
  fi
fi

# ── emit: dedup via seen-ledger, then journal + inbox ────────────────────────
_inbox_append() {
  # Same TSV shape as agent-watch.sh _inbox_record:
  #   <epoch>\t<source>\t<ref>\t<author>\t<snippet>
  local ref="$1" snip="$2" now
  now="$(date +%s 2>/dev/null || echo 0)"
  # Flatten snippet (no tabs/newlines); cap length.
  snip="$(printf '%s' "$snip" | tr '\t\n' '  ')"
  snip="${snip:0:120}"
  printf '%s\t%s\t%s\t%s\t%s\n' "$now" "audit" "$ref" "audit" "$snip" >> "$INBOX" 2>/dev/null || true
  local n; n="$(wc -l < "$INBOX" 2>/dev/null | tr -cd '0-9')"
  if [ "${n:-0}" -gt 50 ]; then
    local keep; keep="$(mktemp "${INBOX}.XXXXXX" 2>/dev/null || true)"
    [ -n "$keep" ] || return 0
    tail -n 50 "$INBOX" > "$keep" 2>/dev/null && mv -f "$keep" "$INBOX" 2>/dev/null || rm -f "$keep" 2>/dev/null
  fi
}

# ── ACT: findings become ACTIONS (HERD-544) ──────────────────────────────────
# THE UNIVERSAL NEVER-STUCK INVARIANT. Everything above this line only REPORTS. Behind
# JOURNAL_AUDIT_ACT (off by default, ship-dormant) each finding class is instead mapped to ONE
# bounded action, so a stall that no other rail owns is owned HERE:
#   dispatch_no_outcome  → free the held gate slot (HERD-185 hygiene); the next tick re-dispatches
#   refix_bounce_no_wake → re-deliver the bounce ONCE; a wake that lands closes the finding itself
#   red_state_stale      → arm the main-health re-verify rail for the current $MAIN HEAD
#   merge_without_reap   → run the retirement invariant (HERD-164) now
#   ANY OTHER CLASS      → no mapped action, so the GAP becomes WORK: file one dedup-keyed tracker
#                          item via the scribe. A class nothing can heal must never be a class
#                          nothing knows about.
# The rails themselves live in journal-act.sh (which composes agent-watch.sh's LIB mode); this file
# owns only WHEN to act, HOW OFTEN, and what to do when acting did not help.
#
# ONCE PER FINDING KEY, ACROSS SEATS. Findings derive from the SHARED journal, so two seats replaying
# the same window see the same key and would both act. Each action is claimed through the shared-pool
# once-guard (pysrc/herd/store.py `--once`, the primitive the finish-stall and draft-promote rails
# already use), keyed `audit_act::<finding key>` — exactly one seat acts, ever. The action pass runs
# BEFORE the seen-ledger check on purpose: the seen-ledger suppresses re-REPORTING a known finding,
# but a finding that is still being FOUND is one the world has not fixed, and that is precisely when
# the escalation below must fire.
#
# ACT ONCE, THEN ESCALATE. A finding still standing on a later sweep means the mapped action did not
# clear it. That is not a reason to act again (the action is bounded by design and a loop is exactly
# the failure mode this item exists to end) — it is a reason to be LOUD: a second guard,
# `audit_escalate::<key>`, fires exactly one escalation (journal + a loud inbox row + a filed tracker
# item) and then the key is silent forever. An UNMAPPED class burns both guards at once: its filing
# IS the terminal outcome, so it can never escalate into a duplicate item.
#
# ALL FAIL-SOFT. Every leg — the once-guard, the rail, the scribe — degrades to a result token and a
# journal line. The audit sweep NEVER fails because a heal could not be attempted.
#
# BOUNDED PER SWEEP. This auditor runs INSIDE the watcher's housekeeping tick, and a rail is a real
# shellout (journal-act.sh stands up agent-watch.sh's library, then talks to git / gh / a driver pane).
# A dirty journal can hold a dozen findings at once, so acting on all of them in one pass would turn a
# housekeeping sweep into a minutes-long tick stall — the very "stuck" this item exists to end. Two
# bounds prevent that: each rail is wrapped in `timeout`, and at most _JA_ACT_MAX actions fire per
# sweep. Nothing is dropped: the once-guards are keyed by FINDING, not by sweep, so a finding not
# reached this pass is simply acted on the next one. Deliberate inline constant, not a config key
# (mirrors _MAIN_HEALTH_DIED_MAX); HERD_JOURNAL_AUDIT_ACT_MAX is a test seam, not an operator knob.
_JA_ACT_MAX="$(_num_or "${HERD_JOURNAL_AUDIT_ACT_MAX:-}" 3)"
_JA_ACT_SPENT=0
# Re-observations a MAPPED finding may survive, still standing, before the lifecycle pass escalates it
# (HERD-564/573; see _ja_act_lifecycle_pass below). Shares the SAME per-sweep budget as a fresh action
# — an escalation is a real scribe shellout, not a free journal line, so it must never be exempt from
# the "BOUNDED PER SWEEP" bound above. HERD_JOURNAL_AUDIT_ACT_MAX is still per-sweep total, not
# per-class; JOURNAL_AUDIT_ESCALATE_AFTER is the SEPARATE "how many sweeps of grace" knob.
_JA_ESCALATE_AFTER="$(_num_or "${JOURNAL_AUDIT_ESCALATE_AFTER:-}" 2)"
# RECURRENCE ESCALATION (HERD-597): distinct occurrences a DELIBERATE no-action class (fixture_slug,
# merged_hv_unknown) may accumulate, across every finding KEY that class has ever produced, before it
# is itself treated as a signal worth a human's attention — see _ja_noaction_recur below. Deliberate
# inline default, not a config key (mirrors _JA_ACT_MAX / _JA_ESCALATE_AFTER's own "test seam, not an
# operator knob" posture); HERD_JOURNAL_AUDIT_NOACTION_RECUR_MAX exists so tests can prove the
# threshold without seeding a dozen synthetic slugs.
_JA_NOACTION_RECUR_MAX="$(_num_or "${HERD_JOURNAL_AUDIT_NOACTION_RECUR_MAX:-}" 3)"

# _ja_act_enabled — true iff JOURNAL_AUDIT_ACT opts in. Default OFF; any unrecognized value reads as
# off (fail toward dormant — mirrors _ja_enabled above and every other ship-dormant lever).
_ja_act_enabled() {
  case "$(printf '%s' "${JOURNAL_AUDIT_ACT:-off}" | tr '[:upper:]' '[:lower:]')" in
    1|true|on|yes|enable|enabled) return 0 ;;
    *) return 1 ;;
  esac
}

# _ja_store_pysrc — pysrc/ for the shared-pool store shellout, or empty when it cannot be found
# (mirrors agent-watch.sh's _main_health_fix_pysrc). Empty ⇒ every caller falls back, never crashes.
_ja_store_pysrc() {
  local _sp_home _sp_pyp
  _sp_home="${HERDKIT_HOME:-$(cd "$HERE/../.." 2>/dev/null && pwd)}"
  _sp_pyp="$_sp_home/pysrc"
  [ -f "$_sp_pyp/herd/store.py" ] && printf '%s' "$_sp_pyp"
}

# _ja_act_once <guard-key> — true iff THIS call is the first, across every seat, to claim <guard-key>.
# Primary: the shared-pool once-guard (atomic, cross-seat). FALLBACK, when the store is unavailable
# (no pysrc, a store error): the auditor's own seen-ledger, which makes the guard seat-LOCAL but never
# lets one seat act twice — the safe direction. NB the seen-ledger is tail-trimmed at 500 lines, so a
# very long-lived dirty seat could in principle re-arm a fallback guard; that is a bounded second
# attempt on a finding that has been standing for hundreds of distinct findings, never a loop.
_ja_act_once() {
  local _ao_key="$1" _ao_pyp="" _ao_rc=0
  # `|| _ao_pyp=""`, NOT a bare assignment: this file runs under `set -e`, and _ja_store_pysrc exits
  # non-zero when the store module is absent — the very case this fallback exists for. A bare
  # assignment from a failing command substitution would abort the whole sweep instead of degrading.
  _ao_pyp="$(_ja_store_pysrc)" || _ao_pyp=""
  if [ -n "$_ao_pyp" ]; then
    PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$_ao_pyp" WORKTREES_DIR="${WORKTREES_DIR:-}" \
      python3 -m herd.store --once "$_ao_key" >/dev/null 2>&1 || _ao_rc=$?
    case "$_ao_rc" in
      0) return 0 ;;   # we won it
      3) return 1 ;;   # another seat / an earlier sweep already claimed it
      *) : ;;          # store unusable → fall through to the seat-local ledger
    esac
  fi
  _seen_has "$_ao_key" && return 1
  _seen_mark "$_ao_key"
  return 0
}

# _ja_noaction_hwm_advance <kind> <ts> — HERD-606. True iff <ts> (the underlying journal event's own
# epoch timestamp) is STRICTLY newer than the persisted per-class high-water mark for <kind> in the
# shared pool — a genuinely NEW occurrence, safe to feed into _ja_noaction_recur's counter — in which
# case the mark is atomically raised to <ts>. False iff <ts> is at-or-below the mark: this occurrence
# has ALREADY been counted (the same journal line replayed on a later sweep still inside the lookback
# window, or a once-guard claim that was lost) and must never inflate the recurrence tally again. This
# is a BACKSTOP on top of the per-key once-guard above, not a replacement for it: the once-guard is
# what is normally relied on to dedup a key; this closes the gap when that guard's protection is lost
# (its fallback — the seen-ledger — is tail-trimmed, see _ja_act_once's own comment) or the same event
# simply never left the bounded window between sweeps.
# <ts> empty/non-numeric (a caller that could not derive a stamp) or the shared-pool store unavailable
# both degrade to "count it" — the pre-HWM behavior — since the once-guard above is still the floor;
# this mark is additional protection, never the only one.
_ja_noaction_hwm_advance() {
  local _nh_kind="$1" _nh_ts="$2" _nh_pyp="" _nh_rc=0
  case "$_nh_ts" in ''|*[!0-9]*) return 0 ;; esac
  _nh_pyp="$(_ja_store_pysrc)" || _nh_pyp=""
  [ -n "$_nh_pyp" ] || return 0
  PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$_nh_pyp" WORKTREES_DIR="${WORKTREES_DIR:-}" \
    python3 -m herd.store --noaction-hwm-advance "$_nh_kind" "$_nh_ts" >/dev/null 2>&1 || _nh_rc=$?
  case "$_nh_rc" in
    0) return 0 ;;   # genuinely newer — count it
    3) return 1 ;;   # at-or-below the mark — a historical replay, never recount it
    *) return 0 ;;   # store unusable → degrade to counting (the once-guard above is still the floor)
  esac
}

# _ja_ctx_field <ctx> <name> — pull `<name>=<value>` out of a space-separated `k=v…` ctx string (the
# same shape journal-act.sh parses via its own word-split loop). Empty when absent.
_ja_ctx_field() {
  local _cf_ctx="$1" _cf_name="$2" _cf_kv
  for _cf_kv in $_cf_ctx; do
    case "$_cf_kv" in
      "${_cf_name}="*) printf '%s' "${_cf_kv#"${_cf_name}"=}"; return 0 ;;
    esac
  done
}

# _ja_act_mapped <kind> — true iff this finding class has a rail in journal-act.sh. Kept HERE, next to
# the escalation policy, and asserted against journal-act.sh's own case arms by the unit test: a class
# that gains a rail must gain it in both places or the test reds.
_ja_act_mapped() {
  case "$1" in
    merge_without_reap|dispatch_no_outcome|refix_bounce_no_wake|red_state_stale) return 0 ;;
    *) return 1 ;;
  esac
}

# _ja_act_no_action_reason <kind> — prints a reason and returns 0 iff <kind> is a DELIBERATE no-action
# class (HERD-562/HERD-563, extended HERD-600/HERD-606): the finding is real and stays REPORTED (the
# advisory half above is unaffected), but it is not itself a gap to route anywhere — neither to a rail
# (nothing to heal) nor to the scribe (filing it would be noise, not work). Checked BEFORE
# `_ja_act_mapped`'s unmapped fallthrough so these classes can never fall into the generic "file a
# tracker item" path:
#   fixture_slug             — evidence that a TEST/SIM fixture wrote to the LIVE journal (see
#                               tests/test-sim-journal-hermeticity.sh), not evidence of a production gap.
#                               The fix is a hermeticity guard on the leaking fixture, not a filed item
#                               every time its slug shows up in a bounded replay window.
#   merged_hv_unknown        — the PR body fetch failed (a transient `gh`/network hiccup); the NEXT
#                               sweep re-probes on its own (the seen-ledger only memoizes a SETTLED
#                               verdict, never an unknown one — see the (g) check above), so filing a
#                               permanent item for a transient read failure would be pure noise.
#   merged_hv_no_approval    — a merge that declared a HUMAN-VERIFY block but carries no sha-keyed
#                               approval record (see the (g) check above). Real signal — the declared
#                               steps may never have run — but the PR is already MERGED: no rail can
#                               retroactively verify unrun manual steps or undo the merge, so there is
#                               nothing bounded to route this to. A human has to look.
#   watcher_restart_blocked  — an orphaned lock holder is blocking watcher recovery, but the holder_pid
#                               is an UNIDENTIFIED process to this auditor: a rail that auto-killed it
#                               could just as easily kill a live builder mid-flight as an actual corpse.
#                               That call needs a human looking at the live pane/process, not a bounded
#                               rail guessing. Real signal, no safe automated action.
#   checkout_unclean         — reconcile_checkout_cleanliness deliberately LEAVES the contamination in
#                               the shared checkout in place (staged/tracked cruft, or a detached HEAD)
#                               as evidence for a human to inspect; see the (j) check above. A rail that
#                               auto-reset/auto-discarded it would destroy the very evidence the check
#                               exists to preserve, so no automated action may touch it.
# Each class still recurrence-escalates via _ja_noaction_recur (HERD-597) below: a class that keeps
# firing under distinct keys (a new holder_pid, a new head sha) is itself a signal nothing has looked at
# the root cause, and files ONE class-scoped item once that keeps recurring — gated by the per-class
# high-water mark (HERD-606, `_ja_noaction_hwm_advance` below) so a replayed/historical occurrence of a
# key that has already been counted can never inflate that tally a second time.
# This is a SHIPPED (hardcoded) mapping, not a config key — same posture as _ja_act_mapped just above.
_ja_act_no_action_reason() {
  case "$1" in
    fixture_slug)
      printf 'known-fixture slug — evidence of test/fixture pollution reaching the live journal, not a gap to file work against'
      ;;
    merged_hv_unknown)
      printf 'PR body unreadable (transient fetch failure) — the next sweep re-probes on its own; filing a permanent item for a transient read would be noise'
      ;;
    merged_hv_no_approval)
      printf 'merged with declared HUMAN-VERIFY steps and no approval record — the PR is already merged, so no rail can retroactively verify or undo it; a human must inspect it'
      ;;
    watcher_restart_blocked)
      printf 'orphaned lock holder blocking a watcher restart — the holder_pid is unidentified, so auto-killing it risks killing a live builder; a human must inspect it, no rail can safely act'
      ;;
    checkout_unclean)
      printf 'shared checkout left deliberately dirty as evidence for a human to inspect — an automated rail must never discard/reset the contamination itself'
      ;;
    *) return 1 ;;
  esac
}

# _ja_act_rail <kind> <key> <ctx> — drive the mapped rail, print its one-word result token.
# HERD_JOURNAL_AUDIT_ACT_CMD is the seam (invoked as `<cmd> <kind> <key> <ctx…>`); it defaults to the
# live journal-act.sh. Bounded by `timeout` where coreutils has it — a rail that hangs (a wedged
# driver RPC, a stalled `gh`) must never stall the watcher's housekeeping sweep. The token is scrubbed
# to [a-z0-9_-] so a misbehaving seam can never inject fields into the journal line below.
_ja_act_rail() {
  local _ar_cmd _ar_out=""
  _ar_cmd="${HERD_JOURNAL_AUDIT_ACT_CMD:-bash $HERE/journal-act.sh}"
  # Word-split deliberately: both the seam and $3 (the `k=v` context) are command-LINE fragments.
  # </dev/null: this runs inside the findings-reading loop, and a rail that read stdin would eat it.
  # shellcheck disable=SC2086
  if command -v timeout >/dev/null 2>&1; then
    _ar_out="$(timeout 60 $_ar_cmd "$1" "$2" $3 2>/dev/null </dev/null)" || _ar_out=""
  else
    _ar_out="$($_ar_cmd "$1" "$2" $3 2>/dev/null </dev/null)" || _ar_out=""
  fi
  # FIRST line only, via parameter expansion rather than `| head -1`: the rail is a command whose
  # output we do not control, and closing a pipe on it early is the EPIPE-under-pipefail shape.
  _ar_out="${_ar_out%%$'\n'*}"
  _ar_out="$(printf '%s' "$_ar_out" | tr -cd 'a-z0-9_-')"
  [ -n "$_ar_out" ] || _ar_out="failed"
  printf '%s' "$_ar_out"
}

# _ja_file_item <kind> <key> <summary> [escalated] — file ONE tracker item through the scribe so a gap
# (or a heal that did not take) becomes WORK. The caller's once-guard is the dedup; the finding KEY is
# carried in the body so a human — and a later sweep from a fresh pool — can still recognize the
# duplicate. First line is a SHORT title (the tracker backend takes line 1 verbatim as the title, so a
# long first line becomes an unreadable item).
_ja_file_item() {
  local _fi_kind="$1" _fi_key="$2" _fi_summary="$3" _fi_mode="${4:-unmapped}" _fi_cmd _fi_title _fi_body
  _fi_cmd="${HERD_JOURNAL_AUDIT_SCRIBE_CMD:-bash $HERE/scribe.sh}"
  if [ "$_fi_mode" = "escalated" ]; then
    _fi_title="journal-audit: ${_fi_kind} did not clear after its auto-action"
    _fi_body="The journal auditor (JOURNAL_AUDIT_ACT=on) ran the mapped action for this finding class and the finding was STILL found on a later sweep — the rail did not unstick it."
  elif [ "$_fi_mode" = "recurring" ]; then
    _fi_title="journal-audit: ${_fi_kind} keeps recurring (HERD-597)"
    _fi_body="This is a DELIBERATE no-action class (see _ja_act_no_action_reason in journal-audit.sh) — each individual occurrence is real but not itself actionable work. It has now recurred across ${_JA_NOACTION_RECUR_MAX}+ distinct findings, which is itself a signal that something keeps PRODUCING this condition and nobody has looked at the root cause. Filed once for the whole class (dedup key below is class-scoped, not per-finding); this class will never file again."
  else
    _fi_title="journal-audit: ${_fi_kind} has no mapped auto-action"
    _fi_body="The journal auditor found this class but NO rail owns it, so nothing can heal it automatically. Map it to a bounded action in scripts/herd/journal-act.sh (and _ja_act_mapped in journal-audit.sh), or record why it must stay advisory."
  fi
  _fi_title="${_fi_title:0:78}"
  # shellcheck disable=SC2086  # the seam is a command LINE, not a single argv[0]
  $_fi_cmd "$(printf '%s\n\n%s\n\nFinding: %s\nDedup key: %s\nFiled by: scripts/herd/journal-audit.sh (HERD-544)' \
    "$_fi_title" "$_fi_body" "$_fi_summary" "$_fi_key")" >/dev/null 2>&1 </dev/null
}

# _ja_noaction_recur <kind> <summary> — RECURRENCE ESCALATION (HERD-597). A deliberate no-action class
# (see _ja_act_no_action_reason) is inert PER OCCURRENCE, but a class that keeps recurring is itself a
# gap: something keeps PRODUCING the condition and nobody has looked at why. Live case that motivated
# this: fixture_slug fired for slug=retiree, slug=conv, slug=stuck across separate findings/sweeps —
# three DISTINCT keys of the SAME class — and none of them ever escalated, because the per-key guard in
# _ja_act's caller is (correctly) keyed per finding, not per class.
#
# Called ONLY when the caller's per-KEY once-guard (audit_noaction::<key>) just claimed a genuinely NEW
# occurrence — a repeat sighting of an already-counted key must never double-count. Counts distinct
# occurrences PER CLASS in NOACTION_COUNT (one row: "<class>\t<count>"); at _JA_NOACTION_RECUR_MAX or
# more, files ONE recurring-flagged item — dedup key is class-scoped ("recurring:<class>"), so this can
# never fire twice for the same class, and the per-key filings above it are never duplicated by it.
# Shares the SAME per-sweep action budget as every other real scribe shellout (BOUNDED PER SWEEP): if
# the budget is spent this sweep, the escalation is simply deferred to the next one — the count itself
# is never lost (it is upserted unconditionally, before the budget check).
_ja_noaction_recur() {
  local _nr_kind="$1" _nr_summary="$2" _nr_count=0 _nr_hit=0 _nr_k _nr_c _nr_tmp
  _nr_tmp="$(mktemp "${NOACTION_COUNT}.XXXXXX" 2>/dev/null || true)"
  [ -n "$_nr_tmp" ] || return 0
  : > "$_nr_tmp"
  if [ -s "$NOACTION_COUNT" ]; then
    while IFS=$'\t' read -r _nr_k _nr_c; do
      [ -n "$_nr_k" ] || continue
      if [ "$_nr_k" = "$_nr_kind" ]; then
        _nr_count=$(( ${_nr_c:-0} + 1 ))
        _nr_hit=1
        printf '%s\t%s\n' "$_nr_k" "$_nr_count" >> "$_nr_tmp"
      else
        printf '%s\t%s\n' "$_nr_k" "$_nr_c" >> "$_nr_tmp"
      fi
    done < "$NOACTION_COUNT"
  fi
  if [ "$_nr_hit" -eq 0 ]; then
    _nr_count=1
    printf '%s\t%s\n' "$_nr_kind" "$_nr_count" >> "$_nr_tmp"
  fi
  mv -f "$_nr_tmp" "$NOACTION_COUNT" 2>/dev/null || rm -f "$_nr_tmp" 2>/dev/null
  [ "$_nr_count" -ge "$_JA_NOACTION_RECUR_MAX" ] || return 0
  [ "$_JA_ACT_SPENT" -lt "$_JA_ACT_MAX" ] 2>/dev/null || return 0
  if _ja_act_once "audit_noaction_recurring::${_nr_kind}"; then
    _JA_ACT_SPENT=$((_JA_ACT_SPENT + 1))
    if _ja_file_item "$_nr_kind" "recurring:${_nr_kind}" "$_nr_summary" recurring; then
      journal_append audit_acted \
        class "$_nr_kind" \
        key "recurring:${_nr_kind}" \
        result recurring_filed \
        observations "$_nr_count" \
        component audit
      _inbox_append "audit-recurring:${_nr_kind}" "RECURRING no-action class (${_nr_count}+ occurrences) — filed for root-cause · ${_nr_summary}"
    fi
  fi
}

# _ja_act <kind> <key> <summary> <ctx> — the whole action policy for ONE finding. Hard no-op (and
# byte-identical output) while JOURNAL_AUDIT_ACT is off.
_ja_act() {
  _ja_act_enabled || return 0
  local _aa_kind="$1" _aa_key="$2" _aa_summary="$3" _aa_ctx="${4:-}" _aa_result="" _aa_reason=""
  # DELIBERATE NO-ACTION (HERD-562/HERD-563): own guard, own single journal line, NEVER escalates or
  # files — checked first and returns before touching the shared per-sweep budget or the
  # audit_act::/audit_escalate:: guards the mapped/unmapped paths below share.
  if _aa_reason="$(_ja_act_no_action_reason "$_aa_kind")"; then
    _ja_act_once "audit_noaction::${_aa_key}" || return 0
    journal_append audit_acted \
      class "$_aa_kind" \
      key "$_aa_key" \
      result no_action \
      reason "$_aa_reason" \
      component audit
    _inbox_append "audit-noaction:${_aa_kind}" "no-action (${_aa_reason}) · ${_aa_summary}"
    # RECURRENCE ESCALATION (HERD-597): this key was just claimed for the FIRST time, so it is a
    # genuinely new occurrence of the class — count it. A re-observation of an already-counted key
    # never reaches here (the once-guard above returns first). HERD-606: still gated on the per-class
    # high-water mark — a historical journal re-read that fooled the once-guard into re-claiming this
    # key (its fallback is a tail-trimmed ledger) must not inflate the recurrence tally a second time.
    if _ja_noaction_hwm_advance "$_aa_kind" "$(_ja_ctx_field "$_aa_ctx" ts)"; then
      _ja_noaction_recur "$_aa_kind" "$_aa_summary"
    fi
    return 0
  fi
  # Per-sweep budget spent → leave this finding for the next sweep. Checked BEFORE the once-guard so a
  # skipped finding does not burn its at-most-once claim without acting on it.
  [ "$_JA_ACT_SPENT" -lt "$_JA_ACT_MAX" ] 2>/dev/null || return 0
  if _ja_act_once "audit_act::${_aa_key}"; then
    _JA_ACT_SPENT=$((_JA_ACT_SPENT + 1))
    if _ja_act_mapped "$_aa_kind"; then
      _aa_result="$(_ja_act_rail "$_aa_kind" "$_aa_key" "$_aa_ctx")"
      # ACT-THEN-CLEAR (HERD-564/573): start tracking this key so a LATER sweep can prove the action
      # actually resolved the finding (audit_finding_cleared) instead of it firing once and the
      # finding just going quiet. See _ja_act_lifecycle_pass below, which owns clear-or-escalate for
      # everything appended here — this file is deliberately append-only.
      printf '%s\t%s\t0\t%s\n' "$_aa_key" "$_aa_kind" "$_aa_summary" >> "$PENDING" 2>/dev/null || true
    else
      # No rail owns this class: filing IS the action, and it is TERMINAL — burn the (per-key)
      # escalation guard in the same breath so this key can never later escalate into a duplicate.
      _ja_act_once "audit_escalate::${_aa_key}" >/dev/null 2>&1 || true
      # HERD-602: the guard above (audit_act::<key>) is keyed PER FINDING KEY, so a class that keeps
      # producing NEW keys (a new pr, a new slug, a new ts) reaches this branch once per key and would
      # file one tracker item per key — a flood of duplicates for what is really ONE gap. The actual
      # filing is therefore gated on a SECOND, CLASS-scoped guard: only the first key of a class ever
      # reaches the scribe; every later key of the same class still gets acted on (journaled, budget
      # spent, escalation guard burned) but never files again.
      if _ja_act_once "audit_unmapped_filed::${_aa_kind}"; then
        if _ja_file_item "$_aa_kind" "$_aa_key" "$_aa_summary"; then _aa_result="filed"; else _aa_result="file_failed"; fi
      else
        _aa_result="already_filed_for_class"
      fi
    fi
    journal_append audit_acted \
      class "$_aa_kind" \
      key "$_aa_key" \
      result "$_aa_result" \
      component audit
    _inbox_append "audit-act:${_aa_kind}" "auto-action ${_aa_result} · ${_aa_summary}"
    return 0
  fi
  # Already acted (or already claimed this sweep) — _ja_act_lifecycle_pass below is the ONLY place a
  # mapped finding's clear-or-escalate fires from now on. Re-entering here must never re-act, re-file,
  # or re-escalate.
  return 0
}

# _ja_act_lifecycle_pass — ACT-THEN-CLEAR (HERD-564/573). Resolves every key in the PENDING ledger
# (populated by _ja_act's mapped-rail branch above) against what THIS sweep's fresh replay actually
# found:
#   ABSENT from $FINDINGS  → the world proved the action worked (a reap landed, a green cleared the
#                            red, a wake_result was journaled, a gate slot's re-dispatch resolved the
#                            dispatch, …). Journal `audit_finding_cleared` and stop tracking.
#   STILL PRESENT           → one more re-observation. Below JOURNAL_AUDIT_ESCALATE_AFTER rounds, just
#                            re-store the incremented count and wait. At/past it, escalate LOUDLY
#                            exactly once (journal + inbox row + filed item, the SAME shape the old
#                            immediate-next-sighting escalate used) and stop tracking either way.
# This is what closes the loop the pre-HERD-564 code left open: an action fired once and the finding
# either sat mute forever (nothing ever said "this actually got fixed") or escalated on its very next
# sighting regardless of whether the rail's effect had had time to land — a false alarm for
# red_state_stale's `reverify_pending` result in particular, which explicitly defers to
# reconcile_main_health's OWN cadence rather than forcing anything itself.
#
# Runs BEFORE the main findings loop (and even when $FINDINGS comes back empty — a fully-resolved
# journal must still close out everything this seat was tracking) and shares the SAME per-sweep
# `_JA_ACT_SPENT`/`_JA_ACT_MAX` budget as a fresh action, so an escalation storm can never turn one
# sweep into a wall of scribe shellouts either.
_ja_act_lifecycle_pass() {
  [ -s "$PENDING" ] || return 0
  local _lp_live _lp_tmp _lp_key _lp_kind _lp_count _lp_summary _lp_result
  _lp_live="$(printf '%s\n' "$FINDINGS" | awk -F'\t' 'NF{print $2}')"
  _lp_tmp="$(mktemp "${PENDING}.XXXXXX" 2>/dev/null || true)"
  [ -n "$_lp_tmp" ] || return 0
  : > "$_lp_tmp"
  while IFS=$'\t' read -r _lp_key _lp_kind _lp_count _lp_summary; do
    [ -n "$_lp_key" ] || continue
    if ! grep -qxF -- "$_lp_key" <<<"$_lp_live" 2>/dev/null; then
      journal_append audit_finding_cleared \
        class "$_lp_kind" \
        key "$_lp_key" \
        observations "${_lp_count:-0}" \
        component audit
      _inbox_append "audit-cleared:${_lp_kind}" "finding cleared · ${_lp_summary}"
      continue
    fi
    _lp_count=$(( ${_lp_count:-0} + 1 ))
    if [ "$_lp_count" -ge "$_JA_ESCALATE_AFTER" ]; then
      if [ "$_JA_ACT_SPENT" -lt "$_JA_ACT_MAX" ] 2>/dev/null; then
        if _ja_act_once "audit_escalate::${_lp_key}"; then
          _JA_ACT_SPENT=$((_JA_ACT_SPENT + 1))
          if _ja_file_item "$_lp_kind" "$_lp_key" "$_lp_summary" escalated; then
            _lp_result="escalated"
          else
            _lp_result="escalate_file_failed"
          fi
          journal_append audit_acted \
            class "$_lp_kind" \
            key "$_lp_key" \
            result "$_lp_result" \
            component audit
          _inbox_append "audit-escalated:${_lp_kind}" "ESCALATED — auto-action did not clear it · ${_lp_summary}"
        fi
        # Either WE just escalated, or the guard was already claimed (another seat/sweep beat us to
        # it) — either way the escalation is SETTLED, so stop tracking rather than re-checking a guard
        # that will never again return true.
        continue
      fi
      # Past the escalate threshold but this sweep's budget is spent — defer to the next sweep rather
      # than skip the escalation outright (BOUNDED PER SWEEP, nothing dropped: same shape as the
      # fresh-action budget check in _ja_act above).
    fi
    printf '%s\t%s\t%s\t%s\n' "$_lp_key" "$_lp_kind" "$_lp_count" "$_lp_summary" >> "$_lp_tmp"
  done < "$PENDING"
  mv -f "$_lp_tmp" "$PENDING" 2>/dev/null || rm -f "$_lp_tmp" 2>/dev/null
}

if _ja_act_enabled; then
  _ja_act_lifecycle_pass
fi

# Clean / empty findings → silent (no journal spam on a healthy seat). Checked AFTER the lifecycle
# pass above so a sweep that just cleared/escalated its last pending finding still exits quietly here.
[ -n "$FINDINGS" ] || exit 0

n_new=0
while IFS=$'\t' read -r kind key summary ctx; do
  [ -n "$kind" ] || continue
  # ACT FIRST, on EVERY finding — new or already-reported. A finding the seen-ledger has muted is
  # still a live stall; muting the report must never mute the heal.
  _ja_act "$kind" "$key" "$summary" "${ctx:-}"
  _seen_has "$key" && continue
  _seen_mark "$key"
  # One journal_audit event per finding — component=audit so herd log filters cleanly.
  journal_append journal_audit \
    kind "$kind" \
    key "$key" \
    summary "$summary" \
    component audit
  # Operator-inbox row (source=audit). Rendered when OPERATOR_INBOX is on.
  _inbox_append "audit:${kind}" "$summary"
  n_new=$((n_new + 1))
done <<< "$FINDINGS"

# Loud-but-brief stdout when something NEW fired (watcher swallows this; CLI runs surface it).
if [ "$n_new" -gt 0 ]; then
  printf '🔎 journal-audit: %d new finding(s) (advisory only — never gates).\n' "$n_new"
fi
exit 0
