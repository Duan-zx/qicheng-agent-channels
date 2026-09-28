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


class RequestConflict(LeaseError):
    pass


class LeaseGone(LeaseError):
    pass


class InvalidToken(LeaseError):
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
            """)

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
    def _lock(self, kind: str, identifier: str):
        """Cross-process lock; the OS releases it if its owner dies."""
        digest = hashlib.sha256(identifier.encode("utf-8")).hexdigest()
        path = self.lock_dir / f"{kind}-{digest}.lock"
        fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
        try:
            if os.fstat(fd).st_size == 0:
                os.write(fd, b"\0")
            deadline = time.monotonic() + 10
            while True:
                try:
                    if os.name == "nt":
                        os.lseek(fd, 0, os.SEEK_SET)
                        msvcrt.locking(fd, msvcrt.LK_NBLCK, 1)
                    else:
                        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except OSError as error:
                    if error.errno not in (errno.EAGAIN, errno.EACCES, errno.EWOULDBLOCK) or time.monotonic() >= deadline:
                        raise LeaseError(f"timed out or failed to lock {kind}") from error
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

    def acquire(self, *, request_id: str, channel_id: str, task_id: str,
                project_id: str, project_path: str, endpoint_id: str,
                tool_id: str, ttl_seconds: float = 60) -> Lease:
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
        binding = (request_id, channel_id, task_id, project_id, project_path, endpoint_id, tool_id)
        # Always take channel before endpoint. The same order is used by
        # execute_owned, preventing deadlocks between transitions and actions.
        with self._lock("channel", channel_id), self._lock("endpoint", endpoint_id):
            with self._transaction() as db:
                db.execute("BEGIN IMMEDIATE")
                now = self.clock()
                previous = db.execute("SELECT * FROM requests WHERE request_id=?", (request_id,)).fetchone()
                if previous:
                    if tuple(previous[key] for key in ("request_id", "channel_id", "task_id", "project_id", "project_path", "endpoint_id", "tool_id")) != binding:
                        raise RequestConflict("request_id already belongs to a different binding")
                    active = self._select(db, "r.generation=?", previous["generation"])
                    if not active or active["expires_at"] <= now:
                        raise LeaseGone("request_id is already terminal")
                    return self._lease(active, self._token(request_id, active["generation"]))
                # Only prune rows protected by these locks. Deleting every
                # expired row could evict an unrelated action still running.
                db.execute("""DELETE FROM leases WHERE expires_at <= ? AND
                    (channel_id=? OR generation IN
                        (SELECT generation FROM requests WHERE endpoint_id=?))""",
                           (now, channel_id, endpoint_id))
                if self._select(db, "l.channel_id=?", channel_id):
                    raise ChannelBusy(channel_id)
                if self._select(db, "r.endpoint_id=?", endpoint_id):
                    raise EndpointBusy(endpoint_id)
                cursor = db.execute("""
                    INSERT INTO requests(request_id,channel_id,task_id,project_id,project_path,endpoint_id,tool_id)
                    VALUES(?,?,?,?,?,?,?)
                """, binding)
                generation = cursor.lastrowid
                expires_at = now + ttl
                db.execute("INSERT INTO leases(channel_id,generation,expires_at) VALUES(?,?,?)",
                           (channel_id, generation, expires_at))
                row = self._select(db, "r.generation=?", generation)
                return self._lease(row, self._token(request_id, generation))

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

    def execute_owned(self, channel_id: str, token: str, action):
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
