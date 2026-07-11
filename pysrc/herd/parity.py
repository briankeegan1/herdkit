"""herd.parity — the P3a journal-diff PARITY HARNESS (HERD-314, EPIC HERD-300).

The **acceptance instrument** for the engine port: a deterministic canonicalize-and-diff
over two journal event streams. P3 runs a Python shadow engine beside the bash engine and the
acceptance gate is a journal diff — *same inputs → same event stream* (spike
``docs/spikes/engine-port-python.md`` §3; contract ``docs/engine-contract.md`` §7 names the
journal schema "the cross-implementation parity oracle for P3 shadow mode"). This module is that
oracle's canonicalizer + differ; ``scripts/herd/sim/parity-run.sh`` is the orchestration that
drives a sim scenario and feeds the two journals in.

WHAT PARITY MEANS HERE. Two engines that process the SAME inputs must emit the SAME sequence of
journal events — but NOT byte-for-byte: every event carries a wall-clock ``ts``, workers carry a
``pid``, and log/worktree paths are absolute tmp paths. Those three categories are volatile and
carry no cross-implementation meaning, so canonicalization neutralizes them before the diff. The
event NAME, the ``pr``/``sha`` keys, the ``value``/``outcome``/``source`` — the semantic payload —
are preserved and compared. (The event catalog is contract ``docs/engine-contract.md`` §3.4.)

CANONICALIZATION (``canonicalize_event``), matching the item spec "strip timestamps/pids/paths,
stable field order":

  * ``ts``                      → ``"<TS>"``    (the ISO-8601 stamp from ``journal.sh:_journal_ts``)
  * ``pid`` / any ``*_pid`` key → ``"<PID>"``   (worker pids: review_dispatched, healthcheck_started)
  * every string VALUE          → absolute-path substrings collapsed to ``"<PATH>"`` (log_path, and
                                  any absolute path embedded in a value such as an absolute
                                  ``location`` prefix). A RELATIVE path (``app/greet.sh``) has no
                                  leading slash and is preserved as semantic; a ``sha``/``pin`` is
                                  hex/``base..sha`` with no leading slash and is preserved.
  * keys are SORTED             → stable field order, so a differing key-insertion order between
                                  two implementations never reads as a divergence.

The volatile categories are neutralized by VALUE (``<TS>``/``<PID>``/``<PATH>``) rather than
dropped, so a structural difference — a field PRESENT in one stream and ABSENT in the other — is
still caught; only the noisy value is erased.

SHADOW-PRIVATE FRAMES (oracle v2, HERD-325 leg 1). The Python shadow engine narrates its own run
with ``shadow_*`` diagnostic events (``shadow_tick_start``/``shadow_state``/``shadow_blessing``/…)
— its assertion layer over the real output, NOT engine events the bash tree ever emits. The oracle
canonicalizes them AWAY before the diff (:func:`is_shadow_private`), so the shadow's instrumentation
never reads as a divergence. The filter is namespaced to the ``shadow_`` PREFIX, which no REAL
engine family uses (the catalog is ``merge``/``verdict_recorded``/``main_health``/``push_hold_*``/…,
contract §3.4) — so a genuine engine event can NEVER be filtered. That is the load-bearing rule:
only the shadow's OWN diagnostics are dropped; real families pass through untouched.

THE DIFF (``compare``) is ALIGNMENT-based (oracle v2, HERD-325 leg 2), not positional. The old
positional diff compared event *N* to event *N*, so a SINGLE inserted or deleted event knocked every
following event out of position and cascaded into a wall of false divergences. The alignment differ
runs a longest-common-subsequence match (:mod:`difflib`) over the canonical event lines and reports
only the TRUE edits: an INSERT (present only in shadow), a DELETE (present only in real), or a
MUTATION (an aligned pair whose canonical payload differs). One offset stays one edit. Each edit
yields ONE readable divergence record (stream index, event name(s), the differing fields, and the
raw pre-canonicalization lines for forensics) — the item's "one readable divergence report per
mismatch".

EXIT CONTRACT (mirrors the reviewer's ``0/1/2`` in contract §2.2): ``0`` = identical after
canonicalization (parity), ``1`` = divergent (report printed), ``2`` = INFRA (a journal was
unreadable or held invalid JSON) — loud, never cached, never a silent green.

SELF-DIFF TODAY. With only the bash engine (P3c's shadow engine not yet built) the harness proves
its canonicalization end-to-end by diffing a real sim journal against a ``--perturb``-ed copy of
itself: the perturbation rewrites ONLY the volatile categories (a different ``ts``, a bumped
``pid``, a reprefixed absolute path), so canonicalization must fold them back to identity — a green
self-diff is a live proof that the ts/pid/path pipeline works on real journal data, not a tautology
over identical bytes. (Item: "Must work TODAY with only the bash engine — self-diff = trivially
identical — proves canonicalization.")

Stdlib-only (the P1 packaging rule, ``pysrc/herd/__init__.py``): no external deps, ``python3`` is
already a hard engine dependency. ZERO model calls, no config keys, no mutation of engine state —
a pure reader + a perturbation writer that only ever writes to stdout.
"""

import difflib
import json
import re
import sys

# A canonicalization token per volatile category. Distinct, self-describing, and — critically — not
# a value any real event field carries, so a collapse can never alias a genuine payload.
TS_TOKEN = "<TS>"
PID_TOKEN = "<PID>"
PATH_TOKEN = "<PATH>"

# An ABSOLUTE-path token inside a string value: a leading "/" at a boundary (NOT preceded by a colon
# or word char, so "https://host/x" and "base..sha" are untouched) followed by one or more
# slash-separated path segments. Matches "/tmp/a/b.log", "/private/tmp/x/repo/app/greet.sh"; leaves
# a relative "app/greet.sh" and a bare "/" alone.
_ABS_PATH_RE = re.compile(r"(?<![:\w])/[\w.\-]+(?:/[\w.\-]+)*")


def _canon_value(key, value):
    """Neutralize one (key, value) pair per the canonicalization rules in the module docstring."""
    if key == "ts":
        return TS_TOKEN
    if key == "pid" or key.endswith("_pid"):
        return PID_TOKEN
    if isinstance(value, str):
        return _ABS_PATH_RE.sub(PATH_TOKEN, value)
    return value


# ── shadow-private frame filter (oracle v2, HERD-325 leg 1) ───────────────────────────────────────
# The Python shadow engine's own diagnostic namespace: every event it emits to NARRATE its run —
# tick frames, lifecycle transitions, the dry-run blessing/observe/supersede notes — is prefixed
# "shadow_". None of these has a bash-engine counterpart (they are the shadow's assertion layer over
# the real output, not engine events), so the oracle drops them before the diff. The prefix is the
# whole contract: no REAL engine family is named "shadow_*" (see the event catalog, contract §3.4), so
# this can NEVER filter a genuine engine event — including main_health / push_hold_* (HERD-325 leg 3).
_SHADOW_PRIVATE_PREFIX = "shadow_"


def is_shadow_private(obj):
    """True iff ``obj`` is a shadow-private diagnostic frame (event name starts with ``shadow_``)."""
    if not isinstance(obj, dict):
        return False
    ev = obj.get("event")
    return isinstance(ev, str) and ev.startswith(_SHADOW_PRIVATE_PREFIX)


def filter_shadow_private(events):
    """Return ``events`` with shadow-private frames removed (leg 1). Real families pass through."""
    return [e for e in events if not is_shadow_private(e)]


def canonicalize_event(obj):
    """Return a canonical dict for one journal event: volatile fields neutralized, keys sorted.

    Key order is normalized by returning a plain dict built in sorted-key order; callers compare
    the dicts (order-independent) or serialize via :func:`canon_line` (sorted). ``obj`` is the
    parsed JSON object for one journal line.
    """
    return {k: _canon_value(k, obj[k]) for k in sorted(obj)}


def canon_line(obj):
    """Deterministic one-line serialization of a canonical event (sorted keys, compact)."""
    return json.dumps(canonicalize_event(obj), sort_keys=True,
                      separators=(",", ":"), ensure_ascii=False)


class ParityError(Exception):
    """An INFRA failure (exit 2): a journal was unreadable or a line was not valid JSON."""


def load_events(path):
    """Parse a journal JSONL file into a list of event objects. Blank lines skipped.

    Raises :class:`ParityError` on an unreadable file or an un-parseable line — the acceptance
    instrument must fail LOUD on a broken input, never silently treat it as an empty (parity) run.
    """
    events = []
    try:
        with open(path, encoding="utf-8") as fh:
            for lineno, raw in enumerate(fh, 1):
                line = raw.strip()
                if not line:
                    continue
                try:
                    events.append(json.loads(line))
                except ValueError as exc:
                    raise ParityError("%s:%d: invalid JSON: %s" % (path, lineno, exc))
    except OSError as exc:
        raise ParityError("cannot read journal %s: %s" % (path, exc))
    return events


class Divergence:
    """One canonical mismatch at a stream position (``real`` and/or ``shadow`` may be ``None``)."""

    __slots__ = ("index", "real", "shadow", "canon_real", "canon_shadow")

    def __init__(self, index, real, shadow, canon_real, canon_shadow):
        self.index = index
        self.real = real
        self.shadow = shadow
        self.canon_real = canon_real
        self.canon_shadow = canon_shadow

    def _event_name(self, obj):
        return obj.get("event", "?") if isinstance(obj, dict) else "—"

    def differing_fields(self):
        """The sorted set of keys whose canonical values differ (or exist on only one side)."""
        cr = self.canon_real or {}
        cs = self.canon_shadow or {}
        return sorted(k for k in set(cr) | set(cs) if cr.get(k) != cs.get(k))

    def render(self):
        """A human-readable multi-line report for this one divergence."""
        lines = []
        if self.real is None:
            lines.append("  event #%d: MISSING from real (present only in shadow: %s)"
                         % (self.index, self._event_name(self.shadow)))
        elif self.shadow is None:
            lines.append("  event #%d: MISSING from shadow (present only in real: %s)"
                         % (self.index, self._event_name(self.real)))
        else:
            lines.append("  event #%d: %s vs %s"
                         % (self.index, self._event_name(self.real),
                            self._event_name(self.shadow)))
            for k in self.differing_fields():
                cr = (self.canon_real or {}).get(k, "∅")
                cs = (self.canon_shadow or {}).get(k, "∅")
                lines.append("      %-12s real=%r  shadow=%r" % (k, cr, cs))
        lines.append("      raw real   : %s"
                     % (json.dumps(self.real, ensure_ascii=False) if self.real is not None else "—"))
        lines.append("      raw shadow : %s"
                     % (json.dumps(self.shadow, ensure_ascii=False) if self.shadow is not None else "—"))
        return "\n".join(lines)


def _divergence(index, real, shadow):
    """Build a :class:`Divergence`, canonicalizing whichever side(s) are present."""
    cr = canonicalize_event(real) if real is not None else None
    cs = canonicalize_event(shadow) if shadow is not None else None
    return Divergence(index, real, shadow, cr, cs)


def compare(real_events, shadow_events):
    """Alignment-based canonical comparison → the list of :class:`Divergence` (empty = parity).

    Shadow-private frames are filtered first (leg 1), then the two canonical streams are aligned by
    a longest-common-subsequence match (leg 2). Only the true edits are reported — a run of matched
    events aligns as ``equal`` (no divergence); an unmatched real event is a DELETE (MISSING from
    shadow), an unmatched shadow event is an INSERT (MISSING from real), and an aligned pair whose
    canonical payload differs is a MUTATION. A single inserted/deleted event no longer cascades.
    """
    real = filter_shadow_private(real_events)
    shadow = filter_shadow_private(shadow_events)
    # difflib matches HASHABLE opaque tokens — the canonical one-line serialization of each event, so
    # two events "match" iff they are identical after canonicalization (the parity definition).
    rc = [canon_line(e) for e in real]
    sc = [canon_line(e) for e in shadow]
    divs = []
    for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(None, rc, sc, autojunk=False).get_opcodes():
        if tag == "equal":
            continue
        if tag == "delete":                                  # real[i1:i2] present only in real
            for i in range(i1, i2):
                divs.append(_divergence(i, real[i], None))
        elif tag == "insert":                                # shadow[j1:j2] present only in shadow
            for j in range(j1, j2):
                divs.append(_divergence(j, None, shadow[j]))
        else:                                                # replace: pair as mutations, surplus = ins/del
            rn, sn = i2 - i1, j2 - j1
            for k in range(max(rn, sn)):
                r = real[i1 + k] if k < rn else None
                s = shadow[j1 + k] if k < sn else None
                divs.append(_divergence(i1 + k if r is not None else j1 + k, r, s))
    return divs


def format_report(divs, label_real, label_shadow, total_real, total_shadow, max_show):
    """Assemble the full divergence report as a string (header + per-mismatch records)."""
    out = []
    out.append("JOURNAL PARITY: DIVERGENT")
    out.append("  real   (%s): %d events" % (label_real, total_real))
    out.append("  shadow (%s): %d events" % (label_shadow, total_shadow))
    out.append("  divergences: %d" % len(divs))
    shown = divs if max_show <= 0 else divs[:max_show]
    for d in shown:
        out.append(d.render())
    if len(shown) < len(divs):
        out.append("  … %d more divergence(s) suppressed (raise --max to see them)"
                   % (len(divs) - len(shown)))
    return "\n".join(out)


# ── perturbation (self-diff proof; see module docstring) ─────────────────────────────────────────

def perturb_event(obj):
    """Rewrite ONLY the volatile categories of one event, so canonicalization must fold it back.

    A different ``ts``, a bumped ``pid``, and every absolute-path value reprefixed — each a change
    that :func:`canonicalize_event` erases. A perturbed stream that still diffs clean against its
    source is a live proof the ts/pid/path canonicalization is complete on real journal data.
    """
    out = {}
    for k, v in obj.items():
        if k == "ts":
            out[k] = "1999-12-31T23:59:59Z"
        elif k == "pid" or k.endswith("_pid"):
            try:
                out[k] = int(v) + 100000
            except (TypeError, ValueError):
                out[k] = "999999"
        elif isinstance(v, str):
            out[k] = _ABS_PATH_RE.sub(lambda m: "/perturbed" + m.group(0), v)
        else:
            out[k] = v
    return out


def _emit_perturbed(path, out_stream):
    for obj in load_events(path):
        out_stream.write(json.dumps(perturb_event(obj), separators=(",", ":"),
                                    ensure_ascii=False) + "\n")


# ── CLI ──────────────────────────────────────────────────────────────────────────────────────────

_USAGE = (
    "usage: python3 -m herd.parity <real.jsonl> <shadow.jsonl> "
    "[--label-real N] [--label-shadow N] [--max N] [--quiet]\n"
    "       python3 -m herd.parity --perturb <journal.jsonl>   "
    "# write a volatile-only-perturbed copy to stdout (self-diff shadow)\n"
    "exit: 0 parity · 1 divergent · 2 infra (unreadable/invalid journal)"
)


def main(argv):
    if argv[:1] == ["--perturb"]:
        if len(argv) != 2:
            sys.stderr.write(_USAGE + "\n")
            return 2
        try:
            _emit_perturbed(argv[1], sys.stdout)
        except ParityError as exc:
            sys.stderr.write("herd.parity: %s\n" % exc)
            return 2
        return 0

    real_path = shadow_path = None
    label_real = "real"
    label_shadow = "shadow"
    max_show = 20
    quiet = False
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--label-real":
            i += 1
            label_real = argv[i] if i < len(argv) else label_real
        elif a == "--label-shadow":
            i += 1
            label_shadow = argv[i] if i < len(argv) else label_shadow
        elif a == "--max":
            i += 1
            try:
                max_show = int(argv[i]) if i < len(argv) else max_show
            except ValueError:
                sys.stderr.write(_USAGE + "\n")
                return 2
        elif a == "--quiet":
            quiet = True
        elif a in ("-h", "--help"):
            sys.stdout.write(_USAGE + "\n")
            return 0
        elif a.startswith("-"):
            sys.stderr.write("herd.parity: unknown flag %r\n%s\n" % (a, _USAGE))
            return 2
        elif real_path is None:
            real_path = a
        elif shadow_path is None:
            shadow_path = a
        else:
            sys.stderr.write("herd.parity: unexpected argument %r\n%s\n" % (a, _USAGE))
            return 2
        i += 1

    if real_path is None or shadow_path is None:
        sys.stderr.write(_USAGE + "\n")
        return 2

    try:
        real_events = load_events(real_path)
        shadow_events = load_events(shadow_path)
    except ParityError as exc:
        sys.stderr.write("herd.parity: %s\n" % exc)
        return 2

    # Filtered stream lengths (leg 1): the counts that actually enter the diff, so the report and the
    # OK line are honest about what was compared and how many shadow-private frames were dropped.
    real_kept = filter_shadow_private(real_events)
    shadow_kept = filter_shadow_private(shadow_events)
    dropped = len(shadow_events) - len(shadow_kept)

    divs = compare(real_events, shadow_events)
    if not divs:
        if not quiet:
            note = (" · %d shadow-private frame(s) filtered" % dropped) if dropped else ""
            sys.stdout.write("JOURNAL PARITY: OK (%d events, identical after canonicalization%s)\n"
                             % (len(real_kept), note))
        return 0

    sys.stdout.write(format_report(divs, label_real, label_shadow,
                                   len(real_kept), len(shadow_kept), max_show) + "\n")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
