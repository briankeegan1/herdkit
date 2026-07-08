#!/usr/bin/env bash
# backlog-reconcile-sweep.sh — periodic, ADVISORY reconcile SWEEP for backlog drift.
#
# The problem (backlog item "Auto-refix / direct hand-offs bypass backlog reconciliation"): some
# automated paths advance work to MERGED without any coordinator bookkeeping — REVIEW_AUTOFIX
# bounces a BLOCK straight to the builder and the watcher merges the fix; a coordinator DIRECT
# hand-off re-tasks a live builder mid-flight. Neither consults the backlog, so a 🔜 item that
# described that shipped work is never reaped and stays marked 🔜 forever (the observed backlog-
# drift pattern, e.g. items found already-shipped-but-still-🔜 around PR #66).
#
# This is OPTION (b): a periodic sweep that cross-references the OPEN 🔜 items in $BACKLOG_FILE
# against merged PRs (`gh pr list --state merged`) and recent commit subjects (`git log`) and
# surfaces the 🔜 items that probably already shipped. It runs TWO passes:
#   • EXACT-REF pass (FIRST, high signal) — if an open item carries a tracker id (e.g. HERD-49) and
#     that id token appears verbatim in ANY merged-PR title across the FULL merged history (limit
#     250, independent of merge recency), the item is a HIGH-confidence probably-shipped finding.
#     This catches the gap fuzzy title matching + a short recent-PR window both miss: HERD-49 sat
#     OPEN while merged PR #185 was literally titled "feat(HERD-49): …" 25h earlier (2026-07-08).
#   • FUZZY pass (SECOND, fallback) — for the items whose PRs don't carry the ref, fall back to the
#     key-term overlap heuristic below against recently-merged PRs + recent commit subjects.
# In both passes it surfaces the 🔜 items that probably shipped. It is deliberately:
#   • ADVISORY + NON-DESTRUCTIVE — the DEFAULT run only PRINTS a ranked candidate list for the
#     coordinator to review. It NEVER edits BACKLOG.md (the scribe is the one writer; the
#     coordinator owns the backlog) and never merges or touches git history.
#   • CONSERVATIVE — precision over recall. A missed candidate is fine; a wrong auto-reap is not.
#     Matching requires a strong distinctive-term overlap and drops bookkeeping/merge commits.
#   • OPT-IN for any write — only the explicit `--enqueue` flag enqueues ONE scribe reconcile
#     request per HIGH-confidence candidate (via scripts/herd/scribe.sh); the scribe then VERIFIES
#     and updates BACKLOG.md. Without the flag nothing is enqueued.
#
# Usage:
#   backlog-reconcile-sweep.sh [--enqueue] [--limit N]
#     (default)    scan open 🔜 items vs merged PRs + recent commits, PRINT ranked candidates.
#     --enqueue    additionally file ONE scribe reconcile request per HIGH-confidence candidate.
#     --limit N    how many recent merged PRs / commits to look back over (default 50).
#
# Hermetic seams (default to the real gh/git; the tests override them):
#   HERD_SWEEP_PRS_FILE        file of "<pr#>\t<title>" lines to use instead of `gh pr list` (fuzzy).
#   HERD_SWEEP_EXACT_PRS_FILE  file of "<pr#>\t<title>" lines for the exact-ref pass's FULL history
#                              (falls back to HERD_SWEEP_PRS_FILE, then to a limit-250 `gh pr list`).
#   HERD_SWEEP_COMMITS_FILE    file of "<sha>\t<subject>" lines to use instead of `git log`.
#   HERD_RECONCILE_SCRIBE      scribe enqueue command (default scribe.sh) — the enqueue seam.
#   JOURNAL_FILE               journal.sh's own seam for the backlog_reconcile_sweep summary event.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/herd-config.sh"
. "$HERE/journal.sh"        # journal_append (best-effort, silent) — for the sweep summary event.
REPO="$PROJECT_ROOT"
BACKLOG="$REPO/$BACKLOG_FILE"
PY="$(command -v python3 || true)"

_sweep_die() { echo "backlog-reconcile-sweep: $1" >&2; exit "${2:-1}"; }
[ -n "$PY" ] || _sweep_die "python3 is required" 1

# ── argument parsing ─────────────────────────────────────────────────────────
ENQUEUE=0
LIMIT="${SWEEP_LIMIT:-50}"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --enqueue) ENQUEUE=1 ;;
    --limit)   shift; LIMIT="${1:?--limit needs a number}" ;;
    --limit=*) LIMIT="${1#--limit=}" ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) _sweep_die "unknown argument: $1 (usage: backlog-reconcile-sweep.sh [--enqueue] [--limit N])" 2 ;;
  esac
  shift
done
case "$LIMIT" in ''|*[!0-9]*) LIMIT=50 ;; esac   # non-numeric → default
# The exact-ref pass scans the FULL merged-PR title history, independent of the fuzzy recency window.
EXACT_LIMIT="${SWEEP_EXACT_LIMIT:-250}"
case "$EXACT_LIMIT" in ''|*[!0-9]*) EXACT_LIMIT=250 ;; esac

# ── data sources (each has a hermetic file seam) ─────────────────────────────
# _merged_prs — "<pr#>\t<title>" per line, most-recent first. gh's default sort is newest-first.
_merged_prs() {
  if [ -n "${HERD_SWEEP_PRS_FILE:-}" ]; then cat "$HERD_SWEEP_PRS_FILE"; return 0; fi
  command -v gh >/dev/null 2>&1 || return 0
  (cd "$REPO" && gh pr list --state merged --limit "$LIMIT" --json number,title \
      -q '.[] | "\(.number)\t\(.title)"' 2>/dev/null) || true
}
# _merged_prs_exact — "<pr#>\t<title>" over the FULL merged history (limit 250) for the exact-ref
# pass. Independent of the fuzzy recency window so an id that shipped long ago is still caught.
# Fail-soft: a gh error yields empty output, which simply degrades that item to the fuzzy pass.
_merged_prs_exact() {
  if [ -n "${HERD_SWEEP_EXACT_PRS_FILE:-}" ]; then cat "$HERD_SWEEP_EXACT_PRS_FILE"; return 0; fi
  if [ -n "${HERD_SWEEP_PRS_FILE:-}" ]; then cat "$HERD_SWEEP_PRS_FILE"; return 0; fi
  command -v gh >/dev/null 2>&1 || return 0
  (cd "$REPO" && gh pr list --state merged --limit "$EXACT_LIMIT" --json number,title \
      -q '.[] | "\(.number)\t\(.title)"' 2>/dev/null) || true
}
# _recent_commits — "<shortsha>\t<subject>" per line, most-recent first.
_recent_commits() {
  if [ -n "${HERD_SWEEP_COMMITS_FILE:-}" ]; then cat "$HERD_SWEEP_COMMITS_FILE"; return 0; fi
  git -C "$REPO" log -n "$LIMIT" --format='%h%x09%s' 2>/dev/null || true
}

# ── matcher (pure python; the tests drive it through the file seams) ──────────
# TWO passes, exact-ref FIRST:
#   1. EXACT-REF — pull any tracker id token (e.g. HERD-49) out of each OPEN 🔜 item line and scan
#      the FULL merged-PR title history (EXACT_PRS) for that verbatim token. A hit is a HIGH-
#      confidence probably-shipped finding regardless of merge recency, citing the PR#. Items caught
#      here are removed from the fuzzy pass so they are surfaced/enqueued exactly once.
#   2. FUZZY — for the REMAINING items, extract the distinctive key terms of the item TITLE
#      (lowercased alnum tokens, ≥3 chars, not pure digits, minus a stop/domain-generic list) and
#      find the merged PR / commit whose subject shares the most of those terms. Confidence =
#      matched/total terms.
#        HIGH  → score ≥ $HI_SCORE AND matched ≥ $HI_TERMS  (auto-enqueue candidates)
#        MED   → score ≥ $MED_SCORE AND matched ≥ $MED_TERMS (printed, never auto-enqueued)
#        below → not a candidate (not printed) — favors precision.
# Bookkeeping ("Backlog:…") and merge ("Merge pull request/branch…") commit subjects are dropped:
# they echo item/branch text and would inflate false matches; merged PRs already cover that work.
# When EMIT_TSV is set, every HIGH candidate (exact + fuzzy) is ALSO written there as
#   <lineno>\t<title>\t<kind>\t<ref>\t<subject>\t<score>\t<matched>/<total>\t<via>
# for the --enqueue path to consume — matching runs exactly once. When EMIT_STATS is set, a single
#   <scanned>\t<exact_hits>\t<fuzzy_hits>
# line is written there for the summary journal event.
_match() {
  BACKLOG="$BACKLOG" \
  PRS="$(_merged_prs)" COMMITS="$(_recent_commits)" EXACT_PRS="$(_merged_prs_exact)" \
  HI_SCORE="${SWEEP_HIGH_SCORE:-0.6}"  HI_TERMS="${SWEEP_HIGH_TERMS:-3}" \
  MED_SCORE="${SWEEP_MED_SCORE:-0.5}"  MED_TERMS="${SWEEP_MED_TERMS:-2}" \
  EMIT_TSV="${EMIT_TSV:-}" EMIT_STATS="${EMIT_STATS:-}" \
  "$PY" -c '
import os, re, sys

backlog = os.environ["BACKLOG"]
hi_score, hi_terms = float(os.environ["HI_SCORE"]), int(os.environ["HI_TERMS"])
med_score, med_terms = float(os.environ["MED_SCORE"]), int(os.environ["MED_TERMS"])
emit_tsv = os.environ.get("EMIT_TSV", "")
emit_stats = os.environ.get("EMIT_STATS", "")

# Tracker id token, e.g. HERD-49, ROAD-12 — a prefix of ≥2 upper alnum chars + "-" + digits.
ID_RE = re.compile(r"\b([A-Z][A-Z0-9]+-[0-9]+)\b")

STOP = set("""
the a an and or to of in on for with via per its it is are be so that this these those when
if as at by from into onto after before now not no but than then must can could would should
do does did each any all still only over under up down off out more less own new old they their
them we our you your he she him her his was were has have had will not been being about across
adds add added fixes fix fixed change changed changes changing work works thing things item items
backlog herd herdkit engine coordinator scribe watcher lane pane tab feature builder
""".split())

def terms(text):
    out, seen = [], set()
    for tok in re.findall(r"[a-z0-9]+", text.lower()):
        if len(tok) < 3 or tok.isdigit() or tok in STOP or tok in seen:
            continue
        seen.add(tok); out.append(tok)
    return out

def open_items(path):
    try:
        lines = open(path, encoding="utf-8").read().splitlines()
    except OSError:
        return []
    items = []
    for i, ln in enumerate(lines, start=1):
        if "\U0001f51c" not in ln:            # 🔜 — only OPEN/queued items
            continue
        m = re.search(r"\*\*(.+?)\*\*", ln)   # the bold title
        if m:
            title = m.group(1).strip()
        else:                                 # fallback: text after 🔜 up to an em-dash
            after = ln.split("\U0001f51c", 1)[1]
            title = re.split(r"\s+[—–-]\s+", after.strip(), 1)[0].strip()
        ids = list(dict.fromkeys(ID_RE.findall(ln)))   # tracker id token(s) on the FULL line
        items.append((i, title, set(terms(title)), ids))
    return items

def candidates():
    cands = []
    for line in os.environ.get("PRS", "").splitlines():
        if "\t" not in line: continue
        ref, subj = line.split("\t", 1)
        if subj.strip(): cands.append(("PR", ref.strip(), subj.strip()))
    for line in os.environ.get("COMMITS", "").splitlines():
        if "\t" not in line: continue
        ref, subj = line.split("\t", 1)
        subj = subj.strip()
        if not subj: continue
        if re.match(r"(Backlog:|Merge pull request|Merge branch|Merge remote)", subj):
            continue                          # bookkeeping/merge noise — drop for precision
        cands.append(("commit", ref.strip(), subj))
    # Pre-tokenize each candidate subject to a membership set.
    return [(k, r, s, set(terms(s))) for (k, r, s) in cands]

def exact_prs():
    # "<pr#>\t<title>" over the FULL merged history — titles only, cheap. Newest-first.
    out = []
    for line in os.environ.get("EXACT_PRS", "").splitlines():
        if "\t" not in line: continue
        ref, subj = line.split("\t", 1)
        subj = subj.strip()
        if subj: out.append((ref.strip(), subj))
    return out

items = open_items(backlog)
cands = candidates()
epr = exact_prs()

# ── PASS 1: exact-ref ─────────────────────────────────────────────────────────
# For each open item carrying a tracker id, find the (most recent) merged PR whose title contains
# that id verbatim. A hit is HIGH-confidence probably-shipped, independent of merge recency. Items
# matched here are claimed (by line number) so the fuzzy pass skips them — surfaced/enqueued once.
exact_rows = []          # (lineno, title, ident, ref, subj)
exact_claimed = set()    # line numbers already surfaced by the exact pass
for (lineno, title, iterms, ids) in items:
    hit = None
    for ident in ids:
        needle = re.compile(r"\b" + re.escape(ident) + r"\b")
        for (ref, subj) in epr:               # epr is newest-first → cite the most recent carrier
            if needle.search(subj):
                hit = (ident, ref, subj); break
        if hit: break
    if hit:
        ident, ref, subj = hit
        exact_rows.append((lineno, title, ident, ref, subj))
        exact_claimed.add(lineno)

# ── PASS 2: fuzzy (fallback for items whose PRs do not carry the ref) ─────────
rows = []   # (score, matched, total, lineno, title, kind, ref, subj)
for (lineno, title, iterms, ids) in items:
    if lineno in exact_claimed:               # exact pass already claimed it — skip to avoid double-count
        continue
    if len(iterms) < med_terms:               # too few distinctive terms to judge — skip (precision)
        continue
    best = None
    for (kind, ref, subj, cterms) in cands:
        matched = iterms & cterms
        n = len(matched)
        if n == 0: continue
        score = n / len(iterms)
        key = (n, score)
        if best is None or key > best[0]:
            best = (key, score, n, kind, ref, subj, sorted(matched))
    if best is None: continue
    _, score, n, kind, ref, subj, matched = best
    total = len(iterms)
    if score >= hi_score and n >= hi_terms:
        conf = "HIGH"
    elif score >= med_score and n >= med_terms:
        conf = "MED"
    else:
        continue                              # incidental overlap — not a candidate
    rows.append((conf, score, n, total, lineno, title, kind, ref, subj, matched))

# Rank: HIGH before MED, then by score, then by matched-term count.
order = {"HIGH": 0, "MED": 1}
rows.sort(key=lambda r: (order[r[0]], -r[1], -r[2]))

n_open = len(items)
n_exact = len(exact_rows)
n_fuzzy = len(rows)
n_fuzzy_hi = sum(1 for r in rows if r[0] == "HIGH")
n_hi = n_exact + n_fuzzy_hi                    # every exact hit is HIGH-confidence
base = os.path.basename(backlog)
n_total = n_exact + n_fuzzy

if not exact_rows and not rows:
    print("backlog-reconcile-sweep: no probably-shipped 🔜 items — %d open item(s) scanned, none "
          "carry a merged tracker ref or strongly match recent merged work. Nothing to reconcile." % n_open)
else:
    print("backlog-reconcile-sweep: %d probably-shipped 🔜 candidate(s) of %d open item(s) "
          "(%d exact-ref, %d fuzzy; %d HIGH-confidence). Review before reconciling:\n"
          % (n_total, n_open, n_exact, n_fuzzy, n_hi))
    for (lineno, title, ident, ref, subj) in exact_rows:
        print("[HIGH exact] 🔜 %s  (%s:%d)" % (title, base, lineno))
        print("    ↳ PR #%s  “%s”" % (ref, subj))
        print("       tracker id %s appears verbatim in the merged PR title\n" % ident)
    for (conf, score, n, total, lineno, title, kind, ref, subj, matched) in rows:
        refname = ("PR #" + ref) if kind == "PR" else ("commit " + ref)
        print("[%-4s %3d%%] 🔜 %s  (%s:%d)" % (conf, round(score * 100), title, base, lineno))
        print("    ↳ %s  “%s”" % (refname, subj))
        print("       matched %d/%d key terms: %s\n" % (n, total, ", ".join(matched)))
    if n_hi:
        print("Run with --enqueue to file a scribe reconcile request for the %d HIGH-confidence "
              "candidate(s) (the scribe verifies before touching %s)." % (n_hi, base))
    else:
        print("No HIGH-confidence candidates — nothing would be enqueued. Review the MED matches by hand.")

# Machine-readable HIGH rows for the --enqueue path (exact hits first, then fuzzy HIGH).
if emit_tsv:
    with open(emit_tsv, "w", encoding="utf-8") as f:
        for (lineno, title, ident, ref, subj) in exact_rows:
            # score 1.00 / "1/1" — the tracker id matched exactly; via=exact drives the request wording.
            f.write("%d\t%s\t%s\t%s\t%s\t%.2f\t%s\t%s\n" %
                    (lineno, title, "PR", ref, subj, 1.0, "1/1", "exact:" + ident))
        for (conf, score, n, total, lineno, title, kind, ref, subj, matched) in rows:
            if conf != "HIGH": continue
            f.write("%d\t%s\t%s\t%s\t%s\t%.2f\t%d/%d\t%s\n" %
                    (lineno, title, kind, ref, subj, score, n, total, "fuzzy"))

# Summary counts for the audit journal event (written on EVERY run, even a silent one).
if emit_stats:
    with open(emit_stats, "w", encoding="utf-8") as f:
        f.write("%d\t%d\t%d\n" % (n_open, n_exact, n_fuzzy))
'
}

# ── scribe request for ONE high-confidence candidate ─────────────────────────
# Mirrors backlog-reconcile.sh: a precise prompt with a VERIFY command and a strict, non-
# destructive rule. The scribe confirms the work actually shipped before editing BACKLOG.md.
_build_request() {
  local title="$1" kind="$2" ref="$3" subj="$4" score="$5" matched="$6" lineno="$7" via="${8:-fuzzy}" refname verify
  if [ "$kind" = "PR" ]; then refname="PR #$ref"; verify="gh pr view $ref"; else refname="commit $ref"; verify="git show $ref"; fi
  if [ "${via#exact:}" != "$via" ]; then          # exact-ref hit: via="exact:<id>"
    local ident="${via#exact:}"
    printf 'Reconcile a probably-shipped-but-still-🔜 backlog item. The periodic reconcile sweep found a 🔜 item in %s whose tracker id (%s) appears verbatim in a merged PR title, which strongly suggests it shipped without being reaped.\n\n' "$BACKLOG_FILE" "$ident"
    printf 'SUSPECTED-SHIPPED ITEM:\n  - %s:%s  🔜 %s\n\n' "$BACKLOG_FILE" "$lineno" "$title"
    printf 'MATCHING MERGED WORK:\n  - %s — "%s"\n  - exact-ref match: the item id %s appears in this merged PR title\n\n' "$refname" "$subj" "$ident"
  else
    printf 'Reconcile a probably-shipped-but-still-🔜 backlog item. The periodic reconcile sweep found a 🔜 item in %s whose key terms strongly match recently-merged work, which suggests it shipped through an automated path (auto-refix or a direct hand-off) without being reaped.\n\n' "$BACKLOG_FILE"
    printf 'SUSPECTED-SHIPPED ITEM:\n  - %s:%s  🔜 %s\n\n' "$BACKLOG_FILE" "$lineno" "$title"
    printf 'MATCHING MERGED WORK:\n  - %s — "%s"\n  - term-overlap: score %s, %s key terms matched\n\n' "$refname" "$subj" "$score" "$matched"
  fi
  printf 'VERIFY FIRST, then act — do NOT reap on the term match alone:\n'
  printf '  1. Confirm the item actually shipped: run `%s` (and inspect the live repo) and check that the merged change genuinely IMPLEMENTS what this 🔜 item describes — not merely a title coincidence.\n' "$verify"
  printf '  2. IF confirmed shipped: move the item to the "## Recently shipped" section, rewriting it as a ✅ entry that names %s (e.g. "- ✅ **%s** *(%s)*"). This is the reap that the automated merge path skipped.\n' "$refname" "$title" "$refname"
  printf '  3. IF NOT clearly shipped (partial, or a coincidental match): do NOT move it. Leave it 🔜 and touch nothing — a missed reap is fine, a wrong one is not.\n\n'
  printf 'Edit ONLY %s. Do not merge, switch branches, or edit any other file.' "$BACKLOG_FILE"
}

# ── run ──────────────────────────────────────────────────────────────────────
[ -f "$BACKLOG" ] || _sweep_die "backlog file not found: $BACKLOG" 1

# _journal_summary — journal ONE backlog_reconcile_sweep event from the stats file the matcher wrote,
# so even a silent "nothing to reconcile" run is auditable. Best-effort: absent/garbled stats → skip.
_journal_summary() {
  local statsfile="$1" scanned exact fuzzy
  [ -f "$statsfile" ] || return 0
  IFS=$'\t' read -r scanned exact fuzzy < "$statsfile" || return 0
  [ -n "${scanned:-}" ] || return 0
  journal_append backlog_reconcile_sweep \
    scanned "${scanned:-0}" exact_hits "${exact:-0}" fuzzy_hits "${fuzzy:-0}" component sweep
}

STATS="$(mktemp "${TMPDIR:-/tmp}/sweep-stats.XXXXXX")"

if [ "$ENQUEUE" -eq 0 ]; then
  trap 'rm -f "$STATS"' EXIT
  EMIT_STATS="$STATS" _match                   # report-only (default): print ranked candidates
  _journal_summary "$STATS"
  exit 0
fi

# --enqueue: print the report AND file one scribe request per HIGH-confidence candidate.
TSV="$(mktemp "${TMPDIR:-/tmp}/sweep-high.XXXXXX")"
trap 'rm -f "$TSV" "$STATS"' EXIT
EMIT_TSV="$TSV" EMIT_STATS="$STATS" _match
_journal_summary "$STATS"
n=0
while IFS=$'\t' read -r lineno title kind ref subj score matched via; do
  [ -n "${lineno:-}" ] || continue
  req="$(_build_request "$title" "$kind" "$ref" "$subj" "$score" "$matched" "$lineno" "$via")"
  if bash "${HERD_RECONCILE_SCRIBE:-$HERE/scribe.sh}" "$req" >/dev/null 2>&1; then
    n=$((n + 1))
  else
    echo "backlog-reconcile-sweep: ⚠️  failed to enqueue a scribe request for '$title' (line $lineno)." >&2
  fi
done < "$TSV"

if [ "$n" -gt 0 ]; then
  echo ""
  echo "✍️  backlog-reconcile-sweep: enqueued $n scribe reconcile request(s) for HIGH-confidence candidate(s). The scribe verifies each before editing $BACKLOG_FILE."
else
  echo ""
  echo "backlog-reconcile-sweep: no HIGH-confidence candidates to enqueue."
fi
