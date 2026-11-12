"""SuperAgent calls share the native desktop lease with the paired phone.

A ticket holds the desktop only for a single tool call, never while waiting for
human input. Observations are bound to its assignment and the takeover epoch.
"""
import asyncio
from collections import OrderedDict
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Access'))
from desktop_control import DesktopLease, native_request


class SuperAgentComputer:
    def __init__(self, data, read_ticket):
        self.data = Path(data)
        self.read_ticket = read_ticket
        self.lock = asyncio.Lock()
        self.observations = OrderedDict()

    async def call(self, ticket_id, assignment_id, op, args):
        if op not in ('accessibility-snapshot', 'accessibility-action'):
            raise ValueError('Unsupported computer operation')
        if not isinstance(ticket_id, str) or not isinstance(assignment_id, str) or not ticket_id or not assignment_id:
            raise ValueError('Missing ticket authority')
        async with self.lock:
            ticket = await self.read_ticket(ticket_id)
            active = [a for a in ticket.get('assignments', ()) if a.get('id') == assignment_id and a.get('state') == 'running' and not a.get('turnEndedAt')]
            if ticket.get('state') != 'open' or ticket.get('paused') or ticket.get('ended') or ticket.get('attention') or not active:
                raise PermissionError('Ticket is stopped, paused or waiting for the user')
            token = dict(work_id='superagent:' + ticket_id, run_id=assignment_id, generation=1)
            lease = DesktopLease(self.data)
            observed_key = (ticket_id, assignment_id)
            with lease.locked():
                current = lease.read()
                if current['owner'] != 'agent' or current.get('agent_work'):
                    raise PermissionError('Desktop is held by the user or another task. Wait for control; do not bypass it.')
                if current.get('last_agent_work') != token:
                    current['epoch'] += 1
                epoch = current['epoch']
                if op == 'accessibility-action' and self.observations.get(observed_key) != epoch:
                    raise PermissionError('Desktop changed. Read computer_snapshot before deciding a new action.')
                current['agent_work'] = token
                current['last_agent_work'] = token
                current.pop('observed_epoch', None)
                if self.observations.get(observed_key) == epoch: current['observed_epoch'] = epoch
                lease.write(current)
            try:
                payload = dict(op=op, actor='agent', control=dict(**token, epoch=epoch))
                if op == 'accessibility-snapshot':
                    payload.update(app=args.get('app', ''), depth=args.get('depth', 10))
                else:
                    payload['event'] = args
                result = await native_request(self.data, payload)
                if 'error' in result: raise RuntimeError(result['error'])
                with lease.locked():
                    current = lease.read()
                    if current['owner'] != 'agent' or current['epoch'] != epoch or current.get('agent_work') != token:
                        raise PermissionError('Desktop control changed during this call. Read again after control returns.')
                    if op == 'accessibility-snapshot' and result['result'].get('ok'):
                        self.observations[observed_key] = epoch
                        self.observations.move_to_end(observed_key)
                        while len(self.observations) > 256: self.observations.popitem(last=False)
                return result['result']
            finally:
                with lease.locked():
                    current = lease.read()
                    if current.get('agent_work') == token:
                        current.pop('agent_work', None)
                        current.pop('observed_epoch', None)
                        lease.write(current)
