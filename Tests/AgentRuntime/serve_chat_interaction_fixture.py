"""Loopback-only synthetic service for ChatInteractionTests; never touches the real agent."""
import asyncio,base64,json,time,uuid,pathlib,sys
from aiohttp import web
ids={k:str(uuid.uuid4()) for k in ['workspace_id','assistant_id','instance_id']}
base='http://127.0.0.1:19277'
connection={**ids,'base_url':base,'data_url':base+'/context'}
ROOT=pathlib.Path(__file__).resolve().parents[2]
root=pathlib.Path('/tmp/momo-chat-interaction-fixture');root.mkdir(exist_ok=True)
(root/'phone-pairing.json').write_text(json.dumps(dict(runID='5F12C378-A804-4E20-A46D-213FE37495AB',connection=json.dumps(connection),credential='synthetic-local-only-fixture-credential')))
image=base64.b64encode((ROOT/'Tests/AgentRuntime/fixtures/chat-desktop.jpg').read_bytes()).decode()
memories = [
 dict(id='memory-layout-1',text='10/29–30 录音 0fcdf941-b14c-4087-ad0e-a3eab9495fe2 v78 (归属/执行未核)：讨论转录中的说话人分段。同一个人的连续发言应合并，换人时另起一行，保留自然的停顿。后续还需要用真实录音核对识别效果。',kind='memory',basis='hermes',status='current',revision=1,evidence=[]),
 dict(id='memory-layout-2',text='偏好简洁的界面，先看到内容和能做的操作。说明应放在需要它的地方。',kind='user',basis='hermes',status='current',revision=1,evidence=[]),
 dict(id='memory-layout-3',text='准备下周的产品评审：先验证主要流程，再整理反馈。原来的讨论有更新，需要核对后再执行。',kind='memory',basis='inferred',status='stale',revision=1,evidence=[dict(source_id='synthetic-source',source_revision='1',quote='先把主要流程测试一遍，再收集问题。',recorded_at=1793318400)]),
 dict(id='memory-layout-4',text='一段需要完整阅读的长记忆。'+'具体内容保留原始措辞，不把推断当作事实。'*80+'全文末尾保留标记。',kind='memory',basis='hermes',status='current',revision=1,evidence=[])
] if '--memory' in sys.argv else []
operations={};attempts=0;inputs=[];owner='agent';session=None;epoch=0
async def serve(r):
 global attempts,owner,session,epoch
 p=r.path;b=await r.json() if r.can_read_body else {}
 if p=='/test/status':return web.json_response(dict(submission_attempts=attempts,unique_operations=len(operations),input_count=len(inputs),owner=owner))
 if r.headers.get('Authorization')!='Bearer synthetic-local-only-fixture-credential':return web.json_response({'error':{'code':'auth','message':'fixture credential required'}},status=401)
 if p=='/transport/v1/config':return web.json_response(dict(enabled=False))
 if p=='/v1/capabilities':return web.json_response(dict(features=dict(run_submission=True,runs_idempotency=dict(supported=True,durable=True,retention_seconds=86400))))
 if p=='/context/v1/status':return web.json_response(dict(workspace_id=ids['workspace_id'],source_sync=True,memory_writer='Hermes',memory_pending=0,memory_needs_review=0))
 if p=='/context/v1/memories':return web.json_response(dict(revision=1,items=memories,next_cursor=None))
 if p=='/context/v1/sources':return web.json_response(dict(items=[],next_cursor=None))
 if p=='/v1/runs' and r.method=='POST':
  attempts+=1
  if attempts==1:return web.json_response({'error':{'code':'offline','message':'暂时无法发送，请重试。'}},status=503)
  op=r.headers['Idempotency-Key']
  if op not in operations:operations[op]=dict(session_id=b['session_id'],created=time.monotonic())
  return web.json_response(dict(run_id='fixture-run',status='started',session_id=b['session_id']))
 if p=='/v1/runs/fixture-run':
  x=next(iter(operations.values()));done=time.monotonic()-x['created']>3
  return web.json_response(dict(run_id='fixture-run',session_id=x['session_id'],status='completed' if done else 'running',output='处理好了。' if done else None))
 if p=='/v1/runs/fixture-run/events':
  response=web.StreamResponse(headers={'Content-Type':'text/event-stream'});await response.prepare(r)
  events=[dict(event='message.interim',text='消息已收到。'),dict(event='tool.started',tool='fixture'),dict(event='tool.completed',tool='fixture'),dict(event='run.completed')]
  after=int(r.headers.get('Last-Event-ID','-1'))
  for seq,x in enumerate(events):
   if seq>after:
    await asyncio.sleep(.15);await response.write(('data:'+json.dumps(dict(**x,run_id='fixture-run',seq=seq),ensure_ascii=False)+'\n\n').encode())
  await response.write_eof();return response
 if p.startswith('/desktop/v1/'):
  if p.endswith('/frame'):return web.json_response(dict(jpeg=image,width=1120,height=760))
  if p.endswith('/claim'):owner='you';session=str(uuid.uuid4());epoch+=1
  if p.endswith('/release'):assert b['session']==session;owner='agent';session=None;epoch+=1
  if p.endswith('/input'):
   assert owner=='you' and b['session']==session;inputs.append(b);return web.json_response({'ok':True})
  return web.json_response(dict(approved=True,screen=True,input=True,owner=owner,session=session,active=owner=='you',epoch=epoch))
 return web.json_response({'error':{'code':'fixture_missing','message':p}},status=404)
app=web.Application();app.router.add_route('*','/{tail:.*}',serve);web.run_app(app,host='127.0.0.1',port=19277,print=None)
