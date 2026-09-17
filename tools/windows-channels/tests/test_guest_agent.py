import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest

ROOT = Path(__file__).parents[1]
sys.path.insert(0, str(ROOT))

from guest import agent, protocol


class FakeListener:
    def __init__(self, *args):
        self.args = args
        self.timeout = None
        self.bound = None
        self.backlog = None
        self.closed = False
    def settimeout(self, value): self.timeout = value
    def bind(self, value): self.bound = value
    def listen(self, value): self.backlog = value
    def close(self): self.closed = True


class FakeSocketModule:
    AF_HYPERV = 34
    SOCK_STREAM = 1
    HV_PROTOCOL_RAW = 1
    HV_GUID_PARENT = "a42e7cda-d03f-480c-9cc2-a4de20abb878"
    def __init__(self): self.listener = None
    def socket(self, *args): self.listener = FakeListener(*args); return self.listener


class Connection:
    def __init__(self, request):
        raw = json.dumps(request, separators=(",", ":")).encode()
        self.data = bytearray(struct.pack("!I", len(raw)) + raw)
        self.sent = bytearray()
        self.timeout = None
    def settimeout(self, value): self.timeout = value
    def recv(self, size):
        result = bytes(self.data[:size]); del self.data[:size]; return result
    def sendall(self, value): self.sent.extend(value)


class Backend:
    def probe_ready(self): return True, "ready"
    def dimensions(self): return 640, 480


class AgentTests(unittest.TestCase):
    def test_listener_is_hyperv_only_with_fixed_service_id(self):
        module = FakeSocketModule()
        listener = agent.create_hyperv_listener(module)
        self.assertEqual(listener.args, (module.AF_HYPERV, module.SOCK_STREAM, module.HV_PROTOCOL_RAW))
        self.assertEqual(listener.bound, (module.HV_GUID_PARENT, agent.SERVICE_ID))
        self.assertEqual(listener.backlog, 8)
        self.assertEqual(listener.timeout, 1)

    def test_missing_hyperv_constants_refuses_listener(self):
        class Missing: pass
        with self.assertRaises(RuntimeError): agent.create_hyperv_listener(Missing())

    def test_token_file_is_explicit_and_strict(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "token"
            path.write_text("a" * 64, encoding="ascii")
            self.assertEqual(agent.load_token(path), "a" * 64)
            path.write_text("not-a-token", encoding="ascii")
            with self.assertRaises(RuntimeError): agent.load_token(path)

    def test_one_connection_returns_fixed_response_shape(self):
        token = "a" * 64
        channel = protocol.GuestChannel(Backend(), {
            "bios_uuid": "11111111-2222-3333-4444-555555555555",
            "model": "Virtual Machine", "manufacturer": "Microsoft Corporation",
        })
        connection = Connection({"id": "r1", "token": token, "op": "state"})
        agent.handle_connection(connection, token, channel)
        size = struct.unpack("!I", connection.sent[:4])[0]
        response = json.loads(connection.sent[4:4 + size])
        self.assertEqual(set(response), {"id", "ok", "result"})
        self.assertEqual(response["id"], "r1")
        self.assertTrue(response["ok"])
        self.assertEqual(connection.timeout, agent.CONNECTION_TIMEOUT_SECONDS)


if __name__ == "__main__":
    unittest.main(verbosity=2)
