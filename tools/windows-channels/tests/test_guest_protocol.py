import json
from pathlib import Path
import struct
import sys
import unittest

ROOT = Path(__file__).parents[1]
sys.path.insert(0, str(ROOT))

from guest import protocol


TOKEN = "a" * 64
IDENTITY = {"bios_uuid": "11111111-2222-3333-4444-555555555555",
            "model": "Virtual Machine", "manufacturer": "Microsoft Corporation"}


class Backend:
    def __init__(self):
        self.ready = True
        self.status = "ready"
        self.calls = []
        self.failure = None

    def probe_ready(self):
        return self.ready, self.status

    def dimensions(self):
        if self.failure == "dimensions":
            raise OSError("dimension secret")
        return 1280, 800

    def perform(self, request):
        self.calls.append(request["action"])
        if self.failure:
            raise self.failure

    def screenshot_png(self):
        if self.failure:
            raise self.failure
        return (b"\x89PNG\r\n\x1a\n" + b"\x00\x00\x00\x0dIHDR" +
                struct.pack("!II", 1280, 800) + b"fixture")


class FakeConnection:
    def __init__(self, data, chunk=7):
        self.data = bytearray(data)
        self.chunk = chunk
        self.sent = bytearray()

    def recv(self, count):
        count = min(count, self.chunk, len(self.data))
        result = bytes(self.data[:count])
        del self.data[:count]
        return result

    def sendall(self, data):
        self.sent.extend(data)


class ProtocolTests(unittest.TestCase):
    def setUp(self):
        self.backend = Backend()
        self.channel = protocol.GuestChannel(self.backend, IDENTITY)

    def request(self, op, **values):
        return {"id": "request-1", "token": TOKEN, "op": op, **values}

    def test_state_shape_and_locked_desktop_remains_readable(self):
        first = protocol.dispatch(self.request("state"), TOKEN, self.channel)
        self.assertEqual(first["result"]["identity"], IDENTITY)
        self.assertEqual(first["result"]["input_target"], "private-windows-guest")
        self.assertFalse(first["result"]["host_input_supported"])
        self.channel.control("agent")
        self.backend.ready = False
        self.backend.status = "non_default_desktop"
        locked = protocol.dispatch(self.request("state"), TOKEN, self.channel)
        self.assertTrue(locked["ok"])
        self.assertFalse(locked["result"]["desktop_ready"])
        self.assertEqual(locked["result"]["desktop_status"], "non_default_desktop")
        self.assertEqual(locked["result"]["mode"], "paused")

    def test_top_level_input_and_controller_permissions(self):
        self.assertTrue(protocol.dispatch(self.request("control", mode="agent"), TOKEN, self.channel)["ok"])
        click = self.request("input", actor="agent", action="click", x=250, y=463, button=1)
        result = protocol.dispatch(click, TOKEN, self.channel)
        self.assertTrue(result["ok"])
        self.assertEqual(result["result"]["actions"], 1)
        self.assertEqual(self.backend.calls, ["click"])
        denied = protocol.dispatch(self.request("input", actor="human", action="key", key="Return"), TOKEN, self.channel)
        self.assertFalse(denied["ok"])
        self.assertEqual(denied["error"]["code"], "input_disabled")

    def test_failure_pauses_and_diagnostic_excludes_sensitive_values(self):
        secret_values = ["input-secret", "command-secret", "stderr-secret", "token-secret"]
        self.backend.failure = OSError(" ".join(secret_values))
        protocol.dispatch(self.request("control", mode="agent"), TOKEN, self.channel)
        request = self.request("input", actor="agent", action="type", text="input-secret token-secret")
        response = protocol.dispatch(request, TOKEN, self.channel)
        public = json.dumps(response) + json.dumps(self.channel.state())
        self.assertFalse(response["ok"])
        self.assertEqual(response["error"]["diagnostic"]["category"], "os_error")
        self.assertEqual(response["error"]["diagnostic"]["stage"], "text_type")
        self.assertEqual(self.channel.mode, "paused")
        for secret in secret_values:
            self.assertNotIn(secret, public)

    def test_non_default_desktop_rejects_screenshot_and_enable(self):
        self.backend.ready = False
        self.backend.status = "session_zero"
        control = protocol.dispatch(self.request("control", mode="human"), TOKEN, self.channel)
        screenshot = protocol.dispatch(self.request("screenshot"), TOKEN, self.channel)
        self.assertFalse(control["ok"])
        self.assertFalse(screenshot["ok"])
        self.assertEqual(self.channel.mode, "paused")

    def test_screenshot_response_contract(self):
        response = protocol.dispatch(self.request("screenshot"), TOKEN, self.channel)
        self.assertEqual(response["result"]["mime_type"], "image/png")
        self.assertEqual(response["result"]["width"], 1280)
        self.assertEqual(response["result"]["height"], 800)
        self.assertIsInstance(response["result"]["data"], str)

    def test_authentication_and_request_allowlist(self):
        denied = protocol.dispatch(self.request("state"), "b" * 64, self.channel)
        self.assertEqual(denied["error"]["code"], "authentication_failed")
        unknown = self.request("remote-shell")
        self.assertEqual(protocol.dispatch(unknown, "b" * 64, self.channel)["error"]["code"],
                         "authentication_failed")
        self.assertEqual(protocol.dispatch(unknown, TOKEN, self.channel)["error"]["code"],
                         "unsupported_operation")
        for request in [
            self.request("input", actor="agent", action="shell", command="whoami"),
            self.request("input", actor="agent", action="click", x=True, y=0),
            self.request("input", actor="agent", action="key", key="Win+R"),
            dict(self.request("state"), extra="value"),
        ]:
            with self.subTest(request=request), self.assertRaises(protocol.RequestError):
                protocol.validate_request(request, 1280, 800)

    def test_length_prefixed_frame_and_duplicate_fields(self):
        raw = json.dumps(self.request("state"), separators=(",", ":")).encode()
        connection = FakeConnection(struct.pack("!I", len(raw)) + raw)
        self.assertEqual(protocol.receive_request(connection)["op"], "state")
        protocol.send_response(connection, protocol.response_ok("request-1", {}))
        size = struct.unpack("!I", connection.sent[:4])[0]
        self.assertEqual(size, len(connection.sent) - 4)
        duplicate = b'{"id":"one","id":"two","token":"' + TOKEN.encode() + b'","op":"state"}'
        with self.assertRaises(protocol.RequestError):
            protocol.decode_request(duplicate)

    def test_request_size_limit(self):
        connection = FakeConnection(struct.pack("!I", protocol.MAX_REQUEST_BYTES + 1))
        with self.assertRaises(protocol.RequestError):
            protocol.receive_request(connection)

    def test_dimension_failure_pauses_and_is_sanitized(self):
        self.channel.mode = "agent"
        self.backend.failure = "dimensions"
        response = protocol.dispatch(self.request("state"), TOKEN, self.channel)
        self.assertFalse(response["ok"])
        self.assertEqual(self.channel.mode, "paused")
        self.assertNotIn("dimension secret", json.dumps(response))


if __name__ == "__main__":
    unittest.main(verbosity=2)
