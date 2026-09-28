import importlib.util
import multiprocessing
import sqlite3
import tempfile
import threading
import time
import unittest
from concurrent.futures import ThreadPoolExecutor
from contextlib import closing
from pathlib import Path


MODULE = Path(__file__).resolve().parents[1] / "lease.py"
spec = importlib.util.spec_from_file_location("qicheng_lease", MODULE)
lease = importlib.util.module_from_spec(spec)
import sys
sys.modules[spec.name] = lease
spec.loader.exec_module(lease)


def acquire_worker(path, channel, request, queue):
    try:
        store = lease.LeaseStore(path)
        result = store.acquire(request_id=request, channel_id=channel,
                               task_id=request, project_id="project",
                               project_path=str(Path(path).parent),
                               endpoint_id="endpoint", tool_id="browser")
        queue.put(("ok", result.generation))
    except Exception as error:
        queue.put((type(error).__name__, str(error)))


def execute_worker(path, channel, token, started, finish, queue):
    try:
        store = lease.LeaseStore(path)
        def action(_active):
            started.set()
            if not finish.wait(8):
                raise TimeoutError("test action did not finish")
            return "ok"
        queue.put(store.execute_owned(channel, token, action))
    except Exception as error:
        queue.put((type(error).__name__, str(error)))


def wait_worker(path, request, queue):
    try:
        store = lease.LeaseStore(path)
        result = store.acquire(request_id=request, channel_id="channel-B",
                               task_id=request, project_id="project",
                               project_path=str(Path(path).parent),
                               endpoint_id="endpoint", tool_id="browser",
                               wait_seconds=8)
        queue.put(("ok", result.request_id, result.token))
    except Exception as error:
        queue.put((type(error).__name__, str(error)))


class LeaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "leases.db"
        self.now = [1000.0]
        self.store = lease.LeaseStore(self.path, clock=lambda: self.now[0])

    def acquire(self, request="run-1", channel="channel-2", **changes):
        args = dict(request_id=request, channel_id=channel, task_id="task-A",
                    project_id="project-A", project_path=self.temp.name,
                    endpoint_id="wechat-A", tool_id="browser", ttl_seconds=20)
        args.update(changes)
        return self.store.acquire(**args)

    def test_maintenance_persists_and_blocks_new_admission(self):
        first = self.acquire()
        self.assertTrue(self.store.set_maintenance(True))
        reopened = lease.LeaseStore(self.path, clock=lambda: self.now[0])
        self.assertTrue(reopened.maintenance())
        with self.assertRaises(lease.MaintenanceMode):
            self.acquire("new", "channel-3", endpoint_id="other")
        with self.assertRaises(lease.MaintenanceMode):
            self.acquire()
        with self.assertRaises(lease.MaintenanceMode):
            reopened.execute_owned(first.channel_id, first.token, lambda _: "started")
        self.assertEqual("ack", reopened.execute_owned(
            first.channel_id, first.token, lambda _: "ack", allow_maintenance=True))
        reopened.release(first.channel_id, first.token)
        self.assertIsNone(reopened.current(first.channel_id))
        reopened.set_maintenance(False)
        self.assertFalse(self.store.maintenance())
        self.assertEqual("new", self.acquire("new").request_id)

    def test_maintenance_cancels_waiters_and_allows_running_action_to_finish(self):
        first = self.acquire()
        started = threading.Event()
        finish = threading.Event()
        with ThreadPoolExecutor(max_workers=2) as pool:
            running = pool.submit(self.store.execute_owned, first.channel_id,
                                  first.token,
                                  lambda _: started.set() or finish.wait(3))
            self.assertTrue(started.wait(2))
            waiting = pool.submit(self.acquire, "queued", "channel-3",
                                  wait_seconds=3)
            deadline = time.monotonic() + 2
            while time.monotonic() < deadline:
                with closing(sqlite3.connect(self.path)) as db:
                    if db.execute("SELECT COUNT(*) FROM waiters").fetchone()[0]:
                        break
                time.sleep(0.01)
            else:
                self.fail("waiter did not join")
            self.store.set_maintenance(True)
            finish.set()
            self.assertTrue(running.result(timeout=3))
            with self.assertRaises(lease.MaintenanceMode):
                waiting.result(timeout=3)
        with closing(sqlite3.connect(self.path)) as db:
            self.assertEqual(0, db.execute("SELECT COUNT(*) FROM waiters").fetchone()[0])
        self.store.release(first.channel_id, first.token)
        self.store.set_maintenance(False)
        with self.assertRaises(lease.LeaseGone):
            self.acquire("queued", "channel-3", wait_seconds=3)
        self.assertEqual("fresh", self.acquire("fresh", "channel-3").request_id)

    def test_maintenance_and_acquire_share_write_transaction(self):
        admitted = threading.Event()
        proceed = threading.Event()
        original = self.store._require_open
        def pause_after_check(db):
            original(db)
            admitted.set()
            if not proceed.wait(3):
                raise TimeoutError("acquire did not resume")
        self.store._require_open = pause_after_check
        try:
            with ThreadPoolExecutor(max_workers=2) as pool:
                acquiring = pool.submit(self.acquire)
                self.assertTrue(admitted.wait(2))
                with closing(sqlite3.connect(self.path, timeout=0.05,
                                             isolation_level=None)) as db:
                    with self.assertRaises(sqlite3.OperationalError):
                        db.execute("BEGIN IMMEDIATE")
                enabling_started = threading.Event()
                def enable():
                    enabling_started.set()
                    return self.store.set_maintenance(True)
                enabling = pool.submit(enable)
                self.assertTrue(enabling_started.wait(2))
                self.assertFalse(enabling.done())
                proceed.set()
                first = acquiring.result(timeout=3)
                self.assertTrue(enabling.result(timeout=3))
            self.assertEqual(first.public(), self.store.current(first.channel_id).public())
            with self.assertRaises(lease.MaintenanceMode):
                self.acquire("later", "channel-3", endpoint_id="other")
        finally:
            proceed.set()
            self.store._require_open = original

    def test_exclusive_retry_and_binding(self):
        first = self.acquire()
        self.assertEqual(first, self.acquire())
        self.assertEqual(first.task_id, self.store.current("channel-2").task_id)
        with self.assertRaises(lease.ChannelBusy):
            self.acquire("run-2", task_id="task-B")
        with self.assertRaises(lease.RequestConflict):
            self.acquire("run-1", project_id="project-B")
        self.assertIsNone(self.store.current("channel-3"))

    def test_renew_release_expiry_and_fencing(self):
        first = self.acquire()
        self.now[0] += 10
        renewed = self.store.renew("channel-2", first.token, 30)
        self.assertEqual(1040.0, renewed.expires_at)
        self.assertEqual(first.generation, renewed.generation)
        self.now[0] = 1040.0
        with self.assertRaises(lease.LeaseGone):
            self.store.renew("channel-2", first.token)
        second = self.acquire("run-2", task_id="task-B")
        self.assertGreater(second.generation, first.generation)
        with self.assertRaises(lease.InvalidToken):
            self.store.release("channel-2", first.token)
        self.assertEqual("task-B", self.store.assert_owner("channel-2", second.token).task_id)
        self.store.release("channel-2", second.token)
        self.assertIsNone(self.store.current("channel-2"))
        with self.assertRaises(lease.LeaseGone):
            self.acquire("run-2", task_id="task-B")

    def test_endpoint_exclusive_across_channels(self):
        first = self.acquire()
        with self.assertRaises(lease.EndpointBusy):
            self.acquire("run-2", "channel-3", task_id="task-B")
        self.assertEqual(first, self.acquire())
        other = self.acquire("run-3", "channel-3", task_id="task-C",
                             endpoint_id="wechat-B")
        self.assertEqual("wechat-B", other.endpoint_id)
        self.store.release("channel-2", first.token)
        # A different channel can now claim the released endpoint.
        next_lease = self.acquire("run-4", "channel-4", task_id="task-B")
        self.assertEqual("wechat-A", next_lease.endpoint_id)
        self.now[0] += 20
        expired_claim = self.acquire("run-5", "channel-5", task_id="task-D")
        self.assertGreater(expired_claim.generation, next_lease.generation)

    def test_acquire_ttl_starts_after_write_lock(self):
        with closing(sqlite3.connect(self.path)) as blocker:
            blocker.execute("BEGIN IMMEDIATE")
            entered = threading.Event()
            def waiting_acquire():
                entered.set()
                return self.acquire("run-wait", "channel-3", ttl_seconds=1,
                                    endpoint_id="wechat-B")
            with ThreadPoolExecutor(max_workers=1) as pool:
                result = pool.submit(waiting_acquire)
                self.assertTrue(entered.wait(2))
                time.sleep(0.05)
                self.assertFalse(result.done())
                self.now[0] = 1005.0
                blocker.commit()
                acquired = result.result(timeout=5)
        self.assertEqual(1006.0, acquired.expires_at)
        self.assertIsNotNone(self.store.current("channel-3"))

    def test_owned_action_blocks_successor(self):
        first = self.acquire()
        action_started = threading.Event()
        allow_action_finish = threading.Event()
        successor_done = threading.Event()
        successor = []
        def action(active):
            self.assertEqual(first.generation, active.generation)
            action_started.set()
            self.assertTrue(allow_action_finish.wait(5))
            return "performed"
        def transition():
            self.store.release("channel-2", first.token)
            successor.append(self.acquire("run-2", task_id="task-B"))
            successor_done.set()
        with ThreadPoolExecutor(max_workers=2) as pool:
            running = pool.submit(self.store.execute_owned, "channel-2", first.token, action)
            self.assertTrue(action_started.wait(2))
            moving = pool.submit(transition)
            self.assertFalse(successor_done.wait(0.1))
            allow_action_finish.set()
            self.assertEqual("performed", running.result(timeout=5))
            moving.result(timeout=5)
        self.assertTrue(successor_done.is_set())
        with self.assertRaises(lease.InvalidToken):
            self.store.execute_owned("channel-2", first.token, lambda _: "wrong")
        self.assertEqual("task-B", successor[0].task_id)

    def test_expiry_and_release_cannot_race_running_action(self):
        first = self.acquire(ttl_seconds=1)
        started = threading.Event()
        finish = threading.Event()
        def action(_active):
            started.set()
            self.assertTrue(finish.wait(5))
        with ThreadPoolExecutor(max_workers=3) as pool:
            running = pool.submit(self.store.execute_owned, "channel-2", first.token, action)
            self.assertTrue(started.wait(2))
            self.now[0] = first.expires_at
            releasing = pool.submit(self.store.release, "channel-2", first.token)
            successor = pool.submit(self.acquire, "run-next", "channel-3",
                                    task_id="task-next")
            time.sleep(0.1)
            self.assertFalse(releasing.done())
            self.assertFalse(successor.done())
            finish.set()
            running.result(timeout=5)
            with self.assertRaises(lease.LeaseGone):
                releasing.result(timeout=5)
            next_lease = successor.result(timeout=5)
        self.assertGreater(next_lease.generation, first.generation)
        with self.assertRaises(lease.InvalidToken):
            self.store.execute_owned("channel-3", first.token, lambda _: None)

    def test_other_endpoint_executes_while_process_holds_action(self):
        context = multiprocessing.get_context("spawn")
        path = Path(self.temp.name) / "parallel.db"
        store = lease.LeaseStore(path)
        first = store.acquire(request_id="parallel-A", channel_id="channel-A",
                              task_id="task-A", project_id="project",
                              project_path=self.temp.name, endpoint_id="endpoint-A",
                              tool_id="browser", ttl_seconds=10)
        second = store.acquire(request_id="parallel-B", channel_id="channel-B",
                               task_id="task-B", project_id="project",
                               project_path=self.temp.name, endpoint_id="endpoint-B",
                               tool_id="browser", ttl_seconds=10)
        started, finish, queue = context.Event(), context.Event(), context.Queue()
        worker = context.Process(target=execute_worker,
                                 args=(str(path), "channel-A", first.token,
                                       started, finish, queue))
        worker.start()
        try:
            self.assertTrue(started.wait(5))
            began = time.monotonic()
            self.assertEqual("other", store.execute_owned("channel-B", second.token,
                                                         lambda _: "other"))
            self.assertLess(time.monotonic() - began, 1.5)
            with ThreadPoolExecutor(max_workers=1) as pool:
                blocked = pool.submit(store.release, "channel-A", first.token)
                self.assertFalse(blocked.done())
                finish.set()
                self.assertEqual("ok", queue.get(timeout=5))
                blocked.result(timeout=5)
        finally:
            finish.set()
            worker.join(5)
            if worker.is_alive():
                worker.terminate()
                worker.join(5)
        self.assertEqual(0, worker.exitcode)

    def test_restart_and_key_loss_fail_closed(self):
        first = self.acquire()
        restarted = lease.LeaseStore(self.path, clock=lambda: self.now[0])
        retry = restarted.acquire(request_id="run-1", channel_id="channel-2",
                                  task_id="task-A", project_id="project-A",
                                  project_path=self.temp.name,
                                  endpoint_id="wechat-A", tool_id="browser")
        self.assertEqual(first.token, retry.token)
        self.assertEqual("task-A", restarted.assert_owner("channel-2", first.token).task_id)
        self.path.with_name(self.path.name + ".key").unlink()
        with self.assertRaises(lease.LeaseError):
            lease.LeaseStore(self.path)

    def test_no_bearer_secret_in_database(self):
        first = self.acquire()
        with closing(sqlite3.connect(self.path)) as db:
            rows = " ".join(str(row) for table in ("leases", "requests")
                            for row in db.execute(f"SELECT * FROM {table}"))
        self.assertNotIn(first.token, rows)
        self.assertNotIn(first.token, self.path.read_bytes().decode("utf-8", "ignore"))
        with self.assertRaises(ValueError):
            self.acquire("run/with/slash")

    def test_two_processes_compete(self):
        context = multiprocessing.get_context("spawn")
        queue = context.Queue()
        # Both child processes initialize this second database themselves.
        fresh_path = Path(self.temp.name) / "fresh.db"
        jobs = [context.Process(target=acquire_worker,
                                args=(str(fresh_path), "channel-3", f"process-{i}", queue))
                for i in range(2)]
        for job in jobs:
            job.start()
        results = [queue.get(timeout=15) for _ in jobs]
        outcomes = [item[0] for item in results]
        for job in jobs:
            job.join(15)
            self.assertEqual(0, job.exitcode)
        self.assertCountEqual(["ok", "ChannelBusy"], outcomes, str(results))

    def test_two_processes_compete_for_endpoint(self):
        context = multiprocessing.get_context("spawn")
        queue = context.Queue()
        jobs = [context.Process(target=acquire_worker,
                                args=(str(self.path), f"channel-{i}", f"endpoint-run-{i}", queue))
                for i in range(2)]
        for job in jobs:
            job.start()
        outcomes = [queue.get(timeout=15)[0] for _ in jobs]
        for job in jobs:
            job.join(15)
            self.assertEqual(0, job.exitcode)
        self.assertCountEqual(["ok", "EndpointBusy"], outcomes)

    def test_waiters_are_fifo_and_retry_does_not_duplicate(self):
        real = lease.LeaseStore(self.path)
        first = real.acquire(request_id="owner", channel_id="channel-A",
                             task_id="owner", project_id="project-A",
                             project_path=self.temp.name, endpoint_id="wechat-A",
                             tool_id="browser")
        # Use a real clock for bounded waits; the original owner is released explicitly.
        def waiting(request, channel):
            return real.acquire(request_id=request, channel_id=channel,
                                task_id=request, project_id="project-A",
                                project_path=self.temp.name, endpoint_id="wechat-A",
                                tool_id="browser", wait_seconds=3)
        with ThreadPoolExecutor(max_workers=3) as pool:
            ahead = pool.submit(waiting, "ahead", "channel-B")
            self._await_waiters(1)
            retry = pool.submit(waiting, "ahead", "channel-B")
            behind = pool.submit(waiting, "behind", "channel-C")
            self._await_waiters(2)
            with closing(sqlite3.connect(self.path)) as db:
                self.assertEqual(2, db.execute("SELECT COUNT(*) FROM waiters").fetchone()[0])
            real.release("channel-A", first.token)
            awarded = ahead.result(timeout=4)
            self.assertEqual(awarded, retry.result(timeout=4))
            self.assertFalse(behind.done())
            real.release("channel-B", awarded.token)
            second = behind.result(timeout=4)
            self.assertGreater(second.generation, awarded.generation)
            real.release("channel-C", second.token)

    def _await_waiters(self, count):
        deadline = time.monotonic() + 4
        while time.monotonic() < deadline:
            with closing(sqlite3.connect(self.path)) as db:
                if db.execute("SELECT COUNT(*) FROM waiters").fetchone()[0] == count:
                    return
            time.sleep(0.02)
        self.fail(f"expected {count} waiters")

    def test_wait_timeout_and_cancel_are_terminal_and_release_queue(self):
        first = self.acquire("owner", "channel-A")
        with self.assertRaises(lease.WaitTimedOut):
            self.acquire("timed", "channel-B", wait_seconds=0.15)
        with self.assertRaises(lease.LeaseGone):
            self.acquire("timed", "channel-B", wait_seconds=1)
        cancelled = threading.Event()
        with ThreadPoolExecutor(max_workers=1) as pool:
            waiting = pool.submit(self.acquire, "cancelled", "channel-B",
                                  wait_seconds=2, cancelled=cancelled.is_set)
            self._await_waiters(1)
            cancelled.set()
            with self.assertRaises(lease.WaitCancelled):
                waiting.result(timeout=2)
        self._await_waiters(0)
        self.store.release("channel-A", first.token)
        successor = self.acquire("successor", "channel-C")
        self.assertEqual("successor", successor.request_id)

    def test_wait_queue_capacity_rejects_without_consuming_request_id(self):
        self.store.MAX_WAITERS_PER_ENDPOINT = 1
        owner = self.acquire("owner", "channel-A")
        cancelled = threading.Event()
        with ThreadPoolExecutor(max_workers=1) as pool:
            waiting = pool.submit(self.acquire, "first-waiter", "channel-B",
                                  wait_seconds=2, cancelled=cancelled.is_set)
            self._await_waiters(1)
            with self.assertRaises(lease.WaitQueueFull):
                self.acquire("second-waiter", "channel-C", wait_seconds=1)
            with closing(sqlite3.connect(self.path)) as db:
                self.assertIsNone(db.execute("SELECT 1 FROM requests WHERE request_id=?",
                                             ("second-waiter",)).fetchone())
            cancelled.set()
            with self.assertRaises(lease.WaitCancelled):
                waiting.result(timeout=2)
        self.store.release("channel-A", owner.token)
        self.assertEqual("second-waiter", self.acquire("second-waiter", "channel-C").request_id)

    def test_disconnect_of_one_retry_preserves_shared_queue_position(self):
        owner = self.acquire("owner", "channel-A")
        first_cancel = threading.Event()
        with ThreadPoolExecutor(max_workers=2) as pool:
            first = pool.submit(self.acquire, "shared", "channel-B", wait_seconds=2,
                                cancelled=first_cancel.is_set)
            self._await_waiters(1)
            second = pool.submit(self.acquire, "shared", "channel-B", wait_seconds=2)
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline:
                with closing(sqlite3.connect(self.path)) as db:
                    if db.execute("SELECT COUNT(*) FROM waiter_clients").fetchone()[0] == 2:
                        break
                time.sleep(0.02)
            else:
                self.fail("second retry did not attach")
            first_cancel.set()
            with self.assertRaises(lease.WaitCancelled):
                first.result(timeout=2)
            self._await_waiters(1)
            self.store.release("channel-A", owner.token)
            self.assertEqual("shared", second.result(timeout=3).request_id)

    def test_short_retry_timeout_preserves_original_waiter(self):
        owner = self.acquire("owner", "channel-A")
        with ThreadPoolExecutor(max_workers=2) as pool:
            original = pool.submit(self.acquire, "shared", "channel-B", wait_seconds=2)
            self._await_waiters(1)
            short = pool.submit(self.acquire, "shared", "channel-B", wait_seconds=0.2)
            with self.assertRaises(lease.WaitTimedOut):
                short.result(timeout=1)
            with closing(sqlite3.connect(self.path)) as db:
                self.assertEqual(1, db.execute("SELECT COUNT(*) FROM waiters").fetchone()[0])
                self.assertEqual(1, db.execute("SELECT COUNT(*) FROM waiter_clients").fetchone()[0])
            self.store.release("channel-A", owner.token)
            self.assertEqual("shared", original.result(timeout=3).request_id)

    def test_long_action_lock_keeps_fifo_waiters_alive_past_ten_seconds(self):
        real = lease.LeaseStore(self.path)
        def acquire(request, channel, wait=0):
            return real.acquire(request_id=request, channel_id=channel,
                                task_id=request, project_id="project",
                                project_path=self.temp.name, endpoint_id="endpoint",
                                tool_id="browser", wait_seconds=wait, ttl_seconds=30)
        owner = acquire("owner", "channel-A")
        started = threading.Event()
        with ThreadPoolExecutor(max_workers=3) as pool:
            def long_action(_active):
                started.set()
                time.sleep(10.6)
            action = pool.submit(real.execute_owned, "channel-A", owner.token, long_action)
            self.assertTrue(started.wait(2))
            head = pool.submit(acquire, "head", "channel-A", 20)
            self._await_waiters(1)
            behind = pool.submit(acquire, "behind", "channel-B", 20)
            self._await_waiters(2)
            with closing(sqlite3.connect(self.path)) as db:
                queued = db.execute("""SELECT r.request_id FROM waiters w
                    JOIN requests r ON r.generation=w.generation
                    ORDER BY w.generation""").fetchall()
                self.assertEqual([("head",), ("behind",)], queued)
            time.sleep(6)
            with closing(sqlite3.connect(self.path)) as db:
                self.assertEqual(2, db.execute("SELECT COUNT(*) FROM waiters").fetchone()[0])
                heartbeat = db.execute("SELECT MIN(heartbeat) FROM waiter_clients").fetchone()[0]
                self.assertLess(time.time() - heartbeat, 2)
            action.result(timeout=8)
            real.release("channel-A", owner.token)
            awarded = head.result(timeout=5)
            self.assertEqual("head", awarded.request_id)
            self.assertFalse(behind.done())
            real.release("channel-A", awarded.token)
            self.assertEqual("behind", behind.result(timeout=5).request_id)

    def test_cross_process_waiter_survives_store_restart(self):
        real = lease.LeaseStore(self.path)
        first = real.acquire(request_id="owner", channel_id="channel-A",
                             task_id="owner", project_id="project",
                             project_path=self.temp.name, endpoint_id="endpoint",
                             tool_id="browser")
        context = multiprocessing.get_context("spawn")
        queue = context.Queue()
        worker = context.Process(target=wait_worker, args=(str(self.path), "queued", queue))
        worker.start()
        try:
            self._await_waiters(1)
            restarted = lease.LeaseStore(self.path)
            restarted.release("channel-A", first.token)
            outcome = queue.get(timeout=10)
            self.assertEqual(("ok", "queued"), outcome[:2])
            self.assertEqual("queued", restarted.current("channel-B").request_id)
            restarted.release("channel-B", outcome[2])
        finally:
            worker.join(5)
            if worker.is_alive():
                worker.terminate()
                worker.join(5)
        self.assertEqual(0, worker.exitcode)

    def test_dead_process_waiter_is_pruned_after_heartbeat_lapse(self):
        real = lease.LeaseStore(self.path)
        owner = real.acquire(request_id="owner", channel_id="channel-A",
                             task_id="owner", project_id="project",
                             project_path=self.temp.name, endpoint_id="endpoint",
                             tool_id="browser")
        context = multiprocessing.get_context("spawn")
        queue = context.Queue()
        worker = context.Process(target=wait_worker, args=(str(self.path), "orphan", queue))
        worker.start()
        try:
            self._await_waiters(1)
        finally:
            worker.terminate()
            worker.join(5)
        self.assertFalse(worker.is_alive())
        # Simulate five seconds elapsed without a process heartbeating.
        with closing(sqlite3.connect(self.path)) as db:
            db.execute("UPDATE waiter_clients SET heartbeat=?", (time.time() - 10,))
            db.commit()
        restarted = lease.LeaseStore(self.path)
        restarted.release("channel-A", owner.token)
        successor = restarted.acquire(request_id="successor", channel_id="channel-C",
            task_id="successor", project_id="project", project_path=self.temp.name,
            endpoint_id="endpoint", tool_id="browser")
        self.assertEqual("successor", successor.request_id)
        with self.assertRaises(lease.LeaseGone):
            restarted.acquire(request_id="orphan", channel_id="channel-B",
                task_id="orphan", project_id="project", project_path=self.temp.name,
                endpoint_id="endpoint", tool_id="browser", wait_seconds=1)


if __name__ == "__main__":
    unittest.main()
