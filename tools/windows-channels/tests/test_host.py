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
from host.client import GuestClient, MAX_RESPONSE, normalize_key, read_config
from host.client import main
from guest import protocol

VM = 'ca6d2942-6d2c-4050-9ba5-b9bca1754b28'
BIOS = '5a73f8d6-cf5b-41c2-a423-989a8772a9cb'
DIGEST = 'd' * 64
NONCE = 'c' * 64


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


class Desktop:
    def __init__(self): self.actions = []
    def probe_ready(self): return True, 'ready'
    def dimensions(self): return 1280, 800
    def perform(self, request): self.actions.append(request)
    def screenshot_png(self): return b'\x89PNG\r\n\x1a\n' + b'\x00' * 8 + struct.pack('!II', 1280, 800)


class ProtocolStream(Stream):
    def __init__(self, channel, bios=BIOS):
        super().__init__([])
        self.channel = channel
        self.bios = bios
    def sendall(self, frame):
        request = json.loads(frame[4:])
        self.sent.append(request)
        response = protocol.dispatch(request, 'a' * 64, self.channel)
        data = json.dumps(response).encode()
        self.buffer = struct.pack('!I', len(data)) + data


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
    def leased_client(self, human='c' * 64, bios=BIOS):
        self.human_file = self.root / 'human-token'
        self.human_file.write_text(human)
        self.binding['human_token_file'] = self.human_file
        self.desktop = Desktop()
        self.channel = protocol.GuestChannel(self.desktop, dict(bios_uuid=bios),
                                             broker_token='b' * 64, human_token='c' * 64)
        self.stream = ProtocolStream(self.channel)
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
    def test_familiar_enter_key_spelling_is_canonicalized_before_guest(self):
        self.assertEqual(normalize_key('ENTER'), 'Return')
        self.assertEqual(normalize_key('Enter'), 'Return')
        self.assertEqual(normalize_key('CTRL+L'), 'ctrl+l')
        client = self.client([dict(id='1', ok=True, result=state()), dict(id='2', ok=True, result=dict(actions=1))])
        client.operation('input', actor='agent', action='key', key='ENTER')
        self.assertEqual(self.stream.sent[-1]['key'], 'Return')
    def test_duplicate_guest_bindings_rejected(self):
        path = self.root / 'config.json'
        item = dict(vm_id=VM, bios_uuid=BIOS, token_file='token')
        path.write_text(json.dumps(dict(schema_version=1, projects=dict(alpha=item, beta=item))))
        with self.assertRaisesRegex(ValueError, 'must not share'):
            read_config(path)
    def test_mismatched_response_id_rejected(self):
        client = self.client([dict(id=99, ok=True, result=state())])
        with self.assertRaises(ValueError): client.state()

    def test_wechat_operation_checks_identity_mode_and_startup_digest(self):
        fields = dict(action='check-login', project_id='qicheng',
                      lease_owner='worker-a', lease_generation=1,
                      lease_nonce=NONCE, config_digest=DIGEST)
        for observed in (state(VM), state(mode='human'), state(),
                         dict(state(), desktop_ready=True, wechat_config_digest='e' * 64)):
            with self.subTest(observed=observed):
                client = self.client([dict(id='1', ok=True, result=observed)])
                with self.assertRaises(RuntimeError):
                    client.operation('wechat_cli', **fields)
                self.assertEqual([r['op'] for r in self.stream.sent], ['state'])
        ready = dict(state(), desktop_ready=True, wechat_config_digest=DIGEST)
        client = self.client([dict(id='1', ok=True, result=ready),
                              dict(id='2', ok=True, result={'login': False})])
        self.assertEqual(client.operation('wechat_cli', **fields), {'login': False})
        self.assertEqual([r['op'] for r in self.stream.sent], ['state', 'wechat_cli'])
        self.assertEqual({k: v for k, v in self.stream.sent[-1].items()
                          if k not in {'id', 'token', 'op'}}, fields)

    def test_wechat_operation_rejects_extra_fields_and_unfixed_action(self):
        client = self.client([])
        fields = dict(action='check-login', project_id='qicheng',
                      lease_owner='worker-a', lease_generation=1,
                      lease_nonce=NONCE, config_digest=DIGEST)
        for changed in (dict(action='open'), dict(argv=['anything']),
                        dict(config_digest='D' * 64), dict(lease_generation=True)):
            with self.subTest(changed=changed), self.assertRaises(ValueError):
                client.operation('wechat_cli', **(fields | changed))
        self.assertEqual(self.stream.sent, [])

    def test_distinct_human_token_routes_viewer_handback(self):
        client = self.leased_client()
        self.assertEqual(client.operation('control', mode='human')['mode'], 'human')
        self.assertEqual(client.operation('input', actor='human', action='key', key='ENTER')['actions'], 1)
        with self.assertRaisesRegex(RuntimeError, 'Human takeover'):
            client.operation('control', mode='agent')
        self.assertEqual(client.operation('control', mode='paused')['mode'], 'paused')
        self.assertEqual(client.operation('control', mode='agent')['mode'], 'agent')
        self.assertEqual(client.operation('screenshot')['mime_type'], 'image/png')
        requests = self.stream.sent
        self.assertTrue(all(r['token'] == 'a' * 64 for r in requests if r['op'] in ('state', 'screenshot')))
        self.assertTrue(all(r['token'] == 'c' * 64 for r in requests if r['op'] == 'control'
                            or (r['op'] == 'input' and r['actor'] == 'human')))
        self.assertEqual([r['mode'] for r in requests if r['op'] == 'control'],
                         ['human', 'paused', 'agent'])
        self.assertEqual(self.desktop.actions[0]['key'], 'Return')

    def test_wrong_human_token_and_wrong_identity_refuse_before_action(self):
        client = self.leased_client(human='d' * 64)
        with self.assertRaisesRegex(RuntimeError, 'Guest rejected'):
            client.operation('control', mode='human')
        self.assertEqual([r['op'] for r in self.stream.sent], ['state', 'control'])
        self.assertEqual(self.channel.mode, 'paused')
        client = self.leased_client(bios=VM)
        with self.assertRaisesRegex(RuntimeError, 'identity mismatch'):
            client.operation('control', mode='human')
        self.assertEqual([r['op'] for r in self.stream.sent], ['state'])

    def test_human_token_file_and_value_are_independent(self):
        path = self.root / 'config.json'
        item = dict(vm_id=VM, bios_uuid=BIOS, token_file='token', human_token_file='token')
        path.write_text(json.dumps(dict(schema_version=1, projects=dict(alpha=item))))
        with self.assertRaisesRegex(ValueError, 'must differ'):
            read_config(path)
        item['human_token_file'] = 'human-token'
        self.human_file = self.root / 'human-token'
        self.human_file.write_text('a' * 64)
        path.write_text(json.dumps(dict(schema_version=1, projects=dict(alpha=item))))
        binding = read_config(path)['alpha']
        stream = Stream([dict(id='1', ok=True, result=state())])
        client = GuestClient(binding, lambda *args: stream)
        with self.assertRaisesRegex(ValueError, 'values must differ'):
            client.operation('control', mode='human')

    def test_cli_viewer_commands_use_human_credential_without_printing_it(self):
        self.leased_client()
        config = self.root / 'config.json'
        config.write_text(json.dumps(dict(schema_version=1, projects=dict(alpha=dict(
            vm_id=VM, bios_uuid=BIOS, token_file='token', human_token_file='human-token')))))
        for command, arguments in (('takeover', []),
                                   ('input', ['--actor', 'human', '--action', 'key', '--key', 'Return']),
                                   ('allow', []), ('pause', []), ('allow', [])):
            output = io.StringIO()
            argv = ['client', '--config', str(config), '--project', 'alpha', command] + arguments
            with patch.object(sys, 'argv', argv), \
                    patch('host.client.GuestClient', side_effect=lambda binding: GuestClient(
                        binding, lambda *args: self.stream)), redirect_stdout(output):
                self.assertEqual(main(), 1 if command == 'allow' and self.channel.mode == 'human' else 0)
            self.assertNotIn('c' * 64, output.getvalue())
        self.assertEqual(self.channel.mode, 'agent')
        self.assertEqual([r['mode'] for r in self.stream.sent if r['op'] == 'control'],
                         ['human', 'paused', 'agent'])


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
