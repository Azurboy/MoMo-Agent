"""Serve real generated images through the normal API for isolated Simulator acceptance.

The scenes and transcripts are invented acceptance fixtures. This server never reads
OAuth credentials, user recordings, or a running Mac application's database.
"""
import argparse
import datetime as dt
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
from urllib.parse import urlsplit, parse_qs
from zoneinfo import ZoneInfo


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--samples', type=Path, required=True)
    parser.add_argument('--port', type=int, default=18743)
    args = parser.parse_args()
    zone = ZoneInfo('Asia/Shanghai')
    now = dt.datetime.now(zone)
    boundary = now.replace(hour=8, minute=0, second=0, microsecond=0)
    if now < boundary:
        boundary -= dt.timedelta(days=1)
    assets, items = {}, []
    for index, name in enumerate(('code', 'outdoor', 'night')):
        data = (args.samples / f'sample_{name}.png').read_bytes()
        thumbnail = (args.samples / f'sample_{name}_thumbnail.png').read_bytes()
        from PIL import Image
        import io
        for raw, size in [(data, 1024), (thumbnail, 512)]:
            with Image.open(io.BytesIO(raw)) as image:
                if image.format != 'PNG' or image.size != (size, size) or image.mode != 'RGBA':
                    raise ValueError('Acceptance needs the real square RGBA originals and thumbnails')
        sha = hashlib.sha256(data).hexdigest()
        thumbnail_sha = hashlib.sha256(thumbnail).hexdigest()
        assets[sha] = data
        assets[thumbnail_sha] = thumbnail
        start = boundary.timestamp() + (6 + index * 3) * 3600
        items.append(dict(id=f'sample-{name}', deleted=False, window_start=start, window_end=start+10800,
                          logical_day=boundary.date().isoformat(), timezone='Asia/Shanghai', place=None,
                          asset_sha256=sha, thumbnail_sha256=thumbnail_sha, width=1024, height=1024,
                          source_ids=[f'acceptance-{name}'], created_at=start+11400, updated_at=start+11400))
    settings = dict(enabled=True, interval_hours=3, day_start_hour=8, provider='openai-codex', supported=True,
                    service_status='ready', updated_at=now.timestamp(), pending_count=0, needs_review_count=0)

    class Handler(BaseHTTPRequestHandler):
        def send(self, value, status=200):
            data = value if isinstance(value, bytes) else json.dumps(value).encode()
            self.send_response(status)
            self.send_header('Content-Type', 'image/png' if isinstance(value, bytes) else 'application/json')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            if self.headers.get('Authorization') != 'Bearer life-illustration-fixture':
                return self.send({'error': 'unauthorized'}, 401)
            url = urlsplit(self.path)
            if url.path.endswith('/settings'):
                return self.send(settings)
            if url.path.endswith('/manifest'):
                cursor = int(parse_qs(url.query).get('cursor', ['0'])[0])
                return self.send(dict(items=items[cursor:], next_cursor=str(len(items)), has_more=False))
            sha = url.path.rsplit('/', 1)[-1]
            if '/assets/' in url.path and sha in assets:
                return self.send(assets[sha])
            self.send({'error': 'not_found'}, 404)

        def do_POST(self):
            if self.headers.get('Authorization') != 'Bearer life-illustration-fixture':
                return self.send({'error': 'unauthorized'}, 401)
            body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', 0))) or b'{}')
            if self.path.endswith('/settings'):
                settings.update(enabled=body['enabled'], interval_hours=body['interval_hours'])
                return self.send(settings)
            if self.path.endswith('/delete'):
                tombstone = dict(id=body['id'], deleted=True, updated_at=dt.datetime.now().timestamp())
                items.append(tombstone)
                return self.send(tombstone)
            self.send({'error': 'not_found'}, 404)

    print(f'Fixture API listening on http://127.0.0.1:{args.port}', flush=True)
    ThreadingHTTPServer(('127.0.0.1', args.port), Handler).serve_forever()


if __name__ == '__main__':
    main()
