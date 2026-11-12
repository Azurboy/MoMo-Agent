"""Synthetic loopback UI acceptance. No model calls, real tasks, OS input or personal data."""
import argparse
import asyncio
import json
from pathlib import Path
import time
import uuid
from aiohttp import web


async def main(directory, port):
    directory.mkdir(parents=True, exist_ok=True)
    (directory/'profile').mkdir(exist_ok=True)
    ids = {k:str(uuid.uuid4()) for k in ('workspace_id','assistant_id','instance_id')}
    if (directory/'connection.json').exists():
        saved=json.loads((directory/'connection.json').read_text());ids={k:saved[k] for k in ids}
    session='momo-main-'+ids['assistant_id']
    base = f'http://127.0.0.1:{port}'
    (directory/'connection.json').write_text(json.dumps({**ids,'base_url':base,'data_url':base+'/context'}))
    (directory/'api-key').write_text('synthetic-ui-only-credential')
    (directory/'profile/config.yaml').write_text(json.dumps(dict(model=dict(default='Synthetic UI fixture', provider='custom'))))
    operation = str(uuid.uuid4()); message_id = 'user-'+operation
    messages=[dict(id=message_id,seq=1,role='user',content='把刚才的方案改为周三交稿。',created_at=time.time(),operation_id=operation,run_id='rejected-run')]
    reported=False; requests=[]
    async def serve(request):
        nonlocal reported
        path=request.path
        if request.headers.get('Authorization')!='Bearer synthetic-ui-only-credential': raise web.HTTPUnauthorized()
        body=await request.json() if request.can_read_body else {}
        requests.append(dict(path=path,method=request.method,body=body))
        (directory/'ui-requests.json').write_text(json.dumps(requests,ensure_ascii=False))
        if path=='/status': return web.json_response(dict(agent_online=True,tunnel=dict(state='connected',mode='external',endpoint='https://fixture.invalid'),devices=[]))
        if path=='/v1/capabilities': return web.json_response(dict(features=dict(run_submission=True,runs_idempotency=dict(supported=True,durable=True,retention_seconds=86400))))
        if path=='/context/v1/status': return web.json_response(dict(workspace_id=ids['workspace_id'],source_sync=True,memory_writer='SuperAgent'))
        if path in ('/context/v1/memories','/context/v1/sources'): return web.json_response(dict(revision=1,items=[],next_cursor=None))
        if path=='/momo/v1/conversation': return web.json_response(dict(conversation_id='fixture',session_id=session,**{k:ids[k] for k in ('assistant_id','instance_id')},capabilities=dict(shared_conversation=True,server_owned_completion=True,durable_steering=True,independent_chat_while_waiting=True,system_push=False)))
        if path.endswith('/messages'):
            after=int(request.query.get('after',0)); rows=[m for m in messages if m['seq']>after]
            return web.json_response(dict(data=rows,next_cursor=rows[-1]['seq'] if rows else after,has_more=False))
        if path.endswith('/runs'): return web.json_response(dict(data=[dict(run_id='waiting-run',session_id=session,status='waiting_for_computer',work_id='work-wait',execution_generation=1,title='整理演示文稿',wait_reason='computer_task',cancellable=False)],
            background_work=[dict(id='process:report',state='completed',report_state='reported' if reported else 'failed',title='汇总今日事项',kind='process',execution_generation=1,cancellable=False,report_retry_available=not reported)],
            message_states={message_id:'not_applied'},next_cursor=1,has_more=False))
        if path.endswith('/report-retry'):
            assert path=='/momo/v1/conversation/work/process:report/report-retry'
            assert set(body)=={'operation_id'}; uuid.UUID(body['operation_id'])
            if not reported:
                reported=True
                messages.append(dict(id='report',seq=2,role='assistant',content='事项汇总已完成。这里是已保存结果的重新汇报。',created_at=time.time()))
            await asyncio.sleep(1)
            return web.json_response(dict(id='process:report',report_state='pending'),status=202)
        if path.endswith(('/read','/push/visible','/adopt')): return web.json_response({})
        if path.endswith('/events'):
            response=web.StreamResponse(headers={'Content-Type':'text/event-stream'});await response.prepare(request)
            try:
                for i in range(60): await response.write(b': heartbeat\n\n');await asyncio.sleep(1)
            except (ConnectionError,asyncio.CancelledError): pass
            return response
        return web.json_response(dict(error=dict(code='fixture_missing',message=path)),status=404)
    app=web.Application();app.router.add_route('*','/{path:.*}',serve)
    runner=web.AppRunner(app);await runner.setup()
    for p in (port,port+3): await web.TCPSite(runner,'127.0.0.1',p).start()
    print('UI fixture ready',flush=True)
    try: await asyncio.Event().wait()
    finally: await runner.cleanup()


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--directory',type=Path,required=True);parser.add_argument('--port',type=int,default=19336)
    args=parser.parse_args();asyncio.run(main(args.directory,args.port))
