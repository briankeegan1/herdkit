"""test_store.py — stdlib unit invariants for the P4 SQLite state store (HERD-305, EPIC HERD-300).

Hermetic (temp dirs only; no gh / git / herdr / network / model), stdlib ``unittest`` + ``sqlite3``.
Drives ``pysrc/herd/store.py`` directly. Covers the load-bearing claims:

  * ACCESSOR PARITY — the flat and sqlite backends answer every accessor identically (the store is one
    surface over two substrates), so ``STORE_BACKEND=sqlite`` is behavior-identical to the flat default.
  * ROUND-TRIP LOSSLESS — files → db → files is byte-for-byte identical (the migration's core proof),
    including a file with no trailing newline and non-utf8 bytes.
  * CONCURRENT CLAIM — many writers racing one id yield EXACTLY one winner, zero lost updates, on BOTH
    backends; every racer agrees on the committed owner.
  * SHA-KEYED RMW — refix bump increments transactionally; once-guards fire exactly once; approvals fold
    to the strongest record and purge by pr; the review ledger's last matching row wins.
  * BACKEND RESOLUTION — default FLAT (ship-dormant), the marker engages sqlite, the env lever forces.

Run: PYTHONPATH=pysrc python3 tests/test_store.py
"""

import os
import shutil
import tempfile
import threading
import unittest

from herd import store as S


class _PoolCase(unittest.TestCase):
    def setUp(self):
        self.pool = tempfile.mkdtemp(prefix="herd-store-test-")
        os.makedirs(os.path.join(self.pool, ".herd"), exist_ok=True)
        self._saved = {k: os.environ.get(k) for k in ("WORKTREES_DIR", "TREES", "STORE_BACKEND")}
        os.environ["WORKTREES_DIR"] = self.pool
        os.environ.pop("TREES", None)

    def tearDown(self):
        for k, v in self._saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        shutil.rmtree(self.pool, ignore_errors=True)

    def store(self, backend):
        os.environ["STORE_BACKEND"] = backend
        return S.open_store(self.pool)


class AccessorParity(_PoolCase):
    """The two backends must answer every accessor the SAME way — parity is the whole point of the
    store-backend seam (a sim can run either substrate and get identical decisions)."""

    def _exercise(self, st):
        st.record_approval("hv-informed", "42", "abcdef123456")
        st.record_approval("approved", "42", "abcdef123456")
        st.record_review("42", "sha1", "PASS", "reviewer")
        st.record_review("42", "sha1", "BLOCK", "reviewer")   # last matching row wins
        st.record_health_result("42", "sha1", "CLEAN", "ok")
        st.bump_refix("k", "sha1")
        st.bump_refix("k", "sha1")
        st.seat_stamp("s1", 5, 1000, "active")
        st.seat_stamp("s1", 6, 1001, "active")               # latest per seat wins
        return {
            "approval": st.approval_state("42", "abcdef"),   # strongest = approved
            "approval_none": st.approval_state("99"),
            "review": st.recorded_review("42", "sha1"),      # BLOCK (last)
            "health": st.health_cached_verdict("42", "sha1"),
            "refix": st.refix_count("k", "sha1"),            # 2
            "once_first": st.once("g1"),
            "once_second": st.once("g1"),
            "seat": sorted(st.seat_rows()),
        }

    def test_parity(self):
        flat = self._exercise(self.store("flat"))
        # fresh pool for sqlite so the flat writes don't bleed in
        shutil.rmtree(self.pool); os.makedirs(os.path.join(self.pool, ".herd"))
        sql = self._exercise(self.store("sqlite"))
        self.assertEqual(flat, sql, "flat and sqlite backends diverged: %r vs %r" % (flat, sql))
        self.assertEqual(flat["approval"], "approved")
        self.assertEqual(flat["approval_none"], "none")
        self.assertEqual(flat["review"], "BLOCK")
        self.assertEqual(flat["health"], "CLEAN")
        self.assertEqual(flat["refix"], 2)
        self.assertTrue(flat["once_first"] and not flat["once_second"])
        self.assertEqual(flat["seat"], [("s1", 6, 1001, "active")])

    def test_approval_purge_by_pr(self):
        for be in ("flat", "sqlite"):
            shutil.rmtree(self.pool); os.makedirs(os.path.join(self.pool, ".herd"))
            st = self.store(be)
            st.record_approval("approved", "5", "deadbeef")
            self.assertEqual(st.approval_state("5", "dead"), "approved", be)
            st.purge_pr_approvals("5")
            self.assertEqual(st.approval_state("5", "dead"), "none", "%s: purge left a phantom row" % be)

    def test_release_claim_only_own(self):
        for be in ("flat", "sqlite"):
            shutil.rmtree(self.pool); os.makedirs(os.path.join(self.pool, ".herd"))
            st = self.store(be)
            self.assertEqual(st.claim("HERD-1", "alice"), "alice", be)
            self.assertFalse(st.release_claim("HERD-1", "mallory"), "%s: released another's claim" % be)
            self.assertEqual(st.claim_owner("HERD-1"), "alice", be)
            self.assertTrue(st.release_claim("HERD-1", "alice"), be)
            self.assertIsNone(st.claim_owner("HERD-1"), be)


class RoundTrip(_PoolCase):
    """files → db → files is byte-for-byte identical — the migration's lossless core."""

    def _seed(self):
        p = self.pool
        with open(os.path.join(p, ".agent-watch-approvals"), "w") as f:
            f.write("1000 approved 42 abcdef123456\n1001 awaiting 43 beef\n")
        with open(os.path.join(p, ".agent-watch-reviewed"), "w") as f:
            f.write("1000 42 sha1 PASS reviewer\n")
        with open(os.path.join(p, ".health-result-42-sha1"), "w") as f:
            f.write("CLEAN\tall good\n")
        with open(os.path.join(p, ".herd", "engine-seats.tsv"), "w") as f:
            f.write("solo\t5\t1000\tactive\n")
        # byte-tricky: no trailing newline + a raw non-utf8 byte
        with open(os.path.join(p, ".agent-watch-merged"), "wb") as f:
            f.write(b"1000 42 my-slug\xff\x00tail")

    def _digest(self, rels, root):
        import hashlib
        out = {}
        for r in rels:
            with open(os.path.join(root, r), "rb") as fh:
                out[r] = hashlib.sha256(fh.read()).hexdigest()
        return out

    def test_migrate_rollback_byte_identical(self):
        self._seed()
        os.environ["HERD_ENGINE_DUALWRITE"] = "1"   # declare the window so the guard proceeds hermetically
        try:
            rels = S.discover_state_files(self.pool)
            self.assertIn(".agent-watch-approvals", rels)
            self.assertIn(os.path.join(".herd", "engine-seats.tsv"), rels)
            before = self._digest(rels, self.pool)
            self.assertEqual(S.migrate(self.pool, verify=True), 0, "guarded migrate should succeed")
            self.assertEqual(S.resolve_backend(self.pool), "sqlite", "marker should engage sqlite")
            # post-migration accessors read from the db
            st = S.open_store(self.pool)
            self.assertTrue(st.is_sqlite)
            self.assertEqual(st.approval_state("42", "abcdef"), "approved")
            self.assertEqual(st.recorded_review("42", "sha1"), "PASS")
            self.assertEqual(st.health_cached_verdict("42", "sha1"), "CLEAN")
            # rollback restores every byte and drops the marker
            self.assertEqual(S.rollback(self.pool), 0)
            after = self._digest(rels, self.pool)
            self.assertEqual(before, after, "round-trip was NOT byte-identical")
            self.assertEqual(S.resolve_backend(self.pool), "flat", "rollback should drop the marker")
        finally:
            os.environ.pop("HERD_ENGINE_DUALWRITE", None)

    def test_journal_never_migrated(self):
        """The append-only journal is NEVER a state file (contract §P4)."""
        with open(os.path.join(self.pool, ".herd", "journal.jsonl"), "w") as f:
            f.write('{"event":"x"}\n')
        with open(os.path.join(self.pool, ".agent-watch-approvals"), "w") as f:
            f.write("1000 approved 1 aa\n")
        rels = S.discover_state_files(self.pool)
        self.assertNotIn(os.path.join(".herd", "journal.jsonl"), rels)
        self.assertIn(".agent-watch-approvals", rels)


class ConcurrentClaim(_PoolCase):
    """Two (many) writers racing one id → exactly one winner, zero lost updates. BOTH backends."""

    def _race(self, backend, n=24):
        os.environ["STORE_BACKEND"] = backend
        results = []
        lock = threading.Lock()
        barrier = threading.Barrier(n)

        def worker(owner):
            st = S.open_store(self.pool)
            barrier.wait()                      # all racers fire together
            r = st.claim("HERD-RACE", owner)
            with lock:
                results.append(r)

        threads = [threading.Thread(target=worker, args=("w%d" % i,)) for i in range(n)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        final = S.open_store(self.pool).claim_owner("HERD-RACE")
        return set(results), final

    def test_sqlite_single_winner(self):
        winners, final = self._race("sqlite")
        self.assertEqual(len(winners), 1, "sqlite lost-update: %r" % winners)
        self.assertIn(final, winners, "committed owner not among reported winners")

    def test_flat_single_winner(self):
        winners, final = self._race("flat")
        self.assertEqual(len(winners), 1, "flat lost-update: %r" % winners)
        self.assertIn(final, winners)


class BackendResolution(_PoolCase):
    def test_default_is_flat(self):
        os.environ.pop("STORE_BACKEND", None)
        self.assertEqual(S.resolve_backend(self.pool), "flat", "ship default must be flat (dormant)")

    def test_auto_needs_marker_and_db(self):
        os.environ["STORE_BACKEND"] = "auto"
        # a marker alone (no db) must NOT engage sqlite — never engage a backend we cannot open
        with open(os.path.join(self.pool, ".herd", "store-backend"), "w") as f:
            f.write("sqlite\n")
        self.assertEqual(S.resolve_backend(self.pool), "flat", "marker without db must stay flat")

    def test_explicit_lever_forces(self):
        os.environ["STORE_BACKEND"] = "sqlite"
        st = S.open_store(self.pool)
        self.assertTrue(st.is_sqlite, "explicit sqlite lever must force the sqlite backend")
        os.environ["STORE_BACKEND"] = "flat"
        # even with a marker present, flat forces flat
        with open(os.path.join(self.pool, ".herd", "store-backend"), "w") as f:
            f.write("sqlite\n")
        self.assertEqual(S.resolve_backend(self.pool), "flat")


if __name__ == "__main__":
    unittest.main(verbosity=2)
