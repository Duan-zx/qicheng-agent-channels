"""Local broker MCP client contract and fail-closed state tests."""
import json
import secrets
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from host.broker_client import BrokerClient


class Response:
    def __init__(self, payload, status=200):
        self.body = json.dumps(payload).encode()
        self.status = status

    def getheader(self, name):
        return str(len(self.body)) if name == 'Content-Length' else None

    def read(self, count):
        return self.body[:count]


class Connection:
    def __init__(self, owner, host, port, timeout):
        assert (host, port) == ('127.0.0.1', 18770)
        self.owner = owner
        self.timeout = timeout

    def request(self, method, path, body, headers):
        assert method == 'POST'
        assert headers['Authorization'] == 'Bearer ' + self.owner.credential
        assert headers['Content-Length'] == str(len(body))
        self.path, self.body = path, json.loads(body)
        self.owner.raw_bodies.append((path, body))
        self.owner.calls.append((path, self.body))
        self.owner.timeouts.append((path, self.timeout))
        if path == '/v1/renew':
            self.owner.renew_sent.set()

    def getresponse(self):
        if self.owner.fail:
            raise ConnectionError('lost response')
        path, body = self.path, self.body
        if path == '/v1/acquire' and self.owner.acquire_error is not None:
            raise self.owner.acquire_error
        if path == '/v1/renew' and self.owner.block_renew:
            self.owner.renew_release.wait(1)
        if path == '/v1/release' and self.owner.block_release:
            self.owner.release_sent.set()
            self.owner.release_continue.wait(1)
        if path == '/v1/release' and self.owner.fail_release:
            raise ConnectionError('release response lost')
        if self.owner.fail_ack and path == '/v1/ack':
            raise ConnectionError('ack response lost')
        if self.owner.reject_input and path == '/v1/input':
            return Response({'ok': False, 'error': 'guest_dirty'}, status=409)
        if path == '/v1/acquire':
            self.owner.now[0] += self.owner.acquire_elapsed
            self.owner.generation += 1
            self.owner.lease = dict(request_id=body['request_id'],
                                    task_id=body['task_id'],
                                    channel_id=body['channel_id'],
                                    generation=self.owner.generation,
                                    expires_at=self.owner.now[0] + 30.0,
                                    guest_identity=dict(self.owner.response_identity),
                                    token=f'{self.owner.generation:064x}')
            payload = (self.owner.acquire_payload if self.owner.acquire_payload is not None
                       else self.owner.stale_acquire_response or self.owner.lease)
            self.owner.now[0] += self.owner.acquire_response_delay
            return Response(payload, status=self.owner.acquire_status)
        if path == '/v1/renew':
            if (self.owner.lease is None
                    or body['token'] != self.owner.lease['token']):
                return Response({'error': 'lease_unavailable'}, status=409)
            renewed = dict(self.owner.lease,
                           expires_at=self.owner.now[0] + 30.0,
                           guest_identity=dict(self.owner.response_identity))
            self.owner.lease = renewed
            self.owner.now[0] += self.owner.renew_response_delay
            return Response(self.owner.stale_renew_response or renewed)
        if path == '/v1/input':
            return Response({'ok': True, 'action': body['action']})
        if path == '/v1/ack':
            return Response({'ok': True, 'action_id': body['action_id']})
        if self.owner.lease is None or body['token'] != self.owner.lease['token']:
            return Response({'error': 'lease_unavailable'}, status=409)
        released = {'request_id': self.owner.lease['request_id'],
                    'channel_id': self.owner.lease['channel_id']}
        self.owner.last_released_lease = self.owner.lease
        self.owner.lease = None
        return Response({'released': self.owner.stale_release_response or released})

    def close(self):
        pass


class BrokerClientTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.credential = secrets.token_hex(32)
        self.token_file = Path(self.temp.name) / 'broker.token'
        self.token_file.write_text(self.credential, encoding='ascii')
        self.calls = []
        self.raw_bodies = []
        self.timeouts = []
        self.generation = 0
        self.lease = None
        self.last_released_lease = None
        self.stale_acquire_response = None
        self.acquire_payload = None
        self.acquire_status = 200
        self.acquire_error = None
        self.acquire_elapsed = 0.0
        self.acquire_response_delay = 0.0
        self.renew_response_delay = 0.0
        self.stale_renew_response = None
        self.stale_release_response = None
        self.fail = False
        self.fail_ack = False
        self.reject_input = False
        self.renew_sent = threading.Event()
        self.renew_release = threading.Event()
        self.block_renew = False
        self.block_release = False
        self.fail_release = False
        self.release_sent = threading.Event()
        self.release_continue = threading.Event()
        self.now = [0.0]
        self.identity = {'vm_id': '00000000-0000-0000-0000-00000000000a',
                         'bios_uuid': '00000000-0000-0000-0000-00000000000b',
                         'project': 'A'}
        self.response_identity = dict(self.identity)
        self.client = BrokerClient('http://127.0.0.1:18770', self.token_file,
                                   'channel-A', self.identity,
                                   connection_factory=lambda host, port, timeout:
                                   Connection(self, host, port, timeout),
                                   monotonic=lambda: self.now[0],
                                   wall_clock=lambda: self.now[0])
        self.addCleanup(self.client._kill)

    def test_explicit_begin_input_finish_and_no_token_in_results(self):
        with self.assertRaises(RuntimeError):
            self.client.input('key', key='Return')
        # A pre-begin input permanently ends the session.
        self.assertEqual('dead', self.client.phase)

    def test_successful_session_and_action_ids(self):
        self.client.begin()
        self.assertEqual(30, self.calls[0][1]['wait_seconds'])
        self.assertEqual(('/v1/acquire', 35), self.timeouts[0])
        first = self.client.input('key', key='Enter')
        second = self.client.input('click', x=1, y=2)
        self.assertNotEqual(first['action_id'], second['action_id'])
        self.assertEqual('Return', self.calls[1][1]['key'])
        self.assertEqual(['/v1/acquire', '/v1/input', '/v1/ack',
                          '/v1/input', '/v1/ack'],
                         [path for path, _ in self.calls])
        self.assertTrue(all(timeout == 5 for path, timeout in self.timeouts
                            if path != '/v1/acquire'))
        self.client.finish()
        self.assertEqual('finished', self.client.phase)
        self.assertEqual('/v1/release', self.calls[-1][0])
        first_request_id = self.client.request_id
        first_task_id = self.client.task_id
        first_stop_event = self.client._stop_heartbeat
        self.client.begin()
        self.assertNotEqual(first_request_id, self.client.request_id)
        self.assertNotEqual(first_task_id, self.client.task_id)
        self.assertIsNot(first_stop_event, self.client._stop_heartbeat)
        self.assertTrue(first_stop_event.is_set())
        self.assertEqual(self.client.request_id, self.calls[-1][1]['request_id'])
        self.assertEqual(self.client.task_id, self.calls[-1][1]['task_id'])
        self.client.input('move', x=3, y=4)
        self.client.finish()
        self.assertEqual(['/v1/acquire', '/v1/input', '/v1/ack',
                          '/v1/input', '/v1/ack', '/v1/release',
                          '/v1/acquire', '/v1/input', '/v1/ack', '/v1/release'],
                         [path for path, _ in self.calls])

    def test_explicit_queue_bounds_and_local_validation(self):
        for wait, timeout in ((0, 5), (300, 305)):
            with self.subTest(wait=wait):
                self.client.begin(wait_seconds=wait)
                self.assertEqual(wait, self.calls[-1][1]['wait_seconds'])
                self.assertEqual(('/v1/acquire', timeout), self.timeouts[-1])
                self.client.finish()
        count = len(self.calls)
        for invalid in (True, 1.5, -1, 301, '30', None):
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                self.client.begin(wait_seconds=invalid)
        self.assertEqual('finished', self.client.phase)
        self.assertEqual(count, len(self.calls))

    def test_queued_acquire_does_not_age_new_lease(self):
        self.acquire_elapsed = 30.0
        self.client.begin()
        self.assertEqual('active', self.client.phase)
        self.assertEqual(58.0, self.client.deadline)
        self.client.input('key', key='Return')
        self.assertEqual(5, self.timeouts[-1][1])

    def test_delayed_acquire_response_is_bounded_by_broker_expiry(self):
        self.acquire_elapsed = 30.0
        self.acquire_response_delay = 4.0
        self.client.begin()
        self.assertEqual('active', self.client.phase)
        self.assertEqual(60.0, self.lease['expires_at'])
        self.assertEqual(34.0, self.now[0])
        self.assertEqual(58.0, self.client.deadline)  # 26s lease left, 2s margin.

    def test_expired_acquire_response_is_terminal(self):
        self.acquire_response_delay = 31.0
        with self.assertRaises(RuntimeError): self.client.begin()
        self.assertEqual('dead', self.client.phase)
        with self.assertRaises(RuntimeError): self.client.begin()
        self.assertEqual(['/v1/acquire'], [path for path, _ in self.calls])

    def test_delayed_renew_response_is_bounded_by_broker_expiry(self):
        self.client.begin()
        self.now[0] = 17.0
        self.renew_response_delay = 4.0
        self.client.input('key', key='Return')
        self.assertEqual(21.0, self.now[0])
        self.assertEqual(47.0, self.lease['expires_at'])
        self.assertEqual(45.0, self.client.deadline)

    def test_expired_renew_response_is_terminal(self):
        self.client.begin()
        self.now[0] = 17.0
        self.renew_response_delay = 31.0
        with self.assertRaises(RuntimeError): self.client.input('key', key='Return')
        self.assertEqual('dead', self.client.phase)
        with self.assertRaises(RuntimeError): self.client.begin()
        self.assertEqual(['/v1/acquire', '/v1/renew'],
                         [path for path, _ in self.calls])

    def test_queue_timeout_and_uncertain_acquire_are_terminal(self):
        for failure in ('server_timeout', 'socket_timeout', 'connection_loss',
                        'malformed_response'):
            with self.subTest(failure=failure):
                # A new client starts each independent failed exchange.
                client = BrokerClient('http://127.0.0.1:18770', self.token_file,
                                      'channel-A', self.identity,
                                      connection_factory=lambda host, port, timeout:
                                      Connection(self, host, port, timeout),
                                      monotonic=lambda: self.now[0],
                                      wall_clock=lambda: self.now[0])
                self.addCleanup(client._kill)
                self.acquire_status = 408 if failure == 'server_timeout' else 200
                self.acquire_error = (TimeoutError('queue read timed out')
                                      if failure == 'socket_timeout' else
                                      ConnectionError('lost response')
                                      if failure == 'connection_loss' else None)
                self.acquire_payload = [] if failure == 'malformed_response' else None
                before = len(self.calls)
                with self.assertRaises(RuntimeError): client.begin()
                self.assertEqual('dead', client.phase)
                with self.assertRaises(RuntimeError): client.begin()
                self.assertEqual(before + 1, len(self.calls))
                self.assertEqual(('/v1/acquire', 35), self.timeouts[-1])
                self.acquire_status = 200
                self.acquire_error = None
                self.acquire_payload = None

    def test_previous_heartbeat_cannot_renew_a_new_session(self):
        class TimedOutEvent:
            def __init__(self):
                self.waiting = threading.Event()
                self.resume = threading.Event()
                self.passed_wait = threading.Event()
                self.stopped = threading.Event()
                self.first_wait = True

            def wait(self, timeout):
                if self.first_wait:
                    self.first_wait = False
                    self.waiting.set()
                    if not self.resume.wait(1):
                        raise AssertionError('old heartbeat wait was not released')
                    self.passed_wait.set()
                    return False  # Timeout won the race with finish() setting stop.
                return self.stopped.wait(timeout)

            def set(self):
                self.stopped.set()

        class ObservedLock:
            def __init__(self, old_thread):
                self.lock = threading.RLock()
                self.old_thread = old_thread
                self.old_attempted = threading.Event()

            def __enter__(self):
                if threading.current_thread() is self.old_thread:
                    self.old_attempted.set()
                self.lock.acquire()
                return self

            def __exit__(self, *_):
                self.lock.release()

        old_event = TimedOutEvent()
        self.client._stop_heartbeat = old_event
        self.client.begin()
        old_thread = self.client._heartbeat_thread
        self.assertTrue(old_event.waiting.wait(1))
        observed_lock = ObservedLock(old_thread)
        self.client._lock = observed_lock
        with observed_lock:
            old_event.resume.set()
            self.assertTrue(old_event.passed_wait.wait(1))
            self.assertTrue(observed_lock.old_attempted.wait(1))
            self.assertTrue(old_thread.is_alive())
            self.client.finish()
            self.client.begin()
            self.now[0] = 17.0
        old_thread.join(1)
        self.assertFalse(old_thread.is_alive())
        self.assertEqual(0, len([p for p, _ in self.calls if p == '/v1/renew']))
        self.client.input('move', x=1, y=2)
        self.assertEqual(1, len([p for p, _ in self.calls if p == '/v1/renew']))

    def test_failed_second_acquire_is_permanently_dead(self):
        self.client.begin()
        self.client.finish()
        self.fail = True
        with self.assertRaises(RuntimeError): self.client.begin()
        self.assertEqual('dead', self.client.phase)
        self.fail = False
        with self.assertRaises(RuntimeError): self.client.begin()
        self.assertEqual(2, len([p for p, _ in self.calls if p == '/v1/acquire']))

    def test_stale_acquire_response_from_previous_session_is_fatal(self):
        self.client.begin()
        self.client.finish()
        previous = dict(self.last_released_lease)
        self.stale_acquire_response = previous
        with self.assertRaises(RuntimeError): self.client.begin()
        self.assertNotEqual(previous['request_id'], self.calls[-1][1]['request_id'])
        self.assertEqual('dead', self.client.phase)
        with self.assertRaises(RuntimeError): self.client.begin()

    def test_stale_renew_response_from_previous_session_is_fatal(self):
        self.client.begin()
        self.client.finish()
        self.stale_renew_response = dict(self.last_released_lease)
        self.client.begin()
        self.now[0] = 17.0
        with self.assertRaises(RuntimeError): self.client.input('move', x=1, y=2)
        self.assertEqual('dead', self.client.phase)
        self.assertEqual(['/v1/acquire', '/v1/release', '/v1/acquire', '/v1/renew'],
                         [path for path, _ in self.calls])

    def test_active_begin_never_acquires_a_second_lease(self):
        self.client.begin()
        with self.assertRaises(RuntimeError): self.client.begin()
        self.assertEqual('active', self.client.phase)
        self.assertEqual(1, len([p for p, _ in self.calls if p == '/v1/acquire']))
        self.client.finish()

    def test_second_session_lost_ack_forbids_a_third_begin(self):
        self.client.begin()
        self.client.finish()
        self.client.begin()
        self.fail_ack = True
        with self.assertRaises(RuntimeError): self.client.input('key', key='Return')
        self.assertEqual('dead', self.client.phase)
        with self.assertRaises(RuntimeError): self.client.begin()
        self.assertEqual(2, len([p for p, _ in self.calls if p == '/v1/acquire']))

    def test_uncertain_release_is_permanently_dead(self):
        self.client.begin()
        self.fail_release = True
        with self.assertRaises(RuntimeError): self.client.finish()
        self.assertEqual('dead', self.client.phase)
        with self.assertRaises(RuntimeError): self.client.begin()
        self.assertEqual(1, len([p for p, _ in self.calls if p == '/v1/acquire']))

    def test_stale_release_response_from_previous_session_is_fatal(self):
        self.client.begin()
        self.client.finish()
        previous = self.last_released_lease
        self.client.begin()
        self.stale_release_response = {
            'request_id': previous['request_id'],
            'channel_id': previous['channel_id']}
        with self.assertRaises(RuntimeError): self.client.finish()
        self.assertEqual('dead', self.client.phase)
        with self.assertRaises(RuntimeError): self.client.begin()
        self.assertEqual(2, len([p for p, _ in self.calls if p == '/v1/acquire']))

    def test_begin_waits_for_confirmed_release(self):
        self.client.begin()
        self.block_release = True
        completed = threading.Event()
        outcomes = []

        def release():
            outcomes.append(self.client.finish())

        def acquire():
            outcomes.append(self.client.begin())
            completed.set()

        finisher = threading.Thread(target=release)
        beginner = threading.Thread(target=acquire)
        finisher.start()
        self.assertTrue(self.release_sent.wait(1))
        beginner.start()
        self.assertFalse(completed.wait(0.03))
        self.assertEqual(1, len([p for p, _ in self.calls if p == '/v1/acquire']))
        self.release_continue.set()
        finisher.join(1)
        beginner.join(1)
        self.assertFalse(finisher.is_alive())
        self.assertFalse(beginner.is_alive())
        self.assertEqual(['finished', 'active'], [x['session'] for x in outcomes])
        self.assertEqual(['/v1/acquire', '/v1/release', '/v1/acquire'],
                         [p for p, _ in self.calls])

    def test_lost_input_response_ends_session_without_retry(self):
        self.client.begin()
        self.fail = True
        with self.assertRaises(RuntimeError): self.client.input('key', key='Return')
        self.assertEqual('dead', self.client.phase)
        self.fail = False
        with self.assertRaises(RuntimeError): self.client.input('key', key='Return')
        with self.assertRaises(RuntimeError): self.client.begin()
        self.assertEqual(1, len([path for path, _ in self.calls if path == '/v1/input']))

    def test_expiry_never_reacquires_and_near_expiry_renews(self):
        self.client.begin()
        self.now[0] = 17.0
        self.client.input('move', x=3, y=4)
        self.assertEqual(['/v1/acquire', '/v1/renew', '/v1/input', '/v1/ack'],
                         [path for path, _ in self.calls])
        self.now[0] = 50.0
        with self.assertRaises(RuntimeError): self.client.input('move', x=3, y=4)
        self.assertEqual('dead', self.client.phase)
        self.assertEqual(1, len([path for path, _ in self.calls if path == '/v1/acquire']))

    def test_background_renews_during_long_model_pause(self):
        with patch('host.broker_client._HEARTBEAT_INTERVAL', 0.01):
            self.client.begin()
            for now in (17.0, 40.0, 63.0):
                self.renew_sent.clear()
                self.now[0] = now
                self.assertTrue(self.renew_sent.wait(1), 'background renew did not run')
                # The request signal precedes validation and deadline update.
                with self.client._lock:
                    self.assertEqual('active', self.client.phase)
                    self.assertGreater(self.client.deadline, now)
            result = self.client.input('key', key='Return')
            self.assertTrue(result['ok'])
            self.assertEqual(1, len([p for p, _ in self.calls if p == '/v1/acquire']))
            self.renew_sent.clear()
            self.client.finish()
            count = len(self.calls)
            self.now[0] = 100.0
            self.assertFalse(self.renew_sent.wait(0.04))
            self.assertEqual(count, len(self.calls))

    def test_input_waits_for_inflight_background_renew(self):
        with patch('host.broker_client._HEARTBEAT_INTERVAL', 0.01):
            self.client.begin()
            self.block_renew = True
            self.now[0] = 17.0
            self.assertTrue(self.renew_sent.wait(1))
            completed = threading.Event()
            outcome = []

            def send_input():
                try:
                    outcome.append(self.client.input('key', key='Return'))
                finally:
                    completed.set()

            worker = threading.Thread(target=send_input)
            worker.start()
            self.assertFalse(completed.wait(0.03))
            self.renew_release.set()
            self.assertTrue(completed.wait(1))
            worker.join(1)
            self.assertTrue(outcome[0]['ok'])
            self.assertEqual(['/v1/acquire', '/v1/renew', '/v1/input', '/v1/ack'],
                             [path for path, _ in self.calls])

    def test_background_renew_failure_is_terminal(self):
        with patch('host.broker_client._HEARTBEAT_INTERVAL', 0.01):
            self.client.begin()
            self.fail = True
            self.now[0] = 17.0
            self.assertTrue(self.renew_sent.wait(1))
            self.client._heartbeat_thread.join(1)
            self.assertFalse(self.client._heartbeat_thread.is_alive())
            self.assertEqual('dead', self.client.phase)
            self.fail = False
            with self.assertRaises(RuntimeError): self.client.input('key', key='Return')
            with self.assertRaises(RuntimeError): self.client.begin()
            self.assertEqual(['/v1/acquire', '/v1/renew'],
                             [path for path, _ in self.calls])

    def test_dirty_fence_rejection_stops_heartbeat_without_reacquire(self):
        with patch('host.broker_client._HEARTBEAT_INTERVAL', 0.01):
            self.client.begin()
            self.reject_input = True
            with self.assertRaises(RuntimeError):
                self.client.input('key', key='Return')
            self.assertEqual('dead', self.client.phase)
            self.now[0] = 17.0
            self.assertFalse(self.renew_sent.wait(0.04))
            with self.assertRaises(RuntimeError): self.client.begin()
            self.assertEqual(['/v1/acquire', '/v1/input'],
                             [path for path, _ in self.calls])

    def test_bad_url_and_credential_rejected(self):
        for url in ('http://localhost:18770', 'http://0.0.0.0:18770',
                    'https://127.0.0.1:18770', 'http://127.0.0.1:18770/path'):
            with self.assertRaises(ValueError):
                BrokerClient(url, self.token_file, 'channel-A', self.identity)
        self.token_file.write_text('bad', encoding='ascii')
        with self.assertRaises(ValueError):
            BrokerClient('http://127.0.0.1:18770', self.token_file,
                         'channel-A', self.identity)

    def test_acquire_wrong_guest_identity_is_fatal_before_input(self):
        self.response_identity = dict(self.identity, project='C')
        with self.assertRaises(RuntimeError): self.client.begin()
        self.assertEqual('dead', self.client.phase)
        with self.assertRaises(RuntimeError): self.client.input('key', key='Return')
        self.assertEqual(['/v1/acquire'], [path for path, _ in self.calls])

    def test_renew_wrong_guest_identity_is_fatal_before_input(self):
        self.client.begin()
        self.now[0] = 17.0
        self.response_identity = dict(self.identity, bios_uuid='00000000-0000-0000-0000-00000000000c')
        with self.assertRaises(RuntimeError): self.client.input('key', key='Return')
        self.assertEqual('dead', self.client.phase)
        self.assertEqual(['/v1/acquire', '/v1/renew'],
                         [path for path, _ in self.calls])

    def test_lost_ack_ends_session_without_next_action(self):
        self.client.begin()
        self.fail_ack = True
        with self.assertRaises(RuntimeError): self.client.input('key', key='Return')
        self.assertEqual('dead', self.client.phase)
        self.fail_ack = False
        with self.assertRaises(RuntimeError): self.client.input('key', key='Return')
        with self.assertRaises(RuntimeError): self.client.begin()
        self.assertEqual(['/v1/acquire', '/v1/input', '/v1/ack'],
                         [path for path, _ in self.calls])

    def test_non_bmp_text_uses_utf8_wire_size_and_can_be_acked(self):
        self.client.begin()
        result = self.client.input('type', text='😀' * 1500)
        self.assertTrue(result['ok'])
        path, body = self.raw_bodies[1]
        self.assertEqual('/v1/input', path)
        self.assertIn('😀'.encode('utf-8'), body)
        self.assertNotIn(b'\\ud83d', body)
        self.assertLessEqual(len(body), 16384)
        self.assertEqual(['/v1/acquire', '/v1/input', '/v1/ack'],
                         [path for path, _ in self.calls])
        self.assertEqual('active', self.client.phase)


if __name__ == '__main__': unittest.main()
