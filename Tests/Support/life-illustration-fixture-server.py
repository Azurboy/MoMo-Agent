"""Serve real generated images through the normal API for isolated Simulator acceptance.

The scenes and transcripts are invented acceptance fixtures. This server never reads
OAuth credentials, user recordings, or a running Mac application's database.
"""
import argparse
import datetime as dt
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import io
import json
from pathlib import Path
from urllib.parse import urlsplit, parse_qs
from zoneinfo import ZoneInfo


def load_png_pair(samples: Path, name: str):
    from PIL import Image
    data = (samples / f'sample_{name}.png').read_bytes()
    thumbnail = (samples / f'sample_{name}_thumbnail.png').read_bytes()
    for raw, size in [(data, 1024), (thumbnail, 512)]:
        with Image.open(io.BytesIO(raw)) as image:
            if image.format != 'PNG' or image.size != (size, size) or image.mode not in ('RGB', 'RGBA'):
                raise ValueError('Acceptance needs the real square originals and thumbnails')
    return data, thumbnail, hashlib.sha256(data).hexdigest(), hashlib.sha256(thumbnail).hexdigest()


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
    journey = json.loads((args.samples / 'journey_generation_evidence.json').read_text())

    # Optional morning sticker at the same first stop (望京工作室) so acceptance verifies multi-image stops.
    if (args.samples / 'sample_morning.png').is_file():
        m_data, m_thumb, m_sha, m_thumb_sha = load_png_pair(args.samples, 'morning')
        assets[m_sha] = m_data
        assets[m_thumb_sha] = m_thumb
        first = journey['manifest']['items'][0]
        m_start = boundary.timestamp() + 3 * 3600 + 25 * 60
        m_end = boundary.timestamp() + 4 * 3600 + 2 * 60
        items.append(dict(
            id='sample-morning', deleted=False, window_start=m_start, window_end=m_end,
            logical_day=boundary.date().isoformat(), timezone='Asia/Shanghai', place=first['place'],
            summary='铺开草图纸核对接口清单，先把待确认的数据字段记在便签纸上，尚未定案',
            latitude=first['latitude'] + 0.0001, longitude=first['longitude'] + 0.0001,
            place_start=boundary.timestamp() + 3 * 3600 + 360, place_end=boundary.timestamp() + 6 * 3600,
            route_points=[dict(
                latitude=first['latitude'] + 0.0001, longitude=first['longitude'] + 0.0001,
                timestamp=boundary.timestamp() + 3 * 3600 + 360, end_timestamp=boundary.timestamp() + 6 * 3600,
                kind='visit', title=first['place']
            )],
            asset_sha256=m_sha, thumbnail_sha256=m_thumb_sha, width=1024, height=1024,
            source_ids=['acceptance-morning'], created_at=m_end + 600, updated_at=m_end + 600
        ))

    episode_windows = [
        ('code', 6 * 3600 + 12 * 60, 6 * 3600 + 50 * 60),
        ('outdoor', 9 * 3600 + 15 * 60, 9 * 3600 + 48 * 60),
        ('night', 12 * 3600 + 15 * 60, 12 * 3600 + 50 * 60),
    ]
    for index, (name, start_offset, end_offset) in enumerate(episode_windows):
        data, thumbnail, sha, thumbnail_sha = load_png_pair(args.samples, name)
        assets[sha] = data
        assets[thumbnail_sha] = thumbnail
        batch_start = boundary.timestamp() + (6 + index * 3) * 3600
        start = boundary.timestamp() + start_offset
        end = boundary.timestamp() + end_offset
        generated = journey['manifest']['items'][index]
        shift = batch_start - generated['window_start']
        items.append(dict(id=f'sample-{name}', deleted=False, window_start=start, window_end=end,
                          logical_day=boundary.date().isoformat(), timezone='Asia/Shanghai', place=generated['place'],
                          summary=generated['summary'], latitude=generated['latitude'], longitude=generated['longitude'],
                          place_start=generated['place_start'] + shift, place_end=generated['place_end'] + shift,
                          route_points=[dict(point, timestamp=point['timestamp'] + shift,
                              end_timestamp=point['end_timestamp'] + shift if point.get('end_timestamp') is not None else None)
                              for point in generated['route_points']],
                          asset_sha256=sha, thumbnail_sha256=thumbnail_sha, width=1024, height=1024,
                          source_ids=[f'acceptance-{name}'], created_at=batch_start + 11400, updated_at=batch_start + 11400))
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
