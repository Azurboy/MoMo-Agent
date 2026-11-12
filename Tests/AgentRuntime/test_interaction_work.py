"""Real native admission fences and the existing flock lease, without user data."""
import asyncio
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
import uuid
from types import SimpleNamespace
from unittest.mock import patch,AsyncMock
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'Tests/AgentRuntime/fixtures/legacy_gateway'))
sys.path[:0]=[str(ROOT/'Apps/MacApp/Runtime'),str(ROOT/'Apps/MacApp/Access'),str(ROOT/'Vendor/HermesAgent')]
from personal_agent import PersonalAgent,ProductStore
from hermes_state import SessionDB
from hermes_state_runtime import begin_runtime_epoch,admit_session_input,claim_session_input,steer_session_input,settle_session_input,get_session_admission,recover_session_inputs
from desktop_control import DesktopLease


class InteractionTests(unittest.IsolatedAsyncioTestCase):
    async def test_ttft_ignores_empty_events_and_logs_first_public_text_once(self):
        product=PersonalAgent.__new__(PersonalAgent);product.observers={}
        row={'admission_id':'synthetic-admission','request_id':'synthetic-run','status':'started'}
        async def observe(admitted, **callbacks):
            callback=callbacks['stream_delta_callback']
            callback(None);callback('');callback('PRIVATE_FIRST_TEXT');callback('PRIVATE_NEXT_TEXT')
        with patch('gateway.session_api_turn.observe_api_turn',side_effect=observe), self.assertLogs('momo.personal_agent',level='INFO') as logs:
            product.observe((None,None,row))
            await asyncio.gather(*product.observers.values())
        self.assertEqual(1,len(logs.output))
        self.assertIn('admission_to_text_ms=',logs.output[0])
        self.assertNotIn('PRIVATE',logs.output[0])

    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(); self.data=Path(self.temp.name)
        self.store=ProductStore(self.data/'product.db',{'assistant_id':str(uuid.uuid4())})
        self.db=SessionDB(db_path=self.data/'state.db')
        self.epoch=begin_runtime_epoch(self.db,instance_id='synthetic')
        self.addCleanup(self.temp.cleanup);self.addCleanup(self.store.db.close);self.addCleanup(self.db.close)
    def admit(self,sid,request,steer=False):
        if not self.db.get_session(sid):self.db.create_session(sid,source='api_server')
        payload={'text':request,'api_turn_v1':{'history':None,'settings':{}}}
        if steer:payload['api_turn_v1']['momo_steer_only']={'generation':1,'target_run_id':'first'}
        return admit_session_input(self.db,epoch=self.epoch,principal_id='api',session_id=sid,request_id=request,payload=payload)
    def test_failed_model_request_projects_safe_actionable_error(self):
        accepted=self.store.accept(str(uuid.uuid4()),'synthetic greeting','scope')
        sid=self.store.db.execute('SELECT native_root FROM works WHERE id=?',(accepted['work_id'],)).fetchone()[0]
        row=self.admit(sid,accepted['run_id'])
        product=PersonalAgent.__new__(PersonalAgent);product.store=self.store
        product.authority=lambda:SimpleNamespace(db=self.db,logical_owner=lambda value:value)
        product.computer_wait=lambda *_:None
        value=dict(status='failed',session_id=sid,pending_controls=[])
        with patch('gateway.session_results.admission_result',return_value={'result':{'failure_reason':'timeout','error':'SECRET_TOKEN must never be shown'}}):
            projected=product.project_run(row,value)
        self.assertIn('Mac 暂时连不上模型服务',projected['error'])
        self.assertNotIn('SECRET_TOKEN',json.dumps(projected))
        self.assertEqual(accepted['work_id'],projected['work_id'])
        self.assertEqual('failed',projected['status'])
    def test_unconsumed_steer_never_becomes_independent_claim(self):
        self.admit('root','first'); first=claim_session_input(self.db,epoch=self.epoch,session_id='root')
        steer=self.admit('root','note',True)
        steer_session_input(self.db,epoch=self.epoch,admission_id=steer['admission_id'],generation=first['generation'])
        settle_session_input(self.db,epoch=self.epoch,admission_id=first['admission_id'],generation=first['generation'],outcome='completed',_transfers={steer['admission_id']:False})
        self.assertIsNone(claim_session_input(self.db,epoch=self.epoch,session_id='root'))
        self.assertEqual('cancelled',get_session_admission(self.db,admission_id=steer['admission_id'])['outcome'])
        # A crash before transfer is also fenced durably, independently of the product process.
        orphan=self.admit('root','orphan',True)
        self.epoch=begin_runtime_epoch(self.db,instance_id='restart');recover_session_inputs(self.db,epoch=self.epoch)
        self.assertFalse(claim_session_input(self.db,epoch=self.epoch,session_id='root'))
        self.assertEqual('cancelled',get_session_admission(self.db,admission_id=orphan['admission_id'])['outcome'])
    def test_context_snapshot_and_input_remain_stable_across_retry(self):
        first=self.store.accept(str(uuid.uuid4()),'prior human intent','scope')
        self.store.append_assistant('one','prior response',1)
        op=str(uuid.uuid4()); accepted=self.store.accept(op,'new question','scope')
        original=self.store.db.execute('SELECT context_json FROM works WHERE id=?',(accepted['work_id'],)).fetchone()[0]
        self.store.append_assistant('late','a later response',2)
        self.assertEqual(accepted,self.store.accept(op,'new question','scope'))
        self.assertEqual(original,self.store.db.execute('SELECT context_json FROM works WHERE id=?',(accepted['work_id'],)).fetchone()[0])
        self.assertEqual(['user','assistant'],[r['role'] for r in json.loads(original)])
        self.assertNotEqual(first['work_id'],accepted['work_id'])
    def test_failed_supplement_remains_visible_but_never_enters_later_context(self):
        first=self.store.accept(str(uuid.uuid4()),'original work','scope')
        operation=str(uuid.uuid4())
        supplement=self.store.accept(operation,'FAILED_SECRET_SUPPLEMENT','scope',first['run_id'],1,first['work_id'])
        before=self.store.page()['data'];cursor=before[-1]['seq']
        self.assertEqual('pending',self.store.message_states()['user-'+operation])
        self.store.db.execute("UPDATE inputs SET delivery_state='not_applied' WHERE operation_id=?",(operation,));self.store.db.commit()
        self.assertEqual(before,self.store.page()['data'])
        self.assertEqual([],self.store.page(after=cursor)['data'])
        self.assertEqual('not_applied',self.store.message_states()['user-'+operation])
        later=self.store.accept(str(uuid.uuid4()),'next question','scope')
        history=self.store.db.execute('SELECT context_json FROM works WHERE id=?',(later['work_id'],)).fetchone()[0]
        self.assertNotIn('FAILED_SECRET_SUPPLEMENT',history)
        self.assertIn('original work',history)
        # Retrying the old operation does not create a new user bubble or execution.
        self.assertEqual(supplement['run_id'],self.store.accept(operation,'FAILED_SECRET_SUPPLEMENT','scope',first['run_id'],1,first['work_id'])['run_id'])

    async def test_cancel_queue_observation_survives_claim_race_exactly_once(self):
        accepted=self.store.accept(str(uuid.uuid4()),'queued task','scope')
        sid=self.store.db.execute('SELECT native_root FROM works WHERE id=?',(accepted['work_id'],)).fetchone()[0]
        self.admit(sid,accepted['run_id']);claimed=claim_session_input(self.db,epoch=self.epoch,session_id=sid)
        product=PersonalAgent.__new__(PersonalAgent);product.store=self.store
        product.authority=lambda:SimpleNamespace(db=self.db,logical_owner=lambda value:value)
        product.child_snapshot=lambda:[];product.apply_cancellations=AsyncMock()
        body=dict(operation_id=str(uuid.uuid4()),execution_generation=0,target_run_id=accepted['run_id'])
        await product.cancel_work(accepted['work_id'],body);await product.cancel_work(accepted['work_id'],body)
        self.assertEqual(1,self.store.db.execute('SELECT count(*) FROM work_cancels').fetchone()[0])
        self.assertEqual('started',get_session_admission(self.db,admission_id=claimed['admission_id'])['status'])
        from aiohttp import web
        with self.assertRaises(web.HTTPConflict):await product.cancel_work(accepted['work_id'],{**body,'operation_id':str(uuid.uuid4()),'target_run_id':'other'})

    async def test_control_wait_releases_only_after_inflight_call_and_invalidates_epoch(self):
        import threading
        accepted=self.store.accept(str(uuid.uuid4()),'computer task','scope')
        sid=self.store.db.execute('SELECT native_root FROM works WHERE id=?',(accepted['work_id'],)).fetchone()[0]
        self.admit(sid,accepted['run_id']);claim=claim_session_input(self.db,epoch=self.epoch,session_id=sid)
        controls=[]
        authority=SimpleNamespace(db=self.db,logical_owner=lambda value:value,sessions={sid:SimpleNamespace(event_stream=SimpleNamespace(lock=threading.RLock()),controls=SimpleNamespace(snapshot=lambda *_:controls))})
        product=PersonalAgent.__new__(PersonalAgent);product.store=self.store;product.data=self.data;product.loop=asyncio.get_running_loop();product.authority=lambda:authority
        agent=SimpleNamespace(_interrupt_requested=False);product.bind_computer_gate(agent,(authority,sid,claim['generation']))
        lease=DesktopLease(self.data);entered=threading.Event();release=threading.Event()
        def execute(args):
            entered.set();release.wait(3)
            with lease.locked():
                value=lease.read();value['observed_epoch']=value['epoch'];lease.write(value)
            return 'image'
        task=asyncio.create_task(asyncio.to_thread(agent._product_computer_gate,'mcp__momo_computer__computer_screenshot',{},'inflight',execute))
        while not entered.is_set():await asyncio.sleep(.01)
        controls.append({'kind':'approval'})
        product.reconcile_computer();self.assertIsNotNone(lease.read().get('agent_work'))
        release.set();await task;old_epoch=lease.read()['epoch']
        product.reconcile_computer();self.assertIsNone(lease.read().get('agent_work'));self.assertGreater(lease.read()['epoch'],old_epoch)
        controls.clear();calls=[]
        result=await asyncio.to_thread(agent._product_computer_gate,'mcp__momo_computer__computer_input',{},'old-click',lambda args:calls.append(args))
        self.assertIn('desktop_changed',result);self.assertEqual([],calls)

    async def test_unadmitted_strict_refusal_is_terminal_but_transient_does_not_block_other_inputs(self):
        from hermes_state_runtime import RuntimeStoreError
        from aiohttp import web
        first=self.store.accept(str(uuid.uuid4()),'work','scope')
        supplement=self.store.accept(str(uuid.uuid4()),'must not become context','scope',first['run_id'],1,first['work_id'])
        product=PersonalAgent.__new__(PersonalAgent);product.store=self.store
        product.authority=lambda:SimpleNamespace(db=self.db)
        product._admit_input=AsyncMock(side_effect=RuntimeStoreError('permission_denied'))
        with self.assertRaises(RuntimeStoreError):await product.admit_input(supplement)
        self.assertEqual(('rejected','not_applied'),tuple(self.store.db.execute('SELECT state,delivery_state FROM inputs WHERE run_id=?',(supplement['run_id'],)).fetchone()))
        product._admit_input.reset_mock()
        with self.assertRaises(web.HTTPConflict):await product.admit_input(supplement)
        product._admit_input.assert_not_awaited()
        later=self.store.accept(str(uuid.uuid4()),'later input','scope')
        seen=[]
        async def admit(row):
            seen.append(row['run_id'])
            if row['run_id']==first['run_id']:raise RuntimeStoreError('storage_unavailable')
            with self.store.db:self.store.db.execute("UPDATE inputs SET state='admitted' WHERE run_id=?",(row['run_id'],))
        product._admit_input=admit
        await product.deliver_inputs()
        self.assertEqual([first['run_id'],later['run_id']],seen)
        self.assertEqual('pending',self.store.db.execute('SELECT state FROM inputs WHERE run_id=?',(first['run_id'],)).fetchone()[0])
        self.assertEqual('admitted',self.store.db.execute('SELECT state FROM inputs WHERE run_id=?',(later['run_id'],)).fetchone()[0])

    async def test_other_work_wait_keeps_owner_and_is_not_human_takeover(self):
        accepted=self.store.accept(str(uuid.uuid4()),'waiting task','scope')
        sid=self.store.db.execute('SELECT native_root FROM works WHERE id=?',(accepted['work_id'],)).fetchone()[0]
        self.admit(sid,accepted['run_id']);claim=claim_session_input(self.db,epoch=self.epoch,session_id=sid)
        product=PersonalAgent.__new__(PersonalAgent);product.store=self.store;product.data=self.data;product.loop=asyncio.get_running_loop()
        authority=SimpleNamespace(db=self.db,logical_owner=lambda value:value);product.authority=lambda:authority
        agent=SimpleNamespace(_interrupt_requested=False);product.bind_computer_gate(agent,(authority,sid,claim['generation']))
        lease=DesktopLease(self.data);owner=dict(work_id='another-work',run_id='other-run',generation=8)
        lease.write(dict(owner='agent',epoch=3,agent_work=owner))
        calls=[]
        task=asyncio.create_task(asyncio.to_thread(agent._product_computer_gate,'mcp__momo_computer__computer_screenshot',{},'wait-other',lambda args:calls.append(args)))
        for _ in range(100):
            waiting=product.computer_wait(accepted['run_id'],claim['generation'])
            if waiting:break
            await asyncio.sleep(.01)
        self.assertEqual('computer_task',waiting['wait_reason']);self.assertEqual('another-work',waiting['blocking_work_id'])
        agent._interrupt_requested=True;self.assertIn('cancelled',await task)
        self.assertEqual(owner,lease.read()['agent_work']);self.assertEqual([],calls)

    async def test_report_retry_survives_reopen_and_late_old_claim_is_still_readonly(self):
        accepted=self.store.accept(str(uuid.uuid4()),'original process','scope')
        sid=self.store.db.execute('SELECT native_root FROM works WHERE id=?',(accepted['work_id'],)).fetchone()[0]
        self.admit(sid,'momo_completion_event');claim=claim_session_input(self.db,epoch=self.epoch,session_id=sid)
        settle_session_input(self.db,epoch=self.epoch,admission_id=claim['admission_id'],generation=claim['generation'],outcome='failed')
        self.store.db.execute("INSERT INTO work_children VALUES(?,?,?,?,?,?,?,?,?,?)",('process:done',accepted['work_id'],accepted['run_id'],'process','done',1,1,'finished','completed',0))
        self.store.db.execute("INSERT INTO completions(event_key,owner,event_json,source_message_id,prompt,state,admission_id,result_text,created_at) VALUES(?,?,?,?,?,?,?,?,?)",('event',sid,'{"session_id":"done"}',42,'old','failed',claim['admission_id'],'saved immutable result',1));self.store.db.commit()
        product=PersonalAgent.__new__(PersonalAgent);product.store=self.store;product.data=self.data;product.loop=asyncio.get_running_loop()
        authority=SimpleNamespace(db=self.db,logical_owner=lambda value:value);product.authority=lambda:authority
        operation=dict(operation_id=str(uuid.uuid4()))
        await product.retry_report('process:done',operation)
        identity=product.root.removeprefix('momo-main-');self.store.db.close();self.store=ProductStore(self.data/'product.db',{'assistant_id':identity});self.addCleanup(self.store.db.close)
        product.store=self.store
        await product.retry_report('process:done',operation)
        self.assertEqual((1,1),tuple(self.store.db.execute('SELECT count(*),max(attempt) FROM report_retries').fetchone()))
        self.admit(sid,'momo_completion_event_report_1');retry=claim_session_input(self.db,epoch=self.epoch,session_id=sid)
        settle_session_input(self.db,epoch=self.epoch,admission_id=retry['admission_id'],generation=retry['generation'],outcome='failed')
        self.store.db.execute('UPDATE completions SET report_attempt=2');self.store.db.commit()
        agent=SimpleNamespace(_interrupt_requested=False);product.bind_computer_gate(agent,(authority,sid,retry['generation']))
        calls=[]
        result=await asyncio.to_thread(agent._product_computer_gate,'terminal',{'command':'unsafe'},'late',lambda args:calls.append(args))
        self.assertIn('report_only',result);self.assertEqual([],calls)

    def test_expired_foreign_human_may_reacquire_without_stale_release(self):
        clock=[1.0]; lease=DesktopLease(self.data,now=lambda:clock[0])
        lease.write(dict(owner='agent',epoch=0,agent_work={'work_id':'a','run_id':'run','generation':1}))
        old=lease.acquire('one',str(uuid.uuid4())); clock[0]=30
        new=lease.acquire('two',str(uuid.uuid4()))
        with self.assertRaises(PermissionError):lease.release('one',old['session'])
        released=lease.release('two',new['session']);self.assertEqual('a',released['agent_work']['work_id'])
        self.assertEqual(released,lease.release('two',new['session']))
    async def test_cancel_targets_active_claim_not_newer_queued_steer(self):
        accepted=self.store.accept(str(uuid.uuid4()),'active task','scope')
        work=self.store.db.execute('SELECT * FROM works WHERE id=?',(accepted['work_id'],)).fetchone();sid=work['native_root']
        self.admit(sid,accepted['run_id']);claimed=claim_session_input(self.db,epoch=self.epoch,session_id=sid)
        self.admit(sid,'later-queued-supplement',True)
        product=PersonalAgent.__new__(PersonalAgent);product.store=self.store
        product.authority=lambda:SimpleNamespace(db=self.db,logical_owner=lambda value:value)
        product.child_snapshot=lambda:[];product.apply_cancellations=AsyncMock()
        operation=dict(operation_id=str(uuid.uuid4()),execution_generation=claimed['generation'])
        await product.cancel_work(work['id'],operation)
        await product.cancel_work(work['id'],operation)
        self.assertEqual(1,self.store.db.execute('SELECT count(*) FROM work_cancels').fetchone()[0])
        self.assertEqual(1,self.store.db.execute('SELECT cancel_requested FROM works WHERE id=?',(work['id'],)).fetchone()[0])
        # Request acceptance does not mutate native started state or pretend it stopped.
        self.assertEqual('started',get_session_admission(self.db,admission_id=claimed['admission_id'])['status'])

    async def test_disappeared_child_is_durable_unknown_not_cancelled(self):
        accepted=self.store.accept(str(uuid.uuid4()),'lost process','scope')
        self.store.db.execute("INSERT INTO work_children VALUES(?,?,?,?,?,?,?,?,?,?)",('process:lost',accepted['work_id'],accepted['run_id'],'process','lost',1,1,'lost','running',1));self.store.db.commit()
        product=PersonalAgent.__new__(PersonalAgent);product.store=self.store
        product.authority=lambda:SimpleNamespace(db=self.db,logical_owner=lambda value:value)
        with patch('tools.async_delegation.list_async_delegations',return_value=[]),patch('tools.process_registry.process_registry.list_sessions',return_value=[]):
            rows=product.child_snapshot()
        self.assertEqual('unknown',rows[0]['state']);self.assertEqual('requested',rows[0]['cancel_state'])
        self.assertFalse(rows[0]['cancellable'])
        self.assertEqual('unknown',self.store.db.execute('SELECT state FROM work_children').fetchone()[0])

    async def test_exited_process_without_notify_on_complete_settles_reported(self):
        accepted=self.store.accept(str(uuid.uuid4()),'sync polled process','scope')
        sid=self.store.db.execute('SELECT native_root FROM works WHERE id=?',(accepted['work_id'],)).fetchone()[0]
        product=PersonalAgent.__new__(PersonalAgent);product.store=self.store
        product.authority=lambda:SimpleNamespace(db=self.db,logical_owner=lambda value:value)
        session=dict(session_id='proc_sync',parent_session_id=sid,started_at_epoch=10.0,command='echo ok',status='exited',exit_code=0,completion_reason='exited')
        with patch('tools.async_delegation.list_async_delegations',return_value=[]),patch('tools.process_registry.process_registry.list_sessions',return_value=[session]):
            rows=product.child_snapshot()
        self.assertEqual('completed',rows[0]['state'])
        self.assertEqual('reported',rows[0]['report_state'])

    async def test_wait_return_reobserve_and_cancel_never_replays_input(self):
        accepted=self.store.accept(str(uuid.uuid4()),'control task','scope')
        work=self.store.db.execute('SELECT * FROM works WHERE id=?',(accepted['work_id'],)).fetchone();sid=work['native_root']
        self.admit(sid,accepted['run_id']);claimed=claim_session_input(self.db,epoch=self.epoch,session_id=sid)
        product=PersonalAgent.__new__(PersonalAgent);product.store=self.store;product.data=self.data;product.loop=asyncio.get_running_loop()
        authority=SimpleNamespace(db=self.db,logical_owner=lambda value:value)
        product.authority=lambda:authority
        agent=SimpleNamespace(_interrupt_requested=False)
        product.bind_computer_gate(agent,(authority,sid,claimed['generation']))
        lease=DesktopLease(self.data);human=lease.acquire('phone',str(uuid.uuid4()));calls=[]
        execute=lambda args:calls.append(args) or 'ok'
        pending=asyncio.create_task(asyncio.to_thread(agent._product_computer_gate,'mcp__momo_computer__computer_input',{},'click-1',execute))
        await asyncio.sleep(.2);self.assertFalse(pending.done());self.assertEqual([],calls)
        lease.release('phone',human['session'])
        result=await asyncio.wait_for(pending,2);self.assertIn('desktop_changed',result);self.assertEqual([],calls)
        # A screenshot confirms only the exact current epoch before the next input.
        def screenshot(args):
            with lease.locked():
                current=lease.read();current['observed_epoch']=args['momo_control']['epoch'];lease.write(current)
            return 'image'
        await asyncio.to_thread(agent._product_computer_gate,'mcp__momo_computer__computer_screenshot',{},'shot',screenshot)
        await asyncio.to_thread(agent._product_computer_gate,'mcp__momo_computer__computer_input',{},'click-2',execute)
        self.assertEqual(1,len(calls))
        human=lease.acquire('phone',str(uuid.uuid4()))
        pending=asyncio.create_task(asyncio.to_thread(agent._product_computer_gate,'mcp__momo_computer__computer_input',{},'click-3',execute))
        await asyncio.sleep(.15);agent._interrupt_requested=True
        self.assertIn('cancelled',await asyncio.wait_for(pending,2));lease.release('phone',human['session'])
        self.assertEqual(1,len(calls))

    async def test_agent_desktop_refs_wait_reobserve_and_cancel(self):
        accepted=self.store.accept(str(uuid.uuid4()),'control task','scope')
        work=self.store.db.execute('SELECT * FROM works WHERE id=?',(accepted['work_id'],)).fetchone();sid=work['native_root']
        self.admit(sid,accepted['run_id']);claimed=claim_session_input(self.db,epoch=self.epoch,session_id=sid)
        product=PersonalAgent.__new__(PersonalAgent);product.store=self.store;product.data=self.data;product.loop=asyncio.get_running_loop()
        authority=SimpleNamespace(db=self.db,logical_owner=lambda value:value)
        product.authority=lambda:authority
        agent=SimpleNamespace(_interrupt_requested=False)
        product.bind_computer_gate(agent,(authority,sid,claimed['generation']))
        lease=DesktopLease(self.data);human=lease.acquire('phone',str(uuid.uuid4()));calls=[]
        execute=lambda args:calls.append(args) or 'ok'
        pending=asyncio.create_task(asyncio.to_thread(agent._product_computer_gate,'mcp__momo_computer__computer_action',{},'click-1',execute))
        await asyncio.sleep(.2);self.assertFalse(pending.done());self.assertEqual([],calls)
        lease.release('phone',human['session'])
        result=await asyncio.wait_for(pending,2);self.assertIn('desktop_changed',result);self.assertEqual([],calls)
        # A screenshot confirms only the exact current epoch before the next input.
        def screenshot(args):
            with lease.locked():
                current=lease.read();current['observed_epoch']=args['momo_control']['epoch'];lease.write(current)
            return 'image'
        await asyncio.to_thread(agent._product_computer_gate,'mcp__momo_computer__computer_snapshot',{},'shot',screenshot)
        await asyncio.to_thread(agent._product_computer_gate,'mcp__momo_computer__computer_action',{},'click-2',execute)
        self.assertEqual(1,len(calls))
        human=lease.acquire('phone',str(uuid.uuid4()))
        pending=asyncio.create_task(asyncio.to_thread(agent._product_computer_gate,'mcp__momo_computer__computer_action',{},'click-3',execute))
        await asyncio.sleep(.15);agent._interrupt_requested=True
        self.assertIn('cancelled',await asyncio.wait_for(pending,2));lease.release('phone',human['session'])
        self.assertEqual(1,len(calls))

if __name__=='__main__':unittest.main()
