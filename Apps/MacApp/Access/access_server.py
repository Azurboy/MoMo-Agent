"""Owned remote boundary: local control, explicit device grants, SSE passthrough."""
import argparse
import base64
import asyncio
import hmac
import json
from pathlib import Path
import re
import sys
import time

from aiohttp import ClientError, ClientSession, ClientTimeout, web
# Isolated Python omits the script directory; import siblings from this signed bundle.
if sys.flags.isolated:
    sys.path.insert(0, str(Path(__file__).resolve().parent))
from pairing_store import PairingStore, is_tailnet_endpoint
from tunnel import TunnelLifecycle, EmbeddedTailscale
from relay_access import RelayTunnel
from rtc_transport import RTCTransport, permitted_route
from desktop_control import DesktopBridge, DesktopFrameFeed


class AccessService:
    def __init__(self, data):
        self.data = Path(data)
        self.connection = json.loads((self.data / 'connection.json').read_text())
        self.key = (self.data / 'api-key').read_text().strip()
        self.port = self.connection['port'] + 2
        if self.port + 1 > 65535: raise ValueError('Runtime port must leave three additional local ports')
        self.store = PairingStore(self.data / 'access')
        self.tunnel = TunnelLifecycle(self.data / 'access', self.port)
        self.store.invalidate_invitations()
        self.invitation = None
        self.paired_device_id = None
        self.session = None
        self.rtc = RTCTransport(self)
        self.desktop = DesktopBridge(self)

    @property
    def provider(self): return self.tunnel.provider

    async def probe(self, url):
        try:
            async with self.session.get(url + '/pair/identity', allow_redirects=False, timeout=ClientTimeout(total=3)) as r:
                identity = await r.json()
                return r.status == 200 and identity.get('instance_id') == self.connection['instance_id']
        except (OSError, ClientError, ValueError, asyncio.TimeoutError): return False

    async def maintain_tunnel(self):
        while True:
            await self.tunnel.tick(self.probe)
            await self.rtc.prune()
            await asyncio.sleep(5)

    def public_connection(self, url):
        return {**{k: self.connection[k] for k in ('workspace_id', 'assistant_id', 'instance_id')},
                'base_url': url, 'data_url': url + '/context', 'event_transport': 'sse',
                **({'network': 'tailscale'} if isinstance(self.provider, EmbeddedTailscale) and is_tailnet_endpoint(url) else
                   {'network': 'relay', 'relay_code': self.provider.code} if isinstance(self.provider, RelayTunnel) and url == self.provider.url else {})}

    async def upstream(self, method, path, body=None, context=False, headers=None, streaming=False):
        url = self.connection['data_url' if context else 'base_url'] + path
        h = {'Authorization': 'Bearer ' + self.key, 'Content-Type': 'application/json',
             'X-Hermes-Session-Key': 'momo:' + self.connection['assistant_id']}
        h.update(headers or {})
        timeout = ClientTimeout(total=None, sock_connect=10, sock_read=45) if streaming else ClientTimeout(total=60, sock_connect=10)
        return await self.session.request(method, url, data=body, headers=h, allow_redirects=False, timeout=timeout)

    async def status(self):
        online = False
        try:
            async with await self.upstream('GET', '/v1/capabilities') as r: online = r.status == 200
        except (OSError, ClientError, asyncio.TimeoutError): pass
        url = self.provider.state['endpoint']
        if self.invitation and (self.invitation['expires'] <= time.time() or
                self.invitation['endpoint'] != url and not self.invitation['endpoint'].startswith('http://127.0.0.1:')):
            self.store.invalidate_invitations(); self.invitation = None
        return {'agent_online': online, 'tunnel': self.provider.state, 'devices': self.store.devices(),
                'invitation': self.invitation, 'paired_device_id': self.paired_device_id,
                'connection': self.public_connection(f'http://127.0.0.1:{self.port}'), 'webrtc': self.rtc.status()}

    def token(self, request):
        auth = request.headers.get('Authorization', '')
        return auth[7:] if auth.startswith('Bearer ') else ''

    async def public(self, request):
        path = request.path
        if path == '/pair/identity' and request.method == 'GET':
            return web.json_response({'application': 'MoMoAgent', 'instance_id': self.connection['instance_id']})
        if not self.tunnel.enabled: raise web.HTTPServiceUnavailable(reason='Remote access is disabled')
        if path == '/pair/requests' and request.method == 'POST':
            if request.content_length is None or request.content_length > 16384: raise web.HTTPRequestEntityTooLarge(max_size=16384, actual_size=request.content_length or 0)
            body = await request.json()
            return web.json_response(self.store.request(body['invitation_id'], body['name'], self.token(request)))
        if re.fullmatch(r'/pair/requests/[a-f0-9-]{36}', path) and request.method == 'GET':
            result = self.store.claim(path.rsplit('/', 1)[1], self.token(request))
            if result['state'] == 'approved':
                # Public endpoint comes from the local invitation, never an untrusted Host header.
                row = self.store.db.execute('SELECT endpoint FROM devices WHERE id=?', (result['id'],)).fetchone()
                result['connection'] = self.public_connection(row['endpoint'])
            return web.json_response(result)
        if not self.store.authorized(self.token(request)): raise web.HTTPUnauthorized()
        if path == '/transport/v1/config' and request.method == 'GET':
            return web.json_response(self.rtc.configuration())
        if path == '/transport/v1/offer' and request.method == 'POST':
            if request.content_length is None or request.content_length > 147456:
                raise web.HTTPRequestEntityTooLarge(max_size=147456, actual_size=request.content_length or 0)
            return web.json_response(await self.rtc.offer(self.token(request), await request.json()))
        if path == '/desktop/v2/offer' and request.method == 'POST' and not request.query_string:
            if request.content_length is None or request.content_length > 147456:
                raise web.HTTPRequestEntityTooLarge(max_size=147456, actual_size=request.content_length or 0)
            code, result = await self.desktop.handle('POST', path, await request.read(), self.token(request))
            return web.json_response(result, status=code)
        if path.startswith('/desktop/v1/'):
            if permitted_route(request.method, path) is None or request.query_string: raise web.HTTPNotFound()
            if path == '/desktop/v1/frames': return await self.desktop_frames(request)
            if request.method == 'POST' and (request.content_length is None or request.content_length > 16_384):
                raise web.HTTPRequestEntityTooLarge(max_size=16_384, actual_size=request.content_length)
            code, result = await self.desktop.handle(request.method, path, await request.read(), self.token(request))
            return web.json_response(result, status=code, headers={'Cache-Control': 'no-store'})
        route = permitted_route(request.method, path + ('?' + request.query_string if request.query_string else ''))
        if route is None: raise web.HTTPNotFound()
        target, context, streaming = route
        if streaming or (request.method == 'POST' and target == '/momo/v1/conversation/messages'
                         and request.headers.get('Accept') == 'text/event-stream'):
            return await self.stream(request, target)
        headers = {'X-MoMo-Device': self.store.device_id(self.token(request)) or 'revoked'}
        if 'Idempotency-Key' in request.headers: headers['Idempotency-Key'] = request.headers['Idempotency-Key']
        body = await request.read() if request.method == 'POST' else None
        async with await self.upstream(request.method, target, body, context, headers) as response:
            data = await response.read()
            return web.Response(status=response.status, body=data, content_type=response.content_type,
                headers={'Cache-Control': response.headers.get('Cache-Control', 'no-store'),
                         **({'Retry-After':response.headers['Retry-After']} if 'Retry-After' in response.headers else {})})

    async def desktop_frames(self, request):
        feed = DesktopFrameFeed(self.desktop, self.token(request))
        code, packet = await feed.next()
        if code != 200: return web.json_response(packet, status=code)
        response = web.StreamResponse(headers={'Content-Type': feed.content_type, 'Cache-Control': 'no-store', 'X-Accel-Buffering': 'no'})
        await response.prepare(request)
        for previous in list(self.desktop.feeds.values()):
            if hmac.compare_digest(previous.token, feed.token):
                previous.closed = True; previous.available.set()
        self.desktop.feeds[feed.id] = feed
        # Keep the socket backlog small; never let video occupy the control pool.
        if request.transport: request.transport.set_write_buffer_limits(high=16 * 1024, low=4 * 1024)
        try:
            while self.tunnel.enabled and not feed.closed and self.store.authorized(self.token(request)):
                start = asyncio.get_running_loop().time()
                await asyncio.wait_for(response.write(packet), 3)
                await asyncio.sleep(max(0, 0.1 - (asyncio.get_running_loop().time() - start)))
                code, packet = await feed.next()
                if code != 200: break
        except (OSError, ClientError, asyncio.TimeoutError): pass
        finally: self.desktop.feeds.pop(feed.id, None)
        return response

    async def stream(self, request, path):
        headers = {'Accept': 'text/event-stream', 'X-MoMo-Device': self.store.device_id(self.token(request)) or 'revoked'}
        if 'Last-Event-ID' in request.headers: headers['Last-Event-ID'] = request.headers['Last-Event-ID']
        body = await request.read() if request.method == 'POST' else None
        async with await self.upstream(request.method, path, body=body, headers=headers, streaming=True) as upstream:
            if upstream.status != 200:
                return web.Response(status=upstream.status, body=await upstream.read(), content_type='application/json',
                    headers={'Retry-After':upstream.headers['Retry-After']} if 'Retry-After' in upstream.headers else None)
            response = web.StreamResponse(headers={'Content-Type':'text/event-stream', 'Cache-Control':'no-store', 'X-Accel-Buffering':'no'})
            await response.prepare(request)
            try:
                async for chunk in upstream.content.iter_any():
                    if not self.tunnel.enabled or not self.store.authorized(self.token(request)): break
                    await response.write(chunk)
            except (OSError, ClientError, asyncio.TimeoutError): pass
            return response

    async def control(self, request):
        if not hmac.compare_digest(self.token(request).encode(), self.key.encode()): raise web.HTTPUnauthorized()
        path = request.path
        if request.method == 'GET' and path == '/status': return web.json_response(await self.status())
        raw = await request.read() if request.can_read_body else b''
        limit = 49152 if path == '/desktop/rtc' else 16384
        if len(raw) > limit: raise web.HTTPRequestEntityTooLarge(max_size=limit, actual_size=len(raw))
        body = json.loads(raw) if raw else {}
        if path == '/desktop/rtc' and request.method == 'POST':
            if len(json.dumps(body).encode()) > 49152: raise ValueError('Desktop command too large')
            payload = base64.b64decode(body['body'], validate=True)
            if len(payload) > 16384: raise ValueError('Desktop command too large')
            code, result = await self.desktop.control_device(body['viewer'], body['operation'], payload)
            return web.json_response(result, status=code)
        if path == '/tunnel/start':
            await self.tunnel.start()
        elif path == '/tunnel/configure':
            await self.tunnel.configure(body.get('provider', 'embedded'), body.get('endpoint'), body.get('registration_key', ''))
            self.store.invalidate_invitations()
            self.invitation = None; self.paired_device_id = None
        elif path == '/tunnel/stop':
            await self.tunnel.stop()
            await self.rtc.close()
            self.invitation = None
            self.store.invalidate_invitations()
        elif path == '/tunnel/embedded':
            if not isinstance(self.provider, EmbeddedTailscale) or not self.tunnel.enabled: raise ValueError('Embedded access is not enabled')
            self.provider.report(body, self.tunnel.now())
        elif path == '/pair/invite':
            url = self.provider.state['endpoint'] if self.provider.state['state'] == 'connected' else None
            if body.get('loopback') is True:
                url = f'http://127.0.0.1:{self.port}'
                self.tunnel.enabled = True  # Explicit local POC; never persists a public connector choice.
            if not url: raise ValueError('异地入口尚未连通，请稍后再试')
            self.invitation = self.store.invite(url, network=self.public_connection(url).get('network'))
            self.paired_device_id = None
            self.invitation['payload'] = json.dumps({'version': 1, 'application': 'MoMoAgent', 'invitation_id': self.invitation['id'], 'endpoint': url, 'instance_id': self.connection['instance_id'], 'expires': self.invitation['expires']}, separators=(',', ':'))
            if 'network' in self.public_connection(url):
                payload = json.loads(self.invitation['payload']); payload.update({key: value for key, value in self.public_connection(url).items() if key in ('network', 'relay_code')})
                self.invitation['payload'] = json.dumps(payload, separators=(',', ':'))
        elif path == '/pair/decide':
            self.store.decide(body['id'], body['allow'] is True)
            if body['allow'] is True:
                self.invitation = None; self.paired_device_id = body['id']
        elif path == '/devices/revoke':
            self.store.revoke(body['id']); await self.rtc.prune()
        elif path == '/webrtc/configure': await self.rtc.configure(body)
        else: raise web.HTTPNotFound()
        return web.json_response(await self.status())


@web.middleware
async def errors(request, handler):
    try:
        response = await handler(request)
    except web.HTTPException as e:
        response = web.json_response({'error': {'code': 'access_denied', 'message': e.reason}}, status=e.status)
    except (ValueError, KeyError, TypeError):
        response = web.json_response({'error': {'code': 'invalid_request', 'message': '请求无效或配对已过期，请刷新后重试。'}}, status=400)
    except PermissionError:
        response = web.json_response({'error': {'code': 'unauthorized', 'message': '配对凭据不匹配'}}, status=401)
    except (OSError, ClientError, asyncio.TimeoutError):
        response = web.json_response({'error': {'code': 'unavailable', 'message': 'Mac Agent 暂时不可用，请检查运行状态。'}}, status=503)
    response.headers.setdefault('Cache-Control', 'no-store')
    return response


def control_application(service):
    local = web.Application(middlewares=[errors], client_max_size=49152)
    local.router.add_get('/status', service.control)
    for path in ['/tunnel/start', '/tunnel/stop', '/tunnel/configure', '/tunnel/embedded', '/pair/invite', '/pair/decide', '/devices/revoke', '/webrtc/configure', '/desktop/rtc']:
        local.router.add_post(path, service.control)
    return local


async def serve(data):
    service = AccessService(data)
    # A lock prevents a second desktop window/process from taking over the same runtime.
    import fcntl
    lock = open(service.data / 'access/service.lock', 'w')
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    async with ClientSession(timeout=ClientTimeout(total=60, sock_connect=10), trust_env=False) as session:
        service.session = session
        public = web.Application(middlewares=[errors], client_max_size=8_000_000)
        public.router.add_route('*', '/{tail:.*}', service.public)
        local = control_application(service)
        runners = []; maintenance = None
        try:
            for app, port in [(public, service.port), (local, service.port + 1)]:
                runner = web.AppRunner(app, access_log=None); await runner.setup(); runners.append(runner)
                await web.TCPSite(runner, '127.0.0.1', port).start()
            maintenance = asyncio.create_task(service.maintain_tunnel())
            stop = asyncio.Event()
            import signal
            for sig in (signal.SIGTERM, signal.SIGINT): asyncio.get_running_loop().add_signal_handler(sig, stop.set)
            await stop.wait()
        finally:
            if maintenance:
                maintenance.cancel()
                await asyncio.gather(maintenance, return_exceptions=True)
            await service.provider.stop()
            await service.rtc.close()
            for runner in runners: await runner.cleanup()
            service.store.db.close(); lock.close()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(); parser.add_argument('--data-dir', type=Path, required=True)
    asyncio.run(serve(parser.parse_args().data_dir.resolve()))
