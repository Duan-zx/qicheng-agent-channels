"""Host-independent tests for the bounded guest WeChat CLI probe."""

import io
import hashlib
import json
from pathlib import Path
import sys
import tempfile
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
OPEN_REQUEST = {"project_id": "guest-a", "action": "open"}


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

    def test_startup_digest_hashes_exact_raw_bytes_from_one_read(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "wechat.json"
            raw = json.dumps(CONFIG, separators=(",", ":")).encode("utf-8")
            path.write_bytes(raw)
            first, digest = wechat_cli.load_trusted_config_and_digest(path)
            self.assertEqual(first, self.config)
            self.assertEqual(digest, hashlib.sha256(raw).hexdigest())
            changed = json.dumps(CONFIG, indent=2).encode("utf-8")
            path.write_bytes(changed)
            second, changed_digest = wechat_cli.load_trusted_config_and_digest(path)
            self.assertEqual(second, first)
            self.assertNotEqual(changed_digest, digest)

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

        with patch.object(wechat_cli.subprocess, "Popen") as popen:
            for request in (
                OPEN_REQUEST | {"project_path": r"C:\Other"},
                OPEN_REQUEST | {"port": 1},
                OPEN_REQUEST | {"argv": ["upload"]},
                OPEN_REQUEST | {"action": "preview"},
                OPEN_REQUEST | {"project_id": "guest-b"},
            ):
                self.assertEqual(wechat_cli.open_project(self.config, request),
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
        self.assertEqual(kwargs["stderr"], wechat_cli.subprocess.STDOUT)

    def test_open_uses_only_configured_project_but_requires_verified_receipt(self):
        with patch.object(wechat_cli.subprocess, "Popen", return_value=FakeProcess(
            b"[success] IDE request accepted\n")) as popen:
            result = wechat_cli.open_project(self.config, OPEN_REQUEST)
        self.assertEqual(result, {"ok": False,
                                  "error": {"code": "indeterminate_output"}})
        args, kwargs = popen.call_args
        self.assertEqual(args[0], [CONFIG["cli_bat_path"], "open", "--project",
                                   CONFIG["guest_project_path"], "--port", "36635"])
        self.assertEqual(kwargs["cwd"], CONFIG["guest_project_path"])
        self.assertIs(kwargs["shell"], False)
        self.assertEqual(kwargs["stderr"], wechat_cli.subprocess.STDOUT)

    def test_cli_error_with_zero_exit_is_failure_and_redacted(self):
        for output in (b"[error] {code:10, message:'SECRET AppID'}\n",
                       b'{"code":10,"message":"SECRET AppID"}\n',
                       b'{"code":"10","message":"SECRET AppID"}\n'):
            for action, operation in ((REQUEST, wechat_cli.check_login),
                                      (OPEN_REQUEST, wechat_cli.open_project)):
                with self.subTest(action=action["action"], output=output):
                    with patch.object(wechat_cli.subprocess, "Popen",
                                      return_value=FakeProcess(output, exit_code=0)):
                        result = operation(self.config, action)
                    self.assertEqual(result, {"ok": False,
                                              "error": {"code": "cli_reported_error"}})
                    self.assertNotIn("SECRET", str(result))

    def test_open_unknown_zero_exit_output_never_reports_submission(self):
        for output in (b"", b"failed to open project\n", b"[success]\n",
                       b'{"code":0}\n', b'{"code":"0"}\n'):
            with self.subTest(output=output):
                with patch.object(wechat_cli.subprocess, "Popen",
                                  return_value=FakeProcess(output, exit_code=0)):
                    result = wechat_cli.open_project(self.config, OPEN_REQUEST)
                self.assertEqual(result, {"ok": False,
                                          "error": {"code": "indeterminate_output"}})

    def test_check_login_observed_boolean_false_is_a_valid_result(self):
        with patch.object(wechat_cli.subprocess, "Popen", return_value=FakeProcess(
            b'{"login":false}\n', exit_code=0)):
            self.assertEqual(wechat_cli.check_login(self.config, REQUEST),
                             {"ok": True, "result": {"login": False}})

    def test_nonzero_exit_is_failure_even_with_success_text(self):
        with patch.object(wechat_cli.subprocess, "Popen", return_value=FakeProcess(
            b"[success]\n", exit_code=1)):
            self.assertEqual(wechat_cli.open_project(self.config, OPEN_REQUEST),
                             {"ok": False, "error": {"code": "cli_failed"}})

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
