"""Loopback-only input acceptance fixture. Never opens the Mac screen or posts OS events."""
import argparse
import base64
import json
from pathlib import Path
import uuid
from aiohttp import web

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument('--connection', type=Path, required=True)
args = parser.parse_args()
credential = 'synthetic-local-only-fixture-credential'
ids = {k: str(uuid.uuid4()) for k in ('workspace_id', 'assistant_id', 'instance_id')}
base = 'http://127.0.0.1:19277'
connection = dict(**ids, base_url=base, data_url=base + '/context')
args.connection.write_text(json.dumps(dict(runID='5F12C378-A804-4E20-A46D-213FE37495AB', connection=json.dumps(connection), credential=credential)))
image = base64.b64encode((ROOT / 'Tests/AgentRuntime/fixtures/chat-desktop.jpg').read_bytes()).decode()
state = dict(owner='agent', session=None, epoch=0, screen=True, input=True, input_sequence=0)
inputs = []
frame_failures = 0
revoked = False

def status():
    return dict(**state, approved=True, active=state['owner'] == 'you')

async def serve(request):
    global frame_failures, revoked
    path = request.path
    body = await request.json() if request.can_read_body else {}
    if path == '/test/status': return web.json_response(dict(**state, events=inputs))
    if path == '/test/permissions':
        state['screen'] = state['input'] = bool(body['enabled'])
        return web.json_response({})
    if path == '/test/frame-failure': frame_failures = 1; return web.json_response({})
    if path == '/test/revoke': revoked = True; return web.json_response({})
    if request.headers.get('Authorization') != 'Bearer ' + credential: raise web.HTTPUnauthorized()
    if revoked: return web.json_response({'error': {'code': 'device_revoked', 'message': '配对已失效'}}, status=403)
    if path == '/transport/v1/config': return web.json_response(dict(enabled=False))
    if path == '/v1/capabilities': return web.json_response(dict(features=dict(run_submission=True, runs_idempotency=dict(supported=True, durable=True, retention_seconds=86400))))
    if path == '/context/v1/status': return web.json_response(dict(**ids, source_sync=True, memory_writer='SuperAgent', memory_pending=0, memory_needs_review=0))
    if path == '/context/v1/memories': return web.json_response(dict(revision=1, items=[], next_cursor=None))
    if path == '/context/v1/sources': return web.json_response(dict(items=[], next_cursor=None))
    if path == '/desktop/v1/request': raise web.HTTPBadRequest(reason='A paired phone must not request another host grant')
    if path == '/desktop/v1/frame':
        if frame_failures:
            frame_failures -= 1
            return web.json_response({'error': {'code': 'capture_unavailable', 'message': '预览暂时不可用'}}, status=503)
        return web.json_response(dict(jpeg=image, width=1120, height=760))
    if path == '/desktop/v1/claim':
        assert state['screen'] and state['input']
        state.update(owner='you', session=str(uuid.uuid4()), epoch=state['epoch'] + 1, input_sequence=0)
    if path == '/desktop/v1/release':
        assert body['session'] == state['session']
        state.update(owner='agent', session=None, epoch=state['epoch'] + 1, input_sequence=0)
    if path == '/desktop/v1/heartbeat': assert body['session'] == state['session']
    if path == '/desktop/v1/input':
        assert state['owner'] == 'you' and body['session'] == state['session']
        event = body['event']
        if event.get('sequence', 0) > state['input_sequence']:
            inputs.append(event); state['input_sequence'] = event['sequence']
        return web.json_response({'ok': True})
    if path.startswith('/desktop/v1/'): return web.json_response(status())
    return web.json_response({'error': {'code': 'fixture_missing', 'message': path}}, status=404)

app = web.Application(); app.router.add_route('*', '/{path:.*}', serve)
web.run_app(app, host='127.0.0.1', port=19277, print=None)
