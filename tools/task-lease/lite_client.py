"""Fixed loopback client for a Qicheng Lite channel.

The caller owns the local SQLite endpoint lease. This client only speaks to the
configured Lite port and never accepts a caller supplied URL or credential.
"""

from __future__ import annotations

import hmac
import json
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import ProxyHandler, Request, build_opener


_OPENER = build_opener(ProxyHandler({}))
_MAX_RESPONSE = 16384


class LiteClient:
    def __init__(self, binding: dict, channel_id: str):
        self.binding = binding
        self.channel_id = channel_id
        self.base = f"http://127.0.0.1:{binding['port']}"
        self._lease = None

    @staticmethod
    def _token(path: Path) -> str:
        value = path.read_text(encoding="ascii").strip()
        if len(value) != 64 or any(char not in "0123456789abcdef" for char in value):
            raise RuntimeError("Lite credential is invalid")
        return value

    def _request(self, path: str, *, body: dict | None = None, broker: bool = True) -> dict:
        token_file = self.binding["broker_token_file" if broker else "channel_token_file"]
        headers = {"Authorization": "Bearer " + self._token(token_file)}
        data = None
        if body is not None:
            data = json.dumps(body, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
            headers["Content-Type"] = "application/json"
        request = Request(self.base + path, data=data, headers=headers,
                          method="POST" if body is not None else "GET")
        try:
            with _OPENER.open(request, timeout=5) as response:
                if response.status != 200:
                    raise RuntimeError("Lite request failed")
                length = response.headers.get("Content-Length")
                if length is not None and (not length.isdecimal() or int(length) > _MAX_RESPONSE):
                    raise RuntimeError("Lite response is too large")
                raw = response.read(_MAX_RESPONSE + 1)
                if len(raw) > _MAX_RESPONSE:
                    raise RuntimeError("Lite response is too large")
                result = json.loads(raw)
        except (HTTPError, URLError, TimeoutError, ValueError, OSError):
            raise RuntimeError("Lite request failed") from None
        if not isinstance(result, dict) or "error" in result:
            raise RuntimeError("Lite request failed")
        return result

    def _status(self, result: dict) -> dict:
        if not hmac.compare_digest(str(result.get("channel_id", "")),
                                   str(self.binding["channel_number"])):
            raise RuntimeError("Lite channel identity differs")
        if result.get("mode") not in ("agent", "human", "paused"):
            raise RuntimeError("Lite mode is invalid")
        if type(result.get("actions")) is not int or result["actions"] < 0:
            raise RuntimeError("Lite action count is invalid")
        return result

    def state(self) -> dict:
        return self._status(self._request("/api/state", broker=False))

    def inspect(self) -> dict:
        return self._status(self._request("/api/lease/inspect"))

    def claim(self, owner: str, generation: int, nonce: str, ttl_seconds: int) -> None:
        result = self._status(self._request("/api/lease/claim", body={
            "owner": owner, "generation": generation, "nonce": nonce,
            "ttl_seconds": ttl_seconds}))
        lease = result.get("lease")
        if (result.get("mode") != "agent" or not isinstance(lease, dict) or
                lease.get("owner") != owner or lease.get("generation") != generation):
            raise RuntimeError("Lite claim was not verified")
        self._lease = {"owner": owner, "generation": generation, "nonce": nonce}

    def renew(self, ttl_seconds: int) -> None:
        if self._lease is None:
            raise RuntimeError("Lite lease is absent")
        result = self._status(self._request("/api/lease/renew", body={
            **self._lease, "ttl_seconds": ttl_seconds}))
        lease = result.get("lease")
        if (result.get("mode") != "agent" or not isinstance(lease, dict) or
                lease.get("owner") != self._lease["owner"] or
                lease.get("generation") != self._lease["generation"]):
            raise RuntimeError("Lite renewal was not verified")

    def input(self, action: str, **fields) -> None:
        if self._lease is None:
            raise RuntimeError("Lite lease is absent")
        before = self.inspect()
        result = self._status(self._request("/api/input", body={
            "actor": "agent", "lease": self._lease, "action": action, **fields}))
        if result["actions"] != before["actions"] + 1:
            raise RuntimeError("Lite input was not acknowledged")

    def release(self) -> None:
        if self._lease is None:
            return
        lease = self._lease
        result = self._status(self._request("/api/lease/release", body=lease))
        if result.get("lease") is not None:
            raise RuntimeError("Lite release was not acknowledged")
        self._lease = None
