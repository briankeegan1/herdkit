#!/usr/bin/env bash
# outcome-ledger.sh — the OUTCOME LEDGER MVP (HERD-739, week-1 child of the Governance & Proof EPIC):
# a per-tracker-item VALUE record, so the gate that already checks "is this change correct" gets a
# companion answer to "did this change turn out to be worth it". Correctness is gated; value was not
# — this is the first cut at closing that gap, deliberately small.
#
# NOT A DASHBOARD. This is a DERIVER + a reader:
#   • the substrate is the EXISTING engine journal (.herd/journal.jsonl + rotated archives) — the same
#     append-only JSONL every other reader (cost.sh, changelog.sh, journal-audit.sh) already reads.
#     No second bookkeeping file a builder must remember to write.
#   • ROWS are derived MECHANICALLY, keyed by tracker ref, by joining four existing event families:
#       reconcile          (pr → ref, emitted on every merge — work-units/git-pr.sh reconcile_backlog)
#       merge / merge_observed   (when + what sha landed)
#       cost                (spend, already split builder/review — scripts/herd/cost.sh)
#       verdict_recorded    (review verdicts, PASS/BLOCK + reason — record_review in agent-watch.sh)
#     plus refix_bounce-shaped events (review rework rounds) and two NEW event families this file
#     introduces and is the sole producer of:
#       intervention         (`herd intervene` — a human touched the pipeline; HERD-739 taxonomy)
#       outcome_ledger_eval  (the delayed +24h/+7d re-evaluation the sweep leg below fills)
#   • risk_class and disposition=reverted are the only fields that reach past the journal into git
#     history (a `git diff`/`git log --grep` against the already-checked-out repo — the SAME kind of
#     mechanical git lookup changelog.sh already does for its subject resolution). Every other field
#     is journal-only.
#
# HONEST SCOPE (read before trusting a row): disposition is MECHANICALLY {accepted, reverted, unknown}
# only — duplicate/abandoned dispositions would need a live tracker query (gh/linear) this reader
# deliberately never makes, so they are not claimed. declared "objective" (item title/body) is left
# blank for the same reason: this file makes ZERO live network calls, on purpose, so it stays usable
# offline and inside a hermetic test. A row with prs=[] but only interventions/evals is impossible —
# every row is anchored by at least one `reconcile` event, so a tracker ref that never had a PR merge
# through the git-pr work unit never gets a row (the mechanical-derivation trade-off, spelled out
# rather than silently claiming coverage it doesn't have).
#
# SHIP-DORMANT: OUTCOME_LEDGER=off (default). Every entry point below — `herd ledger-report`,
# `herd intervene`, and the sweep leg wired into `herd sweep` — refuses with one dormant line and does
# ZERO journal writes / ZERO file writes when off, mirroring agent-update.sh's AGENT_UPDATE=off
# posture. `herd sweep` output is BYTE-IDENTICAL with the lever off: the leg prints nothing and calls
# this file not at all (bin/herd's cmd_sweep gates the call itself, not just the script's own refusal).
#
# STAYS OFF agent-watch.sh HOT PATHS: this file is never sourced by agent-watch.sh and defines no
# per-tick behavior. The only automatic trigger is `herd sweep`'s leg 6 (bin/herd's cmd_sweep), an
# ON-DEMAND CLI command — never the watcher's per-~4s tick loop.
#
# Sourced (functions only, no side effect) by bin/herd's cmd_ledger_report / cmd_intervene, mirroring
# core-surface.sh's dual sourced-library-or-executed-CLI shape. Executed directly by cmd_sweep's leg 6:
#   bash scripts/herd/outcome-ledger.sh sweep
#
# CLI (executed form; `herd ledger-report` / `herd intervene` are the documented entry points):
#   outcome-ledger.sh report   [--json]           human summary, or the full derived model as JSON
#   outcome-ledger.sh alerts                       loud rows only; exit 1 iff at least one fired
#   outcome-ledger.sh daily    [--file PATH]       render + write today's UTC markdown report
#   outcome-ledger.sh sweep                        fill any DUE +24h/+7d evaluation slots
#   outcome-ledger.sh intervene <ref> <taxonomy> "<note>"   record one intervention
#
# Env seams (test-only; built-in defaults cover production):
#   HERD_OL_NOW           epoch seconds to treat as "now" (default: date -u +%s)
#   HERD_OL_WINDOW_24H    seconds before the first slot is due (default 86400)
#   HERD_OL_WINDOW_7D     seconds before the second slot is due (default 604800)

_OL_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── config / gate ──────────────────────────────────────────────────────────────────────────────
_ol_enabled() { [ "${OUTCOME_LEDGER:-off}" = "on" ]; }

# _ol_dormant_note <what> — the ONE off-message every entry point prints, mirroring
# agent-update.sh's "AGENT_UPDATE is off (opt-in)" line so the posture reads the same way twice.
_ol_dormant_note() {
  printf 'outcome-ledger: OUTCOME_LEDGER is off (opt-in) — %s did nothing. Enable with: herd config set OUTCOME_LEDGER on\n' "${1:-this command}"
}

# ── journal file resolution (mirrors changelog.sh's _cl_journal_files — same small idiom, kept as
# its own copy per this codebase's own precedent: cost.sh, changelog.sh and journal-audit.sh each
# carry an independent one rather than sharing a fourth-file extraction for six lines of glob+sort) ──
_ol_journal_files() {
  if [ -n "${JOURNAL_FILE:-}" ]; then
    [ -f "$JOURNAL_FILE" ] && printf '%s\n' "$JOURNAL_FILE"
    return 0
  fi
  local dir="${WORKTREES_DIR:-}/.herd"
  [ -n "${WORKTREES_DIR:-}" ] && [ -d "$dir" ] || return 0
  ls -1 "$dir"/journal-*.jsonl 2>/dev/null | sort || true
  [ -f "$dir/journal.jsonl" ] && printf '%s\n' "$dir/journal.jsonl"
  return 0
}

_ol_now() {
  if [ -n "${HERD_OL_NOW:-}" ]; then printf '%s' "$HERD_OL_NOW"; return 0; fi
  date -u +%s 2>/dev/null || printf '0'
}

# ── THE deriver — one python pass over every journal line, one optional git lookup per merged ref ──
# Reads journal file paths on stdin (oldest→newest, see _ol_journal_files). Emits the full derived
# model as ONE JSON object to stdout: {"rows": [...], "alerts": [...]}. Pure function of its inputs
# (journal contents + git history + now); never writes anything.
_OL_PY_DERIVE='
import sys, os, json, re, subprocess

NOW = int(os.environ.get("HERD_OL_NOW_RESOLVED", "0") or "0")
WIN24 = int(os.environ.get("HERD_OL_WINDOW_24H", "86400") or "86400")
WIN7D = int(os.environ.get("HERD_OL_WINDOW_7D", "604800") or "604800")
ROOT = os.environ.get("HERD_OL_PROJECT_ROOT", "")
CORE_GLOB = os.environ.get("HERD_OL_CORE_GLOB", "")

def parse_ts(ts):
    try:
        import datetime
        return int(datetime.datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ")
                    .replace(tzinfo=datetime.timezone.utc).timestamp())
    except Exception:
        return None

# ── pass 1: read every journal line once ──
pr_refs = {}          # pr -> set(ref) via reconcile
merges = {}           # pr -> list of {ts,ts_epoch,sha,slug}
cost_by_pr = {}        # pr -> {"builder":usd,"review":usd}
verdicts_by_pr = {}    # pr -> list of {sha,value,source,reason,ts}
refix_by_pr = {}       # pr -> int
interventions_by_ref = {}   # ref -> list
evals_by_ref = {}      # ref -> {"24h":{...},"7d":{...}}

for path in sys.stdin.read().split("\n"):
    path = path.strip()
    if not path:
        continue
    try:
        f = open(path, encoding="utf-8")
    except OSError:
        continue
    with f:
        for raw in f:
            raw = raw.strip()
            if not raw:
                continue
            try:
                o = json.loads(raw)
            except Exception:
                continue
            ev = o.get("event")
            ts = o.get("ts", "")
            if ev == "reconcile":
                pr = o.get("pr"); ref = o.get("ref")
                if pr is not None and ref:
                    pr_refs.setdefault(str(pr), set()).add(str(ref))
            elif ev in ("merge", "merge_observed"):
                pr = o.get("pr")
                if pr is None:
                    continue
                merges.setdefault(str(pr), []).append({
                    "ts": ts, "ts_epoch": parse_ts(ts) or 0,
                    "sha": o.get("sha") or "", "slug": o.get("slug") or "",
                })
            elif ev == "cost":
                pr = o.get("pr"); comp = o.get("component")
                if pr is None or comp not in ("builder", "review"):
                    continue
                try:
                    usd = float(o.get("usd") or 0)
                except (TypeError, ValueError):
                    usd = 0.0
                d = cost_by_pr.setdefault(str(pr), {"builder": 0.0, "review": 0.0})
                d[comp] = d.get(comp, 0.0) + usd
            elif ev == "verdict_recorded":
                pr = o.get("pr")
                if pr is None:
                    continue
                verdicts_by_pr.setdefault(str(pr), []).append({
                    "sha": o.get("sha") or "", "value": o.get("value") or "",
                    "source": o.get("source") or "", "reason": o.get("reason") or "", "ts": ts,
                })
            elif isinstance(ev, str) and ev.endswith("_bounce"):
                pr = o.get("pr")
                if pr is None:
                    continue
                refix_by_pr[str(pr)] = refix_by_pr.get(str(pr), 0) + 1
            elif ev == "intervention":
                ref = o.get("ref")
                if not ref:
                    continue
                interventions_by_ref.setdefault(str(ref), []).append({
                    "ts": ts, "taxonomy": o.get("taxonomy") or "", "note": o.get("note") or "",
                    "operator": o.get("operator") or "",
                })
            elif ev == "outcome_ledger_eval":
                ref = o.get("ref"); slot = o.get("slot")
                if not ref or slot not in ("24h", "7d"):
                    continue
                evals_by_ref.setdefault(str(ref), {})[slot] = {
                    "value": o.get("value") or "unknown", "evidence": o.get("evidence") or "", "ts": ts,
                }

# ── pass 2: git enrichment (best-effort, fail-soft to "unknown"/no-revert) ──
_revert_subjects = None
def _load_revert_subjects():
    global _revert_subjects
    if _revert_subjects is not None:
        return _revert_subjects
    _revert_subjects = []
    if not ROOT:
        return _revert_subjects
    try:
        out = subprocess.run(
            ["git", "-C", ROOT, "log", "--all", "--format=%H\x09%s"],
            capture_output=True, text=True, timeout=20,
        )
        if out.returncode == 0:
            for line in out.stdout.split("\n"):
                if "\x09" not in line:
                    continue
                h, subj = line.split("\x09", 1)
                _revert_subjects.append((h, subj))
    except Exception:
        pass
    return _revert_subjects

def _find_revert(pr, sha):
    if not pr:
        return ""
    needle = "#%s" % pr
    short = (sha or "")[:7]
    for h, subj in _load_revert_subjects():
        if not re.match(r"^\s*Revert\b", subj, re.I):
            continue
        if needle in subj or (short and short in subj):
            return h
    return ""

_diff_cache = {}
def _changed_files(sha):
    if not ROOT or not sha:
        return set()
    if sha in _diff_cache:
        return _diff_cache[sha]
    files = set()
    try:
        out = subprocess.run(
            ["git", "-C", ROOT, "diff", "--name-only", sha + "~1", sha],
            capture_output=True, text=True, timeout=20,
        )
        if out.returncode == 0:
            files = set(x for x in out.stdout.split("\n") if x.strip())
    except Exception:
        pass
    _diff_cache[sha] = files
    return files

def _risk_class(files):
    if not files:
        return "unknown"
    if CORE_GLOB:
        try:
            pat = re.compile(CORE_GLOB)
            if any(pat.search(f) for f in files):
                return "core-surface"
        except re.error:
            pass
    if any(re.match(r"^(scripts/herd/|templates/|bin/herd$)", f) for f in files):
        return "rails"
    if any(f.endswith(".md") or f.startswith("docs/") for f in files):
        return "docs"
    return "app"

# ── pass 3: build one row per ref ──
ref_to_prs = {}
for pr, refs in pr_refs.items():
    for ref in refs:
        ref_to_prs.setdefault(ref, set()).add(pr)

rows = []
for ref in sorted(ref_to_prs.keys()):
    prs = sorted(ref_to_prs[ref], key=lambda x: int(x) if x.isdigit() else 0)
    first_merge = None
    for pr in prs:
        for m in merges.get(pr, []):
            cand = dict(m); cand["pr"] = int(pr) if pr.isdigit() else pr
            if first_merge is None or (cand["ts_epoch"] or 0) < (first_merge["ts_epoch"] or 1 << 62):
                first_merge = cand

    spend_builder = sum(cost_by_pr.get(pr, {}).get("builder", 0.0) for pr in prs)
    spend_review = sum(cost_by_pr.get(pr, {}).get("review", 0.0) for pr in prs)

    verdicts = []
    for pr in prs:
        verdicts.extend(verdicts_by_pr.get(pr, []))
    block_count = sum(1 for v in verdicts if v.get("value") == "BLOCK")
    refix_rounds = sum(refix_by_pr.get(pr, 0) for pr in prs)

    revert_evidence = ""
    if first_merge is not None:
        revert_evidence = _find_revert(first_merge.get("pr"), first_merge.get("sha"))
    disposition = "unknown"
    if first_merge is not None:
        disposition = "reverted" if revert_evidence else "accepted"

    risk_class = "unknown"
    if first_merge is not None and first_merge.get("sha"):
        risk_class = _risk_class(_changed_files(first_merge["sha"]))

    evals = evals_by_ref.get(ref, {})
    rows.append({
        "ref": ref,
        "prs": [int(p) if p.isdigit() else p for p in prs],
        "risk_class": risk_class,
        "first_merge": first_merge,
        "spend": {"builder": round(spend_builder, 6), "review": round(spend_review, 6),
                   "total": round(spend_builder + spend_review, 6)},
        "verdicts": verdicts,
        "block_count": block_count,
        "refix_rounds": refix_rounds,
        "disposition": disposition,
        "revert_evidence": revert_evidence,
        "eval_24h": evals.get("24h"),
        "eval_7d": evals.get("7d"),
        "interventions": interventions_by_ref.get(ref, []),
    })

# ── pass 4: alerts ──
alerts = []
for r in rows:
    fm = r.get("first_merge")
    if not fm:
        continue
    age = NOW - (fm.get("ts_epoch") or 0)
    if age >= WIN24 and r.get("eval_24h") is None:
        alerts.append({"kind": "missing_eval_24h", "ref": r["ref"],
                        "detail": "no +24h evaluation recorded (%ds overdue)" % (age - WIN24)})
    if age >= WIN7D and r.get("eval_7d") is None:
        alerts.append({"kind": "missing_eval_7d", "ref": r["ref"],
                        "detail": "no +7d evaluation recorded (%ds overdue)" % (age - WIN7D)})
    if r.get("disposition") == "reverted":
        alerts.append({"kind": "reverted", "ref": r["ref"],
                        "detail": "reverted by %s" % r.get("revert_evidence", "?")})
    e7 = r.get("eval_7d")
    if age >= WIN7D and e7 is not None and e7.get("value") == "unknown":
        alerts.append({"kind": "unknown_value_7d", "ref": r["ref"],
                        "detail": "value still unknown %ds past the +7d checkpoint" % (age - WIN7D)})

print(json.dumps({"rows": rows, "alerts": alerts, "now": NOW}, separators=(",", ":")))
'

# _ol_derive_json — run the deriver, print the JSON model. Fail-soft: no journal / no python3 →
# {"rows":[],"alerts":[],"now":<now>}.
_ol_derive_json() {
  local files now
  files="$(_ol_journal_files)"
  now="$(_ol_now)"
  if ! command -v python3 >/dev/null 2>&1; then
    printf '{"rows":[],"alerts":[],"now":%s}' "$now"
    return 0
  fi
  printf '%s\n' "$files" \
    | HERD_OL_NOW_RESOLVED="$now" \
      HERD_OL_WINDOW_24H="${HERD_OL_WINDOW_24H:-86400}" \
      HERD_OL_WINDOW_7D="${HERD_OL_WINDOW_7D:-604800}" \
      HERD_OL_PROJECT_ROOT="${PROJECT_ROOT:-}" \
      HERD_OL_CORE_GLOB="${CORE_SURFACE_GLOB:-}" \
      python3 -c "$_OL_PY_DERIVE" 2>/dev/null || printf '{"rows":[],"alerts":[],"now":%s}' "$now"
}

# ── report / alerts / daily rendering (python-side formatting — one model, one place it becomes text) ──
_OL_PY_RENDER='
import sys, json

MODE = sys.argv[1]
model = json.loads(sys.stdin.read() or "{}")
rows = model.get("rows") or []
alerts = model.get("alerts") or []

def money(x):
    try:
        return "$%.2f" % float(x)
    except Exception:
        return "$0.00"

def evalmark(e):
    if e is None:
        return "\xe2\x8f\xb3"          # ⏳ pending
    v = e.get("value", "unknown")
    return {"valuable": "\xe2\x9c\x85", "neutral": "\xe2\x9e\x96",
            "harmful": "\xe2\x9d\x8c", "unknown": "\xe2\x9d\x93"}.get(v, "\xe2\x9d\x93") + " " + v

def render_alerts(lines):
    if not alerts:
        lines.append("no alerts \xe2\x80\x94 every merged ref is within its evaluation window")
        return
    for a in alerts:
        lines.append("\xe2\x9a\xa0\xef\xb8\x8f  %s \xe2\x80\x94 %s [%s]" % (a["ref"], a["detail"], a["kind"]))

if MODE == "report":
    lines = []
    if not rows:
        lines.append("outcome ledger: no ref has a recorded merge yet (nothing to report)")
    for r in rows:
        fm = r.get("first_merge") or {}
        verdict_bits = []
        passn = sum(1 for v in r["verdicts"] if v.get("value") == "PASS")
        if passn:
            verdict_bits.append("PASS x%d" % passn)
        if r["block_count"]:
            verdict_bits.append("BLOCK x%d" % r["block_count"])
        verdict_s = ", ".join(verdict_bits) if verdict_bits else "none"
        lines.append("%-14s %-9s spend=%s (builder %s / review %s)  verdict=%s  refix=%d" % (
            r["ref"], r["disposition"], money(r["spend"]["total"]),
            money(r["spend"]["builder"]), money(r["spend"]["review"]), verdict_s, r["refix_rounds"]))
        lines.append("               risk=%s  pr(s)=%s  evals: 24h %s  7d %s  interventions=%d" % (
            r["risk_class"], ",".join(str(p) for p in r["prs"]),
            evalmark(r.get("eval_24h")), evalmark(r.get("eval_7d")), len(r["interventions"])))
    lines.append("")
    lines.append("-- alerts --")
    render_alerts(lines)
    print("\n".join(lines))

elif MODE == "alerts":
    lines = []
    render_alerts(lines)
    print("\n".join(lines))
    sys.exit(1 if alerts else 0)

elif MODE == "daily":
    import datetime
    day = datetime.datetime.utcfromtimestamp(model.get("now", 0)).strftime("%Y-%m-%d")
    lines = ["# Outcome ledger \xe2\x80\x94 %s" % day, ""]
    if not rows:
        lines.append("_No merged tracker refs recorded yet._")
    else:
        lines.append("| ref | disposition | spend | verdict | risk | 24h | 7d | interventions |")
        lines.append("|---|---|---|---|---|---|---|---|")
        for r in rows:
            passn = sum(1 for v in r["verdicts"] if v.get("value") == "PASS")
            verdict_s = ("PASS x%d" % passn if passn else "") + (" BLOCK x%d" % r["block_count"] if r["block_count"] else "")
            verdict_s = verdict_s.strip() or "none"
            e24 = r.get("eval_24h"); e7 = r.get("eval_7d")
            lines.append("| %s | %s | %s | %s | %s | %s | %s | %d |" % (
                r["ref"], r["disposition"], money(r["spend"]["total"]), verdict_s, r["risk_class"],
                (e24["value"] if e24 else "pending"), (e7["value"] if e7 else "pending"),
                len(r["interventions"])))
    lines.append("")
    lines.append("## Alerts")
    render_alerts(lines)
    lines.append("")
    print("\n".join(lines))
'

# ol_report_text [--json] — the CLI summary (or the raw JSON model with --json).
ol_report_text() {
  local model; model="$(_ol_derive_json)"
  if [ "${1:-}" = "--json" ]; then
    printf '%s\n' "$model"
    return 0
  fi
  command -v python3 >/dev/null 2>&1 || { printf 'outcome-ledger: python3 unavailable — cannot render\n'; return 0; }
  printf '%s' "$model" | python3 -c "$_OL_PY_RENDER" report
}

# ol_alerts_text — loud alert lines only. Exit 1 iff at least one alert fired (0 = clean).
ol_alerts_text() {
  local model; model="$(_ol_derive_json)"
  command -v python3 >/dev/null 2>&1 || { printf 'outcome-ledger: python3 unavailable — cannot render\n'; return 0; }
  printf '%s' "$model" | python3 -c "$_OL_PY_RENDER" alerts
}

# ol_daily_write [<file>] — render today's UTC markdown report, write it (idempotent: skip when
# byte-identical), print the path. Default path: $WORKTREES_DIR/.herd/ledger-reports/<UTC date>.md.
ol_daily_write() {
  local model day file
  model="$(_ol_derive_json)"
  command -v python3 >/dev/null 2>&1 || { printf 'outcome-ledger: python3 unavailable — cannot render\n'; return 1; }
  day="$(date -u +%Y-%m-%d 2>/dev/null || echo unknown)"
  file="${1:-$WORKTREES_DIR/.herd/ledger-reports/$day.md}"
  local dir; dir="$(dirname "$file")"
  mkdir -p "$dir" 2>/dev/null || { printf 'outcome-ledger: cannot create %s\n' "$dir"; return 1; }
  local rendered; rendered="$(printf '%s' "$model" | python3 -c "$_OL_PY_RENDER" daily)"
  if [ -f "$file" ] && printf '%s' "$rendered" | cmp -s "$file" -; then
    printf '%s\n' "$file"
    return 0
  fi
  printf '%s' "$rendered" > "$file"
  printf '%s\n' "$file"
}

# ── sweep: fill DUE +24h/+7d evaluation slots (mechanical: revert > churn > valuable) ──
# Reads _ol_derive_json's model, journals one outcome_ledger_eval PER due-and-unrecorded slot. Never
# re-evaluates an already-recorded slot (idempotent — safe to run every `herd sweep`). Silent when
# nothing is due (matches the SAFE-leg posture of sweep.sh's other legs: quiet on a clean pass).
ol_sweep_evals() {
  type journal_append >/dev/null 2>&1 || {
    # shellcheck source=/dev/null
    [ -f "$_OL_HERE/journal.sh" ] && . "$_OL_HERE/journal.sh"
  }
  type journal_append >/dev/null 2>&1 || { printf 'outcome-ledger: journal.sh unavailable — sweep skipped\n'; return 0; }

  local model now win24 win7d
  model="$(_ol_derive_json)"
  command -v python3 >/dev/null 2>&1 || { printf 'outcome-ledger: python3 unavailable — sweep skipped\n'; return 0; }
  now="$(_ol_now)"
  win24="${HERD_OL_WINDOW_24H:-86400}"
  win7d="${HERD_OL_WINDOW_7D:-604800}"

  # One TSV line per DUE-and-unrecorded slot: ref \t pr \t slot \t value \t evidence
  local due
  due="$(printf '%s' "$model" | HERD_OL_NOW="$now" HERD_OL_WINDOW_24H="$win24" HERD_OL_WINDOW_7D="$win7d" python3 -c '
import sys, os, json

model = json.loads(sys.stdin.read() or "{}")
now = int(os.environ.get("HERD_OL_NOW", "0") or "0")
win24 = int(os.environ.get("HERD_OL_WINDOW_24H", "86400") or "86400")
win7d = int(os.environ.get("HERD_OL_WINDOW_7D", "604800") or "604800")
rows = model.get("rows") or []

# Churn: does ANOTHER refs merge, within the window, touch a file this refs merge also touched?
# Best-effort signal from the SAME model (no extra git calls): we only know file overlap when the
# deriver already resolved a risk_class from a real diff — lacking a raw file list here, this MVP
# uses the coarser, still-mechanical proxy of "another distinct ref merged within the window and
# shares this refs risk_class" (both landed in the same engine surface bucket). Documented as a
# coarser signal than a true path-set intersection; it never fabricates a valuable/harmful verdict.
def churn_peers(row, window):
    fm = row.get("first_merge") or {}
    t0 = fm.get("ts_epoch") or 0
    rc = row.get("risk_class")
    if rc in (None, "unknown"):
        return []
    peers = []
    for other in rows:
        if other is row:
            continue
        ofm = other.get("first_merge") or {}
        ot = ofm.get("ts_epoch") or 0
        if other.get("risk_class") != rc:
            continue
        if t0 < ot <= t0 + window:
            peers.append(other["ref"])
    return peers

out = []
for r in rows:
    fm = r.get("first_merge")
    if not fm:
        continue
    age = now - (fm.get("ts_epoch") or 0)
    pr = fm.get("pr")
    for slot, win in (("24h", win24), ("7d", win7d)):
        key = "eval_24h" if slot == "24h" else "eval_7d"
        if age < win or r.get(key) is not None:
            continue
        if r.get("disposition") == "reverted":
            value = "harmful"
            evidence = "reverted by %s" % r.get("revert_evidence", "?")
        else:
            peers = churn_peers(r, win)
            if peers:
                value = "neutral"
                evidence = "churn: %s also touched %s within +%s" % (",".join(peers), r.get("risk_class"), slot)
            else:
                value = "valuable"
                evidence = "no revert or same-surface churn detected within +%s" % slot
        evidence = evidence.replace("\t", " ").replace("\n", " ")
        out.append("%s\t%s\t%s\t%s\t%s" % (r["ref"], pr, slot, value, evidence))
print("\n".join(out))
')" || due=""

  [ -n "$due" ] || { printf 'outcome-ledger sweep: nothing due\n'; return 0; }

  local ref pr slot value evidence n24=0 n7d=0
  while IFS=$'\t' read -r ref pr slot value evidence; do
    [ -n "$ref" ] || continue
    journal_append outcome_ledger_eval ref "$ref" pr "$pr" slot "$slot" value "$value" evidence "$evidence"
    case "$slot" in 24h) n24=$((n24 + 1)) ;; 7d) n7d=$((n7d + 1)) ;; esac
  done <<EOF
$due
EOF
  printf 'outcome-ledger sweep: filled %d x 24h, %d x 7d eval(s)\n' "$n24" "$n7d"
}

# ── intervene: record one first-class intervention entry ──
_OL_TAXONOMY="safety product infra-recovery convenience"
ol_taxonomy_ok() {
  local t="$1" x
  for x in $_OL_TAXONOMY; do [ "$x" = "$t" ] && return 0; done
  return 1
}

# ol_intervene <ref> <taxonomy> <note> — journal one `intervention` event. Validates taxonomy against
# the fixed HERD-739 set; refuses (rc=2) rather than journaling a garbage taxonomy value a reader would
# then have to special-case forever.
ol_intervene() {
  local ref="${1:-}" taxonomy="${2:-}" note="${3:-}"
  [ -n "$ref" ] && [ -n "$taxonomy" ] && [ -n "$note" ] || {
    printf 'usage: herd intervene <ref> <safety|product|infra-recovery|convenience> "<note>"\n' >&2
    return 2
  }
  ol_taxonomy_ok "$taxonomy" || {
    printf 'herd intervene: unknown taxonomy "%s" (must be one of: %s)\n' "$taxonomy" "$_OL_TAXONOMY" >&2
    return 2
  }
  type journal_append >/dev/null 2>&1 || {
    # shellcheck source=/dev/null
    [ -f "$_OL_HERE/journal.sh" ] && . "$_OL_HERE/journal.sh"
  }
  type journal_append >/dev/null 2>&1 || { printf 'herd intervene: journal.sh unavailable\n' >&2; return 1; }
  local operator="${WATCHER_OWNER:-}"
  [ -n "$operator" ] || operator="$(whoami 2>/dev/null || echo unknown)"
  journal_append intervention ref "$ref" taxonomy "$taxonomy" note "$note" operator "$operator"
  printf 'intervened · %s [%s]: %s\n' "$ref" "$taxonomy" "$note"
}

# ── CLI (executed form only; sourcing this file defines functions and does nothing else) ──
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  # shellcheck source=/dev/null
  . "$_OL_HERE/herd-config.sh"
  _ol_verb="${1:-}"; shift || true
  case "$_ol_verb" in
    report)
      _ol_enabled || { _ol_dormant_note "herd ledger-report"; exit 0; }
      ol_report_text "$@" ;;
    alerts)
      _ol_enabled || { _ol_dormant_note "herd ledger-report --alerts"; exit 0; }
      ol_alerts_text ;;
    daily)
      _ol_enabled || { _ol_dormant_note "herd ledger-report --daily"; exit 0; }
      _ol_file=""
      case "${1:-}" in --file) _ol_file="${2:-}" ;; --file=*) _ol_file="${1#--file=}" ;; esac
      ol_daily_write "$_ol_file" ;;
    sweep)
      _ol_enabled || exit 0   # silent — the sweep leg's own gate already skipped the call; belt+suspenders
      ol_sweep_evals ;;
    intervene)
      _ol_enabled || { _ol_dormant_note "herd intervene"; exit 0; }
      ol_intervene "$@" ;;
    *)
      echo "usage: outcome-ledger.sh report [--json] | alerts | daily [--file PATH] | sweep | intervene <ref> <taxonomy> \"<note>\"" >&2
      exit 64 ;;
  esac
fi
