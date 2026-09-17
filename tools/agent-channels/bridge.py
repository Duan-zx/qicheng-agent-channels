"""Dependency-free MCP stdio adapter. Human must enable agent input in viewer first.
Never writes protocol logs or tokens to stdout; desktop traffic stays on loopback.
"""
import argparse
import base64
import json
from pathlib import Path
import sys
import urllib.request
import urllib.error

TOOLS = [
    {'name':'channel_state','description':'Read this isolated Linux desktop and input mode.', 'inputSchema':{'type':'object','properties':{},'additionalProperties':False}},
    {'name':'channel_screenshot','description':'See this isolated Linux desktop, not the Windows host.', 'inputSchema':{'type':'object','properties':{},'additionalProperties':False}},
    {'name':'channel_input','description':'Send one action to the isolated Linux desktop. Requires the human to select Allow agent in the viewer. Never falls back to the Windows host.',
     'inputSchema':{'type':'object','properties':{'action':{'enum':['click','move','type','key']},'x':{'type':'integer'},'y':{'type':'integer'},'button':{'type':'integer','enum':[1,2,3,4,5]},'text':{'type':'string','maxLength':2000},'key':{'type':'string'}},'required':['action'],'additionalProperties':False}},
]

class Bridge:
    def __init__(self, channel, token_path):
        if channel not in (1,2): raise ValueError('Channel must be 1 or 2')
        self.base='http://127.0.0.1:'+str(18760+channel)
        self.token=Path(token_path).read_text().strip()
        self.opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
    def request(self, path, data=None):
        headers={'Authorization':'Bearer '+self.token,'Content-Type':'application/json'}
        req=urllib.request.Request(self.base+path,headers=headers,data=None if data is None else json.dumps(data).encode())
        with self.opener.open(req,timeout=15) as response: return response.read()
    def tool(self, name, arguments):
        if not isinstance(arguments, dict): raise ValueError('Arguments must be an object')
        if name=='channel_screenshot':
            return {'content':[{'type':'image','mimeType':'image/png','data':base64.b64encode(self.request('/api/screenshot')).decode()}]}
        if name=='channel_state': result=self.request('/api/state').decode()
        elif name=='channel_input':
            allowed={'action','x','y','button','text','key'}
            if set(arguments)-allowed: raise ValueError('Unknown argument')
            result=self.request('/api/input',dict(arguments,actor='agent')).decode()
        else: raise ValueError('Unknown tool')
        return {'content':[{'type':'text','text':result}]}
    def handle(self, message):
        method=message.get('method'); request_id=message.get('id')
        if 'id' not in message: return None
        try:
            if method=='initialize':
                requested=message.get('params',{}).get('protocolVersion')
                version=requested if requested in ('2024-11-05','2025-03-26','2025-06-18') else '2025-06-18'
                result={'protocolVersion':version,'capabilities':{'tools':{}},'serverInfo':{'name':'agent-channels','version':'0.1.0'},
                        'instructions':'These tools target only one isolated Linux desktop, never the Windows host. Read channel_state and channel_screenshot before input. Coordinates are guest screenshot pixels. A human must enable agent mode in the viewer. If input is paused or taken over, stop and do not fall back to host computer-use tools. Capture a new screenshot after actions; follow user authorization for external actions.'}
            elif method=='ping': result={}
            elif method=='tools/list': result={'tools':TOOLS}
            elif method=='tools/call':
                params=message.get('params',{})
                try: result=self.tool(params.get('name'),params.get('arguments',{}))
                except urllib.error.HTTPError as exc:
                    result={'isError':True,'content':[{'type':'text','text':'Desktop request rejected (HTTP '+str(exc.code)+'). A human must enable agent mode; do not target the host instead.'}]}
                except Exception:
                    result={'isError':True,'content':[{'type':'text','text':'Isolated desktop unavailable or invalid action. No host fallback.'}]}
            else: return {'jsonrpc':'2.0','id':request_id,'error':{'code':-32601,'message':'Method not found'}}
            return {'jsonrpc':'2.0','id':request_id,'result':result}
        except Exception:
            return {'jsonrpc':'2.0','id':request_id,'error':{'code':-32602,'message':'Invalid parameters'}}

def main():
    sys.stdin.reconfigure(encoding='utf-8')
    sys.stdout.reconfigure(encoding='utf-8')
    parser=argparse.ArgumentParser()
    parser.add_argument('--channel',type=int,choices=[1,2],default=1)
    parser.add_argument('--token-file',default=str(Path(__file__).parent/'.local'/'channel.token'))
    args=parser.parse_args()
    try: bridge=Bridge(args.channel,args.token_file)
    except Exception:
        print('Local channel token unavailable. Run Start-Backend.ps1 first.',file=sys.stderr); return 1
    for line in sys.stdin:
        try:
            msg=json.loads(line)
            if not isinstance(msg,dict): raise ValueError()
            response=bridge.handle(msg)
        except Exception: response={'jsonrpc':'2.0','id':None,'error':{'code':-32700,'message':'Invalid JSON request'}}
        if response is not None: print(json.dumps(response),flush=True)
    return 0

if __name__=='__main__': sys.exit(main())
