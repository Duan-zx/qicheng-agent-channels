"""Hyper-V transport and credential separation for the host lease adapter."""

import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from host.lease_client import LeaseClient
from host.client import SERVICE_ID


VM = "ca6d2942-6d2c-4050-9ba5-b9bca1754b28"
BIOS = "5a73f8d6-cf5b-41c2-a423-989a8772a9cb"
CHANNEL = "a" * 64
BROKER = "b" * 64
NONCE = "c" * 64
DIGEST = "d" * 64


class Socket:
    def __init__(self, transport):
        self.transport = transport
        self.buffer = b""

    def __enter__(self):
        return self

    def __exit__(self, *args):
        pass

    def settimeout(self, value):
        self.timeout = value

    def connect(self, endpoint):
        self.transport.endpoints.append(endpoint)

    def sendall(self, frame):
        size = struct.unpack("!I", frame[:4])[0]
        request = json.loads(frame[4:])
        assert size == len(frame) - 4
        self.transport.requests.append(request)
        response = self.transport.answer(request)
        encoded = json.dumps(dict(id=request["id"], ok=True, result=response)).encode()
        self.buffer = struct.pack("!I", len(encoded)) + encoded

    def recv(self, size):
        chunk, self.buffer = self.buffer[:size], self.buffer[size:]
        return chunk


class Transport:
    def __init__(self):
        self.requests = []
        self.endpoints = []
        self.mode = "agent"
        self.bios = BIOS
        self.enabled = True
        self.claim = None
        self.generation = 0
        self.answer_override = None
        self.digest = DIGEST
        self.desktop_ready = True
        self.login = True

    def __call__(self, *args):
        return Socket(self)

    def lease(self):
        return dict(enabled=self.enabled, active=self.claim is not None,
                    owner=self.claim["owner"] if self.claim else None,
                    generation=self.claim["generation"] if self.claim else None,
                    expires_in_seconds=20.0 if self.claim else None)

    def answer(self, request):
        if self.answer_override is not None:
            override = self.answer_override(request)
            if override is not None:
                return override
        op = request["op"]
        if op in {"state", "input", "wechat_cli"}:
            assert request["token"] == CHANNEL
        else:
            assert request["token"] == BROKER
        if op == "state":
            return dict(identity=dict(bios_uuid=self.bios), mode=self.mode,
                        lease=self.lease(), input_target="private-windows-guest",
                        host_input_supported=False, desktop_ready=self.desktop_ready,
                        wechat_config_digest=self.digest)
        if op == "lease_claim":
            self.generation += 1
            self.claim = dict(owner=request["owner"], generation=self.generation,
                              nonce=NONCE)
            return dict(self.claim, expires_in_seconds=request["ttl_seconds"])
        if op == "lease_inspect":
            return self.lease()
        if op == "lease_renew":
            return dict(self.lease(), expires_in_seconds=request["ttl_seconds"])
        if op == "lease_release":
            self.claim = None
            return self.lease()
        if op == "input":
            return {"actions": 1}
        if op == "wechat_cli":
            return {"login": self.login}
        raise AssertionError("Unexpected operation")


class HostLeaseTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.channel_path = self.root / "channel.token"
        self.broker_path = self.root / "broker.token"
        self.channel_path.write_text(CHANNEL)
        self.broker_path.write_text(BROKER)
        self.binding = dict(vm_id=VM, bios_uuid=BIOS, token_file=self.channel_path)
        self.transport = Transport()
        self.hyperv = patch.multiple("host.client.socket", AF_HYPERV=34,
                                    HV_PROTOCOL_RAW=1, create=True)
        self.hyperv.start()

    def tearDown(self):
        self.hyperv.stop()
        self.tmp.cleanup()

    def client(self):
        return LeaseClient(self.binding, self.broker_path, self.transport)

    def test_uses_separate_tokens_on_same_guest_and_exact_request_fields(self):
        client = self.client()
        claim = client.claim("worker-a", 30)
        self.assertEqual(claim, dict(owner="worker-a", generation=1,
                                     nonce=NONCE, expires_in_seconds=30))
        self.assertEqual(client.input("key", key="ENTER"), {"actions": 1})
        client.renew(25)
        client.inspect()
        client.release()
        self.assertEqual([r["op"] for r in self.transport.requests],
                         ["state", "lease_claim", "state", "state", "input",
                          "state", "lease_renew", "lease_inspect", "lease_release"])
        for request in self.transport.requests:
            self.assertEqual(request["token"], CHANNEL if request["op"] in {"state", "input"} else BROKER)
        self.assertEqual({k: v for k, v in self.transport.requests[1].items()
                          if k not in {"id", "token", "op"}},
                         dict(owner="worker-a", ttl_seconds=30))
        self.assertEqual({k: v for k, v in self.transport.requests[4].items()
                          if k not in {"id", "token", "op"}},
                         dict(actor="agent", action="key", key="Return",
                              lease_owner="worker-a", lease_generation=1,
                              lease_nonce=NONCE))
        self.assertEqual({k: v for k, v in self.transport.requests[6].items()
                          if k not in {"id", "token", "op"}},
                         dict(owner="worker-a", generation=1, nonce=NONCE,
                              ttl_seconds=25))
        self.assertEqual({k: v for k, v in self.transport.requests[8].items()
                          if k not in {"id", "token", "op"}},
                         dict(owner="worker-a", generation=1, nonce=NONCE))
        self.assertTrue(all(endpoint == (VM, SERVICE_ID) for endpoint in self.transport.endpoints))
        with self.assertRaisesRegex(RuntimeError, "No guest lease"):
            client.input("key", key="Return")

    def test_token_files_and_values_must_be_distinct(self):
        with self.assertRaisesRegex(ValueError, "files must differ"):
            LeaseClient(self.binding, self.channel_path, self.transport)
        self.broker_path.write_text(CHANNEL)
        with self.assertRaisesRegex(ValueError, "values must differ"):
            self.client()
        self.assertEqual(self.transport.requests, [])

    def test_identity_mode_and_disabled_lease_refuse_claim(self):
        for field, value in (("bios", VM), ("mode", "human"), ("enabled", False)):
            with self.subTest(field=field):
                setattr(self.transport, field, value)
                with self.assertRaises(RuntimeError):
                    self.client().claim("worker-a", 30)
                self.assertEqual(self.transport.requests[-1]["op"], "state")
                self.assertFalse(any(r["op"] == "lease_claim" for r in self.transport.requests))
                setattr(self.transport, field, {"bios": BIOS, "mode": "agent",
                                                "enabled": True}[field])

    def test_rejects_invalid_owner_ttl_and_claim_shape(self):
        for owner, ttl in (("bad owner", 30), ("worker-a", True), ("worker-a", 301)):
            with self.subTest(owner=owner, ttl=ttl), self.assertRaises(ValueError):
                self.client().claim(owner, ttl)
        self.assertEqual(self.transport.requests, [])
        self.transport.answer_override = lambda request: (dict(owner="other", generation=1,
            nonce=NONCE, expires_in_seconds=30) if request["op"] == "lease_claim" else None)
        client = self.client()
        with self.assertRaisesRegex(RuntimeError, "invalid lease claim"):
            client.claim("worker-a", 30)
        with self.assertRaisesRegex(RuntimeError, "No guest lease"):
            client.input("key", key="Return")

    def test_rejects_invalid_generation_or_nonce_from_claim(self):
        for changed in ({"generation": True}, {"nonce": "not-a-nonce"},
                        {"expires_in_seconds": 31}):
            with self.subTest(changed=changed):
                self.transport.answer_override = lambda request: (
                    (dict(owner="worker-a", generation=1, nonce=NONCE,
                          expires_in_seconds=30) | changed)
                    if request["op"] == "lease_claim" else None)
                with self.assertRaisesRegex(RuntimeError, "invalid lease claim"):
                    self.client().claim("worker-a", 30)

    def test_renew_requires_exact_owner_generation_echo(self):
        client = self.client()
        client.claim("worker-a", 30)
        self.transport.answer_override = lambda request: (
            dict(enabled=True, active=True, owner="worker-b", generation=1,
                 expires_in_seconds=25.0)
            if request["op"] == "lease_renew" else None)
        with self.assertRaisesRegex(RuntimeError, "invalid lease renewal"):
            client.renew(25)
        with self.assertRaisesRegex(RuntimeError, "uncertain"):
            client.input("key", key="Return")
        self.assertEqual(client.release()["active"], False)

    def test_lost_input_response_keeps_claim_for_release_and_blocks_repeat(self):
        client = self.client()
        client.claim("worker-a", 30)
        def lose_input(request):
            if request["op"] == "input":
                raise OSError("input response lost " + NONCE)
            return None
        self.transport.answer_override = lose_input
        with self.assertRaises(RuntimeError) as raised:
            client.input("key", key="Return")
        self.assertNotIn(NONCE, str(raised.exception))
        count = len(self.transport.requests)
        with self.assertRaisesRegex(RuntimeError, "uncertain"):
            client.input("key", key="Return")
        self.assertEqual(len(self.transport.requests), count)
        self.transport.answer_override = None
        self.assertFalse(client.release()["active"])
        with self.assertRaisesRegex(RuntimeError, "No guest lease"):
            client.input("key", key="Return")

    def test_release_failure_keeps_claim_and_retry_can_release(self):
        client = self.client()
        client.claim("worker-a", 30)
        def lose_release(request):
            if request["op"] == "lease_release":
                raise OSError("release response lost " + BROKER)
            return None
        self.transport.answer_override = lose_release
        with self.assertRaises(RuntimeError) as raised:
            client.release()
        self.assertNotIn(BROKER, str(raised.exception))
        with self.assertRaisesRegex(RuntimeError, "uncertain"):
            client.input("key", key="Return")
        self.transport.answer_override = None
        self.assertFalse(client.release()["active"])

    def test_invalid_release_response_keeps_claim_for_retry(self):
        client = self.client()
        client.claim("worker-a", 30)
        self.transport.answer_override = lambda request: (
            dict(enabled=True, active=True, owner="worker-a", generation=1,
                 expires_in_seconds=20.0)
            if request["op"] == "lease_release" else None)
        with self.assertRaisesRegex(RuntimeError, "invalid lease release"):
            client.release()
        with self.assertRaisesRegex(RuntimeError, "uncertain"):
            client.input("key", key="Return")
        self.transport.answer_override = None
        self.assertFalse(client.release()["active"])

    def test_renew_response_loss_preserves_claim_for_release(self):
        client = self.client()
        client.claim("worker-a", 30)
        def lose_renew(request):
            if request["op"] == "lease_renew":
                raise OSError("renew response lost")
            return None
        self.transport.answer_override = lose_renew
        with self.assertRaisesRegex(RuntimeError, "Guest lease operation failed"):
            client.renew(25)
        with self.assertRaisesRegex(RuntimeError, "uncertain"):
            client.input("key", key="Return")
        self.transport.answer_override = None
        client.renew(25)
        with self.assertRaisesRegex(RuntimeError, "uncertain"):
            client.input("key", key="Return")
        self.assertFalse(client.release()["active"])

    def test_state_observed_revocation_clears_uncertain_claim(self):
        client = self.client()
        client.claim("worker-a", 30)
        self.transport.answer_override = lambda request: (_ for _ in ()).throw(OSError("lost")) if request["op"] == "input" else None
        with self.assertRaises(RuntimeError):
            client.input("key", key="Return")
        self.transport.answer_override = None
        self.transport.claim = None
        self.assertFalse(client.state()["lease"]["active"])
        with self.assertRaisesRegex(RuntimeError, "No guest lease"):
            client.release()

    def test_stale_occupancy_and_human_takeover_stop_input(self):
        client = self.client()
        client.claim("worker-a", 30)
        self.transport.generation = 2
        self.transport.claim["generation"] = 2
        with self.assertRaisesRegex(RuntimeError, "no longer held"):
            client.input("key", key="Return")
        self.assertNotIn("input", [r["op"] for r in self.transport.requests])
        self.transport.claim = None
        client = self.client()
        client.claim("worker-a", 30)
        self.transport.mode = "human"
        self.transport.claim = None
        with self.assertRaisesRegex(RuntimeError, "no longer held"):
            client.input("key", key="Return")
        self.assertNotIn("input", [r["op"] for r in self.transport.requests])

    def test_no_arbitrary_operation_or_host_fallback(self):
        client = self.client()
        with self.assertRaisesRegex(RuntimeError, "No guest lease"):
            client.input("key", key="Return")
        with self.assertRaises(ValueError):
            client.input("key", key="Return", lease_nonce=NONCE)
        self.assertFalse(hasattr(client, "operation"))
        self.assertFalse(hasattr(client, "exchange"))
        self.assertEqual(self.transport.requests, [])

    def test_wechat_wire_request_and_both_boolean_results(self):
        client = self.client()
        client.claim("worker-a", 30)
        for value in (True, False):
            self.transport.login = value
            self.assertEqual(client.wechat("check-login", project_id="qicheng",
                                           config_digest=DIGEST), {"login": value})
        sent = [r for r in self.transport.requests if r["op"] == "wechat_cli"]
        self.assertEqual(len(sent), 2)
        for request in sent:
            self.assertEqual({k: v for k, v in request.items() if k not in {"id", "token", "op"}},
                             dict(action="check-login", project_id="qicheng",
                                  lease_owner="worker-a", lease_generation=1,
                                  lease_nonce=NONCE, config_digest=DIGEST))
            self.assertEqual(request["token"], CHANNEL)
        self.assertTrue(all(endpoint == (VM, SERVICE_ID) for endpoint in self.transport.endpoints))

    def test_wechat_refuses_missing_legacy_digest_wrong_vm_and_config(self):
        for name, value in (("digest", None), ("digest", "e" * 64),
                            ("bios", VM), ("desktop_ready", False)):
            with self.subTest(name=name, value=value):
                transport = Transport()
                client = LeaseClient(self.binding, self.broker_path, transport)
                client.claim("worker-a", 30)
                setattr(transport, name, value)
                with self.assertRaises(RuntimeError):
                    client.wechat("check-login", project_id="qicheng",
                                  config_digest=DIGEST)
                self.assertNotIn("wechat_cli", [r["op"] for r in transport.requests])

    def test_wechat_refuses_lost_lease_and_human_takeover(self):
        for changed in ("owner", "generation", "human"):
            with self.subTest(changed=changed):
                transport = Transport()
                client = LeaseClient(self.binding, self.broker_path, transport)
                client.claim("worker-a", 30)
                if changed == "human":
                    transport.mode = "human"
                    transport.claim = None
                else:
                    transport.claim[changed] = "other" if changed == "owner" else 2
                with self.assertRaisesRegex(RuntimeError, "no longer held"):
                    client.wechat("check-login", project_id="qicheng",
                                  config_digest=DIGEST)
                self.assertNotIn("wechat_cli", [r["op"] for r in transport.requests])

    def test_wechat_validates_fixed_parameters_before_wire(self):
        client = self.client()
        client.claim("worker-a", 30)
        for action, project, digest in (("open", "qicheng", DIGEST),
                                        ("check-login", "other project", DIGEST),
                                        ("check-login", "qicheng", "D" * 64)):
            with self.assertRaises(ValueError):
                client.wechat(action, project_id=project, config_digest=digest)
        self.assertNotIn("wechat_cli", [r["op"] for r in self.transport.requests])

    def test_wechat_bad_result_or_lost_response_blocks_reuse(self):
        for result in ({"login": 1}, {"login": "true"}, {"login": True, "extra": 1},
                       {}, OSError("lost response " + NONCE)):
            with self.subTest(result=result):
                transport = Transport()
                client = LeaseClient(self.binding, self.broker_path, transport)
                client.claim("worker-a", 30)
                def answer(request):
                    if request["op"] == "wechat_cli":
                        if isinstance(result, Exception):
                            raise result
                        return result
                    return None
                transport.answer_override = answer
                with self.assertRaisesRegex(RuntimeError, "WeChat operation failed") as raised:
                    client.wechat("check-login", project_id="qicheng",
                                  config_digest=DIGEST)
                self.assertNotIn(NONCE, str(raised.exception))
                count = len(transport.requests)
                with self.assertRaisesRegex(RuntimeError, "uncertain"):
                    client.wechat("check-login", project_id="qicheng",
                                  config_digest=DIGEST)
                self.assertEqual(len(transport.requests), count)
                transport.answer_override = None
                self.assertFalse(client.release()["active"])

    def test_transport_error_does_not_echo_credentials(self):
        class FailingSocket(Socket):
            def connect(self, endpoint):
                raise OSError("secret " + BROKER + CHANNEL)
        client = LeaseClient(self.binding, self.broker_path,
                             lambda *args: FailingSocket(self.transport))
        with self.assertRaises(RuntimeError) as raised:
            client.claim("worker-a", 30)
        self.assertNotIn(BROKER, str(raised.exception))
        self.assertNotIn(CHANNEL, str(raised.exception))


if __name__ == "__main__":
    unittest.main()
