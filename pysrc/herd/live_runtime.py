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
                 "hv_body", "author", "assignees", "labels", "review_decision", "merge_status")

    def __init__(self, pr, sha, slug="", base="", worktree="", stale=False,
                 hv_hold=False, approved=False, hv_body="", author="", assignees=None,
                 labels=None, review_decision="", merge_status=""):
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

    @classmethod
    def from_dict(cls, d):
        return cls(
            pr=d["pr"], sha=d["sha"], slug=d.get("slug", ""), base=d.get("base", ""),
            worktree=d.get("worktree", ""), stale=d.get("stale", False),
            hv_hold=d.get("hv_hold", False), approved=d.get("approved", False),
            hv_body=d.get("hv_body", ""), author=d.get("author", ""),
            assignees=d.get("assignees"), labels=d.get("labels"),
            review_decision=d.get("review_decision", ""), merge_status=d.get("merge_status", ""),
        )


# ── the real journal (journal.sh-identical shapes, best-effort, never raises) ──────────────────────

class LiveJournal:
    """Append-only writer to the REAL ``.herd/journal.jsonl``, in ``journal.sh`` shapes.

    Reuses :func:`herd.shadow_journal.encode_event` — the exact bash encoding contract (``ts``+``event``
    first, integer coercion, ``separators=(",", ":")``) — so a line this writer emits is
    indistinguishable from one the bash watcher emits for the same ``(event, kv…)``. Like
    ``journal_append`` (and :class:`ShadowJournal`) it is BEST-EFFORT and SILENT: an unwritable path or
    an encoding fault drops the entry and returns ``False``, never raising into the tick. A ``path`` of
    ``None`` is a black hole (every append is a no-op) — the safe default when no destination resolves.
    """

    def __init__(self, path=None):
        self.path = path

    @classmethod
    def resolve_live_path(cls):
        """Resolve the LIVE journal path: ``JOURNAL_FILE`` (the bash engine's own knob) else
        ``<WORKTREES_DIR>/.herd/journal.jsonl``; ``None`` when neither is set."""
        override = os.environ.get("JOURNAL_FILE")
        if override:
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


def _iter_pairs(seq):
    """Yield ``(k, v)`` from a flat ``[k, v, …]`` list (dangling final key dropped, journal.sh:136)."""
    for i in range(0, len(seq) - 1, 2):
        yield seq[i], seq[i + 1]


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


def _marker_write(path, pid):
    """Lay down a restart-safe in-flight marker: pid, its start-time, dispatch ts, SESSION id
    (agent-watch.sh:2012 + the HERD-348 session line). The 4th line lets the sweep exempt — and a
    supersession cancel — the worker's whole detached subtree by session; older 3-line markers (the bash
    writer, a marker predating this line) still work, the reader falls back to the recorded pid's own
    session. Best-effort — an unwritable path drops the marker, never raises into the tick."""
    try:
        with open(path, "w", encoding="utf-8") as fh:
            fh.write("%s\n%s\n%s\n%s\n" % (pid, _pid_starttime(pid), _now_epoch(), _pid_session(pid)))
    except Exception:
        pass


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

    def rm(self, *paths):
        for p in paths:
            if p:
                try:
                    os.remove(p)
                except OSError:
                    pass

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
# verdict atomically (temp+mv) as one ``<verdict>\t<detail>`` line the collector consumes:
#   CLEAN\t{clean|dataenv}  — passed (clean, or a tolerated data/env ⚠️ first line, healthcheck.sh exit 0)
#   FLAKY\t<detail>         — first run code-errored but the solo retry PASSED
#   CODEERROR\t<detail>     — code error reproduced on the retry; drives the red row
# Args: $1 healthcheck.sh  $2 worktree  $3 dispatch-out  $4 log  $5 MAIN(base)  $6 TREES(base cache).
_HEALTH_WORKER_SH = r'''
set -u
hc="$1"; dir="$2"; out="$3"; log="$4"; base="$5"; cache="$6"
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
printf '%s\n' "$line" > "$out.tmp.$$" 2>/dev/null && mv "$out.tmp.$$" "$out" 2>/dev/null || true
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
        "headRefOid baseRefName reviewDecision author{login} "
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
        # leg 1: derive the SLUG from the head branch (bash convention, herd_branch_parse) and resolve
        # the POOL worktree ($TREES/<slug>) the rails run on — never leave worktree empty, which shells
        # healthcheck.sh with no tree and usage-errors into a phantom CODEERROR (HERD-346, #453).
        branch = node.get("headRefName", "")
        slug = branch_to_slug(branch)
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
                 "WATCHER_VIEW_LABEL", "WATCHER_VIEW_STATUS", "WATCHER_VIEW_DEPS_LABEL", "WATCHER_OWNER")


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

    def __init__(self, home, state, journal):
        self.home = home
        self.state = state
        self.journal = journal
        self.reused_review = False
        self.reused_health = False

    def _script(self, name):
        return os.path.join(self.home, "scripts", "herd", name)

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
        if disp and os.path.exists(disp):
            try:
                with open(disp, encoding="utf-8") as fh:
                    first = fh.readline().rstrip("\n")
            except Exception:
                first = ""
            verdict, _, detail = first.partition("\t")
            if verdict in ("CLEAN", "FLAKY", "CODEERROR"):
                st.record_health_result(cand, verdict, detail)
                st.rm(disp, st.health_inflight_file(cand))
                return verdict
            # Unparseable / truncated worker output → an infra death, NOT a verdict; never cache. Drop
            # it and re-dispatch on the next tick (bounded implicitly once the suite finally succeeds).
            st.rm(disp)
            return WAIT
        # 3. IN FLIGHT: a live worker on this exact (pr, sha) → wait, never a second overlapping suite.
        inflight = st.health_inflight_file(cand)
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
        base = os.environ.get("MAIN") or os.environ.get("PROJECT_ROOT") or ""
        try:
            proc = subprocess.Popen(
                ["bash", "-c", _HEALTH_WORKER_SH, "_",
                 self._script("healthcheck.sh"), cand.worktree, disp, log, base, st.dir or ""],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True,
            )
        except Exception as exc:
            self.journal.append("infra_event", "pr", cand.pr, "sha", cand.sha, "rail", "health",
                                "detail", "health dispatch failed: %s" % str(exc)[:160])
            return
        # The marker records the worker's SESSION (HERD-348): start_new_session makes it a session
        # leader, so a supersession (and the sweep) reaps its whole detached suite subtree by session.
        _marker_write(inflight, proc.pid)
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
                    verdict = parse_review_verdict(fh.read())
            except Exception:
                verdict = "INFRA"
            if verdict in ("PASS", "BLOCK"):
                st.record_review(cand.pr, cand.sha, verdict, "reviewer")
                st.rm(result, inflight, st.review_registry_file(cand))
                return verdict
            st.rm(result, inflight, st.review_registry_file(cand))
            return "INFRA"          # infra death — a transient the caller escalates, never a cached BLOCK
        # 3. IN FLIGHT: a live reviewer poller (marker) OR its pane (registry) → dispatch-and-wait.
        if inflight and _marker_live(inflight):
            return WAIT
        if st.reviewer_registry_live(cand):
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
        # keys bash emits (agent-watch.sh:2545) and the shadow twin emits (shadow_runtime.py:382), so
        # `herd why`/`herd log`/cost read `model`+`log_path` and a shadow↔live parity diff stays clean.
        # `model` mirrors bash's env fallback chain; `log_path` is the reviewer's result file.
        model = os.environ.get("HERD_REVIEW_MODEL") or os.environ.get("MODEL_REVIEW") or ""
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
        self.journal.append("reap", "pr", cand.pr, "slug", cand.slug, "sha", cand.sha,
                            "reason", "merged")
        return True


class LiveActuator:
    """The REAL apply layer: merge via ``gh``, reap the worktree via ``git`` (contract §2, §6.1).

    ``merge`` squash-merges the PR (``gh pr merge --squash --delete-branch``); ``reap`` removes the
    builder worktree (``git worktree remove --force``). Both journal the SAME event the dry-run twin
    does, so the forensic stream is identical shape whether or not actuation ran. Each actuation is
    guarded so a single failing merge/reap surfaces (returns ``False``) without sinking the whole tick.
    Reached only from ``--tick`` in genuine live mode — never from any test.
    """

    def __init__(self, home, journal):
        self.home = home
        self.journal = journal

    def merge(self, cand):
        try:
            subprocess.run(["gh", "pr", "merge", cand.pr, "--squash", "--delete-branch"],
                           capture_output=True, text=True, check=True)
        except Exception as exc:
            self.journal.append("merge_gh_unreadable", "pr", cand.pr, "sha", cand.sha,
                                "detail", str(exc)[:200])
            return False
        self.journal.append("merge", "pr", cand.pr, "slug", cand.slug, "sha", cand.sha,
                            "method", "squash", "reason", "gates_passed")
        return True

    def reap(self, cand):
        if cand.worktree:
            try:
                subprocess.run(["git", "worktree", "remove", "--force", cand.worktree],
                               capture_output=True, text=True, check=True)
            except Exception:
                pass  # a reap that cannot remove the worktree is not fatal — the sweep retries it
        self.journal.append("reap", "pr", cand.pr, "slug", cand.slug, "sha", cand.sha,
                            "reason", "merged")
        return True


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
        self._state = {}       # pr -> lifecycle state (the assertion layer)
        self._outcome = {}     # pr -> terminal action string
        self._refix_rounds = {}  # (pr, rule) -> refix rounds spent on that rail (S2: real round, not 1)

    def _next_refix_round(self, pr, rule):
        """The round number this rail's refix_bounce carries: the per-``(pr, rule)`` bounce count so
        far + 1 — matching bash's ``round = refix_rail_count + 1`` (``agent-watch.sh:7519,:8260``).
        The rail budget is per (pr, rule), NOT sha-keyed (contract §4; ``decisions.refix_rail_count``),
        so a repeat bounce on the same rail increments the real round instead of a hardcoded 1."""
        key = (pr, rule)
        n = self._refix_rounds.get(key, 0) + 1
        self._refix_rounds[key] = n
        return n

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
        if health == "CODEERROR":
            # Contract §3.4 refix_bounce shape (pr, sha, slug, round, agent_status_before, rule,
            # location) — the port unifies both rails under one event keyed by `rule` (there is no
            # `health_refix_bounce` in the catalog). Match the shadow twin's field SET
            # (shadow_runtime.py:418) with bash-faithful defaults: the live tick does not probe the
            # pane here (bash's own fallback is "unknown") and parses no finding location.
            self.journal.append("refix_bounce", "pr", cand.pr, "sha", cand.sha, "slug", cand.slug,
                                "round", self._next_refix_round(cand.pr, "healthcheck"),
                                "agent_status_before", "unknown", "rule", "healthcheck",
                                "location", "")
            return BLOCK

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
            # Contract §3.4 refix_bounce shape — mirror the shadow twin (shadow_runtime.py:429) and
            # bash (agent-watch.sh:7321) with bash-faithful defaults for the fields the live tick does
            # not compute here (pane status → "unknown"; finding location unparsed → "").
            self.journal.append("refix_bounce", "pr", cand.pr, "sha", cand.sha, "slug", cand.slug,
                                "round", self._next_refix_round(cand.pr, "review"),
                                "agent_status_before", "unknown", "rule", "review",
                                "location", "")
            return BLOCK

        # 4. the blessing — both rails passed (review_pass advanced the lifecycle to BLESSED). Once per
        #    (pr, sha): a held-but-blessed PR re-walked every tick posts the blessing exactly once (§5.3).
        if self.state.once(cand.pr, cand.sha, "blessing"):
            self.journal.append("blessing", "pr", cand.pr, "sha", cand.sha, "context", "herd/gates",
                                "state", "success")

        # 5. the pure hold / merge / observe decision (reused from P2, contract §2.2/§5.4-§5.5).
        action = D.hold_decision(self._merge_policy, cand.hv_hold, cand.approved, self._hv_policy)
        self._advance(cand, {"MERGE": "decide_merge", "HOLD": "decide_hold",
                             "OBSERVE": "decide_observe"}[action])

        # 6. apply — the ONLY step that actuates (and only under LiveActuator).
        if action == "MERGE":
            if self.actuator.merge(cand):
                self.actuator.reap(cand)          # reap-on-merge (contract §6.1)
                return "MERGE"
            return ESCALATE                        # merge failed → escalate, never a silent drop
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

def _config_from_env(scenario=None):
    config = dict((scenario or {}).get("config") or {})
    knobs = ("MERGE_POLICY", "WATCHER_AUTOMERGE", "HUMAN_VERIFY_POLICY") + _WATCHER_KEYS
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
    actuator = DryRunActuator(journal) if dry else LiveActuator(home, journal)
    tick = LiveTick(config, _GraphQLDiscovery(config), LiveGates(home, state, journal),
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
