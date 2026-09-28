"""Loopback-only HTTP broker for trusted local Qicheng clients.

Guest input is available only for explicitly bound channels.
Other MCP and tool paths remain independent of this broker.
"""

from __future__ import annotations

import argparse
import hashlib
import hmac
import json
import os
import re
import secrets
import select
import socket
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

from bounded_action import run_action
from lease import (ChannelBusy, EndpointBusy, InvalidToken, LeaseGone,
                   LeaseStore, RequestConflict, WaitCancelled, WaitQueueFull,
                   WaitTimedOut)

_GUEST_TTL_SECONDS = 30
_GUEST_OWNER = re.compile(r"[A-Za-z0-9._-]{1,64}\Z")
_ACTION_ID = re.compile(r"[A-Za-z0-9._-]{1,64}\Z")
_INPUT_FIELDS = {"click": {"x", "y", "button"},
                 "move": {"x", "y"}, "key": {"key"}, "type": {"text"}}
_KEYS = frozenset(("Return", "BackSpace", "Tab", "Escape", "Delete", "Left",
                   "Right", "Up", "Down", "Home", "End", "Page_Up",
                   "Page_Down", "space", "ctrl+a", "ctrl+c", "ctrl+v",
                   "ctrl+x", "ctrl+z", "ctrl+f", "ctrl+l", "Enter", "ENTER"))


def _windows_host():
    try:
        from guest_bridge import windows_host
    except ImportError:
        raise RuntimeError("Windows guest source adapter is unavailable") from None
    return windows_host()


def _input_fields(payload: dict) -> tuple[str, dict]:
    action = payload.get("action")
    allowed = _INPUT_FIELDS.get(action) if isinstance(action, str) else None
    if allowed is None or set(payload) - {"channel_id", "token", "action", "action_id"} - allowed:
        raise ValueError("invalid input action or fields")
    fields = {key: value for key, value in payload.items()
              if key not in {"channel_id", "token", "action", "action_id"}}
    if action in {"click", "move"}:
        if (set(fields) - ({"x", "y", "button"} if action == "click" else {"x", "y"})
                or not {"x", "y"} <= set(fields)
                or any(type(fields[name]) is not int or not 0 <= fields[name] <= 16383
                       for name in ("x", "y"))
                or ("button" in fields and (type(fields["button"]) is not int
                                            or fields["button"] not in {1, 2, 3}))):
            raise ValueError("invalid input coordinates or button")
    elif action == "key":
        if set(fields) != {"key"} or fields["key"] not in _KEYS:
            raise ValueError("invalid input key")
    elif action == "type":
        value = fields.get("text")
        if (set(fields) != {"text"} or not isinstance(value, str)
                or not value or len(value) > 2000 or "\x00" in value):
            raise ValueError("invalid input text")
    return action, fields


@dataclass(frozen=True)
class Channel:
    channel_id: str
    endpoint_id: str
    tool_id: str
    project_id: str
    project_path: str
    actions: dict
    exclusive_ports: tuple[int, ...]
    guest: dict | None
    lite: dict | None
    workspace: dict | None


class Broker:
    def __init__(self, *, config_path: str | Path, credential_path: str | Path,
                 db_path: str | Path, clock=None, guest_client_factory=None,
                 lite_client_factory=None):
        config = json.loads(Path(config_path).read_text(encoding="utf-8"))
        if not isinstance(config, dict) or not isinstance(config.get("channels"), list):
            raise ValueError("config requires a channels list")
        self.channels = {}
        for entry in config["channels"]:
            required = {"channel_id", "endpoint_id", "tool_id", "project_id", "project_path"}
            if not isinstance(entry, dict) or not required <= set(entry) or set(entry) - required - {"actions", "exclusive_ports", "guest", "lite", "workspace"}:
                raise ValueError("each channel needs binding fields and optional actions")
            for key in ("channel_id", "endpoint_id", "tool_id", "project_id"):
                LeaseStore._id(entry[key], key)
            project_path = Path(entry["project_path"])
            if not project_path.is_absolute():
                raise ValueError("configured project_path must be absolute")
            project_path = project_path.resolve()
            if not project_path.is_dir():
                raise ValueError("configured project_path must be an existing directory")
            actions = entry.get("actions", {})
            ports = entry.get("exclusive_ports", [])
            guest = entry.get("guest")
            lite = entry.get("lite")
            workspace = entry.get("workspace")
            if sum(item is not None for item in (guest, lite, workspace)) > 1:
                raise ValueError("guest, lite and workspace are mutually exclusive")
            if workspace is not None:
                if guest is not None:
                    raise ValueError("guest and workspace cannot share a channel")
                if not isinstance(workspace, dict) or set(workspace) != {
                        "worktree_root", "build_root", "ref"}:
                    raise ValueError("workspace requires fixed worktree_root, build_root and ref")
                # Import only for opted-in channels so existing broker packages
                # remain usable without the workspace preparer.
                from attempt_workspace import _REF, _plain_path, _separate
                roots = [_plain_path(workspace[name], name)
                         for name in ("worktree_root", "build_root")]
                if not all(root.is_dir() for root in roots):
                    raise ValueError("workspace roots must already exist")
                if not (_separate(project_path, roots[0]) and
                        _separate(project_path, roots[1]) and
                        _separate(*roots)):
                    raise ValueError("workspace source and roots must not overlap")
                if not isinstance(workspace["ref"], str) or not _REF.fullmatch(workspace["ref"]):
                    raise ValueError("invalid workspace ref")
                workspace = {"worktree_root": str(roots[0]),
                             "build_root": str(roots[1]), "ref": workspace["ref"]}
            if guest is not None:
                if not isinstance(guest, dict) or set(guest) != {
                        "host_config_path", "project", "broker_token_file"}:
                    raise ValueError("guest requires fixed host config, project and broker token file")
                for name in ("host_config_path", "broker_token_file"):
                    if not isinstance(guest[name], str) or not Path(guest[name]).is_absolute():
                        raise ValueError("guest paths must be absolute")
                host_config = Path(guest["host_config_path"]).resolve()
                broker_token = Path(guest["broker_token_file"]).resolve()
                if str(broker_token).casefold() == str(Path(credential_path).resolve()).casefold():
                    raise ValueError("guest broker token must differ from local bearer credential")
                project = guest["project"]
                if not isinstance(project, str):
                    raise ValueError("guest project must be configured")
                read_config, _ = _windows_host()
                bindings = read_config(host_config)
                if project not in bindings:
                    raise ValueError("guest project is absent from host config")
                binding = bindings[project]
                if str(Path(binding["token_file"]).resolve()).casefold() == str(broker_token).casefold():
                    raise ValueError("guest broker and channel token files must differ")
                guest = {"binding": binding, "broker_token_file": broker_token,
                         "host_config_path": host_config, "project": project}
            if lite is not None:
                if not isinstance(lite, dict) or set(lite) != {
                        "port", "channel_number", "broker_token_file", "channel_token_file"}:
                    raise ValueError("lite requires fixed port, channel number and token files")
                number = lite["channel_number"]
                port = lite["port"]
                if type(number) is not int or number not in (1, 2) or type(port) is not int or port != 18760 + number:
                    raise ValueError("lite port must match channel number")
                paths = []
                for name in ("broker_token_file", "channel_token_file"):
                    value = lite[name]
                    if not isinstance(value, str) or not Path(value).is_absolute():
                        raise ValueError("lite token paths must be absolute")
                    paths.append(Path(value).resolve())
                paths.append(Path(credential_path).resolve())
                if len({str(path).casefold() for path in paths}) != len(paths):
                    raise ValueError("lite token files must differ")
                lite = {**lite, "broker_token_file": paths[0],
                        "channel_token_file": paths[1]}
            if (not isinstance(ports, list) or
                    any(type(port) is not int or not 1 <= port <= 65535 for port in ports) or
                    len(set(ports)) != len(ports)):
                raise ValueError("exclusive_ports must be distinct TCP port numbers")
            if not isinstance(actions, dict):
                raise ValueError("actions must be an object")
            for name, spec in actions.items():
                LeaseStore._id(name, "action name")
                if (not isinstance(spec, dict) or set(spec) != {"argv", "timeout_seconds"}
                        or not isinstance(spec["argv"], list) or not spec["argv"]
                        or any(not isinstance(part, str) or not part or "\x00" in part
                               for part in spec["argv"])
                        or not isinstance(spec["timeout_seconds"], (int, float))
                        or not 0 < spec["timeout_seconds"] <= 8):
                    raise ValueError("action requires fixed argv and timeout_seconds <= 8")
                if not Path(spec["argv"][0]).is_absolute():
                    raise ValueError("action executable must be an absolute path")
                if not Path(spec["argv"][0]).is_file():
                    raise ValueError("action executable does not exist")
                if any("{" in part or "}" in part for part in spec["argv"]):
                    raise ValueError("action argv must be literal; use absolute project path")
                for index, part in enumerate(spec["argv"]):
                    if part in ("--port", "--auto-port"):
                        if index + 1 >= len(spec["argv"]) or not spec["argv"][index + 1].isdigit():
                            raise ValueError("CLI port flag requires a numeric value")
                        if int(spec["argv"][index + 1]) not in ports:
                            raise ValueError("CLI port must be an exclusive_port")
            channel = Channel(**{**entry, "project_path": str(project_path),
                                 "actions": actions, "exclusive_ports": tuple(ports),
                                 "guest": guest, "lite": lite, "workspace": workspace})
            if channel.channel_id in self.channels:
                raise ValueError("duplicate channel_id")
            for existing in self.channels.values():
                existing_root = Path(existing.project_path)
                shared_isolated_source = (project_path == existing_root
                                          and workspace is not None
                                          and existing.workspace is not None)
                if (not shared_isolated_source and
                        (project_path == existing_root or
                         project_path in existing_root.parents or
                         existing_root in project_path.parents)):
                    raise ValueError("channel project roots must not overlap")
                if set(ports) & set(existing.exclusive_ports) and channel.endpoint_id != existing.endpoint_id:
                    raise ValueError("shared TCP port requires the same endpoint_id")
                if (guest is not None and existing.guest is not None
                        and channel.endpoint_id != existing.endpoint_id
                        and any(guest["binding"][name] == existing.guest["binding"][name]
                                for name in ("vm_id", "bios_uuid", "token_file"))):
                    raise ValueError("shared guest requires the same endpoint_id")
                if lite is not None and existing.lite is not None:
                    if lite["port"] == existing.lite["port"] or lite["channel_number"] == existing.lite["channel_number"]:
                        raise ValueError("lite channels must use distinct ports")
                    if channel.endpoint_id == existing.endpoint_id:
                        raise ValueError("distinct lite channels need distinct endpoints")
            self.channels[channel.channel_id] = channel
        for channel in self.channels.values():
            if channel.workspace is not None:
                for other in self.channels.values():
                    source = Path(other.project_path)
                    for name in ("worktree_root", "build_root"):
                        root = Path(channel.workspace[name])
                        if source == root or source in root.parents or root in source.parents:
                            raise ValueError("workspace root overlaps a channel project root")
                    if other.workspace is not None:
                        for left in ("worktree_root", "build_root"):
                            for right in ("worktree_root", "build_root"):
                                first = Path(channel.workspace[left])
                                second = Path(other.workspace[right])
                                if first == second and left == right:
                                    continue  # A shared root still has distinct hashed IDs.
                                if first == second or first in second.parents or second in first.parents:
                                    raise ValueError("workspace roots conflict across channels")
        if not self.channels:
            raise ValueError("at least one channel is required")
        self.default_ttl = LeaseStore._ttl(config.get("default_ttl_seconds", 60))
        self.max_ttl = LeaseStore._ttl(config.get("max_ttl_seconds", 300))
        if self.default_ttl > self.max_ttl:
            raise ValueError("default_ttl_seconds exceeds max_ttl_seconds")
        credential = Path(credential_path).read_text(encoding="ascii").strip()
        if len(credential) != 64 or any(char not in "0123456789abcdef" for char in credential):
            raise ValueError("credential must be a 32-byte lowercase hex token")
        for channel in self.channels.values():
            if channel.guest is not None:
                try:
                    guest_token = channel.guest["broker_token_file"].read_text(encoding="ascii").strip()
                except Exception:
                    raise ValueError("guest broker credential is unavailable") from None
                if hmac.compare_digest(credential, guest_token):
                    raise ValueError("guest broker credential must differ from local bearer credential")
        self.credential = credential
        self.guest_client_factory = (
            guest_client_factory or _windows_host()[1]
            if any(channel.guest is not None for channel in self.channels.values()) else None)
        if any(channel.lite is not None for channel in self.channels.values()):
            from lite_client import LiteClient
            self.lite_client_factory = lite_client_factory or LiteClient
        else:
            self.lite_client_factory = None
        self.store = LeaseStore(db_path, **({"clock": clock} if clock is not None else {}))
        for channel in self.channels.values():
            if channel.lite is not None:
                self._lite_fingerprint(channel)
        self._reconcile_guest_bindings()
        self._init_action_dirty()
        self._init_runs()

    def _digest(self, value: object) -> str:
        encoded = json.dumps(value, ensure_ascii=True, sort_keys=True,
                             separators=(",", ":")).encode("utf-8")
        return hmac.new(self.store._key, encoded, hashlib.sha256).hexdigest()

    def _guest_fingerprint(self, channel: Channel) -> str:
        guest = channel.guest
        try:
            channel_token = Path(guest["binding"]["token_file"]).read_text(
                encoding="ascii").strip()
            broker_token = guest["broker_token_file"].read_text(encoding="ascii").strip()
        except Exception:
            raise RuntimeError("guest binding credentials are unavailable") from None
        for token in (channel_token, broker_token):
            if len(token) != 64 or any(char not in "0123456789abcdef" for char in token):
                raise RuntimeError("guest binding credentials are invalid")
        if hmac.compare_digest(channel_token, broker_token):
            raise RuntimeError("guest channel and broker credentials must differ")
        return self._digest({
            "channel_id": channel.channel_id, "endpoint_id": channel.endpoint_id,
            "tool_id": channel.tool_id, "project_id": channel.project_id,
            "project_path": channel.project_path,
            "host_config_path": str(guest["host_config_path"]),
            "guest_project": guest["project"],
            "vm_id": guest["binding"]["vm_id"],
            "bios_uuid": guest["binding"]["bios_uuid"],
            "channel_token_file": str(guest["binding"]["token_file"]),
            "channel_token": channel_token,
            "broker_token_file": str(guest["broker_token_file"]),
            "broker_token": broker_token})

    def _lite_fingerprint(self, channel: Channel) -> str:
        lite = channel.lite
        tokens = []
        try:
            for name in ("broker_token_file", "channel_token_file"):
                tokens.append(lite[name].read_text(encoding="ascii").strip())
        except Exception:
            raise RuntimeError("lite binding credentials are unavailable") from None
        if any(len(token) != 64 or any(char not in "0123456789abcdef" for char in token)
               for token in tokens):
            raise RuntimeError("lite binding credentials are invalid")
        if len(set(tokens + [self.credential])) != 3:
            raise RuntimeError("lite credentials must differ")
        return self._digest({
            "channel_id": channel.channel_id, "endpoint_id": channel.endpoint_id,
            "tool_id": channel.tool_id, "project_id": channel.project_id,
            "project_path": channel.project_path, "port": lite["port"],
            "channel_number": lite["channel_number"],
            "broker_token_file": str(lite["broker_token_file"]),
            "channel_token_file": str(lite["channel_token_file"]),
            "broker_token": tokens[0], "channel_token": tokens[1]})

    def _input_fingerprint(self, channel: Channel) -> str:
        if channel.guest is not None:
            return self._guest_fingerprint(channel)
        return self._lite_fingerprint(channel)

    def _reconcile_guest_bindings(self):
        """Pin guest identity in the lease DB; changing it needs an explicit migration."""
        expected = {channel.channel_id: self._input_fingerprint(channel)
                    for channel in self.channels.values()
                    if channel.guest is not None or channel.lite is not None}
        with self.store._transaction() as db:
            db.execute("""CREATE TABLE IF NOT EXISTS guest_bindings (
                channel_id TEXT PRIMARY KEY, fingerprint TEXT NOT NULL)""")
            db.execute("""CREATE TABLE IF NOT EXISTS guest_input_attempts (
                channel_id TEXT NOT NULL, request_id TEXT NOT NULL,
                action_id TEXT NOT NULL, fingerprint TEXT NOT NULL,
                status TEXT NOT NULL CHECK(status IN ('uncertain', 'success')),
                acked INTEGER NOT NULL DEFAULT 0 CHECK(acked IN (0, 1)),
                PRIMARY KEY(channel_id, request_id, action_id))""")
            dirty_exists = db.execute("""SELECT 1 FROM sqlite_master
                WHERE type='table' AND name='guest_dirty'""").fetchone() is not None
            attempt_columns = {row["name"] for row in
                               db.execute("PRAGMA table_info(guest_input_attempts)")}
            if not dirty_exists:
                # An earlier broker could have sent input. Its outcome cannot be
                # reconstructed from a lease that may already have expired.
                if db.execute("SELECT 1 FROM guest_input_attempts LIMIT 1").fetchone():
                    raise RuntimeError("legacy guest attempts require offline reconciliation")
                db.execute("""CREATE TABLE guest_dirty (
                    endpoint_id TEXT PRIMARY KEY, channel_id TEXT NOT NULL,
                    request_id TEXT NOT NULL)""")
            if "acked" not in attempt_columns:
                if db.execute("SELECT 1 FROM guest_input_attempts LIMIT 1").fetchone():
                    raise RuntimeError("legacy guest attempts require offline reconciliation")
                db.execute("""ALTER TABLE guest_input_attempts ADD COLUMN
                    acked INTEGER NOT NULL DEFAULT 0 CHECK(acked IN (0, 1))""")
            if not {"channel_id", "request_id", "action_id", "fingerprint",
                    "status", "acked"} <= {row["name"] for row in
                        db.execute("PRAGMA table_info(guest_input_attempts)")}:
                raise RuntimeError("guest attempt schema is unsupported")
            if {row["name"] for row in db.execute("PRAGMA table_info(guest_dirty)")} != {
                    "endpoint_id", "channel_id", "request_id"}:
                raise RuntimeError("guest dirty schema is unsupported")
            db.execute("BEGIN IMMEDIATE")
            existing = {row["channel_id"]: row["fingerprint"] for row in
                        db.execute("SELECT channel_id, fingerprint FROM guest_bindings")}
            if set(existing) - set(expected):
                raise RuntimeError("registered guest binding was removed")
            for channel_id, fingerprint in expected.items():
                old = existing.get(channel_id)
                if old is not None and not hmac.compare_digest(old, fingerprint):
                    raise RuntimeError("registered guest binding changed")
                if old is None:
                    active = db.execute(
                        "SELECT 1 FROM leases WHERE channel_id=? AND expires_at>?",
                        (channel_id, self.store.clock())).fetchone()
                    if active is not None:
                        raise RuntimeError("active lease predates guest binding")
                    db.execute("INSERT INTO guest_bindings VALUES (?, ?)",
                               (channel_id, fingerprint))

    def _assert_guest_binding(self, channel: Channel):
        fingerprint = self._input_fingerprint(channel)
        with self.store._transaction() as db:
            row = db.execute("SELECT fingerprint FROM guest_bindings WHERE channel_id=?",
                             (channel.channel_id,)).fetchone()
        if row is None or not hmac.compare_digest(row["fingerprint"], fingerprint):
            raise RuntimeError("registered guest binding changed")

    def _action_binding_fingerprint(self, channel: Channel) -> str:
        return self._digest({"channel_id": channel.channel_id,
                             "endpoint_id": channel.endpoint_id,
                             "tool_id": channel.tool_id,
                             "project_id": channel.project_id,
                             "project_path": channel.project_path,
                             "exclusive_ports": channel.exclusive_ports,
                             "workspace": channel.workspace,
                             "actions": channel.actions})

    def _init_action_dirty(self):
        with self.store._transaction() as db:
            db.execute("""CREATE TABLE IF NOT EXISTS action_dirty (
                endpoint_id TEXT PRIMARY KEY, channel_id TEXT NOT NULL,
                request_id TEXT NOT NULL, fingerprint TEXT NOT NULL)""")
            columns = {row["name"] for row in db.execute("PRAGMA table_info(action_dirty)")}
            if columns != {"endpoint_id", "channel_id", "request_id", "fingerprint"}:
                raise RuntimeError("action dirty schema is unsupported")
            for row in db.execute("SELECT * FROM action_dirty"):
                channel = self.channels.get(row["channel_id"])
                if (channel is None or channel.endpoint_id != row["endpoint_id"] or
                        not hmac.compare_digest(
                            row["fingerprint"], self._action_binding_fingerprint(channel))):
                    raise RuntimeError("dirty action binding changed; reconcile offline")

    def _action_dirty(self, endpoint_id: str) -> bool:
        with self.store._transaction() as db:
            return db.execute("SELECT 1 FROM action_dirty WHERE endpoint_id=?",
                              (endpoint_id,)).fetchone() is not None

    def _action_dirty_state(self, endpoint_id: str) -> str:
        """Read the dirty fence and its lease in one SQLite snapshot."""
        with self.store._transaction() as db:
            row = db.execute("""SELECT l.expires_at FROM action_dirty d
                LEFT JOIN requests r ON r.channel_id=d.channel_id AND r.request_id=d.request_id
                LEFT JOIN leases l ON l.generation=r.generation
                WHERE d.endpoint_id=?""", (endpoint_id,)).fetchone()
            if row is None:
                return "clean"
            return "live" if row["expires_at"] is not None and row["expires_at"] > self.store.clock() else "stale"

    def _mark_action_dirty(self, channel: Channel, request_id: str):
        with self.store._transaction() as db:
            db.execute("BEGIN IMMEDIATE")
            inserted = db.execute("""INSERT OR IGNORE INTO action_dirty
                (endpoint_id, channel_id, request_id, fingerprint)
                VALUES (?, ?, ?, ?)""", (channel.endpoint_id, channel.channel_id,
                request_id, self._action_binding_fingerprint(channel)))
            return inserted.rowcount == 1

    def _clear_action_dirty(self, channel: Channel, request_id: str):
        with self.store._transaction() as db:
            db.execute("BEGIN IMMEDIATE")
            cleared = db.execute("""DELETE FROM action_dirty WHERE endpoint_id=?
                AND channel_id=? AND request_id=? AND fingerprint=?""",
                (channel.endpoint_id, channel.channel_id, request_id,
                 self._action_binding_fingerprint(channel)))
            if cleared.rowcount != 1:
                raise RuntimeError("action dirty binding changed; reconcile offline")

    def _init_runs(self):
        with self.store._transaction() as db:
            db.execute("""CREATE TABLE IF NOT EXISTS atomic_runs (
                request_id TEXT PRIMARY KEY, fingerprint TEXT NOT NULL,
                owner TEXT NOT NULL, status TEXT NOT NULL,
                response TEXT)""")
            columns = {row["name"] for row in db.execute("PRAGMA table_info(atomic_runs)")}
            if columns != {"request_id", "fingerprint", "owner", "status", "response"}:
                raise RuntimeError("atomic run schema is unsupported")
        self._run_owner = secrets.token_hex(16)

    def _claim_run(self, request_id, task_id, channel, action_name):
        fingerprint = self._digest({"request_id": request_id, "task_id": task_id,
                                    "binding": self._action_binding_fingerprint(channel),
                                    "action": action_name})
        with self.store._transaction() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT * FROM atomic_runs WHERE request_id=?",
                             (request_id,)).fetchone()
            if row is not None:
                if not hmac.compare_digest(row["fingerprint"], fingerprint):
                    raise RequestConflict("atomic run binding or action changed")
                if row["status"] == "complete":
                    return json.loads(row["response"])
                if row["owner"] != self._run_owner:
                    return {"ok": False, "error": "result_unknown", "request_id": request_id}
                return {"ok": False, "error": "run_in_progress" if row["status"] == "running"
                        else "result_unknown", "request_id": request_id}
            # Reserve the public ID in the legacy request namespace. A regular
            # acquire cannot expose the private lease token for this run.
            if db.execute("SELECT 1 FROM requests WHERE request_id=?", (request_id,)).fetchone():
                raise RequestConflict("request_id already belongs to a lease")
            db.execute("""INSERT INTO requests
                (request_id,channel_id,task_id,project_id,project_path,endpoint_id,tool_id)
                VALUES(?,?,?,?,?,?,?)""", (request_id, channel.channel_id, task_id,
                channel.project_id, channel.project_path, channel.endpoint_id, channel.tool_id))
            db.execute("INSERT INTO atomic_runs VALUES (?, ?, ?, 'running', NULL)",
                       (request_id, fingerprint, self._run_owner))
        return None

    def _finish_run(self, request_id, response):
        with self.store._transaction() as db:
            db.execute("BEGIN IMMEDIATE")
            changed = db.execute("""UPDATE atomic_runs SET status='complete', response=?
                WHERE request_id=? AND owner=? AND status='running'""",
                (json.dumps(response, ensure_ascii=True), request_id,
                 self._run_owner)).rowcount
            if changed != 1:
                raise RuntimeError("atomic run ownership changed")

    def _attempt_fingerprint(self, channel: Channel, active, action, fields):
        details = {
            "channel_id": channel.channel_id, "request_id": active.request_id,
            "generation": active.generation, "endpoint_id": active.endpoint_id,
            "project_id": active.project_id, "project_path": active.project_path,
            "tool_id": active.tool_id, "action": action, "fields": fields}
        if channel.guest is not None:
            details["guest"] = self._guest_fingerprint(channel)
        else:
            details["lite"] = self._lite_fingerprint(channel)
        return self._digest(details)

    def _begin_input_attempt(self, channel_id, endpoint_id, request_id, action_id,
                             fingerprint, *, record=True):
        with self.store._transaction() as db:
            db.execute("BEGIN IMMEDIATE")
            dirty = db.execute("SELECT channel_id, request_id FROM guest_dirty WHERE endpoint_id=?",
                               (endpoint_id,)).fetchone()
            if dirty is not None and (dirty["channel_id"], dirty["request_id"]) != (channel_id, request_id):
                return "dirty"
            row = db.execute("""SELECT fingerprint, status FROM guest_input_attempts
                WHERE channel_id=? AND request_id=? AND action_id=?""",
                (channel_id, request_id, action_id)).fetchone()
            if row is not None:
                if not hmac.compare_digest(row["fingerprint"], fingerprint):
                    return "conflict"
                return row["status"]
            if db.execute("""SELECT 1 FROM guest_input_attempts
                WHERE channel_id=? AND request_id=? AND (status!='success' OR acked=0)
                LIMIT 1""", (channel_id, request_id)).fetchone():
                return "pending_ack"
            if not record:
                return "ready"
            if dirty is None:
                db.execute("INSERT INTO guest_dirty VALUES (?, ?, ?)",
                           (endpoint_id, channel_id, request_id))
            db.execute("""INSERT INTO guest_input_attempts
                (channel_id, request_id, action_id, fingerprint, status)
                VALUES (?, ?, ?, ?, 'uncertain')""",
                (channel_id, request_id, action_id, fingerprint))
            return "new"

    def _complete_input_attempt(self, channel_id, request_id, action_id):
        with self.store._transaction() as db:
            db.execute("BEGIN IMMEDIATE")
            changed = db.execute("""UPDATE guest_input_attempts SET status='success'
                WHERE channel_id=? AND request_id=? AND action_id=? AND status='uncertain'""",
                (channel_id, request_id, action_id)).rowcount
            if changed != 1:
                raise RuntimeError("input attempt could not be completed")

    def _dirty_owner(self, endpoint_id):
        with self.store._transaction() as db:
            row = db.execute("SELECT channel_id, request_id FROM guest_dirty WHERE endpoint_id=?",
                             (endpoint_id,)).fetchone()
            return (row["channel_id"], row["request_id"]) if row else None

    @staticmethod
    def _guest_identity(channel: Channel) -> dict:
        binding = channel.guest["binding"]
        return {"vm_id": binding["vm_id"], "bios_uuid": binding["bios_uuid"],
                "project": channel.guest["project"]}

    @staticmethod
    def _lite_identity(channel: Channel) -> dict:
        return {"channel_id": channel.channel_id,
                "channel_number": channel.lite["channel_number"],
                "port": channel.lite["port"]}

    @staticmethod
    def _binding_error(channel: Channel) -> str:
        return "lite_binding_unavailable" if channel.lite is not None else "guest_binding_unavailable"

    def authorize(self, authorization: str | None) -> bool:
        if not authorization or not authorization.startswith("Bearer "):
            return False
        return hmac.compare_digest(authorization[7:], self.credential)

    def _channel(self, channel_id: object) -> Channel:
        if not isinstance(channel_id, str) or channel_id not in self.channels:
            raise ValueError("channel_id is not registered")
        return self.channels[channel_id]

    def acquire(self, payload: dict, *, disconnected=None, _atomic=False) -> dict:
        allowed = {"request_id", "task_id", "channel_id", "ttl_seconds", "wait_seconds"}
        if set(payload) - allowed or not {"request_id", "task_id", "channel_id"} <= set(payload):
            raise ValueError("acquire accepts only request_id, task_id, channel_id, ttl_seconds, wait_seconds")
        channel = self._channel(payload["channel_id"])
        if (not _atomic and isinstance(payload["request_id"], str)
                and payload["request_id"].startswith("atomic:")):
            raise ValueError("reserved request_id namespace")
        if (channel.guest is not None or channel.lite is not None) and (not isinstance(payload["request_id"], str)
                                          or not _GUEST_OWNER.fullmatch(payload["request_id"])):
            raise ValueError("input request_id must be 1..64 safe characters")
        if channel.guest is not None or channel.lite is not None:
            try:
                self._assert_guest_binding(channel)
            except Exception:
                return {"ok": False, "error": self._binding_error(channel)}
        ttl = LeaseStore._ttl(payload.get("ttl_seconds", self.default_ttl))
        if ttl > self.max_ttl:
            raise ValueError("ttl_seconds exceeds configured maximum")
        wait = LeaseStore._wait(payload.get("wait_seconds", 0))
        owner = (channel.channel_id, payload["request_id"])
        allow_dirty_wait = _atomic and wait > 0
        if self._action_dirty_state(channel.endpoint_id) not in (
                ("clean", "live") if allow_dirty_wait else ("clean",)):
            return {"ok": False, "error": "action_dirty"}
        dirty = self._dirty_owner(channel.endpoint_id)
        if dirty is not None and dirty != owner:
            return {"ok": False, "error": "guest_dirty"}
        abort_reason = None
        def cancelled():
            nonlocal abort_reason
            if disconnected is not None and disconnected():
                abort_reason = "client_disconnected"
            elif channel.guest is not None or channel.lite is not None:
                try:
                    self._assert_guest_binding(channel)
                except Exception:
                    abort_reason = self._binding_error(channel)
            if abort_reason is None and self._dirty_owner(channel.endpoint_id) not in (None, owner):
                abort_reason = "guest_dirty"
            if (abort_reason is None and self._action_dirty_state(channel.endpoint_id) not in
                    (("clean", "live") if allow_dirty_wait else ("clean",))):
                abort_reason = "action_dirty"
            return abort_reason is not None
        try:
            result = self.store.acquire(
                request_id=payload["request_id"], task_id=payload["task_id"],
                channel_id=channel.channel_id, project_id=channel.project_id,
                project_path=channel.project_path, endpoint_id=channel.endpoint_id,
                tool_id=channel.tool_id, ttl_seconds=ttl, wait_seconds=wait,
                cancelled=cancelled if wait else None)
        except WaitCancelled:
            return {"ok": False, "error": abort_reason or "client_disconnected"}
        # A previous expired action may have marked the endpoint dirty while
        # acquire waited for its endpoint lock. Close that race after allocation.
        dirty = self._dirty_owner(channel.endpoint_id)
        if dirty is not None and dirty != owner:
            self.store.release(channel.channel_id, result.token)
            return {"ok": False, "error": "guest_dirty"}
        if self._action_dirty(channel.endpoint_id):
            self.store.release(channel.channel_id, result.token)
            return {"ok": False, "error": "action_dirty"}
        if channel.guest is not None or channel.lite is not None:
            try:
                self._assert_guest_binding(channel)
            except Exception:
                self.store.release(channel.channel_id, result.token)
                return {"ok": False, "error": self._binding_error(channel)}
        response = {**result.public(), "token": result.token}
        if channel.guest is not None:
            response["guest_identity"] = self._guest_identity(channel)
        if channel.lite is not None:
            response["lite_identity"] = self._lite_identity(channel)
        return response

    def renew(self, payload: dict) -> dict:
        allowed = {"channel_id", "token", "ttl_seconds"}
        if set(payload) - allowed or not {"channel_id", "token"} <= set(payload):
            raise ValueError("renew accepts only channel_id, token, ttl_seconds")
        channel = self._channel(payload["channel_id"])
        if channel.guest is not None or channel.lite is not None:
            try:
                self._assert_guest_binding(channel)
            except Exception:
                return {"ok": False, "error": self._binding_error(channel)}
        ttl = LeaseStore._ttl(payload.get("ttl_seconds", self.default_ttl))
        if ttl > self.max_ttl:
            raise ValueError("ttl_seconds exceeds configured maximum")
        result = self.store.renew(channel.channel_id, payload["token"], ttl)
        response = {**result.public(), "token": result.token}
        if channel.guest is not None:
            response["guest_identity"] = self._guest_identity(channel)
        if channel.lite is not None:
            response["lite_identity"] = self._lite_identity(channel)
        return response

    def release(self, payload: dict) -> dict:
        if set(payload) != {"channel_id", "token"}:
            raise ValueError("release requires channel_id and token")
        channel = self._channel(payload["channel_id"])
        released = self.store.release(channel.channel_id, payload["token"])
        if channel.guest is not None or channel.lite is not None:
            with self.store._transaction() as db:
                db.execute("BEGIN IMMEDIATE")
                owner = db.execute("""SELECT channel_id, request_id FROM guest_dirty
                    WHERE endpoint_id=?""", (channel.endpoint_id,)).fetchone()
                if owner and (owner["channel_id"], owner["request_id"]) == (
                        channel.channel_id, released.request_id):
                    incomplete = db.execute("""SELECT 1 FROM guest_input_attempts
                        WHERE channel_id=? AND request_id=?
                        AND (status!='success' OR acked=0) LIMIT 1""",
                        (channel.channel_id, released.request_id)).fetchone()
                    if incomplete is None:
                        db.execute("""DELETE FROM guest_dirty WHERE endpoint_id=?
                            AND channel_id=? AND request_id=?""",
                            (channel.endpoint_id, channel.channel_id, released.request_id))
        return {"released": released.public()}

    def ack(self, payload: dict) -> dict:
        if set(payload) != {"channel_id", "token", "action_id"}:
            raise ValueError("ack requires channel_id, token and action_id")
        channel = self._channel(payload["channel_id"])
        if channel.guest is None and channel.lite is None:
            raise ValueError("input is not configured for this channel")
        action_id = payload["action_id"]
        if not isinstance(action_id, str) or not _ACTION_ID.fullmatch(action_id):
            raise ValueError("action_id must be 1..64 safe characters")
        def acknowledge(active):
            with self.store._transaction() as db:
                db.execute("BEGIN IMMEDIATE")
                row = db.execute("""SELECT status FROM guest_input_attempts
                    WHERE channel_id=? AND request_id=? AND action_id=?""",
                    (channel.channel_id, active.request_id, action_id)).fetchone()
                if row is None or row["status"] != "success":
                    return {"ok": False, "error": "ack_unavailable"}
                db.execute("""UPDATE guest_input_attempts SET acked=1
                    WHERE channel_id=? AND request_id=? AND action_id=?""",
                    (channel.channel_id, active.request_id, action_id))
            return {"ok": True, "action_id": action_id}
        return self.store.execute_owned(channel.channel_id, payload["token"], acknowledge)

    def status(self, channel_id: str | None = None) -> dict:
        channels = [self._channel(channel_id)] if channel_id is not None else self.channels.values()
        def entry(channel):
            active = self.store.current(channel.channel_id)
            public_lease = active.public() if active else None
            if public_lease is not None and public_lease["request_id"].startswith("atomic:"):
                public_lease["request_id"] = "[atomic]"
            result = {"channel_id": channel.channel_id,
                      "lease": public_lease,
                      "action_dirty": self._action_dirty(channel.endpoint_id)}
            if channel.guest is not None or channel.lite is not None:
                result["guest_dirty"] = self._dirty_owner(channel.endpoint_id) is not None
            return result
        return {"channels": [entry(channel) for channel in channels]}

    def execute(self, payload: dict) -> dict:
        """Run one configured, bounded command under its endpoint fence."""
        if set(payload) != {"channel_id", "token", "action"}:
            raise ValueError("execute requires channel_id, token and action")
        channel = self._channel(payload["channel_id"])
        if channel.guest is not None:
            return {"ok": False, "error": "guest_execute_disabled"}
        if channel.lite is not None:
            return {"ok": False, "error": "lite_execute_disabled"}
        action_name = payload["action"]
        if not isinstance(action_name, str) or action_name not in channel.actions:
            raise ValueError("action is not registered for this channel")
        spec = channel.actions[action_name]
        def run(active):
            # Recheck the immutable binding under the execution fence. No caller
            # supplied command, cwd or port can redirect the operation.
            if (active.endpoint_id != channel.endpoint_id or
                    active.project_id != channel.project_id or
                    active.project_path != channel.project_path or
                    active.tool_id != channel.tool_id):
                raise ValueError("lease binding differs from channel configuration")
            if self._action_dirty(channel.endpoint_id):
                return {"action": action_name, "ok": False,
                        "error": "action_dirty"}
            cwd = channel.project_path
            env = None
            workspace_result = None
            if channel.workspace is not None:
                from attempt_workspace import prepare
                # IDs are derived from the lease binding, never from paths or
                # commands supplied by the HTTP client. Replays use the same IDs.
                task_key = hashlib.sha256(json.dumps(
                    [channel.channel_id, active.task_id], separators=(",", ":")
                    ).encode("utf-8")).hexdigest()
                attempt_key = hashlib.sha256(json.dumps(
                    [channel.channel_id, active.task_id, active.request_id],
                    separators=(",", ":")).encode("utf-8")).hexdigest()
                try:
                    workspace_result = prepare(
                        channel.project_path, channel.workspace["worktree_root"],
                        channel.workspace["build_root"], "t" + task_key[:16],
                        "a" + attempt_key[:16], channel.workspace["ref"])
                except Exception:
                    return {"action": action_name, "ok": False,
                            "error": "workspace_unavailable"}
                cwd = workspace_result["worktree"]
                env = os.environ.copy()
                env.update(QICHENG_WORKTREE=cwd,
                           QICHENG_BUILD_OUTPUT=workspace_result["build_output"],
                           QICHENG_EXCLUSIVE_PORTS=",".join(map(str, channel.exclusive_ports)))
            # Persist the fence before launching the worker. A broker crash leaves
            # this row in place, so lease expiry cannot admit a successor.
            if not self._mark_action_dirty(channel, active.request_id):
                return {"action": action_name, "ok": False,
                        "error": "action_dirty"}
            try:
                result = run_action(spec["argv"], cwd=cwd, env=env,
                                    timeout_seconds=spec["timeout_seconds"])
            except OSError:
                return {"action": action_name, "ok": False,
                        "error": "action_unavailable", "action_dirty": True}
            if result.termination_uncertain:
                return {"action": action_name, "ok": False,
                        "error": "timeout" if result.timed_out else "action_uncertain",
                        "termination_uncertain": True}
            self._clear_action_dirty(channel, active.request_id)
            if result.timed_out:
                return {"action": action_name, "ok": False, "error": "timeout",
                        "termination_uncertain": False}
            response = {"action": action_name, "ok": result.exit_code == 0,
                    "exit_code": result.exit_code,
                    "stdout": result.stdout.decode("utf-8", "replace"),
                    "stderr": result.stderr.decode("utf-8", "replace"),
                    "stdout_truncated": result.stdout_truncated,
                    "stderr_truncated": result.stderr_truncated}
            if workspace_result is not None:
                response["workspace"] = workspace_result
            return response
        return self.store.execute_owned(channel.channel_id, payload["token"], run)

    def run(self, payload: dict, *, disconnected=None) -> dict:
        """Own a single fixed action from allocation through terminal receipt."""
        allowed = {"request_id", "task_id", "channel_id", "action",
                   "ttl_seconds", "wait_seconds"}
        if set(payload) - allowed or not {"request_id", "task_id", "channel_id", "action"} <= set(payload):
            raise ValueError("run requires request_id, task_id, channel_id and action")
        request_id = LeaseStore._id(payload["request_id"], "request_id")
        task_id = LeaseStore._id(payload["task_id"], "task_id")
        channel = self._channel(payload["channel_id"])
        if channel.guest is not None or channel.lite is not None:
            return {"ok": False, "error": "run_channel_disabled"}
        action_name = payload["action"]
        if not isinstance(action_name, str) or action_name not in channel.actions:
            raise ValueError("action is not registered for this channel")
        wait = LeaseStore._wait(payload.get("wait_seconds", 0))
        minimum_ttl = channel.actions[action_name]["timeout_seconds"] + 5
        ttl = LeaseStore._ttl(payload.get("ttl_seconds", max(self.default_ttl, minimum_ttl)))
        if ttl < minimum_ttl or ttl > self.max_ttl:
            raise ValueError("ttl_seconds must cover action deadline and cleanup within max_ttl_seconds")
        previous = self._claim_run(request_id, task_id, channel, action_name)
        if previous is not None:
            return previous
        private_id = "atomic:" + hmac.new(self.store._key, request_id.encode("utf-8"),
                                            hashlib.sha256).hexdigest()
        acquired = None
        response = None
        try:
            acquired = self.acquire({"request_id": private_id, "task_id": task_id,
                                     "channel_id": channel.channel_id,
                                     "ttl_seconds": ttl, "wait_seconds": wait},
                                    disconnected=disconnected, _atomic=True)
            if not acquired.get("token"):
                response = {**acquired, "request_id": request_id}
                if response.get("error") == "client_disconnected":
                    response["error"] = "run_cancelled"
            else:
                # After allocation the operation belongs to the broker. A lost
                # HTTP connection cannot cancel the action or its cleanup.
                action_result = self.execute({"channel_id": channel.channel_id,
                                              "token": acquired["token"],
                                              "action": action_name})
                response = {**action_result, "request_id": request_id}
                if (response.get("ok") is False and "exit_code" in response
                        and response["exit_code"] != 0):
                    response["error"] = "action_failed"
        except (ChannelBusy, EndpointBusy):
            response = {"ok": False, "error": "busy", "request_id": request_id}
        except WaitTimedOut:
            response = {"ok": False, "error": "wait_timeout", "request_id": request_id}
        except WaitQueueFull:
            response = {"ok": False, "error": "wait_queue_full", "request_id": request_id}
        except WaitCancelled:
            response = {"ok": False, "error": "run_cancelled", "request_id": request_id}
        except Exception:
            # The worker may have started before an exception. Never infer that
            # retrying is safe from a missing HTTP response.
            response = {"ok": False, "error": "result_unknown", "request_id": request_id}
        finally:
            if acquired is not None and acquired.get("token"):
                try:
                    self.store.release(channel.channel_id, acquired["token"])
                except Exception:
                    response = {"ok": False, "error": "result_unknown", "request_id": request_id}
            if response is None:
                response = {"ok": False, "error": "result_unknown", "request_id": request_id}
            self._finish_run(request_id, response)
        return response

    def input(self, payload: dict) -> dict:
        """Send exactly one bounded action while holding the local endpoint fence."""
        if not {"channel_id", "token", "action", "action_id"} <= set(payload):
            raise ValueError("input requires channel_id, token, action and action_id")
        action_id = payload["action_id"]
        if not isinstance(action_id, str) or not _ACTION_ID.fullmatch(action_id):
            raise ValueError("action_id must be 1..64 safe characters")
        channel = self._channel(payload["channel_id"])
        if channel.guest is None and channel.lite is None:
            raise ValueError("input is not configured for this channel")
        action, fields = _input_fields(payload)

        def run(active):
            if (active.endpoint_id != channel.endpoint_id or
                    active.project_id != channel.project_id or
                    active.project_path != channel.project_path or
                    active.tool_id != channel.tool_id):
                raise ValueError("lease binding differs from channel configuration")
            try:
                self._assert_guest_binding(channel)
                fingerprint = self._attempt_fingerprint(channel, active, action, fields)
                attempt = self._begin_input_attempt(
                    channel.channel_id, channel.endpoint_id, active.request_id,
                    action_id, fingerprint, record=False)
            except Exception:
                return {"ok": False, "error": "attempt_unavailable"}
            if attempt == "success":
                return {"ok": True, "action": action}
            if attempt == "conflict":
                return {"ok": False, "error": "action_conflict"}
            if attempt == "dirty":
                return {"ok": False, "error": "guest_dirty"}
            if attempt == "pending_ack":
                return {"ok": False, "error": "ack_required"}
            if attempt != "ready":
                return {"ok": False, "error": "already_attempted"}
            client = None
            claimed = False
            outcome = {"ok": False, "error": (
                "lite_unavailable" if channel.lite is not None else "guest_unavailable")}
            try:
                if channel.lite is not None:
                    client = self.lite_client_factory(channel.lite, channel.channel_id)
                else:
                    client = self.guest_client_factory(
                        channel.guest["binding"], channel.guest["broker_token_file"])
                # Still under the endpoint fence. A paused or unreachable guest
                # cannot have received this action, so leave no dirty attempt.
                if client.state().get("mode") != "agent":
                    return outcome
                if channel.lite is not None:
                    client.claim(active.request_id, active.generation,
                                 secrets.token_hex(16), _GUEST_TTL_SECONDS)
                else:
                    client.claim(active.request_id, _GUEST_TTL_SECONDS)
                claimed = True
                # Guest preflight may consume the entire local TTL. The endpoint
                # fence excludes a successor, but expiry still revokes input.
                self.store.assert_owner(channel.channel_id, payload["token"])
                # Claim is complete, but no input has been sent. Record the
                # tombstone immediately before crossing the input boundary.
                attempt = self._begin_input_attempt(
                    channel.channel_id, channel.endpoint_id, active.request_id,
                    action_id, fingerprint)
                if attempt != "new":
                    return {"ok": False, "error": "attempt_unavailable"}
                # Recheck at the actual input boundary as a slow database write
                # may itself cross expiry. An uncertain tombstone is kept then.
                self.store.assert_owner(channel.channel_id, payload["token"])
                client.input(action, **fields)
                outcome = {"ok": True, "action": action}
            except LeaseGone:
                outcome = {"ok": False, "error": "lease_expired"}
            except Exception:
                # The input outcome can be uncertain. Never send it again here.
                outcome = {"ok": False, "error": "input_failed" if claimed else (
                    "lite_unavailable" if channel.lite is not None else "guest_unavailable")}
            finally:
                if claimed:
                    try:
                        client.release()
                    except Exception:
                        # Guest expiry is the only safe successor fence now.
                        outcome = {"ok": False, "error": (
                            "lite_release_uncertain" if channel.lite is not None
                            else "guest_release_uncertain")}
            if outcome["ok"]:
                try:
                    self._complete_input_attempt(
                        channel.channel_id, active.request_id, action_id)
                except Exception:
                    return {"ok": False, "error": "attempt_unavailable"}
            return outcome
        return self.store.execute_owned(channel.channel_id, payload["token"], run)


class BrokerHTTPServer(ThreadingHTTPServer):
    def __init__(self, broker: Broker, port: int = 18770):
        self.broker = broker
        super().__init__(("127.0.0.1", port), BrokerHandler)
        self.daemon_threads = True


class BrokerHandler(BaseHTTPRequestHandler):
    server: BrokerHTTPServer
    protocol_version = "HTTP/1.1"

    def log_message(self, _format, *_args):
        # Never log authorization headers, tokens or task payloads.
        pass

    def _send(self, status: int, body: dict):
        data = json.dumps(body, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        self.close_connection = True
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.end_headers()
        try:
            self.wfile.write(data)
        except OSError:
            pass

    def _authorized(self) -> bool:
        if self.server.broker.authorize(self.headers.get("Authorization")):
            return True
        self._send(401, {"error": "unauthorized"})
        return False

    def _read_json(self) -> dict:
        if self.headers.get("Content-Type", "").split(";")[0].strip() != "application/json":
            raise ValueError("Content-Type must be application/json")
        length = int(self.headers.get("Content-Length", "0"))
        if not 0 < length <= 16384:
            raise ValueError("request body must be 1..16384 bytes")
        body = json.loads(self.rfile.read(length))
        if not isinstance(body, dict):
            raise ValueError("JSON object required")
        return body

    def _dispatch(self, callback):
        try:
            result = callback()
        except (ChannelBusy, EndpointBusy):
            self._send(409, {"error": "busy"})
        except RequestConflict:
            self._send(409, {"error": "request_conflict"})
        except LeaseGone:
            self._send(410, {"error": "lease_gone"})
        except WaitTimedOut:
            self._send(408, {"error": "wait_timeout"})
        except WaitQueueFull:
            self._send(429, {"error": "wait_queue_full"})
        except InvalidToken:
            self._send(403, {"error": "invalid_token"})
        except (ValueError, TypeError, json.JSONDecodeError) as error:
            self._send(400, {"error": "invalid_request", "detail": str(error)})
        else:
            if result.get("error") == "client_disconnected":
                return
            code = {"timeout": 504, "workspace_unavailable": 503,
                    "result_unknown": 503, "run_in_progress": 409,
                    "action_failed": 502,
                    "run_cancelled": 410, "busy": 409,
                    "wait_timeout": 408, "wait_queue_full": 429,
                    "run_channel_disabled": 403,
                    "action_dirty": 503, "action_uncertain": 503,
                    "action_unavailable": 503, "guest_unavailable": 503,
                     "lite_unavailable": 503, "input_failed": 502,
                     "guest_release_uncertain": 503, "lite_release_uncertain": 503,
                     "attempt_unavailable": 503, "already_attempted": 409,
                     "action_conflict": 409, "ack_unavailable": 409,
                     "ack_required": 409, "guest_dirty": 409,
                     "lease_expired": 410, "client_disconnected": 499,
                     "guest_execute_disabled": 403, "lite_execute_disabled": 403,
                    "guest_binding_unavailable": 503,
                    "lite_binding_unavailable": 503}.get(
                        result.get("error"), 200)
            self._send(code, result)

    def do_POST(self):
        if not self._authorized():
            return
        routes = {"/v1/acquire": self.server.broker.acquire,
                   "/v1/run": self.server.broker.run,
                   "/v1/renew": self.server.broker.renew,
                   "/v1/release": self.server.broker.release,
                   "/v1/ack": self.server.broker.ack,
                  "/v1/execute": self.server.broker.execute,
                  "/v1/input": self.server.broker.input}
        if self.path not in routes:
            self._send(404, {"error": "not_found"})
            return
        if self.path in ("/v1/acquire", "/v1/run"):
            def disconnected():
                try:
                    readable, _, _ = select.select([self.connection], [], [], 0)
                    if not readable:
                        return False
                    return not self.connection.recv(1, socket.MSG_PEEK)
                except (ConnectionError, OSError, ValueError):
                    return True
            self._dispatch(lambda: routes[self.path](
                self._read_json(), disconnected=disconnected))
        else:
            self._dispatch(lambda: routes[self.path](self._read_json()))

    def do_GET(self):
        if not self._authorized():
            return
        parsed = urlsplit(self.path)
        if parsed.path != "/v1/status":
            self._send(404, {"error": "not_found"})
            return
        def status():
            query = parse_qs(parsed.query, strict_parsing=True)
            if set(query) - {"channel_id"} or len(query.get("channel_id", [])) > 1:
                raise ValueError("only one channel_id query parameter is allowed")
            return self.server.broker.status(query.get("channel_id", [None])[0])
        self._dispatch(status)


def main():
    parser = argparse.ArgumentParser(description="Qicheng local lease broker")
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--credential-file", type=Path, required=True)
    parser.add_argument("--db", type=Path, required=True)
    parser.add_argument("--port", type=int, default=18770)
    parser.add_argument("--init-credential", action="store_true",
                        help="create missing private credential file, then exit")
    args = parser.parse_args()
    if args.init_credential:
        args.credential_file.parent.mkdir(parents=True, exist_ok=True)
        fd = args.credential_file.open("x", encoding="ascii")
        try:
            fd.write(secrets.token_hex(32) + "\n")
        finally:
            fd.close()
        if hasattr(args.credential_file, "chmod"):
            args.credential_file.chmod(0o600)
        return
    broker = Broker(config_path=args.config, credential_path=args.credential_file,
                    db_path=args.db)
    server = BrokerHTTPServer(broker, args.port)
    try:
        server.serve_forever()
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
