import json
from pathlib import Path
import tempfile
import unittest

import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from guest import protocol
from host.client import GuestClient, SERVICE_ID


TOKEN = "a" * 64
VM_ID = "ca6d2942-6d2c-4050-9ba5-b9bca1754b28"
BIOS_ID = "5a73f8d6-cf5b-41c2-a423-989a8772a9cb"
OTHER_BIOS_ID = "11111111-2222-3333-4444-555555555555"


class FakeDesktop:
    def __init__(self):
        self.probe_calls = 0
        self.dimension_calls = 0
        self.actions = []

    def probe_ready(self):
        self.probe_calls += 1
        return True, "ready"

    def dimensions(self):
        self.dimension_calls += 1
        return 1280, 800

    def perform(self, request):
        self.actions.append({key: request[key] for key in ("actor", "action", "key")})


class FrameInput:
    """Partial reads exercise the guest's actual length-prefixed decoder."""
    def __init__(self, data):
        self.data = bytearray(data)

    def recv(self, count):
        size = min(count, 5, len(self.data))
        result = bytes(self.data[:size])
        del self.data[:size]
        return result


class LoopbackStream:
    def __init__(self, harness, socket_args):
        self.harness = harness
        self.socket_args = socket_args
        self.response = bytearray()
        self.connected = None
        self.timeout = None

    def __enter__(self):
        return self

    def __exit__(self, *_):
        return False

    def settimeout(self, value):
        self.timeout = value

    def connect(self, endpoint):
        self.connected = endpoint

    def sendall(self, frame):
        request = protocol.receive_request(FrameInput(frame))
        response = protocol.dispatch(request, self.harness.expected_token, self.harness.channel)
        self.harness.requests.append(request)
        self.harness.responses.append(response)
        self.response.extend(protocol.encode_response(response))

    def recv(self, count):
        size = min(count, 7, len(self.response))
        result = bytes(self.response[:size])
        del self.response[:size]
        return result


class ContractHarness:
    def __init__(self, identity_bios=BIOS_ID):
        self.expected_token = TOKEN
        self.desktop = FakeDesktop()
        identity = {
            "bios_uuid": identity_bios,
            "model": "Virtual Machine",
            "manufacturer": "Microsoft Corporation",
        }
        self.channel = protocol.GuestChannel(self.desktop, identity)
        self.requests = []
        self.responses = []
        self.streams = []

    def factory(self, *socket_args):
        stream = LoopbackStream(self, socket_args)
        self.streams.append(stream)
        return stream


class HostGuestContractTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)

    def tearDown(self):
        self.temporary.cleanup()

    def client(self, harness, token=TOKEN):
        token_file = self.root / ("token-" + token[0])
        token_file.write_text(token, encoding="ascii")
        binding = {"vm_id": VM_ID, "bios_uuid": BIOS_ID, "token_file": token_file}
        return GuestClient(binding, harness.factory)

    def test_identity_state_allow_input_takeover_and_pause_contract(self):
        harness = ContractHarness()
        client = self.client(harness)

        initial = client.state()
        self.assertEqual(initial["identity"]["bios_uuid"], BIOS_ID)
        self.assertEqual(initial["mode"], "paused")
        self.assertEqual(initial["input_target"], "private-windows-guest")
        self.assertFalse(initial["host_input_supported"])

        allowed = client.operation("control", mode="agent")
        self.assertEqual(allowed["mode"], "agent")

        after_input = client.operation("input", actor="agent", action="key", key="Return")
        self.assertEqual(after_input["mode"], "agent")
        self.assertEqual(after_input["actions"], 1)
        self.assertEqual(harness.desktop.actions,
                         [{"actor": "agent", "action": "key", "key": "Return"}])

        takeover = client.operation("control", mode="human")
        self.assertEqual(takeover["mode"], "human")
        with self.assertRaisesRegex(RuntimeError, "Human takeover retained"):
            client.operation("control", mode="agent")
        self.assertEqual(harness.channel.mode, "human")

        paused = client.operation("control", mode="paused")
        self.assertEqual(paused["mode"], "paused")
        with self.assertRaisesRegex(RuntimeError, "Input is paused"):
            client.operation("input", actor="agent", action="key", key="Return")
        self.assertEqual(harness.desktop.actions,
                         [{"actor": "agent", "action": "key", "key": "Return"}])

        self.assertEqual([request["id"] for request in harness.requests],
                         [str(value) for value in range(1, 12)])
        self.assertTrue(all(request["token"] == TOKEN for request in harness.requests))
        self.assertTrue(all(stream.connected == (VM_ID, SERVICE_ID)
                            for stream in harness.streams))
        self.assertTrue(all(response["id"] == request["id"]
                            for request, response in zip(harness.requests, harness.responses)))
        self.assertEqual([request["op"] for request in harness.requests], [
            "state", "state", "control", "state", "input", "state", "control",
            "state", "state", "control", "state",
        ])

    def test_guest_identity_mismatch_blocks_before_control_dispatch(self):
        harness = ContractHarness(identity_bios=OTHER_BIOS_ID)
        client = self.client(harness)

        with self.assertRaisesRegex(RuntimeError, "Guest identity mismatch"):
            client.operation("control", mode="agent")

        self.assertEqual([request["op"] for request in harness.requests], ["state"])
        self.assertEqual(harness.channel.mode, "paused")
        self.assertEqual(harness.desktop.actions, [])

    def test_token_mismatch_is_rejected_before_guest_state_or_desktop_probe(self):
        harness = ContractHarness()
        client = self.client(harness, token="b" * 64)

        with self.assertRaisesRegex(RuntimeError, "Guest rejected the operation"):
            client.state()

        self.assertEqual([request["op"] for request in harness.requests], ["state"])
        self.assertEqual(harness.responses[0]["error"]["code"], "authentication_failed")
        self.assertEqual(harness.responses[0]["id"], harness.requests[0]["id"])
        self.assertEqual(harness.desktop.probe_calls, 0)
        self.assertEqual(harness.desktop.dimension_calls, 0)
        self.assertEqual(harness.desktop.actions, [])
        self.assertEqual(harness.channel.mode, "paused")
        self.assertNotIn("b" * 64, json.dumps(harness.responses[0]))


if __name__ == "__main__":
    unittest.main(verbosity=2)
