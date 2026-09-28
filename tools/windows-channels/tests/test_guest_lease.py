"""Opt-in broker lease contract at the guest protocol boundary."""
from pathlib import Path
import sys
import threading
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parents[1]))
from guest import protocol

CHANNEL_TOKEN = "a" * 64
BROKER_TOKEN = "b" * 64
HUMAN_TOKEN = "c" * 64
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


if __name__ == "__main__":
    unittest.main(verbosity=2)
