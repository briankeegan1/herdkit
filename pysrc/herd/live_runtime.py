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
import hashlib
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time

from herd import cost_emit as _cost_emit
from herd import decisions as D
from herd import human_verify as _human_verify
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


# ── chaos-injection seams (HERD-425, test-only) ─────────────────────────────────────────────────────
# Three production boundaries where an untrappable hard watcher death is a genuine live risk — mid
# do_merge (LiveActuator.merge, after the merge actuates but before it is durably recorded), mid
# gate-result collect (LiveGates.health, after a dispatched worker's verdict is readable but before it
# is durably cached), and mid refix-bounce (LiveTick._bounce_and_wake, after the builder wake attempt
# actuates but before its refix_bounce/refix_wake_result journal pair lands). The refix-bounce wake
# ITSELF is never repeated on restart — the once-guard ledger row was already written durably by the
# caller, _refix_check_and_record, BEFORE _bounce_and_wake is even reached, so it blocks any further
# bounce attempt for this (pr, sha, kind) regardless of what happens next. What a death here actually
# costs is narrower: only the refix_bounce/refix_wake_result journal PAIR — an observability record,
# not a functional guard — is missing after restart; the builder was genuinely woken exactly once.
# ``tests/test-gate-reconciler-chaos-sim.sh`` is the ONLY caller that ever sets these env vars.
#
# SHIP-DORMANT / BYTE-IDENTICAL-WHEN-OFF (AGENTS.md): with HERD_CHAOS_KILL_AT unset (always true in
# production and in every other test), _chaos_kill is one cheap os.environ.get returning None — no
# journal write, no state mutation, no behavior change at any of the three call sites.
#
# FAIL-CLOSED: firing ALSO requires HERD_CHAOS_GUARD to name an EXISTING file. A stray/leaked
# HERD_CHAOS_KILL_AT in a real environment (operator typo, inherited shell env) can still never
# self-destruct a real watcher, because no real deployment ever also has HERD_CHAOS_GUARD pointing at
# an existing sentinel the hermetic harness created for itself.
def _chaos_kill(point):
    target = os.environ.get("HERD_CHAOS_KILL_AT")
    if not target or target != point:
        return
    guard = os.environ.get("HERD_CHAOS_GUARD")
    if not guard or not os.path.isfile(guard):
        return
    # SIGKILL, not sys.exit/raise: an untrappable kernel-level death — no atexit, no finally, no
    # cleanup — the exact failure mode the chaos sim must prove the NEXT tick recovers from.
    os.kill(os.getpid(), signal.SIGKILL)


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
                 "restale_laps", "agent_status", "wake_succeeds", "dirty")

    def __init__(self, pr, sha, slug="", base="", worktree="", stale=False,
                 hv_hold=False, approved=False, hv_body="", author="", assignees=None,
                 labels=None, review_decision="", merge_status="", restale_laps=0,
                 agent_status="", wake_succeeds=True, dirty=False):
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
        # FIXTURE-ONLY worktree-dirty surface (HERD-420, the same pattern as agent_status/
        # wake_succeeds above): DryRunActuator.worktree_dirty reads this directly; LiveActuator
        # ignores it and probes the real worktree (see _worktree_dirty). Absent -> False, so no
        # fixture written before this task changes shape.
        self.dirty = bool(dirty)

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
            dirty=d.get("dirty", False),
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


_INFLIGHT_TIMEOUT_PREFIXES = (".health-inflight", ".merge-result-inflight")


def _count_live_inflight(state_dir, prefix):
    """Count live in-flight markers across ALL candidates for one rail.

    ``prefix`` is the glob prefix, e.g. ``.health-inflight`` or ``.review-inflight``. For the two
    HEALTH_CONCURRENCY-shared families (HERD-451: ``.health-inflight`` and ``.merge-result-inflight``),
    liveness is IDENTITY-verified and bounded by ``HEALTH_INFLIGHT_TIMEOUT`` when a marker carries no
    provable identity at all (see :func:`_inflight_verified_live` — mirrored verbatim by
    agent-watch.sh's ``_count_live_healthchecks`` / ``_health_slot_free``, cross-referenced). Every other
    rail (review) keeps the unbounded ``_marker_live`` check, unchanged. Dead — or, for the two families
    above, identity-unverifiable-and-expired — markers are not counted (mirrors bash's
    ``_count_live_reviews``). Zero with no state dir (a sim/dry-run tick has no on-disk markers)."""
    if not state_dir:
        return 0
    if prefix in _INFLIGHT_TIMEOUT_PREFIXES:
        timeout = _pos_int(os.environ.get("HEALTH_INFLIGHT_TIMEOUT"), 1800)
        live = lambda p: _inflight_verified_live(p, timeout)
    else:
        live = _marker_live
    n = 0
    for path in glob.glob(os.path.join(state_dir, prefix + "-*")):
        if live(path):
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


# ── INFRA circuit breaker (HERD-110; gate READ restored HERD-447) ────────────────────────────────────
# The GLOBAL "env looks dead, stop dispatching" seam (contract §3.3; agent-watch.sh:_breaker_gate /
# :_breaker_record_infra / :_breaker_record_ok, agent-watch.sh:3141-3265). HERD-306's P5b deleted the
# bash action pass (_tick_act) that consulted _breaker_gate at the top of every candidate's iteration —
# the HERD-442 audit found the read had had NO caller since, so the breaker recorded consecutive
# non-verdict review deaths but never actually halted dispatch. This restores the READ into the walk
# below (:meth:`LiveTick._walk`) and the two RECORD call sites the port itself can reach (the review
# rail's verdict classification, also in :meth:`LiveTick._walk` — bash's ``_review_gate_step``). A
# THIRD bash recorder, ``_predispatch_review_if_parallel``, was genuinely obsolete here: it existed only
# to kick the reviewer early under ``GATE_DISPATCH=parallel``, a lever the Python port never
# implemented (no parallel pre-dispatch step exists in the walk) — see docs/engine-contract.md §3.3
# for the full three-way audit. HERD-580 retired ``GATE_DISPATCH`` and this bash body entirely on that
# finding. A FOURTH, ``_sweep_gate_corpses``, needs no restoration at all: it is
# bash-owned via ``herd sweep`` (scripts/herd/sweep.sh; unrelated to the deleted ``_tick_act``) and
# still runs today, writing the SAME shared ledger file :class:`LiveState`'s breaker methods use below
# — so a stuck reviewer corpse a `herd sweep` reaps still counts toward this exact global counter.
#
# BYTE-INERT BY DEFAULT: every function below short-circuits to a no-op the instant
# ``INFRA_BREAKER_MAX`` is unset/0/non-numeric (mirroring bash's ``_breaker_enabled`` guard) — no file
# I/O, no journal write, no gating — so a tick with the lever off is byte-identical to before this
# restoration.

_BREAKER_DIGITS_RE = re.compile(r"^[0-9]+$")


def _breaker_digits(raw, default):
    """Parse a config value the way bash's ``case … in ''|*[!0-9]*) …; esac`` does: digits-only (no
    sign, no decimal point) or fall back to ``default`` — so ``"-5"``/``"3.5"``/``""``/``None`` all
    degrade exactly as they do in the shell, not merely whatever Python's permissive ``int()`` accepts."""
    s = "" if raw is None else str(raw)
    return int(s) if _BREAKER_DIGITS_RE.match(s) else default


def _breaker_enabled(config):
    """True iff ``INFRA_BREAKER_MAX`` is a positive integer (agent-watch.sh:_breaker_enabled). The
    opt-in gate every function below checks first."""
    return _breaker_digits((config or {}).get("INFRA_BREAKER_MAX"), 0) > 0


def _breaker_max(config):
    return _breaker_digits((config or {}).get("INFRA_BREAKER_MAX"), 0)


def _breaker_cooldown(config):
    """``INFRA_BREAKER_COOLDOWN`` seconds, non-numeric/unset → 300 (agent-watch.sh:_breaker_cooldown)."""
    return _breaker_digits((config or {}).get("INFRA_BREAKER_COOLDOWN"), 300)


def _breaker_record_infra(state, config, journal):
    """One non-verdict INFRA death observed — bump the consecutive counter; OPEN at
    ``INFRA_BREAKER_MAX`` from CLOSED, or RE-OPEN (fresh cooldown) if already open/probing
    (agent-watch.sh:_breaker_record_infra). No-op (no ledger write, no journal) when disabled."""
    if not _breaker_enabled(config):
        return
    st, fa, op, _pb = state.breaker_read()
    now = int(_now_epoch())
    fa += 1
    maxn = _breaker_max(config)
    if st == "closed":
        if fa >= maxn:
            state.breaker_write("open", fa, now, None)
            journal.append("infra_breaker_open", "scope", "global", "fails", fa, "threshold", maxn,
                           "cooldown", _breaker_cooldown(config))
        else:
            state.breaker_write("closed", fa, op, None)
    else:
        state.breaker_write("open", fa, now, None)
        journal.append("infra_breaker_reopen", "scope", "global", "fails", fa, "threshold", maxn,
                       "cooldown", _breaker_cooldown(config))


def _breaker_record_ok(state, config, journal):
    """A REAL verdict landed (PASS or BLOCK): the env is provably alive — reset the counter and CLOSE
    (agent-watch.sh:_breaker_record_ok). No-op when disabled; cheap no-op when already closed at 0."""
    if not _breaker_enabled(config):
        return
    st, fa, _op, _pb = state.breaker_read()
    if st != "closed":
        state.breaker_write("closed", 0, 0, None)
        journal.append("infra_breaker_close", "scope", "global", "recovered_via", "verdict")
    elif fa != 0:
        state.breaker_write("closed", 0, 0, None)


def _breaker_gate(pr, state, config):
    """Per-candidate dispatch decision (agent-watch.sh:_breaker_gate) — one of:

      PASS    — breaker closed → dispatch normally.
      PROBE   — breaker half-open and THIS candidate is (or just claimed) the single recovery probe.
      BLOCKED — breaker open/cooling down, or another candidate already holds the probe claim.

    Half-open is entered by transitioning open→probing once the cooldown elapses: the FIRST candidate
    to reach the gate claims itself as the probe (persisted in the ledger) and gets PROBE; every other
    candidate reads state=probing and, not being the claimed PR, gets BLOCKED. Byte-inert (always
    PASS, no file I/O) when disabled."""
    if not _breaker_enabled(config):
        return "PASS"
    st, fa, op, pb = state.breaker_read()
    if st in ("open", "probing"):
        now = int(_now_epoch())
        cd = _breaker_cooldown(config)
        if now - op >= cd:
            state.breaker_write("probing", fa, now, pr)
            return "PROBE"
        if st == "probing" and pb is not None and str(pr) == str(pb):
            return "PROBE"
        return "BLOCKED"
    return "PASS"


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


# ── durable per-rail EXHAUSTION LATCH (HERD-576) ──────────────────────────────────────────────────
# The refix round cap is already correctly re-derived from the durable ledger every tick (a FRESH
# `python3 -m herd.live_runtime --tick` subprocess each cycle, HERD-358) — that arithmetic survives a
# watcher restart on its own. This latch adds a SEPARATE, restart-safe belt: a dedicated one-file-per-
# (pr, rail) marker under $TREES, the same shape as every other restart-safe marker this pool already
# carries (`.review-inflight-*`, `.health-dispatch-*`, HERD-185's pattern of "one small file names one
# fact") — so "this rail's budget is spent" is a durably PERSISTED fact the moment it is first true,
# not only an inference re-derived by re-scanning the whole ledger. Once written, the latch survives
# ANY restart and keeps STOPPING bounces on that rail even if the ledger scan were ever wrong; it is
# cleared the moment the rail's red genuinely resolves (`refix_rail_reset`), exactly when the ledger
# count itself zeroes (contract §4's refund-on-green). NOT sha-keyed: a rail's exhaustion — like its
# budget — spans every sha until a reset, the same scope `refix_rail_count` already uses.
def _refix_escalated_path(state_dir, pr, kind):
    """Path to the durable exhaustion latch for this ``(pr, rail)``; ``None`` with no state dir."""
    return os.path.join(state_dir, ".refix-escalated-%s-%s" % (pr, kind)) if state_dir else None


def _refix_rail_escalated(state_dir, pr, kind):
    """True iff this rail's budget was already latched exhausted and has not been reset since."""
    path = _refix_escalated_path(state_dir, pr, kind)
    return bool(path) and os.path.exists(path)


def _mark_refix_rail_escalated(state_dir, pr, kind):
    """Write the durable latch; a no-op (never raises) with no state dir or on I/O failure."""
    path = _refix_escalated_path(state_dir, pr, kind)
    if not path:
        return
    try:
        open(path, "w", encoding="utf-8").close()
    except Exception:
        pass


def _clear_refix_rail_escalated(state_dir, pr, kind):
    """Remove the durable latch; a no-op when absent, with no state dir, or on I/O failure."""
    path = _refix_escalated_path(state_dir, pr, kind)
    if not path:
        return
    try:
        os.remove(path)
    except OSError:
        pass


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


def _marker_dispatch_ts(path):
    """Line 3 of an in-flight marker — the dispatch epoch stamped by ``_marker_write``
    (agent-watch.sh:_marker_dispatch_ts). ``""`` when missing/unreadable (a legacy pre-restart-safe
    marker, or any writer that laid down fewer than 3 lines)."""
    try:
        lines = open(path, encoding="utf-8").read().splitlines()
    except Exception:
        return ""
    return lines[2].strip() if len(lines) > 2 else ""


def _marker_age(path):
    """Seconds since the marker's dispatch ts, or ``None`` when no ts is recorded
    (agent-watch.sh:_marker_age)."""
    ts = _marker_dispatch_ts(path)
    if not ts.isdigit():
        return None
    try:
        return int(_now_epoch()) - int(ts)
    except Exception:
        return None


def _marker_age_or_mtime(path):
    """``_marker_age`` when available, else a FALLBACK computed from the marker FILE's own mtime — the
    on-disk floor for a marker written before the dispatch-ts line existed (agent-watch.sh:
    _marker_age_or_mtime). ``None`` only when both signals are unavailable (the file vanished mid-read)."""
    age = _marker_age(path)
    if age is not None:
        return age
    try:
        return int(_now_epoch()) - int(os.path.getmtime(path))
    except Exception:
        return None


def _inflight_verified_live(path, timeout):
    """THE shared "does this in-flight marker still legitimately hold a health/merge-result slot" check
    (HERD-451 — mirrors agent-watch.sh's ``_inflight_verified_live`` verbatim, cross-referenced; Rule 2,
    one notion of liveness, never two divergent copies). Recycling-safe IDENTITY, not bare existence:
      * pid dead → not live.
      * pid alive AND the marker's recorded start-time matches the pid's CURRENT one → live, UNBOUNDED
        (a verified-same-process worker is trusted for as long as it legitimately runs — the SEPARATE
        inflight-timeout the corpse sweep enforces decides whether to TERM a long-running one, not this).
      * pid alive but the recorded start-time does NOT match → NOT live (the classic PID-RECYCLING case;
        already handled by ``_marker_live`` and unchanged here).
      * pid alive but NO start-time was ever recorded (a legacy pre-restart-safe marker, or any writer
        that bypassed ``_marker_write``) → identity CANNOT be proven from the marker alone. A bare
        ``kill -0`` success is trusted ONLY within ``timeout`` seconds of the marker's age (dispatch-ts,
        else file mtime); past that it reads as NOT live. An unverifiable marker no longer gets an
        indefinite pass just because *some* process now happens to hold that recycled pid — the EXACT
        GROUNDED 2026-07-31 failure: a stale ``.health-inflight-*`` marker's recorded pid had been
        recycled by the OS onto the watcher itself / an unrelated ``sleep``, and the old bare-existence
        check trusted it forever, wedging the HEALTH_CONCURRENCY slot with zero suites actually running.
    """
    try:
        lines = open(path, encoding="utf-8").read().splitlines()
    except Exception:
        return False
    pid = (lines[0].strip() if lines else "")
    if not pid or not _pid_live(pid):
        return False
    st = (lines[1].strip() if len(lines) > 1 else "")
    if st:
        cur = _pid_starttime(pid)
        if not cur:
            return True          # transient ps hiccup — trust the recorded identity, unchanged
        return cur == st
    age = _marker_age_or_mtime(path)
    if age is None:
        return True              # no signal at all — fail toward not reaping
    return age < timeout


_MARKER_SHA_RE = re.compile(r'^[0-9a-f]{7,40}$')


def _parse_marker_sha(path, prefix, pr, journal=None):
    """Extract + validate the sha field off a ``<prefix>-<pr>-<sha>`` in-flight marker filename
    (HERD-471). ``prefix`` and ``pr`` are known to the caller, so the sha is sliced off the KNOWN
    ``<prefix>-<pr>-`` stem, never rsplit on the name's last hyphen — a blind rsplit truncates at the
    WRONG boundary whenever the sha itself contains a hyphen (a hyphenated fixture sha; conceivably a
    corrupted real one), silently handing back a plausible-looking but wrong fragment instead of the
    real sha. The remainder is then shape-checked against a real git sha ([0-9a-f]{7,40}); anything
    else is malformed — parsed off a marker this process didn't write in this shape, a partial write
    caught mid-flight, or disk corruption — and is skipped LOUDLY: journaled as ``marker_sha_malformed``
    (when a journal is given) rather than silently treated as a live/stale sha either way. Returns the
    sha string, or ``None`` for anything that doesn't parse."""
    name = os.path.basename(path)
    stem = "%s-%s-" % (prefix, pr)
    sha = name[len(stem):] if name.startswith(stem) else ""
    if not _MARKER_SHA_RE.match(sha):
        if journal is not None:
            journal.append("marker_sha_malformed", "path", path, "prefix", prefix, "pr", pr)
        return None
    return sha


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

    def review_escalate_file(self, pr):
        """Evidence-triggered escalation arm marker, keyed per-PR (NOT per-sha; HERD-580 port of
        agent-watch.sh:_review_escalate_file). Armed once a PR's REVIEW refix rounds prove the cheap
        reviewer missed the issue, consumed by the next review dispatch on that PR."""
        return self._p(".review-escalate-%s" % pr)

    def claude_hang_state_file(self):
        """The claude exec-hang probe's episode marker (HERD-108, HERD-580 port of agent-watch.sh's
        ``CLAUDE_HANG_STATE``): one line, the epoch the CURRENT hang episode began, absent when healthy."""
        return self._p(".agent-watch-claude-hang")

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

    def recorded_review_reason(self, pr, sha):
        """The reviewer's recorded BLOCK reason for this exact ``(pr, sha)``, or ``""`` (HERD-473).

        The ledger row's TRAILING field (everything after ``source``), so the five positional fields
        every other reader parses are untouched. FAIL-SOFT on a LEGACY reason-less row, a missing ledger
        and an unreadable one alike: all three answer ``""``, and a caller never has to tell them apart
        — "no reason recorded" is a first-class, sayable answer, not an error."""
        if self._store is not None:
            try:
                return self._store.recorded_review_reason(pr, sha)
            except Exception:
                return ""
        path = self.review_ledger()
        if not path or not os.path.exists(path):
            return ""
        reason = ""
        try:
            with open(path, encoding="utf-8") as fh:
                for line in fh:
                    f = line.split()
                    if len(f) >= 4 and f[1] == str(pr) and f[2] == str(sha):
                        reason = " ".join(f[5:])
        except Exception:
            return ""
        return reason

    def recorded_review_source(self, pr, sha):
        """The PROVENANCE field of this ``(pr, sha)``'s recorded verdict (HERD-559) —
        ``reviewer`` | ``pregate`` | ``skipped-low-risk`` | ``carried-forward`` — or ``""`` when no row
        exists. The review rail can now refuse a diff two ways (a model's correctness finding and a
        deterministic pre-gate lint red), and a reader that cannot tell them apart would misdescribe
        both: the refix prompt would point a mechanical red at a review that was never written.

        FAIL-SOFT exactly like ``recorded_review_reason``: a legacy row with no source field, like a
        missing or unreadable ledger, is not an error. A row that HAS a verdict but no provenance is
        ``reviewer`` — that is what every row written before provenance existed meant."""
        if self._store is not None:
            try:
                return self._store.recorded_review_source(pr, sha)
            except Exception:
                return ""
        path = self.review_ledger()
        if not path or not os.path.exists(path):
            return ""
        source = ""
        try:
            with open(path, encoding="utf-8") as fh:
                for line in fh:
                    f = line.split()
                    if len(f) >= 4 and f[1] == str(pr) and f[2] == str(sha):
                        source = f[4] if len(f) >= 5 else "reviewer"
        except Exception:
            return ""
        return source

    def recorded_review_last_pass_sha(self, pr):
        """The sha of the most-recently recorded PASS for this PR — any provenance (a real reviewer
        PASS, a low-risk skip, or an earlier carry-forward, each tracing back to a real cleared commit)
        — or ``None`` (HERD-580 port of agent-watch.sh:_review_last_passed_sha). The DELTA_REVIEW
        carry-forward proof's "last-passed sha" input."""
        if self._store is not None:
            try:
                return self._store.recorded_review_last_pass_sha(pr)
            except Exception:
                return None
        path = self.review_ledger()
        if not path or not os.path.exists(path):
            return None
        sha = None
        try:
            with open(path, encoding="utf-8") as fh:
                for line in fh:
                    f = line.split()
                    if len(f) >= 4 and f[1] == str(pr) and f[3] == "PASS":
                        sha = f[2]
        except Exception:
            return None
        return sha

    def record_review(self, pr, sha, verdict, source="reviewer", reason=""):
        """Append one review ledger row ``<epoch> <pr> <sha> <verdict> <source> [reason…]``
        (agent-watch.sh:1820).

        ``reason`` (HERD-473) is the reviewer's structured BLOCK reason, whitespace-collapsed to a single
        token run so it rides as the TRAILING field — appended, never interleaved, so `awk '$4'`/`$5` and
        `f[3]`/`f[4]` readers are unaffected. Empty ⇒ the row is written BYTE-IDENTICALLY to before this
        field existed, which is also exactly the shape every pre-HERD-473 row already has."""
        reason = " ".join(str(reason).split())
        if self._store is not None:
            self._store.record_review(pr, sha, verdict, source, reason)
            return
        path = self.review_ledger()
        if not path:
            return
        try:
            with open(path, "a", encoding="utf-8") as fh:
                if reason:
                    fh.write("%s %s %s %s %s %s\n" % (_now_epoch(), pr, sha, verdict, source, reason))
                else:
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

    # gate-config generation side-channel (HERD-576, leg 2) ───────────────────────────────────────
    # A SEPARATE file from the classic sha-cache above (never shares a name, never changes its
    # format) — purely additive: it exists ONLY to answer "did this cached red predate the current
    # gate config", and its absence (every cache written before this feature, or a SQLite-backend
    # pool where the store never gained a column for it) is a first-class, silent "unknown, no hint"
    # answer, never an error. See herd.decisions.gate_config_generation / gate_config_generation_hint.
    def health_generation_file(self, cand):
        return self._p(".health-result-gen-%s-%s" % (cand.pr, cand.sha))

    def record_health_generation(self, cand, generation):
        path = self.health_generation_file(cand)
        if not path or not cand.sha:
            return
        try:
            with open(path, "w", encoding="utf-8") as fh:
                fh.write("%s\n" % generation)
        except Exception:
            pass

    def health_cached_generation(self, cand):
        """The generation fingerprint recorded alongside this cached verdict, or ``None`` when
        absent/unreadable (a pre-feature cache, a store-backend pool, or a sim with no state dir)."""
        path = self.health_generation_file(cand)
        if not path or not os.path.exists(path):
            return None
        try:
            with open(path, encoding="utf-8") as fh:
                gen = fh.readline().strip()
        except Exception:
            return None
        return gen or None

    # merge-result-gate substrate (MERGE_RESULT_GATE, §6.4, HERD-296) ─────────────────────────────
    # A SEPARATE namespace from the classic health substrate above — never shares a filename with it —
    # so gate-off leaves zero markers behind (byte-identical: the glob a gate-off tick performs against
    # ``.health-inflight``/``.health-result`` never sees one of these) and the classic health dispatch/
    # collect code above is never touched by this feature. Dispatch/inflight/log/tree are keyed by
    # ``(pr, sha)`` only — ONE merge-result suite may be in flight per head sha regardless of which base
    # it is being tested against (the base actually tested travels inside the dispatch nonce, see
    # ``_dispatch_nonce_with_base`` / ``_nonce_base``); the DURABLE verdict cache is keyed by
    # ``(pr, sha, base)`` so a base move naturally re-arms the gate (a new base sha is simply a cache miss).
    def merge_result_dispatch_file(self, pr, sha):
        return self._p(".merge-result-dispatch-%s-%s" % (pr, sha))

    def merge_result_inflight_file(self, pr, sha):
        return self._p(".merge-result-inflight-%s-%s" % (pr, sha))

    def merge_result_log_file(self, pr, sha):
        return self._p(".merge-result-log-%s-%s" % (pr, sha))

    def merge_result_tree_path(self, pr, sha):
        return self._p(".merge-result-tree-%s-%s" % (pr, sha))

    def merge_result_verdict(self, pr, sha, base):
        """The TERMINAL merge-result verdict already proven for this EXACT (head, base) pair — reused
        with no suite re-run. ``None`` on any miss (never tested, or tested against a DIFFERENT base —
        the base-move re-arm, §6.4 target 4)."""
        path = self._p(".merge-result-verdict-%s-%s-%s" % (pr, sha, base))
        if not path or not os.path.exists(path):
            return None
        try:
            with open(path, encoding="utf-8") as fh:
                first = fh.readline().rstrip("\n")
        except Exception:
            return None
        verdict = first.split("\t", 1)[0]
        return verdict if verdict in ("CLEAN", "FLAKY", "CODEERROR") else None

    def record_merge_result_verdict(self, pr, sha, base, verdict, detail=""):
        path = self._p(".merge-result-verdict-%s-%s-%s" % (pr, sha, base))
        if not path:
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

    # INFRA circuit-breaker substrate (HERD-110, gate read restored HERD-447) ─────────────────────────
    # THE SAME one-line ledger bash's ``_breaker_read``/``_breaker_write`` use
    # (``$TREES/.agent-watch-infra-breaker``, agent-watch.sh:3153/:3175/:3184) — GLOBAL (not sha-keyed),
    # so a python tick and `herd sweep`'s bash-owned ``_sweep_gate_corpses`` leg (agent-watch.sh:12312,
    # STILL a live writer — see docs/engine-contract.md §3.3) genuinely share one counter, exactly like
    # the review/health ledgers above. Format: ``<state> <fails> <opened_epoch> <probe_pr>``, state ∈
    # closed|open|probing, probe_pr ``-`` when unclaimed.

    def breaker_state_path(self):
        return self._p(".agent-watch-infra-breaker")

    def breaker_read(self):
        """``(state, fails, opened, probe_pr)`` — mirrors agent-watch.sh:_breaker_read. A missing, short,
        or corrupt ledger line reads as the closed/zeroed default, exactly like bash's ``${st:-closed}``
        fallback fields."""
        path = self.breaker_state_path()
        if path and os.path.exists(path):
            try:
                with open(path, encoding="utf-8") as fh:
                    fields = fh.readline().split()
            except Exception:
                fields = []
            if len(fields) >= 4:
                st, fa, op, pb = fields[0], fields[1], fields[2], fields[3]
                try:
                    fa = int(fa)
                except ValueError:
                    fa = 0
                try:
                    op = int(op)
                except ValueError:
                    op = 0
                return st, fa, op, (None if pb == "-" else pb)
        return "closed", 0, 0, None

    def breaker_write(self, state, fails, opened, probe_pr):
        """Persist the one-line breaker ledger (agent-watch.sh:_breaker_write). No-op w/o a state dir —
        a sim/dry-run tick with a black-hole state carries no cross-tick breaker memory, same as every
        other ledger above."""
        path = self.breaker_state_path()
        if not path:
            return
        try:
            with open(path, "w", encoding="utf-8") as fh:
                fh.write("%s %s %s %s\n" % (state, fails, opened, probe_pr if probe_pr else "-"))
        except Exception:
            pass

    # gh rate-limit backoff substrate (HERD-582) ──────────────────────────────────────────────────
    # GLOBAL (not sha-keyed), like the breaker ledger above: one line, ``<until_epoch>``, the moment a
    # tick may next attempt a REMOTE (gh) call. Written when a tick classifies a gh failure as a rate
    # limit (never on a genuine fault, agent-watch.sh:epoch_to_hhmm renders the SAME file for the
    # console's calm row) and read at the TOP of every tick so a still-active backoff window skips the
    # gh round-trip entirely rather than re-drawing the same rejection tick after tick.

    def gh_rate_limit_path(self):
        return self._p(".agent-watch-gh-rate-limit")

    def gh_rate_limited_until(self):
        """The epoch a rate-limit backoff window ends, or 0 (no window / unreadable / no state dir)."""
        path = self.gh_rate_limit_path()
        if not path or not os.path.exists(path):
            return 0
        try:
            with open(path, encoding="utf-8") as fh:
                return int(fh.readline().strip())
        except Exception:
            return 0

    def set_gh_rate_limited_until(self, until):
        """Persist the backoff window end. No-op w/o a state dir — a sim/dry-run tick carries no
        cross-tick memory, same as every other ledger above."""
        path = self.gh_rate_limit_path()
        if not path:
            return
        try:
            with open(path, "w", encoding="utf-8") as fh:
                fh.write("%d\n" % int(until))
        except Exception:
            pass

    def clear_gh_rate_limited(self):
        """Drop the backoff marker on a clean (non-rate-limited) discovery — the recovery path."""
        path = self.gh_rate_limit_path()
        if not path:
            return
        try:
            if os.path.exists(path):
                os.remove(path)
        except Exception:
            pass

    # approvals substrate ──────────────────────────────────────────────────────────────────────────
    # THE SAME flat ledger `herd-approve.sh` reads and writes (approvals.sh: one seam, one answer):
    # rows are `<epoch> <state> <pr#> <sha>` with state ∈ awaiting | approved | hv-informed, at
    # `$HERD_APPROVALS_FILE` else `$WORKTREES_DIR/.agent-watch-approvals`. The port MUST use this file
    # and not a private marker: `herd approve <pr#>` REFUSES ("No awaiting approval record found") when
    # no `awaiting` row exists, so an engine that holds a PR without writing one holds it forever.
    # Matching is EXACT on the full sha, mirroring agent-watch.sh:approval_is_approved — the prefix
    # tolerance in approvals.sh:approval_state is for the operator-facing `list`, not the merge gate.

    def approvals_ledger(self):
        return os.environ.get("HERD_APPROVALS_FILE") or self._p(".agent-watch-approvals")

    def _ledger_row(self, path, state, pr, sha):
        """True iff `path` carries an exact `<epoch> <state> <pr> <sha>` row. False on any read
        fault / missing ledger — fail-soft, mirroring bash's `[ -s "$LEDGER" ] || return 1`. Shared by
        the approvals ledger (:meth:`_approval_row`) and the overrides ledger (:meth:`override_exists`)
        — same flat-row shape, different file."""
        if not path or not os.path.exists(path):
            return False
        want = (str(state), str(pr), str(sha))
        try:
            with open(path, encoding="utf-8", errors="replace") as fh:
                for line in fh:
                    f = line.split()
                    if len(f) >= 4 and (f[1], f[2], f[3]) == want:
                        return True
        except Exception:
            return False
        return False

    def _approval_row(self, state, pr, sha):
        return self._ledger_row(self.approvals_ledger(), state, pr, sha)

    def approval_is_approved(self, pr, sha):
        """True iff `herd-approve.sh approve` wrote an explicit approval for this exact (pr, sha)."""
        return self._approval_row("approved", pr, sha)

    def approval_awaiting_noted(self, pr, sha):
        """True iff an awaiting-approval notice is already on the ledger for this exact (pr, sha)."""
        return self._approval_row("awaiting", pr, sha)

    def record_approval(self, state, pr, sha):
        """Append one `<epoch> <state> <pr> <sha>` row (agent-watch.sh:record_approval_awaiting /
        :record_hv_informed). No-op with no ledger path, so a fixture/dry-run tick writes nothing."""
        path = self.approvals_ledger()
        if not path:
            return
        try:
            with open(path, "a", encoding="utf-8") as fh:
                fh.write("%d %s %s %s\n" % (int(time.time()), state, pr, sha))
        except Exception:
            pass

    def purge_pr_approvals(self, pr):
        """Drop EVERY row for this PR — a merge is terminal (agent-watch.sh:purge_pr_approvals,
        HERD-90). Without this an old sha's `awaiting` row survives the merge as a phantom hold that
        `herd approve list` keeps surfacing. Atomic rewrite, fully fail-soft."""
        path = self.approvals_ledger()
        if not path or not os.path.exists(path):
            return
        try:
            with open(path, encoding="utf-8", errors="replace") as fh:
                kept = [l for l in fh if len(l.split()) < 4 or l.split()[2] != str(pr)]
            tmp = path + ".%d.tmp" % os.getpid()
            with open(tmp, "w", encoding="utf-8") as fh:
                fh.writelines(kept)
            os.replace(tmp, path)
        except Exception:
            pass

    # cross-seat BLOCK override substrate (HERD-247, restored HERD-446) ──────────────────────────────
    # A SEPARATE flat ledger from the approvals one above — `herd-approve.sh override <pr#>` writes
    # `<epoch> override <pr> <sha>` rows to `$WORKTREES_DIR/.agent-watch-overrides` (agent-watch.sh:
    # OVERRIDES), never to the approvals file. Sha-keyed: a new commit does not inherit the override.

    def overrides_ledger(self):
        return self._p(".agent-watch-overrides")

    def override_exists(self, pr, sha):
        """True iff a human override was recorded for this exact ``(pr, sha)`` via
        ``herd-approve.sh override`` (agent-watch.sh:override_exists) — the documented human out that
        clears a standing cross-seat BLOCK."""
        return self._ledger_row(self.overrides_ledger(), "override", pr, sha)

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

    def merge_result_dispatch_file_sha(self, pr, sha):
        return self._sha_path(".merge-result-dispatch", pr, sha)

    def merge_result_log_file_sha(self, pr, sha):
        return self._sha_path(".merge-result-log", pr, sha)

    def merge_result_tree_path_sha(self, pr, sha):
        return self._sha_path(".merge-result-tree", pr, sha)

    def stale_inflight(self, prefix, pr, cur_sha, journal=None):
        """DYNAMIC discovery of doomed workers: yield ``(marker_path, sha)`` for every
        ``$TREES/<prefix>-<pr>-<sha>`` in-flight marker whose ``sha`` differs from the PR's current head
        ``cur_sha`` (a prior head this PR has moved past). No hardcoded candidate list — the stale set is
        globbed off disk, exactly as ``_discard_stale_health`` walks ``.health-inflight-$pr-*``
        (agent-watch.sh:10420). Empty with no state dir (a sim/dry-run tick has no on-disk workers). Each
        marker's sha is extracted + validated by the shared :func:`_parse_marker_sha` (HERD-471) — a
        marker whose sha doesn't parse is skipped (loud-journaled when ``journal`` is given), never
        yielded with a corrupted sha."""
        if not self.dir:
            return
        for path in sorted(glob.glob(self._p("%s-%s-*" % (prefix, pr)))):
            sha = _parse_marker_sha(path, prefix, pr, journal=journal)
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


# ── MERGE_RESULT_GATE (§6.4, HERD-296) — materialize head+base, gate THAT tree ──────────────────────
# Ship-dormant (default off): every function below is reached ONLY when LiveGates._merge_result_gate is
# True, and every filename this namespace touches (``.merge-result-*``) is disjoint from the classic
# health substrate above, so an off tick — the default, and every tick before this feature existed —
# never globs, opens, or writes one of these paths. Off is a hard byte-identical no-op.

def _merge_result_gate_enabled(config):
    """STRICT validated gate key: an unrecognized/absent ``MERGE_RESULT_GATE`` value is OFF — the safe,
    byte-identical default — never accidentally on from a typo (mirrors ``_merge_fairness_enabled``)."""
    val = str((config or {}).get("MERGE_RESULT_GATE", "") or "").strip().lower()
    return val in ("1", "true", "on", "yes", "enable", "enabled")


def _resolve_default_branch_sha():
    """The CURRENT default-branch tip sha — the base the merge-result gate tests against. ``MAIN`` is
    the watcher's (unexported, HERD-345) default-branch checkout dir; ``PROJECT_ROOT`` is the exported
    fallback the classic health dispatch already relies on (mirrors ``_main_health_pending``). Fail-soft:
    any resolution fault (missing dir, no git, detached weirdness) returns ``""`` — the caller then HOLDS
    (never gates un-based, never crashes the tick)."""
    try:
        main_dir = os.environ.get("MAIN") or os.environ.get("PROJECT_ROOT") or ""
        if not main_dir:
            return ""
        out = subprocess.check_output(["git", "-C", main_dir, "rev-parse", "HEAD"],
                                      stderr=subprocess.DEVNULL)
        sha = out.decode().strip()
        return sha if len(sha) == 40 else ""
    except Exception:
        return ""


def _dispatch_nonce_with_base(base_sha):
    """A dispatch nonce (HERD-349 shape: ``<epoch>.<pid>.…``) that ALSO carries the base sha this
    dispatch tests against, so the collector can key the durable verdict to the EXACT (head, base) pair
    a worker actually ran — even if the default branch has since moved on to a newer tip. A 40-char hex
    sha has no ``.``, so the 3-field join round-trips through :func:`_nonce_base` unambiguously."""
    return "%s.%s.%s" % (_now_epoch(), os.getpid(), base_sha)


def _nonce_base(nonce):
    """The base sha embedded by :func:`_dispatch_nonce_with_base`, or ``""`` for a plain (non-base)
    nonce / malformed value — fail-soft, never raises."""
    parts = (nonce or "").split(".", 2)
    return parts[2] if len(parts) == 3 else ""


def _remove_merge_tree(src_worktree, tree_path):
    """Tear down a throwaway merge-result worktree, leaving NEITHER a registered worktree NOR a
    directory behind (task HERD-296: 'without leaving merge commits or temporary state'). Best-effort +
    silent — a cleanup fault never raises into the tick; a future tick's materialize call removes any
    stale leftover before reusing the path (belt-and-braces)."""
    if not tree_path:
        return
    try:
        subprocess.run(["git", "-C", src_worktree, "worktree", "remove", "--force", tree_path],
                       capture_output=True, text=True)
    except Exception:
        pass
    if os.path.isdir(tree_path):
        try:
            shutil.rmtree(tree_path, ignore_errors=True)
        except Exception:
            pass


def _materialize_merge_tree(src_worktree, head_sha, base_sha, tree_path):
    """Build a DETACHED, throwaway worktree at ``head_sha`` merged with ``base_sha`` — the exact
    candidate tree the gate suite runs against (spike §2 step 1: 'the same dance STALE_BASE_AUTOFIX
    already performs, minus the push'). Never touches ``src_worktree`` (the builder's own branch) or the
    shared default-branch checkout: ``git worktree add --detach`` only REGISTERS a new linked worktree
    under the shared ``.git`` — no branch ref is created or moved, so neither the builder branch nor
    main is contaminated. Returns ``(True, "")`` on a clean merge (the tree is left in place for the
    caller to dispatch the suite against) or ``(False, detail)`` on ANY failure — a real conflict, a
    worktree-add fault, an unreadable src — in which case the attempt is fully unwound (worktree removed,
    directory gone) before returning, so a failed materialize never leaks a merge commit or a stray dir.
    """
    try:
        if os.path.exists(tree_path):
            _remove_merge_tree(src_worktree, tree_path)
        added = subprocess.run(
            ["git", "-C", src_worktree, "worktree", "add", "--detach", tree_path, head_sha],
            capture_output=True, text=True,
        )
        if added.returncode != 0:
            _remove_merge_tree(src_worktree, tree_path)
            return False, ("worktree add failed: %s" % (added.stderr or added.stdout or "")).strip()[:200]
        merged = subprocess.run(
            ["git", "-C", tree_path, "merge", "--no-edit", base_sha],
            capture_output=True, text=True,
        )
        if merged.returncode != 0:
            subprocess.run(["git", "-C", tree_path, "merge", "--abort"], capture_output=True, text=True)
            _remove_merge_tree(src_worktree, tree_path)
            detail = ("merge conflict: %s" % (merged.stderr or merged.stdout or "")).strip()
            return False, detail[:200]
        return True, ""
    except Exception as exc:
        _remove_merge_tree(src_worktree, tree_path)
        return False, str(exc)[:200]


def _total_health_inflight(state_dir):
    """The suite-running slot count that must never exceed ``HEALTH_CONCURRENCY`` (spike §2 cleanup
    note: 'respect HEALTH_CONCURRENCY') — the classic health workers PLUS any merge-result-gate workers,
    since both shell the same heavy suite against the same shared git object store. With
    MERGE_RESULT_GATE off (the default) no ``.merge-result-inflight-*`` marker is ever written, so this
    is byte-identical to counting the classic prefix alone."""
    return (_count_live_inflight(state_dir, ".health-inflight")
            + _count_live_inflight(state_dir, ".merge-result-inflight"))


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
#       $8 OPTIONAL profile ("--light") — HERD-531/555: stamped by LiveGates.health only when the
#       sha-matched builder-local trust check (_health_trust_check) trusted this exact head sha,
#       forwarded straight through to healthcheck.sh so a trusted dispatch really runs the light
#       profile instead of the full heavy suite. Empty on every OTHER dispatch, byte-identical to
#       before this key existed. Both the first run and the solo retry below share this SAME profile
#       (one `_run`), so a trusted smoke that reds still retries as a smoke rather than silently
#       escalating mid-verdict. Every invocation — trusted or not — stamps HERD_HEALTH_PROVENANCE=watcher
#       so the provenance record healthcheck.sh writes for THIS run can never later be read back as
#       builder-local evidence (health-trust.sh's own anti-compounding rule).
#
# ENV-SUSPECT TIMEOUT CLASSIFICATION (HERD-546, re-hung onto this live worker by HERD-567): before
# HERD-567, ENV_SUSPECT_TIMEOUT/HEALTH_LOAD_THRESHOLD were wired ONLY into agent-watch.sh's bash
# _health_worker, which lost its only caller (_healthcheck_gate) at the P5b engine port — the lever
# was configurable, defaulted correctly, unit-tested, and dead: turning it on changed nothing under
# the shipped python engine (scripts/herd/lever-reachability-lint.sh's baseline finding, HERD-556).
# THIS worker is the actual live suite runner (LiveGates._dispatch_health / _dispatch_merge_result),
# so the classification is ported here, mirroring agent-watch.sh's _env_suspect_enabled /
# _health_timeout_detail / _health_loadavg_1m / _health_sibling_suites_live / _health_load_high
# byte-for-byte (self-contained — no sourcing, matching this script's own no-dependency style, since
# a sourcing failure here would stall EVERY PR's health gate, not just this lever). ENV_SUSPECT_TIMEOUT
# unset/off (default) never calls any of the _es_* helpers below — byte-inert.
#
# Classified while a run-1 failure is still forming its verdict: the '[env-suspect] …' marker is
# APPENDED to the live $log (never overwriting it) the instant a timeout+load match is found, BEFORE
# the solo retry runs — so agent-watch.sh's _health_inflight_note / _health_env_suspect_marker (the
# render half, painted by either engine) shows it on the very next tick while the retry is still in
# flight. On a reproduced failure the retry's own output later `mv`'s over $log (unchanged from
# before this lever existed), so the marker is transient by design — visible only while in flight,
# exactly like the pre-port bash behavior. The classification detail additionally lands in a
# `$log.envsuspect` side-channel file (a single line, sanitized) so the terminal collector (`health` /
# `_merge_result_health` in this module) can journal `health_env_suspect` once the async worker exits
# — the log itself is not a reliable channel for that at collect time, since a reproduced failure has
# already overwritten it by then.
_HEALTH_WORKER_SH = r'''
set -u
hc="$1"; dir="$2"; out="$3"; log="$4"; base="$5"; cache="$6"; nonce="$7"; profile="${8:-}"
args=("$dir")
[ -n "$profile" ] && args+=("$profile")
# HERD-533: hand healthcheck.sh a per-attempt progress companion ("$1.progress") via
# HEALTHCHECK_PROGRESS_LOG (HERD-494's convention — agent-watch.sh's bash worker sets the same var).
# healthcheck.sh tees the suite's raw output there AS IT RUNS, so an operator tailing it sees real
# progress instead of the 0-byte black box this log used to sit at for the suite's whole runtime.
# Truncated fresh per attempt (run 1 and the solo retry each get their own), and additive only: the
# actual $log this function writes below is unchanged (same command, same redirect, same verdict).
_run() {
  : > "$1.progress" 2>/dev/null || true
  HERD_BASELINE_DIR="$base" HERD_BASELINE_CACHE="$cache" HEALTHCHECK_PROGRESS_LOG="$1.progress" \
    HERD_HEALTH_PROVENANCE=watcher \
    bash "$hc" "${args[@]}" > "$1" 2>&1
}
_es_on() {
  case "$(printf '%s' "${ENV_SUSPECT_TIMEOUT:-off}" | tr '[:upper:]' '[:lower:]')" in
    on|true|1) return 0 ;;
    *) return 1 ;;
  esac
}
_es_timeout_detail() {
  grep -m1 -E '# timeout after [0-9]+s|\(TIMEOUT after [0-9]+s\)' <<<"${1:-}" 2>/dev/null
}
_es_loadavg_1m() {
  [ -n "${HERD_FAKE_LOADAVG:-}" ] && { printf '%s' "$HERD_FAKE_LOADAVG"; return 0; }
  if [ -r /proc/loadavg ]; then awk '{print $1}' /proc/loadavg 2>/dev/null; return 0; fi
  command -v sysctl >/dev/null 2>&1 && { sysctl -n vm.loadavg 2>/dev/null | awk '{print $2}'; return 0; }
  return 0
}
_es_siblings_live() {
  local n=0 f pid
  { [ -n "$cache" ] && [ -d "$cache" ]; } || { printf '0'; return 0; }
  for f in "$cache"/.local-suite-slot-* "$cache"/.capacity-suite-live-*; do
    [ -e "$f" ] || continue
    case "$f" in *.lock) continue ;; esac
    pid="$(sed -n '1p' "$f" 2>/dev/null)"
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    kill -0 "$pid" 2>/dev/null && n=$((n + 1))
  done
  printf '%s' "$n"
}
_es_load_high() {
  _es_on || return 1
  local threshold load siblings
  threshold="${HEALTH_LOAD_THRESHOLD:-4}"
  case "$threshold" in ''|*[!0-9]*) threshold=4 ;; esac
  load="$(_es_loadavg_1m)"
  case "$load" in
    ''|*[!0-9.]*) : ;;
    *) awk -v l="$load" -v t="$threshold" 'BEGIN{exit !(l+0>=t+0)}' </dev/null && return 0 ;;
  esac
  siblings="$(_es_siblings_live)"
  case "$siblings" in ''|*[!0-9]*) siblings=0 ;; esac
  [ "$siblings" -ge 1 ]
}
ES_TEXT="env-suspect · timeout under load · solo re-run queued"
_run "$log"; rc=$?
first="$(sed -n '1p' "$log" 2>/dev/null)"
if [ "$rc" -eq 0 ]; then
  case "$first" in "⚠️"*) line="CLEAN"$'\t'"dataenv" ;; *) line="CLEAN"$'\t'"clean" ;; esac
else
  notok="$(grep -m1 -iE 'not ok' "$log" 2>/dev/null)"; [ -n "$notok" ] || notok="$first"
  if _es_on; then
    es_detail="$(_es_timeout_detail "$notok")"
    if [ -n "$es_detail" ] && _es_load_high; then
      printf '[env-suspect] %s\n' "$ES_TEXT" >> "$log" 2>/dev/null || true
      printf '%s\n' "$es_detail" > "$log.envsuspect" 2>/dev/null || true
    fi
  fi
  _run "$log.retry"; rc2=$?
  if [ "$rc2" -eq 0 ]; then
    rm -f "$log.retry" "$log.retry.progress" 2>/dev/null || true
    d="$(printf '%s' "$notok" | tr '\t\n' '  ')"; line="FLAKY"$'\t'"${d:0:200}"
  else
    mv "$log.retry" "$log" 2>/dev/null || true
    mv "$log.retry.progress" "$log.progress" 2>/dev/null || true
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


# ── gh rate-limit classification (HERD-582) ───────────────────────────────────────────────────────
# The live incident this fixes (2026-08-06 02:06): a GraphQL bucket exhausted after a 50-merge day made
# discover_via_graphql's ``gh`` call exit non-zero. Before this, that CalledProcessError propagated
# straight out of LiveTick.run() to `main`, which is exit-1/fault territory (engine-version.sh:
# herd_engine_live_tick returns 1 on ANY non-zero Python exit) — so a wait-with-a-known-reset rang the
# bash watchdog's fault streak exactly like a genuine engine death, past _ENGINE_FAULT_MAX (3) into a
# loud 'ENGINE DOWN · manual intervention' banner + an operator page. A rate limit is not a fault: it
# is BACKOFF with a published reset time. Two known shapes are reclassified (fail-soft — anything else
# is unparseable and keeps today's genuine-fault behavior verbatim):
#   • GraphQL: the error text names the rate limit (gh's GraphQL client surfaces the API's "rate
#     limit ... exceeded" message on 200-with-errors and on non-zero exits alike).
#   • REST: an HTTP 403 whose response carries ``X-RateLimit-Remaining: 0``.
_RATE_LIMIT_TEXT_RE = re.compile(r"rate limit", re.IGNORECASE)
_RATE_LIMIT_REST_RE = re.compile(r"x-ratelimit-remaining:\s*0", re.IGNORECASE)
_RATE_LIMIT_403_RE = re.compile(r"\b403\b")


def _looks_gh_rate_limited(text):
    """True iff ``text`` (a failed gh call's combined stdout+stderr) carries either rate-limit
    signature (HERD-582): the GraphQL error text, or a REST 403 with a zeroed remaining-quota header.
    Fail-soft — an auth failure, network blip, or malformed query matches neither and keeps the
    genuine-fault path."""
    if not text:
        return False
    if _RATE_LIMIT_TEXT_RE.search(text):
        return True
    return bool(_RATE_LIMIT_REST_RE.search(text) and _RATE_LIMIT_403_RE.search(text))


class GhRateLimited(Exception):
    """Raised by a gh wrapper in place of the underlying ``CalledProcessError`` once its failure is
    classified as a rate limit (HERD-582). ``reset_at`` is the epoch the budget resets (``None`` when
    the cheap follow-up probe itself failed — fail-soft; the caller then applies a default cooldown)."""

    def __init__(self, reset_at=None):
        super().__init__("gh rate limit exceeded")
        self.reset_at = reset_at


def _gh_rate_limit_reset():
    """One cheap REST call (``gh api rate_limit``) for the epoch the exhausted budget resets.
    Best-effort: ANY failure (the probe itself rate-limited, network, parse) returns ``None`` rather
    than raising — a reset-time lookup failing must never itself fault the tick."""
    try:
        out = subprocess.run(["gh", "api", "rate_limit", "-q", ".rate.reset"],
                             capture_output=True, text=True, timeout=10)
        if out.returncode == 0 and out.stdout.strip():
            return int(out.stdout.strip())
    except Exception:
        pass
    return None


def _reraise_gh_failure(exc):
    """Given a failed gh ``CalledProcessError``, raise :class:`GhRateLimited` when its output matches a
    known rate-limit shape, else re-raise ``exc`` unchanged — genuine failures keep the fault path.
    Always raises; never returns."""
    text = "%s\n%s" % (getattr(exc, "stdout", "") or "", getattr(exc, "stderr", "") or "")
    if _looks_gh_rate_limited(text):
        raise GhRateLimited(reset_at=_gh_rate_limit_reset())
    raise exc


# Cushion past GitHub's own reported reset so a fresh tick doesn't race its clock; the fallback when
# the cheap reset probe itself failed (fail-soft — never block backoff on a second gh call succeeding).
_GH_RATE_LIMIT_BUFFER_SECONDS = 30
_GH_RATE_LIMIT_DEFAULT_COOLDOWN_SECONDS = 300


# ── discovery: where candidates come from ─────────────────────────────────────────────────────────

def discover_via_graphql(repo=None, limit=50):
    """Discover open-PR candidates in ONE batched GraphQL round-trip (contract §6, spike §0.3).

    LIVE ONLY — shells out to ``gh api graphql``. Replaces the bash tree's per-PR ``gh`` fan-out with a
    single query for every open PR's number, head sha, base ref, and merge state, so N candidates cost
    ONE request, not N. ``stale`` is derived from ``mergeStateStatus == BEHIND`` (the PR is behind its
    base and must rebuild before it can merge). Raises :class:`GhRateLimited` on a classified rate
    limit (HERD-582 — the caller treats this as BACKOFF, never a fault) or the raw
    ``subprocess.CalledProcessError`` / ``json.JSONDecodeError`` on any other transport/parse failure;
    the ``--tick`` entrypoint catches the latter and returns non-zero so the bash supervisor's fault
    streak still trips for a genuine outage.

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
    try:
        out = subprocess.run(
            ["gh", "api", "graphql", "-f", "query=%s" % query,
             "-F", "owner=%s" % owner, "-F", "name=%s" % name, "-F", "n=%d" % int(limit)],
            capture_output=True, text=True, check=True,
        )
    except subprocess.CalledProcessError as exc:
        _reraise_gh_failure(exc)
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
                 "GATE_STATUS", "GATE_STATUS_PENDING")

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


# ── MERGE_QUEUE — the ordered integration queue / merge train (§6.3, HERD-273) ─────────────────────

def _merge_queue_enabled(config):
    """STRICT validated gate key: an unrecognized/absent ``MERGE_QUEUE`` value is OFF — the safe,
    byte-identical default — never accidentally on from a typo (mirrors ``_merge_result_gate_enabled`` /
    ``_merge_fairness_enabled``).

    ON implies :class:`LiveGates`'s per-slot merge-result verification UNCONDITIONALLY (wired at
    ``LiveGates.__init__``) — the queue's correctness requirement (contract §6.3: "verified against
    the virtual tip") is NOT a second, independently-toggleable config key a project could leave
    mismatched (queue on, verification off). Setting ``MERGE_RESULT_GATE`` explicitly stays supported
    for a project that wants the single-PR gate WITHOUT the queue; setting it ``off`` while
    ``MERGE_QUEUE`` is ``on`` changes nothing — the queue's own requirement already forces the
    verification on, so the two keys can never disagree in a way that matters."""
    val = str((config or {}).get("MERGE_QUEUE", "") or "").strip().lower()
    return val in ("1", "true", "on", "yes", "enable", "enabled")


def _queue_sort_key(pr):
    """The queue's total order key: ascending PR NUMBER — the one stable, collision-free, cross-seat-
    identical order every seat derives with no shared ledger (a PR's number never changes). Numeric
    when possible so ``9`` sorts before ``10`` (plain string order would not); a non-numeric ``pr``
    (a legacy fixture, a non-numeric work-unit id) sorts after every numeric one, deterministically,
    rather than raising."""
    s = str(pr)
    return (0, int(s)) if s.isdigit() else (1, s)


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
    """``(owner, name)`` for the current repo — ``repo`` arg (``owner/name``) else ``gh repo view``
    (REST). A classified rate limit (HERD-582 — e.g. a 403 with ``X-RateLimit-Remaining: 0``) raises
    :class:`GhRateLimited`; any other failure raises the raw ``CalledProcessError`` unchanged."""
    if repo and "/" in repo:
        owner, name = repo.split("/", 1)
        return owner, name
    try:
        out = subprocess.run(
            ["gh", "repo", "view", "--json", "owner,name",
             "-q", "[.owner.login,.name]|@tsv"],
            capture_output=True, text=True, check=True,
        )
    except subprocess.CalledProcessError as exc:
        _reraise_gh_failure(exc)
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


# ── HEALTH_TRUST_BUILDER (HERD-531/555) — sha-matched builder-local health trust, READ side ─────────
# The WRITE side (the provenance record a heavy healthcheck.sh run authors) stays in bash —
# scripts/herd/health-trust.sh, sourced by healthcheck.sh. This is a port of that same library's READ
# side, herd_health_trust_check, into the health dispatch that actually runs today. The bash READ
# (agent-watch.sh:_healthcheck_gate) has been dead code since the P5b port: _healthcheck_gate's only
# caller was never wired into the live pipeline, so builders wrote trust records nobody consulted.
#
# FAIL-CLOSED, identical to health-trust.sh: every disqualifier below is a full heavy re-run, exactly
# as if this trust check did not exist. SHIP-DORMANT: HEALTH_TRUST_BUILDER off (the default) means
# ``_health_trust_on`` is False and :meth:`LiveGates.health` never even opens the record file — zero
# behavior change, byte-identical to before this existed.
#
# FORMAT VERSION 2 (HERD-560): the record grew a leading ``version`` field and a trailing
# ``log_digest`` field (10 fields total, was 8) — see health-trust.sh's header for the full field
# list and the companion ``.health-provenance-log-<sha>`` file the digest is verified against. A
# pre-HERD-560 record (8 fields, no version) or an unrecognized version reads as ABSENT — never an
# error — exactly as if this sha had no record at all. A well-formed record is ALSO refused when
# stale: older than ``HEALTH_TRUST_MAX_AGE_SECS`` (default 21600s / 6h), written before the commit it
# claims to attest existed, or its digest no longer matches the companion log's actual content.

def _health_trust_on(config):
    """Port of ``herd_health_trust_on`` (health-trust.sh) — is HEALTH_TRUST_BUILDER on? An
    unrecognized value reads OFF, so a typo can never arm a path that skips the authoritative suite."""
    val = str((config or {}).get("HEALTH_TRUST_BUILDER", "") or "").strip().lower()
    return val in ("1", "true", "on", "yes", "enable", "enabled")


def _health_trust_abspath(path):
    """Port of ``_herd_health_trust_abspath`` — the PHYSICAL absolute path (mirrors ``cd && pwd -P``),
    so a /tmp pool that resolves to /private/tmp on macOS still compares equal between the bash writer
    and this reader. Fails soft to the raw argument on any resolution error."""
    if not path:
        return ""
    try:
        return os.path.realpath(path)
    except Exception:
        return path


def _health_trust_file(trees, sha):
    """Port of ``herd_health_trust_file`` — the provenance record path for ``sha`` in the ``trees``
    pool, or ``""`` when either argument is empty (never a stub ``/.health-provenance-`` path)."""
    if not trees or not sha:
        return ""
    return os.path.join(trees.rstrip("/"), ".health-provenance-%s" % sha)


def _health_trust_log_file(trees, sha):
    """Port of ``herd_health_trust_log_file`` (HERD-560) — the companion suite-log path a CLEAN
    record's ``log_digest`` is verified against. Same empty-argument contract as
    :func:`_health_trust_file`."""
    if not trees or not sha:
        return ""
    return os.path.join(trees.rstrip("/"), ".health-provenance-log-%s" % sha)


def _health_trust_digest_file(path):
    """sha256 hex digest of ``path``'s content, read as bytes off disk (never a re-quoted string
    round-trip, so a trailing newline can never desync this from the bash writer's own
    ``sha256sum``/``shasum`` hash of the same file). ``""`` on any failure — the caller treats that as
    "no digest" and refuses to trust, never fabricates one."""
    try:
        h = hashlib.sha256()
        with open(path, "rb") as fh:
            for chunk in iter(lambda: fh.read(65536), b""):
                h.update(chunk)
        return h.hexdigest()
    except Exception:
        return ""


# HEALTH_TRUST_MAX_AGE_SECS (HERD-560) — the freshness window's bounded-age default, seconds. Mirrors
# health-trust.sh's own ``${HEALTH_TRUST_MAX_AGE_SECS:-21600}`` fallback so bash and python agree on
# the default with no config-manifest wiring needed (an operator who wants a different bound sets the
# env var directly, the same ad-hoc-override convention HEALTH_TRUST_KEEP_DAYS already uses).
_HEALTH_TRUST_DEFAULT_MAX_AGE_SECS = 21600


def _health_trust_commit_epoch(worktree, sha):
    """The commit time (``%ct``) of ``sha`` as resolved from ``worktree`` — ``""`` on ANY failure (no
    git, unresolvable commit, no worktree), which the caller treats as unresolvable-and-refused,
    mirroring health-trust.sh's own ``git show -s --format=%ct`` call."""
    try:
        out = subprocess.check_output(["git", "-C", worktree, "show", "-s", "--format=%ct", sha],
                                      stderr=subprocess.DEVNULL)
        return out.decode().strip()
    except Exception:
        return ""


def _health_trust_check(trees, sha, worktree):
    """Port of ``herd_health_trust_check`` (health-trust.sh) — is there a record that EARNS a skip of
    the full heavy re-run for this exact ``(sha, worktree)``? Returns ``(provenance, reason)``: a
    non-empty ``provenance`` means TRUSTED; an empty ``provenance`` means NOT trusted and ``reason``
    names the disqualifier (mirrors ``$HERD_HEALTH_TRUST_REASON``). Read-only — never mutates the
    record, never raises; every disqualifier below is a plain full re-run, same as before this
    existed."""
    if not sha:
        return "", "no head sha"
    path = _health_trust_file(trees, sha)
    if not path:
        return "", "no worktree pool"
    if not os.path.isfile(path):
        return "", "no record for sha"
    try:
        with open(path, encoding="utf-8") as fh:
            line = fh.readline().rstrip("\n")
    except Exception:
        return "", "malformed record"
    fields = line.split("\t")
    # OLD-FORMAT (pre-HERD-560, 8 fields, no version) reads as ABSENT — never an error: an engine
    # upgrade must never turn a stale-format leftover into a red gate, only into a plain full re-run,
    # exactly as if this sha had no record at all.
    if len(fields) == 8:
        return "", "old-format record (absent)"
    # A truncated/garbled/interrupted-write record proves nothing — refuse it rather than guessing at
    # whichever fields happen to be present (mirrors the bash reader's own $_ht_epoch emptiness check).
    if len(fields) != 10:
        return "", "malformed record"
    (version, r_sha, r_wt, r_prof, r_out, _r_dur, r_prov, r_state, r_epoch, r_digest) = fields
    if not r_epoch or not r_epoch.isdigit():
        return "", "malformed record"
    # An unrecognized version (a FUTURE format this engine build predates) reads as ABSENT too — the
    # same fail-soft-toward-full-re-run rule as an old-format record, never an error.
    if version != "2":
        return "", "old-format record (absent)"
    # STALE SHA: the record must name the very commit being gated.
    if r_sha != sha:
        return "", "stale sha in record"
    if r_prof != "heavy":
        return "", "profile=%s (not heavy)" % r_prof
    if r_out != "CLEAN":
        return "", "outcome=%s (not CLEAN)" % r_out
    # provenance=watcher would let a trusted (light) run justify the NEXT trusted run — trust must
    # always trace back to a real builder-local heavy suite, never compound on itself.
    if r_prov != "builder-local":
        return "", "provenance=%s (not builder-local)" % r_prov
    if r_state != "clean":
        return "", "tree_state=%s (uncommitted edits at run time)" % r_state
    if worktree:
        wt_abs = _health_trust_abspath(worktree)
        if r_wt != wt_abs:
            return "", "record worktree %s != %s" % (r_wt, wt_abs)
    # FRESHNESS WINDOW, part 1 — BOUNDED AGE (HERD-560): a record older than
    # HEALTH_TRUST_MAX_AGE_SECS (default 21600s / 6h) cannot be trusted no matter how clean its
    # outcome — the world may have moved on since (a dependency bump, a config drift landing on
    # default) that only a fresh suite run would see. 0/negative disables the bound (unlimited,
    # pre-HERD-560 behavior); a non-numeric override falls back to the default.
    max_age = os.environ.get("HEALTH_TRUST_MAX_AGE_SECS", "")
    try:
        max_age = int(max_age)
    except (TypeError, ValueError):
        max_age = _HEALTH_TRUST_DEFAULT_MAX_AGE_SECS
    if max_age > 0:
        now = int(_now_epoch())
        if now - int(r_epoch) > max_age:
            return "", "record older than %ss (stale by age)" % max_age
    # FRESHNESS WINDOW, part 2 — RECORD PREDATES THE BRANCH'S NEWEST PUSH: a record written BEFORE
    # the commit existed cannot have tested it (a recycled path, a clock skew, a hand-forged file).
    # An unresolvable commit is refused too.
    ct = _health_trust_commit_epoch(worktree or r_wt, sha)
    if not ct or not ct.isdigit():
        return "", "commit time unresolvable"
    if int(r_epoch) < int(ct):
        return "", "record predates the commit"
    # DIGEST (HERD-560): the record's claimed suite-log digest must match the companion log file's
    # ACTUAL content. A missing/unreadable log, or one that no longer hashes to what was recorded,
    # proves nothing and is refused exactly like every disqualifier above — no signing, so this
    # catches a corrupted/truncated/swapped log, never a deliberately forged one (the threat model is
    # staleness, not forgery; see the header).
    if not r_digest or r_digest == "-":
        return "", "no suite log for record"
    log_path = _health_trust_log_file(trees, sha)
    if not log_path or not os.path.isfile(log_path):
        return "", "no suite log for record"
    actual = _health_trust_digest_file(log_path)
    if not actual or actual != r_digest:
        return "", "digest mismatch"
    return r_prov, ""


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
        # HERD-559: the review fast path (pre-gate, tier, floor, latency) resolves its levers per
        # candidate, not once per tick — the levers are cheap string reads and keeping the dict is
        # what lets `_review_tier` stay a pure function of (config, diff).
        self.config = cfg
        self._health_max = _pos_int(cfg.get("HEALTH_CONCURRENCY"), 1)
        self._review_max = _pos_int(cfg.get("REVIEW_CONCURRENCY"), 2)
        # HERD-373: a LiveGates instance is constructed fresh once per tick (_run_live_tick), so
        # memoizing here is tick-scoped for free — never persisted, a new tick always re-evaluates.
        self._main_health_pending_cache = None
        # MERGE_RESULT_GATE (§6.4, HERD-296): ship-dormant, default off. Resolved ONCE per tick (a
        # LiveGates instance lives exactly one tick) so `health()` branches on a plain bool, never a
        # re-parsed env lookup per candidate. MERGE_QUEUE (§6.3, HERD-273) implies the SAME
        # verification unconditionally — see _merge_queue_enabled's docstring for why the queue is
        # never a "set two config keys coherently" trap.
        self._merge_result_gate = _merge_result_gate_enabled(cfg) or _merge_queue_enabled(cfg)
        # HEALTH_TRUST_BUILDER (HERD-531/555): ship-dormant, default off. Resolved ONCE per tick, same
        # rationale as _merge_result_gate above — off means health() never even opens a provenance file.
        self._health_trust_on = _health_trust_on(cfg)
        # WATCH_CLAUDE_PROBE_TIMEOUT (HERD-108/HERD-580): the exec-hang probe result, memoized on `self`
        # for the same reason as `_main_health_pending_cache` below — a LiveGates instance lives exactly
        # one tick, so at most ONE `claude --version` exec happens per tick no matter how many
        # candidates would otherwise dispatch a reviewer this round.
        self._claude_hang_cache = None

    def _script(self, name):
        return os.path.join(self.home, "scripts", "herd", name)

    def _claude_hang_memo(self):
        if self._claude_hang_cache is None:
            self._claude_hang_cache = _claude_exec_hung(self.state, self.config, self.journal)
        return self._claude_hang_cache

    def _main_health_pending_memo(self, state_dir):
        """Memoized ``_main_health_pending(state_dir)`` — ONE ``rev-parse`` per tick, not one per
        PR-health candidate (HERD-373). Cached on ``self`` because a LiveGates instance lives exactly
        one tick (a fresh instance is constructed per ``--tick`` invocation, ``_run_live_tick``) — the
        cache is never persisted and a new tick always re-evaluates."""
        if self._main_health_pending_cache is None:
            self._main_health_pending_cache = _main_health_pending(state_dir)
        return self._main_health_pending_cache

    def _collect_env_suspect(self, cand, log_path):
        """HERD-567: the python-side half of the env-suspect port — reads the ``<log>.envsuspect``
        side-channel _HEALTH_WORKER_SH drops the moment it classifies a run-1 timeout as env-suspect
        (see that string's own docstring for why a side channel, not the log itself, carries this to
        the collector), journals ``health_env_suspect`` (mirroring agent-watch.sh's ``_health_worker``
        ``journal_append health_env_suspect dir … detail …``), and removes the marker either way. A
        no-op — no journal line — whenever the marker is absent: every OTHER dispatch (the lever off,
        or on but never classified) never even opens the file. Called once per terminal collect, right
        alongside ``record_health_result`` / ``record_merge_result_verdict``."""
        if not log_path:
            return
        marker = log_path + ".envsuspect"
        try:
            with open(marker, encoding="utf-8") as fh:
                detail = fh.readline().strip()
        except OSError:
            return
        try:
            os.remove(marker)
        except OSError:
            pass
        dir_name = os.path.basename(cand.worktree) if cand.worktree else cand.slug
        self.journal.append("health_env_suspect", "dir", dir_name, "detail", detail)

    # ── health rail ────────────────────────────────────────────────────────────────────────────────
    def health(self, cand):
        # MERGE_RESULT_GATE (§6.4, HERD-296): ON diverts the ENTIRE health rail to the merge-result
        # path below — the suite runs against the materialized (head + base) tree instead of the
        # branch as-is, so there is exactly ONE suite run per candidate, never a doubled gate latency
        # (spike §2 cleanup note). OFF (default) never reaches `_merge_result_health` — byte-identical.
        if self._merge_result_gate:
            return self._merge_result_health(cand)
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
                    # CHAOS SEAM (mid_gate_collect, HERD-425): the async worker's terminal verdict is
                    # already durable on disk (the dispatch out-file, nonce-matched) — a hard death here
                    # models "the suite finished, the watcher died before recording/caching it." The
                    # dispatch + in-flight scratch files are UNTOUCHED at this point, so the next tick's
                    # step-2 collect re-reads this exact same out-file and completes the record+rm in one
                    # shot — no re-dispatch of the underlying suite, no lost result.
                    _chaos_kill("mid_gate_collect")
                    self._collect_env_suspect(cand, st.health_log_file(cand))
                    st.record_health_result(cand, verdict, detail)
                    # HERD-576 leg 2: stamp the gate-config generation ALONGSIDE the verdict this
                    # exact tick observed it under, so a later tick can tell whether the operator has
                    # since released a changed gate posture — see gate_config_generation's docstring.
                    st.record_health_generation(cand, D.gate_config_generation(self.config))
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
        _hc_n = _total_health_inflight(st.dir)
        # HERD-359: if the default-branch sha is unverified and not yet in-flight, reserve one slot
        # so bash's reconcile_main_health (Phase C) always finds capacity within the same tick.
        # With HEALTH_CONCURRENCY=1 this collapses the effective limit to 0 — no new PR health suite
        # starts until main-health is dispatched. Fail-safe: _main_health_pending returns False on
        # any env error (missing MAIN, no git, etc.) so a misconfigured seat never blocks the PR rail.
        _effective_max = self._health_max - (1 if self._main_health_pending_memo(st.dir) else 0)
        if _hc_n >= _effective_max:
            # HERD-459: once per (pr, sha, phase) — see the health_pending guard in LiveTick._walk.
            # "queued behind a full slot budget" is a standing condition, not a per-tick event.
            if st.once(cand.pr, cand.sha, "health_queued"):
                self.journal.append("health_queued", "pr", cand.pr, "sha", cand.sha, "slug", cand.slug,
                                    "inflight", _hc_n, "limit", self._health_max)
            return WAIT
        # 4. SHA-MATCHED BUILDER-LOCAL TRUST (HERD-531/555): before paying for a ~20-60 min heavy suite,
        #    ask whether this EXACT head sha was already proven clean by the builder's own pre-PR heavy
        #    run in this very worktree (see _health_trust_check above). When it was, dispatch the LIGHT
        #    profile as a smoke instead of the full re-run — the suite that matters already ran, on the
        #    same commit, from the same clean tree. Every other case (lever off, no record, stale sha,
        #    non-clean outcome, dirty tree, a record older than the commit, or a record the watcher
        #    itself authored) leaves ``profile`` empty and dispatches the full suite exactly as before.
        #    The verdict/ledger/cache machinery is untouched either way: a trusted dispatch still
        #    produces a real CLEAN/FLAKY/CODEERROR verdict from a real run, so a smoke that reds still
        #    blocks the merge. Byte-identical when HEALTH_TRUST_BUILDER is off: ``_health_trust_check``
        #    is never even called.
        profile = ""
        if self._health_trust_on:
            prov, _reason = _health_trust_check(st.dir, cand.sha, cand.worktree)
            if prov:
                profile = "--light"
                self.journal.append("health_trusted", "pr", cand.pr, "slug", cand.slug, "sha", cand.sha,
                                    "provenance", prov, "profile", "light")
        # 5. DISPATCH the async suite worker + lay the marker → wait.
        self._dispatch_health(cand, profile)
        return WAIT

    def _dispatch_health(self, cand, profile=""):
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
        argv = ["bash", "-c", _HEALTH_WORKER_SH, "_",
                self._script("healthcheck.sh"), cand.worktree, disp, log, base, st.dir or "", nonce]
        # HERD-531/555 <profile>: an OPTIONAL 8th arg, "--light" ONLY when the trust check above
        # trusted this exact (sha, worktree) — see _HEALTH_WORKER_SH. Omitted (byte-identical argv) on
        # every untrusted dispatch, mirroring the bash worker's own optional 4th positional.
        if profile:
            argv.append(profile)
        try:
            proc = subprocess.Popen(
                argv, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True,
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

    # ── merge-result gate (§6.4, HERD-296) — the whole health rail, retargeted at head+base ────────
    def _merge_result_health(self, cand):
        """The health rail under ``MERGE_RESULT_GATE=on``: before gating, materialize the candidate
        tree — the PR's exact head sha merged with the CURRENT default-branch tip — and run the suite
        against THAT, never the branch as-is (spike §2). Same async dispatch/collect/in-flight shape as
        the classic rail above (:meth:`health`), so refix/bounce, concurrency and supersession all reuse
        their existing machinery unchanged; only the substrate namespace and the cache key (``pr, sha,
        base`` — a base move is a cache miss, i.e. the base moving RE-ARMS the gate) differ. A real merge
        conflict is reported as the sentinel ``"CONFLICT"`` (never a cached verdict, never a rail BLOCK)
        — the caller (:meth:`LiveTick._walk`) folds that into the existing honest hold path, resolver-owned.
        """
        st = self.state
        self.reused_health = False
        base_sha = _resolve_default_branch_sha()
        if not base_sha:
            # Fail-soft: cannot resolve what to merge against — hold and retry, never gate un-based and
            # never silently fall through to the classic (un-gated) branch-as-is suite.
            self.journal.append("dispatch_refused", "pr", cand.pr, "sha", cand.sha, "slug", cand.slug,
                                "rail", "merge_result", "reason", "base-unresolved")
            return WAIT
        # 1. REUSE: this EXACT (head, base) pair already has a terminal verdict.
        cached = st.merge_result_verdict(cand.pr, cand.sha, base_sha)
        if cached:
            self.reused_health = True
            return cached
        disp = st.merge_result_dispatch_file(cand.pr, cand.sha)
        inflight = st.merge_result_inflight_file(cand.pr, cand.sha)
        tree = st.merge_result_tree_path(cand.pr, cand.sha)
        # 2. COLLECT a finished worker's terminal verdict (same freshness-guard discipline as classic
        #    health: only a nonce-matched out-file is ever trusted, HERD-349).
        if disp and os.path.exists(disp):
            try:
                with open(disp, encoding="utf-8") as fh:
                    first = fh.readline().rstrip("\n")
            except Exception:
                first = ""
            nonce, _, rest = first.partition("\t")
            expected = _marker_nonce(inflight)
            if not expected or nonce != expected:
                self.journal.append("stale_result_ignored", "pr", cand.pr, "sha", cand.sha,
                                    "slug", cand.slug, "rail", "merge_result", "nonce", nonce or "",
                                    "expected", expected or "")
                st.rm(disp)
            else:
                tested_base = _nonce_base(nonce) or base_sha
                verdict, _, detail = rest.partition("\t")
                if verdict in ("CLEAN", "FLAKY", "CODEERROR"):
                    self._collect_env_suspect(cand, st.merge_result_log_file(cand.pr, cand.sha))
                    st.record_merge_result_verdict(cand.pr, cand.sha, tested_base, verdict, detail)
                    st.rm(disp, inflight)
                    _remove_merge_tree(cand.worktree, tree)
                    self.journal.append("merge_result_gate", "pr", cand.pr, "sha", cand.sha,
                                        "slug", cand.slug, "base", tested_base, "verdict", verdict)
                    return verdict
                st.rm(disp)
                return WAIT
        # 3. IN FLIGHT: a live worker already materializing/testing this exact head sha → wait.
        if inflight and _marker_live(inflight):
            return WAIT
        # 3.5 same pre-dispatch worktree validation as the classic rail (task HERD-346) — the source
        #     worktree the materialize step reads from must actually be there.
        if cand.worktree and not _is_worktree(cand.worktree):
            self.journal.append("dispatch_refused", "pr", cand.pr, "sha", cand.sha, "slug", cand.slug,
                                "rail", "merge_result", "reason", "no-worktree", "worktree", cand.worktree)
            return WAIT
        # 3.7 same concurrency slot check as the classic rail, over the COMBINED count (spike cleanup
        #     note: 'respect HEALTH_CONCURRENCY') — a merge-result suite and a classic suite are never
        #     dispatched past the same shared-object-store budget.
        _hc_n = _total_health_inflight(st.dir)
        _effective_max = self._health_max - (1 if self._main_health_pending_memo(st.dir) else 0)
        if _hc_n >= _effective_max:
            # HERD-459: once per (pr, sha, phase) — the SAME marker the classic rail's slot check uses,
            # so a candidate that queues on both rails for one sha still journals `health_queued` once.
            if st.once(cand.pr, cand.sha, "health_queued"):
                self.journal.append("health_queued", "pr", cand.pr, "sha", cand.sha, "slug", cand.slug,
                                    "inflight", _hc_n, "limit", self._health_max)
            return WAIT
        # 4. MATERIALIZE + DISPATCH.
        return self._dispatch_merge_result(cand, base_sha)

    def _dispatch_merge_result(self, cand, base_sha):
        st = self.state
        disp = st.merge_result_dispatch_file(cand.pr, cand.sha)
        inflight = st.merge_result_inflight_file(cand.pr, cand.sha)
        log = st.merge_result_log_file(cand.pr, cand.sha)
        tree = st.merge_result_tree_path(cand.pr, cand.sha)
        if not disp or not tree:
            return WAIT
        st.rm(disp)
        ok, detail = _materialize_merge_tree(cand.worktree, cand.sha, base_sha, tree)
        if not ok:
            # A real conflict (or a materialize fault) — resolver-owned, fail soft into the honest hold
            # path (never a cached verdict, never a rail BLOCK/bounce). The caller folds this into HOLD.
            self.journal.append("merge_result_conflict", "pr", cand.pr, "sha", cand.sha,
                                "slug", cand.slug, "base", base_sha, "detail", detail)
            return "CONFLICT"
        nonce = _dispatch_nonce_with_base(base_sha)
        main_dir = os.environ.get("MAIN") or os.environ.get("PROJECT_ROOT") or ""
        try:
            proc = subprocess.Popen(
                ["bash", "-c", _HEALTH_WORKER_SH, "_",
                 self._script("healthcheck.sh"), tree, disp, log, main_dir, st.dir or "", nonce],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True,
            )
        except Exception as exc:
            _remove_merge_tree(cand.worktree, tree)
            self.journal.append("infra_event", "pr", cand.pr, "sha", cand.sha, "rail", "merge_result",
                                "detail", "merge-result dispatch failed: %s" % str(exc)[:160])
            return WAIT
        _marker_write(inflight, proc.pid, nonce=nonce)
        self.journal.append("merge_result_gate_dispatched", "pr", cand.pr, "slug", cand.slug,
                            "sha", cand.sha, "base", base_sha, "pid", proc.pid, "log_path", log or "")
        return WAIT

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
            # REVIEW LATENCY TELEMETRY (HERD-559 leg 3) — dispatch→verdict wall-clock, read from the
            # inflight marker BEFORE the scratch is dropped below. The fast path exists because review
            # wall-clock is the pipeline's ceiling, so measure it rather than estimate it: one event
            # per collected verdict, carrying the seconds and the verdict that produced them. Pure
            # telemetry — no gate, dispatch or merge decision reads it. REVIEW_LATENCY=off is a hard
            # no-op. Emitted for an INFRA collect too: a reviewer that burned four minutes and died
            # without a verdict is part of the ceiling, and hiding it would flatter the measurement.
            if (self.config.get("REVIEW_LATENCY") or "on") != "off":
                elapsed = _marker_age(inflight) if inflight else None
                if elapsed is not None and elapsed >= 0:
                    self.journal.append("review_latency", "pr", cand.pr, "sha", cand.sha,
                                        "slug", cand.slug, "secs", elapsed, "verdict", verdict)
            if verdict in ("PASS", "BLOCK"):
                # HERD-473: a BLOCK carries the reviewer's STRUCTURED reason into the ledger row, in the
                # same write that records the verdict — so the reason can never exist without its verdict
                # or outlive it. A PASS, or a BLOCK whose line carried no parseable payload, yields ""
                # and the row is written exactly as it was before this field existed. Parsing is a
                # SECOND, independent pass over the same text (like parse_rubric_verdicts): it can never
                # change the verdict decided above, and it never raises.
                st.record_review(cand.pr, cand.sha, verdict, "reviewer",
                                 parse_block_reason(text) if verdict == "BLOCK" else "")
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
        # 2.5 DELTA-SCOPED REVIEW carry-forward (HERD-204, ship-dormant via DELTA_REVIEW; HERD-580
        #     port). Before spending a reviewer on this new sha, try to PROVE it differs from this PR's
        #     last-passed sha ONLY by a merge of DEFAULT_BRANCH (a pure integration push). If proven,
        #     the prior PASS is carried forward and no reviewer is dispatched. Placed BELOW the
        #     in-flight checks (a review already running still finishes and its verdict is recorded)
        #     and ABOVE the pre-gate/tier/concurrency below, so a carry consumes no reviewer slot and no
        #     mechanical lint pass. Byte-inert when DELTA_REVIEW is off.
        if _maybe_carry_forward_review(cand, st, self.config, self.journal):
            return "PASS"
        # 3.5 CONCURRENCY SLOT CHECK (REVIEW_CONCURRENCY, default 2): never dispatch when the global
        #     in-flight reviewer count reaches the limit (mirrors bash's ``_count_live_reviews >= _review_conc``
        #     QUEUED path, agent-watch.sh:3115). Dead markers are not counted — a crashed reviewer never
        #     wedges a slot (``_count_live_reviews``, agent-watch.sh:2455).
        # 3.6 MECHANICAL-RED PRE-GATE (HERD-559 leg 1, REVIEW_PREGATE=on; ship-dormant). The cheap
        #     deterministic lint set runs BEFORE a reviewer is spawned, so a mechanical red — a
        #     caps-sync miss, a pipe-safety miss, a doc-drift miss — costs zero model time instead of a
        #     full adversarial pass. Placed ABOVE the concurrency check on purpose: a pre-gate red must
        #     never queue behind in-flight reviews, because it is not going to use a slot at all.
        #     Recorded as a real sha-keyed BLOCK with provenance `pregate` (distinct from `reviewer` —
        #     a deterministic lint refusal is not a model's correctness finding) so the refix bounce,
        #     the merge decision and `herd approve why` all work unchanged.
        pregate = self._review_pregate(cand)
        if pregate is not None:
            st.record_review(cand.pr, cand.sha, "BLOCK", "pregate", pregate["reason"])
            self.journal.append("review_pregate_red", "pr", cand.pr, "sha", cand.sha, "slug", cand.slug,
                                "lints", pregate["lints"],
                                "reason", "mechanical lint red — review dispatch skipped, no slot burned")
            return "BLOCK"
        _rv_n = _count_live_inflight(st.dir, ".review-inflight")
        if _rv_n >= self._review_max:
            self.journal.append("review_queued", "pr", cand.pr, "sha", cand.sha, "slug", cand.slug,
                                "inflight", _rv_n, "limit", self._review_max)
            return WAIT
        # 3.7 RISK-TIER (HERD-559 leg 2, REVIEW_TIERING=on; ship-dormant). Chooses the reviewer MODEL
        #     for this diff — or, for a docs/test-only diff, skips the reviewer outright with a
        #     sha-keyed low-risk PASS. Decided AFTER the concurrency check because a dispatched review
        #     is what the tier is FOR; a SKIP short-circuits before any dispatch either way.
        tier, model = self._review_tier(cand)
        if tier == "SKIP":
            st.record_review(cand.pr, cand.sha, "PASS", "skipped-low-risk", "")
            self.journal.append("review_skipped", "pr", cand.pr, "sha", cand.sha,
                                "reason", "docs/test-only low-risk diff")
            return "PASS"
        # WATCH_CLAUDE_PROBE_TIMEOUT (HERD-108, HERD-580 port; ship-dormant): a wedged `claude` binary
        # would spawn a corpse reviewer that never returns a verdict — hold dispatch instead of feeding
        # it one. Checked BEFORE the escalation-arm consumption below (memoized once per tick): a HUNG
        # tick must return WAIT WITHOUT touching the one-shot arm marker, so an escalation armed by a
        # fresh refix bounce survives intact to the recovery tick instead of being silently spent on a
        # dispatch that never happened (a transient hang must not downgrade the NEXT review back to the
        # cheap/default tier — the very model that already missed the issue across >=2 refix rounds).
        if self._claude_hang_memo() == "HUNG":
            esc_file = st.review_escalate_file(cand.pr)
            if esc_file and os.path.exists(esc_file):
                self.journal.append("review_escalation_held", "pr", cand.pr, "sha", cand.sha,
                                    "slug", cand.slug,
                                    "reason", "claude exec-hang held dispatch — escalation arm "
                                              "preserved for the recovery tick")
            return WAIT
        # EVIDENCE-TRIGGERED ESCALATION (REVIEW_MODEL_ESCALATED / REVIEW_EVIDENCE_ESCALATE_ROUNDS,
        # HERD-580 port): if a builder's refix rounds proved the cheap reviewer missed the real issue on
        # this PR (armed by LiveTick._maybe_arm_review_escalation right after a fresh review-BLOCK
        # bounce), force this NEXT dispatch up to the Opus tier, overriding whatever tier the risk
        # classification chose — even the default/STRONG empty-model path. One-shot: consumed here, and
        # ONLY when actually dispatching — both the concurrency check and the hang probe above already
        # passed, so neither a QUEUED nor a HUNG tick ever reaches this line and the arm survives intact
        # to a later tick with a free slot / a responsive claude.
        esc_file = st.review_escalate_file(cand.pr)
        if esc_file and os.path.exists(esc_file):
            model = self.config.get("REVIEW_MODEL_ESCALATED") or "claude-opus-4-8"
            try:
                os.remove(esc_file)
            except OSError:
                pass
            self.journal.append("review_escalated", "pr", cand.pr, "sha", cand.sha, "model", model,
                                "reason", "cheap reviewer missed the issue across refix rounds")
        # 4. DISPATCH the reviewer async + lay the marker → wait.
        self._dispatch_review(cand, model)
        return WAIT

    # ── HERD-559 review fast path ─────────────────────────────────────────────────────────────────
    def _pregate_script(self):
        """``scripts/herd/review-pregate.sh`` — the ONE implementation of the mechanical lint set and
        the mechanical-diff classifier, shared verbatim with ``agent-watch.sh`` and ``herd-review.sh``
        so the three call sites can never disagree about what is mechanically red or mechanically
        shaped. Invoked as a SUBPROCESS: its lint bodies are read from the TREE UNDER TEST, and
        builder-authored code must never be imported into the engine core."""
        return self._script("review-pregate.sh")

    def _review_pregate(self, cand):
        """Run the mechanical pre-gate for this candidate.

        Returns ``None`` when the reviewer should proceed (lever off, no worktree, the script absent,
        the diff clean, or the pre-gate could not attribute its findings) and a
        ``{"lints", "reason", "findings"}`` dict when this diff introduced a mechanical red.

        The rc contract is the shared script's: 0 clean · 1 red (findings on stdout) · 2 skipped.
        **2 is treated exactly like 0**, deliberately: the script skips when it cannot compute the
        merge base it subtracts pre-existing findings against, and bouncing a builder onto a red it
        cannot fix inside its own item would wedge the PR. A pre-gate that is not sure must let the
        reviewer run — fail-soft always beats false-red."""
        if (self.config.get("REVIEW_PREGATE") or "off") != "on":
            return None
        script = self._pregate_script()
        tree = cand.worktree or ""
        if not script or not os.path.exists(script) or not tree or not os.path.isdir(tree):
            return None
        base = self.config.get("DEFAULT_BRANCH") or os.environ.get("DEFAULT_BRANCH") or "main"
        try:
            out = subprocess.run(["bash", script, "lint", tree, base],
                                 capture_output=True, text=True, timeout=_PREGATE_TIMEOUT)
        except Exception:
            return None                      # a timeout or a spawn failure is never a finding
        if out.returncode != 1:
            return None
        findings = (out.stdout or "").strip()
        if not findings:
            return None                      # rc 1 with no output would be an unattributable red
        lints = ",".join(sorted(set(
            line.split(":", 1)[0][len("PREGATE "):].strip()
            for line in findings.splitlines() if line.startswith("PREGATE "))))
        return {"lints": lints or "mechanical",
                "reason": "mechanical lint red (%s) — no reviewer dispatched" % (lints or "mechanical"),
                "findings": findings}

    def _review_tier(self, cand):
        """``(tier, model)`` for this candidate's diff — the risk-tier classification, ported from
        ``work-units/git-pr.sh:_classify_review_tier`` and gated behind ``REVIEW_TIERING=on``.

        WHY IT IS GATED rather than simply matching bash: the P5 engine port never carried the tiering
        across, so on the live core every PR has been dispatching ``$MODEL_REVIEW`` regardless of
        ``REVIEW_ESCALATE_GLOB`` / ``DOCS_ONLY_GLOB``. Restoring it silently would change, on the next
        engine upgrade, WHICH model reviews a PR and whether a docs-only diff is reviewed at all —
        an operator's call, never an upgrade's side effect. Off (the default) returns
        ``("STRONG", "")``: no ``gh`` call, no classification, byte-identical dispatch.

        Fails SAFE in one direction only, exactly as the bash original: any uncertainty (unreadable or
        empty diff) is STRONG, never a downgrade, and an escalate-glob or over-size match wins over
        every cheaper tier."""
        if (self.config.get("REVIEW_TIERING") or "off") != "on":
            return "STRONG", ""
        escalate = self.config.get("REVIEW_ESCALATE_GLOB") or ""
        docs_only = self.config.get("DOCS_ONLY_GLOB") or ""
        floor_on = (self.config.get("REVIEW_MECH_FLOOR") or "off") == "on"
        if not escalate and not docs_only and not floor_on:
            return "STRONG", ""
        paths = self._review_diff_paths(cand)
        if not paths:
            return "STRONG", ""              # unreadable/empty diff → never downgrade blind
        # DOCS/TEST-ONLY: every changed path is a *.md doc or under tests/ → skip the review entirely.
        if all(p.endswith(".md") or p.startswith("tests/") for p in paths):
            return "SKIP", ""
        # ESCALATION WINS — the glob and the size checks run before every cheaper tier.
        if escalate:
            rx = _review_glob(escalate)
            if rx is None or any(rx.search(p) for p in paths):
                # An unparseable SAFETY glob fails to STRONG: an operator who pinned engine paths into
                # it must never get a cheaper reviewer because of a typo in the pattern.
                return "STRONG", ""
        if len(paths) > _pos_int(self.config.get("REVIEW_ESCALATE_MAXFILES"), 10):
            return "STRONG", ""
        if docs_only:
            rx = _review_glob(docs_only)
            # An unparseable DOCS glob simply does not downgrade (it is an opt-IN to a cheaper tier,
            # not a safety net), so it falls through to the tiers below rather than forcing STRONG.
            if rx is not None and all(rx.search(p) for p in paths):
                return "DOCS", self.config.get("REVIEW_MODEL_DOCS") or ""
        if escalate or docs_only:
            return "CHEAP", self.config.get("REVIEW_MODEL_CHEAP") or ""
        # No operator glob is configured, so the tier so far is the STRONG default. The FLOOR is the
        # only thing that may lower it, and only for a diff the shared classifier positively
        # recognizes as mechanical (a TSV row edit, a pure rename, a version bump).
        if floor_on and self._review_mech_floor(cand):
            self.journal.append("review_tier_floor", "pr", cand.pr, "sha", cand.sha,
                                "model", self.config.get("REVIEW_MODEL_CHEAP") or "",
                                "reason", "small mechanical diff (TSV row / rename / version bump)"
                                          " — floored to the cheap tier")
            return "CHEAP", self.config.get("REVIEW_MODEL_CHEAP") or ""
        return "STRONG", ""

    def _review_mech_floor(self, cand):
        """True iff the shared classifier recognizes this worktree's diff as small + mechanical
        (rc 0). Every other rc — not mechanical (1), undecidable (2), missing script, timeout — is
        False, so the floor can only ever fire on a POSITIVE recognition."""
        script = self._pregate_script()
        tree = cand.worktree or ""
        if not script or not os.path.exists(script) or not tree or not os.path.isdir(tree):
            return False
        base = self.config.get("DEFAULT_BRANCH") or os.environ.get("DEFAULT_BRANCH") or "main"
        try:
            out = subprocess.run(["bash", script, "floor", tree, base],
                                 capture_output=True, text=True, timeout=_PREGATE_TIMEOUT)
        except Exception:
            return False
        return out.returncode == 0

    def _review_diff_paths(self, cand):
        """This PR's changed-file paths (``gh pr diff --name-only``) — the classifier's only input.
        Empty on ANY failure, which the caller reads as "do not downgrade"."""
        try:
            out = subprocess.run(["gh", "pr", "diff", str(cand.pr), "--name-only"],
                                 capture_output=True, text=True, timeout=_PREGATE_TIMEOUT)
        except Exception:
            return []
        if out.returncode != 0:
            return []
        return [ln.strip() for ln in (out.stdout or "").splitlines() if ln.strip()]

    def _dispatch_review(self, cand, tier_model=""):
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
        # HERD-559: the risk TIER's chosen model, when the classifier picked one, is resolved FIRST —
        # it is a per-diff decision that must beat the per-project default, exactly as bash's
        # `_dispatch_review <model>` argument does. An EMPTY tier_model (the default, and always so
        # while REVIEW_TIERING is off) leaves this chain byte-identical to before: the operator's
        # HERD_REVIEW_MODEL override, else MODEL_REVIEW. Whatever wins is pinned into the reviewer's
        # env, so `review_dispatched.model` can still never diverge from what actually ran.
        model = tier_model or env.get("HERD_REVIEW_MODEL") or env.get("MODEL_REVIEW") or ""
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


# HERD-559: one bound for every review-fast-path subprocess (the shared lint set, the mechanical-diff
# classifier, the classifier's `gh pr diff`). Generous enough for the pre-gate's two-pass baseline
# subtraction on a large tree, hard enough that a hung git/gh costs at most one tick — the same
# "bounded so a stuck call never hangs the tick" rule as _HV_BODY_TIMEOUT / _HOLD_COMMENT_TIMEOUT.
_PREGATE_TIMEOUT = 120


def _review_glob(pattern):
    """Compile one of the review-tiering egrep keys, or ``None`` when it does not compile.

    ``re.search`` semantics at every call site, never ``re.match``: these keys are documented and used
    as UNANCHORED egrep patterns — this repo's own ``DOCS_ONLY_GLOB="[.](md|txt)"`` is a suffix
    pattern a prefix-anchored match could never satisfy (``work_unit.py`` records the two rounds of
    review that established this).

    ``None`` for an unparseable pattern is deliberately NOT "matches nothing": the caller must decide,
    per key, which way an unusable pattern fails. For ``REVIEW_ESCALATE_GLOB`` — a SAFETY glob whose
    whole job is to force the strong tier — silently treating it as "matched nothing" would let the
    very paths the operator pinned fall through to a cheaper reviewer, so the caller fails to STRONG."""
    try:
        return re.compile(pattern)
    except re.error:
        return None


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


# Per-field cap on a parsed BLOCK reason — the SAME 200-char cap agent-watch.sh's ``_parse_block_fields``
# applies, so one pathological reviewer line can never bloat a ledger row, a journal event, or a comment.
_BLOCK_FIELD_CAP = 200
_BLOCK_FIELD_ORDER = ("rule", "why", "location")


def parse_block_fields(text):
    """The LAST ``REVIEW: BLOCK`` line's structured fields → ``{"rule", "why", "location"}`` (HERD-473).

    herd-review.sh's BLOCK contract is ``REVIEW: BLOCK — rule: <rule> | why: <why> | location: <loc>``.
    This is the PYTHON twin of agent-watch.sh's ``_parse_block_fields`` (:2564) and follows it rule for
    rule: the payload is everything after the em-dash separator, split on ``' | '``; each segment is
    classified by an explicit ``rule:``/``why:``/``location:`` key (case-insensitive); the FIRST unkeyed
    segment falls back to ``why`` so a LEGACY freeform ``REVIEW: BLOCK — <reason>`` still yields one.
    Values are whitespace-collapsed (the ledger row is space-delimited, so a reason may carry no newline
    or tab) and capped at :data:`_BLOCK_FIELD_CAP`.

    Pure and TOTAL: a PASS/INFRA text, an absent BLOCK line, or an empty payload returns ``{}`` — never
    an exception, so a caller collecting a verdict can never be killed by an unparseable reason.
    """
    line = ""
    for raw in text.splitlines():
        s = raw.strip()
        if not s.upper().startswith("REVIEW:"):
            continue
        if s.split(":", 1)[1].strip().upper().startswith("BLOCK"):
            line = s                       # LAST BLOCK line wins, mirroring parse_review_verdict
    if not line:
        return {}
    if "—" in line:
        payload = line.split("—", 1)[1]        # text after the em-dash separator
    else:
        payload = line.split(":", 1)[1].strip()[len("BLOCK"):]   # no separator → tail after the tag
    out = {}
    for seg in payload.split(" | "):
        key, sep, rest = seg.partition(":")
        k = key.strip().lower()
        if sep and k in _BLOCK_FIELD_ORDER:
            val = " ".join(rest.split())[:_BLOCK_FIELD_CAP]
            if val:
                out[k] = val               # a repeated key is last-wins, exactly as bash's case arms are
        elif "why" not in out:
            val = " ".join(seg.split())[:_BLOCK_FIELD_CAP]
            if val:
                out["why"] = val           # legacy freeform → why, first-only (agent-watch.sh:2579)
    return out


def parse_block_reason(text):
    """The reviewer's BLOCK reason as ONE canonical single-line string, or ``""`` (HERD-473).

    ``rule: <rule> | why: <why> | location: <loc>``, in that fixed order, with absent fields simply
    omitted. This is the value that travels into the review ledger, the ``verdict_recorded`` journal
    event and the PR block comment, so all three carry byte-identical text and an operator reading any
    one of them sees exactly what the reviewer said.

    Returns ``""`` for a PASS/INFRA text or a BLOCK with no parseable payload — the caller then records
    exactly what it recorded before this existed (no ``reason`` key, no trailing ledger field), which is
    the same shape every LEGACY reason-less row already has.
    """
    fields = parse_block_fields(text)
    return " | ".join("%s: %s" % (k, fields[k]) for k in _BLOCK_FIELD_ORDER if fields.get(k))


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

# GATE_STATUS_PENDING (HERD-453) — the OPT-IN pending post, and the one narrow exception to the
# SUCCESS-ONLY rule above. THE OPERATOR PROBLEM: under `require herd/gates`, the PR page shows a bare
# "herd/gates — Expected — Waiting for status to be reported" for the WHOLE gate cycle. It is GitHub's
# own placeholder for a required check nothing has reported, it names no owner and no phase, and it
# looks identical whether a suite is running, a reviewer is mid-verdict, or no watcher will ever gate
# this PR at all. Posting `pending` at gate-cycle START replaces it with "herd/gates — pending — review
# in progress", which the terminal success post then overwrites.
#
# WHY IT IS OFF BY DEFAULT AND MUST STAY THAT WAY WITHOUT BRANCH PROTECTION: a non-passing commit status
# flips a CLEAN sha to mergeStateStatus=UNSTABLE in the DEFAULT UNPROTECTED config. UNSTABLE is neither
# CLEAN (the PR drops out of the merge path) nor BLOCKED (it is not gate-eligible either), so every PR
# would silently strand and the block/override/auto-refix paths would break with it — the exact
# self-inflicted deadlock the SUCCESS-ONLY rule exists to prevent. Where `herd/gates` IS a required
# check, that sha is ALREADY BLOCKED on the missing required check, so a pending status changes nothing
# about mergeability and only changes the words the operator reads. Hence: opt-in, documented as
# requiring branch protection, and STRICT (any unrecognized value reads off — a typo can never arm it).
# A gate FAIL still posts NOTHING; the fail-safe is unchanged and still rests on the ABSENCE of success.
_GATE_STATUS_PENDING_DESC = "review in progress"


def _gate_status_pending_enabled(config):
    """True iff ``GATE_STATUS_PENDING`` explicitly opts in. STRICT truthy-token match (mirrors
    agent-watch.sh's ``_main_health_enabled`` shape): anything else — unset, empty, a typo — is off, so
    the default and every misconfiguration preserve the SUCCESS-ONLY contract exactly."""
    val = str((config or {}).get("GATE_STATUS_PENDING", "") or "").strip().lower()
    return val in ("1", "true", "on", "yes", "enable", "enabled")


# Consecutive merge REFUSALS (the API did not confirm state=MERGED) tolerated before the tick escalates
# with a loud needs-you row. Below the threshold the PR STAYS BLESSED and re-attempts next tick; at it,
# a wedged merge surfaces to a human instead of retrying forever in silence (task HERD-352).
_MERGE_REFUSE_MAX = 3

# Deadline on the HUMAN-VERIFY body fetch (§5.4). Mirrors the bash watcher's `_gh_timeout` budget: the
# read is on the merge path, so it must be bounded — but it FAILS CLOSED (hold, never merge), so a
# short deadline costs at most one tick, never a blind merge.
_HV_BODY_TIMEOUT = 15

# ── hold/merge comment + notify actuator (contract §5.6, HERD-448) ─────────────────────────────────
# A hold that fires and tells nobody is a silent stall: bash posted a PR comment + an operator notify
# on each of four hold/merge branches (agent-watch.sh:11873-11920, ede7d45^); the Python core carried
# no actuator for either surface, so a held PR left a journal line and a console row and the AUTHOR
# was never told (PR #563's HUMAN-VERIFY hold went unnoticed for 19 days). Restored here, beside the
# merge/reap/post_gate_status actuator surface, routed through the SAME driver seam bash used
# (herd_driver_notify / scripts/herd/driver.sh notify) — never a hardcoded runtime. Deadlines mirror
# _HV_BODY_TIMEOUT: bounded so a stuck gh/driver call costs at most one tick, never a hang.
_HOLD_COMMENT_TIMEOUT = 15
_HOLD_NOTIFY_TIMEOUT = 15
# herd-resolve.sh returns as soon as the resolver's tab/pane is up — it does not block for the
# resolver's own run — but it chains several herdr calls (+ an optional free-port scan), so it gets a
# wider bound than the single-shot gh/notify calls above.
_RESOLVER_DISPATCH_TIMEOUT = 30


def _hv_steps_text(cand):
    """The declared HUMAN-VERIFY steps, one per line, no bullets — bash's
    ``hv_steps="$(printf '%s' "$hv_body" | human_verify_steps)"``, reusing the SAME already-read body
    (no second fetch, no second timeout)."""
    return "\n".join(_human_verify.steps(cand.hv_body))


def _hold_coordinator_comment(cand):
    """Verbatim bash template (agent-watch.sh:11880, ede7d45^) for a HUMAN_VERIFY_POLICY=coordinator
    hold: coordinator-actionable, not waiting on a human."""
    return (
        "🐑 **herd watch** · all gates passed (healthcheck ✅ · review ✅) — this PR declares manual "
        "steps and `HUMAN_VERIFY_POLICY=coordinator`, so it is held as **coordinator-actionable**: a "
        "coordinator/agent should execute these steps, then approve:\n\n%s\n\nOnce executed, run "
        "`herd approve %s` (or `bash scripts/herd/herd-approve.sh approve %s`) to approve commit "
        "`%s` for merge. A new commit re-holds until re-verified."
        % (_hv_steps_text(cand), cand.pr, cand.pr, cand.sha[:8])
    )


def _hold_human_verify_comment(cand):
    """Verbatim bash template (agent-watch.sh:11890, ede7d45^) for the default HUMAN_VERIFY_POLICY=hold
    hold: waiting on a human to verify the declared steps."""
    return (
        "🐑 **herd watch** · all gates passed (healthcheck ✅ · review ✅) — but this PR declares "
        "manual steps that must be **human-verified** before merge:\n\n%s\n\nOnce verified, run "
        "`herd approve %s` (or `bash scripts/herd/herd-approve.sh approve %s`) to approve commit "
        "`%s` for merge. A new commit re-holds until re-verified."
        % (_hv_steps_text(cand), cand.pr, cand.pr, cand.sha[:8])
    )


def _hold_approve_comment(cand):
    """Verbatim bash template (agent-watch.sh:11898, ede7d45^) for a plain MERGE_POLICY=approve hold
    (no declared HUMAN-VERIFY block)."""
    return (
        "🐑 **herd watch** · all gates passed (healthcheck ✅ · review ✅) · awaiting approval before "
        "merge.\n\nRun `herd approve %s` (or `bash scripts/herd/herd-approve.sh approve %s`) to "
        "approve commit `%s` for merge." % (cand.pr, cand.pr, cand.sha[:8])
    )


def _review_block_comment(cand, reason):
    """The review-BLOCK comment posted when the refix budget is exhausted and the block escalates to a
    human (HERD-473, contract §5.6).

    Carries the reviewer's STRUCTURED reason verbatim — the same string the ledger row and the
    ``verdict_recorded`` journal event hold — so the PR, the journal and `herd approve why` cannot
    disagree about what the objection was. FAIL-SOFT on a reason-less verdict: it says so EXPLICITLY
    rather than going quiet or substituting some other text, because the failure this fixes (#576) was
    an operator reading unrelated text as if it were the gate's objection."""
    stated = ("> %s" % reason) if reason else (
        "_The reviewer recorded no structured reason for this BLOCK._ Read the reviewer's own comment on "
        "this PR, or the review log, before deciding — do NOT treat any other comment as the objection.")
    return (
        "🐑 **herd watch** · review gate **BLOCK** on commit `%s` — the auto-refix budget is spent, so "
        "this now needs a human.\n\nReviewer's stated reason:\n\n%s\n\nInspect: `herd approve why %s` "
        "(verdict + reason) or `herd why %s` (full gate history). If you have independently verified "
        "this commit is correct, `herd approve override %s` records a sha-keyed override; a new commit "
        "invalidates it and re-reviews." % (cand.sha[:8], stated, cand.pr, cand.pr, cand.pr)
    )


def _hv_auto_comment(cand):
    """Verbatim bash template (agent-watch.sh:11916, ede7d45^) for the HUMAN_VERIFY_POLICY=auto
    informational merge: the declared steps were NOT executed, recorded for the audit trail."""
    return (
        "🐑 **herd watch** · `HUMAN_VERIFY_POLICY=auto` — this PR declared manual verify steps, "
        "treated as **informational** and merged on green gates (healthcheck ✅ · review ✅). These "
        "steps were NOT executed before merge:\n\n%s\n\nRecorded in the engine journal as "
        "`human_verify_policy=auto merged-with-declared-steps`." % _hv_steps_text(cand)
    )


def _hold_kind(hv_hold):
    """The `kind` field of hold_applied / hold_released — bash's rule, verbatim (agent-watch.sh
    ``hold_kind="approve"; [ -n "$hv_hold" ] && hold_kind="human-verify"``).

    The port had keyed it off the merge POLICY and spelled the policy hold ``approval``, which is not
    a value bash ever wrote: ``fleet.sh:1556`` matches ``kind == "approve"`` to render "approval hold",
    so every ported policy hold fell through to the generic ``hold (approval)`` row. It also mislabels
    the one case where the two rules disagree — a human-verify PR under ``MERGE_POLICY=approve``,
    which bash called ``human-verify`` (what is actually being verified) and the port called
    ``approval``. One rule, bash's (HERD-442).
    """
    return "human-verify" if hv_hold else "approve"


def _hold_superseded_reason(cand, old_sha, action, hv_policy, approved):
    """Compose the forensic reason a previously-posted hold comment (for ``old_sha``) stopped
    reflecting reality (HERD-464): a new sha landed, an approval landed, or a policy change made
    re-holding it impossible. ``action`` is the FINAL (post merge-fairness/queue-freeze) decision
    for ``cand`` this tick, so the wording never claims a merge that a freeze actually held back."""
    bits = []
    if old_sha != cand.sha:
        bits.append("sha advanced to %s" % cand.sha[:8])
    if action == "MERGE":
        bits.append("approved" if approved else "no approval needed under policy=%s" % hv_policy)
    elif action == "OBSERVE":
        bits.append("now observe mode under policy=%s — not merging" % hv_policy)
    else:
        bits.append("re-held for the new commit under policy=%s" % hv_policy)
    return "; ".join(bits)


def _hold_superseded_comment(cand, reason):
    """The edited body for a superseded hold comment (HERD-464) — replaces the stale hold text in
    place so an operator reading the PR top-to-bottom never sees a hold that no longer applies."""
    return (
        "🐑 **herd watch** · superseded: %s. This hold comment no longer reflects commit `%s` — "
        "see the latest activity on this PR for the current gate outcome."
        % (reason, cand.sha[:8])
    )


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
        # HERD-444: defer instead of reaping when the fixture models a still-WORKING builder or a
        # dirty tree — see LiveActuator.reap for the incident this guards against. ``agent_status``
        # unset (``""``) and ``dirty`` unset (``False``) are both the legacy-fixture defaults, so every
        # scenario written before this fix reaps exactly as before (byte-identical).
        if str(getattr(cand, "agent_status", "") or "") == "working" or self.worktree_dirty(cand):
            self.journal.append("reap_deferred", "pr", cand.pr, "slug", cand.slug, "sha", cand.sha,
                                "reason", "merged-worktree-live")
            return False
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

    def dispatch_resolver(self, cand):
        """Dry-run twin of :meth:`LiveActuator.dispatch_resolver` (HERD-584): no ``herd-resolve.sh``
        spawn — reports success so a dry-run tick's outcome (bounce via resolver, not an escalation)
        matches what the live path would decide, without shelling out."""
        return True

    def post_gate_status(self, cand):
        """PURE no-op twin of the herd/gates commit-status post: no network, no ledger, no journal —
        exactly as bash's ``post_gate_status`` returns early under ``--dry-run``. Returns False (nothing
        posted) so the side-effect-free VERIFY column never records a blessing it did not actually land."""
        return False

    def post_gate_status_pending(self, cand):
        """PURE no-op twin of the GATE_STATUS_PENDING post (HERD-453) — same contract as
        :meth:`post_gate_status` above: an observation run touches no network and records nothing."""
        return False

    def peek_status(self, cand):
        """HERD-420: a READ-ONLY pane-status check — unlike :meth:`wake_builder`, never types
        anything. Simulated straight off the fixture's ``agent_status`` (the same field
        ``wake_builder`` reads); no legacy-sentinel special case here — an unset ``""`` genuinely
        means "not modeled by this fixture", so the completion leg (which requires an observed
        done/idle) correctly no-ops on every pre-HERD-420 fixture."""
        return cand.agent_status

    def worktree_dirty(self, cand):
        """HERD-420: the fixture's scripted dirty bit — see :attr:`LiveCandidate.dirty`."""
        return bool(cand.dirty)

    def post_comment(self, cand, kind, body):
        """PURE no-op twin (HERD-448): DryRunActuator posts nothing — no gh, no network, no journal.
        Returns True (not a failure) so the side-effect-free column never fabricates a
        ``hold_comment_failed`` line for a comment that was never meant to go out."""
        return True

    def notify(self, title, body, sound="default"):
        """PURE no-op twin (HERD-448): no driver-seam dispatch under dry-run."""
        return None

    def edit_comment(self, cand, kind, body):
        """PURE no-op twin (HERD-464): DryRunActuator edits nothing — no gh, no network, no
        journal. Returns True (not a failure), matching :meth:`post_comment`'s contract."""
        return True


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


class LiveHoldSource:
    """The two LIVE INPUTS to the §5.4/§5.5 hold decision: the PR body, and the approval ledger.

    Restores what HERD-306 (P5b) took out. ``discover_via_graphql`` fetches number/sha/base/mergeState
    and nothing else — no body, no approval — so ``LiveCandidate.hv_hold`` and ``.approved`` were left
    at their constructor defaults (``False``) on EVERY live tick. The consequences were both directions
    of the gate at once: a PR declaring HUMAN-VERIFY steps merged with no hold under the ship-default
    policy, and (had anyone run ``MERGE_POLICY=approve``) an approved PR could never be released,
    because nothing read the ledger `herd-approve.sh` writes.

    Injected ONLY by :func:`_run_live_tick`. A fixture / dry-run tick passes ``None``, so a scenario's
    injected ``hv_hold`` / ``approved`` are honored VERBATIM and no ``gh`` ever runs off a sim — the
    same split :class:`FixtureDiscovery` / :class:`DryRunActuator` already draw.
    """

    def __init__(self, state, config=None):
        self.state = state
        self.config = config or {}

    def hv_body(self, pr):
        """``(body, rc)`` for the PR — bash ``_pr_body`` (agent-watch.sh:4341), STATUS AND ALL.

        THE STATUS IS THE POINT (HERD-237). An unreadable body must never be spent as "declares no
        block": with a bounded ``gh`` deadline a slow network would otherwise become the routine silent
        auto-merge of a PR whose manual steps were never run. ``rc`` is 0 only when gh actually
        answered; every fault (timeout, non-zero exit, auth, rate limit) returns non-zero and the
        caller HOLDS.
        """
        try:
            out = subprocess.run(["gh", "pr", "view", str(pr), "--json", "body", "-q", ".body"],
                                 capture_output=True, text=True, timeout=_HV_BODY_TIMEOUT)
        except Exception:
            return "", 124                      # timeout / exec fault — the bash `_gh_timeout` rc
        if out.returncode != 0:
            return "", out.returncode or 1
        return out.stdout, 0

    def approved(self, pr, sha):
        """True iff a sha-keyed ``approved`` row exists (agent-watch.sh:approval_is_approved)."""
        return self.state.approval_is_approved(pr, sha)


# ── cross-seat BLOCK precedence (HERD-247, restored HERD-446) ──────────────────────────────────────
# INCIDENT (PR #343, 2026-07-09 16:19-16:25Z): two seats gated the same PR concurrently. One seat's
# reviewer posted a correctness BLOCK; minutes later the OTHER seat's reviewer posted a PASS, that
# seat's watcher blessed the sha and merged over the standing BLOCK. A BLOCK from ANY seat must be
# TERMINAL for that sha until it is RESOLVED — a second seat's PASS is a second opinion, not a
# resolution. The review ledger cannot see this: it is per-seat local state, so each watcher only ever
# knows its OWN verdict. The check below reads only artifacts EVERY seat already writes — the
# herd/gates commit status and the PR's comments. No new substrate, no new config key.
#
# BOTH BASH ENFORCEMENT STAGES DIED SEPARATELY (HERD-442 audit): the merge stage inside the deleted
# `_tick_act` (commit ede7d45, HERD-306 P5b), and the setter stage inside bash's `post_gate_status`,
# which has had no callers since :meth:`LiveActuator.post_gate_status` took over the blessing. pysrc
# carried no cross_seat reference at all until this restoration. Reinstated at BOTH surfaces — the
# merge decision (:meth:`LiveTick._walk`) and the gate-status setter (:meth:`LiveActuator.post_gate_status`)
# — from this ONE shared implementation (:func:`_cross_seat_block_standing`), per multi-seat doctrine
# Rule 2 (docs/multi-seat-doctrine.md): one shared check, reused identically at every enforcement
# surface, never a second copy per surface.
#
# WHY NO ``failure`` STATUS IS POSTED. Posting herd/gates=failure on the standing-BLOCK sha would break
# the SUCCESS-ONLY invariant (:meth:`LiveActuator.post_gate_status`'s docstring) and strand the PR
# permanently: a non-passing status flips a CLEAN sha to mergeStateStatus=UNSTABLE in the default
# unprotected config, and UNSTABLE is neither CLEAN (drops out of the candidate loop) nor BLOCKED (not
# gate-eligible) — no seat could ever re-enter the loop to overwrite the status back to success once
# the blocking seat reconciles. WITHHOLDING success is enough: it already leaves the PR unmergeable
# under `require herd/gates` branch protection, and the merge-decision surface holds it in the
# unprotected config too. The other half IS honored — an existing herd/gates=failure written by
# another seat is KEPT, never overwritten with our success.
#
# RESOLUTION flows through existing surfaces only: the blocking seat posts a NEWER verdict comment for
# the same sha reading PASS, or a human records the sha-keyed override (`herd-approve.sh override`). A
# new commit is a new sha and carries no verdict at all, so it starts clean.
#
# FAIL-SOFT throughout: an unreadable commit/status/comment read, or an unresolvable seat identity,
# reports NO standing block (never a false hold) — the surface behaves exactly as it did before this
# guard existed.

_XSEAT_GH_TIMEOUT = 15   # bounded, like _HV_BODY_TIMEOUT — an outage costs one tick, never a hang
_XSEAT_MD_STRIP_RE = re.compile(r"[*`_#>]")
_XSEAT_BLOCK_RE = re.compile(r"\bBLOCK\b")
_XSEAT_PASS_RE = re.compile(r"\bPASS\b")


def _xseat_commit_date(sha):
    """The sha's committer date (ISO 8601) — keys a verdict comment to THIS commit (a comment posted
    BEFORE the sha landed is a verdict on the OLD commit). Empty string on any unreadable read
    (agent-watch.sh:_xseat_foreign_block)."""
    try:
        out = subprocess.run(
            ["gh", "api", "repos/{owner}/{repo}/commits/%s" % sha, "--jq", ".commit.committer.date"],
            capture_output=True, text=True, timeout=_XSEAT_GH_TIMEOUT)
    except Exception:
        return ""
    if out.returncode != 0:
        return ""
    return (out.stdout or "").strip()


def _xseat_pr_comments(pr):
    """``(comments, ok)`` — the PR's comments (author/createdAt/body); ``ok`` False on ANY unreadable
    read (timeout, non-zero exit, unparseable JSON) — never spent as "no comments"."""
    try:
        out = subprocess.run(["gh", "pr", "view", str(pr), "--json", "comments"],
                             capture_output=True, text=True, timeout=_XSEAT_GH_TIMEOUT)
    except Exception:
        return [], False
    if out.returncode != 0:
        return [], False
    try:
        data = json.loads(out.stdout or "{}")
    except Exception:
        return [], False
    if not isinstance(data, dict):
        return [], False
    return data.get("comments") or [], True


def _xseat_first_verdict(body):
    """The verdict word on the FIRST non-empty line, markdown emphasis stripped — real reviewers post
    ``REVIEW: **BLOCK** — …``; BLOCK wins a line mentioning both. ``None`` when that line names
    neither (agent-watch.sh's ``_XSEAT_PY`` classifier)."""
    for line in (body or "").splitlines():
        s = _XSEAT_MD_STRIP_RE.sub("", line).strip()
        if not s:
            continue
        if _XSEAT_BLOCK_RE.search(s):
            return "BLOCK"
        if _XSEAT_PASS_RE.search(s):
            return "PASS"
        return None
    return None


def _xseat_foreign_block(pr, sha, me):
    """``(seat, rc)`` for a standing foreign BLOCK on this EXACT sha — rc 0 standing · 1 none ·
    2 degraded (unreadable). Keeps only each foreign seat's LATEST verdict comment at or after the sha
    landed, so a blocking seat's newer PASS resolves its OWN block — a DIFFERENT seat's PASS never does
    (the #343 incident). Port of agent-watch.sh's ``_xseat_foreign_block`` + ``_XSEAT_PY``."""
    since = _xseat_commit_date(sha)
    if not since or since == "null":
        return "", 2
    comments, ok = _xseat_pr_comments(pr)
    if not ok:
        return "", 2
    latest = {}
    for c in comments:
        if not isinstance(c, dict):
            continue
        login = ((c.get("author") or {}).get("login") or "")
        when = c.get("createdAt") or ""
        if not login or not when or login == me or when < since:
            continue
        verdict = _xseat_first_verdict(c.get("body"))
        if verdict is None:
            continue
        prev = latest.get(login)
        if prev is None or when >= prev[0]:
            latest[login] = (when, verdict)
    blockers = sorted(login for login, (_, v) in latest.items() if v == "BLOCK")
    if blockers:
        return blockers[0], 0
    return "", 1


def _gate_status_current(sha):
    """``(state, creator_login)`` for the CURRENT herd/gates status on this sha — newest-first, first
    match wins (agent-watch.sh:_gate_status_current). Empty strings on any unreadable read or no such
    status."""
    if not sha:
        return "", ""
    try:
        out = subprocess.run(
            ["gh", "api", "repos/{owner}/{repo}/commits/%s/statuses" % sha],
            capture_output=True, text=True, timeout=_XSEAT_GH_TIMEOUT)
    except Exception:
        return "", ""
    if out.returncode != 0:
        return "", ""
    try:
        rows = json.loads(out.stdout or "[]")
    except Exception:
        return "", ""
    if not isinstance(rows, list):
        return "", ""
    for row in rows:
        if isinstance(row, dict) and row.get("context") == _GATE_STATUS_CONTEXT:
            return row.get("state") or "", ((row.get("creator") or {}).get("login") or "")
    return "", ""


def _cross_seat_block_standing(pr, sha, state, config=None, me=None):
    """THE shared cross-seat BLOCK precedence check (HERD-247) — reused, unmodified, at BOTH
    enforcement surfaces (multi-seat doctrine Rule 2). Checks, cheapest first:

      1. a sha-keyed human override (``herd-approve.sh override``) → resolved, no hold.
      2. herd/gates=failure written by ANOTHER seat → standing (this seat never posts failure, so any
         failure on the sha is foreign).
      3. a foreign seat whose LATEST verdict comment for this sha is BLOCK → standing.

    Returns ``(seat, degraded_reason)``: ``seat`` is the blocking seat's login when a BLOCK stands,
    else ``""``; ``degraded_reason`` is a non-empty string when the scan itself could not read the
    shared artifacts (identity unresolved / commit+comment scan unreadable) — still reports NO
    standing block either way, never a false hold.

    ``me`` is this seat's identity, pre-resolved by the caller (:meth:`LiveTick._xseat_identity` /
    :meth:`LiveActuator._xseat_identity`) and memoized per tick — mirrors bash's
    ``_resolve_watcher_owner`` (memoized so "the 4s poll loop must never spawn a gh probe every
    tick"); Python is a fresh process per ``--tick``, so the per-tick memo is what caps the identity
    probe at ONE call per tick regardless of how many green candidates walk this check, rather than
    one per candidate. ``None`` (any caller that has not resolved one) falls back to resolving it here.
    """
    if not pr or not sha:
        return "", ""
    if state is not None and state.override_exists(pr, sha):
        return "", ""
    me = me if me is not None else _resolve_owner(config or {})
    if not me:
        return "", "seat identity unresolved"
    cur_state, creator = _gate_status_current(sha)
    if cur_state == "failure" and creator and creator != me:
        return creator, ""
    seat, rc = _xseat_foreign_block(pr, sha, me)
    if rc == 0:
        return seat, ""
    if rc == 2:
        return "", "commit status / comment scan unreadable"
    return "", ""


# ── stale/duplicate pre-merge gate (HERD-188, restored HERD-566/HERD-561 P5b) ─────────────────────────
# GROUNDED: the reachability lint (HERD-556) proved the ENTIRE bash stale-dup gate
# (stale-dup-gate.sh:stale_dup_check, dispatched by agent-watch.sh:_stale_dup_gate_step) lost its only
# caller at the P5b port (HERD-306) — every merge under ENGINE_IMPL=python has run with NEITHER of its
# two provable holds: DUPLICATE (this PR's tracked ref already shipped via another merged PR — #236 vs
# #185) nor STALE-BASE (touched files the base branch materially changed since this branch's merge-base
# — re-applying an old branch's copy would silently clobber newer work). This restoration ports the
# gate's DECISION logic (kind + reason) faithfully from the bash spec; :meth:`LiveTick._walk` wires it
# into the decide path, before health/review dispatch, exactly where bash placed it (HERD-227: the
# check is deterministic-cheap, so it must run before either expensive rail is dispatched — PR #328
# journaled a healthcheck completing 2s before a stale hold superseded it).
#
# LIVE-ONLY, like cross-seat (:func:`_cross_seat_block_standing`): gated on ``hold_source is not None``
# at the call site, so every fixture/dry-run/sim tick — the whole existing test suite — never shells to
# `gh`/`git` here and stays byte-identical.

_STALE_DUP_TIMEOUT = 15   # bounded like _HV_BODY_TIMEOUT/_XSEAT_GH_TIMEOUT — an outage costs one tick

_STALE_DUP_REF_PLACEHOLDER = {"none", "n/a", "na"}
_STALE_DUP_REF_TRAILING = ".,;:!)]}*"
# Leading decoration (heading/list/quote/bold) · "refs:" · a closing bold · the token — the SAME shape
# as scripts/herd/pr-ref.sh's HERD_PR_REF_PY (HERD-522), so a ref reads identically at every surface.
_STALE_DUP_REF_LINE_RE = re.compile(r"^[\s#*>-]*refs:\**\s*(\S+)", re.IGNORECASE)
_STALE_DUP_HTML_COMMENT_RE = re.compile(r"<!--.*?-->", re.DOTALL)


def _stale_dup_ref_token(line):
    """The raw token on an anchored ``Refs:`` line, trailing punctuation stripped; "" when the line
    does not match or nothing usable remains after the strip (pr-ref.sh:_pr_ref_token)."""
    m = _STALE_DUP_REF_LINE_RE.match(line)
    if not m:
        return ""
    return m.group(1).rstrip(_STALE_DUP_REF_TRAILING)


def _stale_dup_pr_ref_from_body(body):
    """Port of pr-ref.sh's ``pr_ref_from_body`` (HERD-522): the FIRST anchored ``Refs:`` line's token,
    HTML comments stripped first, or "" for no ref / an explicit placeholder (``<...>``, none, n/a,
    na) — the same placeholder never raises a silent-miss alarm here either. Pure; no I/O."""
    decommented = _STALE_DUP_HTML_COMMENT_RE.sub("", body or "")
    for line in decommented.splitlines():
        if not _STALE_DUP_REF_LINE_RE.match(line):
            continue
        tok = _stale_dup_ref_token(line)
        if not tok or tok.startswith("<") or tok.lower() in _STALE_DUP_REF_PLACEHOLDER:
            return ""
        return tok
    return ""


def _stale_dup_enabled(config):
    """The master lever — mirrors stale-dup-gate.sh:stale_dup_enabled EXACTLY: only the literal string
    ``off`` disables (case-sensitive); any other value, including unset, is on."""
    return str((config or {}).get("STALE_DUP_DETECT") or "on") != "off"


def _stale_base_autofix_enabled(config):
    """STALE_BASE_AUTOFIX — SHIP-DORMANT (default off): mirrors agent-watch.sh's
    ``_stale_base_autofix_enabled`` truthy set, the same one ``_merge_result_gate_enabled`` and
    siblings use. Any unrecognized value is off — never accidentally on from a typo."""
    val = str((config or {}).get("STALE_BASE_AUTOFIX", "") or "").strip().lower()
    return val in ("1", "true", "on", "yes", "enable", "enabled")


def _stale_dup_derived_paths(config):
    """The shared regenerable-derived-files list (HERD-214, derived-files.sh:herd_derived_paths) —
    a stale-base overlap made ONLY of these excuses nothing (the engine regenerates them
    deterministically; losing the working-tree copy costs nothing)."""
    name = str((config or {}).get("COORDINATOR_CMD") or "/coordinator").strip()
    name = name[1:] if name.startswith("/") else name
    name = name or "coordinator"
    return (".claude/commands/%s.md" % name, ".claude/commands/autopilot.md", ".herd/config.local")


def _stale_dup_this_ref(pr):
    """The ref THIS PR carries — honors the ``HERD_STALE_DUP_BODY_FILE`` test seam (reads a body from
    a file instead of `gh`), mirroring stale-dup-gate.sh:_stale_dup_this_ref. Fail-soft: "" on any
    read fault, never raises."""
    body_file = os.environ.get("HERD_STALE_DUP_BODY_FILE")
    if body_file:
        try:
            with open(body_file, encoding="utf-8") as fh:
                return _stale_dup_pr_ref_from_body(fh.read())
        except Exception:
            return ""
    try:
        out = subprocess.run(["gh", "pr", "view", str(pr), "--json", "body", "-q", ".body"],
                             capture_output=True, text=True, timeout=_STALE_DUP_TIMEOUT)
    except Exception:
        return ""
    if out.returncode != 0:
        return ""
    return _stale_dup_pr_ref_from_body(out.stdout)


def _stale_dup_merged_refs_shipping(ref, this_pr):
    """The PR number of a MERGED PR — other than ``this_pr`` — whose body carries the exact same
    ``ref``, or "" when none does. Honors the ``HERD_STALE_DUP_MERGED_FILE`` test seam (a
    ``"<pr>\\t<ref>"``-per-line file instead of `gh`), mirroring
    stale-dup-gate.sh:_stale_dup_merged_refs + _stale_dup_shipped_by. Fail-soft throughout."""
    if not ref:
        return ""
    merged_file = os.environ.get("HERD_STALE_DUP_MERGED_FILE")
    if merged_file:
        try:
            with open(merged_file, encoding="utf-8") as fh:
                lines = fh.read().splitlines()
        except Exception:
            return ""
        for line in lines:
            parts = line.split("\t", 1)
            if len(parts) != 2:
                continue
            pr_num, r = parts
            if pr_num and pr_num != str(this_pr) and r == ref:
                return pr_num
        return ""
    try:
        out = subprocess.run(
            ["gh", "pr", "list", "--state", "merged", "--search", "%s in:body" % ref,
             "--limit", "100", "--json", "number,body"],
            capture_output=True, text=True, timeout=_STALE_DUP_TIMEOUT)
    except Exception:
        return ""
    if out.returncode != 0:
        return ""
    try:
        rows = json.loads(out.stdout or "[]")
    except Exception:
        return ""
    if not isinstance(rows, list):
        return ""
    for row in rows:
        if not isinstance(row, dict):
            continue
        num = row.get("number")
        if num is None or str(num) == str(this_pr):
            continue
        if _stale_dup_pr_ref_from_body(row.get("body") or "") == ref:
            return str(num)
    return ""


def _stale_dup_base_overlap(dir_, base, head, config=None):
    """The files this branch touches that the base branch ALSO changed since their common merge-base
    (touched-order, first-match-wins for the reason string) — [] when the dir is not a worktree, a ref
    is missing, the branch already contains the base tip (not behind → cannot be stale), either diff
    is empty, or the whole overlap is regenerable derived files (:func:`_stale_dup_derived_paths`).
    Pure git; no network. Port of stale-dup-gate.sh:stale_dup_base_overlap."""
    if not dir_ or not os.path.isdir(dir_):
        return []
    try:
        mb = subprocess.run(["git", "-C", dir_, "merge-base", base, head],
                            capture_output=True, text=True, timeout=_STALE_DUP_TIMEOUT)
        if mb.returncode != 0:
            return []
        mb_sha = (mb.stdout or "").strip()
        if not mb_sha:
            return []
        basetip = subprocess.run(["git", "-C", dir_, "rev-parse", base],
                                 capture_output=True, text=True, timeout=_STALE_DUP_TIMEOUT)
        if basetip.returncode != 0:
            return []
        # Branch is up to date with (or ahead of) base on this line of history → cannot be stale.
        if (basetip.stdout or "").strip() == mb_sha:
            return []
        touched = subprocess.run(["git", "-C", dir_, "diff", "--name-only", mb_sha, head],
                                 capture_output=True, text=True, timeout=_STALE_DUP_TIMEOUT)
        if touched.returncode != 0:
            return []
        touched_files = [l for l in (touched.stdout or "").splitlines() if l]
        if not touched_files:
            return []
        moved = subprocess.run(["git", "-C", dir_, "diff", "--name-only", mb_sha, base],
                               capture_output=True, text=True, timeout=_STALE_DUP_TIMEOUT)
        if moved.returncode != 0:
            return []
        moved_files = set(l for l in (moved.stdout or "").splitlines() if l)
        if not moved_files:
            return []
        derived = set(_stale_dup_derived_paths(config))
        overlap = [p for p in touched_files if p in moved_files and p not in derived]
        return overlap
    except Exception:
        return []


def _stale_dup_check(cand, config):
    """Port of stale-dup-gate.sh:stale_dup_check (HERD-188) — the deterministic, provable-only
    pre-merge gate. Returns ``(kind, reason)``: ``("duplicate", ...)`` when this PR's tracked
    ``Refs:`` item already shipped via another merged PR, ``("stale-base", ...)`` when touched files
    were changed on the base branch since this branch's merge-base, or ``(None, None)`` to proceed
    (the lever is off, or neither condition is provable). Order matches bash: DUPLICATE first (the
    cheaper, ground-truth "already shipped" test, skipped when the PR carries no ref), then
    STALE-BASE. FAIL-SOFT: any read fault is read as "cannot prove a problem" — never a false hold."""
    if not _stale_dup_enabled(config):
        return None, None

    ref = _stale_dup_this_ref(cand.pr)
    if ref:
        shipper = _stale_dup_merged_refs_shipping(ref, cand.pr)
        if shipper:
            return "duplicate", ("tracked item %s already shipped by merged PR #%s — this PR "
                                 "re-implements Done work" % (ref, shipper))

    base = str((config or {}).get("DEFAULT_BRANCH") or os.environ.get("DEFAULT_BRANCH") or "main")
    overlap = _stale_dup_base_overlap(cand.worktree, base, cand.sha, config)
    if overlap:
        return "stale-base", (
            "stale base: %d touched file(s) were changed on %s after this branch's merge-base "
            "(e.g. %s) — merging would silently clobber newer work" % (len(overlap), base, overlap[0]))
    return None, None


# ── DELTA-SCOPED REVIEW carry-forward (HERD-204, ported into the live core at HERD-580) ────────────
# When a builder pushes a PURE INTEGRATION commit — it merged DEFAULT_BRANCH into the branch with NO
# authored change beyond the merge — re-running the full adversarial review for that new sha burns
# tokens/time for zero correctness gain: the newly-merged main commits are already-reviewed main, and
# the merge itself introduced no new authored content. With DELTA_REVIEW=on, the review gate PROVES the
# delta between the new head sha and this PR's LAST review-PASSED sha is integration-only and, if so,
# CARRIES FORWARD the prior PASS onto the new sha instead of dispatching a reviewer.
#
# The proof is CONSERVATIVE + FAIL-CLOSED, mirroring agent-watch.sh:_delta_is_integration_only exactly
# — every one of these must hold, else a normal full review:
#   1. DELTA_REVIEW=on (opt-in; default/unknown → off → byte-inert).
#   2. the PR has a recorded PASS for an OLDER sha (the carry source).
#   3. the new sha is a 2-parent MERGE commit.
#   4. one parent IS the last-passed sha (the branch side — already reviewed & PASSED).
#   5. the OTHER parent is already contained in DEFAULT_BRANCH (already-reviewed main).
#   6. the new commit's tree EQUALS a clean 3-way auto-merge of those two parents — i.e. the merge
#      carries ZERO manual edits (no authored conflict resolution).
# Any authored change beyond the merge diverges the tree (6) or breaks the parent identity (4), and a
# missing sha / worktree / main ref simply returns "not provable" → full review. So a real code change
# NEVER carries forward. Bash's own implementation (agent-watch.sh:_maybe_carry_forward_review) has had
# no reachable caller since the P5b engine port — its only caller was the dead ``_review_gate_step`` —
# so this is a fresh Python implementation, not a call-out to the bash body.

def _delta_review_enabled(config):
    """True iff ``DELTA_REVIEW`` opts in — matches bash's ``case … in on|On|ON) …`` exactly (no
    case-folding beyond those three literals) so an operator's config reads identically either engine."""
    return (config or {}).get("DELTA_REVIEW") in ("on", "On", "ON")


def _delta_main_ref(dir_, config):
    """The first resolvable ref naming DEFAULT_BRANCH in ``dir_`` (the bare name, then
    ``origin/<name>``, then ``refs/remotes/origin/<name>``), or ``None`` when none resolves — the
    caller then treats the delta as "not provable" → full review (port of agent-watch.sh:_delta_main_ref)."""
    base = str((config or {}).get("DEFAULT_BRANCH") or os.environ.get("DEFAULT_BRANCH") or "main")
    b = base[len("origin/"):] if base.startswith("origin/") else base
    for candidate in (base, b, "origin/%s" % b, "refs/remotes/origin/%s" % b):
        if not candidate:
            continue
        try:
            out = subprocess.run(
                ["git", "-C", dir_, "rev-parse", "--verify", "--quiet", "%s^{commit}" % candidate],
                capture_output=True, text=True, timeout=_STALE_DUP_TIMEOUT)
        except Exception:
            continue
        if out.returncode == 0:
            return candidate
    return None


def _delta_is_integration_only(dir_, old, new, config):
    """True iff the delta from ``old`` (the last-passed commit) to ``new`` (the new head) is PROVABLY a
    pure merge of DEFAULT_BRANCH with no authored content. Fail-closed: any missing precondition,
    unresolved ref, or content divergence → False. Pure git; no network. Port of
    agent-watch.sh:_delta_is_integration_only."""
    if not dir_ or not os.path.isdir(dir_):
        return False
    if not old or not new or old == new:
        return False
    try:
        def _git(*args):
            return subprocess.run(["git", "-C", dir_] + list(args),
                                  capture_output=True, text=True, timeout=_STALE_DUP_TIMEOUT)
        if _git("rev-parse", "--git-dir").returncode != 0:
            return False
        oldp = _git("rev-parse", "--verify", "--quiet", "%s^{commit}" % old)
        if oldp.returncode != 0:
            return False
        oldfull = oldp.stdout.strip()
        newp = _git("rev-parse", "--verify", "--quiet", "%s^{commit}" % new)
        if newp.returncode != 0:
            return False
        newfull = newp.stdout.strip()
        # The new head must be a MERGE with EXACTLY two parents (a simple integration merge).
        pline = _git("rev-list", "--parents", "-n1", newfull)
        if pline.returncode != 0:
            return False
        parts = (pline.stdout or "").split()
        if len(parts) != 3:                    # the commit's own oid + exactly two parents
            return False
        _, p1, p2 = parts
        # One parent must BE the last-passed sha (the already-reviewed branch side); the other is the
        # main-side parent. Neither → an authored commit sits between old and the merge → full review.
        if p1 == oldfull:
            branchp, mainp = p1, p2
        elif p2 == oldfull:
            branchp, mainp = p2, p1
        else:
            return False
        # The main-side parent must already be contained in DEFAULT_BRANCH (already-reviewed main).
        mainref = _delta_main_ref(dir_, config)
        if not mainref:
            return False
        if _git("merge-base", "--is-ancestor", mainp, mainref).returncode != 0:
            return False
        # CONTENT-TRIVIAL merge: the new commit's tree must equal a clean 3-way auto-merge of the two
        # parents. A non-zero merge-tree (conflict) or any manual edit diverges the tree → full review.
        autop = _git("merge-tree", "--write-tree", branchp, mainp)
        if autop.returncode != 0:
            return False
        auto_lines = (autop.stdout or "").splitlines()
        auto = auto_lines[0] if auto_lines else ""
        if not auto:
            return False
        newtreep = _git("rev-parse", "--verify", "--quiet", "%s^{tree}" % newfull)
        if newtreep.returncode != 0:
            return False
        return auto == newtreep.stdout.strip()
    except Exception:
        return False


def _maybe_carry_forward_review(cand, state, config, journal):
    """If ``DELTA_REVIEW=on`` and the delta from this PR's last-passed sha to ``cand.sha`` is provably
    integration-only, RECORD a carried-forward PASS for ``cand.sha`` (source=carried-forward) + journal
    ``review_carried_forward``, and return True so the caller skips the reviewer dispatch. Returns False
    (carry nothing) in every other case → normal review. Port of
    agent-watch.sh:_maybe_carry_forward_review."""
    if not _delta_review_enabled(config):
        return False
    if not cand.sha:
        return False
    old = state.recorded_review_last_pass_sha(cand.pr)
    if not old or old == cand.sha:
        return False
    if not _delta_is_integration_only(cand.worktree, old, cand.sha, config):
        return False
    state.record_review(cand.pr, cand.sha, "PASS", "carried-forward", "")
    base = str((config or {}).get("DEFAULT_BRANCH") or os.environ.get("DEFAULT_BRANCH") or "main")
    journal.append("review_carried_forward", "pr", cand.pr, "sha", cand.sha, "from_sha", old,
                   "slug", cand.slug,
                   "reason", "integration-only delta (merge of %s) — prior review PASS carried forward"
                             % base)
    return True


# ── Evidence-triggered review escalation (HERD-580 port of agent-watch.sh:_maybe_arm_review_escalation
#    / REVIEW_MODEL_ESCALATED consumption) ───────────────────────────────────────────────────────────
def _review_evidence_escalate_rounds(config):
    """``REVIEW_EVIDENCE_ESCALATE_ROUNDS``, unset/empty → 2 (bash's ``${VAR:-2}``); any OTHER
    non-digits value → ``None`` (never arm) rather than silently falling back to 2 — bash's
    ``[ N -ge "$VAR" ]`` errors to a non-zero test on a non-numeric VAR that is SET (``:-2`` only
    substitutes when the var is unset/empty), so a typo'd config value fails safe to "no escalation",
    matching that exactly rather than the more permissive default a bare ``int()`` coercion would give."""
    raw = (config or {}).get("REVIEW_EVIDENCE_ESCALATE_ROUNDS")
    if raw is None or str(raw) == "":
        return 2
    s = str(raw)
    return int(s) if _BREAKER_DIGITS_RE.match(s) else None


# ── Claude exec-hang probe (HERD-108, ported into the live core at HERD-580) ────────────────────────
# On some environments `claude` WEDGES on invocation — every exec hangs before the process finishes
# starting (e.g. the macOS com.apple.quarantine _dyld_start hang). A wedged claude makes every review
# dispatch spawn a corpse: the reviewer never writes a verdict, so the tick burns REVIEW_CONCURRENCY
# slots forever against a hang it cannot see (the herd-review.sh subprocess `_dispatch_review` launches
# never returns). This probe DETECTS the wedge DIRECTLY — a trivial `claude --version` under a hard
# timeout, run at most ONCE per tick, memoized on the LiveGates instance exactly like
# `_main_health_pending_memo` (a LiveGates instance lives exactly one tick) — so the watcher can HOLD
# review dispatch and surface the hang LOUDLY (a journal infra_event) instead of feeding a dead binary.
#
# BYTE-INERT BY DEFAULT: WATCH_CLAUDE_PROBE_TIMEOUT defaults to 0 (off). With it 0/empty/non-numeric the
# probe is a no-op — no claude exec, no journal, no gating — so behavior is byte-identical without it.

def _claude_probe_secs(config):
    """The armed timeout in seconds, or ``None`` when the probe is disabled (0/unset/non-numeric →
    OFF, fail-safe parse; port of agent-watch.sh:_claude_probe_secs)."""
    raw = (config or {}).get("WATCH_CLAUDE_PROBE_TIMEOUT")
    s = "" if raw is None else str(raw)
    if not _BREAKER_DIGITS_RE.match(s):
        return None
    n = int(s)
    return n if n > 0 else None


def _claude_hang_clear(state, journal):
    """Drop the hang-episode marker; if a hang HAD been on record, journal one recovery line so the
    episode's open/close is visible. Cheap no-op when no hang was recorded (port of
    agent-watch.sh:_claude_hang_clear)."""
    marker = state.claude_hang_state_file()
    try:
        had_hang = bool(marker) and os.path.exists(marker) and os.path.getsize(marker) > 0
    except OSError:
        had_hang = False
    if not had_hang:
        return
    try:
        os.remove(marker)
    except OSError:
        pass
    journal.append("infra_event", "component", "agent-watch", "reason", "claude-exec-hang-cleared",
                   "detail", "claude --version responded again — resuming review dispatch")


def _claude_exec_hung(state, config, journal):
    """Probe claude ONCE and return this tick's verdict:

      ``"HUNG"`` — ``claude --version`` did not return within the armed timeout (a real exec-wedge).
      ``"OK"``   — probe disabled, OR claude responded in time / exited non-zero (broken-but-not-wedged)
                  / is absent — every NON-hang outcome never holds the queue (fail-soft).

    On the FIRST HUNG of a hang episode it journals ONE loud infra_event (deduped via the hang-state
    marker so a persistent wedge does not spam the journal every tick); any non-hang outcome CLEARS the
    marker. A broken/absent claude is deliberately NOT a hang. Port of agent-watch.sh:_claude_exec_hung."""
    secs = _claude_probe_secs(config)
    if secs is None:
        return "OK"
    if shutil.which("claude") is None:
        _claude_hang_clear(state, journal)
        return "OK"
    try:
        subprocess.run(["claude", "--version"], capture_output=True, timeout=secs)
    except subprocess.TimeoutExpired:
        marker = state.claude_hang_state_file()
        try:
            already = bool(marker) and os.path.exists(marker) and os.path.getsize(marker) > 0
        except OSError:
            already = False
        if not already:
            journal.append("infra_event", "component", "agent-watch", "reason", "claude-exec-hang",
                           "detail", "claude --version did not return within %ss (exec-hang) — "
                                     "holding review dispatch" % secs, "timeout_secs", secs)
            if marker:
                try:
                    with open(marker, "w", encoding="utf-8") as fh:
                        fh.write("%s\n" % _now_epoch())
                except OSError:
                    pass
        return "HUNG"
    except Exception:
        # A spawn failure is treated like "broken/absent", not a hang.
        _claude_hang_clear(state, journal)
        return "OK"
    _claude_hang_clear(state, journal)
    return "OK"


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

    def __init__(self, home, journal, config=None, state=None):
        self.home = home
        self.journal = journal
        self.config = config or {}
        # The shared on-disk state ($TREES) — used for the cross-seat override read (HERD-446,
        # LiveState.override_exists) and its once-per-(pr,sha) journal dedup. ``None`` (every
        # pre-HERD-446 caller/test) falls back to a black-hole LiveState(None) — the SAME degrade
        # LiveTick uses — so override_exists reports False and once() never suppresses, exactly the
        # no-cross-tick-memory behavior a stateless caller already expects.
        self.state = state if state is not None else LiveState(None)
        # Per-instance memo (HERD-446): a LiveActuator lives exactly one tick (constructed fresh in
        # _run_live_tick), so caching here is tick-scoped for free — caps the `gh api user` identity
        # probe at ONE call per tick no matter how many candidates reach the setter guard.
        self._xseat_identity_cache = None

    def _xseat_identity(self):
        if self._xseat_identity_cache is None:
            self._xseat_identity_cache = _resolve_owner(self.config) or ""
        return self._xseat_identity_cache

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
        # CHAOS SEAM (mid_do_merge, HERD-425): the merge action above has already landed (or genuinely
        # failed) on the remote — the one truly unrecoverable step. Everything below this line is local
        # bookkeeping (the state verify + the journal "merge" record + the caller's reap). A hard death
        # here models "the merge reached GitHub, our record of it did not" — the exact shape a foreign
        # merge already leaves, which the existing post-merge reconcile sweep (_sweep_merged_prs,
        # agent-watch.sh) is built to discharge regardless of who performed the merge.
        _chaos_kill("mid_do_merge")
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
        # SETTER GUARD (HERD-247, restored HERD-446): never bless a sha another seat is still blocking,
        # and never overwrite a foreign herd/gates=failure with our success. Defense in depth: the
        # merge-decision surface (LiveTick._walk) already holds a candidate before ever reaching this
        # call, but this guard does not depend on being reached that way — ANY caller of
        # post_gate_status must never post a blessing over a standing foreign BLOCK. One shared
        # implementation (_cross_seat_block_standing), reused verbatim at both surfaces.
        seat, degraded = _cross_seat_block_standing(cand.pr, cand.sha, self.state, self.config,
                                                     me=self._xseat_identity())
        if degraded:
            if self.state.once(cand.pr, cand.sha, "xseat_degraded"):
                self.journal.append("cross_seat_block_scan", "pr", cand.pr, "sha", cand.sha,
                                    "state", "degraded", "reason", degraded)
        elif seat:
            if self.state.once(cand.pr, cand.sha, "xseat_honored_setter"):
                self.journal.append("cross_seat_block_honored", "pr", cand.pr, "sha", cand.sha,
                                    "seat", seat, "stage", "setter",
                                    "reason", "cross-seat BLOCK standing (seat %s)" % seat)
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

    def post_gate_status_pending(self, cand):
        """POST ``herd/gates=pending`` for this ``(pr, sha)`` at gate-cycle start (GATE_STATUS_PENDING,
        HERD-453 — see :data:`_GATE_STATUS_PENDING_DESC` for the full rationale and the UNSTABLE hazard
        that keeps this opt-in). Journals ``gate_status`` in the SAME shape as the success post, with
        ``state=pending``, so one event family covers the whole status surface and every existing
        consumer reads it unchanged. Best-effort: a failed write journals nothing and returns False, so
        the caller records no ledger marker and the post is re-attempted next tick. Never raises.

        NO cross-seat guard here, deliberately, and it is not an omission: the setter guard on the
        success post exists to stop this seat BLESSING over another seat's standing BLOCK. A pending
        status grants nothing — it can never make an unmergeable sha mergeable — so there is no
        blessing to withhold, and holding the pending post behind a `gh` read would spend a network
        call per candidate per tick to protect against nothing."""
        if not cand.sha:
            return False
        try:
            subprocess.run(
                ["gh", "api", "repos/{owner}/{repo}/statuses/%s" % cand.sha,
                 "-f", "state=pending", "-f", "context=%s" % _GATE_STATUS_CONTEXT,
                 "-f", "description=%s" % _GATE_STATUS_PENDING_DESC],
                capture_output=True, text=True, check=True)
        except Exception:
            return False
        self.journal.append("gate_status", "pr", cand.pr, "sha", cand.sha, "state", "pending",
                            "context", _GATE_STATUS_CONTEXT)
        return True

    def _script(self, name):
        return os.path.join(self.home, "scripts", "herd", name)

    def post_comment(self, cand, kind, body):
        """POST a PR comment via ``gh pr comment`` — the hold/merge notify actuator's forensic
        surface (contract §5.6, HERD-448). Best-effort, mirroring bash's ``_gh_timeout ... pr
        comment ... || true``: the caller's once-guard already fired before this runs, so a failed
        post is NEVER retried — it is journaled instead (``hold_comment_failed``), the only durable
        record a comment was ever attempted, and the hold/merge decision already taken above is
        never altered either way."""
        try:
            subprocess.run(["gh", "pr", "comment", str(cand.pr), "--body", body],
                           capture_output=True, text=True, check=True, timeout=_HOLD_COMMENT_TIMEOUT)
            return True
        except Exception:
            self.journal.append("hold_comment_failed", "pr", cand.pr, "sha", cand.sha,
                                "slug", cand.slug, "kind", kind)
            return False

    def edit_comment(self, cand, kind, body):
        """EDIT the last comment THIS identity posted on the PR, in place (HERD-464, contract
        §5.6): ``gh pr comment <pr> --edit-last`` — no comment id ever needs tracking, since gh
        resolves "last comment by the authenticated user" itself. This is the supersession
        actuator: a hold comment that stopped reflecting reality (a new sha landed, an approval
        landed, or a policy change made re-holding it impossible) is corrected in place instead of
        left standing to mislead an operator. Same fail-soft contract as :meth:`post_comment`: the
        caller's once-guard already fired before this runs, so a failed edit is never retried —
        only journaled (``hold_comment_edit_failed``) as the durable record one was attempted."""
        try:
            subprocess.run(["gh", "pr", "comment", str(cand.pr), "--edit-last", "--body", body],
                           capture_output=True, text=True, check=True, timeout=_HOLD_COMMENT_TIMEOUT)
            return True
        except Exception:
            self.journal.append("hold_comment_edit_failed", "pr", cand.pr, "sha", cand.sha,
                                "slug", cand.slug, "kind", kind)
            return False

    def notify(self, title, body, sound="default"):
        """Fire a desktop-style notification through the driver seam (``herd_driver_notify``,
        ``scripts/herd/driver.sh notify``) — NEVER a hardcoded runtime, so a headless project gets
        the durable notifications.log sink and a herdr-claude project gets the real desktop banner,
        with no branch here caring which. NEVER fails (mirrors the bash seam's own contract) — no
        journal, no exception ever escapes."""
        try:
            subprocess.run(["bash", self._script("driver.sh"), "notify", title, body, sound],
                           capture_output=True, text=True, timeout=_HOLD_NOTIFY_TIMEOUT)
        except Exception:
            pass

    def reap(self, cand):
        # REAP-ON-MERGE: this fires the instant THIS tick merged ``cand`` on green gates. It used to
        # reap UNCONDITIONALLY here on the assumption that the builder is DONE the moment its PR merges
        # — false: the coordinator can re-task the SAME builder onto a red (a CI failure, a post-merge
        # finding) BEFORE this tick's own merge runs, and this reap fired seconds later, force-removing
        # the worktree mid-edit with the fix never committed (PR #560, 2026-07-30, HERD-444). The
        # HERD-356 liveness gate ("a still-WORKING builder defers the reap") used to live ONLY in the
        # bash sweep (``sweep.sh:sweep_leg_worktrees`` / ``retirement.sh:retire_classify``, both keying
        # off ``_reap_agent_working``) on the theory that THIS seat's own reap-on-merge never needed it.
        # It does. Apply the SAME two-part check here — dirt first (a paused/crashed agent can leave
        # real edits behind even when not currently "working"), then a fresh liveness read — and defer
        # instead of reaping when either is unsafe. Deferring costs nothing: the bash watcher STILL owns
        # the resident `while true` loop and every sweep even under ``ENGINE_IMPL=python`` (module
        # docstring, "Bash stays the resident supervisor"), so with no open PR left on this branch the
        # very next bash tick re-classifies the worktree MERGED and drives the teardown once it is
        # actually safe — with retirement.sh's own bounded timeout guarding a genuinely wedged agent.
        if self._agent_lookup(cand.slug)[0] == "working" or self.worktree_dirty(cand):
            self.journal.append("reap_deferred", "pr", cand.pr, "slug", cand.slug, "sha", cand.sha,
                                "reason", "merged-worktree-live")
            return False
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

    def dispatch_resolver(self, cand):
        """Best-effort, fire-and-forget spawn of the EXISTING conflict resolver
        (``scripts/herd/herd-resolve.sh``) for a stale-base hold with nobody to bounce (HERD-584,
        mirrors ``agent-watch.sh``'s ``spawn_resolver``). ``herd-resolve.sh`` itself returns as soon as
        the resolver's tab/pane is up — it never blocks for the resolver agent's own run — so this call
        is bounded the same conservative way every other driver-seam shell-out in this module is. Never
        raises: a failed dispatch (missing script, herdr unavailable, a non-worktree slug) is read by
        the caller as "nobody healed this", which falls through to the honest needs-you escalation the
        same way a wake that never landed does."""
        env = dict(os.environ)
        env["HERD_RESOLVE_PR"] = str(cand.pr)
        env["HERD_RESOLVE_SHA"] = str(cand.sha)
        try:
            out = subprocess.run(["bash", self._script("herd-resolve.sh"), str(cand.slug)],
                                 capture_output=True, text=True, env=env,
                                 timeout=_RESOLVER_DISPATCH_TIMEOUT)
        except Exception:
            return False
        return out.returncode == 0

    def peek_status(self, cand):
        """HERD-420: a READ-ONLY pane-status read for the post-bounce completion check — the same
        fresh ``herdr agent list`` roster :meth:`wake_builder` consults, but never types into the
        pane. Reuses ``_agent_lookup`` (multi-seat contract: always the observed roster, never a
        dispatching seat's cache)."""
        return self._agent_lookup(cand.slug)[0]

    def worktree_dirty(self, cand):
        """HERD-420: True iff ``cand.worktree`` carries UNCOMMITTED TRACKED changes (staged or
        unstaged) — untracked files do NOT count, mirroring bash's narrow ``_finish_stall_dirty``
        (agent-watch.sh:10813) rather than wedge's broader definition: a stray scratch file must
        not read as "the fix is sitting right there uncommitted." Fail-soft: no worktree path, or
        any git-status fault, reads as clean (never escalates the round on a probe failure)."""
        if not cand.worktree:
            return False
        try:
            out = subprocess.run(["git", "-C", cand.worktree, "status", "--porcelain"],
                                 capture_output=True, text=True, timeout=10)
        except Exception:
            return False
        for line in (out.stdout or "").splitlines():
            if not line.startswith("??"):
                return True
        return False


# ── the live tick: the minimal correct loop ───────────────────────────────────────────────────────

class LiveTick:
    """Walk every discovered candidate through the gate DAG to a terminal, actuating on green.

    Construct with the resolved config, a discovery, a gates dispatcher, an actuator and a journal;
    :meth:`run` processes the tick and returns a summary the tests assert on. The gate ORDER is the
    cost-classed DAG (contract §2.1): stale/dup (cheap) → health (slow) → review (LLM) → blessing →
    hold decision → apply, a non-pass at any stage short-circuiting the rest. The pure hold/merge/
    observe decision is :func:`herd.decisions.hold_decision`, reused verbatim.
    """

    def __init__(self, config, discovery, gates, actuator, journal, state=None, hold_source=None):
        self.config = config or {}
        self.discovery = discovery
        self.gates = gates
        self.actuator = actuator
        self.journal = journal
        # The §5.4/§5.5 hold INPUTS (HERD-442). A :class:`LiveHoldSource` on the live path resolves
        # hv_hold from the PR body and `approved` from the ledger `herd-approve.sh` writes; ``None``
        # (fixture / dry-run) leaves both fields exactly as the scenario injected them, so every sim
        # and every existing unit fixture is byte-identical to before this was restored.
        self.hold_source = hold_source
        # The shared on-disk state ($TREES) — used here for the once-per-(pr,sha) hold guards (§5.3).
        # None → a black-hole LiveState (no dir): a sim/dry-run tick has no cross-tick state and never
        # writes a marker, so the fixture path stays hermetic.
        self.state = state if state is not None else LiveState(None)
        # Per-tick memo (HERD-446): a LiveTick instance lives exactly one tick (fresh per --tick), so
        # caching here caps the cross-seat identity probe (`gh api user`) at ONE call per tick no
        # matter how many blessed candidates walk the guard this round (mirrors _main_health_pending_memo).
        self._xseat_identity_cache = None
        # HERD-459 transition-dedupe memo. The lifecycle RE-ENTRY generation (:meth:`_transition_generation`)
        # is read from the shared refix ledger; like the identity probe above it is resolved at most ONCE
        # per tick (the ledger is a single global file, so one parse serves every candidate this round).
        self._refix_rows_cache = None
        self._transition_gen_cache = {}
        self._merge_policy = D.effective_merge_policy(
            self.config.get("MERGE_POLICY"), self.config.get("WATCHER_AUTOMERGE"))
        self._hv_policy = self.config.get("HUMAN_VERIFY_POLICY", "hold")
        # GATE_STATUS master lever (HERD-194 contract): on (default) → post the herd/gates commit status
        # on gates-clear; off → byte-inert (no post, no journal, no ledger). Consumed at the blessing seam.
        self._gate_status = str(self.config.get("GATE_STATUS", "on") or "on")
        # GATE_STATUS_PENDING (HERD-453) — SHIP-DORMANT, STRICT. off (default, and every unrecognized
        # value) → byte-identical to the SUCCESS-ONLY contract: no pending post, no journal, no ledger.
        # See :meth:`_gate_status_pending_enabled` for why this is opt-in rather than the default.
        self._gate_status_pending = _gate_status_pending_enabled(self.config)
        self._state = {}       # pr -> lifecycle state (the assertion layer)
        self._outcome = {}     # pr -> terminal action string
        # MERGE_FAIRNESS / starvation freeze (§6.2, HERD-340). OFF (default) → _fairness False and
        # _starved always empty, so the merge path below is byte-identical to before this feature.
        self._fairness = _merge_fairness_enabled(self.config)
        self._starve_threshold = _starve_threshold(self.config)
        self._starved = set()  # PRs that are head-of-line-starved THIS tick (drives the sibling freeze)
        # MERGE_QUEUE / ordered integration queue (§6.3, HERD-273). OFF (default) → _queue False and
        # _queue_front always None, so the merge path below is byte-identical to before this feature.
        self._queue = _merge_queue_enabled(self.config)
        self._queue_front = None   # this tick's queue-front pr (resolved by _queue_prepass, once)

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

        # 2. DURABLE LATCH (HERD-576): a rail already latched exhausted stays exhausted — a cheap,
        #    restart-safe short-circuit that never re-derives the count, so a new sha on an already-
        #    spent rail escalates even if the ledger scan below were ever wrong. See the latch's own
        #    docstring (above _refix_escalated_path) for why this is a SEPARATE fact from the ledger.
        if _refix_rail_escalated(state_dir, pr_str, kind):
            return None, (D.refix_budget_reason(rows, pr_str, kind, self.config.get("REFIX_MAX_ROUNDS"))
                          or "refix limit reached")

        # 3. Budget check: exhausted → needs-you escalation, no bounce. Latch it durably so this rail
        #    STOPS bouncing from here on, across any restart, until its red genuinely resolves.
        reason = D.refix_budget_reason(rows, pr_str, kind, self.config.get("REFIX_MAX_ROUNDS"))
        if reason:
            _mark_refix_rail_escalated(state_dir, pr_str, kind)
            return None, reason

        # 4. Fresh (pr, sha, kind) with budget remaining → record the bounce.
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

    def _maybe_arm_review_escalation(self, cand):
        """Port of agent-watch.sh:_maybe_arm_review_escalation — called right after a fresh REVIEW
        refix bounce is recorded. Arms off the LIFETIME review-bounce count
        (``D.refix_round_count_kind``), NOT ``_refix_check_and_record``'s rail-budget round number: a
        rail reset (written on every review PASS, ``_refix_rail_reset``) zeroes the BUDGET but must
        never erase the EVIDENCE that the cheap reviewer already missed this PR across multiple rounds
        — exactly what ``refix_round_count_kind``'s own docstring says it exists for ("read only to
        arm a stronger-reviewer escalation … so a rail reset must not erase it"). Concretely: bounce
        (rail=1, lifetime=1) -> fix pushed, review PASSes and resets the rail (rail=0, lifetime=1) ->
        a LATER sha bounces review again (rail=1, lifetime=2) — the rail-budget number alone would
        never reach the default threshold of 2, so this RE-SCANS the ledger for the lifetime count,
        mirroring bash's own ``refix_round_count_kind "$pr" review`` re-read rather than reusing the
        rail's round number. Ship-dormant: see :func:`_review_evidence_escalate_rounds` for why a
        garbage threshold fails to "never arm"."""
        threshold = _review_evidence_escalate_rounds(self.config)
        if threshold is None:
            return
        rows = D.parse_refix_ledger(_read_refix_ledger(self.state.dir))
        lifetime = D.refix_round_count_kind(rows, str(cand.pr), "review")
        if lifetime < threshold:
            return
        esc_file = self.state.review_escalate_file(cand.pr)
        if not esc_file:
            return
        try:
            with open(esc_file, "w", encoding="utf-8"):
                pass
        except OSError:
            pass

    def _health_gen_hint_suffix(self, cand):
        """HERD-576 leg 2: `` · <hint>`` when this PR's cached health verdict was stamped under an
        older gate-config generation than the one running THIS tick, else ``""`` (byte-identical
        append — every caller can unconditionally concatenate this). See
        herd.decisions.gate_config_generation_hint for the fail-soft "no cached generation, no
        hint" rule (a verdict cached before this feature existed never false-flags)."""
        cached_gen = self.state.health_cached_generation(cand)
        current_gen = D.gate_config_generation(self.config)
        hint = D.gate_config_generation_hint(cached_gen, current_gen)
        return " · %s" % hint if hint else ""

    def _refix_rail_reset(self, cand, kind,
                          reason="rail resolved its red — per-rail refix budget restored"):
        """Append a ``reset`` row when the rail has unresolved bounces (fail-soft no-op otherwise).

        Mirrors ``refix_rail_reset`` (``agent-watch.sh:7300``): only writes when the rail counter is
        > 0 so the ledger does not accumulate reset rows on a clean path, and journals
        ``refix_rail_reset`` so the coordinator sees the rail budget restored. ``reason`` defaults to
        the refund-on-green wording; :meth:`_bounce_and_wake` (HERD-370) overrides it for the OTHER
        refund case — an unwoken bounce, where the red is emphatically NOT resolved."""
        state_dir = self.state.dir
        # The rail's red resolved — the durable exhaustion latch (HERD-576) must never outlive that
        # fact, even when the ledger scan below finds nothing left to zero (a stale/hand-planted
        # marker, or a reset raced ahead of a bounce this same tick).
        _clear_refix_rail_escalated(state_dir, str(cand.pr), kind)
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
        if kind == "stale":
            # HERD-566: the stale-base rail's fresh-bounce call always passes an explicit `prompt`
            # (the live detected overlap reason), so this generic fallback is reached only if a
            # future caller omits it — mirrors stale-dup-gate.sh's mechanical re-task text.
            base = str(self.config.get("DEFAULT_BRANCH") or os.environ.get("DEFAULT_BRANCH") or "main")
            return ("PR #%s is held: STALE BASE — files this branch touches were changed on %s "
                    "after the branch's merge-base, so a clean merge would silently clobber newer "
                    "work.\nThis is a MECHANICAL fix (not a judgment call). From your worktree:\n"
                    "  git fetch\n  git merge %s\n"
                    "Resolve any conflicts PRESERVING both sides' intent, run the healthcheck, then "
                    "push (normal push, NEVER force, NEVER push to the default branch)." %
                    (cand.pr, base, base))
        # HERD-559: a PRE-GATE block never reached a model, so there is no review to read and no
        # comment to reply to — the canned prompt below would send the builder hunting for a finding
        # that was never posted. Name the mechanical red instead and point at the light healthcheck,
        # which runs the SAME shared lints locally, so the builder can reproduce and fix it directly.
        source = ""
        if hasattr(self.state, "recorded_review_source"):
            source = self.state.recorded_review_source(cand.pr, cand.sha) or ""
        if source == "pregate":
            reason = self.state.recorded_review_reason(cand.pr, cand.sha) or "a mechanical lint red"
            return ("PR #%s was blocked BEFORE the adversarial review by the mechanical pre-gate: %s.\n"
                    "No reviewer was dispatched — the deterministic lint set found a red your diff "
                    "introduced. Reproduce it locally with "
                    "`bash scripts/herd/healthcheck.sh <your worktree> --light` (it runs the same "
                    "shared lints), fix every finding, and push. The review runs automatically once "
                    "the diff is mechanically clean." % (cand.pr, reason))
        return ("PR #%s was review-blocked.\n"
                "Read the full review: gh pr view %s\n"
                "Fix every issue the reviewer raised, run the healthcheck, push your fix, and "
                "reply to the review comment once done." % (cand.pr, cand.pr))

    def _refix_finish_prompt(self, cand, kind):
        """HERD-420: the post-bounce completion nudge — distinct from :meth:`_refix_prompt` because
        the builder does not need to be told the ORIGINAL problem again (it already woke for that);
        it needs to be told the wake did not finish the job. Grounding incident: PR #531 woke,
        edited ``bin/herd``, then read done again with the edit never committed or pushed — the PR
        head sat on the still-blocked sha with nobody watching for exactly this gap."""
        return ("PR #%s: you were re-tasked for a %s failure and your pane went back to idle/done, "
                "but no new commit has reached this PR — the head sha is still %s. If you have "
                "uncommitted or unpushed work in your worktree, finish it now: commit it, push it, "
                "and confirm (git log / gh pr view %s) that the PR head sha moved. If you believe "
                "the fix already left the worktree, run git status and git log again — something "
                "did not make it out." % (cand.pr,
                                          {"health": "healthcheck", "stale": "stale base"}.get(
                                              kind, "review"),
                                          cand.sha, cand.pr))

    def _bounce_and_wake(self, cand, kind, round_num, rule, prompt=None, no_wake_fallback=None):
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

        ``no_wake_fallback``, when given, is tried BEFORE that escalation: a callable taking ``cand``
        and returning True iff it durably handled the "nobody woke" case itself (and already journaled
        its own record of doing so) — that still counts as a live bounce (:data:`BLOCK`, the round is
        NOT refunded) rather than an escalation. Only the stale-base rail passes one today (HERD-584:
        dispatch the existing conflict resolver rather than escalate a MECHANICAL fix to a human); the
        health/review rails pass none, so their no-wake path is unchanged.

        Returns :data:`BLOCK` (bounce landed on a live builder, wait for its push) or :data:`ESCALATE`
        (nobody is on it — needs-you). ``prompt`` overrides the canned re-task text — the HERD-420
        completion leg passes its own "finish your uncommitted work" nudge through this same seam
        rather than the original problem statement.
        """
        prompt = prompt if prompt is not None else self._refix_prompt(cand, kind)
        wake = self.actuator.wake_builder(cand, prompt)
        # CHAOS SEAM (mid_refix_bounce, HERD-425): the once-guard ledger row for this (pr, sha, kind)
        # was already appended by the caller's _refix_check_and_record BEFORE _bounce_and_wake was even
        # invoked, so it is already durable when a death happens here — a restart's own
        # _refix_check_and_record sees it and holds silently, never re-actuating the wake. A hard
        # death here models "the builder was genuinely woken, the journal pair
        # (refix_bounce/refix_wake_result) never landed": the wake side effect is not undone and is
        # never repeated, only its completion RECORD is missing. The safe, honest convergence is:
        # hold silently (never a second wake, never a duplicate bounce) — exactly the same
        # "already bounced" path a normal budget-spent tick takes.
        _chaos_kill("mid_refix_bounce")
        status_before = wake.status_before or "unknown"
        self.journal.append("refix_bounce", "pr", cand.pr, "sha", cand.sha, "slug", cand.slug,
                            "round", round_num, "agent_status_before", status_before,
                            "rule", rule, "location", "")
        if not wake.woke and no_wake_fallback is not None and no_wake_fallback(cand):
            self.journal.append("refix_wake_result", "pr", cand.pr, "sha", cand.sha, "slug", cand.slug,
                                "round", round_num, "agent_status_before", status_before,
                                "agent_status_after", wake.status_after or "unknown",
                                "woke", 0, "escalated", "false")
            return BLOCK
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

    def _stale_no_wake_fallback(self, cand):
        """The stale-base rail's ``no_wake_fallback`` for :meth:`_bounce_and_wake` (HERD-584): nobody
        is on the live pane to re-task with the merge-up, so dispatch the EXISTING conflict resolver
        (``herd-resolve.sh``) instead of escalating a MECHANICAL fix straight to a human — mirrors
        ``agent-watch.sh``'s ``_handle_stale_dup`` "NO LIVE BUILDER" branch, which reaches for the same
        tool. Requires an existing worktree to resolve in place; without one there is nothing to heal,
        so the caller's normal no-wake escalation stands unchanged. A failed dispatch (herdr down, the
        script missing) reads the same way: nobody healed this."""
        if not cand.worktree or not os.path.isdir(cand.worktree):
            return False
        if not self.actuator.dispatch_resolver(cand):
            return False
        self.journal.append("stale_base_autofix_bounce", "pr", cand.pr, "sha", cand.sha,
                            "slug", cand.slug,
                            "reason", "no live builder — dispatched the conflict resolver to merge "
                            "the base")
        return True

    _DONE_IDLE_STATUSES = ("done", "idle")

    def _refix_completion_incomplete(self, cand, kind):
        """HERD-420: the post-bounce COMPLETION check, reached only when :meth:`_refix_check_and_record`
        found the once-guard already holding (this exact ``(pr, sha, kind)`` has a recorded bounce, so
        the sha has not moved since). A paired ``refix_wake_result`` with ``woke=1`` proves the agent's
        pane came back to "working" — it does NOT prove the agent committed or pushed anything. Live
        incident: PR #531 woke, edited ``bin/herd``, then went back to "done" with the edit still sitting
        uncommitted in the worktree; the once-guard held silently and the PR sat BLOCKED on the same sha
        indefinitely, caught only because a human happened to look.

        If ``REFIX_COMPLETE_MIN`` minutes have passed since THIS round's bounce (:func:`D.refix_last_bounce_ts`)
        and the agent now reads done/idle again (a fresh, non-mutating :meth:`peek_status` — never another
        wake attempt), the round is INCOMPLETE: journal ``refix_incomplete`` (pr, sha, slug, kind, round,
        agent_status, dirty), then spend ANOTHER round of the SAME rail's budget through the SAME
        machinery :meth:`_refix_check_and_record`'s fresh-bounce branch uses (budget check, ledger
        append, :meth:`_bounce_and_wake`) — no parallel path, no separate cap. Budget exhausted → the
        same needs-you escalation the normal BLOCK path uses. A completion re-bounce re-arms the
        once-guard with a NEW bounce row/timestamp, so a LATER incomplete round (another full window
        with still no push) is a genuinely fresh detection, not a retrigger of this one — the state.once
        guard below is keyed on this round's bounce_ts specifically so it fires exactly once per round.

        Returns :data:`BLOCK` / :data:`ESCALATE` when the completion leg acted this tick, or ``None``
        when it does not apply (disabled, window not yet elapsed, agent still working/unreadable, or
        already handled this round) — the caller falls back to a plain silent :data:`BLOCK`, byte-identical
        to pre-HERD-420 behavior."""
        complete_min = D.refix_complete_min_num(self.config.get("REFIX_COMPLETE_MIN"))
        if complete_min <= 0:
            return None
        state_dir = self.state.dir
        rows = D.parse_refix_ledger(_read_refix_ledger(state_dir))
        pr_str, sha_str = str(cand.pr), str(cand.sha)
        bounce_ts = D.refix_last_bounce_ts(rows, pr_str, sha_str, kind)
        if not D.refix_complete_window_elapsed(_now_epoch(), bounce_ts, complete_min):
            return None
        status = str(self.actuator.peek_status(cand) or "")
        if status not in self._DONE_IDLE_STATUSES:
            return None
        # AT-MOST-ONCE per round: keyed on bounce_ts so a later round (a fresh bounce row, a fresh
        # timestamp) gets its own detection rather than being swallowed by this marker.
        if not self.state.once(cand.pr, cand.sha, "refix_incomplete_%s_%s" % (kind, bounce_ts)):
            return None
        dirty = self.actuator.worktree_dirty(cand)
        round_before = D.refix_rail_count(rows, pr_str, kind)
        self.journal.append("refix_incomplete", "pr", cand.pr, "sha", cand.sha, "slug", cand.slug,
                            "kind", kind, "round", round_before, "agent_status", status,
                            "dirty", "yes" if dirty else "no")
        reason = D.refix_budget_reason(rows, pr_str, kind, self.config.get("REFIX_MAX_ROUNDS"))
        if reason:
            if self.state.once(cand.pr, cand.sha, "refix_escalated_%s" % kind):
                total = D.refix_total_count(rows, pr_str)
                self.journal.append(
                    {"health": "health_refix_escalated", "stale": "stale_refix_escalated"}.get(
                        kind, "refix_escalated"),
                    "pr", cand.pr, "sha", cand.sha, "slug", cand.slug, "rounds", total,
                    "reason", reason + " — builder went silent without shipping a fix")
            return ESCALATE
        round_num = round_before + 1
        slug = str(cand.slug) if cand.slug else "-"
        _append_refix_ledger(state_dir,
                             "%s %s %s %s %s\n" % (_now_epoch(), cand.pr, cand.sha, slug, kind))
        rule = {"health": "healthcheck", "stale": "stale"}.get(kind, "review")
        return self._bounce_and_wake(cand, kind, round_num, rule,
                                     prompt=self._refix_finish_prompt(cand, kind))

    def _gate_status_enabled(self):
        """GATE_STATUS master lever — ``off`` disables the herd/gates commit-status post entirely
        (byte-inert: no post, no journal, no ledger). Any other value is on
        (agent-watch.sh:_gate_status_enabled — unknown value → on)."""
        return self._gate_status != "off"

    def _xseat_identity(self):
        """This seat's resolved identity for the cross-seat guard, memoized for the LIFE OF THE TICK
        (HERD-446) — see the cache comment in :meth:`__init__`."""
        if self._xseat_identity_cache is None:
            self._xseat_identity_cache = _resolve_owner(self.config) or ""
        return self._xseat_identity_cache

    # ── the lifecycle RE-ENTRY generation (HERD-459) ──────────────────────────────────────────────
    def _transition_generation(self, pr):
        """How many times this PR's gate walk has genuinely been RE-ENTERED — the lifetime refix-bounce
        count from the shared ledger (``D.refix_total_count``), memoized for the life of the tick.

        This is the second half of the transition-dedupe key (:meth:`_advance`). ``self._state`` is
        in-memory and a LiveTick lives exactly ONE tick, so every tick re-walks a still-open candidate
        from :data:`_S_INTAKE` and re-derives the SAME chain of edges off the same cached verdicts —
        that replay is what HERD-459 stops journaling. A new head sha re-arms the guard on its own (the
        sha is in the key), but a refix bounce that re-dispatches the SAME sha is also a genuine
        re-entry the operator must see, and the bounce ledger is exactly the durable record of one:
        it grows by one row per bounce and a rail RESET never refunds it, so it is a monotonic
        generation counter with no new state file of its own.

        Read ORDER matters: every ``_advance`` of a tick sees the generation as it stood at the START
        of that tick (this tick's own bounce row is appended by ``_refix_check_and_record`` AFTER the
        edges leading into the block were journaled), so the bumped generation lands on the NEXT tick —
        the tick that actually re-dispatches. Fail-soft: no ledger / no state dir reads as generation 0.
        """
        key = str(pr)
        if key not in self._transition_gen_cache:
            if self._refix_rows_cache is None:
                self._refix_rows_cache = D.parse_refix_ledger(_read_refix_ledger(self.state.dir))
            self._transition_gen_cache[key] = D.refix_total_count(self._refix_rows_cache, key)
        return self._transition_gen_cache[key]

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
        # HERD-459: journal this edge ONCE per (pr, sha, from, to, trigger, re-entry generation) — the
        # same reconciled once-guard ledger the §5.3 holds use, not a new substrate. Without it a PR
        # parked on one verdict re-journals its whole INTAKE→…→BLOCKED chain every ~6s poll tick (GH
        # #573 measured ~88k events/day from ONE idle blocked PR): `herd why` — the doctrine-mandated
        # first diagnostic — drowns, and the journal ages real history out through JOURNAL_MAX_MB
        # rotation. A genuinely CHANGING lifecycle is byte-identical to before: a new sha, a new edge,
        # a new trigger on the same edge, or a re-entry after a bounce all miss the marker and journal.
        # ``trigger`` is in the key deliberately (the §6 holds share the BLESSED→HOLD edge across four
        # distinct triggers — merge_frozen / queue_wait / cross_seat_block / decide_hold — and which
        # one fired is exactly the forensic bit `herd why` is read for). With NO state dir — every sim,
        # fixture and dry-run tick — ``once`` always proceeds, so those journals never change at all.
        if self.state.once(cand.pr, cand.sha, "state_%s_%s_%s_%s" % (
                self._transition_generation(cand.pr), prev, nxt, event)):
            self.journal.append("live_state", "pr", cand.pr, "sha", cand.sha, "trigger", event,
                                "state_from", prev, "state_to", nxt)
        return nxt

    # ── merge fairness / starvation freeze (§6.2, HERD-340) ───────────────────────────────────────
    def _effective_laps(self, cand):
        """This PR's re-stale lap total: the persistent ledger count (live), else the fixture-injected
        ``restale_laps`` (a sim with a black-hole state dir carries the laps on the candidate)."""
        n = self.state.restale_count(cand.pr)
        return n if n > 0 else int(getattr(cand, "restale_laps", 0) or 0)

    # ── the §5.4/§5.5 hold INPUTS (HERD-442) ──────────────────────────────────────────────────────
    def _resolve_hold_inputs(self, cand):
        """Resolve ``cand.hv_hold`` + ``cand.approved`` from the live world. False ⇒ HOLD, do not merge.

        A strict NO-OP without a ``hold_source`` (every fixture, sim and dry-run tick), so those keep
        whatever the scenario injected and this restoration cannot move a single existing assertion.

        On the live path it mirrors bash's merge gate exactly (agent-watch.sh ``_tick_act``):

          * the body is read ONLY in ``auto`` mode — ``approve``/``observe`` already hold every PR, so
            the marker is moot there and bash never spent the fetch;
          * the branch is on the READ, not on its emptiness (HERD-237): a non-zero rc journals
            ``hv_body_unreadable`` and returns False (hold), because the only safe reading of "we
            cannot see" in front of a merge is HOLD;
          * ``approved`` is the sha-keyed row `herd-approve.sh` wrote, read fresh every tick — a
            just-granted approval must release the hold on the very next tick.
        """
        if self.hold_source is None:
            return True
        cand.approved = bool(self.hold_source.approved(cand.pr, cand.sha))
        if self._merge_policy != "auto":
            return True
        body, rc = self.hold_source.hv_body(cand.pr)
        if rc != 0:
            self.journal.append(
                "hv_body_unreadable", "pr", cand.pr, "sha", cand.sha, "slug", cand.slug, "rc", rc,
                "detail", "cannot read the PR body — holding rather than merging a possibly "
                          "human-verify PR")
            return False
        cand.hv_body = body
        cand.hv_hold = _human_verify.has(body)
        return True

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

    # ── ordered integration queue / merge train (§6.3, HERD-273) ─────────────────────────────────
    def _queue_eligible(self, cand):
        """True iff ``cand`` currently holds a QUEUE POSITION — "eligible" (task HERD-273): not stale,
        and a merge policy that would land it once its gates clear (the SAME pure test
        :meth:`_would_automerge` already uses for the fairness freeze).

        Deliberately NOT "blessed this tick" — membership does not wait on this tick's (base-
        sensitive) health outcome at all, so it is available from a candidate's VERY FIRST tick (no
        cold-start lag: a lone ready candidate merges immediately, exactly as with the lever off) AND
        it never silently lapses while a previously-assigned front is mid-re-verification against a
        moved virtual tip (§6.4) or genuinely stuck (CODEERROR/CONFLICT). :meth:`_queue_prepass` picks
        the front from this same set every tick, and :meth:`_walk` never promotes a non-front
        candidate no matter how green its own gates are — that is exactly what makes "a red/
        conflicting head cannot let later candidates merge past it" true. The tradeoff, by design and
        documented posture (mirrors HERD-296's resolver-owned CONFLICT, which carries no refix budget
        of its own): a front stuck needs-you or in a standing conflict blocks the WHOLE queue until a
        human/resolver clears it (a new sha, or closing the PR) — row-truth (§5.1) makes that stall
        loud, never silent; throughput is deliberately not this PR's concern (task HERD-273: batch/
        speculative slots are out of scope for the ordering primitive).
        """
        if cand.stale:
            return False
        return self._would_automerge(cand)

    def _queue_prepass(self, candidates):
        """Resolve THIS tick's queue front BEFORE any candidate is walked (§6.3, HERD-273) — the same
        prepass shape as :meth:`_fairness_prepass`. A strict NO-OP when ``MERGE_QUEUE`` is off:
        ``_queue_front`` stays ``None``, so :meth:`_walk`'s queue branch is never taken and the merge
        path is byte-identical to before this feature.

        The front is the MINIMUM pr (:func:`_queue_sort_key`, a stable total order every seat derives
        identically with no shared ledger) among :meth:`_queue_eligible` candidates — "treat its front
        as the only merge head for the window" (task HERD-273): at most one candidate applies a merge
        this tick, and it is always the deterministically-first queue member, never whichever candidate
        merely happened to turn green first.
        """
        if not self._queue:
            return
        eligible = [c for c in candidates if self._queue_eligible(c)]
        if not eligible:
            self._queue_front = None
            return
        front = min(eligible, key=lambda c: _queue_sort_key(c.pr))
        self._queue_front = front.pr
        self.journal.append("merge_queue_window", "front_pr", front.pr, "front_sha", front.sha,
                            "eligible", len(eligible))

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
                for path, sha in st.stale_inflight(".health-inflight", cand.pr, cur, journal=self.journal):
                    if _terminate_worker(path):
                        st.rm(path, st.health_dispatch_file_sha(cand.pr, sha),
                              st.health_result_file_sha(cand.pr, sha),
                              st.health_log_file_sha(cand.pr, sha))
                        self.journal.append("gate_superseded", "pr", cand.pr, "rail", "health",
                                            "old_sha", sha, "new_sha", cur, "action", "session_kill")
                # review rail — terminate the stale reviewer's subtree, retire its stamped pane, reap scratch.
                for path, sha in st.stale_inflight(".review-inflight", cand.pr, cur, journal=self.journal):
                    if _terminate_worker(path):
                        pane = st.read_review_pane(cand.pr, sha)
                        st.rm(path, st.review_result_file_sha(cand.pr, sha),
                              st.review_registry_file_sha(cand.pr, sha))
                        self.journal.append("gate_superseded", "pr", cand.pr, "rail", "review",
                                            "old_sha", sha, "new_sha", cur, "action", "pane_retired",
                                            "pane", pane)
                # merge-result-gate rail (§6.4, HERD-296) — same session-kill cancel, plus tear down the
                # doomed sha's throwaway merged worktree so a superseded head never leaks temporary state.
                # BYTE-INERT with the lever off: no ``.merge-result-inflight-*`` marker is ever written,
                # so this glob is always empty and nothing is journaled.
                for path, sha in st.stale_inflight(".merge-result-inflight", cand.pr, cur, journal=self.journal):
                    if _terminate_worker(path):
                        st.rm(path, st.merge_result_dispatch_file_sha(cand.pr, sha),
                              st.merge_result_log_file_sha(cand.pr, sha))
                        _remove_merge_tree(cand.worktree, st.merge_result_tree_path_sha(cand.pr, sha))
                        self.journal.append("gate_superseded", "pr", cand.pr, "rail", "merge_result",
                                            "old_sha", sha, "new_sha", cur, "action", "session_kill")
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

        # 0. INFRA circuit breaker (HERD-110, gate READ restored HERD-447; contract §2.1 step 1) — the
        #    GLOBAL "env looks dead" halt, consulted before ANY rail dispatch, mirroring where bash's
        #    deleted _tick_act called _breaker_gate at the very top of its per-candidate loop body
        #    (agent-watch.sh ede7d45^:11550). BLOCKED skips this candidate entirely — no health, no
        #    review, not even a poll of an already-in-flight worker — for EVERY candidate but the one
        #    admitted as the single half-open PROBE, which falls through and dispatches exactly like a
        #    closed breaker. Byte-inert (no file I/O) under INFRA_BREAKER_MAX unset/0 — see
        #    _breaker_gate. cand.pr's own lifecycle state stays put; _advance degrades to a harmless
        #    illegal_transition line (never fatal) if this candidate was mid-rail when the breaker
        #    tripped, exactly like every other cross-cutting hold in this walk.
        if _breaker_gate(cand.pr, self.state, self.config) == "BLOCKED":
            self._advance(cand, "breaker_open")
            return HOLD

        # 0b. GATE-CYCLE START: post herd/gates=pending so the PR page says WHY it is waiting
        #     (GATE_STATUS_PENDING, HERD-453). Placed here — past the breaker, before the first rail —
        #     because this IS the moment the cycle begins for this (pr, sha): everything below either
        #     dispatches a rail or holds with a reason, and both are "in progress" from the page's seat.
        #     At-most-once per (pr, sha) via the same ledger the success post uses, and the marker is
        #     recorded only on a landed write, so a network blip retries next tick. Byte-inert with the
        #     lever off (the default) or GATE_STATUS=off: no post, no journal, no ledger row.
        if (self._gate_status_pending and self._gate_status_enabled() and cand.sha
                and not self.state.posted(cand.pr, cand.sha, "gate_status")
                and not self.state.posted(cand.pr, cand.sha, "gate_status_pending")):
            if self.actuator.post_gate_status_pending(cand):
                self.state.record_posted(cand.pr, cand.sha, "gate_status_pending")

        # 1. stale/dup gate (HERD-188, restored HERD-566): the deterministic duplicate-ref / stale-base
        #    file-overlap check (:func:`_stale_dup_check`), LIVE-ONLY like cross-seat (4a below) — a
        #    fixture/dry-run/sim tick shells no `gh`/`git` here and this branch is a strict no-op, so
        #    the whole existing test suite stays byte-identical. RESET-ON-PROGRESS (HERD-229): every
        #    tick this proceeds (lever off, or neither condition provable) refunds the stale rail's
        #    refix budget, mirroring stale-dup-gate.sh's caller exactly.
        if self.hold_source is not None:
            _sd_kind, _sd_reason = _stale_dup_check(cand, self.config)
            if _sd_kind is None:
                self._refix_rail_reset(cand, "stale")
            else:
                if self.state.once(cand.pr, cand.sha, "stale_dup_hold"):
                    self.journal.append("stale_dup_hold", "pr", cand.pr, "sha", cand.sha,
                                        "slug", cand.slug, "kind", _sd_kind, "reason", _sd_reason)
                self._advance(cand, "stale_detected")
                if _sd_kind == "duplicate":
                    # DUPLICATE is a judgment call — always human. Never autofix, never consume a
                    # refix round (stale-dup-gate.sh:_handle_stale_dup).
                    self._advance(cand, "refix_exhausted")
                    return ESCALATE
                # kind == "stale-base": mechanical — OFF (default) is byte-identical to the pre-
                # HERD-199 hold (🛑 needs-you, no bounce, no ledger); ON drives the SAME three-way
                # bounce gate health/review already use, reusing its budget/wake/escalate machinery
                # verbatim for a third rail (agent-watch.sh's "stale" refix-ledger kind).
                if not _stale_base_autofix_enabled(self.config):
                    return HOLD
                _sd_round, _sd_budget_reason = self._refix_check_and_record(cand, "stale")
                if _sd_round is None and _sd_budget_reason is None:
                    outcome = self._refix_completion_incomplete(cand, "stale")
                    return outcome if outcome is not None else BLOCK
                if _sd_budget_reason is not None:
                    if self.state.once(cand.pr, cand.sha, "refix_escalated_stale"):
                        rows_after = D.parse_refix_ledger(_read_refix_ledger(self.state.dir))
                        total = D.refix_total_count(rows_after, str(cand.pr))
                        self.journal.append("stale_refix_escalated", "pr", cand.pr, "sha", cand.sha,
                                            "slug", cand.slug, "rounds", total,
                                            "reason", _sd_budget_reason + " — stale base still held")
                    self._advance(cand, "refix_exhausted")
                    return ESCALATE
                _sd_base = str(self.config.get("DEFAULT_BRANCH") or os.environ.get("DEFAULT_BRANCH")
                              or "main")
                _sd_prompt = (
                    "PR #%s is held: STALE BASE — files this branch touches were changed on %s "
                    "after the branch's merge-base, so a clean merge would silently clobber newer "
                    "work.\nThis is a MECHANICAL fix (not a judgment call). From your worktree:\n"
                    "  git fetch\n  git merge %s\n"
                    "Resolve any conflicts PRESERVING both sides' intent, run the healthcheck, then "
                    "push (normal push, NEVER force, NEVER push to the default branch).\n"
                    "Why: %s" % (cand.pr, _sd_base, _sd_base, _sd_reason))
                return self._bounce_and_wake(cand, "stale", _sd_round, "stale", prompt=_sd_prompt,
                                             no_wake_fallback=self._stale_no_wake_fallback)

        # 1b. stale/dup gate (deterministic-cheap): a behind-base PR HOLDS — parking is always safe.
        if cand.stale:
            if self.state.once(cand.pr, cand.sha, "stale"):
                self.journal.append("stale_dup_hold", "pr", cand.pr, "sha", cand.sha, "slug", cand.slug,
                                    "kind", "stale", "reason", "behind base")
            self._advance(cand, "stale_detected")
            return HOLD

        # 2. health rail (deterministic-slow) — DISPATCHED async by shelling out to the health runner
        #    (the dispatch/started event is journaled by the gate, only on an actual dispatch).
        health = self.gates.health(cand)
        # 2a. MERGE_RESULT_GATE (§6.4, HERD-296): materializing the candidate tree hit a real conflict
        #     against the current base — resolver-owned, folded into the SAME honest hold path as the
        #     stale/dup gate above (once-guarded, no bounce, never cached as a red). Unreachable with the
        #     lever off (the gate never returns this sentinel), so the branch is byte-inert by default.
        if health == "CONFLICT":
            self._advance(cand, "dispatch_health")
            if self.state.once(cand.pr, cand.sha, "merge_result_conflict"):
                self.journal.append("stale_dup_hold", "pr", cand.pr, "sha", cand.sha, "slug", cand.slug,
                                    "kind", "merge_result_conflict",
                                    "reason", "merge conflict against base — resolver-owned")
            self._advance(cand, "merge_result_conflict")
            return HOLD
        health = health if health in ("CLEAN", "FLAKY", "CODEERROR", WAIT) else "CLEAN"
        if health == WAIT:
            # HERD-459: "still waiting" is a PHASE, not an event — journal it once per (pr, sha, phase),
            # not once per poll tick. A suite can sit in flight for many minutes and the 100th identical
            # row tells the operator nothing the 1st did not; live_tick_start/live_tick_end already carry
            # per-tick liveness. Re-arms on a new sha (the key is sha-scoped), and the phase CHANGE is
            # still visible because `health_queued` (LiveGates.health) carries its own separate marker.
            if self.state.once(cand.pr, cand.sha, "health_pending"):
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
            # HERD-576 leg 2: a STANDING red (this sha's verdict came from the cache, `reused_health`
            # true — not freshly collected THIS tick) whose stamped generation predates the gate
            # config running right now means an operator released a changed gate posture WHILE this
            # red sat cached. Checked every tick (independent of bounce/hold/escalate) but journaled
            # at most once per (pr, sha) — a fresh collect always stamps the CURRENT generation, so
            # this can only ever fire on a REUSED cache entry, never a same-tick fresh one.
            if getattr(self.gates, "reused_health", False):
                hint = self._health_gen_hint_suffix(cand)
                if hint and self.state.once(cand.pr, cand.sha, "health_gen_hint"):
                    self.journal.append("health_gate_config_stale", "pr", cand.pr, "sha", cand.sha,
                                        "slug", cand.slug, "detail", hint.lstrip(" ·"))
            # Three-way bounce gate (HERD-358).  See _refix_check_and_record for the semantics.
            round_num, reason = self._refix_check_and_record(cand, "health")
            if round_num is None and reason is None:
                # Once-guard: already bounced for this (pr, sha, kind) — hold silently while the
                # agent works (bash: refix_attempted true + _active_fix_note check at :8334-8338).
                # HERD-420: unless REFIX_COMPLETE_MIN has elapsed with the agent back to done/idle
                # and still no new sha — then this is an INCOMPLETE round, not a live one.
                outcome = self._refix_completion_incomplete(cand, "health")
                return outcome if outcome is not None else BLOCK
            if reason is not None:
                # Budget exhausted → needs-you escalation, no bounce.
                if self.state.once(cand.pr, cand.sha, "refix_escalated_health"):
                    rows_after = D.parse_refix_ledger(_read_refix_ledger(self.state.dir))
                    total = D.refix_total_count(rows_after, str(cand.pr))
                    escalated_reason = reason + " — health-check still red" + self._health_gen_hint_suffix(cand)
                    self.journal.append("health_refix_escalated", "pr", cand.pr, "sha", cand.sha,
                                        "slug", cand.slug, "rounds", total,
                                        "reason", escalated_reason)
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
            # INFRA circuit breaker RECORD (HERD-110, restored HERD-447; agent-watch.sh:_review_gate_step
            # non-verdict branch): a non-verdict reviewer death counts against the GLOBAL consecutive
            # counter — never a real BLOCK, so it must never be cached as one, but it DOES feed the
            # breaker. No-op under INFRA_BREAKER_MAX unset/0 (_breaker_record_infra).
            _breaker_record_infra(self.state, self.config, self.journal)
            return ESCALATE
        if not getattr(self.gates, "reused_review", False):
            # HERD-473: the verdict's REASON rides the same event (contract §3.2/§3.4). Read back from
            # the LEDGER the rail just wrote rather than re-parsed here, so the journal and the ledger
            # are the same string by construction and can never drift. Appended ONLY when non-empty:
            # a PASS, a reason-less legacy reviewer line, and every sim/fixture tick journal a
            # byte-identical `verdict_recorded` to the one they journaled before this field existed.
            # HERD-559: the provenance is READ BACK from the ledger row the rail just wrote rather
            # than hardcoded "reviewer" — the review rail can now also produce a `pregate` BLOCK, and a
            # deterministic lint refusal journaled as a model's finding would misdescribe the record
            # for every downstream reader. A legacy/absent source reads back "reviewer", so every
            # pre-HERD-559 path journals byte-identically.
            _vsource = "reviewer"
            if hasattr(self.state, "recorded_review_source"):
                _vsource = self.state.recorded_review_source(cand.pr, cand.sha) or "reviewer"
            _vfields = ["pr", cand.pr, "sha", cand.sha, "value", verdict, "source", _vsource]
            _vreason = self.state.recorded_review_reason(cand.pr, cand.sha)
            if _vreason:
                _vfields += ["reason", _vreason]
            self.journal.append("verdict_recorded", *_vfields)
            # INFRA circuit breaker RECORD (HERD-110, restored HERD-447; agent-watch.sh:_review_gate_step
            # PASS/BLOCK branches): a REAL verdict proves the env is alive — reset + close the breaker.
            # Gated on `reused_review` exactly like the verdict_recorded journal above it: a cache-hit
            # replay of an already-recorded verdict proves nothing NEW about the env this tick, mirroring
            # bash's _review_gate_step contract ("called once per tick for a candidate with no ledger
            # verdict yet" — the merge path never re-invokes it once a verdict is cached).
            _breaker_record_ok(self.state, self.config, self.journal)
        self._advance(cand, "review_block" if verdict == "BLOCK" else "review_pass")
        if verdict == "BLOCK":
            # Three-way bounce gate (HERD-358).  See _refix_check_and_record for the semantics.
            round_num, reason = self._refix_check_and_record(cand, "review")
            if round_num is None and reason is None:
                # Once-guard: already bounced for this (pr, sha, kind) — hold silently.
                # HERD-420: unless REFIX_COMPLETE_MIN has elapsed with the agent back to done/idle
                # and still no new sha — then this is an INCOMPLETE round, not a live one.
                outcome = self._refix_completion_incomplete(cand, "review")
                return outcome if outcome is not None else BLOCK
            if reason is not None:
                # Budget exhausted → needs-you escalation, no bounce.
                if self.state.once(cand.pr, cand.sha, "refix_escalated_review"):
                    rows_after = D.parse_refix_ledger(_read_refix_ledger(self.state.dir))
                    total = D.refix_total_count(rows_after, str(cand.pr))
                    self.journal.append("refix_escalated", "pr", cand.pr, "sha", cand.sha,
                                        "slug", cand.slug, "rounds", total,
                                        "reason", reason + " — review still blocked")
                    # HERD-473: a standing BLOCK that has run out of refix budget is now a HUMAN's
                    # problem, and the human's only surfaces are the PR and `herd approve why`. Post the
                    # reviewer's stated reason to the PR through the SAME comment actuator (§5.6,
                    # HERD-448) the hold branches use, under the SAME once-guard, so a re-walked blocked
                    # PR never re-posts. The grounding incident (#576): the reviewer's reasoning reached
                    # neither the PR nor any reader, leaving a coordinator to choose between a blind
                    # `herd approve override` and nothing.
                    self.actuator.post_comment(
                        cand, "review-block",
                        _review_block_comment(cand, self.state.recorded_review_reason(cand.pr, cand.sha)))
                return ESCALATE
            # EVIDENCE-TRIGGERED ESCALATION (HERD-580 port): a fresh REVIEW-kind bounce that has now
            # accumulated >= REVIEW_EVIDENCE_ESCALATE_ROUNDS rounds is evidence the cheap reviewer
            # missed the real issue — arm a one-shot Opus escalation for this PR's NEXT review dispatch
            # (consumed in LiveGates.review). Placed right after the bounce is recorded, mirroring
            # bash's `_maybe_arm_review_escalation "$pr"` call right after `record_refix`.
            self._maybe_arm_review_escalation(cand)
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

        # 4a. CROSS-SEAT BLOCK precedence (HERD-247, restored HERD-446). Re-establish the invariant from
        #     SHARED state before the blessing is posted and before any merge is attempted: this seat's
        #     own green gates are a second opinion, not a resolution of a BLOCK another seat is still
        #     standing behind on this EXACT sha (the PR #343 incident — a BLOCK from ANY seat is TERMINAL
        #     until resolved by a sha-keyed human override or a newer PASS from that SAME seat). ONE
        #     shared check (_cross_seat_block_standing), reused verbatim at the gate-status setter too
        #     (LiveActuator.post_gate_status) — multi-seat doctrine Rule 2. Unconditional on GATE_STATUS:
        #     runs even under GATE_STATUS=off, because the hazard it guards (a blind merge) is
        #     independent of whether the blessing posts. FAIL-SOFT: an unreadable scan reports no block
        #     and this tick behaves exactly as it did before the guard existed.
        #
        #     LIVE-ONLY (mirrors _resolve_hold_inputs, HERD-442): gated on `hold_source`, the SAME signal
        #     that marks a genuine live tick — `_run_live_tick` is the only caller that constructs one.
        #     A fixture/dry-run tick (every existing test, the --dry-run smoke CLI) must invoke NO
        #     subprocess at all (the VERIFY discipline this module's docstring documents); without this
        #     gate, EVERY blessed fixture candidate would shell out to `gh api user`/`gh pr view` here.
        if self.hold_source is not None:
            seat, degraded = _cross_seat_block_standing(cand.pr, cand.sha, self.state, self.config,
                                                         me=self._xseat_identity())
            if degraded:
                if self.state.once(cand.pr, cand.sha, "xseat_degraded"):
                    self.journal.append("cross_seat_block_scan", "pr", cand.pr, "sha", cand.sha,
                                        "state", "degraded", "reason", degraded)
            elif seat:
                if self.state.once(cand.pr, cand.sha, "xseat_honored_merge"):
                    self.journal.append("cross_seat_block_honored", "pr", cand.pr, "sha", cand.sha,
                                        "seat", seat, "stage", "merge",
                                        "reason", "cross-seat BLOCK standing (seat %s)" % seat)
                self._advance(cand, "cross_seat_block")
                return HOLD

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
        #    Its two INPUTS are resolved from the live world first (HERD-442, restoring what P5b took
        #    out with the bash action pass). An unreadable PR body FAILS CLOSED — hold this tick, no
        #    ledger row, re-gate next tick — so a transient gh fault costs one tick instead of blind-
        #    merging a PR whose declared manual steps were never run.
        #    No lifecycle transition on that path, deliberately: the PR stays BLESSED (bash simply
        #    `continue`d) so the recovery tick re-decides from the same state rather than replaying a
        #    hold it never really entered.
        if not self._resolve_hold_inputs(cand):
            return HOLD
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

        # 5c. MERGE_QUEUE ordering (§6.3, HERD-273): the front of the deterministic queue — resolved
        #     once per tick by _queue_prepass, BEFORE any candidate walked — is the ONLY candidate this
        #     window may actually apply a merge. Every OTHER candidate that would otherwise merge now
        #     HOLDS instead, even one whose own gates are green: two blessed siblings never land out of
        #     queue order, and a front stuck red/CONFLICT blocks every later position too (nobody is
        #     promoted to fill its slot this window — see _queue_eligible). Off / this candidate already
        #     IS the front → the branch is never taken and the decide+apply below are byte-identical.
        if action == "MERGE" and self._queue and str(cand.pr) != str(self._queue_front):
            self._advance(cand, "queue_wait")                  # BLESSED --queue_wait--> HOLD
            if self.state.once(cand.pr, cand.sha, "queue_hold"):
                self.journal.append("merge_queue_hold", "pr", cand.pr, "sha", cand.sha,
                                    "slug", cand.slug, "front_pr", self._queue_front or "")
            return HOLD

        self._advance(cand, {"MERGE": "decide_merge", "HOLD": "decide_hold",
                             "OBSERVE": "decide_observe"}[action])

        # 5d. HOLD-COMMENT SUPERSESSION (HERD-464, contract §5.6): `action` here is the FINAL,
        #     post-freeze decision — edit any hold comment this PR is carrying that no longer
        #     reflects reality BEFORE applying that decision, so the correction lands on the SAME
        #     tick the state actually changed.
        self._supersede_hold_comment(cand, action)

        # 6. apply — the ONLY step that actuates (and only under LiveActuator).
        if action == "MERGE":
            # HUMAN_VERIFY_POLICY=auto (HERD-59, restored in HERD-439): a PR that DECLARED HUMAN-VERIFY
            # steps merges on green with those steps recorded as INFORMATIONAL — the journal line is what
            # makes it explicit and auditable that they were never human-executed. Bash journaled this
            # right before do_merge (agent-watch.sh `_tick_act`); HERD-306 P5b deleted the bash action
            # pass and the port never re-emitted it, leaving `human_verify_policy` a CONSUMER-ONLY event
            # (journal-audit.sh's §5.4 reader and fixture_extract.py's HV_HOLD mapping both still parse
            # it) with no producer — so an auto-merged human-verify PR left no forensic trace at all.
            # Once per (pr, sha), mirroring bash's hv_informed_noted/record_hv_informed ledger guard.
            # STRICTLY INERT on the default policy: HUMAN_VERIFY_POLICY=hold never reaches this branch
            # with hv_hold set (hold_decision returns HOLD), so the default stream is byte-identical.
            if cand.hv_hold and self._hv_policy == "auto" \
                    and self.state.once(cand.pr, cand.sha, "hv_informed"):
                # The ledger twin of that journal line (bash record_hv_informed). approvals.sh calls
                # `hv-informed` "a record, NOT an approval", and approval_state reports it as the
                # strongest row when no approval exists — so an auditor can tell "merged with steps
                # nobody ran" from "merged after a human signed off" from the PRE-merge window too.
                self.state.record_approval("hv-informed", cand.pr, cand.sha)
                self.journal.append("human_verify_policy", "pr", cand.pr, "sha", cand.sha,
                                    "slug", cand.slug, "policy", "auto",
                                    "action", "merged-with-declared-steps")
                # The comment that makes the merge NOTICEABLE (contract §5.6, HERD-448): this is
                # exactly the branch that went unnoticed 19 days with no actuator at all — the PR
                # looked normally merged while its declared steps were silently never run. Bash
                # comment-only here, no notify (agent-watch.sh:11916, ede7d45^): the PR already
                # merged, there is nothing left to action, only to record.
                self.actuator.post_comment(cand, "hv-auto", _hv_auto_comment(cand))
            # HOLD RELEASED (HERD-442). A PR that WAS held — by the approve policy, or by its own
            # HUMAN-VERIFY block under a non-auto HUMAN_VERIFY_POLICY — and now carries a sha-keyed
            # approval is about to merge. Bash journaled this immediately before do_merge and the P5b
            # deletion took it with everything else, leaving `hold_released` a CONSUMER-ONLY event:
            # `herd why` (bin/herd:6694, why.py:63) renders it and the fleet inbox + digest
            # (fleet.sh:1239/:1521) use it to CLEAR the held flag — so without it every approved-then-
            # merged PR stayed "needs-you: approval hold" in the fleet view until the row aged out.
            # Ordered before the merge, exactly as bash did, so the release is on record even if the
            # merge itself is then refused. Byte-inert when nothing was held (`held` false).
            held = (self._merge_policy == "approve"
                    or (cand.hv_hold and self._hv_policy != "auto"))
            if held:
                self.journal.append("hold_released", "pr", cand.pr, "sha", cand.sha,
                                    "slug", cand.slug, "kind", _hold_kind(cand.hv_hold),
                                    "reason", "approved")
            if self.actuator.merge(cand):
                self.state.clear_merge_refusal(cand.pr, cand.sha)
                # A merge is TERMINAL for approval state: drop every row for this PR (bash do_merge's
                # purge_pr_approvals, HERD-90). Left behind, an old sha's `awaiting` row is a phantom
                # hold that `herd approve list` keeps surfacing for a long-merged PR.
                self.state.purge_pr_approvals(cand.pr)
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
                # The awaiting row `herd-approve.sh` reads (HERD-442). WITHOUT it `herd approve <pr#>`
                # exits 1 with "No awaiting approval record found" — i.e. an engine that holds a PR but
                # writes no row holds it FOREVER, with no documented way out. Bash wrote it here, in
                # exactly this once-per-sha branch (record_approval_awaiting); a new sha re-holds and
                # writes a fresh row. No-op without a ledger path, so a sim writes nothing.
                self.state.record_approval("awaiting", cand.pr, cand.sha)
                fields = ["pr", cand.pr, "sha", cand.sha, "slug", cand.slug,
                          "kind", _hold_kind(cand.hv_hold)]
                # HUMAN_VERIFY_POLICY=coordinator (HERD-59, restored in HERD-439): still a HOLD, but the
                # hold event carries the policy so a post-mortem can tell a coordinator-actionable hold
                # (a coordinator/agent is expected to run the steps, then approve) from a plain
                # human-verify hold waiting on a person. Bash appended exactly this field to
                # hold_applied; HERD-306 P5b dropped it with the bash action pass. Absent on the
                # default policy, so a `hold`-policy hold_applied line stays byte-identical.
                if cand.hv_hold and self._hv_policy == "coordinator":
                    fields += ["human_verify_policy", "coordinator"]
                self.journal.append("hold_applied", *fields)
                # A hold is not silent (contract §5.6, HERD-448): comment + operator notify, once
                # per (pr, sha) — the SAME once-guard above already gates this block, so a re-walked
                # held PR never re-posts.
                self._apply_hold_actuation(cand)
            return HOLD
        # OBSERVE — observe mode never merges.
        if self.state.once(cand.pr, cand.sha, "observe"):
            self.journal.append("observe_noted", "pr", cand.pr, "sha", cand.sha, "slug", cand.slug)
            self.actuator.notify(
                "🐑 PR #%s ready (observe)" % cand.pr,
                "%s: review passed — observe mode, not merging" % cand.slug)
        return "OBSERVE"

    def _apply_hold_actuation(self, cand):
        """POST the once-per-(pr,sha) hold comment + fire the operator notify (contract §5.6,
        HERD-448). Which template fires depends on WHY this candidate held — mirrors bash's
        three-way branch verbatim (agent-watch.sh:11878-11901, ede7d45^): a coordinator-actionable
        HUMAN-VERIFY hold, a human-actionable HUMAN-VERIFY hold, or a plain approve-policy hold.
        Fail-soft throughout: :meth:`LiveActuator.post_comment` journals its own failure
        (``hold_comment_failed``) and :meth:`notify` never raises — neither can alter the hold
        decision already taken by the caller."""
        if cand.hv_hold and self._hv_policy == "coordinator":
            posted = self.actuator.post_comment(cand, "coordinator", _hold_coordinator_comment(cand))
            self.actuator.notify(
                "🐑 PR #%s human-verify — coordinator action needed" % cand.pr,
                "%s: gates passed — a coordinator/agent should run the steps then herd approve %s"
                % (cand.slug, cand.pr))
        elif cand.hv_hold:
            posted = self.actuator.post_comment(cand, "human-verify", _hold_human_verify_comment(cand))
            self.actuator.notify(
                "🐑 PR #%s human-verify pending" % cand.pr,
                "%s: gates passed — verify manual steps, then herd approve %s" % (cand.slug, cand.pr))
        else:
            posted = self.actuator.post_comment(cand, "approve", _hold_approve_comment(cand))
            self.actuator.notify(
                "🐑 PR #%s awaiting approval" % cand.pr,
                "%s: gates passed — herd approve %s" % (cand.slug, cand.pr))
        # Remember WHICH (pr, sha) is carrying a live hold comment (HERD-464) — the sole marker
        # :meth:`_supersede_hold_comment` globs to find a comment that later stops reflecting
        # reality. Recorded only on a successful post, mirroring `posted`'s own success-only
        # contract elsewhere (a failed post already journaled `hold_comment_failed` above and has
        # nothing on the PR yet to supersede).
        if posted:
            self.state.record_posted(cand.pr, cand.sha, "hold_comment")

    def _supersede_hold_comment(self, cand, action):
        """EDIT a previously-posted hold comment IN PLACE once it stops reflecting reality
        (HERD-464, contract §5.6): a new sha superseded it, an approval landed, or a policy
        change made re-holding it impossible. A stale hold comment left standing is the exact
        cost this restores — it misled an operator into believing a merge-ready PR was still
        human-gated.

        Two triggers, both discovered off the SAME `hold_comment` post-marker
        :meth:`_apply_hold_actuation` writes:

          (a) a marker for an OLDER sha than `cand.sha` — this PR moved on; that comment now
              names the wrong commit no matter what this tick decides for the new one.
          (b) a marker for `cand.sha` ITSELF, but `action` (the FINAL, post-freeze decision) is
              no longer HOLD — the very commit the comment described was resolved by an approval
              or a policy change, without a new commit ever landing.

        Guarded by the SAME `LiveState.once` doctrine as every other hold side effect (§5.3): each
        (pr, sha) pair is superseded at most once, so a re-walked tick never double-edits. No-op
        with no state dir (a sim/dry-run tick carries no cross-tick marker to discover)."""
        st = self.state
        if not st.dir:
            return
        for path, old_sha in st.stale_inflight(".live-posted-hold_comment", cand.pr, cand.sha, journal=self.journal):
            if not st.once(cand.pr, old_sha, "hold_comment_superseded"):
                continue
            reason = _hold_superseded_reason(cand, old_sha, action, self._hv_policy, cand.approved)
            if self.actuator.edit_comment(cand, "superseded", _hold_superseded_comment(cand, reason)):
                self.journal.append("hold_comment_superseded", "pr", cand.pr, "sha", cand.sha,
                                    "old_sha", old_sha, "slug", cand.slug, "reason", reason)
        if (action != "HOLD" and cand.sha
                and st.posted(cand.pr, cand.sha, "hold_comment")
                and st.once(cand.pr, cand.sha, "hold_comment_superseded")):
            reason = _hold_superseded_reason(cand, cand.sha, action, self._hv_policy, cand.approved)
            if self.actuator.edit_comment(cand, "superseded", _hold_superseded_comment(cand, reason)):
                self.journal.append("hold_comment_superseded", "pr", cand.pr, "sha", cand.sha,
                                    "old_sha", cand.sha, "slug", cand.slug, "reason", reason)

    def _rate_limited_summary(self, until):
        """The calm, non-faulting tick result for a gh rate-limit backoff window (HERD-582): no
        candidates walked, no gate/merge dispatch — REMOTE legs are skipped until ``until`` (an epoch).
        Never raises, so ``main`` exits 0 and the bash watchdog's fault streak is untouched, exactly as
        a genuine outage must NOT be (that path still raises and still faults)."""
        return {"outcomes": {}, "merged": [], "held": [], "pending": [], "journal": self.journal.path,
                "rate_limited": True, "rate_limited_until": until}

    def run(self):
        """Run one tick over all discovered candidates; return the summary."""
        # gh rate-limit backoff (HERD-582), checked BEFORE any discovery call: a still-active window
        # from a PRIOR tick's classified rate limit skips the gh round-trip entirely rather than
        # re-drawing the same rejection tick after tick — local legs (bash's render/reconcile/sweeps)
        # keep running regardless, since they never go through this Python tick at all.
        until = self.state.gh_rate_limited_until()
        now = int(_now_epoch())
        if until and now < until:
            return self._rate_limited_summary(until)
        try:
            candidates = self.discovery.discover()
        except GhRateLimited as exc:
            reset = exc.reset_at if exc.reset_at is not None else now + _GH_RATE_LIMIT_DEFAULT_COOLDOWN_SECONDS
            until = reset + _GH_RATE_LIMIT_BUFFER_SECONDS
            self.state.set_gh_rate_limited_until(until)
            self.journal.append("engine_rate_limited", "reset", reset, "until", until)
            return self._rate_limited_summary(until)
        self.state.clear_gh_rate_limited()
        self.journal.append("live_tick_start", "candidates", len(candidates), "impl", "python",
                            "merge_policy", self._merge_policy)
        # Discovery → supersession-cancel (§2.4/§6.1): before the gate walk, TERM the doomed in-flight
        # workers any candidate has moved past, so a superseded sha never holds a rail slot or races a
        # fresh dispatch. No-op with no state dir / no stale marker (byte-inert when nothing superseded).
        self._supersede_stale(candidates)

        # Resolve this tick's starvation state before any candidate is walked (§6.2, HERD-340). A strict
        # no-op under MERGE_FAIRNESS=off, so the loop below stays byte-identical to before this feature.
        self._fairness_prepass(candidates)
        # Resolve this tick's queue front before any candidate is walked (§6.3, HERD-273). A strict
        # no-op under MERGE_QUEUE=off, so the loop below stays byte-identical to before this feature.
        self._queue_prepass(candidates)
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

# _CORE_ENV_KEYS (HERD-449) — THE single authoritative list of every config knob this engine core
# resolves from os.environ. herd-config.sh MUST `export` each one (a plain `: "${KEY:=default}"` var
# is invisible to this module's subprocess — see engine-version.sh:herd_engine_live_tick, which spawns
# `python3 -m herd.live_runtime --tick` as a CHILD process that inherits only the EXPORTED shell env).
# A key present here but unexported silently falls back to this module's built-in default no matter
# what a project's .herd/config says — the exact bug class HERD-449 fixed for HEALTH_CONCURRENCY /
# REVIEW_CONCURRENCY (three prior items, HERD-353/345/359, each fixed ONE such key for a different
# knob). scripts/herd/env-export-lint.sh imports this tuple directly (not a text scrape) so the lint
# can never drift from the actual consumer list, and fails LOUDLY on any member herd-config.sh sets
# but does not export.
_BREAKER_KEYS = ("INFRA_BREAKER_MAX", "INFRA_BREAKER_COOLDOWN")

# HERD-559 review fast path: the pre-gate lever, the mechanical-floor lever + its ceilings, the
# tiering activation lever, the latency-telemetry lever, and the tiering keys the ported classifier
# reads (they were only ever consumed by the bash reference path before, so none of them crossed into
# this child process — the very gap that left the tiering dormant on the live core).
_REVIEW_FASTPATH_KEYS = ("REVIEW_PREGATE", "REVIEW_MECH_FLOOR", "REVIEW_MECH_FLOOR_MAXFILES",
                         "REVIEW_MECH_FLOOR_MAXLINES", "REVIEW_TIERING", "REVIEW_LATENCY",
                         "REVIEW_ESCALATE_GLOB", "REVIEW_ESCALATE_MAXFILES", "DOCS_ONLY_GLOB",
                         "REVIEW_MODEL_CHEAP", "REVIEW_MODEL_DOCS")

_CORE_ENV_KEYS = (("MERGE_POLICY", "WATCHER_AUTOMERGE", "HUMAN_VERIFY_POLICY",
                    "MERGE_METHOD", "DELETE_BRANCH_ON_MERGE", "REFIX_MAX_ROUNDS", "REFIX_COMPLETE_MIN",
                    "HERD_REFIX_WAIT_TIMEOUT", "WORK_UNIT_KIND", "MERGE_RESULT_GATE", "MERGE_QUEUE",
                    "HEALTH_TRUST_BUILDER")
                   + _CONCURRENCY_KEYS + _WATCHER_KEYS + _FAIRNESS_KEYS + _BREAKER_KEYS
                   + _REVIEW_FASTPATH_KEYS)


def _config_from_env(scenario=None):
    config = dict((scenario or {}).get("config") or {})
    # WORK_UNIT_KIND (HERD-403): carried into the assembled config so herd.work_unit.resolve_adapter
    # can read it from the SAME dict this tick already builds. Nothing in this module branches on it
    # yet — the key is inert here, read only by the unwired adapter skeleton.
    for knob in _CORE_ENV_KEYS:
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
    actuator = DryRunActuator(journal) if dry else LiveActuator(home, journal, config, state)
    # The §5.4/§5.5 hold inputs, LIVE ONLY (HERD-442): the PR body and the approvals ledger. Passed
    # here and nowhere else, so a dry-run / fixture tick never shells out to `gh` for a body and never
    # overrides a scenario-injected hv_hold/approved.
    tick = LiveTick(config, _GraphQLDiscovery(config), LiveGates(home, state, journal, config),
                    actuator, journal, state=state,
                    hold_source=LiveHoldSource(state, config))
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
