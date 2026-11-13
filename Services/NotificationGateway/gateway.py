"""Small private APNs gateway. Credentials scope each Mac to its own device registry."""
import argparse
import asyncio
import hashlib
import json
import logging
from pathlib import Path
import re
import secrets
import sqlite3
import time
import uuid

from aiohttp import web

# HTTP client INFO logs include the device-token URL; never emit those.
logging.getLogger('httpx').setLevel(logging.WARNING)
logging.getLogger('httpcore').setLevel(logging.WARNING)
TOPIC = 'com.momoagent.ios.beta'
TOPICS = frozenset((TOPIC, 'com.momoagent.ios'))
COPY = {'final':'MoMo 有新回复','failed':'有一件事未完成','needs_input':'MoMo 需要你的确认'}


def opaque(value):
    return isinstance(value,str) and re.fullmatch(r'[A-Za-z0-9_-]{1,200}',value) is not None


def private_json(path):
    path = Path(path)
    if path.is_symlink() or path.stat().st_mode & 0o077: raise ValueError('Configuration must be a private file (0600)')
    return json.loads(path.read_text())


class APNs:
    def __init__(self, configuration):
        import httpx
        import jwt
        from cryptography.hazmat.primitives.serialization import load_pem_private_key
        from cryptography.hazmat.primitives.asymmetric.ec import EllipticCurvePrivateKey, SECP256R1
        self.environment = configuration['environment']
        self.topic = configuration['topic']
        if self.topic not in TOPICS or self.environment not in ('development','production'): raise ValueError('Unsupported topic/environment')
        self.team = configuration['team_id']; self.key_id = configuration['key_id']
        if not all(re.fullmatch(r'[A-Z0-9]{10}',v) for v in (self.team,self.key_id)): raise ValueError('Invalid Apple team/key ID')
        path = Path(configuration['key_path'])
        if path.is_symlink() or path.stat().st_mode & 0o077: raise ValueError('APNs key must be private (0600)')
        self.key = path.read_bytes()
        key = load_pem_private_key(self.key, password=None)
        if not isinstance(key,EllipticCurvePrivateKey) or not isinstance(key.curve,SECP256R1): raise ValueError('APNs requires a P-256 private key')
        self.jwt = jwt; self.token = None; self.token_at = 0
        self.client = httpx.AsyncClient(http2=True, timeout=10, follow_redirects=False, trust_env=False)
        self.ready = True

    def bearer(self, refresh=False):
        if refresh or self.token is None or time.time()-self.token_at >= 3000:
            self.token_at = time.time()
            self.token = self.jwt.encode({'iss':self.team,'iat':int(self.token_at)},self.key,algorithm='ES256',headers={'kid':self.key_id})
        return self.token

    async def send(self, device, payload):
        base = 'https://api.sandbox.push.apple.com' if self.environment=='development' else 'https://api.push.apple.com'
        body = {'aps':{'content-available':1,'alert':{'title':'MoMo','body':COPY[payload['kind']]},'sound':'default','thread-id':payload['conversation_id']},'momo':payload}
        collapse = hashlib.sha256((payload['conversation_id']+payload['kind']).encode()).hexdigest()
        for attempt in range(2):
            response = await self.client.post(base+'/3/device/'+device['token'],json=body,headers={
                'authorization':'bearer '+self.bearer(), 'apns-topic':self.topic,'apns-push-type':'alert','apns-priority':'10',
                'apns-id':payload['delivery_id'],'apns-collapse-id':collapse,'apns-expiration':str(int(time.time())+86400)})
            if response.http_version != 'HTTP/2': return {'state':'disabled','reason':'HTTP2Required'}
            if response.status_code==200: return {'state':'accepted'}
            try: result=response.json()
            except ValueError: result={}
            reason=result.get('reason','APNsError')
            if response.status_code==403 and reason=='ExpiredProviderToken' and attempt==0:
                self.bearer(refresh=True); continue
            if response.status_code==410 or reason in ('BadDeviceToken','DeviceTokenNotForTopic'):
                return {'state':'invalid_device','reason':reason,'invalid_at':result.get('timestamp')}
            if response.status_code==429 or response.status_code>=500:
                try: delay=float(response.headers.get('retry-after',0))
                except ValueError: delay=0
                return {'state':'retry','reason':reason,'retry_after':max(900 if response.status_code>=500 else 60,delay)}
            return {'state':'disabled','reason':reason}
        return {'state':'disabled','reason':'ProviderAuthenticationFailed'}

    async def close(self): await self.client.aclose()


class Gateway:
    def __init__(self, path, provider):
        self.provider=provider; self.db=sqlite3.connect(path); self.db.row_factory=sqlite3.Row
        self.db.executescript('''
        PRAGMA journal_mode=WAL;
        CREATE TABLE IF NOT EXISTS instances(id TEXT PRIMARY KEY, credential_hash TEXT UNIQUE NOT NULL, enabled INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS devices(instance TEXT NOT NULL, id TEXT NOT NULL, token TEXT NOT NULL,
          revision INTEGER NOT NULL, registered_at REAL NOT NULL, enabled INTEGER NOT NULL, PRIMARY KEY(instance,id));
        CREATE TABLE IF NOT EXISTS deliveries(instance TEXT NOT NULL,id TEXT NOT NULL,device TEXT NOT NULL,
          payload_hash TEXT NOT NULL,state TEXT NOT NULL,result TEXT NOT NULL,created REAL NOT NULL,PRIMARY KEY(instance,id));
        ''')
        Path(path).chmod(0o600)
        self.locks={}; self.rate={}

    def add_instance(self, ident):
        uuid.UUID(ident); credential=secrets.token_urlsafe(36)
        with self.db: self.db.execute('INSERT INTO instances VALUES(?,?,1) ON CONFLICT(id) DO UPDATE SET credential_hash=excluded.credential_hash,enabled=1',(ident,hashlib.sha256(credential.encode()).hexdigest()))
        return credential

    def revoke_instance(self, ident):
        with self.db: self.db.execute('UPDATE instances SET enabled=0 WHERE id=?',(ident,))

    def authorize(self, request):
        token=request.headers.get('Authorization','').removeprefix('Bearer ')
        row=self.db.execute('SELECT id FROM instances WHERE credential_hash=? AND enabled=1',(hashlib.sha256(token.encode()).hexdigest(),)).fetchone()
        if not row: raise web.HTTPUnauthorized()
        return row[0]

    async def handle(self, request):
        instance=self.authorize(request)
        try:
            if request.path=='/v1/status' and request.method=='GET':
                return web.json_response(dict(configured=self.provider.ready,instance_id=instance,topic=self.provider.topic,environment=self.provider.environment))
            if request.path.startswith('/v1/devices/'):
                ident=request.match_info['device']; uuid.UUID(ident)
                value=await request.json(); revision=value.get('revision')
                if type(revision) is not int or revision<1: raise ValueError('Invalid revision')
                old=self.db.execute('SELECT * FROM devices WHERE instance=? AND id=?',(instance,ident)).fetchone()
                if old and old['revision']>revision: return web.json_response({'state':'invalid_device'})
                if request.method=='DELETE':
                    if set(value)!={'revision'}: raise ValueError('Invalid revoke')
                    with self.db:
                        self.db.execute('INSERT INTO devices VALUES(?,?,\'\',?,0,0) ON CONFLICT(instance,id) DO UPDATE SET enabled=0,revision=excluded.revision',(instance,ident,revision))
                        self.db.execute("UPDATE deliveries SET state='disabled',result=? WHERE instance=? AND device=? AND state!='accepted'",(json.dumps({'state':'disabled'}),instance,ident))
                    return web.json_response({'state':'accepted'})
                if request.method!='PUT': raise web.HTTPNotFound()
                if set(value)!={'token','revision','topic','environment','registered_at'} or value['topic']!=self.provider.topic or value['environment']!=self.provider.environment:
                    raise ValueError('Invalid device registration')
                if not isinstance(value['token'],str) or not re.fullmatch(r'[0-9a-f]{32,512}',value['token']): raise ValueError('Invalid token')
                if not isinstance(value['registered_at'],(int,float)) or not 0<value['registered_at']<=time.time()+300: raise ValueError('Invalid registration time')
                if old and old['revision']==revision:
                    if not old['enabled'] or old['token']!=value['token']: return web.json_response({'state':'invalid_device'})
                    return web.json_response({'state':'accepted'})
                with self.db: self.db.execute('INSERT INTO devices VALUES(?,?,?,?,?,1) ON CONFLICT(instance,id) DO UPDATE SET token=excluded.token,revision=excluded.revision,registered_at=excluded.registered_at,enabled=1',
                    (instance,ident,value['token'],revision,value['registered_at']))
                return web.json_response({'state':'accepted'})
            if request.path=='/v1/notifications' and request.method=='POST':
                value=await request.json()
                return web.json_response(await self.notify(instance,value))
            raise web.HTTPNotFound()
        except (ValueError,KeyError,TypeError): return web.json_response({'error':'invalid_request'},status=400)

    async def notify(self, instance, value):
        if set(value)!={'device_id','revision','payload'}: raise ValueError('Invalid notification')
        ident=value['device_id']; uuid.UUID(ident)
        if type(value['revision']) is not int or value['revision']<1: raise ValueError('Invalid revision')
        payload=value['payload']
        required={'v','kind','instance_id','assistant_id','conversation_id','run_id','delivery_id'}
        optional={'message_id','control_id','execution_generation'}
        if not isinstance(payload,dict) or not required<=set(payload) or set(payload)-required-optional or payload['v']!=1 or payload['instance_id']!=instance or payload['kind'] not in COPY:
            raise ValueError('Invalid payload')
        if any(not opaque(payload[k]) for k in set(payload)-{'v','execution_generation'}): raise ValueError('Invalid locator')
        if 'execution_generation' in payload and (type(payload['execution_generation']) is not int or payload['execution_generation']<1): raise ValueError('Invalid generation')
        if payload['kind']=='final' and not payload.get('message_id'): raise ValueError('Missing message locator')
        if payload['kind']=='needs_input' and not (payload.get('control_id') and payload.get('execution_generation')): raise ValueError('Missing control locator')
        uuid.UUID(payload['delivery_id']); uuid.UUID(payload['assistant_id'])
        fingerprint=hashlib.sha256(json.dumps({'device_id':ident,'payload':payload},sort_keys=True,separators=(',',':')).encode()).hexdigest()
        lock=self.locks.setdefault((instance,payload['delivery_id']),asyncio.Lock())
        async with lock:
            old=self.db.execute('SELECT * FROM deliveries WHERE instance=? AND id=?',(instance,payload['delivery_id'])).fetchone()
            if old and old['payload_hash']!=fingerprint: raise web.HTTPConflict()
            if old and old['state']!='retry': return json.loads(old['result'])
            device=self.db.execute('SELECT * FROM devices WHERE instance=? AND id=? AND enabled=1',(instance,ident)).fetchone()
            if not device or device['revision']!=value['revision']: return {'state':'invalid_device'}
            if not self.db.execute('SELECT 1 FROM instances WHERE id=? AND enabled=1',(instance,)).fetchone(): return {'state':'disabled'}
            now=time.time(); window,count=self.rate.get(instance,(now,0))
            if now-window>=60: window,count=now,0
            if count>=60: return {'state':'retry','retry_after':60}
            self.rate[instance]=(window,count+1)
            try: result=await asyncio.wait_for(self.provider.send(dict(device),payload),12)
            except Exception: result={'state':'retry','retry_after':60}
            state=result.get('state','retry')
            with self.db:
                current=self.db.execute('SELECT * FROM devices WHERE instance=? AND id=?',(instance,ident)).fetchone()
                if not current or not current['enabled']:
                    result={'state':'disabled'}; state='disabled'
                elif current['revision']!=device['revision'] and state!='accepted':
                    result={'state':'retry','retry_after':1}; state='retry'
                if state=='invalid_device':
                    timestamp=result.get('invalid_at')
                    # Apple timestamps are milliseconds. A later registration wins over a stale rejection.
                    if timestamp is None or timestamp/1000>=device['registered_at']:
                        self.db.execute('UPDATE devices SET enabled=0 WHERE instance=? AND id=? AND revision=?',(instance,ident,device['revision']))
                    else: result={'state':'retry','retry_after':60}; state='retry'
                self.db.execute('INSERT INTO deliveries VALUES(?,?,?,?,?,?,?) ON CONFLICT(instance,id) DO UPDATE SET state=excluded.state,result=excluded.result',
                    (instance,payload['delivery_id'],ident,fingerprint,state,json.dumps(result),now))
            return result

    def app(self):
        app=web.Application(client_max_size=4096)
        app.router.add_get('/v1/status',self.handle)
        app.router.add_route('*','/v1/devices/{device}',self.handle)
        app.router.add_post('/v1/notifications',self.handle)
        async def close(_): await self.provider.close(); self.db.close()
        app.on_cleanup.append(close)
        return app


def main():
    parser=argparse.ArgumentParser(); parser.add_argument('--config',required=True); parser.add_argument('--check',action='store_true')
    parser.add_argument('--issue-instance'); parser.add_argument('--revoke-instance')
    args=parser.parse_args(); configuration=private_json(args.config); provider=APNs(configuration)
    gateway=Gateway(configuration['database'],provider)
    if args.check:
        print(json.dumps({'configured':provider.ready,'topic':provider.topic,'environment':provider.environment,'apple_delivery_verified':False})); return
    if args.issue_instance:
        # Operational stdout only: redirect directly to a private file, never application logs.
        print(gateway.add_instance(args.issue_instance)); return
    if args.revoke_instance: gateway.revoke_instance(args.revoke_instance); return
    web.run_app(gateway.app(),host='127.0.0.1',port=configuration.get('port',8870),access_log=None,print=None)

if __name__=='__main__': main()
