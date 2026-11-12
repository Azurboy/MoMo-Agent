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
    def test_transcript_guidance_reaches_all_dream_inputs(self):
        import daily_review
        import transcript_ingestion

        daily_job, _ = review.enqueue_manual_dream(self.store, self.data, now=100)
        self.store.db.execute("UPDATE memory_reviews SET first_attempt=100 WHERE id=?", (daily_job["id"],))
        prompts = {
            "daily and manual": daily_review.prompt(self.store, daily_job),
            "deep review": review.prompt({"kind": "dream", "input": "{}"}),
            "chat review": review.prompt({"kind": "chat", "input": "{}"}),
            "transcript batch": transcript_ingestion.prompt({"source_id": "fixture", "source_revision": "1"}),
        }
        for route, prompt in prompts.items():
            with self.subTest(route=route):
                self.assertIn(review.TRANSCRIPT_GUIDANCE, prompt)

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
        self.assertFalse(review.chat_idle(self.data,699));self.assertTrue(review.chat_idle(self.data,700))
        job=review.next_review(self.store,self.data,160)
        self.assertEqual('dream', job['kind'])
        evidence = self.store.db.execute("SELECT evidence FROM daily_review_pages WHERE review_id=?", (job['id'],)).fetchone()
        self.assertEqual([2, 0], json.loads(evidence[0])['cursor'])
        self.native.execute("INSERT INTO session_admissions VALUES('momo-work-live','queued')");self.native.commit()
        self.assertTrue(review.chat_idle(self.data,800), 'A retired engine cannot hold active admission')

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

    def test_daily_dream_does_not_reingest_its_own_notes_or_briefing(self):
        review.set_state(self.store, "chat_cursor", [1, 0])
        job = review.next_review(self.store, self.data, 1000)
        for i in range(10):
            (self.data / f"hermes/memories/project-{i}.md").write_text(f"# project {i}")
        (self.data / "hermes/memories/BRIEFING.md").write_text("# 2026-11-11 日报")
        with patch.object(review.time, "time", return_value=1000):
            review.finish(self.store, job, {"outcome": "updated", "native_writes": 11}, self.data / "hermes")
        self.assertIsNone(review.next_review(self.store, self.data, 1000 + 2 * review.DREAM_INTERVAL))
        self.message(2, "这条需要纠正", operation="real-turn")
        self.assertEqual([2], [m["seq"] for m in review.chat_batch(self.store, self.data)["messages"]])

    def test_daily_run_consolidates_all_pages_and_keeps_new_arrivals_for_tomorrow(self):
        import daily_review
        from superagent_gateway import SuperAgentGateway
        from unittest.mock import Mock
        self.source("示例记录" * 45000)
        self.source("另一场录音")
        self.message(1, "chat evidence")
        review.set_state(self.store, "v2_migrated", True)
        admissions = []
        start = 100000
        def wake(now):
            service = ContextService.__new__(ContextService)
            service.data, service.directory, service.next_dispatch = self.data, self.data / "context", 0
            service.stopped = Mock()
            service.stopped.wait.side_effect = [False, True]
            service.advance_job = Mock(side_effect=AssertionError("separate transcript run"))
            def admit(_, row):
                admissions.append(row)
                self.store.db.execute("UPDATE memory_reviews SET state='running', first_attempt=? WHERE id=?", (now, row["id"]))
            service.advance_review = admit
            with patch("context_server.time.time", return_value=now):
                service.dispatch()

        wake(start)
        job = admissions[0]
        self.assertEqual("dream", job["kind"])
        session = "momo-review-" + job["id"]
        gateway = SuperAgentGateway.__new__(SuperAgentGateway)
        gateway.data = self.data
        _, _, call = gateway._build_memory_review_session(session)
        first = json.loads(daily_review.prompt(self.store, job).split("DAILY_EVIDENCE=")[-1])
        self.assertEqual(first["evidence"]["messages"][0]["text"], "chat evidence")
        self.assertGreater(first["total_pages"], 20)
        page = first["next_page"]
        sources = set()
        while page is not None:
            item = json.loads(call("read_daily_evidence", {"review_id": job["id"], "page": page}))
            sources.add(item["evidence"]["source_id"])
            page = item["next_page"]
        self.assertEqual(len(sources), 2)
        self.source("later arrival")
        self.message(2, "later chat")
        with patch.object(review.time, "time", return_value=start):
            review.finish(self.store, job, {"outcome": "no_change"}, self.data / "hermes")
        self.assertEqual(review.state(self.store, "chat_cursor"), [2, 0])
        self.assertEqual(self.store.db.execute("SELECT COUNT(*) FROM jobs WHERE state='pending'").fetchone()[0], 1)
        self.assertEqual(self.store.db.execute("SELECT COUNT(*) FROM daily_review_pages").fetchone()[0], 0)
        for minutes in (1, 60, 120, 720, 1439):
            wake(start + 60 * minutes)
        self.assertEqual(len(admissions), 1)
        wake(start + 86400)
        self.assertEqual(len(admissions), 2)

    def test_daily_partial_review_preserves_unread_pages(self):
        import daily_review
        self.message(1, "checked")
        self.source("待处理的录音")
        job = review.next_review(self.store, self.data, 10000)
        self.store.db.execute("UPDATE memory_reviews SET state='running',first_attempt=10000 WHERE id=?", (job["id"],))
        daily_review.prompt(self.store, job)
        review.finish(self.store, job, {"outcome": "no_change"}, self.data/"hermes")
        self.assertEqual(review.state(self.store, "chat_cursor"), [2, 0])
        self.assertEqual(self.store.db.execute("SELECT state FROM jobs").fetchone()[0], "pending")
        self.assertEqual(self.store.db.execute("SELECT COUNT(*) FROM memory_reviews").fetchone()[0], 1)

    def test_daily_retry_reuses_frozen_pages_and_skips_a_revised_source(self):
        import daily_review
        source = self.source("old recording")
        self.message(1, "first chat")
        job = review.next_review(self.store, self.data, 100)
        self.store.db.execute("UPDATE memory_reviews SET state='running', first_attempt=100 WHERE id=?", (job["id"],))
        daily_review.prompt(self.store, job)
        self.assertTrue(review.retry_completed(self.store, "memory_reviews", job, "gateway restarted"))
        self.assertIsNone(review.next_review(self.store, self.data, 101))
        retry = review.next_review(self.store, self.data, 100 + review.DREAM_INTERVAL)
        self.assertEqual(retry["attempt"], 1)
        self.store.db.execute("UPDATE memory_reviews SET state='running', first_attempt=86500 WHERE id=?", (retry["id"],))
        daily_review.prompt(self.store, retry)
        payload = json.loads(self.store.source(source["source_id"])["payload"])
        payload["version"] += 1
        payload["spans"][0]["text"] = "revised recording"
        payload["text_sha256"] = digest("revised recording")
        self.store.sync_source(payload)
        self.assertEqual(daily_review.read_page(self.store, retry["id"], 2)["evidence"], {"superseded": True})
        review.finish(self.store, retry, {"outcome": "no_change"}, self.data/"hermes")
        self.assertEqual(self.store.db.execute("SELECT count(*) FROM jobs WHERE state='done'").fetchone()[0], 0)
        self.assertEqual(self.store.db.execute("SELECT count(*) FROM jobs WHERE state='pending'").fetchone()[0], 1)

    def test_repeated_recording_page_stops_but_twenty_distinct_pages_complete(self):
        from superagent_gateway import RepeatedToolRead, SuperAgentGateway
        from unittest.mock import Mock
        gateway = SuperAgentGateway.__new__(SuperAgentGateway)
        gateway.data = self.data
        session = "momo-review-pagination"
        source_id = self.source("示例转录" * 100)["source_id"]

        def page(i, offset):
            fn = {"name": "read_recording", "arguments": json.dumps({"source_id": source_id, "limit": 5, "offset": offset})}
            return {"choices": [{"message": {"tool_calls": [{"id": str(i), "function": fn}]}}]}

        receipt = json.dumps({"memory_review": {"outcome": "no_change", "reason": "已核对各页"}})
        finish = {"choices": [{"message": {"content": receipt}}]}
        with patch("superagent_gateway.resolve_superagent_llm", return_value={"dsh_provider": "antigravity", "model_id": "mock"}):
            with patch("antigravity_bridge.run_antigravity_completion", side_effect=[page(i, 0) for i in range(14)]) as model:
                with self.assertRaises(RepeatedToolRead):
                    gateway._call_configured_llm_memory_review(session, "review")
                self.assertEqual(model.call_count, 3)
            progress = Mock()
            with patch("antigravity_bridge.run_antigravity_completion", side_effect=[page(i, i*5) for i in range(20)] + [finish]) as model:
                output = gateway._call_configured_llm_memory_review(session, "review", heartbeat=progress)
                self.assertEqual(review.outcome(self.data / "hermes", session, output)["outcome"], "no_change")
                self.assertEqual(model.call_count, 21)
                self.assertEqual(progress.call_count, 41)
        self.assertFalse(ContextService.review_timed_out({"first_attempt": 10, "replay_before": 400}, {"updated_at": 3999}, 4000))

    def test_unverified_update_can_finish_its_write_in_the_same_run(self):
        from superagent_gateway import SuperAgentGateway
        gateway = SuperAgentGateway.__new__(SuperAgentGateway)
        gateway.data = self.data
        session = "momo-review-correct-update"
        updated = json.dumps({"memory_review": {"outcome": "updated", "reason": "已整理笔记"}})
        write = {"id": "write", "function": {"name": "notebook", "arguments": json.dumps({
            "action": "write", "path": "projects/receipt.md", "content": "# 已核对",
        })}}
        def reply(message):
            return {"choices": [{"message": message}]}
        def completion(*, messages, **kwargs):
            if messages[-1]["role"] == "tool":
                self.assertTrue(json.loads(messages[-1]["content"])["success"])
                return reply({"content": updated})
            if len(messages) == 2:
                return reply({"content": updated})
            self.assertEqual(messages[-2]["content"], updated)
            self.assertIn("without a successful native write", messages[-1]["content"])
            return reply({"tool_calls": [write]})
        with patch("superagent_gateway.resolve_superagent_llm", return_value={"dsh_provider":"antigravity","model_id":"mock"}):
            with patch("antigravity_bridge.run_antigravity_completion", side_effect=completion) as model:
                output = gateway._call_configured_llm_memory_review(session, "review")
                self.assertEqual(model.call_count, 3)
                self.assertEqual(review.outcome(self.data/"hermes", session, output)["native_writes"], 1)
            with patch("antigravity_bridge.run_antigravity_completion", return_value=reply({"content": updated})) as model:
                with self.assertRaises(review.InvalidReviewReceipt):
                    gateway._call_configured_llm_memory_review("momo-review-no-write", "review")
                self.assertEqual(model.call_count, 2)
        job, _ = review.enqueue_manual_dream(self.store, self.data)
        with self.assertRaises(Conflict):
            review.handle_failed_run(self.store, "memory_reviews", job, {"error": review.InvalidReviewReceipt.code})
        self.assertEqual(self.store.db.execute("SELECT COUNT(*) FROM memory_reviews").fetchone()[0], 1)

    def test_stalled_or_unverified_batch_keeps_evidence_and_creates_no_retry(self):
        self.source()
        service = ContextService.__new__(ContextService)
        service.data = self.data
        for table, advance, prefix, status in (
            ("jobs", service.advance_job, "momo-transcript-", "failed"),
            ("memory_reviews", service.advance_review, "momo-review-", "completed"),
        ):
            if table == "memory_reviews":
                review.enqueue_manual_dream(self.store, self.data)
            self.store.db.execute(f"UPDATE {table} SET state='running', run_id='r'")
            job = self.store.db.execute(f"SELECT * FROM {table}").fetchone()
            service.request = lambda *_: {
                "run_id": "r", "session_id": prefix + job["id"], "status": status, "error": review.STALLED_REVIEW,
                "output": json.dumps({"memory_review": {"outcome": "updated", "reason": "已写入"}}),
            }
            advance(self.store, job)
            self.assertEqual(["needs_review"], [r[0] for r in self.store.db.execute(f"SELECT state FROM {table}")])
        self.assertIsNone(review.state(self.store, "dream"))

    def test_quota_gate_and_manual_dream_during_cooldown(self):
        from provider_notice import record_provider_issue, clear_provider_notice
        from unittest.mock import Mock
        now = 30000
        (self.data/"hermes/config.yaml").write_text('{"model":{"provider":"antigravity"}}')
        self.source()
        record_provider_issue(self.data, "insufficient_quota", provider="antigravity", now=now)
        service = ContextService.__new__(ContextService)
        service.data = self.data
        service.directory = self.data/"context"
        service.next_dispatch = 0
        service.stopped, service.advance_review, service.advance_job = Mock(), Mock(), Mock()
        with patch("context_server.time.time", return_value=now):
            service.stopped.wait.side_effect = [False, True]
            service.dispatch()
            service.advance_review.assert_not_called()
            service.advance_job.assert_not_called()
            auto = review.next_review(self.store, self.data, now)
            manual, created = review.enqueue_manual_dream(self.store, self.data, now)
            self.assertFalse(created)
            self.assertEqual(manual["id"], auto["id"])
            service.stopped.wait.side_effect = [False, True]
            service.dispatch()
            self.assertEqual(service.advance_review.call_args.args[1]["id"], manual["id"])
        clear_provider_notice(self.data)
        self.assertFalse(service.background_quota_exhausted(now))
        self.store.db.execute("UPDATE memory_reviews SET state='needs_review', first_attempt=?", (now,))
        self.source("新增")
        self.assertIsNone(review.next_review(self.store, self.data, now + 1800))
        self.assertIsNotNone(review.next_review(self.store, self.data, now + review.DREAM_INTERVAL))

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
        self.assertEqual(['needs_review'], [r[0] for r in self.store.db.execute('SELECT state FROM memory_reviews')])
        self.assertIsNone(review.state(self.store,'chat_cursor'))

    def test_superagent_engine_dispatches_reviews_and_respects_bridge_chat_activity(self):
        (self.data/'runtime/engine.json').write_text('{"engine":"superagent","proactive_mode":"auto"}\n')
        self.message(1,'记住我每天早上八点开始新的一天。',at=100)
        bridge=sqlite3.connect(self.data/'runtime/superagent_bridge.sqlite');self.addCleanup(bridge.close)
        bridge.executescript("CREATE TABLE chat_runs(run_id TEXT PRIMARY KEY,status TEXT); INSERT INTO chat_runs VALUES('r1','started');")
        self.assertFalse(review.chat_idle(self.data,800))
        bridge.execute("UPDATE chat_runs SET status='completed'");bridge.commit()
        self.assertTrue(review.chat_idle(self.data,800))

        review.set_state(self.store,'v2_migrated',True)
        service=ContextService.__new__(ContextService)
        service.data=self.data;service.directory=self.data/'context';service.next_dispatch=0
        from unittest.mock import Mock
        service.stopped=Mock();service.stopped.wait.side_effect=[False,True]
        service.advance_review=Mock();service.advance_job=Mock()
        service.dispatch()
        self.assertEqual('dream',service.advance_review.call_args.args[1]['kind'])

    def test_superagent_memory_review_session_writes_hermes_memory_and_verifies_receipt(self):
        from superagent_gateway import SuperAgentGateway
        gateway=SuperAgentGateway.__new__(SuperAgentGateway)
        gateway.data=self.data
        session='momo-review-sa-1'
        system_prompt,tool_specs,execute_tool=gateway._build_memory_review_session(session)
        self.assertIn('empty',system_prompt)
        self.assertEqual(
            {'memory','notebook','relabel_speakers','list_recordings','read_recording','search_recordings','phone_context','session_search','read_daily_evidence'},
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
        execute_tool('notebook',{
            'action':'write',
            'category':'project',
            'slug':'overview',
            'title':'在研项目总览',
            'content':'# 在研项目总览\n\n- 项目一：用研平台',
        })
        self.assertTrue((self.data/'hermes/memories/projects/overview.md').is_file())
        execute_tool('notebook',{
            'action':'write',
            'category':'briefing',
            'content':'# 晨间简报 · 2026-11-10\n\n## 今日脉络\n重点推进 Dream 稳定运行，总览见 `projects/overview.md`。\n\n## 卡片：理清日记法边界\n- 纹样：片段关联\n- 语境：承接昨日讨论\n\n请帮我梳理日记法边界。',
        })
        msgs=[dict(zip(['role','content','operation_id'],r)) for r in self.chat.execute('SELECT role,content,operation_id FROM messages WHERE role="assistant"').fetchall()]
        self.assertEqual(1,len(msgs))
        self.assertIn('晨间简报 · 2026-11-10',msgs[0]['content'])
        self.assertIn('[📔 projects/overview.md](momoagent://memory/projects/overview.md)',msgs[0]['content'])
        self.assertNotIn('我已在消息窗口下方为你备好',msgs[0]['content'])
        self.assertNotIn('- 纹样：',msgs[0]['content'])
        self.assertTrue(msgs[0]['operation_id'].startswith('dream-briefing:'))
        # Idempotent when BRIEFING.md has not changed
        again=review.deliver_briefing_to_conversation(self.data)
        self.assertEqual('already_delivered',again['status'])
        self.assertEqual(1,len(self.chat.execute('SELECT seq FROM messages WHERE role="assistant"').fetchall()))
        # Same-day update modifies the existing briefing bubble in-place instead of spamming duplicates
        execute_tool('notebook',{
            'action':'write',
            'category':'briefing',
            'content':'# 今日简报 · 2026-11-10\n\n## 今日脉络\n已按项目分流，见 `projects/overview.md` 与 `topics/diary-study.md`。',
        })
        msgs_after=[dict(zip(['role','content','operation_id'],r)) for r in self.chat.execute('SELECT role,content,operation_id FROM messages WHERE role="assistant"').fetchall()]
        self.assertEqual(1,len(msgs_after))
        self.assertIn('[📔 topics/diary-study.md](momoagent://memory/topics/diary-study.md)',msgs_after[0]['content'])

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

    def test_chat_speaker_correction_tools_and_retrospective_passage_invalidation(self):
        import asyncio, transcript_ingestion as ti
        from superagent_gateway import SuperAgentGateway
        gateway=SuperAgentGateway.__new__(SuperAgentGateway)
        gateway.data=self.data
        gateway.dsh_ready=False
        gateway.bridge_secret='secret-123'

        lib_id=str(uuid.uuid4()); sess_id=str(uuid.uuid4()); dev_id=str(uuid.uuid4())
        sp1=str(uuid.uuid4()); sp2=str(uuid.uuid4()); sp3=str(uuid.uuid4())
        t1='[佳辰] 大家好，今天先对齐一下本周排期。'
        t2='[佳辰] 双月 OKR 分三个目标：O1 稳住访谈核心能力，O3 客户合同 SLA 99.5%。'
        t3='[说话人 2] 收到，那我跟进 benchmark 部分。'
        full_text='\n'.join([t1,t2,t3])
        receipt=self.store.sync_source({
            'library_id':lib_id,'session_id':sess_id,'device_id':dev_id,
            'generation':0,'version':1,'deleted':False,'recorded_at':1700000100,
            'spans':[
                {'id':sp1,'text':t1,'recorded_at':1700000100,'speaker':'佳辰','is_owner':False},
                {'id':sp2,'text':t2,'recorded_at':1700000120,'speaker':'佳辰','is_owner':False},
                {'id':sp3,'text':t3,'recorded_at':1700000140,'speaker':'说话人 2','is_owner':False},
            ],
            'text_sha256':digest(full_text),
        })
        src_id=receipt['source_id']
        row_before=self.store.db.execute('SELECT * FROM sources WHERE id=?',(src_id,)).fetchone()
        hashes_before=[p['hash'] for p in ti.parts(row_before,self.store)]

        class FakeReq:
            headers={'X-MoMo-Bridge':'secret-123'}
            def __init__(self,body): self._b=json.dumps(body).encode('utf-8')
            async def read(self): return self._b

        async def call_pim(op,args):
            resp=await gateway.handle_internal_pim(FakeReq({'op':op,'args':args}))
            return json.loads(resp.text)

        found=asyncio.run(call_pim('search_recordings',{'query':'双月 OKR'}))
        self.assertTrue(found['ok'])
        self.assertEqual(1,len(found['matches']))
        self.assertEqual(sp2,found['matches'][0]['span_id'])
        self.assertEqual('佳辰',found['matches'][0]['speaker'])

        # Relabel ONLY sp2 (scope='selection' default, even if LLM also supplies from_speaker='佳辰') without touching sp1!
        rel=asyncio.run(call_pim('relabel_recording_speakers',{
            'source_id':src_id,
            'from_speaker':'佳辰',
            'span_ids':[sp2],
            'target_speaker':'shengli',
            'is_owner':False,
            'reason':'用户指正双月 OKR 是 shengli 说的',
        }))
        self.assertTrue(rel['ok'])
        self.assertEqual(1,rel['updated_span_count'])

        read_back=asyncio.run(call_pim('read_recording',{'source_id':src_id}))
        by_id={s['id']:s for s in read_back['spans']}
        self.assertEqual('佳辰',by_id[sp1]['speaker'])
        self.assertEqual('shengli',by_id[sp2]['speaker'])

        # Passage hash must change when speaker override changes so retrospective ingestion sees it
        hashes_after=[p['hash'] for p in ti.parts(row_before,self.store)]
        self.assertNotEqual(hashes_before,hashes_after)

        # Project category + core memory + remove notebook via PIM bridge
        wr=asyncio.run(call_pim('write_memory_notebook',{
            'category':'project','slug':'okr-2026','title':'双月 OKR','content':'# 双月 OKR\n\n- shengli 介绍双月 OKR（SLA 99.5%）。'
        }))
        self.assertTrue(wr['ok'])
        rd=asyncio.run(call_pim('read_memory_notebook',{'category':'project','slug':'okr-2026'}))
        self.assertIn('shengli 介绍双月 OKR',rd['content'])
        cm=asyncio.run(call_pim('update_core_memory',{'action':'add','target':'memory','content':'双月 OKR 由 shengli 负责主讲。'}))
        self.assertTrue(cm['ok'])
        rm=asyncio.run(call_pim('remove_memory_notebook',{'category':'project','slug':'okr-2026'}))
        self.assertTrue(rm['ok'])
        # Model-initiated removal must NOT tombstone the slug permanently, and H2-only notes auto-gain an H1 title
        wr2=asyncio.run(call_pim('write_memory_notebook',{
            'category':'project','slug':'okr-2026','content':'## 2026-11-06 · 双月 OKR 收敛版\n\n- 已合并冗余分支。'
        }))
        self.assertTrue(wr2['ok'])
        rd2=asyncio.run(call_pim('read_memory_notebook',{'category':'project','slug':'okr-2026'}))
        self.assertTrue(rd2['content'].startswith('# 双月 OKR 收敛版\n'))


if __name__=='__main__':unittest.main()
