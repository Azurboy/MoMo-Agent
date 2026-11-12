"""Access boundary contracts and native libwebrtc / aiortc interoperability.

MOMO_RTC_PROBE enables the native scenarios; MOMO_TEST_TURN_URL/USER/PASSWORD
adds a real, locally managed TURN relay. No public relay or model service is used.
"""
import asyncio
import json
import os
from pathlib import Path
import secrets
import sys
import tempfile
import unittest
from unittest.mock import AsyncMock, patch
import uuid

from aiohttp import ClientSession, web
from aiohttp.test_utils import TestServer

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'Apps/MacApp/Access'))
from access_server import AccessService, errors, control_application
from rtc_transport import Peer, permitted_route, validate_ice


class RouteTests(unittest.TestCase):
    def test_recording_summary_uses_authenticated_context_transport_only(self):
        self.assertEqual(('/v1/summaries', True, False), permitted_route('POST', '/context/v1/summaries'))
        self.assertEqual(('/v1/summaries?id=example', True, False), permitted_route('GET', '/context/v1/summaries?id=example'))
        self.assertIsNone(permitted_route('POST', '/v1/summaries'))
        self.assertIsNone(permitted_route('DELETE', '/context/v1/summaries'))

    def test_shared_conversation_and_exact_native_controls_share_the_allowlist(self):
        for method, path in [('GET','/momo/v1/conversation'),('GET','/momo/v1/conversation/runs'),
            ('POST','/momo/v1/conversation/work/process:example/report-retry'),('POST','/momo/v1/conversation/work/work-example/cancel'),
            ('GET','/momo/v1/conversation/messages?after=10&limit=100'),('POST','/momo/v1/conversation/messages'),
            ('GET','/momo/v1/conversation/push'),('POST','/momo/v1/conversation/push'),
            ('POST','/momo/v1/conversation/push/revoke'),('POST','/momo/v1/conversation/push/visible'),('POST','/momo/v1/conversation/adopt'),('POST','/momo/v1/conversation/read'),
            ('POST','/v1/runs/run-safe/approval'),('POST','/v1/runs/run-safe/clarify'),('POST','/v1/runs/run-safe/resolve-unknown')]:
            self.assertIsNotNone(permitted_route(method,path),path)
        for method,path in [('GET','/momo/v1/conversation/push?device_id=spoof'),('PUT','/momo/v1/conversation/push'),
            ('GET','/momo/v1/conversation/work/process:example/report-retry'),('POST','/momo/v1/conversation/work/process:example/report-retry?owner=spoof'),
            ('POST','/momo/v1/conversation/push/other'),('POST','/momo/v1/conversation/complete'),('POST','/v1/runs/run-safe/steer'),
            ('GET','/momo/v1/conversation/messages?after=1&before=4'),('GET','/momo/v1/conversation/messages?after=1&after=2'),
            ('GET','/momo/v1/conversation/messages?owner=other')]:
            self.assertIsNone(permitted_route(method,path),path)

    def test_native_conversation_read_is_available_without_exposing_session_mutations(self):
        path = '/api/sessions/momo-abc/messages?limit=100&offset=0&order=oldest&include_compacted=true'
        self.assertEqual((path, False, False), permitted_route('GET', path))
        for method, bad in [('POST', path), ('GET', '/api/sessions'),
                ('GET', '/api/sessions/momo-abc/messages?limit=10000'),
                ('GET', '/api/sessions/momo-abc/messages?offset=-1'),
                ('GET', '/api/sessions/momo-abc/messages?order=invalid'),
                ('GET', '/api/sessions/momo-abc/messages?limit=20&limit=100'),
                ('GET', '/api/sessions/momo-abc/messages?include_inactive=true')]:
            self.assertIsNone(permitted_route(method, bad), bad)

    def test_shared_allowlist_preserves_cursor_and_context_queries(self):
        self.assertEqual(('/v1/runs/r1/events?after=4', False, True), permitted_route('GET', '/v1/runs/r1/events?after=4'))
        self.assertEqual(('/v1/source?id=a%2Fb', True, False), permitted_route('GET', '/context/v1/source?id=a%2Fb'))
        for path in ['/admin', '/transport/v1/config', '/v1/runs/../stop', 'https://other/v1/runs', '//other/v1/runs', '/v1/runs/r1#fragment', '/context/v1/runs']:
            self.assertIsNone(permitted_route('POST', path), path)

    def test_standard_ice_configuration_has_no_vendor_names(self):
        servers = [{'urls': ['stun:stun.example:3478', 'turns:relay.example:443?transport=tcp'], 'username': 'user', 'credential': 'secret'}]
        self.assertEqual(servers, validate_ice(servers))
        for value in [[{'urls': 'https://relay.example'}], [{'urls': 'turn:user@relay.example'}], [{'urls': 'turn:relay.example', 'credential': 'x\ny'}]]:
            with self.assertRaises(ValueError): validate_ice(value)


class RTCIntegrationTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.data = Path(self.temp.name)
        self.requests = []; self.operations = {}; self.live_detached = asyncio.Event()
        connection = dict(port=19000, workspace_id=str(uuid.uuid4()), assistant_id=str(uuid.uuid4()), instance_id=str(uuid.uuid4()))
        app = web.Application(); app.router.add_route('*', '/{tail:.*}', self.backend)
        self.backend_server = TestServer(app); await self.backend_server.start_server()
        base = str(self.backend_server.make_url('')).rstrip('/')
        connection.update(base_url=base, data_url=base + '/context')
        (self.data / 'connection.json').write_text(json.dumps(connection)); (self.data / 'api-key').write_text('r' * 64)
        self.service = AccessService(self.data)
        self.service.tunnel.enabled = True  # The fixture supplies its own local HTTP listener.
        self.session = ClientSession(); self.service.session = self.session
        public = web.Application(middlewares=[errors]); public.router.add_route('*', '/{tail:.*}', self.service.public)
        self.public = TestServer(public); await self.public.start_server()
        self.endpoint = str(self.public.make_url('')).rstrip('/')
        invite = self.service.store.invite(self.endpoint); self.token = secrets.token_urlsafe(48)
        self.device = self.service.store.request(invite['id'], 'Native probe', self.token)
        self.service.store.decide(self.device['id'], True)

    async def asyncTearDown(self):
        await self.service.rtc.close(); await self.public.close(); await self.backend_server.close()
        await self.session.close(); self.service.store.db.close(); self.temp.cleanup()

    async def backend(self, request):
        body = await request.read()
        self.requests.append((request.method, request.path, dict(request.headers), body))
        self.assertEqual('Bearer ' + 'r' * 64, request.headers.get('Authorization'))
        self.assertEqual('momo:' + self.service.connection['assistant_id'], request.headers.get('X-MoMo-Session-Key'))
        if request.path.endswith('/capabilities'):
            return web.json_response({'features': {'run_submission': True, 'runs_idempotency': {'supported': True, 'durable': True}}})
        if request.path == '/momo/v1/conversation/push':
            return web.json_response({},status=503,headers={'Retry-After':'17'})
        if request.path == '/context/v1/status':
            return web.json_response(dict(workspace_id=self.service.connection['workspace_id'], source_sync=True, memory_writer='SuperAgent'))
        if request.path.startswith('/context/v1/life-illustrations/assets/'):
            return web.Response(body=b'\x89PNG\r\n\x1a\nfixture', content_type='image/png', headers={'Cache-Control': 'private, no-store'})
        if request.path == '/v1/runs' and request.method == 'POST':
            operation = request.headers['Idempotency-Key']; self.operations.setdefault(operation, 'r1')
            return web.json_response(dict(run_id=self.operations[operation], session_id='s1', status='queued'), status=202)
        if request.path.endswith('/events'):
            response = web.StreamResponse(headers={'Content-Type': 'text/event-stream'}); await response.prepare(request)
            if '/live/' in request.path:
                try:
                    for _ in range(60):
                        await response.write(b': heartbeat\n\n'); await asyncio.sleep(.1)
                except (ConnectionError, asyncio.CancelledError): pass
                finally: self.live_detached.set()
            else:
                self.assertEqual('4', request.headers.get('Last-Event-ID'))
                for seq in (5, 6):
                    await response.write(('data: ' + json.dumps(dict(event='message.delta', run_id='r1', seq=seq, delta='你好')) + '\n\n').encode())
            return response
        if request.path == '/v1/runs/revoke':
            async def revoke():
                await asyncio.sleep(.2); self.service.store.revoke(self.device['id']); await self.service.rtc.prune()
            asyncio.create_task(revoke())
        return web.json_response(dict(run_id='r1', status='queued'))

    async def test_real_private_router_accepts_only_management_key_and_bounded_commands(self):
        import base64
        payload = dict(viewer=self.device['id'], operation='status', body=base64.b64encode(b'{}').decode())
        async with TestServer(control_application(self.service)) as server:
            endpoint = str(server.make_url('/desktop/rtc'))
            with patch('desktop_control.native_request', new=AsyncMock(return_value=dict(approved=True, screen=True, input=True))) as native:
                for token in ['', self.token]:
                    async with self.session.post(endpoint, headers={'Authorization':'Bearer '+token}, json=payload) as response: self.assertEqual(401, response.status)
                native.assert_not_awaited()
                headers = {'Authorization':'Bearer '+self.service.key}
                async with self.session.post(endpoint, headers=headers, json=payload) as response:
                    self.assertEqual(200, response.status); self.assertTrue((await response.json())['screen'])
                self.assertEqual('status', native.await_args.args[1]['op'])
                async with self.session.post(endpoint, headers=headers, data=b'x'*49153) as response: self.assertEqual(413, response.status)
                self.service.tunnel.enabled = False
                async with self.session.post(endpoint, headers=headers, json=payload) as response: self.assertEqual(403, response.status)

    async def test_desktop_video_offer_uses_public_pairing_and_keeps_private_control_private(self):
        offer = dict(version=1, nonce=str(uuid.uuid4()), sdp='synthetic')
        answer = {**offer, 'sdp': 'synthetic-answer'}
        with patch('desktop_control.native_request', new=AsyncMock(return_value=answer)) as native:
            for token in ['', 'r' * 64]:
                async with self.session.post(self.endpoint + '/desktop/v2/offer', headers={'Authorization':'Bearer '+token}, json=offer) as response:
                    self.assertEqual(401, response.status)
            native.assert_not_awaited()
            headers = {'Authorization':'Bearer '+self.token}
            async with self.session.post(self.endpoint + '/desktop/v2/offer', headers=headers, json=offer) as response:
                self.assertEqual(200, response.status); self.assertEqual(answer, await response.json())
            self.assertEqual(self.device['id'], native.await_args.args[1]['viewer'])
            for path in ['/desktop/rtc', '/desktop/v2/offer?device=other']:
                async with self.session.post(self.endpoint + path, headers=headers, json=offer) as response: self.assertEqual(404, response.status)
            async with self.session.post(self.endpoint + '/desktop/v2/offer', headers=headers, data=b'x'*147457) as response: self.assertEqual(413, response.status)

    async def test_push_route_overrides_device_identity_and_preserves_retry_after(self):
        async with self.session.get(self.endpoint+'/momo/v1/conversation/push',headers={
            'Authorization':'Bearer '+self.token,'X-MoMo-Device':'spoofed'}) as response:
            self.assertEqual(503,response.status); self.assertEqual('17',response.headers.get('Retry-After'))
        self.assertEqual(self.device['id'],self.requests[-1][2]['X-MoMo-Device'])
        self.service.store.revoke(self.device['id'])
        async with self.session.get(self.endpoint+'/momo/v1/conversation/push',headers={'Authorization':'Bearer '+self.token}) as response:
            self.assertEqual(401,response.status)

    async def test_illustration_asset_keeps_binary_type_and_requires_device_auth(self):
        url = self.endpoint + '/context/v1/life-illustrations/assets/' + 'a' * 64
        async with self.session.get(url) as response:
            self.assertEqual(401, response.status)
        async with self.session.get(url, headers={'Authorization': 'Bearer ' + self.token}) as response:
            self.assertEqual(200, response.status)
            self.assertEqual('image/png', response.content_type)
            self.assertEqual('private, no-store', response.headers['Cache-Control'])
            self.assertEqual(b'\x89PNG\r\n\x1a\nfixture', await response.read())

    async def test_signaling_requires_approved_device_and_matches_identity(self):
        for token in ['', 'r' * 64, secrets.token_urlsafe(48)]:
            async with self.session.get(self.endpoint + '/transport/v1/config', headers={'Authorization': 'Bearer ' + token}) as response:
                self.assertEqual(response.status, 401)
        headers = {'Authorization': 'Bearer ' + self.token}
        async with self.session.get(self.endpoint + '/transport/v1/config', headers=headers) as response:
            value = await response.json(); self.assertEqual(response.status, 200)
            self.assertEqual(value['identity']['instance_id'], self.service.connection['instance_id'])
        async with self.session.post(self.endpoint + '/transport/v1/offer', headers=headers, json={
            'protocol': 'momo-rpc-v1', 'type': 'offer', 'nonce': 'x' * 32, 'identity': {},
            'sdp': 'm=application 9 UDP/DTLS/SCTP webrtc-datachannel\na=fingerprint:test\n'}) as response:
            self.assertEqual(response.status, 401)
        self.assertFalse(self.service.rtc.peers)

    async def test_data_channel_cannot_forward_control_or_replace_root_headers(self):
        class Channel:
            readyState = 'open'
            bufferedAmount = 0
            def __init__(self): self.sent = []
            def send(self, value): self.sent.append(json.loads(value))
        class Connection:
            async def close(self): pass
        peer = Peer(self.service.rtc, Connection(), self.token, 'x' * 32, {})
        channel = Channel(); peer.channel = channel
        for path, headers in [('/devices/revoke', {}), ('/v1/capabilities', {'Authorization': 'Bearer root'}), ('/v1/capabilities', {'Accept': 'a\r\nb'})]:
            await peer.forward(str(uuid.uuid4()), dict(method='GET', path=path, headers=headers))
        self.assertEqual(['error'] * 3, [frame['kind'] for frame in channel.sent])
        self.assertFalse(self.requests)
        self.service.store.revoke(self.device['id'])
        with self.assertRaises(PermissionError): await peer.send(dict(kind='chunk'))

    async def test_ice_file_is_private_and_reconfiguration_closes_only_network(self):
        await self.service.rtc.configure(dict(enabled=False, ice_servers=[]))
        self.assertEqual(0o600, self.service.rtc.file.stat().st_mode & 0o777)
        self.assertFalse(self.service.rtc.configuration()['available'])
        self.assertTrue(self.service.store.authorized(self.token))
        self.assertFalse(self.requests)

    async def test_disabled_remote_access_blocks_a_peer_that_was_already_admitted(self):
        class Connection:
            async def close(self): pass
        peer = Peer(self.service.rtc, Connection(), self.token, 'x' * 32, {})
        self.service.tunnel.enabled = False
        await peer.forward('already-admitted', dict(method='POST', path='/v1/runs', body='e30='))
        self.assertTrue(peer.closed)
        self.assertFalse(self.requests)
        self.assertTrue(self.service.store.authorized(self.token))

    async def test_malformed_frame_closes_network_without_agent_side_effects(self):
        class Channel:
            label = 'momo-rpc-v1'; ordered = True; maxRetransmits = None; maxPacketLifeTime = None
            readyState = 'open'
            def __init__(self): self.handlers = {}
            def on(self, name, handler=None):
                if handler is not None: self.handlers[name] = handler
                else: return lambda callback: self.handlers.__setitem__(name, callback)
            def send(self, value): pass
        class Connection:
            async def close(self): pass
        peer = Peer(self.service.rtc, Connection(), self.token, 'x' * 32, {})
        channel = Channel(); peer.attach(channel)
        channel.handlers['message']('{"kind":"request","id":42}')
        await asyncio.sleep(0)
        self.assertTrue(peer.closed); self.assertFalse(self.requests)

    async def native(self, mode):
        executable = os.environ.get('MOMO_RTC_PROBE')
        if not executable: self.skipTest('Set MOMO_RTC_PROBE to run native interoperability')
        fixture = self.data / 'native.json'
        fixture.write_text(json.dumps(dict(connection=self.service.public_connection(self.endpoint), credential=self.token)))
        fixture.chmod(0o600)
        process = await asyncio.create_subprocess_exec(executable, str(fixture), mode, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
        try: out, err = await asyncio.wait_for(process.communicate(), 45)
        except TimeoutError:
            process.kill(); await process.wait(); raise
        if process.returncode != 0: print('Native probe failed: ' + err.decode()[-3000:], flush=True)
        self.assertEqual(process.returncode, 0, err.decode()[-3000:])
        return json.loads(out)

    async def test_native_direct_rpc_cursor_and_https_resume(self):
        result = await self.native('direct'); self.assertEqual(result['route'], 'direct')
        submissions = [r for r in self.requests if r[0] == 'POST' and r[1] == '/v1/runs']
        self.assertEqual(2, len(submissions)); self.assertEqual(1, len(self.operations))
        self.assertFalse(any(r[1].endswith('/stop') for r in self.requests))
        await asyncio.wait_for(self.live_detached.wait(), 2)

    async def test_native_unreachable_relay_falls_back_to_https(self):
        await self.service.rtc.configure(dict(ice_transport_policy='relay', ice_servers=[{'urls': ['turn:127.0.0.1:9?transport=udp'], 'username': 'test', 'credential': 'test'}]))
        result = await self.native('fallback'); self.assertTrue(result['fallback'])

    async def test_native_revocation_closes_active_channel(self):
        self.assertTrue((await self.native('revoke'))['revocation']); self.assertFalse(self.service.rtc.peers)

    async def test_native_real_turn_relay(self):
        url = os.environ.get('MOMO_TEST_TURN_URL')
        if not url: self.skipTest('Set MOMO_TEST_TURN_URL for real TURN allocation')
        await self.service.rtc.configure(dict(ice_transport_policy='relay', ice_servers=[{'urls': [url], 'username': os.environ['MOMO_TEST_TURN_USER'], 'credential': os.environ['MOMO_TEST_TURN_PASSWORD']}]))
        self.assertEqual((await self.native('relay'))['route'], 'relay')


if __name__ == '__main__': unittest.main()
