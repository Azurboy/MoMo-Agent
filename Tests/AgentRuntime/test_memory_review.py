import json
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest
import uuid
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT/'Apps/MacApp/Context'), str(ROOT/'Apps/MacApp/Runtime')]
from context_store import ContextStore, Conflict, digest
from context_server import ContextService
import memory_review as review


class MemoryReviewTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.data = Path(self.tmp.name)
        for name in ['hermes/memories', 'runtime']: (self.data/name).mkdir(parents=True)
        (self.data/'runtime/engine.json').write_text('{"engine":"hermes","proactive_mode":"auto"}\n')
        self.store = ContextStore(self.data/'context'); self.addCleanup(self.store.close)
        self.chat = sqlite3.connect(self.data/'runtime/conversation.sqlite'); self.addCleanup(self.chat.close)
        self.chat.executescript('CREATE TABLE messages(seq INTEGER PRIMARY KEY,role TEXT,content TEXT,created_at REAL,operation_id TEXT); CREATE TABLE inputs(operation_id TEXT,intent TEXT,delivery_state TEXT);')
        self.native = sqlite3.connect(self.data/'hermes/state.db'); self.addCleanup(self.native.close)
        self.native.executescript('CREATE TABLE messages(session_id TEXT,role TEXT,tool_name TEXT,content TEXT); CREATE TABLE session_admissions(target_session_id TEXT,status TEXT);')

    def message(self, seq, text, at=100, role='user', operation=None):
        self.chat.execute('INSERT INTO messages VALUES(?,?,?,?,?)',(seq,role,text,at,operation)); self.chat.commit()

    def write(self, session, success=True):
        self.native.execute('INSERT INTO messages VALUES(?,?,?,?)',(session,'tool','memory',json.dumps({'success':success})));self.native.commit()

    def source(self, text='有价值的讨论'):
        source = dict(library_id=str(uuid.uuid4()),session_id=str(uuid.uuid4()),device_id=str(uuid.uuid4()),generation=0,version=1,deleted=False,recorded_at=100,spans=[dict(id=str(uuid.uuid4()),text=text,recorded_at=100)],text_sha256=digest(text))
        return self.store.sync_source(source)

    def test_short_work_sessions_still_trigger_chat_after_quiet_period(self):
        self.message(1,'请记住，我喜欢先结论后说明。',at=100)
        self.assertFalse(review.chat_idle(self.data,159));self.assertTrue(review.chat_idle(self.data,160))
        job=review.next_review(self.store,self.data,160)
        self.assertEqual('chat',job['kind'])
        self.assertEqual([2,0],json.loads(job['input'])['cursor'])
        self.native.execute("INSERT INTO session_admissions VALUES('momo-work-live','queued')");self.native.commit()
        self.assertFalse(review.chat_idle(self.data,200))

    def test_long_unicode_chat_drains_exactly_and_restart_retains_cursor(self):
        text='偏好与背景' * 14000;self.message(1,text)
        recovered=[]
        while batch:=review.chat_batch(self.store,self.data):
            self.assertLessEqual(len(json.dumps(batch['messages'],ensure_ascii=False,separators=(',',':')).encode()),review.MAX_BYTES)
            recovered.extend(p['text'] for p in batch['messages'])
            job=review.enqueue(self.store,'chat',batch)
            review.finish(self.store,job,{'outcome':'no_change'},self.data/'hermes')
        self.assertEqual(text,''.join(recovered))
        other=ContextStore(self.data/'context')
        try:self.assertIsNone(review.chat_batch(other,self.data))
        finally:other.close()

    def test_rejected_steer_never_enters_memory_evidence(self):
        self.message(1,'not applied',operation='steer')
        self.chat.execute("INSERT INTO inputs VALUES('steer','steer','not_applied')");self.chat.commit()
        self.message(2,'real user preference')
        self.assertEqual([2],[p['seq'] for p in review.chat_batch(self.store,self.data)['messages']])

    def test_completion_claim_requires_native_write_and_explicit_noop_receipt(self):
        payload=json.dumps({'memory_review':{'outcome':'updated','reason':'已保存'}})
        with self.assertRaises(Conflict):review.outcome(self.data/'hermes','session',payload)
        self.write('other')
        with self.assertRaises(Conflict):review.outcome(self.data/'hermes','session',payload)
        self.write('session')
        self.assertEqual(1,review.outcome(self.data/'hermes','session',payload)['native_writes'])
        with self.assertRaises(Conflict):review.outcome(self.data/'hermes','session','已完成。')
        noop=json.dumps({'memory_review':{'outcome':'no_change','reason':'本批为噪声'}})
        self.assertEqual('no_change',review.outcome(self.data/'hermes','noise',noop)['outcome'])
        self.write('noise',False)
        with self.assertRaises(Conflict):review.outcome(self.data/'hermes','noise',noop)
        self.write('noise',True)
        self.assertEqual('updated',review.outcome(self.data/'hermes','noise',payload)['outcome'])

    def test_dream_is_change_driven_cooldown_and_restart_safe(self):
        self.assertIsNone(review.next_review(self.store,self.data,100))
        review.set_state(self.store,'chat_cursor',[2,0])
        job=review.next_review(self.store,self.data,100)
        self.assertEqual('dream',job['kind'])
        with patch.object(review.time,'time',return_value=100):review.finish(self.store,job,{'outcome':'no_change'},self.data/'hermes')
        self.assertIsNone(review.next_review(self.store,self.data,100+review.DREAM_INTERVAL))
        (self.data/'hermes/memories/USER.md').write_text('新增偏好')
        self.assertIsNone(review.next_review(self.store,self.data,101))
        self.assertEqual('dream',review.next_review(self.store,self.data,100+review.DREAM_INTERVAL)['kind'])

    def test_dream_does_not_acknowledge_sources_arriving_during_its_run(self):
        review.set_state(self.store,'chat_cursor',[2,0])
        job=review.next_review(self.store,self.data,100)
        self.source('during Dream')
        with patch.object(review.time,'time',return_value=100):review.finish(self.store,job,{'outcome':'no_change'},self.data/'hermes')
        next_job=review.next_review(self.store,self.data,100+review.DREAM_INTERVAL)
        self.assertEqual('dream',next_job['kind']);self.assertNotEqual(job['id'],next_job['id'])

    def test_terminal_retry_is_bounded_and_dream_does_not_replay_exhausted_job(self):
        review.set_state(self.store,'chat_cursor',[2,0])
        job=review.next_review(self.store,self.data,100)
        for attempt in (1,2):
            self.assertTrue(review.retry_completed(self.store,'memory_reviews',job,'invalid receipt'))
            job=review.next_review(self.store,self.data,100)
            self.assertEqual(attempt,job['attempt'])
        self.assertFalse(review.retry_completed(self.store,'memory_reviews',job,'invalid receipt'))
        self.store.db.execute("UPDATE memory_reviews SET state='needs_review' WHERE id=?",(job['id'],))
        self.assertIsNone(review.next_review(self.store,self.data,100))

    def test_due_dream_runs_despite_continuous_transcript_backlog(self):
        self.source()
        review.set_state(self.store,'chat_cursor',[2,0])
        review.set_state(self.store,'v2_migrated',True)
        service=ContextService.__new__(ContextService)
        service.data=self.data;service.directory=self.data/'context';service.next_dispatch=0
        from unittest.mock import Mock
        service.stopped=Mock();service.stopped.wait.side_effect=[False,True]
        service.advance_review=Mock();service.advance_job=Mock()
        service.dispatch()
        self.assertEqual('dream',service.advance_review.call_args.args[1]['kind'])
        service.advance_job.assert_not_called()

    def test_legacy_replay_only_once_and_never_resurrects_deleted_memories(self):
        self.source();self.store.db.execute("UPDATE jobs SET state='done'")
        review.recover_empty_legacy(self.store,self.data/'hermes')
        self.assertEqual(1,self.store.db.execute("SELECT count(*) FROM jobs WHERE state='legacy_reviewed'").fetchone()[0])
        self.assertEqual(1,self.store.db.execute("SELECT count(*) FROM jobs WHERE state='pending'").fetchone()[0])
        review.recover_empty_legacy(self.store,self.data/'hermes')
        self.assertEqual(2,self.store.db.execute('SELECT count(*) FROM jobs').fetchone()[0])
        review.set_state(self.store,'v2_migrated',False);self.write('previously-written-and-deleted')
        self.store.db.execute("UPDATE jobs SET state='done'")
        review.recover_empty_legacy(self.store,self.data/'hermes')
        self.assertEqual(0,self.store.db.execute("SELECT count(*) FROM jobs WHERE state='pending'").fetchone()[0])

    def test_lost_admission_uses_same_key_and_completed_run_does_not_fake_success(self):
        self.message(1,'个人偏好')
        job=review.next_review(self.store,self.data,1000)
        service=ContextService.__new__(ContextService);service.data=self.data
        calls=[]
        def request(path,body=None,operation=None):
            calls.append((path,operation))
            if path=='/v1/capabilities':return {'features':{'runs_idempotency':{'durable':True,'supported':True,'retention_seconds':3600}}}
            if path=='/v1/runs':
                if sum(p=='/v1/runs' for p,_ in calls)==1:raise TimeoutError('lost acknowledgement')
                return {'run_id':'same-run'}
            return {'run_id':'same-run','session_id':'momo-review-'+job['id'],'status':'completed','output':'我已经记住了。'}
        service.request=request
        service.advance_review(self.store,job)
        row=self.store.db.execute('SELECT * FROM memory_reviews WHERE id=?',(job['id'],)).fetchone()
        self.assertIsNotNone(row['first_attempt']);self.assertEqual('pending',row['state'])
        service.advance_review(self.store,row)
        self.assertEqual([job['id'],job['id']],[op for p,op in calls if p=='/v1/runs'])
        self.assertEqual('retrying',self.store.db.execute('SELECT state FROM memory_reviews ORDER BY rowid').fetchone()[0])
        self.assertEqual(1,self.store.db.execute("SELECT attempt FROM memory_reviews WHERE state='pending'").fetchone()[0])
        self.assertIsNone(review.state(self.store,'chat_cursor'))

    def test_superagent_engine_dispatches_reviews_and_respects_bridge_chat_activity(self):
        (self.data/'runtime/engine.json').write_text('{"engine":"superagent","proactive_mode":"auto"}\n')
        self.message(1,'记住我每天早上八点开始新的一天。',at=100)
        bridge=sqlite3.connect(self.data/'runtime/superagent_bridge.sqlite');self.addCleanup(bridge.close)
        bridge.executescript("CREATE TABLE chat_runs(run_id TEXT PRIMARY KEY,status TEXT); INSERT INTO chat_runs VALUES('r1','started');")
        self.assertFalse(review.chat_idle(self.data,200))
        bridge.execute("UPDATE chat_runs SET status='completed'");bridge.commit()
        self.assertTrue(review.chat_idle(self.data,200))

        review.set_state(self.store,'v2_migrated',True)
        service=ContextService.__new__(ContextService)
        service.data=self.data;service.directory=self.data/'context';service.next_dispatch=0
        from unittest.mock import Mock
        service.stopped=Mock();service.stopped.wait.side_effect=[False,True]
        service.advance_review=Mock();service.advance_job=Mock()
        service.dispatch()
        self.assertEqual('chat',service.advance_review.call_args.args[1]['kind'])

    def test_superagent_memory_review_session_writes_hermes_memory_and_verifies_receipt(self):
        from superagent_gateway import SuperAgentGateway
        gateway=SuperAgentGateway.__new__(SuperAgentGateway)
        gateway.data=self.data
        session='momo-review-sa-1'
        system_prompt,tool_specs,execute_tool=gateway._build_memory_review_session(session)
        self.assertIn('empty',system_prompt)
        self.assertEqual(
            {'memory','notebook','relabel_speakers','list_recordings','read_recording','search_recordings','phone_context','session_search'},
            {t['name'] for t in tool_specs},
        )

        payload=json.dumps({'memory_review':{'outcome':'updated','reason':'保存了每日起点偏好'}})
        with self.assertRaises(Conflict):
            review.outcome(self.data/'hermes',session,payload)

        bad_res=json.loads(execute_tool('memory',{'target':'user','action':'patch','old_text':'不存在','content':'新内容'}))
        self.assertFalse(bad_res['success'])
        with self.assertRaises(Conflict):
            review.outcome(self.data/'hermes',session,json.dumps({'memory_review':{'outcome':'no_change','reason':'失败后未重试'}}))

        ok_res=json.loads(execute_tool('memory',{'target':'user','action':'add','content':'偏好每天 08:00 作为日程与转录分日起点。'}))
        self.assertTrue(ok_res['success'])
        verified=review.outcome(self.data/'hermes',session,payload)
        self.assertEqual('updated',verified['outcome'])
        self.assertEqual(1,verified['native_writes'])
        self.assertIn('08:00',(self.data/'hermes/memories/USER.md').read_text(encoding='utf-8'))

    def test_dream_relabels_speakers_and_writes_markdown_notebook(self):
        from superagent_gateway import SuperAgentGateway
        gateway=SuperAgentGateway.__new__(SuperAgentGateway)
        gateway.data=self.data
        lib_id=str(uuid.uuid4()); sess_id=str(uuid.uuid4()); dev_id=str(uuid.uuid4())
        sp1=str(uuid.uuid4()); sp2=str(uuid.uuid4())
        t1='[我] 小林，接口清单你下午能发我吗？'
        t2='[说话人 1] 没问题，我四点前整理好发你。'
        full_text=t1+'\n'+t2
        receipt=self.store.sync_source({
            'library_id':lib_id,'session_id':sess_id,'device_id':dev_id,
            'generation':0,'version':1,'deleted':False,'recorded_at':1700000000,
            'spans':[
                {'id':sp1,'text':t1,'recorded_at':1700000000,'is_owner':True},
                {'id':sp2,'text':t2,'recorded_at':1700000010,'is_owner':False},
            ],
            'text_sha256':digest(full_text),
        })
        src_id=receipt['source_id']
        session='momo-review-dream-speaker-1'
        _, _, execute_tool=gateway._build_memory_review_session(session)

        relabel_res=json.loads(execute_tool('relabel_speakers',{
            'source_id':src_id,
            'from_speaker':'说话人 1',
            'target_speaker':'小林',
            'is_owner':False,
            'scope':'cluster',
            'reason':'对话中用户直接称呼对方为小林，对方回应四点前发接口清单',
        }))
        self.assertTrue(relabel_res['success'])
        self.assertEqual(1,relabel_res['updated_span_count'])

        read_res=json.loads(execute_tool('read_recording',{'source_id':src_id}))
        spans={s['id']:s for s in read_res['spans']}
        self.assertEqual('小林',spans[sp2]['speaker'])
        self.assertEqual('other',spans[sp2]['speaker_role'])
        self.assertIn('[小林]',spans[sp2]['text'])

        pending=self.store.pending_speaker_relabels()
        self.assertEqual(1,len(pending))
        self.assertEqual('小林',pending[0]['new_speaker'])
        self.store.ack_speaker_relabels([pending[0]['id']])
        self.assertEqual([],self.store.pending_speaker_relabels())

        nb_res=json.loads(execute_tool('notebook',{
            'action':'write',
            'category':'person',
            'slug':'小林',
            'title':'小林',
            'content':'# 小林\n\n- 协作推进接口清单，约定下午四点前同步。',
        }))
        self.assertTrue(nb_res['success'])
        verified=review.outcome(self.data/'hermes',session,json.dumps({'memory_review':{'outcome':'updated','reason':'修正说话人小林并更新人物活页'}}))
        self.assertEqual('updated',verified['outcome'])
        self.assertEqual(2,verified['native_writes'])

    def test_prose_wrapped_receipt_and_wedged_run_timeout_recovery(self):
        from superagent_gateway import SuperAgentGateway
        from momo_memory import MoMoMemory
        mem=MoMoMemory(self.data)
        self.assertTrue((self.data/'memories').is_symlink())

        gateway=SuperAgentGateway.__new__(SuperAgentGateway)
        gateway.data=self.data
        session='momo-review-prose-1'
        _, _, execute_tool=gateway._build_memory_review_session(session)
        execute_tool('notebook',{'action':'write','category':'briefing','content':'# 今日晨间卡片\n\n- 重点推进 Dream 稳定运行。'})
        synthesized=gateway._finalize_memory_review_output(session,'')
        verified=review.outcome(self.data/'hermes',session,synthesized)
        self.assertEqual('updated',verified['outcome'])

        prose_wrapped='我已完成整理：\n```json\n{"memory_review": {"outcome": "updated", "reason": "已更新晨间简报"}}\n```\n祝工作顺利！'
        self.assertEqual('updated',review.outcome(self.data/'hermes',session,prose_wrapped)['outcome'])

        src_id=self.source('卡住的转录批次')['source_id']
        import transcript_ingestion as ti, time as _time
        job=ti.next_job(self.store,_time.time()+1000,True)
        self.store.db.execute("UPDATE jobs SET state='running', run_id='run_orphaned_1', first_attempt=100, replay_before=160 WHERE id=?",(job['id'],))
        self.store.db.commit()
        service=ContextService.__new__(ContextService);service.data=self.data
        service.request=lambda path,*_: {'run_id':'run_orphaned_1','session_id':'momo-transcript-'+job['id'],'status':'started'}
        row=self.store.db.execute('SELECT * FROM jobs WHERE id=?',(job['id'],)).fetchone()
        with patch('context_server.time.time',return_value=600):
            service.advance_job(self.store,row)
        recovered=self.store.db.execute('SELECT * FROM jobs WHERE id=?',(job['id'],)).fetchone()
        self.assertEqual('retrying',recovered['state'])
        pending=self.store.db.execute("SELECT * FROM jobs WHERE source_id=? AND state='pending'",(src_id,)).fetchone()
        self.assertIsNotNone(pending)
        self.assertIsNone(pending['run_id'])
        self.assertEqual(1,pending['attempt'])


if __name__=='__main__':unittest.main()
