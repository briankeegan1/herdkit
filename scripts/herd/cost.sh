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
# CORRECTNESS REVIEWER for PR #<n>"). A session whose FIRST user message (its initial task prompt)
# contains this string is the REVIEW session; everything else in the dir is BUILDER work. We gate
# on the FIRST user message, NOT any occurrence, because a builder that merely READS herd-review.sh
# would otherwise be misclassified — the fingerprint shows up in that read's tool_result, but a
# tool_result is never a session's opening prompt, so first-message gating filters it out.
_COST_REVIEWER_FINGERPRINT='ADVERSARIAL PRE-MERGE CORRECTNESS REVIEWER for PR #'

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
_COST_PY='
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

FP = os.environ.get("HERD_COST_FP", "")
prices = load_prices()

def price_of(model):
    p = prices.get(model)
    if not p:
        return None
    return (float(p.get("in", 0)), float(p.get("out", 0)))

# Per component accumulators. A component is "builder" or "review".
# comp -> {"in":..,"out":..,"cw":..,"cr":..,"usd":..,"msgs":set(),"model_out":{model:out_tokens}}
def new_acc():
    return {"in": 0, "out": 0, "cw": 0, "cr": 0, "usd": 0.0, "msgs": set(), "model_out": {}}

comps = {"builder": new_acc(), "review": new_acc()}
seen_ids = set()   # global message-id dedup across the whole dir

def classify(path):
    # A session is REVIEW iff its FIRST user-role message (the initial task prompt) carries the
    # reviewer fingerprint; else BUILDER. First-message gating avoids the false positive where a
    # builder that read herd-review.sh has the fingerprint in a later tool_result.
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
                # First user message found — decide here and stop (do not scan the rest).
                c = m.get("content")
                txt = c if isinstance(c, str) else json.dumps(c)
                return "review" if (FP and FP in txt) else "builder"
    except OSError:
        return "builder"
    return "builder"

target_dir = sys.argv[1]
want = sys.argv[2] if len(sys.argv) > 2 else "all"   # "builder" | "review" | "all"

for path in sorted(glob.glob(os.path.join(target_dir, "*.jsonl"))):
    comp = classify(path)
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

def primary_model(acc):
    if not acc["model_out"]:
        return "unknown"
    model = max(acc["model_out"].items(), key=lambda kv: kv[1])[0]
    # Flag models we could not price so the operator knows the usd is understated.
    if price_of(model) is None:
        return model + "?"
    return model

for comp in ("builder", "review"):
    if want not in ("all", comp):
        continue
    acc = comps[comp]
    if not acc["msgs"] and acc["in"] == 0 and acc["out"] == 0:
        continue   # nothing for this component
    print("component=%s model=%s in=%d out=%d cache_read=%d cache_write=%d usd=%.6f msgs=%d" % (
        comp, primary_model(acc), acc["in"], acc["out"], acc["cr"], acc["cw"], acc["usd"], len(acc["msgs"])))
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
