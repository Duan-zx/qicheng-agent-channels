"""Host-side, Hyper-V-only broker lease adapter for one private guest.

The channel credential is used for verified state and agent input.  The
separate broker credential is used only for lease operations.
"""

import hmac
import re
from pathlib import Path

from .client import GuestClient


_OWNER = re.compile(r"[A-Za-z0-9._-]{1,64}\Z")
_NONCE = re.compile(r"[a-f0-9]{64}\Z")
_SHA256 = re.compile(r"[a-f0-9]{64}\Z")
_ACTIONS = {
    "click": frozenset(("x", "y", "button")),
    "move": frozenset(("x", "y")),
    "key": frozenset(("key",)),
    "type": frozenset(("text",)),
}


def _ttl(value):
    if type(value) is not int or not 1 <= value <= 300:
        raise ValueError("Lease TTL must be an integer from 1 to 300 seconds")
    return value


def _lease_state(value):
    if (not isinstance(value, dict) or value.get("enabled") is not True
            or type(value.get("active")) is not bool):
        raise RuntimeError("Guest lease state is invalid or disabled")
    return value


class LeaseClient:
    """Own a single agent lease; never expose the broker's generic exchange.

    ``binding`` is the usual GuestClient binding with a channel token file.
    ``broker_token_file`` must identify a different file containing a different
    token. ``socket_factory`` is only for transport injection in tests.
    """

    def __init__(self, binding, broker_token_file, socket_factory=None):
        channel_path = Path(binding["token_file"]).resolve()
        broker_path = Path(broker_token_file).resolve()
        if str(channel_path).casefold() == str(broker_path).casefold():
            raise ValueError("Channel and broker token files must differ")
        broker_binding = dict(binding, token_file=broker_path)
        try:
            self._channel = GuestClient(binding, socket_factory)
            self._broker = GuestClient(broker_binding, socket_factory)
        except Exception:
            raise RuntimeError("Could not initialize guest credentials") from None
        if hmac.compare_digest(self._channel.token, self._broker.token):
            raise ValueError("Channel and broker token values must differ")
        self._claim = None
        self._uncertain = False

    def _reconcile(self, state):
        if self._claim is None:
            return
        lease = state["lease"]
        if (state.get("mode") != "agent" or lease["active"] is not True
                or lease.get("owner") != self._claim["owner"]
                or type(lease.get("generation")) is not int
                or lease["generation"] != self._claim["generation"]):
            self._claim = None
            self._uncertain = False

    def _state(self):
        try:
            state = self._channel.state()
            _lease_state(state.get("lease"))
            self._reconcile(state)
            return state
        except Exception:
            raise RuntimeError("Verified guest lease state is unavailable") from None

    def _broker_call(self, op, **fields):
        try:
            return self._broker.exchange(op, **fields)
        except Exception:
            raise RuntimeError("Guest lease operation failed") from None

    def state(self):
        """Return identity-verified public state using only the channel token."""
        return self._state()

    def inspect(self):
        """Read public lease occupancy using only the broker token."""
        return _lease_state(self._broker_call("lease_inspect"))

    def claim(self, owner, ttl_seconds):
        if not isinstance(owner, str) or not _OWNER.fullmatch(owner):
            raise ValueError("Invalid lease owner")
        _ttl(ttl_seconds)
        if self._claim is not None:
            raise RuntimeError("This client already holds a lease")
        state = self._state()
        if state.get("mode") != "agent":
            raise RuntimeError("Guest agent mode is not enabled")
        if state["lease"]["active"]:
            raise RuntimeError("Guest lease is occupied")
        result = self._broker_call("lease_claim", owner=owner, ttl_seconds=ttl_seconds)
        if (not isinstance(result, dict) or set(result) != {"owner", "generation", "nonce", "expires_in_seconds"}
                or result["owner"] != owner or type(result["generation"]) is not int
                or result["generation"] < 1 or not isinstance(result["nonce"], str)
                or not _NONCE.fullmatch(result["nonce"])
                or type(result["expires_in_seconds"]) is not int
                or not 0 < result["expires_in_seconds"] <= ttl_seconds):
            raise RuntimeError("Guest returned an invalid lease claim")
        self._claim = dict(owner=owner, generation=result["generation"], nonce=result["nonce"])
        self._uncertain = False
        return dict(result)

    def _held(self):
        if self._claim is None:
            raise RuntimeError("No guest lease is held")
        return dict(self._claim)

    def _check_occupancy(self, return_state=False):
        claim = self._held()
        try:
            state = self._state()
        except Exception:
            self._uncertain = True
            raise
        lease = state["lease"]
        if (state.get("mode") != "agent" or lease["active"] is not True
                or lease.get("owner") != claim["owner"]
                or type(lease.get("generation")) is not int
                or lease["generation"] != claim["generation"]):
            self._claim = None
            self._uncertain = False
            raise RuntimeError("Guest lease is no longer held")
        return (claim, state) if return_state else claim

    def renew(self, ttl_seconds):
        _ttl(ttl_seconds)
        try:
            claim = self._check_occupancy()
            result = self._broker_call("lease_renew", **claim, ttl_seconds=ttl_seconds)
        except Exception:
            if self._claim is not None:
                self._uncertain = True
            raise
        if (not isinstance(result, dict) or result.get("enabled") is not True
                or result.get("active") is not True or result.get("owner") != claim["owner"]
                or type(result.get("generation")) is not int
                or result["generation"] != claim["generation"]
                or not isinstance(result.get("expires_in_seconds"), (int, float))
                or type(result["expires_in_seconds"]) is bool
                or not 0 < result["expires_in_seconds"] <= ttl_seconds
                or "nonce" in result):
            self._uncertain = True
            raise RuntimeError("Guest returned an invalid lease renewal")
        return result

    def release(self):
        claim = self._held()
        try:
            result = self._broker_call("lease_release", **claim)
        except Exception:
            self._uncertain = True
            raise
        if (not isinstance(result, dict) or result.get("enabled") is not True
                or result.get("active") is not False or result.get("owner") is not None
                or result.get("generation") is not None or "nonce" in result):
            self._uncertain = True
            raise RuntimeError("Guest returned an invalid lease release")
        self._claim = None
        self._uncertain = False
        return result

    def input(self, action, **fields):
        """Send one agent input through GuestClient's verified operation path."""
        allowed = _ACTIONS.get(action)
        if allowed is None or set(fields) - allowed:
            raise ValueError("Invalid agent input fields")
        self._held()
        if self._uncertain:
            raise RuntimeError("Guest lease outcome is uncertain; release or recheck it")
        claim = self._check_occupancy()
        try:
            return self._channel.operation(
                "input", actor="agent", action=action, **fields,
                lease_owner=claim["owner"], lease_generation=claim["generation"],
                lease_nonce=claim["nonce"])
        except Exception:
            if self._claim is not None:
                self._uncertain = True
            raise RuntimeError("Guest agent input failed") from None

    def wechat(self, action, *, project_id, config_digest):
        """Run the fixed read-only CLI query under this guest's held lease."""
        if action != "check-login":
            raise ValueError("Unsupported WeChat action")
        if not isinstance(project_id, str) or not _OWNER.fullmatch(project_id):
            raise ValueError("Invalid WeChat project")
        if not isinstance(config_digest, str) or not _SHA256.fullmatch(config_digest):
            raise ValueError("Invalid WeChat configuration digest")
        self._held()
        if self._uncertain:
            raise RuntimeError("Guest lease outcome is uncertain; release or recheck it")
        claim, state = self._check_occupancy(return_state=True)
        # _check_occupancy verifies the pinned VM identity, current mode and
        # claim; this state also binds the startup sidecar used by the guest.
        if state.get("desktop_ready") is not True:
            raise RuntimeError("Guest desktop is unavailable")
        actual = state.get("wechat_config_digest")
        if (not isinstance(actual, str) or not _SHA256.fullmatch(actual)
                or not hmac.compare_digest(actual, config_digest)):
            raise RuntimeError("Guest WeChat configuration mismatch")
        try:
            result = self._channel.operation(
                "wechat_cli", action="check-login", project_id=project_id,
                lease_owner=claim["owner"], lease_generation=claim["generation"],
                lease_nonce=claim["nonce"], config_digest=config_digest)
            if type(result) is not dict or set(result) != {"login"} or type(result["login"]) is not bool:
                raise ValueError("Invalid WeChat guest result")
            return result
        except Exception:
            if self._claim is not None:
                self._uncertain = True
            raise RuntimeError("Guest WeChat operation failed") from None
