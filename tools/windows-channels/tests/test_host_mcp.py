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
