"""Fail-closed client for the loopback task lease broker.

One MCP process owns at most one lease at a time. A confirmed release permits
a new request identity; a failed or uncertain exchange ends the process's input.
"""

import http.client
import json
import math
import re
import secrets
import threading
import time
from pathlib import Path
from urllib.parse import urlsplit

from .client import normalize_key


_SAFE = re.compile(r'[A-Za-z0-9._-]{1,64}\Z')
_HEX = re.compile(r'[a-f0-9]{64}\Z')
_FIELDS = {'click': {'x', 'y', 'button'}, 'move': {'x', 'y'},
           'key': {'key'}, 'type': {'text'}}
_KEYS = frozenset(('Return', 'BackSpace', 'Tab', 'Escape', 'Delete',
                   'Left', 'Right', 'Up', 'Down', 'Home', 'End', 'Page_Up',
                   'Page_Down', 'space', 'ctrl+a', 'ctrl+c', 'ctrl+v',
                   'ctrl+x', 'ctrl+z', 'ctrl+f', 'ctrl+l'))
_MAX_RESPONSE = 16384
_TIMEOUT = 5
_TTL = 30
_DEFAULT_WAIT_SECONDS = 30
_MAX_WAIT_SECONDS = 300
_HEARTBEAT_INTERVAL = 10


def _new_id(previous=None):
    value = 'mcp-' + secrets.token_hex(16)
    while value == previous:
        value = 'mcp-' + secrets.token_hex(16)
    return value


def _input(action, fields):
    allowed = _FIELDS.get(action) if isinstance(action, str) else None
    if allowed is None or set(fields) - allowed:
        raise ValueError('Invalid broker input action or fields')
    if action in ('click', 'move'):
        if not {'x', 'y'} <= set(fields) or any(
                type(fields[n]) is not int or not 0 <= fields[n] <= 16383
                for n in ('x', 'y')):
            raise ValueError('Invalid broker coordinates')
        if 'button' in fields and (type(fields['button']) is not int
                                   or fields['button'] not in (1, 2, 3)):
            raise ValueError('Invalid broker button')
    elif action == 'key':
        if set(fields) != {'key'}:
            raise ValueError('Invalid broker key')
        fields = dict(fields, key=normalize_key(fields['key']))
        if fields['key'] not in _KEYS:
            raise ValueError('Invalid broker key')
    elif action == 'type':
        value = fields.get('text')
        if (set(fields) != {'text'} or not isinstance(value, str)
                or not value or len(value) > 2000 or '\x00' in value):
            raise ValueError('Invalid broker text')
    return fields


class BrokerClient:
    def __init__(self, url, token_file, channel_id, expected_guest_identity,
                 *, connection_factory=None, monotonic=None, wall_clock=None):
        parsed = urlsplit(url)
        if (parsed.scheme != 'http' or parsed.hostname != '127.0.0.1'
                or parsed.username or parsed.password or parsed.path not in ('', '/')
                or parsed.query or parsed.fragment or parsed.port is None):
            raise ValueError('Broker URL must be http://127.0.0.1:<port>')
        if not isinstance(channel_id, str) or not _SAFE.fullmatch(channel_id):
            raise ValueError('Invalid broker channel ID')
        if (not isinstance(expected_guest_identity, dict)
                or set(expected_guest_identity) != {'vm_id', 'bios_uuid', 'project'}
                or any(not isinstance(value, str) or not value
                       for value in expected_guest_identity.values())):
            raise ValueError('Invalid expected guest identity')
        credential = Path(token_file).read_text(encoding='ascii').strip()
        if not _HEX.fullmatch(credential):
            raise ValueError('Invalid broker credential file')
        self.host, self.port = parsed.hostname, parsed.port
        self.credential = credential
        self.channel_id = channel_id
        self.expected_guest_identity = dict(expected_guest_identity)
        self.request_id = _new_id()
        self.task_id = _new_id()
        self.connection_factory = connection_factory or http.client.HTTPConnection
        self.clock = monotonic or time.monotonic
        self.wall_clock = wall_clock or time.time
        self.phase = 'fresh'
        self.lease_token = None
        self.deadline = None
        self._lock = threading.RLock()
        self._stop_heartbeat = threading.Event()
        self._heartbeat_thread = None

    def _post(self, path, payload, *, timeout=_TIMEOUT):
        # Count the actual UTF-8 HTTP bytes, not ASCII JSON escapes. A valid
        # 2000-character non-BMP text action can otherwise exceed 16 KiB here.
        body = json.dumps(payload, ensure_ascii=False, separators=(',', ':')).encode('utf-8')
        if len(body) > 16384:
            raise ValueError('Broker request too large')
        connection = self.connection_factory(self.host, self.port, timeout=timeout)
        try:
            connection.request('POST', path, body=body, headers={
                'Authorization': 'Bearer ' + self.credential,
                'Content-Type': 'application/json',
                'Content-Length': str(len(body))})
            response = connection.getresponse()
            if response.status != 200:
                raise RuntimeError('Broker rejected the request')
            length = response.getheader('Content-Length')
            if length is None or not length.isdigit() or not 0 < int(length) <= _MAX_RESPONSE:
                raise RuntimeError('Invalid broker response length')
            data = response.read(int(length) + 1)
            if len(data) != int(length):
                raise RuntimeError('Incomplete broker response')
            result = json.loads(data)
            if not isinstance(result, dict):
                raise RuntimeError('Invalid broker response')
            return result
        finally:
            connection.close()

    def _kill(self):
        with self._lock:
            self.phase = 'dead'
            self.lease_token = None
            self.deadline = None
            self._stop_heartbeat.set()

    def _heartbeat(self, stop_event):
        while not stop_event.wait(_HEARTBEAT_INTERVAL):
            with self._lock:
                if self._stop_heartbeat is not stop_event or self.phase != 'active':
                    return
                try:
                    self._renew_if_needed()
                except Exception:
                    # An uncertain renewal cannot authorize further input.
                    # The caller must reconcile this session; never acquire again.
                    self._kill()
                    return

    def _lease(self, value, started):
        if (value.get('request_id') != self.request_id
                or value.get('task_id') != self.task_id
                or value.get('channel_id') != self.channel_id
                or value.get('guest_identity') != self.expected_guest_identity
                or type(value.get('generation')) is not int
                or value['generation'] < 1
                or not isinstance(value.get('token'), str)
                or not _HEX.fullmatch(value['token'])
                or not isinstance(value.get('expires_at'), (int, float))
                or type(value['expires_at']) is bool
                or not math.isfinite(value['expires_at'])):
            raise RuntimeError('Invalid broker lease response')
        now = self.clock()
        # The broker and this client share the host wall clock. Its absolute
        # expiry bounds a delayed HTTP response, while monotonic time keeps
        # later local checks independent of wall-clock changes.
        deadline = min(started + _TTL - 2,
                       now + value['expires_at'] - self.wall_clock() - 2)
        if now >= deadline:
            raise RuntimeError('Broker lease response arrived too late')
        self.lease_token = value['token']
        self.deadline = deadline

    def begin(self, wait_seconds=_DEFAULT_WAIT_SECONDS):
        with self._lock:
            if self.phase not in ('fresh', 'finished'):
                raise RuntimeError('Broker session cannot begin again')
            if type(wait_seconds) is not int or not 0 <= wait_seconds <= _MAX_WAIT_SECONDS:
                raise ValueError('wait_seconds must be an integer between 0 and 300')
            try:
                if self.phase == 'finished':
                    self.request_id = _new_id(self.request_id)
                    self.task_id = _new_id(self.task_id)
                    self._stop_heartbeat = threading.Event()
                    self._heartbeat_thread = None
                value = self._post('/v1/acquire', dict(
                    request_id=self.request_id, task_id=self.task_id,
                    channel_id=self.channel_id, ttl_seconds=_TTL,
                    wait_seconds=wait_seconds), timeout=wait_seconds + _TIMEOUT)
                # The broker may allocate only after a queue wait. Its expiry
                # still bounds any subsequent HTTP response delay.
                started = self.clock()
                self._lease(value, started)
                self.phase = 'active'
                self._heartbeat_thread = threading.Thread(
                    target=self._heartbeat, args=(self._stop_heartbeat,),
                    name='broker-lease-renew', daemon=True)
                self._heartbeat_thread.start()
                return {'session': 'active', 'channel_id': self.channel_id,
                        'expires_at': value['expires_at']}
            except Exception:
                self._kill()
                raise RuntimeError('Broker session could not begin') from None

    def _active(self):
        if self.phase != 'active' or self.clock() >= self.deadline:
            self._kill()
            raise RuntimeError('Broker session is unavailable or expired')

    def _renew_if_needed(self):
        self._active()
        if self.deadline - self.clock() > 12:
            return
        started = self.clock()
        value = self._post('/v1/renew', dict(
            channel_id=self.channel_id, token=self.lease_token,
            ttl_seconds=_TTL))
        if value.get('token') != self.lease_token:
            raise RuntimeError('Broker lease token changed')
        self._lease(value, started)

    def input(self, action, **fields):
        with self._lock:
            self._active()
            fields = _input(action, fields)
            action_id = 'a-' + secrets.token_hex(16)
            try:
                self._renew_if_needed()
                result = self._post('/v1/input', dict(
                    channel_id=self.channel_id, token=self.lease_token,
                    action_id=action_id, action=action, **fields))
                if result != {'ok': True, 'action': action}:
                    raise RuntimeError('Broker input was rejected')
                acknowledged = self._post('/v1/ack', dict(
                    channel_id=self.channel_id, token=self.lease_token,
                    action_id=action_id))
                if acknowledged != {'ok': True, 'action_id': action_id}:
                    raise RuntimeError('Broker input acknowledgement failed')
                return {'ok': True, 'action': action, 'action_id': action_id}
            except Exception:
                # Broker records each action_id before guest input. Never retry an
                # uncertain outcome with a new ID or continue this MCP session.
                self._kill()
                raise RuntimeError('Broker input failed; session ended') from None

    def finish(self):
        with self._lock:
            self._active()
            try:
                value = self._post('/v1/release', dict(
                    channel_id=self.channel_id, token=self.lease_token))
                if (not isinstance(value.get('released'), dict)
                        or value['released'].get('request_id') != self.request_id
                        or value['released'].get('channel_id') != self.channel_id):
                    raise RuntimeError('Invalid broker release response')
                self._kill()
                self.phase = 'finished'
                return {'session': 'finished', 'channel_id': self.channel_id}
            except Exception:
                self._kill()
                raise RuntimeError('Broker release uncertain; session ended') from None
