import importlib.util
import json
import threading
import unittest
import urllib.error
import urllib.request
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
from http.server import ThreadingHTTPServer


spec = importlib.util.spec_from_file_location('wechat_server', Path(__file__).parents[1] / 'backend' / 'server.py')
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)
result_spec = importlib.util.spec_from_file_location('wechat_cli_result', Path(__file__).parents[1] / 'wechat-cli-result.py')
cli_result = importlib.util.module_from_spec(result_spec)
result_spec.loader.exec_module(cli_result)


class WechatGuiHealthTests(unittest.TestCase):
    def test_gui_liveness_is_bounded(self):
        with patch.object(server.subprocess, 'run', return_value=SimpleNamespace(returncode=0, stdout=b'123\n')) as run:
            self.assertTrue(server.wechat_gui_alive())
            self.assertEqual(run.call_args.kwargs['timeout'], 1)
        with patch.object(server.subprocess, 'run', return_value=SimpleNamespace(returncode=1, stdout=b'')):
            self.assertFalse(server.wechat_gui_alive())

    def test_http_health_and_state_fail_when_wechat_window_disappears(self):
        channel = server.Channel(object(), broker_enabled=True, channel_id='1')
        token, broker, viewer = 'a' * 64, 'b' * 64, 'c' * 64
        http = ThreadingHTTPServer(('127.0.0.1', 0), server.handler_for(channel, token, broker, viewer))
        thread = threading.Thread(target=http.serve_forever, daemon=True)
        thread.start()
        base = f'http://127.0.0.1:{http.server_port}'
        try:
            with patch.dict(server.os.environ, {'QICHENG_DESKTOP_APP': 'wechat'}), patch.object(server, 'wechat_gui_alive', return_value=False):
                for route, headers in (('/health', {}), ('/api/state', {'Authorization': 'Bearer ' + token})):
                    with self.assertRaises(urllib.error.HTTPError) as error:
                        urllib.request.urlopen(urllib.request.Request(base + route, headers=headers), timeout=2)
                    self.assertEqual(error.exception.code, 503)
                    self.assertIn('WeChat desktop GUI unavailable', error.exception.read().decode())
            with patch.dict(server.os.environ, {'QICHENG_DESKTOP_APP': 'wechat'}), patch.object(server, 'wechat_gui_alive', return_value=True):
                req = urllib.request.Request(base + '/api/state', headers={'Authorization': 'Bearer ' + token})
                with urllib.request.urlopen(req, timeout=2) as response:
                    state = json.load(response)
                self.assertEqual(state['desktop_app'], 'wechat')
                self.assertTrue(state['gui_alive'])
                self.assertEqual(state['input_auth'], 'broker-v2')
        finally:
            http.shutdown()
            http.server_close()
            thread.join(timeout=2)


class WechatCliResultTests(unittest.TestCase):
    def test_nonzero_numeric_and_string_codes_fail_even_with_zero_process_exit(self):
        for output in ('[error] failed', '{"code":10}', '{"code":-1}', '{"code":"-1"}', '{"code":"failure"}'):
            with self.subTest(output=output):
                self.assertTrue(cli_result.failed(output))

    def test_login_false_is_valid_cli_result_not_authentication_success(self):
        for output in ('{"login":false}', '{"code":0}', '{"code":"0"}'):
            with self.subTest(output=output):
                self.assertFalse(cli_result.failed(output))
