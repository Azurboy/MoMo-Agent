"""Local native GUI E2E. Uses an isolated signed MoMo build and a disposable AppKit form.

No external model or personal applications are involved. Requires macOS Accessibility
permission for the signed MoMo application. Never modifies TCC or the installed app.
"""
import argparse
import asyncio
import json
import hashlib
import os
import plistlib
from pathlib import Path
import signal
import subprocess
import sys
import uuid

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / 'Apps/MacApp/Runtime'), str(ROOT / 'Apps/MacApp/Access'), str(ROOT / 'Vendor/HermesAgent')]
from desktop_control import DesktopLease, native_request


def require(value, reason):
    if not value: raise AssertionError(reason)


def prepare(args):
    from momo_agent import initialize
    from runtime_engine import write_engine_config
    output = args.output.resolve()
    marker = output / '.desktop-e2e-owned'
    if output.exists() and any(output.iterdir()):
        require(marker.is_file() and marker.read_text() == 'MoMo disposable desktop E2E\n', 'Refusing an existing non-test output directory')
    output.mkdir(parents=True, exist_ok=True)
    marker.write_text('MoMo disposable desktop E2E\n')
    if (output/'test-pids.json').exists():
        for pid in json.loads((output/'test-pids.json').read_text()):
            try: os.kill(pid, 0)
            except ProcessLookupError: continue
            raise RuntimeError(f'Previous test process {pid} is still alive; do not reset its lease')
    require((ROOT/'Vendor/SuperAgent/node_modules/.bin/vitest').is_file(), 'Run pnpm install --frozen-lockfile in Vendor/SuperAgent first')
    subprocess.run(['codesign','--verify','--deep','--strict',str(args.app)],check=True,capture_output=True,timeout=20)
    fixture = output/'MoMo Desktop Fixture.app/Contents'
    (fixture/'MacOS').mkdir(parents=True,exist_ok=True)
    subprocess.run(['swiftc',str(ROOT/'Tests/Support/agent-desktop-fixture.swift'),'-parse-as-library','-o',str(fixture/'MacOS/MoMoDesktopFixture')],check=True,timeout=60)
    (fixture/'Info.plist').write_bytes(plistlib.dumps(dict(CFBundleIdentifier='com.momoagent.desktop-e2e-fixture',CFBundleExecutable='MoMoDesktopFixture',CFBundleName='MoMo Desktop Fixture',CFBundlePackageType='APPL',NSHighResolutionCapable=True)))
    subprocess.run(['codesign','--force','--sign','-',str(fixture.parent)],check=True,capture_output=True,timeout=20)
    data=output/'data'
    initialize(data,18465)
    write_engine_config(data, proactive_mode='off')
    venv=data/'runtime/venv'
    if not venv.exists(): venv.symlink_to(Path(sys.executable).parent.parent,target_is_directory=True)
    (output/'fixture-state.json').unlink(missing_ok=True)


async def stop_access_child(data):
    record_path = data/'runtime/desktop-access_server.pid'
    if not record_path.exists(): return
    record=json.loads(record_path.read_text())
    require(record['repository'] == str(ROOT.resolve()), 'Access child belongs to another checkout')
    pid=int(record['pid'])
    def owned():
        command=subprocess.run(['ps','-p',str(pid),'-o','args='],capture_output=True,text=True).stdout.strip()
        return str(ROOT/'Apps/MacApp/Access/access_server.py') in command and command.endswith('--data-dir '+str(data))
    if not owned(): return
    os.kill(pid,signal.SIGTERM)
    for _ in range(50):
        if not owned(): return
        await asyncio.sleep(.1)
    if owned(): os.kill(pid,signal.SIGKILL)


async def run(args):
    output = args.output.resolve(); data = output / 'data'
    require((output/'.desktop-e2e-owned').read_text() == 'MoMo disposable desktop E2E\n', 'Output is not an owned test directory')
    report = {'kind': 'local-native-gui-e2e', 'model': 'none', 'checks': [], 'status': 'running'}
    lease = DesktopLease(data)
    with lease.locked():
        previous=lease.read(); lease.write({'owner':'agent','epoch':previous['epoch']+1})
    started = []
    logs = []
    info=plistlib.loads((args.app/'Contents/Info.plist').read_bytes())
    report['application']={'bundle_id':info['CFBundleIdentifier'],'version':info['CFBundleShortVersionString'],
        'executable_sha256':hashlib.sha256((args.app/'Contents/MacOS/MoMoAgentMac').read_bytes()).hexdigest()}
    report['runner_commit']=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip()
    try:
        for label, command in [
            ('host', [str(args.app / 'Contents/MacOS/MoMoAgentMac'), '--data-dir', str(data), '--repository', str(ROOT)]),
            ('fixture', [str(output / 'MoMo Desktop Fixture.app/Contents/MacOS/MoMoDesktopFixture'), str(output)]),
        ]:
            log = (output / (label + '.log')).open('w'); logs.append(log)
            started.append(subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, start_new_session=True))
        (output / 'test-pids.json').write_text(json.dumps([p.pid for p in started]))
        status = None
        for _ in range(80):
            try:
                status = await native_request(data, dict(op='status', actor='agent'))
                break
            except (OSError, TimeoutError): await asyncio.sleep(.25)
        require(status is not None, 'Native host did not start')
        report['permissions'] = {k: status[k] for k in ('screen', 'input')}
        require(status.get('input'), 'MoMo Accessibility permission is missing; no TCC changes were made')
        for _ in range(40):
            if (output / 'fixture-state.json').is_file(): break
            await asyncio.sleep(.1)
        require((output / 'fixture-state.json').exists(), 'Fixture did not start')

        from aiohttp import web, ClientSession as HTTPClient
        from aiohttp.test_utils import TestServer
        from superagent_gateway import SuperAgentGateway
        from momo_agent import child_environment
        gateway = SuperAgentGateway(data, json.loads((data/'connection.json').read_text()), python_executable=Path(sys.executable), base_env=child_environment(data), manage_dsh=False)
        gateway._prepare_bridge_secret()
        ticket = dict(state='open', assignments=[dict(id='desktop-e2e-assignment', state='running')])
        ticket_app = web.Application()
        async def ticket_record(request): return web.json_response(ticket)
        ticket_app.router.add_get('/orchestrator/api/tickets/desktop-e2e-ticket', ticket_record)
        bridge_app = web.Application()
        bridge_app.router.add_post('/momo/internal/superagent/computer', gateway.handle_internal_computer)
        async with TestServer(ticket_app) as ticket_server, TestServer(bridge_app) as bridge_server:
            gateway.dsh_port = ticket_server.port
            bridge_url = str(bridge_server.make_url('/')).rstrip('/')
            with (output/'superagent-e2e.log').open('w') as testlog:
                proc = await asyncio.create_subprocess_exec('pnpm','exec','vitest','run','tests/momo-computer-e2e.spec.ts',cwd=ROOT/'Vendor/SuperAgent',
                    env={**os.environ,'MOMO_DESKTOP_E2E':str(output),'MOMO_DATA_DIR':str(data),'MOMO_COMPUTER_BRIDGE':bridge_url},stdout=testlog,stderr=asyncio.subprocess.STDOUT,start_new_session=True)
                try: require(await asyncio.wait_for(proc.wait(), 60) == 0, 'SuperAgent GUI journey failed; see superagent-e2e.log')
                finally:
                    if proc.returncode is None: os.killpg(proc.pid,signal.SIGTERM); await proc.wait()
            report['checks'].append('SuperAgent TypeScript tool → authenticated HTTP gateway → live ticket-read HTTP fixture → native GUI; saved exactly once')
            async with HTTPClient() as client:
                endpoint=bridge_url+'/momo/internal/superagent/computer'
                payload=dict(ticket_id='desktop-e2e-ticket',assignment_id='desktop-e2e-assignment',op='accessibility-snapshot',args={'app':'MoMo Desktop Fixture'})
                response=await client.post(endpoint,json=payload)
                require(response.status == 403, 'Unauthenticated bridge access was not refused')
                headers={'X-MoMo-Bridge':gateway.bridge_secret}
                human=lease.acquire('e2e-phone',str(uuid.uuid4()))
                response=await client.post(endpoint,json=payload,headers=headers)
                require(response.status == 409, 'SuperAgent bypassed human takeover')
                lease.release('e2e-phone',human['session'])
                ticket['state']='ended'
                response=await client.post(endpoint,json=payload,headers=headers)
                require(response.status == 409, 'Ended ticket reached native driver')
                require(json.loads((output/'fixture-state.json').read_text())['saves']==1, 'Unexpected extra save')
            report['checks'].append('SuperAgent bridge refuses missing credentials, human takeover and ended ticket')
        gateway.bridge.close(); gateway.store.db.close()
        await asyncio.sleep(.3)
        report['fixture_state']=json.loads((output/'fixture-state.json').read_text())
        report['ticket_authority']='Isolated test ticket/assignment; no LLM or external service'
        report['status'] = 'passed'
    except BaseException as error:
        report['status']='failed'; report['error']=str(error) or type(error).__name__
        raise
    finally:
        for process in reversed(started):
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
                try: process.wait(timeout=5)
                except subprocess.TimeoutExpired: os.killpg(process.pid, signal.SIGKILL); process.wait()
        await stop_access_child(data)
        for log in logs: log.close()
        (output/'report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
        print(json.dumps(report,ensure_ascii=False,indent=2))


if __name__ == '__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    args.app=args.app.resolve()
    prepare(args)
    asyncio.run(run(args))
