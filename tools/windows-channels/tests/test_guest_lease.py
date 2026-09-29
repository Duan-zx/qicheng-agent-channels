"""Opt-in broker lease contract at the guest protocol boundary."""
from pathlib import Path
import sys
import threading
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parents[1]))
from guest import protocol
from guest.wechat_cli import TrustedWechatConfig

CHANNEL_TOKEN = "a" * 64
BROKER_TOKEN = "b" * 64
HUMAN_TOKEN = "c" * 64
CONFIG_DIGEST = "d" * 64
IDENTITY = {"bios_uuid": "11111111-2222-3333-4444-555555555555"}


class Backend:
    def __init__(self):
        self.ready = True
        self.fail = False
        self.actions = []
        self.entered = None
        self.continue_event = None

    def probe_ready(self):
        return self.ready, "ready" if self.ready else "desktop_unavailable"

    def dimensions(self):
        return 640, 480

    def perform(self, request):
        if self.entered:
            self.entered.set()
            self.continue_event.wait(3)
        if self.fail:
            raise OSError("private backend detail")
        self.actions.append(request)


class LeaseTests(unittest.TestCase):
    def setUp(self):
        self.backend = Backend()
        self.channel = protocol.GuestChannel(self.backend, IDENTITY,
                                              broker_token=BROKER_TOKEN,
                                              human_token=HUMAN_TOKEN)
        self.channel.control("agent")

    def call(self, op, token=BROKER_TOKEN, **fields):
        return protocol.dispatch({"id": "r1", "token": token, "op": op, **fields},
                                 CHANNEL_TOKEN, self.channel)

    def claim(self, owner="worker-a", ttl_seconds=30):
        result = self.call("lease_claim", owner=owner, ttl_seconds=ttl_seconds)
        self.assertTrue(result["ok"], result)
        return result["result"]

    def input(self, claim=None, **fields):
        lease = ({"lease_owner": claim["owner"],
                  "lease_generation": claim["generation"],
                  "lease_nonce": claim["nonce"]} if claim else {})
        return self.call("input", token=CHANNEL_TOKEN, actor="agent",
                         action="key", key="Return", **lease, **fields)

    def test_two_owners_conflict_and_old_claim_is_stale_after_release(self):
        first = self.claim()
        denied = self.call("lease_claim", owner="worker-b", ttl_seconds=30)
        self.assertEqual(denied["error"]["code"], "lease_unavailable")
        released = self.call("lease_release", owner=first["owner"],
                             generation=first["generation"], nonce=first["nonce"])
        self.assertTrue(released["ok"])
        self.assertEqual(self.channel.mode, "agent")
        second = self.claim("worker-b")
        self.assertGreater(second["generation"], first["generation"])
        self.assertEqual(self.input(first)["error"]["code"], "lease_required")
        self.assertEqual(self.call("lease_release", owner=first["owner"],
                                   generation=first["generation"],
                                   nonce=first["nonce"])["error"]["code"],
                         "lease_not_held")
        self.assertTrue(self.input(second)["ok"])

    def test_agent_claim_required_even_after_legacy_control_agent(self):
        self.assertTrue(self.call("control", token=HUMAN_TOKEN, mode="agent")["ok"])
        self.assertEqual(self.input()["error"]["code"], "lease_required")
        claim = self.claim()
        self.assertTrue(self.input(claim)["ok"])
        self.assertEqual(len(self.backend.actions), 1)
        self.assertNotIn("lease_nonce", self.backend.actions[0])
        self.assertNotIn("token", self.backend.actions[0])

    def test_public_state_shows_occupancy_without_claim_secret(self):
        claim = self.claim()
        state = self.call("state", token=CHANNEL_TOKEN)
        self.assertTrue(state["result"]["lease"]["active"])
        self.assertEqual(state["result"]["lease"]["owner"], claim["owner"])
        self.assertNotIn("nonce", state["result"]["lease"])

    def test_human_takeover_revokes_and_blocks_reclaim_until_paused(self):
        claim = self.claim()
        takeover = self.call("control", token=HUMAN_TOKEN, mode="human")
        self.assertEqual(takeover["result"]["mode"], "human")
        self.assertEqual(self.input(claim)["error"]["code"], "lease_required")
        self.assertEqual(self.call("lease_claim", owner="worker-b", ttl_seconds=30)
                         ["error"]["code"], "lease_unavailable")
        self.assertEqual(self.call("control", token=HUMAN_TOKEN, mode="agent")
                         ["error"]["code"], "control_blocked")
        self.call("control", token=HUMAN_TOKEN, mode="paused")
        self.assertEqual(self.call("lease_claim", owner="worker-b", ttl_seconds=30)
                         ["error"]["code"], "lease_unavailable")
        self.assertTrue(self.call("control", token=HUMAN_TOKEN, mode="agent")["ok"])
        self.assertTrue(self.claim("worker-b"))

    def test_claim_requires_explicit_agent_mode(self):
        self.call("control", token=HUMAN_TOKEN, mode="paused")
        self.assertEqual(self.call("lease_claim", owner="worker-a", ttl_seconds=30)
                         ["error"]["code"], "lease_unavailable")
        self.assertEqual(self.channel.mode, "paused")
        self.assertTrue(self.call("control", token=HUMAN_TOKEN, mode="agent")["ok"])
        self.assertTrue(self.claim())

    def test_expiry_and_operation_failure_revoke_lease(self):
        now = [100.0]
        with patch.object(protocol.time, "monotonic", side_effect=lambda: now[0]):
            old = self.claim(ttl_seconds=1)
            now[0] += 2
            self.assertEqual(self.input(old)["error"]["code"], "lease_required")
            self.assertEqual(self.channel.mode, "agent")
            fresh = self.claim()
            self.backend.fail = True
            failure = self.input(fresh)
            self.assertEqual(failure["error"]["code"], "desktop_operation_failed")
            self.assertNotIn("private backend detail", str(failure))
            self.assertFalse(self.call("lease_inspect")["result"]["active"])
            self.backend.fail = False
            self.assertEqual(self.call("lease_claim", owner="worker-a", ttl_seconds=30)
                             ["error"]["code"], "lease_unavailable")
            self.call("control", token=HUMAN_TOKEN, mode="agent")
            recovered = self.claim()
            self.assertGreater(recovered["generation"], fresh["generation"])

    def test_renew_extends_active_lease_without_revealing_nonce(self):
        now = [100.0]
        with patch.object(protocol.time, "monotonic", side_effect=lambda: now[0]):
            claim = self.claim(ttl_seconds=2)
            self.assertEqual(self.call("lease_renew", owner=claim["owner"],
                                       generation=claim["generation"], nonce="0" * 64,
                                       ttl_seconds=3)["error"]["code"], "lease_not_held")
            now[0] += 1
            renewed = self.call("lease_renew", owner=claim["owner"],
                                generation=claim["generation"], nonce=claim["nonce"],
                                ttl_seconds=3)
            self.assertTrue(renewed["ok"])
            self.assertNotIn("nonce", renewed["result"])
            now[0] += 2
            self.assertTrue(self.input(claim)["ok"])
            now[0] += 2
            self.assertEqual(self.call("lease_renew", owner=claim["owner"],
                                       generation=claim["generation"], nonce=claim["nonce"],
                                       ttl_seconds=3)["error"]["code"], "lease_not_held")
            self.assertEqual(self.call("lease_renew", owner=claim["owner"],
                                       generation=claim["generation"], nonce="0" * 64,
                                       ttl_seconds=3)["error"]["code"], "lease_not_held")
            self.assertTrue(self.claim("worker-b"))

    def test_renew_rejects_unready_desktop_and_revokes(self):
        claim = self.claim()
        self.backend.ready = False
        denied = self.call("lease_renew", owner=claim["owner"],
                           generation=claim["generation"], nonce=claim["nonce"],
                           ttl_seconds=30)
        self.assertEqual(denied["error"]["code"], "lease_unavailable")
        self.assertFalse(self.call("lease_inspect")["result"]["active"])
        self.assertEqual(self.channel.mode, "paused")

    def test_wrong_credentials_and_fixed_fields(self):
        self.assertEqual(self.call("lease_inspect", token=CHANNEL_TOKEN)
                         ["error"]["code"], "authentication_failed")
        self.assertEqual(self.call("lease_inspect", token=HUMAN_TOKEN)
                         ["error"]["code"], "authentication_failed")
        self.assertEqual(self.call("state", token=BROKER_TOKEN)
                         ["error"]["code"], "authentication_failed")
        self.assertEqual(self.call("state", token=HUMAN_TOKEN)
                         ["error"]["code"], "authentication_failed")
        for token in (CHANNEL_TOKEN, BROKER_TOKEN):
            self.assertEqual(self.call("control", token=token, mode="human")
                             ["error"]["code"], "authentication_failed")
            self.assertEqual(self.call("input", token=token, actor="human",
                                       action="key", key="Return")["error"]["code"],
                             "authentication_failed")
        claim = self.claim()
        self.assertEqual(self.call("input", token=HUMAN_TOKEN, actor="agent",
                                   action="key", key="Return", lease_owner=claim["owner"],
                                   lease_generation=claim["generation"],
                                   lease_nonce=claim["nonce"])["error"]["code"],
                         "authentication_failed")
        self.assertEqual(self.call("lease_claim", owner="x", ttl_seconds=True)
                         ["error"]["code"], "invalid_lease")
        self.assertEqual(self.call("lease_claim", owner="x", ttl_seconds=301)
                         ["error"]["code"], "invalid_lease")
        self.assertEqual(self.call("lease_claim", owner="x", ttl_seconds=30,
                                   command="whoami")["error"]["code"], "invalid_lease")

    def test_human_token_controls_and_inputs(self):
        self.assertTrue(self.call("control", token=HUMAN_TOKEN, mode="human")["ok"])
        result = self.call("input", token=HUMAN_TOKEN, actor="human",
                           action="key", key="Return")
        self.assertTrue(result["ok"])
        self.assertEqual(len(self.backend.actions), 1)

    def test_token_configuration_requires_three_distinct_credentials(self):
        with self.assertRaises(ValueError):
            protocol.GuestChannel(self.backend, IDENTITY, broker_token=BROKER_TOKEN)
        with self.assertRaises(ValueError):
            protocol.GuestChannel(self.backend, IDENTITY, broker_token=BROKER_TOKEN,
                                  human_token=BROKER_TOKEN)
        with self.assertRaises(ValueError):
            protocol.GuestChannel(self.backend, IDENTITY, human_token=HUMAN_TOKEN)

    def test_input_probe_crossing_deadline_blocks_perform(self):
        now = [100.0]
        with patch.object(protocol.time, "monotonic", side_effect=lambda: now[0]):
            claim = self.claim(ttl_seconds=1)
            def slow_probe():
                now[0] = 102.0
                return True, "ready"
            self.backend.probe_ready = slow_probe
            request = {"id": "race", "token": CHANNEL_TOKEN, "op": "input",
                       "actor": "agent", "action": "key", "key": "Return",
                       "lease_owner": claim["owner"],
                       "lease_generation": claim["generation"],
                       "lease_nonce": claim["nonce"]}
            with self.assertRaises(protocol.RequestError) as caught:
                self.channel.input(request)
            self.assertEqual(caught.exception.code, "lease_required")
            self.assertEqual(self.backend.actions, [])

    def test_renew_probe_crossing_deadline_cannot_resurrect(self):
        now = [100.0]
        with patch.object(protocol.time, "monotonic", side_effect=lambda: now[0]):
            claim = self.claim(ttl_seconds=1)
            def slow_probe():
                now[0] = 102.0
                return True, "ready"
            self.backend.probe_ready = slow_probe
            with self.assertRaises(protocol.RequestError) as caught:
                self.channel.lease_renew(claim["owner"], claim["generation"],
                                         claim["nonce"], 30)
            self.assertEqual(caught.exception.code, "lease_not_held")
            self.assertFalse(self.channel.lease_inspect()["active"])

    def test_release_waits_for_in_flight_input(self):
        claim = self.claim()
        self.backend.entered = threading.Event()
        self.backend.continue_event = threading.Event()
        results = {}
        input_thread = threading.Thread(target=lambda: results.setdefault("input", self.input(claim)))
        release_thread = threading.Thread(target=lambda: results.setdefault(
            "release", self.call("lease_release", owner=claim["owner"],
                                 generation=claim["generation"], nonce=claim["nonce"])))
        input_thread.start()
        self.assertTrue(self.backend.entered.wait(1))
        release_thread.start()
        time.sleep(0.05)
        self.assertTrue(release_thread.is_alive())
        self.backend.continue_event.set()
        input_thread.join(2)
        release_thread.join(2)
        self.assertTrue(results["input"]["ok"])
        self.assertTrue(results["release"]["ok"])
        self.assertEqual(self.channel.mode, "agent")

    def test_legacy_channel_without_broker_keeps_old_agent_flow(self):
        channel = protocol.GuestChannel(self.backend, IDENTITY)
        def old(op, **fields):
            return protocol.dispatch({"id": "old", "token": CHANNEL_TOKEN,
                                      "op": op, **fields}, CHANNEL_TOKEN, channel)
        self.assertTrue(old("control", mode="agent")["ok"])
        self.assertTrue(old("input", actor="agent", action="key", key="Return")["ok"])
        self.assertTrue(old("control", mode="human")["ok"])
        self.assertTrue(old("input", actor="human", action="key", key="Return")["ok"])
        self.assertEqual(old("lease_inspect")["error"]["code"], "authentication_failed")


class WechatLeaseTests(unittest.TestCase):
    def setUp(self):
        self.backend = Backend()
        self.calls = []
        self.config = TrustedWechatConfig("project-a", r"C:\work\mini", r"C:\cli\cli.bat", 9420)
        def check(config, request):
            self.calls.append((config, request))
            return {"ok": True, "result": {"login": False}}
        self.channel = protocol.GuestChannel(
            self.backend, IDENTITY, broker_token=BROKER_TOKEN,
            human_token=HUMAN_TOKEN, wechat_config=self.config,
            wechat_config_digest=CONFIG_DIGEST,
            wechat_check_login=check)
        self.channel.control("agent")

    def call(self, token=CHANNEL_TOKEN, **fields):
        request = {"id": "wc1", "token": token, "op": "wechat_cli",
                   "action": "check-login", "project_id": "project-a",
                   "config_digest": CONFIG_DIGEST}
        request.update(fields)
        return protocol.dispatch(request, CHANNEL_TOKEN, self.channel)

    def claim(self):
        result = protocol.dispatch({"id": "l1", "token": BROKER_TOKEN,
                                    "op": "lease_claim", "owner": "owner-a",
                                    "ttl_seconds": 30}, CHANNEL_TOKEN, self.channel)
        self.assertTrue(result["ok"], result)
        lease = result["result"]
        return {"lease_owner": lease["owner"],
                "lease_generation": lease["generation"],
                "lease_nonce": lease["nonce"]}

    def test_only_channel_token_with_exact_current_lease_starts_cli(self):
        lease = self.claim()
        for token in (BROKER_TOKEN, HUMAN_TOKEN, "d" * 64):
            self.assertEqual(self.call(token, **lease)["error"]["code"],
                             "authentication_failed")
        self.assertEqual(self.calls, [])
        response = self.call(**lease)
        self.assertEqual(response["result"], {"login": False})
        self.assertEqual(self.calls, [(self.config, {"project_id": "project-a",
                                               "action": "check-login"})])
        self.assertEqual(self.channel.state()["wechat_config_digest"], CONFIG_DIGEST)

    def test_missing_invalid_or_changed_digest_never_starts_cli(self):
        lease = self.claim()
        for bad_digest in (None, "D" * 64, "x" * 64, "0" * 64, [], True):
            response = self.call(**lease, config_digest=bad_digest)
            self.assertFalse(response["ok"])
            self.assertIn(response["error"]["code"],
                          {"invalid_config_digest", "config_mismatch"})
        request = {"id": "missing", "token": CHANNEL_TOKEN, "op": "wechat_cli",
                   "action": "check-login", "project_id": "project-a", **lease}
        response = protocol.dispatch(request, CHANNEL_TOKEN, self.channel)
        self.assertEqual(response["error"]["code"], "unexpected_field")
        self.assertEqual(self.calls, [])

    def test_missing_wrong_and_expired_lease_never_start_cli(self):
        self.assertEqual(self.call()["error"]["code"], "unexpected_field")
        lease = self.claim()
        for altered in ({**lease, "lease_owner": "other"},
                        {**lease, "lease_generation": lease["lease_generation"] + 1},
                        {**lease, "lease_nonce": "0" * 64}):
            self.assertEqual(self.call(**altered)["error"]["code"], "lease_required")
        self.channel._lease_deadline = 0
        self.assertEqual(self.call(**lease)["error"]["code"], "lease_required")
        self.assertEqual(self.calls, [])

    def test_mode_desktop_and_request_shape_gate_cli(self):
        lease = self.claim()
        for extra in ({"argv": ["open"]}, {"path": r"C:\other"},
                      {"port": 1}, {"account": "secret"}):
            self.assertEqual(self.call(**lease, **extra)["error"]["code"],
                             "unexpected_field")
        self.assertEqual(self.call(**lease, action="open")["error"]["code"],
                         "unsupported_action")
        self.assertEqual(self.call(**lease, project_id="other")["error"]["code"],
                         "invalid_project")
        self.backend.ready = False
        self.assertFalse(self.call(**lease)["ok"])
        self.assertEqual(self.channel.mode, "paused")
        self.assertEqual(self.calls, [])
        self.backend.ready = True
        self.channel.control("human")
        self.assertEqual(self.call(**lease)["error"]["code"], "input_disabled")
        self.channel.control("paused")
        self.assertEqual(self.call(**lease)["error"]["code"], "input_disabled")
        self.assertEqual(self.calls, [])

    def test_cli_failure_and_exception_are_fixed_and_private(self):
        lease = self.claim()
        for output, code in [
            ({"ok": False, "error": {"code": "cli_reported_error",
                                      "raw": "account-secret"}}, "cli_reported_error"),
            ({"ok": False, "error": {"code": "unknown", "raw": "account-secret"}},
             "cli_failed"),
            ({"ok": False, "error": {"code": [], "raw": "account-secret"}},
             "cli_failed"),
            ({"ok": False, "error": {"code": {"secret": "account-secret"}}},
             "cli_failed"),
            ({"ok": True, "result": {"login": "account-secret"}}, "cli_failed")]:
            self.channel._wechat_check_login = lambda *_: output
            response = self.call(**lease)
            self.assertEqual(response["error"]["code"], code)
            self.assertNotIn("account-secret", str(response))
        def explode(*_):
            raise OSError("account-secret")
        self.channel._wechat_check_login = explode
        response = self.call(**lease)
        self.assertEqual(response["error"]["code"], "cli_failed")
        self.assertNotIn("account-secret", str(response))

    def test_unconfigured_and_legacy_channels_keep_cli_closed(self):
        broker = protocol.GuestChannel(self.backend, IDENTITY,
                                       broker_token=BROKER_TOKEN,
                                       human_token=HUMAN_TOKEN)
        broker.control("agent")
        denied = protocol.dispatch({"id": "x", "token": CHANNEL_TOKEN,
                                    "op": "wechat_cli", "action": "check-login",
                                    "project_id": "project-a", "config_digest": CONFIG_DIGEST,
                                    "lease_owner": "owner-a",
                                    "lease_generation": 1, "lease_nonce": "0" * 64},
                                   CHANNEL_TOKEN, broker)
        self.assertEqual(denied["error"]["code"], "wechat_unavailable")
        with self.assertRaises(ValueError):
            protocol.GuestChannel(self.backend, IDENTITY, wechat_config=self.config)

    def test_human_takeover_waits_for_in_flight_cli_then_revokes(self):
        lease = self.claim()
        entered, release = threading.Event(), threading.Event()
        def running(*_):
            entered.set()
            release.wait(2)
            return {"ok": True, "result": {"login": True}}
        self.channel._wechat_check_login = running
        results = {}
        operation = threading.Thread(target=lambda: results.setdefault("cli", self.call(**lease)))
        takeover = threading.Thread(target=lambda: results.setdefault(
            "control", protocol.dispatch({"id": "h1", "token": HUMAN_TOKEN,
                                           "op": "control", "mode": "human"},
                                          CHANNEL_TOKEN, self.channel)))
        operation.start()
        self.assertTrue(entered.wait(1))
        takeover.start()
        time.sleep(0.05)
        self.assertTrue(takeover.is_alive())
        release.set()
        operation.join(2)
        takeover.join(2)
        self.assertEqual(results["cli"]["result"], {"login": True})
        self.assertEqual(results["control"]["result"]["mode"], "human")
        self.assertEqual(self.call(**lease)["error"]["code"], "input_disabled")

    def test_cli_completion_after_one_second_lease_does_not_report_login(self):
        claimed = protocol.dispatch({"id": "short", "token": BROKER_TOKEN,
                                     "op": "lease_claim", "owner": "short-owner",
                                     "ttl_seconds": 1}, CHANNEL_TOKEN, self.channel)
        self.assertTrue(claimed["ok"], claimed)
        value = claimed["result"]
        self.channel._wechat_check_login = lambda *_: (
            time.sleep(1.2) or {"ok": True, "result": {"login": True}})
        response = self.call(lease_owner=value["owner"],
                             lease_generation=value["generation"],
                             lease_nonce=value["nonce"])
        self.assertFalse(response["ok"])
        self.assertEqual(response["error"]["code"], "lease_required")
        self.assertNotIn("login", str(response))
        self.assertFalse(self.channel.lease_inspect()["active"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
