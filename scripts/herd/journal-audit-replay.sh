#!/usr/bin/env bash
# journal-audit-replay.sh — THE REPLAY half of journal-audit.sh (HERD-608), split out for exactly one
# reason: bash 3.2.57 — the SYSTEM /bin/bash the watcher pane resolves (no /opt/homebrew/bin on its
# PATH) — has a hard heredoc-parser cliff once a script crosses roughly 1271 total lines: past that,
# `bash -n` throws a FALSE "syntax error near unexpected token `('" at an UNRELATED heredoc far from
# whatever actually changed, while GNU bash 5.x and shellcheck parse the identical file cleanly (not
# unicode-related — a pure line/byte-count threshold). journal-audit.sh sat a handful of lines below
# that cliff, so the NEXT edit to it was one false syntax error away from a guards-blind failure
# visible ONLY in the watcher's environment — a dev box with a homebrew bash on PATH never sees it
# (scripts/herd/bash-syntax-lint.sh is the standing guard that now catches this class before it ever
# reaches the watcher pane).
#
# The fix is structural, not behavioral: journal-audit.sh's two heaviest blocks — the python replay
# scanner that turns a bounded journal window into FINDINGS, and the merge/approval-evidence scanner
# that turns the same window into MERGES for check (g) — are self-contained (no dependency on
# anything journal-audit.sh does AFTER invoking them), so they move here VERBATIM — same env-var
# contract, same stdout shape, same exit status — and journal-audit.sh calls them instead of
# embedding the heredocs inline. This keeps BOTH files well clear of the cliff.
#
# Sourced (never executed) by journal-audit.sh ONLY, right after herd-config.sh/journal.sh/
# human-verify.sh/approvals.sh/aging-pr.sh — same convention as every other scripts/herd/*.sh sourced
# library (see journal.sh's own header). Defines two functions only; no source-time side effects, so
# a partially-upgraded tree missing it fails loudly at the FIRST call rather than silently.
#
# _ja_replay_findings — reads env/globals journal-audit.sh has already resolved before calling it
# (_jf, WINDOW_SECS, DISPATCH_TTL, REFIX_TTL, RED_TTL, MERGE_GRACE, PUSHED_GRACE, FIXTURE_SLUGS,
# AGING_PR_TTL_SECS, HERD_JOURNAL_AUDIT_NOW) and prints the FINDINGS TSV on stdout — one
# kind\tkey\tsummary\tctx line per violation, exactly as documented above the FINDINGS assignment's
# old location and above _ja_act in journal-audit.sh. Caller:
#   FINDINGS="$(_ja_replay_findings)" || FINDINGS=""
#
# _ja_replay_merges — reads _jf, WINDOW_SECS, HERD_JOURNAL_AUDIT_NOW and prints the MERGES TSV on
# stdout — one pr\tsha\tevidence\tts line per distinct merge in the window, exactly as documented
# above check (g) in journal-audit.sh. Caller:
#   MERGES="$(_ja_replay_merges)" || MERGES=""

# shellcheck disable=SC2016
_ja_replay_findings() {
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
# Terminal map: review_dispatched → a collected review outcome (same pr + sha when present).
# Any event whose name ends with _dispatched is considered; unknown families use a
# generic "any later same-pr event other than dispatch" is NOT enough — only known terminals.
def is_dispatched(name):
    return bool(name) and str(name).endswith("_dispatched")

# HERD-607: a dispatch finding needs work identity (a pr or a slug); a heartbeat like
# engine_live_dispatched has neither and never gets a terminal event by design.
def has_work_identity(ev):
    return bool(ev.get("pr")) or bool(ev.get("slug"))

TERMINALS = {
    # review_latency is emitted only when _review_gate_step collects an attempt, including
    # non-verdict INFRA attempts that are retried instead of becoming verdict_recorded.
    "review_dispatched": {"verdict_recorded", "review_skipped", "review_carried_forward", "review_latency"},
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

# ── (b') RESULT-SHAPED dispatches: event=main_health result=dispatched ───────
# HERD-612 leg 4 — the same guards-blind shape as HERD-607: check (b) above keys off the event NAME
# ending in "_dispatched", but the main-health rail journals a CONSTANT event name (`main_health`) and
# carries its lifecycle stage in the `result` FIELD. A died main-health chain was therefore invisible to
# this auditor by construction. GROUNDED: `main_health result=dispatched pid=47281 sha=0f50601` on
# 2026-08-07T14:31:16Z never got a terminal — the worker died between the suite passing and the verdict
# write — and MAIN RED stood for three days with the evidence sitting unread in this very journal.
#
# Scanned per SHA (a main-health dispatch's identity is its sha; its `pr` is routinely the placeholder
# "?" for a sha this seat did not merge, so pr can neither key nor filter it).
#
# WHAT CLOSES A CHAIN is defined as a DENY-list of the results that START one, not an allow-list of the
# ones that end it. That direction is load-bearing (review BLOCK on the first cut of this leg, which
# allow-listed green/red/partial_clear/infra_event): an allow-list makes this scan's correctness depend
# on it enumerating the rail's ENTIRE result vocabulary forever, and the day the rail grows a terminal
# the list does not know about, every healthy chain ending that way is reported STRANDED — a false,
# permanently unclearable finding that escalates into an operator alarm. The two error directions are
# not symmetric: a missed terminal fabricates alarms about work that completed, while a missed START
# token (the deny-list's own failure mode) only means one genuinely-stranded chain goes unreported,
# which is the pre-HERD-612 status quo for this whole rail. Fail toward believing work finished.
#
# The three non-terminals, each of which announces that a run is BEGINNING:
#   dispatched      — a worker was backgrounded for this sha (this is the event being reconciled);
#   recheck         — a cadence / one-shot re-verify is starting another run for it;
#   chain_collected — HERD-612 leg 3 wrote the dead worker's result file; the COLLECTOR still has to
#                     route it, and that routing is what journals the real terminal a tick later.
# "LATER" IS JOURNAL ORDER, NOT A TIMESTAMP COMPARISON. Journal ts carries whole-second resolution, so
# a terminal written in the SAME second as its dispatch — a verdict that lands fast (an infra_event off
# a worker that could not even start), or simply an unlucky second boundary — is not `> d["_ts"]` and a
# ts-strict scan reports the chain stranded. Found by replaying a REAL engine journal through this
# scanner rather than a hand-written fixture: the engine emitted dispatch + terminal in one second and
# this leg still raised a finding. `events` is built in file order and sorted STABLY, so the index is
# the journal's own order and is exact where the clock is not.
MH_NON_TERMINAL = {"dispatched", "recheck", "chain_collected"}

# TERMINATED-SUPERSEDED (HERD-631). $MAIN only ever moves forward, so a LATER `dispatched` for a
# DIFFERENT sha is the rail explicitly starting a fresh chain for a new observed head — it is the
# signal that the OLDER sha's own chain was abandoned, not stalled. If that fresh chain (or whichever
# sha eventually supersedes IT) reaches a genuine terminal, the older sha's missing terminal is
# EXPLAINED — a completed chain wearing a stale sha, not an outcome-less one. Grounded in three real
# corpses (HERD-627/628/629): dispatches at a816294 (11:43), 0541883 (12:23), 18d7e7f (14:19), each
# re-dispatched before completing, with a green finally collected at 18d7e7f (14:45) — a816294 and
# 0541883 are terminal-superseded.
#
# DELIBERATELY NOT "any later terminal on any other sha closes this one": a bare terminal for an
# unrelated sha with no EXPLICIT dispatch chaining it to this one is not evidence the rail itself
# advanced past this sha — see the regression below (a stray green on an unrelated sha, with no
# intervening dispatch, must never paper over a genuinely dead worker; that is exactly how the live
# corpse hid in the first place).
def _mh_chain_terminates(start_i, start_sha):
    """True iff walking forward from start_i, a chain of explicit `dispatched` events for
    successively different shas eventually reaches one with its own genuine (non-MH_NON_TERMINAL)
    terminal — i.e. main superseded start_sha and the fresh chain it superseded to actually finished."""
    cur_sha, cur_i, chain_seen = start_sha, start_i, {start_sha}
    while True:
        nxt = None
        for j in range(cur_i + 1, len(events)):
            e = events[j]
            if str(e.get("event") or "") != "main_health" or str(e.get("result") or "") != "dispatched":
                continue
            nsha = str(e.get("sha") or "")
            if not nsha or nsha in chain_seen:
                continue
            nxt = (j, nsha)
            break
        if nxt is None:
            return False
        next_i, next_sha = nxt
        chain_seen.add(next_sha)
        for e in events[next_i + 1:]:
            if str(e.get("event") or "") != "main_health" or str(e.get("sha") or "") != next_sha:
                continue
            res = str(e.get("result") or "")
            if res and res not in MH_NON_TERMINAL:
                return True
        cur_sha, cur_i = next_sha, next_i

_mh_stranded = []  # (ts, sha, pr) candidates — collapsed to at most one finding below (HERD-631 leg a)
for _mh_i, d in [(i, e) for i, e in enumerate(events)
                 if str(e.get("event") or "") == "main_health" and str(e.get("result") or "") == "dispatched"]:
    if age_secs(now, d["_ts"]) < dispatch_ttl:
        continue
    sha = str(d.get("sha") or "")
    if not sha:
        continue                      # no sha ⇒ no identity to reconcile against (fail-soft, never a finding)
    ok = False
    for e in events[_mh_i + 1:]:
        if str(e.get("event") or "") != "main_health":
            continue
        if str(e.get("sha") or "") != sha:
            continue
        res = str(e.get("result") or "")
        if res and res not in MH_NON_TERMINAL:
            ok = True
            break
    if ok:
        continue
    if _mh_chain_terminates(_mh_i, sha):
        continue                      # terminal-superseded (HERD-631) — not outcome-less
    _mh_stranded.append((d["_ts"], sha, d.get("pr")))

# SHA-AGNOSTIC DEDUP (HERD-631 leg a). The root of a stranded main_health chain is the RAIL — there is
# only one $MAIN — not any one sha, so at most ONE open dispatch_no_outcome item exists for this class
# at a time, refreshed each sweep with the NEWEST offending sha rather than filing one duplicate per
# corpse (the pre-fix behavior that produced HERD-627/628/629 for what was really one gap). Dropping
# the sha from the key is what makes the once-guards and PENDING tracking downstream hold that
# property: a second sha under this same class matches the SAME tracked key and refreshes it rather
# than opening (or escalating into) a second item.
if _mh_stranded:
    _mh_stranded.sort(key=lambda t: t[0])
    _mh_ts, _mh_sha, _mh_pr = _mh_stranded[-1]
    key = "dispatch_no_outcome|main_health"
    summary = "main_health dispatch with no terminal · sha=%s pr=%s" % (
        _mh_sha[:8], _mh_pr if _mh_pr is not None else "?")
    findings.append(("dispatch_no_outcome", key, summary,
                     ctx(pr=_mh_pr, sha=_mh_sha, event="main_health")))

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
_red_stale = []  # (ts, sha, pr, failed) candidates — collapsed to at most one finding below (HERD-631 leg a)
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
        _red_stale.append((r["_ts"], sha, r.get("pr"), str(r.get("failed") or r.get("detail") or "")[:60]))

# SHA-AGNOSTIC DEDUP (HERD-631 leg a). $MAIN is a single branch, so the root of a standing red is the
# RAIL, not any one sha — collapse every simultaneously-stale sha down to at most ONE open
# red_state_stale item, refreshed each sweep with the newest offending sha (the HERD-610/611
# duplications are the fixture for this same shape). Dropping the sha from the key is what lets the
# once-guards / PENDING tracking downstream hold a single tracked finding across shifting corpses.
if _red_stale:
    _red_stale.sort(key=lambda t: t[0])
    _r_ts, _r_sha, _r_pr, _r_failed = _red_stale[-1]
    key = "red_state_stale"
    summary = "MAIN RED older than TTL · sha=%s failed=%s" % ((_r_sha[:8] if _r_sha else "?"), _r_failed)
    findings.append(("red_state_stale", key, summary, ctx(pr=_r_pr, sha=_r_sha)))

# ── (k) gates passed but no merge older than TTL (HERD-334; HELD-VS-UNOWNED split HERD-634) ──
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
# with no such merge → a finding. Shares the render pass's AGING_PR_TTL threshold (aging-pr.sh); 0
# disables this leg. Advisory only — the auditor never merges or clears anything.
#
# HELD vs UNOWNED (HERD-634, root instance: PR 742 sat blessed-but-unmerged 3.5h, but it was HELD —
# serialized behind PR 741's core-diff mutex, not stuck). Not every unmerged-past-TTL blessing is a
# gap: the live engine's OWN merge-ordering rails (core-diff serialization HERD-577, MERGE_QUEUE
# HERD-273, MERGE_POLICY=approve / a declared HUMAN-VERIFY hold) each journal a hold event the SAME
# tick they hold a candidate that just got blessed — same pr, same sha (live_runtime.py's hold
# decision runs on the same cand right after the blessing it followed, before any push could change
# the sha). A hold event sharing the blessing's (pr, sha) is therefore proof this PR is a KNOWN,
# deliberately-serialized wait, not an unowned stall — label it held-not-stuck (no action, no filing;
# see _ja_act_no_action_reason's gates_passed_held case in journal-audit.sh). No hold evidence at all
# past the TTL is the genuinely unowned case and keeps the gates_passed_no_merge kind, now MAPPED to a
# bounded re-verify nudge (see journal-act.sh).
if aging_pr_ttl > 0:
    blessings = [e for e in events
                 if e.get("event") in ("gate_status", "blessing")
                 and str(e.get("state") or "") == "success"
                 and str(e.get("context") or "herd/gates") == "herd/gates"]
    # Evidence a candidate was HELD, not dropped: core-diff serialization, MERGE_QUEUE ordering, and
    # the approve/human-verify hold — the three rails that can legitimately sit a blessed PR without
    # merging it. Each fires once per (pr, sha) the same tick it holds that candidate.
    hold_events = [e for e in events
                   if e.get("event") in ("core_surface_hold", "merge_queue_hold", "hold_applied")]
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
        held = pr is not None and any(
            h.get("pr") is not None and str(h.get("pr")) == str(pr)
            and str(h.get("sha") or "") == sha and h["_ts"] >= b["_ts"]
            for h in hold_events)
        if held:
            key = "gates_passed_held|pr=%s|sha=%s" % (pr if pr is not None else "", sha)
            summary = "engine-approved and HELD (serialized/awaiting-approval), not stuck · pr=%s sha=%s" % (
                pr if pr is not None else "?", (sha[:8] if sha else "?"))
            findings.append(("gates_passed_held", key, summary, ctx(pr=pr, sha=sha, slug=b.get("slug"))))
            continue
        key = "gates_passed_no_merge|pr=%s|sha=%s" % (pr if pr is not None else "", sha)
        summary = "engine-approved but unmerged past TTL, no hold evidence · pr=%s sha=%s — unowned?" % (
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
}

# shellcheck disable=SC2016
_ja_replay_merges() {
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
}
