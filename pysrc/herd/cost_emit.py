"""herd.cost_emit — the LIVE engine's cost-event EMITTER (HERD-375).

The strangler port of ``scripts/herd/cost.sh``'s ``cost_emit_merge``: bash's ``do_merge`` stopped
being the code path that actuates a merge once ``ENGINE_IMPL=python`` cut the tick loop over to
:mod:`herd.live_runtime` (EPIC HERD-300) — so ``cost_emit_merge`` has been dead code since PR #442
and every merged PR since has recorded NO cost event, even though :mod:`herd.cost` still reads them.
This module is the emitter's new home: called from the live actuators' reap seam (mirroring bash
``do_merge``'s "0) COST ACCOUNTING ... BEFORE the worktree is reaped" step), it appends the exact
same ``cost`` event shape the bash summer did, so :mod:`herd.cost` needs zero changes.

BEST-EFFORT, SILENT, NEVER RAISES: a missing transcript dir, an absent price entry, or any read
fault just drops the event — :func:`emit_merge_cost` always returns ``None`` and can never sink a
merge/reap tick. DEDUPED BY MESSAGE ID (a resumed session replays the same assistant message several
times) and split BUILDER vs REVIEW by the same stable reviewer-fingerprint first-user-message check
``cost.sh`` uses (the pre-merge reviewer runs ``claude --cwd <worktree>``, so its transcript lands in
the same munged project dir as the builder's).
"""
import glob
import json
import os

CACHE_READ_MULT = 0.10          # cache read ~= 0.1x input price
CACHE_WRITE_5M_MULT = 1.25      # 5-minute-TTL cache write = 1.25x input price
CACHE_WRITE_1H_MULT = 2.00      # 1-hour-TTL cache write = 2.0x input price

# PERISHABLE — verify against current pricing (as of 2026-07-15). Per-million-token USD. Mirrors
# scripts/herd/cost.sh's BUILTIN_PRICES verbatim; keep the two in sync. claude-sonnet-5 is the
# default builder tier (HERD-102) — priced here so it never silently bills at $0.
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

# The invariant opening of herd-review.sh's review task (cost.sh's _COST_REVIEWER_FINGERPRINT) — a
# session whose FIRST user message contains this string is the REVIEW session; everything else in
# the dir is BUILDER work. First-message gating (not "any occurrence") so a builder that merely
# READS herd-review.sh is never misclassified.
_REVIEWER_FINGERPRINT = "ADVERSARIAL PRE-MERGE CORRECTNESS REVIEWER for the project "


def _load_prices():
    """The active price table: ``HERD_COST_PRICE_FILE`` (the hermetic test seam / operator override)
    when set, else :data:`BUILTIN_PRICES`. A broken override file yields ``{}`` (every model prices
    at $0 and is flagged) rather than silently falling back to the built-in table."""
    pf = os.environ.get("HERD_COST_PRICE_FILE", "")
    if pf:
        try:
            with open(pf, encoding="utf-8") as f:
                return json.load(f)
        except Exception:
            return {}
    return BUILTIN_PRICES


def _price_of(model, prices):
    p = prices.get(model)
    if not p:
        return None
    return (float(p.get("in", 0)), float(p.get("out", 0)))


def _cost_transcript_dir(worktree):
    """The Claude transcript dir for ``worktree``, mirroring ``cost.sh:_cost_transcript_dir`` exactly:
    ``$HERD_TRANSCRIPT_ROOT`` (default ``$HOME/.claude/projects``) / the worktree's absolute path with
    ``/`` and ``.`` rewritten to ``-``."""
    root = os.environ.get("HERD_TRANSCRIPT_ROOT") or os.path.join(
        os.environ.get("HOME") or os.path.expanduser("~"), ".claude", "projects")
    munged = worktree.replace("/", "-").replace(".", "-")
    return os.path.join(root, munged)


def _first_user_text(path):
    """The FIRST user-role message text, or ``""`` on any failure — both scanners classify a session
    on this alone (mirrors ``cost.sh``'s ``first_user_text``)."""
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


def _new_acc():
    return {"in": 0, "out": 0, "cw": 0, "cr": 0, "usd": 0.0, "msgs": set(), "model_out": {}}


def _scan_dir(target_dir, prices):
    """Sum + price every assistant message in ``target_dir``, bucketed builder/review by the first
    user message's reviewer fingerprint. Message ids are deduped across the whole dir (mirrors
    ``cost.sh``'s ``scan_dir``)."""
    comps = {"builder": _new_acc(), "review": _new_acc()}
    seen_ids = set()
    for path in sorted(glob.glob(os.path.join(target_dir, "*.jsonl"))):
        comp = "review" if _REVIEWER_FINGERPRINT in _first_user_text(path) else "builder"
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
                pr = _price_of(model, prices)
                if pr is not None:
                    pin, pout = pr
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


def _primary_model(acc, prices):
    if not acc["model_out"]:
        return "unknown"
    model = max(acc["model_out"].items(), key=lambda kv: kv[1])[0]
    if _price_of(model, prices) is None:
        return model + "?"     # flag an unpriced model rather than silently show it as free
    return model


def emit_merge_cost(journal, pr, slug, worktree):
    """``cost_emit_merge``, ported: for each component (builder/review) present in ``worktree``'s
    transcript dir, append a ``cost`` journal event carrying the token breakdown + priced usd — same
    event name/fields :mod:`herd.cost` already parses. Called from the merge/reap actuation seam
    BEFORE the worktree is reaped (mirrors ``agent-watch.sh do_merge``'s cost-accounting step).

    BEST-EFFORT, ALWAYS returns ``None``: an empty ``pr``/``worktree``, a missing transcript dir, or
    any read fault just drops the event(s), never raises into the caller. The empty-``worktree`` guard
    also keeps a fixture/dry-run candidate (which carries no real worktree) from ever resolving to
    the bare ``$HERD_TRANSCRIPT_ROOT`` and scanning an operator's UNRELATED live transcripts.
    """
    try:
        if not pr or not worktree:
            return
        target_dir = _cost_transcript_dir(worktree)
        if not os.path.isdir(target_dir):
            return
        prices = _load_prices()
        comps = _scan_dir(target_dir, prices)
        for comp, acc in comps.items():
            if not acc["msgs"] and acc["in"] == 0 and acc["out"] == 0:
                continue   # nothing for this component
            unpriced = sum(1 for m in acc["model_out"] if _price_of(m, prices) is None)
            journal.append("cost", "component", comp, "pr", pr, "slug", slug,
                           "model", _primary_model(acc, prices),
                           "in", acc["in"], "out", acc["out"],
                           "cache_read", acc["cr"], "cache_write", acc["cw"],
                           "usd", "%.6f" % acc["usd"], "msgs", len(acc["msgs"]),
                           "unpriced", unpriced)
    except Exception:
        pass
