import importlib.util
import json
import secrets
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import unittest
import urllib.error

ROOT=Path(__file__).parents[1]
sys.path.insert(0,str(ROOT))
spec=importlib.util.spec_from_file_location('bridge',ROOT/'bridge.py')
bridge=importlib.util.module_from_spec(spec); spec.loader.exec_module(bridge)
from broker_client import BrokerClient

class BridgeTests(unittest.TestCase):
    def setUp(self):
        self.bridge=object.__new__(bridge.Bridge)
        self.bridge.broker=None
    def test_handshake_and_notifications(self):
        response=self.bridge.handle({'id':1,'method':'initialize','params':{'protocolVersion':'2025-06-18'}})
        self.assertEqual(response['result']['protocolVersion'],'2025-06-18')
        self.assertIsNone(self.bridge.handle({'method':'notifications/initialized'}))
        self.assertEqual(self.bridge.handle({'id':2,'method':'ping'})['result'],{})
    def test_no_controller_override_tool(self):
        result=self.bridge.handle({'id':2,'method':'tools/list'})
        self.assertEqual([x['name'] for x in result['result']['tools']],['channel_state','channel_screenshot','channel_input'])
        with self.assertRaises(ValueError): self.bridge.tool('channel_input',{'actor':'human','action':'key','key':'Return'})
    def test_agent_actor_and_images(self):
        calls=[]
        def request(path,data=None):
            calls.append((path,data)); return b'{}'
        self.bridge.request=request
        self.bridge.tool('channel_input',{'action':'key','key':'Return'})
        self.assertEqual(calls[0][1]['actor'],'agent')
        self.assertEqual(self.bridge.tool('channel_screenshot',{})['content'][0]['type'],'image')
    def test_rejected_input_is_tool_error(self):
        def rejected(*_): raise urllib.error.HTTPError('local',409,'conflict',{},None)
        self.bridge.request=rejected
        response=self.bridge.handle({'id':3,'method':'tools/call','params':{'name':'channel_input','arguments':{'action':'key','key':'Return'}}})
        self.assertTrue(response['result']['isError'])

    def test_broker_routes_only_input_through_lease(self):
        class FakeBroker:
            def __init__(self): self.calls=[]
            def begin(self,**kw): self.calls.append(('begin',kw)); return {'session':'active'}
            def input(self,action,**kw): self.calls.append((action,kw)); return {'ok':True}
            def finish(self): self.calls.append(('finish',{})); return {'session':'finished'}
        self.bridge.broker=FakeBroker()
        schema=self.bridge.handle({'id':1,'method':'tools/list'})['result']['tools'][2]['inputSchema']
        self.assertEqual(schema['properties']['button']['enum'],[1,2,3])
        direct=[]
        self.bridge.request=lambda path,data=None: direct.append((path,data)) or b'{}'
        self.bridge.tool('channel_state',{})
        self.bridge.tool('channel_screenshot',{})
        self.bridge.tool('channel_input',{'action':'begin','wait_seconds':0})
        self.bridge.tool('channel_input',{'action':'key','key':'Return'})
        self.bridge.tool('channel_input',{'action':'finish'})
        self.assertEqual([x[0] for x in direct],['/api/state','/api/screenshot'])
        self.assertEqual([x[0] for x in self.bridge.broker.calls],['begin','key','finish'])


class BrokerClientTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.token=Path(self.temp.name)/'broker.token'
        self.token.write_text(secrets.token_hex(32),encoding='ascii')
        self.client=BrokerClient('http://127.0.0.1:18770',self.token,'lite-1',1)
        self.addCleanup(self.client._kill)
        self.calls=[]
        self.generation=0
        self.lease=None
        self.fail_path=None
        self.mismatch_identity=False
        self.client._post=self.post

    def post(self,path,payload,**kw):
        self.calls.append((path,payload))
        if path==self.fail_path: raise ConnectionError('uncertain')
        if path=='/v1/acquire':
            self.generation+=1
            identity={'channel_id':'lite-1','channel_number':1,'port':18761}
            if self.mismatch_identity: identity['port']=18762
            self.lease=dict(request_id=payload['request_id'],task_id=payload['task_id'],
                            channel_id='lite-1',generation=self.generation,
                            token=f'{self.generation:064x}',expires_at=time.time()+30,
                            lite_identity=identity)
            return dict(self.lease)
        if path=='/v1/renew':
            self.lease['expires_at']=time.time()+30
            return dict(self.lease)
        if path=='/v1/input': return {'ok':True,'action':payload['action']}
        if path=='/v1/ack': return {'ok':True,'action_id':payload['action_id']}
        if path=='/v1/release':
            return {'released':{'request_id':self.lease['request_id'],'channel_id':'lite-1'}}
        raise AssertionError(path)

    def test_begin_multiple_actions_ack_finish(self):
        self.client.begin(0)
        self.client.input('key',key='Enter')
        self.client.input('click',x=1,y=2,button=3)
        self.client.finish()
        self.assertEqual([p for p,_ in self.calls],['/v1/acquire','/v1/input','/v1/ack',
                                                  '/v1/input','/v1/ack','/v1/release'])
        self.assertEqual(self.calls[1][1]['key'],'Return')
        self.assertEqual(self.client.phase,'finished')

    def test_wrong_lite_identity_kills_before_input(self):
        self.mismatch_identity=True
        with self.assertRaises(RuntimeError): self.client.begin(0)
        self.assertEqual(self.client.phase,'dead')
        with self.assertRaises(RuntimeError): self.client.begin(0)
        self.assertEqual([p for p,_ in self.calls],['/v1/acquire'])

    def test_uncertain_finish_is_fatal(self):
        self.client.begin(0)
        self.fail_path='/v1/release'
        with self.assertRaises(RuntimeError): self.client.finish()
        self.assertEqual(self.client.phase,'dead')
        with self.assertRaises(RuntimeError): self.client.begin(0)
        self.assertEqual([p for p,_ in self.calls],['/v1/acquire','/v1/release'])

    def test_invalid_action_ends_active_session_without_network_input(self):
        self.client.begin(0)
        with self.assertRaises(RuntimeError): self.client.input('click',x=True,y=2)
        self.assertEqual(self.client.phase,'dead')
        self.assertEqual([p for p,_ in self.calls],['/v1/acquire'])

    def test_expired_lease_cannot_send_input(self):
        self.client.begin(0)
        self.client.deadline=self.client.clock()-1
        with self.assertRaises(RuntimeError): self.client.input('key',key='Return')
        self.assertEqual(self.client.phase,'dead')
        self.assertEqual([p for p,_ in self.calls],['/v1/acquire'])

    def test_ack_or_renew_uncertainty_ends_session_without_retry(self):
        for path in ('/v1/ack','/v1/renew'):
            with self.subTest(path=path):
                self.setUp()
                self.client.begin(0)
                self.fail_path=path
                if path=='/v1/renew': self.client.deadline=self.client.clock()+1
                with self.assertRaises(RuntimeError): self.client.input('key',key='Return')
                count=len(self.calls)
                self.assertEqual(self.client.phase,'dead')
                with self.assertRaises(RuntimeError): self.client.begin(0)
                self.assertEqual(len(self.calls),count)

    def test_bad_config(self):
        with self.assertRaises(ValueError): BrokerClient('http://example.com:18770',self.token,'lite-1',1)
        with self.assertRaises(ValueError): BrokerClient('http://127.0.0.1:18770',self.token,'lite-1',3)


class TwoProcessContentionTests(unittest.TestCase):
    def test_partial_broker_configuration_fails_at_startup(self):
        with tempfile.TemporaryDirectory() as folder:
            token=Path(folder)/'channel.token'; token.write_text(secrets.token_hex(32))
            result=subprocess.run([sys.executable,str(ROOT/'bridge.py'),'--token-file',str(token),
                                   '--broker-url','http://127.0.0.1:18770'],
                                  input='',capture_output=True,text=True,timeout=5)
            self.assertEqual(result.returncode,1)
            self.assertEqual(result.stdout,'')

    def test_channel_and_broker_credentials_must_differ(self):
        with tempfile.TemporaryDirectory() as folder:
            token=Path(folder)/'shared.token'; token.write_text(secrets.token_hex(32))
            result=subprocess.run([sys.executable,str(ROOT/'bridge.py'),'--token-file',str(token),
                                   '--broker-url','http://127.0.0.1:18770',
                                   '--broker-token-file',str(token),
                                   '--broker-channel-id','lite-1'],
                                  input='',capture_output=True,text=True,timeout=5)
            self.assertEqual(result.returncode,1)
            self.assertEqual(result.stdout,'')

    def test_only_one_process_acquires_same_channel(self):
        credential=secrets.token_hex(32)
        state={'holder':None,'generation':0,'paths':[]}
        guard=threading.Lock()
        class Handler(BaseHTTPRequestHandler):
            def log_message(self,*args): pass
            def do_POST(self):
                length=int(self.headers['Content-Length'])
                body=json.loads(self.rfile.read(length))
                with guard:
                    state['paths'].append(self.path)
                    if self.headers.get('Authorization')!='Bearer '+credential:
                        status,result=401,{'error':'auth'}
                    elif self.path=='/v1/acquire' and state['holder'] is not None:
                        status,result=409,{'error':'held'}
                    elif self.path=='/v1/acquire':
                        state['generation']+=1
                        result=dict(request_id=body['request_id'],task_id=body['task_id'],
                                    channel_id='lite-1',generation=state['generation'],
                                    token=f"{state['generation']:064x}",expires_at=time.time()+30,
                                    lite_identity={'channel_id':'lite-1','channel_number':1,'port':18761})
                        state['holder']=result
                        status=200
                    elif self.path=='/v1/release' and state['holder'] and body['token']==state['holder']['token']:
                        result={'released':{'request_id':state['holder']['request_id'],'channel_id':'lite-1'}}
                        state['holder']=None; status=200
                    else: status,result=409,{'error':'unavailable'}
                encoded=json.dumps(result).encode()
                self.send_response(status)
                self.send_header('Content-Length',str(len(encoded)))
                self.end_headers(); self.wfile.write(encoded)
        server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
        thread=threading.Thread(target=server.serve_forever,daemon=True); thread.start()
        self.addCleanup(server.server_close); self.addCleanup(server.shutdown)
        with tempfile.TemporaryDirectory() as folder:
            channel_token=Path(folder)/'channel.token'; channel_token.write_text(secrets.token_hex(32))
            broker_token=Path(folder)/'broker.token'; broker_token.write_text(credential)
            command=[sys.executable,str(ROOT/'bridge.py'),'--channel','1','--token-file',str(channel_token),
                     '--broker-url',f'http://127.0.0.1:{server.server_port}',
                     '--broker-token-file',str(broker_token),'--broker-channel-id','lite-1']
            procs=[subprocess.Popen(command,stdin=subprocess.PIPE,stdout=subprocess.PIPE,
                                    stderr=subprocess.PIPE,text=True,encoding='utf-8') for _ in range(2)]
            try:
                def call(proc,number,action):
                    proc.stdin.write(json.dumps({'jsonrpc':'2.0','id':number,'method':'tools/call',
                        'params':{'name':'channel_input','arguments':{'action':action,'wait_seconds':0} if action=='begin' else {'action':action}}})+'\n')
                    proc.stdin.flush()
                    return json.loads(proc.stdout.readline())['result']
                self.assertNotIn('isError',call(procs[0],1,'begin'))
                self.assertTrue(call(procs[1],1,'begin')['isError'])
                self.assertTrue(call(procs[1],2,'begin')['isError'])
                self.assertNotIn('isError',call(procs[0],2,'finish'))
                self.assertEqual(state['paths'],['/v1/acquire','/v1/acquire','/v1/release'])
            finally:
                for proc in procs:
                    proc.stdin.close(); proc.terminate(); proc.wait(timeout=5)
                    proc.stdout.close(); proc.stderr.close()

if __name__=='__main__': unittest.main(verbosity=2)
