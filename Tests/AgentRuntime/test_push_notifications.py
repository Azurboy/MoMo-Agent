import asyncio
import importlib.util
import json
from pathlib import Path
import sqlite3
import sys
import tempfile
import time
import unittest
import uuid
from unittest.mock import AsyncMock
from aiohttp.test_utils import TestClient, TestServer

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'Apps/MacApp/Runtime'))
from conversation_store import ProductStore
from push_notifications import PushOutbox, TOPIC
spec=importlib.util.spec_from_file_location('momo_push_gateway',ROOT/'Services/NotificationGateway/gateway.py')
gateway=importlib.util.module_from_spec(spec); spec.loader.exec_module(gateway)

class Provider:
    ready=True; environment='development'; topic=TOPIC
    def __init__(self): self.send=AsyncMock(return_value={'state':'accepted'})
    async def check(self): return self.ready
    async def register(self,value): return {'state':'accepted'}
    async def revoke(self,value): return {'state':'accepted'}
    async def close(self): pass

class OutboxTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(); self.root=Path(self.temp.name)
        self.connection={'instance_id':str(uuid.uuid4()),'assistant_id':str(uuid.uuid4())}
        self.store=ProductStore(self.root/'product.sqlite',self.connection)
        self.pair=sqlite3.connect(self.root/'pairs.sqlite'); self.pair.execute('CREATE TABLE devices(id TEXT,state TEXT)')
        self.provider=Provider(); self.out=PushOutbox(self.store,self.connection,self.root/'pairs.sqlite',self.provider)
    def tearDown(self): self.store.db.close(); self.pair.close(); self.temp.cleanup()
    def device(self):
        ident=str(uuid.uuid4()); self.pair.execute("INSERT INTO devices VALUES(?,'approved')",(ident,)); self.pair.commit()
        self.out.register(ident,dict(token='a'*64,topic=TOPIC,environment='development',registration_id=str(uuid.uuid4())))
        return ident
    def event(self,key='one',kind='final',historical=False):
        ident=self.store.append_assistant(key,'private transcript content must not reach push',time.time(),'run-one')
        message=dict(self.store.db.execute('SELECT * FROM messages WHERE id=?',(ident,)).fetchone())
        self.out.emit(key,kind,run_id='run-one',message=message,historical=historical)
        return message
    async def test_interim_and_backfill_do_not_queue_two_devices_offline_retry_and_read(self):
        a=self.device(); b=self.device(); self.store.append_assistant('interim','working',time.time(),'run-one')
        self.assertEqual(0,self.store.db.execute('SELECT count(*) FROM notification_deliveries').fetchone()[0])
        self.event('history',historical=True); self.assertEqual(0,self.store.db.execute('SELECT count(*) FROM notification_deliveries').fetchone()[0])
        self.provider.ready=False; message=self.event()
        self.assertEqual(['pending','pending'],[r[0] for r in self.store.db.execute('SELECT state FROM notification_deliveries')])
        await self.out.tick(); self.provider.send.assert_not_awaited()
        self.provider.ready=True; self.out.read(a,message['seq']); await self.out.tick()
        self.assertEqual(1,self.provider.send.await_count)
        sent=self.provider.send.call_args.args[0]; self.assertEqual(b,sent['device_id']); self.assertNotIn('content',str(sent)); self.assertNotIn('transcript',str(sent))
        self.assertEqual({'suppressed','accepted'}, {r[0] for r in self.store.db.execute('SELECT state FROM notification_deliveries')})
        self.assertEqual(1,self.store.db.execute('SELECT count(*) FROM reads').fetchone()[0])
    async def test_same_token_new_registration_survives_old_invalid_response_and_revoke(self):
        a=self.device(); self.event()
        async def rotate(_):
            self.out.register(a,dict(token='a'*64,topic=TOPIC,environment='development',registration_id=str(uuid.uuid4())))
            return {'state':'invalid_device'}
        self.provider.send.side_effect=rotate; await self.out.tick()
        device=self.store.db.execute('SELECT * FROM push_devices').fetchone()
        self.assertEqual(2,device['revision']); self.assertEqual(1,device['enabled'])
        self.provider.send.side_effect=None
        self.pair.execute("UPDATE devices SET state='revoked'"); self.pair.commit()
        await self.out.tick()
        self.assertEqual('disabled',self.store.db.execute('SELECT state FROM notification_deliveries').fetchone()[0])
        self.assertEqual(1,self.provider.send.await_count)
    async def test_slow_provider_does_not_hold_product_writes_and_retry_survives_reopen(self):
        self.device(); self.event(); started=asyncio.Event(); release=asyncio.Event()
        async def blocked(_): started.set(); await release.wait(); return {'state':'retry','retry_after':900}
        self.provider.send.side_effect=blocked; worker=asyncio.create_task(self.out.tick()); await started.wait()
        self.store.accept(str(uuid.uuid4()),'new chat while push is blocked','scope')
        self.assertEqual(1,self.store.db.execute('SELECT count(*) FROM inputs').fetchone()[0])
        release.set(); await worker
        ident=self.store.db.execute('SELECT delivery_id FROM notification_deliveries').fetchone()[0]
        self.store.db.close(); self.store=ProductStore(self.root/'product.sqlite',self.connection)
        self.out=PushOutbox(self.store,self.connection,self.root/'pairs.sqlite',self.provider)
        self.assertEqual(ident,self.store.db.execute('SELECT delivery_id FROM notification_deliveries').fetchone()[0])
        self.assertEqual('retry',self.store.db.execute('SELECT state FROM notification_deliveries').fetchone()[0])
        self.provider.send.assert_awaited_once()
    async def test_control_once_and_resolved_before_send(self):
        self.device()
        for _ in range(3): self.out.emit('control:run:2:p','needs_input',run_id='run',control_id='p',generation=2)
        self.assertEqual(1,self.store.db.execute('SELECT count(*) FROM notification_deliveries').fetchone()[0])
        with self.store.db:self.store.db.execute('UPDATE push_events SET active=0')
        await self.out.tick(); self.provider.send.assert_not_awaited()
    async def test_registration_retry_respects_gateway_backoff(self):
        now = time.time(); self.out.now = lambda: now
        device = self.device()
        self.provider.register = AsyncMock(return_value={'state':'retry','retry_after':120})
        await self.out.tick()
        row = self.store.db.execute('SELECT * FROM push_devices WHERE device_id=?',(device,)).fetchone()
        self.assertEqual(now+120, row['next_attempt'])
        now += 119; await self.out.tick(); self.provider.register.assert_awaited_once()
        now += 1; await self.out.tick(); self.assertEqual(2, self.provider.register.await_count)
    async def test_seen_control_before_event_and_failed_after_read_ack_are_independent(self):
        device=self.device(); ack=self.event('ack')
        self.out.read(device,ack['seq'])
        self.out.visible_controls(device,[{'run_id':'run-one','control_id':'prompt','execution_generation':2}])
        self.out.emit('control:run-one:2:prompt','needs_input',run_id='run-one',control_id='prompt',generation=2)
        self.out.emit('terminal:failed','failed',run_id='run-one')
        await self.out.tick()
        kinds=[call.args[0]['payload']['kind'] for call in self.provider.send.call_args_list]
        self.assertEqual(['failed'],kinds)
        self.out.emit('terminal:another','failed',run_id='run-another')
        self.out.visible_controls(device,[{'kind':'failed','run_id':'run-another'}])
        await self.out.tick(); self.assertEqual(1,self.provider.send.await_count)

    async def test_formal_app_topic_is_preserved_and_cross_topic_registration_rejected(self):
        self.provider.topic = 'com.momoagent.ios'
        device = str(uuid.uuid4())
        self.pair.execute("INSERT INTO devices VALUES(?,'approved')", (device,)); self.pair.commit()
        registration = dict(token='a'*64, topic=self.provider.topic, environment='development', registration_id=str(uuid.uuid4()))
        self.out.register(device, registration)
        self.assertEqual(self.provider.topic, self.out.status(device)['topic'])
        self.assertEqual(self.provider.topic, self.store.db.execute('SELECT topic FROM push_devices').fetchone()[0])
        self.event(); await self.out.tick(); self.provider.send.assert_awaited_once()
        with self.assertRaises(ValueError): self.out.register(device, dict(registration, topic=TOPIC))

    def test_unconfigured_is_truthfully_disabled_and_identity_spoof_rejected(self):
        a=self.device(); self.out.provider=None; self.event()
        self.assertEqual('disabled',self.store.db.execute('SELECT state FROM notification_deliveries').fetchone()[0])
        self.assertFalse(self.out.status(a)['configured'])
        with self.assertRaises(ValueError): self.out.register(a,dict(token='a'*64,topic='another.app',environment='development',registration_id=str(uuid.uuid4())))

class GatewayTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp=tempfile.TemporaryDirectory(); self.provider=Provider(); self.g=gateway.Gateway(Path(self.temp.name)/'gateway.db',self.provider)
        self.instance=str(uuid.uuid4()); self.token=self.g.add_instance(self.instance)
        self.other=str(uuid.uuid4()); self.other_token=self.g.add_instance(self.other)
        self.client=TestClient(TestServer(self.g.app())); await self.client.start_server()
        self.device=str(uuid.uuid4()); self.headers={'Authorization':'Bearer '+self.token}
    async def asyncTearDown(self):await self.client.close(); self.temp.cleanup()
    async def register(self,revision=1):
        return await self.client.put('/v1/devices/'+self.device,headers=self.headers,json=dict(token='b'*64,revision=revision,topic=TOPIC,environment='development',registered_at=time.time()))
    def payload(self): return dict(device_id=self.device,revision=1,payload=dict(v=1,kind='final',instance_id=self.instance,assistant_id=str(uuid.uuid4()),conversation_id='conversation-a',run_id='run-a',message_id='message-a',delivery_id=str(uuid.uuid4())))
    async def test_isolation_idempotency_no_arbitrary_copy_and_revoke(self):
        self.assertEqual(200,(await self.register()).status); value=self.payload()
        response=await self.client.post('/v1/notifications',headers={'Authorization':'Bearer '+self.other_token},json=value)
        self.assertEqual(400,response.status)
        for _ in range(2):
            response=await self.client.post('/v1/notifications',headers=self.headers,json=value); self.assertEqual('accepted',(await response.json())['state'])
        self.provider.send.assert_awaited_once()
        value['payload']['url']='https://bad.example'; self.assertEqual(400,(await self.client.post('/v1/notifications',headers=self.headers,json=value)).status)
        await self.client.delete('/v1/devices/'+self.device,headers=self.headers,json={'revision':2})
        self.assertEqual('invalid_device',(await (await self.register(1)).json())['state'])
        value=self.payload(); self.assertEqual('invalid_device',(await (await self.client.post('/v1/notifications',headers=self.headers,json=value)).json())['state'])
        self.g.revoke_instance(self.instance); self.assertEqual(401,(await self.client.get('/v1/status',headers=self.headers)).status)
    async def test_rotation_during_410_and_registration_timestamp_protect_new_token(self):
        await self.register()
        async def rotate(device,payload):
            await self.register(2); return {'state':'invalid_device','invalid_at':int(time.time()*1000)}
        self.provider.send.side_effect=rotate
        original=self.payload()
        await self.client.post('/v1/notifications',headers=self.headers,json=original)
        row=self.g.db.execute('SELECT * FROM devices').fetchone(); self.assertEqual(2,row['revision']); self.assertEqual(1,row['enabled'])
        self.provider.send.side_effect=None; self.provider.send.return_value={'state':'accepted'}
        original['revision']=2
        retry=await self.client.post('/v1/notifications',headers=self.headers,json=original)
        self.assertEqual('accepted',(await retry.json())['state'])
        self.provider.send.return_value={'state':'invalid_device','invalid_at':1}
        value=self.payload(); value['revision']=2
        response=await self.client.post('/v1/notifications',headers=self.headers,json=value)
        self.assertEqual('retry',(await response.json())['state']); self.assertEqual(1,self.g.db.execute('SELECT enabled FROM devices').fetchone()[0])
    async def test_retry_keeps_delivery_id_and_new_revision_is_allowed(self):
        await self.register(); value=self.payload(); self.provider.send.return_value={'state':'retry','retry_after':900}
        await self.client.post('/v1/notifications',headers=self.headers,json=value)
        await self.register(2); value['revision']=2; self.provider.send.return_value={'state':'accepted'}
        response=await self.client.post('/v1/notifications',headers=self.headers,json=value)
        self.assertEqual('accepted',(await response.json())['state']); self.assertEqual(1,self.g.db.execute('SELECT count(*) FROM deliveries').fetchone()[0])

    async def test_formal_gateway_accepts_only_its_configured_app(self):
        self.provider.topic = 'com.momoagent.ios'
        self.assertEqual(400, (await self.register()).status)
        response = await self.client.put('/v1/devices/'+self.device, headers=self.headers,
            json=dict(token='b'*64,revision=1,topic=self.provider.topic,environment='development',registered_at=time.time()))
        self.assertEqual(200, response.status)
        status = await (await self.client.get('/v1/status',headers=self.headers)).json()
        self.assertEqual(self.provider.topic, status['topic'])

    async def test_reject_notification_without_an_actionable_locator(self):
        await self.register()
        value = self.payload(); del value['payload']['message_id']
        self.assertEqual(400, (await self.client.post('/v1/notifications',headers=self.headers,json=value)).status)
        value['payload']['kind'] = 'needs_input'
        self.assertEqual(400, (await self.client.post('/v1/notifications',headers=self.headers,json=value)).status)
        self.provider.send.assert_not_awaited()


class APNsProtocolTests(unittest.IsolatedAsyncioTestCase):
    def provider(self, responses):
        # Exercise the real serializer/error mapping without loading any Apple key or sending externally.
        provider = gateway.APNs.__new__(gateway.APNs)
        provider.environment = 'development'
        provider.topic = TOPIC
        provider.bearer = lambda refresh=False: 'fixture-provider-auth'
        provider.client = type('Client', (), {'post': AsyncMock(side_effect=responses)})()
        return provider

    def response(self, code, reason=None):
        return type('Response', (), {'http_version':'HTTP/2','status_code':code,'headers':{},
            'json': lambda _: {'reason':reason} if reason else {}})()

    async def test_visible_alert_is_private_and_acceptance_is_not_delivery(self):
        provider = self.provider([self.response(200)])
        payload = dict(v=1,kind='final',conversation_id='conversation-fixture',delivery_id=str(uuid.uuid4()),message_id='persisted-message')
        self.assertEqual({'state':'accepted'}, await provider.send({'token':'test-device-token'}, payload))
        call = provider.client.post.call_args
        self.assertEqual('alert', call.kwargs['headers']['apns-push-type'])
        self.assertEqual('10', call.kwargs['headers']['apns-priority'])
        self.assertEqual({'title':'MoMo','body':'MoMo 有新回复'}, call.kwargs['json']['aps']['alert'])
        self.assertEqual(1, call.kwargs['json']['aps']['content-available'])
        self.assertEqual(payload, call.kwargs['json']['momo'])

    async def test_formal_apns_uses_the_formal_signed_topic(self):
        provider = self.provider([self.response(200)]); provider.topic = 'com.momoagent.ios'
        payload = dict(kind='final',conversation_id='fixture',delivery_id=str(uuid.uuid4()))
        await provider.send({'token':'test-device-token'},payload)
        self.assertEqual('com.momoagent.ios',provider.client.post.call_args.kwargs['headers']['apns-topic'])

    async def test_provider_auth_refresh_uses_same_notification_identity(self):
        provider = self.provider([self.response(403,'ExpiredProviderToken'), self.response(200)])
        payload = dict(kind='final',conversation_id='fixture',delivery_id=str(uuid.uuid4()))
        self.assertEqual('accepted', (await provider.send({'token':'test-device-token'}, payload))['state'])
        ids = [call.kwargs['headers']['apns-id'] for call in provider.client.post.call_args_list]
        self.assertEqual([payload['delivery_id']]*2, ids)

    async def test_invalid_token_and_temporary_rejection_are_distinct(self):
        payload = dict(kind='final',conversation_id='fixture',delivery_id=str(uuid.uuid4()))
        invalid = await self.provider([self.response(410,'Unregistered')]).send({'token':'test-device-token'},payload)
        retry = await self.provider([self.response(503,'ServiceUnavailable')]).send({'token':'test-device-token'},payload)
        self.assertEqual('invalid_device',invalid['state'])
        self.assertEqual('retry',retry['state']); self.assertGreaterEqual(retry['retry_after'],900)

if __name__=='__main__':unittest.main()
