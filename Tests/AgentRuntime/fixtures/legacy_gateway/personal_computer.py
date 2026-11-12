"""Claim-bound computer arbitration, outside the MCP RPC lock."""
import asyncio
import json
import sys
import time
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[4]/'Apps/MacApp/Access'))
from desktop_control import DesktopLease

COMPUTER_TOOLS={'mcp__momo_computer__computer_screenshot','mcp__momo_computer__computer_input','mcp__momo_computer__computer_snapshot','mcp__momo_computer__computer_action'}


class ComputerGate:
    def computer_wait(self,run_id,generation):
        row=self.store.db.execute("SELECT * FROM computer_calls WHERE run_id=? AND generation=? AND state='waiting' ORDER BY call_id LIMIT 1",(run_id,generation)).fetchone()
        return dict(row) if row else None

    def bind_computer_gate(self, agent, owner):
        authority,sid,generation=owner
        loop=self.loop
        async def report_mode():
            # Observer binding runs on the model worker; product SQLite is owned
            # by the main loop. Resolve the exact claim there on every dispatch.
            with authority.db._read_ctx() as db:
                row=db.execute("SELECT request_id FROM session_admissions WHERE target_session_id=? AND generation=?",(sid,generation)).fetchone()
            if row:
                for receipt in self.store.db.execute('SELECT event_key,report_attempt FROM completions WHERE report_attempt>0'):
                    prefix='momo_completion_'+receipt['event_key']+'_report_'
                    suffix=row[0].removeprefix(prefix)
                    if row[0].startswith(prefix) and suffix.isdecimal() and 1<=int(suffix)<=receipt['report_attempt']:return True
            return False
        async def step(call_id,finish=False):
            if finish:
                with self.store.db:
                    self.store.db.execute("UPDATE computer_calls SET state='ended' WHERE call_id=?",(call_id,))
                    self.store.db.execute("UPDATE computer_waits SET state='ended' WHERE tool_call_id=?",(call_id,))
                return None
            work=self.work_for_session(sid); delegation=getattr(agent,'_delegation_id',None)
            with authority.db._read_ctx() as db:
                if delegation:
                    row=db.execute('SELECT state,parent_session_id FROM async_delegations WHERE delegation_id=?',(delegation,)).fetchone()
                    valid=row and row['state'] in ('running','dispatched','stalling') and authority.logical_owner(row['parent_session_id'])==authority.logical_owner(sid)
                    run_id='delegation:'+delegation; claim_generation=1
                    child=self.store.db.execute('SELECT cancel_requested FROM work_children WHERE id=?',(run_id,)).fetchone()
                    valid=valid and not (child and child[0])
                else:
                    row=db.execute('SELECT request_id,status,generation FROM session_admissions WHERE target_session_id=? AND generation=? ORDER BY seq LIMIT 1',(sid,generation)).fetchone()
                    valid=row and row['status']=='started' and row['generation']==generation
                    run_id=row['request_id'] if row else ''; claim_generation=generation
            if not work or work['cancel_requested'] or not valid:return None
            token=dict(work_id=work['id'],run_id=run_id,generation=claim_generation)
            lease=DesktopLease(self.data)
            # Lease acquisition and the in-flight marker are serialized on the main
            # loop. No RPC lock is held during wait; external takeover uses the flock.
            with lease.locked():
                current=lease.read(); holder=current.get('agent_work')
                allowed=current['owner']=='agent' and (holder is None or holder==token)
                reason=None if allowed else 'computer_human' if current['owner']!='agent' else 'computer_task'
                blocker=holder.get('work_id') if holder and not allowed else None
                state='inflight' if allowed else 'waiting'
                if allowed: current['agent_work']=token;lease.write(current)
                with self.store.db:
                    self.store.db.execute('INSERT OR REPLACE INTO computer_calls VALUES(?,?,?,?,?,?,?,?)',(call_id,run_id,work['id'],claim_generation,state,reason,blocker,current['epoch']))
                    self.store.db.execute('INSERT OR REPLACE INTO computer_waits VALUES(?,?,?,?,?,?)',(run_id,work['id'],claim_generation,call_id,current['epoch'],'running' if allowed else 'waiting'))
                return token,allowed,current['epoch'],current.get('observed_epoch')
        def call(call_id,finish=False):
            # Provider call IDs are not globally unique across independent work.
            key=json.dumps([sid,generation,getattr(agent,'_delegation_id',None),call_id],separators=(',',':'))
            return asyncio.run_coroutine_threadsafe(step(key,finish),loop).result(timeout=10)
        def gate(name,args,call_id,execute):
            if asyncio.run_coroutine_threadsafe(report_mode(),loop).result(timeout=10):return json.dumps({'error':'report_only','message':'Only summarize the saved result. No tools or original task may run.'})
            if name not in COMPUTER_TOOLS:return execute(args)
            try:
                while not agent._interrupt_requested:
                    snapshot=call(call_id)
                    if snapshot is None:return json.dumps({'error':'cancelled'})
                    token,allowed,epoch,observed=snapshot
                    if allowed:break
                    time.sleep(.1)
                else:return json.dumps({'error':'cancelled'})
                if agent._interrupt_requested:return json.dumps({'error':'cancelled'})
                if name.endswith(('computer_input','computer_action')) and observed!=epoch:
                    return json.dumps({'error':'desktop_changed','message':'Read computer_snapshot or computer_screenshot before deciding the next action. No old input was replayed.'})
                return execute({**args,'momo_control':{**token,'epoch':epoch}})
            finally:call(call_id,True)
        agent._product_computer_gate=gate
        agent._product_bind_child=lambda child: self.bind_computer_gate(child,owner)

    def reconcile_computer(self):
        lease=DesktopLease(self.data)
        with lease.locked():
            value=lease.read(); holder=value.get('agent_work')
            if not holder:return
            authority=self.authority(); blocked=False
            with authority.db._read_ctx() as db:
                if holder['run_id'].startswith('delegation:'):
                    run=db.execute('SELECT state FROM async_delegations WHERE delegation_id=?',(holder['run_id'].split(':',1)[1],)).fetchone()
                    active=run and run['state'] in ('running','dispatched','stalling')
                else:
                    run=db.execute('SELECT status,generation,target_session_id FROM session_admissions WHERE request_id=?',(holder['run_id'],)).fetchone()
                    active=run and run['status']=='started' and run['generation']==holder['generation']
                    live=getattr(authority,'sessions',{}).get(run['target_session_id']) if run else None
                    if active and live:
                        with live.event_stream.lock:
                            blocked=bool(live.controls.snapshot(run['target_session_id'],holder['generation']))
            inflight=self.store.db.execute("SELECT 1 FROM computer_calls WHERE run_id=? AND generation=? AND state='inflight'",(holder['run_id'],holder['generation'])).fetchone()
            # A parent waiting for an answer never releases a child's active lease.
            if inflight or (active and not blocked):return
            value.pop('agent_work',None); value.pop('observed_epoch',None)
            value['epoch']+=1;lease.write(value)
            if not active:
                with self.store.db:
                    self.store.db.execute("UPDATE computer_calls SET state='ended' WHERE run_id=?",(holder['run_id'],))
                    self.store.db.execute("UPDATE computer_waits SET state='ended' WHERE run_id=?",(holder['run_id'],))
