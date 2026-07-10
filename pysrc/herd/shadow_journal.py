"""herd.shadow_journal — the shadow watcher's append-only journal (HERD-316, P3c, EPIC HERD-300).

Part of the strangler port of the engine core. This is the P3 SHADOW-MODE writer: the Python
watcher (:mod:`herd.shadow_runtime`) runs BESIDE the live bash watcher in DRY-RUN mode and its
sole output is a journal — so the P3 acceptance gate can diff the two event streams (same inputs
→ same events; ``docs/spikes/engine-port-python.md`` §3, P3). Two hard rules make that safe:

  1. **A SEPARATE FILE.** The shadow journal is ``.herd/journal-shadow.jsonl``, NEVER the live
     ``.herd/journal.jsonl`` the bash engine owns. The shadow runtime mutates NOTHING the real
     engine reads — the journal-shadow file is the entire footprint of a shadow run (the DRY-RUN
     non-negotiable: no gh, no merges, no pane ops, writes ONLY to journal-shadow.jsonl).

  2. **BYTE-IDENTICAL EVENT SHAPES.** Every line this writer emits is encoded to be
     indistinguishable from what ``scripts/herd/journal.sh`` would have written for the same
     ``(event, kv…)``, so the parity diff compares like with like. The port MUST NOT change the
     journal schema — it is the cross-implementation parity oracle (contract §7, journal.sh §3.1).

This module therefore re-implements ``journal.sh``'s encoding contract in stdlib Python, faithful
to the bash down to the JSON separators:

  * ``{"ts": …, "event": …}`` FIRST, in that order, then the caller's key/value pairs in order
    (``journal.sh:134``). Python dicts preserve insertion order, matching the bash construction.
  * ``ts`` comes from ONE UTC source (:func:`_journal_ts`, mirroring ``journal.sh:33``) —
    ISO-8601, always ``Z``-suffixed — with the ``HERD_JOURNAL_NOW`` test seam that overrides the
    clock with a caller-supplied string (``journal.sh:34``). No caller formats its own time.
  * Integer-looking values serialize as JSON NUMBERS, everything else as strings, using the exact
    bash predicate ``v and v.lstrip("-").isdigit()`` (``journal.sh:141``–:145). ``"-"`` alone,
    ``""`` and non-digit strings stay strings; ``"-5"``/``"007"`` become ``-5``/``7`` — same as the
    bash ``int(v)``.
  * ``json.dumps(obj, separators=(",", ":"), ensure_ascii=False)`` — the identical serialization
    call ``journal.sh:147`` shells out to.
  * ONE ``O_APPEND`` write of ``line + "\n"`` (``journal.sh:152``); each line stays well under
    PIPE_BUF so concurrent shadow writers interleave whole lines with no lock (journal.sh §"ATOMIC").

And faithful to the bash SAFETY contract: :func:`ShadowJournal.append` is BEST-EFFORT and SILENT —
it wraps its work so an unwritable path, a missing directory it cannot create, or any encoding
error simply drops the entry and returns; it NEVER raises into the shadow runtime's task graph
(``journal_append`` "ALWAYS returns 0", journal.sh §CONTRACT). A dropped shadow entry is a parity
miss, never a crash.

Stdlib-only (the P1 packaging rule): no third-party deps. Run indirectly via
:mod:`herd.shadow_runtime`; unit-driven by ``tests/test_shadow_runtime.py``.
"""

import json
import os


def _journal_ts():
    """THE single UTC timestamp source — ISO-8601, ``Z``-suffixed (mirrors ``journal.sh:33``).

    ``HERD_JOURNAL_NOW`` (the shared test seam, ``journal.sh:34``) overrides the clock outright so a
    unit can assert a deterministic ``ts``; otherwise ``datetime.now(timezone.utc)`` formatted
    exactly as the bash ``date -u +%Y-%m-%dT%H:%M:%SZ``. Routing every write through here is the
    same discipline journal.sh enforces — a local-clock writer once poisoned ``herd why`` chronology
    with a future ``Z`` timestamp, and one UTC helper makes that unrepresentable (journal.sh §33).
    """
    override = os.environ.get("HERD_JOURNAL_NOW")
    if override:
        return override
    # Imported lazily so importing this module never touches the clock (parallels the bash lazy
    # `date` call) and so the HERD_JOURNAL_NOW fast path stays allocation-free.
    from datetime import datetime, timezone

    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _coerce(value):
    """Bash-parity value coercion: an integer-looking value → ``int``, everything else → ``str``.

    Reproduces ``journal.sh:141``–:145 EXACTLY, including the leading-``-`` handling:
    ``str(value)`` then, iff the string is non-empty AND ``s.lstrip("-").isdigit()``, ``int(s)``.
    So ``"5"``/``5`` → ``5``, ``"-5"`` → ``-5``, ``"007"`` → ``7`` (matching the bash ``int("007")``),
    while ``""``, ``"-"``, ``"1.5"``, ``"abc"`` and ``"5s"`` stay strings. A ``bool`` is normalized
    to its digit string first (``True`` → ``"True"`` stays a string — bash never passes a bool), and
    ``None`` becomes the empty string, matching a bash empty-arg.
    """
    if value is None:
        s = ""
    elif value is True or value is False:
        # bash has no bool; a caller that passes one gets the stringy form, never a JSON true/false.
        s = "true" if value else "false"
    else:
        s = str(value)
    if s and s.lstrip("-").isdigit():
        try:
            return int(s)
        except ValueError:
            return s
    return s


def encode_event(event, pairs, ts=None):
    """Encode ONE event to the exact JSON line ``journal.sh`` would write (no I/O).

    ``pairs`` is a flat sequence ``[k1, v1, k2, v2, …]`` (the ``journal_append`` argv shape) OR an
    iterable of ``(k, v)`` tuples OR a mapping — all normalized to ordered key/value pairs. The
    object is ``{"ts", "event"}`` then the pairs in order; values pass through :func:`_coerce`;
    serialization is ``separators=(",", ":")`` with ``ensure_ascii=False`` (``journal.sh:147``).
    Exposed separately from :func:`ShadowJournal.append` so the parity test can assert the encoding
    without a filesystem.
    """
    obj = {"ts": _journal_ts() if ts is None else ts, "event": str(event)}
    for k, v in _iter_pairs(pairs):
        obj[str(k)] = _coerce(v)
    return json.dumps(obj, separators=(",", ":"), ensure_ascii=False)


def _iter_pairs(pairs):
    """Yield ``(k, v)`` from a flat ``[k, v, …]`` list, a ``(k, v)`` iterable, or a mapping.

    A flat list with an odd length drops its trailing key with no value — the same lenient shape
    the bash loop has (``range(0, len(a) - 1, 2)``, ``journal.sh:136``): a dangling final key is
    ignored rather than raising.
    """
    if pairs is None:
        return
    if hasattr(pairs, "items"):
        for k, v in pairs.items():
            yield k, v
        return
    seq = list(pairs)
    if seq and not isinstance(seq[0], (tuple, list)):
        # flat [k, v, k, v, …]
        for i in range(0, len(seq) - 1, 2):
            yield seq[i], seq[i + 1]
        return
    for kv in seq:
        yield kv[0], kv[1]


class ShadowJournal:
    """A best-effort, silent, append-only writer for ``.herd/journal-shadow.jsonl``.

    Construct with an explicit ``path`` (the hermetic tests do) or let :meth:`resolve_path` derive
    ``<WORKTREES_DIR>/.herd/journal-shadow.jsonl`` — deliberately a DIFFERENT basename from the live
    journal so a shadow run can never write the real forensic substrate. All writes go through
    :meth:`append`, which mirrors ``journal_append``'s contract: it never raises, never blocks the
    caller, and returns ``True``/``False`` only as an advisory "did the line land" the parity test
    can assert — a shadow runtime coroutine ignores the return exactly as bash ignores the rc.
    """

    #: The fixed basename. NEVER "journal.jsonl" — that file is the live bash engine's.
    BASENAME = "journal-shadow.jsonl"

    def __init__(self, path=None):
        self.path = path or self.resolve_path()

    @classmethod
    def resolve_path(cls):
        """Resolve the shadow-journal path from the environment, or ``None`` if none is derivable.

        Precedence: ``SHADOW_JOURNAL_FILE`` (explicit test/override seam) wins; else
        ``<WORKTREES_DIR>/.herd/<BASENAME>`` (the same ``WORKTREES_DIR`` anchor ``journal.sh`` uses,
        journal.sh:73). ``None`` when neither is set — a caller with no destination drops entries,
        exactly as the bash writer does.
        """
        override = os.environ.get("SHADOW_JOURNAL_FILE")
        if override:
            return override
        base = os.environ.get("WORKTREES_DIR")
        if not base:
            return None
        return os.path.join(base, ".herd", cls.BASENAME)

    def append(self, event, *pairs, **kv):
        """Append one event. BEST-EFFORT and SILENT — never raises into the caller.

        ``event`` is the event name; positional ``pairs`` is either a flat ``k, v, k, v, …`` argv
        (the ``journal_append`` call shape) or already-``(k, v)`` tuples; keyword ``**kv`` is a
        convenience for Python callers (appended after the positional pairs, insertion-ordered).
        The whole body runs under a broad ``except`` so a read-only FS, an un-creatable directory,
        or an encoding fault drops the entry and returns ``False`` — the shadow runtime's task
        graph is never torn down by a journal hiccup (journal.sh §CONTRACT: "ALWAYS returns 0").
        """
        try:
            path = self.path
            if not path:
                return False
            # Normalize the positional argv into (k, v) pairs, then tack on any kwargs.
            flat = list(pairs)
            items = list(_iter_pairs(flat))
            items.extend(kv.items())
            line = encode_event(event, items)
            if not line:
                return False
            directory = os.path.dirname(path)
            if directory and not os.path.isdir(directory):
                os.makedirs(directory, exist_ok=True)
            # One O_APPEND write of a sub-PIPE_BUF line ⇒ concurrent-writer safe, no lock
            # (journal.sh:151-152). Open per-append (not a held handle) so the writer is
            # fork/async-safe and a rotated/removed file is transparently recreated.
            with open(path, "a", encoding="utf-8") as fh:
                fh.write(line + "\n")
            return True
        except Exception:
            # Silent by contract: a shadow-journal failure is a parity miss, never a crash.
            return False
