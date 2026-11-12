"""Run only against an explicitly named synthetic test runtime, until interrupted."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
from remote_fixture import start_model

ROOT=Path(__file__).resolve().parents[2]
p=argparse.ArgumentParser(); p.add_argument('--data-dir',type=Path,required=True); args=p.parse_args()
data=args.data_dir.resolve(); model=start_model(data/'runtime')
config={'model':{'provider':'custom','default':'momo-remote-fixture','streaming':False,'base_url':f'http://127.0.0.1:{model.server_port}/v1','context_length':128000},
        'agent':{'max_turns':20},'updates':{'check':False},'memory':{'memory_enabled':False,'user_profile_enabled':False},'platform_toolsets':{'api_server':['momo_context']}}
(data/'profile/config.yaml').write_text(json.dumps(config,indent=2))
(data/'profile/.env').write_text('OPENAI_API_KEY=synthetic-local-only\n')
log=(data/'runtime/remote-gateway.log').open('w')
child=subprocess.Popen([sys.executable,str(ROOT/'Apps/MacApp/Runtime/momo_agent.py'),'serve','--data-dir',str(data)],stdout=log,stderr=subprocess.STDOUT)
print('Synthetic model and embedded Gateway started. PID '+str(child.pid),flush=True)
try: child.wait()
finally:
    child.terminate()
    try: child.wait(timeout=20)
    except subprocess.TimeoutExpired: child.kill(); child.wait()
    model.shutdown(); model.server_close(); log.close()
