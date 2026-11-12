"""Durable replay over a single paired HTTP stream, including idle revocation."""
import asyncio
import gzip
import json
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
import uuid
from aiohttp import ClientSession, web
from aiohttp.test_utils import TestServer

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT/'Apps/MacApp/Runtime'), str(ROOT/'Apps/MacApp/Access')]
from conversation_store import ProductStore
from access_server import AccessService
from rtc_transport import permitted_route


class ConversationEventsTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.path = Path(self.temp.name)/'conversation.sqlite'
        self.connection = {'assistant_id':'fixture'}
        self.store = ProductStore(self.path, self.connection)
        self.accepted = 0; self.authorized = True
        async def subscribe(request):
            self.accepted += 1
            return await self.store.events.subscribe(request, lambda: True, heartbeat=0.02)
        async def submit(request):
            value = await request.json()
            row = self.store.accept(value['operation_id'], value['content'], 'fixture')
            return web.json_response({'run_id':row['run_id'], 'status':'queued'})
        app = web.Application(); app.router.add_get('/momo/v1/conversation/subscribe', subscribe)
        app.router.add_post('/momo/v1/conversation/messages', submit)
        async def snapshot(request):
            return web.json_response({'history': 'conversation' * 10_000})
        app.router.add_get('/momo/v1/conversation/snapshot', snapshot)
        self.native = TestServer(app); await self.native.start_server()
        self.session = ClientSession()
        service = AccessService.__new__(AccessService); service.tunnel = SimpleNamespace(enabled=True)
        service.store = SimpleNamespace(authorized=lambda token:self.authorized and token=='paired', device_id=lambda _: 'device')
        async def forward(method,path,body=None,context=False,headers=None,streaming=False):
            return await self.session.request(method,self.native.make_url(path),data=body,headers=headers)
        service.upstream = forward
        app = web.Application(); app.router.add_route('*','/{tail:.*}',service.public)
        self.public = TestServer(app); await self.public.start_server()
        self.headers = {'Authorization':'Bearer paired'}

    async def asyncTearDown(self):
        await self.session.close(); await self.public.close(); await self.native.close()
        self.store.db.close(); self.temp.cleanup()

    async def frame(self, response, kind=None):
        async with asyncio.timeout(2):
            while True:
                line = await response.content.readline()
                if not line: return None
                if line.startswith(b'data:'):
                    value=json.loads(line[5:])
                    if kind is None or value['kind']==kind:return value

    async def test_snapshot_compression_preserves_history_for_both_clients(self):
        url = self.public.make_url('/momo/v1/conversation/snapshot')
        async with ClientSession(auto_decompress=False) as client:
            async with client.get(url, headers={**self.headers, 'Accept-Encoding': 'identity'}) as plain:
                self.assertEqual(plain.status, 200)
                self.assertNotIn('Content-Encoding', plain.headers)
                original = await plain.read()
            async with client.get(url, headers={**self.headers, 'Accept-Encoding': 'gzip'}) as compressed:
                self.assertEqual(compressed.headers['Content-Encoding'], 'gzip')
                body = await compressed.read()
                self.assertLess(len(body), len(original))
                self.assertEqual(gzip.decompress(body), original)

    async def test_two_independent_posts_and_background_reply_share_one_subscription(self):
        async with self.session.get(self.public.make_url('/momo/v1/conversation/subscribe?after=0'),headers=self.headers) as stream:
            self.assertEqual('ready',(await self.frame(stream))['kind'])
            for content in ['first','second']:
                operation=str(uuid.uuid4())
                async with self.session.post(self.public.make_url('/momo/v1/conversation/messages'),
                        headers=self.headers,json={'operation_id':operation,'content':content}) as response:
                    run=(await response.json())['run_id']
                event=await self.frame(stream,'message.created')
                self.assertEqual(content,event['message']['content'])
                self.store.append_assistant('answer:'+operation,'done '+content,1,run)
                self.assertEqual('done '+content,(await self.frame(stream,'message.created'))['message']['content'])
            self.assertEqual(1,self.accepted)

    async def test_commit_between_snapshot_and_subscribe_replays_after_restart(self):
        before=self.store.events.cursor
        operation=str(uuid.uuid4());self.store.accept(operation,'offline','scope')
        after=self.store.events.cursor
        self.store.accept(operation,'offline','scope')
        self.assertEqual(after,self.store.events.cursor,'Duplicate operation cannot emit another event')
        self.store.db.close(); self.store=ProductStore(self.path,self.connection)
        async with self.session.get(self.public.make_url(f'/momo/v1/conversation/subscribe?after={before}'),headers=self.headers) as stream:
            event=await self.frame(stream,'message.created')
            self.assertEqual(after,event['cursor']);self.assertEqual('offline',event['message']['content'])
        async with self.session.get(self.public.make_url(f'/momo/v1/conversation/subscribe?after={after}'),headers=self.headers) as stream:
            await self.frame(stream,'ready')
            self.assertEqual('heartbeat',(await self.frame(stream))['kind'])

    async def test_phone_disconnect_does_not_lose_completion_and_reopen_replays_once(self):
        operation = str(uuid.uuid4())
        async with self.session.post(self.public.make_url('/momo/v1/conversation/messages'),
                headers=self.headers, json={'operation_id': operation, 'content': 'finish later'}) as response:
            run = (await response.json())['run_id']
        async with self.session.get(self.public.make_url('/momo/v1/conversation/subscribe?after=0'), headers=self.headers) as stream:
            receipt = await self.frame(stream, 'message.created')
        # No connected phone or subscriber when the independent native result is committed.
        identifier = self.store.append_assistant('completed:'+operation, 'durable answer', 1, run)
        self.store.append_assistant('completed:'+operation, 'durable answer', 1, run)
        async with asyncio.timeout(2):
            while self.store.events.listeners: await asyncio.sleep(0.01)
        self.store.db.close(); self.store = ProductStore(self.path, self.connection)
        async with self.session.get(self.public.make_url(f'/momo/v1/conversation/subscribe?after={receipt["cursor"]}'), headers=self.headers) as stream:
            result = await self.frame(stream, 'message.created')
            self.assertEqual(identifier, result['message']['id'])
            self.assertEqual('durable answer', result['message']['content'])
            self.assertEqual('heartbeat', (await self.frame(stream))['kind'])
        self.assertEqual(2, len(self.store.page()['data']))

    async def test_rollback_has_no_event_and_idle_revocation_closes_stream(self):
        with self.assertRaises(RuntimeError):
            with self.store.db:
                self.store.events.append('message.created',{'message':{'content':'uncommitted'}})
                raise RuntimeError()
        self.assertEqual(0,self.store.events.cursor)
        async with self.session.get(self.public.make_url('/momo/v1/conversation/subscribe?after=0'),headers=self.headers) as stream:
            await self.frame(stream,'ready'); self.authorized=False
            async with asyncio.timeout(2):self.assertEqual(b'',(await stream.read()).strip())
        async with self.session.get(self.public.make_url('/momo/v1/conversation/subscribe?after=0'),headers=self.headers) as response:
            self.assertEqual(401,response.status)

    async def test_cursor_validation_and_changed_state_deduplication(self):
        self.store.events.changed('run:r','run.updated',{'run':{'run_id':'r','status':'running'}})
        cursor=self.store.events.cursor
        self.store.events.changed('run:r','run.updated',{'run':{'status':'running','run_id':'r'}})
        self.assertEqual(cursor,self.store.events.cursor)
        async with self.session.get(self.public.make_url('/momo/v1/conversation/subscribe?after=999'),headers=self.headers) as response:
            self.assertEqual(409,response.status)
        for suffix in ['?after=-1','?after=0&after=1','?after=0&url=http://example.com']:
            self.assertIsNone(permitted_route('GET','/momo/v1/conversation/subscribe'+suffix))


if __name__=='__main__':unittest.main()
