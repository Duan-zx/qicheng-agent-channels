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
        assert (host, port, timeout) == ('127.0.0.1', 18770, 5)
        self.owner = owner

    def request(self, method, path, body, headers):
        assert method == 'POST'
        assert headers['Authorization'] == 'Bearer ' + self.owner.credential
        assert headers['Content-Length'] == str(len(body))
        self.owner.raw_bodies.append((path, body))
        self.owner.calls.append((path, json.loads(body)))
        if path == '/v1/renew':
            self.owner.renew_sent.set()

    def getresponse(self):
        if self.owner.fail:
            raise ConnectionError('lost response')
        path, body = self.owner.calls[-1]
        if path == '/v1/renew' and self.owner.block_renew:
            self.owner.renew_release.wait(1)
        if self.owner.fail_ack and path == '/v1/ack':
            raise ConnectionError('ack response lost')
        if self.owner.reject_input and path == '/v1/input':
            return Response({'ok': False, 'error': 'guest_dirty'}, status=409)
        if path == '/v1/acquire' or path == '/v1/renew':
            return Response(dict(request_id=self.owner.client.request_id,
                                 task_id=self.owner.client.task_id,
                                 channel_id='channel-A', generation=1,
                                 expires_at=123456.0,
                                 guest_identity=self.owner.response_identity,
                                 token='b' * 64))
        if path == '/v1/input':
            return Response({'ok': True, 'action': body['action']})
        if path == '/v1/ack':
            return Response({'ok': True, 'action_id': body['action_id']})
        return Response({'released': {'request_id': self.owner.client.request_id,
                                      'channel_id': 'channel-A'}})

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
        self.fail = False
        self.fail_ack = False
        self.reject_input = False
        self.renew_sent = threading.Event()
        self.renew_release = threading.Event()
        self.block_renew = False
        self.now = [0.0]
        self.identity = {'vm_id': '00000000-0000-0000-0000-00000000000a',
                         'bios_uuid': '00000000-0000-0000-0000-00000000000b',
                         'project': 'A'}
        self.response_identity = dict(self.identity)
        self.client = BrokerClient('http://127.0.0.1:18770', self.token_file,
                                   'channel-A', self.identity,
                                   connection_factory=lambda host, port, timeout:
                                   Connection(self, host, port, timeout),
                                   monotonic=lambda: self.now[0])
        self.addCleanup(self.client._kill)

    def test_explicit_begin_input_finish_and_no_token_in_results(self):
        with self.assertRaises(RuntimeError):
            self.client.input('key', key='Return')
        # A pre-begin input permanently ends the session.
        self.assertEqual('dead', self.client.phase)

    def test_successful_session_and_action_ids(self):
        self.client.begin()
        first = self.client.input('key', key='Enter')
        second = self.client.input('click', x=1, y=2)
        self.assertNotEqual(first['action_id'], second['action_id'])
        self.assertEqual('Return', self.calls[1][1]['key'])
        self.assertEqual(['/v1/acquire', '/v1/input', '/v1/ack',
                          '/v1/input', '/v1/ack'],
                         [path for path, _ in self.calls])
        self.client.finish()
        self.assertEqual('finished', self.client.phase)
        self.assertEqual('/v1/release', self.calls[-1][0])
        with self.assertRaises(RuntimeError): self.client.begin()

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
