"""Durable, process-safe channel leases for local Qicheng integrations.

This module does not perform desktop input. Every input bridge must check its
lease immediately before acting; a lease alone is not an authorization layer.
"""

from __future__ import annotations

import errno
import hashlib
import hmac
import os
import re
import secrets
import sqlite3
import time
from contextlib import contextmanager
from dataclasses import asdict, dataclass
from pathlib import Path

if os.name == "nt":
    import msvcrt
else:
    import fcntl


_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")


class LeaseError(Exception):
    pass


class ChannelBusy(LeaseError):
    pass


class EndpointBusy(LeaseError):
    pass


class WaitTimedOut(LeaseError):
    pass


class WaitCancelled(LeaseError):
    pass


class WaitQueueFull(LeaseError):
    pass


class LockUnavailable(LeaseError):
    pass


class RequestConflict(LeaseError):
    pass


class LeaseGone(LeaseError):
    pass


class InvalidToken(LeaseError):
    pass


class MaintenanceMode(LeaseError):
    pass


@dataclass(frozen=True)
class Lease:
    channel_id: str
    task_id: str
    project_id: str
    project_path: str
    endpoint_id: str
    tool_id: str
    request_id: str
    generation: int
    expires_at: float
    token: str | None = None

    def public(self) -> dict:
        value = asdict(self)
        value.pop("token")
        return value


class LeaseStore:
    """SQLite-backed allocator. Put database and sibling `.key` in private runtime data.

    A request_id is single-use forever, even if its lease expires. Repeating an
    active request returns the same token; changing its binding raises
    RequestConflict. A lost key file is fatal for an existing database.
    """

    MAX_WAIT_SECONDS = 300
    MAX_WAITERS_PER_ENDPOINT = 64
    WAIT_POLL_SECONDS = 0.05
    WAITER_STALE_SECONDS = 5

    def __init__(self, db_path: str | Path, *, clock=time.time):
        self.path = Path(db_path).resolve()
        self.key_path = self.path.with_name(self.path.name + ".key")
        self.lock_dir = self.path.with_name(self.path.name + ".locks")
        self.clock = clock
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.lock_dir.mkdir(mode=0o700, exist_ok=True)
        self._key = self._load_key()
        with self._transaction() as db:
            db.executescript("""
                CREATE TABLE IF NOT EXISTS requests (
                    generation INTEGER PRIMARY KEY AUTOINCREMENT,
                    request_id TEXT NOT NULL UNIQUE,
                    channel_id TEXT NOT NULL,
                    task_id TEXT NOT NULL,
                    project_id TEXT NOT NULL,
                    project_path TEXT NOT NULL,
                    endpoint_id TEXT NOT NULL,
                    tool_id TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS leases (
                    channel_id TEXT PRIMARY KEY,
                    generation INTEGER NOT NULL UNIQUE REFERENCES requests(generation),
                    expires_at REAL NOT NULL
                );
                CREATE TABLE IF NOT EXISTS waiters (
                    generation INTEGER PRIMARY KEY REFERENCES requests(generation),
                    endpoint_id TEXT NOT NULL,
                    deadline REAL NOT NULL
                );
                CREATE INDEX IF NOT EXISTS waiters_endpoint_order
                    ON waiters(endpoint_id, generation);
                CREATE TABLE IF NOT EXISTS waiter_clients (
                    client_id TEXT PRIMARY KEY,
                    generation INTEGER NOT NULL REFERENCES requests(generation),
                    heartbeat REAL NOT NULL
                );
                CREATE INDEX IF NOT EXISTS waiter_clients_generation
                    ON waiter_clients(generation);
                CREATE TABLE IF NOT EXISTS broker_control (
                    id INTEGER PRIMARY KEY CHECK (id=1),
                    maintenance INTEGER NOT NULL CHECK (maintenance IN (0,1))
                );
                INSERT OR IGNORE INTO broker_control(id, maintenance) VALUES(1, 0);
            """)

    @staticmethod
    def _require_open(db: sqlite3.Connection):
        if db.execute("SELECT maintenance FROM broker_control WHERE id=1").fetchone()[0]:
            raise MaintenanceMode("broker is in maintenance")

    def maintenance(self) -> bool:
        with self._transaction() as db:
            return bool(db.execute(
                "SELECT maintenance FROM broker_control WHERE id=1").fetchone()[0])

    def set_maintenance(self, enabled: bool) -> bool:
        """Offline administrator control, serialized with allocation/action admission."""
        if type(enabled) is not bool:
            raise TypeError("enabled must be boolean")
        with self._transaction() as db:
            db.execute("BEGIN IMMEDIATE")
            db.execute("UPDATE broker_control SET maintenance=? WHERE id=1",
                       (int(enabled),))
            if enabled:
                # Queued requests keep their single-use request tombstones.
                db.execute("DELETE FROM waiter_clients")
                db.execute("DELETE FROM waiters")
        return enabled

    def _load_key(self) -> bytes:
        if not self.key_path.exists():
            if self.path.exists():
                raise LeaseError("existing lease database has no key file")
            try:
                fd = os.open(self.key_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            except FileExistsError:
                pass
            else:
                with os.fdopen(fd, "wb") as output:
                    output.write(secrets.token_bytes(32))
                    output.flush()
                    os.fsync(output.fileno())
        for _ in range(20):
            key = self.key_path.read_bytes()
            if len(key) == 32:
                return key
            time.sleep(0.01)
        raise LeaseError("lease key file is incomplete")

    def _connect(self) -> sqlite3.Connection:
        deadline = time.monotonic() + 10
        while True:
            db = sqlite3.connect(self.path, timeout=10, isolation_level=None)
            try:
                db.row_factory = sqlite3.Row
                db.execute("PRAGMA busy_timeout=10000")
                mode = db.execute("PRAGMA journal_mode=WAL").fetchone()[0]
                if mode.lower() != "wal":
                    raise LeaseError("SQLite WAL mode is unavailable")
                db.execute("PRAGMA foreign_keys=ON")
                return db
            except sqlite3.OperationalError as error:
                db.close()
                if "locked" not in str(error).lower() or time.monotonic() >= deadline:
                    raise
                time.sleep(0.05)
            except BaseException:
                db.close()
                raise

    @contextmanager
    def _transaction(self):
        db = self._connect()
        try:
            yield db
            db.commit()
        except BaseException:
            db.rollback()
            raise
        finally:
            db.close()

    @contextmanager
    def _lock(self, kind: str, identifier: str, *, timeout_seconds: float = 10):
        """Cross-process lock; the OS releases it if its owner dies."""
        digest = hashlib.sha256(identifier.encode("utf-8")).hexdigest()
        path = self.lock_dir / f"{kind}-{digest}.lock"
        fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
        try:
            if os.fstat(fd).st_size == 0:
                os.write(fd, b"\0")
            deadline = time.monotonic() + timeout_seconds
            while True:
                try:
                    if os.name == "nt":
                        os.lseek(fd, 0, os.SEEK_SET)
                        msvcrt.locking(fd, msvcrt.LK_NBLCK, 1)
                    else:
                        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except OSError as error:
                    if error.errno not in (errno.EAGAIN, errno.EACCES, errno.EWOULDBLOCK):
                        raise LeaseError(f"failed to lock {kind}") from error
                    if time.monotonic() >= deadline:
                        raise LockUnavailable(f"timed out locking {kind}") from error
                    time.sleep(0.02)
            try:
                yield
            finally:
                if os.name == "nt":
                    os.lseek(fd, 0, os.SEEK_SET)
                    msvcrt.locking(fd, msvcrt.LK_UNLCK, 1)
                else:
                    fcntl.flock(fd, fcntl.LOCK_UN)
        finally:
            os.close(fd)

    @staticmethod
    def _id(value: str, name: str) -> str:
        if not isinstance(value, str) or not _ID.fullmatch(value):
            raise ValueError(f"{name} must be a non-secret identifier")
        return value

    @staticmethod
    def _ttl(value: float) -> float:
        if not isinstance(value, (int, float)) or not 1 <= value <= 86400:
            raise ValueError("ttl_seconds must be between 1 and 86400")
        return float(value)

    @classmethod
    def _wait(cls, value: float) -> float:
        if (type(value) not in (int, float) or not 0 <= value <= cls.MAX_WAIT_SECONDS
                or value != value):
            raise ValueError(f"wait_seconds must be between 0 and {cls.MAX_WAIT_SECONDS}")
        return float(value)

    def _token(self, request_id: str, generation: int) -> str:
        payload = f"{generation}:{request_id}".encode("utf-8")
        return hmac.new(self._key, payload, hashlib.sha256).hexdigest()

    @staticmethod
    def _lease(row: sqlite3.Row, token: str | None = None) -> Lease:
        return Lease(**{key: row[key] for key in (
            "channel_id", "task_id", "project_id", "project_path",
            "endpoint_id", "tool_id", "request_id", "generation", "expires_at"
        )}, token=token)

    @staticmethod
    def _select(db: sqlite3.Connection, where: str, value: object) -> sqlite3.Row | None:
        return db.execute("""
            SELECT r.*, l.expires_at FROM requests r
            JOIN leases l ON l.generation = r.generation
            WHERE """ + where, (value,)).fetchone()

    def _heartbeat_waiter(self, client_id: str):
        # Queue bookkeeping uses SQLite's write lock, not action locks. A live
        # waiter can therefore stay visible while an action holds its channel.
        with self._transaction() as db:
            self._require_open(db)
            db.execute("UPDATE waiter_clients SET heartbeat=? WHERE client_id=?",
                       (self.clock(), client_id))

    def _prune_waiters(self, db: sqlite3.Connection, endpoint_id: str,
                       request_id: str, now: float):
        db.execute("""DELETE FROM waiter_clients WHERE heartbeat<?
            AND generation IN (SELECT generation FROM waiters
                               WHERE endpoint_id=?)""",
                   (now - self.WAITER_STALE_SECONDS, endpoint_id))
        db.execute("""DELETE FROM waiters WHERE endpoint_id=? AND
            (deadline<=? OR NOT EXISTS
                (SELECT 1 FROM waiter_clients c
                 WHERE c.generation=waiters.generation)) AND generation NOT IN
            (SELECT generation FROM requests WHERE request_id=?)""",
                   (endpoint_id, now, request_id))

    def _join_waiter(self, binding: tuple[str, ...], wait: float,
                     client_id: str) -> Lease | None:
        request_id, channel_id, _task_id, _project_id, _project_path, endpoint_id, _tool_id = binding
        with self._transaction() as db:
            db.execute("BEGIN IMMEDIATE")
            self._require_open(db)
            now = self.clock()
            self._prune_waiters(db, endpoint_id, request_id, now)
            previous = db.execute("SELECT * FROM requests WHERE request_id=?",
                                  (request_id,)).fetchone()
            if previous is not None:
                if tuple(previous[key] for key in (
                        "request_id", "channel_id", "task_id", "project_id",
                        "project_path", "endpoint_id", "tool_id")) != binding:
                    raise RequestConflict("request_id already belongs to a different binding")
                active = self._select(db, "r.generation=?", previous["generation"])
                if active and active["expires_at"] > now:
                    return self._lease(active, self._token(request_id, active["generation"]))
                waiter = db.execute("SELECT * FROM waiters WHERE generation=?",
                                    (previous["generation"],)).fetchone()
                if waiter is None:
                    raise LeaseGone("request_id is already terminal")
                if waiter["deadline"] <= now:
                    db.execute("DELETE FROM waiter_clients WHERE generation=?",
                               (previous["generation"],))
                    db.execute("DELETE FROM waiters WHERE generation=?",
                               (previous["generation"],))
                    db.commit()
                    raise WaitTimedOut(request_id)
                generation = previous["generation"]
            else:
                if db.execute("SELECT COUNT(*) FROM waiters WHERE endpoint_id=?",
                              (endpoint_id,)).fetchone()[0] >= self.MAX_WAITERS_PER_ENDPOINT:
                    raise WaitQueueFull(endpoint_id)
                cursor = db.execute("""INSERT INTO requests
                    (request_id,channel_id,task_id,project_id,project_path,endpoint_id,tool_id)
                    VALUES(?,?,?,?,?,?,?)""", binding)
                generation = cursor.lastrowid
                db.execute("""INSERT INTO waiters(generation,endpoint_id,deadline)
                    VALUES(?,?,?)""", (generation, endpoint_id, now + wait))
            db.execute("""INSERT INTO waiter_clients(client_id,generation,heartbeat)
                VALUES(?,?,?)""", (client_id, generation, now))
        return None

    @contextmanager
    def _acquire_locks(self, channel_id: str, endpoint_id: str, wait: float,
                       local_deadline: float, request_id: str, client_id: str | None,
                       cancelled):
        if wait == 0:
            with self._lock("channel", channel_id), self._lock("endpoint", endpoint_id):
                yield
            return
        while True:
            if cancelled is not None and cancelled():
                self._remove_waiter(request_id, channel_id, endpoint_id, client_id)
                raise WaitCancelled(request_id)
            if time.monotonic() >= local_deadline:
                self._remove_waiter(request_id, channel_id, endpoint_id, client_id)
                raise WaitTimedOut(request_id)
            try:
                with self._lock("channel", channel_id, timeout_seconds=0.25), \
                        self._lock("endpoint", endpoint_id, timeout_seconds=0.25):
                    yield
                return
            except LockUnavailable:
                self._heartbeat_waiter(client_id)

    def acquire(self, *, request_id: str, channel_id: str, task_id: str,
                project_id: str, project_path: str, endpoint_id: str,
                tool_id: str, ttl_seconds: float = 60, wait_seconds: float = 0,
                cancelled=None) -> Lease:
        fields = ("request_id", "channel_id", "task_id", "project_id", "endpoint_id", "tool_id")
        values = (request_id, channel_id, task_id, project_id, endpoint_id, tool_id)
        for name, value in zip(fields, values):
            self._id(value, name)
        if not isinstance(project_path, str) or not project_path or "\x00" in project_path:
            raise ValueError("project_path is required")
        # Resolve once at allocation, so later callers can compare a stable path.
        project = Path(project_path).resolve()
        if not project.is_dir():
            raise ValueError("project_path must be an existing directory")
        project_path = str(project)
        ttl = self._ttl(ttl_seconds)
        wait = self._wait(wait_seconds)
        binding = (request_id, channel_id, task_id, project_id, project_path, endpoint_id, tool_id)
        client_id = secrets.token_hex(16) if wait else None
        if wait:
            active = self._join_waiter(binding, wait, client_id)
            if active is not None:
                return active
        # Wall-clock deadline survives broker restart. Monotonic time also
        # bounds a live call if a local wall clock moves backwards.
        local_deadline = time.monotonic() + wait
        while True:
            if cancelled is not None and cancelled():
                self._remove_waiter(request_id, channel_id, endpoint_id, client_id)
                raise WaitCancelled(request_id)
            # Action locks can outlive a waiting call. Short lock attempts
            # refresh the caller heartbeat and respect its own deadline.
            with self._acquire_locks(channel_id, endpoint_id, wait, local_deadline,
                                     request_id, client_id, cancelled):
                with self._transaction() as db:
                    db.execute("BEGIN IMMEDIATE")
                    self._require_open(db)
                    now = self.clock()
                    self._prune_waiters(db, endpoint_id, request_id, now)
                    previous = db.execute("SELECT * FROM requests WHERE request_id=?",
                                          (request_id,)).fetchone()
                    waiter = None
                    if previous:
                        if tuple(previous[key] for key in ("request_id", "channel_id", "task_id", "project_id", "project_path", "endpoint_id", "tool_id")) != binding:
                            raise RequestConflict("request_id already belongs to a different binding")
                        active = self._select(db, "r.generation=?", previous["generation"])
                        if active and active["expires_at"] > now:
                            return self._lease(active, self._token(request_id, active["generation"]))
                        waiter = db.execute("SELECT * FROM waiters WHERE generation=?",
                                            (previous["generation"],)).fetchone()
                        if waiter is None:
                            raise LeaseGone("request_id is already terminal")
                    # Only prune leases protected by these locks. An unrelated
                    # expired lease may still have an action in progress.
                    db.execute("""DELETE FROM leases WHERE expires_at <= ? AND
                        (channel_id=? OR generation IN
                            (SELECT generation FROM requests WHERE endpoint_id=?))""",
                               (now, channel_id, endpoint_id))
                    if waiter is not None:
                        if wait == 0:
                            raise EndpointBusy(endpoint_id)
                        if waiter["deadline"] <= now:
                            db.execute("DELETE FROM waiter_clients WHERE generation=?",
                                       (previous["generation"],))
                            db.execute("DELETE FROM waiters WHERE generation=?",
                                       (previous["generation"],))
                            # Commit the tombstone before reporting timeout;
                            # the transaction context rolls back exceptions.
                            db.commit()
                            raise WaitTimedOut(request_id)
                        if time.monotonic() >= local_deadline:
                            db.execute("DELETE FROM waiter_clients WHERE client_id=?",
                                       (client_id,))
                            db.execute("""DELETE FROM waiters WHERE generation=? AND
                                NOT EXISTS (SELECT 1 FROM waiter_clients c
                                            WHERE c.generation=?)""",
                                       (previous["generation"], previous["generation"]))
                            db.commit()
                            raise WaitTimedOut(request_id)
                        db.execute("""INSERT OR REPLACE INTO waiter_clients
                            (client_id,generation,heartbeat) VALUES(?,?,?)""",
                                   (client_id, previous["generation"], now))
                    head = db.execute("""SELECT generation FROM waiters
                        WHERE endpoint_id=? ORDER BY generation LIMIT 1""",
                                      (endpoint_id,)).fetchone()
                    channel_busy = self._select(db, "l.channel_id=?", channel_id)
                    endpoint_busy = self._select(db, "r.endpoint_id=?", endpoint_id)
                    at_head = head is None or (waiter is not None and
                                                head["generation"] == previous["generation"])
                    if not channel_busy and not endpoint_busy and at_head:
                        if previous is None:
                            cursor = db.execute("""INSERT INTO requests
                                (request_id,channel_id,task_id,project_id,project_path,endpoint_id,tool_id)
                                VALUES(?,?,?,?,?,?,?)""", binding)
                            generation = cursor.lastrowid
                        else:
                            generation = previous["generation"]
                            db.execute("DELETE FROM waiter_clients WHERE generation=?", (generation,))
                            db.execute("DELETE FROM waiters WHERE generation=?", (generation,))
                        expires_at = now + ttl
                        db.execute("INSERT INTO leases(channel_id,generation,expires_at) VALUES(?,?,?)",
                                   (channel_id, generation, expires_at))
                        row = self._select(db, "r.generation=?", generation)
                        return self._lease(row, self._token(request_id, generation))
                    if wait == 0 and waiter is None:
                        if channel_busy:
                            raise ChannelBusy(channel_id)
                        raise EndpointBusy(endpoint_id)
                    if previous is None:
                        if db.execute("SELECT COUNT(*) FROM waiters WHERE endpoint_id=?",
                                      (endpoint_id,)).fetchone()[0] >= self.MAX_WAITERS_PER_ENDPOINT:
                            raise WaitQueueFull(endpoint_id)
                        cursor = db.execute("""INSERT INTO requests
                            (request_id,channel_id,task_id,project_id,project_path,endpoint_id,tool_id)
                            VALUES(?,?,?,?,?,?,?)""", binding)
                        generation = cursor.lastrowid
                        db.execute("""INSERT INTO waiters(generation,endpoint_id,deadline)
                            VALUES(?,?,?)""", (generation, endpoint_id, now + wait))
                        db.execute("""INSERT INTO waiter_clients(client_id,generation,heartbeat)
                            VALUES(?,?,?)""", (client_id, generation, now))
            time.sleep(min(self.WAIT_POLL_SECONDS,
                           max(0, local_deadline - time.monotonic())))

    def _remove_waiter(self, request_id: str, channel_id: str, endpoint_id: str,
                       client_id: str | None):
        with self._transaction() as db:
            db.execute("BEGIN IMMEDIATE")
            db.execute("DELETE FROM waiter_clients WHERE client_id=?", (client_id,))
            db.execute("""DELETE FROM waiters WHERE generation IN
                (SELECT generation FROM requests WHERE request_id=? AND channel_id=?
                 AND endpoint_id=?) AND NOT EXISTS
                (SELECT 1 FROM waiter_clients c
                 WHERE c.generation=waiters.generation)""",
                       (request_id, channel_id, endpoint_id))

    def _authenticated(self, db: sqlite3.Connection, channel_id: str, token: str) -> sqlite3.Row:
        row = self._select(db, "l.channel_id=?", channel_id)
        if not row or row["expires_at"] <= self.clock():
            raise LeaseGone(channel_id)
        expected = self._token(row["request_id"], row["generation"])
        if not isinstance(token, str) or not hmac.compare_digest(token, expected):
            raise InvalidToken(channel_id)
        return row

    def assert_owner(self, channel_id: str, token: str) -> Lease:
        """Return a snapshot only. Do not authorize an action with this method."""
        self._id(channel_id, "channel_id")
        with self._transaction() as db:
            return self._lease(self._authenticated(db, channel_id, token))

    def execute_owned(self, channel_id: str, token: str, action, *, allow_maintenance=False):
        """Run a bounded action under channel and endpoint OS locks.

        The database is closed before the callback, so independent endpoints
        can run concurrently. The callback must not recurse into this store.
        """
        self._id(channel_id, "channel_id")
        if not callable(action):
            raise TypeError("action must be callable")
        with self._lock("channel", channel_id):
            with self._transaction() as db:
                endpoint_id = self._authenticated(db, channel_id, token)["endpoint_id"]
            with self._lock("endpoint", endpoint_id):
                with self._transaction() as db:
                    db.execute("BEGIN IMMEDIATE")
                    if not allow_maintenance:
                        self._require_open(db)
                    row = self._authenticated(db, channel_id, token)
                    active = self._lease(row)
                return action(active)

    def renew(self, channel_id: str, token: str, ttl_seconds: float = 60) -> Lease:
        self._id(channel_id, "channel_id")
        ttl = self._ttl(ttl_seconds)
        with self._lock("channel", channel_id):
            with self._transaction() as db:
                db.execute("BEGIN IMMEDIATE")
                row = self._authenticated(db, channel_id, token)
                expires_at = self.clock() + ttl
                db.execute("UPDATE leases SET expires_at=? WHERE generation=?", (expires_at, row["generation"]))
                return self._lease(self._select(db, "r.generation=?", row["generation"]), token)

    def release(self, channel_id: str, token: str) -> Lease:
        self._id(channel_id, "channel_id")
        with self._lock("channel", channel_id):
            with self._transaction() as db:
                db.execute("BEGIN IMMEDIATE")
                row = self._authenticated(db, channel_id, token)
                db.execute("DELETE FROM leases WHERE generation=?", (row["generation"],))
                return self._lease(row)

    def current(self, channel_id: str) -> Lease | None:
        self._id(channel_id, "channel_id")
        with self._transaction() as db:
            row = self._select(db, "l.channel_id=?", channel_id)
            return self._lease(row) if row and row["expires_at"] > self.clock() else None
