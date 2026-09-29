from pathlib import Path
import sys
import unittest
from unittest.mock import Mock
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from host.mcp import Bridge, read_request, MAX_REQUEST_BYTES
import io
import json


class McpTests(unittest.TestCase):
    def setUp(self): self.client = Mock(); self.bridge = Bridge(self.client)
    def test_only_three_tools_and_no_control(self):
        result = self.bridge.handle(dict(id=1, method='tools/list'))
        self.assertEqual([t['name'] for t in result['result']['tools']], ['windows_channel_state', 'windows_channel_screenshot', 'windows_channel_input'])
    def test_tool_read_only_annotations_in_direct_and_broker_modes(self):
        expected = {
            'windows_channel_state': {'readOnlyHint': True},
            'windows_channel_screenshot': {'readOnlyHint': True},
            'windows_channel_input': {'readOnlyHint': False},
            'windows_channel_wechat_check_login': {'readOnlyHint': True},
        }
        for mode, bridge in (('direct', self.bridge), ('broker', Bridge(self.client, Mock()))):
            with self.subTest(mode=mode):
                response = bridge.handle({'id': 1, 'method': 'tools/list'})
                listed = json.loads(json.dumps(response))['result']['tools']
                annotations = {tool['name']: tool['annotations'] for tool in listed}
                self.assertEqual(expected if mode == 'broker' else {
                    key: value for key, value in expected.items()
                    if key != 'windows_channel_wechat_check_login'}, annotations)
    def test_actor_override_refused(self):
        with self.assertRaises(ValueError):
            self.bridge.tool('windows_channel_input', dict(actor='human', action='key', key='Return'))
        self.client.operation.assert_not_called()
    def test_valid_input_forces_agent(self):
        self.client.operation.return_value = dict(actions=1)
        self.bridge.tool('windows_channel_input', dict(action='key', key='Return'))
        self.client.operation.assert_called_once_with('input', actor='agent', action='key', key='Return')
    def test_error_does_not_echo_transport_secrets(self):
        self.client.operation.side_effect = RuntimeError('secret-token')
        result = self.bridge.handle(dict(id=2, method='tools/call', params=dict(name='windows_channel_input', arguments=dict(action='key', key='Return'))))
        self.assertTrue(result['result']['isError']); self.assertNotIn('secret-token', str(result))
    def test_screenshot_is_image_content(self):
        self.client.operation.return_value = dict(mime_type='image/png', data='cG5n')
        result = self.bridge.tool('windows_channel_screenshot', {})
        self.assertEqual(result['content'][0]['type'], 'image')

    def test_broker_tools_explicit_session_and_no_guest_input(self):
        broker = Mock()
        broker.begin.return_value = {'session': 'active'}
        broker.input.return_value = {'ok': True}
        broker.finish.return_value = {'session': 'finished'}
        bridge = Bridge(self.client, broker)
        tools = bridge.handle(dict(id=1, method='tools/list'))['result']['tools']
        self.assertEqual([tool['name'] for tool in tools],
                         ['windows_channel_state', 'windows_channel_screenshot',
                          'windows_channel_input',
                          'windows_channel_wechat_check_login'])
        self.assertIn('begin', tools[2]['inputSchema']['properties']['action']['enum'])
        wait_schema = tools[2]['inputSchema']['properties']['wait_seconds']
        self.assertEqual({'type': 'integer', 'minimum': 0, 'maximum': 300},
                         {key: wait_schema[key] for key in ('type', 'minimum', 'maximum')})
        self.assertIn('30 seconds', tools[2]['description'])
        self.assertIn('confirmed finish permits a new begin', tools[2]['description'])
        bridge.tool('windows_channel_input', {'action': 'begin'})
        bridge.tool('windows_channel_input', {'action': 'key', 'key': 'Return'})
        bridge.tool('windows_channel_input', {'action': 'finish'})
        broker.begin.assert_called_once_with()
        broker.input.assert_called_once_with('key', key='Return')
        broker.finish.assert_called_once_with()
        self.client.operation.assert_not_called()

    def test_wechat_is_zero_argument_broker_only_boolean_tool(self):
        broker = Mock()
        broker.wechat_check_login.return_value = False
        bridge = Bridge(self.client, broker)
        name = 'windows_channel_wechat_check_login'
        tool = bridge.handle({'id': 1, 'method': 'tools/list'})['result']['tools'][-1]
        self.assertEqual(name, tool['name'])
        self.assertEqual({'type': 'object', 'properties': {}, 'additionalProperties': False},
                         tool['inputSchema'])
        self.assertIn('User authorization', tool['description'])
        self.assertIn('Source candidate', tool['description'])
        with self.assertRaises(ValueError):
            self.bridge.tool(name, {})
        with self.assertRaises(ValueError):
            bridge.tool(name, {'action': 'check-login'})
        broker.wechat_check_login.assert_not_called()
        result = bridge.tool(name, {})
        self.assertEqual('false', result['content'][0]['text'])
        broker.wechat_check_login.assert_called_once_with()
        self.client.operation.assert_not_called()

    def test_broker_wait_override_is_begin_only(self):
        broker = Mock()
        broker.begin.return_value = {'session': 'active'}
        bridge = Bridge(self.client, broker)
        bridge.tool('windows_channel_input', {'action': 'begin', 'wait_seconds': 0})
        bridge.tool('windows_channel_input', {'action': 'begin', 'wait_seconds': 300})
        self.assertEqual([unittest.mock.call(wait_seconds=0),
                          unittest.mock.call(wait_seconds=300)], broker.begin.call_args_list)
        for action in ('finish', 'key'):
            with self.subTest(action=action), self.assertRaises(ValueError):
                bridge.tool('windows_channel_input', {'action': action,
                                                     'wait_seconds': 1})
        broker.input.assert_not_called()
        broker.finish.assert_not_called()
        self.client.operation.assert_not_called()

    def test_direct_mode_refuses_queue_argument(self):
        with self.assertRaises(ValueError):
            self.bridge.tool('windows_channel_input', {'action': 'key',
                                                      'key': 'Return',
                                                      'wait_seconds': 30})
        self.client.operation.assert_not_called()

    def test_broker_screenshot_is_direct_read_only_unprotected(self):
        bridge = Bridge(self.client, Mock())
        self.client.operation.return_value = {'mime_type': 'image/png', 'data': 'cG5n'}
        self.assertEqual('image', bridge.tool('windows_channel_screenshot', {})['content'][0]['type'])
        self.client.operation.assert_called_once_with('screenshot')
        instructions = bridge.handle({'id': 1, 'method': 'initialize'})['result']['instructions']
        self.assertIn('not atomically protected', instructions)
        self.assertIn('same-channel queue', instructions)
        self.assertIn('confirmed finish permits a new begin', instructions)
        self.assertIn('no host fallback', instructions.lower())

    def test_bounded_binary_read_and_eof(self):
        stream = io.BytesIO(b'{"id":1}\n{"id":2}\n')
        self.assertEqual(read_request(stream), {'id': 1})
        self.assertEqual(read_request(stream), {'id': 2})
        self.assertIsNone(read_request(stream))

    def test_oversized_line_is_not_fully_read(self):
        stream = io.BytesIO(b'x' * (MAX_REQUEST_BYTES * 2))
        with self.assertRaises(ValueError): read_request(stream)
        self.assertEqual(stream.tell(), MAX_REQUEST_BYTES + 1)

    def test_limit_counts_utf8_bytes_not_characters(self):
        payload = json.dumps({'text': '\u4e2d' * 23000}, ensure_ascii=False).encode('utf-8')
        self.assertLess(len(payload.decode('utf-8')), MAX_REQUEST_BYTES)
        with self.assertRaises(ValueError): read_request(io.BytesIO(payload))


if __name__ == '__main__': unittest.main()
