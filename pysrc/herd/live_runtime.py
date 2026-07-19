"""herd.live_runtime — the LIVE watcher tick, ported to Python (HERD-320, P3f, EPIC HERD-300).

This is P3f of the strangler port: the FIRST Python engine core that can be AUTHORITATIVE. Where P3c
(:mod:`herd.shadow_runtime`) walked the candidate → gate → decision → apply pipeline in DRY-RUN and
its only footprint was a shadow journal, this module walks the SAME pipeline for real — it discovers
open PRs, DISPATCHES the gate rails by shelling out to the existing leaf scripts, consumes their
verdicts, and — on green — MERGES and REAPS. It is the minimal-but-correct loop the cutover needs:

    discover candidates  →  gate dispatch (health, review)  →  verdict/outcome consumption
                         →  merge-on-green  →  reap        (with holds recognized and HELD)

DESIGN PILLARS (contract §2, spike §0 — the port replaces LOOP+STATE+DECISIONS, shells out for the
leaves):

  * **Python replaces the loop; bash leaves stay leaves.** The gate RAILS are the existing shell
    scripts — ``scripts/herd/herd-review.sh`` (the adversarial review gate) and
    ``scripts/herd/healthcheck.sh`` (the health runner). This module never re-implements a gate; it
    DISPATCHES one (:class:`LiveGates`, which ``subprocess``-execs the leaf and parses its contract
    output) and consumes the result. The *decision* core it reuses VERBATIM from P2
    (:mod:`herd.decisions`) — merge-policy resolution and the hold/merge/observe selector are pure
    functions, never re-derived here.

  * **Same flat state files, real journal, same event shapes.** Actuation writes the SAME
    ``.herd/journal.jsonl`` the bash engine owns, in ``journal.sh``-identical event shapes
    (:class:`LiveJournal` reuses :func:`herd.shadow_journal.encode_event`), so ``herd why`` / ``herd
    log`` / the parity diff read one coherent stream regardless of which implementation wrote a line.
    NO SQLite — that is P4; this phase keeps the append-only flat-file substrate unchanged.

  * **A typed lifecycle, reused from the shadow port.** Candidate lifecycle transitions run through
    the SAME state machine P3b/P3c use (:data:`SM`), as an assertion layer over the real output — an
    illegal transition is journaled, never fatal, exactly as in shadow mode.

  * **Bash stays the resident supervisor; Python is the tick, instant-fallback the kill-switch.** The
    watcher (``agent-watch.sh``) still owns the ``while true`` loop and every sweep. Under
    ``ENGINE_IMPL=python`` it hands ONE tick to ``python3 -m herd.live_runtime --tick``; if that exits
    nonzero the bash tick body runs instead (``herd_engine_live_tick`` returns non-zero → fallback),
    and flipping ``ENGINE_IMPL`` back to ``bash`` disables the port instantly. Ship default ``bash``
    ⇒ this module is never invoked and the watcher is byte-identical to before it existed.

THE VERIFY DISCIPLINE (why this module is safe to test). Every side effect is behind a pluggable
seam with a DRY-RUN twin:

    layer        live (actuates)         dry-run / sim (side-effect-free)
    ─────────    ─────────────────       ────────────────────────────────
    discovery    discover_via_graphql    FixtureDiscovery   (reads a scenario JSON)
    gates        LiveGates               FixtureGates       (scripted rail outcomes)
    apply        LiveActuator            DryRunActuator      (journals only — no gh / git / pane)

``--dry-run`` wires the RIGHT column exclusively: it invokes NO subprocess, touches NO gh/git/pane,
and writes only a caller-named journal (never the real ``.herd/journal.jsonl`` unless explicitly
pointed there). The unit + gate tests drive ONLY that column, so a test run can never actuate against
the live control room — the sim rig "drives behavior through stubs, not bash internals" (spike §3).
The live column's ``subprocess`` calls exist and are real, but are reached only by ``--tick`` against
a genuine repo with ``ENGINE_IMPL=python`` armed.

Stdlib-only (the P1 packaging rule). CLI:
    python3 -m herd.live_runtime --dry-run [--fixture FILE]   # smoke: sim in, result JSON out
    python3 -m herd.live_runtime --tick                       # live: one authoritative tick
Unit-driven by ``tests/test_live_runtime.py`` + gate wrapper ``tests/test-py-live-runtime.sh``.
"""

import glob
import json
import os
import signal
import subprocess
import sys
import time

from herd import cost_emit as _cost_emit
from herd import decisions as D
from herd import shadow_runtime as _shadow
from herd.shadow_journal import encode_event

# ── the typed lifecycle, reused from P3b/P3c (single source of truth for the state vocabulary) ────
# Live mode drives the SAME lifecycle the shadow runtime drives — reusing its resolved state machine
# (real P3b when present, the local mirror otherwise) keeps one authoritative transition table across
# the port. The lifecycle is an ASSERTION layer over the journal here too: a disagreement is observed
# (journaled ``illegal_transition``), never fatal to a tick.
SM = _shadow.SM
_S_INTAKE = _shadow._S_INTAKE
IllegalTransition = _shadow.IllegalTransition

# The four normalized gate outcomes a rail resolves to (contract §2.2) — shared with shadow mode.
PASS, BLOCK, ESCALATE, HOLD = "PASS", "BLOCK", "ESCALATE", "HOLD"

# A FIFTH terminal the live async model needs: a rail whose verdict is not in yet. WAIT is the rail's
# "DISPATCH-AND-WAIT" token (contract §2.1 the gate is async dispatch/collect) — a reviewer/suite was
# just dispatched OR is still in flight for this exact (pr, sha). The candidate is NOT ready this tick;
# it holds WITHOUT merging and re-evaluates next tick when the verdict lands. It is NEVER a BLOCK — a
# missing verdict is not a defect (task HERD-324 leg 1). PENDING is the candidate outcome WAIT maps to.
WAIT, PENDING = "WAIT", "PENDING"


# ── the subject under gate ────────────────────────────────────────────────────────────────────────

class LiveCandidate:
    """One PR at a specific head sha, plus the facts the gate walk needs.

    In live mode these fields come from :func:`discover_via_graphql` (``gh``); in dry-run/sim they
    are injected fixtures. ``stale`` is the cheap behind-base gate (a PR behind its base holds, never
    merges); ``hv_hold`` marks a declared HUMAN-VERIFY block; ``approved`` a sha-keyed approval
    record; ``worktree`` is the path reaped on merge.
    """

    __slots__ = ("pr", "sha", "slug", "base", "worktree", "stale", "hv_hold", "approved",
                 "hv_body", "author", "assignees", "labels", "review_decision", "merge_status",
                 "restale_laps", "agent_status", "wake_succeeds")

    def __init__(self, pr, sha, slug="", base="", worktree="", stale=False,
                 hv_hold=False, approved=False, hv_body="", author="", assignees=None,
                 labels=None, review_decision="", merge_status="", restale_laps=0,
                 agent_status="", wake_succeeds=True):
        self.pr = str(pr)
        self.sha = str(sha)
        self.slug = slug or ("pr-%s" % pr)
        self.base = str(base)
        self.worktree = str(worktree)
        self.stale = bool(stale)
        self.hv_hold = bool(hv_hold)
        self.approved = bool(approved)
        self.hv_body = str(hv_body)
        # SCOPE fields (task HERD-324 leg 3): the identity/labels the watcher-view lens + the
        # WATCHER_SCOPE ownership gate filter discovery on, so a foreign-owner PR never enters
        # classification. Absent in a legacy fixture → empty, which the default (mine/all) passes.
        self.author = str(author or "")
        self.assignees = list(assignees or [])
        self.labels = list(labels or [])
        self.review_decision = str(review_decision or "")
        self.merge_status = str(merge_status or "")
        # MERGE_FAIRNESS (§6.2, HERD-340): this PR's re-stale lap count. In live mode the freeze reads
        # the persistent ledger (LiveState.restale_count); a sim with a black-hole state dir carries the
        # laps here instead, so a scenario can inject a starved candidate. Absent → 0 (never starved).
        self.restale_laps = int(restale_laps or 0)
        # FIXTURE-ONLY wake surface (HERD-370, unit/fixture verification of the bounce's pane-wake
        # check — LiveActuator ignores both and reads the OBSERVED pane state for real; see
        # DryRunActuator.wake_builder). ``agent_status`` is the fixture's simulated pre-bounce pane
        # read ("" | "idle" | "done" | "working" | "dead" | "missing"); "" (the legacy-fixture default,
        # never set before this task) is a sentinel for "not modeled by this fixture" and simulates a
        # successful wake, so every scenario written before HERD-370 stays byte-identical.
        # ``wake_succeeds`` only matters for "idle"/"done" — whether the type+Enter submit flips the
        # agent to "working".
        self.agent_status = str(agent_status or "")
        self.wake_succeeds = bool(wake_succeeds) if wake_succeeds is not None else True

    @classmethod
    def from_dict(cls, d):
        return cls(
            pr=d["pr"], sha=d["sha"], slug=d.get("slug", ""), base=d.get("base", ""),
            worktree=d.get("worktree", ""), stale=d.get("stale", False),
            hv_hold=d.get("hv_hold", False), approved=d.get("approved", False),
            hv_body=d.get("hv_body", ""), author=d.get("author", ""),
            assignees=d.get("assignees"), labels=d.get("labels"),
            review_decision=d.get("review_decision", ""), merge_status=d.get("merge_status", ""),
            restale_laps=d.get("restale_laps", 0),
            agent_status=d.get("agent_status", ""), wake_succeeds=d.get("wake_succeeds", True),
        )


# ── the real journal (journal.sh-identical shapes, best-effort, never raises) ──────────────────────

def _is_verdict_shaped_path(path):
    """A path-typed value that is actually a REVIEWER VERDICT leaked into a filesystem seam (HERD-360):
    it begins with the literal ``REVIEW:`` verdict prefix, or it carries an embedded newline. No real
    journal path does either, so such a value must never reach ``os.makedirs`` — mirrors bash's
    ``_journal_path_is_verdict``."""
    return bool(path) and (path.startswith("REVIEW:") or "\n" in path)


class LiveJournal:
    """Append-only writer to the REAL ``.herd/journal.jsonl``, in ``journal.sh`` shapes.

    Reuses :func:`herd.shadow_journal.encode_event` — the exact bash encoding contract (``ts``+``event``
    first, integer coercion, ``separators=(",", ":")``) — so a line this writer emits is
    indistinguishable from one the bash watcher emits for the same ``(event, kv…)``. Like
    ``journal_append`` (and :class:`ShadowJournal`) it is BEST-EFFORT and SILENT: an unwritable path or
    an encoding fault drops the entry and returns ``False``, never raising into the tick. A ``path`` of
    ``None`` is a black hole (every append is a no-op) — the safe default when no destination resolves.
    """

    _verdict_reject_logged = False

    def __init__(self, path=None):
        self.path = path

    @classmethod
    def resolve_live_path(cls):
        """Resolve the LIVE journal path: ``JOURNAL_FILE`` (the bash engine's own knob) else
        ``<WORKTREES_DIR>/.herd/journal.jsonl``; ``None`` when neither is set.

        HERD-360: a ``JOURNAL_FILE`` override that is verdict-shaped (a reviewer verdict captured into a
        path-typed variable) is DROPPED, not honoured — it falls through to the derived path so a leaked
        verdict never reaches ``os.makedirs``. ``append`` re-checks belt-and-braces."""
        override = os.environ.get("JOURNAL_FILE")
        if override and not _is_verdict_shaped_path(override):
            return override
        base = os.environ.get("WORKTREES_DIR")
        if not base:
            return None
        return os.path.join(base, ".herd", "journal.jsonl")

    def append(self, event, *pairs, **kv):
        """Append one event. Best-effort + silent — a journal hiccup is never fatal to a tick."""
        try:
            if not self.path:
                return False
            # HERD-360 CHANNEL GUARD: never mkdir a verdict-shaped path. A severed-review verdict string
            # ('REVIEW: INFRA-FAIL — … SIGTERM/SIGPIPE …') that reached a path-typed variable would grow a
            # stray dir tree at os.makedirs below. Refuse it, record ONE loud infra_event to a safe
            # fallback, and drop this write. Production paths are never verdict-shaped (byte-inert).
            if _is_verdict_shaped_path(self.path):
                self._reject_verdict_path()
                return False
            items = list(_iter_pairs(list(pairs)))
            items.extend(kv.items())
            line = encode_event(event, items)
            if not line:
                return False
            directory = os.path.dirname(self.path)
            if directory and not os.path.isdir(directory):
                os.makedirs(directory, exist_ok=True)
            with open(self.path, "a", encoding="utf-8") as fh:
                fh.write(line + "\n")
            return True
        except Exception:
            return False

    def _reject_verdict_path(self):
        """Record ONE loud infra_event to a SAFE per-process fallback (never the verdict-shaped path)
        naming the offending value. Idempotent per process; mirrors bash's _journal_reject_verdict_path."""
        if LiveJournal._verdict_reject_logged:
            return
        LiveJournal._verdict_reject_logged = True
        try:
            safe = os.path.join(os.environ.get("TMPDIR") or "/tmp",
                                "herd-journal-verdict-reject-%d.jsonl" % os.getpid())
            line = encode_event("infra_event", [
                ("component", "journal"),
                ("reason", "verdict-shaped journal path rejected (HERD-360) — channel leak, never mkdir'd"),
                ("offending", (self.path or "").replace("\n", " ")[:160]),
            ])
            if line:
                with open(safe, "a", encoding="utf-8") as fh:
                    fh.write(line + "\n")
        except Exception:
            pass


def _iter_pairs(seq):
    """Yield ``(k, v)`` from a flat ``[k, v, …]`` list (dangling final key dropped, journal.sh:136)."""
    for i in range(0, len(seq) - 1, 2):
        yield seq[i], seq[i + 1]


def _pos_int(value, default):
    """A positive int, else ``default`` — fail-soft concurrency-knob coercion (contract §2.3).
    Mirrors ``shadow_runtime._pos_int``: a typo in HEALTH_CONCURRENCY / REVIEW_CONCURRENCY never
    unbounds a rail (0/None → default) or crashes dispatch."""
    try:
        n = int(str(value))
    except (TypeError, ValueError):
        return default
    return n if n > 0 else default


def _count_live_inflight(state_dir, prefix):
    """Count live in-flight markers across ALL candidates for one rail.

    ``prefix`` is the glob prefix, e.g. ``.health-inflight`` or ``.review-inflight``. Dead markers are
    not counted — a crashed worker never wedges a slot (mirrors bash's ``_count_live_healthchecks`` /
    ``_count_live_reviews``). Zero with no state dir (a sim/dry-run tick has no on-disk markers)."""
    if not state_dir:
        return 0
    n = 0
    for path in glob.glob(os.path.join(state_dir, prefix + "-*")):
        if _marker_live(path):
            n += 1
    return n


def _main_health_pending(state_dir):
    """True iff the current main branch HEAD needs a health slot — no verdict yet and no live suite.

    HERD-359: when True the PR health slot check MUST reserve capacity for bash's
    ``reconcile_main_health`` (Phase C). PR candidates MUST NOT claim the last slot when main-health
    is pending: doing so starves the default-branch suite indefinitely when back-to-back PRs keep the
    single HEALTH_CONCURRENCY=1 slot occupied between every pair of ticks.

    Fail-safe: any exception returns False so a misconfigured env never blocks the PR rail.
    Mirrors bash ``_main_health_enabled`` + ``reconcile_main_health`` guard
    (agent-watch.sh:5656, :5962)."""
    try:
        # Same truthy set as bash _main_health_enabled (1|true|on|yes|enable|enabled) — a value that
        # arms the bash reconcile must also arm the reservation, or the two seats disagree per tick.
        tick = os.environ.get("MAIN_HEALTH_TICK", "off").lower()
        if tick not in ("1", "true", "on", "yes", "enable", "enabled"):
            return False
        # MAIN is a plain (unexported) shell var in agent-watch.sh — it never crosses the
        # `--tick` subprocess boundary; fall back to the exported PROJECT_ROOT (HERD-345),
        # exactly like _dispatch_health below.
        main_dir = os.environ.get("MAIN") or os.environ.get("PROJECT_ROOT") or ""
        if not main_dir or not state_dir:
            return False
        out = subprocess.check_output(
            ["git", "-C", main_dir, "rev-parse", "HEAD"],
            stderr=subprocess.DEVNULL,
        )
        sha = out.decode().strip()
        if len(sha) != 40:
            return False
        # Run-once marker: this sha already has a collected verdict.
        if os.path.exists(os.path.join(state_dir, ".main-health-" + sha)):
            return False
        # Live in-flight marker: a worker is already dispatched for this sha.
        inflight = os.path.join(state_dir, ".health-inflight-main-" + sha)
        if os.path.exists(inflight) and _marker_live(inflight):
            return False
        return True
    except Exception:
        return False


# ── the shared on-disk gate contract ($TREES) — sha-keyed ledgers + in-flight markers ─────────────
# The gate rails are ASYNC dispatch/collect state machines whose truth lives in flat files under the
# watcher's state dir ``$TREES`` (== ``$WORKTREES_DIR``): the review ledger, the sha-keyed verdict/health
# caches, the per-``(pr, sha)`` result/dispatch files a finished worker leaves, and the in-flight markers
# that say "a worker is already on this exact (pr, sha)". :class:`LiveState` resolves EXACTLY the same
# paths and formats ``agent-watch.sh`` uses, so a python tick and a bash tick share one substrate: a flip
# between them REUSES a recorded verdict (review-once) and RESPECTS a live marker (never double-dispatch).
# Every path/format anchor is an ``agent-watch.sh`` line; the port must not drift from them.

def _now_epoch():
    """Wall-clock epoch seconds, honoring the ``HERD_FAKE_NOW`` test seam (agent-watch.sh:_now_epoch)."""
    fake = os.environ.get("HERD_FAKE_NOW")
    return fake if fake else str(int(time.time()))


# ── durable refix ledger I/O ($REFIX_STATE = $TREES/.agent-watch-refixed) ───────────────────────────
# Mirrors record_refix + refix_rail_reset (agent-watch.sh:7291, :7300). Fail-soft throughout: a missing
# or unwritable ledger loses a record, never aborts the tick.

def _refix_ledger_path(state_dir):
    """Path to the durable refix ledger; ``None`` when there is no state dir (sim/dry-run)."""
    return os.path.join(state_dir, ".agent-watch-refixed") if state_dir else None


def _read_refix_ledger(state_dir):
    """Read the durable refix ledger; return empty string on any I/O error (fail-soft)."""
    path = _refix_ledger_path(state_dir)
    if not path:
        return ""
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read()
    except Exception:
        return ""


def _append_refix_ledger(state_dir, line):
    """Append one row to the durable refix ledger; return True on success, False on I/O failure.

    A False return with a non-None ``state_dir`` means the ledger is UNWRITABLE — the once-guard
    will not hold on the next tick and the PR will re-bounce indefinitely until the underlying I/O
    problem is resolved.  Callers should journal a one-shot warning when this happens."""
    path = _refix_ledger_path(state_dir)
    if not path:
        return True   # no state dir = sim/dry-run context, treat as success
    try:
        with open(path, "a", encoding="utf-8") as fh:
            fh.write(line)
        return True
    except Exception:
        return False


def _pid_starttime(pid):
    """A stable per-pid start-time token (agent-watch.sh:_pid_starttime) — the marker's recycling guard.
    ``ps -o lstart=`` is portable across macOS/BSD+Linux; empty when ps cannot answer (caller then falls
    back to a bare liveness check rather than over-reaping a live worker)."""
    try:
        out = subprocess.run(["ps", "-o", "lstart=", "-p", str(pid)],
                             capture_output=True, text=True).stdout
        return " ".join(out.split())
    except Exception:
        return ""


def _pid_live(pid):
    try:
        os.kill(int(pid), 0)
        return True
    except Exception:
        return False


def _pid_session(pid):
    """The SESSION id of <pid> (``os.getsid``) — the identity a detached gate worker's WHOLE subtree
    shares (HERD-348). We dispatch the async health/review worker with ``start_new_session=True``, so the
    worker is a session LEADER and its own bats subtree runs under a DIFFERENT process group within that
    session (GNU ``timeout`` re-groups its child). The recorded pid therefore never names every pid in
    the subtree — but the session does: the sweep EXEMPTS it and a supersession CANCELS it by session.
    Empty when the pid is gone or the platform refuses, so a caller never over-reads an absent token."""
    try:
        return str(os.getsid(int(pid)))
    except Exception:
        return ""


def _dispatch_nonce():
    """A per-dispatch nonce — dispatch epoch + dispatcher pid — stamped into the in-flight marker and
    echoed back by the worker into its out-file's first field (HERD-349). It keys a result to the EXACT
    dispatch that produced it regardless of which seat/process wrote the file, so the collector never
    consumes a verdict that predates the live dispatch (it never trusts mtime). A ``.``-joined pair keeps
    it a single whitespace-free token that survives the marker's line-oriented format verbatim."""
    return "%s.%s" % (_now_epoch(), os.getpid())


def _marker_write(path, pid, nonce=""):
    """Lay down a restart-safe in-flight marker: pid, its start-time, dispatch ts, SESSION id
    (agent-watch.sh:2012 + the HERD-348 session line), plus an OPTIONAL 5th line — the dispatch nonce
    (HERD-349). The 4th line lets the sweep exempt — and a supersession cancel — the worker's whole
    detached subtree by session; older 3-line markers (the bash writer, a marker predating this line)
    still work, the reader falls back to the recorded pid's own session. The 5th line is written ONLY
    when a nonce is supplied, so a marker with no nonce (review, bash) stays byte-identical to before.
    Best-effort — an unwritable path drops the marker, never raises into the tick."""
    try:
        with open(path, "w", encoding="utf-8") as fh:
            fh.write("%s\n%s\n%s\n%s\n" % (pid, _pid_starttime(pid), _now_epoch(), _pid_session(pid)))
            if nonce:
                fh.write("%s\n" % nonce)
    except Exception:
        pass


def _marker_nonce(path):
    """The dispatch nonce recorded on line 5 of an in-flight marker (HERD-349), or ``""`` when the
    marker is missing, unreadable, or predates the nonce line (a legacy ≤4-line marker). Fail-soft: any
    fault reads as no-nonce, so the collector treats a result it cannot key to a live dispatch as stale."""
    if not path:
        return ""
    try:
        lines = open(path, encoding="utf-8").read().splitlines()
    except Exception:
        return ""
    return lines[4].strip() if len(lines) > 4 else ""


def _term_sleep():
    """One short (~0.1s) grace tick between a stale worker's SIGTERM and SIGKILL, mirroring
    ``agent-watch.sh:_health_term_sleep`` — a constant upper bound on unwind time, not a knob.
    ``HERD_HEALTH_TERM_SLEEP`` is the test seam so a unit drives the loop with no real wall-clock."""
    try:
        time.sleep(float(os.environ.get("HERD_HEALTH_TERM_SLEEP", "0.1")))
    except Exception:
        pass


def _reap(pid):
    """Best-effort reap of a signaled child so its zombie does not read as 'alive' to ``kill -0`` within
    the same tick. A no-op (ECHILD) when ``pid`` is not our child — the common case, a worker orphaned
    to init by the PRIOR tick that dispatched it, which init reaps for us."""
    try:
        os.waitpid(int(pid), os.WNOHANG)
    except Exception:
        pass


def _session_pids(sess):
    """Live pids whose SESSION == ``sess``, enumerated portably via ``ps -A -o pid=`` + ``os.getsid``.
    macOS' ``ps -o sess=`` prints a hex handle, not the leader pid (sweep.sh:515), so membership is
    resolved by ``os.getsid`` per pid — the same call ``_pid_session`` records. Empty on any ps fault."""
    if not sess:
        return []
    try:
        out = subprocess.run(["ps", "-A", "-o", "pid="], capture_output=True, text=True).stdout
    except Exception:
        return []
    pids = []
    for tok in out.split():
        if not tok.isdigit():
            continue
        try:
            if str(os.getsid(int(tok))) == str(sess):
                pids.append(int(tok))
        except Exception:
            pass
    return pids


def _worker_gone(pid, sess, use_session):
    """True iff the worker is gone — for a SESSION kill, no session member survives; else the bare pid."""
    if use_session:
        return not _session_pids(sess)
    return not _pid_live(pid)


def _signal_session(pid, sess, use_session, sig):
    """Signal the worker's whole SESSION — every member (HERD-348: the ``timeout``-re-grouped suite
    children the leader's process group alone would miss) — when ``use_session``; else the bare pid."""
    if use_session:
        for p in _session_pids(sess):
            try:
                os.kill(p, sig)
            except Exception:
                pass
    else:
        try:
            os.kill(int(pid), sig)
        except Exception:
            pass


def _terminate_worker(path):
    """TERM → grace → KILL a stale in-flight worker and its WHOLE detached subtree — the shared cancel
    primitive supersession reuses (the port's analogue of ``agent-watch.sh:_health_terminate_worker``,
    unified with the HERD-348 session identity).

    The worker is a session LEADER (``start_new_session``), and its suite children may re-group under a
    DIFFERENT process group within that session (GNU ``timeout`` re-groups its child, HERD-348), so the
    whole subtree is reaped by SESSION — the leader's process group alone would leave the re-grouped
    children orphaned-but-alive. Returns ``True`` when every session member is gone; ``False`` when a
    live member survived — the caller then KEEPS the marker so the next tick retries, never re-terminating
    blind over a live suite.

    SAFETY — never sever the tick/watcher. Acts ONLY on the pid/session RECORDED in the marker (or, for a
    legacy 3-line marker, the recorded pid's own session), never a pattern-matched one, and:
      * a dead / pid-recycled marker (``_marker_live`` false) is already gone — nothing to signal;
      * a marker naming THIS process, or whose session is OURS, DOWNGRADES to a bare-pid kill (the
        isolation did not take) — never a session kill that could reach the tick itself.
    """
    if not path or not os.path.exists(path):
        return True
    try:
        with open(path, encoding="utf-8") as fh:
            lines = fh.read().splitlines()
    except Exception:
        return True
    pid = (lines[0].strip() if lines else "")
    if not pid.isdigit():
        return True
    if not _marker_live(path):
        return True                       # dead / recycled — the recycling guard prevents signaling it
    if pid == str(os.getpid()):
        return False                      # never signal ourselves
    # The session to reap: the recorded line 4 (HERD-348) else the pid's own session (a 3-line marker).
    sess = lines[3].strip() if len(lines) > 3 and lines[3].strip() else _pid_session(pid)
    try:
        selfsess = str(os.getsid(0))
    except Exception:
        selfsess = ""
    # SESSION kill only when the recorded session is the worker's OWN and is NOT ours — else DOWNGRADE to
    # a single-pid kill, exactly as the bash seam downgrades a mis-recorded group.
    use_session = bool(sess) and sess.isdigit() and sess != selfsess and sess != str(os.getpid())
    _signal_session(pid, sess, use_session, signal.SIGTERM)
    for _ in range(6):
        _reap(pid)
        if _worker_gone(pid, sess, use_session):
            break
        _term_sleep()
    if not _worker_gone(pid, sess, use_session):
        _signal_session(pid, sess, use_session, signal.SIGKILL)
        for _ in range(3):
            _reap(pid)
            if _worker_gone(pid, sess, use_session):
                break
            _term_sleep()
    # Collect a just-signaled DIRECT-child zombie (ps no longer lists it, but its pid entry lingers until
    # reaped) so kill -0 reflects real death — a no-op (ECHILD) for the common orphan-of-a-prior-tick.
    _reap(pid)
    return _worker_gone(pid, sess, use_session)


def _marker_live(path):
    """True iff the marker's pid is alive AND (recycling guard) its start-time still matches
    (agent-watch.sh:_marker_live). No recorded start-time → a bare kill -0 (fail toward NOT reaping)."""
    try:
        lines = open(path, encoding="utf-8").read().splitlines()
    except Exception:
        return False
    pid = (lines[0].strip() if lines else "")
    if not pid or not _pid_live(pid):
        return False
    st = (lines[1].strip() if len(lines) > 1 else "")
    if not st:
        return True
    cur = _pid_starttime(pid)
    return (not cur) or (cur == st)


class LiveState:
    """Resolver for the sha-keyed gate ledgers + in-flight markers under ``$TREES`` (== ``$WORKTREES_DIR``).

    ``dir`` is the watcher's exported state dir. When it cannot resolve (neither env set) every path is
    ``None`` and every read is empty / every write a no-op — the safe degrade for a sim with no state dir.
    All formats mirror ``agent-watch.sh`` verbatim so the two implementations interoperate on one substrate.
    """

    def __init__(self, state_dir=None):
        self.dir = state_dir or os.environ.get("TREES") or os.environ.get("WORKTREES_DIR") or None
        # P4 store-backend seam (HERD-305). Resolve the mutable-state store: flat (default) reads the
        # flat files below verbatim; sqlite (engaged only post-migration, via the marker resolve_backend
        # honours) routes the sha-keyed accessors through the SQLite store. Fail-soft + SHIP-DORMANT: any
        # import/resolve error leaves _store=None and every method runs its existing flat path unchanged.
        self._store = None
        try:
            from herd import store as _store_mod
            if _store_mod.resolve_backend(self.dir) == "sqlite":
                self._store = _store_mod.open_store(self.dir)
                if not getattr(self._store, "is_sqlite", False):
                    self._store = None
        except Exception:
            self._store = None

    def _p(self, name):
        return os.path.join(self.dir, name) if self.dir else None

    # review substrate ─────────────────────────────────────────────────────────────────────────────
    def review_ledger(self):
        return self._p(".agent-watch-reviewed")            # REVIEW_STATE (agent-watch.sh:301)

    def review_result_file(self, cand):
        return self._p(".review-result-%s-%s" % (cand.pr, cand.sha))     # agent-watch.sh:1946

    def review_inflight_file(self, cand):
        return self._p(".review-inflight-%s-%s" % (cand.pr, cand.sha))   # agent-watch.sh:1945

    def review_registry_file(self, cand):
        return self._p(".review-registry-%s-%s" % (cand.pr, cand.sha))   # agent-watch.sh:1966

    def recorded_review(self, pr, sha):
        """The recorded verdict for this exact ``(pr, sha)`` — review-once reuse (agent-watch.sh:1687).
        ``awk '$2==pr && $3==sha {v=$4} END{print v}'`` — the LAST matching row wins."""
        if self._store is not None:
            return self._store.recorded_review(pr, sha)
        path = self.review_ledger()
        if not path or not os.path.exists(path):
            return None
        verdict = None
        try:
            with open(path, encoding="utf-8") as fh:
                for line in fh:
                    f = line.split()
                    if len(f) >= 4 and f[1] == str(pr) and f[2] == str(sha):
                        verdict = f[3]
        except Exception:
            return None
        return verdict

    def record_review(self, pr, sha, verdict, source="reviewer"):
        """Append one review ledger row ``<epoch> <pr> <sha> <verdict> <source>`` (agent-watch.sh:1820)."""
        if self._store is not None:
            self._store.record_review(pr, sha, verdict, source)
            return
        path = self.review_ledger()
        if not path:
            return
        try:
            with open(path, "a", encoding="utf-8") as fh:
                fh.write("%s %s %s %s %s\n" % (_now_epoch(), pr, sha, verdict, source))
        except Exception:
            pass

    def reviewer_registry_live(self, cand):
        """True iff a reviewer pane is still registered live for this ``(pr, sha)`` (agent-watch.sh:2355):
        a poller may have died but the pane persists — one reviewer IS already on it, so do not spawn a
        second (the 2026-07-08 double-Opus incident). The registry row is ``<pid> <pane>``; pid live ⇒ live."""
        path = self.review_registry_file(cand)
        if not path or not os.path.exists(path):
            return False
        try:
            with open(path, encoding="utf-8") as fh:
                first = fh.readline().split()
        except Exception:
            return False
        return bool(first) and _pid_live(first[0])

    # health substrate ─────────────────────────────────────────────────────────────────────────────
    def health_result_file(self, cand):
        return self._p(".health-result-%s-%s" % (cand.pr, cand.sha))     # sha-cache (agent-watch.sh)

    def _health_key(self, cand):
        return "%s-%s" % (cand.pr, cand.sha)

    def health_dispatch_file(self, cand):
        return self._p(".health-dispatch-%s" % self._health_key(cand))   # worker output (agent-watch.sh)

    def health_inflight_file(self, cand):
        return self._p(".health-inflight-%s" % self._health_key(cand))   # agent-watch.sh:_health_inflight_file

    def health_log_file(self, cand):
        return self._p(".health-log-%s" % self._health_key(cand))

    def health_cached_verdict(self, cand):
        """The TERMINAL health verdict cached for this exact head sha — reuse with no suite re-run
        (agent-watch.sh:10237). The cache line is ``<verdict>\\t<detail>``; verdict ∈ CLEAN|FLAKY|CODEERROR."""
        if self._store is not None:
            return self._store.health_cached_verdict(cand.pr, cand.sha)
        path = self.health_result_file(cand)
        if not path or not os.path.exists(path):
            return None
        try:
            with open(path, encoding="utf-8") as fh:
                first = fh.readline().rstrip("\n")
        except Exception:
            return None
        verdict = first.split("\t", 1)[0]
        return verdict if verdict in ("CLEAN", "FLAKY", "CODEERROR") else None

    def record_health_result(self, cand, verdict, detail=""):
        """Cache a terminal health verdict for this exact commit (agent-watch.sh:record_health_result)."""
        if self._store is not None:
            self._store.record_health_result(cand.pr, cand.sha, verdict, detail)
            return
        path = self.health_result_file(cand)
        if not path or not cand.sha:
            return
        try:
            with open(path, "w", encoding="utf-8") as fh:
                fh.write("%s\t%s\n" % (verdict, detail or ""))
        except Exception:
            pass

    # shared helpers ───────────────────────────────────────────────────────────────────────────────
    def once(self, pr, sha, kind):
        """Fire a hold's side effects exactly once per ``(pr, sha, kind)`` (once-guard doctrine, §5.3).
        Returns True the first time (proceed + record the marker), False thereafter. With no state dir it
        always proceeds — a sim/dry-run tick has no cross-tick state to dedup against, so it never suppresses."""
        if self._store is not None:
            return self._store.once("live-%s-%s-%s" % (kind, pr, sha))
        path = self._p(".live-noted-%s-%s-%s" % (kind, pr, sha))
        if not path:
            return True
        if os.path.exists(path):
            return False
        try:
            open(path, "w", encoding="utf-8").close()
        except Exception:
            pass
        return True

    def posted(self, pr, sha, kind):
        """True iff a SUCCESSFUL ``<kind>`` network post was already recorded for this ``(pr, sha)``.
        Unlike :meth:`once`, the marker is written SEPARATELY (:meth:`record_posted`) only AFTER the post
        succeeds — so a failed post retries next tick, mirroring bash's success-only ledger row
        (agent-watch.sh:_gate_status_posted). With no state dir there is no marker → never posted."""
        path = self._p(".live-posted-%s-%s-%s" % (kind, pr, sha))
        return bool(path) and os.path.exists(path)

    def record_posted(self, pr, sha, kind):
        """Record a SUCCESSFUL ``<kind>`` post for this ``(pr, sha)`` — the at-most-once ledger for a
        network write (agent-watch.sh:_record_gate_status). No-op with no state dir."""
        path = self._p(".live-posted-%s-%s-%s" % (kind, pr, sha))
        if not path:
            return
        try:
            open(path, "w", encoding="utf-8").close()
        except Exception:
            pass

    def merge_refusals(self, pr, sha):
        """The count of consecutive merge REFUSALS recorded for this ``(pr, sha)`` (0 if none / no dir)."""
        path = self._p(".live-merge-refused-%s-%s" % (pr, sha))
        if not path or not os.path.exists(path):
            return 0
        try:
            with open(path, encoding="utf-8") as fh:
                return int((fh.readline() or "0").strip() or "0")
        except Exception:
            return 0

    def bump_merge_refusal(self, pr, sha):
        """Increment and return the consecutive-refusal count for this ``(pr, sha)``. With no state dir (a
        sim/dry-run tick has no cross-tick memory) it cannot persist, so it always reports 1 — a stateless
        tick never accumulates toward the escalation threshold (task HERD-352)."""
        path = self._p(".live-merge-refused-%s-%s" % (pr, sha))
        if not path:
            return 1
        n = self.merge_refusals(pr, sha) + 1
        try:
            with open(path, "w", encoding="utf-8") as fh:
                fh.write("%d\n" % n)
        except Exception:
            pass
        return n

    def clear_merge_refusal(self, pr, sha):
        """Drop the refusal counter for this ``(pr, sha)`` — called on a VERIFIED merge so the ledger
        never carries a stale count forward. No-op with no state dir."""
        self.rm(self._p(".live-merge-refused-%s-%s" % (pr, sha)))

    def rm(self, *paths):
        for p in paths:
            if p:
                try:
                    os.remove(p)
                except OSError:
                    pass

    # re-stale / starvation substrate (MERGE_FAIRNESS, §6.2 / HERD-340) ───────────────────────────────
    def restale_ledger(self):
        return self._p(".agent-watch-restale")            # RESTALE_STATE (agent-watch.sh:407)

    def gate_work_invested(self, cand):
        """True iff this watcher has ALREADY spent (or is spending) gate work on this exact ``(pr, sha)``
        — a cached health verdict, a health worker in flight / awaiting collection, a reviewer in flight,
        or a recorded review verdict (agent-watch.sh:_gate_work_invested:3539). A re-stale lap counts
        only for a sha that carried real investment ('measure work thrown away, not holds'): a PR held
        on its first tick, before any gate ran, has lost nothing. All LOCAL reads — no network, no git."""
        if not cand.pr or not cand.sha or cand.sha == "-":
            return False
        if self.health_cached_verdict(cand):
            return True
        for p in (self.health_inflight_file(cand), self.health_dispatch_file(cand),
                  self.review_inflight_file(cand)):
            if p and os.path.exists(p):
                return True
        return bool(self.recorded_review(cand.pr, cand.sha))

    def restale_counted(self, pr, sha, kind):
        """True iff this exact ``(pr, sha, kind)`` lap is already on the ledger — the dedup that keeps a
        hold lingering across many ticks from inflating the count (agent-watch.sh:restale_counted:3552)."""
        path = self.restale_ledger()
        if not path or not os.path.exists(path):
            return False
        try:
            with open(path, encoding="utf-8") as fh:
                for line in fh:
                    f = line.split()
                    if len(f) >= 4 and f[1] == str(pr) and f[2] == str(sha) and f[3] == str(kind):
                        return True
        except Exception:
            return False
        return False

    def restale_count(self, pr):
        """How many laps this PR has lost across every sha and kind (agent-watch.sh:restale_count:3559).
        ``0`` when the ledger is absent, so callers compare without guarding."""
        path = self.restale_ledger()
        if not path or not os.path.exists(path):
            return 0
        n = 0
        try:
            with open(path, encoding="utf-8") as fh:
                for line in fh:
                    f = line.split()
                    if len(f) >= 2 and f[1] == str(pr):
                        n += 1
        except Exception:
            return 0
        return n

    def note_restale(self, pr, sha, kind):
        """Record ONE lost lap for ``(pr, sha, kind)``, deduped. Returns the PR's new lap total, or
        ``None`` when nothing was recorded (no state dir, missing key, or already counted). Mirrors
        agent-watch.sh:_restale_note:3568 minus the journal side effect — the caller journals — so the
        ledger row format ``<epoch> <pr> <sha> <kind>`` stays byte-identical to the bash tree's."""
        path = self.restale_ledger()
        if not path or not pr or not sha:
            return None
        if self.restale_counted(pr, sha, kind):
            return None
        try:
            with open(path, "a", encoding="utf-8") as fh:
                fh.write("%s %s %s %s\n" % (_now_epoch(), pr, sha, kind))
        except Exception:
            return None
        return self.restale_count(pr)

    # supersession substrate ($TREES) — the sha-keyed scratch a superseded sha's workers leave behind,
    # resolved for an ARBITRARY (pr, sha) so the discovery→cancel pass can reap a PRIOR head's files.
    def _sha_path(self, prefix, pr, sha):
        return self._p("%s-%s-%s" % (prefix, pr, sha)) if self.dir else None

    def health_dispatch_file_sha(self, pr, sha):
        return self._sha_path(".health-dispatch", pr, sha)

    def health_result_file_sha(self, pr, sha):
        return self._sha_path(".health-result", pr, sha)

    def health_log_file_sha(self, pr, sha):
        return self._sha_path(".health-log", pr, sha)

    def review_result_file_sha(self, pr, sha):
        return self._sha_path(".review-result", pr, sha)

    def review_registry_file_sha(self, pr, sha):
        return self._sha_path(".review-registry", pr, sha)

    def stale_inflight(self, prefix, pr, cur_sha):
        """DYNAMIC discovery of doomed workers: yield ``(marker_path, sha)`` for every
        ``$TREES/<prefix>-<pr>-<sha>`` in-flight marker whose ``sha`` differs from the PR's current head
        ``cur_sha`` (a prior head this PR has moved past). No hardcoded candidate list — the stale set is
        globbed off disk, exactly as ``_discard_stale_health`` walks ``.health-inflight-$pr-*``
        (agent-watch.sh:10420). Empty with no state dir (a sim/dry-run tick has no on-disk workers)."""
        if not self.dir:
            return
        for path in sorted(glob.glob(self._p("%s-%s-*" % (prefix, pr)))):
            sha = os.path.basename(path).rsplit("-", 1)[-1]
            if sha and sha != str(cur_sha):
                yield path, sha

    def read_review_pane(self, pr, sha):
        """The reviewer's STAMPED pane id from its dispatch registry row ``<pid> <pane>``
        (agent-watch.sh:2505); '' when there is no registry row — the pane a supersession retires."""
        path = self.review_registry_file_sha(pr, sha)
        if not path or not os.path.exists(path):
            return ""
        try:
            with open(path, encoding="utf-8") as fh:
                parts = fh.readline().split()
        except Exception:
            return ""
        return parts[1] if len(parts) > 1 else ""


# _health_worker mirror (agent-watch.sh:_health_worker): the ASYNC suite the port dispatches for one
# (pr, sha). Runs healthcheck.sh BASELINE-AWARE (HERD-190: $MAIN as the base tree, $TREES as the sha-keyed
# base cache) streaming to a tailable log, keeps the SAME retry-before-red (a rc-1 code error is re-run
# ONCE, solo — a transient self-heals to FLAKY, only a reproducing failure reds), and writes its TERMINAL
# verdict atomically (temp+mv) as one ``<nonce>\t<verdict>\t<detail>`` line the collector consumes:
#   <nonce>\tCLEAN\t{clean|dataenv} — passed (clean, or a tolerated data/env ⚠️ first line, exit 0)
#   <nonce>\tFLAKY\t<detail>        — first run code-errored but the solo retry PASSED
#   <nonce>\tCODEERROR\t<detail>    — code error reproduced on the retry; drives the red row
# The FIRST field is the dispatch nonce ($7) the dispatcher stamped into the in-flight marker (HERD-349):
# the collector consumes this out-file ONLY when the nonce matches the LIVE marker, so a result that
# predates the dispatch (a leftover from a prior/garbage run) is never trusted regardless of its mtime.
# Args: $1 healthcheck.sh  $2 worktree  $3 dispatch-out  $4 log  $5 MAIN(base)  $6 TREES(base cache)
#       $7 dispatch-nonce (epoch.pid — echoed verbatim as the out-file's first field).
_HEALTH_WORKER_SH = r'''
set -u
hc="$1"; dir="$2"; out="$3"; log="$4"; base="$5"; cache="$6"; nonce="$7"
_run() { HERD_BASELINE_DIR="$base" HERD_BASELINE_CACHE="$cache" bash "$hc" "$dir" > "$1" 2>&1; }
_run "$log"; rc=$?
first="$(sed -n '1p' "$log" 2>/dev/null)"
if [ "$rc" -eq 0 ]; then
  case "$first" in "⚠️"*) line="CLEAN"$'\t'"dataenv" ;; *) line="CLEAN"$'\t'"clean" ;; esac
else
  notok="$(grep -m1 -iE 'not ok' "$log" 2>/dev/null)"; [ -n "$notok" ] || notok="$first"
  _run "$log.retry"; rc2=$?
  if [ "$rc2" -eq 0 ]; then
    rm -f "$log.retry" 2>/dev/null || true
    d="$(printf '%s' "$notok" | tr '\t\n' '  ')"; line="FLAKY"$'\t'"${d:0:200}"
  else
    mv "$log.retry" "$log" 2>/dev/null || true
    d="$(grep -m1 -iE 'not ok' "$log" 2>/dev/null)"; [ -n "$d" ] || d="$notok"
    d="$(printf '%s' "$d" | tr '\t\n' '  ')"; line="CODEERROR"$'\t'"${d:0:200}"
  fi
fi
printf '%s\t%s\n' "$nonce" "$line" > "$out.tmp.$$" 2>/dev/null && mv "$out.tmp.$$" "$out" 2>/dev/null || true
'''


# ── branch → slug → worktree (task HERD-346): resolve the POOL worktree a candidate lives in ───────
# Live GraphQL discovery yields a PR's HEAD BRANCH, but the gate rails (healthcheck.sh, herd-review.sh)
# operate on its WORKTREE, keyed by the SLUG. bash derives the slug from the branch with
# ``herd_branch_parse`` (herd-config.sh:1557) under BRANCH_TEMPLATE, and the worktree as ``$TREES/<slug>``
# (agent-watch.sh:1934). This port mirrors that EXACTLY so a python tick dispatches the same suite on the
# same tree the bash tick would — instead of shelling ``healthcheck.sh`` with an EMPTY worktree, which
# usage-errors into a phantom CODEERROR + an endless refix_bounce (the HERD-346 live regression, #453).

def _branch_template():
    """The active BRANCH_TEMPLATE (default ``feat/{slug}``); an unusable value (no ``{slug}``) degrades
    to the default, mirroring the bash inline parser (agent-watch.sh:6341) and ``_herd_branch_template``."""
    tmpl = os.environ.get("BRANCH_TEMPLATE") or "feat/{slug}"
    return tmpl if "{slug}" in tmpl else "feat/{slug}"


def branch_to_slug(branch):
    """Port of ``herd_branch_parse`` (herd-config.sh:1557): echo the slug encoded in ``branch`` under
    the active BRANCH_TEMPLATE. Strips the template's literal prefix (everything up to ``{slug}``, any
    ``{ref}`` a wildcard) and its literal suffix. Empty when the branch does not fit the template."""
    if not branch:
        return ""
    pre, _, post = _branch_template().partition("{slug}")
    slug = branch
    if "{ref}" in pre:                                   # drop up to the last separator trailing {ref}
        sep = pre.rsplit("{ref}", 1)[1]
        if sep:
            i = slug.rfind(sep)
            if i >= 0:
                slug = slug[i + len(sep):]
    elif pre and slug.startswith(pre):                   # else drop the fixed literal prefix
        slug = slug[len(pre):]
    if "{ref}" in post:                                  # cut from the first separator leading {ref}
        sep2 = post.split("{ref}", 1)[0]
        if sep2:
            i = slug.find(sep2)
            if i >= 0:
                slug = slug[:i]
    elif post and slug.endswith(post):                   # else drop the fixed literal suffix
        slug = slug[:len(slug) - len(post)]
    return slug


def _branch_worktree_slug(branch):
    """The WORKTREE-SAFE slug for ``branch``: :func:`branch_to_slug`'s result, unless that result is
    empty or still carries a literal ``/`` (the branch does not fit BRANCH_TEMPLATE) — in which case it
    falls back to flattening every ``/`` in ``branch`` to ``-``. A raw ``/`` left in a slug would nest a
    stray subdirectory under ``$TREES/<slug>`` instead of naming one worktree.

    ONE shared fallback used by BOTH candidate discovery (here) and the ``ADOPT_REMOTE_PRS`` leg
    (``herd_branch_slug``, herd-config.sh) — never a second, independently-invented slugifier. Their
    prior divergence (this port's ``branch_to_slug`` vs. the adopt leg's unconditional ``tr '/' '-'``)
    is exactly what shipped the HERD-377 regression: the adopt leg checked a PR's branch out at
    ``TREES/feat-python-draft-pr-hold`` while discovery resolved ``TREES/python-draft-pr-hold`` for the
    same branch, so the adopted PR was dropped from candidates."""
    slug = branch_to_slug(branch)
    if not slug or "/" in slug:
        return (branch or "").replace("/", "-")
    return slug


def _pool_dir():
    """The worktree POOL root — ``$TREES`` else ``$WORKTREES_DIR`` (identical to :class:`LiveState.dir`).
    Empty when neither is set (an unconfigured pool: the scope/dispatch guards then fail-soft)."""
    return os.environ.get("TREES") or os.environ.get("WORKTREES_DIR") or ""


def _worktree_for_slug(slug):
    """The pool worktree path for ``slug``: ``$TREES/<slug>`` (agent-watch.sh:1934). Empty when there is
    no slug or no configured pool — fail-soft: we never fabricate a worktree path we cannot ground."""
    pool = _pool_dir()
    return os.path.join(pool, slug) if (slug and pool) else ""


def _is_worktree(path):
    """True iff ``path`` is a checked-out git worktree (its ``.git`` pointer file/dir exists). Backs the
    pool-membership scope (leg 3) and the pre-dispatch guard (leg 2): a PR whose slug has no worktree on
    disk is FOREIGN to this pool — its suite would usage-error, so it is never classified nor dispatched."""
    return bool(path) and os.path.isdir(path) and os.path.exists(os.path.join(path, ".git"))


def _pool_scoped(cands):
    """Drop candidates NOT backed by a real worktree in this pool (task HERD-346, leg 3) — the port of
    bash's worktree-first discovery (``_discover_feature_worktrees``, agent-watch.sh:11211), where a PR
    with no ``$TREES`` worktree never becomes a candidate. FAIL-SOFT: with no pool configured the check is
    skipped (byte-identical passthrough), exactly as bash's ``_under_trees`` no-ops when ``$TREES`` is unset."""
    if not _pool_dir():
        return list(cands)
    return [c for c in cands if _is_worktree(c.worktree)]


# ── discovery: where candidates come from ─────────────────────────────────────────────────────────

def discover_via_graphql(repo=None, limit=50):
    """Discover open-PR candidates in ONE batched GraphQL round-trip (contract §6, spike §0.3).

    LIVE ONLY — shells out to ``gh api graphql``. Replaces the bash tree's per-PR ``gh`` fan-out with a
    single query for every open PR's number, head sha, base ref, and merge state, so N candidates cost
    ONE request, not N. ``stale`` is derived from ``mergeStateStatus == BEHIND`` (the PR is behind its
    base and must rebuild before it can merge). Raises ``subprocess.CalledProcessError`` /
    ``json.JSONDecodeError`` on a transport/parse failure — the caller (the ``--tick`` entrypoint)
    catches it and returns non-zero so the bash supervisor falls back for that tick.

    Never called under ``--dry-run`` (that path uses :class:`FixtureDiscovery`), so a test never runs
    ``gh``.
    """
    query = (
        "query($owner:String!,$name:String!,$n:Int!){repository(owner:$owner,name:$name){"
        "pullRequests(states:OPEN,first:$n){nodes{number headRefName mergeStateStatus "
        "headRefOid baseRefName reviewDecision isDraft author{login} "
        "assignees(first:10){nodes{login}} labels(first:20){nodes{name}}}}}}"
    )
    owner, name = _repo_owner_name(repo)
    out = subprocess.run(
        ["gh", "api", "graphql", "-f", "query=%s" % query,
         "-F", "owner=%s" % owner, "-F", "name=%s" % name, "-F", "n=%d" % int(limit)],
        capture_output=True, text=True, check=True,
    )
    data = json.loads(out.stdout)
    nodes = (((data.get("data") or {}).get("repository") or {})
             .get("pullRequests") or {}).get("nodes") or []
    cands = []
    for node in nodes:
        if node.get("isDraft"):
            continue  # never adopt a draft (parity: agent-watch.sh ~line 1805)
        # leg 1: derive the SLUG from the head branch (bash convention, herd_branch_parse) and resolve
        # the POOL worktree ($TREES/<slug>) the rails run on — never leave worktree empty, which shells
        # healthcheck.sh with no tree and usage-errors into a phantom CODEERROR (HERD-346, #453).
        branch = node.get("headRefName", "")
        slug = _branch_worktree_slug(branch)
        cands.append(LiveCandidate(
            pr=node.get("number"), sha=node.get("headRefOid", ""),
            slug=slug, base=node.get("baseRefName", ""),
            worktree=_worktree_for_slug(slug),
            stale=(node.get("mergeStateStatus") == "BEHIND"),
            merge_status=node.get("mergeStateStatus", ""),
            author=((node.get("author") or {}).get("login", "")),
            assignees=[(a or {}).get("login", "") for a in
                       ((node.get("assignees") or {}).get("nodes") or [])],
            labels=[(l or {}).get("name", "") for l in
                    ((node.get("labels") or {}).get("nodes") or [])],
            review_decision=node.get("reviewDecision", ""),
        ))
    return cands


# ── scope: which discovered PRs may ENTER classification (task HERD-324 leg 3) ─────────────────────
# The watcher-view lens (WATCHER_VIEW*) and the WATCHER_SCOPE ownership gate NARROW discovery exactly
# as the bash tick does (agent-watch.sh:10620–10810): a foreign-owner PR never enters the gate DAG, so
# the port can never merge a teammate's PR. Both are read-time SELECTION filters — they only ever
# WITHHOLD a candidate, never authorize a merge the gates would otherwise deny. Default (WATCHER_VIEW
# unset/all + WATCHER_SCOPE unset/mine) is a byte-identical passthrough: every discovered PR flows through.

_WATCHER_KEYS = ("WATCHER_SCOPE", "WATCHER_VIEW", "WATCHER_VIEW_AUTHOR", "WATCHER_VIEW_ASSIGNEE",
                 "WATCHER_VIEW_LABEL", "WATCHER_VIEW_STATUS", "WATCHER_VIEW_DEPS_LABEL", "WATCHER_OWNER",
                 "GATE_STATUS")

# ── merge fairness / starvation freeze (MERGE_FAIRNESS, §6.2 / HERD-340) ───────────────────────────
# SHIP-DORMANT. MERGE_FAIRNESS=off (the default, and any unrecognized value) disables every re-stale
# count and every freeze, so the candidate walk — and every event, dispatch and merge that follows —
# is BYTE-IDENTICAL to today. The keys are READ from the same watcher-exported config the bash engine
# reads; nothing is added to herd-config.sh (MERGE_FAIRNESS is already a registered bash key).
_FAIRNESS_KEYS = ("MERGE_FAIRNESS", "MERGE_FAIRNESS_STARVE_THRESHOLD")
_DEFAULT_STARVE_THRESHOLD = 3         # agent-watch.sh:_RESTALE_STARVE_THRESHOLD=3 (line 410)


def _merge_fairness_enabled(config):
    """True iff ``MERGE_FAIRNESS`` opts in (agent-watch.sh:_merge_fairness_enabled:3619). Any
    unrecognized value → off, so the default and any typo preserve today's EXACT behavior."""
    val = str((config or {}).get("MERGE_FAIRNESS", "") or "").strip().lower()
    return val in ("1", "true", "on", "yes", "enable", "enabled")


def _starve_threshold(config):
    """Laps at or past which a would-auto-merge PR is head-of-line-starved and freezes its siblings for
    one window (agent-watch.sh:_RESTALE_STARVE_THRESHOLD). A missing / non-positive / non-integer
    ``MERGE_FAIRNESS_STARVE_THRESHOLD`` falls back to the bash default (3)."""
    raw = str((config or {}).get("MERGE_FAIRNESS_STARVE_THRESHOLD", "") or "").strip()
    try:
        n = int(raw)
    except (TypeError, ValueError):
        return _DEFAULT_STARVE_THRESHOLD
    return n if n >= 1 else _DEFAULT_STARVE_THRESHOLD


def _watcher_scope(config):
    v = str(config.get("WATCHER_SCOPE", "") or "mine")
    return v if v in ("mine", "all") else "mine"                      # unknown → safe default (10764)


def _resolve_owner(config):
    """The operator identity that owns auto-merge: WATCHER_OWNER → WATCHER_VIEW_AUTHOR → ``gh api user``
    (agent-watch.sh:10784). The gh probe is LIVE-only and reached solely in team mode with no configured
    identity; a sim always supplies WATCHER_OWNER, so a test never runs gh."""
    owner = config.get("WATCHER_OWNER") or config.get("WATCHER_VIEW_AUTHOR")
    if owner:
        return owner
    try:
        out = subprocess.run(["gh", "api", "user", "-q", ".login"],
                             capture_output=True, text=True, check=True)
        return out.stdout.strip()
    except Exception:
        return ""


def _view_keeps(cand, config):
    """Port of the bash watcher-view ``keep(pr)`` predicate (agent-watch.sh:10731): lens narrowing
    (mine/deps/review-queue) AND'd with the author/assignee/label/status filters. An unknown lens
    degrades to ``all`` (shows every PR, never fewer-by-accident)."""
    lens = str(config.get("WATCHER_VIEW", "") or "all")
    if lens not in ("all", "mine", "deps", "review-queue"):
        lens = "all"
    author = config.get("WATCHER_VIEW_AUTHOR") or (_resolve_owner(config) if lens == "mine" else "")
    assignee = config.get("WATCHER_VIEW_ASSIGNEE") or ""
    label = config.get("WATCHER_VIEW_LABEL") or ""
    status = config.get("WATCHER_VIEW_STATUS") or ""
    deps_label = config.get("WATCHER_VIEW_DEPS_LABEL") or "dependencies"
    if lens == "mine":
        if not author or cand.author != author:
            return False
    elif lens == "review-queue":
        if cand.review_decision != "REVIEW_REQUIRED":
            return False
    elif lens == "deps":
        if deps_label not in cand.labels:
            return False
    if author and lens != "mine" and cand.author != author:
        return False
    if assignee and assignee not in cand.assignees:
        return False
    if label and label not in cand.labels:
        return False
    if status and cand.merge_status != status:
        return False
    return True


def _select_candidates(cands, config):
    """Apply the watcher-view lens then the WATCHER_SCOPE ownership gate to a discovered candidate list.
    In team mode (scope=all) a PR NOT authored by the resolved operator identity is dropped — FAIL-CLOSED:
    an unresolvable owner drops every foreign candidate rather than blind-merge one (agent-watch.sh:10801)."""
    config = config or {}
    kept = [c for c in cands if _view_keeps(c, config)]
    if _watcher_scope(config) == "all":
        owner = _resolve_owner(config)
        kept = [c for c in kept if owner and c.author == owner]
    return kept


def _repo_owner_name(repo=None):
    """``(owner, name)`` for the current repo — ``repo`` arg (``owner/name``) else ``gh repo view``."""
    if repo and "/" in repo:
        owner, name = repo.split("/", 1)
        return owner, name
    out = subprocess.run(
        ["gh", "repo", "view", "--json", "owner,name",
         "-q", "[.owner.login,.name]|@tsv"],
        capture_output=True, text=True, check=True,
    )
    parts = out.stdout.strip().split("\t")
    return (parts[0], parts[1]) if len(parts) == 2 else ("", "")


class FixtureDiscovery:
    """Sim/dry-run discovery: candidates injected from a scenario dict, never the live control room.
    The scope/view filter (leg 3) is applied HERE too, so a sim can prove foreign-owner exclusion
    hermetically (no gh) via a scenario ``config`` carrying WATCHER_SCOPE/WATCHER_VIEW/WATCHER_OWNER."""

    def __init__(self, scenario):
        self._cands = [LiveCandidate.from_dict(c) for c in (scenario.get("candidates") or [])]
        self._config = dict((scenario or {}).get("config") or {})

    def discover(self):
        return _select_candidates(list(self._cands), self._config)


class _GraphQLDiscovery:
    """Thin adapter so the live entrypoint has the same ``.discover()`` shape as the fixture one, with
    the scope/view ownership gate applied to the batched GraphQL result before anything is classified."""

    def __init__(self, config=None, repo=None):
        self._config = config or {}
        self._repo = repo

    def discover(self):
        # owner/view scope, THEN pool scope (leg 3): a PR with no worktree in this pool is foreign and
        # never enters classification — the port of bash's worktree-first discovery.
        return _pool_scoped(_select_candidates(discover_via_graphql(self._repo), self._config))


# ── gate dispatch: shell out to the existing leaf scripts, consume their contract output ───────────

class LiveGates:
    """Dispatch the gate rails by SHELLING OUT to the existing leaf scripts — ASYNC, sha-keyed, and
    marker-aware, EXACTLY as the bash tick does (task HERD-324 leg 1, agent-watch.sh:_review_gate_step /
    :_healthcheck_gate). Each rail is a NON-BLOCKING dispatch/collect step over the shared ``$TREES``
    substrate (:class:`LiveState`), so a python↔bash flip on the very same ``(pr, sha)`` can never
    double-dispatch and never re-runs a review whose verdict is already recorded:

      1. REVIEW-ONCE — a verdict recorded for this exact ``(pr, sha)`` is REUSED, no reviewer/suite runs.
      2. COLLECT — a finished worker's result/dispatch file is consumed into the ledger/sha-cache.
      3. IN FLIGHT — a live marker (or, for review, a live reviewer registry) means one is ALREADY on it
         → :data:`WAIT` (dispatch-and-wait), NEVER a second dispatch.
      4. DISPATCH — nothing recorded, nothing in flight → launch the leaf ASYNC, lay the marker, WAIT.

    A missing verdict is :data:`WAIT`, NEVER :data:`BLOCK`. ``health`` runs ``healthcheck.sh`` baseline-aware
    via the :data:`_HEALTH_WORKER_SH` worker; ``review`` runs ``herd-review.sh`` with the same result-file /
    sha-pin env the bash dispatcher uses. Never reached under ``--dry-run`` (that uses :class:`FixtureGates`).
    The ``reused_*`` flags tell the walk a terminal was REUSED (not freshly collected), so it does not
    re-journal a ``verdict_recorded`` / ``healthcheck_outcome`` for a held PR every tick.
    """

    def __init__(self, home, state, journal, config=None):
        self.home = home
        self.state = state
        self.journal = journal
        self.reused_review = False
        self.reused_health = False
        cfg = config or {}
        self._health_max = _pos_int(cfg.get("HEALTH_CONCURRENCY"), 1)
        self._review_max = _pos_int(cfg.get("REVIEW_CONCURRENCY"), 2)
        # HERD-373: a LiveGates instance is constructed fresh once per tick (_run_live_tick), so
        # memoizing here is tick-scoped for free — never persisted, a new tick always re-evaluates.
        self._main_health_pending_cache = None

    def _script(self, name):
        return os.path.join(self.home, "scripts", "herd", name)

    def _main_health_pending_memo(self, state_dir):
        """Memoized ``_main_health_pending(state_dir)`` — ONE ``rev-parse`` per tick, not one per
        PR-health candidate (HERD-373). Cached on ``self`` because a LiveGates instance lives exactly
        one tick (a fresh instance is constructed per ``--tick`` invocation, ``_run_live_tick``) — the
        cache is never persisted and a new tick always re-evaluates."""
        if self._main_health_pending_cache is None:
            self._main_health_pending_cache = _main_health_pending(state_dir)
        return self._main_health_pending_cache

    # ── health rail ────────────────────────────────────────────────────────────────────────────────
    def health(self, cand):
        st = self.state
        self.reused_health = False
        # 1. REVIEW-ONCE: an unchanged commit cannot yield a different verdict — reuse the sha-cache.
        cached = st.health_cached_verdict(cand)
        if cached:
            self.reused_health = True
            return cached
        # 2. COLLECT a finished worker's terminal verdict into the sha-cache (at-least-once: record the
        #    durable cache, THEN drop the scratch — a crash mid-collect re-reads the dispatch file next tick).
        disp = st.health_dispatch_file(cand)
        inflight = st.health_inflight_file(cand)
        if disp and os.path.exists(disp):
            try:
                with open(disp, encoding="utf-8") as fh:
                    first = fh.readline().rstrip("\n")
            except Exception:
                first = ""
            # 2a. FRESHNESS GUARD (HERD-349): the worker echoes its dispatch nonce as the out-file's FIRST
            #     field. A result is trustworthy ONLY when that nonce matches the LIVE in-flight marker's
            #     nonce; a missing/mismatched nonce means the file predates this dispatch (a leftover from a
            #     prior or garbage run — the 2026-07-11 PR450/451 same-tick stale-consume). Fail-soft: drop
            #     it, journal `stale_result_ignored`, and FALL THROUGH so a real suite is re-dispatched — a
            #     stale out-file is NEVER consumed as a verdict, never trusts mtime, and never crashes the tick.
            nonce, _, rest = first.partition("\t")
            expected = _marker_nonce(inflight)
            if not expected or nonce != expected:
                self.journal.append("stale_result_ignored", "pr", cand.pr, "sha", cand.sha,
                                    "slug", cand.slug, "rail", "health", "nonce", nonce or "",
                                    "expected", expected or "")
                st.rm(disp)
                # no return: a live worker (if any) still owns the marker and will write a fresh,
                # nonce-matched result; otherwise the dispatch legs below start one.
            else:
                verdict, _, detail = rest.partition("\t")
                if verdict in ("CLEAN", "FLAKY", "CODEERROR"):
                    st.record_health_result(cand, verdict, detail)
                    st.rm(disp, inflight)
                    return verdict
                # Nonce matched but the payload is unparseable / truncated → an infra death, NOT a verdict;
                # never cache. Drop it and re-dispatch next tick (bounded once the suite finally succeeds).
                st.rm(disp)
                return WAIT
        # 3. IN FLIGHT: a live worker on this exact (pr, sha) → wait, never a second overlapping suite.
        if inflight and _marker_live(inflight):
            return WAIT
        # 3.5 HARD pre-dispatch worktree validation (task HERD-346, leg 2): NEVER shell the suite at a
        #     worktree that isn't there — healthcheck.sh <missing> usage-errors into a phantom CODEERROR
        #     and an endless refix_bounce (#453). A resolved-but-ABSENT worktree REFUSES dispatch and
        #     HOLDS (WAIT, re-evaluated next tick) — never a red row, never a merge. The pool scope (leg 3)
        #     normally drops such a PR at discovery, so this is the belt-and-suspenders guard for a worktree
        #     reaped between discovery and dispatch. An EMPTY worktree (a hermetic/legacy candidate that
        #     carries none) is UNKNOWN, not absent → fall through, byte-identical to before.
        if cand.worktree and not _is_worktree(cand.worktree):
            self.journal.append("dispatch_refused", "pr", cand.pr, "sha", cand.sha, "slug", cand.slug,
                                "rail", "health", "reason", "no-worktree", "worktree", cand.worktree)
            return WAIT
        # 3.7 CONCURRENCY SLOT CHECK (HEALTH_CONCURRENCY, default 1): never dispatch when the global
        #     in-flight count reaches the limit — all worktrees share one git object store, so concurrent
        #     suites race on object refs and blow past HEALTH_INFLIGHT_TIMEOUT (live regression 2026-07-12:
        #     PRs 450+451 ran concurrently, both reaped at timeout, re-dispatched, looping forever).
        #     Dead markers are not counted — a crashed worker never wedges a slot (mirrors bash's
        #     ``_count_live_healthchecks`` / ``_health_slot_free``, agent-watch.sh:10297,10311).
        _hc_n = _count_live_inflight(st.dir, ".health-inflight")
        # HERD-359: if the default-branch sha is unverified and not yet in-flight, reserve one slot
        # so bash's reconcile_main_health (Phase C) always finds capacity within the same tick.
        # With HEALTH_CONCURRENCY=1 this collapses the effective limit to 0 — no new PR health suite
        # starts until main-health is dispatched. Fail-safe: _main_health_pending returns False on
        # any env error (missing MAIN, no git, etc.) so a misconfigured seat never blocks the PR rail.
        _effective_max = self._health_max - (1 if self._main_health_pending_memo(st.dir) else 0)
        if _hc_n >= _effective_max:
            self.journal.append("health_queued", "pr", cand.pr, "sha", cand.sha, "slug", cand.slug,
                                "inflight", _hc_n, "limit", self._health_max)
            return WAIT
        # 4. DISPATCH the async suite worker + lay the marker → wait.
        self._dispatch_health(cand)
        return WAIT

    def _dispatch_health(self, cand):
        st = self.state
        disp = st.health_dispatch_file(cand)
        inflight = st.health_inflight_file(cand)
        log = st.health_log_file(cand)
        if not disp:
            return
        # (a) A dispatch OWNS its result slot (HERD-349): DELETE any pre-existing out-file BEFORE spawning,
        #     so a leftover from a prior/garbage run can never be mistaken for this worker's result — the
        #     collect leg runs before dispatch, so a stale file left in place would be consumed same-tick.
        st.rm(disp)
        # (b) Belt-and-braces: a per-dispatch nonce keys the result to THIS dispatch. It is stamped into the
        #     in-flight marker AND handed to the worker, which echoes it as the out-file's first field; the
        #     collector ignores any out-file whose nonce does not match the live marker (never trusts mtime).
        nonce = _dispatch_nonce()
        base = os.environ.get("MAIN") or os.environ.get("PROJECT_ROOT") or ""
        try:
            proc = subprocess.Popen(
                ["bash", "-c", _HEALTH_WORKER_SH, "_",
                 self._script("healthcheck.sh"), cand.worktree, disp, log, base, st.dir or "", nonce],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True,
            )
        except Exception as exc:
            self.journal.append("infra_event", "pr", cand.pr, "sha", cand.sha, "rail", "health",
                                "detail", "health dispatch failed: %s" % str(exc)[:160])
            return
        # The marker records the worker's SESSION (HERD-348): start_new_session makes it a session
        # leader, so a supersession (and the sweep) reaps its whole detached suite subtree by session.
        # It also carries the dispatch nonce (line 5) the collector matches the out-file's first field against.
        _marker_write(inflight, proc.pid, nonce=nonce)
        self.journal.append("healthcheck_started", "pr", cand.pr, "slug", cand.slug, "sha", cand.sha,
                            "pid", proc.pid, "log_path", log or "")

    # ── review rail ────────────────────────────────────────────────────────────────────────────────
    def review(self, cand):
        st = self.state
        self.reused_review = False
        # 1. REVIEW-ONCE: a recorded PASS/BLOCK for this exact (pr, sha) is reused — no reviewer runs.
        rec = st.recorded_review(cand.pr, cand.sha)
        if rec in ("PASS", "BLOCK"):
            self.reused_review = True
            return rec
        # 2. COLLECT a finished reviewer verdict: record PASS/BLOCK durably to the ledger FIRST, then drop
        #    the scratch (record-before-rm, agent-watch.sh:2863). INFRA-FAIL / no verdict is never cached.
        result = st.review_result_file(cand)
        inflight = st.review_inflight_file(cand)
        if result and os.path.exists(result):
            try:
                with open(result, encoding="utf-8") as fh:
                    text = fh.read()
                verdict = parse_review_verdict(text)
            except Exception:
                text, verdict = "", "INFRA"
            if verdict in ("PASS", "BLOCK"):
                st.record_review(cand.pr, cand.sha, verdict, "reviewer")
                # RUBRIC_FILE (HERD-400): a second, independent pass over the SAME text — a malformed
                # or absent RUBRIC: line never affects the verdict just recorded above. Journaled only
                # when >=1 criterion parsed cleanly (RUBRIC_FILE unset, or every line malformed, stays
                # a silent no-op — byte-identical to before this key existed).
                rubric = parse_rubric_verdicts(text)
                if rubric:
                    self.journal.append("rubric_verdicts", "pr", cand.pr, "sha", cand.sha,
                                        "verdict", verdict, "criteria_count", len(rubric),
                                        "criteria", json.dumps(rubric, separators=(",", ":")))
                st.rm(result, inflight, st.review_registry_file(cand))
                return verdict
            st.rm(result, inflight, st.review_registry_file(cand))
            return "INFRA"          # infra death — a transient the caller escalates, never a cached BLOCK
        # 3. IN FLIGHT: a live reviewer poller (marker) OR its pane (registry) → dispatch-and-wait.
        if inflight and _marker_live(inflight):
            return WAIT
        if st.reviewer_registry_live(cand):
            return WAIT
        # 3.5 CONCURRENCY SLOT CHECK (REVIEW_CONCURRENCY, default 2): never dispatch when the global
        #     in-flight reviewer count reaches the limit (mirrors bash's ``_count_live_reviews >= _review_conc``
        #     QUEUED path, agent-watch.sh:3115). Dead markers are not counted — a crashed reviewer never
        #     wedges a slot (``_count_live_reviews``, agent-watch.sh:2455).
        _rv_n = _count_live_inflight(st.dir, ".review-inflight")
        if _rv_n >= self._review_max:
            self.journal.append("review_queued", "pr", cand.pr, "sha", cand.sha, "slug", cand.slug,
                                "inflight", _rv_n, "limit", self._review_max)
            return WAIT
        # 4. DISPATCH the reviewer async + lay the marker → wait.
        self._dispatch_review(cand)
        return WAIT

    def _dispatch_review(self, cand):
        st = self.state
        result = st.review_result_file(cand)
        inflight = st.review_inflight_file(cand)
        registry = st.review_registry_file(cand)
        if not result:
            return
        env = dict(os.environ)
        env["HERD_REVIEW_RESULT_FILE"] = result
        env["HERD_REVIEW_REGISTRY_FILE"] = registry or ""
        env["HERD_REVIEW_SHA"] = cand.sha          # pin the reviewer's diff input to this dispatch sha
        # HERD-353: resolve the reviewer model ONCE — from the effective config env herd-config.sh
        # exports to this engine child (HERD_REVIEW_MODEL override wins, else MODEL_REVIEW — the SAME
        # fallback chain herd-review.sh's REVIEW_MODEL uses) — and PIN it into the reviewer's env so the
        # process runs on EXACTLY the model we journal. That single resolution point is the invariant:
        # `review_dispatched.model` can never diverge from what the reviewer actually ran, and it never
        # reads a second, drifting lookup. (The port regressed this — the field journaled empty because
        # MODEL_REVIEW is an UNEXPORTED shell var the python child never saw; the reviewer, which sources
        # config itself, still ran the right model, so only the journal was wrong. Pinning + the
        # herd-config.sh export close both halves.)
        model = env.get("HERD_REVIEW_MODEL") or env.get("MODEL_REVIEW") or ""
        if model:
            env["HERD_REVIEW_MODEL"] = model
        try:
            proc = subprocess.Popen(
                ["bash", self._script("herd-review.sh"), cand.pr, cand.slug],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True, env=env,
            )
        except Exception as exc:
            self.journal.append("infra_event", "pr", cand.pr, "sha", cand.sha, "rail", "review",
                                "detail", "review dispatch failed: %s" % str(exc)[:160])
            return
        # The marker records the reviewer's SESSION (start_new_session → session leader) so a superseding
        # push can terminate its whole subtree, then retire its stamped pane (HERD-341 + HERD-348).
        _marker_write(inflight, proc.pid)
        # Contract §3.4 requires the full shape (pr, sha, pid, model, log_path, pin) — the same six
        # keys bash emits (agent-watch.sh:2754) and the shadow twin emits (shadow_runtime.py:482), so
        # `herd why`/`herd log`/cost read `model`+`log_path` and a shadow↔live parity diff stays clean.
        # `model` is the SAME value pinned into the reviewer's env above (single source); `log_path` is
        # the reviewer's result file.
        self.journal.append("review_dispatched", "pr", cand.pr, "sha", cand.sha, "pid", proc.pid,
                            "model", model, "log_path", result, "pin", cand.sha)


def parse_review_verdict(text):
    """The LAST ``REVIEW:`` line's verdict → ``PASS`` | ``BLOCK`` | ``INFRA`` (herd-review.sh CONTRACT).

    ``REVIEW: PASS`` / ``REVIEW: BLOCK`` map to the recorded verdict; ``REVIEW: INFRA-FAIL`` and ANY
    absent/unparseable output map to ``INFRA`` — a transient the caller retries and NEVER caches as a
    per-PR code verdict (contract §2.2/§3.2). Pure, so the parser is unit-tested without a subprocess.
    """
    verdict = "INFRA"
    for line in text.splitlines():
        s = line.strip()
        if not s.upper().startswith("REVIEW:"):
            continue
        body = s.split(":", 1)[1].strip().upper()   # everything after the first colon
        if body.startswith("PASS"):
            verdict = "PASS"
        elif body.startswith("BLOCK"):
            verdict = "BLOCK"
        else:
            # INFRA-FAIL, an empty body, or any unrecognized word — a transient, never a code verdict.
            verdict = "INFRA"
    return verdict


def parse_rubric_verdicts(text):
    """Extract ``RUBRIC: <id> | PASS|FAIL | <reason>`` lines (rubric-primitive, HERD-400).

    A SECOND, independent pass over the exact same text :func:`parse_review_verdict` reads — never
    consulted by it, and never able to change its PASS/BLOCK/INFRA result. Returns an ordered list of
    ``{"id", "verdict", "reason"}`` dicts, one per well-formed line (duplicates — e.g. one per review-
    panel member — are kept, not folded). A malformed line (not exactly three ``|``-separated fields,
    an empty id, or a verdict word that isn't ``PASS``/``FAIL``) is SILENTLY SKIPPED: it degrades to
    "this one criterion produced no signal", matching herd-review.sh's own fail-soft contract — it
    NEVER raises and never turns into an INFRA-FAIL of the review it was found in.
    """
    out = []
    for line in text.splitlines():
        s = line.strip()
        if not s.upper().startswith("RUBRIC:"):
            continue
        parts = s.split(":", 1)[1].split("|")
        if len(parts) != 3:
            continue
        cid, verdict, reason = (p.strip() for p in parts)
        verdict = verdict.upper()
        if not cid or verdict not in ("PASS", "FAIL"):
            continue
        out.append({"id": cid, "verdict": verdict, "reason": reason})
    return out


class FixtureGates:
    """Sim/dry-run gates: return the rail outcomes SCRIPTED per-candidate in the scenario.

    Reads ``health`` ∈ CLEAN|FLAKY|CODEERROR|WAIT and ``review`` ∈ PASS|BLOCK|INFRA|WAIT off the
    candidate's own fixture fields, so a scenario drives the whole DAG (including the async
    dispatch-and-wait path) with NO subprocess — the side-effect-free VERIFY path. ``reused_*`` are
    inert here (a sim rail is always "fresh"), so the walk journals its outcome exactly as before.
    """

    reused_review = False
    reused_health = False

    def __init__(self, scenario):
        self._by_pr = {str(c["pr"]): c for c in (scenario.get("candidates") or [])}

    def _spec(self, cand):
        return self._by_pr.get(cand.pr, {})

    def health(self, cand):
        v = str(self._spec(cand).get("health", "CLEAN")).upper()
        return v if v in ("CLEAN", "FLAKY", "CODEERROR", WAIT) else "CLEAN"

    def review(self, cand):
        v = str(self._spec(cand).get("review", "PASS")).upper()
        return v if v in ("PASS", "BLOCK", "INFRA", WAIT) else "PASS"


# ── apply: actuate the terminal action (merge / reap) or, in dry-run, journal only ────────────────

# The herd/gates commit-status contract (GATE_STATUS=on), mirrored VERBATIM from the bash watcher so a
# python-posted blessing is indistinguishable from a bash-posted one. ONLY `success` is ever posted — a
# non-passing status flips a CLEAN sha to mergeStateStatus=UNSTABLE and strands it, so the fail-safe rests
# entirely on the ABSENCE of success (agent-watch.sh:GATE_STATUS_CONTEXT / :_gate_status_desc).
_GATE_STATUS_CONTEXT = "herd/gates"
_GATE_STATUS_DESC = "healthcheck + adversarial review passed"

# Consecutive merge REFUSALS (the API did not confirm state=MERGED) tolerated before the tick escalates
# with a loud needs-you row. Below the threshold the PR STAYS BLESSED and re-attempts next tick; at it,
# a wedged merge surfaces to a human instead of retrying forever in silence (task HERD-352).
_MERGE_REFUSE_MAX = 3


class WakeResult:
    """The outcome of one refix-bounce wake attempt (HERD-370).

    ``status_before``/``status_after`` are the observed pane state (``""`` when unreadable) straddling
    the wake; ``woke`` is True iff the agent is confirmed WORKING after the attempt (or was already).
    This is the single shape both actuators return so :meth:`LiveTick._bounce_and_wake` never branches
    on which column produced it — dry-run simulates it from fixture data, live probes the real pane.
    """

    __slots__ = ("status_before", "status_after", "woke")

    def __init__(self, status_before="", status_after="", woke=False):
        self.status_before = str(status_before or "")
        self.status_after = str(status_after or "")
        self.woke = bool(woke)


# Agent states a bounce may actually WAKE by typing the re-task prompt + Enter (HERD-186's single wake
# path for idle AND done — a 'done' agent's TUI is still up and waiting). "working" is already-awake
# (no submit needed); anything else observed ("dead", "missing", "" — an unreadable/absent roster read)
# is nobody to wake, so the caller escalates the bounce instead of spending a round on a doomed submit.
_WAKEABLE_STATUSES = ("idle", "done")


class DryRunActuator:
    """The side-effect-free apply twin: journals the SAME terminal events, actuates NOTHING.

    ``merge`` / ``reap`` write ``journal.sh``-shaped ``merge`` / ``reap`` lines so a dry-run stream is
    diff-comparable against a live one, but no ``gh``, no ``git worktree remove``, no pane op runs.
    This is the actuator ``--dry-run`` (and a dry-run watcher tick) always uses.
    """

    def __init__(self, journal):
        self.journal = journal

    def merge(self, cand):
        self.journal.append("merge", "pr", cand.pr, "slug", cand.slug, "sha", cand.sha,
                            "method", "squash", "reason", "gates_passed")
        return True

    def reap(self, cand):
        _cost_emit.emit_merge_cost(self.journal, cand.pr, cand.slug, cand.worktree)
        self.journal.append("reap", "pr", cand.pr, "slug", cand.slug, "sha", cand.sha,
                            "reason", "merged")
        return True

    def wake_builder(self, cand, prompt):
        """Simulate the refix-bounce wake check from the candidate's fixture-declared pane state.

        ``cand.agent_status`` unset (``""``) is the LEGACY-FIXTURE sentinel — no scenario written
        before HERD-370 models a pane at all, so it simulates an immediate successful wake (byte-
        identical outcome for every pre-existing fixture/test). A scenario that opts into modeling the
        wake surface sets ``agent_status`` explicitly: "working" is already-awake; "idle"/"done" attempt
        a wake, gated by ``cand.wake_succeeds`` (default True); any other value ("dead", "missing", ...)
        is nobody to wake.
        """
        status = str(getattr(cand, "agent_status", "") or "")
        if not status:
            return WakeResult("working", "working", True)
        if status == "working":
            return WakeResult(status, status, True)
        if status in _WAKEABLE_STATUSES:
            woke = bool(getattr(cand, "wake_succeeds", True))
            return WakeResult(status, "working" if woke else status, woke)
        return WakeResult(status, status, False)

    def post_gate_status(self, cand):
        """PURE no-op twin of the herd/gates commit-status post: no network, no ledger, no journal —
        exactly as bash's ``post_gate_status`` returns early under ``--dry-run``. Returns False (nothing
        posted) so the side-effect-free VERIFY column never records a blessing it did not actually land."""
        return False


# ── merge actuation config (MERGE_METHOD + DELETE_BRANCH_ON_MERGE, HERD-354) ──────────────────────
# The live merge actuator must honor the SAME two knobs bash do_merge composes into `gh pr merge`
# (agent-watch.sh:_merge_method_flag / _delete_branch_flag). Hardcoding `--squash --delete-branch`
# refused EVERY merge on a repo whose branch protection disallows squash (53 refusals on PR #451).
_MERGE_METHODS = ("merge", "squash", "rebase")


def _merge_method(config):
    """The configured gh merge strategy (agent-watch.sh:_merge_method_flag:3951). Default ``merge`` —
    an unrecognized value falls back to ``merge``, exactly as the bash ``case`` default does, so the gh
    flag is ``--`` + this."""
    val = str((config or {}).get("MERGE_METHOD", "") or "").strip().lower()
    return val if val in _MERGE_METHODS else "merge"


def _delete_branch_on_merge(config):
    """True iff ``DELETE_BRANCH_ON_MERGE`` opts in (agent-watch.sh:_delete_branch_flag:3963). Default
    false; only ``1/true/yes/on`` enable it, matching the bash ``case`` — every other value (and the
    absent default) contributes NO ``--delete-branch`` argument, so a merged branch is retained."""
    val = str((config or {}).get("DELETE_BRANCH_ON_MERGE", "") or "").strip().lower()
    return val in ("1", "true", "yes", "on")


class LiveActuator:
    """The REAL apply layer: merge via ``gh``, reap the worktree via ``git`` (contract §2, §6.1).

    ``merge`` merges the PR via ``gh pr merge`` with the strategy/deletion resolved from config
    (``MERGE_METHOD`` → ``--merge``/``--squash``/``--rebase``, ``DELETE_BRANCH_ON_MERGE`` →
    ``--delete-branch`` when true), exactly as bash do_merge composes them; ``reap`` removes the
    builder worktree (``git worktree remove --force``). Both journal the SAME event the dry-run twin
    does, so the forensic stream is identical shape whether or not actuation ran. Each actuation is
    guarded so a single failing merge/reap surfaces (returns ``False``) without sinking the whole tick.
    Reached only from ``--tick`` in genuine live mode — never from any test.
    """

    def __init__(self, home, journal, config=None):
        self.home = home
        self.journal = journal
        self.config = config or {}

    def merge(self, cand):
        # Run the squash-merge, then VERIFY via the API that the PR actually reached state=MERGED before
        # we treat it as merged (task HERD-352). A merge is the one UNRECOVERABLE action, so its exit code
        # is not authoritative: `gh pr merge` can exit non-zero AFTER a successful merge (HERD-221: a failed
        # local branch delete on a still-checked-out worktree) AND exit zero without merging is possible
        # under a mergeability regression / branch-protection race. We never infer the merge from the exit
        # code — we read the PR's real state.
        method = _merge_method(self.config)                       # merge | squash | rebase (default merge)
        argv = ["gh", "pr", "merge", cand.pr, "--" + method]
        if _delete_branch_on_merge(self.config):                  # default false → no --delete-branch, branch retained
            argv.append("--delete-branch")
        try:
            subprocess.run(argv, capture_output=True, text=True, check=True)
        except Exception:
            pass  # non-zero is NOT authoritative — the API state below is the only truth that merges
        state = self._merged_state(cand)
        if state == "MERGED":
            self.journal.append("merge", "pr", cand.pr, "slug", cand.slug, "sha", cand.sha,
                                "method", method, "reason", "gates_passed")
            return True
        if not state:
            # HONEST LABELS (HERD-232): an EMPTY/unreadable state (network blip, rate limit, expired auth)
            # is NOT evidence of anything — it must NOT be labelled a genuine refusal. It is an infra event,
            # so FAIL CLOSED (no merge, no fabricated moved/merged row) and re-gate next tick.
            self.journal.append("merge_gh_unreadable", "pr", cand.pr, "slug", cand.slug, "sha", cand.sha)
            return False
        # A READABLE non-MERGED state is a GENUINE refusal (a mergeability regression / branch-protection
        # race). Name the state it actually saw so the label and the evidence agree, and NEVER reap or
        # transition — return False so the tick keeps the PR BLESSED and re-attempts next tick (HERD-352).
        self.journal.append("merge_refused", "pr", cand.pr, "slug", cand.slug, "sha", cand.sha,
                            "state", state, "reason", "api_not_merged")
        return False

    def _merged_state(self, cand):
        """The PR's real state per the GitHub API (``gh pr view --json state``) — the ONLY confirmation
        that authorizes reaping the worktree. An unreadable state (network/auth/rate-limit) returns ``""``,
        which the caller treats as an infra outage (merge_gh_unreadable), NOT a genuine refusal — the
        honest-labels split (HERD-232). Either way it fails closed: an unconfirmed merge never reaps."""
        try:
            out = subprocess.run(["gh", "pr", "view", cand.pr, "--json", "state,mergedAt", "-q", ".state"],
                                 capture_output=True, text=True, check=True)
        except Exception:
            return ""
        return out.stdout.strip()

    def post_gate_status(self, cand):
        """POST the herd/gates=success commit status for this ``(pr, sha)`` via the GitHub Statuses API
        (GATE_STATUS=on contract, agent-watch.sh:post_gate_status). ONLY ``success`` is ever posted — a
        non-passing status flips a CLEAN sha to UNSTABLE and strands it, so the fail-safe rests on the
        ABSENCE of success. Journals ``gate_status`` (bash-identical shape) on a successful write and
        returns True; a failed/empty write journals NOTHING and returns False, so the tick retries next
        round — the blessing MUST land for the ``require herd/gates`` fail-safe to hold. Never raises."""
        if not cand.sha:
            return False
        try:
            subprocess.run(
                ["gh", "api", "repos/{owner}/{repo}/statuses/%s" % cand.sha,
                 "-f", "state=success", "-f", "context=%s" % _GATE_STATUS_CONTEXT,
                 "-f", "description=%s" % _GATE_STATUS_DESC],
                capture_output=True, text=True, check=True)
        except Exception:
            return False   # best-effort: a failed post lands NO ledger row, so it retries next tick
        self.journal.append("gate_status", "pr", cand.pr, "sha", cand.sha, "state", "success",
                            "context", _GATE_STATUS_CONTEXT)
        return True

    def reap(self, cand):
        # REAP-ON-MERGE only: this fires the instant THIS tick merged ``cand`` on green gates, so the
        # builder is DONE by definition — there is no separate resident builder to defer for here, and no
        # roster is fetched on this path. The HERD-356 liveness gate ("a still-WORKING builder defers the
        # reap; an idle/merged builder's pane is retired with the worktree") lives in the ONE place that
        # reaps a merge THIS seat did not perform: the bash sweep (``sweep.sh:sweep_leg_worktrees`` and
        # ``retirement.sh:retire_classify``, both keying off the shared ``_reap_agent_working`` verdict).
        # That is the multi-seat authority the contract requires — it reconciles observed PR state each
        # sweep tick, so the gate holds regardless of which seat merged. Keeping it single-sourced there
        # (rather than re-deriving a roster verdict on this already-post-gate path) is deliberate.
        # 0) COST ACCOUNTING (best-effort, read-only): sum this builder's worktree transcript and
        #    journal a `cost` event (builder — and the in-worktree review, if captured) BEFORE the
        #    worktree is reaped (mirrors agent-watch.sh do_merge's step 0). Never affects the reap.
        _cost_emit.emit_merge_cost(self.journal, cand.pr, cand.slug, cand.worktree)
        if cand.worktree:
            try:
                subprocess.run(["git", "worktree", "remove", "--force", cand.worktree],
                               capture_output=True, text=True, check=True)
            except Exception:
                pass  # a reap that cannot remove the worktree is not fatal — the sweep retries it
        self.journal.append("reap", "pr", cand.pr, "slug", cand.slug, "sha", cand.sha,
                            "reason", "merged")
        return True

    # ── refix-bounce wake verification (HERD-370) ─────────────────────────────────────────────────
    # A fresh `herdr agent list` read on every call, by design (multi-seat contract): wake verification
    # must read the OBSERVED pane state, not a dispatching seat's cache — a second coordinator seat's
    # stale in-process view of "who's on this red" is exactly how a bounce can silently land on nobody.

    def _herdr_agents(self):
        """The live ``herdr agent list`` roster, parsed; ``[]`` on ANY read fault.

        Fail-soft, not fail-dead: an unreadable/blank roster is BLINDNESS, never evidence of a dead or
        missing agent (contract §5.2) — the caller's wake check reads an empty roster exactly like a
        genuinely absent agent (nobody found, no live target), which is the conservative call for THIS
        seam: a bounce that cannot positively confirm a live builder must escalate, not spin silently.
        """
        try:
            out = subprocess.run(["herdr", "agent", "list"], capture_output=True, text=True, timeout=10)
            data = json.loads(out.stdout or "{}")
            return (data.get("result") or {}).get("agents") or []
        except Exception:
            return []

    def _agent_lookup(self, slug):
        """``(agent_status, pane_id)`` for the agent whose identity (``name`` else ``agent``) == slug;
        ``("", "")`` when absent or the roster read failed. Mirrors ``_agent_status`` /
        ``_find_builder_pane_id_any`` (``agent-watch.sh:7948``/``:8955``) folded into one read."""
        for a in self._herdr_agents():
            ident = a.get("name") or a.get("agent") or ""
            if ident == slug:
                return str(a.get("agent_status") or ""), str(a.get("pane_id") or "")
        return "", ""

    def _send_wake(self, pane_id, prompt):
        """Type the re-task prompt then an explicit Enter (HERD-186: `pane run` alone leaves it sitting
        in the prompt buffer un-submitted). Best-effort — a failed send is caught by the poll below."""
        try:
            subprocess.run(["herdr", "pane", "run", pane_id, prompt],
                           capture_output=True, text=True, timeout=10)
            subprocess.run(["herdr", "pane", "send-keys", pane_id, "Enter"],
                           capture_output=True, text=True, timeout=10)
        except Exception:
            pass

    def _wait_agent_working(self, slug, window):
        """Poll ``herdr agent list`` for this agent to flip to "working", on a backed-off cadence (an
        immediate check, then 1s, 2s, 3s… capped at 5s) across ``window`` seconds. Mirrors
        ``_wait_agent_working`` (``agent-watch.sh:7979``) — several spread checks catch a submit that
        takes a few seconds to land without hammering herdr every second for the whole window."""
        deadline = time.time() + window
        if self._agent_lookup(slug)[0] == "working":
            return True
        interval = 1
        while time.time() < deadline:
            time.sleep(interval)
            if self._agent_lookup(slug)[0] == "working":
                return True
            interval = min(interval + 1, 5)
        return False

    def wake_builder(self, cand, prompt):
        """The REAL refix-bounce wake check: read the observed pane, and — only for a wakeable state
        ("idle"/"done") — type the re-task prompt + Enter and verify the flip to "working" over a
        bounded, backed-off window, re-sending once on a silent first attempt (mirrors the review bounce
        wake path, ``agent-watch.sh:8164-8202``). "working" already is a wake with no submit needed.
        Anything else observed (absent, "dead", or any other value) is nobody to wake — no submit is
        attempted, so a doomed bounce never spends a live round on a target that cannot receive it."""
        slug = cand.slug
        status_before, pane_id = self._agent_lookup(slug)
        if status_before == "working":
            return WakeResult(status_before, status_before, True)
        if not pane_id or status_before not in _WAKEABLE_STATUSES:
            return WakeResult(status_before, status_before, False)
        timeout = _pos_int(self.config.get("HERD_REFIX_WAIT_TIMEOUT"), 15)
        self._send_wake(pane_id, prompt)
        if self._wait_agent_working(slug, timeout):
            return WakeResult(status_before, "working", True)
        self._send_wake(pane_id, prompt)
        if self._wait_agent_working(slug, timeout):
            return WakeResult(status_before, "working", True)
        status_after, _ = self._agent_lookup(slug)
        return WakeResult(status_before, status_after or status_before, False)


# ── the live tick: the minimal correct loop ───────────────────────────────────────────────────────

class LiveTick:
    """Walk every discovered candidate through the gate DAG to a terminal, actuating on green.

    Construct with the resolved config, a discovery, a gates dispatcher, an actuator and a journal;
    :meth:`run` processes the tick and returns a summary the tests assert on. The gate ORDER is the
    cost-classed DAG (contract §2.1): stale/dup (cheap) → health (slow) → review (LLM) → blessing →
    hold decision → apply, a non-pass at any stage short-circuiting the rest. The pure hold/merge/
    observe decision is :func:`herd.decisions.hold_decision`, reused verbatim.
    """

    def __init__(self, config, discovery, gates, actuator, journal, state=None):
        self.config = config or {}
        self.discovery = discovery
        self.gates = gates
        self.actuator = actuator
        self.journal = journal
        # The shared on-disk state ($TREES) — used here for the once-per-(pr,sha) hold guards (§5.3).
        # None → a black-hole LiveState (no dir): a sim/dry-run tick has no cross-tick state and never
        # writes a marker, so the fixture path stays hermetic.
        self.state = state if state is not None else LiveState(None)
        self._merge_policy = D.effective_merge_policy(
            self.config.get("MERGE_POLICY"), self.config.get("WATCHER_AUTOMERGE"))
        self._hv_policy = self.config.get("HUMAN_VERIFY_POLICY", "hold")
        # GATE_STATUS master lever (HERD-194 contract): on (default) → post the herd/gates commit status
        # on gates-clear; off → byte-inert (no post, no journal, no ledger). Consumed at the blessing seam.
        self._gate_status = str(self.config.get("GATE_STATUS", "on") or "on")
        self._state = {}       # pr -> lifecycle state (the assertion layer)
        self._outcome = {}     # pr -> terminal action string
        # MERGE_FAIRNESS / starvation freeze (§6.2, HERD-340). OFF (default) → _fairness False and
        # _starved always empty, so the merge path below is byte-identical to before this feature.
        self._fairness = _merge_fairness_enabled(self.config)
        self._starve_threshold = _starve_threshold(self.config)
        self._starved = set()  # PRs that are head-of-line-starved THIS tick (drives the sibling freeze)

    # Return sentinel for _refix_check_and_record: sha already bounced, hold silently.
    _REFIX_ALREADY_ATTEMPTED = object()

    def _refix_check_and_record(self, cand, kind):
        """Gate the bounce: check once-guard → check budget → append bounce row.

        Returns one of three shapes, mirroring bash's pre-bounce checks
        (``agent-watch.sh:8334-8346`` health / ``:7600-7609`` review):

          ``(round_num, None)``              — fresh bounce recorded; emit ``refix_bounce``
          ``(None, None)``                   — sha already bounced for this rail; hold silently
                                               (agent was re-tasked; wait for push)
          ``(None, <reason_str>)``           — budget exhausted; escalate to needs-you

        ``kind`` is the LEDGER kind (``"health"`` or ``"review"``) — bash's ``$5`` field.
        Round = ``refix_rail_count + 1`` before the append (bash ``:8389, :7648``).

        **Once-guard** (``refix_attempted``, ``agent-watch.sh:8340/:7605``): a (pr, sha, kind)
        triple that is already in the ledger MUST NOT produce a second bounce row — the tick
        re-walks every open candidate on every ~8s cycle using the cached verdict, so without
        this guard the same sha would burn its entire per-rail budget in one minute while the
        woken agent is still working and has not yet pushed.

        **Ledger-fault advisory**: if the write succeeds on no ledger and state_dir is set, the
        once-guard will never hold → infinite re-bounce on the next tick.  A one-shot journal
        event ``refix_ledger_fault`` is emitted so the operator can see the underlying I/O
        problem instead of diagnosing runaway bounces."""
        state_dir = self.state.dir
        text = _read_refix_ledger(state_dir)
        rows = D.parse_refix_ledger(text)
        pr_str = str(cand.pr)
        sha_str = str(cand.sha)

        # 1. Once-guard: if already bounced for this exact (pr, sha, kind), hold silently.
        if D.refix_attempted(rows, pr_str, sha_str, kind):
            return None, None

        # 2. Budget check: exhausted → needs-you escalation, no bounce.
        reason = D.refix_budget_reason(rows, pr_str, kind, self.config.get("REFIX_MAX_ROUNDS"))
        if reason:
            return None, reason

        # 3. Fresh (pr, sha, kind) with budget remaining → record the bounce.
        rail = D.refix_rail_count(rows, pr_str, kind)
        round_num = rail + 1
        slug = str(cand.slug) if cand.slug else "-"
        wrote = _append_refix_ledger(
            state_dir,
            "%s %s %s %s %s\n" % (_now_epoch(), cand.pr, cand.sha, slug, kind))
        if not wrote and state_dir:
            # Ledger unwritable: the once-guard will not hold next tick → emit advisory once.
            if self.state.once(cand.pr, cand.sha, "refix_ledger_fault_%s" % kind):
                self.journal.append("refix_ledger_fault", "pr", cand.pr, "sha", cand.sha,
                                    "slug", cand.slug, "kind", kind,
                                    "detail", "refix ledger unwritable — once-guard will not hold")
        return round_num, None

    def _refix_rail_reset(self, cand, kind,
                          reason="rail resolved its red — per-rail refix budget restored"):
        """Append a ``reset`` row when the rail has unresolved bounces (fail-soft no-op otherwise).

        Mirrors ``refix_rail_reset`` (``agent-watch.sh:7300``): only writes when the rail counter is
        > 0 so the ledger does not accumulate reset rows on a clean path, and journals
        ``refix_rail_reset`` so the coordinator sees the rail budget restored. ``reason`` defaults to
        the refund-on-green wording; :meth:`_bounce_and_wake` (HERD-370) overrides it for the OTHER
        refund case — an unwoken bounce, where the red is emphatically NOT resolved."""
        state_dir = self.state.dir
        text = _read_refix_ledger(state_dir)
        rows = D.parse_refix_ledger(text)
        n = D.refix_rail_count(rows, str(cand.pr), kind)
        if n <= 0:
            return
        sha = str(cand.sha) if cand.sha else "-"
        slug = str(cand.slug) if cand.slug else "-"
        _append_refix_ledger(state_dir,
                             "%s %s %s %s %s reset\n" % (_now_epoch(), cand.pr, sha, slug, kind))
        self.journal.append("refix_rail_reset", "pr", cand.pr, "sha", cand.sha,
                            "slug", cand.slug, "kind", kind, "rounds", n, "reason", reason)

    def _refix_prompt(self, cand, kind):
        """The re-task prompt text typed into the builder's pane for this rail's bounce."""
        if kind == "health":
            return ("PR #%s failed the healthcheck (CODEERROR).\n"
                    "Read the failing suite output, fix every CODE error, run the healthcheck, and "
                    "push your fix." % cand.pr)
        return ("PR #%s was review-blocked.\n"
                "Read the full review: gh pr view %s\n"
                "Fix every issue the reviewer raised, run the healthcheck, push your fix, and "
                "reply to the review comment once done." % (cand.pr, cand.pr))

    def _bounce_and_wake(self, cand, kind, round_num, rule):
        """Record the bounce, ALWAYS verify + journal the wake, and escalate immediately (with the
        round refunded) when nobody actually woke (HERD-370).

        The grounding incident: a review-BLOCK refix bounced PR #471 with the wake never even
        attempted — no ``refix_wake_result`` followed, and the PR sat BLOCKED ~70 minutes with the
        sha-keyed once-guard silently holding any retry. The fix has two parts, both unconditional:

          1. Every ``refix_bounce`` this walk emits is IMMEDIATELY paired with exactly one
             ``refix_wake_result`` (``woke`` 1|0), regardless of what the wake check finds — the
             journal-audit ``refix_bounce_no_wake`` check (``journal-audit.sh:293``) reads this pairing
             as its ground truth, and a bounce with no matching wake result is exactly the gap it flags.
          2. ``woke=False`` — whether because the wake attempt failed or because the observed agent was
             already dead/missing/absent (:data:`_WAKEABLE_STATUSES` — both actuators fold every
             non-wakeable observed state into ``woke=False`` the same way) — escalates to needs-you
             RIGHT HERE, in this same tick, naming the slug so a human knows who to re-task by hand, and
             REFUNDS the round via a ``reset`` ledger row: an unwoken bounce spent no real attempt, so it
             must not count against the rail's budget (a later, ACTUALLY-woken bounce starts clean).

        Returns :data:`BLOCK` (bounce landed on a live builder, wait for its push) or :data:`ESCALATE`
        (nobody is on it — needs-you).
        """
        prompt = self._refix_prompt(cand, kind)
        wake = self.actuator.wake_builder(cand, prompt)
        status_before = wake.status_before or "unknown"
        self.journal.append("refix_bounce", "pr", cand.pr, "sha", cand.sha, "slug", cand.slug,
                            "round", round_num, "agent_status_before", status_before,
                            "rule", rule, "location", "")
        escalated = not wake.woke
        self.journal.append("refix_wake_result", "pr", cand.pr, "sha", cand.sha, "slug", cand.slug,
                            "round", round_num, "agent_status_before", status_before,
                            "agent_status_after", wake.status_after or "unknown",
                            "woke", 1 if wake.woke else 0,
                            "escalated", "true" if escalated else "false")
        if wake.woke:
            return BLOCK
        self._refix_rail_reset(
            cand, kind,
            reason="unwoken bounce refunded — no live builder (%s), round not spent" % status_before)
        self.journal.append("refix_escalated_no_wake", "pr", cand.pr, "sha", cand.sha,
                            "slug", cand.slug, "kind", kind, "reason", "no-live-builder",
                            "agent_status", wake.status_after or status_before)
        return ESCALATE

    def _gate_status_enabled(self):
        """GATE_STATUS master lever — ``off`` disables the herd/gates commit-status post entirely
        (byte-inert: no post, no journal, no ledger). Any other value is on
        (agent-watch.sh:_gate_status_enabled — unknown value → on)."""
        return self._gate_status != "off"

    # lifecycle transition through SM; journal it, never let a disagreement sink the tick (as shadow).
    def _advance(self, cand, event):
        prev = self._state.get(cand.pr, _S_INTAKE)
        try:
            nxt = SM.transition(prev, event)
        except Exception as exc:
            self.journal.append("illegal_transition", "pr", cand.pr, "sha", cand.sha,
                                "state", prev, "attempted_event", event, "detail", str(exc))
            return prev
        self._state[cand.pr] = nxt
        self.journal.append("live_state", "pr", cand.pr, "sha", cand.sha, "trigger", event,
                            "state_from", prev, "state_to", nxt)
        return nxt

    # ── merge fairness / starvation freeze (§6.2, HERD-340) ───────────────────────────────────────
    def _effective_laps(self, cand):
        """This PR's re-stale lap total: the persistent ledger count (live), else the fixture-injected
        ``restale_laps`` (a sim with a black-hole state dir carries the laps on the candidate)."""
        n = self.state.restale_count(cand.pr)
        return n if n > 0 else int(getattr(cand, "restale_laps", 0) or 0)

    def _would_automerge(self, cand):
        """True iff this candidate's resolved merge policy would MERGE it (not HOLD on approve/human-
        verify, not OBSERVE) once its gates are green. The head-of-line test that keeps the freeze from
        deadlocking behind a human hold: a PR parked on a human never triggers a sibling freeze."""
        return D.hold_decision(self._merge_policy, cand.hv_hold, cand.approved, self._hv_policy) == "MERGE"

    def _fairness_prepass(self, candidates):
        """Resolve the starvation state for this tick BEFORE any candidate is walked (§6.2, HERD-340).

        A strict NO-OP when ``MERGE_FAIRNESS`` is off — ``_starved`` stays empty, so the merge path is
        byte-identical to today. When on it does two things:

          (a) COUNT this tick's fresh re-stale laps. A candidate re-staled (behind base) this tick that
              already carried real gate investment lost a lap (agent-watch.sh:_restale_note — 'measure
              work thrown away, not holds'); it is recorded once per ``(pr, sha, kind)`` and journaled
              ``pr_restale`` (plus ``pr_starvation`` at/above threshold), reusing the existing bash
              journal schema so the counter is cross-implementation-identical.
          (b) RESOLVE the head-of-line starved set. A PR is head-of-line-starved when its laps reach the
              threshold AND its own policy would auto-merge it once it gets a clean window. It is bounded
              to ONE window per ``(pr, sha)`` via the once-guard, so a PR that cannot land never freezes
              the queue forever ('for one merge window', §6.2); a rebased sha re-arms it.
        """
        if not self._fairness:
            return
        for cand in candidates:
            if cand.stale and self.state.gate_work_invested(cand):
                laps = self.state.note_restale(cand.pr, cand.sha, "stale")
                if laps is not None:
                    self.journal.append("pr_restale", "pr", cand.pr, "sha", cand.sha,
                                        "slug", cand.slug, "kind", "stale", "laps", laps)
                    if laps >= self._starve_threshold:
                        self.journal.append("pr_starvation", "pr", cand.pr, "sha", cand.sha,
                                            "slug", cand.slug, "laps", laps,
                                            "threshold", self._starve_threshold)
        for cand in candidates:
            if (self._effective_laps(cand) >= self._starve_threshold
                    and self._would_automerge(cand)
                    and self.state.once(cand.pr, cand.sha, "fairness_window")):
                self._starved.add(cand.pr)

    def _supersede_stale(self, candidates):
        """Discovery → cancel: TERM every doomed in-flight worker a candidate has moved PAST (contract
        §2.4/§6.1, HERD-341). For each current candidate, DYNAMICALLY discover the in-flight markers
        left for a SUPERSEDED sha (a prior head), then reap them — a health suite worker by a SESSION
        kill of its whole detached subtree (HERD-283/348: the leader's process group alone would miss the
        ``timeout``-re-grouped suite children), a stale reviewer likewise + its STAMPED PANE retired —
        and journal ``gate_superseded`` for each. This is the shadow's task-group cancel
        (P3c ``_maybe_inject_supersession``) generalized to the live tick's on-disk substrate: the
        production tree already performs it on a new head sha (``_discard_stale_health`` /
        ``_discard_stale_reviews``); the port carries the same invariant into the typed core.

        BYTE-INERT when nothing is superseded: with no state dir (a sim/dry-run tick) or no stale marker,
        the glob is empty and this journals nothing — the stream is identical to before. A worker that
        refuses to die keeps its marker (the terminate returned False) and is retried next tick, never
        re-terminated blind and never falsely reported superseded.
        """
        st = self.state
        if not st.dir:
            return
        for cand in candidates:
            try:
                cur = str(cand.sha)
                # health rail — session-kill the stale suite worker's subtree (HERD-283/348), reap scratch.
                for path, sha in st.stale_inflight(".health-inflight", cand.pr, cur):
                    if _terminate_worker(path):
                        st.rm(path, st.health_dispatch_file_sha(cand.pr, sha),
                              st.health_result_file_sha(cand.pr, sha),
                              st.health_log_file_sha(cand.pr, sha))
                        self.journal.append("gate_superseded", "pr", cand.pr, "rail", "health",
                                            "old_sha", sha, "new_sha", cur, "action", "session_kill")
                # review rail — terminate the stale reviewer's subtree, retire its stamped pane, reap scratch.
                for path, sha in st.stale_inflight(".review-inflight", cand.pr, cur):
                    if _terminate_worker(path):
                        pane = st.read_review_pane(cand.pr, sha)
                        st.rm(path, st.review_result_file_sha(cand.pr, sha),
                              st.review_registry_file_sha(cand.pr, sha))
                        self.journal.append("gate_superseded", "pr", cand.pr, "rail", "review",
                                            "old_sha", sha, "new_sha", cur, "action", "pane_retired",
                                            "pane", pane)
            except Exception as exc:
                # A supersession scan fault for one candidate must never sink the tick (parking a doomed
                # worker for the next tick's corpse sweep is always safe); journal it and move on.
                self.journal.append("live_candidate_error", "pr", cand.pr, "sha", cand.sha,
                                    "detail", "supersede: %s" % str(exc)[:180])

    def _walk(self, cand):
        """Walk one candidate's gate DAG; actuate the terminal; return the action string.

        A rail that returns :data:`WAIT` (a reviewer/suite dispatched or in flight for this ``(pr, sha)``)
        short-circuits to :data:`PENDING`: the candidate holds WITHOUT merging and re-evaluates next tick
        when the verdict lands — a missing verdict is never a BLOCK (task HERD-324 leg 1). ``reused_*``
        from the gate suppresses re-journaling a verdict/outcome for a terminal REUSED from the sha ledger.
        """
        self._state.setdefault(cand.pr, _S_INTAKE)

        # 1. stale/dup gate (deterministic-cheap): a behind-base PR HOLDS — parking is always safe.
        if cand.stale:
            if self.state.once(cand.pr, cand.sha, "stale"):
                self.journal.append("stale_dup_hold", "pr", cand.pr, "sha", cand.sha, "slug", cand.slug,
                                    "kind", "stale", "reason", "behind base")
            self._advance(cand, "stale_detected")
            return HOLD

        # 2. health rail (deterministic-slow) — DISPATCHED async by shelling out to the health runner
        #    (the dispatch/started event is journaled by the gate, only on an actual dispatch).
        health = self.gates.health(cand)
        health = health if health in ("CLEAN", "FLAKY", "CODEERROR", WAIT) else "CLEAN"
        if health == WAIT:
            self.journal.append("health_pending", "pr", cand.pr, "sha", cand.sha, "slug", cand.slug)
            self._advance(cand, "dispatch_health")
            return PENDING
        self._advance(cand, "dispatch_health")
        if not getattr(self.gates, "reused_health", False):
            self.journal.append("healthcheck_outcome", "pr", cand.pr, "slug", cand.slug, "outcome", health)
        self._advance(cand, {"CLEAN": "health_clean", "FLAKY": "health_flaky",
                             "CODEERROR": "health_codeerror"}[health])
        if health in ("CLEAN", "FLAKY"):
            # Rail resolved → refund its per-rail budget (contract §4, bash line 10419).
            self._refix_rail_reset(cand, "health")
        if health == "CODEERROR":
            # Three-way bounce gate (HERD-358).  See _refix_check_and_record for the semantics.
            round_num, reason = self._refix_check_and_record(cand, "health")
            if round_num is None and reason is None:
                # Once-guard: already bounced for this (pr, sha, kind) — hold silently while the
                # agent works (bash: refix_attempted true + _active_fix_note check at :8334-8338).
                return BLOCK
            if reason is not None:
                # Budget exhausted → needs-you escalation, no bounce.
                if self.state.once(cand.pr, cand.sha, "refix_escalated_health"):
                    rows_after = D.parse_refix_ledger(_read_refix_ledger(self.state.dir))
                    total = D.refix_total_count(rows_after, str(cand.pr))
                    self.journal.append("health_refix_escalated", "pr", cand.pr, "sha", cand.sha,
                                        "slug", cand.slug, "rounds", total,
                                        "reason", reason + " — health-check still red")
                return ESCALATE
            # Contract §3.4 refix_bounce shape (pr, sha, slug, round, agent_status_before, rule,
            # location) — the port unifies both rails under one event keyed by `rule` (there is no
            # `health_refix_bounce` in the catalog). Match the shadow twin's field SET
            # (shadow_runtime.py:418); the live tick parses no finding location for either rail.
            # HERD-370: the bounce is not "sent and forgotten" — _bounce_and_wake ALWAYS journals the
            # paired refix_wake_result and escalates immediately (refunding this round) when nobody
            # woke, so a red never sits BLOCKED with no evidence of whether the builder ever heard it.
            return self._bounce_and_wake(cand, "health", round_num, "healthcheck")

        # 3. review rail (LLM) — DISPATCHED async by shelling out to the adversarial reviewer.
        verdict = self.gates.review(cand)
        verdict = verdict if verdict in ("PASS", "BLOCK", "INFRA", WAIT) else "PASS"
        if verdict == WAIT:
            self.journal.append("review_pending", "pr", cand.pr, "sha", cand.sha, "slug", cand.slug)
            return PENDING
        if verdict == "INFRA":
            # Infra death is not a verdict — forensic record is infra_event, the caller retries (§2.2).
            self.journal.append("infra_event", "pr", cand.pr, "sha", cand.sha, "rail", "review",
                                "detail", "no parseable verdict")
            self._advance(cand, "review_infra")
            return ESCALATE
        if not getattr(self.gates, "reused_review", False):
            self.journal.append("verdict_recorded", "pr", cand.pr, "sha", cand.sha, "value", verdict,
                                "source", "reviewer")
        self._advance(cand, "review_block" if verdict == "BLOCK" else "review_pass")
        if verdict == "BLOCK":
            # Three-way bounce gate (HERD-358).  See _refix_check_and_record for the semantics.
            round_num, reason = self._refix_check_and_record(cand, "review")
            if round_num is None and reason is None:
                # Once-guard: already bounced for this (pr, sha, kind) — hold silently.
                return BLOCK
            if reason is not None:
                # Budget exhausted → needs-you escalation, no bounce.
                if self.state.once(cand.pr, cand.sha, "refix_escalated_review"):
                    rows_after = D.parse_refix_ledger(_read_refix_ledger(self.state.dir))
                    total = D.refix_total_count(rows_after, str(cand.pr))
                    self.journal.append("refix_escalated", "pr", cand.pr, "sha", cand.sha,
                                        "slug", cand.slug, "rounds", total,
                                        "reason", reason + " — review still blocked")
                return ESCALATE
            # Contract §3.4 refix_bounce shape — mirror the shadow twin (shadow_runtime.py:429) and
            # bash (agent-watch.sh:7321); the live tick parses no finding location for either rail.
            # HERD-370: see the health leg above — _bounce_and_wake owns the wake verification the
            # PR #471 incident found silently missing (refix_bounce with no paired refix_wake_result).
            return self._bounce_and_wake(cand, "review", round_num, "review")
        # verdict == "PASS" — rail resolved; refund its per-rail budget (contract §4, bash line 1952).
        self._refix_rail_reset(cand, "review")

        # 4. the blessing — both rails passed (review_pass advanced the lifecycle to BLESSED). Once per
        #    (pr, sha): a held-but-blessed PR re-walked every tick posts the blessing exactly once (§5.3).
        if self.state.once(cand.pr, cand.sha, "blessing"):
            self.journal.append("blessing", "pr", cand.pr, "sha", cand.sha, "context", "herd/gates",
                                "state", "success")

        # 4b. POST the herd/gates=success commit status (GATE_STATUS=on contract, agent-watch.sh:
        #     post_gate_status). ONLY the actuator touches the network; the DryRunActuator twin is a pure
        #     no-op, so the side-effect-free VERIFY column never posts. At-most-once per (pr,sha): the
        #     ledger marker is recorded ONLY on a successful post, so a failed network write retries next
        #     tick — the blessing MUST land for the `require herd/gates` fail-safe to hold. Byte-inert when
        #     GATE_STATUS=off (no post, no journal, no ledger).
        if self._gate_status_enabled() and cand.sha and not self.state.posted(cand.pr, cand.sha, "gate_status"):
            if self.actuator.post_gate_status(cand):
                self.state.record_posted(cand.pr, cand.sha, "gate_status")

        # 5. the pure hold / merge / observe decision (reused from P2, contract §2.2/§5.4-§5.5).
        action = D.hold_decision(self._merge_policy, cand.hv_hold, cand.approved, self._hv_policy)

        # 5b. MERGE_FAIRNESS starvation freeze (§6.2, HERD-340): a would-be sibling merge is HELD for one
        #     window when a starved head-of-line PR (some OTHER candidate re-staled past threshold) needs
        #     a clean base to finish its final gate and land. The starved PR is excluded from its own
        #     freeze, so it still merges. Off / no starvation → the branch is never taken and the decide
        #     advance + apply below are byte-identical to today.
        if action == "MERGE" and self._fairness and (self._starved - {cand.pr}):
            self._advance(cand, "merge_frozen")               # BLESSED --merge_frozen--> HOLD
            if self.state.once(cand.pr, cand.sha, "fairness_freeze"):
                self.journal.append("merge_fairness_freeze", "pr", cand.pr, "sha", cand.sha,
                                    "slug", cand.slug,
                                    "starved", ",".join(sorted(self._starved - {cand.pr})),
                                    "threshold", self._starve_threshold)
            return HOLD

        self._advance(cand, {"MERGE": "decide_merge", "HOLD": "decide_hold",
                             "OBSERVE": "decide_observe"}[action])

        # 6. apply — the ONLY step that actuates (and only under LiveActuator).
        if action == "MERGE":
            if self.actuator.merge(cand):
                self.state.clear_merge_refusal(cand.pr, cand.sha)
                self.actuator.reap(cand)          # reap-on-merge (contract §6.1)
                return "MERGE"
            # Merge REFUSED — the actuator's API verify did not confirm state=MERGED (it journaled the
            # refusal: `merge_refused` for a readable non-MERGED state, `merge_gh_unreadable` for an infra
            # outage). A merge is the one unrecoverable action, so an UNCONFIRMED merge is never
            # treated as done: the PR STAYS BLESSED (no reap, no silent drop) and re-attempts next tick.
            # Only after _MERGE_REFUSE_MAX consecutive refusals do we ESCALATE with a loud needs-you row,
            # so a wedged merge surfaces to a human instead of retrying forever in silence (task HERD-352).
            n = self.state.bump_merge_refusal(cand.pr, cand.sha)
            if n >= _MERGE_REFUSE_MAX:
                # The loud needs-you row: N consecutive refusals means the merge is genuinely wedged.
                self.journal.append("merge_refused_escalated", "pr", cand.pr, "sha", cand.sha,
                                    "slug", cand.slug, "count", n, "reason", "merge refused")
                return ESCALATE
            return HOLD                            # stay BLESSED, re-attempt next tick
        if action == "HOLD":
            if self.state.once(cand.pr, cand.sha, "hold"):
                self.journal.append("hold_applied", "pr", cand.pr, "sha", cand.sha, "slug", cand.slug,
                                    "kind", "approval" if self._merge_policy == "approve" else "human-verify")
            return HOLD
        # OBSERVE — observe mode never merges.
        if self.state.once(cand.pr, cand.sha, "observe"):
            self.journal.append("observe_noted", "pr", cand.pr, "sha", cand.sha, "slug", cand.slug)
        return "OBSERVE"

    def run(self):
        """Run one tick over all discovered candidates; return the summary."""
        candidates = self.discovery.discover()
        self.journal.append("live_tick_start", "candidates", len(candidates), "impl", "python",
                            "merge_policy", self._merge_policy)
        # Discovery → supersession-cancel (§2.4/§6.1): before the gate walk, TERM the doomed in-flight
        # workers any candidate has moved past, so a superseded sha never holds a rail slot or races a
        # fresh dispatch. No-op with no state dir / no stale marker (byte-inert when nothing superseded).
        self._supersede_stale(candidates)

        # Resolve this tick's starvation state before any candidate is walked (§6.2, HERD-340). A strict
        # no-op under MERGE_FAIRNESS=off, so the loop below stays byte-identical to before this feature.
        self._fairness_prepass(candidates)
        for cand in candidates:
            try:
                self._outcome[cand.pr] = self._walk(cand)
            except Exception as exc:
                # A single candidate's failure must never abort the tick or actuate wrongly — journal
                # it and move on (parking/skipping is safe; a wrong merge is the only unrecoverable error).
                self.journal.append("live_candidate_error", "pr", cand.pr, "sha", cand.sha,
                                    "detail", str(exc)[:200])
                self._outcome[cand.pr] = ESCALATE
        merged = [pr for pr, a in self._outcome.items() if a == "MERGE"]
        held = [pr for pr, a in self._outcome.items() if a == HOLD]
        pending = [pr for pr, a in self._outcome.items() if a == PENDING]
        self.journal.append("live_tick_end", "merged", len(merged), "held", len(held),
                            "pending", len(pending))
        return {"outcomes": dict(self._outcome), "merged": merged, "held": held, "pending": pending,
                "journal": self.journal.path}


# ── config assembly (read the same knobs the bash watcher reads; env is READ-ONLY) ────────────────

_CONCURRENCY_KEYS = ("HEALTH_CONCURRENCY", "REVIEW_CONCURRENCY")


def _config_from_env(scenario=None):
    config = dict((scenario or {}).get("config") or {})
    knobs = (("MERGE_POLICY", "WATCHER_AUTOMERGE", "HUMAN_VERIFY_POLICY",
              "MERGE_METHOD", "DELETE_BRANCH_ON_MERGE", "REFIX_MAX_ROUNDS",
              "HERD_REFIX_WAIT_TIMEOUT") + _CONCURRENCY_KEYS + _WATCHER_KEYS + _FAIRNESS_KEYS)
    for knob in knobs:
        if knob not in config and os.environ.get(knob) is not None:
            config[knob] = os.environ[knob]
    return config


def _dryrun_env():
    """True iff the watcher's dry-run switch is set — so ``--tick`` inherits it and never actuates."""
    return os.environ.get("AGENT_WATCH_DRYRUN") in ("1", "true", "yes", "on") \
        or bool(os.environ.get("DRYRUN"))


def _home():
    """The herdkit checkout root — ``HERDKIT_HOME`` else two dirs up from this file (pysrc/herd)."""
    env = os.environ.get("HERDKIT_HOME")
    if env:
        return env
    here = os.path.dirname(os.path.abspath(__file__))
    return os.path.normpath(os.path.join(here, "..", ".."))


# ── CLI harness (the impure glue; the classes above hold the logic) ───────────────────────────────

def _parse_argv(argv):
    opts = {"dry_run": False, "tick": False, "fixture": None}
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--dry-run":
            opts["dry_run"] = True
        elif a == "--tick":
            opts["tick"] = True
        elif a == "--fixture" and i + 1 < len(argv):
            opts["fixture"] = argv[i + 1]
            i += 1
        i += 1
    return opts


def _run_dry_run(fixture):
    """``--dry-run`` smoke mode: sim in, result JSON out, ZERO subprocess / gh / git / pane.

    Wires the side-effect-free column exclusively (FixtureDiscovery + FixtureGates + DryRunActuator).
    The journal path is ``LIVE_DRYRUN_JOURNAL`` if set, else ``None`` (a black hole) — it defaults to
    NEVER writing the real ``.herd/journal.jsonl``, honoring the VERIFY discipline.
    """
    raw = open(fixture, encoding="utf-8").read() if fixture else sys.stdin.read()
    scenario = json.loads(raw) if raw.strip() else {}
    config = _config_from_env(scenario)
    journal = LiveJournal(os.environ.get("LIVE_DRYRUN_JOURNAL"))
    # A black-hole LiveState (no dir): the fixture path writes NO on-disk marker, stays hermetic.
    tick = LiveTick(config, FixtureDiscovery(scenario), FixtureGates(scenario),
                    DryRunActuator(journal), journal, state=LiveState(None))
    return tick.run()


def _run_live_tick():
    """``--tick``: one AUTHORITATIVE live tick — discover via gh, dispatch leaves, merge/reap on green.

    Inherits the watcher's dry-run switch: under ``AGENT_WATCH_DRYRUN``/``DRYRUN`` the actuator is the
    DryRunActuator (journals, no gh/git), exactly as the bash watcher's dry-run does everything except
    the real merge/remove. Returns the summary; the ``main`` wrapper turns any exception into a
    non-zero exit so the bash supervisor falls back to its own tick body for this cycle.

    JOURNAL WIRING (task HERD-324 leg 2): the journal path is resolved from the SAME watcher-exported
    config the bash engine reads (``JOURNAL_FILE`` else ``<WORKTREES_DIR>/.herd/journal.jsonl``). A live
    (actuating) tick REFUSES to run unjournaled — if the path cannot resolve we FAIL LOUD so ``main``
    returns non-zero and the bash supervisor owns the tick, rather than actuate merges with a null
    journal (the manual-tick ``journal:null`` this fixes). A dry-run tick actuates nothing, so a
    black-hole journal there is tolerated.
    """
    home = _home()
    config = _config_from_env()
    dry = _dryrun_env()
    path = LiveJournal.resolve_live_path()
    if not path and not dry:
        raise RuntimeError(
            "live tick refuses to run unjournaled: neither JOURNAL_FILE nor WORKTREES_DIR resolves a "
            "journal path (docs/engine-contract.md §3) — never actuate a merge with journal:null")
    journal = LiveJournal(path)
    state = LiveState()          # $TREES / $WORKTREES_DIR — the shared sha-keyed ledger + marker substrate
    actuator = DryRunActuator(journal) if dry else LiveActuator(home, journal, config)
    tick = LiveTick(config, _GraphQLDiscovery(config), LiveGates(home, state, journal, config),
                    actuator, journal, state=state)
    return tick.run()


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    opts = _parse_argv(argv)
    try:
        if opts["tick"] and not opts["dry_run"]:
            result = _run_live_tick()
        else:
            # Default (and explicit --dry-run) is the safe smoke path — a bare invocation never actuates.
            result = _run_dry_run(opts["fixture"])
    except Exception as exc:
        # Loud to stderr, non-zero to the caller: the bash supervisor reads the exit code and falls
        # back to its own tick body (the instant-fallback kill-switch), so a port fault never stalls.
        sys.stderr.write("herd.live_runtime: tick aborted: %s\n" % exc)
        return 1
    sys.stdout.write(json.dumps(result, separators=(",", ":"), sort_keys=True) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
