import json
import importlib.util
import secrets
import shutil
import socket
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from concurrent.futures import ThreadPoolExecutor
from contextlib import closing
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest.mock import patch
from urllib.error import HTTPError
from urllib.request import Request, urlopen


sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from broker import Broker, BrokerHTTPServer  # noqa: E402
from lite_client import LiteClient  # noqa: E402
from lease import ChannelBusy  # noqa: E402
from bounded_action import ActionResult  # noqa: E402
from reconcile_action_dirty import reconcile  # noqa: E402


class BrokerHTTPTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.credential = secrets.token_hex(32)
        (root / "broker.token").write_text(self.credential, encoding="ascii")
        (root / "project-A").mkdir()
        (root / "project-B").mkdir()
        (root / "project-C").mkdir()
        actions = {"check": {"argv": [sys.executable, "-c", "print('guarded')"],
                             "timeout_seconds": 2},
                   "fail": {"argv": [sys.executable, "-c",
                            "import sys; print('failed'); sys.stderr.write('reason\\n'); sys.exit(7)"],
                            "timeout_seconds": 2},
                   "loud": {"argv": [sys.executable, "-c",
                           "import os; os.write(1,b'a'*200000); os.write(2,b'b'*200000)"],
                           "timeout_seconds": 2},
                   "hold": {"argv": [sys.executable, "-c",
                           "import pathlib,time; pathlib.Path('started').touch(); "
                           "deadline=time.monotonic()+2; "
                           "exec('while not pathlib.Path(\"finish\").exists() and time.monotonic()<deadline: time.sleep(0.01)')"],
                           "timeout_seconds": 3}}
        (root / "config.json").write_text(json.dumps({
            "default_ttl_seconds": 3,
            "max_ttl_seconds": 30,
            "channels": [
                {"channel_id": "channel-A", "endpoint_id": "wechat-1",
                 "tool_id": "wechat", "project_id": "project-A",
                 "project_path": str(root / "project-A"), "actions": actions},
                {"channel_id": "channel-B", "endpoint_id": "wechat-1",
                 "tool_id": "wechat", "project_id": "project-B",
                 "project_path": str(root / "project-B"), "actions": actions},
                {"channel_id": "channel-C", "endpoint_id": "browser-2",
                 "tool_id": "browser", "project_id": "project-C",
                 "project_path": str(root / "project-C"), "actions": actions},
            ]
        }), encoding="utf-8")
        self.now = [1000.0]
        broker = Broker(config_path=root / "config.json", credential_path=root / "broker.token",
                        db_path=root / "leases.db", clock=lambda: self.now[0])
        self.server = BrokerHTTPServer(broker, 0)
        self.addCleanup(self.server.server_close)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self._stop)
        self.base = f"http://127.0.0.1:{self.server.server_port}"

    def _stop(self):
        self.server.shutdown()
        self.thread.join(5)

    def call(self, path, body=None, credential=True):
        headers = {"Authorization": "Bearer " + self.credential} if credential else {}
        if body is not None:
            headers["Content-Type"] = "application/json"
        req = Request(self.base + path, data=json.dumps(body).encode() if body is not None else None,
                      headers=headers, method="POST" if body is not None else "GET")
        try:
            with urlopen(req, timeout=5) as response:
                return response.status, json.load(response)
        except HTTPError as error:
            return error.code, json.load(error)

    def acquire(self, request_id, channel_id, **extra):
        return self.call("/v1/acquire", {"request_id": request_id, "task_id": request_id,
                                         "channel_id": channel_id, **extra})

    def test_offline_maintenance_blocks_http_entries_and_survives_restart(self):
        _, active = self.acquire("owner", "channel-A")
        self.server.broker.store.set_maintenance(True)
        self.assertTrue(self.call("/v1/status")[1]["maintenance"])
        self.assertEqual((503, {"error": "maintenance"}),
                         self.acquire("next", "channel-C"))
        self.assertEqual((503, {"error": "maintenance"}),
                         self.call("/v1/execute", {"channel_id": "channel-A",
                                                    "token": active["token"],
                                                    "action": "check"}))
        with closing(sqlite3.connect(Path(self.temp.name) / "leases.db")) as db:
            before = tuple(db.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
                           for table in ("requests", "atomic_runs", "waiters"))
        status, response = self.atomic_run("new-run", "channel-C")
        self.assertEqual((503, "maintenance"), (status, response["error"]))
        with closing(sqlite3.connect(Path(self.temp.name) / "leases.db")) as db:
            after = tuple(db.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
                          for table in ("requests", "atomic_runs", "waiters"))
        self.assertEqual(before, after)
        self.assertTrue(Broker(config_path=Path(self.temp.name) / "config.json",
                               credential_path=Path(self.temp.name) / "broker.token",
                               db_path=Path(self.temp.name) / "leases.db").store.maintenance())
        self.assertEqual(200, self.call("/v1/release", {
            "channel_id": "channel-A", "token": active["token"]})[0])
        self.server.broker.store.set_maintenance(False)
        self.assertEqual(200, self.acquire("next", "channel-C")[0])

    def test_maintenance_cli_uses_existing_private_database(self):
        script = Path(__file__).resolve().parents[1] / "broker.py"
        db = Path(self.temp.name) / "leases.db"
        for command, expected in (("on", "on"), ("status", "on"),
                                  ("off", "off"), ("status", "off")):
            result = subprocess.run([sys.executable, str(script), "--db", str(db),
                                     "--maintenance", command], capture_output=True,
                                    text=True, timeout=10)
            self.assertEqual(0, result.returncode, result.stderr)
            self.assertEqual(expected, result.stdout.strip())
        missing = db.with_name("missing.db")
        result = subprocess.run([sys.executable, str(script), "--db", str(missing),
                                 "--maintenance", "on"], capture_output=True,
                                text=True, timeout=10)
        self.assertNotEqual(0, result.returncode)
        self.assertFalse(missing.exists())

    def test_maintenance_cancels_queued_run_without_later_replay(self):
        _, active = self.acquire("owner", "channel-A")
        with ThreadPoolExecutor(max_workers=1) as pool:
            waiting = pool.submit(self.atomic_run, "queued-run", "channel-B",
                                  "hold", wait_seconds=3)
            self.wait_for_queue(1)
            self.server.broker.store.set_maintenance(True)
            status, response = waiting.result(timeout=5)
        self.assertEqual((503, "maintenance"), (status, response["error"]))
        self.assertFalse((Path(self.temp.name) / "project-B" / "started").exists())
        with closing(sqlite3.connect(Path(self.temp.name) / "leases.db")) as db:
            self.assertEqual(0, db.execute("SELECT COUNT(*) FROM waiters").fetchone()[0])
        self.server.broker.store.set_maintenance(False)
        self.call("/v1/release", {"channel_id": "channel-A", "token": active["token"]})
        status, response = self.atomic_run("queued-run", "channel-B", "hold",
                                           wait_seconds=3)
        self.assertEqual((503, "maintenance"), (status, response["error"]))
        self.assertFalse((Path(self.temp.name) / "project-B" / "started").exists())

    def test_maintenance_and_new_run_claim_share_write_transaction(self):
        broker = self.server.broker
        entered = threading.Event()
        proceed = threading.Event()
        original = broker.store._require_open
        def pause_after_check(db):
            original(db)
            entered.set()
            if not proceed.wait(3):
                raise TimeoutError("claim did not resume")
        broker.store._require_open = pause_after_check
        try:
            with ThreadPoolExecutor(max_workers=2) as pool:
                claiming = pool.submit(broker._claim_run, "pre-maintenance", "task",
                                       broker.channels["channel-C"], "check")
                self.assertTrue(entered.wait(2))
                with closing(sqlite3.connect(Path(self.temp.name) / "leases.db",
                                             timeout=0.05, isolation_level=None)) as db:
                    with self.assertRaises(sqlite3.OperationalError):
                        db.execute("BEGIN IMMEDIATE")
                enabling_started = threading.Event()
                def enable():
                    enabling_started.set()
                    return broker.store.set_maintenance(True)
                enabling = pool.submit(enable)
                self.assertTrue(enabling_started.wait(2))
                self.assertFalse(enabling.done())
                proceed.set()
                self.assertIsNone(claiming.result(timeout=3))
                self.assertTrue(enabling.result(timeout=3))
        finally:
            proceed.set()
            broker.store._require_open = original
        with closing(sqlite3.connect(Path(self.temp.name) / "leases.db")) as db:
            self.assertEqual(1, db.execute("SELECT COUNT(*) FROM atomic_runs").fetchone()[0])
            self.assertEqual(1, db.execute("SELECT COUNT(*) FROM requests").fetchone()[0])
        status, response = self.atomic_run("post-maintenance", "channel-C")
        self.assertEqual((503, "maintenance"), (status, response["error"]))
        with closing(sqlite3.connect(Path(self.temp.name) / "leases.db")) as db:
            self.assertEqual(1, db.execute("SELECT COUNT(*) FROM atomic_runs").fetchone()[0])
            self.assertEqual(1, db.execute("SELECT COUNT(*) FROM requests").fetchone()[0])

    def test_run_admitted_before_maintenance_finishes_and_releases(self):
        project = Path(self.temp.name) / "project-C"
        with ThreadPoolExecutor(max_workers=1) as pool:
            running = pool.submit(self.atomic_run, "in-flight", "channel-C", "hold")
            deadline = time.monotonic() + 2
            while time.monotonic() < deadline and not (project / "started").exists():
                time.sleep(0.01)
            self.assertTrue((project / "started").exists())
            self.server.broker.store.set_maintenance(True)
            (project / "finish").touch()
            status, response = running.result(timeout=5)
        self.assertEqual((200, True), (status, response["ok"]))
        self.assertIsNone(self.server.broker.store.current("channel-C"))

    def atomic_run(self, request_id, channel_id="channel-A", action="check", **extra):
        return self.call("/v1/run", {"request_id": request_id, "task_id": request_id,
                                     "channel_id": channel_id, "action": action, **extra})

    def n8n_run(self, request_id, execution_id="42", workflow_id="workflow-1", **extra):
        return self.atomic_run(request_id, "channel-B", n8n_execution_id=execution_id,
                               n8n_workflow_id=workflow_id, **extra)

    def n8n_cancel(self, request_id, execution_id="42", workflow_id="workflow-1"):
        return self.call("/v1/cancel-run", {
            "request_id": request_id, "task_id": request_id,
            "channel_id": "channel-B", "action": "check",
            "n8n_execution_id": execution_id, "n8n_workflow_id": workflow_id})

    def enable_n8n(self):
        self.server.broker.n8n_status = {"base_url": "http://127.0.0.1:5678",
                                          "api_key_file": Path(self.temp.name) / "n8n.key"}
        self.server.broker.n8n_status["api_key_file"].write_text("test-key", encoding="ascii")

    def wait_for_queue(self, count):
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            with closing(sqlite3.connect(Path(self.temp.name) / "leases.db")) as db:
                if db.execute("SELECT COUNT(*) FROM waiters").fetchone()[0] == count:
                    return
            time.sleep(0.02)
        self.fail(f"expected {count} waiters")

    def test_http_bounded_wait_and_disconnect_cleanup(self):
        status, owner = self.acquire("owner", "channel-A")
        self.assertEqual(200, status)
        with ThreadPoolExecutor(max_workers=1) as pool:
            waiting = pool.submit(self.acquire, "next", "channel-B", wait_seconds=2)
            self.wait_for_queue(1)
            self.assertEqual(409, self.acquire("immediate", "channel-B")[0])
            self.assertEqual(200, self.call("/v1/release", {
                "channel_id": "channel-A", "token": owner["token"]})[0])
            status, successor = waiting.result(timeout=4)
        self.assertEqual(200, status)
        self.assertEqual("next", successor["request_id"])
        self.assertEqual(200, self.call("/v1/release", {
            "channel_id": "channel-B", "token": successor["token"]})[0])

        status, owner = self.acquire("owner-2", "channel-A")
        self.assertEqual(200, status)
        body = json.dumps({"channel_id": "channel-B", "task_id": "abandoned",
                           "request_id": "abandoned", "wait_seconds": 2}).encode()
        request = (b"POST /v1/acquire HTTP/1.1\r\nHost: 127.0.0.1\r\n"
                   + f"Authorization: Bearer {self.credential}\r\n".encode()
                   + b"Content-Type: application/json\r\n"
                   + f"Content-Length: {len(body)}\r\n\r\n".encode() + body)
        connection = socket.create_connection(("127.0.0.1", self.server.server_port))
        try:
            connection.sendall(request)
            self.wait_for_queue(1)
        finally:
            connection.close()
        self.wait_for_queue(0)
        self.assertEqual(200, self.call("/v1/release", {
            "channel_id": "channel-A", "token": owner["token"]})[0])
        self.assertEqual(200, self.acquire("after-disconnect", "channel-B")[0])

    def test_atomic_run_replay_conflict_and_ttl(self):
        self.assertEqual(400, self.atomic_run("short", ttl_seconds=2)[0])
        status, first = self.atomic_run("atomic-one")
        self.assertEqual(200, status)
        self.assertTrue(first["ok"])
        self.assertEqual((status, first), self.atomic_run("atomic-one"))
        self.assertEqual(409, self.atomic_run("atomic-one", action="loud")[0])
        self.assertEqual(410, self.acquire("atomic-one", "channel-A")[0])
        self.assertIsNone(self.server.broker.store.current("channel-A"))
        root = Path(self.temp.name)
        restarted = Broker(config_path=root / "config.json",
                           credential_path=root / "broker.token",
                           db_path=root / "leases.db", clock=lambda: self.now[0])
        self.assertEqual(first, restarted.run({"request_id": "atomic-one",
            "task_id": "atomic-one", "channel_id": "channel-A", "action": "check"}))

    def test_n8n_wait_needs_status_source_and_both_ids(self):
        self.assertEqual(400, self.n8n_run("missing", wait_seconds=1)[0])
        self.assertEqual(400, self.atomic_run("one-id", "channel-B",
            n8n_execution_id="42", wait_seconds=1)[0])
        with closing(sqlite3.connect(Path(self.temp.name) / "leases.db")) as db:
            self.assertEqual(0, db.execute("SELECT COUNT(*) FROM atomic_runs").fetchone()[0])

    def test_n8n_status_reads_only_matching_running_execution(self):
        seen = []
        mode = ["running"]
        class StatusHandler(BaseHTTPRequestHandler):
            def do_GET(self):
                seen.append((self.path, self.headers.get("X-N8N-API-KEY")))
                if mode[0] == "redirect":
                    self.send_response(302)
                    self.send_header("Location", "http://example.com/steal")
                    self.end_headers()
                    return
                body = json.dumps({"id": "43" if mode[0] == "wrong-id" else "42",
                                   "workflowId": "workflow-1",
                                   "status": "running"}).encode()
                self.send_response(200)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            def log_message(self, *_args):
                pass
        status_server = ThreadingHTTPServer(("127.0.0.1", 0), StatusHandler)
        thread = threading.Thread(target=status_server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(thread.join, 5)
        self.addCleanup(status_server.server_close)
        self.addCleanup(status_server.shutdown)
        self.enable_n8n()
        self.server.broker.n8n_status["base_url"] = f"http://127.0.0.1:{status_server.server_port}"
        self.assertTrue(self.server.broker._n8n_running("42", "workflow-1"))
        self.assertFalse(self.server.broker._n8n_running("42", "other-workflow"))
        mode[0] = "wrong-id"
        self.assertFalse(self.server.broker._n8n_running("42", "workflow-1"))
        mode[0] = "redirect"
        self.assertFalse(self.server.broker._n8n_running("42", "workflow-1"))
        self.assertEqual(("/api/v1/executions/42?includeData=false", "test-key"), seen[0])

    def test_n8n_queued_cancel_and_binding_replay(self):
        self.enable_n8n()
        _, owner = self.acquire("owner-n8n", "channel-A")
        with patch.object(self.server.broker, "_n8n_running", return_value=True):
            with ThreadPoolExecutor(max_workers=1) as pool:
                future = pool.submit(self.n8n_run, "queued", wait_seconds=2)
                self.wait_for_queue(1)
                self.assertEqual(409, self.n8n_cancel("queued", "other")[0])
                self.assertEqual(409, self.n8n_cancel("queued", workflow_id="other")[0])
                self.assertEqual((200, {"ok": True, "cancelled": True,
                                        "request_id": "queued"}), self.n8n_cancel("queued"))
                self.assertEqual(410, future.result(timeout=4)[0])
        self.wait_for_queue(0)
        self.assertEqual(410, self.n8n_run("queued")[0])
        self.assertEqual(409, self.n8n_run("queued", execution_id="43")[0])
        self.assertEqual(409, self.n8n_run("queued", workflow_id="other")[0])
        self.assertEqual(200, self.call("/v1/release", {
            "channel_id": "channel-A", "token": owner["token"]})[0])

    def test_n8n_status_unreadable_cancels_wait_and_other_request_survives(self):
        self.enable_n8n()
        _, owner = self.acquire("owner-unreadable", "channel-A")
        live = {"first": True, "second": True}
        def running(execution_id, _workflow_id):
            return live[execution_id]
        with patch.object(self.server.broker, "_n8n_running", side_effect=running):
            with ThreadPoolExecutor(max_workers=2) as pool:
                first = pool.submit(self.n8n_run, "first", "first", wait_seconds=2)
                second = pool.submit(self.n8n_run, "second", "second", wait_seconds=2)
                self.wait_for_queue(2)
                live["first"] = False
                self.assertEqual(410, first.result(timeout=4)[0])
                self.assertEqual(409, self.n8n_cancel("second", "first")[0])
                self.assertEqual(200, self.call("/v1/release", {
                    "channel_id": "channel-A", "token": owner["token"]})[0])
                self.assertEqual(200, second.result(timeout=4)[0])

    def test_n8n_initial_404_grace_still_requires_running_before_action(self):
        self.enable_n8n()
        _, owner = self.acquire("owner-404", "channel-A")
        reads = []
        def appearing(_execution_id, _workflow_id):
            reads.append(1)
            return None if len(reads) <= 2 else True
        with patch.object(self.server.broker, "_n8n_running", side_effect=appearing):
            with ThreadPoolExecutor(max_workers=1) as pool:
                future = pool.submit(self.n8n_run, "appearing", wait_seconds=2)
                self.wait_for_queue(1)
                self.assertEqual(200, self.call("/v1/release", {
                    "channel_id": "channel-A", "token": owner["token"]})[0])
                self.assertEqual(200, future.result(timeout=4)[0])
        self.assertGreaterEqual(len(reads), 3)

    def test_n8n_persistent_404_removes_waiter_without_action(self):
        self.enable_n8n()
        _, owner = self.acquire("owner-missing", "channel-A")
        with patch.object(self.server.broker, "_n8n_running", return_value=None), \
                patch("broker.run_action") as action:
            with ThreadPoolExecutor(max_workers=1) as pool:
                future = pool.submit(self.n8n_run, "missing-execution", wait_seconds=2)
                self.wait_for_queue(1)
                self.assertEqual((410, {"ok": False, "error": "run_cancelled",
                                        "request_id": "missing-execution"}),
                                 future.result(timeout=4))
            self.wait_for_queue(0)
            action.assert_not_called()
        self.assertEqual(410, self.n8n_run("missing-execution")[0])
        self.assertEqual(200, self.call("/v1/release", {
            "channel_id": "channel-A", "token": owner["token"]})[0])

    def test_n8n_final_refusal_release_failure_is_unknown_on_http_and_replay(self):
        self.enable_n8n()
        states = iter((True, False))
        with patch.object(self.server.broker, "_n8n_running",
                          side_effect=lambda *_args: next(states)), \
                patch.object(self.server.broker.store, "release",
                             side_effect=RuntimeError("release failed")), \
                patch("broker.run_action") as action:
            status, result = self.n8n_run("release-uncertain")
        self.assertEqual(503, status)
        self.assertEqual({"ok": False, "error": "result_unknown",
                          "request_id": "release-uncertain"}, result)
        self.assertEqual((status, result), self.n8n_run("release-uncertain"))
        action.assert_not_called()

    def test_n8n_initial_refusal_has_one_terminal_receipt_without_lease(self):
        self.enable_n8n()
        with patch.object(self.server.broker, "_n8n_running", return_value=False), \
                patch.object(self.server.broker, "acquire") as acquire:
            status, result = self.n8n_run("refused-before-acquire")
        self.assertEqual(410, status)
        self.assertEqual({"ok": False, "error": "run_cancelled",
                          "request_id": "refused-before-acquire"}, result)
        self.assertEqual((status, result), self.n8n_run("refused-before-acquire"))
        acquire.assert_not_called()

    def test_n8n_started_action_ignores_later_cancel(self):
        self.enable_n8n()
        entered = threading.Event()
        finish = threading.Event()
        def held(*_args, **_kwargs):
            entered.set()
            self.assertTrue(finish.wait(3))
            return ActionResult(0, False, b"done", b"", False, False, False)
        with patch.object(self.server.broker, "_n8n_running", return_value=True), \
                patch("broker.run_action", side_effect=held):
            with ThreadPoolExecutor(max_workers=1) as pool:
                future = pool.submit(self.n8n_run, "started")
                self.assertTrue(entered.wait(2))
                self.assertEqual((200, {"ok": True, "cancelled": False,
                                        "request_id": "started"}), self.n8n_cancel("started"))
                finish.set()
                self.assertEqual(200, future.result(timeout=5)[0])
        self.assertIsNone(self.server.broker.store.current("channel-B"))
        self.assertEqual(200, self.n8n_run("started")[0])

    def test_atomic_run_nonzero_exit_is_http_failure_and_replays(self):
        status, first = self.atomic_run("failed-run", action="fail")
        self.assertEqual(502, status)
        self.assertEqual("action_failed", first["error"])
        self.assertFalse(first["ok"])
        self.assertEqual(7, first["exit_code"])
        self.assertEqual("failed", first["stdout"].strip())
        self.assertEqual("reason", first["stderr"].strip())
        with patch("broker.run_action") as action:
            self.assertEqual((status, first), self.atomic_run("failed-run", action="fail"))
        action.assert_not_called()

        _, legacy = self.acquire("legacy-fail", "channel-A")
        status, old = self.call("/v1/execute", {"channel_id": "channel-A",
                                                   "token": legacy["token"], "action": "fail"})
        self.assertEqual(200, status)
        self.assertFalse(old["ok"])
        self.assertNotIn("error", old)

    def test_atomic_run_same_key_concurrent_and_parallel_endpoint(self):
        entered = threading.Event()
        finish = threading.Event()
        count = []
        def held(*_args, **_kwargs):
            count.append(1)
            if Path(_kwargs["cwd"]).name == "project-A":
                entered.set()
                self.assertTrue(finish.wait(3))
            return ActionResult(0, False, b"ok", b"", False, False, False)
        with patch("broker.run_action", side_effect=held):
            with ThreadPoolExecutor(max_workers=2) as pool:
                first = pool.submit(self.atomic_run, "same")
                self.assertTrue(entered.wait(2))
                try:
                    private_id = self.server.broker.store.current("channel-A").request_id
                    self.assertTrue(private_id.startswith("atomic:"))
                    state = self.call("/v1/status?channel_id=channel-A")[1]
                    self.assertEqual("[atomic]", state["channels"][0]["lease"]["request_id"])
                    self.assertEqual(400, self.acquire(private_id, "channel-A", task_id="same")[0])
                    self.assertEqual((409, {"ok": False, "error": "run_in_progress",
                                            "request_id": "same"}), self.atomic_run("same"))
                    self.assertEqual("action_dirty", self.atomic_run("other", "channel-B")[1]["error"])
                    self.assertEqual(200, self.atomic_run("parallel", "channel-C")[0])
                finally:
                    finish.set()
                self.assertEqual(200, first.result(timeout=5)[0])
        self.assertEqual(2, len(count))

    def test_atomic_run_busy_timeout_and_queue_full_are_known(self):
        _, owner = self.acquire("owner", "channel-A")
        with patch("broker.run_action") as action:
            self.assertEqual("busy", self.atomic_run("busy", "channel-B")[1]["error"])
            self.assertEqual("busy", self.atomic_run("busy", "channel-B")[1]["error"])
            self.assertEqual("wait_timeout", self.atomic_run(
                "timed", "channel-B", wait_seconds=0.1)[1]["error"])
            with patch.object(self.server.broker.store, "MAX_WAITERS_PER_ENDPOINT", 0):
                self.assertEqual("wait_queue_full", self.atomic_run(
                    "full", "channel-B", wait_seconds=1)[1]["error"])
        action.assert_not_called()
        self.call("/v1/release", {"channel_id": "channel-A", "token": owner["token"]})

    def test_atomic_run_wait_queues_behind_live_action_but_stale_dirty_blocks(self):
        entered = threading.Event()
        finish = threading.Event()
        count = []
        def held(*_args, **_kwargs):
            count.append(1)
            if len(count) == 1:
                entered.set()
                self.assertTrue(finish.wait(3))
            return ActionResult(0, False, b"ok", b"", False, False, False)
        with patch("broker.run_action", side_effect=held):
            with ThreadPoolExecutor(max_workers=2) as pool:
                first = pool.submit(self.atomic_run, "first")
                self.assertTrue(entered.wait(2))
                second = pool.submit(self.atomic_run, "second", "channel-B",
                                     wait_seconds=2)
                self.wait_for_queue(1)
                finish.set()
                self.assertEqual(200, first.result(timeout=5)[0])
                self.assertEqual(200, second.result(timeout=5)[0])
        self.assertEqual(2, len(count))
        _, owner = self.acquire("cleaning", "channel-A")
        channel = self.server.broker.channels["channel-A"]
        self.server.broker._mark_action_dirty(channel, "cleaning")
        self.assertEqual("live", self.server.broker._action_dirty_state("wechat-1"))
        self.server.broker._clear_action_dirty(channel, "cleaning")
        self.assertEqual("clean", self.server.broker._action_dirty_state("wechat-1"))
        self.call("/v1/release", {"channel_id": "channel-A", "token": owner["token"]})
        self.server.broker._mark_action_dirty(self.server.broker.channels["channel-A"],
                                               "stale")
        self.assertEqual("stale", self.server.broker._action_dirty_state("wechat-1"))
        self.assertEqual("action_dirty", self.atomic_run(
            "after-stale", "channel-B", wait_seconds=1)[1]["error"])

    def test_atomic_run_wait_disconnect_and_post_acquire_disconnect(self):
        _, owner = self.acquire("blocker", "channel-A")
        body = json.dumps({"channel_id": "channel-B", "task_id": "wait-run",
                           "request_id": "wait-run", "action": "check",
                           "wait_seconds": 2}).encode()
        request = (b"POST /v1/run HTTP/1.1\r\nHost: 127.0.0.1\r\n"
                   + f"Authorization: Bearer {self.credential}\r\n".encode()
                   + b"Content-Type: application/json\r\n"
                   + f"Content-Length: {len(body)}\r\n\r\n".encode() + body)
        connection = socket.create_connection(("127.0.0.1", self.server.server_port))
        connection.sendall(request)
        self.wait_for_queue(1)
        connection.close()
        self.wait_for_queue(0)
        self.call("/v1/release", {"channel_id": "channel-A", "token": owner["token"]})
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            _, result = self.atomic_run("wait-run", "channel-B")
            if result["error"] != "run_in_progress":
                break
            time.sleep(0.02)
        self.assertEqual("run_cancelled", result["error"])

        entered = threading.Event()
        finish = threading.Event()
        count = []
        def held(*_args, **_kwargs):
            count.append(1)
            entered.set()
            self.assertTrue(finish.wait(3))
            return ActionResult(0, False, b"done", b"", False, False, False)
        body = json.dumps({"channel_id": "channel-A", "task_id": "lost-reply",
                           "request_id": "lost-reply", "action": "check"}).encode()
        request = (b"POST /v1/run HTTP/1.1\r\nHost: 127.0.0.1\r\n"
                   + f"Authorization: Bearer {self.credential}\r\n".encode()
                   + b"Content-Type: application/json\r\n"
                   + f"Content-Length: {len(body)}\r\n\r\n".encode() + body)
        with patch("broker.run_action", side_effect=held):
            connection = socket.create_connection(("127.0.0.1", self.server.server_port))
            connection.sendall(request)
            self.assertTrue(entered.wait(2))
            connection.close()
            finish.set()
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline:
                status, result = self.atomic_run("lost-reply")
                if status == 200:
                    break
                time.sleep(0.02)
            self.assertEqual(200, status)
            self.assertEqual(1, len(count))
            self.assertEqual("done", result["stdout"])

    def test_atomic_run_uncertain_replay_and_crash_window(self):
        uncertain = ActionResult(None, True, b"", b"", False, False, True)
        with patch("broker.run_action", return_value=uncertain) as action:
            self.assertEqual(504, self.atomic_run("uncertain")[0])
            self.assertEqual(504, self.atomic_run("uncertain")[0])
        self.assertEqual(1, action.call_count)
        self.assertTrue(self.server.broker._action_dirty("wechat-1"))

        root = Path(self.temp.name)
        channel = self.server.broker.channels["channel-C"]
        self.assertIsNone(self.server.broker._claim_run("crash", "crash", channel, "check"))
        restarted = Broker(config_path=root / "config.json",
                           credential_path=root / "broker.token",
                           db_path=root / "leases.db", clock=lambda: self.now[0])
        with patch("broker.run_action") as action:
            response = restarted.run({"request_id": "crash", "task_id": "crash",
                                      "channel_id": "channel-C", "action": "check"})
        self.assertEqual("result_unknown", response["error"])
        action.assert_not_called()

    def test_atomic_run_interrupted_before_receipt_replays_unknown(self):
        payload = {"request_id": "interrupted", "task_id": "interrupted",
                   "channel_id": "channel-A", "action": "check"}
        with patch("broker.run_action", side_effect=KeyboardInterrupt):
            with self.assertRaises(KeyboardInterrupt):
                self.server.broker.run(payload)
        self.assertEqual({"ok": False, "error": "result_unknown",
                          "request_id": "interrupted"}, self.server.broker.run(payload))
        self.assertIsNone(self.server.broker.store.current("channel-A"))
        self.assertTrue(self.server.broker._action_dirty("wechat-1"))

    def test_wait_parameters_and_timeout(self):
        status, _ = self.acquire("owner", "channel-A")
        self.assertEqual(200, status)
        for value in (-1, 301, True, "1"):
            self.assertEqual(400, self.acquire(f"invalid-{value}", "channel-B",
                                               wait_seconds=value)[0])
        self.assertEqual(408, self.acquire("timed", "channel-B", wait_seconds=0.15)[0])
        self.assertEqual(410, self.acquire("timed", "channel-B", wait_seconds=1)[0])

    def test_unauthorized_and_binding_override_rejected(self):
        self.assertEqual(401, self.call("/v1/status", credential=False)[0])
        self.assertEqual(401, self.call("/v1/acquire", {}, credential=False)[0])
        status, _ = self.acquire("attempt-1", "channel-A", project_path=self.temp.name)
        self.assertEqual(400, status)
        status, lease = self.acquire("attempt-1", "channel-A")
        self.assertEqual(200, status)
        self.assertEqual("wechat-1", lease["endpoint_id"])
        self.assertNotEqual(self.temp.name, lease["project_path"])
        status, current = self.call("/v1/status?channel_id=channel-A")
        self.assertEqual(200, status)
        self.assertNotIn("token", current["channels"][0]["lease"])

    def test_http_endpoint_contention_and_distinct_parallelism(self):
        with ThreadPoolExecutor(max_workers=2) as pool:
            first = pool.submit(self.acquire, "attempt-A", "channel-A")
            second = pool.submit(self.acquire, "attempt-B", "channel-B")
            outcomes = [first.result(), second.result()]
        self.assertCountEqual([200, 409], [item[0] for item in outcomes])
        self.assertEqual("busy", next(body["error"] for code, body in outcomes if code == 409))
        status, distinct = self.acquire("attempt-C", "channel-C")
        self.assertEqual(200, status)
        self.assertNotEqual("wechat-1", distinct["endpoint_id"])
        status, current = self.call("/v1/status")
        self.assertEqual(200, status)
        self.assertEqual(2, sum(item["lease"] is not None for item in current["channels"]))

    def test_http_different_endpoints_can_acquire_concurrently(self):
        with ThreadPoolExecutor(max_workers=2) as pool:
            first = pool.submit(self.acquire, "attempt-A", "channel-A")
            second = pool.submit(self.acquire, "attempt-C", "channel-C")
            self.assertEqual(200, first.result()[0])
            self.assertEqual(200, second.result()[0])

    def test_expiry_retry_renew_release(self):
        status, first = self.acquire("attempt-1", "channel-A")
        self.assertEqual(200, status)
        self.assertEqual(first, self.acquire("attempt-1", "channel-A")[1])
        self.now[0] += 2
        status, renewed = self.call("/v1/renew", {"channel_id": "channel-A",
                                                  "token": first["token"], "ttl_seconds": 5})
        self.assertEqual(200, status)
        self.assertEqual(1007.0, renewed["expires_at"])
        self.now[0] = 1007.0
        self.assertEqual(410, self.acquire("attempt-1", "channel-A")[0])
        status, successor = self.acquire("attempt-2", "channel-B")
        self.assertEqual(200, status)
        self.assertGreater(successor["generation"], first["generation"])
        self.assertEqual(403, self.call("/v1/release", {"channel_id": "channel-B",
                                                        "token": first["token"]})[0])
        self.assertEqual(200, self.call("/v1/release", {"channel_id": "channel-B",
                                                        "token": successor["token"]})[0])
        self.assertEqual(410, self.acquire("attempt-2", "channel-B")[0])

    def test_no_guest_lease_has_no_guest_identity_or_ack_requirement(self):
        status, lease = self.acquire("ordinary", "channel-A")
        self.assertEqual(200, status)
        self.assertNotIn("guest_identity", lease)
        self.assertEqual(200, self.call("/v1/release", {
            "channel_id": "channel-A", "token": lease["token"]})[0])
        self.assertEqual(200, self.acquire("next", "channel-B")[0])

    def test_execute_requires_current_owner_and_fixed_action(self):
        status, first = self.acquire("attempt-1", "channel-A")
        self.assertEqual(200, status)
        payload = {"channel_id": "channel-A", "token": first["token"], "action": "check"}
        status, result = self.call("/v1/execute", payload)
        self.assertEqual(200, status)
        self.assertTrue(result["ok"])
        self.assertEqual("guarded", result["stdout"].strip())
        self.assertEqual(400, self.call("/v1/execute", {**payload, "argv": ["bad"]})[0])
        self.assertEqual(400, self.call("/v1/execute", {**payload, "action": "unknown"})[0])
        self.now[0] += 3
        self.assertEqual(410, self.call("/v1/execute", payload)[0])
        status, successor = self.acquire("attempt-2", "channel-B")
        self.assertEqual(200, status)
        self.assertEqual(403, self.call("/v1/execute", {**payload,
            "channel_id": "channel-B"})[0])
        self.assertEqual(200, self.call("/v1/execute", {**payload,
            "channel_id": "channel-B", "token": successor["token"]})[0])

    def test_execute_bounded_output_reaches_http_response(self):
        status, lease = self.acquire("loud-attempt", "channel-A")
        self.assertEqual(200, status)
        status, result = self.call("/v1/execute", {
            "channel_id": "channel-A", "token": lease["token"], "action": "loud"})
        self.assertEqual(200, status)
        self.assertTrue(result["ok"], result)
        self.assertEqual(16384, len(result["stdout"]))
        self.assertEqual(16384, len(result["stderr"]))
        self.assertTrue(result["stdout_truncated"])
        self.assertTrue(result["stderr_truncated"])

    def test_uncertain_action_blocks_successor_after_release_and_restart(self):
        status, lease = self.acquire("uncertain-action", "channel-A")
        self.assertEqual(200, status)
        uncertain = ActionResult(exit_code=None, timed_out=True, stdout=b"",
                                 stderr=b"", stdout_truncated=False,
                                 stderr_truncated=False, termination_uncertain=True)
        with patch("broker.run_action", return_value=uncertain):
            status, result = self.call("/v1/execute", {"channel_id": "channel-A",
                "token": lease["token"], "action": "check"})
        self.assertEqual(504, status)
        self.assertTrue(result["termination_uncertain"])
        self.assertEqual(200, self.call("/v1/release", {
            "channel_id": "channel-A", "token": lease["token"]})[0])
        status, denied = self.acquire("successor", "channel-B")
        self.assertEqual(503, status)
        self.assertEqual("action_dirty", denied["error"])
        status, state = self.call("/v1/status?channel_id=channel-A")
        self.assertEqual(200, status)
        self.assertTrue(state["channels"][0]["action_dirty"])
        root = Path(self.temp.name)
        restarted = Broker(config_path=root / "config.json",
                           credential_path=root / "broker.token",
                           db_path=root / "leases.db", clock=lambda: self.now[0])
        self.assertTrue(restarted.status("channel-A")["channels"][0]["action_dirty"])
        self.assertEqual("action_dirty", restarted.acquire({
            "channel_id": "channel-B", "task_id": "successor",
            "request_id": "successor-after-restart"})["error"])

    def test_action_is_marked_before_launch_and_cleared_after_confirmed_exit(self):
        status, lease = self.acquire("complete-action", "channel-A")
        self.assertEqual(200, status)
        def completed(*_args, **_kwargs):
            self.assertTrue(self.server.broker._action_dirty("wechat-1"))
            return ActionResult(exit_code=0, timed_out=False, stdout=b"ok",
                                stderr=b"", stdout_truncated=False,
                                stderr_truncated=False, termination_uncertain=False)
        with patch("broker.run_action", side_effect=completed):
            status, result = self.call("/v1/execute", {"channel_id": "channel-A",
                "token": lease["token"], "action": "check"})
        self.assertEqual(200, status)
        self.assertTrue(result["ok"])
        self.assertFalse(self.server.broker._action_dirty("wechat-1"))
        self.assertEqual(200, self.call("/v1/release", {
            "channel_id": "channel-A", "token": lease["token"]})[0])
        self.assertEqual(200, self.acquire("next", "channel-B")[0])

    def test_launch_failure_leaves_prelaunch_fence_until_offline_reconciliation(self):
        status, lease = self.acquire("crashed-action", "channel-A")
        self.assertEqual(200, status)
        def failed(*_args, **_kwargs):
            self.assertTrue(self.server.broker._action_dirty("wechat-1"))
            raise OSError("worker startup failed")
        with patch("broker.run_action", side_effect=failed):
            status, result = self.call("/v1/execute", {"channel_id": "channel-A",
                "token": lease["token"], "action": "check"})
        self.assertEqual(503, status)
        self.assertEqual("action_unavailable", result["error"])
        self.assertTrue(result["action_dirty"])
        self.assertEqual(200, self.call("/v1/release", {
            "channel_id": "channel-A", "token": lease["token"]})[0])
        root = Path(self.temp.name)
        restarted = Broker(config_path=root / "config.json",
                           credential_path=root / "broker.token",
                           db_path=root / "leases.db", clock=lambda: self.now[0])
        self.assertEqual("action_dirty", restarted.acquire({
            "channel_id": "channel-B", "task_id": "next",
            "request_id": "next-after-failure"})["error"])

    def test_success_exit_with_uncertain_cleanup_is_not_reported_as_success(self):
        status, lease = self.acquire("uncertain-cleanup", "channel-A")
        self.assertEqual(200, status)
        uncertain = ActionResult(exit_code=0, timed_out=False, stdout=b"ok",
                                 stderr=b"", stdout_truncated=False,
                                 stderr_truncated=False, termination_uncertain=True)
        with patch("broker.run_action", return_value=uncertain):
            status, result = self.call("/v1/execute", {"channel_id": "channel-A",
                "token": lease["token"], "action": "check"})
        self.assertEqual(503, status)
        self.assertEqual("action_uncertain", result["error"])
        self.assertTrue(self.server.broker._action_dirty("wechat-1"))

    def test_action_dirty_reconciliation_requires_stopped_action_and_no_lease(self):
        self.now[0] = time.time()
        status, lease = self.acquire("reconcile-action", "channel-A")
        self.assertEqual(200, status)
        root = Path(self.temp.name)
        db_path = str(root / "leases.db")
        self.server.broker._mark_action_dirty(
            self.server.broker.channels["channel-A"], "reconcile-action")
        with self.assertRaisesRegex(RuntimeError, "active lease"):
            reconcile(db_path, "wechat-1")
        self.assertEqual(200, self.call("/v1/release", {
            "channel_id": "channel-A", "token": lease["token"]})[0])
        self.assertEqual("reconcile-plan", reconcile(db_path, "wechat-1")["status"])
        with self.assertRaisesRegex(ValueError, "requires"):
            reconcile(db_path, "wechat-1", apply=True)
        cleared = reconcile(db_path, "wechat-1", apply=True,
                            broker_stopped=True, action_stopped_verified=True)
        self.assertEqual("cleared", cleared["status"])
        self.assertFalse(self.server.broker.status("channel-A")["channels"][0]["action_dirty"])

    def test_execute_serializes_release_and_successor(self):
        status, first = self.acquire("attempt-1", "channel-A")
        self.assertEqual(200, status)
        project = Path(first["project_path"])
        with ThreadPoolExecutor(max_workers=2) as pool:
            running = pool.submit(self.call, "/v1/execute", {
                "channel_id": "channel-A", "token": first["token"], "action": "hold"})
            deadline = time.monotonic() + 2
            while not (project / "started").exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue((project / "started").exists())
            releasing = pool.submit(self.call, "/v1/release", {
                "channel_id": "channel-A", "token": first["token"]})
            self.assertFalse(releasing.done())
            (project / "finish").touch()
            self.assertEqual(200, running.result(timeout=5)[0])
            self.assertEqual(200, releasing.result(timeout=5)[0])
        self.assertEqual(410, self.call("/v1/execute", {
            "channel_id": "channel-A", "token": first["token"], "action": "check"})[0])
        self.assertEqual(200, self.acquire("attempt-2", "channel-B")[0])

    def test_execute_different_endpoints_run_concurrently(self):
        _, first = self.acquire("attempt-A", "channel-A")
        _, second = self.acquire("attempt-C", "channel-C")
        project = Path(first["project_path"])
        with ThreadPoolExecutor(max_workers=2) as pool:
            running = pool.submit(self.call, "/v1/execute", {
                "channel_id": "channel-A", "token": first["token"], "action": "hold"})
            deadline = time.monotonic() + 2
            while not (project / "started").exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue((project / "started").exists())
            try:
                began = time.monotonic()
                status, result = self.call("/v1/execute", {
                    "channel_id": "channel-C", "token": second["token"], "action": "check"})
                self.assertEqual(200, status)
                self.assertTrue(result["ok"])
                self.assertLess(time.monotonic() - began, 1.5)
            finally:
                (project / "finish").touch()
            self.assertEqual(200, running.result(timeout=5)[0])

    def test_port_alias_and_unregistered_cli_port_rejected(self):
        root = Path(self.temp.name)
        config_path = root / "port-config.json"
        base = {"channel_id": "A", "endpoint_id": "devtools-A",
                "tool_id": "wechat-cli", "project_id": "A",
                "project_path": str(root / "project-A"),
                "exclusive_ports": [9420],
                "actions": {"check": {"argv": [sys.executable, "--port", "9420"],
                                       "timeout_seconds": 1}}}
        other = {**base, "channel_id": "B", "endpoint_id": "devtools-B",
                 "project_id": "B", "project_path": str(root / "project-B")}
        def make(channels):
            config_path.write_text(json.dumps({"channels": channels}), encoding="utf-8")
            return Broker(config_path=config_path, credential_path=root / "broker.token",
                          db_path=root / "ports.db")
        with self.assertRaisesRegex(ValueError, "shared TCP port"):
            make([base, other])
        with self.assertRaisesRegex(ValueError, "exclusive_port"):
            make([{**base, "actions": {"check": {"argv": [sys.executable,
                "--port", "9421"], "timeout_seconds": 1}}}])
        self.assertEqual(2, len(make([base, {**other, "endpoint_id": "devtools-A"}]).channels))

    def test_existing_package_can_start_without_candidate_bridge(self):
        package = Path(self.temp.name) / "old-package"
        package.mkdir()
        source = Path(__file__).resolve().parents[1]
        for name in ("broker.py", "lease.py", "bounded_action.py"):
            shutil.copy2(source / name, package / name)
        result = subprocess.run([sys.executable, str(package / "broker.py"), "--help"],
                                capture_output=True, text=True, timeout=5)
        self.assertEqual(0, result.returncode, result.stderr)

    def _workspace_broker(self):
        root = Path(self.temp.name)
        work_root, build_root = root / "worktrees", root / "builds"
        work_root.mkdir(exist_ok=True)
        build_root.mkdir(exist_ok=True)
        config = json.loads((root / "config.json").read_text(encoding="utf-8"))
        script = ("import json,os,pathlib,time; "
                  "p=pathlib.Path(os.environ['QICHENG_BUILD_OUTPUT']); "
                  "data=dict(cwd=os.getcwd(),worktree=os.environ['QICHENG_WORKTREE'],"
                  "build=str(p),started=time.time(),"
                  "ports=os.environ['QICHENG_EXCLUSIVE_PORTS']); "
                  "(p/'started').touch(); "
                  "time.sleep(1); data['finished']=time.time(); "
                  "pathlib.Path('source-output.json').write_text(json.dumps(data)); "
                  "(p/'result.json').write_text(json.dumps(data))")
        for entry, port in zip(config["channels"], (40101, 40102, 40103)):
            source = Path(entry["project_path"])
            subprocess.run(["git", "init", "-q", str(source)], check=True)
            (source / "tracked.txt").write_text("source", encoding="utf-8")
            subprocess.run(["git", "-C", str(source), "add", "tracked.txt"], check=True)
            subprocess.run(["git", "-C", str(source), "-c", "user.name=Test",
                            "-c", "user.email=test@example.invalid", "commit", "-qm",
                            "initial"], check=True)
            entry["workspace"] = {"worktree_root": str(work_root),
                                  "build_root": str(build_root), "ref": "HEAD"}
            entry["exclusive_ports"] = [port]
            entry["actions"] = {"build": {"argv": [sys.executable, "-c", script],
                                          "timeout_seconds": 3}}
        path = root / "workspace-config.json"
        path.write_text(json.dumps(config), encoding="utf-8")
        return Broker(config_path=path, credential_path=root / "broker.token",
                      db_path=root / "leases.db", clock=lambda: self.now[0]), config

    def test_workspace_isolated_parallel_and_retry_binding(self):
        broker, config = self._workspace_broker()
        first = broker.acquire({"channel_id": "channel-A", "task_id": "task",
                                "request_id": "request-A"})
        second = broker.acquire({"channel_id": "channel-C", "task_id": "task",
                                 "request_id": "request-C"})
        command = lambda channel, lease: broker.execute({
            "channel_id": channel, "token": lease["token"], "action": "build"})
        with ThreadPoolExecutor(max_workers=2) as pool:
            runs = list(pool.map(lambda pair: command(*pair),
                                 [("channel-A", first), ("channel-C", second)]))
        self.assertTrue(all(run["ok"] for run in runs), runs)
        self.assertNotEqual(runs[0]["workspace"]["worktree"],
                            runs[1]["workspace"]["worktree"])
        records = [json.loads((Path(run["workspace"]["build_output"])
                               / "result.json").read_text()) for run in runs]
        self.assertLess(max(record["started"] for record in records),
                        min(record["finished"] for record in records))
        for run, port, entry in zip(runs, (40101, 40103),
                                    (config["channels"][0], config["channels"][2])):
            workspace = run["workspace"]
            record = json.loads((Path(workspace["build_output"]) / "result.json").read_text())
            self.assertEqual(str(port), record["ports"])
            self.assertEqual(workspace["worktree"], record["cwd"])
            self.assertEqual(workspace["worktree"], record["worktree"])
            self.assertEqual(workspace["build_output"], record["build"])
            self.assertEqual(record, json.loads((Path(workspace["worktree"]) /
                                                 "source-output.json").read_text()))
            self.assertFalse((Path(entry["project_path"]) / "source-output.json").exists())
        again = command("channel-A", first)
        self.assertEqual(runs[0]["workspace"], again["workspace"])
        restarted = Broker(config_path=Path(self.temp.name) / "workspace-config.json",
                           credential_path=Path(self.temp.name) / "broker.token",
                           db_path=Path(self.temp.name) / "leases.db",
                           clock=lambda: self.now[0])
        self.assertEqual(runs[0]["workspace"], command("channel-A", first)["workspace"])
        self.assertEqual(runs[0]["workspace"], restarted.execute({
            "channel_id": "channel-A", "token": first["token"],
            "action": "build"})["workspace"])
        with self.assertRaises(ValueError):
            broker.execute({"channel_id": "channel-A", "token": first["token"],
                            "action": "build", "cwd": str(Path(self.temp.name))})
        broker.release({"channel_id": "channel-A", "token": first["token"]})
        with self.assertRaises(Exception):
            command("channel-A", first)

    def test_workspace_config_rejects_overlap_and_unrecorded_target(self):
        broker, config = self._workspace_broker()
        root = Path(self.temp.name)
        path = root / "workspace-config.json"
        config["channels"][0]["workspace"]["build_root"] = str(root / "project-C")
        path.write_text(json.dumps(config), encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "overlap"):
            Broker(config_path=path, credential_path=root / "broker.token",
                   db_path=root / "leases.db")
        config["channels"][0]["workspace"]["build_root"] = str(root / "builds")
        (root / "other-worktrees").mkdir()
        config["channels"][1]["workspace"]["worktree_root"] = str(root / "other-worktrees")
        config["channels"][1]["workspace"]["build_root"] = str(root / "worktrees")
        path.write_text(json.dumps(config), encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "conflict"):
            Broker(config_path=path, credential_path=root / "broker.token",
                   db_path=root / "leases.db")
        config["channels"][1]["workspace"]["build_root"] = str(root / "builds")
        config["channels"][1]["workspace"]["worktree_root"] = str(root / "worktrees")
        path.write_text(json.dumps(config), encoding="utf-8")
        lease = broker.acquire({"channel_id": "channel-A", "task_id": "task",
                                "request_id": "request-A"})
        first = broker.execute({"channel_id": "channel-A", "token": lease["token"],
                                "action": "build"})
        self.assertTrue(first["ok"])
        marker = Path(first["workspace"]["build_output"]) / ".qicheng-attempt.json"
        marker.write_text("{}", encoding="utf-8")
        denied = broker.execute({"channel_id": "channel-A", "token": lease["token"],
                                 "action": "build"})
        self.assertEqual("workspace_unavailable", denied["error"])
        self.assertEqual(1, len(list(Path(first["workspace"]["worktree"]).glob(
            "source-output.json"))))

    def test_two_channels_compile_same_source_in_parallel(self):
        _, config = self._workspace_broker()
        root = Path(self.temp.name)
        config["channels"][2]["project_path"] = config["channels"][0]["project_path"]
        path = root / "shared-source-config.json"
        path.write_text(json.dumps(config), encoding="utf-8")
        broker = Broker(config_path=path, credential_path=root / "broker.token",
                        db_path=root / "shared-source-leases.db", clock=lambda: self.now[0])
        leases = [broker.acquire({"channel_id": channel, "task_id": "same-project",
                                  "request_id": "request-" + channel})
                  for channel in ("channel-A", "channel-C")]
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(lambda pair: broker.execute({
                "channel_id": pair[0], "token": pair[1]["token"], "action": "build"}),
                zip(("channel-A", "channel-C"), leases)))
        self.assertTrue(all(result["ok"] for result in results), results)
        self.assertNotEqual(results[0]["workspace"]["worktree"],
                            results[1]["workspace"]["worktree"])
        self.assertNotEqual(results[0]["workspace"]["build_output"],
                            results[1]["workspace"]["build_output"])
        receipts = [json.loads((Path(result["workspace"]["build_output"])
                                / "result.json").read_text()) for result in results]
        self.assertLess(max(receipt["started"] for receipt in receipts),
                        min(receipt["finished"] for receipt in receipts))
        self.assertEqual(["40101", "40103"],
                         [receipt["ports"] for receipt in receipts])
        self.assertFalse((Path(config["channels"][0]["project_path"])
                          / "source-output.json").exists())
        del config["channels"][2]["workspace"]
        path.write_text(json.dumps(config), encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "roots must not overlap"):
            Broker(config_path=path, credential_path=root / "broker.token",
                   db_path=root / "shared-source-leases.db")

    def test_two_channels_same_source_with_separate_workspace_roots(self):
        _, config = self._workspace_broker()
        root = Path(self.temp.name)
        work_c, build_c = root / "worktrees-C", root / "builds-C"
        work_c.mkdir()
        build_c.mkdir()
        config["channels"][2]["project_path"] = config["channels"][0]["project_path"]
        config["channels"][2]["workspace"]["worktree_root"] = str(work_c)
        config["channels"][2]["workspace"]["build_root"] = str(build_c)
        path = root / "separate-roots-config.json"
        path.write_text(json.dumps(config), encoding="utf-8")
        broker = Broker(config_path=path, credential_path=root / "broker.token",
                        db_path=root / "separate-roots-leases.db",
                        clock=lambda: self.now[0])
        leases = [broker.acquire({"channel_id": channel, "task_id": "same-project",
                                  "request_id": "separate-" + channel})
                  for channel in ("channel-A", "channel-C")]
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(lambda pair: broker.execute({
                "channel_id": pair[0], "token": pair[1]["token"], "action": "build"}),
                zip(("channel-A", "channel-C"), leases)))
        self.assertTrue(all(result["ok"] for result in results), results)
        receipts = [json.loads((Path(result["workspace"]["build_output"])
                                / "result.json").read_text()) for result in results]
        self.assertLess(max(receipt["started"] for receipt in receipts),
                        min(receipt["finished"] for receipt in receipts))
        self.assertTrue(Path(results[0]["workspace"]["worktree"]).is_dir())
        self.assertTrue(Path(results[1]["workspace"]["worktree"]).is_dir())

    def test_workspace_same_endpoint_waits_for_fixed_action(self):
        broker, _ = self._workspace_broker()
        first = broker.acquire({"channel_id": "channel-A", "task_id": "task-A",
                                "request_id": "request-A"})
        with self.assertRaises(Exception):
            broker.acquire({"channel_id": "channel-B", "task_id": "task-B",
                            "request_id": "request-B"})
        with ThreadPoolExecutor(max_workers=2) as pool:
            running = pool.submit(broker.execute, {"channel_id": "channel-A",
                "token": first["token"], "action": "build"})
            deadline = time.monotonic() + 3
            while not list((Path(self.temp.name) / "builds").glob("*/*/started")):
                self.assertLess(time.monotonic(), deadline)
                time.sleep(.01)
            releasing = pool.submit(broker.release, {"channel_id": "channel-A",
                "token": first["token"]})
            self.assertFalse(releasing.done())
            self.assertTrue(running.result(timeout=5)["ok"])
            releasing.result(timeout=5)
        second = broker.acquire({"channel_id": "channel-B", "task_id": "task-B",
                                 "request_id": "request-B"})
        result = broker.execute({"channel_id": "channel-B", "token": second["token"],
                                 "action": "build"})
        self.assertTrue(result["ok"])
        self.assertEqual("40102", json.loads((Path(result["workspace"]["build_output"])
            / "result.json").read_text())["ports"])

    def test_workspace_ids_fit_deep_windows_roots(self):
        _, config = self._workspace_broker()
        root = Path(self.temp.name)
        deep = root / ("x" * 100)
        work_root, build_root = deep / "worktrees", deep / "builds"
        work_root.mkdir(parents=True)
        build_root.mkdir()
        for channel in config["channels"]:
            channel["workspace"]["worktree_root"] = str(work_root)
            channel["workspace"]["build_root"] = str(build_root)
        path = root / "deep-workspace-config.json"
        path.write_text(json.dumps(config), encoding="utf-8")
        broker = Broker(config_path=path, credential_path=root / "broker.token",
                        db_path=root / "deep-leases.db", clock=lambda: self.now[0])
        lease = broker.acquire({"channel_id": "channel-A", "task_id": "task",
                                "request_id": "deep-request"})
        result = broker.execute({"channel_id": "channel-A", "token": lease["token"],
                                 "action": "build"})
        self.assertTrue(result["ok"], result)
        self.assertLessEqual(len(Path(result["workspace"]["worktree"]).name), 17)


class GuestInputTests(unittest.TestCase):
    def test_atomic_run_rejects_guest(self):
        response = self.broker.run({"request_id": "guest-run", "task_id": "guest-run",
                                    "channel_id": "channel-A", "action": "check"})
        self.assertEqual("run_channel_disabled", response["error"])

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.credential = secrets.token_hex(32)
        (self.root / "broker.token").write_text(self.credential, encoding="ascii")
        projects = {}
        channels = []
        for letter, vm, bios in (
                ("A", "11111111-1111-4111-8111-111111111111", "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"),
                ("C", "22222222-2222-4222-8222-222222222222", "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")):
            project_path = self.root / f"project-{letter}"
            project_path.mkdir()
            channel_token = self.root / f"channel-{letter}.token"
            channel_token.write_text(secrets.token_hex(32), encoding="ascii")
            (self.root / f"guest-broker-{letter}.token").write_text(
                secrets.token_hex(32), encoding="ascii")
            projects[f"guest-{letter.lower()}"] = {
                "vm_id": vm, "bios_uuid": bios, "token_file": str(channel_token)}
            channels.append({
                "channel_id": f"channel-{letter}", "endpoint_id": f"guest-{letter}",
                "tool_id": "windows-guest", "project_id": f"project-{letter}",
                "project_path": str(project_path),
                "actions": {"check": {"argv": [sys.executable, "-c", "print('old-action')"],
                                      "timeout_seconds": 2}},
                "guest": {"host_config_path": str(self.root / "host.json"),
                          "project": f"guest-{letter.lower()}",
                          "broker_token_file": str(self.root / f"guest-broker-{letter}.token")}})
        (self.root / "host.json").write_text(json.dumps({
            "schema_version": 1, "projects": projects}), encoding="utf-8")
        self.config_path = self.root / "config.json"
        self.config_path.write_text(json.dumps({"channels": channels}), encoding="utf-8")
        self.events = []
        self.events_lock = threading.Lock()
        self.input_failure = False
        self.claim_failure = False
        self.guest_mode = "agent"
        self.release_failure = False
        self.after_claim = None
        self.hold_a = False
        self.started_a = threading.Event()
        self.resume_a = threading.Event()
        outer = self

        class FakeGuest:
            def __init__(self, binding, broker_token_file):
                self.letter = Path(broker_token_file).stem[-1]
                self.binding = binding
                outer.record((self.letter, "init"))

            def state(self):
                return {"mode": outer.guest_mode}

            def claim(self, owner, ttl_seconds):
                outer.record((self.letter, "claim", owner, ttl_seconds))
                if outer.claim_failure:
                    raise RuntimeError("identity mismatch secret diagnostic")
                if outer.after_claim:
                    outer.after_claim()

            def input(self, action, **fields):
                outer.record((self.letter, "input", action, fields))
                if self.letter == "A" and outer.hold_a:
                    outer.started_a.set()
                    if not outer.resume_a.wait(3):
                        raise TimeoutError("test input wait expired")
                if outer.input_failure:
                    raise RuntimeError("raw text and token must be redacted")

            def release(self):
                outer.record((self.letter, "release"))
                if outer.release_failure:
                    raise RuntimeError("raw guest token must be redacted")

        self.broker = Broker(config_path=self.config_path,
                             credential_path=self.root / "broker.token",
                             db_path=self.root / "leases.db",
                             guest_client_factory=FakeGuest)
        self.server = BrokerHTTPServer(self.broker, 0)
        self.addCleanup(self.server.server_close)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self._stop)
        self.base = f"http://127.0.0.1:{self.server.server_port}"

    def _stop(self):
        self.resume_a.set()
        self.server.shutdown()
        self.thread.join(5)

    def record(self, event):
        with self.events_lock:
            self.events.append(event)

    def call(self, path, body, credential=True):
        headers = {"Content-Type": "application/json"}
        if credential:
            headers["Authorization"] = "Bearer " + self.credential
        request = Request(self.base + path, data=json.dumps(body).encode("utf-8"),
                          headers=headers, method="POST")
        try:
            with urlopen(request, timeout=5) as response:
                return response.status, json.load(response)
        except HTTPError as error:
            return error.code, json.load(error)

    def acquire(self, letter, request_id):
        return self.call("/v1/acquire", {"channel_id": f"channel-{letter}",
                                         "task_id": request_id, "request_id": request_id})

    def test_waiter_aborts_on_guest_dirty_or_binding_change(self):
        status, owner = self.acquire("A", "owner")
        self.assertEqual(200, status)
        def wait_for(request_id):
            return self.call("/v1/acquire", {"channel_id": "channel-A",
                "task_id": request_id, "request_id": request_id,
                "wait_seconds": 2})
        def queued():
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline:
                with closing(sqlite3.connect(self.root / "leases.db")) as db:
                    if db.execute("SELECT COUNT(*) FROM waiters").fetchone()[0] == 1:
                        return
                time.sleep(0.02)
            self.fail("guest waiter was not queued")
        with ThreadPoolExecutor(max_workers=1) as pool:
            dirty_waiter = pool.submit(wait_for, "dirty-next")
            queued()
            with closing(sqlite3.connect(self.root / "leases.db")) as db:
                db.execute("INSERT INTO guest_dirty VALUES (?, ?, ?)",
                           ("guest-A", "channel-A", "owner"))
                db.commit()
            self.assertEqual((409, {"ok": False, "error": "guest_dirty"}),
                             dirty_waiter.result(timeout=3))
            with closing(sqlite3.connect(self.root / "leases.db")) as db:
                self.assertEqual(0, db.execute("SELECT COUNT(*) FROM waiters").fetchone()[0])
                db.execute("DELETE FROM guest_dirty")
                db.commit()
            binding_waiter = pool.submit(wait_for, "binding-next")
            queued()
            (self.root / "channel-A.token").write_text(secrets.token_hex(32), encoding="ascii")
            self.assertEqual((503, {"ok": False, "error": "guest_binding_unavailable"}),
                             binding_waiter.result(timeout=3))
            with closing(sqlite3.connect(self.root / "leases.db")) as db:
                self.assertEqual(0, db.execute("SELECT COUNT(*) FROM waiters").fetchone()[0])

    def payload(self, letter, token, **fields):
        if fields.get("action") in {"click", "move", "key", "type"}:
            fields.setdefault("action_id", "action-1")
        return {"channel_id": f"channel-{letter}", "token": token, **fields}

    def restart_input(self, body):
        source = Path(__file__).resolve().parents[1]
        code = ("import json,sys;sys.path.insert(0,sys.argv[4]);"
                "from broker import Broker;"
                "broker=Broker(config_path=sys.argv[1],credential_path=sys.argv[2],"
                "db_path=sys.argv[3]);"
                "print(json.dumps(broker.input(json.load(sys.stdin))))")
        result = subprocess.run([
            sys.executable, "-I", "-c", code, str(self.config_path),
            str(self.root / "broker.token"), str(self.root / "leases.db"), str(source)],
            input=json.dumps(body), capture_output=True, text=True, timeout=5)
        self.assertEqual(0, result.returncode, result.stderr)
        return json.loads(result.stdout)

    def restart_acquire(self, letter, request_id, now=None):
        source = Path(__file__).resolve().parents[1]
        code = ("import json,sys;sys.path.insert(0,sys.argv[4]);"
                "from broker import Broker;"
                "broker=Broker(config_path=sys.argv[1],credential_path=sys.argv[2],"
                "db_path=sys.argv[3],clock=lambda:float(sys.argv[7])"
                " if sys.argv[7]!='real' else __import__('time').time());"
                "print(json.dumps(broker.acquire({'channel_id':sys.argv[5],"
                "'task_id':sys.argv[6],'request_id':sys.argv[6]})))")
        result = subprocess.run([
            sys.executable, "-I", "-c", code, str(self.config_path),
            str(self.root / "broker.token"), str(self.root / "leases.db"),
            str(source), f"channel-{letter}", request_id,
            "real" if now is None else str(now)],
            capture_output=True, text=True, timeout=5)
        self.assertEqual(0, result.returncode, result.stderr)
        return json.loads(result.stdout)

    def test_input_claim_release_and_guest_execute_denial(self):
        status, lease = self.acquire("A", "attempt-A")
        self.assertEqual(200, status)
        self.assertEqual({"vm_id": "11111111-1111-4111-8111-111111111111",
                          "bios_uuid": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
                          "project": "guest-a"}, lease["guest_identity"])
        renewed = self.call("/v1/renew", {"channel_id": "channel-A",
                                           "token": lease["token"]})[1]
        self.assertEqual(lease["guest_identity"], renewed["guest_identity"])
        body = self.payload("A", lease["token"], action="click", x=20, y=30, button=1)
        self.assertEqual((200, {"ok": True, "action": "click"}), self.call("/v1/input", body))
        self.assertEqual([("A", "init"), ("A", "claim", "attempt-A", 30),
                          ("A", "input", "click", {"x": 20, "y": 30, "button": 1}),
                          ("A", "release")], self.events)
        status, result = self.call("/v1/execute", self.payload(
            "A", lease["token"], action="check"))
        self.assertEqual(403, status)
        self.assertEqual({"ok": False, "error": "guest_execute_disabled"}, result)

    def test_rejects_field_binding_and_token_overrides(self):
        _, lease = self.acquire("A", "attempt-A")
        self.assertEqual(200, self.acquire("C", "attempt-C")[0])
        base = self.payload("A", lease["token"], action="type", text="private input")
        self.assertEqual(400, self.call("/v1/input", {
            key: value for key, value in base.items() if key != "action_id"})[0])
        self.assertEqual(401, self.call("/v1/input", base, credential=False)[0])
        self.assertEqual(403, self.call("/v1/input", {**base, "token": secrets.token_hex(32)})[0])
        self.assertEqual(403, self.call("/v1/input", {**base, "channel_id": "channel-C"})[0])
        for wrong in ({**base, "vm_id": "fake"}, {**base, "project_path": self.temp.name},
                      {**base, "text": "x" * 2001}, {**base, "text": "bad\x00text"},
                      {**base, "action": "key", "key": "secret-key"},
                      self.payload("A", lease["token"], action="click", x=-1, y=1)):
            status, response = self.call("/v1/input", wrong)
            self.assertEqual(400, status)
            self.assertNotIn("private input", json.dumps(response))
        self.assertEqual([], self.events)

    def test_claim_input_and_release_fail_closed_without_raw_diagnostics(self):
        _, lease = self.acquire("A", "attempt-A")
        body = self.payload("A", lease["token"], action="type", text="private input")
        self.claim_failure = True
        self.assertEqual((503, {"ok": False, "error": "guest_unavailable"}),
                         self.call("/v1/input", body))
        self.assertFalse(any(event[1] == "input" for event in self.events))
        with closing(sqlite3.connect(self.root / "leases.db")) as db:
            self.assertEqual(0, db.execute(
                "SELECT COUNT(*) FROM guest_input_attempts").fetchone()[0])
            self.assertEqual(0, db.execute(
                "SELECT COUNT(*) FROM guest_dirty").fetchone()[0])
        self.claim_failure = False
        self.events.clear()
        self.assertEqual((200, {"ok": True, "action": "type"}),
                         self.call("/v1/input", body))
        self.assertEqual(1, sum(event[1] == "input" for event in self.events))
        self.assertEqual(200, self.call("/v1/ack", {
            "channel_id": "channel-A", "token": lease["token"],
            "action_id": "action-1"})[0])
        self.assertEqual(200, self.call("/v1/release", {
            "channel_id": "channel-A", "token": lease["token"]})[0])
        self.assertEqual(200, self.acquire("A", "after-claim-failure")[0])

    def test_paused_preflight_has_no_attempt_or_dirty_and_can_recover(self):
        _, lease = self.acquire("A", "attempt-A")
        body = self.payload("A", lease["token"], action="key", key="Return")
        self.guest_mode = "paused"
        self.assertEqual((503, {"ok": False, "error": "guest_unavailable"}),
                         self.call("/v1/input", body))
        self.assertFalse(any(event[1] in ("claim", "input") for event in self.events))
        with closing(sqlite3.connect(self.root / "leases.db")) as db:
            self.assertEqual(0, db.execute(
                "SELECT COUNT(*) FROM guest_input_attempts").fetchone()[0])
            self.assertEqual(0, db.execute(
                "SELECT COUNT(*) FROM guest_dirty").fetchone()[0])
        self.guest_mode = "agent"
        self.assertEqual((200, {"ok": True, "action": "key"}),
                         self.call("/v1/input", body))

    def test_slow_guest_claim_cannot_input_after_local_lease_expires(self):
        now = [1000.0]
        self.broker.store.clock = lambda: now[0]
        _, lease = self.acquire("A", "slow-claim")
        self.after_claim = lambda: now.__setitem__(0, lease["expires_at"] + 1)
        body = self.payload("A", lease["token"], action="key", key="Return")
        self.assertEqual((410, {"ok": False, "error": "lease_expired"}),
                         self.call("/v1/input", body))
        self.assertFalse(any(event[1] == "input" for event in self.events))
        self.assertIn(("A", "release"), self.events)
        with closing(sqlite3.connect(self.root / "leases.db")) as db:
            self.assertEqual(0, db.execute(
                "SELECT COUNT(*) FROM guest_input_attempts").fetchone()[0])
            self.assertEqual(0, db.execute(
                "SELECT COUNT(*) FROM guest_dirty").fetchone()[0])
        self.assertEqual(200, self.acquire("A", "after-slow-claim")[0])

    def test_expiry_after_attempt_record_does_not_send_input(self):
        now = [1000.0]
        self.broker.store.clock = lambda: now[0]
        _, lease = self.acquire("A", "slow-record")
        original = self.broker._begin_input_attempt
        def delayed(*args, **kwargs):
            result = original(*args, **kwargs)
            if result == "new":
                now[0] = lease["expires_at"] + 1
            return result
        self.broker._begin_input_attempt = delayed
        self.addCleanup(setattr, self.broker, "_begin_input_attempt", original)
        body = self.payload("A", lease["token"], action="key", key="Return")
        self.assertEqual((410, {"ok": False, "error": "lease_expired"}),
                         self.call("/v1/input", body))
        self.assertFalse(any(event[1] == "input" for event in self.events))
        self.assertEqual((409, {"ok": False, "error": "guest_dirty"}),
                         self.acquire("A", "after-slow-record"))

    def test_input_failure_and_release_uncertain_keep_dirty(self):
        _, lease = self.acquire("A", "attempt-A")
        body = self.payload("A", lease["token"], action="type", text="private input")
        self.input_failure = True
        self.assertEqual((502, {"ok": False, "error": "input_failed"}),
                         self.call("/v1/input", body))
        self.assertEqual(409, self.call("/v1/ack", {
            "channel_id": "channel-A", "token": lease["token"],
            "action_id": "action-1"})[0])
        self.assertEqual(200, self.call("/v1/release", {
            "channel_id": "channel-A", "token": lease["token"]})[0])
        self.assertEqual((409, {"ok": False, "error": "guest_dirty"}),
                         self.acquire("A", "new-A"))

    def test_guest_release_failure_keeps_dirty(self):
        _, lease = self.acquire("A", "attempt-A")
        body = self.payload("A", lease["token"], action="key", key="Return")
        self.release_failure = True
        self.assertEqual((503, {"ok": False, "error": "guest_release_uncertain"}),
                         self.call("/v1/input", body))
        self.release_failure = False
        self.assertEqual((409, {"ok": False, "error": "already_attempted"}),
                         self.call("/v1/input", body))
        self.assertEqual(409, self.call("/v1/ack", {
            "channel_id": "channel-A", "token": lease["token"],
            "action_id": "action-1"})[0])

    def test_same_channel_input_serializes_release_and_other_guest_runs(self):
        _, first = self.acquire("A", "attempt-A")
        _, other = self.acquire("C", "attempt-C")
        self.hold_a = True
        first_body = self.payload("A", first["token"], action="move", x=2, y=3)
        with ThreadPoolExecutor(max_workers=2) as pool:
            running = pool.submit(self.call, "/v1/input", first_body)
            self.assertTrue(self.started_a.wait(2))
            same = pool.submit(self.call, "/v1/input", {
                **first_body, "action_id": "action-2"})
            self.assertFalse(same.done())
            began = time.monotonic()
            status, _ = self.call("/v1/input", self.payload(
                "C", other["token"], action="key", key="Return"))
            self.assertEqual(200, status)
            self.assertLess(time.monotonic() - began, 1.5)
            self.resume_a.set()
            self.assertEqual(200, running.result(timeout=5)[0])
            self.assertEqual((409, {"ok": False, "error": "ack_required"}),
                             same.result(timeout=5))
        self.assertEqual((200, {"ok": True, "action_id": "action-1"}),
                         self.call("/v1/ack", self.payload("A", first["token"],
                                                           action_id="action-1")))
        self.assertEqual(200, self.call("/v1/input", {
            **first_body, "action_id": "action-2"})[0])
        self.assertEqual(200, self.call("/v1/ack", self.payload(
            "A", first["token"], action_id="action-2"))[0])
        a_events = [event[1] for event in self.events if event[0] == "A"]
        self.assertEqual(["init", "claim", "input", "release",
                          "init", "claim", "input", "release"], a_events)
        self.assertEqual(200, self.call("/v1/release",
                                        self.payload("A", first["token"]))[0])

    def test_guest_binding_validation_and_owner_limit(self):
        self.assertEqual(400, self.acquire("A", "owner:invalid")[0])
        self.assertEqual(400, self.acquire("A", "x" * 65)[0])
        config = json.loads(self.config_path.read_text(encoding="utf-8"))
        config["channels"][0]["guest"]["broker_token_file"] = str(self.root / "channel-A.token")
        self.config_path.write_text(json.dumps(config), encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "token files must differ"):
            Broker(config_path=self.config_path, credential_path=self.root / "broker.token",
                   db_path=self.root / "other.db")
        config["channels"][0]["guest"]["broker_token_file"] = str(self.root / "broker.token")
        self.config_path.write_text(json.dumps(config), encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "local bearer credential"):
            Broker(config_path=self.config_path, credential_path=self.root / "broker.token",
                   db_path=self.root / "other.db")

    def test_equal_guest_tokens_and_verified_identity_failure_fail_closed(self):
        _, lease = self.acquire("A", "attempt-A")
        body = self.payload("A", lease["token"], action="key", key="Return")
        channel_secret = (self.root / "channel-A.token").read_text(encoding="ascii")
        broker_secret = (self.root / "guest-broker-A.token").read_text(encoding="ascii")
        (self.root / "guest-broker-A.token").write_text(channel_secret, encoding="ascii")
        with self.assertRaisesRegex(RuntimeError, "channel and broker credentials must differ"):
            Broker(config_path=self.config_path,
                   credential_path=self.root / "broker.token",
                   db_path=self.root / "leases.db")
        self.assertEqual([], self.events)
        (self.root / "guest-broker-A.token").write_text(broker_secret, encoding="ascii")
        self.claim_failure = True
        status, response = self.call("/v1/input", {**body, "action_id": "action-2"})
        self.assertEqual(503, status)
        self.assertEqual({"ok": False, "error": "guest_unavailable"}, response)
        self.assertFalse(any(event[1] == "input" for event in self.events))

    def test_action_id_replays_success_and_rejects_changed_fields_after_restart(self):
        _, lease = self.acquire("A", "attempt-A")
        body = self.payload("A", lease["token"], action="type", text="private input")
        # Model a lost HTTP response: the first action completed, then the caller
        # sends the exact same request without seeing that response.
        self.call("/v1/input", body)
        self.assertEqual((200, {"ok": True, "action": "type"}),
                         self.call("/v1/input", body))
        self.assertEqual(1, sum(event[1] == "input" for event in self.events))
        self.assertEqual({"ok": True, "action": "type"}, self.restart_input(body))
        self.assertEqual({"ok": False, "error": "action_conflict"},
                         self.restart_input({**body, "text": "changed"}))
        self.assertEqual(1, sum(event[1] == "input" for event in self.events))
        with closing(sqlite3.connect(self.root / "leases.db")) as db:
            row = db.execute("""SELECT channel_id, request_id, action_id,
                fingerprint, status FROM guest_input_attempts""").fetchone()
        self.assertEqual(("channel-A", "attempt-A", "action-1"), row[:3])
        self.assertEqual("success", row[4])
        self.assertEqual(64, len(row[3]))
        self.assertNotIn("private input", str(row))
        self.assertNotIn(lease["token"], str(row))

    def test_uncertain_tombstone_blocks_retry_after_restart(self):
        _, lease = self.acquire("A", "attempt-A")
        body = self.payload("A", lease["token"], action="click", x=1, y=2)
        active = self.broker.store.current("channel-A")
        channel = self.broker.channels["channel-A"]
        fingerprint = self.broker._attempt_fingerprint(channel, active, "click",
                                                        {"x": 1, "y": 2})
        self.assertEqual("new", self.broker._begin_input_attempt(
            "channel-A", "guest-A", "attempt-A", "action-1", fingerprint))
        self.assertEqual({"ok": False, "error": "already_attempted"},
                         self.restart_input(body))
        self.assertEqual([], self.events)
        self.assertEqual((409, {"ok": False, "error": "already_attempted"}),
                         self.call("/v1/input", body))

    def test_error_retry_never_resends_input(self):
        _, lease = self.acquire("A", "attempt-A")
        body = self.payload("A", lease["token"], action="type", text="private input")
        self.input_failure = True
        self.assertEqual(502, self.call("/v1/input", body)[0])
        self.input_failure = False
        self.assertEqual((409, {"ok": False, "error": "already_attempted"}),
                         self.call("/v1/input", body))
        self.assertEqual(1, sum(event[1] == "input" for event in self.events))

    def test_ack_idempotent_then_release_unlocks_endpoint(self):
        _, lease = self.acquire("A", "attempt-A")
        body = self.payload("A", lease["token"], action="key", key="Return")
        self.assertEqual(200, self.call("/v1/input", body)[0])
        ack = {"channel_id": "channel-A", "token": lease["token"],
               "action_id": "action-1"}
        self.assertEqual(403, self.call("/v1/ack", {
            **ack, "token": secrets.token_hex(32)})[0])
        self.assertEqual(409, self.call("/v1/ack", {
            **ack, "action_id": "missing"})[0])
        self.assertEqual(400, self.call("/v1/ack", {
            **ack, "request_id": "attempt-A"})[0])
        self.assertEqual((200, {"ok": True, "action_id": "action-1"}),
                         self.call("/v1/ack", ack))
        self.assertEqual((200, {"ok": True, "action_id": "action-1"}),
                         self.call("/v1/ack", ack))
        self.assertEqual(200, self.call("/v1/release", {
            "channel_id": "channel-A", "token": lease["token"]})[0])
        self.assertEqual(200, self.acquire("A", "next-A")[0])
        with closing(sqlite3.connect(self.root / "leases.db")) as db:
            self.assertEqual(0, db.execute("SELECT COUNT(*) FROM guest_dirty").fetchone()[0])

    def test_legacy_guest_attempt_schema_fails_closed(self):
        _, lease = self.acquire("A", "attempt-A")
        self.assertEqual(200, self.call("/v1/input", self.payload(
            "A", lease["token"], action="key", key="Return"))[0])
        with closing(sqlite3.connect(self.root / "leases.db")) as db:
            db.execute("DROP TABLE guest_dirty")
            db.commit()
        with self.assertRaisesRegex(RuntimeError, "offline reconciliation"):
            Broker(config_path=self.config_path,
                   credential_path=self.root / "broker.token",
                   db_path=self.root / "leases.db",
                   guest_client_factory=self.broker.guest_client_factory)

    def test_success_without_ack_release_and_expiry_remain_dirty(self):
        _, lease = self.acquire("A", "attempt-A")
        body = self.payload("A", lease["token"], action="key", key="Return")
        self.assertEqual(200, self.call("/v1/input", body)[0])
        self.assertEqual(200, self.call("/v1/release", {
            "channel_id": "channel-A", "token": lease["token"]})[0])
        self.assertEqual((409, {"ok": False, "error": "guest_dirty"}),
                         self.acquire("A", "next-A"))
        self.assertEqual({"ok": False, "error": "guest_dirty"},
                         self.restart_acquire("A", "process-A"))
        self.assertEqual(410, self.call("/v1/ack", {
            "channel_id": "channel-A", "token": lease["token"],
            "action_id": "action-1"})[0])

    def test_uncertain_attempt_blocks_alias_and_new_action_after_expiry(self):
        _, lease = self.acquire("A", "attempt-A")
        body = self.payload("A", lease["token"], action="click", x=1, y=2)
        self.input_failure = True
        self.assertEqual(502, self.call("/v1/input", body)[0])
        self.input_failure = False
        config = json.loads(self.config_path.read_text(encoding="utf-8"))
        alias_root = self.root / "project-B"
        alias_root.mkdir()
        alias = dict(config["channels"][0])
        alias.update(channel_id="channel-B", project_id="project-B",
                     project_path=str(alias_root))
        config["channels"].append(alias)
        self.config_path.write_text(json.dumps(config), encoding="utf-8")
        alias_broker = Broker(config_path=self.config_path,
                              credential_path=self.root / "broker.token",
                              db_path=self.root / "leases.db",
                              guest_client_factory=self.broker.guest_client_factory)
        self.assertEqual({"ok": False, "error": "guest_dirty"},
                         alias_broker.acquire({"channel_id": "channel-B",
                                               "request_id": "alias-B", "task_id": "alias-B"}))
        self.assertEqual((409, {"ok": False, "error": "ack_required"}),
                         self.call("/v1/input", {**body, "action_id": "action-2"}))
        self.broker.store.clock = lambda: lease["expires_at"] + 1
        self.assertEqual((409, {"ok": False, "error": "guest_dirty"}),
                         self.acquire("A", "expired-successor"))
        self.assertEqual({"ok": False, "error": "guest_dirty"},
                         self.restart_acquire("A", "process-expired",
                                              now=lease["expires_at"] + 1))

    def test_dirty_inserted_while_acquire_waits_is_checked_again(self):
        _, lease = self.acquire("A", "attempt-A")
        entered = threading.Event()
        prechecked = threading.Event()
        resume = threading.Event()
        original = self.broker._begin_input_attempt
        original_owner = self.broker._dirty_owner
        def paused(*args, **kwargs):
            if kwargs.get("record") is False:
                return original(*args, **kwargs)
            entered.set()
            if not resume.wait(3):
                raise TimeoutError("test pause expired")
            return original(*args, **kwargs)
        def probe(endpoint_id):
            result = original_owner(endpoint_id)
            if result is None:
                prechecked.set()
            return result
        self.broker._begin_input_attempt = paused
        self.broker._dirty_owner = probe
        self.addCleanup(setattr, self.broker, "_begin_input_attempt", original)
        self.addCleanup(setattr, self.broker, "_dirty_owner", original_owner)
        with ThreadPoolExecutor(max_workers=2) as pool:
            sending = pool.submit(self.call, "/v1/input", self.payload(
                "A", lease["token"], action="key", key="Return"))
            self.assertTrue(entered.wait(2))
            self.broker.store.clock = lambda: lease["expires_at"] + 1
            successor = pool.submit(self.acquire, "A", "racing-successor")
            self.assertTrue(prechecked.wait(2))
            resume.set()
            self.assertEqual((410, {"ok": False, "error": "lease_expired"}),
                             sending.result(timeout=5))
            self.assertEqual((409, {"ok": False, "error": "guest_dirty"}),
                             successor.result(timeout=5))

    def test_guest_binding_drift_fails_closed(self):
        _, lease = self.acquire("A", "attempt-A")
        body = self.payload("A", lease["token"], action="key", key="Return")
        token_path = self.root / "channel-A.token"
        old_token = token_path.read_text(encoding="ascii")
        token_path.write_text(secrets.token_hex(32), encoding="ascii")
        self.assertEqual((503, {"ok": False, "error": "attempt_unavailable"}),
                         self.call("/v1/input", body))
        self.assertEqual([], self.events)
        self.assertEqual(503, self.call("/v1/acquire", {
            "request_id": "new-A", "task_id": "new-A", "channel_id": "channel-A"})[0])
        token_path.write_text(old_token, encoding="ascii")
        host = json.loads((self.root / "host.json").read_text(encoding="utf-8"))
        host["projects"]["guest-a"]["vm_id"] = "33333333-3333-4333-8333-333333333333"
        (self.root / "host.json").write_text(json.dumps(host), encoding="utf-8")
        with self.assertRaisesRegex(RuntimeError, "registered guest binding changed"):
            Broker(config_path=self.config_path,
                   credential_path=self.root / "broker.token",
                   db_path=self.root / "leases.db",
                   guest_client_factory=self.broker.guest_client_factory)


class BrokerLiteTests(unittest.TestCase):
    def test_atomic_run_rejects_lite(self):
        response = self.broker.run({"request_id": "lite-run", "task_id": "lite-run",
                                    "channel_id": "lite-1", "action": "check"})
        self.assertEqual("run_channel_disabled", response["error"])

    def test_maintenance_blocks_guest_input_without_sending(self):
        first = self.acquire(1, "owner-1")
        self.assertEqual({"ok": True, "action": "key"}, self.broker.input({
            "channel_id": "lite-1", "token": first["token"],
            "action_id": "completed", "action": "key", "key": "Return"}))
        sent_before = list(self.events)
        self.broker.store.set_maintenance(True)
        with self.assertRaisesRegex(Exception, "maintenance"):
            self.broker.input({"channel_id": "lite-1", "token": first["token"],
                               "action_id": "action-1", "action": "key",
                               "key": "Return"})
        self.assertEqual(sent_before, self.events)
        self.assertEqual({"ok": True, "action_id": "completed"}, self.broker.ack({
            "channel_id": "lite-1", "token": first["token"],
            "action_id": "completed"}))
        self.broker.renew({"channel_id": "lite-1", "token": first["token"]})
        self.broker.release({"channel_id": "lite-1", "token": first["token"]})

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.credential = self.root / "local.token"
        self.credential.write_text(secrets.token_hex(32), encoding="ascii")
        channels = []
        for number in (1, 2):
            project = self.root / f"project-{number}"
            project.mkdir()
            broker_token = self.root / f"lite-broker-{number}.token"
            channel_token = self.root / f"lite-channel-{number}.token"
            broker_token.write_text(secrets.token_hex(32), encoding="ascii")
            channel_token.write_text(secrets.token_hex(32), encoding="ascii")
            channels.append({"channel_id": f"lite-{number}", "endpoint_id": f"lite-{number}",
                             "tool_id": "lite", "project_id": f"project-{number}",
                             "project_path": str(project), "lite": {
                                 "port": 18760 + number, "channel_number": number,
                                 "broker_token_file": str(broker_token),
                                 "channel_token_file": str(channel_token)}})
        self.config = self.root / "config.json"
        self.config.write_text(json.dumps({"channels": channels}), encoding="utf-8")
        self.events = []
        outer = self
        class FakeLite:
            def __init__(self, binding, channel_id):
                self.number = binding["channel_number"]
                self.channel_id = channel_id
            def state(self):
                outer.events.append((self.number, "state"))
                return {"channel_id": self.channel_id, "mode": "agent"}
            def claim(self, owner, generation, nonce, ttl):
                outer.events.append((self.number, "claim", owner, generation, nonce, ttl))
            def input(self, action, **fields):
                outer.events.append((self.number, "input", action, fields))
                if outer.fail_input:
                    raise TimeoutError("uncertain")
            def release(self):
                outer.events.append((self.number, "release"))
        self.fail_input = False
        self.broker = Broker(config_path=self.config, credential_path=self.credential,
                             db_path=self.root / "leases.db", lite_client_factory=FakeLite)

    def acquire(self, number, request):
        return self.broker.acquire({"channel_id": f"lite-{number}",
                                    "request_id": request, "task_id": request})

    def test_same_channel_contention_and_two_channel_parallelism(self):
        first = self.acquire(1, "owner-1")
        self.assertEqual(first["lite_identity"], {
            "channel_id": "lite-1", "channel_number": 1, "port": 18761})
        with self.assertRaises(ChannelBusy):
            self.acquire(1, "contender")
        second = self.acquire(2, "owner-2")
        self.assertNotEqual(first["endpoint_id"], second["endpoint_id"])
        self.assertEqual(second["lite_identity"], self.broker.renew({
            "channel_id": "lite-2", "token": second["token"]})["lite_identity"])

    def test_input_claim_ack_dirty_and_fingerprint(self):
        first = self.acquire(1, "owner-1")
        body = {"channel_id": "lite-1", "token": first["token"],
                "action_id": "action-1", "action": "key", "key": "Return"}
        self.assertEqual({"ok": True, "action": "key"}, self.broker.input(body))
        self.assertEqual(["state", "claim", "input", "release"],
                         [event[1] for event in self.events])
        self.assertEqual("owner-1", self.events[1][2])
        self.assertEqual(first["generation"], self.events[1][3])
        self.assertEqual(32, len(self.events[1][4]))
        self.assertEqual({"ok": False, "error": "ack_required"},
                         self.broker.input({**body, "action_id": "action-2"}))
        self.assertEqual({"ok": True, "action_id": "action-1"}, self.broker.ack({
            "channel_id": "lite-1", "token": first["token"], "action_id": "action-1"}))
        self.broker.release({"channel_id": "lite-1", "token": first["token"]})
        self.assertIsNone(self.broker._dirty_owner("lite-1"))
        self.assertIn("token", self.acquire(1, "next"))

    def test_uncertain_input_blocks_successor_and_token_drift(self):
        first = self.acquire(1, "owner-1")
        self.fail_input = True
        body = {"channel_id": "lite-1", "token": first["token"],
                "action_id": "action-1", "action": "key", "key": "Return"}
        self.assertEqual({"ok": False, "error": "input_failed"}, self.broker.input(body))
        self.broker.release({"channel_id": "lite-1", "token": first["token"]})
        self.assertEqual({"ok": False, "error": "guest_dirty"}, self.acquire(1, "next"))
        token = self.root / "lite-channel-2.token"
        token.write_text(secrets.token_hex(32), encoding="ascii")
        self.assertEqual({"ok": False, "error": "lite_binding_unavailable"},
                         self.acquire(2, "owner-2"))
        with self.assertRaisesRegex(RuntimeError, "registered guest binding changed"):
            Broker(config_path=self.config, credential_path=self.credential,
                   db_path=self.root / "leases.db", lite_client_factory=self.broker.lite_client_factory)

    def test_invalid_lite_binding_rejected(self):
        config = json.loads(self.config.read_text(encoding="utf-8"))
        config["channels"][0]["lite"]["port"] = 18762
        self.config.write_text(json.dumps(config), encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "port must match"):
            Broker(config_path=self.config, credential_path=self.credential,
                   db_path=self.root / "other.db", lite_client_factory=self.broker.lite_client_factory)

    def test_lite_client_matches_backend_status_contract(self):
        server_path = Path(__file__).resolve().parents[2] / "agent-channels" / "backend" / "server.py"
        if not server_path.is_file():
            self.skipTest("Lite backend is a separate optional package")
        spec = importlib.util.spec_from_file_location("lite_backend_contract", server_path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        class Display:
            def input(self, _args, _stdin):
                pass
        channel = module.Channel(Display(), broker_enabled=True, channel_id="1")
        channel.control("agent")
        binding = self.broker.channels["lite-1"].lite
        server = ThreadingHTTPServer(("127.0.0.1", 0), module.handler_for(
            channel, binding["channel_token_file"].read_text(encoding="ascii"),
            binding["broker_token_file"].read_text(encoding="ascii"),
            secrets.token_hex(32)))
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(thread.join, 5)
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        client = LiteClient(binding, "lite-1")
        client.base = f"http://127.0.0.1:{server.server_port}"
        self.assertEqual("agent", client.state()["mode"])
        client.claim("owner", 1, secrets.token_hex(16), 30)
        client.input("key", key="Return")
        client.release()
        self.assertEqual(1, channel.status()["actions"])
        self.assertIsNone(channel.status()["lease"])


if __name__ == "__main__":
    unittest.main()
