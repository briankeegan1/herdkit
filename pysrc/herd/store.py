"""herd.store — the SQLite state store + one-shot migration runner (HERD-305, P4, EPIC HERD-300).

P4 of the strangler port replaces the ~45 flat state files that hold the engine's MUTABLE state —
approvals, the review ledger, health results, claims, refix rounds, once-guards, the seat registry —
with a single SQLite database (WAL), reached through ACCESSOR FUNCTIONS that mirror the existing
flat-file semantics 1:1. The append-only journal (``.herd/journal.jsonl``) stays exactly where it is:
this store NEVER holds the journal (contract §3, spike §P4) — forensic truth remains an append-only
JSONL stream, and only the read-modify-write mutable state moves into the db.

THREE things ship here, all BUILD-AND-SIM-TEST ONLY (executing the migration against the real
worktree pool is a separate, later, operator-triggered act — this module never does it on import or
in a test):

  1. **The store, two backends behind one accessor surface.** :class:`Store` is a facade over either
     :class:`_FlatBackend` (reads/writes the SAME flat files ``agent-watch.sh`` owns — the current
     substrate, verbatim) or :class:`_SqliteBackend` (the same accessors against SQLite, every
     read-modify-write TRANSACTIONAL under WAL, sha-keyed). The two are behavior-identical by
     construction; a test asserts parity. Backend selection is ship-dormant: :func:`resolve_backend`
     answers ``flat`` by default and only answers ``sqlite`` once the migration runner has written a
     marker into the pool, so with nothing migrated the store is byte-identical to today.

  2. **The migration runner** (``python3 -m herd.store --migrate``). One-shot flat-files → db with a
     LOSSLESS round-trip: every mutable-state file's raw bytes are snapshotted into a ``state_blob``
     table, so ``--rollback`` reconstructs the files BYTE-IDENTICALLY (``--verify`` proves
     files → db → files is byte-for-byte). BEFORE any write it crosses the P3.5 quiesce gate
     (``herd_engine_migration_guard`` in ``scripts/herd/engine-seat.sh``) — WIRED, not reimplemented:
     it refuses loudly unless every other seat is quiesced or a dual-write window is declared, so a
     migration never races a live writer. On success it writes the backend marker; the typed tables
     are ALSO populated (best-effort) so post-migration accessors work immediately.

  3. **The runtime seam.** ``live_runtime`` / ``shadow_runtime`` resolve their store backend through
     :func:`resolve_backend` (default FLAT). The lever is ``STORE_BACKEND`` (herd-config.sh):
     ``auto`` (default — flat until the marker engages sqlite) | ``flat`` | ``sqlite``.

DOCTRINE (AGENTS.md): stdlib-only (``sqlite3`` is stdlib — no new dependency), fail-soft (an
unresolvable pool / unreadable db degrades to the safe default, never a red row or an abort under
``set -euo pipefail``), ship-dormant (default flat ⇒ hard no-op). CLI:

    python3 -m herd.store --status  [--pool DIR]     # resolved backend + marker + row counts
    python3 -m herd.store --migrate [--pool DIR]     # flat → db (guarded); --verify to prove round-trip
    python3 -m herd.store --rollback [--pool DIR]    # db → flat (byte-identical), drop the marker
    python3 -m herd.store --verify  [--pool DIR]     # files → db → files byte-identical proof, no marker
    python3 -m herd.store --main-health-fix-mark ID [--pr P] [--sha S] [--pool DIR]  # HERD-371 dedup
        # claim: rc 0 = won (file it), rc 3 = already marked (dedup), rc 2 = no pool
    python3 -m herd.store --main-health-fix-clear ID [--pool DIR]                    # drop the marker
"""

import os
import sqlite3
import sys
import time

# ── paths & backend resolution ──────────────────────────────────────────────────────────────────

# The db + marker live in the pool's own ``.herd/`` state dir, beside the journal and the seat
# registry — LOCAL, per-machine, never committed (the *-trees/ gitignore already covers it).
_DB_NAME = "store.db"
_MARKER_NAME = "store-backend"          # contains the engaged backend name ("sqlite") once migrated
_SEATS_NAME = "engine-seats.tsv"        # the P3.5 registry — the seat store adopts its exact format


def _pool_dir(state_dir=None):
    """The worktree pool root. Explicit arg wins; else ``TREES`` / ``WORKTREES_DIR`` (the same order
    live_runtime's GateState resolves). Returns ``None`` when nothing resolves — every caller then
    degrades to the safe default (flat / no-op), never inventing a path."""
    d = state_dir or os.environ.get("TREES") or os.environ.get("WORKTREES_DIR")
    return d or None


def _herd_dir(pool):
    return os.path.join(pool, ".herd") if pool else None


def db_path(state_dir=None):
    hd = _herd_dir(_pool_dir(state_dir))
    return os.path.join(hd, _DB_NAME) if hd else None


def marker_path(state_dir=None):
    hd = _herd_dir(_pool_dir(state_dir))
    return os.path.join(hd, _MARKER_NAME) if hd else None


def resolve_backend(state_dir=None):
    """The engaged store backend: ``"flat"`` (default) or ``"sqlite"``.

    ``STORE_BACKEND`` (herd-config.sh, exported into the env) is the lever:
      * ``flat``           — force flat (the current substrate).
      * ``sqlite``         — force sqlite (an operator/test explicit opt-in).
      * ``auto`` / unset   — flat UNTIL the migration runner has engaged sqlite, signalled by a marker
                             file in the pool AND a readable db. This is the ship default: with nothing
                             migrated it is flat, so behavior is byte-identical to before this module.

    Fail-soft in every branch: an unreadable marker, a missing db, or an unresolvable pool all answer
    ``flat`` — the store never engages sqlite it cannot actually open."""
    lever = (os.environ.get("STORE_BACKEND") or "auto").strip().lower()
    if lever == "flat":
        return "flat"
    if lever == "sqlite":
        return "sqlite"
    # auto (default): honour the marker the migration runner wrote, but only if the db is really there.
    try:
        mk = marker_path(state_dir)
        db = db_path(state_dir)
        if mk and db and os.path.isfile(mk) and os.path.isfile(db):
            with open(mk, encoding="utf-8") as fh:
                if fh.read().strip() == "sqlite":
                    return "sqlite"
    except Exception:
        pass
    return "flat"


def open_store(state_dir=None, backend=None):
    """Open the store on the resolved (or forced) backend. Fail-soft: if sqlite is asked for but the db
    cannot be opened, fall back to flat rather than raising into a caller under ``set -euo pipefail``."""
    pool = _pool_dir(state_dir)
    be = backend or resolve_backend(state_dir)
    if be == "sqlite":
        dbp = db_path(state_dir)
        try:
            return Store(_SqliteBackend(dbp), pool, "sqlite")
        except Exception:
            be = "flat"
    return Store(_FlatBackend(pool), pool, "flat")


# ── the accessor facade ─────────────────────────────────────────────────────────────────────────


class Store:
    """One accessor surface over either backend. Every method mirrors the flat-file semantics the bash
    engine and ``live_runtime.GateState`` already implement, so the two substrates interoperate 1:1."""

    def __init__(self, backend, pool, name):
        self._b = backend
        self.pool = pool
        self.backend = name

    @property
    def is_sqlite(self):
        return self.backend == "sqlite"

    # approvals ── sha-keyed approval ledger (approvals.sh; rows "<epoch> <state> <pr> <sha>") ───────
    def approval_state(self, pr, sha=None):
        return self._b.approval_state(pr, sha)

    def record_approval(self, state, pr, sha):
        return self._b.record_approval(state, pr, sha)

    def purge_pr_approvals(self, pr):
        return self._b.purge_pr_approvals(pr)

    # review ledger ── "<epoch> <pr> <sha> <verdict> <source>", last matching row wins ───────────────
    def recorded_review(self, pr, sha):
        return self._b.recorded_review(pr, sha)

    def record_review(self, pr, sha, verdict, source="reviewer"):
        return self._b.record_review(pr, sha, verdict, source)

    # health results ── sha-keyed terminal verdict cache ("<verdict>\t<detail>") ─────────────────────
    def health_cached_verdict(self, pr, sha):
        return self._b.health_cached_verdict(pr, sha)

    def record_health_result(self, pr, sha, verdict, detail=""):
        return self._b.record_health_result(pr, sha, verdict, detail)

    # claims ── atomic claim-or-abort: exactly one writer wins a contested id (herd-claim.sh doctrine) ─
    def claim(self, item_id, owner):
        """Claim ``item_id`` for ``owner``. Returns the WINNING owner: ``owner`` if we won (or already
        held it), else the identity that got there first. Atomic across concurrent writers — zero lost
        updates — so two coordinators racing the same pick never both win."""
        return self._b.claim(item_id, owner)

    def claim_owner(self, item_id):
        return self._b.claim_owner(item_id)

    def release_claim(self, item_id, owner):
        """Release OUR OWN claim (never steal another identity's). True iff a claim we owned was
        released."""
        return self._b.release_claim(item_id, owner)

    # refix rounds ── sha-keyed refix-budget counter, transactional increment (contract §4) ──────────
    def refix_count(self, key, sha):
        return self._b.refix_count(key, sha)

    def bump_refix(self, key, sha):
        """Increment and return the refix round count for ``(key, sha)``. Atomic RMW."""
        return self._b.bump_refix(key, sha)

    # once-guards ── fire a hold's side effects exactly once per key (contract §5.3) ─────────────────
    def once(self, key):
        """True the FIRST time this exact key is seen (record + proceed), False thereafter. Atomic, so
        two racing ticks never both fire a once-guarded side effect."""
        return self._b.once(key)

    # seat registry ── the P3.5 engine-seats.tsv, latest row per seat ("<id>\t<lvl>\t<epoch>\t<st>") ──
    def seat_stamp(self, seat_id, level, epoch, state="active"):
        return self._b.seat_stamp(seat_id, level, epoch, state)

    def seat_rows(self):
        """Latest ``(id, level, epoch, state)`` per seat (chronological fold — last row per id wins)."""
        return self._b.seat_rows()

    # main-health-fix marker ── HERD-371: the MAIN RED autofix filing leg's dedup marker, keyed by the
    # FAILING-TEST IDENTITY (not sha, not pr) so it survives a sha change and is visible to every seat ──
    def main_health_fix_marked(self, identity):
        return self._b.main_health_fix_marked(identity)

    def mark_main_health_fix(self, identity, pr="", sha=""):
        """Atomic claim-or-abort for ``identity`` (mirrors ``claim``/``once``). True iff THIS call is the
        FIRST across the whole pool to see this failing-test identity — the caller should file. False iff
        it is already marked (another seat, or an earlier tick on this seat, already filed) — the caller
        must dedup, never re-file."""
        return self._b.mark_main_health_fix(identity, pr, sha)

    def clear_main_health_fix(self, identity):
        """Drop the marker once main is GREEN for this identity, so a LATER regression files fresh."""
        return self._b.clear_main_health_fix(identity)


# ── flat backend: the current substrate, verbatim ─────────────────────────────────────────────────


def _now():
    return int(time.time())


def _thread_id():
    """A per-thread id so a claim's staging temp file is unique across concurrent writers in ONE process
    (os.getpid() alone collides between threads). stdlib; falls back to 0 if threading is unavailable."""
    try:
        import threading
        return threading.get_ident()
    except Exception:
        return 0


class _FlatBackend:
    """Accessors over the SAME flat files the bash engine owns. This is the current behavior expressed
    as the store's flat backend — so ``resolve_backend()==flat`` (the ship default) routes through code
    that is byte-identical in effect to what ``agent-watch.sh`` / ``approvals.sh`` do today."""

    def __init__(self, pool):
        self.pool = pool

    def _p(self, name):
        return os.path.join(self.pool, name) if self.pool else None

    def _hp(self, name):
        hd = _herd_dir(self.pool)
        return os.path.join(hd, name) if hd else None

    # approvals ──────────────────────────────────────────────────────────────────────────────────
    def approval_state(self, pr, sha=None):
        path = self._p(".agent-watch-approvals")
        if not path or not os.path.isfile(path) or pr in (None, ""):
            return "none"
        best = "none"
        rank = {"none": 0, "hv-informed": 1, "approved": 2}
        try:
            with open(path, encoding="utf-8") as fh:
                for line in fh:
                    f = line.split()
                    if len(f) < 4 or f[2] != str(pr):
                        continue
                    s = f[3]
                    if sha:
                        if s != str(sha) and not s.startswith(str(sha)) and not str(sha).startswith(s):
                            continue
                    st = f[1] if f[1] in rank else "none"
                    st = "approved" if st == "approved" else ("hv-informed" if st == "hv-informed" else "none")
                    if rank.get(st, 0) > rank.get(best, 0):
                        best = st
        except Exception:
            return "none"
        return best

    def record_approval(self, state, pr, sha):
        path = self._p(".agent-watch-approvals")
        if not path:
            return
        _ensure_parent(path)
        try:
            with open(path, "a", encoding="utf-8") as fh:
                fh.write("%s %s %s %s\n" % (_now(), state, pr, sha))
        except Exception:
            pass

    def purge_pr_approvals(self, pr):
        path = self._p(".agent-watch-approvals")
        if not path or not os.path.isfile(path):
            return
        try:
            with open(path, encoding="utf-8") as fh:
                kept = [ln for ln in fh if len(ln.split()) < 3 or ln.split()[2] != str(pr)]
            with open(path, "w", encoding="utf-8") as fh:
                fh.writelines(kept)
        except Exception:
            pass

    # review ledger ──────────────────────────────────────────────────────────────────────────────
    def recorded_review(self, pr, sha):
        path = self._p(".agent-watch-reviewed")
        if not path or not os.path.isfile(path):
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
        path = self._p(".agent-watch-reviewed")
        if not path:
            return
        _ensure_parent(path)
        try:
            with open(path, "a", encoding="utf-8") as fh:
                fh.write("%s %s %s %s %s\n" % (_now(), pr, sha, verdict, source))
        except Exception:
            pass

    # health results ─────────────────────────────────────────────────────────────────────────────
    def _health_file(self, pr, sha):
        return self._p(".health-result-%s-%s" % (pr, sha))

    def health_cached_verdict(self, pr, sha):
        path = self._health_file(pr, sha)
        if not path or not os.path.isfile(path):
            return None
        try:
            with open(path, encoding="utf-8") as fh:
                first = fh.readline().rstrip("\n")
        except Exception:
            return None
        v = first.split("\t", 1)[0]
        return v if v in ("CLEAN", "FLAKY", "CODEERROR") else None

    def record_health_result(self, pr, sha, verdict, detail=""):
        path = self._health_file(pr, sha)
        if not path or not sha:
            return
        _ensure_parent(path)
        try:
            with open(path, "w", encoding="utf-8") as fh:
                fh.write("%s\t%s\n" % (verdict, detail or ""))
        except Exception:
            pass

    # claims ─────────────────────────────────────────────────────────────────────────────────────
    def _claim_file(self, item_id):
        return self._hp("claim-%s" % _safe(item_id))

    def claim(self, item_id, owner):
        path = self._claim_file(item_id)
        if not path:
            return owner
        _ensure_parent(path)
        # Atomic claim-or-abort with NO empty window: materialize a COMPLETE temp file (owner already
        # written and closed) and hard-link it into place. os.link is atomic and fails EEXIST when a
        # rival already linked — so the claim file, ONCE IT EXISTS, always carries the winner's identity.
        #
        # A plain O_CREAT|O_EXCL create is atomic for "who makes the file", but it leaves the file EMPTY
        # until the winner's separate os.write lands. A loser that hits EEXIST in that window reads an
        # empty file, gets no owner, and (via `or owner`) falsely reports ITSELF the winner — a real
        # lost-update that surfaces as multiple "winners" under load (HERD-333). Writing the identity
        # BEFORE the file is linkable closes that window entirely.
        tmp = "%s.tmp-%d-%d" % (path, os.getpid(), _thread_id())
        try:
            fd = os.open(tmp, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o644)
        except Exception:
            # Could not stage a temp file (e.g. a stale sibling from a crashed writer) — fall back to a
            # committed read so we never invent a win; if truly nothing is there, contend as ourselves.
            return self.claim_owner(item_id) or owner
        try:
            os.write(fd, ("%s\t%s\n" % (owner, _now())).encode("utf-8"))
        finally:
            os.close(fd)
        try:
            os.link(tmp, path)          # atomic publish: fails EEXIST if a rival won the race
            return owner                # we won (the claim file now holds OUR identity)
        except FileExistsError:
            return self.claim_owner(item_id) or owner   # rival won; their id is already fully written
        except Exception:
            return owner
        finally:
            try:
                os.remove(tmp)          # our temp is never the published file — always clean it up
            except Exception:
                pass

    def claim_owner(self, item_id):
        path = self._claim_file(item_id)
        if not path or not os.path.isfile(path):
            return None
        try:
            with open(path, encoding="utf-8") as fh:
                first = fh.readline().split("\t")
            return first[0] if first and first[0] else None
        except Exception:
            return None

    def release_claim(self, item_id, owner):
        if self.claim_owner(item_id) != owner:
            return False
        path = self._claim_file(item_id)
        try:
            os.remove(path)
            return True
        except Exception:
            return False

    # refix rounds ───────────────────────────────────────────────────────────────────────────────
    def _refix_file(self, key, sha):
        return self._hp("refix-%s-%s" % (_safe(key), _safe(sha)))

    def refix_count(self, key, sha):
        path = self._refix_file(key, sha)
        if not path or not os.path.isfile(path):
            return 0
        try:
            with open(path, encoding="utf-8") as fh:
                return int((fh.readline() or "0").strip() or "0")
        except Exception:
            return 0

    def bump_refix(self, key, sha):
        path = self._refix_file(key, sha)
        if not path:
            return 0
        _ensure_parent(path)
        n = self.refix_count(key, sha) + 1
        try:
            with open(path, "w", encoding="utf-8") as fh:
                fh.write("%d\n" % n)
        except Exception:
            pass
        return n

    # once-guards ────────────────────────────────────────────────────────────────────────────────
    def once(self, key):
        path = self._hp("once-%s" % _safe(key))
        if not path:
            return True
        _ensure_parent(path)
        try:
            fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o644)
        except FileExistsError:
            return False
        except Exception:
            return True
        os.close(fd)
        return True

    # seat registry ──────────────────────────────────────────────────────────────────────────────
    def seat_stamp(self, seat_id, level, epoch, state="active"):
        path = self._hp(_SEATS_NAME)
        if not path:
            return
        _ensure_parent(path)
        try:
            with open(path, "a", encoding="utf-8") as fh:
                fh.write("%s\t%s\t%s\t%s\n" % (seat_id, int(level), int(epoch), state))
        except Exception:
            pass

    def seat_rows(self):
        path = self._hp(_SEATS_NAME)
        if not path or not os.path.isfile(path):
            return []
        latest = {}
        try:
            with open(path, encoding="utf-8") as fh:
                for line in fh:
                    f = line.rstrip("\n").split("\t")
                    if len(f) >= 3 and f[0]:
                        latest[f[0]] = (f[0], _int(f[1]), _int(f[2]), f[3] if len(f) > 3 else "active")
        except Exception:
            return []
        return [latest[k] for k in latest]

    # main-health-fix marker ─────────────────────────────────────────────────────────────────────
    def _main_health_fix_file(self, identity):
        return self._p(".agent-watch-main-health-fix-%s" % _safe(identity))

    def main_health_fix_marked(self, identity):
        path = self._main_health_fix_file(identity)
        return bool(path and os.path.isfile(path))

    def mark_main_health_fix(self, identity, pr="", sha=""):
        path = self._main_health_fix_file(identity)
        if not path:
            return True
        _ensure_parent(path)
        # Atomic claim-or-abort, exactly like `once()`: O_CREAT|O_EXCL never leaves a lost-update window
        # between two seats racing to file the SAME failing-test identity.
        try:
            fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o644)
        except FileExistsError:
            return False
        except Exception:
            return True
        try:
            os.write(fd, ("%s\t%s\t%s\n" % (_now(), pr, sha)).encode("utf-8"))
        finally:
            os.close(fd)
        return True

    def clear_main_health_fix(self, identity):
        path = self._main_health_fix_file(identity)
        if not path:
            return
        try:
            os.remove(path)
        except Exception:
            pass


# ── sqlite backend: the same accessors, transactional under WAL ───────────────────────────────────

_SCHEMA = """
CREATE TABLE IF NOT EXISTS approvals   (epoch INTEGER, state TEXT, pr TEXT, sha TEXT);
CREATE INDEX IF NOT EXISTS approvals_pr ON approvals(pr);
CREATE TABLE IF NOT EXISTS review_ledger(epoch INTEGER, pr TEXT, sha TEXT, verdict TEXT, source TEXT);
CREATE INDEX IF NOT EXISTS review_prsha ON review_ledger(pr, sha);
CREATE TABLE IF NOT EXISTS health_results(pr TEXT, sha TEXT, verdict TEXT, detail TEXT, epoch INTEGER,
                                          PRIMARY KEY (pr, sha));
CREATE TABLE IF NOT EXISTS claims       (item_id TEXT PRIMARY KEY, owner TEXT, epoch INTEGER);
CREATE TABLE IF NOT EXISTS refix_rounds (key TEXT, sha TEXT, n INTEGER, PRIMARY KEY (key, sha));
CREATE TABLE IF NOT EXISTS once_guards  (key TEXT PRIMARY KEY, epoch INTEGER);
CREATE TABLE IF NOT EXISTS seat_registry(epoch INTEGER, id TEXT, level INTEGER, state TEXT);
CREATE INDEX IF NOT EXISTS seat_id ON seat_registry(id);
CREATE TABLE IF NOT EXISTS main_health_fix(identity TEXT PRIMARY KEY, epoch INTEGER, pr TEXT, sha TEXT);
CREATE TABLE IF NOT EXISTS state_blob  (path TEXT PRIMARY KEY, content BLOB, mode INTEGER);
CREATE TABLE IF NOT EXISTS meta        (key TEXT PRIMARY KEY, value TEXT);
"""


# Bounded retries for the one-time WAL + schema setup when many connections open a fresh db at once
# (200 × 10ms ≈ 2s worst case — far under the 30s busy_timeout, and only ever hit on first-touch races).
_INIT_RETRIES = 200


class _SqliteBackend:
    """The store on SQLite. WAL for concurrent readers/writers; every read-modify-write runs inside a
    ``BEGIN IMMEDIATE`` transaction so a contested claim / refix bump / once-guard resolves without a
    lost update. ``sqlite3`` is stdlib — no new dependency (AGENTS.md)."""

    def __init__(self, path):
        if not path:
            raise ValueError("no db path")
        _ensure_parent(path)
        self.path = path
        self._conn = sqlite3.connect(path, timeout=30, isolation_level=None)
        # busy_timeout FIRST, so every subsequent lock wait — including the one-time WAL + schema
        # setup below — is patient rather than failing fast on a contended lock.
        self._conn.execute("PRAGMA busy_timeout=30000")
        # One-time WAL enable + schema create is a WRITE, and when many connections open the SAME fresh
        # db at once (the concurrent-claim path) it collides: CREATE TABLE contends for the write lock,
        # and — critically — ``PRAGMA journal_mode=WAL`` can return SQLITE_BUSY *without* honoring
        # busy_timeout (the journal-mode switch is not a normal statement the busy handler covers). A
        # throw here is not benign: ``open_store`` catches it and SILENTLY downgrades that one caller to
        # the FLAT backend, so the pool splits across two substrates and a second writer manufactures a
        # false claim "winner" (HERD-333). Retry the setup a bounded number of times so concurrent opens
        # converge to WAL instead of one of them tipping into flat. Idempotent (all IF NOT EXISTS).
        for _attempt in range(_INIT_RETRIES):
            try:
                self._conn.execute("PRAGMA journal_mode=WAL")
                self._conn.executescript(_SCHEMA)
                break
            except sqlite3.OperationalError:
                if _attempt == _INIT_RETRIES - 1:
                    raise
                time.sleep(0.01)

    # _rmw — run a read-modify-write body inside a BEGIN IMMEDIATE … COMMIT transaction, RETRYING on a
    # transient lock error. BEGIN IMMEDIATE takes the write lock up front so a contended writer WAITS
    # (busy_timeout) rather than racing; a lock error that still slips through (a COMMIT that raced) is
    # retried, never swallowed into a false result. On definitive give-up it re-raises so the caller's
    # honest fallback (a fresh committed read) runs — a claimer NEVER reports itself the winner unless a
    # committed row actually says so. ``body(conn)`` returns the value; it must not commit itself.
    def _rmw(self, body, attempts=50):
        last = None
        for _ in range(attempts):
            try:
                self._conn.execute("BEGIN IMMEDIATE")
            except sqlite3.OperationalError as e:
                last = e
                time.sleep(0.005)
                continue
            try:
                val = body(self._conn)
                self._conn.execute("COMMIT")
                return val
            except sqlite3.OperationalError as e:
                last = e
                try:
                    self._conn.execute("ROLLBACK")
                except Exception:
                    pass
                time.sleep(0.005)
                continue
        raise last if last else sqlite3.OperationalError("rmw exhausted retries")

    # approvals ──────────────────────────────────────────────────────────────────────────────────
    def approval_state(self, pr, sha=None):
        if pr in (None, ""):
            return "none"
        rank = {"none": 0, "hv-informed": 1, "approved": 2}
        best = "none"
        for (state, s) in self._conn.execute(
                "SELECT state, sha FROM approvals WHERE pr=?", (str(pr),)):
            if sha:
                s = s or ""
                if s != str(sha) and not s.startswith(str(sha)) and not str(sha).startswith(s):
                    continue
            st = state if state in ("approved", "hv-informed") else "none"
            if rank.get(st, 0) > rank.get(best, 0):
                best = st
        return best

    def record_approval(self, state, pr, sha):
        self._conn.execute("INSERT INTO approvals(epoch, state, pr, sha) VALUES (?,?,?,?)",
                           (_now(), state, str(pr), str(sha)))

    def purge_pr_approvals(self, pr):
        self._conn.execute("DELETE FROM approvals WHERE pr=?", (str(pr),))

    # review ledger ──────────────────────────────────────────────────────────────────────────────
    def recorded_review(self, pr, sha):
        row = self._conn.execute(
            "SELECT verdict FROM review_ledger WHERE pr=? AND sha=? ORDER BY rowid DESC LIMIT 1",
            (str(pr), str(sha))).fetchone()
        return row[0] if row else None

    def record_review(self, pr, sha, verdict, source="reviewer"):
        self._conn.execute(
            "INSERT INTO review_ledger(epoch, pr, sha, verdict, source) VALUES (?,?,?,?,?)",
            (_now(), str(pr), str(sha), verdict, source))

    # health results ─────────────────────────────────────────────────────────────────────────────
    def health_cached_verdict(self, pr, sha):
        row = self._conn.execute("SELECT verdict FROM health_results WHERE pr=? AND sha=?",
                                 (str(pr), str(sha))).fetchone()
        v = row[0] if row else None
        return v if v in ("CLEAN", "FLAKY", "CODEERROR") else None

    def record_health_result(self, pr, sha, verdict, detail=""):
        if not sha:
            return
        self._conn.execute(
            "INSERT INTO health_results(pr, sha, verdict, detail, epoch) VALUES (?,?,?,?,?) "
            "ON CONFLICT(pr, sha) DO UPDATE SET verdict=excluded.verdict, detail=excluded.detail, "
            "epoch=excluded.epoch", (str(pr), str(sha), verdict, detail or "", _now()))

    # claims ── the transactional claim-or-abort ───────────────────────────────────────────────────
    def claim(self, item_id, owner):
        def body(conn):
            conn.execute("INSERT OR IGNORE INTO claims(item_id, owner, epoch) VALUES (?,?,?)",
                        (str(item_id), owner, _now()))
            row = conn.execute("SELECT owner FROM claims WHERE item_id=?", (str(item_id),)).fetchone()
            return row[0] if row else owner
        try:
            return self._rmw(body)
        except Exception:
            # Never claim a false win: report the TRUE committed owner, or ours only if the table is
            # genuinely empty (the write never landed — a caller that retries will contend again).
            return self.claim_owner(item_id) or owner

    def claim_owner(self, item_id):
        row = self._conn.execute("SELECT owner FROM claims WHERE item_id=?", (str(item_id),)).fetchone()
        return row[0] if row else None

    def release_claim(self, item_id, owner):
        def body(conn):
            return conn.execute("DELETE FROM claims WHERE item_id=? AND owner=?",
                               (str(item_id), owner)).rowcount
        try:
            return self._rmw(body) > 0
        except Exception:
            return False

    # refix rounds ───────────────────────────────────────────────────────────────────────────────
    def refix_count(self, key, sha):
        row = self._conn.execute("SELECT n FROM refix_rounds WHERE key=? AND sha=?",
                                 (str(key), str(sha))).fetchone()
        return int(row[0]) if row else 0

    def bump_refix(self, key, sha):
        def body(conn):
            conn.execute(
                "INSERT INTO refix_rounds(key, sha, n) VALUES (?,?,1) "
                "ON CONFLICT(key, sha) DO UPDATE SET n = n + 1", (str(key), str(sha)))
            row = conn.execute("SELECT n FROM refix_rounds WHERE key=? AND sha=?",
                              (str(key), str(sha))).fetchone()
            return int(row[0]) if row else 0
        try:
            return self._rmw(body)
        except Exception:
            return self.refix_count(key, sha)

    # once-guards ────────────────────────────────────────────────────────────────────────────────
    def once(self, key):
        def body(conn):
            return conn.execute("INSERT OR IGNORE INTO once_guards(key, epoch) VALUES (?,?)",
                               (str(key), _now())).rowcount > 0
        try:
            return self._rmw(body)
        except Exception:
            # A once-guard that cannot record must NOT fire (returning True would double-fire a hold's
            # side effects) — fail closed.
            return False

    # seat registry ──────────────────────────────────────────────────────────────────────────────
    def seat_stamp(self, seat_id, level, epoch, state="active"):
        self._conn.execute("INSERT INTO seat_registry(epoch, id, level, state) VALUES (?,?,?,?)",
                           (int(epoch), seat_id, int(level), state))

    def seat_rows(self):
        rows = self._conn.execute(
            "SELECT id, level, epoch, state FROM seat_registry ORDER BY rowid").fetchall()
        latest = {}
        for (sid, lvl, ep, st) in rows:
            latest[sid] = (sid, _int(lvl), _int(ep), st or "active")
        return [latest[k] for k in latest]

    # main-health-fix marker ─────────────────────────────────────────────────────────────────────
    def main_health_fix_marked(self, identity):
        row = self._conn.execute(
            "SELECT 1 FROM main_health_fix WHERE identity=?", (str(identity),)).fetchone()
        return row is not None

    def mark_main_health_fix(self, identity, pr="", sha=""):
        def body(conn):
            return conn.execute(
                "INSERT OR IGNORE INTO main_health_fix(identity, epoch, pr, sha) VALUES (?,?,?,?)",
                (str(identity), _now(), str(pr), str(sha))).rowcount > 0
        try:
            return self._rmw(body)
        except Exception:
            # Fail CLOSED like `once()`: if the marker cannot be durably recorded, never claim a win —
            # missing one filing is safe, double-filing a duplicate tracker item is the bug this exists
            # to remove.
            return False

    def clear_main_health_fix(self, identity):
        def body(conn):
            conn.execute("DELETE FROM main_health_fix WHERE identity=?", (str(identity),))
            return True
        try:
            self._rmw(body)
        except Exception:
            pass

    # ── migration substrate (state_blob + meta): NOT part of the accessor surface ─────────────────
    def put_blob(self, path, content, mode):
        self._conn.execute(
            "INSERT INTO state_blob(path, content, mode) VALUES (?,?,?) "
            "ON CONFLICT(path) DO UPDATE SET content=excluded.content, mode=excluded.mode",
            (path, sqlite3.Binary(content), mode))

    def blobs(self):
        return list(self._conn.execute("SELECT path, content, mode FROM state_blob ORDER BY path"))

    def set_meta(self, key, value):
        self._conn.execute(
            "INSERT INTO meta(key, value) VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
            (key, value))

    def get_meta(self, key):
        row = self._conn.execute("SELECT value FROM meta WHERE key=?", (key,)).fetchone()
        return row[0] if row else None

    def counts(self):
        out = {}
        for t in ("approvals", "review_ledger", "health_results", "claims", "refix_rounds",
                  "once_guards", "seat_registry", "main_health_fix", "state_blob"):
            try:
                out[t] = self._conn.execute("SELECT COUNT(*) FROM %s" % t).fetchone()[0]
            except Exception:
                out[t] = 0
        return out

    def close(self):
        try:
            self._conn.close()
        except Exception:
            pass


# ── shared helpers ────────────────────────────────────────────────────────────────────────────────


def _ensure_parent(path):
    d = os.path.dirname(path)
    if d and not os.path.isdir(d):
        try:
            os.makedirs(d, exist_ok=True)
        except Exception:
            pass


def _safe(token):
    """A filesystem-safe rendering of an id/key for a flat marker name (no path separators / spaces)."""
    return "".join(c if (c.isalnum() or c in "._@") else "_" for c in str(token))


def _int(v):
    try:
        return int(v)
    except (TypeError, ValueError):
        return 0


# ── the migration runner ──────────────────────────────────────────────────────────────────────────

# Mutable-state files this store owns, discovered under the pool for the lossless snapshot. The journal
# and any other append-only ``*.jsonl`` are DELIBERATELY excluded (contract §P4: the journal is NEVER in
# the db). Config, secrets, the db itself and the marker are never state and never snapshotted.
_ROOT_PREFIXES = (".agent-watch-", ".health-result-", ".health-", ".review-result-",
                  ".review-inflight-", ".review-registry-", ".review-log-", ".live-noted-")
_HERD_PREFIXES = ("claim-", "refix-", "once-")
_HERD_EXACT = (_SEATS_NAME,)
_DENY_SUFFIX = (".jsonl",)
_DENY_HERD = (_DB_NAME, _MARKER_NAME, "config", "config.local", "secrets", "journal.jsonl",
              "journal-shadow.jsonl", "ledger.jsonl")


def discover_state_files(pool):
    """Every mutable-state file under ``pool`` this store migrates, as pool-relative paths (sorted).
    Scans the pool root (the ``.agent-watch-*`` / ``.health-*`` / ``.review-*`` dotfiles) and ``.herd/``
    (the seat registry + the store's own claim/refix/once markers), honouring the deny rules above."""
    if not pool or not os.path.isdir(pool):
        return []
    found = []
    try:
        for name in os.listdir(pool):
            full = os.path.join(pool, name)
            if not os.path.isfile(full):
                continue
            if name.endswith(_DENY_SUFFIX):
                continue
            if any(name.startswith(p) for p in _ROOT_PREFIXES):
                found.append(name)
    except Exception:
        pass
    hd = _herd_dir(pool)
    if hd and os.path.isdir(hd):
        try:
            for name in os.listdir(hd):
                full = os.path.join(hd, name)
                if not os.path.isfile(full):
                    continue
                if name in _DENY_HERD or name.endswith(_DENY_SUFFIX):
                    continue
                if name in _HERD_EXACT or any(name.startswith(p) for p in _HERD_PREFIXES):
                    found.append(os.path.join(".herd", name))
        except Exception:
            pass
    return sorted(found)


def _migration_guard_ok(pool, surface="store-migrate"):
    """Cross the P3.5 quiesce gate BEFORE any migration write — WIRED, not reimplemented. Shells into
    ``scripts/herd/engine-seat.sh`` with the pool exported and calls ``herd_engine_migration_guard``:
    rc 0 ⇒ proceed (all other seats quiesced / aged out, or a dual-write window declared), rc 1 ⇒ the
    guard REFUSED (it printed the un-quiesced seats + remedy to stderr and journaled the refusal).

    This is a GATE, so it fails STRICT: if the guard machinery cannot be located or sourced we REFUSE
    (a migration must never proceed unable to prove the pool is quiesced) unless an operator has
    explicitly declared a dual-write window via ``HERD_ENGINE_DUALWRITE``."""
    import subprocess
    scripts = _scripts_dir()
    seat = os.path.join(scripts, "engine-seat.sh") if scripts else None
    if not seat or not os.path.isfile(seat):
        if str(os.environ.get("HERD_ENGINE_DUALWRITE", "")).lower() in ("1", "true", "yes", "on"):
            return True
        sys.stderr.write("herd store: cannot locate engine-seat.sh — refusing migration (cannot prove "
                         "the pool is quiesced). Set HERD_ENGINE_DUALWRITE=1 to override deliberately.\n")
        return False
    env = dict(os.environ)
    env["WORKTREES_DIR"] = pool
    script = (
        '. "%s/journal.sh" 2>/dev/null || true\n'
        '. "%s/engine-version.sh" 2>/dev/null || true\n'
        '. "%s" || exit 3\n'
        'herd_engine_migration_guard "%s"\n' % (scripts, scripts, seat, surface))
    try:
        rc = subprocess.call(["bash", "-c", script], env=env)
    except Exception as e:
        sys.stderr.write("herd store: could not run the migration guard (%s) — refusing.\n" % e)
        return False
    return rc == 0


def _scripts_dir():
    """Locate ``scripts/herd``. ``HERDKIT_HOME`` wins (bin/herd exports it); else walk up from this file
    (pysrc/herd/store.py → repo root → scripts/herd)."""
    home = os.environ.get("HERDKIT_HOME")
    if home:
        cand = os.path.join(home, "scripts", "herd")
        if os.path.isdir(cand):
            return cand
    here = os.path.dirname(os.path.abspath(__file__))
    cand = os.path.normpath(os.path.join(here, "..", "..", "scripts", "herd"))
    return cand if os.path.isdir(cand) else None


def _ingest_typed(be, pool, rel, raw):
    """Best-effort parse of a snapshotted flat file into its typed table, so post-migration accessors
    answer immediately. A parse failure is silently skipped — the ``state_blob`` snapshot (and thus the
    lossless round-trip) is unaffected; only the convenience typed row is lost."""
    text = raw.decode("utf-8", "replace")
    name = os.path.basename(rel)
    try:
        if name == ".agent-watch-approvals":
            for ln in text.splitlines():
                f = ln.split()
                if len(f) >= 4:
                    be._conn.execute("INSERT INTO approvals(epoch, state, pr, sha) VALUES (?,?,?,?)",
                                    (_int(f[0]), f[1], f[2], f[3]))
        elif name == ".agent-watch-reviewed":
            for ln in text.splitlines():
                f = ln.split()
                if len(f) >= 4:
                    be._conn.execute(
                        "INSERT INTO review_ledger(epoch, pr, sha, verdict, source) VALUES (?,?,?,?,?)",
                        (_int(f[0]), f[1], f[2], f[3], f[4] if len(f) > 4 else "reviewer"))
        elif name.startswith(".health-result-"):
            key = name[len(".health-result-"):]
            pr, _, sha = key.partition("-")
            first = (text.splitlines() or [""])[0]
            v = first.split("\t", 1)
            be.record_health_result(pr, sha, v[0], v[1] if len(v) > 1 else "")
        elif name == _SEATS_NAME:
            for ln in text.splitlines():
                f = ln.split("\t")
                if len(f) >= 3 and f[0]:
                    be._conn.execute("INSERT INTO seat_registry(epoch, id, level, state) VALUES (?,?,?,?)",
                                    (_int(f[2]), f[0], _int(f[1]), f[3] if len(f) > 3 else "active"))
        elif name.startswith("claim-"):
            first = (text.splitlines() or [""])[0].split("\t")
            if first and first[0]:
                be._conn.execute("INSERT OR IGNORE INTO claims(item_id, owner, epoch) VALUES (?,?,?)",
                                (name[len("claim-"):], first[0], _int(first[1]) if len(first) > 1 else 0))
        elif name.startswith("once-"):
            be._conn.execute("INSERT OR IGNORE INTO once_guards(key, epoch) VALUES (?,?)",
                            (name[len("once-"):], 0))
    except Exception:
        pass


def migrate(pool, verify=False):
    """One-shot flat-files → db. Crosses the quiesce guard first; snapshots every mutable-state file's
    raw bytes into ``state_blob`` (the lossless carrier) and populates the typed tables; on success
    writes the backend marker so ``resolve_backend`` engages sqlite. Returns 0 on success, non-zero on
    a refused guard or an error. Idempotent-safe: re-running rebuilds the snapshot from the live files."""
    if not pool or not os.path.isdir(pool):
        sys.stderr.write("herd store: no pool to migrate (set WORKTREES_DIR / --pool)\n")
        return 2
    if not _migration_guard_ok(pool):
        return 1
    dbp = os.path.join(_herd_dir(pool), _DB_NAME)
    try:
        be = _SqliteBackend(dbp)
    except Exception as e:
        sys.stderr.write("herd store: cannot open db %s (%s)\n" % (dbp, e))
        return 2
    files = discover_state_files(pool)
    for rel in files:
        full = os.path.join(pool, rel)
        try:
            with open(full, "rb") as fh:
                raw = fh.read()
            mode = os.stat(full).st_mode & 0o777
        except Exception:
            continue
        be.put_blob(rel, raw, mode)
        _ingest_typed(be, pool, rel, raw)
    be.set_meta("migrated_at", str(_now()))
    be.set_meta("engine_level", os.environ.get("HERD_ENGINE_LEVEL_FORCE", "") or "")
    be.set_meta("file_count", str(len(files)))
    ok = True
    if verify:
        ok = _verify_roundtrip(pool, be)
        if not ok:
            sys.stderr.write("herd store: round-trip verification FAILED — marker NOT written\n")
    be.close()
    if not ok:
        return 4
    # Engage sqlite: write the marker resolve_backend() honours. Journal the applied migration.
    try:
        with open(os.path.join(_herd_dir(pool), _MARKER_NAME), "w", encoding="utf-8") as fh:
            fh.write("sqlite\n")
    except Exception:
        pass
    _journal(pool, "engine_migration_applied", files=str(len(files)), backend="sqlite")
    sys.stdout.write("herd store: migrated %d state file(s) → %s (backend engaged: sqlite)\n"
                     % (len(files), dbp))
    return 0


def rollback(pool):
    """db → flat: reconstruct every snapshotted file BYTE-IDENTICALLY from ``state_blob`` and drop the
    marker so ``resolve_backend`` reverts to flat. The safe undo — a migration is never a one-way door."""
    if not pool or not os.path.isdir(pool):
        sys.stderr.write("herd store: no pool to roll back\n")
        return 2
    dbp = os.path.join(_herd_dir(pool), _DB_NAME)
    if not os.path.isfile(dbp):
        sys.stderr.write("herd store: no db at %s — nothing to roll back\n" % dbp)
        return 2
    try:
        be = _SqliteBackend(dbp)
    except Exception as e:
        sys.stderr.write("herd store: cannot open db %s (%s)\n" % (dbp, e))
        return 2
    n = _emit_blobs(pool, be)
    be.close()
    try:
        os.remove(os.path.join(_herd_dir(pool), _MARKER_NAME))
    except Exception:
        pass
    _journal(pool, "engine_migration_rolled_back", files=str(n), backend="flat")
    sys.stdout.write("herd store: rolled back %d state file(s) → flat (marker dropped)\n" % n)
    return 0


def _emit_blobs(pool, be, dest=None):
    """Write every ``state_blob`` back under ``dest`` (default the pool), byte-identically. Returns the
    count written."""
    dest = dest or pool
    n = 0
    for (rel, content, mode) in be.blobs():
        out = os.path.join(dest, rel)
        _ensure_parent(out)
        try:
            with open(out, "wb") as fh:
                fh.write(content if isinstance(content, (bytes, bytearray)) else bytes(content))
            if mode:
                os.chmod(out, mode)
            n += 1
        except Exception:
            pass
    return n


def _verify_roundtrip(pool, be):
    """Prove files → db → files is byte-identical: re-emit every blob into a scratch tree and compare
    each against the live pool file. Side-effect-free w.r.t. the pool (writes only under a temp dir)."""
    import tempfile
    import filecmp
    tmp = tempfile.mkdtemp(prefix="herd-store-verify-")
    try:
        _emit_blobs(pool, be, dest=tmp)
        for (rel, _content, _mode) in be.blobs():
            a = os.path.join(pool, rel)
            b = os.path.join(tmp, rel)
            if not os.path.isfile(a) or not os.path.isfile(b) or not filecmp.cmp(a, b, shallow=False):
                return False
        return True
    finally:
        import shutil
        shutil.rmtree(tmp, ignore_errors=True)


def _journal(pool, event, **fields):
    """Best-effort append of one event line to the pool's journal (append-only JSONL — the db never
    holds it). Reuses the engine's event encoder when importable; a failure is silently dropped."""
    hd = _herd_dir(pool)
    if not hd:
        return
    path = os.environ.get("JOURNAL_FILE") or os.path.join(hd, "journal.jsonl")
    try:
        from herd.shadow_journal import encode_event
        line = encode_event(event, fields)
    except Exception:
        import json
        rec = {"ts": _now(), "event": event}
        rec.update(fields)
        line = json.dumps(rec, separators=(",", ":"))
    try:
        _ensure_parent(path)
        with open(path, "a", encoding="utf-8") as fh:
            fh.write(line.rstrip("\n") + "\n")
    except Exception:
        pass


def _status(pool):
    be_name = resolve_backend(pool)
    sys.stdout.write("backend: %s\n" % be_name)
    dbp = db_path(pool)
    mk = marker_path(pool)
    sys.stdout.write("pool:    %s\n" % (pool or "(unresolved)"))
    sys.stdout.write("db:      %s%s\n" % (dbp or "(none)", "" if (dbp and os.path.isfile(dbp)) else " (absent)"))
    sys.stdout.write("marker:  %s\n" % ("present" if (mk and os.path.isfile(mk)) else "absent"))
    if dbp and os.path.isfile(dbp):
        try:
            be = _SqliteBackend(dbp)
            for t, c in sorted(be.counts().items()):
                sys.stdout.write("  %-16s %d\n" % (t, c))
            be.close()
        except Exception:
            pass
    return 0


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    action = None
    pool = None
    do_verify = False
    identity = None
    pr = ""
    sha = ""
    i = 0
    while i < len(argv):
        a = argv[i]
        if a in ("--migrate", "--rollback", "--status", "--verify",
                  "--main-health-fix-mark", "--main-health-fix-clear"):
            action = a
            if a in ("--main-health-fix-mark", "--main-health-fix-clear"):
                i += 1
                identity = argv[i] if i < len(argv) else None
        elif a == "--pool":
            i += 1
            pool = argv[i] if i < len(argv) else None
        elif a == "--pr":
            i += 1
            pr = argv[i] if i < len(argv) else ""
        elif a == "--sha":
            i += 1
            sha = argv[i] if i < len(argv) else ""
        elif a in ("--do-verify", "--check"):
            do_verify = True
        elif a in ("-h", "--help"):
            sys.stdout.write(__doc__ or "")
            return 0
        i += 1
    pool = pool or _pool_dir()
    if action == "--migrate":
        return migrate(pool, verify=True)         # migrate ALWAYS proves the round-trip before engaging
    if action == "--rollback":
        return rollback(pool)
    if action == "--main-health-fix-mark":
        # HERD-371: the shared-pool dedup marker the bash main-health autofix leg claims before filing.
        # rc 0 = we won (caller should file); rc 3 = already marked (caller must dedup); rc 2 = no pool.
        if not identity:
            sys.stderr.write("herd store: --main-health-fix-mark requires an identity\n")
            return 2
        st = open_store(pool)
        return 0 if st.mark_main_health_fix(identity, pr, sha) else 3
    if action == "--main-health-fix-clear":
        if identity:
            open_store(pool).clear_main_health_fix(identity)
        return 0
    if action == "--verify":
        if not pool or not os.path.isdir(pool):
            sys.stderr.write("herd store: no pool to verify\n")
            return 2
        # A standalone proof: migrate into a scratch db (no marker, no guard side effect on the pool),
        # confirm the round-trip, and report — the pool is never mutated.
        import tempfile
        import shutil
        tmp = tempfile.mkdtemp(prefix="herd-store-verifydb-")
        try:
            be = _SqliteBackend(os.path.join(tmp, _DB_NAME))
            for rel in discover_state_files(pool):
                full = os.path.join(pool, rel)
                try:
                    with open(full, "rb") as fh:
                        raw = fh.read()
                    be.put_blob(rel, raw, os.stat(full).st_mode & 0o777)
                except Exception:
                    continue
            ok = _verify_roundtrip(pool, be)
            be.close()
            sys.stdout.write("round-trip: %s\n" % ("OK (byte-identical)" if ok else "MISMATCH"))
            return 0 if ok else 4
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
    return _status(pool)


if __name__ == "__main__":
    sys.exit(main())
