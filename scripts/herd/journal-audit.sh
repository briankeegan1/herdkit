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
#   (b) a *_dispatched event with no terminal outcome past a family TTL
#   (c) a refix_bounce with no matching refix_wake_result (same pr + sha + round)
#   (d) a red state (main_health result=red) older than a TTL with no later green
#   (e) pushed=no never followed by a later pushed=yes (codemap/symbol_index refresh)
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
# BINDING CONSTRAINTS:
#   • ADVISORY ONLY — never gates a merge, never mutates git/PRs/tracker/BACKLOG, never auto-heals.
#     Findings are journaled as `journal_audit` events (component=audit) and appended as operator-inbox
#     ledger rows so a human can see them. Nothing is fixed.
#   • SHIP-DORMANT — JOURNAL_AUDIT=off (default) is byte-inert: no journal read, no write, no inbox.
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
# Ensure parent dirs exist so inbox/seen writes never fail the advisory path.
mkdir -p "$(dirname "$INBOX")" "$(dirname "$SEEN")" 2>/dev/null || true

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

# ── replay: pure python scanner → one finding line per violation ─────────────
# Each stdout line:  kind\tkey\tsummary
# kind ∈ merge_without_reap | dispatch_no_outcome | refix_bounce_no_wake |
#        red_state_stale | pushed_no_unresolved | fixture_slug | watcher_restart_blocked
# key is a stable dedup token; summary is a short human phrase for the inbox row.
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

findings = []  # (kind, key, summary)

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
        findings.append(("merge_without_reap", key, summary))

# ── (b) *_dispatched with no terminal past family TTL ───────────────────────
# Terminal map: review_dispatched → verdict_recorded (same pr + sha when present).
# Any event whose name ends with _dispatched is considered; unknown families use a
# generic "any later same-pr event other than dispatch" is NOT enough — only known terminals.
def is_dispatched(name):
    return bool(name) and str(name).endswith("_dispatched")

TERMINALS = {
    "review_dispatched": {"verdict_recorded", "review_skipped", "review_carried_forward"},
}

dispatches = [e for e in events if is_dispatched(e.get("event"))]
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
        findings.append(("dispatch_no_outcome", key, summary))

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
        findings.append(("refix_bounce_no_wake", key, summary))

# ── (d) red state older than TTL ────────────────────────────────────────────
# main_health result=red without a later main_health result=green (any sha clears).
reds = [e for e in events if e.get("event") == "main_health" and str(e.get("result") or "") == "red"]
greens = [e for e in events if e.get("event") == "main_health" and str(e.get("result") or "") == "green"]
for r in reds:
    if age_secs(now, r["_ts"]) < red_ttl:
        continue
    # Cleared if any green lands after this red.
    ok = any(g["_ts"] > r["_ts"] for g in greens)
    if not ok:
        sha = str(r.get("sha") or "")
        key = "red_state_stale|sha=%s|ts=%s" % (sha, r["_ts"].strftime("%Y%m%dT%H%M%SZ"))
        summary = "MAIN RED older than TTL · sha=%s failed=%s" % (
            (sha[:8] if sha else "?"), str(r.get("failed") or r.get("detail") or "")[:60])
        findings.append(("red_state_stale", key, summary))

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
        findings.append(("pushed_no_unresolved", key, summary))

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
        findings.append(("fixture_slug", key, summary))

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
    findings.append(("watcher_restart_blocked", key, summary))

for kind, key, summary in findings:
    # TAB-separated; summary flattened (no tabs/newlines).
    summary = " ".join(summary.split())
    key = " ".join(key.split())
    print("%s\t%s\t%s" % (kind, key, summary))
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

# _ja_hv_add <kind> <key> <summary> — accumulate one finding line in the same TSV shape python emits.
HV_FINDINGS=""
_ja_hv_add() {
  local _row
  _row="$(printf '%s\t%s\t%s' "$1" "$2" "$3")"
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
    print("%s\t%s\t%s" % (pr, sha, evidence(pr, sha)))
PY
  )" || MERGES=""

  while IFS=$'\t' read -r _hv_pr _hv_sha _hv_evidence; do
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
        "merged PR body unreadable — human-verify approval unverifiable · pr=${_hv_pr} sha=${_hv_sha:-?}"
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
      "merged with HUMAN-VERIFY steps, ${_hv_why} · pr=${_hv_pr} sha=${_hv_sha:-?}"
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

# Clean / empty findings → silent (no journal spam on a healthy seat).
[ -n "$FINDINGS" ] || exit 0

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

n_new=0
while IFS=$'\t' read -r kind key summary; do
  [ -n "$kind" ] || continue
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
