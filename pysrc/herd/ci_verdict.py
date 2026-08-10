"""ci_verdict.py — THE one shared CI-VERDICT MAPPING (HERD-578).

Every consumer that turns "what did GitHub Actions say?" into an engine decision reads its answer
from HERE, and nowhere else:

  * ``pysrc/herd/live_runtime.py`` — the watcher's health rail under ``HEALTH_SOURCE=ci`` (the PR's
    OWN CI conclusion IS the health verdict; no local suite is dispatched).
  * ``scripts/herd/agent-watch.sh`` — the main-health branch-CI leg (``_main_ci_classify`` /
    ``_main_ci_starve_scan`` / ``_main_health_ci_log_identity``) and the CI_FAST_BOUNCE leg
    (``_ci_fastbounce_identity`` / ``_handle_ci_fastbounce``), which shell out to the ``__main__``
    CLI below rather than carrying their own copies of the vocabulary.

Before this module the PASS/FAIL conclusion vocabulary, the "✗ <test>" honest-identity parse and the
cancelled-run "no signal, never red" rule each existed in TWO hand-kept copies (agent-watch.sh's two
inline ``python3 -c`` programs). docs/multi-seat-doctrine.md's rule — one reconciled invariant, one
shared check at every surface — is why they now live in one importable place: a fix to the mapping
(a new infra signature, a new terminal conclusion) reaches every consumer at once or not at all.

PURE by construction: nothing here shells out, reads the clock, or touches the filesystem. The
CALLER fetches (`gh run list`, `gh run view --log-failed`) and the caller acts (rerun, bounce,
merge); this module only classifies what it is handed, so every mapping is unit-testable with a
literal fixture and no network.

Two independent reads, composed by :func:`map_verdict`:

  1. :func:`classify_runs` — WHICH run speaks for this head sha, and what bucket is it in
     (``pass`` | ``fail`` | ``cancelled`` | ``pending`` | ``none`` | ``absent``).
  2. :func:`classify_failure_log` — for a ``fail`` bucket ONLY, what KIND of failure the failed
     jobs' own logs describe: a real ``code`` red (run-suite.sh named a test), a platform
     ``infra`` transient (HERD-609), or ``unknown`` (nothing parseable — never guessed at).
"""

# gh's `conclusion` vocabulary, split exactly as the branch-CI leg has always split it. CANCELLED /
# STALE / SKIPPED-by-supersession and any conclusion a future gh adds are deliberately NEVER red:
# a cancelled run is NO SIGNAL, not a failure (agent-watch.sh:_main_ci_classify, HERD-434/545).
PASS_CONCLUSIONS = frozenset(("SUCCESS", "NEUTRAL", "SKIPPED"))
FAIL_CONCLUSIONS = frozenset(("FAILURE", "TIMED_OUT", "STARTUP_FAILURE", "ACTION_REQUIRED"))

# HERD-609 — PLATFORM-INFRA signatures, grounded in the 2026-08-06 GitHub Actions outage that held
# this project's own main red overnight: every failing job died before a single test ran, and the
# engine read the run's FAILURE conclusion as a code red. A failure whose logs carry one of these and
# names no test is the PLATFORM failing, not the diff — it must WAIT (and get one bounded rerun),
# never CODEERROR. Matched case-insensitively as substrings of any log line, so a runner's own
# wording drift ("The self-hosted runner: … lost communication") still lands on the right side.
INFRA_SIGNATURES = (
    "failed to resolve action download info",
    "service unavailable",
    "was not acquired by runner",
    "not acquired by runner",
    "no runner matching the specified labels",
    "the runner has received a shutdown signal",
    "lost communication with the server",
    "the operation was canceled",              # concurrency-cancelled mid-job
    "canceling since a higher priority waiting request",
    "the hosted runner encountered an error",
    "we are experiencing a high volume",
    "unable to resolve action",
    "connection reset by peer",
    "502 bad gateway",
    "503 service temporarily unavailable",
    "remote end closed connection without response",
)

# The honest-identity marker scripts/ci/run-suite.sh prints for each real failing test — the SAME
# glyph agent-watch.sh:_main_health_ci_log_identity has always grepped for (HERD-476/PR #600).
_FAIL_MARK = "✗"        # ✗
_IDENTITY_CAP = 200          # chars, matching the bash leg's ${_cl_names:0:200}

# Verdicts this mapping can produce. CLEAN/CODEERROR/WAIT are the health rail's own vocabulary
# (live_runtime.LiveGates.health); LOCAL is the ONE escape hatch: "CI cannot answer for this repo —
# fall back to the local suite, loudly" (never a silent skip, never an invented verdict).
CLEAN = "CLEAN"
CODEERROR = "CODEERROR"
WAIT = "WAIT"
LOCAL = "LOCAL"


def _clean(value, extra=""):
    """Field-safe rendering for the tab/US-separated CLI lines: no separator may survive inside a
    field or every later column shifts (the hazard $MAIN_HEALTH_STATE's own US-vs-tab note warns
    about)."""
    out = str(value or "").replace("\t", " ").replace("\n", " ")
    for ch in extra:
        out = out.replace(ch, " ")
    return out.strip()


def _conclusion_bucket(conclusion):
    """PASS/FAIL vocabulary → bucket. Anything else (CANCELLED, STALE, an unknown future value) is
    ``cancelled``: terminal, but NO SIGNAL — never red-sustaining, never a clear."""
    concl = str(conclusion or "").upper()
    if concl in PASS_CONCLUSIONS:
        return "pass"
    if concl in FAIL_CONCLUSIONS:
        return "fail"
    return "cancelled"


def classify_runs(runs, sha="", skip_cancelled=None):
    """Classify a ``gh run list --json headSha,status,conclusion,workflowName,databaseId`` array.

    With ``sha`` set (the head-sha-scoped read every PR gate wants), the FIRST COMPLETED run whose
    ``headSha`` matches decides — gh returns newest-first, so that is the newest terminal word about
    this exact commit. Without it, the first conclusive run in the window decides (the branch-wide
    read the main-health leg wants).

    Returns a dict, always the same keys:

      ``bucket``       — ``pass`` | ``fail`` | ``cancelled`` | ``pending`` | ``none`` | ``absent``
      ``workflow``     — the deciding run's workflow name ("" when none decided)
      ``conclusion``   — its raw conclusion, uppercased ("" when none decided)
      ``run_id``       — its ``databaseId`` as a string ("" when absent — an older gh, or a caller
                         that omitted the field; the identity leg then reads UNREADABLE rather than
                         guessing)
      ``run_sha``      — the deciding run's own head sha (which, branch-wide, need not be ``sha``)
      ``cancelled``    — how many DISTINCT shas newer than the deciding run produced only
                         no-signal terminals (the HERD-545 starvation evidence)
      ``in_progress``  — 1 iff any run in the window is still QUEUED/IN_PROGRESS
      ``total``        — how many run objects were in the window at all

    The bucket when nothing decided:
      * ``absent`` — the window held NO runs at all → this branch has no Actions coverage to read.
        The ONLY bucket that means "ask something else"; every other bucket is a real CI state.
      * ``pending`` — a run for this sha is still running (or a newer one is), so a verdict is coming.
      * ``none``    — runs exist, but none of them speak for this sha yet.

    ``skip_cancelled`` decides what a no-signal terminal (CANCELLED/STALE/unknown) does: skip it and
    keep scanning for a conclusive run (the branch-wide starvation read), or let it DECIDE as
    ``cancelled`` (the sha-scoped read — "the newest word about this exact commit was a cancel", which
    is a WAIT). Defaults to ``not sha``, i.e. each read's natural rule; the ``classify`` CLI passes it
    explicitly so its legacy line shape is preserved for every argument, including an empty sha.

    Fail-soft: a non-list, or rows that are not dicts, yield ``absent``/skips rather than raising.
    """
    out = {"bucket": "absent", "workflow": "", "conclusion": "", "run_id": "", "run_sha": "",
           "cancelled": 0, "in_progress": 0, "total": 0}
    if not isinstance(runs, list):
        return out
    if skip_cancelled is None:
        skip_cancelled = not sha
    rows = [r for r in runs if isinstance(r, dict)]
    out["total"] = len(rows)
    if not rows:
        return out
    # Sha-scoped, the count is "how many runs for THIS commit died no-signal" (the merge-burst
    # supersession chain a PR sees); branch-wide it is "how many DISTINCT newer shas never got a
    # conclusive run" (HERD-545's starvation evidence). Both answer "how starved is this read?", so
    # both ride the same field — pre-counted here because the decision loop below returns at the
    # first terminal row and would otherwise never see the rest of the window.
    cancelled = 0
    if sha:
        cancelled = sum(1 for r in rows
                        if _clean(r.get("headSha")) == sha
                        and str(r.get("status") or "").upper() == "COMPLETED"
                        and _conclusion_bucket(r.get("conclusion")) == "cancelled")
    cancelled_shas = set()
    for row in rows:                                   # gh returns newest-first
        row_sha = _clean(row.get("headSha"))
        if sha and row_sha != sha:
            continue
        if str(row.get("status") or "").upper() != "COMPLETED":
            out["in_progress"] = 1                     # still running → never redispatch onto it
            continue
        bucket = _conclusion_bucket(row.get("conclusion"))
        if bucket == "cancelled" and skip_cancelled:
            # Branch-wide: a cancelled run is no-signal — keep scanning for a conclusive one, and
            # count this sha as starvation evidence (HERD-545 part 1).
            if row_sha:
                cancelled_shas.add(row_sha)
            continue
        rid = row.get("databaseId")
        out.update({"bucket": bucket, "workflow": _clean(row.get("workflowName")),
                    "conclusion": str(row.get("conclusion") or "").upper(),
                    "run_id": str(rid) if rid else "", "run_sha": row_sha,
                    "cancelled": cancelled if sha else len(cancelled_shas)})
        return out
    # Nothing terminal decided. Sha-scoped that means a run is either still going (``pending``) or
    # has not been created for this commit yet (``none``); branch-wide it means deep starvation —
    # no conclusive run anywhere in the window (``none``, exactly as the starve scan reports it).
    out["cancelled"] = cancelled if sha else len(cancelled_shas)
    out["bucket"] = "pending" if (sha and out["in_progress"]) else "none"
    return out


def classify_failure_log(text):
    """Classify the FAILED-JOB log of a run that concluded FAILURE (``gh run view <id> --log-failed``).

    Returns ``(kind, detail)``:

      ``("code", "<test>[,<test>…]")``  — scripts/ci/run-suite.sh's own "✗ <test>" lines named real
          failing tests. REAL TEST OUTPUT IS THE ONLY THING THAT MAKES A RED A CODE RED (HERD-609),
          and it wins even when an infra signature also appears in the stream: a run that got far
          enough to fail a named test failed on the diff, whatever else the platform logged.
      ``("infra", "<signature>")``      — no test named, but a failed job carries a platform-infra
          signature → WAIT-infra-transient, never CODEERROR.
      ``("unknown", "")``               — an empty/unreadable log, or one that names neither. The
          caller HOLDS (and says so) rather than guessing a verdict off a bare conclusion string.

    Deliberately narrow, exactly like the bash leg it replaces: no ANSI stripping, no heuristics
    beyond these two markers.
    """
    if not text:
        return ("unknown", "")
    names = []
    seen = set()
    infra_hit = ""
    for raw in str(text).splitlines():
        line = raw.replace("\r", "")
        if _FAIL_MARK in line:
            name = line.split(_FAIL_MARK, 1)[1].strip()
            if name and name not in seen:
                seen.add(name)
                names.append(name)
        if not infra_hit:
            low = line.lower()
            for sig in INFRA_SIGNATURES:
                if sig in low:
                    infra_hit = sig
                    break
    if names:
        return ("code", ",".join(names)[:_IDENTITY_CAP])
    if infra_hit:
        return ("infra", infra_hit)
    return ("unknown", "")


def identity_from_log(text):
    """The honest failing-test identity alone (agent-watch.sh:_main_health_ci_log_identity's contract:
    the comma-joined distinct "✗ <test>" names, capped, or "" when the log names none)."""
    kind, detail = classify_failure_log(text)
    return detail if kind == "code" else ""


def map_verdict(scan, failure=None):
    """Compose the two reads into ONE health verdict. This is the mapping every consumer shares.

    ``scan``    — a :func:`classify_runs` dict.
    ``failure`` — the :func:`classify_failure_log` pair, REQUIRED only for a ``fail`` bucket (a
                  caller that could not read the log at all passes ``None``, which reads UNKNOWN).

    Returns ``(verdict, reason, detail)``:

      ``(CLEAN,     "ci-green",           "<workflow>: <conclusion>")``
      ``(CODEERROR, "ci-code-red",        "<test>[,<test>…]")``
      ``(WAIT,      "ci-infra-transient", "<signature>")``      → caller may rerun ONCE (bounded)
      ``(WAIT,      "ci-log-unreadable",  "<workflow>: <conclusion>")``
      ``(WAIT,      "ci-pending",         "")``
      ``(WAIT,      "ci-cancelled-chain", "<n> newer runs cancelled")``  (qualified, never a red)
      ``(WAIT,      "ci-no-run-yet",      "")``
      ``(LOCAL,     "ci-absent",          "")``                 → fall back to the local suite, loudly

    A missing verdict is ALWAYS WAIT, never BLOCK and never a merge — the same invariant the local
    health rail holds.
    """
    bucket = (scan or {}).get("bucket", "absent")
    workflow = (scan or {}).get("workflow", "") or "run"
    conclusion = (scan or {}).get("conclusion", "") or "?"
    if bucket == "pass":
        return (CLEAN, "ci-green", "%s: %s" % (workflow, conclusion))
    if bucket == "fail":
        kind, detail = failure if failure else ("unknown", "")
        if kind == "code":
            return (CODEERROR, "ci-code-red", detail)
        if kind == "infra":
            return (WAIT, "ci-infra-transient", detail)
        return (WAIT, "ci-log-unreadable", "%s: %s" % (workflow, conclusion))
    if bucket == "cancelled":
        n = int((scan or {}).get("cancelled", 0) or 0)
        return (WAIT, "ci-cancelled-chain",
                "%d newer runs cancelled" % n if n else "run cancelled — awaiting a completed run")
    if bucket == "pending":
        return (WAIT, "ci-pending", "")
    if bucket == "none":
        return (WAIT, "ci-no-run-yet", "")
    return (LOCAL, "ci-absent", "")


# ── CLI: the seam scripts/herd/agent-watch.sh reads this mapping through ───────────────────────────
# Bash cannot import a python module, so the shell consumers shell out to these subcommands rather
# than keeping their own copy of the vocabulary. Each prints EXACTLY the line shape its bash caller
# already parsed before this module existed, so the delegation is a refactor, not a format change.

def _emit_classify(runs, sha):
    """``_main_ci_classify <sha>`` — "<bucket>\\t<workflow>\\t<conclusion>\\t<run-id>" for the newest
    COMPLETED run matching <sha>, or NOTHING. bucket ∈ pass|fail|pending (a cancelled/unknown
    terminal renders ``pending``: terminal, but never red)."""
    scan = classify_runs(runs, sha, skip_cancelled=False)
    bucket = scan["bucket"]
    if bucket in ("absent", "pending", "none"):
        return ""                                       # no completed run for this sha → no verdict
    if bucket == "cancelled":
        bucket = "pending"
    return "%s\t%s\t%s\t%s\n" % (bucket, scan["workflow"], scan["conclusion"] or "?", scan["run_id"])


def _emit_starve_scan(runs):
    """``_main_ci_starve_scan`` — the branch-wide read: "<bucket>US<workflow>US<conclusion>US<run-id>
    US<run-sha>US<n-cancelled>US<in-progress>", US (0x1f) not tab because <run-id>/<workflow> are
    routinely empty and `read` collapses consecutive tabs. bucket ∈ pass|fail|none."""
    scan = classify_runs(runs, "", skip_cancelled=True)
    bucket = scan["bucket"] if scan["bucket"] in ("pass", "fail") else "none"
    return "\x1f".join([bucket, _clean(scan["workflow"], "\x1f"), _clean(scan["conclusion"], "\x1f"),
                        scan["run_id"], _clean(scan["run_sha"], "\x1f"),
                        str(scan["cancelled"]), str(scan["in_progress"])]) + "\n"


def main(argv=None):
    import json
    import sys
    argv = list(sys.argv[1:] if argv is None else argv)
    cmd = argv[0] if argv else ""
    if cmd in ("classify", "starve-scan"):
        try:
            runs = json.load(sys.stdin)
        except Exception:
            return 0                                    # bad/absent JSON → print nothing, fail soft
        if cmd == "classify":
            sys.stdout.write(_emit_classify(runs, argv[1] if len(argv) > 1 else ""))
        else:
            sys.stdout.write(_emit_starve_scan(runs))
        return 0
    if cmd in ("identity", "failure-class"):
        try:
            text = sys.stdin.read()
        except Exception:
            text = ""
        kind, detail = classify_failure_log(text)
        if cmd == "identity":
            sys.stdout.write(detail if kind == "code" else "")
        else:
            sys.stdout.write("%s\t%s\n" % (kind, _clean(detail)))
        return 0
    sys.stderr.write("usage: python3 -m herd.ci_verdict "
                     "classify <sha> | starve-scan | identity | failure-class\n")
    return 2


if __name__ == "__main__":
    import sys
    sys.exit(main())
