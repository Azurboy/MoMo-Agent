"""Authenticated WebRTC byte transport. Agent execution remains behind AccessService."""
import asyncio
import base64
import importlib.util
import json
import os
import re
import time
import uuid
from urllib.parse import parse_qs, urlsplit

from aiohttp import ClientError, web

PROTOCOL = 'momo-rpc-v1'
MAX_FRAME = 32_768
CHUNK_BYTES = 12_000
MAX_RESPONSE = 8 * 1024 * 1024


def rtc_backend():
    # Loading native crypto/codec libraries may be slow on first launch; keep HTTPS responsive.
    from aiortc import RTCConfiguration, RTCIceServer, RTCPeerConnection, RTCSessionDescription
    return RTCConfiguration, RTCIceServer, RTCPeerConnection, RTCSessionDescription


def permitted_route(method, path):
    """One allowlist for HTTPS and data channels; never an arbitrary proxy target."""
    if not isinstance(path, str) or len(path) > 8192 or any(ord(c) < 32 for c in path):
        return None
    parts = urlsplit(path)
    if parts.scheme or parts.netloc or parts.fragment or not parts.path.startswith('/'):
        return None
    context = parts.path.startswith('/context/')
    if method == 'GET' and parts.path == '/desktop/v1/frames' and not parts.query:
        return parts.path, False, True
    if not parts.query and ((method == 'GET' and parts.path in ('/desktop/v1/status', '/desktop/v1/frame')) or
            (method == 'POST' and parts.path in ('/desktop/v1/request', '/desktop/v1/claim', '/desktop/v1/release', '/desktop/v1/heartbeat', '/desktop/v1/input', '/desktop/v1/frame-ack'))):
        return parts.path, False, False
    target = parts.path[len('/context'):] if context else parts.path
    if context and target.startswith('/v1/life-illustrations/'):
        suffix = target.removeprefix('/v1/life-illustrations/')
        query = parse_qs(parts.query, keep_blank_values=True)
        valid = (method == 'GET' and suffix == 'settings' and not parts.query or
                 method == 'POST' and suffix in ('settings', 'delete') and not parts.query or
                 method == 'GET' and re.fullmatch(r'assets/[a-f0-9]{64}', suffix) and not parts.query or
                 method == 'GET' and suffix == 'manifest' and set(query) <= {'cursor', 'limit'}
                 and all(len(value) == 1 and value[0].isdigit() for value in query.values()))
        return (target + ('?' + parts.query if parts.query else ''), True, False) if valid else None
    # The native session transcript carries detached delegation delivery notices.
    if (not context and method == 'GET' and
            re.fullmatch(r'/api/sessions/[A-Za-z0-9_-]+/messages', target)):
        query = parse_qs(parts.query, keep_blank_values=True)
        if (set(query) <= {'limit', 'offset', 'order', 'include_compacted'} and
                all(len(values) == 1 for values in query.values()) and
                query.get('order', ['latest'])[0] in ('oldest', 'latest') and
                query.get('include_compacted', ['true']) == ['true'] and
                query.get('limit', ['100'])[0].isdigit() and
                1 <= int(query.get('limit', ['100'])[0]) <= 100 and
                query.get('offset', ['0'])[0].isdigit()):
            return path, False, False
        return None
    if not context and parts.path in ('/momo/v1/proactive', '/momo/v1/proactive/ingest') and not parts.query:
        if method in ('GET', 'POST') and (method == 'POST' or parts.path == '/momo/v1/proactive'):
            return parts.path, False, False
        return None
    if not context and target.startswith('/momo/v1/conversation'):
        suffix = target[len('/momo/v1/conversation'):]
        if method == 'POST' and re.fullmatch(r'/work/[A-Za-z0-9_%:-]+/(cancel|report-retry)', suffix) and '..' not in suffix and not parts.query: return path, False, False
        if method == 'GET' and re.fullmatch(r'/work/[A-Za-z0-9_%:-]+', suffix) and '..' not in suffix and not parts.query: return path, False, False
        query = parse_qs(parts.query, keep_blank_values=True)
        if method == 'GET' and suffix in ('','/push','/snapshot') and not parts.query: return path, False, False
        if method == 'GET' and suffix == '/works' and set(query) <= {'limit'} and all(len(v) == 1 and v[0].isdigit() for v in query.values()): return path, False, False
        if method == 'GET' and suffix == '/subscribe' and set(query) == {'after'} and len(query['after']) == 1 and query['after'][0].isdigit(): return path, False, True
        if method == 'GET' and suffix == '/runs' and set(query) <= {'after','limit'} and all(len(v) == 1 and v[0].isdigit() for v in query.values()): return path, False, False
        if method == 'GET' and suffix in ('/messages', '/events'):
            if set(query) <= {'after', 'before', 'limit'} and not {'after','before'} <= set(query) and all(len(v) == 1 and v[0].isdigit() for v in query.values()):
                return path, False, False
        if method == 'POST' and suffix in ('/messages', '/read', '/adopt', '/push', '/push/revoke', '/push/visible') and not parts.query: return path, False, False
        return None
    stream = method == 'GET' and re.fullmatch(r'/v1/runs/[A-Za-z0-9_-]+/events', target) is not None and not context
    allowed = (method == 'GET' and re.fullmatch(r'/v1/(capabilities|runs/[A-Za-z0-9_-]+)', target) is not None or
               method == 'POST' and re.fullmatch(r'/v1/runs(?:/[A-Za-z0-9_-]+/(?:stop|approval|clarify|resolve-unknown))?', target) is not None) if not context else (
               method == 'GET' and target in ('/v1/status', '/v1/sources', '/v1/source', '/v1/memories', '/v1/health', '/v1/phone-sources', '/v1/summaries') or
               method == 'POST' and target in ('/v1/sources', '/v1/memories/forget', '/v1/health', '/v1/phone-sources', '/v1/summaries'))
    if not (allowed or stream): return None
    return target + ('?' + parts.query if parts.query else ''), context, stream


def validate_ice(value):
    if not isinstance(value, list) or len(value) > 8: raise ValueError('Invalid ICE configuration')
    result = []
    for server in value:
        if not isinstance(server, dict) or set(server) - {'urls', 'username', 'credential'}:
            raise ValueError('Invalid ICE server')
        urls = server.get('urls')
        if isinstance(urls, str): urls = [urls]
        if not isinstance(urls, list) or not 1 <= len(urls) <= 8: raise ValueError('Invalid ICE URLs')
        for url in urls:
            if not isinstance(url, str) or len(url) > 1024 or not re.fullmatch(r'(?:stun|stuns|turn|turns):[^\s/@#]+', url):
                raise ValueError('Use standard STUN/TURN URLs')
        normalized = {'urls': urls}
        for key in ('username', 'credential'):
            if key in server:
                if not isinstance(server[key], str) or len(server[key]) > 4096 or any(ord(c) < 32 for c in server[key]):
                    raise ValueError('Invalid ICE credential')
                normalized[key] = server[key]
        result.append(normalized)
    return result


class RTCTransport:
    def __init__(self, service):
        self.service = service
        self.file = service.data / 'access/webrtc.json'
        saved = json.loads(self.file.read_text()) if self.file.exists() else {}
        self.enabled = saved.get('enabled', True) is True
        self.ice_servers = validate_ice(saved.get('ice_servers', []))
        self.policy = saved.get('ice_transport_policy', 'all')
        if self.policy not in ('all', 'relay'): raise ValueError('Invalid ICE policy')
        self.peers = {}
        self.available = importlib.util.find_spec('aiortc') is not None

    def configuration(self):
        return dict(protocol=PROTOCOL, available=self.enabled and self.available,
                    identity={key: self.service.connection[key] for key in ('workspace_id', 'assistant_id', 'instance_id')},
                    ice_servers=self.ice_servers, ice_transport_policy=self.policy, max_request_bytes=MAX_FRAME)

    async def configure(self, value):
        if not isinstance(value, dict) or type(value.get('enabled', True)) is not bool: raise ValueError('Invalid WebRTC configuration')
        servers = validate_ice(value.get('ice_servers', []))
        policy = value.get('ice_transport_policy', 'all')
        if policy not in ('all', 'relay'): raise ValueError('Invalid ICE policy')
        temporary = self.file.with_suffix('.new')
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, 'w') as file:
            json.dump(dict(enabled=value.get('enabled', True), ice_servers=servers, ice_transport_policy=policy), file)
            file.flush(); os.fsync(file.fileno())
        temporary.replace(self.file)
        self.enabled = value.get('enabled', True); self.ice_servers = servers; self.policy = policy
        await self.close()

    async def offer(self, token, value):
        if not self.enabled or not self.available: raise web.HTTPServiceUnavailable()
        if not isinstance(value, dict) or value.get('protocol') != PROTOCOL or value.get('type') != 'offer':
            raise ValueError('Unsupported WebRTC offer')
        nonce = value.get('nonce'); sdp = value.get('sdp')
        if not isinstance(nonce, str) or not 16 <= len(nonce) <= 128 or not isinstance(sdp, str) or len(sdp.encode()) > 131072:
            raise ValueError('Invalid WebRTC offer')
        identity = self.configuration()['identity']
        supplied = value.get('identity')
        if not isinstance(supplied, dict) or set(supplied) != set(identity) or not all(isinstance(v, str) for v in supplied.values()) or any(
                uuid.UUID(supplied[key]) != uuid.UUID(expected) for key, expected in identity.items()):
            raise PermissionError('Workspace identity differs')
        # Data-only peer. Media capture and arbitrary application targets are not granted here.
        media = [line for line in sdp.splitlines() if line.startswith('m=')]
        if len(media) != 1 or not media[0].startswith('m=application ') or 'a=fingerprint:' not in sdp:
            raise ValueError('A single encrypted data channel is required')
        await self.prune()
        if len(self.peers) >= 16 or sum(peer.token == token for peer in self.peers.values()) >= 2:
            raise web.HTTPTooManyRequests()
        RTCConfiguration, RTCIceServer, RTCPeerConnection, RTCSessionDescription = await asyncio.wait_for(
            asyncio.to_thread(rtc_backend), 10)
        if not self.service.store.authorized(token): raise PermissionError('Device revoked')
        # Recheck after the import await, before reserving this connection.
        if len(self.peers) >= 16 or sum(peer.token == token for peer in self.peers.values()) >= 2:
            raise web.HTTPTooManyRequests()
        pc = RTCPeerConnection(RTCConfiguration(iceServers=[RTCIceServer(**item) for item in self.ice_servers]))
        peer = Peer(self, pc, token, nonce, identity); self.peers[peer.id] = peer

        @pc.on('datachannel')
        def datachannel(channel): peer.attach(channel)

        @pc.on('connectionstatechange')
        async def statechange():
            if pc.connectionState in ('failed', 'closed'): await peer.close()

        try:
            async with asyncio.timeout(20):
                await pc.setRemoteDescription(RTCSessionDescription(sdp=sdp, type='offer'))
                await pc.setLocalDescription(await pc.createAnswer())
            return dict(protocol=PROTOCOL, session_id=peer.id, nonce=nonce, identity=identity,
                        type='answer', sdp=pc.localDescription.sdp)
        except BaseException:
            await peer.close()
            raise

    async def prune(self):
        await asyncio.gather(*(peer.close() for peer in list(self.peers.values())
            if not self.service.tunnel.enabled or not self.service.store.authorized(peer.token)
            or time.monotonic() - peer.created > 30 and peer.channel is None))

    async def close(self):
        await asyncio.gather(*(peer.close() for peer in list(self.peers.values())))

    def status(self):
        return dict(available=self.enabled and self.available, peers=len(self.peers),
                    ice_configured=bool(self.ice_servers), relay_configured=any(
                        url.startswith(('turn:', 'turns:')) for server in self.ice_servers for url in server['urls']))


class Peer:
    def __init__(self, owner, pc, token, nonce, identity):
        self.owner = owner; self.pc = pc; self.token = token; self.nonce = nonce; self.identity = identity
        self.id = str(uuid.uuid4()); self.created = time.monotonic()
        self.channel = None; self.requests = {}; self.closed = False
        self.drained = asyncio.Event(); self.drained.set()

    def attach(self, channel):
        if self.channel or channel.label != PROTOCOL or not channel.ordered or channel.maxRetransmits is not None or channel.maxPacketLifeTime is not None:
            channel.close(); return
        self.channel = channel; channel.bufferedAmountLowThreshold = 65536

        @channel.on('bufferedamountlow')
        def drained(): self.drained.set()

        @channel.on('message')
        def message(raw):
            try:
                if not isinstance(raw, str) or len(raw.encode()) > MAX_FRAME: raise ValueError('Frame too large')
                value = json.loads(raw)
                if not isinstance(value, dict) or not isinstance(value.get('id'), str): raise ValueError('Invalid request ID')
                ident = value['id']; uuid.UUID(ident)
                if value.get('kind') == 'cancel':
                    pending = self.requests.get(ident)
                    if pending: pending.cancel()
                    return
                if value.get('kind') != 'request' or ident in self.requests or len(self.requests) >= 16:
                    raise ValueError('Invalid request')
                self.requests[ident] = asyncio.create_task(self.forward(ident, value))
            except (ValueError, TypeError, KeyError):
                asyncio.create_task(self.close())

        @channel.on('close')
        def closed(): asyncio.create_task(self.close())

        def hello():
            if not self.owner.service.store.authorized(self.token):
                asyncio.create_task(self.close()); return
            if channel.readyState == 'open':
                channel.send(json.dumps(dict(kind='hello', protocol=PROTOCOL, session_id=self.id, nonce=self.nonce, identity=self.identity)))
        channel.on('open', hello)
        hello()

    async def send(self, value):
        if self.closed or not self.owner.service.tunnel.enabled or not self.owner.service.store.authorized(self.token):
            raise PermissionError('Remote access disabled or device revoked')
        channel = self.channel
        if channel is None or channel.readyState != 'open': raise ConnectionError('Channel closed')
        while channel.bufferedAmount > 262144:
            self.drained.clear()
            await asyncio.wait_for(self.drained.wait(), 15)
            if self.closed: raise ConnectionError('Channel closed')
        channel.send(json.dumps(value, separators=(',', ':')))

    async def forward(self, ident, value):
        try:
            if not self.owner.service.tunnel.enabled or not self.owner.service.store.authorized(self.token):
                raise PermissionError('Remote access disabled or device revoked')
            method = value.get('method'); route = permitted_route(method, value.get('path'))
            if route is None: raise ValueError('Route not allowed')
            target, context, stream = route
            headers = value.get('headers', {})
            if not isinstance(headers, dict) or set(headers) - {'Idempotency-Key', 'Last-Event-ID', 'Accept'}:
                raise ValueError('Headers not allowed')
            if any(not isinstance(v, str) or len(v) > 4096 or any(ord(c) < 32 for c in v) for v in headers.values()):
                raise ValueError('Invalid headers')
            body = base64.b64decode(value.get('body', ''), validate=True)
            if len(body) > MAX_FRAME or method == 'GET' and body: raise ValueError('Invalid body')
            if target.startswith('/desktop/v1/'):
                if target == '/desktop/v1/frames':
                    raise ValueError('Pictures require the separate HTTP media stream')
                if len(body) > 16_384: raise ValueError('Desktop request too large')
                code, result = await self.owner.service.desktop.handle(method, target, body, self.token)
                data = json.dumps(result, separators=(',', ':')).encode()
                await self.send(dict(kind='head', id=ident, status=code, content_type='application/json'))
                for start in range(0, len(data), CHUNK_BYTES):
                    await self.send(dict(kind='chunk', id=ident, body=base64.b64encode(data[start:start+CHUNK_BYTES]).decode('ascii')))
                await self.send(dict(kind='end', id=ident)); return
            headers['X-MoMo-Device'] = self.owner.service.store.device_id(self.token) or 'revoked'
            stream = stream or (method == 'POST' and target == '/momo/v1/conversation/messages'
                                and headers.get('Accept') == 'text/event-stream')
            async with await self.owner.service.upstream(method, target, body if method == 'POST' else None, context, headers, streaming=stream) as response:
                await self.send(dict(kind='head', id=ident, status=response.status, content_type=response.content_type,retry_after=response.headers.get('Retry-After')))
                total = 0
                async for chunk in response.content.iter_chunked(CHUNK_BYTES):
                    total += len(chunk)
                    if not stream and total > MAX_RESPONSE: raise ValueError('Response exceeds data channel limit; use pagination')
                    await self.send(dict(kind='chunk', id=ident, body=base64.b64encode(chunk).decode('ascii')))
                await self.send(dict(kind='end', id=ident))
        except asyncio.CancelledError:
            pass  # Unsubscribe only. A remote Agent stop is a distinct allowlisted request.
        except (ValueError, TypeError, KeyError, PermissionError, OSError, ClientError, asyncio.TimeoutError):
            try: await self.send(dict(kind='error', id=ident, message='Transport request failed; reconcile the original operation over HTTPS.'))
            except (PermissionError, OSError, asyncio.TimeoutError): await self.close()
        finally:
            self.requests.pop(ident, None)

    async def close(self):
        if self.closed: return
        self.closed = True; self.drained.set()
        self.owner.peers.pop(self.id, None)
        current = asyncio.current_task()
        pending = [task for task in self.requests.values() if task is not current]
        for task in pending: task.cancel()
        await asyncio.gather(*pending, return_exceptions=True)
        self.requests.clear()
        await self.pc.close()
