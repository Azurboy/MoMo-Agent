"""Check bundled engine payloads and Hermes cold setup without network or developer tools."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('app', type=Path)
args = parser.parse_args()
app = args.app.resolve()
root = app / 'Contents/Resources/AgentRuntime'
python = root / 'python/bin/python3.14'
script = root / 'Apps/MacApp/Runtime/momo_agent.py'
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
assert 'MoMoRepositoryRoot' not in info
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
# Deny network and all known developer sources/interpreters for this process.
blocked = [str(Path(__file__).resolve().parents[2]), '/opt/homebrew', '/usr/local',
           str(Path.home() / '.local/share/uv'),
           str(Path.home() / 'Library/Application Support/MoMoAgent/Agent/runtime/tools'),
           str(Path.home() / 'Workspace/MoMo-Agent/Apps'),
           str(Path.home() / 'Workspace/MoMo-Agent/Vendor')]
profile = '(version 1)(allow default)(deny network*)' + ''.join(
    '(deny file-read* (subpath ' + json.dumps(p) + '))' for p in blocked if not root.is_relative_to(p))
with tempfile.TemporaryDirectory(prefix='momo-cold-setup-') as temp:
    home = Path(temp)
    data = home / 'Agent'
    environment = {'HOME': str(home), 'PATH': '/usr/bin:/bin', 'UV_OFFLINE': '1', 'TMPDIR': temp,
                   'PYTHONDONTWRITEBYTECODE': '1', 'LC_ALL': 'en_US.UTF-8'}
    prefix = ['/usr/bin/sandbox-exec', '-p', profile, str(python), '-I', '-B']
    def run(*arguments):
        subprocess.run(prefix + list(arguments), env=environment, cwd=temp, check=True,
                       stdout=subprocess.DEVNULL, timeout=90)
    run(str(script), 'init', '--data-dir', str(data), '--port', '19870')
    # SuperAgent uses a separately prepared Node runner; Hermes is the offline Python path.
    run(str(script), 'engine', '--data-dir', str(data), '--engine', 'hermes')
    run('-c', 'import sys; sys.path.insert(0, ' + repr(str(script.parent)) +
        '); from superagent_runtime import superagent_fingerprint; assert superagent_fingerprint()["bundle_sha256"]')
    before = {str(p.relative_to(data)): hashlib.sha256(p.read_bytes()).hexdigest()
              for p in data.rglob('*') if p.is_file()}
    run(str(script), 'prepare', '--data-dir', str(data))
    run(str(script), 'prepare', '--data-dir', str(data))
    run(str(root / 'Apps/MacApp/Access/access_server.py'), '--help')
    run('-c', 'import ssl,sqlite3,aiohttp,aiortc,cryptography,openai,anthropic,mcp; assert sqlite3.sqlite_version_info >= (3,51,3)')
    run('-c', 'import sys; sys.path.insert(0, ' + repr(str(root / 'Vendor/HermesAgent')) +
        '); import gateway.run_shutdown, gateway.session_llm_oneshot')
    after = {str(p.relative_to(data)): hashlib.sha256(p.read_bytes()).hexdigest()
             for p in data.rglob('*') if p.is_file()}
    assert before == after, 'Setup altered existing identity or config'
    assert not (data / 'runtime/venv').exists(), 'Setup rebuilt a user environment'
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
print(json.dumps({'version': info['CFBundleShortVersionString'], 'build': info['CFBundleVersion'],
                  'hermes_cold_setup_without_network': True, 'hermes_developer_tools_not_required': True,
                  'superagent_payload_verified': True,
                  'identity_preserved_on_repeat': True, 'bundle_signature_preserved': True}))
