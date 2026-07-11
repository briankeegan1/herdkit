"""herd — the herdkit engine, ported to Python one seam at a time (EPIC HERD-300).

This is P1 (HERD-302): the READ-ONLY journal/state tools. Each command is a stdlib-only
submodule invoked behind the EXISTING `herd` CLI name via ``python3 -m herd.<cmd>``:

    python3 -m herd.why    <- herd why <pr#>
    python3 -m herd.log    <- herd log / --pr N / --tail (stdin formatter)
    python3 -m herd.cost   <- herd cost / --pr N / --full

bin/herd resolves config, journal paths and (for cost --full) the live-scan lines in bash
exactly as before, then pipes/exports them to these modules — so the modules are pure
readers with ZERO mutation and receive byte-for-byte the same input the inline programs did.
Output is byte-identical to the historical inline `python3 -c` implementations, which bin/herd
keeps as a FAIL-SOFT fallback: if this package fails to import (or a module exits
nonzero-with-no-output) the CLI silently runs the builtin reader instead, never a red row.

Layout (this phase proves the packaging story):

    pysrc/herd/__init__.py   package marker + this contract
    pysrc/herd/why.py        `herd why`  reader
    pysrc/herd/log.py        `herd log`  formatter
    pysrc/herd/cost.py       `herd cost` reader

Later phases (P1b/P2/P3, HERD-307..320) grew the package beyond the P1 readers: the
`herd status` formatter (status.py, P1b), the pure decision core + typed state machine
(decisions.py / statemachine.py, P2/P3b), and the parity harness + shadow/live runtimes and
their bridges (parity/shadow_journal/shadow_runtime/fixture_extract/live_runtime, P3a–P3f).
Every importable submodule is listed in ``__all__`` below.

Invocation adds pysrc/ to PYTHONPATH (bin/herd derives it from HERDKIT_HOME). No external
dependencies — python3 is already a hard engine dep; NONE are added here.
"""

__all__ = ["why", "log", "cost", "status", "decisions", "statemachine", "parity", "driver",
           "shadow_journal", "shadow_runtime", "fixture_extract", "live_runtime", "store"]
