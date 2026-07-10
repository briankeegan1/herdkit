"""test_driver_dispatch.py — stdlib unit tests for herd.driver (HERD-317, P3d, EPIC HERD-300).

These assert the INTERNAL invariants of the driver-table dispatch port directly (no bash oracle) —
the cross-implementation parity with scripts/herd/driver.sh is proved by tests/test-py-driver.sh,
which drives this module and the live bash functions off one argv. Stdlib-only (unittest) so the gate
never needs an external dep; an OPTIONAL hypothesis pass runs only when hypothesis happens to be
installed and is skip-soft otherwise (a missing optional tool is never a red — AGENTS.md).

The four load-bearing invariants (the item's non-negotiables):
  1. parse driver files as DATA — a value that looks like a shell command is inert, never executed.
  2. @degrade sentinels become TYPED Degraded values with fail-safe regex / usage-key semantics.
  3. binary probe BEFORE dispatch → DriverUnavailable, never a stall (the HERD-311 fix).
  4. a stub (non-claude) driver runs a one-shot END TO END against a fixture runtime.

Run:  PYTHONPATH=pysrc python3 tests/test_driver_dispatch.py
"""
import os
import stat
import sys
import tempfile
import unittest

from herd import driver as DRV

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SHIPPED_DRIVERS = os.path.join(REPO, "templates", "drivers")


class _DriversDir:
    """Context manager: point HERD_DRIVERS_DIR / HERD_DRIVER at a chosen table + active driver.

    Side-effect-free: it saves and restores the two env vars, mutating nothing else (VERIFY discipline
    — the port's tests never touch shared state beyond a private tempdir).
    """

    def __init__(self, dir_=None, active=None):
        self.dir_, self.active = dir_, active
        self._saved = {}

    def __enter__(self):
        for k, v in (("HERD_DRIVERS_DIR", self.dir_), ("HERD_DRIVER", self.active)):
            self._saved[k] = os.environ.get(k)
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        return self

    def __exit__(self, *exc):
        for k, v in self._saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        return False


def _write_driver(dir_, name, body):
    path = os.path.join(dir_, "%s.driver" % name)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(body)
    return path


def _write_exe(dir_, name, script):
    path = os.path.join(dir_, name)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(script)
    os.chmod(path, os.stat(path).st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    return path


class ParseAsData(unittest.TestCase):
    """Non-negotiable #1: a .driver file is read as DATA — a value is never sourced/evaluated."""

    def test_command_looking_value_is_inert(self):
        with tempfile.TemporaryDirectory() as td:
            canary = os.path.join(td, "PWNED")
            # A value that WOULD create the canary if the file were sourced into a shell.
            body = (
                "# a hostile driver\n"
                "DRIVER_AGENT_ONESHOT_EXEC='stub-agent -p \"<prompt>\"'\n"
                "DRIVER_AGENT_INJECT=$(touch %s)\n"
                "DRIVER_AGENT_BACKTICK=`touch %s`\n" % (canary, canary)
            )
            _write_driver(td, "hostile", body)
            with _DriversDir(td, "hostile"):
                inj = DRV.agent_value("DRIVER_AGENT_INJECT")
                bt = DRV.agent_value("DRIVER_AGENT_BACKTICK")
            self.assertEqual(inj, "$(touch %s)" % canary)   # returned VERBATIM, as data
            self.assertEqual(bt, "`touch %s`" % canary)
            self.assertFalse(os.path.exists(canary), "value was EXECUTED — port sourced the file!")

    def test_quote_stripping_matches_bash(self):
        with tempfile.TemporaryDirectory() as td:
            body = (
                "SINGLE='hi there'\n"
                'DOUBLE="hi there"\n'
                "UNQUOTED=codex exec --model <model> \"<prompt>\"\n"
                "EMPTYQ=''\n"
            )
            _write_driver(td, "q", body)
            with _DriversDir(td, "q"):
                self.assertEqual(DRV.agent_value("SINGLE"), "hi there")
                self.assertEqual(DRV.agent_value("DOUBLE"), "hi there")
                # unquoted command shape kept verbatim, inner quotes intact
                self.assertEqual(DRV.agent_value("UNQUOTED"),
                                 'codex exec --model <model> "<prompt>"')
                # a value that strips to empty → the default
                self.assertEqual(DRV.agent_value("EMPTYQ", "DFLT"), "DFLT")

    def test_last_binding_wins(self):
        with tempfile.TemporaryDirectory() as td:
            _write_driver(td, "dup", "K='first'\nK='second'\n")
            with _DriversDir(td, "dup"):
                self.assertEqual(DRV.agent_value("K"), "second")   # bash tail -n1

    def test_missing_file_and_key_fail_soft(self):
        with tempfile.TemporaryDirectory() as td:
            with _DriversDir(td, "nonexistent"):
                self.assertEqual(DRV.agent_value("ANY", "DFLT"), "DFLT")
            _write_driver(td, "empty", "# nothing here\n")
            with _DriversDir(td, "empty"):
                self.assertEqual(DRV.agent_value("MISSING", "DFLT"), "DFLT")


class DegradeSentinels(unittest.TestCase):
    """Non-negotiable #2: @degrade values are typed Degraded with fail-safe semantics."""

    def test_agent_value_returns_typed_degraded(self):
        # codex.driver binds LIMIT_PATTERN + COST_USAGE_KEYS to @degrade sentinels.
        with _DriversDir(SHIPPED_DRIVERS, "codex"):
            lp = DRV.agent_value("DRIVER_AGENT_LIMIT_PATTERN")
            ck = DRV.agent_value("DRIVER_AGENT_COST_USAGE_KEYS")
        self.assertIsInstance(lp, DRV.Degraded)
        self.assertIsInstance(ck, DRV.Degraded)
        self.assertTrue(DRV.is_degraded(lp))
        self.assertEqual(lp.reason, "no-verified-codex-usage-limit-banner")

    def test_degraded_renders_byte_identically(self):
        raw = "@degrade:some-reason"
        d = DRV.Degraded(raw)
        self.assertEqual(str(d), raw)      # parity with bash: prints the raw sentinel
        self.assertEqual("%s" % d, raw)

    def test_degraded_regex_never_matches(self):
        d = DRV.Degraded("@degrade:no-verified-codex-usage-limit-banner")
        # Even against text that CONTAINS the sentinel string, a degraded pattern never matches.
        for text in ("usage limit reached", "@degrade:no-verified-codex-usage-limit-banner", ""):
            self.assertFalse(DRV.pattern_matches(d, text))
        # a real (non-degraded) pattern still matches normally
        self.assertTrue(DRV.pattern_matches("usage limit|session limit", "hit the usage limit"))
        self.assertFalse(DRV.pattern_matches("usage limit", "all good"))

    def test_degraded_usage_keys_is_empty(self):
        d = DRV.Degraded("@degrade:no-verified-codex-usage-token-schema")
        self.assertEqual(DRV.usage_keys(d), [])
        self.assertEqual(DRV.usage_keys("input_tokens output_tokens"),
                         ["input_tokens", "output_tokens"])

    def test_limit_pattern_default_when_unbound(self):
        with tempfile.TemporaryDirectory() as td:
            _write_driver(td, "bare", "DRIVER_AGENT_ONESHOT_EXEC='x -p'\n")
            with _DriversDir(td, "bare"):
                self.assertEqual(DRV.limit_pattern(), DRV.DEFAULT_LIMIT_PATTERN)


class RuntimeResolution(unittest.TestCase):
    def test_runtime_is_first_token_of_oneshot(self):
        with _DriversDir(SHIPPED_DRIVERS, "codex"):
            self.assertEqual(DRV.agent_runtime(), "codex")
        with _DriversDir(SHIPPED_DRIVERS, "stub"):
            self.assertEqual(DRV.agent_runtime(), "stub-agent")
        with _DriversDir(SHIPPED_DRIVERS, "herdr-claude"):
            self.assertEqual(DRV.agent_runtime(), "claude")

    def test_runtime_falls_back_to_interactive_then_empty(self):
        with tempfile.TemporaryDirectory() as td:
            _write_driver(td, "ionly", "DRIVER_AGENT_INTERACTIVE_SPAWN='foo --model <model>'\n")
            with _DriversDir(td, "ionly"):
                self.assertEqual(DRV.agent_runtime(), "foo")
            _write_driver(td, "none", "# no exec bindings\n")
            with _DriversDir(td, "none"):
                self.assertEqual(DRV.agent_runtime(), "")
                # resolved_runtime degrades an unbound exec surface to claude
                self.assertEqual(DRV.resolved_runtime(), "claude")


class ModelRefResolution(unittest.TestCase):
    def test_bare_resolves_to_active_driver(self):
        with _DriversDir(SHIPPED_DRIVERS, "codex"):
            self.assertEqual(DRV.model_resolve("gpt-5.4"), ("codex", "gpt-5.4"))
            self.assertEqual(DRV.model_for_spawn("gpt-5.4"), "gpt-5.4")
            self.assertEqual(DRV.model_driver_for("gpt-5.4"), "codex")

    def test_qualified_ref_splits_on_first_colon(self):
        with _DriversDir(SHIPPED_DRIVERS, "herdr-claude"):
            self.assertEqual(DRV.model_resolve("stub:llama3:8b"), ("stub", "llama3:8b"))
            self.assertEqual(DRV.model_driver_for("codex:gpt-5.4"), "codex")

    def test_unknown_driver_is_loud(self):
        with _DriversDir(SHIPPED_DRIVERS, "herdr-claude"):
            with self.assertRaises(DRV.ModelRefError):
                DRV.model_resolve("nope:x")
            with self.assertRaises(DRV.ModelRefError):
                DRV.model_for_spawn("nope:x")
            self.assertIsNone(DRV.model_driver_for("nope:x"))   # fail-soft companion

    def test_empty_model_after_prefix_is_loud(self):
        with _DriversDir(SHIPPED_DRIVERS, "herdr-claude"):
            with self.assertRaises(DRV.ModelRefError):
                DRV.model_resolve("codex:")
            self.assertIsNone(DRV.model_driver_for("codex:"))

    def test_empty_ref_is_byte_identical(self):
        with _DriversDir(SHIPPED_DRIVERS, "herdr-claude"):
            self.assertEqual(DRV.model_resolve(""), ("herdr-claude", ""))
            self.assertEqual(DRV.model_for_spawn(""), "")


class ProbeBeforeDispatch(unittest.TestCase):
    """Non-negotiable #3: a missing runtime raises DriverUnavailable BEFORE any process is spawned."""

    def test_missing_runtime_raises_not_stalls(self):
        with tempfile.TemporaryDirectory() as td:
            # a driver whose runtime binary is guaranteed absent
            _write_driver(td, "ghost", "DRIVER_AGENT_ONESHOT_EXEC='definitely-not-a-real-binary-xyz -p'\n")
            saved_path = os.environ.get("PATH")
            try:
                os.environ["PATH"] = td  # nothing executable named that binary anywhere here
                with _DriversDir(td, "ghost"):
                    with self.assertRaises(DRV.DriverUnavailable) as cm:
                        DRV.oneshot_dispatch("hello", "some-model")
                    self.assertEqual(cm.exception.runtime, "definitely-not-a-real-binary-xyz")
                    self.assertEqual(cm.exception.driver, "ghost")
            finally:
                if saved_path is None:
                    os.environ.pop("PATH", None)
                else:
                    os.environ["PATH"] = saved_path

    def test_run_false_still_probes(self):
        with tempfile.TemporaryDirectory() as td:
            _write_driver(td, "ghost", "DRIVER_AGENT_ONESHOT_EXEC='nope-xyz -p'\n")
            saved_path = os.environ.get("PATH")
            try:
                os.environ["PATH"] = td
                with _DriversDir(td, "ghost"):
                    with self.assertRaises(DRV.DriverUnavailable):
                        DRV.oneshot_dispatch("hi", "m", run=False)
            finally:
                if saved_path is None:
                    os.environ.pop("PATH", None)
                else:
                    os.environ["PATH"] = saved_path

    def test_probe_runtime_helper(self):
        self.assertTrue(DRV.probe_runtime(os.path.basename(sys.executable)) or
                        DRV.probe_runtime("sh"))   # something is always on PATH
        self.assertFalse(DRV.probe_runtime("definitely-not-a-real-binary-xyz"))
        self.assertFalse(DRV.probe_runtime(""))


class StubDriverEndToEnd(unittest.TestCase):
    """Non-negotiable #4: the stub (non-claude) driver runs a one-shot END TO END in a fixture."""

    def test_oneshot_dispatches_stub_agent(self):
        with tempfile.TemporaryDirectory() as td:
            bindir = os.path.join(td, "bin")
            os.makedirs(bindir)
            marker = os.path.join(td, "ran.txt")
            # a fixture `stub-agent` that records the argv it was invoked with, proving dispatch ran.
            _write_exe(bindir, "stub-agent",
                       "#!/usr/bin/env bash\nprintf '%%s\\n' \"$@\" > '%s'\n" % marker)
            saved_path = os.environ.get("PATH")
            try:
                os.environ["PATH"] = bindir + os.pathsep + (saved_path or "")
                with _DriversDir(SHIPPED_DRIVERS, "stub"):
                    # the resolved runtime is stub-agent (non-claude) — proves the seam is portable
                    self.assertEqual(DRV.resolved_runtime(), "stub-agent")
                    cp = DRV.oneshot_dispatch("the prompt", "stub-model-1",
                                              capture_output=True, text=True)
                self.assertEqual(cp.returncode, 0)
            finally:
                if saved_path is None:
                    os.environ.pop("PATH", None)
                else:
                    os.environ["PATH"] = saved_path
            self.assertTrue(os.path.exists(marker), "stub-agent was never actually invoked")
            with open(marker, encoding="utf-8") as fh:
                got = fh.read().splitlines()
            self.assertEqual(got, ["-p", "the prompt", "--model", "stub-model-1"])

    def test_oneshot_argv_is_byte_faithful(self):
        # run=False returns the composed argv without executing — the compose shape the bash seam uses.
        with _DriversDir(SHIPPED_DRIVERS, "stub"):
            argv = DRV.oneshot_argv("p", "m", extra=["--output-format", "stream-json"])
            self.assertEqual(argv, ["stub-agent", "-p", "p", "--model", "m",
                                    "--output-format", "stream-json"])


# ── OPTIONAL hypothesis pass — extra fuzz when installed; skip-soft otherwise (never a red) ──────
try:
    from hypothesis import given, settings, strategies as st
    _HAS_HYPOTHESIS = True
except Exception:
    _HAS_HYPOTHESIS = False


@unittest.skipUnless(_HAS_HYPOTHESIS, "hypothesis not installed (optional; stdlib checks cover this)")
class HypothesisProperties(unittest.TestCase):
    def test_quote_strip_never_grows(self):
        @given(st.text(max_size=40))
        @settings(max_examples=200, deadline=None)
        def check(v):
            stripped = DRV._strip_one_quote_pair(v)
            self.assertLessEqual(len(stripped), len(v))
        check()

    def test_degrade_roundtrip(self):
        @given(st.text(max_size=30))
        @settings(max_examples=200, deadline=None)
        def check(reason):
            raw = DRV.DEGRADE_PREFIX + reason
            d = DRV.classify(raw)
            self.assertIsInstance(d, DRV.Degraded)
            self.assertEqual(str(d), raw)
            self.assertEqual(d.reason, reason)
            self.assertFalse(DRV.pattern_matches(d, reason))   # never matches, even its own reason
            self.assertEqual(DRV.usage_keys(d), [])
        check()


if __name__ == "__main__":
    unittest.main(verbosity=1)
