"""Loopback-only HTTP broker for trusted local Qicheng clients.

Guest input is available only for explicitly bound channels.
Other MCP and tool paths remain independent of this broker.
"""

from __future__ import annotations

import argparse
import hashlib
import hmac
import json
import re
import secrets
import select
import socket
import subprocess
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

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


class Broker:
    def __init__(self, *, config_path: str | Path, credential_path: str | Path,
                 db_path: str | Path, clock=None, guest_client_factory=None):
        config = json.loads(Path(config_path).read_text(encoding="utf-8"))
        if not isinstance(config, dict) or not isinstance(config.get("channels"), list):
            raise ValueError("config requires a channels list")
        self.channels = {}
        for entry in config["channels"]:
            required = {"channel_id", "endpoint_id", "tool_id", "project_id", "project_path"}
            if not isinstance(entry, dict) or not required <= set(entry) or set(entry) - required - {"actions", "exclusive_ports", "guest"}:
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
                                 "guest": guest})
            if channel.channel_id in self.channels:
                raise ValueError("duplicate channel_id")
            for existing in self.channels.values():
                existing_root = Path(existing.project_path)
                if project_path == existing_root or project_path in existing_root.parents or existing_root in project_path.parents:
                    raise ValueError("channel project roots must not overlap")
                if set(ports) & set(existing.exclusive_ports) and channel.endpoint_id != existing.endpoint_id:
                    raise ValueError("shared TCP port requires the same endpoint_id")
                if (guest is not None and existing.guest is not None
                        and channel.endpoint_id != existing.endpoint_id
                        and any(guest["binding"][name] == existing.guest["binding"][name]
                                for name in ("vm_id", "bios_uuid", "token_file"))):
                    raise ValueError("shared guest requires the same endpoint_id")
            self.channels[channel.channel_id] = channel
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
        self.store = LeaseStore(db_path, **({"clock": clock} if clock is not None else {}))
        self._reconcile_guest_bindings()

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

    def _reconcile_guest_bindings(self):
        """Pin guest identity in the lease DB; changing it needs an explicit migration."""
        expected = {channel.channel_id: self._guest_fingerprint(channel)
                    for channel in self.channels.values() if channel.guest is not None}
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
        fingerprint = self._guest_fingerprint(channel)
        with self.store._transaction() as db:
            row = db.execute("SELECT fingerprint FROM guest_bindings WHERE channel_id=?",
                             (channel.channel_id,)).fetchone()
        if row is None or not hmac.compare_digest(row["fingerprint"], fingerprint):
            raise RuntimeError("registered guest binding changed")

    def _attempt_fingerprint(self, channel: Channel, active, action, fields):
        return self._digest({
            "channel_id": channel.channel_id, "request_id": active.request_id,
            "generation": active.generation, "endpoint_id": active.endpoint_id,
            "project_id": active.project_id, "project_path": active.project_path,
            "tool_id": active.tool_id, "guest": self._guest_fingerprint(channel),
            "action": action, "fields": fields})

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

    def authorize(self, authorization: str | None) -> bool:
        if not authorization or not authorization.startswith("Bearer "):
            return False
        return hmac.compare_digest(authorization[7:], self.credential)

    def _channel(self, channel_id: object) -> Channel:
        if not isinstance(channel_id, str) or channel_id not in self.channels:
            raise ValueError("channel_id is not registered")
        return self.channels[channel_id]

    def acquire(self, payload: dict, *, disconnected=None) -> dict:
        allowed = {"request_id", "task_id", "channel_id", "ttl_seconds", "wait_seconds"}
        if set(payload) - allowed or not {"request_id", "task_id", "channel_id"} <= set(payload):
            raise ValueError("acquire accepts only request_id, task_id, channel_id, ttl_seconds, wait_seconds")
        channel = self._channel(payload["channel_id"])
        if channel.guest is not None and (not isinstance(payload["request_id"], str)
                                          or not _GUEST_OWNER.fullmatch(payload["request_id"])):
            raise ValueError("guest request_id must be 1..64 safe characters")
        if channel.guest is not None:
            try:
                self._assert_guest_binding(channel)
            except Exception:
                return {"ok": False, "error": "guest_binding_unavailable"}
        ttl = LeaseStore._ttl(payload.get("ttl_seconds", self.default_ttl))
        if ttl > self.max_ttl:
            raise ValueError("ttl_seconds exceeds configured maximum")
        wait = LeaseStore._wait(payload.get("wait_seconds", 0))
        owner = (channel.channel_id, payload["request_id"])
        dirty = self._dirty_owner(channel.endpoint_id)
        if dirty is not None and dirty != owner:
            return {"ok": False, "error": "guest_dirty"}
        abort_reason = None
        def cancelled():
            nonlocal abort_reason
            if disconnected is not None and disconnected():
                abort_reason = "client_disconnected"
            elif channel.guest is not None:
                try:
                    self._assert_guest_binding(channel)
                except Exception:
                    abort_reason = "guest_binding_unavailable"
            if abort_reason is None and self._dirty_owner(channel.endpoint_id) not in (None, owner):
                abort_reason = "guest_dirty"
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
        if channel.guest is not None:
            try:
                self._assert_guest_binding(channel)
            except Exception:
                self.store.release(channel.channel_id, result.token)
                return {"ok": False, "error": "guest_binding_unavailable"}
        response = {**result.public(), "token": result.token}
        if channel.guest is not None:
            response["guest_identity"] = self._guest_identity(channel)
        return response

    def renew(self, payload: dict) -> dict:
        allowed = {"channel_id", "token", "ttl_seconds"}
        if set(payload) - allowed or not {"channel_id", "token"} <= set(payload):
            raise ValueError("renew accepts only channel_id, token, ttl_seconds")
        channel = self._channel(payload["channel_id"])
        if channel.guest is not None:
            try:
                self._assert_guest_binding(channel)
            except Exception:
                return {"ok": False, "error": "guest_binding_unavailable"}
        ttl = LeaseStore._ttl(payload.get("ttl_seconds", self.default_ttl))
        if ttl > self.max_ttl:
            raise ValueError("ttl_seconds exceeds configured maximum")
        result = self.store.renew(channel.channel_id, payload["token"], ttl)
        response = {**result.public(), "token": result.token}
        if channel.guest is not None:
            response["guest_identity"] = self._guest_identity(channel)
        return response

    def release(self, payload: dict) -> dict:
        if set(payload) != {"channel_id", "token"}:
            raise ValueError("release requires channel_id and token")
        channel = self._channel(payload["channel_id"])
        released = self.store.release(channel.channel_id, payload["token"])
        if channel.guest is not None:
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
        if channel.guest is None:
            raise ValueError("guest input is not configured for this channel")
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
            result = {"channel_id": channel.channel_id,
                      "lease": active.public() if active else None}
            if channel.guest is not None:
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
        action_name = payload["action"]
        if not isinstance(action_name, str) or action_name not in channel.actions:
            raise ValueError("action is not registered for this channel")
        spec = channel.actions[action_name]
        def run(active):
            # Recheck the immutable binding under the execution fence. No caller
            # supplied command, cwd or port can redirect the operation.
            if (active.endpoint_id != channel.endpoint_id or
                    active.project_path != channel.project_path or
                    active.tool_id != channel.tool_id):
                raise ValueError("lease binding differs from channel configuration")
            try:
                result = subprocess.run(spec["argv"], cwd=channel.project_path,
                                        stdin=subprocess.DEVNULL, capture_output=True,
                                        timeout=spec["timeout_seconds"], shell=False)
            except subprocess.TimeoutExpired:
                return {"action": action_name, "ok": False, "error": "timeout"}
            return {"action": action_name, "ok": result.returncode == 0,
                    "exit_code": result.returncode,
                    "stdout": result.stdout[:16384].decode("utf-8", "replace"),
                    "stderr": result.stderr[:16384].decode("utf-8", "replace")}
        return self.store.execute_owned(channel.channel_id, payload["token"], run)

    def input(self, payload: dict) -> dict:
        """Send exactly one bounded action while holding the local endpoint fence."""
        if not {"channel_id", "token", "action", "action_id"} <= set(payload):
            raise ValueError("input requires channel_id, token, action and action_id")
        action_id = payload["action_id"]
        if not isinstance(action_id, str) or not _ACTION_ID.fullmatch(action_id):
            raise ValueError("action_id must be 1..64 safe characters")
        channel = self._channel(payload["channel_id"])
        if channel.guest is None:
            raise ValueError("guest input is not configured for this channel")
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
            outcome = {"ok": False, "error": "guest_unavailable"}
            try:
                client = self.guest_client_factory(
                    channel.guest["binding"], channel.guest["broker_token_file"])
                # Still under the endpoint fence. A paused or unreachable guest
                # cannot have received this action, so leave no dirty attempt.
                if client.state().get("mode") != "agent":
                    return outcome
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
                outcome = {"ok": False, "error": "input_failed" if claimed else "guest_unavailable"}
            finally:
                if claimed:
                    try:
                        client.release()
                    except Exception:
                        # Guest expiry is the only safe successor fence now.
                        outcome = {"ok": False, "error": "guest_release_uncertain"}
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
        self.wfile.write(data)

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
            code = {"timeout": 504, "guest_unavailable": 503,
                     "input_failed": 502, "guest_release_uncertain": 503,
                     "attempt_unavailable": 503, "already_attempted": 409,
                     "action_conflict": 409, "ack_unavailable": 409,
                     "ack_required": 409, "guest_dirty": 409,
                     "lease_expired": 410, "client_disconnected": 499,
                     "guest_execute_disabled": 403,
                    "guest_binding_unavailable": 503}.get(
                        result.get("error"), 200)
            self._send(code, result)

    def do_POST(self):
        if not self._authorized():
            return
        routes = {"/v1/acquire": self.server.broker.acquire,
                   "/v1/renew": self.server.broker.renew,
                   "/v1/release": self.server.broker.release,
                   "/v1/ack": self.server.broker.ack,
                  "/v1/execute": self.server.broker.execute,
                  "/v1/input": self.server.broker.input}
        if self.path not in routes:
            self._send(404, {"error": "not_found"})
            return
        if self.path == "/v1/acquire":
            def disconnected():
                try:
                    readable, _, _ = select.select([self.connection], [], [], 0)
                    if not readable:
                        return False
                    return not self.connection.recv(1, socket.MSG_PEEK)
                except (ConnectionError, OSError, ValueError):
                    return True
            self._dispatch(lambda: self.server.broker.acquire(
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
