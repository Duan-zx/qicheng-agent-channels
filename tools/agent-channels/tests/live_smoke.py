"""Explicit synthetic integration check; never discovers or modifies other stacks.
Requires both Agent Channels containers. Writes one disposable marker in channel 1.
"""
import base64
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import time
import urllib.error

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('bridge',ROOT/'bridge.py')
bridge=importlib.util.module_from_spec(spec); spec.loader.exec_module(bridge)

def docker(*args, check=True):
    return subprocess.run(['docker','compose','--project-directory',str(ROOT),'-f',str(ROOT/'compose.yaml'),'--profile','second',*args],capture_output=True,text=True,timeout=30,check=check)

def run():
    output=ROOT/'dist'/'evidence'; output.mkdir(parents=True,exist_ok=True)
    channels=[bridge.Bridge(i,ROOT/'.local'/'channel.token') for i in (1,2)]
    report={'tested_at':time.strftime('%Y-%m-%dT%H:%M:%S%z'),'checks':{},'kind':'synthetic real-container integration','host_focus_tested':False,'screen_off_tested':False,'lock_tested':False,'model_task_tested':False}
    windows=[]
    try:
        for client in channels: client.request('/api/control',{'mode':'paused'})
        before=[json.loads(c.request('/api/state')) for c in channels]
        try: channels[0].tool('channel_input',{'action':'key','key':'Return'}); raise AssertionError('Paused input accepted')
        except urllib.error.HTTPError as exc: assert exc.code==409
        report['checks']['paused_rejects_agent']=True
        # Focus a known synthetic xterm inside the private guest; no Windows input API.
        docker('exec','-d','channel1','xterm','-fa','DejaVu Sans Mono','-fs','11','-title','Agent Channels synthetic test')
        for _ in range(20):
            found=docker('exec','-T','channel1','xdotool','search','--name','Agent Channels synthetic test',check=False)
            if found.returncode==0: break
            time.sleep(.1)
        windows=found.stdout.split()
        assert windows, 'Synthetic xterm not found'
        docker('exec','-T','channel1','xdotool','windowmap',windows[0])
        docker('exec','-T','channel1','xdotool','windowactivate','--sync',windows[0])
        channels[0].request('/api/control',{'mode':'agent'})
        channels[0].tool('channel_input',{'action':'type','text':"printf 'channel-one-only' > /tmp/agent-channels-smoke"})
        channels[0].tool('channel_input',{'action':'key','key':'Return'})
        for _ in range(20):
            marker=docker('exec','-T','channel1','cat','/tmp/agent-channels-smoke',check=False)
            if marker.returncode==0: break
            time.sleep(.1)
        assert marker.stdout=='channel-one-only', 'Real xdotool typing not observed'
        report['checks']['real_agent_typing']=True
        assert docker('exec','-T','channel2','test','-e','/tmp/agent-channels-smoke',check=False).returncode==1
        assert json.loads(channels[1].request('/api/state'))['actions']==before[1]['actions']
        report['checks']['channel_two_unchanged']=True
        channels[0].request('/api/control',{'mode':'human'})
        try: channels[0].tool('channel_input',{'action':'key','key':'Return'}); raise AssertionError('Agent input accepted during takeover')
        except urllib.error.HTTPError as exc: assert exc.code==409
        report['checks']['human_takeover_rejects_agent']=True
        requests=[{'jsonrpc':'2.0','id':1,'method':'initialize','params':{'protocolVersion':'2025-06-18','capabilities':{},'clientInfo':{'name':'synthetic-test','version':'1'}}},
                  {'jsonrpc':'2.0','method':'notifications/initialized'},
                  {'jsonrpc':'2.0','id':2,'method':'tools/call','params':{'name':'channel_screenshot','arguments':{}}}]
        proc=subprocess.run([sys.executable,str(ROOT/'bridge.py'),'--channel','1'],input=''.join(json.dumps(r)+'\n' for r in requests),capture_output=True,text=True,encoding='utf-8',timeout=30,check=True)
        messages=[json.loads(line) for line in proc.stdout.splitlines()]
        assert len(messages)==2 and messages[0]['id']==1 and messages[1]['id']==2
        png=base64.b64decode(messages[1]['result']['content'][0]['data']); assert png.startswith(b'\x89PNG\r\n\x1a\n')
        (output/'channel1.png').write_bytes(png)
        (output/'channel2.png').write_bytes(channels[1].request('/api/screenshot'))
        report['checks']['stdio_mcp_real_screenshot']=True
        ids=docker('ps','-q').stdout.split()
        details=json.loads(subprocess.run(['docker','inspect',*ids],capture_output=True,text=True,timeout=15,check=True).stdout)
        assert len(details)==2
        for item in details:
            assert item['HostConfig']['ReadonlyRootfs'] and item['Config']['User']=='channel'
            assert 'ALL' in item['HostConfig']['CapDrop']
            for bindings in item['HostConfig']['PortBindings'].values():
                assert all(b['HostIp']=='127.0.0.1' for b in bindings)
        report['checks']['nonroot_readonly_loopback_capdrop']=True
        report['passed']=True
    except Exception as exc:
        report['passed']=False; report['error_type']=type(exc).__name__; report['error']=str(exc)
        raise
    finally:
        if windows:
            try: docker('exec','-T','channel1','xdotool','windowkill',windows[0],check=False)
            except Exception: pass
        for client in channels:
            try: client.request('/api/control',{'mode':'paused'})
            except Exception: pass
        (output/'live-smoke.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
    print(json.dumps(report,indent=2))

if __name__=='__main__': run()
