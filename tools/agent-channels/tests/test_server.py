import importlib.util
import json
from pathlib import Path
import subprocess
import threading
import unittest
from unittest.mock import patch
from types import SimpleNamespace
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer

spec = importlib.util.spec_from_file_location('server', Path(__file__).parents[1] / 'backend' / 'server.py')
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)

class Display:
    def __init__(self): self.calls = []; self.failure = None
    def input(self, args, stdin):
        self.calls.append((args, stdin))
        if self.failure: raise self.failure
    def screenshot(self): return b'\x89PNG\r\n\x1a\nfixture'
    def frame_jpeg(self): return b'\xff\xd8\xfffixture'

class ChannelTests(unittest.TestCase):
    def setUp(self): self.display = Display(); self.channel = server.Channel(self.display)
    def test_unicode_uses_private_clipboard(self):
        display=object.__new__(server.XDisplay);display.env={'DISPLAY':':99'}
        value='岩隅'.encode('utf-8')
        with patch.object(server.subprocess,'run',return_value=SimpleNamespace(stdout=value)) as run:
            display.input(['type','--file','-'],value)
            self.assertEqual(run.call_count,3)
            self.assertEqual(run.call_args_list[0].args[0],['xclip','-selection','clipboard','-in'])
            self.assertEqual(run.call_args_list[0].kwargs['input'],value)
            self.assertEqual(run.call_args_list[-1].args[0],['xdotool','key','--clearmodifiers','ctrl+v'])
            self.assertTrue(all(c.kwargs['env']=={'DISPLAY':':99'} and c.kwargs['shell'] is False for c in run.call_args_list))
    def test_jpeg_capture_uses_bounded_quality_and_validates_signature(self):
        display=object.__new__(server.XDisplay); display.env={'DISPLAY':':99'}
        with patch.object(server.subprocess,'run',return_value=SimpleNamespace(stdout=b'\xff\xd8\xffframe')) as run:
            self.assertEqual(display.frame_jpeg(),b'\xff\xd8\xffframe')
            self.assertEqual(run.call_args.args[0],
                             ['import','-display',':99','-window','root','-quality','72','jpeg:-'])
            self.assertEqual(run.call_args.kwargs['timeout'],8)
            self.assertFalse(run.call_args.kwargs['shell'])
        with patch.object(server.subprocess,'run',return_value=SimpleNamespace(stdout=b'not-jpeg')):
            with self.assertRaises(RuntimeError): display.frame_jpeg()
    def test_default_pause_and_takeover(self):
        action = dict(actor='agent', action='click', x=10, y=20)
        with self.assertRaises(server.Conflict): self.channel.act(action)
        self.channel.control('agent'); self.channel.act(action)
        self.channel.control('human')
        with self.assertRaises(server.Conflict): self.channel.act(action)
        self.channel.act(dict(action, actor='human'))
        self.channel.control('paused')
        with self.assertRaises(server.Conflict): self.channel.act(dict(action, actor='human'))
        self.assertEqual(len(self.display.calls), 2)
        self.assertEqual((self.channel.status()['width'],self.channel.status()['height']),(1600,900))
    def test_repeated_same_coordinate_click_does_not_sync_on_movement(self):
        action = dict(actor='agent', action='click', x=250, y=463)
        self.channel.control('agent')
        self.channel.act(action); self.channel.act(action)
        self.assertEqual(self.display.calls, [
            (['mousemove','250','463','click','1'], None),
            (['mousemove','250','463','click','1'], None),
        ])
        self.assertNotIn('--sync', self.display.calls[0][0])
        self.assertEqual(self.channel.status()['actions'], 2)
    def test_channels_do_not_share_input_or_mode(self):
        other = server.Channel(Display()); self.channel.control('agent')
        self.channel.act(dict(actor='agent', action='key', key='Return'))
        self.assertEqual(other.status()['mode'], 'paused'); self.assertEqual(other.display.calls, [])
    def test_bounds_and_command_injection(self):
        for data in [dict(action='click', x=-1, y=0), dict(action='click', x=1600, y=0),
                     dict(action='click', x=True, y=0), dict(action='key', key='Return; calc'),
                     dict(action='key', key=[]), dict(action='shell', command='id'),
                     dict(action='type', text='\0'), dict(action='type', text='x'*2001)]:
            with self.subTest(data=data), self.assertRaises(server.Invalid):
                server.validate_action(dict(data, actor='agent'), 1600, 900)
        _, args, stdin = server.validate_action(dict(actor='agent', action='type', text='$(touch x); --help'),1600,900)
        self.assertEqual(args, ['type','--clearmodifiers','--delay','1','--file','-'])
        self.assertEqual(stdin, b'$(touch x); --help')
        for key in ('ctrl+l','ctrl+r','ctrl+t','ctrl+w','ctrl+shift+t'):
            _, args, stdin = server.validate_action(dict(actor='human',action='key',key=key),1600,900)
            self.assertEqual(args,['key','--clearmodifiers',key]); self.assertIsNone(stdin)
    def test_takeover_waits_for_inflight_action(self):
        started, release, finished = threading.Event(), threading.Event(), threading.Event()
        class Slow(Display):
            def input(self, args, stdin): started.set(); release.wait(2)
        channel = server.Channel(Slow()); channel.control('agent')
        action = threading.Thread(target=lambda: channel.act(dict(actor='agent',action='key',key='Return')))
        action.start(); self.assertTrue(started.wait(1))
        takeover = threading.Thread(target=lambda: (channel.control('human'), finished.set()))
        takeover.start(); self.assertFalse(finished.wait(.05)); release.set()
        action.join(2); takeover.join(2); self.assertTrue(finished.is_set())
        with self.assertRaises(server.Conflict): channel.act(dict(actor='agent',action='key',key='Return'))

    def test_failed_input_pauses_channel(self):
        class Failed(Display):
            def input(self, args, stdin): raise TimeoutError('injection timed out')
        channel=server.Channel(Failed()); channel.control('agent')
        with self.assertRaises(server.InputFailure) as failure:
            channel.act(dict(actor='agent',action='key',key='Return'))
        self.assertEqual(channel.status()['mode'],'paused')
        self.assertEqual(channel.status()['actions'],0)
        self.assertEqual(failure.exception.diagnostic['category'],'timeout')
        self.assertEqual(failure.exception.diagnostic['stage'],'key')
    def test_failed_input_diagnostic_excludes_sensitive_values(self):
        command_secret = 'command-secret'
        stderr_secret = b'stderr-secret'
        input_secret = 'input-secret token-secret'
        self.display.failure = subprocess.CalledProcessError(
            23, ['xdotool', command_secret], stderr=stderr_secret)
        self.channel.control('agent')
        with self.assertRaises(server.InputFailure) as failure:
            self.channel.act(dict(actor='agent',action='type',text=input_secret))
        public = json.dumps({'failure': failure.exception.diagnostic,
                             'state': self.channel.status()})
        self.assertEqual(failure.exception.diagnostic['category'],'process_exit')
        self.assertEqual(failure.exception.diagnostic['exception_type'],'CalledProcessError')
        self.assertEqual(failure.exception.diagnostic['stage'],'text_type')
        self.assertEqual(failure.exception.diagnostic['exit_code'],23)
        self.assertGreaterEqual(failure.exception.diagnostic['duration_ms'],0)
        for secret in (command_secret, stderr_secret.decode(), input_secret, 'token-secret'):
            self.assertNotIn(secret, public)

class HttpTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.channel=server.Channel(Display())
        cls.http=ThreadingHTTPServer(('127.0.0.1',0),server.handler_for(cls.channel,'a'*64))
        cls.thread=threading.Thread(target=cls.http.serve_forever,daemon=True); cls.thread.start()
        cls.base='http://127.0.0.1:'+str(cls.http.server_port)
    @classmethod
    def tearDownClass(cls): cls.http.shutdown(); cls.http.server_close(); cls.thread.join()
    def call(self, path, body=None, token=True, origin=None):
        headers={'Content-Type':'application/json'}
        if token: headers['Authorization']='Bearer '+'a'*64
        if origin: headers['Origin']=origin
        request=urllib.request.Request(self.base+path, data=None if body is None else json.dumps(body).encode(),headers=headers)
        try:
            with urllib.request.urlopen(request,timeout=3) as response: return response.status,response.read()
        except urllib.error.HTTPError as response: return response.code,response.read()
    def test_auth_and_browser_origin(self):
        self.assertEqual(self.call('/api/state',token=False)[0],401)
        self.assertEqual(self.call('/api/state',origin='https://example.org')[0],401)
        self.assertEqual(self.call('/health',token=False)[0],200)
    def test_input_requires_matching_controller(self):
        self.assertEqual(self.call('/api/control',dict(mode='paused'))[0],200)
        self.assertEqual(self.call('/api/input',dict(actor='agent',action='key',key='Return'))[0],409)
        self.assertEqual(self.call('/api/control',dict(mode='agent'))[0],200)
        self.assertEqual(self.call('/api/input',dict(actor='agent',action='key',key='Return'))[0],200)
        self.assertEqual(self.call('/api/input',dict(actor='human',action='key',key='Return'))[0],409)
    def test_screenshot_and_invalid_request(self):
        status,png=self.call('/api/screenshot'); self.assertEqual(status,200); self.assertTrue(png.startswith(b'\x89PNG'))
        self.assertEqual(self.call('/api/control',[])[0],400)
        self.assertEqual(self.call('/api/control',dict(mode='root'))[0],400)
        self.assertEqual(self.call('/missing')[0],404)
    def test_jpeg_frame_is_authenticated_and_does_not_replace_png(self):
        status,jpeg=self.call('/api/frame.jpg')
        self.assertEqual(status,200); self.assertTrue(jpeg.startswith(b'\xff\xd8\xff'))
        request=urllib.request.Request(self.base+'/api/frame.jpg')
        with self.assertRaises(urllib.error.HTTPError) as denied:
            urllib.request.urlopen(request,timeout=3)
        self.assertEqual(denied.exception.code,401)
        with urllib.request.urlopen(urllib.request.Request(
                self.base+'/api/frame.jpg', headers={'Authorization':'Bearer '+'a'*64}), timeout=3) as response:
            self.assertEqual(response.headers.get_content_type(),'image/jpeg')
            self.assertEqual(response.headers['Cache-Control'],'no-store')
    def test_input_failure_returns_safe_diagnostic_and_pauses(self):
        command_secret = 'command-secret'
        stderr_secret = 'stderr-secret'
        input_secret = 'input-secret token-secret'
        self.channel.display.failure = subprocess.CalledProcessError(
            19, ['xdotool', command_secret], stderr=stderr_secret.encode())
        try:
            self.assertEqual(self.call('/api/control',dict(mode='agent'))[0],200)
            status, raw = self.call('/api/input',dict(actor='agent',action='type',text=input_secret))
            body = json.loads(raw)
            self.assertEqual(status,503)
            self.assertEqual(body['diagnostic']['category'],'process_exit')
            self.assertEqual(body['diagnostic']['stage'],'text_type')
            self.assertEqual(body['diagnostic']['exit_code'],19)
            self.assertEqual(self.channel.status()['mode'],'paused')
            public = raw.decode() + json.dumps(self.channel.status())
            for secret in (command_secret, stderr_secret, input_secret, 'token-secret'):
                self.assertNotIn(secret, public)
        finally:
            self.channel.display.failure = None
            self.channel.control('paused')

if __name__=='__main__': unittest.main(verbosity=2)
