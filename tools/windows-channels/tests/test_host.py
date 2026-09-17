import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch
from contextlib import redirect_stdout
import io

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from host.client import GuestClient, MAX_RESPONSE, read_config
from host.client import main

VM = 'ca6d2942-6d2c-4050-9ba5-b9bca1754b28'
BIOS = '5a73f8d6-cf5b-41c2-a423-989a8772a9cb'


class Stream:
    def __init__(self, responses):
        self.responses = responses; self.sent = []; self.connected = []
    def __enter__(self): return self
    def __exit__(self, *args): pass
    def settimeout(self, timeout): self.timeout = timeout
    def connect(self, endpoint): self.connected.append(endpoint)
    def sendall(self, frame):
        self.sent.append(json.loads(frame[4:]))
        response = self.responses.pop(0)
        data = json.dumps(response).encode()
        self.buffer = struct.pack('!I', len(data)) + data
    def recv(self, size):
        result, self.buffer = self.buffer[:min(size, 7)], self.buffer[min(size, 7):]
        return result


def state(bios=BIOS, mode='agent'):
    return dict(identity=dict(bios_uuid=bios), mode=mode, input_target='private-windows-guest', host_input_supported=False)


class HostTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.root = Path(self.tmp.name)
        self.token = self.root / 'token'; self.token.write_text('a' * 64)
        self.binding = dict(vm_id=VM, bios_uuid=BIOS, token_file=self.token)
    def tearDown(self): self.tmp.cleanup()
    def client(self, responses):
        self.stream = Stream(responses)
        return GuestClient(self.binding, lambda *args: self.stream)
    def test_input_checks_identity_before_sending(self):
        client = self.client([dict(id='1', ok=True, result=state(VM))])
        with self.assertRaisesRegex(RuntimeError, 'identity mismatch'):
            client.operation('input', actor='agent', action='key', key='Return')
        self.assertEqual([r['op'] for r in self.stream.sent], ['state'])
    def test_inputs_only_use_configured_vm_and_sequential_response_ids(self):
        client = self.client([dict(id='1', ok=True, result=state()), dict(id='2', ok=True, result=dict(actions=1))])
        result = client.operation('input', actor='agent', action='click', x=10, y=20)
        self.assertEqual(result, dict(actions=1))
        self.assertTrue(all(endpoint[0] == VM for endpoint in self.stream.connected))
    def test_human_takeover_cannot_be_reenabled_by_allow(self):
        client = self.client([dict(id='1', ok=True, result=state(mode='human'))])
        with self.assertRaisesRegex(RuntimeError, 'Human takeover'):
            client.operation('control', mode='agent')
        self.assertEqual(len(self.stream.sent), 1)
    def test_paused_input_is_not_forwarded(self):
        client = self.client([dict(id='1', ok=True, result=state(mode='paused'))])
        with self.assertRaises(RuntimeError):
            client.operation('input', actor='agent', action='key', key='Return')
        self.assertEqual(len(self.stream.sent), 1)
    def test_duplicate_guest_bindings_rejected(self):
        path = self.root / 'config.json'
        item = dict(vm_id=VM, bios_uuid=BIOS, token_file='token')
        path.write_text(json.dumps(dict(schema_version=1, projects=dict(alpha=item, beta=item))))
        with self.assertRaisesRegex(ValueError, 'must not share'):
            read_config(path)
    def test_mismatched_response_id_rejected(self):
        client = self.client([dict(id=99, ok=True, result=state())])
        with self.assertRaises(ValueError): client.state()


class CliActorTests(unittest.TestCase):
    def test_actor_defaults_to_agent_and_accepts_explicit_human(self):
        for actor in ('agent', 'human'):
            argv = ['client', '--config', 'test.json', '--project', 'alpha',
                    'input', '--action', 'type', '--text', '中文']
            if actor == 'human':
                argv += ['--actor', 'human']
            with patch.object(sys, 'argv', argv), patch('host.client.read_config', return_value={'alpha': {}}), \
                    patch('host.client.GuestClient') as factory, redirect_stdout(io.StringIO()):
                factory.return_value.operation.return_value = {'actions': 1}
                self.assertEqual(main(), 0)
                factory.return_value.operation.assert_called_once_with(
                    'input', actor=actor, action='type', text='中文')


if __name__ == '__main__': unittest.main()
