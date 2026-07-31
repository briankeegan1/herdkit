"""The Python twin of ``scripts/herd/human-verify.sh`` — the per-PR HUMAN-VERIFY hold parser.

The bash seam is authoritative prose (``human-verify.sh``); this is the same parse, in-process, for
the Python engine core. It exists because the merge gate that consumes it moved: ``agent-watch.sh``
piped a PR body through ``human_verify_has`` inside ``_tick_act``, and when HERD-306 (P5b) deleted
that action pass the port never re-acquired the input — ``LiveCandidate.hv_hold`` was left permanently
``False``, so on the SHIP DEFAULT (``MERGE_POLICY=auto`` + ``HUMAN_VERIFY_POLICY=hold``) a PR that
declared manual steps was auto-merged with no hold at all (HERD-442; PR #555 merged that way on
2026-07-30 with no ``hold_applied`` row anywhere in the journal).

**The parse contract is bash's, verbatim** (``human-verify.sh``:20-29):

  * The block opens at the first line whose text — after optional markdown bullet ``[- * +]``,
    heading, or bold decoration — is ``HUMAN-VERIFY:``, case-insensitive. Any text after the colon on
    that line is the first step (the one-liner ``HUMAN-VERIFY: <single step>`` form).
  * Following non-blank lines are further steps, until the first blank line or the end of the body.
  * Each step is de-bulleted (``- ``, ``* ``, ``+ ``, ``1.``, ``1)``) and trimmed; empties drop.
  * A bare marker with NO steps is NOT a hold — there is nothing for a human to verify, so it must
    never trip the gate (:func:`has` returns False).

The marker character class MUST keep every bullet the de-bulleter handles: a builder naturally writes
the block as a ``-`` list, and a missing bullet here fails OPEN — no hold, silent auto-merge — which
is the exact bypass the gate exists to prevent.

Drift between the two implementations would silently re-open that bypass, so it is pinned rather than
asserted: ``tests/test-human-verify-parity.sh`` feeds one corpus of bodies through BOTH this module
and ``human-verify.sh`` and fails on any disagreement.
"""

import re

_MARKER = re.compile(r"^[\s>*#`+-]*HUMAN-VERIFY\s*:\s*(.*)$", re.IGNORECASE)
_BULLET = re.compile(r"^\s*(?:[-*+]\s+|\d+[.)]\s+)")


def _clean(s):
    return _BULLET.sub("", s.strip()).strip()


def steps(body):
    """The declared HUMAN-VERIFY steps in ``body``, in order; ``[]`` when none are declared."""
    lines = (body or "").splitlines()
    n = len(lines)
    out = []
    for i in range(n):
        m = _MARKER.match(lines[i])
        if not m:
            continue
        rest = m.group(1).strip().strip("*").strip()
        if rest:
            c = _clean(rest)
            if c:
                out.append(c)
        j = i + 1
        while j < n and lines[j].strip() != "":
            c = _clean(lines[j])
            if c:
                out.append(c)
            j += 1
        break
    return out


def has(body):
    """True iff ``body`` declares a NON-EMPTY HUMAN-VERIFY block (at least one step)."""
    return bool(steps(body))
