import importlib.util
from pathlib import Path
import unittest
import urllib.error

spec=importlib.util.spec_from_file_location('bridge',Path(__file__).parents[1]/'bridge.py')
bridge=importlib.util.module_from_spec(spec); spec.loader.exec_module(bridge)

class BridgeTests(unittest.TestCase):
    def setUp(self): self.bridge=object.__new__(bridge.Bridge)
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

if __name__=='__main__': unittest.main(verbosity=2)
