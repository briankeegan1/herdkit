"""herd.driver — the driver-table DISPATCH layer, ported to Python (HERD-317, P3d, EPIC HERD-300).

Part of the strangler port of the engine core (HERD-300). This module ports the *pure*,
runtime-portable core of the bash driver shim (``scripts/herd/driver.sh``) — the part that reads a
``templates/drivers/<name>.driver`` file as DATA and resolves a capability to a concrete runtime —
plus the ONE dispatch guarantee the bash seam relies on a caller to supply by hand: a binary probe
BEFORE dispatch, so a missing runtime fails LOUD and EARLY instead of stalling.

WHAT IS PORTED (the pure driver-table surface, parity-tested against ``driver.sh``):

  * :func:`agent_value`        — read a ``DRIVER_AGENT_*`` binding from a ``.driver`` file
    (bash: ``herd_driver_agent_value``). A single-key read + quote-strip, mirroring the awk/grep.
  * :func:`agent_runtime`      — the runtime EXECUTABLE a driver spawns: the first token of its
    ``DRIVER_AGENT_ONESHOT_EXEC`` (else ``INTERACTIVE_SPAWN``) binding (bash: ``herd_driver_agent_runtime``).
  * :func:`model_resolve` / :func:`model_for_spawn` / :func:`model_driver_for` — the runtime-qualified
    ``<driver>:<model>`` MODEL-ref resolver (bash: ``herd_model_resolve`` &c). An UNKNOWN driver
    prefix is a LOUD hard error, never a silent claude fallback — the reference resolution the item
    body points at.

THE TWO NON-NEGOTIABLES THIS PORT ADDS (the reason P3d exists as its own seam):

  1. **Parse driver files as DATA — never source into a live shell.** :func:`parse_driver_file` and
     :func:`agent_value` READ the file line-by-line (like the bash ``grep`` + quote-strip); a value
     that looks like ``$(rm -rf …)`` or a backtick command is returned as an inert string, never
     evaluated. Sourcing a committed-but-attacker-influenced ``.driver`` into ``bash`` would execute
     it; this port cannot.

  2. **Binary probe BEFORE dispatch → :class:`DriverUnavailable`, never a stall.** :func:`oneshot_dispatch`
     resolves the runtime, then ``shutil.which``-probes it FIRST. A runtime that is not on PATH raises
     :class:`DriverUnavailable` immediately — it never execs into a doomed process that hangs waiting
     for input. This is the direct fix for the HERD-311 incident (``MODEL_REVIEW=codex:gpt-5.4`` with
     no ``codex`` binary produced a 30-minute silent stall): the bash seam is "not fail-soft — the
     runtime's exit status is returned unchanged" and leaves the probe to each caller; the port makes
     the probe a load-bearing precondition of dispatch so the stall is structurally impossible.

@degrade SENTINELS BECOME TYPED :class:`Degraded` VALUES. A binding a runtime cannot honestly supply
(codex/grok's usage-limit banner, its token-usage schema) is carried in the ``.driver`` file as an
``@degrade:<reason>`` sentinel. :func:`agent_value` returns such a value as a :class:`Degraded` — a
``str`` subclass that renders byte-identically to the raw sentinel (so parity with bash holds) but is
*type-tagged* so a consumer applies the documented fail-safe: as a regex it NEVER matches
(:func:`pattern_matches` → ``False``, so limit-detection never false-fires and falls through to the
runtime-independent backstop); as a usage-key list it names NO field (:func:`usage_keys` → ``[]``, so
cost summing finds nothing and the model is ``unpriced``, never a fabricated ``$0``).

NOT WIRED LIVE. Like the P2 decision core, the bash driver shim keeps its implementation UNCHANGED
(zero behavior change) — this module exists to be parity-tested against it
(``tests/test-py-driver.sh``) and to carry the dispatch guarantee the later routing phases consume.
Stdlib-only (no external deps — the P1 packaging rule). The optional live dispatch in
:func:`oneshot_dispatch` shells out only when a caller asks it to; the tests exercise it end-to-end
against a fixture runtime, never a real vendor CLI.
"""

import os
import shutil
import subprocess

DEFAULT_DRIVER = "herdr-claude"
DEGRADE_PREFIX = "@degrade:"

# The byte-identical fallback the bash seam uses when a runtime is unresolvable/claude (driver.sh:1087)
# and the default limit-banner phrase (driver.sh:1157). Kept here so the port degrades identically.
DEFAULT_RUNTIME = "claude"
DEFAULT_LIMIT_PATTERN = "usage limit|session limit|hit your (usage|session) limit"


class DriverError(Exception):
    """Base class for the port's LOUD (non-fail-soft) errors — a bad ref / a missing runtime."""


class ModelRefError(DriverError):
    """A runtime-qualified MODEL ref names an unknown driver, or a ``<driver>:`` with no model.

    The port's analog of ``herd_model_resolve``'s loud one-line stderr + non-zero return: a
    misconfigured ref is an OPERATOR error that must STOP the spawn, never silently downgrade to the
    wrong runtime (docs/driver-abstraction.md § model matrix).
    """


class DriverUnavailable(DriverError):
    """The resolved runtime binary is not on PATH — dispatch is refused BEFORE it can stall.

    Carries the resolved ``runtime`` and ``driver`` so a caller can report INFRA precisely (the
    HERD-311 fix: a missing ``codex`` must raise here, not hang a 30-minute doomed dispatch).
    """

    def __init__(self, runtime, driver=None, ref=None):
        self.runtime = runtime
        self.driver = driver
        self.ref = ref
        display = ref or (("%s:" % driver) if driver else runtime)
        super().__init__(
            "model %r cannot dispatch — runtime binary %r (driver %r) is not on PATH"
            % (display, runtime, driver)
        )


class Degraded(str):
    """An ``@degrade:<reason>`` sentinel, typed so consumers apply fail-safe semantics.

    A ``str`` subclass so it renders BYTE-IDENTICALLY to the raw sentinel (batch/CLI output and the
    bash parity harness see the same text), yet ``isinstance(v, Degraded)`` lets a consumer branch
    onto the documented fail-safe. The two fail-safe faces:

      * **As a regex** it can never match real runtime output — see :func:`pattern_matches`. So
        limit-detection built on a degraded ``DRIVER_AGENT_LIMIT_PATTERN`` never false-fires and
        falls straight through to the runtime-independent hook-sentinel + resume backstop.
      * **As a space-separated key list** it names no real JSON field — see :func:`usage_keys`. So a
        cost/usage sum finds nothing and the model is surfaced ``unpriced``, not a fabricated ``$0``.

    Always non-empty, so no consumer trips on an empty value; ``reason`` self-documents WHY.
    """

    __slots__ = ()

    @property
    def reason(self):
        """The text after the ``@degrade:`` prefix — WHY the capability degraded."""
        return self[len(DEGRADE_PREFIX):]


def classify(value):
    """Wrap an ``@degrade:`` string as :class:`Degraded`; return any other string unchanged.

    The single place a raw ``.driver`` value is promoted to its typed form. A non-``@degrade`` value
    (including ``""``) is returned as a plain ``str`` so nothing else changes.
    """
    if isinstance(value, str) and value.startswith(DEGRADE_PREFIX):
        return Degraded(value)
    return value


def is_degraded(value):
    """True iff ``value`` is a degraded sentinel (a :class:`Degraded`, or a raw ``@degrade:`` str)."""
    return isinstance(value, Degraded) or (
        isinstance(value, str) and value.startswith(DEGRADE_PREFIX)
    )


def pattern_matches(pattern, text):
    """Regex fail-safe: a :class:`Degraded` pattern NEVER matches; else a real ``re.search``.

    Mirrors the bash contract that a ``@degrade:…`` limit pattern "can never match real runtime
    output, so limit-detection simply never false-fires". A malformed real regex fails soft to
    ``False`` too (a bad binding must not crash the detector).
    """
    if is_degraded(pattern):
        return False
    import re
    try:
        return re.search(pattern, text) is not None
    except re.error:
        return False


def usage_keys(value):
    """Cost fail-safe: a :class:`Degraded` usage-key binding names NO field (``[]``); else split.

    Mirrors the bash contract that a degraded ``DRIVER_AGENT_COST_USAGE_KEYS`` "names no real JSON
    field, so a usage sum finds nothing and cost.sh marks the model unpriced".
    """
    if is_degraded(value):
        return []
    return value.split()


# ── driver-table location + enumeration (bash: _herd_drivers_dir / herd_driver_known) ────────────

def drivers_dir():
    """The ``templates/drivers`` directory holding the shipped ``<name>.driver`` files.

    ``HERD_DRIVERS_DIR`` overrides (the same knob bin/herd + the driver tests use). Otherwise resolved
    RELATIVE TO THIS FILE (``pysrc/herd/driver.py`` → ``../../templates/drivers``), mirroring the bash
    ``scripts/herd/driver.sh`` → ``../../templates/drivers`` resolution so it works in both the
    vendored dogfood layout and a global install where ``pysrc``/``templates`` are siblings.
    """
    env = os.environ.get("HERD_DRIVERS_DIR")
    if env:
        return env
    here = os.path.dirname(os.path.abspath(__file__))
    return os.path.normpath(os.path.join(here, "..", "..", "templates", "drivers"))


def driver_name():
    """The active driver: ``HERD_DRIVER`` env, else the default (``herdr-claude``).

    Mirrors ``herd_driver_name`` (``driver.sh:26``): ``${HERD_DRIVER:-herdr-claude}``.
    """
    return os.environ.get("HERD_DRIVER") or DEFAULT_DRIVER


def _driver_file(driver):
    return os.path.join(drivers_dir(), "%s.driver" % driver)


def driver_known(name):
    """True iff ``name`` is a shipped driver (a ``templates/drivers/<name>.driver`` exists).

    Mirrors ``herd_driver_known`` (``driver.sh:75``) — the valid-driver oracle the qualified-ref
    resolver checks a ``<driver>:`` prefix against.
    """
    return bool(name) and os.path.isfile(_driver_file(name))


def known_drivers():
    """Sorted list of the shipped driver names (for the loud error message). Empty when unreadable."""
    d = drivers_dir()
    try:
        names = [f[:-len(".driver")] for f in os.listdir(d) if f.endswith(".driver")]
    except OSError:
        return []
    return sorted(names)


# ── parse driver files as DATA, never source (the non-negotiable) ────────────────────────────────

def _strip_one_quote_pair(v):
    """Strip a SINGLE pair of surrounding single- or double-quotes — the ``.driver`` value convention.

    Byte-faithful to the bash ``case`` in ``herd_driver_agent_value`` (``driver.sh:113``): a value is
    unquoted only when its first char is a quote AND its last char is the SAME quote (length ≥ 2).
    Everything else — including inner quotes in an unquoted command shape — is left verbatim.
    """
    if len(v) >= 2 and v[0] in ("'", '"') and v[-1] == v[0]:
        return v[1:-1]
    return v


def _iter_bindings(path):
    """Yield ``(key, raw_value_after_quote_strip)`` for every ``KEY=value`` line in a ``.driver`` file.

    Reads the file as TEXT and splits each line at the FIRST ``=`` — it NEVER sources or evaluates a
    value, so a value like ``$(cmd)`` or a backtick string is inert data. Comment (``#``) and blank
    lines are skipped. A key must be a leading run of ``[A-Za-z0-9_]`` immediately followed by ``=``.
    """
    try:
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
    except OSError:
        return
    for line in text.splitlines():
        s = line.lstrip()
        if not s or s.startswith("#"):
            continue
        eq = line.find("=")
        if eq <= 0:
            continue
        key = line[:eq]
        # A shell assignment target: a leading identifier, no leading whitespace (the .driver
        # convention writes KEY=… flush-left). Anything else is not a binding line.
        if not key or key != key.strip() or not all(c.isalnum() or c == "_" for c in key):
            continue
        yield key, _strip_one_quote_pair(line[eq + 1:])


def parse_driver_file(path):
    """Parse a whole ``.driver`` file into a dict of ``KEY -> value`` (last occurrence wins).

    Values are CLASSIFIED: an ``@degrade:`` value becomes a :class:`Degraded`, everything else a
    plain ``str``. Reads as DATA (see :func:`_iter_bindings`) — the port cannot execute a value.
    """
    out = {}
    for key, raw in _iter_bindings(path):
        out[key] = classify(raw)
    return out


def agent_value(key, default="", driver=None):
    """Read a ``DRIVER_AGENT_*`` (or any ``KEY=``) binding from a driver's ``.driver`` file.

    Mirrors ``herd_driver_agent_value`` (``driver.sh:103``): the ACTIVE driver by default; pass
    ``driver`` to read a SPECIFIC driver's binding (the resolved runtime driver may differ from the
    active one). PURE — reads the file, never sources it. LAST matching line wins (bash ``tail -n1``).
    FAIL-SOFT — returns ``default`` when the file/key is unreadable or the value strips to empty. An
    ``@degrade:`` value is returned TYPED (:class:`Degraded`); ``default`` is returned as given.
    """
    if not key:
        return default
    if not driver:
        driver = driver_name()
    found = None
    for k, raw in _iter_bindings(_driver_file(driver)):
        if k == key:
            found = raw  # last wins
    if found is None or found == "":
        return default
    return classify(found)


def agent_runtime(driver=None):
    """The runtime EXECUTABLE a driver spawns — the first token of its exec binding, else ``""``.

    Mirrors ``herd_driver_agent_runtime`` (``driver.sh:130``): the first whitespace token of
    ``DRIVER_AGENT_ONESHOT_EXEC``, falling back to ``DRIVER_AGENT_INTERACTIVE_SPAWN``; empty when
    neither is bound (the caller then defaults to ``claude``, so an absent binding degrades to
    today's behavior). Returns a plain ``str`` (a runtime binary is never itself degraded).
    """
    b = agent_value("DRIVER_AGENT_ONESHOT_EXEC", "", driver)
    if not b:
        b = agent_value("DRIVER_AGENT_INTERACTIVE_SPAWN", "", driver)
    if not b:
        return ""
    return str(b).split()[0]


def limit_pattern(driver=None):
    """The usage-limit banner regex — ``DRIVER_AGENT_LIMIT_PATTERN`` with the fail-soft default.

    Mirrors ``herd_driver_agent_limit_pattern`` (``driver.sh:1153``): the herdr-claude default phrase
    when unbound; a driver's ``@degrade:`` sentinel is returned TYPED so :func:`pattern_matches`
    treats it as never-match.
    """
    return agent_value("DRIVER_AGENT_LIMIT_PATTERN", DEFAULT_LIMIT_PATTERN, driver)


# ── runtime-qualified MODEL ref resolution (bash: herd_model_resolve &c) ──────────────────────────

def model_resolve(ref):
    """Resolve an optionally runtime-qualified MODEL ref into ``(driver, model)``.

    Mirrors ``herd_model_resolve`` (``driver.sh:146``):

      * BARE (no colon, incl. ``""``)  → ``(default_driver, ref)`` — byte-identical to a plain model.
      * ``<known-driver>:<model>``     → ``(driver, model)``, split on the FIRST colon (so a model id
        may itself contain colons, e.g. ``ollama:llama3:8b`` → ``("ollama", "llama3:8b")``).

    Raises :class:`ModelRefError` (LOUD) on an UNKNOWN driver prefix, or a ``<known-driver>:`` with an
    EMPTY model — never a silent claude fallback.
    """
    ref = "" if ref is None else str(ref)
    if ":" not in ref:
        return driver_name(), ref
    drv, mdl = ref.split(":", 1)
    if not driver_known(drv):
        known = " ".join(known_drivers()) or "<none>"
        raise ModelRefError(
            "MODEL ref %r names an unknown runtime driver %r — no templates/drivers/%s.driver. "
            "Known drivers: %s. Use a bare model (default driver) or a known <driver>:<model> ref; "
            "a bad ref never silently falls back to claude." % (ref, drv, drv, known)
        )
    if not mdl:
        raise ModelRefError(
            "MODEL ref %r has an empty model after the %r driver prefix — write %r or a bare model id."
            % (ref, drv, "%s:<model>" % drv)
        )
    return drv, mdl


def model_for_spawn(ref):
    """Resolve ``ref`` and return ONLY the bare model (bash: ``herd_model_for_spawn``).

    An empty ref stays empty (no ``--model``). Raises :class:`ModelRefError` on a bad ref, so a lane
    aborts instead of spawning on it. BYTE-IDENTICAL for a bare model (it resolves to itself).
    """
    ref = "" if ref is None else str(ref)
    if not ref:
        return ""
    return model_resolve(ref)[1]


def model_driver_for(ref):
    """Resolve ``ref`` and return ONLY the driver, or ``None`` on a bad ref (bash: fail-soft companion).

    Mirrors ``herd_model_driver_for`` (``driver.sh:182``): the fail-soft companion for callers that
    only want the runtime side and must not abort — an unknown/empty-model ref returns ``None`` (no
    loud message; :func:`model_for_spawn` owns the loud path at spawn time).
    """
    try:
        return model_resolve(ref)[0]
    except ModelRefError:
        return None


# ── the DISPATCH guarantee: probe the runtime BEFORE dispatch, never stall ────────────────────────

def resolved_runtime(driver=None, ref=None):
    """The runtime binary a dispatch would exec — the driver's exec runtime, else ``claude``.

    When ``ref`` is given it takes precedence (a runtime-qualified MODEL ref selects the driver);
    otherwise ``driver`` (default: active). An absent/unbound exec surface degrades to ``claude``,
    matching the bash seam's default branch (``driver.sh:1084``).
    """
    if ref is not None:
        driver = model_driver_for(ref) or driver_name()
    rt = agent_runtime(driver)
    return rt or DEFAULT_RUNTIME


def probe_runtime(runtime):
    """True iff ``runtime`` is an executable on PATH (``shutil.which``). The pre-dispatch probe."""
    return bool(runtime) and shutil.which(runtime) is not None


def oneshot_argv(prompt, model, extra=(), driver=None, ref=None, runtime=None):
    """Compose the one-shot dispatch argv: ``[<runtime>, "-p", <prompt>, "--model", <model>, *extra]``.

    Byte-faithful to ``herd_driver_oneshot_exec_as`` (``driver.sh:1074``): ``<rt> -p "$prompt"
    --model "$model" "$@"`` — every ``extra`` arg is forwarded VERBATIM. ``runtime`` overrides the
    resolved one (used only after a successful probe); otherwise :func:`resolved_runtime` picks it.
    """
    rt = runtime or resolved_runtime(driver=driver, ref=ref)
    return [rt, "-p", prompt, "--model", model, *extra]


def oneshot_dispatch(prompt, model, extra=(), driver=None, ref=None, run=True, **run_kwargs):
    """Dispatch a one-shot runtime query — but PROBE THE BINARY FIRST, never stall.

    THE dispatch guarantee (HERD-311 fix). Steps, in order:

      1. Resolve the runtime (:func:`resolved_runtime`) — an ``@degrade`` / absent binding degrades
         to ``claude``, exactly as the bash seam.
      2. **Probe it** (:func:`probe_runtime`). A runtime NOT on PATH raises :class:`DriverUnavailable`
         RIGHT HERE — before any process is spawned — so a missing ``codex`` fails loud and early
         instead of hanging a doomed dispatch for 30 minutes.
      3. Compose the argv (:func:`oneshot_argv`) and, when ``run`` is true, ``subprocess.run`` it and
         return the :class:`subprocess.CompletedProcess`. With ``run=False`` the probed argv is
         returned WITHOUT executing (for callers/tests that only want the resolved command).

    Extra ``run_kwargs`` pass through to ``subprocess.run`` (e.g. ``capture_output``, ``text``,
    ``timeout``). Not fail-soft on a bad runtime (the whole point): a stall is the failure mode this
    refuses to reach.
    """
    rt = resolved_runtime(driver=driver, ref=ref)
    if not probe_runtime(rt):
        who = driver if driver is not None else (model_driver_for(ref) if ref else driver_name())
        raise DriverUnavailable(rt, driver=who, ref=ref)
    argv = oneshot_argv(prompt, model, extra=extra, runtime=rt)
    if not run:
        return argv
    return subprocess.run(argv, **run_kwargs)


# ── thin CLI harness (impure glue; the functions above stay pure) ─────────────────────────────────
#
# Used ONLY by tests/test-py-driver.sh so the SAME argv drives this port and the bash driver.sh
# functions. Env-sourced knobs (HERD_DRIVER selects the active/default driver; HERD_DRIVERS_DIR the
# table location) are read the way bash reads them. A verb that mirrors a LOUD bash path (a bad model
# ref) prints the sentinel ``@ERR`` on failure so the two streams diff cleanly without stderr noise.

_ERR = "@ERR"


def _cli(argv):
    cmd = argv[0] if argv else ""
    a = argv[1:]
    if cmd == "agent-value":
        return str(agent_value(a[0] if a else "", a[1] if len(a) > 1 else ""))
    if cmd == "agent-runtime":
        return agent_runtime()
    if cmd == "limit-pattern":
        return str(limit_pattern(a[0] if a else None))
    if cmd == "driver-for":
        return model_driver_for(a[0] if a else "") or ""
    if cmd == "for-spawn":
        try:
            return model_for_spawn(a[0] if a else "")
        except ModelRefError:
            return _ERR
    if cmd == "resolve":
        try:
            drv, mdl = model_resolve(a[0] if a else "")
            return "%s\t%s" % (drv, mdl)
        except ModelRefError:
            return _ERR
    if cmd == "known":
        return "yes" if driver_known(a[0] if a else "") else "no"
    if cmd == "resolved-runtime":
        return resolved_runtime()
    raise SystemExit("herd.driver: unknown subcommand %r" % cmd)


def _batch(stream, sep="\x1f"):
    """Run many cases in ONE process (the parity harness's fast path).

    Each input line is ``<driver|@U><sep><verb>[<sep>arg...]``; a ``@U`` driver field UNSETS
    ``HERD_DRIVER`` (the active/default driver falls back to ``herdr-claude``), any other value
    (including ``""``) sets it verbatim. ``HERD_DRIVERS_DIR`` is constant across a run, so the caller
    exports it once. Yields one output line per case for a line-for-line diff against the bash lib.
    """
    out = []
    for line in stream:
        line = line.rstrip("\n")
        if not line:
            continue
        f = line.split(sep)
        if len(f) < 2:
            continue
        if f[0] == "@U":
            os.environ.pop("HERD_DRIVER", None)
        else:
            os.environ["HERD_DRIVER"] = f[0]
        out.append(_cli(f[1:]))
    return out


if __name__ == "__main__":
    import sys

    if sys.argv[1:2] == ["--batch"]:
        results = _batch(sys.stdin)
        sys.stdout.write("".join(r + "\n" for r in results))
    else:
        sys.stdout.write(_cli(sys.argv[1:]) + "\n")
