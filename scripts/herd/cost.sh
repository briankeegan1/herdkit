#!/usr/bin/env bash
# cost.sh — the herdkit TOKEN/COST SUMMER: the measurement precursor to the efficiency program.
# Given a Claude SESSION TRANSCRIPT (the *.jsonl a builder or reviewer leaves behind), it sums the
# usage across every assistant message, prices it against a PERISHABLE model→$ table, and hands the
# breakdown to journal.sh so `herd cost` can surface "how many tokens / how much $ did this cost"
# per builder, per review, and as cost-per-merged-PR.
#
# ADDITIVE + READ-ONLY: this file only ever OBSERVES transcripts and APPENDS journal events. It
# changes no gate, merge, review, or watcher behavior. Sourced (never executed) AFTER journal.sh:
#   . "$HERE/journal.sh"
#   . "$HERE/cost.sh"
# then, at merge time (agent-watch.sh do_merge, before the worktree is reaped):
#   cost_emit_merge "$pr" "$slug" "$worktree"
#
# CONTRACT (why this is safe to call from the merge path):
#   • BEST-EFFORT, SILENT: cost_emit_merge is wrapped so it can NEVER break, slow-fault, or abort a
#     caller — even under `set -euo pipefail`. A missing transcript, absent python3, or unwritable
#     journal simply drops the cost events. It ALWAYS returns 0.
#   • DEDUP BY MESSAGE ID: a transcript replays the same assistant message many times (resumed
#     sessions, tool loops). Summing raw over-counts ~3x. We sum each message.id exactly once.
#   • BUILDER vs REVIEW split from ONE dir: the pre-merge reviewer runs `claude --cwd <worktree>`
#     (herd-review.sh), so its transcript lands in the SAME munged project dir as the builder's.
#     We classify each session .jsonl by a stable reviewer fingerprint and attribute tokens to the
#     right component. Reviews that ran with the worktree already gone (CWD falls back to $MAIN),
#     and reviews on PRs that BLOCKED and never merged, are NOT captured here — that is the
#     best-effort review-cost gap (builder cost is robust; see the PR body's HUMAN-VERIFY note).

# _COST_REVIEWER_FINGERPRINT — the invariant opening of herd-review.sh's review task (both the
# agent-pane AGENT_TASK and the headless TASK begin with "You are an ADVERSARIAL PRE-MERGE
# CORRECTNESS REVIEWER for the project '<name>'"). A session whose FIRST user message (its initial
# task prompt) contains this string is the REVIEW session; everything else in the dir is BUILDER
# work. We gate on the FIRST user message, NOT any occurrence, because a builder that merely READS
# herd-review.sh would otherwise be misclassified — the fingerprint shows up in that read's
# tool_result, but a tool_result is never a session's opening prompt, so first-message gating filters
# it out. NOTE: prompt-cache-aware ordering moved the unique 'PR #<n>' to the prompt's TAIL, so the
# fingerprint keys on the stable 'for the project' preamble that now leads (not 'for PR #').
_COST_REVIEWER_FINGERPRINT='ADVERSARIAL PRE-MERGE CORRECTNESS REVIEWER for the project '

# ── LIVE-SESSION-AGENT FINGERPRINTS (the on-demand `herd cost --full` scan) ─────────────────────
# The default `herd cost` only sees builder+review spend (journaled at MERGE time). The long-lived
# COORDINATOR, the SCRIBE drainer, and the RESEARCH drainer leave NO merge event to hook, so their
# tokens go uncounted. `herd cost --full` closes that gap by scanning their LIVE transcripts on
# demand. All three are launched with `--cwd $PROJECT_ROOT` (coordinator.sh / scribe.sh /
# research.sh), so — unlike builders/reviews, which run from feature worktrees — their sessions all
# land in the SINGLE munged transcript dir of MAIN (`_cost_transcript_dir "$PROJECT_ROOT"`). We split
# that dir by classifying each session on its FIRST user message, the same first-message gating the
# builder/review split uses, and we POSITIVELY match each agent so an unrelated manual `claude`
# session run from the repo root is skipped (classified "other") rather than misattributed to the
# coordinator:
#   • coordinator — first user message is the slash-command marker '<command-name>/coordinator'
#                   (the coordinator is launched as `claude --model … /coordinator`).
#   • scribe      — the drainer task opens 'You are the BACKLOG SCRIBE (queue drainer)'.
#   • researcher  — the drainer task opens 'You are the RESEARCH DRAINER (queue drainer)'.
# A pre-merge review that fell back to $MAIN (its worktree was already reaped) still carries the
# reviewer fingerprint; it is classified "review" here and DELIBERATELY skipped — it is neither the
# coordinator nor a --full component, and its cost is the known best-effort review gap, not new spend.
_COST_COORDINATOR_FINGERPRINT='<command-name>/coordinator'
_COST_SCRIBE_FINGERPRINT='You are the BACKLOG SCRIBE'
_COST_RESEARCHER_FINGERPRINT='You are the RESEARCH DRAINER'

# ── PERISHABLE PRICE TABLE ────────────────────────────────────────────────────────────────────
# ⚠️ VERIFY AGAINST CURRENT PRICING — as of 2026-06-24.
# Source: the bundled `claude-api` skill's "Current Models" table (cached 2026-06-24), which mirrors
# platform.claude.com/docs/en/pricing. Per-MILLION-token USD, input / output, by model id.
# When Anthropic changes prices or ships a new model, UPDATE THIS TABLE and bump the date above.
# Cache multipliers (applied to the INPUT price): a cache READ costs ~0.10x input; a cache WRITE
# costs 1.25x input at the 5-minute TTL and 2.0x at the 1-hour TTL. Unknown models price at $0 and
# are flagged (model=<id>? in the report) rather than guessed.
#
# A test seam / operator override: set HERD_COST_PRICE_FILE to a JSON file of the same shape
#   { "claude-opus-4-8": {"in": 5.0, "out": 25.0}, ... }
# to replace this built-in table wholesale (the hermetic tests use this to assert exact figures).
#
# ── SHARED SCANNER CORE ─────────────────────────────────────────────────────────────────────────
# One price table + one summing/pricing engine, shared verbatim by BOTH scanners: the builder/review
# split (_COST_PY, merge-gated) and the coordinator/scribe/researcher scan (_COST_FULL_PY, on-demand
# via `herd cost --full`). Keeping ONE table matters because it is perishable — a second copy would
# silently drift out of date. Each scanner appends only its own classify() + a call to emit().
_COST_PY_CORE='
import sys, os, json, glob

CACHE_READ_MULT = 0.10          # cache read ~= 0.1x input price
CACHE_WRITE_5M_MULT = 1.25      # 5-minute-TTL cache write = 1.25x input price
CACHE_WRITE_1H_MULT = 2.00      # 1-hour-TTL cache write = 2.0x input price

# PERISHABLE — verify against current pricing (as of 2026-06-24). Per-million-token USD.
BUILTIN_PRICES = {
    "claude-fable-5":     {"in": 10.0, "out": 50.0},
    "claude-mythos-5":    {"in": 10.0, "out": 50.0},
    "claude-opus-4-8":    {"in": 5.0,  "out": 25.0},
    "claude-opus-4-7":    {"in": 5.0,  "out": 25.0},
    "claude-opus-4-6":    {"in": 5.0,  "out": 25.0},
    "claude-opus-4-5":    {"in": 5.0,  "out": 25.0},
    "claude-sonnet-5":    {"in": 3.0,  "out": 15.0},
    "claude-sonnet-4-6":  {"in": 3.0,  "out": 15.0},
    "claude-sonnet-4-5":  {"in": 3.0,  "out": 15.0},
    "claude-haiku-4-5":   {"in": 1.0,  "out": 5.0},
}

def load_prices():
    pf = os.environ.get("HERD_COST_PRICE_FILE", "")
    if pf:
        try:
            with open(pf, encoding="utf-8") as f:
                return json.load(f)
        except Exception:
            return {}   # a broken override table yields $0 pricing rather than silently using built-ins
    return BUILTIN_PRICES

prices = load_prices()

def price_of(model):
    p = prices.get(model)
    if not p:
        return None
    return (float(p.get("in", 0)), float(p.get("out", 0)))

# Per-component accumulator.
# comp -> {"in":..,"out":..,"cw":..,"cr":..,"usd":..,"msgs":set(),"model_out":{model:out_tokens}}
def new_acc():
    return {"in": 0, "out": 0, "cw": 0, "cr": 0, "usd": 0.0, "msgs": set(), "model_out": {}}

def first_user_text(path):
    # The FIRST user-role message text (the session initial task prompt), or "" on any failure. Both
    # scanners classify a session on this alone: first-message gating avoids the false positive where
    # a body that merely READ a fingerprinted file has that string in a later tool_result.
    try:
        with open(path, encoding="utf-8") as f:
            for raw in f:
                if not raw.strip():
                    continue
                try:
                    o = json.loads(raw)
                except Exception:
                    continue
                m = o.get("message")
                if not isinstance(m, dict) or m.get("role") != "user":
                    continue
                c = m.get("content")
                return c if isinstance(c, str) else json.dumps(c)
    except OSError:
        return ""
    return ""

def scan_dir(target_dir, classify, components):
    # Sum + price every assistant message in target_dir, bucketed by classify() into components.
    # Sessions whose classify() result is not in components (e.g. a review in the MAIN dir, or an
    # unrelated "other" session) are skipped entirely. Message ids are deduped across the whole dir
    # (a resumed session replays the same message many times; summing raw over-counts ~3x).
    comps = {c: new_acc() for c in components}
    seen_ids = set()
    for path in sorted(glob.glob(os.path.join(target_dir, "*.jsonl"))):
        comp = classify(path)
        if comp not in comps:
            continue
        acc = comps[comp]
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
                m = o.get("message")
                if not isinstance(m, dict) or m.get("role") != "assistant":
                    continue
                u = m.get("usage")
                if not isinstance(u, dict):
                    continue
                mid = m.get("id")
                if mid is not None:
                    if mid in seen_ids:
                        continue
                    seen_ids.add(mid)
                    acc["msgs"].add(mid)
                model = m.get("model") or "unknown"
                it = int(u.get("input_tokens", 0) or 0)
                ot = int(u.get("output_tokens", 0) or 0)
                cw = int(u.get("cache_creation_input_tokens", 0) or 0)
                cr = int(u.get("cache_read_input_tokens", 0) or 0)
                acc["in"] += it; acc["out"] += ot; acc["cw"] += cw; acc["cr"] += cr
                acc["model_out"][model] = acc["model_out"].get(model, 0) + ot
                pr = price_of(model)
                if pr is not None:
                    pin, pout = pr
                    # Split cache-write cost by TTL when the transcript breaks it down; else 5m rate.
                    cc = u.get("cache_creation")
                    if isinstance(cc, dict):
                        cw5 = int(cc.get("ephemeral_5m_input_tokens", 0) or 0)
                        cw1 = int(cc.get("ephemeral_1h_input_tokens", 0) or 0)
                        cw_cost = (cw5 * CACHE_WRITE_5M_MULT + cw1 * CACHE_WRITE_1H_MULT) * pin
                    else:
                        cw_cost = cw * CACHE_WRITE_5M_MULT * pin
                    usd = (it * pin + ot * pout + cr * CACHE_READ_MULT * pin + cw_cost) / 1_000_000.0
                    acc["usd"] += usd
    return comps

def primary_model(acc):
    if not acc["model_out"]:
        return "unknown"
    model = max(acc["model_out"].items(), key=lambda kv: kv[1])[0]
    # Flag models we could not price so the operator knows the usd is understated.
    if price_of(model) is None:
        return model + "?"
    return model

def emit(comps, components, want):
    for comp in components:
        if want not in ("all", comp):
            continue
        acc = comps[comp]
        if not acc["msgs"] and acc["in"] == 0 and acc["out"] == 0:
            continue   # nothing for this component
        print("component=%s model=%s in=%d out=%d cache_read=%d cache_write=%d usd=%.6f msgs=%d" % (
            comp, primary_model(acc), acc["in"], acc["out"], acc["cr"], acc["cw"], acc["usd"], len(acc["msgs"])))
'

# _COST_PY — the builder/review scanner (default `herd cost`, journaled at merge). A session is
# REVIEW iff its first user message carries the reviewer fingerprint; else BUILDER.
_COST_PY="$_COST_PY_CORE"'
FP = os.environ.get("HERD_COST_FP", "")

def classify(path):
    txt = first_user_text(path)
    return "review" if (FP and FP in txt) else "builder"

target_dir = sys.argv[1]
want = sys.argv[2] if len(sys.argv) > 2 else "all"   # "builder" | "review" | "all"
emit(scan_dir(target_dir, classify, ("builder", "review")), ("builder", "review"), want)
'

# _COST_FULL_PY — the on-demand `herd cost --full` scanner of the MAIN transcript dir. POSITIVELY
# classifies each session into coordinator / scribe / researcher by its first user message; a
# fallback review (reviewer fingerprint) and any unrelated manual session both fall through to
# "other" and are skipped (not in the component set), so neither inflates the coordinator figure.
_COST_FULL_PY="$_COST_PY_CORE"'
REV_FP = os.environ.get("HERD_COST_FP", "")
COORD_FP = os.environ.get("HERD_COST_COORD_FP", "")
SCRIBE_FP = os.environ.get("HERD_COST_SCRIBE_FP", "")
RESEARCH_FP = os.environ.get("HERD_COST_RESEARCH_FP", "")

def classify(path):
    txt = first_user_text(path)
    if REV_FP and REV_FP in txt:
        return "review"        # a review that fell back to MAIN — out of scope, skip
    if COORD_FP and COORD_FP in txt:
        return "coordinator"
    if SCRIBE_FP and SCRIBE_FP in txt:
        return "scribe"
    if RESEARCH_FP and RESEARCH_FP in txt:
        return "researcher"
    return "other"             # unrelated manual session in the repo root — skip

COMPONENTS = ("coordinator", "scribe", "researcher")
emit(scan_dir(sys.argv[1], classify, COMPONENTS), COMPONENTS, "all")
'

# _cost_transcript_dir <worktree> — echo the Claude transcript dir for this worktree, reusing the
# EXACT munging + root logic from agent-watch.sh's _transcript_obs: transcripts live at
# $HERD_TRANSCRIPT_ROOT (default $HOME/.claude/projects)/<munged>/*.jsonl where <munged> is the
# worktree's absolute path with '/' and '.' rewritten to '-'. Echoes the path unconditionally
# (existence is the caller's / python's concern).
_cost_transcript_dir() {
  local wt="$1" root munged
  root="${HERD_TRANSCRIPT_ROOT:-$HOME/.claude/projects}"
  munged="$(printf '%s' "$wt" | tr '/.' '-')"
  printf '%s/%s' "$root" "$munged"
}

# cost_report_dir <dir> [component] — print one summary line per component present in <dir>'s
# transcripts (builder, review, or both). Component filter is "builder" | "review" | "all"
# (default all). Each line: "component=.. model=.. in=.. out=.. cache_read=.. cache_write=.. usd=..
# msgs=..". Empty output when there is no transcript / no assistant usage. Pure reader — the public
# seam the hermetic tests drive directly against a fixture transcript dir.
cost_report_dir() {
  local dir="$1" want="${2:-all}"
  [ -n "$dir" ] || return 0
  HERD_COST_FP="$_COST_REVIEWER_FINGERPRINT" python3 -c "$_COST_PY" "$dir" "$want" 2>/dev/null || true
}

# cost_report_full <maindir> — the on-demand `herd cost --full` reader. Print one summary line per
# LIVE SESSION AGENT (coordinator, scribe, researcher) whose transcript is present in <maindir> — the
# MAIN project's munged transcript dir (`_cost_transcript_dir "$PROJECT_ROOT"`), where all three run.
# Same line shape as cost_report_dir, same price table. A fallback review or an unrelated manual
# session in that dir is skipped, not attributed. Empty output when the dir holds no such session
# (a missing dir is the caller's to note). Pure reader — driven directly by the hermetic tests.
cost_report_full() {
  local dir="$1"
  [ -n "$dir" ] || return 0
  HERD_COST_FP="$_COST_REVIEWER_FINGERPRINT" \
  HERD_COST_COORD_FP="$_COST_COORDINATOR_FINGERPRINT" \
  HERD_COST_SCRIBE_FP="$_COST_SCRIBE_FINGERPRINT" \
  HERD_COST_RESEARCH_FP="$_COST_RESEARCHER_FINGERPRINT" \
    python3 -c "$_COST_FULL_PY" "$dir" 2>/dev/null || true
}

# cost_emit_merge <pr> <slug> <worktree> — BEST-EFFORT, SILENT, ALWAYS returns 0. Reads the
# builder worktree's transcript dir, and for each component present appends a `cost` journal event
# (via journal_append) carrying the token breakdown + priced usd. Called from do_merge before the
# worktree is reaped. Wrapped so nothing it does can propagate out to the merge path.
cost_emit_merge() {
  ( set +e +u +o pipefail 2>/dev/null || true; _cost_emit_merge_impl "$@" ) >/dev/null 2>&1 || true
  return 0
}

# _cost_emit_merge_impl — the real work, run inside the strict-mode-neutralized subshell above.
_cost_emit_merge_impl() {
  local pr="$1" slug="$2" wt="$3"
  [ -n "$pr" ] || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  type journal_append >/dev/null 2>&1 || return 0
  local dir; dir="$(_cost_transcript_dir "$wt")"
  [ -d "$dir" ] || return 0
  local line component model tin tout cread cwrite usd msgs kv
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    component=""; model=""; tin=""; tout=""; cread=""; cwrite=""; usd=""; msgs=""
    for kv in $line; do
      case "$kv" in
        component=*)   component="${kv#component=}" ;;
        model=*)       model="${kv#model=}" ;;
        in=*)          tin="${kv#in=}" ;;
        out=*)         tout="${kv#out=}" ;;
        cache_read=*)  cread="${kv#cache_read=}" ;;
        cache_write=*) cwrite="${kv#cache_write=}" ;;
        usd=*)         usd="${kv#usd=}" ;;
        msgs=*)        msgs="${kv#msgs=}" ;;
      esac
    done
    [ -n "$component" ] || continue
    journal_append cost component "$component" pr "$pr" slug "$slug" model "$model" \
      in "$tin" out "$tout" cache_read "$cread" cache_write "$cwrite" usd "$usd" msgs "$msgs"
  done <<EOF
$(cost_report_dir "$dir" all)
EOF
}
