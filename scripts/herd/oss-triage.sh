#!/usr/bin/env bash
# oss-triage.sh — OSS auto-triage (HERD-255 / HERD-168 part 1/3).
#
# Classify + draft replies for incoming GitHub issues on HERD_REPO via the READ-ONLY research
# lane. FAIL-SOFT, OPT-IN, NEVER auto-posts (drafts for human approval only).
#
# Gate: OSS_TRIAGE=off (default) → byte-inert: no gh, no research enqueue, no files written.
# When on: list open issues (gh issue list), enqueue one research.sh request per NEW issue to
# classify (bug/feature/question/duplicate) + draft a suggested reply/labels, then write a
# ranked shortlist report for the coordinator. Re-runs collect ready research reports into the
# shortlist without re-enqueuing already-seen issues.
#
# Invoked by bin/herd (`herd triage …`) or standalone:
#   bash scripts/herd/oss-triage.sh [run|report|help] [--limit N]
#
# Test seams (never needed in production):
#   HERD_OSS_RESEARCH_SH  — path to research.sh (or a stub that prints REQ_ID <id>)
#   HERD_OSS_TRIAGE_DIR   — override the state/report directory
#   RESEARCH_REPORTS      — where research-get looks for filed findings
set -euo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/herd-config.sh"

# ── paths / seams ──────────────────────────────────────────────────────────────────────────────
ROOT="${PROJECT_ROOT:-$(pwd)}"
TREES="${WORKTREES_DIR:-$ROOT/.herd-trees}"
TRIAGE_DIR="${HERD_OSS_TRIAGE_DIR:-$TREES/.herd/oss-triage}"
STATE_FILE="$TRIAGE_DIR/seen.tsv"
SHORTLIST_FILE="$TRIAGE_DIR/shortlist.md"
INBOX_FILE="$TRIAGE_DIR/inbox"   # operator-facing one-line pointers (mirrors research inbox shape)
REPORTS="${RESEARCH_REPORTS:-$TREES/research-reports}"
RESEARCH_BIN="${HERD_OSS_RESEARCH_SH:-$HERE/research.sh}"
LIMIT_DEFAULT=50

_die()  { printf 'herd triage: %s\n' "$*" >&2; exit 2; }
_say()  { printf '%s\n' "$*"; }
_warn() { printf 'herd triage: %s\n' "$*" >&2; }

_usage() {
  cat <<'EOF'
usage: herd triage [run|report|help] [--limit N]

  run (default)  List open issues on HERD_REPO, enqueue research for NEW issues
                 (classify + draft reply), collect ready reports into a ranked
                 shortlist. NEVER posts, comments, closes, or labels on GitHub.
  report         Print the current ranked shortlist (if any).
  help           This help.

Opt-in via OSS_TRIAGE=on in .herd/config (default off → byte-inert).
Drafts are for human approval only — nothing is auto-posted.
EOF
}

# True iff OSS_TRIAGE opts in. Default OFF; only on|true|1|yes|enable|enabled enable it.
_oss_triage_enabled() {
  case "$(printf '%s' "${OSS_TRIAGE:-off}" | tr '[:upper:]' '[:lower:]')" in
    on|true|1|yes|enable|enabled) return 0 ;;
    *) return 1 ;;
  esac
}

# Rank for shortlist order: lower = higher priority.
_class_rank() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    bug)       printf '1' ;;
    feature)   printf '2' ;;
    question)  printf '3' ;;
    duplicate) printf '4' ;;
    pending)   printf '8' ;;
    *)         printf '9' ;;
  esac
}

_ensure_dir() {
  mkdir -p "$TRIAGE_DIR" "$REPORTS" 2>/dev/null || true
  if [ ! -f "$STATE_FILE" ]; then
    printf '# number\treq_id\tstatus\tclassification\ttitle\turl\n' > "$STATE_FILE"
  fi
}

# Return 0 if issue number is already in the seen ledger.
_seen() {
  local num="$1"
  [ -f "$STATE_FILE" ] || return 1
  awk -F'\t' -v n="$num" 'NR>1 && $1==n { found=1; exit } END { exit !found }' "$STATE_FILE" 2>/dev/null
}

# Append or update a state row. Args: number req_id status classification title url
_state_upsert() {
  local num="$1" rid="$2" st="$3" cls="$4" title="$5" url="$6"
  _ensure_dir
  local tmp
  tmp="$(mktemp "$TRIAGE_DIR/.state.XXXXXX")"
  # Keep header + every other issue; rewrite this one.
  awk -F'\t' -v n="$num" 'NR==1 || $1!=n { print }' "$STATE_FILE" > "$tmp" 2>/dev/null || \
    printf '# number\treq_id\tstatus\tclassification\ttitle\turl\n' > "$tmp"
  # Flatten title tabs/newlines so the TSV stays one row.
  title="$(printf '%s' "$title" | tr '\t\n\r' '   ' | sed 's/  */ /g')"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$num" "$rid" "$st" "$cls" "$title" "$url" >> "$tmp"
  mv -f "$tmp" "$STATE_FILE"
}

# Build the structured research question for one issue.
_research_question() {
  local num="$1" title="$2" body="$3" labels="$4" url="$5" repo="$6"
  # Cap body so a huge issue does not blow the research prompt.
  body="$(printf '%s' "$body" | head -c 4000)"  # pipe-ok: head in a command or process substitution; pipeline status not gated
  cat <<EOF
OSS-TRIAGE issue #${num} on ${repo}:
Title: ${title}
URL: ${url}
Labels: ${labels}
Body:
${body}

CLASSIFY this GitHub issue as exactly one of: bug | feature | question | duplicate.
Then DRAFT a suggested reply (and optional label set) for a human to approve.
Do NOT post, comment, close, label, or edit the issue on GitHub — drafts only.

Respond in this structured markdown shape (so the triage collector can parse it):
## Classification: <bug|feature|question|duplicate>
## Confidence: <high|medium|low>
## Suggested labels: <comma-separated or none>
## Suggested reply:
<one short draft the maintainer can paste after review>
## Notes:
<optional: related issues, missing repro steps, etc.>
EOF
}

# Enqueue via research.sh (or HERD_OSS_RESEARCH_SH stub). Prints REQ_ID on success, empty on fail.
_enqueue_research() {
  local question="$1" out rid
  if [ ! -x "$RESEARCH_BIN" ] && [ ! -f "$RESEARCH_BIN" ]; then
    _warn "research binary missing at $RESEARCH_BIN — skip enqueue"
    return 1
  fi
  # research.sh may try to spawn a drainer; capture stdout and parse REQ_ID.
  # Fail-soft: a spawn/network failure still leaves the queue entry when using real research.sh.
  out="$(bash "$RESEARCH_BIN" "$question" 2>/dev/null || true)"
  rid="$(printf '%s\n' "$out" | sed -n 's/^REQ_ID //p' | head -n1)"  # pipe-ok: head in a command or process substitution; pipeline status not gated
  if [ -z "$rid" ]; then
    _warn "research enqueue produced no REQ_ID"
    return 1
  fi
  printf '%s' "$rid"
}

# Parse classification from a research report file. Default: pending
_parse_classification() {
  local f="$1" cls
  [ -f "$f" ] || { printf 'pending'; return 0; }
  cls="$(sed -nE 's/^##[[:space:]]*Classification:[[:space:]]*//p; s/^Classification:[[:space:]]*//p' "$f" \
    | head -n1 | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"  # pipe-ok: head in a command or process substitution; pipeline status not gated
  case "$cls" in
    bug|feature|question|duplicate) printf '%s' "$cls" ;;
    *) printf 'pending' ;;
  esac
}

# Extract a short draft reply snippet from a research report (first non-empty line after Suggested reply).
_parse_reply_snippet() {
  local f="$1"
  [ -f "$f" ] || return 0
  python3 - "$f" <<'PY' 2>/dev/null || true
import sys
text = open(sys.argv[1], encoding="utf-8", errors="replace").read().splitlines()
i = 0
while i < len(text):
    line = text[i].strip().lower()
    if line.startswith("## suggested reply") or line.startswith("suggested reply"):
        i += 1
        parts = []
        while i < len(text):
            l = text[i]
            if l.startswith("## "):
                break
            if l.strip():
                parts.append(l.strip())
            i += 1
            if sum(len(p) for p in parts) > 240:
                break
        snip = " ".join(parts)[:240]
        print(snip)
        break
    i += 1
PY
}

# List open issues as TSV: number\ttitle\tbody\tlabels\turl\tcreatedAt
# FAIL-SOFT: empty on gh error (never red).
_list_open_issues() {
  local repo="$1" limit="$2" json
  if ! command -v gh >/dev/null 2>&1; then
    _warn "gh not on PATH — cannot list issues"
    return 0
  fi
  local args=(issue list --state open --limit "$limit"
    --json number,title,body,labels,url,createdAt)
  if [ -n "$repo" ]; then
    args+=(-R "$repo")
  fi
  json="$(gh "${args[@]}" 2>/dev/null || true)"
  [ -n "$json" ] || return 0
  printf '%s' "$json" | python3 -c '
import sys, json
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if not isinstance(data, list):
    sys.exit(0)
for it in data:
    num = it.get("number", "")
    title = (it.get("title") or "").replace("\t", " ").replace("\n", " ")
    body = (it.get("body") or "").replace("\t", " ")
    labels = ",".join(
        (l.get("name") if isinstance(l, dict) else str(l))
        for l in (it.get("labels") or [])
    )
    url = it.get("url") or ""
    created = it.get("createdAt") or ""
    # body may contain newlines — keep as single field by encoding newlines as \n literal for TSV safety via python join later
    print("\t".join([
        str(num),
        title,
        body.replace("\n", "\\n"),
        labels,
        url,
        created,
    ]))
' 2>/dev/null || true
}

# Collect ready research reports into state; rewrite ranked shortlist.
_collect_and_write_shortlist() {
  _ensure_dir
  [ -f "$STATE_FILE" ] || return 0

  local tmp_rows tmp_state
  tmp_rows="$(mktemp "$TRIAGE_DIR/.rows.XXXXXX")"
  tmp_state="$(mktemp "$TRIAGE_DIR/.state.XXXXXX")"
  : > "$tmp_rows"
  printf '# number\treq_id\tstatus\tclassification\ttitle\turl\n' > "$tmp_state"

  # Snapshot state first so we never rewrite the file we are reading.
  local snap
  snap="$(mktemp "$TRIAGE_DIR/.snap.XXXXXX")"
  cp "$STATE_FILE" "$snap"

  while IFS=$'\t' read -r num rid st cls title url; do
    case "$num" in ''|'#'*) continue ;; esac
    local report="$REPORTS/${rid}.md"
    local new_cls="${cls:-pending}" new_st="${st:-queued}" reply=""
    if [ -n "$rid" ] && [ -f "$report" ]; then
      new_cls="$(_parse_classification "$report")"
      new_st="ready"
      reply="$(_parse_reply_snippet "$report")"
    fi
    title="$(printf '%s' "$title" | tr '\t\n\r' '   ' | sed 's/  */ /g')"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$num" "$rid" "$new_st" "$new_cls" "$title" "$url" >> "$tmp_state"
    local rank
    rank="$(_class_rank "$new_cls")"
    # rank \t number \t classification \t status \t title \t url \t reply \t req_id
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$rank" "$num" "$new_cls" "$new_st" "$title" "$url" "$reply" "$rid" >> "$tmp_rows"
  done < "$snap"
  mv -f "$tmp_state" "$STATE_FILE"
  rm -f "$snap"

  local ready=0 queued=0
  if [ -s "$tmp_rows" ]; then
    ready="$(awk -F'\t' '$4=="ready"{c++} END{print c+0}' "$tmp_rows")"
    queued="$(awk -F'\t' '$4!="ready"{c++} END{print c+0}' "$tmp_rows")"
  fi

  # Ranked shortlist markdown.
  {
    printf '# OSS triage shortlist\n\n'
    printf 'Drafts for **human approval only** — nothing is auto-posted to GitHub.\n\n'
    printf 'Generated by `herd triage` (HERD-255). Rank: bug > feature > question > duplicate > pending.\n\n'
    if [ -s "$tmp_rows" ]; then
      sort -t$'\t' -k1,1n -k2,2n "$tmp_rows" | while IFS=$'\t' read -r rank num cls st title url reply rid; do
        printf '## #%s — %s (%s)\n' "$num" "$cls" "$st"
        printf -- '- **Title:** %s\n' "$title"
        [ -n "$url" ] && printf -- '- **URL:** %s\n' "$url"
        printf -- '- **Research:** `%s`\n' "$rid"
        if [ -n "$reply" ]; then
          printf -- '- **Suggested reply (draft):** %s\n' "$reply"
        elif [ "$st" = "queued" ] || [ "$cls" = "pending" ]; then
          printf -- '- **Suggested reply (draft):** _(pending research)_\n'
        fi
        printf '\n'
      done
    else
      printf '_No open issues triaged yet._\n'
    fi
    printf '\n---\nready=%s queued=%s\n' "$ready" "$queued"
  } > "$SHORTLIST_FILE"

  # Operator-inbox style pointer file (ranked, human-readable).
  {
    printf '# oss-triage inbox — ranked shortlist at %s\n' "$SHORTLIST_FILE"
    if [ -s "$tmp_rows" ]; then
      sort -t$'\t' -k1,1n -k2,2n "$tmp_rows" | while IFS=$'\t' read -r rank num cls st title url reply rid; do
        printf '[%s] #%s %s · %s · %s\n' "$st" "$num" "$cls" "$title" "${url:-no-url}"
      done
    fi
  } > "$INBOX_FILE"

  rm -f "$tmp_rows"
  _say "shortlist → $SHORTLIST_FILE"
  _say "inbox     → $INBOX_FILE"
}

_cmd_report() {
  if [ ! -f "$SHORTLIST_FILE" ]; then
    _say "no shortlist yet (run: herd triage run, with OSS_TRIAGE=on)"
    return 0
  fi
  cat "$SHORTLIST_FILE"
}

_cmd_run() {
  local limit="${1:-$LIMIT_DEFAULT}"

  if ! _oss_triage_enabled; then
    _say "herd triage: OSS_TRIAGE=off (default) — byte-inert; set OSS_TRIAGE=on to enable"
    return 0
  fi

  local repo="${HERD_REPO:-}"
  if [ -z "$repo" ]; then
    _warn "HERD_REPO unset — cannot list issues (fail-soft)"
    _ensure_dir
    _collect_and_write_shortlist
    return 0
  fi

  _ensure_dir
  _say "herd triage: scanning open issues on $repo (limit $limit)"

  local line num title body labels url created q rid new_count=0
  while IFS=$'\t' read -r num title body labels url created; do
    [ -n "$num" ] || continue
    if _seen "$num"; then
      continue
    fi
    # Decode \n placeholders from the python emitter.
    body="$(printf '%s' "$body" | sed 's/\\n/\n/g')"
    q="$(_research_question "$num" "$title" "$body" "$labels" "$url" "$repo")"
    rid=""
    if rid="$(_enqueue_research "$q")"; then
      _state_upsert "$num" "$rid" "queued" "pending" "$title" "$url"
      _say "  queued #$num → REQ_ID $rid"
      new_count=$((new_count + 1))
    else
      _state_upsert "$num" "" "error" "pending" "$title" "$url"
      _warn "  failed to enqueue #$num"
    fi
  done < <(_list_open_issues "$repo" "$limit")

  _say "herd triage: enqueued $new_count new issue(s)"
  _collect_and_write_shortlist
}

# ── dispatch ───────────────────────────────────────────────────────────────────────────────────
sub="${1:-run}"
shift || true
LIMIT="$LIMIT_DEFAULT"
while [ $# -gt 0 ]; do
  case "$1" in
    --limit) LIMIT="${2:-}"; [ -n "$LIMIT" ] || _die "--limit requires N"; shift 2 ;;
    --limit=*) LIMIT="${1#--limit=}"; shift ;;
    -h|--help) _usage; exit 0 ;;
    *) _die "unknown arg: $1 (try: herd triage help)" ;;
  esac
done
case "$LIMIT" in ''|*[!0-9]*) _die "--limit must be a positive integer (got '$LIMIT')" ;; esac

case "$sub" in
  run|"")  _cmd_run "$LIMIT" ;;
  report)  _cmd_report ;;
  help|-h|--help) _usage ;;
  *) _die "unknown subcommand: $sub (try: herd triage help)" ;;
esac
