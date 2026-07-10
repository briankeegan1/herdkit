"""herd.decisions — the pure decision core of the watcher, ported to Python (HERD-303, P2).

Part of EPIC HERD-300 (strangler port of the engine core). This module ports the *pure*
decision logic the bash watcher already factored out — no I/O, no subprocess, no mutation:

  * the merge-policy resolver  (bash: ``_effective_merge_policy`` / ``_legacy_automerge_policy``
    / ``_merge_policy_is_typo`` in ``scripts/herd/merge-policy.sh``; contract §5.5).
  * the merge-decision helper  (bash: ``_hold_decision`` in ``scripts/herd/agent-watch.sh:3712``;
    contract §2.2 outcomes, §5.4–§5.5 holds).
  * the refix-budget arithmetic (bash: ``refix_*`` in ``scripts/herd/agent-watch.sh``
    :6859–:6932; contract §4) — per-rail budgets (review / health / stale / ci), refund-on-green
    via sha-keyed ``reset`` rows, the lifetime total that ignores resets, and the derived
    3×-rail-cap total ceiling.

WHAT IS *NOT* HERE, on purpose. The *writers* — ``record_refix`` (appends a bounce with a
``date +%s`` timestamp) and ``refix_rail_reset`` (appends a ``reset`` row + journals) — mutate
the ledger and are impure, so they stay in bash; the port targets only the arithmetic that
*reads* the ledger to reach a decision. Likewise nothing here touches the live engine: the bash
watcher keeps its implementation unchanged (zero behavior change), and these functions exist to
be parity-tested against it (``tests/test-py-decisions.sh``) — the harness P3's shadow-mode
state machine builds on.

THE LEDGER MODEL. The refix ledger (``$REFIX_STATE`` = ``.agent-watch-refixed``,
``agent-watch.sh:309``) is append-only, space-separated, positional. Two row shapes
(``agent-watch.sh:6850``–:6854):

    bounce: "<epoch> <pr#> <sha> <slug> <kind>"            # 5 fields (legacy 4-field == kind review)
    reset:  "<epoch> <pr#> <sha> <slug> <kind> reset"      # 6 fields; the 6th field is the marker

Every bash reader discriminates on the awk fields ``$2`` (pr), ``$3`` (sha), ``$5`` (kind),
``$6`` (reset marker), splitting on whitespace with missing fields empty — a legacy 4-field
line therefore has an empty ``$5`` and is read as ``kind == "review"`` (``agent-watch.sh:6828``,
:6879, :6900). :class:`RefixRow` and :func:`parse_refix_ledger` reproduce those exact field
semantics so the arithmetic below is byte-faithful to the awk.
"""


class RefixRow:
    """One parsed ledger row, with the awk field semantics the bash readers rely on.

    Positional fields are read the way ``awk`` reads them: whitespace-split, missing fields
    empty. ``kind`` mirrors the ``$5``-or-legacy-``review`` rule; ``is_reset`` is ``$6 == "reset"``.
    """

    __slots__ = ("pr", "sha", "kind", "is_reset")

    def __init__(self, pr, sha, kind, is_reset):
        self.pr = pr
        self.sha = sha
        self.kind = kind
        self.is_reset = is_reset

    # A row's kind MATCHES a queried rail exactly, OR the query is "review" and the row's kind
    # is empty (a legacy 4-field bounce). This is the awk clause `($5==k) || (k=="review" && $5=="")`
    # shared by refix_rail_count / refix_attempted / refix_round_count_kind.
    def kind_matches(self, kind):
        return self.kind == kind or (kind == "review" and self.kind == "")


def parse_refix_ledger(text):
    """Parse raw ledger text into a list of :class:`RefixRow`, matching awk field-splitting.

    ``text`` is the whole ``$REFIX_STATE`` file (or ``""``). Blank lines are skipped exactly as
    awk skips records with no fields. Field indices mirror the bash: ``$2`` pr, ``$3`` sha,
    ``$5`` kind, ``$6`` reset marker; a short line leaves the missing fields empty.
    """
    rows = []
    for line in text.splitlines():
        f = line.split()
        if not f:
            continue
        pr = f[1] if len(f) > 1 else ""
        sha = f[2] if len(f) > 2 else ""
        kind = f[4] if len(f) > 4 else ""
        is_reset = (f[5] if len(f) > 5 else "") == "reset"
        rows.append(RefixRow(pr, sha, kind, is_reset))
    return rows


# ── refix caps (agent-watch.sh:6859–6869) ───────────────────────────────────────────────────

def refix_cap_num(refix_max_rounds):
    """``REFIX_MAX_ROUNDS`` coerced to a sane positive int, fail-soft to 3.

    Mirrors ``_refix_cap_num`` (``agent-watch.sh:6859``): empty, non-numeric, or ``0`` all fall
    back to the documented default 3, so a garbage config never caps every rail at zero and
    escalates every PR on its first red. ``refix_max_rounds`` may be a string (as from the
    environment) or ``None``.

    Byte-parity domain: unset / empty / non-numeric / ``"0"`` / a plain positive integer with no
    leading zeros. ZERO-PADDED or octal-looking values (``"00"``, ``"010"``) are out of scope — the
    bash reads them inconsistently (``$((00*3))``==0 in arithmetic, but ``printf '%s' 00`` displays
    ``"00"``; ``$((010))`` is *octal* 8), a degenerate config the contract's "coerce to a sane
    positive int" rule (§4) does not endorse. This port honors that intent: any numeric-zero value
    coerces to 3.
    """
    v = "" if refix_max_rounds is None else str(refix_max_rounds)
    # case '' | *[!0-9]* | 0)  -> 3   (§4 intent: a zero/garbage cap must never reach the rails)
    if v == "" or not v.isdigit() or int(v) == 0:
        return 3
    return int(v)


def refix_rail_cap(refix_max_rounds):
    """The per-rail round cap — ``refix_rail_cap`` (``agent-watch.sh:6866``) == the cap number."""
    return refix_cap_num(refix_max_rounds)


def refix_total_cap(refix_max_rounds):
    """The per-PR ceiling across all rails, DERIVED as 3× the rail cap — no config key.

    ``refix_total_cap`` (``agent-watch.sh:6869``): ``_refix_cap_num * 3``. The runaway guard for
    a PR thrashing across different rails (contract §4).
    """
    return refix_cap_num(refix_max_rounds) * 3


# ── refix ledger arithmetic (agent-watch.sh:6876–6932) ───────────────────────────────────────

def refix_attempted(rows, pr, sha, kind=None):
    """True iff a bounce (not a reset) was already recorded for this exact ``(pr, sha)``.

    Mirrors ``refix_attempted`` (``agent-watch.sh:6876``): with ``kind`` given, only a bounce of
    THAT rail counts (a legacy no-kind line reads as ``review``); with ``kind`` ``None`` any rail
    matches. This is the sha-keyed once-guard — a new sha has no matching rows, so it naturally
    re-opens a fresh bounce (contract §2.4, §4).
    """
    k = "" if kind is None else kind
    for r in rows:
        if r.pr == pr and r.sha == sha and not r.is_reset and (k == "" or r.kind_matches(k)):
            return True
    return False


def refix_total_count(rows, pr):
    """Every bounce ever recorded for this PR, across all shas and rails; resets never refund it.

    ``refix_total_count`` (``agent-watch.sh:6885``) — what the TOTAL safety cap reads (§4).
    """
    return sum(1 for r in rows if r.pr == pr and not r.is_reset)


# refix_round_count (agent-watch.sh:6892) is just an alias for the lifetime total, retained for
# the "N failed refix rounds" escalation display.
refix_round_count = refix_total_count


def refix_rail_count(rows, pr, kind):
    """Bounces on ONE rail SINCE THAT RAIL LAST MADE PROGRESS — the rail's live budget.

    Mirrors ``refix_rail_count`` (``agent-watch.sh:6897``): a chronological scan where a matching
    ``reset`` row zeroes the running count and a matching bounce increments it, so refund-on-green
    (contract §4) falls straight out of the ledger order. Not sha-keyed — a rail's budget spans
    shas, and a reset (written for a newer sha) refunds the whole rail.
    """
    n = 0
    for r in rows:
        if r.pr == pr and r.kind_matches(kind):
            if r.is_reset:
                n = 0
            else:
                n += 1
    return n


def refix_round_count_kind(rows, pr, kind):
    """LIFETIME bounces of one kind; resets do NOT refund it. EVIDENCE, not a budget.

    ``refix_round_count_kind`` (``agent-watch.sh:6910``) — read only to arm a stronger-reviewer
    escalation (``agent-watch.sh:7080``), never as a cap, so a rail reset must not erase it (§4).
    """
    return sum(1 for r in rows if r.pr == pr and not r.is_reset and r.kind_matches(kind))


def refix_budget_reason(rows, pr, kind, refix_max_rounds):
    """The honest cap phrase when this rail may NOT bounce again, else ``None`` (budget remains).

    Mirrors ``_refix_budget_reason`` (``agent-watch.sh:6920``): blocks when the RAIL count ≥ rail
    cap, OR the TOTAL count ≥ total cap — rail checked first, because the two ceilings carry
    different remedies (a spent rail = one check keeps failing; a spent total = the PR is
    thrashing across rails, contract §4). Returns the exact phrase the bash prints, so the row
    wording is byte-identical.
    """
    rcap = refix_rail_cap(refix_max_rounds)
    tcap = refix_total_cap(refix_max_rounds)
    rail = refix_rail_count(rows, pr, kind)
    total = refix_total_count(rows, pr)
    if rail >= rcap:
        return "refix limit (%s rounds) reached" % rcap
    if total >= tcap:
        return "refix limit (%s total rounds across rails) reached" % tcap
    return None


# ── merge-policy resolver (merge-policy.sh) ──────────────────────────────────────────────────

_RECOGNIZED_POLICIES = ("auto", "approve", "observe")


def legacy_automerge_policy(watcher_automerge):
    """Derive the policy from the legacy ``WATCHER_AUTOMERGE`` boolean (back-compat).

    ``_legacy_automerge_policy`` (``merge-policy.sh:27``): ``false|no|off|0`` → ``approve``;
    anything else, INCLUDING unset, → ``auto`` (the ``${WATCHER_AUTOMERGE:-true}`` default).
    ``watcher_automerge`` is a string or ``None`` (unset).
    """
    v = "true" if watcher_automerge is None else str(watcher_automerge)
    if v in ("false", "no", "off", "0"):
        return "approve"
    return "auto"


def effective_merge_policy(merge_policy, watcher_automerge=None):
    """Resolve the effective merge policy: ``auto`` | ``approve`` | ``observe``.

    ``_effective_merge_policy`` (``merge-policy.sh:35``), precedence (contract §5.5): a RECOGNIZED
    ``MERGE_POLICY`` wins verbatim; empty/unset derives from ``WATCHER_AUTOMERGE``; anything else
    is a TYPO that fails STRICT to ``observe`` (never merge), case-SENSITIVELY. ``merge_policy``
    is a string or ``None`` (unset, treated as empty).
    """
    mp = "" if merge_policy is None else str(merge_policy)
    if mp in _RECOGNIZED_POLICIES:
        return mp
    if mp == "":
        return legacy_automerge_policy(watcher_automerge)
    return "observe"


def merge_policy_is_typo(merge_policy):
    """True iff ``MERGE_POLICY`` is a non-empty UNRECOGNIZED value (the strict-observe fallback).

    ``_merge_policy_is_typo`` (``merge-policy.sh:46``) — callers surface the bad value loudly.
    """
    mp = "" if merge_policy is None else str(merge_policy)
    return mp not in ("",) + _RECOGNIZED_POLICIES


# ── the merge-decision helper (agent-watch.sh:3712) ──────────────────────────────────────────

def hold_decision(mode, hv_hold, approved, hv_policy="hold"):
    """The pure action selector for a PASS-gated PR: exactly one of ``MERGE`` | ``HOLD`` | ``OBSERVE``.

    Mirrors ``_hold_decision`` (``agent-watch.sh:3712``), no side effects (contract §2.2 outcomes,
    §5.4–§5.5 holds):

      * ``mode`` — the effective merge policy (``auto`` | ``approve`` | ``observe``).
      * ``hv_hold`` — truthy iff the PR declares a HUMAN-VERIFY block (only ever set in auto mode).
      * ``approved`` — truthy iff a sha-keyed approval record exists for this ``(pr, sha)``.
      * ``hv_policy`` — ``HUMAN_VERIFY_POLICY`` (``hold`` | ``coordinator`` | ``auto``); default
        ``hold`` for legacy 3-arg callers.

    ``observe`` never merges; ``approve`` holds until approved (``hv_hold`` ignored — the policy
    already holds, so a human-verify PR is held exactly once); ``auto`` merges unless a
    human-verify block holds it under a non-``auto`` ``HUMAN_VERIFY_POLICY``. Truthiness follows
    bash ``[ -n ... ]``: a non-empty string / ``True`` is set, ``""`` / ``None`` / ``False`` is not.
    """
    hv = _is_set(hv_hold)
    ok = _is_set(approved)
    if mode == "observe":
        return "OBSERVE"
    if mode == "approve":
        return "MERGE" if ok else "HOLD"
    if mode == "auto":
        if hv and hv_policy != "auto":
            return "MERGE" if ok else "HOLD"
        return "MERGE"
    # Unknown mode: bash's catch-all `*)` merges.
    return "MERGE"


def _is_set(v):
    """bash ``[ -n "$v" ]`` truthiness: a non-empty string (or ``True``) is set."""
    if v is None or v is False:
        return False
    if v is True:
        return True
    return str(v) != ""


# ── thin CLI harness (impure glue; the functions above stay pure) ────────────────────────────
#
# Used ONLY by tests/test-py-decisions.sh so the SAME argv drives this port and the bash lib. The
# refix subcommands read $REFIX_STATE (a file path) and parse it here; all decision logic lives in
# the pure functions. Env-sourced knobs (REFIX_MAX_ROUNDS / MERGE_POLICY / WATCHER_AUTOMERGE) are
# read the way bash reads them — unset == absent.

def _cli(argv):
    import os

    def _rows():
        path = os.environ.get("REFIX_STATE", "")
        try:
            with open(path, encoding="utf-8") as fh:
                return parse_refix_ledger(fh.read())
        except OSError:
            return parse_refix_ledger("")

    rmr = os.environ.get("REFIX_MAX_ROUNDS")
    cmd = argv[0] if argv else ""
    a = argv[1:]

    if cmd == "rail_cap":
        return str(refix_rail_cap(rmr))
    if cmd == "total_cap":
        return str(refix_total_cap(rmr))
    if cmd == "attempted":
        kind = a[2] if len(a) > 2 else None
        return "yes" if refix_attempted(_rows(), a[0], a[1], kind) else "no"
    if cmd == "total_count":
        return str(refix_total_count(_rows(), a[0]))
    if cmd == "rail_count":
        return str(refix_rail_count(_rows(), a[0], a[1]))
    if cmd == "round_count_kind":
        return str(refix_round_count_kind(_rows(), a[0], a[1]))
    if cmd == "budget_reason":
        return refix_budget_reason(_rows(), a[0], a[1], rmr) or ""
    if cmd == "effective_policy":
        return effective_merge_policy(os.environ.get("MERGE_POLICY"),
                                      os.environ.get("WATCHER_AUTOMERGE"))
    if cmd == "legacy_policy":
        return legacy_automerge_policy(os.environ.get("WATCHER_AUTOMERGE"))
    if cmd == "is_typo":
        return "yes" if merge_policy_is_typo(os.environ.get("MERGE_POLICY")) else "no"
    if cmd == "hold_decision":
        hvpol = a[3] if len(a) > 3 else "hold"
        return hold_decision(a[0], a[1], a[2], hvpol)
    raise SystemExit("herd.decisions: unknown subcommand %r" % cmd)


def _batch(stream, sep="\x1f"):
    """Run many cases in ONE process (the parity harness's fast path).

    Each input line is ``<state><sep><rmr><sep><mp><sep><wa><sep><verb>[<sep>arg...]``; a knob
    field equal to ``@U`` means that variable is UNSET (absent), any other value (including "")
    is set verbatim. Yields one output line per case, so the caller can diff against the bash lib
    line-for-line. Env mutation is confined here — the decision functions stay pure.
    """
    import os

    knobs = ("REFIX_STATE", "REFIX_MAX_ROUNDS", "MERGE_POLICY", "WATCHER_AUTOMERGE")
    out = []
    for line in stream:
        line = line.rstrip("\n")
        if not line:
            continue
        f = line.split(sep)
        if len(f) < 5:
            continue
        for name, val in zip(knobs, f[:4]):
            if val == "@U":
                os.environ.pop(name, None)
            else:
                os.environ[name] = val
        out.append(_cli(f[4:]))
    return out


if __name__ == "__main__":
    import sys

    if sys.argv[1:2] == ["--batch"]:
        results = _batch(sys.stdin)
        sys.stdout.write("".join(r + "\n" for r in results))
    else:
        sys.stdout.write(_cli(sys.argv[1:]) + "\n")
