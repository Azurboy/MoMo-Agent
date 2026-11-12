"""Disposable UI fixture; approves only requests to its own invitation in a synthetic runtime."""
import argparse
import json
from pathlib import Path
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

p = argparse.ArgumentParser(); p.add_argument('--data-dir', type=Path, required=True)
p.add_argument('--output', type=Path, required=True); p.add_argument('--public', action='store_true')
args = p.parse_args(); data = args.data_dir.resolve()
model_keys = [line for line in (data / 'profile/.env').read_text().splitlines() if line.startswith('OPENAI_API_KEY=')]
assert model_keys == ['OPENAI_API_KEY=synthetic-local-only']
connection = json.loads((data / 'connection.json').read_text())
key = (data / 'api-key').read_text().strip()
base = f'http://127.0.0.1:{connection["port"] + 3}'

def control(path, body=None):
    request = urllib.request.Request(base + '/' + path, data=json.dumps(body).encode() if body is not None else None,
        headers={'Authorization': 'Bearer ' + key, 'Content-Type': 'application/json'})
    with urllib.request.urlopen(request, timeout=15) as response: return json.load(response)

state = control('pair/invite', {} if args.public else {'loopback': True})
invitation = state['invitation']; seen = {d['id'] for d in state['devices']}; approved = []; stop = threading.Event()
args.output.write_text(invitation['payload'])

def approve():
    while not stop.wait(1):
        try:
            for device in control('status')['devices']:
                if device['id'] not in seen and device['state'] == 'pending' and device['endpoint'] == invitation['endpoint']:
                    seen.add(device['id'])
                    if stop.wait(8): return
                    control('pair/decide', {'id': device['id'], 'allow': True}); approved.append(device['id'])
                    print('Synthetic phone approved', flush=True)
        except (OSError, ValueError) as e: print(type(e).__name__, flush=True)

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def do_GET(self):
        self.send_response(200); self.end_headers(); self.wfile.write(b'{"synthetic":true}')

server = ThreadingHTTPServer(('127.0.0.1', 18778), Handler)
threading.Thread(target=approve, daemon=True).start()
print('Pairing fixture ready', flush=True)
try: server.serve_forever()
finally:
    stop.set(); server.server_close()
    for ident in approved: control('devices/revoke', {'id': ident})
