"""Product journal and projection boundaries using a real native SessionDB."""
import asyncio
import hashlib
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
import uuid
from unittest.mock import AsyncMock, patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'Tests/AgentRuntime/fixtures/legacy_gateway'))
sys.path.insert(0, str(ROOT / 'Apps/MacApp/Runtime'))
sys.path.insert(0, str(ROOT / 'Vendor/HermesAgent'))
from personal_agent import ProductStore, PersonalAgent
from hermes_state import SessionDB
from aiohttp import web


class PersonalAgentTests(unittest.IsolatedAsyncioTestCase):
    async def test_real_interim_callback_tools_and_native_final_share_one_durable_stream(self):
        from hermes_state_runtime import begin_runtime_epoch, admit_session_input
        db = SessionDB(db_path=Path(self.temp.name) / 'state.db')
        try:
            epoch = begin_runtime_epoch(db, instance_id='live-interim-final')
            root = self.store.identity['root']; db.create_session(root, source='api_server')
            run = 'run-real-interim-final'
            with self.store.db:
                self.store.db.execute('INSERT INTO inputs(operation_id,content,run_id,owner_scope,work_id) VALUES(?,?,?,?,?)',
                                     (str(uuid.uuid4()), 'check', run, 'scope', root))
            admission = admit_session_input(db, epoch=epoch, principal_id='api', session_id=root, request_id=run, payload={'text':'check'})
            db.append_message(root, role='user', content='check', platform_message_id=admission['admission_id'])
            product = PersonalAgent.__new__(PersonalAgent); product.store = self.store; product.observers = {}
            product.adapter = SimpleNamespace(_run_streams={}, _run_streams_created={})
            product.authority = lambda: SimpleNamespace(db=db)
            async def observe(admitted, **callbacks):
                await asyncio.to_thread(callbacks['interim_assistant_callback'], 'I will check')
                self.assertEqual(['I will check'], [m['content'] for m in self.store.page()['data']])
                db.append_message(root, role='assistant', content=None, tool_calls=[{'id':'call','type':'function','function':{'name':'terminal','arguments':'{}'}}])
                db.append_message(root, role='tool', content='verified fact', tool_call_id='call')
                await asyncio.to_thread(callbacks['stream_delta_callback'], 'Verified')
                db.append_message(root, role='assistant', content='Verified result')
                return {'final_response':'Verified result','completed':True}, {}
            with patch('gateway.session_api_turn.observe_api_turn', side_effect=observe) as native:
                product.observe((None, None, admission))
                await product.observers[admission['admission_id']]
                native.assert_awaited_once()
            rows = self.store.page()['data']
            self.assertEqual(['I will check','Verified result'], [m['content'] for m in rows])
            _, replay = product.adapter._run_streams[run].attach()
            events = [event for _, event in replay if event is not None]
            self.assertEqual('run.completed', events[-1]['event'])
            self.assertEqual(rows[-1]['id'], events[-2]['message']['id'])
            await product.project_session(root)
            self.assertEqual(rows, self.store.page()['data'])
        finally: db.close()

    async def test_shared_turn_replays_first_text_before_completion_without_second_execution(self):
        product = PersonalAgent.__new__(PersonalAgent)
        product.store = self.store; product.observers = {}
        product.adapter = SimpleNamespace(_run_streams={}, _run_streams_created={})
        row = dict(admission_id='admission', request_id='run-shared', status='started', target_session_id='work')
        product.project_session = AsyncMock(side_effect=lambda _: self.store.append_assistant('turn:admission:0', '真实首字完整回复', 1, 'run-shared'))
        produced = asyncio.Event(); finish = asyncio.Event()
        async def observe(admitted, **callbacks):
            await asyncio.to_thread(callbacks['stream_delta_callback'], '真实首字')
            produced.set()
            await finish.wait()
            return {'final_response': '真实首字完整回复', 'completed': True}, {}
        with patch('gateway.session_api_turn.observe_api_turn', side_effect=observe) as native:
            product.observe((None, None, row)); product.observe((None, None, row))
            worker = product.observers['admission']
            await asyncio.wait_for(produced.wait(), 5)
            stream = product.adapter._run_streams['run-shared']
            queue, replay = stream.attach()
            self.assertEqual([event['delta'] for _, event in replay], ['真实首字'])
            self.assertFalse(stream.terminal)
            finish.set(); await worker
            _, committed = await asyncio.wait_for(queue.get(), 5)
            self.assertEqual(committed['event'], 'message.committed')
            self.assertEqual(committed['message']['content'], '真实首字完整回复')
            self.assertEqual(committed['message']['id'], self.store.page()['data'][0]['id'])
            _, terminal = await asyncio.wait_for(queue.get(), 5)
            self.assertEqual(terminal['event'], 'run.completed')
            self.assertEqual(native.call_count, 1)
            _, suffix = stream.attach(replay[-1][0])
            self.assertEqual([e['event'] for _, e in suffix if e], ['message.committed', 'run.completed'])
            self.assertTrue(stream.terminal)

    def setUp(self):
        # Native bootstrap can adopt its own venv; do not leak that import path
        # into Access tests sharing this Python process.
        import_path = sys.path.copy()
        self.addCleanup(lambda: sys.path.__setitem__(slice(None), import_path))
        self.temp = tempfile.TemporaryDirectory()
        self.connection = {'assistant_id': str(uuid.uuid4()),'instance_id': str(uuid.uuid4())}
        self.store = ProductStore(Path(self.temp.name) / 'conversation.db', self.connection)

    def tearDown(self):
        self.store.db.close(); self.temp.cleanup()

    def test_full_pagination_stable_ids_idempotency_and_conflicting_retry(self):
        for i in range(205):
            operation = str(uuid.uuid4())
            self.store.accept(operation, str(i), 'scope')
            self.store.accept(operation, str(i), 'scope')
        rows = []; cursor = 0
        while True:
            page = self.store.page(cursor, limit=23); rows += page['data']; cursor = page['next_cursor']
            if not page['has_more']: break
        self.assertEqual(205,len(rows)); self.assertEqual(205,len({r['id'] for r in rows}))
        self.assertEqual(list(range(1,206)),[r['seq'] for r in rows])
        with self.assertRaises(web.HTTPConflict): self.store.accept(operation,'different','scope')
        self.assertEqual(list(range(191,201)),[r['seq'] for r in self.store.page(before=201,limit=10)['data']])

    def test_interim_projection_does_not_create_notification_events(self):
        self.store.append_assistant('native:1','hello',1)
        self.assertEqual(0,self.store.db.execute('SELECT count(*) FROM notifications').fetchone()[0])

    async def test_handoff_uses_real_receipts_not_tool_intent(self):
        db = SessionDB(db_path=Path(self.temp.name) / 'state.db')
        try:
            root=self.store.identity['root']; db.create_session(root,source='api_server')
            product=PersonalAgent.__new__(PersonalAgent); product.store=self.store
            product.authority=lambda: SimpleNamespace(db=db)
            for index,(receipt,expected) in enumerate([
                ({'error':'User denied','notify_on_complete':True},False),
                ({'error':'Spawn failed','session_id':'proc_fail','notify_on_complete':True},False),
                ({'output':'Background process started','session_id':'proc_actual','pid':42,'exit_code':0,'error':None,'notify_on_complete':True},True),
                ({'status':'yielded_to_background','session_id':'proc_auto','notify_on_complete':True},True),
                ({'output':'foreground result','exit_code':0},False)]):
                admission='turn-'+str(index)
                db.append_message(root,role='user',content='do synthetic work',platform_message_id=admission)
                db.append_message(root,role='assistant',content='I will handle it',tool_calls=[{'id':'call-'+str(index),'type':'function','function':{'name':'terminal','arguments':'{"background": true}'}}])
                import json
                db.append_message(root,role='tool',content=json.dumps(receipt),tool_call_id='call-'+str(index))
                self.assertEqual(expected,product.turn_handed_off({'admission_id':admission,'target_session_id':root}))
        finally: db.close()

    async def test_interim_does_not_consume_final_native_answer_or_duplicate_on_recovery(self):
        from hermes_state_runtime import begin_runtime_epoch, admit_session_input
        db = SessionDB(db_path=Path(self.temp.name) / 'state.db')
        try:
            epoch = begin_runtime_epoch(db, instance_id='interim-final')
            root = self.store.identity['root']; db.create_session(root, source='api_server')
            run = 'run-interim-final'
            with self.store.db:
                self.store.db.execute('INSERT INTO inputs(operation_id,content,run_id,owner_scope,work_id) VALUES(?,?,?,?,?)',
                                     (str(uuid.uuid4()), 'check', run, 'scope', root))
            admission = admit_session_input(db, epoch=epoch, principal_id='api', session_id=root, request_id=run,
                                            payload={'text': 'check'})['admission_id']
            db.append_message(root, role='user', content='check', platform_message_id=admission)
            # Real Codex path: the callback acknowledgement is not in SessionDB;
            # only the final answer is persisted after the tool loop finishes.
            ack = self.store.append_assistant(f'turn:{admission}:0', 'I will check', 1, run)
            db.append_message(root, role='assistant', content='Verified result after tools')
            product = PersonalAgent.__new__(PersonalAgent); product.store = self.store
            product.authority = lambda: SimpleNamespace(db=db)
            await product.project(); await product.project()
            messages = self.store.page()['data']
            self.assertEqual(['I will check', 'Verified result after tools'], [m['content'] for m in messages])
            self.assertEqual(ack, messages[0]['id'])
            self.assertNotEqual(ack, messages[1]['id'])
            self.store.db.close(); self.store = ProductStore(Path(self.temp.name) / 'conversation.db', self.connection)
            product.store = self.store
            await product.project()
            self.assertEqual(messages, self.store.page()['data'])
        finally: db.close()

    def test_native_interim_reuses_visible_message_but_distinct_occurrences_survive(self):
        first = self.store.append_assistant('interim:admission:0', 'Checking', 1, 'run')
        second = self.store.append_assistant('interim:admission:1', 'Checking', 2, 'run')
        self.assertEqual(first, self.store.project_assistant('admission', 0, 'Checking', 1, 'run'))
        self.assertEqual(second, self.store.project_assistant('admission', 1, 'Checking', 2, 'run'))
        final = self.store.project_assistant('admission', 2, 'Done', 3, 'run')
        self.assertEqual(final, self.store.project_assistant('admission', 2, 'Done', 3, 'run'))
        self.assertEqual(['Checking', 'Checking', 'Done'], [m['content'] for m in self.store.page()['data']])

    async def test_native_compaction_lineage_keeps_same_text_occurrences_and_source_ids(self):
        db = SessionDB(db_path=Path(self.temp.name) / 'state.db')
        try:
            from hermes_state_runtime import begin_runtime_epoch, admit_session_input
            epoch = begin_runtime_epoch(db, instance_id='projection')
            root = self.store.identity['root']; db.create_session(root,source='api_server')
            def own_turn(text):
                run='run-'+str(uuid.uuid4())
                with self.store.db:
                    self.store.db.execute('INSERT INTO inputs(operation_id,content,run_id,owner_scope,work_id) VALUES(?,?,?,?,?)',(str(uuid.uuid4()),text,run,'scope',root))
                return admit_session_input(db,epoch=epoch,principal_id='api',session_id=root,request_id=run,payload={'text':text})['admission_id']
            first=own_turn('first')
            db.append_message(root,role='user',content='first',platform_message_id=first)
            db.append_message(root,role='assistant',content='same answer')
            db.end_session(root,'compression')
            db.create_session('tip',source='api_server',parent_session_id=root)
            second=own_turn('second')
            db.append_message('tip',role='user',content='second',platform_message_id=second)
            db.append_message('tip',role='assistant',content='same answer')
            product = PersonalAgent.__new__(PersonalAgent); product.store = self.store
            product.authority = lambda: SimpleNamespace(db=db)
            await product.project(); await product.project()
            rows = self.store.page()['data']
            self.assertEqual(2,len(rows)); self.assertNotEqual(rows[0]['id'],rows[1]['id'])
            self.assertEqual([f'native-turn:{first}:0',f'native-turn:{second}:0'],[r['source_key'] for r in rows])
        finally: db.close()

    async def test_upgrade_adopted_legacy_is_not_reprojected_but_owned_completion_is(self):
        from hermes_state_runtime import begin_runtime_epoch, admit_session_input
        db = SessionDB(db_path=Path(self.temp.name) / 'state.db')
        try:
            epoch=begin_runtime_epoch(db,instance_id='upgrade')
            scope=hashlib.sha256(b'default\0fixture-key').hexdigest()
            old='momo-'+str(uuid.uuid4()); db.create_session(old,source='api_server')
            legacy=admit_session_input(db,epoch=epoch,principal_id='api',session_id=old,request_id='old-phone-request',payload={'text':'old question','api_turn_v1':{'run_owner_scope':scope}})
            db.append_message(old,role='assistant',content='unbound inherited context')
            db.append_message(old,role='user',content='old question',platform_message_id=legacy['admission_id'])
            db.append_message(old,role='assistant',content='old reply')
            # Upgrade adoption registers execution ownership, not a new message source.
            with self.store.db:
                self.store.db.execute('INSERT INTO legacy_sessions VALUES(?)',(old,))
                self.store.db.execute('INSERT INTO works(id,native_root,title,created_at,context_through_seq,context_json) VALUES(?,?,?,1,0,?)',(old,old,'old work','[]'))
            product=PersonalAgent.__new__(PersonalAgent); product.store=self.store
            product.adapter=SimpleNamespace(_expected_api_key=lambda:'fixture-key')
            product.authority=lambda:SimpleNamespace(db=db,profile_id=self.temp.name)
            await product.project_legacy()
            before=self.store.page()['data']; self.assertEqual(['old question','old reply'],[r['content'] for r in before])
            await product.project(); await product.project_legacy(); await product.project()
            self.assertEqual(before,self.store.page()['data'])
            completion=admit_session_input(db,epoch=epoch,principal_id='momo-completion',session_id=old,request_id='owned-completion',payload={'text':'saved native result'})
            with self.store.db:
                self.store.db.execute("INSERT INTO completions(event_key,owner,event_json,source_message_id,prompt,state,created_at,admission_id) VALUES('event',?,'{}',0,'saved result','admitted',2,?)",(old,completion['admission_id']))
            db.append_message(old,role='user',content='saved native result',platform_message_id=completion['admission_id'],display_kind='hidden')
            db.append_message(old,role='assistant',content='completion from old phone task')
            # This unbound history is not another assistant message from the completion.
            db.append_message(old,role='user',content='inherited user context')
            db.append_message(old,role='assistant',content='inherited assistant context')
            foreign=admit_session_input(db,epoch=epoch,principal_id='momo-completion',session_id=old,request_id='unowned-completion',payload={'text':'unregistered event'})
            db.append_message(old,role='user',content='unregistered event',platform_message_id=foreign['admission_id'])
            db.append_message(old,role='assistant',content='unowned completion context')
            await product.project_legacy(); await product.project()
            after=self.store.page()['data']
            self.assertEqual(['old question','old reply','completion from old phone task'],[r['content'] for r in after])
            self.assertEqual(f"native-turn:{completion['admission_id']}:0",after[-1]['source_key'])
            self.assertEqual('owned-completion',after[-1]['run_id']); self.assertIsNone(after[-1]['source_session'])
            # A restart must retain the same message IDs/cursor, not import history again.
            self.store.db.close(); self.store=ProductStore(Path(self.temp.name)/'conversation.db',self.connection);product.store=self.store
            await product.project_legacy();await product.project()
            self.assertEqual(after,self.store.page()['data'])
        finally: db.close()

    async def test_unknown_receipt_without_native_claim_never_materializes_or_readmits(self):
        db = SessionDB(db_path=Path(self.temp.name) / 'state.db')
        try:
            with self.store.db:
                self.store.db.execute("INSERT INTO completions(event_key,owner,event_json,source_message_id,prompt,state,created_at) VALUES('unknown-event',?,'{}',0,'','unknown',1)", (self.store.identity['root'],))
            product = PersonalAgent.__new__(PersonalAgent); product.store = self.store
            product.authority = lambda: SimpleNamespace(db=db)
            product.materialize = AsyncMock()
            with patch('gateway.session_api_completion.admit_api_completion', new_callable=AsyncMock) as admit:
                await product.reconcile_completions(); await product.reconcile_completions()
                admit.assert_not_awaited(); product.materialize.assert_not_awaited()
            self.assertEqual('unknown', self.store.db.execute('SELECT state FROM completions').fetchone()[0])
        finally: db.close()

    async def test_legacy_phone_and_mac_history_imports_once_without_replaying_or_notifying(self):
        db = SessionDB(db_path=Path(self.temp.name) / 'state.db')
        try:
            from hermes_state_runtime import begin_runtime_epoch, admit_session_input, get_session_admission
            epoch = begin_runtime_epoch(db, instance_id='test')
            scope = hashlib.sha256(b'default\0fixture-key').hexdigest()
            product = PersonalAgent.__new__(PersonalAgent); product.store = self.store
            product.adapter = SimpleNamespace(_expected_api_key=lambda: 'fixture-key')
            product.authority = lambda: SimpleNamespace(db=db, profile_id=self.temp.name)
            def message(sid, text, owner=scope, source='api_server'):
                db.create_session(sid, source=source)
                admission = admit_session_input(db, epoch=epoch, principal_id='api', session_id=sid,
                    request_id='run-' + sid, payload={'text': text, 'api_turn_v1': {'run_owner_scope': owner}})
                db.append_message(sid, role='user', content=text, platform_message_id=admission['admission_id'])
                db.append_message(sid, role='assistant', content='reply ' + text)
                return admission
            phone = 'momo-' + str(uuid.uuid4()); mac = 'momo-' + str(uuid.uuid4())
            a = message(phone,'from phone'); message(mac,'from Mac')
            message('momo-' + str(uuid.uuid4()), 'other owner', owner='foreign-scope')
            message('momo-transcript-' + str(uuid.uuid4()), 'recording')
            message('momo-' + str(uuid.uuid4()), 'not API', source='cli')
            operation = str(uuid.uuid4()); self.store.accept(operation, 'new shared message', scope)
            await product.project_legacy(); await product.project_legacy()
            rows = self.store.page()['data']
            self.assertEqual(['new shared message','from phone','reply from phone','from Mac','reply from Mac'], [r['content'] for r in rows])
            self.assertEqual({phone,mac}, {r['source_session'] for r in rows[1:]})
            cursor = rows[-1]['seq']
            db.append_message(phone, role='assistant', content='late phone result')
            await product.project_legacy()
            self.assertEqual(['late phone result'], [r['content'] for r in self.store.page(after=cursor)['data']])
            self.assertEqual('queued', get_session_admission(db, admission_id=a['admission_id'])['status'])
            self.assertEqual(0, self.store.db.execute('SELECT count(*) FROM notifications').fetchone()[0])
            self.assertEqual(0, self.store.db.execute('SELECT count(*) FROM legacy_sessions').fetchone()[0])
            self.assertEqual(1, self.store.db.execute('SELECT count(*) FROM inputs').fetchone()[0])
        finally: db.close()

    async def test_settled_work_projection_skips_idle_rescan_until_new_activity(self):
        from hermes_state_runtime import begin_runtime_epoch, admit_session_input, claim_session_input, settle_session_input
        db = SessionDB(db_path=Path(self.temp.name) / 'state.db')
        try:
            epoch = begin_runtime_epoch(db, instance_id='settled-test')
            scope = hashlib.sha256(b'default\0fixture-key').hexdigest()
            accepted = self.store.accept(str(uuid.uuid4()), 'hello', scope)
            root = self.store.db.execute('SELECT native_root FROM works WHERE id=?', (accepted['work_id'],)).fetchone()[0]
            db.create_session(root, source='api_server')
            adm = admit_session_input(db, epoch=epoch, principal_id='api', session_id=root, request_id=accepted['run_id'], payload={'text': 'hello', 'api_turn_v1': {'history': None, 'settings': {}}})
            claimed = claim_session_input(db, epoch=epoch, session_id=root)
            db.append_message(root, role='user', content='hello', platform_message_id=adm['admission_id'])
            db.append_message(root, role='assistant', content='world')
            settle_session_input(db, epoch=epoch, admission_id=adm['admission_id'], generation=claimed['generation'], outcome='completed')
            product = PersonalAgent.__new__(PersonalAgent); product.store = self.store
            product.adapter = SimpleNamespace(_expected_api_key=lambda: 'fixture-key')
            product.authority = lambda: SimpleNamespace(db=db, profile_id=self.temp.name)
            await product.project()
            self.assertEqual(['hello', 'world'], [r['content'] for r in self.store.page()['data']])
            with patch.object(db, 'get_messages', wraps=db.get_messages) as spy:
                await product.project()
                spy.assert_not_called()
        finally: db.close()

if __name__ == '__main__': unittest.main()
