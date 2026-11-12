"""Opt-in real-model acceptance in an isolated MoMo profile, using synthetic evidence only.

Uses the existing subscription without printing credentials. Never writes test facts to the
user profile. Run with the prepared Python and --live-data pointing to that profile's owner.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import time
import urllib.request
import uuid

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT/'Apps/MacApp/Runtime'),str(ROOT/'Apps/MacApp/Context'),str(ROOT/'Vendor/HermesAgent')]
import momo_agent
from context_store import ContextStore,digest
from context_server import ContextService
import memory_review


def main(args):
    args.output=args.output.resolve();args.live_data=args.live_data.resolve()
    data=args.output/'isolated-agent';args.output.mkdir(parents=True,exist_ok=True)
    for port in range(28465,28565,4):
        held=[]
        try:
            for n in range(4):
                s=socket.socket();s.bind(('127.0.0.1',port+n));held.append(s)
            break
        except OSError:
            continue
        finally:
            for s in held:s.close()
    connection=momo_agent.initialize(data,port)
    (data/'runtime/venv').symlink_to(args.live_data/'runtime/venv',target_is_directory=True)
    momo_agent.write_private(data/'runtime/prepared.json',json.dumps(momo_agent.fingerprint()))
    profile = momo_agent.profile_directory(data)
    live_profile = momo_agent.profile_directory(args.live_data)
    config=json.loads((profile/'config.yaml').read_text())
    live=json.loads((live_profile/'config.yaml').read_text())
    config['model']=live['model'];config['auxiliary']={'background_review':{'enabled':False}}
    (profile/'config.yaml').write_text(json.dumps(config))
    auth=profile/'auth.json';shutil.copy2(live_profile/'auth.json',auth);auth.chmod(0o600)
    env=momo_agent.child_environment(data)
    env.update(API_SERVER_ENABLED='true',API_SERVER_HOST='127.0.0.1',API_SERVER_PORT=str(port),
               API_SERVER_KEY=(data/'api-key').read_text().strip())
    # This test drives the production admission/reconciliation explicitly. The isolated
    # gateway's ordinary timer must not race the test driver or run another paid batch.
    code="import sys;from pathlib import Path;sys.path[:0]="+repr([str(ROOT/'Apps/MacApp/Context'),str(ROOT/'Apps/MacApp/Runtime')])+";import transcript_ingestion;transcript_ingestion.INTERVAL=3600;import momo_agent;momo_agent.gateway(Path(sys.argv[1]))"
    log=(args.output/'gateway.log').open('w')
    child=subprocess.Popen([sys.executable,'-c',code,str(data)],env=env,stdout=log,stderr=subprocess.STDOUT)
    service=ContextService.__new__(ContextService);service.data=data;service.connection=connection;service.key=env['API_SERVER_KEY']
    store=ContextStore(data/'context');checks=[]
    def settle(table,identity,advance):
        deadline=time.monotonic()+180
        while time.monotonic()<deadline:
            row=store.db.execute(f'SELECT * FROM {table} WHERE id=?',(identity,)).fetchone()
            if row['state']=='done':return row
            if row['state']=='needs_review':raise AssertionError(row['error'])
            if row['state']=='retrying':
                identity=str(uuid.uuid5(uuid.NAMESPACE_URL,identity+':retry'))
                continue
            advance(store,row);time.sleep(.3)
        raise TimeoutError('real model review timed out')
    def check(name,condition):
        assert condition,name
        checks.append(name);print('PASS:',name,flush=True)
    try:
        for _ in range(100):
            if child.poll() is not None:raise RuntimeError('Isolated gateway exited; inspect local log')
            try:
                service.request('/v1/capabilities');break
            except OSError:time.sleep(.3)
        else:raise TimeoutError('gateway startup')
        now=time.time()
        batch={'messages':[{'seq':1,'role':'user','at':now,'text':'请记住，我叫小岚，长期喜欢先看结论再看说明；我正在持续开发个人助手“溪流”，重点是生活录音检索。'}],'cursor':[2,0],'remaining':False}
        job=memory_review.enqueue(store,'chat',batch)
        done=settle('memory_reviews',job['id'],service.advance_review)
        check('chat review performs a real native memory write',json.loads(done['result'])['native_writes']>0)
        text='团队在讨论溪流项目：第一版确定先做好生活录音检索，演示安排暂定月底；录音没有标注具体发言人。有人说这两天失眠，不能确认是谁。'
        source=dict(library_id=str(uuid.uuid4()),session_id=str(uuid.uuid4()),device_id=str(uuid.uuid4()),generation=0,version=1,deleted=False,recorded_at=now,spans=[dict(id=str(uuid.uuid4()),text=text,recorded_at=now)],text_sha256=digest(text))
        receipt=store.sync_source(source)
        job=store.db.execute("SELECT * FROM jobs WHERE state='pending'").fetchone()
        done=settle('jobs',job['id'],service.advance_job)
        check('unknown-speaker project context can be retained',json.loads(done['result'])['native_writes']>0)
        job=memory_review.enqueue(store,'dream',{'signature':memory_review.signature(profile, memory_review.state(store, 'chat_cursor', [0, 0]), store.revision),'source_revision':store.revision,'chat_cursor':[2,0]})
        done=settle('memory_reviews',job['id'],service.advance_review)
        check('Dream produces a verified receipt',json.loads(done['result'])['outcome'] in {'updated','no_change'})
        recall=service.request('/v1/runs',{'session_id':'memory-acceptance-'+str(uuid.uuid4()),'input':'只按已有记忆回答：我叫什么、喜欢什么回答方式、溪流项目先做什么？不要调用工具。'},str(uuid.uuid4()))
        for _ in range(600):
            snapshot=service.request('/v1/runs/'+recall['run_id'])
            if snapshot['status']=='completed':break
            if snapshot['status'] in {'failed','cancelled'}:raise AssertionError('recall failed')
            time.sleep(.3)
        output=snapshot.get('output','')
        assert snapshot['status']=='completed','Recall did not complete before the deadline'
        check('new native session recalls saved personal context',all(s in output for s in ['小岚','结论','录音']))
        files='\n'.join(p.read_text() for p in (profile/'memories').glob('*.md'))
        check('third party sleep comment is not written as user health',not any(s in files for s in ['小岚失眠','用户失眠','用户患']))
        (args.output/'result.json').write_text(json.dumps({'passed':True,'model':config['model']['default'],'synthetic_evidence':True,'checks':checks,'recall':output,'memories':files},ensure_ascii=False,indent=2))
    finally:
        store.close();child.terminate()
        try:child.wait(timeout=20)
        except subprocess.TimeoutExpired:child.kill();child.wait()
        log.close();auth.unlink(missing_ok=True)
        # Delete only the disposable credential copies and localhost test credential.
        (data/'api-key').unlink(missing_ok=True)


if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--live-data',type=Path,required=True);p.add_argument('--output',type=Path,required=True)
    main(p.parse_args())
