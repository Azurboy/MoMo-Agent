"""Device-scoped notification outbox. No Agent work or network runs in its transactions."""
import asyncio
import hashlib
import json
from pathlib import Path
import re
import sqlite3
import time
import uuid
from urllib.parse import urlsplit

from aiohttp import ClientSession, ClientTimeout, web

TOPIC = 'com.momoagent.ios.beta'
TOPICS = frozenset((TOPIC, 'com.momoagent.ios'))
KINDS = {'final', 'failed', 'needs_input'}


class GatewayProvider:
    def __init__(self, configuration, instance_id):
        self.url = configuration['url'].rstrip('/')
        url = urlsplit(self.url)
        if (url.scheme != 'https' and not (url.scheme == 'http' and url.hostname in ('127.0.0.1', 'localhost'))) or url.username or url.password or url.path not in ('', '/') or url.query or url.fragment:
            raise ValueError('Invalid notification gateway endpoint')
        self.credential = configuration['credential']
        if not isinstance(self.credential, str) or not re.fullmatch(r'[A-Za-z0-9_-]{40,160}', self.credential):
            raise ValueError('Invalid notification instance credential')
        self.environment = configuration['environment']
        self.topic = configuration.get('topic', TOPIC)
        if self.topic not in TOPICS: raise ValueError('Invalid push topic')
        if self.environment not in ('development', 'production'): raise ValueError('Invalid push environment')
        self.instance_id = instance_id
        self.ready = False

    async def request(self, method, path, body=None):
        async with ClientSession(timeout=ClientTimeout(total=12), trust_env=True) as session:
            async with session.request(method, self.url + path, json=body,
                    headers={'Authorization': 'Bearer ' + self.credential}, allow_redirects=False) as response:
                if response.status == 429 or response.status >= 500:
                    return {'state': 'retry', 'retry_after': min(3600, max(1, int(response.headers.get('Retry-After', '30'))))}
                if response.status in (401,403): self.ready = False; return {'state':'disabled'}
                if response.status not in (200,201): return {'state':'disabled'}
                return await response.json()

    async def check(self):
        value = await self.request('GET', '/v1/status')
        self.ready = (value.get('configured') is True and value.get('instance_id') == self.instance_id and
            value.get('topic') == self.topic and value.get('environment') == self.environment)
        return self.ready

    async def register(self, device):
        return await self.request('PUT', '/v1/devices/' + device['device_id'],
            {k: device[k] for k in ('token','revision','topic','environment','registered_at')})

    async def revoke(self, device):
        return await self.request('DELETE', '/v1/devices/' + device['device_id'], {'revision': device['revision']})

    async def send(self, delivery):
        return await self.request('POST', '/v1/notifications', delivery)


def load_provider(data, connection):
    path = Path(data) / 'push-gateway.json'
    if not path.exists(): return None
    if path.is_symlink() or path.stat().st_mode & 0o077: raise ValueError('push-gateway.json must be private (0600)')
    value = json.loads(path.read_text())
    if not {'url','credential','environment'} <= set(value) or set(value)-{'url','credential','environment','topic'}: raise ValueError('Invalid notification gateway configuration')
    return GatewayProvider(value, connection['instance_id'])


class PushOutbox:
    def __init__(self, store, connection, pairing_path, provider=None, now=time.time):
        self.store = store; self.db = store.db; self.connection = connection
        self.pairing_path = Path(pairing_path); self.provider = provider; self.now = now
        self.next_check = 0
        self.db.executescript('''
        CREATE TABLE IF NOT EXISTS push_seen(device TEXT NOT NULL,event_key TEXT NOT NULL,PRIMARY KEY(device,event_key));
        CREATE TABLE IF NOT EXISTS push_meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS push_devices(device_id TEXT PRIMARY KEY, token TEXT NOT NULL,
          topic TEXT NOT NULL, environment TEXT NOT NULL, revision INTEGER NOT NULL, registered_at REAL NOT NULL,
          registration_id TEXT NOT NULL, enabled INTEGER NOT NULL, gateway_state TEXT NOT NULL, attempts INTEGER NOT NULL DEFAULT 0, next_attempt REAL NOT NULL DEFAULT 0);
        CREATE TABLE IF NOT EXISTS push_events(event_key TEXT PRIMARY KEY, kind TEXT NOT NULL, payload TEXT NOT NULL,
          message_seq INTEGER, created_at REAL NOT NULL, expires REAL NOT NULL, active INTEGER NOT NULL DEFAULT 1);
        CREATE TABLE IF NOT EXISTS notification_deliveries(delivery_id TEXT PRIMARY KEY, event_key TEXT NOT NULL,
          device_id TEXT NOT NULL, token_revision INTEGER NOT NULL, state TEXT NOT NULL, attempts INTEGER NOT NULL DEFAULT 0,
          next_attempt REAL NOT NULL DEFAULT 0, last_reason TEXT, UNIQUE(event_key,device_id));
        ''')

    def paired(self, ident):
        if not self.pairing_path.exists(): return False
        try:
            with sqlite3.connect(self.pairing_path.as_uri() + '?mode=ro', uri=True) as db:
                return db.execute("SELECT 1 FROM devices WHERE id=? AND state='approved'", (ident,)).fetchone() is not None
        except sqlite3.Error: return False

    def status(self, device):
        row = self.db.execute('SELECT * FROM push_devices WHERE device_id=?', (device,)).fetchone()
        return dict(configured=bool(self.provider and self.provider.ready),
            registered=bool(row and row['enabled'] and row['gateway_state']=='registered'),
            enabled=bool(row and row['enabled']), topic=self.provider.topic if self.provider else (row['topic'] if row else TOPIC),
            environment=self.provider.environment if self.provider else None)

    def register(self, device, value):
        if not self.paired(device): raise web.HTTPForbidden()
        if set(value) != {'token','topic','environment','registration_id'} or value['topic'] not in TOPICS or value['environment'] not in ('development','production'):
            raise ValueError('Invalid push registration')
        if self.provider and value['environment'] != self.provider.environment: raise ValueError('Push signing environment mismatch')
        if self.provider and value['topic'] != self.provider.topic: raise ValueError('Push topic mismatch')
        uuid.UUID(value['registration_id'])
        token = value['token']
        if not isinstance(token,str) or not re.fullmatch(r'[0-9a-f]{32,512}', token): raise ValueError('Invalid device token')
        old = self.db.execute('SELECT * FROM push_devices WHERE device_id=?',(device,)).fetchone()
        # Re-uploading the current APNs token is idempotent; rotation never inherits a stale 410.
        if old and old['enabled'] and all(old[k] == value[k] for k in ('token','topic','environment','registration_id')): return self.status(device)
        revision = (old['revision'] + 1) if old else 1
        with self.db:
            self.db.execute('''INSERT INTO push_devices(device_id,token,topic,environment,revision,registered_at,registration_id,enabled,gateway_state)
              VALUES(?,?,?,?,?,?,?,1,'pending') ON CONFLICT(device_id) DO UPDATE SET token=excluded.token,
              topic=excluded.topic,environment=excluded.environment,revision=excluded.revision,
              registered_at=excluded.registered_at,registration_id=excluded.registration_id,enabled=1,gateway_state='pending',attempts=0,next_attempt=0''',
              (device,token,value['topic'],value['environment'],revision,self.now(),value['registration_id']))
            self.db.execute("UPDATE notification_deliveries SET token_revision=? WHERE device_id=? AND state IN ('pending','retry')",(revision,device))
        return self.status(device)

    def revoke(self, device):
        with self.db:
            self.db.execute("UPDATE push_devices SET enabled=0,revision=revision+1,gateway_state='revoke_pending',next_attempt=0,attempts=0 WHERE device_id=? AND enabled=1",(device,))
            self.db.execute("UPDATE notification_deliveries SET state='disabled' WHERE device_id=? AND state IN ('pending','retry')",(device,))

    def briefing_alerts_enabled(self):
        preference = self.db.execute("SELECT value FROM push_meta WHERE key='briefing_alerts'").fetchone()
        return self.provider is not None and (preference is None or preference[0] != 'off')

    def emit(self, key, kind, *, run_id, message=None, control_id=None, generation=None, historical=False):
        if kind not in KINDS: raise ValueError('Invalid event kind')
        payload = dict(v=1,kind=kind,instance_id=self.connection['instance_id'],assistant_id=self.connection['assistant_id'],
            conversation_id=self.store.identity['id'],run_id=run_id)
        if message: payload['message_id'] = message['id']
        if control_id: payload.update(control_id=control_id,execution_generation=generation)
        now = self.now()
        with self.db:
            created = self.db.execute('INSERT OR IGNORE INTO push_events VALUES(?,?,?,?,?,?,?)',
                (key,kind,json.dumps(payload,sort_keys=True),message['seq'] if message else None,now,now+86400,0 if historical else 1)).rowcount
            if not created or historical: return
            for device in self.db.execute('SELECT * FROM push_devices WHERE enabled=1').fetchall():
                if not self.paired(device['device_id']): continue
                delivery = str(uuid.uuid5(uuid.NAMESPACE_URL, self.connection['instance_id'] + ':' + key + ':' + device['device_id']))
                state = 'pending' if self.provider else 'disabled'
                self.db.execute('INSERT OR IGNORE INTO notification_deliveries(delivery_id,event_key,device_id,token_revision,state) VALUES(?,?,?,?,?)',
                    (delivery,key,device['device_id'],device['revision'],state))

    def read(self, device, seq):
        with self.db:
            self.db.execute('INSERT INTO reads VALUES(?,?) ON CONFLICT(device) DO UPDATE SET through_seq=max(through_seq,excluded.through_seq)',(device,seq))

    def visible_controls(self, device, controls):
        # Visibility is a read receipt, never an approval or an execution input.
        if not isinstance(controls,list) or len(controls)>100: raise ValueError('Invalid controls')
        keys=[]
        for control in controls:
            if not isinstance(control,dict): raise ValueError('Invalid visible control')
            if set(control)=={'kind','run_id'} and control['kind']=='failed' and isinstance(control['run_id'],str):
                keys.append('failed:'+control['run_id'])
            elif set(control)=={'run_id','control_id','execution_generation'} and type(control['execution_generation']) is int:
                keys.append(f"control:{control['run_id']}:{control['execution_generation']}:{control['control_id']}")
            else: raise ValueError('Invalid visible control')
        if any(len(key)>600 for key in keys): raise ValueError('Invalid locator')
        with self.db:
            for key in keys:
                self.db.execute('INSERT OR IGNORE INTO push_seen VALUES(?,?)',(device,key))


    def suppress(self, delivery):
        event = self.db.execute('SELECT * FROM push_events WHERE event_key=?',(delivery['event_key'],)).fetchone()
        payload=json.loads(event['payload'])
        seen_key='failed:'+payload['run_id'] if event['kind']=='failed' else event['event_key']
        if self.db.execute('SELECT 1 FROM push_seen WHERE device=? AND event_key=?',(delivery['device_id'],seen_key)).fetchone(): return 'suppressed'
        if not event['active']: return 'suppressed'
        if event['expires'] <= self.now(): return 'expired'
        seen = self.db.execute('SELECT through_seq FROM reads WHERE device=?',(delivery['device_id'],)).fetchone()
        if event['message_seq'] is not None and seen and seen[0]>=event['message_seq']: return 'suppressed'
        return None

    async def tick(self):
        # Revocation is checked even when the gateway is unconfigured/offline.
        for device in self.db.execute('SELECT device_id FROM push_devices WHERE enabled=1').fetchall():
            if not self.paired(device[0]): self.revoke(device[0])
        if self.provider is None: return
        if self.now() >= self.next_check:
            self.next_check = self.now()+60
            try: await self.provider.check()
            except Exception: self.provider.ready = False
        if not self.provider.ready: return
        devices = self.db.execute("SELECT * FROM push_devices WHERE gateway_state IN ('pending','revoke_pending') AND next_attempt<=? LIMIT 8",(self.now(),)).fetchall()
        for saved in devices:
            device = dict(saved)
            try: result = await asyncio.wait_for(self.provider.register(device) if device['enabled'] else self.provider.revoke(device), 15)
            except Exception: result = {'state':'retry'}
            state = result.get('state')
            state = ('registered' if device['enabled'] else 'revoked') if state == 'accepted' else 'disabled' if state in ('disabled','invalid_device') else device['gateway_state']
            with self.db:
                self.db.execute('UPDATE push_devices SET gateway_state=?,attempts=attempts+1,next_attempt=? WHERE device_id=? AND revision=?',
                    (state,self.now()+max(min(3600,float(result.get('retry_after',0))),min(3600,2**min(10,device['attempts']+1))),device['device_id'],device['revision']))
        rows = self.db.execute("SELECT * FROM notification_deliveries WHERE state IN ('pending','retry') AND next_attempt<=? LIMIT 8",(self.now(),)).fetchall()
        for saved in rows:
            delivery = dict(saved); device = self.db.execute('SELECT * FROM push_devices WHERE device_id=?',(delivery['device_id'],)).fetchone()
            reason = self.suppress(delivery)
            if not device or not device['enabled'] or not self.paired(delivery['device_id']): reason = 'disabled'
            if reason:
                with self.db: self.db.execute('UPDATE notification_deliveries SET state=? WHERE delivery_id=?',(reason,delivery['delivery_id']))
                continue
            if device['gateway_state'] != 'registered': continue
            if device['revision'] != delivery['token_revision']:
                with self.db: self.db.execute('UPDATE notification_deliveries SET token_revision=? WHERE delivery_id=?',(device['revision'],delivery['delivery_id']))
                delivery['token_revision'] = device['revision']
            event = self.db.execute('SELECT payload FROM push_events WHERE event_key=?',(delivery['event_key'],)).fetchone()
            payload = json.loads(event[0]); payload['delivery_id'] = delivery['delivery_id']
            request = dict(device_id=delivery['device_id'],revision=delivery['token_revision'],payload=payload)
            try: result = await asyncio.wait_for(self.provider.send(request),15)
            except Exception: result = {'state':'retry'}
            state = result.get('state')
            if state not in ('accepted','invalid_device','disabled','retry'): state='retry'
            with self.db:
                # Local revoke/read/rotation during I/O wins over an old network response.
                current = self.db.execute('SELECT * FROM push_devices WHERE device_id=?',(delivery['device_id'],)).fetchone()
                if not current or current['revision'] != delivery['token_revision']: continue
                if not self.paired(delivery['device_id']): self.revoke(delivery['device_id']); continue
                self.db.execute("UPDATE notification_deliveries SET state=?,attempts=attempts+1,next_attempt=? WHERE delivery_id=? AND state IN ('pending','retry')",
                    ('invalid_token' if state=='invalid_device' else state,self.now()+max(min(3600,float(result.get('retry_after',0))),min(300,2**min(8,delivery['attempts']+1))),delivery['delivery_id']))
                if state == 'invalid_device':
                    self.db.execute("UPDATE push_devices SET enabled=0,gateway_state='invalid_token' WHERE device_id=? AND revision=?",(delivery['device_id'],delivery['token_revision']))

    async def run(self):
        while True:
            try: await self.tick()
            except asyncio.CancelledError: raise
            except Exception: pass  # Bounded retry; tokens/credentials are never logged.
            await asyncio.sleep(2)
