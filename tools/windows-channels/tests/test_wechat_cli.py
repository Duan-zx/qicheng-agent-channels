"""Host-independent tests for the bounded guest WeChat CLI probe."""

import io
from pathlib import Path
import sys
import threading
import unittest
from unittest.mock import patch


sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from guest import wechat_cli


CONFIG = {
    "project_id": "guest-a",
    "guest_project_path": r"C:\Projects\Qicheng",
    "cli_bat_path": r"C:\Program Files\WeChat DevTools\cli.bat",
    "service_port": 36635,
}
REQUEST = {"project_id": "guest-a", "action": "check-login"}


class FakeProcess:
    pid = 31415

    def __init__(self, output, exit_code=0):
        self.stdout = io.BytesIO(output)
        self.exit_code = exit_code
        self.killed = False

    def poll(self):
        return self.exit_code if not self.killed else -9

    def wait(self, timeout=None):
        return self.poll()

    def kill(self):
        self.killed = True


class BlockingStream:
    def __init__(self):
        self.released = threading.Event()

    def read(self, size):
        self.released.wait(2)
        return b""

    def close(self):
        self.released.set()


class BlockingProcess(FakeProcess):
    def __init__(self):
        self.stdout = BlockingStream()
        self.exit_code = None
        self.killed = False

    def poll(self):
        return -9 if self.killed else None

    def kill(self):
        self.killed = True
        self.stdout.released.set()


class WechatCliTests(unittest.TestCase):
    def setUp(self):
        self.config = wechat_cli.TrustedWechatConfig.from_mapping(CONFIG)

    def test_rejects_untrusted_configuration(self):
        for change in (
            {"guest_project_path": r"..\project"},
            {"cli_bat_path": r"\\server\share\cli.bat"},
            {"cli_bat_path": r"C:\tool\evil.bat"},
            {"service_port": True},
            {"service_port": 65536},
            {"project_id": "guest a"},
        ):
            with self.subTest(change=change), self.assertRaises(ValueError):
                wechat_cli.TrustedWechatConfig.from_mapping(CONFIG | change)
        with self.assertRaises(ValueError):
            wechat_cli.TrustedWechatConfig.from_mapping(CONFIG | {"argv": ["whoami"]})

    def test_request_cannot_override_command_or_target(self):
        with patch.object(wechat_cli.subprocess, "Popen") as popen:
            for request in (
                REQUEST | {"argv": ["upload"]},
                REQUEST | {"port": 1},
                REQUEST | {"action": "preview"},
                REQUEST | {"project_id": "guest-b"},
            ):
                self.assertEqual(wechat_cli.check_login(self.config, request),
                                 {"ok": False, "error": {"code": "invalid_request"}})
            popen.assert_not_called()

    def test_fixed_command_and_boolean_only(self):
        with patch.object(wechat_cli.subprocess, "Popen", return_value=FakeProcess(
            b'IDE server listening on 127.0.0.1\n{"login":true}\n')) as popen:
            result = wechat_cli.check_login(self.config, REQUEST)
        self.assertEqual(result, {"ok": True, "result": {"login": True}})
        args, kwargs = popen.call_args
        self.assertEqual(args[0], [CONFIG["cli_bat_path"], "islogin", "--port", "36635"])
        self.assertEqual(kwargs["cwd"], CONFIG["guest_project_path"])
        self.assertIs(kwargs["shell"], False)
        self.assertEqual(kwargs["stderr"], wechat_cli.subprocess.DEVNULL)

    def test_output_limit_and_no_raw_diagnostics(self):
        with patch.object(wechat_cli.subprocess, "Popen", return_value=FakeProcess(
            b"SECRET" + b"x" * wechat_cli.MAX_OUTPUT_BYTES)) as popen:
            with patch.object(wechat_cli.subprocess, "run"):
                result = wechat_cli.check_login(self.config, REQUEST)
        self.assertEqual(result, {"ok": False, "error": {"code": "output_too_large"}})
        self.assertNotIn("SECRET", str(result))
        popen.assert_called_once()

    def test_timeout_stops_child_and_returns_fixed_error(self):
        process = BlockingProcess()
        with patch.object(wechat_cli.subprocess, "Popen", return_value=process):
            with patch.object(wechat_cli.subprocess, "run") as taskkill:
                with patch.object(wechat_cli, "TIMEOUT_SECONDS", 0.01):
                    result = wechat_cli.check_login(self.config, REQUEST)
        self.assertEqual(result, {"ok": False, "error": {"code": "timeout"}})
        self.assertTrue(process.killed)
        self.assertEqual(taskkill.call_args.args[0],
                         ["taskkill.exe", "/PID", "31415", "/T", "/F"])

    def test_rejects_non_boolean_output(self):
        with patch.object(wechat_cli.subprocess, "Popen", return_value=FakeProcess(
            b'{"login":"yes"}\n')):
            self.assertEqual(wechat_cli.check_login(self.config, REQUEST),
                             {"ok": False, "error": {"code": "invalid_output"}})


if __name__ == "__main__":
    unittest.main()
